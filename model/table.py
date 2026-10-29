# =============================================================================
# File        : model/table.py
# Spec Section: 8.1 (Symbol Filter), 8.2, 8.3 (Order Table)
# Description : Python reference model for symbol filtering and 4-way
#               set-associative order table tracking.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict
from model.itch import ItchMessage


# Operation codes for OP bus (Section 4.2 / 5.2)
OP_ADD     = 0
OP_REDUCE  = 1
OP_CORRUPT = 2

SIDE_BID   = 0
SIDE_ASK   = 1


@dataclass
class TableCounters:
    sym_hit: int = 0
    sym_miss: int = 0
    tbl_ins: int = 0
    tbl_ref_miss: int = 0
    tbl_dup_ref: int = 0
    tbl_set_full: int = 0
    tbl_qty_underflow: int = 0
    tbl_same_set_stalls: int = 0


@dataclass
class TableEntry:
    valid: bool = False
    ref: int = 0
    sym: int = 0
    side: int = 0
    price: int = 0
    shares: int = 0


@dataclass
class BookOp:
    idx: int       # message index
    code: int      # 0=ADD, 1=REDUCE, 2=CORRUPT
    sym: int       # symbol slot (0..7)
    side: int      # 0=bid, 1=ask
    remove: int    # 1 if order is fully deleted from book level
    last: int      # 1 if final op for this message (trigger acts on last)
    price: int     # 32-bit price
    qty: int       # 32-bit shares / delta

    def format_op2_line(self) -> str:
        """Format as normative exp_op2.txt line (Section 6.3)."""
        # idx8 code1 sym1 side1 remove1 last1 price8 qty8
        return (
            f"{self.idx:08X} "
            f"{self.code:01X} "
            f"{self.sym:01X} "
            f"{self.side:01X} "
            f"{self.remove:01X} "
            f"{self.last:01X} "
            f"{self.price:08X} "
            f"{self.qty:08X}"
        )


class OrderTableModel:
    """
    Reference model for S4 (Symbol Filter) and S5 (4-way Set-Associative Order Table).
    """
    def __init__(
        self,
        symbols: List[bytes],
        table_aw: int = 9,      # 512 sets for Artix-7 (A7)
        table_ways: int = 4
    ):
        self.num_symbols = len(symbols)
        self.symbols = [s[:8].ljust(8, b" ") for s in symbols]
        self.table_aw = table_aw
        self.num_sets = 1 << table_aw
        self.table_ways = table_ways
        self.sets: List[List[TableEntry]] = [
            [TableEntry() for _ in range(table_ways)]
            for _ in range(self.num_sets)
        ]
        self.counters = TableCounters()

    def reset(self):
        self.sets = [
            [TableEntry() for _ in range(self.table_ways)]
            for _ in range(self.num_sets)
        ]
        self.counters = TableCounters()

    def _lookup_slot(self, stock_bytes: bytes) -> Optional[int]:
        """Match stock against active symbol slots. Lowest index wins."""
        stock_clean = stock_bytes[:8].ljust(8, b" ")
        for i, sym in enumerate(self.symbols):
            if sym != b"\x00" * 8 and sym == stock_clean:
                return i
        return None

    def _lookup_ref(self, ref: int) -> Tuple[int, Optional[int]]:
        """Find way index for ref in its set. Returns (set_idx, way_idx)."""
        set_idx = ref & (self.num_sets - 1)
        the_set = self.sets[set_idx]
        for w, entry in enumerate(the_set):
            if entry.valid and entry.ref == ref:
                return set_idx, w
        return set_idx, None

    def _find_free_way(self, set_idx: int) -> Optional[int]:
        """Lowest invalid way in the set."""
        for w, entry in enumerate(self.sets[set_idx]):
            if not entry.valid:
                return w
        return None

    def process_message(self, msg: ItchMessage) -> List[BookOp]:
        """
        Process a parsed ITCH message through symbol filter and order table.
        Emits list of BookOp objects.
        """
        if not msg.handled:
            return []

        ops: List[BookOp] = []

        # ---------------------------------------------------------------------
        # Types A & F: Add Order
        # ---------------------------------------------------------------------
        if msg.msg_type in (0x41, 0x46):
            slot = self._lookup_slot(msg.stock)
            if slot is None:
                self.counters.sym_miss += 1
                return []
            self.counters.sym_hit += 1

            # Validate side
            if msg.side not in (ord('B'), ord('S')):
                # CORRUPT op
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=slot, side=SIDE_BID,
                    remove=0, last=1, price=0, qty=0
                ))
                return ops

            side_code = SIDE_BID if msg.side == ord('B') else SIDE_ASK
            set_idx, way_idx = self._lookup_ref(msg.ref)

            if way_idx is not None:
                # Duplicate reference hazard -> CORRUPT
                self.counters.tbl_dup_ref += 1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=slot, side=side_code,
                    remove=0, last=1, price=0, qty=0
                ))
                return ops

            free_way = self._find_free_way(set_idx)
            if free_way is None:
                # Set full -> CORRUPT
                self.counters.tbl_set_full += 1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=slot, side=side_code,
                    remove=0, last=1, price=0, qty=0
                ))
                return ops

            # Write lowest invalid way
            self.sets[set_idx][free_way] = TableEntry(
                valid=True,
                ref=msg.ref,
                sym=slot,
                side=side_code,
                price=msg.price,
                shares=msg.shares
            )
            self.counters.tbl_ins += 1
            ops.append(BookOp(
                idx=msg.idx, code=OP_ADD, sym=slot, side=side_code,
                remove=0, last=1, price=msg.price, qty=msg.shares
            ))
            return ops

        # ---------------------------------------------------------------------
        # Types E, C, X: Order Executed / Executed with Price / Cancel
        # ---------------------------------------------------------------------
        elif msg.msg_type in (0x45, 0x43, 0x58):
            set_idx, way_idx = self._lookup_ref(msg.ref)
            if way_idx is None:
                # Reference miss (benign)
                self.counters.tbl_ref_miss += 1
                return []

            entry = self.sets[set_idx][way_idx]
            x = msg.shares

            if x > entry.shares:
                # Quantity underflow -> CORRUPT
                self.counters.tbl_qty_underflow += 1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=entry.sym, side=entry.side,
                    remove=0, last=1, price=0, qty=0
                ))
            elif x == entry.shares:
                # Full execution/cancellation: invalidate way, remove=1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_REDUCE, sym=entry.sym, side=entry.side,
                    remove=1, last=1, price=entry.price, qty=x
                ))
                self.sets[set_idx][way_idx] = TableEntry()
            else:
                # Partial reduction: decrement shares, remove=0
                entry.shares -= x
                ops.append(BookOp(
                    idx=msg.idx, code=OP_REDUCE, sym=entry.sym, side=entry.side,
                    remove=0, last=1, price=entry.price, qty=x
                ))
            return ops

        # ---------------------------------------------------------------------
        # Type D: Order Delete
        # ---------------------------------------------------------------------
        elif msg.msg_type == 0x44:
            set_idx, way_idx = self._lookup_ref(msg.ref)
            if way_idx is None:
                self.counters.tbl_ref_miss += 1
                return []

            entry = self.sets[set_idx][way_idx]
            ops.append(BookOp(
                idx=msg.idx, code=OP_REDUCE, sym=entry.sym, side=entry.side,
                remove=1, last=1, price=entry.price, qty=entry.shares
            ))
            self.sets[set_idx][way_idx] = TableEntry()
            return ops

        # ---------------------------------------------------------------------
        # Type U: Order Replace
        # ---------------------------------------------------------------------
        elif msg.msg_type == 0x55:
            set_idx, way_idx = self._lookup_ref(msg.ref)
            if way_idx is None:
                self.counters.tbl_ref_miss += 1
                return []

            entry = self.sets[set_idx][way_idx]
            old_sym = entry.sym
            old_side = entry.side
            old_price = entry.price
            old_shares = entry.shares

            # Invalidate old way before inserting new
            self.sets[set_idx][way_idx] = TableEntry()

            # Op 1: REDUCE old order (remove=1, not last)
            op1 = BookOp(
                idx=msg.idx, code=OP_REDUCE, sym=old_sym, side=old_side,
                remove=1, last=0, price=old_price, qty=old_shares
            )
            ops.append(op1)

            # Insert new_ref with old sym & side, new price & shares
            new_set_idx, new_way_idx = self._lookup_ref(msg.newref)
            if new_way_idx is not None:
                # dup_ref on new ref
                self.counters.tbl_dup_ref += 1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=old_sym, side=old_side,
                    remove=0, last=1, price=0, qty=0
                ))
                return ops

            new_free_way = self._find_free_way(new_set_idx)
            if new_free_way is None:
                # set_full on new set
                self.counters.tbl_set_full += 1
                ops.append(BookOp(
                    idx=msg.idx, code=OP_CORRUPT, sym=old_sym, side=old_side,
                    remove=0, last=1, price=0, qty=0
                ))
                return ops

            self.sets[new_set_idx][new_free_way] = TableEntry(
                valid=True,
                ref=msg.newref,
                sym=old_sym,
                side=old_side,
                price=msg.price,
                shares=msg.shares
            )
            self.counters.tbl_ins += 1
            ops.append(BookOp(
                idx=msg.idx, code=OP_ADD, sym=old_sym, side=old_side,
                remove=0, last=1, price=msg.price, qty=msg.shares
            ))
            return ops

        return []
