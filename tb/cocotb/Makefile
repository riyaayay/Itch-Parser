# ==============================================================================
# File        : tb/cocotb/Makefile
# Spec Section: 12.2 (IT-4), 14.1, 15 (Task T10)
# Description : Cocotb Makefile targeting Verilator for constrained-random suite.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# ==============================================================================

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

PWD = $(shell pwd)
REPO_ROOT = $(PWD)/../..

VERILOG_SOURCES = \
    $(REPO_ROOT)/rtl/t2t_sfifo.v \
    $(REPO_ROOT)/rtl/t2t_ingest.v \
    $(REPO_ROOT)/rtl/t2t_framer.v \
    $(REPO_ROOT)/rtl/t2t_extract.v \
    $(REPO_ROOT)/rtl/t2t_symfilter.v \
    $(REPO_ROOT)/rtl/t2t_ordtable.v \
    $(REPO_ROOT)/rtl/t2t_book.v \
    $(REPO_ROOT)/rtl/t2t_trigger.v \
    $(REPO_ROOT)/rtl/t2t_mul32x16.v \
    $(REPO_ROOT)/rtl/t2t_risk.v \
    $(REPO_ROOT)/rtl/t2t_encoder.v \
    $(REPO_ROOT)/rtl/t2t_sess.v \
    $(REPO_ROOT)/rtl/t2t_regs.v \
    $(REPO_ROOT)/rtl/t2t_top.v

TOPLEVEL = t2t_top
MODULE   = test_t2t
COCOTB_TEST_MODULES = test_t2t

ifeq ($(SIM),verilator)
EXTRA_ARGS += -I$(REPO_ROOT)/rtl -DT2T_PROFILE_A7 --timing
EXTRA_ARGS += -Wno-UNUSED -Wno-UNDRIVEN -Wno-EOFNEWLINE -Wno-SYNCASYNCNET \
              -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -Wno-DECLFILENAME \
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-INITIALDLY
else
COMPILE_ARGS += -I$(REPO_ROOT)/rtl -DT2T_PROFILE_A7 -g2012
endif

export PYTHONPATH := $(REPO_ROOT):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
