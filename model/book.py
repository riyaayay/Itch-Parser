# =============================================================================
# File        : model/book.py
# Spec Section: 9.1, 9.2, 9.3 (Top-8 Order Book Engine), 12.2 (MDL-2, BK-W)
# Description : Python reference model for Top-8 L2 Order Book with hidden
#               order depth tracking and mathematical invariant enforcement.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict
from model.table import BookOp, OP_ADD, OP_REDUCE, OP_CORRUPT, SIDE_BID, SIDE_ASK


BOOK_N_DEFAULT = 8


@dataclass
class Level:
    px: int = 0
    qty: int = 0
    cnt: int = 0

    def copy(self) -> Level:
        return Level(px=self.px, qty=self.qty, cnt=self.cnt)


@dataclass
class BookCounters:
    book_ops: int = 0
    book_same_key_bubbles: int = 0
    book_corrupt_events: int = 0
    book_hidden_adds: int = 0
    book_evictions: int = 0
    upd_total: int = 0
    upd_with_stale: int = 0


@dataclass
class BookSide:
    side: int  # 0 = BID, 1 = ASK
    book_n: int = BOOK_N_DEFAULT
    levels: List[Level] = field(default_factory=list)
    hidden: int = 0

    def __post_init__(self):
        if not self.levels:
            self.levels = []

    @property
    def lv(self) -> int:
        return len(self.levels)

    @property
    def ok(self) -> bool:
        return self.lv != 0

    @property
    def stale(self) -> bool:
        return self.lv == 0 and self.hidden != 0

    @property
    def best_price(self) -> int:
        return self.levels[0].px if self.lv > 0 else 0

    @property
    def best_qty(self) -> int:
        return self.levels[0].qty if self.lv > 0 else 0

    @property
    def worst_price(self) -> int:
        return self.levels[-1].px if self.lv > 0 else 0

    def is_better(self, p1: int, p2: int) -> bool:
        """True if p1 is a better price than p2."""
        if self.side == SIDE_BID:
            return p1 > p2
        else:
            return p1 < p2

    def is_worse(self, p1: int, p2: int) -> bool:
        """True if p1 is a worse price than p2."""
        if self.side == SIDE_BID:
            return p1 < p2
        else:
            return p1 > p2

    def check_invariants(self) -> None:
        """Section 9.1 Normative Invariants."""
        # 1. Monotonicity & non-zero levels
        for i in range(len(self.levels)):
            lvl = self.levels[i]
            assert lvl.qty > 0, f"Invariant violation: level {i} has qty <= 0 ({lvl.qty})"
            assert lvl.cnt > 0, f"Invariant violation: level {i} has cnt <= 0 ({lvl.cnt})"
            if i > 0:
                prev = self.levels[i - 1]
                if self.side == SIDE_BID:
                    assert prev.px > lvl.px, f"Bid levels not strictly descending: {prev.px} <= {lvl.px}"
                else:
                    assert prev.px < lvl.px, f"Ask levels not strictly ascending: {prev.px} >= {lvl.px}"
        # 2. Capacity
        assert len(self.levels) <= self.book_n, f"Levels {len(self.levels)} exceeds {self.book_n}"
        assert self.hidden >= 0, f"Hidden count negative: {self.hidden}"


@dataclass
class BookUpdate:
    idx: int
    sym: int
    last: int
    bid_px: int
    bid_qty: int
    ask_px: int
    ask_qty: int
    bid_lv: int
    ask_lv: int
    bid_hidden: int
    ask_hidden: int
    bid_stale: bool
    ask_stale: bool
    corrupt: bool
    crossed: bool
    seq: int

    @property
    def flags_int(self) -> int:
        # flags: bit0 bid_stale, bit1 ask_stale, bit2 corrupt, bit3 crossed
        flg = 0
        if self.bid_stale:
            flg |= (1 << 0)
        if self.ask_stale:
            flg |= (1 << 1)
        if self.corrupt:
            flg |= (1 << 2)
        if self.crossed:
            flg |= (1 << 3)
        return flg

    def format_op3_line(self) -> str:
        """Format as normative exp_op3.txt line (Section 6.3)."""
        # idx8 sym1 last1 bidpx8 bidqty8 askpx8 askqty8 bidlv1 asklv1 bidhid5 askhid5 flags2 seq8
        return (
            f"{self.idx:08X} "
            f"{self.sym:01X} "
            f"{self.last:01X} "
            f"{self.bid_px:08X} "
            f"{self.bid_qty:08X} "
            f"{self.ask_px:08X} "
            f"{self.ask_qty:08X} "
            f"{self.bid_lv:01X} "
            f"{self.ask_lv:01X} "
            f"{self.bid_hidden:05X} "
            f"{self.ask_hidden:05X} "
            f"{self.flags_int:02X} "
            f"{self.seq:08X}"
        )


class OrderBookModel:
    """
    Reference model for S6 (t2t_book).
    Tracks Top-N (default 8) levels per side for N_SYMBOLS (default 8) symbols.
    """
    def __init__(self, num_symbols: int = 8, book_n: int = BOOK_N_DEFAULT):
        self.num_symbols = num_symbols
        self.book_n = book_n
        self.bids: List[BookSide] = [BookSide(side=SIDE_BID, book_n=book_n) for _ in range(num_symbols)]
        self.asks: List[BookSide] = [BookSide(side=SIDE_ASK, book_n=book_n) for _ in range(num_symbols)]
        self.corrupt: List[bool] = [False] * num_symbols
        self.seq: List[int] = [0] * num_symbols
        self.counters = BookCounters()
        self.session_invalid = False

    def reset(self):
        self.bids = [BookSide(side=SIDE_BID, book_n=self.book_n) for _ in range(self.num_symbols)]
        self.asks = [BookSide(side=SIDE_ASK, book_n=self.book_n) for _ in range(self.num_symbols)]
        self.corrupt = [False] * self.num_symbols
        self.seq = [0] * self.num_symbols
        self.counters = BookCounters()
        self.session_invalid = False

    def is_tradable(self, sym: int) -> bool:
        """Section 9.1: tradable(sym)."""
        bid = self.bids[sym]
        ask = self.asks[sym]
        crossed = bid.ok and ask.ok and (bid.best_price >= ask.best_price)
        return (
            bid.ok and
            ask.ok and
            not crossed and
            not self.corrupt[sym] and
            not self.session_invalid
        )

    def apply_op(self, op: BookOp) -> BookUpdate:
        """
        Apply an operation from the OP bus (S5 OrdTable).
        Updates state and emits a BookUpdate (UPD) record.
        """
        self.counters.book_ops += 1
        sym = op.sym
        ladder = self.bids[sym] if op.side == SIDE_BID else self.asks[sym]
        prev_corrupt = self.corrupt[sym]

        if op.code == OP_CORRUPT:
            self.corrupt[sym] = True
            if not prev_corrupt:
                self.counters.book_corrupt_events += 1

        elif op.code == OP_ADD:
            p = op.price
            q = op.qty
            match_idx = None
            for i, lvl in enumerate(ladder.levels):
                if lvl.px == p:
                    match_idx = i
                    break

            if match_idx is not None:
                # 1. Existing level
                ladder.levels[match_idx].qty += q
                ladder.levels[match_idx].cnt += 1
                if ladder.levels[match_idx].cnt >= 65536:
                    self.corrupt[sym] = True
                    if not prev_corrupt:
                        self.counters.book_corrupt_events += 1
            elif ladder.hidden == 0 and ladder.lv < self.book_n:
                # 2. Free level available and no hidden orders
                new_lvl = Level(px=p, qty=q, cnt=1)
                insert_pos = 0
                while insert_pos < len(ladder.levels) and ladder.is_better(ladder.levels[insert_pos].px, p):
                    insert_pos += 1
                ladder.levels.insert(insert_pos, new_lvl)
            elif ladder.lv > 0 and ladder.is_better(p, ladder.worst_price):
                # 3. Better than worst level
                new_lvl = Level(px=p, qty=q, cnt=1)
                if ladder.lv == self.book_n:
                    # Evict worst level into hidden
                    worst = ladder.levels.pop()
                    ladder.hidden += worst.cnt
                    self.counters.book_evictions += 1
                insert_pos = 0
                while insert_pos < len(ladder.levels) and ladder.is_better(ladder.levels[insert_pos].px, p):
                    insert_pos += 1
                ladder.levels.insert(insert_pos, new_lvl)
            else:
                # 4. Worse than worst level -> hidden
                ladder.hidden += 1
                self.counters.book_hidden_adds += 1

        elif op.code == OP_REDUCE:
            p = op.price
            d = op.qty
            remove = (op.remove == 1)

            match_idx = None
            for i, lvl in enumerate(ladder.levels):
                if lvl.px == p:
                    match_idx = i
                    break

            if match_idx is not None:
                lvl = ladder.levels[match_idx]
                if lvl.qty < d:
                    self.corrupt[sym] = True
                    if not prev_corrupt:
                        self.counters.book_corrupt_events += 1
                else:
                    lvl.qty -= d
                    if remove:
                        if lvl.cnt == 0:
                            self.corrupt[sym] = True
                            if not prev_corrupt:
                                self.counters.book_corrupt_events += 1
                        else:
                            lvl.cnt -= 1

                    if (lvl.qty == 0) ^ (lvl.cnt == 0):
                        self.corrupt[sym] = True
                        if not prev_corrupt:
                            self.counters.book_corrupt_events += 1
                    elif lvl.qty == 0 and lvl.cnt == 0:
                        ladder.levels.pop(match_idx)
            elif ladder.hidden > 0 and (ladder.lv == 0 or ladder.is_worse(p, ladder.worst_price)):
                if remove:
                    ladder.hidden -= 1
            else:
                # Order not found in book -> corrupt
                self.corrupt[sym] = True
                if not prev_corrupt:
                    self.counters.book_corrupt_events += 1

        # Check invariants
        ladder.check_invariants()

        # Update per-symbol sequence counter
        current_seq = self.seq[sym]
        self.seq[sym] = (current_seq + 1) & 0xFFFF_FFFF

        bid = self.bids[sym]
        ask = self.asks[sym]
        crossed = bid.ok and ask.ok and (bid.best_price >= ask.best_price)

        self.counters.upd_total += 1
        if bid.stale or ask.stale:
            self.counters.upd_with_stale += 1

        return BookUpdate(
            idx=op.idx,
            sym=sym,
            last=op.last,
            bid_px=bid.best_price,
            bid_qty=bid.best_qty,
            ask_px=ask.best_price,
            ask_qty=ask.best_qty,
            bid_lv=bid.lv,
            ask_lv=ask.lv,
            bid_hidden=bid.hidden,
            ask_hidden=ask.hidden,
            bid_stale=bid.stale,
            ask_stale=ask.stale,
            corrupt=self.corrupt[sym],
            crossed=crossed,
            seq=current_seq
        )


def test_bkw() -> bool:
    """
    Verification Gate MDL-2 / Section 9.3 (Test BK-W):
    Reproduce the exact worked example for N=2 on the bid side.
    """
    book = OrderBookModel(num_symbols=1, book_n=2)
    sym = 0
    side = SIDE_BID

    # Step 1: ADD 100 q10 -> Levels: 100:10, lv=1, hidden=0, ok
    upd1 = book.apply_op(BookOp(idx=1, code=OP_ADD, sym=sym, side=side, remove=0, last=1, price=100, qty=10))
    assert upd1.bid_lv == 1 and upd1.bid_px == 100 and upd1.bid_qty == 10 and upd1.bid_hidden == 0 and not upd1.bid_stale

    # Step 2: ADD 99 q5 -> Levels: 100:10, 99:5, lv=2, hidden=0, ok
    upd2 = book.apply_op(BookOp(idx=2, code=OP_ADD, sym=sym, side=side, remove=0, last=1, price=99, qty=5))
    assert upd2.bid_lv == 2 and upd2.bid_px == 100 and upd2.bid_qty == 10 and upd2.bid_hidden == 0 and not upd2.bid_stale

    # Step 3: ADD 98 q7 -> Levels: 100:10, 99:5, lv=2, hidden=1, ok
    upd3 = book.apply_op(BookOp(idx=3, code=OP_ADD, sym=sym, side=side, remove=0, last=1, price=98, qty=7))
    assert upd3.bid_lv == 2 and upd3.bid_px == 100 and upd3.bid_qty == 10 and upd3.bid_hidden == 1 and not upd3.bid_stale

    # Step 4: ADD 101 q3 -> Levels: 101:3, 100:10, lv=2, hidden=2, ok (99 evicted, cnt 1)
    upd4 = book.apply_op(BookOp(idx=4, code=OP_ADD, sym=sym, side=side, remove=0, last=1, price=101, qty=3))
    assert upd4.bid_lv == 2 and upd4.bid_px == 101 and upd4.bid_qty == 3 and upd4.bid_hidden == 2 and not upd4.bid_stale

    # Step 5: REDUCE 101 q3 remove -> Levels: 100:10, lv=1, hidden=2, ok, best 100 exact
    upd5 = book.apply_op(BookOp(idx=5, code=OP_REDUCE, sym=sym, side=side, remove=1, last=1, price=101, qty=3))
    assert upd5.bid_lv == 1 and upd5.bid_px == 100 and upd5.bid_qty == 10 and upd5.bid_hidden == 2 and not upd5.bid_stale

    # Step 6: REDUCE 100 q10 remove -> none, lv=0, hidden=2, stale
    upd6 = book.apply_op(BookOp(idx=6, code=OP_REDUCE, sym=sym, side=side, remove=1, last=1, price=100, qty=10))
    assert upd6.bid_lv == 0 and upd6.bid_px == 0 and upd6.bid_qty == 0 and upd6.bid_hidden == 2 and upd6.bid_stale

    # Step 7: ADD 105 q1 -> none, lv=0, hidden=3, stale (cannot insert into empty book when hidden > 0)
    upd7 = book.apply_op(BookOp(idx=7, code=OP_ADD, sym=sym, side=side, remove=0, last=1, price=105, qty=1))
    assert upd7.bid_lv == 0 and upd7.bid_hidden == 3 and upd7.bid_stale

    # Step 8: REDUCE 99 q5 remove -> none, lv=0, hidden=2, stale
    upd8 = book.apply_op(BookOp(idx=8, code=OP_REDUCE, sym=sym, side=side, remove=1, last=1, price=99, qty=5))
    assert upd8.bid_lv == 0 and upd8.bid_hidden == 2 and upd8.bid_stale

    # Step 9: REDUCE 98 q7 remove -> none, lv=0, hidden=1, stale
    upd9 = book.apply_op(BookOp(idx=9, code=OP_REDUCE, sym=sym, side=side, remove=1, last=1, price=98, qty=7))
    assert upd9.bid_lv == 0 and upd9.bid_hidden == 1 and upd9.bid_stale

    # Step 10: REDUCE 105 q1 remove -> none, lv=0, hidden=0, empty, not stale
    upd10 = book.apply_op(BookOp(idx=10, code=OP_REDUCE, sym=sym, side=side, remove=1, last=1, price=105, qty=1))
    assert upd10.bid_lv == 0 and upd10.bid_hidden == 0 and not upd10.bid_stale

    print("MDL-2 / BK-W: PASS (All 10 steps of Section 9.3 reproduced exactly)")
    return True


if __name__ == "__main__":
    test_bkw()
