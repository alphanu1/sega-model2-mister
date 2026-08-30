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
# THE TOP LEVEL WAS NEVER LINTED. `make lint` ran the sixteen i960 modules and
# nothing else, so every "lint clean" reported here was a statement about the
# CPU and said nothing whatever about Model2.sv -- which is where every
# integration bug in this project has actually been.
#
# It cost four builds of unusable sound. m2_sound_board's sample ports changed
# from byte addresses to four-word bursts and Model2.sv was not updated with
# them, so a 19-bit output drove a 22-bit wire: the burst index landed in the
# low bits, p_addr then took [21:3] of a value that was already shifted and
# divided it by eight a second time, and the byte select indexed off a burst
# index. Both sample chips read the wrong address and the wrong byte out of it.
#
# Verilator names that exactly -- "Output port connection 'pcm1_rom_addr'
# expects 19 bits on the pin connection, but pin connection's VARREF
# 'pcm1_addr' generates 22 bits" -- and this target was written by REINTRODUCING
# the bug and checking the message appears, rather than by assuming it would.
#
# Only PORT CONNECTION width mismatches fail the build, and only in our own
# files. The third-party cores carry their own internal width warnings by the
# dozen; holding them to our standard would mean waiving the whole class, which
# is how this one got through.
TOP_RTL := $(shell grep -oE "rtl/[a-z0-9_/]+\.(sv|v)" Model2.qsf | tr '\n' ' ')

.PHONY: lint_top
lint_top:
	@echo "== lint Model2.sv and everything it instantiates"
	@verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-fatal --top-module emu \
	  -Irtl/sound/jt12 $(TOP_RTL) Model2.sv 2>&1 \
	  | grep -E "port connection" \
	  | grep -vE "rtl/sound/(jt12|fx68k)/|rtl/sound/m2_multipcm" > .lint_top.tmp || true
	@if [ -s .lint_top.tmp ]; then \
	  echo "PORT WIDTH MISMATCH -- this is the class that cost four builds:"; \
	  cat .lint_top.tmp; rm -f .lint_top.tmp; exit 1; \
	 else echo "  no port width mismatches"; rm -f .lint_top.tmp; fi

lint: lint_top lint_i960_dec lint_i960_alu lint_i960_regs lint_i960_agu lint_i960_ldst lint_i960_lsu lint_i960_memmap lint_i960_icache lint_i960_muldiv lint_i960_fpmul lint_i960_fpadd lint_i960_fpdiv lint_i960_fpsqrt lint_i960_fpmisc lint_i960_fpcvt lint_i960_top

# THE PLL IS LINTED TOO, and it was not until a build failed.
#
# rtl/pll/pll.v is plain Verilog wrapping vendor IP, so it sat outside the
# SystemVerilog sweep and nothing checked it. Taking the PLL from three outputs
# to five, `outclk_3` and `outclk_4` were added to the wrapper's port list and
# to the altera_pll instantiation, and missed in TWO places between them: the
# inner module's port list and the wrapper's instantiation of it. Verilog
# creates implicit nets rather than complaining, so both outputs dangled.
#
# Quartus said what had happened -- "created implicit net for outclk_4" -- as a
# WARNING, in a log with 152 of them, and then failed for two other reasons
# further downstream. The lint below turns that into an error before a
# twenty-five minute build.
#
# altera_pll is vendor IP with no source here, so the module is linted with the
# instantiation left unresolved: -Wno-MODMISSING checks this file's own wiring,
# which is exactly what was wrong. UNDRIVEN and UNUSEDSIGNAL follow from the
# same absence -- with the IP unresolved every output it should drive looks
# dead -- and suppressing them does not weaken the check that matters, which is
# IMPLICIT: a name used and never declared.
.PHONY: lint_pll
lint_pll:
	@echo "== lint pll"
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MODMISSING -Wno-UNDRIVEN \
	  -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY --top-module pll rtl/pll/pll.v


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

.PHONY: test test_m2_sndboard test_m2_romload test_m2_sdram test_m2_sdram128 test_m2_video_timing test_i960_dec test_i960_alu test_i960_alu_carrybug test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache test_i960_muldiv test_i960_fpmul test_i960_fpadd test_i960_fpdiv test_i960_fpsqrt test_i960_fpmisc test_i960_fpcvt test_i960_top test_i960_top_irq test_i960_rom test_m2_video_frame test_m2_cpu_bridge test_m2_cpu_sdram test_fx68k test_m2_ioboard
test: test_m2_sndlink test_fx68k test_m2_sndboard test_m2_ioboard test_m2_char_cdc test_m2_char_cache test_m2_sdram_x2 test_m2_romload test_m2_sdram test_m2_sdram128 test_m2_video_timing test_i960_dec test_i960_alu test_i960_regs test_i960_agu test_i960_ldst test_i960_lsu test_i960_icache test_i960_muldiv test_i960_fpmul test_i960_fpadd test_i960_fpdiv test_i960_fpsqrt test_i960_fpmisc test_i960_fpcvt test_i960_top test_i960_top_irq test_i960_rom test_m2_video_frame test_m2_cpu_bridge test_m2_cpu_sdram

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

# The SAME suite at the 128 MB geometry: 11 column bits, which is the only
# decomposition reaching 64M words on the connector's 13 address and 2 bank pins.
# Column maps to A0..A9 then A11, A12, skipping A10 -- the auto-precharge flag,
# and the reason ten column bits taken as [10:1] aliases.
test_m2_sdram128: obj_m2_sdram128/Vm2_sdram_harness
	@echo "== test m2_sdram at the 128 MB geometry (11 column bits)"
	./obj_m2_sdram128/Vm2_sdram_harness

obj_m2_sdram128/Vm2_sdram_harness: $(SDR_RTL) sim/mem/tb_m2_sdram.cpp
	$(VBUILD) --top-module m2_sdram_harness -GCOL_BITS=11 \
	  -CFLAGS "-O2 -I../sim/mem -DTB_COL_BITS=11" \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
	  --Mdir obj_m2_sdram128 -o Vm2_sdram_harness $(SDR_RTL) sim/mem/tb_m2_sdram.cpp

test_m2_romload: obj_m2_romload/Vm2_romload_harness
	@echo "== test m2_romload (ioctl -> loader -> sdram -> readback)"
	./obj_m2_romload/Vm2_romload_harness

obj_m2_romload/Vm2_romload_harness: $(RLD_RTL) sim/mem/tb_m2_romload.cpp
	$(VBUILD) --top-module m2_romload_harness -CFLAGS "-O2 -I../sim/mem" \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
	  -Wno-PINCONNECTEMPTY \
	  --Mdir obj_m2_romload -o Vm2_romload_harness $(RLD_RTL) sim/mem/tb_m2_romload.cpp

JT12_RTL := $(wildcard rtl/sound/jt12/*.v)
SNDB_RTL := rtl/sound/fx68k/fx68k.sv rtl/sound/fx68k/fx68kAlu.sv \
            rtl/sound/fx68k/uaddrPla.sv rtl/sound/m2_i8251.sv \
            $(JT12_RTL) \
            rtl/sound/m2_multipcm.sv rtl/sound/m2_pcm_fetch.sv rtl/sound/m2_pcm_rate.sv \
            rtl/sound/m2_sound_board.sv sim/sound/m2_sndboard_harness.sv

# RUN FROM obj_sndboard. fx68k's microcode and nanocode are $readmemb'd by
# RELATIVE path, so they are found in the working directory or not at all --
# and when they are not, the CPU comes up with an all-zero microword and dies on
# an unrelated-looking `unique case` assertion in the ALU.
test_m2_sndboard: obj_sndboard/Vm2_sndboard_harness
	@echo "== test m2_sndboard (the sound 68000 on the real ROM, against MAME)"
	@cp -f rtl/sound/fx68k/microrom.mem rtl/sound/fx68k/nanorom.mem obj_sndboard/
	@cd obj_sndboard && ./Vm2_sndboard_harness

# fx68k IS UPSTREAM'S, BYTE FOR BYTE, and two flags are what keeps it that way.
#
# THIRD_PARTY.md recorded this as needing "a two-word change" -- packing
# s_irdecod and s_nanod so Verilator accepts the mixed blocking/non-blocking
# writes. It does not. -Wno-BLKANDNBLK accepts the construct as it stands, which
# is better than editing a cycle-exact CPU: nothing to re-apply on an upstream
# bump, and nothing to get subtly wrong.
#
# --no-assert-case is the second. fx68k's ALU has a `unique case` on the
# microword, and before reset is released that word is all zeroes and matches no
# arm. Verilator's runtime check fires at time 0, in the ALU, which reads as a
# decode fault in a CPU that has not started yet. The condition is real and
# harmless; the assertion is what has to go.
#
# The remaining -Wno-* are upstream's own warnings plus the deliberately empty
# pins on a CPU whose FC/BG/E outputs nothing here uses.
obj_sndboard/Vm2_sndboard_harness: $(SNDB_RTL) sim/sound/tb_m2_sndboard.cpp
	$(VBUILD) --top-module m2_sndboard_harness -CFLAGS "-O2" \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
	  -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
	  -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-LATCH \
	  -Wno-BLKANDNBLK -Wno-ALWCOMBORDER --no-assert-case \
	  -Wno-WIDTH -Wno-UNSIGNED -Wno-CMPCONST -Wno-REALCVT -Wno-SELRANGE \
	  -Wno-IMPLICIT -Wno-ASCRANGE -Wno-SIDEEFFECT -Wno-EOFNEWLINE \
	  -Wno-PROCASSINIT -Wno-GENUNNAMED -Irtl/sound/jt12 \
	  --Mdir obj_sndboard -o Vm2_sndboard_harness $(SNDB_RTL) sim/sound/tb_m2_sndboard.cpp

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

# Separate invocation, and deliberately so. `steps` is the PROGRAM LENGTH, so
# raising it changes the working set, the I-cache hit rate and the measured CPI
# the study quotes -- the default run has to keep its configuration. This one
# exists to reach the interrupt paths the default barely touches: at 60 the run
# produced four dequeues and a mutation reversing the priority scan survived.
# +strictcov makes zero coverage on any interrupt path a failure rather than a
# warning.
test_i960_top_irq: obj_i960_top/Vi960_top
	@echo "== test i960_top (interrupt soak)"
	./obj_i960_top/Vi960_top +steps=400 +seed=7 +strictcov

# --public-flat-rw exposes the register file so lockstep can read architectural
# state without adding debug ports that would change what is measured.
obj_i960_top/Vi960_top: $(TOP_RTL) $(TB)/tb_i960_top.cpp $(TB)/i960_cpu_ref.h
	$(VBUILD) --top-module i960_top --public-flat-rw -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_top -o Vi960_top $(TOP_RTL) $(TB)/tb_i960_top.cpp

# Render a whole frame out of m2_video, from the tile/char/palette images our
# own i960 built. Skips when they are absent.
test_m2_video_frame: obj_m2_vf/Vm2_video
	@echo "== test m2_video (frame render)"
	@./obj_m2_vf/Vm2_video $(TEST_ARGS)

M2V_RTL := rtl/video/m2_video_timing.sv rtl/video/m2_tile_decode.sv \
           rtl/video/m2_tile_fetch.sv rtl/video/m2_tile_mixer.sv \
           rtl/video/m2_palette.sv rtl/video/m2_video.sv

obj_m2_vf/Vm2_video: $(M2V_RTL) sim/video/tb_m2_video_frame.cpp
	$(VBUILD) -Wno-fatal --top-module m2_video -CFLAGS "-O2" \
	  --Mdir obj_m2_vf -o Vm2_video $(M2V_RTL) sim/video/tb_m2_video_frame.cpp

# The CPU bridge: decode, the 32-to-16 split, and the 25-to-40 MHz crossing.
test_m2_cpu_bridge: obj_m2_bridge/Vm2_cpu_bridge
	@echo "== test m2_cpu_bridge (decode + clock crossing)"
	@./obj_m2_bridge/Vm2_cpu_bridge $(TEST_ARGS)

obj_m2_bridge/Vm2_cpu_bridge: rtl/io/m2_cpu_bridge.sv sim/mem/tb_m2_cpu_bridge.cpp
	$(VBUILD) --top-module m2_cpu_bridge -CFLAGS "-O2" \
	  --Mdir obj_m2_bridge -o Vm2_cpu_bridge rtl/io/m2_cpu_bridge.sv sim/mem/tb_m2_cpu_bridge.cpp

# The bridge against the REAL controller. Both pass their own tests; this is the
# composition, which is what ships and what had never been tested together.
test_m2_cpu_sdram: obj_m2_cs/Vm2_cpu_sdram_harness
	@echo "== test m2_cpu_bridge + m2_sdram (the composition)"
	@./obj_m2_cs/Vm2_cpu_sdram_harness $(TEST_ARGS)

obj_m2_cs/Vm2_cpu_sdram_harness: rtl/io/m2_cpu_bridge.sv rtl/mem/m2_sdram.sv \
	  sim/mem/sdram_model.sv sim/mem/m2_cpu_sdram_harness.sv sim/mem/tb_m2_cpu_sdram.cpp
	$(VBUILD) -Wno-fatal --top-module m2_cpu_sdram_harness -CFLAGS "-O2" \
	  --Mdir obj_m2_cs -o Vm2_cpu_sdram_harness rtl/io/m2_cpu_bridge.sv rtl/mem/m2_sdram.sv \
	  sim/mem/sdram_model.sv sim/mem/m2_cpu_sdram_harness.sv sim/mem/tb_m2_cpu_sdram.cpp

# Real ROM execution. P1 exit criterion 3, and the only test here whose input
# this project did not write. Skips with a message when the set is absent -- a
# missing ROM is not a broken build, and NO ROM BYTE ENTERS THE REPOSITORY.
test_i960_rom: obj_i960_rom/Vi960_rom
	@echo "== test i960_rom (real Daytona program ROM)"
	@./obj_i960_rom/Vi960_rom $(TEST_ARGS)

obj_i960_rom/Vi960_rom: $(TOP_RTL) $(TB)/tb_i960_rom.cpp
	$(VBUILD) --top-module i960_top -CFLAGS "-O2 -I../$(TB)" \
	  --Mdir obj_i960_rom -o Vi960_rom $(TOP_RTL) $(TB)/tb_i960_rom.cpp

# -------------------------------------------------- SDRAM at 2:1 (96/48 MHz)
#
# tb_m2_sdram tests the controller with NO SLOW DOMAIN to be misaligned with, so
# it passes whether or not m2_sdram_x2 is right. This drives the slow side only
# on slow edges, and drops `req` the cycle AFTER the acknowledge, which is what
# a real requester does.
#
# Deleting the read-data bypass fails 1,786 of 2,560 checks. Deleting the
# request mask fails nothing, and that is recorded in both files rather than
# left to be discovered: this controller latches requests on their edge.

.PHONY: test_m2_sdram_x2
# The character fetch crossing. m2_sdram_x2's premise -- that every requester is
# on clk_sys -- is false for this one port, and the frequencies are not integer
# multiples, so the failure could only ever show on hardware. Study R49.
test_m2_char_cdc: obj_ccdc/Vm2_char_cdc
	@echo "== test m2_char_cdc (character fetch, 48 MHz <-> 32 MHz)"
	@./obj_ccdc/Vm2_char_cdc $(TEST_ARGS)

obj_ccdc/Vm2_char_cdc: rtl/mem/m2_char_cdc.sv sim/mem/tb_m2_char_cdc.cpp
	$(VBUILD) --top-module m2_char_cdc -Wno-UNUSEDSIGNAL \
	  --Mdir obj_ccdc -o Vm2_char_cdc -CFLAGS "-O2" \
	  rtl/mem/m2_char_cdc.sv sim/mem/tb_m2_char_cdc.cpp

test_m2_sdram_x2: obj_x2/Vm2_sdram_x2_harness
	@echo "== test m2_sdram_x2 (controller at 2x the core clock)"
	@./obj_x2/Vm2_sdram_x2_harness $(TEST_ARGS)

obj_x2/Vm2_sdram_x2_harness: sim/mem/m2_sdram_x2_harness.sv rtl/mem/m2_sdram_x2.sv \
                             rtl/mem/m2_sdram.sv sim/mem/sdram_model.sv sim/mem/tb_m2_sdram_x2.cpp
	$(VBUILD) --top-module m2_sdram_x2_harness -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET \
	  -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  --Mdir obj_x2 -o Vm2_sdram_x2_harness -CFLAGS "-O2" \
	  sim/mem/m2_sdram_x2_harness.sv rtl/mem/m2_sdram_x2.sv rtl/mem/m2_sdram.sv \
	  sim/mem/sdram_model.sv sim/mem/tb_m2_sdram_x2.cpp

# ------------------------------------------------- the boot, through the bridge
#
# test_i960_rom drives i960_top DIRECTLY with a C++ memory, so every one of the
# 803,355 instructions verified against MAME went through that path and none
# went through m2_cpu_bridge. This runs the real boot through the real bridge
# into the real I/O board and backup SRAM.
#
# It reproduced the hardware fault on its first run -- same I/O board state,
# same 4,097 tile writes, same zero window reads -- and named it in one trace:
# the I/O board returned 00400000 and the i960 was handed 00000000. Five
# seconds, against a 25-minute build.

.PHONY: test_m2_boot
test_m2_boot: obj_boot/Vm2_boot_harness
	@echo "== test m2_boot (the real boot through the real bridge)"
	@./obj_boot/Vm2_boot_harness $(TEST_ARGS)

# NOW CARRIES THE RENDERER TOO. Every isolated test passes and the board still
# misbehaves, so what this harness is for is the one configuration nothing else
# builds: the CPU writing tile RAM while m2_video reads it, with character
# fetches crossing clk_vid/clk_sys through the real m2_char_cdc.
obj_boot/Vm2_boot_harness: sim/io/m2_boot_harness.sv sim/io/tb_m2_boot.cpp \
                           rtl/io/m2_cpu_bridge.sv rtl/io/m2_ioboard.sv rtl/io/m2_backup.sv \
                           rtl/io/m2_ioz80.sv $(wildcard rtl/cpu/tv80/*.v) \
                           rtl/mem/m2_char_cdc.sv $(wildcard rtl/video/*.sv) \
                           $(wildcard rtl/cpu/i960/*.sv)
	$(VBUILD) --top-module m2_boot_harness -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM \
	  -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL --Mdir obj_boot -o Vm2_boot_harness \
	  -CFLAGS "-O2" sim/io/m2_boot_harness.sv rtl/io/m2_cpu_bridge.sv \
	  rtl/io/m2_ioboard.sv rtl/io/m2_backup.sv rtl/io/m2_ioz80.sv \
	  $(wildcard rtl/cpu/tv80/*.v) rtl/mem/m2_char_cdc.sv \
	  $(wildcard rtl/video/*.sv) $(wildcard rtl/cpu/i960/*.sv) \
	  sim/io/tb_m2_boot.cpp

# ------------------------------------------------------------------ I/O board
#
# BUILT WITH SMALL TIMERS. The real ones are 75,652,174 cycles of power-on
# self-test and 25,000 of reply delay -- three seconds of simulation to observe
# one edge. What is under test is the SEQUENCE, not the constants: the constants
# are measured in docs/io-board.md and are asserted by the differential against
# MAME, which is the only instrument that can judge them.
#
# The two replies are checked SEPARATELY because conflating them is the failure
# mode. The status reply follows the i960 writing its block; the flag clear
# follows the board's own self-test and lands regardless. Building with
# -GCOMPLETE_WINDOW=0 fails four checks and -GSELFTEST_CYCLES=2 fails one, so
# neither half can be removed without the suite noticing.

.PHONY: test_m2_ioboard
# THE REAL FIRMWARE, FIRST LIGHT. Runs EPR-14869C on tv80 and watches what it
# does to the DPRAM -- the discovery instrument for retiring R37-R41's HLE.
# Not in `make test` until its testimony is read and strong assertions exist.
# THE REAL-MEMORY COMPOSITION (R63): the boot harness with m2_sdram + the x2
# adapter + the device model in place of the C++ array, so the game side runs
# at true latency and the digit race becomes reproducible at the desk.
BOOTSRC := sim/io/m2_boot_harness.sv rtl/io/m2_cpu_bridge.sv \
           rtl/io/m2_ioboard.sv rtl/io/m2_backup.sv rtl/io/m2_ioz80.sv \
           $(wildcard rtl/cpu/tv80/*.v) rtl/mem/m2_char_cdc.sv \
           rtl/mem/m2_sdram_x2.sv rtl/mem/m2_sdram.sv \
           sim/mem/m2_sdram_x2_harness.sv sim/mem/sdram_model.sv \
           $(wildcard rtl/video/*.sv) $(wildcard rtl/cpu/i960/*.sv)

obj_boot_rm/Vm2_boot_harness: $(BOOTSRC) sim/io/tb_m2_boot.cpp
	$(VBUILD) --top-module m2_boot_harness -GREAL_MEM=1 \
	  -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  -Wno-SYNCASYNCNET \
	  -Wno-DECLFILENAME --Mdir obj_boot_rm -o Vm2_boot_harness \
	  -CFLAGS "-O2" $(BOOTSRC) sim/io/tb_m2_boot.cpp

test_m2_sndlink: obj_sndlink/Vm2_sndlink_harness
	@echo "== test m2_sndlink (the sound board serial link, against MAME's bytes)"
	@./obj_sndlink/Vm2_sndlink_harness

obj_sndlink/Vm2_sndlink_harness: rtl/sound/m2_i8251.sv rtl/sound/m2_sound_link.sv \
                                 sim/sound/m2_sndlink_harness.sv sim/sound/tb_m2_sndlink.cpp
	$(VERILATOR) --cc --exe --build -j 0 $(VFLAGS) --top-module m2_sndlink_harness \
	  --Mdir obj_sndlink -o Vm2_sndlink_harness -CFLAGS -O2 \
	  rtl/sound/m2_i8251.sv rtl/sound/m2_sound_link.sv \
	  sim/sound/m2_sndlink_harness.sv sim/sound/tb_m2_sndlink.cpp

test_m2_char_cache: obj_charcache/Vm2_char_cache
	@./obj_charcache/Vm2_char_cache

obj_charcache/Vm2_char_cache: rtl/video/m2_char_cache.sv sim/video/tb_m2_char_cache.cpp
	$(VERILATOR) --cc --exe --build -j 0 $(VFLAGS) --top-module m2_char_cache \
	  --Mdir obj_charcache -o Vm2_char_cache -CFLAGS -O2 \
	  rtl/video/m2_char_cache.sv sim/video/tb_m2_char_cache.cpp

test_m2_ioz80: obj_ioz80/Vm2_ioz80_harness
	@echo "== test m2_ioz80 (real firmware on tv80)"
	@./obj_ioz80/Vm2_ioz80_harness $(TEST_ARGS)

obj_ioz80/Vm2_ioz80_harness: sim/io/m2_ioz80_harness.sv rtl/io/m2_ioz80.sv \
                             $(wildcard rtl/cpu/tv80/*.v) sim/io/tb_m2_ioz80.cpp
	$(VBUILD) --top-module m2_ioz80_harness -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM \
	  -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
	  --Mdir obj_ioz80 -o Vm2_ioz80_harness -CFLAGS "-O2" \
	  sim/io/m2_ioz80_harness.sv rtl/io/m2_ioz80.sv rtl/cpu/tv80/tv80s.v \
	  rtl/cpu/tv80/tv80_core.v rtl/cpu/tv80/tv80_alu.v rtl/cpu/tv80/tv80_mcode.v \
	  rtl/cpu/tv80/tv80_reg.v sim/io/tb_m2_ioz80.cpp

test_m2_ioboard: obj_m2_io/Vm2_ioboard
	@echo "== test m2_ioboard (the two replies, on their two triggers)"
	@./obj_m2_io/Vm2_ioboard $(TEST_ARGS)

obj_m2_io/Vm2_ioboard: rtl/io/m2_ioboard.sv sim/io/tb_m2_ioboard.cpp
	$(VBUILD) --top-module m2_ioboard -GSELFTEST_CYCLES=5000 -GSTATUS_CYCLES=1000 \
	  --Mdir obj_m2_io -o Vm2_ioboard -CFLAGS "-O2" \
	  rtl/io/m2_ioboard.sv sim/io/tb_m2_ioboard.cpp

# ---------------------------------------------------------------- sound CPU
#
# fx68k on a real bus. THIRD_PARTY.md carried "does it simulate under
# Verilator?" as an open question for two sessions; it does, and the answer
# needed a bus rather than a clock. A C++ harness that drove enPhi1/enPhi2 and
# the data bus by hand never saw the core fetch a vector, and could not
# distinguish a broken core from a broken harness. The bus is RTL now.
#
# ITS OWN FLAGS, and they are not the project's VFLAGS. This is third-party
# code and it does not lint to our standard:
#   -Wno-UNOPTFLAT     Nanod/Irdecod are genuinely circular combinationally
#   -Wno-WIDTH*        19 width warnings in the original, none of them ours
#   --no-assert        fx68kAlu.sv:313 is a `unique case` that matches nothing
#                      while the ALU is idle, and $stops during reset if armed
#   -Wno-BLKANDNBLK    s_nanod and s_irdecod are written from both a blocking
#                      and a non-blocking context. THIRD_PARTY.md recorded this
#                      as needing "a two-word change" -- packing the structs --
#                      and it does not: the flag accepts the construct as it
#                      stands. That is the better answer, because the file then
#                      stays byte-for-byte upstream's and there is nothing to
#                      re-apply on a bump. It also removes a real hazard, which
#                      is how it was found: a patched copy in a git-ignored
#                      directory is invisible to `git status` on this repo, and
#                      overwriting it from another project's clone silently
#                      broke this test.
# Waiving them here rather than in VFLAGS keeps our own RTL held to -Wall.
#
# ONE COPY, IN rtl/, NOT third_party/. It was third_party/fx68k, which cannot
# work for the core: third_party/ is git-ignored, so a Quartus build on any
# other checkout would have no CPU. Simulation and synthesis now read the same
# committed files.
#
# RUN FROM rtl/sound/fx68k. fx68k's $readmemb takes a bare filename, so the
# microcode and nanocode ROMs are found relative to the WORKING DIRECTORY. Load
# them and the core executes; miss them and the sequencer is full of zeros,
# which is indistinguishable from a core that does not work -- so the test
# reports "no bus cycles at all" and names this as the first thing to check.

FX68K_RTL := rtl/sound/fx68k/fx68k.sv rtl/sound/fx68k/fx68kAlu.sv \
             rtl/sound/fx68k/uaddrPla.sv
FX68K_VFLAGS := -Wno-fatal -Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
                -Wno-BLKANDNBLK -Wno-ALWCOMBORDER --no-assert

.PHONY: test_fx68k
test_fx68k: obj_fx68k/Vfx68k_harness
	@echo "== test fx68k (the 68000 executes a program over a modelled bus)"
	@cd rtl/sound/fx68k && $(CURDIR)/obj_fx68k/Vfx68k_harness $(TEST_ARGS)

obj_fx68k/Vfx68k_harness: sim/sound/fx68k_harness.sv sim/sound/tb_fx68k.cpp $(FX68K_RTL)
	$(VERILATOR) --cc --exe --build -j 0 -sv $(FX68K_VFLAGS) \
	  --top-module fx68k_harness --Mdir obj_fx68k -o Vfx68k_harness \
	  -CFLAGS "-O2" sim/sound/fx68k_harness.sv $(FX68K_RTL) sim/sound/tb_fx68k.cpp

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

# An .mra that does not parse is a black screen with no error, and both of these
# were committed broken before being checked once. XML comments may not contain a
# double hyphen, which is what did it.
check_mra:
	@python3 -c "import xml.etree.ElementTree as ET, glob, sys; \
	  [ET.parse(f) for f in sorted(glob.glob('mra/*.mra'))] and \
	  print('mra: %d file(s) parse' % len(glob.glob('mra/*.mra')))"

.PHONY: release check_mra
release: check_mra
	@test -f output_files/Model2.rbf || { \
	  echo "no output_files/Model2.rbf -- run: quartus_sh --flow compile Model2"; exit 1; }
	@# REFUSE A STALE BITSTREAM. This has now shipped the wrong core twice: a
	@# build fails or is killed, output_files still holds the previous .rbf, and
	@# release copies it. The deploy then verifies it by md5 -- against itself --
	@# and reports success, so the board is tested with a core that does not
	@# contain the change being tested. An hour went into reading overlays that
	@# were telling the truth about the wrong build.
	@newer=$$(find Model2.sv Model2.qsf rtl sys -newer output_files/Model2.rbf \
	          -type f \( -name '*.sv' -o -name '*.v' -o -name '*.qsf' \) 2>/dev/null | head -3); \
	 if [ -n "$$newer" ]; then \
	   echo "STALE: output_files/Model2.rbf is older than:"; \
	   echo "$$newer" | sed 's/^/    /'; \
	   echo "  rebuild first: quartus_sh --flow compile Model2"; exit 1; \
	 fi
	@grep -q 'Flow Status.*Successful' output_files/Model2.flow.rpt 2>/dev/null || { \
	  echo "last Quartus flow did not report Successful -- refusing to release"; exit 1; }
	@# FOUR DISTINCT CORE PLL CLOCKS, checked where the answer is final.
	@#
	@# It was five until the video moved onto clk_sys with a one-in-three enable
	@# (48/3 = 16 MHz, the exact old pixel rate). outclk_2's 32 MHz then had no
	@# consumer, so the fitter drops it and four is now correct. The check stays
	@# because the hazard it guards has not gone away: outputs with identical
	@# settings can still be merged into one counter, and this caught a real
	@# stale-release today -- the count fell to four, the release refused, and
	@# the deploy would have pushed the PREVIOUS bitstream while a test was run
	@# against it. Which it did, before the number was corrected.
	@#
	@# This was an SDC guard, and it fired during the fitter's read_sdc when the
	@# derived clocks were not all present yet -- reporting 1 on a build whose
	@# PLL had been elaborated with all five. Worse, `post_message -type error`
	@# in an SDC makes read_sdc FAIL, so the design was fitted with no
	@# constraints and Quartus reported "Can't fit design in device" at 46%
	@# logic. The check is right; the place was wrong.
	@#
	@# It matters because outputs with identical settings can be merged into one
	@# output counter by the IP -- general[0] and general[4] are both 96 MHz and
	@# differ only in phase. The Kaneko16 core lost a whole design to that: three
	@# outputs became one, the core collapsed to a single clock domain, and Fmax
	@# fell to 54.74 MHz with no error anywhere.
	@n=$$(grep -oE 'general\[[0-9]\]\.gpll~PLL_OUTPUT_COUNTER\|divclk' \
	      output_files/Model2.sta.rpt 2>/dev/null | sort -u | wc -l); \
	 if [ "$$n" -lt 4 ]; then \
	   echo "only $$n distinct core PLL output clocks, expected 4 -- refusing to release"; \
	   echo "  outputs with identical settings can be merged by the IP; see rtl/pll/pll.v"; \
	   exit 1; \
	 else echo "  core PLL clocks: $$n distinct outputs"; fi
	@# REFUSE NEGATIVE SLACK. "Flow Status: Successful" does not mean timing
	@# closed -- Quartus reports success and lists the failing paths in the STA
	@# report, and a core that misses by picosecond margins works until it does
	@# not, on someone else's board or in July.
	@#
	@# Taken from the Kaneko16 core, where exactly this guard caught a build that
	@# had closed at +0.615 ns and went to -0.009 ns when four debug counters
	@# were added: a nine-picosecond miss, in a build that otherwise looked
	@# identical to the one before it.
	@#
	@# It reads the Setup Summary, not the whole report, because the whole report
	@# also contains hold and recovery tables whose formatting differs.
	@neg=$$(grep -A20 '; Setup Summary' output_files/Model2.sta.rpt 2>/dev/null \
	        | grep -E '^; [^;]+; +-[0-9]' | sed 's/;/ /g' | awk '{print $$1, $$2}'); \
	 if [ -n "$$neg" ]; then \
	   echo "TIMING NOT CLOSED -- refusing to release. Negative setup slack on:"; \
	   echo "$$neg" | sed 's/^/    /'; exit 1; \
	 fi
	@ws=$$(grep -A20 '; Setup Summary' output_files/Model2.sta.rpt 2>/dev/null \
	       | grep -oE '; +-?[0-9]+\.[0-9]+ +;' | tr -d '; ' | sort -g | head -1); \
	 echo "  timing closed, worst-case setup slack $${ws:-unknown} ns (ALL clocks)"
	@# AND WHOSE IT IS. The line above is the global minimum, and on this board
	@# that is almost always pll_hdmi -- MiSTer framework infrastructure that no
	@# change to this core touches. Quoting it as "our slack" reads a healthy
	@# build as a marginal one: 0.074 ns was reported for a build whose tightest
	@# core clock was +2.350. The Makefile already warns, three targets up, that
	@# the summary gives slack but not endpoints and that Model 1's M0 attributed
	@# a miss to the wrong one. This is the same mistake with the sign reversed --
	@# a number that is real, and about something else.
	@#
	@# The refusal above still covers EVERY clock, framework included: a negative
	@# slack anywhere is still a failed build. This only says which is ours.
	@core=$$(grep -A20 '; Setup Summary' output_files/Model2.sta.rpt 2>/dev/null \
	        | grep 'emu|pll|pll_inst' \
	        | awk -F';' '{s=$$3; n=$$2; gsub(/ /,"",s); \
	                      sub(/^ +/,"",n); sub(/ +$$/,"",n); \
	                      sub(/.*general/,"general",n); sub(/\..*/,"",n); \
	                      print s" "n}' | sort -g | head -1); \
	 echo "  this core's tightest clock:     $${core:-unknown} ns"

	@rm -rf $(RELEASE)
	@mkdir -p $(RELEASE)/_Arcade/cores
	@cp output_files/Model2.rbf $(RELEASE)/Model2.rbf
	@cp output_files/Model2.rbf $(RELEASE)/_Arcade/cores/Model2.rbf
	@cp mra/*.mra $(RELEASE)/_Arcade/
	@echo "release tree in $(RELEASE):"
	@cd $(RELEASE) && find . -type f | sort | sed 's/^/  /'
	@echo ""
	@echo "  Copy Model2.rbf to /media/fat/_Other/ to run it standalone."
	@echo "  Overlay must read  word2=000001A8  word3=000001F0  -- MAME set_raw."
	@echo ""
	@echo "  DAYTONA: the i960 IS in the core and executes the real boot. Set"
	@echo "  the OSD's \"Sweep region (2MB)\" and read overlay rows 12 and 13"
	@echo "  together -- row 13 is DD00000N, where DD means the sweep finished"
	@echo "  and N names the region row 12 folded. Compare against"
	@echo "    python3 tools/rom_csum.py mra/<game>.mra <romdir> --scan"
	@echo "  Regions past the end of the image are NOT evidence; --scan says"
	@echo "  which those are. Study R38."
	@echo ""
	@echo "  2D TILEMAP TEST: copy the .mra to _Arcade/ and m2tiles.zip alongside"
	@echo "  your other zips. It renders a captured Daytona frame; that image is"
	@echo "  canned MAME state, so it exercises the renderer, not the CPU."
	@echo ""
	@echo "  m2tiles.zip NOW NEEDS A FOURTH SECTION, the colour translation table"
	@echo "  at 0x094000. An image without it still works -- the core checks the"
	@echo "  section and falls back to the old expansion -- but the colours stay"
	@echo "  slightly wrong. Regenerate it with tools/mame_m2_tiledump.lua and"
	@echo "  concatenate tile, palette, char, colorxlat in that order. Study R27."
	@echo ""
	@echo "  The full 43.62 MB ROM set fits: this controller addresses 64 MB, a"
	@echo "  MEASURED figure, not the 32 MB earlier notes assumed. Study R19."

# --------------------------------------------------------------------- clean

clean:
	rm -rf obj_*

distclean: clean
	rm -rf db incremental_db output_files simulation greybox_tmp
