# =============================================================================
# File        : model/encoder.py
# Spec Section: 6.2 (Outbound OUCH-Style Enter Order Frame), 11.1 (t2t_encoder)
# Description : Python reference model for 48-byte OUCH order formatting,
#               user reference counter sequencing, and AXI-Stream framing.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import struct
from dataclasses import dataclass, field
from typing import List, Optional, Tuple
from model.table import SIDE_BID, SIDE_ASK
from model.risk import RiskDecision


OUCH_TYPE_ENTER       = 0x4F   # 'O'
OUCH_TIF_IOC          = 0x0000_0000
OUCH_DISPLAY          = 0x59   # 'Y'
OUCH_CAPACITY         = 0x50   # 'P'
OUCH_ISO              = 0x4E   # 'N'
OUCH_MIN_QTY          = 0x0000_0000
OUCH_CROSS_TYPE       = 0x4E   # 'N'
OUCH_CUST_TYPE        = 0x4E   # 'N'
OUCH_APPEND_LEN       = 0x0000


@dataclass
class OutboundFrame:
    user_ref: int
    trigger_idx: int
    rule_id: int
    sym: int
    side: int
    qty: int
    price: int
    stock: bytes
    frame_bytes: bytes

    def format_op6_line(self) -> str:
        """Format as normative exp_op6.txt line (Section 6.3): 96 hex digits, byte 0 first."""
        return self.frame_bytes.hex().upper()

    def to_axis_beat(self) -> Tuple[bytes, int, bool]:
        """Convert to 64-byte AXI-Stream beat (Section 6.2)."""
        # Bytes 0..47 hold frame, bytes 48..63 are zero
        # tdata[8*i +: 8] = byte i
        tdata = self.frame_bytes.ljust(64, b"\x00")
        tkeep = 0x0000_FFFF_FFFF_FFFF
        tlast = True
        return tdata, tkeep, tlast


class EncoderModel:
    """
    Reference model for S9 (t2t_encoder) and TX FIFO.
    """
    def __init__(self, symbols: List[bytes]):
        self.symbols = [s[:8].ljust(8, b" ") for s in symbols]
        self.user_ref_counter: int = 0
        self.tx_frames_count: int = 0
        self.tx_overflow_count: int = 0

    def reset(self):
        self.user_ref_counter = 0
        self.tx_frames_count = 0
        self.tx_overflow_count = 0

    def encode(
        self,
        decision: RiskDecision,
        rule_id: int = 0
    ) -> Optional[OutboundFrame]:
        """
        Encode an accepted risk decision into a 48-byte OUCH Enter Order frame.
        """
        if not decision.passed:
            return None

        self.user_ref_counter += 1
        uref = self.user_ref_counter
        self.tx_frames_count += 1

        sym = decision.sym
        stock_bytes = self.symbols[sym]
        side_byte = ord('B') if decision.side == SIDE_BID else ord('S')

        # Construct 48-byte big-endian frame
        # Offset  0: type 0x4F (1B)
        # Offset  1: user_ref (4B)
        # Offset  5: side (1B)
        # Offset  6: quantity (4B)
        # Offset 10: stock (8B)
        # Offset 18: price (4B)
        # Offset 22: time_in_force (4B)
        # Offset 26: display (1B)
        # Offset 27: capacity (1B)
        # Offset 28: ISO (1B)
        # Offset 29: min qty (4B)
        # Offset 33: cross type (1B)
        # Offset 34: cust type (1B)
        # Offset 35: append len (2B)
        # Offset 37: trigger_idx (4B)
        # Offset 41: rule_id (1B)
        # Offset 42: pad (6B)
        frame = bytearray(48)
        frame[0] = OUCH_TYPE_ENTER
        struct.pack_into(">I", frame, 1, uref)
        frame[5] = side_byte
        struct.pack_into(">I", frame, 6, decision.qty)
        frame[10:18] = stock_bytes
        struct.pack_into(">I", frame, 18, decision.price)
        struct.pack_into(">I", frame, 22, OUCH_TIF_IOC)
        frame[26] = OUCH_DISPLAY
        frame[27] = OUCH_CAPACITY
        frame[28] = OUCH_ISO
        struct.pack_into(">I", frame, 29, OUCH_MIN_QTY)
        frame[33] = OUCH_CROSS_TYPE
        frame[34] = OUCH_CUST_TYPE
        struct.pack_into(">H", frame, 35, OUCH_APPEND_LEN)
        struct.pack_into(">I", frame, 37, decision.idx)
        frame[41] = rule_id & 0xFF
        frame[42:48] = b"\x00" * 6

        assert len(frame) == 48, f"Frame length {len(frame)} != 48"

        return OutboundFrame(
            user_ref=uref,
            trigger_idx=decision.idx,
            rule_id=rule_id,
            sym=sym,
            side=decision.side,
            qty=decision.qty,
            price=decision.price,
            stock=stock_bytes,
            frame_bytes=bytes(frame)
        )

