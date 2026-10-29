#!/usr/bin/env python3
# =============================================================================
# File        : tools/extract_itch.py
# Spec Section: 6.1, 14.1
# Description : Utility to extract and decode raw ITCH 5.0 binary message streams.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import argparse
import pathlib
import struct
import sys
from typing import Generator, Tuple
from model.itch import parse_itch_block, ItchMessage, HANDLED_TYPES


def stream_itch_blocks(path: pathlib.Path) -> Generator[Tuple[int, int, bytes], None, None]:
    """Yields (block_idx, stored_len, payload_bytes) from a 2-byte prefixed ITCH stream."""
    with open(path, "rb") as f:
        blk_idx = 0
        while True:
            prefix = f.read(2)
            if len(prefix) < 2:
                break
            stored_len = struct.unpack(">H", prefix)[0]
            if stored_len == 0:
                yield blk_idx, 0, b""
                blk_idx += 1
                continue
            payload = f.read(stored_len)
            if len(payload) < stored_len:
                break
            yield blk_idx, stored_len, payload
            blk_idx += 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract and decode ITCH 5.0 binary files")
    parser.add_argument("--input", type=pathlib.Path, required=True, help="Input ITCH binary file")
    parser.add_argument("--limit", type=int, default=100, help="Max blocks to decode")
    parser.add_argument("--type", type=str, default=None, help="Filter by message type char (e.g. 'A')")
    args = parser.parse_args()

    filter_type = ord(args.type) if args.type else None
    count = 0

    print(f"Decoding {args.input} (limit={args.limit})...")
    print("BlkIdx | Type | Len | Stock    | Side | Shares     | Price       | Ref")
    print("-------+------+-----+----------+------+------------+-------------+-------------------")

    for idx, stored_len, payload in stream_itch_blocks(args.input):
        msg = parse_itch_block(idx, stored_len, payload)
        if filter_type and msg.msg_type != filter_type:
            continue
        print(
            f"{msg.idx:6d} | {msg.type_char:4s} | {msg.stored_len:3d} | "
            f"{msg.stock_str:8s} | {msg.side_str:4s} | {msg.shares:10d} | "
            f"${msg.price/10000.0:10.4f} | {msg.ref}"
        )
        count += 1
        if args.limit and count >= args.limit:
            break

    print(f"Extracted {count} messages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

