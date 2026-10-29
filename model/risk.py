# =============================================================================
# File        : model/risk.py
# Spec Section: 10.2 (Sequentially Consistent Pre-Trade Risk Engine)
# Description : Python reference model for pre-trade risk checks with
#               priority arbitration and single-cycle state mutation.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict
from model.table import SIDE_BID, SIDE_ASK
from model.trigger import Candidate


RSN_PASS      = 0
RSN_KILL      = 1
RSN_QTY       = 2
RSN_NOTIONAL  = 3
RSN_COLLAR    = 4
RSN_POS_SYM   = 5
RSN_POS_GLOB  = 6
RSN_RATE      = 7
RSN_TX_FAULT  = 8
RSN_UNKNOWN   = 15


@dataclass
class RiskSymbolConfig:
    cfg_valid: bool = False
    max_qty: int = 0           # 16 bits
    max_notional: int = 0      # 48 bits (in 1/10000 USD)
    collar_abs: int = 0        # 32 bits
    ref_px: int = 0            # 32 bits
    max_pos: int = 0           # 32 bits (absolute max net shares)


@dataclass
class RiskGlobalConfig:
    max_gross: int = 0xFFFF_FFFF  # 32 bits
    max_orders: int = 0xFFFF      # 16 bits
    win_shift: int = 5            # 5 bits (window of 32 messages)


@dataclass
class RiskCounters:
    risk_pass: int = 0
    risk_rej_1: int = 0
    risk_rej_2: int = 0
    risk_rej_3: int = 0
    risk_rej_4: int = 0
    risk_rej_5: int = 0
    risk_rej_6: int = 0
    risk_rej_7: int = 0
    risk_rej_8: int = 0
    risk_rej_15: int = 0


@dataclass
class RiskDecision:
    idx: int
    sym: int
    passed: bool
    reason: int
    side: int
    price: int
    qty: int

    def format_op5_line(self) -> str:
        """Format as normative exp_op5.txt line (Section 6.3)."""
        # idx8 sym1 pass1 reason1 side1 price8 qty4
        pass_digit = 1 if self.passed else 0
        return (
            f"{self.idx:08X} "
            f"{self.sym:01X} "
            f"{pass_digit:01X} "
            f"{self.reason:01X} "
            f"{self.side:01X} "
            f"{self.price:08X} "
            f"{self.qty:04X}"
        )


class RiskEngineModel:
    """
    Reference model for S8 (t2t_risk).
    Sequential consistency: each decision sees the state mutated by earlier passes.
    """
    def __init__(self, num_symbols: int = 8):
        self.num_symbols = num_symbols
        self.sym_configs: List[RiskSymbolConfig] = [RiskSymbolConfig() for _ in range(num_symbols)]
        self.global_config = RiskGlobalConfig()
        self.pos: List[int] = [0] * num_symbols        # signed 32-bit net pos
        self.gross: int = 0                            # unsigned 32-bit gross
        self.win_id: int = -1
        self.win_cnt: int = 0
        self.kill: bool = False
        self.tx_fault: bool = False
        self.counters = RiskCounters()

    def reset_state(self):
        self.pos = [0] * self.num_symbols
        self.gross = 0
        self.win_id = -1
        self.win_cnt = 0
        self.kill = False
        self.tx_fault = False
        self.counters = RiskCounters()

    def evaluate(self, cand: Candidate) -> RiskDecision:
        """
        Evaluate candidate order against risk limits in strict priority order.
        """
        sym = cand.sym
        cfg = self.sym_configs[sym]
        gcfg = self.global_config

        # 1. Update sliding message window
        current_win = cand.idx >> gcfg.win_shift
        if current_win != self.win_id:
            self.win_id = current_win
            self.win_cnt = 0

        # Check priority ladder:
        # Priority 1: KILL (1)
        if self.kill:
            self.counters.risk_rej_1 += 1
            return RiskDecision(cand.idx, sym, False, RSN_KILL, cand.side, cand.price, cand.qty)

        # Priority 2: TX_FAULT (8)
        if self.tx_fault:
            self.counters.risk_rej_8 += 1
            return RiskDecision(cand.idx, sym, False, RSN_TX_FAULT, cand.side, cand.price, cand.qty)

        # Priority 3: UNKNOWN (15)
        if not cfg.cfg_valid:
            self.counters.risk_rej_15 += 1
            return RiskDecision(cand.idx, sym, False, RSN_UNKNOWN, cand.side, cand.price, cand.qty)

        # Priority 4: QTY (2)
        if cand.qty == 0 or cand.qty > cfg.max_qty:
            self.counters.risk_rej_2 += 1
            return RiskDecision(cand.idx, sym, False, RSN_QTY, cand.side, cand.price, cand.qty)

        # Priority 5: NOTIONAL (3)
        notional = cand.price * cand.qty
        if notional > cfg.max_notional:
            self.counters.risk_rej_3 += 1
            return RiskDecision(cand.idx, sym, False, RSN_NOTIONAL, cand.side, cand.price, cand.qty)

        # Priority 6: COLLAR (4)
        collar_delta = abs(cand.price - cfg.ref_px)
        if collar_delta > cfg.collar_abs:
            self.counters.risk_rej_4 += 1
            return RiskDecision(cand.idx, sym, False, RSN_COLLAR, cand.side, cand.price, cand.qty)

        # Priority 7: POS_SYM (5)
        delta_pos = cand.qty if cand.side == SIDE_BID else -cand.qty
        new_pos = self.pos[sym] + delta_pos
        if abs(new_pos) > cfg.max_pos:
            self.counters.risk_rej_5 += 1
            return RiskDecision(cand.idx, sym, False, RSN_POS_SYM, cand.side, cand.price, cand.qty)

        # Priority 8: POS_GLOB (6)
        if self.gross + cand.qty > gcfg.max_gross:
            self.counters.risk_rej_6 += 1
            return RiskDecision(cand.idx, sym, False, RSN_POS_GLOB, cand.side, cand.price, cand.qty)

        # Priority 9: RATE (7)
        if self.win_cnt >= gcfg.max_orders:
            self.counters.risk_rej_7 += 1
            return RiskDecision(cand.idx, sym, False, RSN_RATE, cand.side, cand.price, cand.qty)

        # PASS: Update internal risk state
        self.pos[sym] = new_pos
        self.gross = min(0xFFFF_FFFF, self.gross + cand.qty)
        self.win_cnt += 1
        self.counters.risk_pass += 1

        return RiskDecision(cand.idx, sym, True, RSN_PASS, cand.side, cand.price, cand.qty)
