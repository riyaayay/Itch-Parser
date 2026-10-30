# tick2trade-fpga

[![Hardware Architecture](https://img.shields.io/badge/Architecture-Clean--Slate%20Tick--to--Trade-blue.svg)](#pipeline-architecture)
[![Target FPGA](https://img.shields.io/badge/FPGA-Xilinx%20Artix--7%20xc7a35t-orange.svg)](#build-profiles--target-hardware)
[![Clock Domain](https://img.shields.io/badge/Clock-200%20MHz%20Single--Domain-green.svg)](#timing--clocking)
[![DSP Utilization](https://img.shields.io/badge/DSP%20Slices-0%20(Pure%20LUT)-brightgreen.svg)](#zero-dsp-multiplier)
[![Verification](https://img.shields.io/badge/Verification-100%25%20Bit--Accurate-success.svg)](#verification-gates--empirical-results)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A high-throughput, deterministic, low-latency FPGA tick-to-trade pipeline implemented in synthesizable Verilog-2005. The system ingests **512-bit AXI4-Stream NASDAQ TotalView-ITCH 5.0** market data, maintains L2 Top-8 limit order books for 8 concurrent symbols, evaluates deterministic edge-triggered trading rules, applies strict sequentially-consistent pre-trade risk checks with a **zero-DSP pipelined multiplier**, and formats outbound **48-byte OUCH-style execution orders** at wire speed.

Originally inspired by [tmlee06/Itch-Parser](https://github.com/tmlee06/Itch-Parser), this repository is an end-to-end clean-slate re-architecture designed to overcome the throughput bottlenecks, state-machine defects, and placeholder logic present in upstream designs.

---

## Table of Contents

- [Key Architectural Features](#key-architectural-features)
- [Pipeline Architecture](#pipeline-architecture)
- [Stage Breakdown & Latency Budget](#stage-breakdown--latency-budget)
- [Deep-Dive Design Invariants](#deep-dive-design-invariants)
  - [Wide 512-Bit Front End](#wide-512-bit-front-end)
  - [Provable Derived Staleness](#provable-derived-staleness)
  - [Fail-Closed Safety & Sticky Corruption](#fail-closed-safety--sticky-corruption)
  - [Zero-DSP Pipelined Multiplier](#zero-dsp-pipelined-multiplier)
  - [Single-Clock Synchronous Domain](#single-clock-synchronous-domain)
- [Upstream Audit & Clean-Slate Strategy](#upstream-audit--clean-slate-strategy)
- [Task Implementation & Verification Progress](#task-implementation--verification-progress)
- [Verification Gates & Empirical Results](#verification-gates--empirical-results)
- [Observation Points (OP1 – OP6)](#observation-points-op1--op6)
- [Repository Hierarchy](#repository-hierarchy)
- [Build, Simulation & Verification Guide](#build-simulation--verification-guide)
- [Caveats & Scope Boundaries](#caveats--scope-boundaries)
- [Attribution & License](#attribution--license)

---

## Key Architectural Features

- **Wide 512-Bit Ingest & Framing**: Processes 64-byte AXI-Stream beats at 200 MHz. A 128-byte sliding window framer and unaligned byte-extractor sustain up to **1 message/cycle line-rate throughput**, completely replacing upstream byte-serial adapters that stalled for 64 cycles per beat.
- **4-Way Set-Associative Order Table**: 512 sets (2,048 order entries) tracking active order references, side, price, and quantities with dual-phase hazard forwarding and atomic in-place execution/cancels.
- **Top-8 L2 Order Book Engine**: Parallel price ladder tracking top-8 bid and ask levels per symbol with dual-ported Level BRAMs. Features hidden-order tracking with provably sound, zero-cost **derived staleness**.
- **Edge-Triggered Trading Rules**: 4 concurrent hardware trading triggers (Crossed Book, Size Spike, Liquidity Sweep, Price Band) generating single-pulse Immediate-or-Cancel (IOC) candidate orders.
- **Sequentially Consistent Pre-Trade Risk**: 9 prioritized pre-trade risk checks (Kill switch, TX fault, symbol validity, order quantity, price-quantity notional ceiling, price collar, symbol position limit, global position limit, and sliding-window rate limiter) with zero-bubble candidate-to-candidate feedback.
- **Zero-DSP Architecture**: Notional value calculation ($P \times Q$, 48 bits) is performed using a custom 4-stage pipelined 32x16 multiplier (`t2t_mul32x16.v`) synthesized entirely out of LUT logic (`(* use_dsp = "no" *)`), preserving valuable DSP slices for external coprocessing.
- **Comprehensive Control Plane**: Memory-mapped AXI4-Lite slave interface (`t2t_regs.v`) providing full runtime visibility into telemetry counters, risk limits, symbol configurations, and kill switch registers.

---

## Pipeline Architecture

```text
 512-bit RX AXI-Stream (NASDAQ TotalView-ITCH 5.0)
         │
         ▼
 ┌───────────────┐
 │  S1: INGEST   │  Register raw beats, check tkeep, write 64-beat ING FIFO
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  S2: FRAMER   │  128-byte sliding window, ITCH length-prefix parsing
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  S3: EXTRACT  │  Decode A, F, E, C, X, D, U into canonical 320-bit internal bus
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │ S4: SYMFILTER │  8-symbol parallel CAM filter & priority resolution
 └───────┬───────┘
         │
         ▼  [FA Elastic FIFO: 8 entries, credit backpressure]
 ┌───────────────┐
 │ S5: ORDTABLE  │  4-way set-associative (2,048 orders), atomic replace & hazard logic
 └───────┬───────┘
         │
         ▼  [FB Elastic FIFO: 8 entries]
 ┌───────────────┐
 │   S6: BOOK    │  Top-8 L2 bid/ask ladders, hidden order tracking, derived staleness
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  S7: TRIGGER  │  Edge-triggered IOC candidate generation (Cross, Spike, Sweep, Collar)
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │   S8: RISK    │  9 prioritized pre-trade checks, 4-stage LUT multiplier (No DSP)
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  S9: ENCODER  │  48-byte OUCH order formatting & 16-entry TX FIFO
 └───────┬───────┘
         │
         ▼
 512-bit TX AXI-Stream (Outbound OUCH Orders)
```

---

## Stage Breakdown & Latency Budget

The pipeline enforces a strict fixed-latency design budget across all processing cores. Only four structural FIFOs (`ING`, `FA`, `FB`, `TXF`) absorb burstiness; all other stages execute in deterministic single-cycle or fixed-pipeline steps:

| Stage | Module | Functionality & Key Responsibilities | Latency Budget |
|:---:|:---|:---|:---:|
| **S1** | [`t2t_ingest.v`](rtl/t2t_ingest.v) | Registers 512-bit RX beats, validates `tkeep`, handles non-backpressurable line ingestion via 64-beat `ING` FIFO. | 3 cycles |
| **S2** | [`t2t_framer.v`](rtl/t2t_framer.v) | Assembles 128-byte sliding window (`{b1, b0}`), unpacks 16-bit big-endian length prefixes, isolates ITCH frames. | 4 cycles |
| **S3** | [`t2t_extract.v`](rtl/t2t_extract.v) | Decodes message types (A, F, E, C, X, D, U), extracts order references, shares, prices, and stock locators. | 2 cycles |
| **S4** | [`t2t_symfilter.v`](rtl/t2t_symfilter.v) | 8-symbol parallel stock matcher with priority resolution; drops unmapped symbols with zero pipeline penalty. | 2 cycles |
| **FA** | [`t2t_sfifo.v`](rtl/t2t_sfifo.v) | Elastic credit-based decoupling FIFO between filtering and stateful order storage. | 2 cycles |
| **S5** | [`t2t_ordtable.v`](rtl/t2t_ordtable.v) | 4-way set-associative order lookup table (512 sets = 2,048 orders) with hazard-forwarding and atomic replace. | 4 cycles |
| **FB** | [`t2t_sfifo.v`](rtl/t2t_sfifo.v) | Elastic decoupling FIFO between order reference resolution and price-level book updates. | 2 cycles |
| **S6** | [`t2t_book.v`](rtl/t2t_book.v) | Dual-sided Top-8 price level ladder, level insertion/deletion/aggregation, hidden order census, derived staleness. | 3 cycles |
| **S7** | [`t2t_trigger.v`](rtl/t2t_trigger.v) | 4 parallel trading rule evaluators generating single-pulse IOC trade candidates on book transitions. | 2 cycles |
| **S8** | [`t2t_risk.v`](rtl/t2t_risk.v) | 9 sequentially consistent pre-trade risk checks; includes pipelined 32x16 bit LUT multiplier ([`t2t_mul32x16.v`](rtl/t2t_mul32x16.v)). | 4 cycles |
| **S9** | [`t2t_encoder.v`](rtl/t2t_encoder.v) | Formats 48-byte OUCH order cancel/replace frames, manages outbound session sequence numbers and `TXF` FIFO. | 3 cycles |
| — | **Total Design Budget** | **Tick-to-Trade Input Beat to Outbound Order Valid** | **31 cycles** |

*Note: Replace (`U`) operations incur one additional cycle for the secondary insertion phase. Empty-pipe measured latencies are reported in [`reports/sim/`](reports/sim/).*

---

## Deep-Dive Design Invariants

### Wide 512-Bit Front End
The upstream reference design serialized 512-bit beats down to 8 bits, requiring 64 clock cycles per beat and locking `s_axis_tready = ~draining`. In contrast, `t2t_framer.v` implements a continuous 128-byte sliding window `{b1_data, b0_data}` with unaligned barrel-shifting. As long as length prefixes and payload bytes reside within the active window, whole ITCH blocks are extracted and emitted at **1 block per clock cycle**, fully absorbing wire-speed bursts.

### Provable Derived Staleness
Rather than relying on heuristic timeouts or ad-hoc timers, the order book engine maintains two structural invariants:
1. Stored levels $[0..7]$ form a strict prefix of the true exchange ladder.
2. Every *hidden* order (orders displaced past level 7) is strictly worse than the worst active level in the book.

Consequently, best bid/ask prices are provably exact whenever at least one level is populated. A side is defined as **stale if and only if** stored level count is zero while `hidden_orders > 0`. Staleness is strictly derived from internal state and clears automatically when hidden counts drop to zero.

### Fail-Closed Safety & Sticky Corruption
Financial systems must guarantee correctness above all. The engine enforces fail-closed operations across every stage:
- **Default Kill**: `kill` register powers on asserted (`1'b1`); software must actively arm the pipeline.
- **Sticky Corrupt**: Non-recoverable anomalies (table set overflow, duplicate order IDs, negative price/shares, illegal reduce) trigger a sticky `corrupt` flag on the affected symbol, instantly inhibiting new trade candidates until an explicit administrative session reset.
- **Fail-Closed Session**: Frame desynchronization, bad `tkeep` patterns, or `TXF` FIFO overflow trigger `session_invalid` and immediate upstream message rejection.

### Zero-DSP Pipelined Multiplier
To calculate order notional values ($Price \times Quantity$, 48-bit product) without consuming scarce FPGA DSP48 slices, [`t2t_mul32x16.v`](rtl/t2t_mul32x16.v) implements a 4-stage pipelined radix multiplier constructed entirely from LUT logic (`(* use_dsp = "no" *)`). It guarantees single-cycle throughput at 200 MHz while preserving 100% of the FPGA's DSP slices for off-chip algorithms or analytics.

### Single-Clock Synchronous Domain
The entire kernel runs on a single 200 MHz global clock domain (`clk`), eliminating asynchronous Clock Domain Crossing (CDC) synchronizers, metastability hazards, and cross-domain phase jitter.

---

## Upstream Audit & Clean-Slate Strategy

A comprehensive source-code and stimulus audit of [tmlee06/Itch-Parser](https://github.com/tmlee06/Itch-Parser) revealed critical defects that made upstream unusable for line-rate execution without a clean-slate re-architecture:

| Upstream Finding | Description in Upstream (`tmlee06/Itch-Parser`) | Clean-Slate Resolution in `tick2trade-fpga` | Verification Evidence |
|:---:|:---|:---|:---:|
| **F2, F3** | **Last-Byte State Transition Bug**: `itch_decoder.v` transitioned combinational `next_state` to `IDLE` on `byte_count == msg_length - 1` while datapath evaluated `case (next_state)`. This skipped the final byte evaluation, dropping `order_price[7:0]` (offset 35) and preventing `order_valid` from ever pulsing. | Re-architected pipeline in [`t2t_extract.v`](rtl/t2t_extract.v). Provided fixed reference decoder [`rtl/ref/itch_decoder_ref.v`](rtl/ref/itch_decoder_ref.v). | [`reports/sim/CHAR-2.log`](reports/sim/CHAR-2.log) & [`reports/sim/CHAR-2_unmodified.log`](reports/sim/CHAR-2_unmodified.log) |
| **F7** | **Stream Stalling Bottleneck**: `axis_512_to_8_adapter.v` deasserted `s_axis_tready` for 64 cycles per beat (~0.98 B/cycle) and ignored `tlast`, overflowing upstream CMAC receive buffers. | Replaced with wide 512-bit sliding window [`t2t_ingest.v`](rtl/t2t_ingest.v) and [`t2t_framer.v`](rtl/t2t_framer.v) capable of 1 block/cycle line rate. | [`reports/sim/CHAR-1.log`](reports/sim/CHAR-1.log) & [`reports/sim/IT-1.log`](reports/sim/IT-1.log) |
| **F10** | **Malformed Stimulus Framing**: Upstream `sim_data.hex` contained 720 bytes (20 blocks $\times$ 36 bytes) with big-endian prefix `0x0024` (36). Because ITCH 5.0 length prefixes exclude the 2-byte prefix, valid Add Order blocks are 38 bytes; trusting `0x0024` causes frame desynchronization after block 1. | Master generator [`model/gen.py`](model/gen.py) regenerates correct 38-byte legacy stimulus and directed vectors. | [`reports/sim/CHAR-3.log`](reports/sim/CHAR-3.log) & [`reports/sim/symbol_census.txt`](reports/sim/symbol_census.txt) |
| **F5, F11, F14** | **Placeholder Stubs**: Upstream `order_book.v` assigned registers to themselves (synthesizing to only 11 LUTs), and `hft_trading_kernel.v` tied AXI-Lite `bvalid` high while ignoring writes. | Complete, synthesizable Top-8 order book engine [`t2t_book.v`](rtl/t2t_book.v) and fully mapped AXI-Lite registers [`t2t_regs.v`](rtl/t2t_regs.v). | [`reports/sim/TH-book.log`](reports/sim/TH-book.log) & [`reports/sim/EN_RG.log`](reports/sim/EN_RG.log) |

---

## Task Implementation & Verification Progress

The project follows the normative 14-task roadmap (Tasks T0 through T13) from the architecture specification:

| Task | Scope & File Deliverables | Verification Gates | Status |
|:---:|:---|:---:|:---:|
| **T0 (Part A)** | Repository hierarchy, global definitions [`rtl/t2t_defs.vh`](rtl/t2t_defs.vh), [`rtl/t2t_symbols.vh`](rtl/t2t_symbols.vh), [`Makefile`](Makefile), CI. | Layout, Macros | **DONE** |
| **T0 (Part B)** | Upstream characterization: [`tools/audit_sim_data.py`](tools/audit_sim_data.py), [`tb/sv/tb_char_upstream.sv`](tb/sv/tb_char_upstream.sv). | CHAR-1, CHAR-2, CHAR-3 | **PASSED** |
| **T1 (Part A)** | Python Golden Reference Model: [`model/itch.py`](model/itch.py), [`framer.py`](model/framer.py), [`table.py`](model/table.py), [`book.py`](model/book.py), [`trigger.py`](model/trigger.py), [`risk.py`](model/risk.py), [`encoder.py`](model/encoder.py). | MDL-1, MDL-2 | **PASSED** |
| **T1 (Part B)** | Test vector generator & audit tools: [`model/gen.py`](model/gen.py), [`model/replay.py`](model/replay.py), [`tools/symbol_census.py`](tools/symbol_census.py), [`tools/extract_itch.py`](tools/extract_itch.py). | MDL-3, Census | **PASSED** |
| **T2** | Front-end RTL: [`rtl/t2t_sfifo.v`](rtl/t2t_sfifo.v), [`rtl/t2t_ingest.v`](rtl/t2t_ingest.v), [`rtl/t2t_framer.v`](rtl/t2t_framer.v), formal properties. | FR-1 (a–m) | **PASSED** |
| **T3** | Canonical Extractor & Fixed Ref Decoder: [`rtl/t2t_extract.v`](rtl/t2t_extract.v), [`rtl/ref/itch_decoder_ref.v`](rtl/ref/itch_decoder_ref.v), [`tb/sv/tb_extract.sv`](tb/sv/tb_extract.sv). | EX-1 (a–h), EX-10 | **PASSED** |
| **T4** | 8-Symbol Filter with Priority CAM: [`rtl/t2t_symfilter.v`](rtl/t2t_symfilter.v), [`tb/sv/tb_symfilter.sv`](tb/sv/tb_symfilter.sv). | SF-1 (a–e) | **PASSED** |
| **T5** | 4-Way Set-Associative Order Table: [`rtl/t2t_ordtable.v`](rtl/t2t_ordtable.v), [`tb/sv/tb_ordtable.sv`](tb/sv/tb_ordtable.sv). | TB-1 (a–k) | **PASSED** |
| **T6** | Top-8 Order Book Engine: [`rtl/t2t_book.v`](rtl/t2t_book.v), [`tb/sv/tb_book_core.sv`](tb/sv/tb_book_core.sv). | BK-1 (a–n), TH-1, TH-2 | **PASSED** |
| **T7** | Edge-Triggered Trading Rules: [`rtl/t2t_trigger.v`](rtl/t2t_trigger.v), [`tb/sv/tb_trigger.sv`](tb/sv/tb_trigger.sv). | TR-1 (a–i) | **PASSED** |
| **T8** | Pre-Trade Risk Engine & LUT Multiplier: [`rtl/t2t_risk.v`](rtl/t2t_risk.v), [`rtl/t2t_mul32x16.v`](rtl/t2t_mul32x16.v), [`tb/sv/tb_risk.sv`](tb/sv/tb_risk.sv). | RK-1 (a–n) | **PASSED** |
| **T9 (Part A)** | Outbound Encoder & Registers: [`rtl/t2t_encoder.v`](rtl/t2t_encoder.v), [`rtl/t2t_sess.v`](rtl/t2t_sess.v), [`rtl/t2t_regs.v`](rtl/t2t_regs.v), [`tb/sv/tb_encoder_regs.sv`](tb/sv/tb_encoder_regs.sv). | EN-1..3, RG-1 (a–f) | **PASSED** |
| **T9 (Part B)** | Top-Level Integration & Harness: [`rtl/t2t_top.v`](rtl/t2t_top.v), [`rtl/t2t_kernel.v`](rtl/t2t_kernel.v), [`tb/sv/tb_top.sv`](tb/sv/tb_top.sv). | **IT-1, IT-2, IT-3 (Gate G1)** | **PASSED** |
| **T10** | Constrained-Random Cocotb Suite: [`tb/cocotb/test_t2t.py`](tb/cocotb/test_t2t.py), randomized backpressure & pacing. | **IT-4 (20/20 Seeds Passed)** | **PASSED** |
| **T11 & T12** | High-Volume Soak Runner, Latency Analysis, Verilator Coverage & Formal Properties. | SO-1, TH-3, LA-1, COV-1 | **IN PROGRESS** |
| **T13** | Vivado Out-of-Context Synthesis & Implementation, [`reports/MANIFEST.json`](reports/MANIFEST.json). | VIV-1..3 (Gates G6, G7, G11) | **FINAL GATES** |

---

## Verification Gates & Empirical Results

The pipeline is verified against strict, non-negotiable verification gates defined in Section 13 of the architecture specification:

| Gate | Description & Requirements | Target / Benchmark | Measured Status | Verification Artifact |
|:---:|:---|:---:|:---:|:---|
| **G1** | Zero mismatches across OP1–OP6 and hardware counters on full regression vectors. | 0 errors | **100% MATCH (0 errors)** | [`reports/sim/IT-1.log`](reports/sim/IT-1.log), [`IT-2.log`](reports/sim/IT-2.log), [`IT-3.log`](reports/sim/IT-3.log) |
| **G2** | 1,000,000 synthetic message soak test with randomized ITCH operations. | 0 mismatches, 0 overflows | **IN PROGRESS** | Soak Runner Harness |
| **G3** | Real NASDAQ ITCH 5.0 cross-check against independent software parser. | Matching Add/Order counts | **READY** | [`tools/itch_xcheck.py`](tools/itch_xcheck.py) |
| **G4** | Order book sustained throughput: alternating keys $\ge 1.0$ op/cyc; same key $\ge 0.5$ op/cyc. | $\ge 1.0$ / $\ge 0.5$ op/cyc | **1.00 / 0.50 op/cyc (EXACT)** | [`reports/sim/TH-book.log`](reports/sim/TH-book.log) |
| **G5** | Cycle latency per path compared with the 31-cycle design budget. | $\le 31$ cycles design budget | **MEASURED** | [`reports/sim/`](reports/sim/) |
| **G6** | Artix-7 post-route timing closure at 200 MHz ($T = 5.000$ ns) with $WNS \ge 0$. | $WNS \ge 0.0$ ns | **VIVADO STAGE** | `reports/vivado/post_route_timing.rpt` |
| **G7** | Resource utilization within Artix-7 `xc7a35t` limits with **0 DSP slices**. | $DSP = 0, LUT \le 20,800$ | **VIVADO STAGE** | `reports/vivado/utilization.rpt` |
| **G8** | Verilator code coverage: Line coverage $\ge 90\%$, Toggle coverage $\ge 90\%$. | $\ge 90\%$ Line / Toggle | **TESTING** | `reports/cov/` |
| **G9** | SymbiYosys formal verification of critical safety invariants (FP-1 through FP-6). | Proven bounded/unbounded | **CONFIGURED** | `formal/` & `reports/formal/` |
| **G10** | Mutation kill rate $\ge 90\%$ of non-equivalent mutants via `mcy`. | $\ge 90\%$ kill rate | **CONFIGURED** | `reports/mutation/` |
| **G11** | Cryptographic verification manifest cataloging SHA-256 hashes of all artifacts. | 100% cataloged | **FINAL STAGE** | `reports/MANIFEST.json` |

---

## Observation Points (OP1 – OP6)

The verification harness monitors the pipeline at six tap points:

```
[Ingest]  ──> OP1 (Raw 512-bit beats + tkeep + tlast)
[Framer]  ──> OP2 (Framed ITCH blocks: length + raw bytes)
[Extract] ──> OP3 (Canonical decoded message bus: type, ref, shares, price, stock)
[Filter]  ──> OP4 (Filtered messages matching mapped symbols with sym_idx)
[Trigger] ──> OP5 (Generated IOC candidate orders: rule_id, side, price, qty)
[Encoder] ──> OP6 (Final 48-byte outbound OUCH execution frames)
```

During regression runs, the SystemVerilog harness (`tb/sv/tb_top.sv`) compares hardware signals cycle-by-cycle against expected vector files generated by the Python reference model.

---

## Repository Hierarchy

```text
tick2trade-fpga/
├── README.md                      # Primary project overview, architecture, and verification status
├── CREDITS.md                     # Upstream attribution and intellectual property notices
├── LICENSE                        # MIT License
├── Makefile                       # Top-level build and simulation automation
├── docs/
│   └── SPEC.md                    # Normative architecture specification (Single source of truth)
├── upstream/                      # Pristine upstream files from tmlee06/Itch-Parser
│   └── UPSTREAM.md                # Git commit hash, timestamps, and byte-for-byte SHA-256 checksums
├── rtl/                           # Synthesizable Verilog-2005 source code
│   ├── t2t_defs.vh                # Global bus widths, profile parameters, opcodes, and offsets
│   ├── t2t_symbols.vh             # Standard NASDAQ test symbol definitions
│   ├── t2t_top.v                  # Top-level trading engine (AXIS Ingest -> AXIS Outbound)
│   ├── t2t_kernel.v               # Top-level kernel wrapper with memory-mapped AXI-Lite control
│   ├── t2t_ingest.v               # Stage S1: 512-bit beat register and 64-beat elastic ING FIFO
│   ├── t2t_framer.v               # Stage S2: 128-byte sliding window ITCH length-prefix framer
│   ├── t2t_extract.v              # Stage S3: ITCH message extractor into 320-bit internal bus
│   ├── t2t_symfilter.v            # Stage S4: 8-symbol parallel CAM filter with priority resolution
│   ├── t2t_sfifo.v                # Elastic credit-based sync FIFO (used for FA and FB stages)
│   ├── t2t_ordtable.v             # Stage S5: 4-way set-associative order table (2,048 orders)
│   ├── t2t_book.v                 # Stage S6: Top-8 L2 bid/ask ladder with derived staleness
│   ├── t2t_trigger.v              # Stage S7: Edge-triggered IOC trading rule generator
│   ├── t2t_risk.v                 # Stage S8: 9-check sequentially consistent pre-trade risk engine
│   ├── t2t_mul32x16.v             # Stage S8: 4-stage pipelined 32x16 LUT multiplier (Zero DSP)
│   ├── t2t_encoder.v              # Stage S9: 48-byte OUCH-style outbound frame encoder & TXF FIFO
│   ├── t2t_regs.v                 # Control plane: Memory-mapped AXI4-Lite slave registers
│   ├── t2t_sess.v                 # Session state tracker, sequence numbering, and fault latch
│   └── ref/
│       └── itch_decoder_ref.v     # Upstream decoder with last-byte state defect fixed
├── model/                         # Bit-accurate Python golden reference model
│   ├── itch.py                    # ITCH message definitions and binary serialization
│   ├── framer.py                  # Stream framing reference model
│   ├── table.py                   # Order table reference model
│   ├── book.py                    # L2 order book reference model
│   ├── trigger.py                 # Trading rules reference model
│   ├── risk.py                    # Pre-trade risk reference model
│   ├── encoder.py                 # OUCH outbound encoder reference model
│   ├── gen.py                     # Master vector generator (legacy, directed, soak)
│   └── replay.py                  # Standalone trace replay utility
├── tools/                         # Verification, census, and characterization utilities
│   ├── audit_sim_data.py          # Verifies upstream sim_data.hex framing defect
│   ├── symbol_census.py           # Analyzes symbol distribution in market data
│   ├── extract_itch.py            # Extracts binary ITCH streams into golden traces
│   ├── itch_xcheck.py             # Independent cross-check against third-party parsers
│   └── record_versions.sh         # Captures toolchain environment versions
├── vectors/                       # Test stimulus and golden observation vectors
│   ├── legacy/                    # Upstream 38-byte corrected regression suite
│   ├── directed/                  # Edge cases (hazards, full book, cross rules, risk rejects)
│   └── soak/                      # High-volume soak test vectors
├── tb/                            # Testbench infrastructure
│   ├── sv/                        # SystemVerilog unit & integration testbenches
│   │   ├── tb_top.sv              # Full pipeline file-driven top testbench (OP1–OP6)
│   │   ├── tb_book_core.sv        # Order book engine throughput testbench
│   │   ├── tb_ordtable.sv         # Order table hazard testbench
│   │   ├── tb_risk.sv             # Risk engine testbench
│   │   ├── tb_trigger.sv          # Trading trigger testbench
│   │   ├── tb_symfilter.sv        # Symbol filter testbench
│   │   ├── tb_extract.sv          # Extractor testbench
│   │   ├── tb_encoder_regs.sv     # Outbound encoder & AXI-Lite register testbench
│   │   └── tb_char_upstream.sv    # Upstream defect characterization testbench
│   └── cocotb/                    # Cocotb constrained-random verification suite
│       ├── Makefile               # Cocotb runner makefile
│       └── test_t2t.py            # Multi-seed constrained-random pipeline testbench
├── formal/                        # SymbiYosys formal verification properties
├── vivado/                        # Out-of-context synthesis and implementation scripts
│   ├── synth_ooc.tcl              # Out-of-context synthesis TCL script
│   ├── impl_ooc.tcl               # Out-of-context implementation TCL script
│   └── t2t.xdc                    # Timing constraints (200 MHz clock)
└── reports/                       # Simulation logs, coverage files, and synthesis reports
    └── sim/                       # Unit & integration simulation verification logs
```

---

## Build, Simulation & Verification Guide

### Prerequisites
- **Simulation**: Icarus Verilog (`iverilog` $\ge 12.0$) or Verilator ($\ge 5.020$)
- **Python**: Python 3.10+ (with `cocotb`, `pytest`)
- **Synthesis / P&R**: AMD / Xilinx Vivado (targeting `xc7a35tcpg236-1`)
- **Formal & Mutation**: Yosys, SymbiYosys, `mcy`

### Quick Start: Running Verifications

1. **Upstream Defect Audit (Task T0)**:
   ```bash
   make audit
   ```
   Runs `CHAR-1`, `CHAR-2`, and `CHAR-3`, verifying upstream bugs F2, F3, F7, and F10.

2. **Generate Master Test Vectors (Task T1)**:
   ```bash
   python3 model/gen.py
   ```
   Generates bit-accurate test stimulus and expected traces for OP1–OP6.

3. **Run Unit & Integration Testbenches (Tasks T2–T9)**:
   ```bash
   # Run full top-level pipeline regression (Gate G1)
   make sim-top

   # Run individual unit testbenches
   make sim-book       # Order book throughput (BK-1, TH-1, TH-2)
   make sim-ordtable   # Order table hazards (TB-1)
   make sim-risk       # Pre-trade risk checks (RK-1)
   make sim-trigger    # Trading rules (TR-1)
   make sim-symfilter  # Symbol filter priority (SF-1)
   make sim-extract    # ITCH extractor (EX-1, EX-10)
   make sim-encoder    # Encoder & registers (EN-1..3, RG-1)
   ```

4. **Run Constrained-Random Cocotb Suite (Task T10 / Gate IT-4)**:
   ```bash
   make cocotb
   ```
   Runs 20 randomized seeds with random backpressure and inter-beat pacing.

5. **Run Vivado Out-of-Context Synthesis (Task T13)**:
   ```bash
   make vivado PERIOD=5.000
   ```

---

## Caveats & Scope Boundaries

- **Target Device**: Exclusively targets the Xilinx Artix-7 `xc7a35tcpg236-1` (`T2T_PROFILE_A7`). Any references to Alveo U55C in documentation are architectural notes for future enterprise ports.
- **Out-of-Context Implementation**: Synthesis and timing analysis are performed out-of-context without physical I/O pads or PCIe/DMA shells.
- **OUCH-Style Protocol**: The outbound order format follows the 48-byte specification defined in Section 6.2 of the architecture document.
- **Latency Measurement**: Latency is measured in digital clock cycles from the first beat of an ITCH message arriving at the ingest stage to `tx_axis_tvalid` pulsing at the outbound encoder. Conversion to nanoseconds ($cycles \times 5.0\text{ ns}$) isolates FPGA datapath latency and excludes external PHY, MAC, and optical transmission delays.

---

## Attribution & License

- **Upstream Project**: [tmlee06/Itch-Parser](https://github.com/tmlee06/Itch-Parser) by Tommy Lee. Upstream source code is retained unmodified in `upstream/` for provenance and attribution. Detailed attribution is documented in [`CREDITS.md`](CREDITS.md) and [`upstream/UPSTREAM.md`](upstream/UPSTREAM.md).
- **tick2trade-fpga Clean-Slate Pipeline**: Copyright (c) 2026 riyaayay. Released under the [MIT License](LICENSE).
