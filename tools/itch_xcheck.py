#!/usr/bin/env python3
# =============================================================================
# File        : tools/itch_xcheck.py
# Spec Section: 6.3, 12.2, 14.1
# Description : Cross-checker comparing RTL simulation outputs against
#               Python Golden Reference Model expected output files.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

from __future__ import annotations
import argparse
import pathlib
import sys
from typing import List, Tuple


FILES_TO_CHECK = [
    "exp_op1.txt",
    "exp_op2.txt",
    "exp_op3.txt",
    "exp_op4.txt",
    "exp_op5.txt",
    "exp_op6.txt",
    "exp_counters.txt",
]


def compare_files(exp_path: pathlib.Path, act_path: pathlib.Path) -> Tuple[bool, List[str]]:
    """Compare two files line by line, ignoring trailing whitespace and empty lines."""
    if not exp_path.exists():
        return False, [f"Expected file missing: {exp_path}"]
    if not act_path.exists():
        return False, [f"Actual file missing: {act_path}"]

    with open(exp_path, "r", encoding="ascii", errors="replace") as f:
        exp_lines = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    with open(act_path, "r", encoding="ascii", errors="replace") as f:
        act_lines = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]

    errors = []
    if len(exp_lines) != len(act_lines):
        errors.append(f"Line count mismatch: expected {len(exp_lines)} lines, got {len(act_lines)} lines")

    min_len = min(len(exp_lines), len(act_lines))
    mismatches = 0
    for i in range(min_len):
        if exp_lines[i] != act_lines[i]:
            mismatches += 1
            if mismatches <= 10:
                errors.append(
                    f"Line {i + 1} mismatch:\n"
                    f"  EXP: {exp_lines[i]}\n"
                    f"  ACT: {act_lines[i]}"
                )

    if mismatches > 10:
        errors.append(f"... and {mismatches - 10} additional line mismatches.")

    return len(errors) == 0, errors


def main() -> int:
    parser = argparse.ArgumentParser(description="tick2trade-fpga Output Cross-Checker")
    parser.add_argument("--exp-dir", type=pathlib.Path, required=True, help="Directory containing expected files")
    parser.add_argument("--act-dir", type=pathlib.Path, required=True, help="Directory containing simulation actual files")
    args = parser.parse_args()

    all_passed = True
    print(f"Cross-checking {args.act_dir} against {args.exp_dir}...")

    for fname in FILES_TO_CHECK:
        exp_file = args.exp_dir / fname
        act_file = args.act_dir / fname
        if not exp_file.exists():
            continue

        passed, errs = compare_files(exp_file, act_file)
        if passed:
            print(f"  [PASS] {fname}")
        else:
            all_passed = False
            print(f"  [FAIL] {fname}:")
            for e in errs:
                print(f"    {e}")

    if all_passed:
        print("ALL VERIFICATION GATES PASSED (100% Exact Match)")
        return 0
    else:
        print("VERIFICATION FAILED: Mismatches detected.")
        return 1


if __name__ == "__main__":
    sys.exit(main())

