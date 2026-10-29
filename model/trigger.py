# =============================================================================
# File        : model/trigger.py
# Spec Section: 10.1 (Edge-Triggered Trading Rules)
# Description : Python reference model for 4 edge-triggered quantitative
#               trading rules with spread gating and edge re-arming.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict
from model.table import SIDE_BID, SIDE_ASK
from model.book import BookUpdate


RULE_CROSS_BUY  = 0
RULE_CROSS_SELL = 1
RULE_IMB_BUY    = 2
RULE_IMB_SELL   = 3


@dataclass
class TriggerConfig:
    en: bool = False
    rule_mask: int = 0         # 4 bits [3:0]
    imb_shift: int = 0         # 3 bits [2:0]
    buy_limit: int = 0         # 32 bits
    sell_limit: int = 0        # 32 bits
    max_spread: int = 0        # 32 bits
    qty: int = 0               # 16 bits


@dataclass
class Candidate:
    idx: int       # upd_idx
    sym: int       # symbol index
    side: int      # 0=buy (bid), 1=sell (ask)
    rule: int      # 0..3
    price: int     # 32-bit execution price
    qty: int       # 16-bit candidate quantity

    def format_op4_line(self) -> str:
        """Format as normative exp_op4.txt line (Section 6.3)."""
        # idx8 sym1 side1 rule1 price8 qty4
        return (
            f"{self.idx:08X} "
            f"{self.sym:01X} "
            f"{self.side:01X} "
            f"{self.rule:01X} "
            f"{self.price:08X} "
            f"{self.qty:04X}"
        )


class TriggerModel:
    """
    Reference model for S7 (t2t_trigger).
    """
    def __init__(self, num_symbols: int = 8):
        self.num_symbols = num_symbols
        self.configs: List[TriggerConfig] = [TriggerConfig() for _ in range(num_symbols)]
        # armed[sym][rule]: True if condition was asserted in previous evaluation
        self.armed: List[List[bool]] = [[False] * 4 for _ in range(num_symbols)]
        self.global_enable: bool = True
        self.session_invalid: bool = False
        self.cand_count: int = 0

    def reset(self):
        self.armed = [[False] * 4 for _ in range(self.num_symbols)]
        self.global_enable = True
        self.session_invalid = False
        self.cand_count = 0

    def evaluate(self, upd: BookUpdate) -> Optional[Candidate]:
        """
        Evaluate trading rules on a BookUpdate.
        Only acts on upd.last == 1.
        """
        if upd.last != 1:
            return None

        sym = upd.sym
        cfg = self.configs[sym]

        # 1. Precondition P:
        # global_enable and en and tradable(sym) and (ask_px - bid_px <= max_spread)
        # tradable(sym): both sides ok, not crossed, not corrupt, not session_invalid
        sides_ok = (upd.bid_lv > 0) and (upd.ask_lv > 0)
        tradable = (
            sides_ok and
            (not upd.crossed) and
            (not upd.corrupt) and
            (not self.session_invalid)
        )

        spread = (upd.ask_px - upd.bid_px) if (upd.ask_px >= upd.bid_px) else 0xFFFFFFFF
        p_spread = spread <= cfg.max_spread

        P = self.global_enable and cfg.en and tradable and p_spread

        # 2. Rule conditions
        # Rule 0: CROSS_BUY: ask_px <= buy_limit -> buy at ask_px
        cond_0 = upd.ask_px <= cfg.buy_limit
        # Rule 1: CROSS_SELL: bid_px >= sell_limit -> sell at bid_px
        cond_1 = upd.bid_px >= cfg.sell_limit
        # Rule 2: IMB_BUY: bid_qty >= (ask_qty << imb_shift) -> buy at ask_px
        shifted_ask = upd.ask_qty << cfg.imb_shift
        cond_2 = upd.bid_qty >= shifted_ask
        # Rule 3: IMB_SELL: ask_qty >= (bid_qty << imb_shift) -> sell at bid_px
        shifted_bid = upd.bid_qty << cfg.imb_shift
        cond_3 = upd.ask_qty >= shifted_bid

        conds = [cond_0, cond_1, cond_2, cond_3]

        # 3. Edge-trigger firing: fire_i = P and mask[i] and cond_i and not armed[i]
        fired_rules = []
        for i in range(4):
            mask_bit = bool(cfg.rule_mask & (1 << i))
            if P and mask_bit and conds[i] and not self.armed[sym][i]:
                fired_rules.append(i)

        # 4. State update: armed[i] = P and cond_i (re-arms once cond or P drops)
        for i in range(4):
            self.armed[sym][i] = P and conds[i]

        if not fired_rules:
            return None

        # Lowest rule ID wins
        winning_rule = min(fired_rules)
        self.cand_count += 1

        is_buy = winning_rule in (RULE_CROSS_BUY, RULE_IMB_BUY)
        cand_side = SIDE_BID if is_buy else SIDE_ASK
        cand_price = upd.ask_px if is_buy else upd.bid_px

        return Candidate(
            idx=upd.idx,
            sym=sym,
            side=cand_side,
            rule=winning_rule,
            price=cand_price,
            qty=cfg.qty
        )
