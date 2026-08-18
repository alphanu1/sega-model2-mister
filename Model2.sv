// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// P1.5 step 1: the core top level, producing a test pattern at Model 2's real
// video timing. No CPU, no renderer, no sound -- see docs/milestones.md P1.5.
//
// The point of this build is to answer the bring-up questions before there is
// anything complicated in the design to blame: does it fit, does it boot, does
// the framework hand us a picture, and are the sync parameters right on a real
// display. Those are cheap to answer now and expensive to answer later.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Unused by this core. Driven explicitly rather than left floating,
///////// because an undriven output in a MiSTer core is a synthesis warning
///////// that hides real ones.

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH,
        SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL  = 0;
assign VGA_F1  = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 0;
assign AUDIO_L   = 0;
assign AUDIO_R   = 0;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Model 2 is a 4:3 machine. 496x384 is not 4:3 as a pixel count -- the pixels
// are not square -- so the aspect ratio is stated rather than derived from the
// resolution.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Model2;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_vid),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////
//
// The PLL module MUST be named `pll` -- sys/sys_top.sdc constrains it by that
// name, and a rename makes the constraints match nothing while still passing.
// See rtl/pll/pll.v.

wire clk_sdram;   // 80 MHz, unused in this step but generated so the PLL that
                  //         later steps need is the one being timed now
wire clk_vid;     // 32 MHz
wire clk_i960;    // 25 MHz, unused in this step
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sdram),
	.outclk_1(clk_vid),
	.outclk_2(clk_i960),
	.locked(pll_locked)
);

// EXACTLY half of 32 MHz. MAME declares Model 2's pixel clock as
// `32_MHz_XTAL/2`, so this is the reference rate and not an approximation of it.
reg ce_pix;
always @(posedge clk_vid) ce_pix <= ~ce_pix;

// Memory comes out of reset on PLL lock and STAYS out, separately from the
// game reset. One signal must not mean two things -- docs/mister-integration.md.
// There is no memory in this step; the distinction is established here so that
// adding it later does not require rewiring reset.
wire mem_rst_n  = pll_locked;
wire game_rst_n = pll_locked & ~RESET & ~status[0] & ~buttons[1];

///////////////////////   VIDEO   ////////////////////////////////

wire        hs, vs, hblank, vblank, visible;
wire  [9:0] hcnt, vcnt;
wire  [7:0] pat_r, pat_g, pat_b;

m2_video_timing u_timing
(
	.clk(clk_vid),
	.ce_pix(ce_pix),
	.rst_n(mem_rst_n),
	.hcnt(hcnt),
	.vcnt(vcnt),
	.hblank(hblank),
	.vblank(vblank),
	.hsync(hs),
	.vsync(vs),
	.visible(visible),
	.line_start(),
	.line_number(),
	.vblank_start()
);

// The pattern is on the GAME reset, not the memory reset, so pressing reset in
// the OSD visibly restarts the marching block. That is the cheapest possible
// confirmation on a bench that reset reaches the core at all.
wire vbs;
assign vbs = vblank & ~vblank_d;
reg vblank_d;
always @(posedge clk_vid) if (ce_pix) vblank_d <= vblank;

m2_testpattern u_pattern
(
	.clk(clk_vid),
	.ce_pix(ce_pix),
	.rst_n(game_rst_n),
	.hcnt(hcnt),
	.vcnt(vcnt),
	.visible(visible),
	.vblank_start(vbs),
	.r(pat_r),
	.g(pat_g),
	.b(pat_b)
);

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = ce_pix;

assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_R  = pat_r;
assign VGA_G  = pat_g;
assign VGA_B  = pat_b;

endmodule
