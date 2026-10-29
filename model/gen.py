# =============================================================================
# File        : model/gen.py
# Spec Section: 6.3 (Vector and expected-output files), 12.2 (MDL-3)
# Description : Master test stimulus and golden response vector generator.
#               Supports --suite legacy, --suite directed, and --suite soak.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import argparse
import pathlib
import struct
import random
from typing import List, Tuple
from model.itch import encode_itch_message
from model.framer import AxisFramerModel
from model.replay import PipelineReplay
from model.trigger import TriggerConfig
from model.risk import RiskSymbolConfig, RiskGlobalConfig


DEFAULT_SYMBOLS = [
    b"AAPL    ",
    b"SPY     ",
    b"MSFT    ",
    b"QQQ     ",
    b"NVDA    ",
    b"TSLA    ",
    b"AMZN    ",
    b"META    ",
]

# Upstream legacy 20 prices and shares (Finding F10 / MDL-3)
LEGACY_PRICES = [
    5948600, 5950000, 5950000, 5951100, 5951100, 5950200, 5950599, 5950400,
    5953099, 5952400, 5952900, 5953099, 5953200, 5953300, 5953099, 5953400,
    5953300, 5953099, 5953500, 5953600
]
LEGACY_SHARES = [
    5, 31, 108, 7, 7, 17, 100, 75,
    8, 6, 5, 1, 2, 20, 12, 3,
    5, 1, 100, 100
]


def write_stim_hex(beats: List[Tuple[bytes, int, bool]], out_file: pathlib.Path):
    """
    Format as normative stim.hex (Section 6.3):
    <gap> <tlast> <tkeep16> <tdata128>
    gap: decimal idle cycles before beat (0)
    tlast: one hex digit
    tkeep16: 16 hex digits
    tdata128: 128 hex digits, byte 63 leftmost
    """
    with open(out_file, "w", encoding="ascii") as f:
        for tdata, tkeep, tlast in beats:
            gap = 0
            tlast_str = "1" if tlast else "0"
            tkeep_str = f"{tkeep:016X}"
            # Byte 63 leftmost -> reverse bytes for MSB-first hex representation
            tdata_rev = tdata[::-1]
            tdata_str = tdata_rev.hex().upper()
            f.write(f"{gap} {tlast_str} {tkeep_str} {tdata_str}\n")


def write_ctrl_config(
    out_dir: pathlib.Path,
    sym_configs: List[Tuple[int, TriggerConfig, RiskSymbolConfig]],
    gcfg: RiskGlobalConfig = None
):
    with open(out_dir / "ctrl.txt", "w", encoding="ascii") as f:
        # Global risk settings
        if gcfg is not None:
            f.write(f"0 W 800 {gcfg.max_gross:08X}\n")
            f.write(f"0 W 808 {gcfg.max_orders:08X}\n")
            f.write(f"0 W 80C {gcfg.win_shift:08X}\n")
        else:
            f.write("0 W 800 FFFFFFFF\n")
            f.write("0 W 808 0000FFFF\n")
            f.write("0 W 80C 00000005\n")

        # Per-symbol configs
        for sym, tcfg, rcfg in sym_configs:
            base = 0x400 + 0x40 * sym
            ctrl_val = (tcfg.en & 1) | ((rcfg.cfg_valid & 1) << 1) | ((tcfg.rule_mask & 0xF) << 4) | ((tcfg.imb_shift & 0x7) << 8)
            f.write(f"0 W {base+0x08:03X} {ctrl_val:08X}\n")
            f.write(f"0 W {base+0x0C:03X} {tcfg.buy_limit:08X}\n")
            f.write(f"0 W {base+0x10:03X} {tcfg.sell_limit:08X}\n")
            f.write(f"0 W {base+0x14:03X} {tcfg.max_spread:08X}\n")
            f.write(f"0 W {base+0x18:03X} {tcfg.qty:08X}\n")
            f.write(f"0 W {base+0x1C:03X} {rcfg.max_qty:08X}\n")
            f.write(f"0 W {base+0x20:03X} {rcfg.max_notional & 0xFFFFFFFF:08X}\n")
            f.write(f"0 W {base+0x24:03X} {(rcfg.max_notional >> 32) & 0xFFFF:08X}\n")
            f.write(f"0 W {base+0x28:03X} {rcfg.collar_abs:08X}\n")
            f.write(f"0 W {base+0x2C:03X} {rcfg.ref_px:08X}\n")
            f.write(f"0 W {base+0x30:03X} {rcfg.max_pos:08X}\n")

        # Enable global_enable (bit 3) and clear kill_switch (bit 1 = 0)
        f.write("0 W 004 00000008\n")


def gen_legacy_suite(out_dir: pathlib.Path):
    """
    MDL-3 / IT-2: Regenerate upstream sim_data.hex with valid 38-byte framing
    preserving the exact 20 prices and shares.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    stream = bytearray()

    # Generate 20 Add Order (0x41) blocks with valid 38-byte framing
    # 2B prefix (0x0024 = 36) + 36B payload = 38B per block
    raw_hex_lines = []
    for i in range(20):
        block = encode_itch_message(
            msg_type=0x41,
            locate=1,
            tracking=i + 1,
            timestamp=1000000000 + i * 1000,
            ref=10000 + i,
            side=ord('B'),
            shares=LEGACY_SHARES[i],
            stock=b"AAPL    ",
            price=LEGACY_PRICES[i]
        )
        assert len(block) == 38, f"Block length {len(block)} != 38"
        stream.extend(block)
        for b in block:
            raw_hex_lines.append(f"{b:02x}\n")

    # Save byte-by-byte hex for reference
    with open(out_dir / "sim_data_38b.hex", "w", encoding="ascii") as f:
        f.writelines(raw_hex_lines)

    beats = AxisFramerModel.pack_stream_into_beats(bytes(stream))
    write_stim_hex(beats, out_dir / "stim.hex")

    sym0_tcfg = TriggerConfig(
        en=True, rule_mask=0x0F, imb_shift=0,
        buy_limit=6000000, sell_limit=5000000, max_spread=100000, qty=10
    )
    sym0_rcfg = RiskSymbolConfig(
        cfg_valid=True, max_qty=500, max_notional=100_000_000,
        collar_abs=200000, ref_px=5950000, max_pos=1000
    )

    write_ctrl_config(out_dir, [(0, sym0_tcfg, sym0_rcfg)])

    with open(out_dir / "txready.txt", "w", encoding="ascii") as f:
        f.write("1\n")

    # Run replay to produce exp_op1..exp_op6 and exp_counters
    replay = PipelineReplay(symbols=DEFAULT_SYMBOLS)
    replay.configure_symbol(sym=0, tcfg=sym0_tcfg, rcfg=sym0_rcfg)
    replay.process_beats(beats)
    replay.write_expected_outputs(out_dir)
    print(f"MDL-3: Successfully generated legacy suite in {out_dir} (20 blocks, 760 bytes, {len(beats)} beats)")


def gen_directed_suite(out_dir: pathlib.Path):
    """
    Generates comprehensive directed scenario exercising all 7 handled ITCH types,
    unhandled types, zero length, bad length, book mutations, triggers, and risk limits.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    stream = bytearray()

    # 1. Add orders on AAPL (sym 0) - bids and asks
    # AAPL Best Bid: 1500000 (100 sh), 1490000 (200 sh)
    # AAPL Best Ask: 1510000 (100 sh), 1520000 (300 sh)
    stream.extend(encode_itch_message(0x41, locate=1, ref=101, side=ord('B'), shares=100, stock=b"AAPL    ", price=1500000))
    stream.extend(encode_itch_message(0x41, locate=1, ref=102, side=ord('B'), shares=200, stock=b"AAPL    ", price=1490000))
    stream.extend(encode_itch_message(0x41, locate=1, ref=103, side=ord('S'), shares=100, stock=b"AAPL    ", price=1510000))
    stream.extend(encode_itch_message(0x41, locate=1, ref=104, side=ord('S'), shares=300, stock=b"AAPL    ", price=1520000))

    # 2. Add Order with MPID ('F') on SPY (sym 1)
    stream.extend(encode_itch_message(0x46, locate=2, ref=201, side=ord('B'), shares=50, stock=b"SPY     ", price=4500000, attribution=b"GSCO"))
    stream.extend(encode_itch_message(0x46, locate=2, ref=202, side=ord('S'), shares=50, stock=b"SPY     ", price=4510000, attribution=b"MSCO"))

    # 3. Add order on untracked stock (GOOG) -> sym miss
    stream.extend(encode_itch_message(0x41, locate=99, ref=999, side=ord('B'), shares=10, stock=b"GOOG    ", price=2800000))

    # 4. Partial execute on ref 102 (reduce 50 shares)
    stream.extend(encode_itch_message(0x45, locate=1, ref=102, shares=50))

    # 5. Execute with price on ref 101 (execute 100 shares, full delete)
    stream.extend(encode_itch_message(0x43, locate=1, ref=101, shares=100, price=1500000))

    # 6. Cancel ('X') on ref 104 (cancel 100 shares, partial)
    stream.extend(encode_itch_message(0x58, locate=1, ref=104, shares=100))

    # 7. Delete ('D') on ref 103 (full delete)
    stream.extend(encode_itch_message(0x44, locate=1, ref=103))

    # 8. Order Replace ('U') on ref 104 -> new ref 105, new price 1515000, new shares 150
    stream.extend(encode_itch_message(0x55, locate=1, ref=104, newref=105, shares=150, price=1515000))

    # 9. Insert a bid at 1514000 to narrow spread and fire CROSS_BUY trigger!
    stream.extend(encode_itch_message(0x41, locate=1, ref=106, side=ord('B'), shares=100, stock=b"AAPL    ", price=1514000))

    # 10. Unhandled type 'R' (Stock Directory, len 39) -> other skipped
    r_payload = bytes([ord('R')]) + (b"\x00" * 38)
    stream.extend(struct.pack(">H", 39) + r_payload)

    # 11. Zero length block (prefix 0x0000)
    stream.extend(struct.pack(">H", 0))

    # 12. Trigger candidate that trips risk collar
    # Bid at 1800000 (way above ref_px 1500000 with collar 100000) -> COLLAR reject
    stream.extend(encode_itch_message(0x41, locate=1, ref=107, side=ord('B'), shares=10, stock=b"AAPL    ", price=1800000))

    beats = AxisFramerModel.pack_stream_into_beats(bytes(stream))
    write_stim_hex(beats, out_dir / "stim.hex")

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

    write_ctrl_config(out_dir, [(0, sym0_tcfg, sym0_rcfg), (1, sym1_tcfg, sym1_rcfg)])

    with open(out_dir / "txready.txt", "w", encoding="ascii") as f:
        f.write("1\n")

    replay = PipelineReplay(symbols=DEFAULT_SYMBOLS)
    replay.configure_symbol(sym=0, tcfg=sym0_tcfg, rcfg=sym0_rcfg)
    replay.configure_symbol(sym=1, tcfg=sym1_tcfg, rcfg=sym1_rcfg)
    replay.process_beats(beats)
    replay.write_expected_outputs(out_dir)
    print(f"Directed: Successfully generated directed suite in {out_dir} ({len(stream)} bytes, {len(beats)} beats)")


def gen_soak_suite(out_dir: pathlib.Path, num_msgs: int = 1000):
    """
    Generates synthetic high-volume soak vector across all 8 symbols.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    random.seed(42)
    stream = bytearray()

    live_refs: List[Tuple[int, int, bytes, int, int]] = [] # (ref, sym, stock, side, price)
    next_ref = 10000

    base_prices = [1500000, 4500000, 3000000, 3800000, 4800000, 2200000, 1300000, 2800000]

    for m_idx in range(num_msgs):
        sym = random.randint(0, 7)
        stock = DEFAULT_SYMBOLS[sym]
        op_type = random.choices(["A", "E", "X", "D"], weights=[0.6, 0.15, 0.15, 0.1])[0]

        if op_type == "A" or not live_refs:
            ref = next_ref
            next_ref += 1
            side = random.choice([ord('B'), ord('S')])
            delta = random.randint(-50, 50) * 100
            price = max(10000, base_prices[sym] + delta)
            shares = random.randint(1, 10) * 10
            msg_bytes = encode_itch_message(
                0x41, locate=sym+1, ref=ref, side=side, shares=shares, stock=stock, price=price
            )
            live_refs.append((ref, sym, stock, side, price))
            stream.extend(msg_bytes)
        elif op_type in ("E", "X"):
            chosen = random.choice(live_refs)
            ref = chosen[0]
            shares = random.randint(1, 5) * 10
            m_code = 0x45 if op_type == "E" else 0x58
            msg_bytes = encode_itch_message(m_code, locate=chosen[1]+1, ref=ref, shares=shares)
            stream.extend(msg_bytes)
        elif op_type == "D":
            idx = random.randrange(len(live_refs))
            chosen = live_refs.pop(idx)
            ref = chosen[0]
            msg_bytes = encode_itch_message(0x44, locate=chosen[1]+1, ref=ref)
            stream.extend(msg_bytes)

    beats = AxisFramerModel.pack_stream_into_beats(bytes(stream))
    write_stim_hex(beats, out_dir / "stim.hex")

    with open(out_dir / "ctrl.txt", "w", encoding="ascii") as f:
        f.write("# Soak scenario ctrl config\n")

    with open(out_dir / "txready.txt", "w", encoding="ascii") as f:
        f.write("1\n")

    replay = PipelineReplay(symbols=DEFAULT_SYMBOLS)
    for s in range(8):
        replay.configure_symbol(
            sym=s,
            tcfg=TriggerConfig(en=True, rule_mask=0x0F, imb_shift=0, buy_limit=base_prices[s] + 50000, sell_limit=base_prices[s] - 50000, max_spread=200000, qty=10),
            rcfg=RiskSymbolConfig(cfg_valid=True, max_qty=500, max_notional=100_000_000, collar_abs=500000, ref_px=base_prices[s], max_pos=5000)
        )
    replay.process_beats(beats)
    replay.write_expected_outputs(out_dir)
    print(f"Soak: Successfully generated soak suite in {out_dir} ({num_msgs} msgs, {len(beats)} beats)")


def main():
    parser = argparse.ArgumentParser(description="tick2trade-fpga Vector Generator (gen.py)")
    parser.add_argument("--suite", choices=["legacy", "directed", "soak"], required=True)
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--count", type=int, default=1000, help="Message count for soak suite")
    args = parser.parse_args()

    if args.suite == "legacy":
        gen_legacy_suite(args.out_dir)
    elif args.suite == "directed":
        gen_directed_suite(args.out_dir)
    elif args.suite == "soak":
        gen_soak_suite(args.out_dir, num_msgs=args.count)


if __name__ == "__main__":
    main()

