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
AGU_RTL  := $(I960)/i960_agu.sv
LST_RTL  := $(I960)/i960_ldst.sv
LSU_RTL  := $(I960)/i960_lsu.sv
MAP_RTL  := $(I960)/i960_memmap.sv
ICA_RTL  := $(I960)/i960_icache.sv

TEST_ARGS := $(if $(RANDOM),+random=$(RANDOM),) $(if $(SEED),+seed=$(SEED),)

.PHONY: all lint synth test clean distclean
all: lint synth test

# --------------------------------------------------------------------- lint

.PHONY: lint lint_i960_dec lint_i960_alu lint_i960_regs lint_i960_agu lint_i960_ldst lint_i960_lsu lint_i960_memmap lint_i960_icache
lint: lint_i960_dec lint_i960_alu lint_i960_regs lint_i960_agu lint_i960_ldst lint_i960_lsu lint_i960_memmap lint_i960_icache

lint_i960_dec:
	@echo "== lint i960_dec"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_dec $(DEC_RTL)

lint_i960_alu:
	@echo "== lint i960_alu"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_alu $(ALU_RTL)

lint_i960_regs:
	@echo "== lint i960_regs"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_regs $(REG_RTL)

lint_i960_agu:
	@echo "== lint i960_agu"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_agu $(AGU_RTL)

lint_i960_ldst:
	@echo "== lint i960_ldst"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_ldst $(LST_RTL)

lint_i960_lsu:
	@echo "== lint i960_lsu"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_lsu $(LSU_RTL)

lint_i960_memmap:
	@echo "== lint i960_memmap"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_memmap $(MAP_RTL)

lint_i960_icache:
	@echo "== lint i960_icache"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_icache $(ICA_RTL)

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

.PHONY: synth synth_i960_dec synth_i960_alu synth_i960_regs synth_i960_agu synth_i960_ldst
synth: synth_i960_dec synth_i960_alu synth_i960_regs synth_i960_agu synth_i960_ldst

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

synth_i960_agu:
	@echo "== synth i960_agu (yosys portability check)"
	@$(YOSYS) -p "read_verilog -sv $(AGU_RTL); hierarchy -top i960_agu; proc; opt; techmap; opt; abc -lut 6; opt; stat" 2>/dev/null \
	  | sed -n '/Local Count/,/^$$/p' | grep -E 'cells|lut|memor' || true

synth_i960_ldst:
	@echo "== synth i960_ldst (yosys portability check)"
	@$(YOSYS) -p "read_verilog -sv $(LST_RTL); hierarchy -top i960_ldst; proc; opt; techmap; opt; abc -lut 6; opt; stat" 2>/dev/null \
	  | sed -n '/Local Count/,/^$$/p' | grep -E 'cells|lut|memor' || true

# --------------------------------------------------------------------- tests

.PHONY: test test_i960_dec test_i960_alu test_i960_alu_carrybug test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache
test: test_i960_dec test_i960_alu test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache

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

test_i960_agu: obj_i960_agu/Vi960_agu
	@echo "== test i960_agu"
	./obj_i960_agu/Vi960_agu $(TEST_ARGS)

obj_i960_agu/Vi960_agu: $(AGU_RTL) $(TB)/tb_i960_agu.cpp $(TB)/i960_agu_ref.h
	$(VBUILD) --top-module i960_agu -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_agu -o Vi960_agu $(AGU_RTL) $(TB)/tb_i960_agu.cpp

test_i960_ldst: obj_i960_ldst/Vi960_ldst
	@echo "== test i960_ldst"
	./obj_i960_ldst/Vi960_ldst $(TEST_ARGS)

obj_i960_ldst/Vi960_ldst: $(LST_RTL) $(TB)/tb_i960_ldst.cpp $(TB)/i960_ldst_ref.h
	$(VBUILD) --top-module i960_ldst -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_ldst -o Vi960_ldst $(LST_RTL) $(TB)/tb_i960_ldst.cpp

test_i960_lsu: obj_i960_lsu/Vi960_lsu
	@echo "== test i960_lsu"
	./obj_i960_lsu/Vi960_lsu $(TEST_ARGS)

obj_i960_lsu/Vi960_lsu: $(LSU_RTL) $(TB)/tb_i960_lsu.cpp $(TB)/i960_lsu_ref.h
	$(VBUILD) --top-module i960_lsu -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_lsu -o Vi960_lsu $(LSU_RTL) $(TB)/tb_i960_lsu.cpp

test_i960_icache: obj_i960_icache/Vi960_icache
	@echo "== test i960_icache"
	./obj_i960_icache/Vi960_icache $(TEST_ARGS)

obj_i960_icache/Vi960_icache: $(ICA_RTL) $(TB)/tb_i960_icache.cpp
	$(VBUILD) --top-module i960_icache -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_icache -o Vi960_icache $(ICA_RTL) $(TB)/tb_i960_icache.cpp

# ------------------------------------------------------------------- quartus
#
# 17.0.0 Build 595 only. 24.1std is installed on this machine and must not
# build the core: the MiSTer framework targets 17.0.x and inference behaviour
# differs between versions. Re-run map, not just fit — a fit-only rerun reuses
# the previous netlist and reports success for a setting that breaks the build.

.PHONY: quartus quartus_all quartus_report
MOD  ?= i960_alu
QDIR := build/quartus/$(MOD)

SRCS_i960_dec  := $(DEC_RTL)
SRCS_i960_alu  := $(ALU_RTL)
SRCS_i960_regs := $(REG_RTL)
SRCS_i960_agu  := $(AGU_RTL)
SRCS_i960_ldst := $(LST_RTL)
SRCS_i960_lsu  := $(LSU_RTL)
SRCS_i960_memmap := $(MAP_RTL)
SRCS_i960_icache := $(ICA_RTL)

QUARTUS_MODS := i960_dec i960_alu i960_regs i960_agu i960_ldst i960_lsu i960_memmap i960_icache

# One module, real device, real toolchain. This is the only thing that gives
# ALM, M10K and DSP — yosys gives LUT6, which is an indicator and not the same
# currency. Model 1 measured fp_mul at 1312 LUT6 and 144 ALM because the
# multiplier left the fabric into a DSP block.
quartus:
	@test -x $(QUARTUS)/quartus_map || { echo "Quartus 17.0 not found at $(QUARTUS)"; exit 1; }
	@mkdir -p $(QDIR)
	@srcs=""; for f in $(SRCS_$(MOD)); do \
	  srcs="$$srcs\nset_global_assignment -name SYSTEMVERILOG_FILE ../../../$$f"; done; \
	  sed -e 's/@MODULE@/$(MOD)/g' -e "s|@SRCS@|$$srcs|" quartus/spike.qsf.in > $(QDIR)/$(MOD).qsf
	@cp quartus/spike.sdc $(QDIR)/spike.sdc
	@echo 'PROJECT_REVISION = "$(MOD)"' > $(QDIR)/$(MOD).qpf
	@cd $(QDIR) && PATH="$(QUARTUS)):$$PATH" sh -c \
	   '$(QUARTUS)/quartus_map $(MOD) >map.log 2>&1 && \
	    $(QUARTUS)/quartus_fit $(MOD) >fit.log 2>&1 && \
	    $(QUARTUS)/quartus_sta $(MOD) >sta.log 2>&1' \
	  || { echo "FAILED — see $(QDIR)/*.log"; tail -5 $(QDIR)/map.log $(QDIR)/fit.log 2>/dev/null; exit 1; }
	@$(MAKE) --no-print-directory quartus_report MOD=$(MOD)

# Always re-run map, never fit alone: a fit-only rerun reuses the previous
# netlist and reports success for a setting that actually breaks the build.
quartus_all:
	@for m in $(QUARTUS_MODS); do $(MAKE) --no-print-directory quartus MOD=$$m || exit 1; done

quartus_report:
	@printf '%-12s ' "$(MOD)"
	@alm=$$(grep -m1 'Logic utilization (in ALMs)' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 reg=$$(grep -m1 'Total registers' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *;.*/\1/'); \
	 m10k=$$(grep -m1 'Total block memory bits' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 dsp=$$(grep -m1 'Total DSP Blocks' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 fmax=$$(grep -A3 '; Fmax  *; Restricted Fmax' $(QDIR)/output_files/$(MOD).sta.rpt 2>/dev/null | grep -m1 -oE '^; [0-9]+\.[0-9]+ MHz' | grep -oE '[0-9.]+'); \
	 mlab=$$(grep -m1 'Total MLAB memory bits' $(QDIR)/output_files/$(MOD).map.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *;.*/\1/'); \
	 printf 'ALM %-7s reg %-6s MLABbits %-6s DSP %-3s Fmax %s\n' "$${alm:-?}" "$${reg:-?}" "$${mlab:-0}" "$${dsp:-?}" "$${fmax:-comb (no clock)}"

# --------------------------------------------------------------------- clean

clean:
	rm -rf obj_*

distclean: clean
	rm -rf db incremental_db output_files simulation greybox_tmp
