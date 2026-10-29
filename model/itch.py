# =============================================================================
# File        : model/itch.py
# Spec Section: 4.2, 6.1 (Inbound ITCH 5.0 Wire Formats), VERIFY-2, VERIFY-9
# Description : ITCH 5.0 message parser, encoder, and data definitions.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import struct
from dataclasses import dataclass
from typing import Optional, Tuple, Dict


# -----------------------------------------------------------------------------
# 6.1 ITCH 5.0 Normative Lengths & Types
# -----------------------------------------------------------------------------
# Handled ITCH 5.0 message types:
# Type byte -> (Stored length excluding 2-byte prefix, Description)
HANDLED_TYPES: Dict[int, Tuple[int, str]] = {
    0x41: (36, "Add Order"),
    0x46: (40, "Add Order with MPID"),
    0x45: (31, "Order Executed"),
    0x43: (36, "Order Executed with Price"),
    0x58: (23, "Order Cancel"),
    0x44: (19, "Order Delete"),
    0x55: (35, "Order Replace"),
}

# Unhandled types with normative lengths (VERIFY-2):
# These are skipped by length when 1 <= len <= 50
UNHANDLED_TYPES: Dict[int, int] = {
    ord('S'): 12,  # System Event
    ord('R'): 39,  # Stock Directory
    ord('H'): 25,  # Stock Trading Action
    ord('Y'): 20,  # Reg SHO Restriction
    ord('L'): 26,  # Market Participant Position
    ord('V'): 35,  # MWCB Decline Level
    ord('W'): 12,  # MWCB Status
    ord('K'): 28,  # IPO Quoting Period
    ord('J'): 35,  # LULD Auction Collar
    ord('h'): 21,  # Operational Halt
    ord('P'): 44,  # Non-cross Trade
    ord('Q'): 40,  # Cross Trade
    ord('B'): 19,  # Broken Trade
    ord('I'): 50,  # NOII
    ord('N'): 20,  # Retail Interest
}

MAX_ITCH_LEN = 50


@dataclass
class ItchMessage:
    """Represents a parsed ITCH 5.0 message block."""
    idx: int                    # Monotonic block index (0-based)
    msg_type: int               # Raw type byte (e.g. 0x41 for 'A')
    stored_len: int             # Length in 2-byte prefix
    locate: int = 0             # 16-bit Stock Locate
    ref: int = 0                # 64-bit Order Reference Number
    newref: int = 0             # 64-bit New Order Reference Number (Type U)
    side: int = 0               # ASCII side byte (0x42 'B' or 0x53 'S')
    shares: int = 0             # 32-bit Shares / Executed Shares / Cancelled Shares
    price: int = 0              # 32-bit Price (in 1/10000 USD)
    stock: bytes = b"        "  # 8-byte space-padded ASCII stock symbol
    attribution: bytes = b"    "# 4-byte MPID (Type F)

    # Diagnostic / Pipeline Flags (exp_op1.txt):
    # bit 0: handled
    # bit 1: bad_len (handled type but length != table length)
    # bit 2: zero_len (stored_len == 0)
    # bit 3: bad_side (A or F message where side is neither 'B' nor 'S')
    handled: bool = False
    bad_len: bool = False
    zero_len: bool = False
    bad_side: bool = False

    @property
    def side_str(self) -> str:
        return chr(self.side) if self.side in (ord('B'), ord('S')) else "?"

    @property
    def stock_str(self) -> str:
        return self.stock.decode("ascii", errors="replace")

    @property
    def type_char(self) -> str:
        return chr(self.msg_type) if 32 <= self.msg_type <= 126 else "?"

    @property
    def flags_int(self) -> int:
        flg = 0
        if self.handled:
            flg |= (1 << 0)
        if self.bad_len:
            flg |= (1 << 1)
        if self.zero_len:
            flg |= (1 << 2)
        if self.bad_side:
            flg |= (1 << 3)
        return flg

    def format_op1_line(self) -> str:
        """Format as normative exp_op1.txt line (Section 6.3)."""
        # idx8 type2 len4 flags2 locate4 ref16 newref16 side2 shares8 price8 stock16 (hex)
        stock_hex = self.stock.hex().upper()
        return (
            f"{self.idx:08X} "
            f"{self.msg_type:02X} "
            f"{self.stored_len:04X} "
            f"{self.flags_int:02X} "
            f"{self.locate:04X} "
            f"{self.ref:016X} "
            f"{self.newref:016X} "
            f"{self.side:02X} "
            f"{self.shares:08X} "
            f"{self.price:08X} "
            f"{stock_hex}"
        )


def parse_itch_block(idx: int, stored_len: int, payload: bytes) -> ItchMessage:
    """
    Parse an ITCH 5.0 block payload (excluding the 2-byte length prefix).
    Section 6.1 normative field offsets:
      Offset 0 (1B): Type
      Offset 1 (2B): Locate
      Offset 3 (2B): Tracking Number (ignored)
      Offset 5 (6B): Timestamp (ignored)
    """
    if stored_len == 0 or len(payload) == 0:
        return ItchMessage(
            idx=idx,
            msg_type=0,
            stored_len=stored_len,
            zero_len=True,
            handled=False
        )

    msg_type = payload[0]

    # Check for handled types
    if msg_type not in HANDLED_TYPES:
        return ItchMessage(
            idx=idx,
            msg_type=msg_type,
            stored_len=stored_len,
            handled=False
        )

    expected_len, _ = HANDLED_TYPES[msg_type]
    if stored_len != expected_len or len(payload) < expected_len:
        return ItchMessage(
            idx=idx,
            msg_type=msg_type,
            stored_len=stored_len,
            bad_len=True,
            handled=False
        )

    # Valid handled message
    msg = ItchMessage(
        idx=idx,
        msg_type=msg_type,
        stored_len=stored_len,
        handled=True
    )

    # Common fields: locate (offset 1:2)
    msg.locate = struct.unpack(">H", payload[1:3])[0]

    if msg_type in (0x41, 0x46):  # 'A', 'F' Add Order
        # ref: 11:8, side: 19:1, shares: 20:4, stock: 24:8, price: 32:4
        msg.ref = struct.unpack(">Q", payload[11:19])[0]
        msg.side = payload[19]
        msg.shares = struct.unpack(">I", payload[20:24])[0]
        msg.stock = payload[24:32]
        msg.price = struct.unpack(">I", payload[32:36])[0]
        if msg_type == 0x46 and len(payload) >= 40:
            msg.attribution = payload[36:40]
        if msg.side not in (ord('B'), ord('S')):
            msg.bad_side = True

    elif msg_type == 0x45:  # 'E' Order Executed
        # ref: 11:8, executed shares: 19:4
        msg.ref = struct.unpack(">Q", payload[11:19])[0]
        msg.shares = struct.unpack(">I", payload[19:23])[0]

    elif msg_type == 0x43:  # 'C' Order Executed with Price
        # ref: 11:8, executed shares: 19:4, price: 32:4
        msg.ref = struct.unpack(">Q", payload[11:19])[0]
        msg.shares = struct.unpack(">I", payload[19:23])[0]
        msg.price = struct.unpack(">I", payload[32:36])[0]

    elif msg_type == 0x58:  # 'X' Order Cancel
        # ref: 11:8, cancelled shares: 19:4
        msg.ref = struct.unpack(">Q", payload[11:19])[0]
        msg.shares = struct.unpack(">I", payload[19:23])[0]

    elif msg_type == 0x44:  # 'D' Order Delete
        # ref: 11:8
        msg.ref = struct.unpack(">Q", payload[11:19])[0]

    elif msg_type == 0x55:  # 'U' Order Replace
        # orig_ref: 11:8, new_ref: 19:8, shares: 27:4, price: 31:4
        msg.ref = struct.unpack(">Q", payload[11:19])[0]
        msg.newref = struct.unpack(">Q", payload[19:27])[0]
        msg.shares = struct.unpack(">I", payload[27:31])[0]
        msg.price = struct.unpack(">I", payload[31:35])[0]

    return msg


def encode_itch_message(
    msg_type: int,
    locate: int = 0,
    tracking: int = 0,
    timestamp: int = 0,
    ref: int = 0,
    side: int = ord('B'),
    shares: int = 0,
    stock: bytes = b"AAPL    ",
    price: int = 0,
    newref: int = 0,
    attribution: bytes = b"MPID",
    match_num: int = 0,
    printable: int = ord('Y')
) -> bytes:
    """
    Construct a full well-formed ITCH 5.0 block including 2-byte length prefix.
    """
    if len(stock) < 8:
        stock = stock.ljust(8, b" ")
    else:
        stock = stock[:8]

    # Timestamp is 6 bytes (48-bit unsigned integer)
    ts_bytes = timestamp.to_bytes(6, byteorder="big")

    if msg_type == 0x41:  # 'A' Add Order (36B payload)
        payload = byteorder = (
            bytes([0x41]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QB", ref, side) +
            struct.pack(">I", shares) +
            stock +
            struct.pack(">I", price)
        )
    elif msg_type == 0x46:  # 'F' Add Order with MPID (40B payload)
        payload = (
            bytes([0x46]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QB", ref, side) +
            struct.pack(">I", shares) +
            stock +
            struct.pack(">I", price) +
            attribution[:4].ljust(4, b" ")
        )
    elif msg_type == 0x45:  # 'E' Order Executed (31B payload)
        payload = (
            bytes([0x45]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QI", ref, shares) +
            struct.pack(">Q", match_num)
        )
    elif msg_type == 0x43:  # 'C' Order Executed with Price (36B payload)
        payload = (
            bytes([0x43]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QI", ref, shares) +
            struct.pack(">Q", match_num) +
            bytes([printable]) +
            struct.pack(">I", price)
        )
    elif msg_type == 0x58:  # 'X' Order Cancel (23B payload)
        payload = (
            bytes([0x58]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QI", ref, shares)
        )
    elif msg_type == 0x44:  # 'D' Order Delete (19B payload)
        payload = (
            bytes([0x44]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">Q", ref)
        )
    elif msg_type == 0x55:  # 'U' Order Replace (35B payload)
        payload = (
            bytes([0x55]) +
            struct.pack(">HH", locate, tracking) +
            ts_bytes +
            struct.pack(">QQII", ref, newref, shares, price)
        )
    else:
        raise ValueError(f"Unsupported encode type: {hex(msg_type)}")

    prefix = struct.pack(">H", len(payload))
    return prefix + payload


def test_mdl1() -> bool:
    """
    Verification Gate MDL-1 (Section 12.2 / VERIFY-2, VERIFY-9):
    Verify that every handled ITCH 5.0 message type parses correctly against
    hand-built examples with exact field positions, lengths, and round-trips.
    """
    cases = [
        # Type A: Add Order (36B)
        (0x41, 101, 1, 123456789, 10001, ord('B'), 500, b"AAPL    ", 1500000),
        # Type F: Add Order with MPID (40B)
        (0x46, 102, 2, 123456790, 10002, ord('S'), 300, b"SPY     ", 4500000),
        # Type E: Order Executed (31B)
        (0x45, 101, 3, 123456791, 10001, 0, 200, b"", 0),
        # Type C: Order Executed with Price (36B)
        (0x43, 101, 4, 123456792, 10001, 0, 100, b"", 1505000),
        # Type X: Order Cancel (23B)
        (0x58, 101, 5, 123456793, 10001, 0, 50, b"", 0),
        # Type D: Order Delete (19B)
        (0x44, 101, 6, 123456794, 10001, 0, 0, b"", 0),
        # Type U: Order Replace (35B)
        (0x55, 101, 7, 123456795, 10001, 0, 600, b"", 1510000),
    ]

    for c in cases:
        mtype, locate, tracking, ts, ref, side, shares, stock, price = c
        raw = encode_itch_message(
            msg_type=mtype,
            locate=locate,
            tracking=tracking,
            timestamp=ts,
            ref=ref,
            side=side,
            shares=shares,
            stock=stock,
            price=price,
            newref=ref + 500 if mtype == 0x55 else 0
        )
        stored_len = struct.unpack(">H", raw[:2])[0]
        payload = raw[2:]
        expected_len, _ = HANDLED_TYPES[mtype]
        assert stored_len == expected_len, f"Type {chr(mtype)} length mismatch: {stored_len} vs {expected_len}"
        assert len(payload) == expected_len, f"Type {chr(mtype)} payload len mismatch"

        msg = parse_itch_block(idx=0, stored_len=stored_len, payload=payload)
        assert msg.handled, f"Type {chr(mtype)} not marked handled"
        assert not msg.bad_len, f"Type {chr(mtype)} marked bad_len"
        assert msg.locate == locate, f"Type {chr(mtype)} locate mismatch: {msg.locate} vs {locate}"
        assert msg.ref == ref, f"Type {chr(mtype)} ref mismatch: {msg.ref} vs {ref}"

        if mtype in (0x41, 0x46):
            assert msg.side == side
            assert msg.shares == shares
            assert msg.price == price
            assert msg.stock.rstrip() == stock.rstrip()
        elif mtype in (0x45, 0x43, 0x58):
            assert msg.shares == shares
            if mtype == 0x43:
                assert msg.price == price
        elif mtype == 0x55:
            assert msg.newref == ref + 500
            assert msg.shares == shares
            assert msg.price == price

    print("MDL-1 / VERIFY-2 / VERIFY-9: PASS (All ITCH 5.0 message formats verified)")
    return True


if __name__ == "__main__":
    test_mdl1()
