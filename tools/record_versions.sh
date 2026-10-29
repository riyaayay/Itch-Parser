#!/usr/bin/env bash
# ==============================================================================
# File        : tools/record_versions.sh
# Spec Section: 14.3, 15 (T0), 16.1 (VERIFY-8)
# Description : Records installed tool versions into tools/VERSIONS.txt and
#               verifies Verilator line and toggle coverage flags (VERIFY-8).
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# ==============================================================================
set -eu

OUT="tools/VERSIONS.txt"

{
    echo "# tick2trade-fpga Toolchain Versions (Recorded at T0)"
    echo "Date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "OS / Kernel: $(uname -srm)"
    echo ""
    echo "## Python"
    python3 --version 2>&1 || echo "python3: NOT INSTALLED"
    echo ""
    echo "## Icarus Verilog"
    (iverilog -V 2>&1 || true) | sed -n '1p'
    echo ""
    echo "## Verilator"
    verilator --version 2>&1 || echo "verilator: NOT INSTALLED"
    echo ""
    echo "## Yosys"
    yosys -V 2>&1 || echo "yosys: NOT INSTALLED"
    echo ""
    echo "## SymbiYosys"
    sby --version 2>&1 || echo "sby: NOT INSTALLED (optional until T2/T12)"
    echo ""
    echo "## VERIFY-8: Verilator Line & Toggle Coverage Flag Verification"
    if verilator --help 2>&1 | grep -q -- "--coverage-line" && \
       verilator --help 2>&1 | grep -q -- "--coverage-toggle"; then
        echo "VERIFY-8 STATUS: CONFIRMED (--coverage-line and --coverage-toggle supported)"
    else
        echo "VERIFY-8 STATUS: FAILED (missing coverage flags)"
        exit 1
    fi
} > "${OUT}"

cat "${OUT}"
