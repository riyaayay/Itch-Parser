# =============================================================================
# File        : model/framer.py
# Spec Section: 7.1 (Ingest), 7.2 (Framer)
# Description : Python reference model for AXI-Stream packet ingest and
#               2-byte big-endian ITCH block framing.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import struct
from typing import List, Tuple, Generator, Optional
from dataclasses import dataclass, field


@dataclass
class FramerCounters:
    rx_beats: int = 0
    rx_frames: int = 0
    ingest_overflow: int = 0
    rx_dropped_init: int = 0
    frame_err: int = 0
    keep_err: int = 0
    blocks_total: int = 0
    n_zero_len: int = 0


@dataclass
class FramedBlock:
    idx: int
    stored_len: int
    payload: bytes  # up to 50 bytes (zero-padded to 50 bytes for RTL compatibility)
    raw_payload: bytes # unpadded


class AxisFramerModel:
    """
    Reference model for S1 (t2t_ingest) and S2 (t2t_framer).
    Converts 64-byte (512-bit) AXI-Stream beats into structured ITCH message blocks.
    """
    def __init__(self):
        self.counters = FramerCounters()
        self.block_idx = 0
        self.session_invalid = False

    def reset(self):
        self.counters = FramerCounters()
        self.block_idx = 0
        self.session_invalid = False

    def process_frame_beats(
        self,
        beats: List[Tuple[bytes, int, bool]]
    ) -> Generator[FramedBlock, None, None]:
        """
        Ingest a list of AXI-Stream beats representing one frame.
        Each beat is (data_64b, keep_64b, is_last).
        """
        self.counters.rx_frames += 1
        frame_bytes = bytearray()
        frame_aborted = False

        for beat_idx, (tdata, tkeep, tlast) in enumerate(beats):
            self.counters.rx_beats += 1
            if len(tdata) < 64:
                tdata = tdata.ljust(64, b"\x00")
            elif len(tdata) > 64:
                tdata = tdata[:64]

            # Validate tkeep
            # On non-last beats, tkeep must be all ones (64'hFFFF_FFFF_FFFF_FFFF)
            if not tlast:
                if tkeep != 0xFFFF_FFFF_FFFF_FFFF:
                    self.counters.keep_err += 1
                    self.session_invalid = True
                    frame_aborted = True
                    break
                frame_bytes.extend(tdata)
            else:
                # On last beat, tkeep must be 2^n - 1 for 1 <= n <= 64
                if tkeep == 0:
                    self.counters.keep_err += 1
                    self.session_invalid = True
                    frame_aborted = True
                    break
                # Check for contiguous ones from LSB (lane 0)
                n_bytes = (tkeep + 1).bit_length() - 1
                expected_keep = (1 << n_bytes) - 1
                if tkeep != expected_keep or n_bytes > 64 or n_bytes < 1:
                    self.counters.keep_err += 1
                    self.session_invalid = True
                    frame_aborted = True
                    break
                frame_bytes.extend(tdata[:n_bytes])

        if frame_aborted:
            return

        # Framing: parse 2-byte length prefixed ITCH blocks
        p = 0
        total_len = len(frame_bytes)

        while p < total_len:
            # Need at least 2 bytes for the length prefix
            if p + 2 > total_len:
                self.counters.frame_err += 1
                self.session_invalid = True
                break

            stored_len = struct.unpack(">H", frame_bytes[p:p+2])[0]

            if stored_len > 50:
                self.counters.frame_err += 1
                self.session_invalid = True
                break

            if stored_len == 0:
                self.counters.n_zero_len += 1
                self.counters.blocks_total += 1
                yield FramedBlock(
                    idx=self.block_idx,
                    stored_len=0,
                    payload=b"\x00" * 50,
                    raw_payload=b""
                )
                self.block_idx += 1
                p += 2
                continue

            if p + 2 + stored_len > total_len:
                self.counters.frame_err += 1
                self.session_invalid = True
                break

            raw_payload = bytes(frame_bytes[p+2 : p+2+stored_len])
            # Zero pad to 50 bytes (400 bits) for RTL o_blk_bytes equivalence
            padded_payload = raw_payload.ljust(50, b"\x00")

            self.counters.blocks_total += 1
            yield FramedBlock(
                idx=self.block_idx,
                stored_len=stored_len,
                payload=padded_payload,
                raw_payload=raw_payload
            )
            self.block_idx += 1
            p += 2 + stored_len

    @staticmethod
    def pack_stream_into_beats(stream_bytes: bytes) -> List[Tuple[bytes, int, bool]]:
        """Utility to partition raw byte buffer into 64-byte AXI-Stream beats."""
        beats = []
        offset = 0
        total = len(stream_bytes)
        if total == 0:
            return beats

        while offset < total:
            chunk = stream_bytes[offset : offset + 64]
            is_last = (offset + len(chunk) == total)
            chunk_len = len(chunk)
            tkeep = (1 << chunk_len) - 1
            tdata = chunk.ljust(64, b"\x00")
            beats.append((tdata, tkeep, is_last))
            offset += 64
        return beats

