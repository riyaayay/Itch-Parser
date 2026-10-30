# ==============================================================================
# File        : tb/cocotb/test_t2t.py
# Spec Section: 12.2 (Gate IT-4), 15 (Task T10)
# Description : Constrained-random Cocotb verification suite for tick2trade-fpga.
#               Exercises valid & malformed streams, randomized pacing,
#               and randomized backpressure across 20+ pseudo-random seeds.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# ==============================================================================

import os
import sys
import random
import struct
import pathlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, Event
from cocotb.task import Task

# Add repo root to sys.path so model imports work cleanly
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from model.itch import encode_itch_message
from model.framer import AxisFramerModel
from model.replay import PipelineReplay
from model.trigger import TriggerConfig
from model.risk import RiskSymbolConfig, RiskGlobalConfig

# ------------------------------------------------------------------------------
# AXI-Lite and DUT Control Helpers
# ------------------------------------------------------------------------------

async def axi_write(dut, addr: int, data: int):
    """Perform a single 32-bit AXI-Lite write transaction."""
    dut.s_axi_ctrl_awaddr.value = addr & 0xFFF
    dut.s_axi_ctrl_awvalid.value = 1
    dut.s_axi_ctrl_wdata.value = data & 0xFFFFFFFF
    dut.s_axi_ctrl_wstrb.value = 0xF
    dut.s_axi_ctrl_wvalid.value = 1
    dut.s_axi_ctrl_bready.value = 1

    aw_done = False
    w_done = False

    while not (aw_done and w_done):
        await RisingEdge(dut.clk)
        if int(dut.s_axi_ctrl_awready.value) == 1:
            aw_done = True
            dut.s_axi_ctrl_awvalid.value = 0
        if int(dut.s_axi_ctrl_wready.value) == 1:
            w_done = True
            dut.s_axi_ctrl_wvalid.value = 0

    while int(dut.s_axi_ctrl_bvalid.value) == 0:
        await RisingEdge(dut.clk)

    await RisingEdge(dut.clk)
    dut.s_axi_ctrl_bready.value = 0


async def axi_read(dut, addr: int) -> int:
    """Perform a single 32-bit AXI-Lite read transaction."""
    dut.s_axi_ctrl_araddr.value = addr & 0xFFF
    dut.s_axi_ctrl_arvalid.value = 1
    dut.s_axi_ctrl_rready.value = 1

    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_axi_ctrl_arready.value) == 1:
            break
    dut.s_axi_ctrl_arvalid.value = 0

    while int(dut.s_axi_ctrl_rvalid.value) == 0:
        await RisingEdge(dut.clk)

    val = int(dut.s_axi_ctrl_rdata.value)
    await RisingEdge(dut.clk)
    dut.s_axi_ctrl_rready.value = 0
    return val


async def reset_dut(dut):
    """Hardware power-on reset and wait for BRAM table sweep."""
    dut.rst.value = 1
    dut.s_axi_ctrl_awvalid.value = 0
    dut.s_axi_ctrl_wvalid.value = 0
    dut.s_axi_ctrl_bready.value = 0
    dut.s_axi_ctrl_arvalid.value = 0
    dut.s_axi_ctrl_rready.value = 0
    dut.rx_axis_tvalid.value = 0
    dut.rx_axis_tlast.value = 0
    dut.rx_axis_tdata.value = 0
    dut.rx_axis_tkeep.value = 0
    dut.tx_axis_tready.value = 1

    await ClockCycles(dut.clk, 10)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)

    # Wait for session initialization sweep (1024 cycles)
    for _ in range(1100):
        await RisingEdge(dut.clk)
        # Check u_sess.o_init_busy if accessible
        try:
            if int(dut.u_sess.o_init_busy.value) == 0:
                break
        except Exception:
            pass
    await ClockCycles(dut.clk, 5)


# ------------------------------------------------------------------------------
# Background Coroutines: Backpressure & Outbound Monitoring
# ------------------------------------------------------------------------------

async def tx_backpressure_coro(dut, rng: random.Random, stop_event: Event):
    """Randomly backpressure tx_axis_tready to test outbound FIFO buffering."""
    while not stop_event.is_set():
        # ~75% ready, ~25% stalled
        is_ready = 1 if rng.random() > 0.25 else 0
        dut.tx_axis_tready.value = is_ready
        await RisingEdge(dut.clk)
    dut.tx_axis_tready.value = 1


async def framer_monitor_coro(dut, stop_event: Event):
    while not stop_event.is_set():
        await RisingEdge(dut.clk)
        if int(dut.u_framer.o_blk_valid.value) == 1:
            blen = int(dut.u_framer.o_blk_len.value)
            raw = int(dut.u_framer.o_blk_bytes.value)
            tbyte = raw & 0xFF
            dut._log.info(f"    [FRAMER OUT] len={blen} type=0x{tbyte:02X} ('{chr(tbyte) if 32 <= tbyte <= 126 else '?' }')")

async def tx_monitor_coro(dut, captured_frames: list, stop_event: Event):
    """Captures all accepted outbound 48-byte frames."""
    while not stop_event.is_set():
        await RisingEdge(dut.clk)
        if int(dut.tx_axis_tvalid.value) == 1 and int(dut.tx_axis_tready.value) == 1:
            raw_val = int(dut.tx_axis_tdata.value)
            frame_bytes = (raw_val & ((1 << 384) - 1)).to_bytes(48, byteorder="little")
            captured_frames.append(frame_bytes.hex().upper())


# ------------------------------------------------------------------------------
# Constrained Random Stimulus Generator
# ------------------------------------------------------------------------------

def generate_random_scenario(seed: int):
    """
    Constructs a randomized sequence of ITCH messages with valid order books,
    cancellations, executions, replaces, crossing triggers, and risk tests.
    """
    rng = random.Random(seed)
    stream = bytearray()

    symbols = [b"AAPL    ", b"SPY     ", b"MSFT    "]
    # Track open orders for valid execution / cancels: (ref, sym_idx, side, shares, price)
    open_orders = []
    next_ref = 1000 + (seed * 100)

    # 1. Populate initial book levels for AAPL (sym 0)
    for _ in range(rng.randint(6, 12)):
        sd = ord('B') if rng.random() > 0.5 else ord('S')
        px = 1500000 + (rng.randint(-50, 50) * 1000)
        sh = rng.randint(10, 100)
        rf = next_ref
        next_ref += 1
        msg = encode_itch_message(
            0x41, locate=1, ref=rf, side=sd, shares=sh,
            stock=b"AAPL    ", price=px
        )
        stream.extend(msg)
        open_orders.append((rf, 0, sd, sh, px))

    # 2. Populate initial book levels for SPY (sym 1)
    for _ in range(rng.randint(4, 8)):
        sd = ord('B') if rng.random() > 0.5 else ord('S')
        px = 4500000 + (rng.randint(-40, 40) * 1000)
        sh = rng.randint(10, 50)
        rf = next_ref
        next_ref += 1
        msg = encode_itch_message(
            0x46, locate=2, ref=rf, side=sd, shares=sh,
            stock=b"SPY     ", price=px, attribution=b"GSCO"
        )
        stream.extend(msg)
        open_orders.append((rf, 1, sd, sh, px))

    # 3. Add mixed operations: executions, cancels, deletes, replaces, triggers
    for _ in range(rng.randint(15, 25)):
        op_choice = rng.random()

        if op_choice < 0.25 and open_orders:
            # Type E: Partial execution
            idx = rng.randrange(len(open_orders))
            rf, s_idx, sd, sh, px = open_orders[idx]
            exec_sh = max(1, sh // 2)
            stream.extend(encode_itch_message(0x45, locate=s_idx+1, ref=rf, shares=exec_sh))
            open_orders[idx] = (rf, s_idx, sd, sh - exec_sh, px)

        elif op_choice < 0.40 and open_orders:
            # Type X: Partial cancel
            idx = rng.randrange(len(open_orders))
            rf, s_idx, sd, sh, px = open_orders[idx]
            cancel_sh = max(1, sh // 2)
            stream.extend(encode_itch_message(0x58, locate=s_idx+1, ref=rf, shares=cancel_sh))
            open_orders[idx] = (rf, s_idx, sd, sh - cancel_sh, px)

        elif op_choice < 0.55 and open_orders:
            # Type D: Full delete
            idx = rng.randrange(len(open_orders))
            rf, s_idx, sd, sh, px = open_orders.pop(idx)
            stream.extend(encode_itch_message(0x44, locate=s_idx+1, ref=rf))

        elif op_choice < 0.70 and open_orders:
            # Type U: Order Replace
            idx = rng.randrange(len(open_orders))
            rf, s_idx, sd, sh, px = open_orders.pop(idx)
            new_rf = next_ref
            next_ref += 1
            new_sh = rng.randint(20, 150)
            new_px = px + (rng.randint(-5, 5) * 1000)
            stream.extend(encode_itch_message(
                0x55, locate=s_idx+1, ref=rf, newref=new_rf,
                shares=new_sh, price=new_px
            ))
            open_orders.append((new_rf, s_idx, sd, new_sh, new_px))

        elif op_choice < 0.85:
            # Aggressive quote crossing trigger thresholds (CROSS_BUY / CROSS_SELL)
            s_idx = 0 if rng.random() > 0.4 else 1
            stk = b"AAPL    " if s_idx == 0 else b"SPY     "
            base_px = 1500000 if s_idx == 0 else 4500000
            sd = ord('B') if rng.random() > 0.5 else ord('S')
            px = base_px + (15000 if sd == ord('B') else -15000)
            sh = 50
            rf = next_ref
            next_ref += 1
            stream.extend(encode_itch_message(
                0x41, locate=s_idx+1, ref=rf, side=sd, shares=sh,
                stock=stk, price=px
            ))
            open_orders.append((rf, s_idx, sd, sh, px))

        else:
            # Unhandled message type or short block perturbation
            if rng.random() > 0.5:
                # System Event 'S'
                stream.extend(struct.pack(">HB11s", 12, ord('S'), b"\x00" * 11))
            else:
                # Zero length block
                stream.extend(struct.pack(">H", 0))

    # Pack into 64-byte beats
    beats = AxisFramerModel.pack_stream_into_beats(bytes(stream))

    # Execute Python Reference Model to determine expected outbound frames
    ref_symbols = [b"AAPL    ", b"SPY     ", b"MSFT    ", b"QQQ     ",
                   b"NVDA    ", b"TSLA    ", b"AMZN    ", b"META    "]
    replay = PipelineReplay(symbols=ref_symbols)

    sym0_tcfg = TriggerConfig(
        en=True, rule_mask=0x0F, imb_shift=0,
        buy_limit=1600000, sell_limit=1400000, max_spread=50000, qty=25
    )
    sym0_rcfg = RiskSymbolConfig(
        cfg_valid=True, max_qty=500, max_notional=100_000_000,
        collar_abs=100000, ref_px=1500000, max_pos=1000
    )
    sym1_tcfg = TriggerConfig(
        en=True, rule_mask=0x0F, imb_shift=0,
        buy_limit=4600000, sell_limit=4400000, max_spread=50000, qty=10
    )
    sym1_rcfg = RiskSymbolConfig(
        cfg_valid=True, max_qty=100, max_notional=100_000_000,
        collar_abs=100000, ref_px=4500000, max_pos=500
    )

    replay.configure_symbol(sym=0, tcfg=sym0_tcfg, rcfg=sym0_rcfg)
    replay.configure_symbol(sym=1, tcfg=sym1_tcfg, rcfg=sym1_rcfg)
    replay.configure_global(RiskGlobalConfig(max_gross=0xFFFFFFFF, max_orders=0xFFFF, win_shift=5), global_enable=True)

    replay.process_beats(beats)

    expected_frames = [f.frame_bytes.hex().upper() for f in replay.op6_frames]
    return beats, expected_frames


# ------------------------------------------------------------------------------
# Main Cocotb Test Suite (Gate IT-4: 20+ Random Seeds)
# ------------------------------------------------------------------------------

@cocotb.test()
async def test_constrained_random_suite(dut):
    """
    Gate IT-4: Run constrained-random test suite across 20 pseudo-random seeds.
    Verifies valid & malformed ITCH streams, randomized beat pacing,
    and randomized AXI backpressure with zero mismatches against Golden Reference Model.
    """
    dut._log.info("=============================================================================")
    dut._log.info("Starting Gate IT-4: Constrained-Random Cocotb Suite (20 Seeds)")
    dut._log.info("=============================================================================")

    # Start 200 MHz Clock (5.0 ns period)
    clock = Clock(dut.clk, 5.0, unit="ns")
    cocotb.start_soon(clock.start())

    total_seeds = 20
    failed_seeds = []

    for seed_idx in range(1, total_seeds + 1):
        seed = 1000 + seed_idx
        dut._log.info(f"--- Running Seed {seed_idx}/{total_seeds} (Seed value: {seed}) ---")

        # Generate scenario
        beats, expected_frames = generate_random_scenario(seed)
        dut._log.info(f"  Generated {len(beats)} beats; Expected outbound orders: {len(expected_frames)}")

        # Reset DUT
        await reset_dut(dut)

        # Configure Global Registers via AXI-Lite
        await axi_write(dut, 0x800, 0xFFFFFFFF) # max_gross
        await axi_write(dut, 0x808, 0x0000FFFF) # max_orders
        await axi_write(dut, 0x80C, 0x00000005) # win_shift

        # Configure Slot 0 (AAPL)
        await axi_write(dut, 0x408, 0x000000F3) # ctrl: en=1, valid=1, mask=0xF, imb=0
        await axi_write(dut, 0x40C, 1600000)    # buy_limit
        await axi_write(dut, 0x410, 1400000)    # sell_limit
        await axi_write(dut, 0x414, 50000)      # max_spread
        await axi_write(dut, 0x418, 25)         # qty
        await axi_write(dut, 0x41C, 500)        # max_qty
        await axi_write(dut, 0x420, 100000000)  # max_notional_lo
        await axi_write(dut, 0x424, 0)          # max_notional_hi
        await axi_write(dut, 0x428, 100000)     # collar_abs
        await axi_write(dut, 0x42C, 1500000)    # ref_px
        await axi_write(dut, 0x430, 1000)       # max_pos

        # Configure Slot 1 (SPY)
        await axi_write(dut, 0x448, 0x000000F3) # ctrl: en=1, valid=1, mask=0xF, imb=0
        await axi_write(dut, 0x44C, 4600000)    # buy_limit
        await axi_write(dut, 0x450, 4400000)    # sell_limit
        await axi_write(dut, 0x454, 50000)      # max_spread
        await axi_write(dut, 0x458, 10)         # qty
        await axi_write(dut, 0x45C, 100)        # max_qty
        await axi_write(dut, 0x460, 100000000)  # max_notional_lo
        await axi_write(dut, 0x464, 0)          # max_notional_hi
        await axi_write(dut, 0x468, 100000)     # collar_abs
        await axi_write(dut, 0x46C, 4500000)    # ref_px
        await axi_write(dut, 0x470, 500)        # max_pos

        # Enable trading (bit 3: global_enable)
        await axi_write(dut, 0x004, 0x00000008)

        # Start backpressure and monitor coroutines
        stop_event = Event()
        captured_frames = []
        bp_rng = random.Random(seed + 999)

        bp_task = cocotb.start_soon(tx_backpressure_coro(dut, bp_rng, stop_event))
        mon_task = cocotb.start_soon(tx_monitor_coro(dut, captured_frames, stop_event))

        # Drive RX beats with randomized idle gaps (0-3 cycles)
        pacing_rng = random.Random(seed + 555)
        for tdata_bytes, tkeep_int, tlast_bool in beats:
            gap = pacing_rng.randint(0, 3)
            if gap > 0:
                dut.rx_axis_tvalid.value = 0
                await ClockCycles(dut.clk, gap)

            dut.rx_axis_tvalid.value = 1
            dut.rx_axis_tdata.value = int.from_bytes(tdata_bytes, byteorder="little")
            dut.rx_axis_tkeep.value = tkeep_int
            dut.rx_axis_tlast.value = 1 if tlast_bool else 0
            await RisingEdge(dut.clk)

        dut.rx_axis_tvalid.value = 0
        dut.rx_axis_tlast.value = 0

        # Drain pipeline
        await ClockCycles(dut.clk, 300)

        # Stop coroutines
        stop_event.set()
        await RisingEdge(dut.clk)

        # Verification checks
        non_zero_cnts = {}
        for c in range(47):
            val = int(dut.u_regs.live_counters[c].value)
            if val != 0:
                non_zero_cnts[c] = val
        dut._log.info(f"  Diagnostics: global_en={int(dut.u_regs.o_global_enable.value)} non_zero_counters={non_zero_cnts}")
        dut._log.info(f"  Diagnostics: last framer len={int(dut.u_framer.o_blk_len.value)} valid={int(dut.u_framer.o_blk_valid.value)}")
        assert int(dut.fatal_overflow.value) == 0, f"Fatal overflow occurred on seed {seed}!"
        assert int(dut.tx_fault.value) == 0, f"TX fault occurred on seed {seed}!"

        # Compare captured outbound frames with reference model
        mismatches = 0
        if len(captured_frames) != len(expected_frames):
            dut._log.error(f"  Frame count mismatch: ACT={len(captured_frames)} vs EXP={len(expected_frames)}")
            mismatches += 1
        for i, (act, exp) in enumerate(zip(captured_frames, expected_frames)):
            if act != exp:
                dut._log.error(f"  Frame {i} mismatch:\n    ACT: {act}\n    EXP: {exp}")
                mismatches += 1

        if mismatches > 0:
            failed_seeds.append((seed, f"{mismatches} frame mismatches"))
            dut._log.error(f"  [SEED {seed}] FAILED")
        else:
            dut._log.info(f"  [SEED {seed}] PASSED (Captured {len(captured_frames)} orders matching model)")

    dut._log.info("=============================================================================")
    if failed_seeds:
        dut._log.error(f"GATE IT-4 FAILED: {len(failed_seeds)}/{total_seeds} seeds failed!")
        for s, err in failed_seeds:
            dut._log.error(f"  Failed Seed {s}: {err}")
        assert False, f"{len(failed_seeds)} seeds failed in Cocotb constrained-random suite"
    else:
        dut._log.info(f"GATE IT-4 PASSED: All {total_seeds}/{total_seeds} seeds passed with 0 mismatches!")
    dut._log.info("=============================================================================")
