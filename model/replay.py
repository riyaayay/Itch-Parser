# =============================================================================
# File        : model/replay.py
# Spec Section: 6.3, 11, 12.2
# Description : Pipeline replay engine executing the Python Golden Reference
#               Model on ITCH message streams and dumping verification files.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import argparse
import pathlib
import sys
from typing import List, Tuple, Optional, Dict
from model.itch import parse_itch_block, ItchMessage
from model.framer import AxisFramerModel, FramedBlock
from model.table import OrderTableModel, BookOp
from model.book import OrderBookModel, BookUpdate
from model.trigger import TriggerModel, TriggerConfig, Candidate
from model.risk import RiskEngineModel, RiskSymbolConfig, RiskGlobalConfig, RiskDecision
from model.encoder import EncoderModel, OutboundFrame


class PipelineReplay:
    """
    Executes the complete Golden Reference Model on an input byte stream or AXI-Stream beats.
    Generates all normative output streams exp_op1..exp_op6 and exp_counters.
    """
    def __init__(
        self,
        symbols: List[bytes],
        book_n: int = 8,
        table_aw: int = 9,
        table_ways: int = 4
    ):
        self.symbols = [s[:8].ljust(8, b" ") for s in symbols]
        self.framer = AxisFramerModel()
        self.table = OrderTableModel(symbols=symbols, table_aw=table_aw, table_ways=table_ways)
        self.book = OrderBookModel(num_symbols=len(symbols), book_n=book_n)
        self.trigger = TriggerModel(num_symbols=len(symbols))
        self.risk = RiskEngineModel(num_symbols=len(symbols))
        self.encoder = EncoderModel(symbols=symbols)

        # Traced outputs
        self.op1_msgs: List[ItchMessage] = []
        self.op2_ops: List[BookOp] = []
        self.op3_upds: List[BookUpdate] = []
        self.op4_cands: List[Candidate] = []
        self.op5_decs: List[RiskDecision] = []
        self.op6_frames: List[OutboundFrame] = []

    def configure_symbol(
        self,
        sym: int,
        tcfg: TriggerConfig,
        rcfg: RiskSymbolConfig
    ):
        self.trigger.configs[sym] = tcfg
        self.risk.sym_configs[sym] = rcfg

    def configure_global(
        self,
        rcfg_global: RiskGlobalConfig,
        global_enable: bool = True
    ):
        self.risk.global_config = rcfg_global
        self.trigger.global_enable = global_enable

    def process_beats(
        self,
        beats: List[Tuple[bytes, int, bool]]
    ):
        """Feed AXI-Stream beats through the entire pipeline."""
        for blk in self.framer.process_frame_beats(beats):
            msg = parse_itch_block(blk.idx, blk.stored_len, blk.payload[:blk.stored_len])
            self.op1_msgs.append(msg)

            ops = self.table.process_message(msg)
            for op in ops:
                self.op2_ops.append(op)
                upd = self.book.apply_op(op)
                self.op3_upds.append(upd)

                cand = self.trigger.evaluate(upd)
                if cand is not None:
                    self.op4_cands.append(cand)
                    dec = self.risk.evaluate(cand)
                    self.op5_decs.append(dec)

                    frame = self.encoder.encode(dec, cand.rule)
                    if frame is not None:
                        self.op6_frames.append(frame)

    def write_expected_outputs(self, out_dir: pathlib.Path):
        """Write all 6 exp_op files and exp_counters.txt to out_dir."""
        out_dir.mkdir(parents=True, exist_ok=True)

        with open(out_dir / "exp_op1.txt", "w", encoding="ascii") as f:
            for msg in self.op1_msgs:
                f.write(msg.format_op1_line() + "\n")

        with open(out_dir / "exp_op2.txt", "w", encoding="ascii") as f:
            for op in self.op2_ops:
                f.write(op.format_op2_line() + "\n")

        with open(out_dir / "exp_op3.txt", "w", encoding="ascii") as f:
            for upd in self.op3_upds:
                f.write(upd.format_op3_line() + "\n")

        with open(out_dir / "exp_op4.txt", "w", encoding="ascii") as f:
            for cand in self.op4_cands:
                f.write(cand.format_op4_line() + "\n")

        with open(out_dir / "exp_op5.txt", "w", encoding="ascii") as f:
            for dec in self.op5_decs:
                f.write(dec.format_op5_line() + "\n")

        with open(out_dir / "exp_op6.txt", "w", encoding="ascii") as f:
            for frame in self.op6_frames:
                f.write(frame.format_op6_line() + "\n")

        # Counters file (Section 11.3)
        # 47 normative counters indexed 0..46
        counters_map = self._collect_counters()
        with open(out_dir / "exp_counters.txt", "w", encoding="ascii") as f:
            for cid in sorted(counters_map.keys()):
                f.write(f"{cid} {counters_map[cid]}\n")

    def _collect_counters(self) -> Dict[int, int]:
        c = {}
        fc = self.framer.counters
        tc = self.table.counters
        bc = self.book.counters
        rc = self.risk.counters
        ec = self.encoder

        # Counters per Section 11.3 / rtl/t2t_defs.vh:
        c[0]  = fc.rx_beats
        c[1]  = fc.rx_frames
        c[2]  = fc.ingest_overflow
        c[3]  = fc.rx_dropped_init
        c[4]  = fc.frame_err
        c[5]  = fc.keep_err
        c[6]  = fc.blocks_total

        # Message type counts from S3 extract
        cnt_a = sum(1 for m in self.op1_msgs if m.msg_type == 0x41 and m.handled)
        cnt_f = sum(1 for m in self.op1_msgs if m.msg_type == 0x46 and m.handled)
        cnt_e = sum(1 for m in self.op1_msgs if m.msg_type == 0x45 and m.handled)
        cnt_c = sum(1 for m in self.op1_msgs if m.msg_type == 0x43 and m.handled)
        cnt_x = sum(1 for m in self.op1_msgs if m.msg_type == 0x58 and m.handled)
        cnt_d = sum(1 for m in self.op1_msgs if m.msg_type == 0x44 and m.handled)
        cnt_u = sum(1 for m in self.op1_msgs if m.msg_type == 0x55 and m.handled)
        cnt_badlen = sum(1 for m in self.op1_msgs if m.bad_len)
        cnt_badside = sum(1 for m in self.op1_msgs if m.bad_side)
        cnt_other = sum(1 for m in self.op1_msgs if not m.handled and not m.zero_len and not m.bad_len)

        c[7]  = cnt_a
        c[8]  = cnt_f
        c[9]  = cnt_e
        c[10] = cnt_c
        c[11] = cnt_x
        c[12] = cnt_d
        c[13] = cnt_u
        c[14] = cnt_other
        c[15] = fc.n_zero_len
        c[16] = cnt_badlen
        c[17] = cnt_badside

        c[18] = tc.sym_hit
        c[19] = tc.sym_miss
        c[20] = tc.tbl_ins
        c[21] = tc.tbl_ref_miss
        c[22] = tc.tbl_dup_ref
        c[23] = tc.tbl_set_full
        c[24] = tc.tbl_qty_underflow
        c[25] = tc.tbl_same_set_stalls

        c[26] = bc.book_ops
        c[27] = bc.book_same_key_bubbles
        c[28] = bc.book_corrupt_events
        c[29] = bc.book_hidden_adds
        c[30] = bc.book_evictions

        c[31] = len(self.op4_cands)
        c[32] = rc.risk_pass
        c[33] = rc.risk_rej_1
        c[34] = rc.risk_rej_2
        c[35] = rc.risk_rej_3
        c[36] = rc.risk_rej_4
        c[37] = rc.risk_rej_5
        c[38] = rc.risk_rej_6
        c[39] = rc.risk_rej_7
        c[40] = rc.risk_rej_8
        c[41] = rc.risk_rej_15

        c[42] = ec.tx_frames_count
        c[43] = ec.tx_overflow_count
        c[44] = bc.upd_total
        c[45] = bc.upd_with_stale
        c[46] = 0 # fatal_overflow
        return c
