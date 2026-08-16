# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Rule 8: nothing reaches the fitter until it is clean here. A Quartus build is
# the most expensive way to find an error.
#
#   make lint          lint every RTL module
#   make test          every module fuzz test
#   make test_i960_dec one module
#   make quartus       core build (17.0.0 only)
#
# RANDOM= overrides the random-vector count, SEED= the seed. Both exist so a
# failure can be replayed exactly and so a suspicious pass can be re-run an
# order of magnitude deeper without editing anything.

VERILATOR ?= verilator
QUARTUS   ?= /home/ben/intelFPGA_lite/17.0/quartus/bin
RANDOM    ?=
SEED      ?=

RTL_DIR := rtl
SIM_DIR := sim

# -Wall plus the ones that actually catch encoding bugs. UNUSED is NOT
# suppressed globally: an unused decoder output usually means a field was
# extracted and then forgotten, which is exactly the bug class here.
VFLAGS := -Wall -Wno-DECLFILENAME --timing

I960_RTL := $(RTL_DIR)/cpu/i960/i960_pkg.sv $(RTL_DIR)/cpu/i960/i960_dec.sv

.PHONY: all lint test clean distclean
all: lint test

# --------------------------------------------------------------------- lint

lint: lint_i960_dec

.PHONY: lint_i960_dec
lint_i960_dec:
	@echo "== lint i960_dec"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_dec $(I960_RTL)

# --------------------------------------------------------------------- tests

TEST_ARGS := $(if $(RANDOM),+random=$(RANDOM),) $(if $(SEED),+seed=$(SEED),)

test: test_i960_dec

.PHONY: test_i960_dec
test_i960_dec: obj_i960_dec/Vi960_dec
	@echo "== test i960_dec"
	./obj_i960_dec/Vi960_dec $(TEST_ARGS)

obj_i960_dec/Vi960_dec: $(I960_RTL) $(SIM_DIR)/i960/tb_i960_dec.cpp $(SIM_DIR)/i960/i960_dec_ref.h
	$(VERILATOR) --cc --exe --build -j 0 $(VFLAGS) \
	  --top-module i960_dec \
	  -CFLAGS "-O2 -I../$(SIM_DIR)/i960" \
	  --Mdir obj_i960_dec \
	  -o Vi960_dec \
	  $(I960_RTL) $(SIM_DIR)/i960/tb_i960_dec.cpp

# ------------------------------------------------------------------- quartus
#
# 17.0.0 Build 595 only. 24.1std is installed on this machine and must not
# build the core: the MiSTer framework targets 17.0.x and inference behaviour
# differs between versions. Re-run map, not just fit — a fit-only rerun reuses
# the previous netlist and reports success for a setting that breaks the build.

.PHONY: quartus
quartus:
	@test -x $(QUARTUS)/quartus_sh || { echo "Quartus 17.0 not found at $(QUARTUS)"; exit 1; }
	@echo "no Quartus project yet — P1 reaches this at spike stage (M2-D)"; exit 1

# --------------------------------------------------------------------- clean

clean:
	rm -rf obj_*

distclean: clean
	rm -rf db incremental_db output_files simulation greybox_tmp
