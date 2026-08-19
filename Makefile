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
MDV_RTL  := $(I960)/i960_muldiv.sv
FPM_RTL  := $(I960)/i960_fpmul.sv
FPA_RTL  := $(I960)/i960_fpadd.sv
FPD_RTL  := $(I960)/i960_fpdiv.sv
FPS_RTL  := $(I960)/i960_fpsqrt.sv
FPX_RTL  := $(I960)/i960_fpmisc.sv
FPC_RTL  := $(I960)/i960_fpcvt.sv
# The assembled CPU. Order matters only for readability; Quartus resolves by name.
TOP_RTL  := $(DEC_RTL) $(ALU_RTL) $(REG_RTL) $(AGU_RTL) $(LST_RTL) \
            $(LSU_RTL) $(MAP_RTL) $(ICA_RTL) $(MDV_RTL) \
            $(FPM_RTL) $(FPA_RTL) $(FPD_RTL) $(FPS_RTL) $(FPX_RTL) $(FPC_RTL) \
            $(I960)/i960_top.sv

TEST_ARGS := $(if $(RANDOM),+random=$(RANDOM),) $(if $(SEED),+seed=$(SEED),)

.PHONY: all lint synth test clean distclean
all: lint synth test

# --------------------------------------------------------------------- lint

.PHONY: lint lint_i960_dec lint_i960_alu lint_i960_regs lint_i960_agu lint_i960_ldst lint_i960_lsu lint_i960_memmap lint_i960_icache lint_i960_muldiv lint_i960_fpmul lint_i960_fpadd lint_i960_fpdiv lint_i960_fpsqrt lint_i960_fpmisc lint_i960_fpcvt lint_i960_top
lint: lint_i960_dec lint_i960_alu lint_i960_regs lint_i960_agu lint_i960_ldst lint_i960_lsu lint_i960_memmap lint_i960_icache lint_i960_muldiv lint_i960_fpmul lint_i960_fpadd lint_i960_fpdiv lint_i960_fpsqrt lint_i960_fpmisc lint_i960_fpcvt lint_i960_top

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

lint_i960_muldiv:
	@echo "== lint i960_muldiv"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_muldiv $(MDV_RTL)

lint_i960_fpmul:
	@echo "== lint i960_fpmul"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpmul $(FPM_RTL)

lint_i960_fpadd:
	@echo "== lint i960_fpadd"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpadd $(FPA_RTL)

lint_i960_fpdiv:
	@echo "== lint i960_fpdiv"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpdiv $(FPD_RTL)

lint_i960_fpsqrt:
	@echo "== lint i960_fpsqrt"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpsqrt $(FPS_RTL)

lint_i960_fpmisc:
	@echo "== lint i960_fpmisc"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpmisc $(FPX_RTL)

lint_i960_fpcvt:
	@echo "== lint i960_fpcvt"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_fpcvt $(FPC_RTL)

lint_i960_top:
	@echo "== lint i960_top"
	$(VERILATOR) --lint-only $(VFLAGS) --top-module i960_top $(TOP_RTL)

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

.PHONY: test test_m2_romload test_m2_sdram test_m2_video_timing test_i960_dec test_i960_alu test_i960_alu_carrybug test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache test_i960_muldiv test_i960_fpmul test_i960_fpadd test_i960_fpdiv test_i960_fpsqrt test_i960_fpmisc test_i960_fpcvt test_i960_top
test: test_m2_romload test_m2_sdram test_m2_video_timing test_i960_dec test_i960_alu test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache test_i960_muldiv test_i960_fpmul test_i960_fpadd test_i960_fpdiv test_i960_fpsqrt test_i960_fpmisc test_i960_fpcvt test_i960_top

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

test_i960_muldiv: obj_i960_muldiv/Vi960_muldiv
	@echo "== test i960_muldiv"
	./obj_i960_muldiv/Vi960_muldiv $(TEST_ARGS)

obj_i960_muldiv/Vi960_muldiv: $(MDV_RTL) $(TB)/tb_i960_muldiv.cpp $(TB)/i960_muldiv_ref.h
	$(VBUILD) --top-module i960_muldiv -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_muldiv -o Vi960_muldiv $(MDV_RTL) $(TB)/tb_i960_muldiv.cpp

test_i960_fpmul: obj_i960_fpmul/Vi960_fpmul
	@echo "== test i960_fpmul"
	./obj_i960_fpmul/Vi960_fpmul $(TEST_ARGS)

obj_i960_fpmul/Vi960_fpmul: $(FPM_RTL) $(TB)/tb_i960_fpmul.cpp
	$(VBUILD) --top-module i960_fpmul -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpmul -o Vi960_fpmul $(FPM_RTL) $(TB)/tb_i960_fpmul.cpp

test_i960_fpadd: obj_i960_fpadd/Vi960_fpadd
	@echo "== test i960_fpadd"
	./obj_i960_fpadd/Vi960_fpadd $(TEST_ARGS)

obj_i960_fpadd/Vi960_fpadd: $(FPA_RTL) $(TB)/tb_i960_fpadd.cpp
	$(VBUILD) --top-module i960_fpadd -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpadd -o Vi960_fpadd $(FPA_RTL) $(TB)/tb_i960_fpadd.cpp

test_i960_fpdiv: obj_i960_fpdiv/Vi960_fpdiv
	@echo "== test i960_fpdiv"
	./obj_i960_fpdiv/Vi960_fpdiv $(TEST_ARGS)

obj_i960_fpdiv/Vi960_fpdiv: $(FPD_RTL) $(TB)/tb_i960_fpdiv.cpp
	$(VBUILD) --top-module i960_fpdiv -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpdiv -o Vi960_fpdiv $(FPD_RTL) $(TB)/tb_i960_fpdiv.cpp

test_i960_fpsqrt: obj_i960_fpsqrt/Vi960_fpsqrt
	@echo "== test i960_fpsqrt"
	./obj_i960_fpsqrt/Vi960_fpsqrt $(TEST_ARGS)

obj_i960_fpsqrt/Vi960_fpsqrt: $(FPS_RTL) $(TB)/tb_i960_fpsqrt.cpp
	$(VBUILD) --top-module i960_fpsqrt -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpsqrt -o Vi960_fpsqrt $(FPS_RTL) $(TB)/tb_i960_fpsqrt.cpp

test_i960_fpmisc: obj_i960_fpmisc/Vi960_fpmisc
	@echo "== test i960_fpmisc"
	./obj_i960_fpmisc/Vi960_fpmisc $(TEST_ARGS)

obj_i960_fpmisc/Vi960_fpmisc: $(FPX_RTL) $(TB)/tb_i960_fpmisc.cpp
	$(VBUILD) --top-module i960_fpmisc -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpmisc -o Vi960_fpmisc $(FPX_RTL) $(TB)/tb_i960_fpmisc.cpp

test_i960_fpcvt: obj_i960_fpcvt/Vi960_fpcvt
	@echo "== test i960_fpcvt"
	./obj_i960_fpcvt/Vi960_fpcvt $(TEST_ARGS)

obj_i960_fpcvt/Vi960_fpcvt: $(FPC_RTL) $(TB)/tb_i960_fpcvt.cpp
	$(VBUILD) --top-module i960_fpcvt -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_fpcvt -o Vi960_fpcvt $(FPC_RTL) $(TB)/tb_i960_fpcvt.cpp

# The controller against a device MODEL, lifted with it. This is how the ROM
# readback gets diagnosed without spending a 25-minute build per hypothesis.
test_m2_sdram: obj_m2_sdram/Vm2_sdram_harness
	@echo "== test m2_sdram (controller against the device model)"
	./obj_m2_sdram/Vm2_sdram_harness

obj_m2_sdram/Vm2_sdram_harness: $(SDR_RTL) sim/mem/tb_m2_sdram.cpp
	$(VBUILD) --top-module m2_sdram_harness -CFLAGS "-O2 -I../sim/mem" \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
	  --Mdir obj_m2_sdram -o Vm2_sdram_harness $(SDR_RTL) sim/mem/tb_m2_sdram.cpp

test_m2_romload: obj_m2_romload/Vm2_romload_harness
	@echo "== test m2_romload (ioctl -> loader -> sdram -> readback)"
	./obj_m2_romload/Vm2_romload_harness

obj_m2_romload/Vm2_romload_harness: $(RLD_RTL) sim/mem/tb_m2_romload.cpp
	$(VBUILD) --top-module m2_romload_harness -CFLAGS "-O2 -I../sim/mem" \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
	  -Wno-PINCONNECTEMPTY \
	  --Mdir obj_m2_romload -o Vm2_romload_harness $(RLD_RTL) sim/mem/tb_m2_romload.cpp

test_m2_video_timing: obj_m2_vt/Vm2_video_timing
	@echo "== test m2_video_timing (against MAME set_raw)"
	./obj_m2_vt/Vm2_video_timing

obj_m2_vt/Vm2_video_timing: $(VID_RTL) sim/video/tb_m2_video_timing.cpp
	$(VBUILD) --top-module m2_video_timing -CFLAGS "-O2" \
	  --Mdir obj_m2_vt -o Vm2_video_timing $(VID_RTL) sim/video/tb_m2_video_timing.cpp

lint_m2_video_timing lint_m2_testpattern:
	@verilator --lint-only -Wall -Wno-DECLFILENAME $(SRCS_$(@:lint_%=%))

test_i960_top: obj_i960_top/Vi960_top
	@echo "== test i960_top (whole-CPU lockstep)"
	./obj_i960_top/Vi960_top $(TEST_ARGS)

# --public-flat-rw exposes the register file so lockstep can read architectural
# state without adding debug ports that would change what is measured.
obj_i960_top/Vi960_top: $(TOP_RTL) $(TB)/tb_i960_top.cpp $(TB)/i960_cpu_ref.h
	$(VBUILD) --top-module i960_top --public-flat-rw -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_top -o Vi960_top $(TOP_RTL) $(TB)/tb_i960_top.cpp

# ------------------------------------------------------------------- quartus
#
# 17.0.0 Build 595 only. 24.1std is installed on this machine and must not
# build the core: the MiSTer framework targets 17.0.x and inference behaviour
# differs between versions. Re-run map, not just fit — a fit-only rerun reuses
# the previous netlist and reports success for a setting that breaks the build.

.PHONY: quartus quartus_all quartus_report quartus_paths
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
SRCS_i960_muldiv := $(MDV_RTL)
SRCS_i960_fpmul  := $(FPM_RTL)
SRCS_i960_fpadd  := $(FPA_RTL)
SRCS_i960_fpdiv  := $(FPD_RTL)
SRCS_i960_fpsqrt := $(FPS_RTL)
SRCS_i960_fpmisc := $(FPX_RTL)
SRCS_i960_fpcvt  := $(FPC_RTL)
SRCS_i960_top    := $(TOP_RTL)
VID_RTL := rtl/video/m2_video_timing.sv
SRCS_m2_video_timing := $(VID_RTL)
SRCS_m2_testpattern  := rtl/video/m2_testpattern.sv
SDR_RTL := rtl/mem/m2_sdram.sv rtl/mem/bw_monitor.sv sim/mem/sdram_model.sv sim/mem/m2_sdram_harness.sv
RLD_RTL := rtl/mem/m2_sdram.sv rtl/io/m2_rom_loader.sv sim/mem/sdram_model.sv sim/mem/m2_romload_harness.sv
SRCS_m2_sdram := rtl/mem/m2_sdram.sv

# ---------------------------------------------------------------------------
# M2-E proxies: third-party cores measured on THIS part, for area only.
#
# Not our code and never will be -- srg320/Saturn carries NO LICENCE, so this
# is measurement and reading only (THIRD_PARTY.md, design study 5.3/R6).
# Compiling locally to count ALMs is not distribution; copying a line of it
# would be.
#
# SCSP is the prize: Model 2 uses the SAME chip, so this is a direct
# measurement of a Model 2 block rather than a proxy, replacing a from-scratch
# 3,000-5,000 ALM estimate. VDP1 is a quad rasterizer like Model 2's, but with
# no Z-buffer, no mipmapping and no filtering, so it bounds the renderer from
# BELOW where the N64 RDP's 8,347 bounds it from above.
SAT := third_party/saturn
SRCS_SCSP := $(SAT)/SCSP/SCSP_pkg.sv $(SAT)/SCSP/SCSP.sv
SRCS_VDP1 := $(SAT)/VDP1/VDP1_pkg.sv $(SAT)/VDP1/VDP1.sv
SRCS_VDP2 := $(SAT)/VDP2/VDP2_pkg.sv $(SAT)/VDP2/VDP2_MEM.sv $(SAT)/VDP2/VDP2.sv

# Third-party blocks measured to replace budget ESTIMATES with figures on this
# part, through this flow. None of this code ships; it is measured because an
# estimate with no anchor is the weakest row in the budget.
#
#   fx68k     the sound 68000 we intend to port (GPL-3.0, THIRD_PARTY.md)
#   MB86233   Model 1's geometry coprocessor, from tools/model1-ref. Model 2's
#             MB86234 is the same family, so this bounds a row that has only ever
#             carried a 3,000-5,000 estimate. READ ONLY: the build directory is
#             ours, nothing is written inside the reference clone.
FX  := third_party/fx68k
M1R := tools/model1-ref/rtl/tgp
SRCS_fx68k    := $(FX)/uaddrPla.sv $(FX)/fx68kAlu.sv $(FX)/fx68k.sv
SRCS_mb86233_core := $(M1R)/mb86233_pkg.sv $(M1R)/fp_add.sv $(M1R)/fp_mul.sv \
                 $(M1R)/fp_div.sv $(M1R)/mb86233_dec.sv $(M1R)/mb86233_alu.sv \
                 $(M1R)/mb86233_agu.sv $(M1R)/mb86233_regs.sv $(M1R)/mb86233_mem.sv \
                 $(M1R)/mb86233_xfer.sv $(M1R)/mb86233_seq.sv $(M1R)/mb86233_core.sv

# Rule 8's lint gate exists to stop OUR unlintable RTL reaching the fitter. It
# is meaningless against code we neither own nor may modify, so these targets
# elaborate rather than lint -- enough to prove the fitter is being handed
# something real, without pretending we can fix what it reports.
# These instantiate Altera megafunctions (altsyncram), which verilator cannot
# elaborate without the vendor libraries and Quartus instantiates natively. So
# there is no pre-fitter check available for them at all, and saying so is
# better than running a command that always passes. The figure these produce is
# an AREA MEASUREMENT of somebody else's verified core -- it is not evidence
# about anything we wrote, and rule 8 still applies in full to rtl/.
lint_SCSP lint_VDP1 lint_VDP2 lint_fx68k lint_mb86233_core:
	@echo "== $(@:lint_%=%): third-party, area measurement only"
	@echo "   no pre-fitter check possible (Altera megafunctions); rule 8 unaffected"


QUARTUS_MODS := i960_dec i960_alu i960_regs i960_agu i960_ldst i960_lsu i960_memmap i960_icache i960_muldiv i960_fpmul i960_fpadd i960_fpdiv i960_fpsqrt i960_fpmisc i960_fpcvt i960_top

# One module, real device, real toolchain. This is the only thing that gives
# ALM, M10K and DSP — yosys gives LUT6, which is an indicator and not the same
# currency. Model 1 measured fp_mul at 1312 LUT6 and 144 ALM because the
# multiplier left the fabric into a DSP block.
# Rule 8 is enforced here rather than remembered. Quartus accepts width
# mismatches that verilator rejects, so RTL that cannot lint can still produce
# a plausible-looking ALM figure from a design that would never work — which is
# exactly how an invalid frame-width comparison got measured and briefly
# believed. Lint first, always.
quartus: lint_$(MOD)
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

# Where the critical path actually runs. The STA summary gives slack and Fmax
# but not endpoints, and Model 1's M0 recorded attributing a miss to the wrong
# stage once — retiming there would have cost a pipeline stage and moved Fmax by
# nothing. Run this before touching anything for timing.
quartus_paths:
	@test -d $(QDIR) || { echo "run 'make quartus MOD=$(MOD)' first"; exit 1; }
	@cd $(QDIR) && $(QUARTUS)/quartus_sta -t ../../../quartus/report_timing.tcl $(MOD) 2>&1 \
	  | grep -E 'SLACK|FROM|TO ' | head -12

quartus_report:
	@printf '%-12s ' "$(MOD)"
	@alm=$$(grep -m1 'Logic utilization (in ALMs)' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 reg=$$(grep -m1 'Total registers' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *;.*/\1/'); \
	 m10k=$$(grep -m1 'M10K blocks' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 dsp=$$(grep -m1 'Total DSP Blocks' $(QDIR)/output_files/$(MOD).fit.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *\/.*/\1/'); \
	 fmax=$$(grep -A3 '; Fmax  *; Restricted Fmax' $(QDIR)/output_files/$(MOD).sta.rpt 2>/dev/null | grep -m1 -oE '^; [0-9]+\.[0-9]+ MHz' | grep -oE '[0-9.]+'); \
	 mlab=$$(grep -m1 'Total MLAB memory bits' $(QDIR)/output_files/$(MOD).map.rpt 2>/dev/null | sed 's/.*; *\([0-9,]*\) *;.*/\1/'); \
	 printf 'ALM %-7s reg %-6s M10K %-4s MLABbits %-6s DSP %-3s Fmax %s\n' "$${alm:-?}" "$${reg:-?}" "$${m10k:-0}" "$${mlab:-0}" "$${dsp:-?}" "$${fmax:-comb (no clock)}"

# --------------------------------------------------------------------- release
# Gather the .rbf and the .mra into one tree laid out the way MiSTer expects, so
# flashing is a copy rather than an assembly job. Two arrangements, because the
# core is currently useful in both:
#
#   Model2.rbf            top level -- launch it DIRECTLY from the MiSTer menu.
#                         This is the one to use today: steps 1-3 need no ROM,
#                         and a bare .rbf placed where the menu browses is listed.
#   _Arcade/*.mra         the arcade flow, for when the loader has something to
#   _Arcade/cores/*.rbf   load. `_Arcade/cores` is NOT browsed directly -- those
#                         cores launch via their .mra.
#
# The .rbf is a build artifact and stays out of git; the .mra is tracked, because
# a file describing a ROM layout is fine and the bytes are not.
RELEASE := build/release

.PHONY: release
release:
	@test -f output_files/Model2.rbf || { \
	  echo "no output_files/Model2.rbf -- run: quartus_sh --flow compile Model2"; exit 1; }
	@rm -rf $(RELEASE)
	@mkdir -p $(RELEASE)/_Arcade/cores
	@cp output_files/Model2.rbf $(RELEASE)/Model2.rbf
	@cp output_files/Model2.rbf $(RELEASE)/_Arcade/cores/Model2.rbf
	@cp mra/*.mra $(RELEASE)/_Arcade/
	@echo "release tree in $(RELEASE):"
	@cd $(RELEASE) && find . -type f | sort | sed 's/^/  /'
	@echo ""
	@echo "  TODAY (no ROM needed): copy Model2.rbf to /media/fat/_Other/ and run it."
	@echo "  Overlay must read  word2=000001A8  word3=000001F0  -- MAME set_raw."
	@echo ""
	@echo "  The .mra is NOT usable yet: the loader has no consumer, and the full"
	@echo "  ROM set is 43.62 MB against the 32 MB this controller addresses."
	@echo "  See docs/rom-layout.md."

# --------------------------------------------------------------------- clean

clean:
	rm -rf obj_*

distclean: clean
	rm -rf db incremental_db output_files simulation greybox_tmp
