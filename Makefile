# ==============================================================================
# File        : Makefile
# Spec Section: 14.2
# Description : Master build, audit, simulation, soak, coverage, formal,
#               mutation, and Vivado OOC implementation runner.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# ==============================================================================

SHELL := /bin/bash
PYTHON ?= PYTHONPATH=. python3
VERILATOR ?= verilator
IVERILOG ?= iverilog
VVP ?= vvp
SBY ?= sby
YOSYS ?= yosys
VIVADO ?= vivado

PROFILE ?= T2T_PROFILE_A7
PERIOD ?=

RTL_DIR := rtl
UPSTREAM_DIR := upstream
TB_SV_DIR := tb/sv
MODEL_DIR := model
TOOLS_DIR := tools
REPORTS_DIR := reports

RTL_SRCS := \
	$(RTL_DIR)/t2t_sfifo.v \
	$(RTL_DIR)/t2t_ingest.v \
	$(RTL_DIR)/t2t_framer.v \
	$(RTL_DIR)/t2t_extract.v \
	$(RTL_DIR)/t2t_symfilter.v \
	$(RTL_DIR)/t2t_ordtable.v \
	$(RTL_DIR)/t2t_book.v \
	$(RTL_DIR)/t2t_trigger.v \
	$(RTL_DIR)/t2t_mul32x16.v \
	$(RTL_DIR)/t2t_risk.v \
	$(RTL_DIR)/t2t_encoder.v \
	$(RTL_DIR)/t2t_sess.v \
	$(RTL_DIR)/t2t_regs.v \
	$(RTL_DIR)/t2t_top.v \
	$(RTL_DIR)/t2t_kernel.v

VERILATOR_FLAGS := --binary --timing -Wall -Wno-UNUSED -Wno-UNDRIVEN \
	-Wno-EOFNEWLINE -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -Wno-DECLFILENAME \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-INITIALDLY \
	-I$(RTL_DIR) -D$(PROFILE)

.PHONY: all audit model_test sim soak cov formal mutation synth_est vivado clean

all: audit sim

# ------------------------------------------------------------------------------
# Task T0: Upstream Characterisation & Tool Audit (CHAR-1, CHAR-2, CHAR-3)
# ------------------------------------------------------------------------------
audit:
	@echo "=== [T0] Recording Tool Versions ==="
	@bash $(TOOLS_DIR)/record_versions.sh
	@echo "=== [T0] Running CHAR-3: sim_data.hex Audit ==="
	@$(PYTHON) $(TOOLS_DIR)/audit_sim_data.py \
		--input $(UPSTREAM_DIR)/sim_data.hex \
		--output $(REPORTS_DIR)/sim/CHAR-3.log
	@echo "=== [T0] Running CHAR-1: Unmodified Upstream Adapter TB ==="
	@$(IVERILOG) -g2005 -o $(REPORTS_DIR)/sim/char1.vvp \
		$(UPSTREAM_DIR)/axis_512_to_8_adapter.v \
		$(UPSTREAM_DIR)/tb_axis_adapter.v
	@$(VVP) $(REPORTS_DIR)/sim/char1.vvp | tee $(REPORTS_DIR)/sim/CHAR-1.log
	@grep -q "PASS" $(REPORTS_DIR)/sim/CHAR-1.log
	@echo "=== [T0] Running CHAR-2: Upstream Decoder Unmodified & Instrumented ==="
	@cp -f $(UPSTREAM_DIR)/sim_data.hex ./sim_data.hex
	@$(VERILATOR) --binary --timing -Wno-fatal \
		$(UPSTREAM_DIR)/itch_decoder.v \
		$(UPSTREAM_DIR)/order_book.v \
		$(UPSTREAM_DIR)/top_parser_to_lab.v \
		$(UPSTREAM_DIR)/tb_itch_decoder_real_data.v \
		--top tb_itch_decoder_real_data \
		-o Vtb_itch_decoder_real_data
	@./obj_dir/Vtb_itch_decoder_real_data | tee $(REPORTS_DIR)/sim/CHAR-2_unmodified.log
	@$(IVERILOG) -g2012 -o $(REPORTS_DIR)/sim/char2_inst.vvp \
		$(UPSTREAM_DIR)/itch_decoder.v \
		$(TB_SV_DIR)/tb_char_upstream.sv
	@$(VVP) $(REPORTS_DIR)/sim/char2_inst.vvp | tee $(REPORTS_DIR)/sim/CHAR-2.log
	@rm -f ./sim_data.hex $(REPORTS_DIR)/sim/*.vvp

# ------------------------------------------------------------------------------
# Task T1: Golden Reference Model & Vector Generation (MDL-1, MDL-2, MDL-3)
# ------------------------------------------------------------------------------
model_test:
	@$(PYTHON) $(MODEL_DIR)/gen.py --suite directed --out-dir vectors/directed
	@$(PYTHON) $(MODEL_DIR)/gen.py --suite legacy --out-dir vectors/legacy

# ------------------------------------------------------------------------------
# Task T2-T10: Directed, Reference-Mode & Cocotb Regression (G1, G4)
# ------------------------------------------------------------------------------
sim: model_test
	@echo "=== [SIM] Building & Running Reference-Mode Cross-Check (EX-10) ==="
	@$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_refmode \
		$(UPSTREAM_DIR)/axis_512_to_8_adapter.v \
		$(RTL_DIR)/ref/itch_decoder_ref.v \
		$(RTL_DIR)/t2t_sfifo.v \
		$(RTL_DIR)/t2t_ingest.v \
		$(RTL_DIR)/t2t_framer.v \
		$(RTL_DIR)/t2t_extract.v \
		$(TB_SV_DIR)/tb_refmode.sv \
		-o Vtb_refmode
	@./obj_dir/Vtb_refmode | tee $(REPORTS_DIR)/sim/EX-10.log
	@echo "=== [SIM] Building & Running Book Core Throughput Bench (TH-1, TH-2) ==="
	@$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_book_core \
		$(RTL_DIR)/t2t_book.v \
		$(TB_SV_DIR)/tb_book_core.sv \
		-o Vtb_book_core
	@./obj_dir/Vtb_book_core | tee $(REPORTS_DIR)/sim/TH-book.log
	@echo "=== [SIM] Building & Running Full Pipeline Regression (tb_top) ==="
	@$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_top \
		$(RTL_SRCS) $(TB_SV_DIR)/tb_top.sv \
		-o Vtb_top
	@./obj_dir/Vtb_top +SUITE=directed | tee $(REPORTS_DIR)/sim/IT-1.log
	@./obj_dir/Vtb_top +SUITE=legacy | tee $(REPORTS_DIR)/sim/IT-2.log
	@./obj_dir/Vtb_top +TEST=IT-3 | tee $(REPORTS_DIR)/sim/IT-3.log

# ------------------------------------------------------------------------------
# Task T10: Constrained-Random Cocotb Suite (Gate IT-4)
# ------------------------------------------------------------------------------
cocotb:
	@echo "=== [COCOTB] Running Constrained-Random Verification (IT-4: 20 Seeds) ==="
	@export PATH=/home/riya/.local/bin:$$PATH && \
		$(MAKE) -C tb/cocotb SIM=icarus | tee $(REPORTS_DIR)/sim/IT-4.log

# ------------------------------------------------------------------------------
# Task T11: 1,000,000-Message Soak & Real ITCH Replay (G2, G3, G5)
# ------------------------------------------------------------------------------
soak:
	@$(PYTHON) $(MODEL_DIR)/gen.py --suite soak --out-dir vectors/soak
	@$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_top \
		$(RTL_SRCS) $(TB_SV_DIR)/tb_top.sv \
		-o Vtb_top_soak
	@./obj_dir/Vtb_top_soak +SUITE=soak | tee $(REPORTS_DIR)/sim/soak.log

# ------------------------------------------------------------------------------
# Task T12: Line + Toggle Coverage (G8), SymbiYosys Formal (G9), Mutation (G10)
# ------------------------------------------------------------------------------
cov:
	@$(VERILATOR) $(VERILATOR_FLAGS) --coverage-line --coverage-toggle \
		--top-module tb_top $(RTL_SRCS) $(TB_SV_DIR)/tb_top.sv -o Vtb_top_cov
	@./obj_dir/Vtb_top_cov +SUITE=directed
	@verilator_coverage --annotate $(REPORTS_DIR)/cov/annotated \
		--write-info $(REPORTS_DIR)/cov/coverage.info coverage.dat

formal:
	@for sby_file in formal/*.sby; do \
		echo "=== [FORMAL] Running $$sby_file ==="; \
		$(SBY) -f "$$sby_file"; \
	done

mutation:
	@bash scripts/run_mutation.sh

# ------------------------------------------------------------------------------
# Task T13: Yosys Gate Estimate (G7e) & Vivado OOC Implementation (G6, G7, G11)
# ------------------------------------------------------------------------------
synth_est:
	@$(YOSYS) -p "read_verilog -I$(RTL_DIR) $(RTL_SRCS); synth_xilinx -top t2t_top; stat" \
		| tee $(REPORTS_DIR)/synth/yosys_stat.txt

vivado:
	@if [ -n "$(PERIOD)" ]; then \
		$(VIVADO) -mode batch -nojournal -nolog -source vivado/impl_ooc.tcl -tclargs $(PERIOD); \
	else \
		$(VIVADO) -mode batch -nojournal -nolog -source vivado/impl_ooc.tcl -tclargs 5.000; \
		$(VIVADO) -mode batch -nojournal -nolog -source vivado/impl_ooc.tcl -tclargs 6.667; \
	fi
	@$(PYTHON) scripts/parse_reports.py

clean:
	rm -rf obj_dir simv* *.vcd *.fst coverage.dat $(REPORTS_DIR)/sim/*.vvp