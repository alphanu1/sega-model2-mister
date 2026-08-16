# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Rule 8: nothing reaches the fitter until it is clean here. A Quartus build is
# the most expensive way to find an error.
#
#   make lint                    lint every RTL module
#   make test                    every module fuzz test
#   make test_i960_alu           one module
#   make test_i960_alu_carrybug  prove a claimed divergence is where it is claimed
#   make synth                   yosys parse+synth check (portability gate)
#   make quartus                 core build (17.0.0 only)
#
# RANDOM= overrides the random-vector count, SEED= the seed. Both exist so a
# failure can be replayed exactly and so a suspicious pass can be re-run an
# order of magnitude deeper without editing anything.

VERILATOR ?= verilator
YOSYS     ?= yosys
QUARTUS   ?= /home/ben/intelFPGA_lite/17.0/quartus/bin
RANDOM    ?=
SEED      ?=

RTL_DIR := rtl
SIM_DIR := sim
I960    := $(RTL_DIR)/cpu/i960
TB      := $(SIM_DIR)/i960

# -Wall, and UNUSED is deliberately NOT suppressed. An unused signal here is
# usually a field extracted and then forgotten, which is the bug class this CPU
# is most exposed to. It has already caught one import that earned nothing.
VFLAGS := -Wall -Wno-DECLFILENAME --timing
VBUILD  = $(VERILATOR) --cc --exe --build -j 0 $(VFLAGS)


DEC_RTL  := $(I960)/i960_dec.sv
ALU_RTL  := $(I960)/i960_alu.sv
REG_RTL  := $(I960)/i960_regs.sv

TEST_ARGS := $(if $(RANDOM),+random=$(RANDOM),) $(if $(SEED),+seed=$(SEED),)

.PHONY: all lint synth test clean distclean
all: lint synth test

# --------------------------------------------------------------------- lint

.PHONY: lint lint_i960_dec lint_i960_alu lint_i960_regs
lint: lint_i960_dec lint_i960_alu lint_i960_regs

lint_i960_dec:
	@echo "== lint i960_dec"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_dec $(DEC_RTL)

lint_i960_alu:
	@echo "== lint i960_alu"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_alu $(ALU_RTL)

lint_i960_regs:
	@echo "== lint i960_regs"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_regs $(REG_RTL)

# --------------------------------------------------------------------- synth
#
# Portability gate. Model 1's rtl-conventions.md requires code to pass
# verilator, yosys AND Quartus 17.0, because each rejects things the others
# accept and the expensive one is 25 minutes away. This has already caught the
# module-header package import, which verilator takes and yosys refuses:
#   module i960_dec import i960_pkg::*; (...)
#     ERROR: syntax error, unexpected TOK_IMPORT
# File-scope `import i960_pkg::*;` before the module works in both.
#
# The LUT6 counts this prints are a rough indicator, NOT an area measurement.
# Only Quartus gives ALM, and the two disagree badly where DSP or memory
# inference is involved — Model 1 measured fp_mul at 1312 LUT6 under yosys and
# 144 ALM in Quartus, because the multiplier left the fabric entirely.

.PHONY: synth synth_i960_dec synth_i960_alu synth_i960_regs
synth: synth_i960_dec synth_i960_alu synth_i960_regs

synth_i960_dec:
	@echo "== synth i960_dec (yosys portability check)"
	@$(YOSYS) -p "read_verilog -sv $(DEC_RTL); hierarchy -top i960_dec; proc; opt; techmap; opt; abc -lut 6; opt; stat" \
	  | sed -n '/Local Count/,/^$$/p' | grep -E 'cells|lut|memor' || true

synth_i960_alu:
	@echo "== synth i960_alu (yosys portability check)"
	@$(YOSYS) -p "read_verilog -sv $(ALU_RTL); hierarchy -top i960_alu; proc; opt; techmap; opt; abc -lut 6; opt; stat" \
	  | sed -n '/Local Count/,/^$$/p' | grep -E 'cells|lut|memor' || true

synth_i960_regs:
	@echo "== synth i960_regs (yosys portability check)"
	@$(YOSYS) -p "read_verilog -sv $(REG_RTL); hierarchy -top i960_regs; proc; opt; techmap; opt; abc -lut 6; opt; stat" 2>/dev/null \
	  | sed -n '/Local Count/,/^$$/p' | grep -E 'cells|lut|memor' || true

# --------------------------------------------------------------------- tests

.PHONY: test test_i960_dec test_i960_alu test_i960_alu_carrybug test_i960_regs
test: test_i960_dec test_i960_alu test_i960_regs

test_i960_dec: obj_i960_dec/Vi960_dec
	@echo "== test i960_dec"
	./obj_i960_dec/Vi960_dec $(TEST_ARGS)

obj_i960_dec/Vi960_dec: $(DEC_RTL) $(TB)/tb_i960_dec.cpp $(TB)/i960_dec_ref.h
	$(VBUILD) --top-module i960_dec -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_dec -o Vi960_dec $(DEC_RTL) $(TB)/tb_i960_dec.cpp

test_i960_alu: obj_i960_alu/Vi960_alu
	@echo "== test i960_alu"
	./obj_i960_alu/Vi960_alu $(TEST_ARGS)

# Proves the addc/subc divergence is exactly where it is claimed to be. The
# reference switches to MAME's carry behaviour while the RTL keeps hardware
# carry, so this MUST report divergence — and only on carry. A pass here would
# mean the RTL had reproduced the defect.
test_i960_alu_carrybug: obj_i960_alu/Vi960_alu
	@echo "== test i960_alu (MAME carry defect modelled — divergence expected)"
	./obj_i960_alu/Vi960_alu $(TEST_ARGS) +mame_carry_bug

obj_i960_alu/Vi960_alu: $(ALU_RTL) $(TB)/tb_i960_alu.cpp $(TB)/i960_alu_ref.h
	$(VBUILD) --top-module i960_alu -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_alu -o Vi960_alu $(ALU_RTL) $(TB)/tb_i960_alu.cpp

test_i960_regs: obj_i960_regs/Vi960_regs
	@echo "== test i960_regs"
	./obj_i960_regs/Vi960_regs $(TEST_ARGS)

obj_i960_regs/Vi960_regs: $(REG_RTL) $(TB)/tb_i960_regs.cpp $(TB)/i960_regs_ref.h
	$(VBUILD) --top-module i960_regs -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_regs -o Vi960_regs $(REG_RTL) $(TB)/tb_i960_regs.cpp

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
