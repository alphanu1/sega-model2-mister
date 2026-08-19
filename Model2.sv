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

// LED_USER included deliberately: the first build left it undriven, which is
// exactly the warning this block exists to avoid.
assign LED_USER  = 0;
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
	// The read capture phase is an OSD option rather than a constant because the
	// Model 1 core found its board returned every burst shifted right by one
	// 16-bit word. Its m2_sdram derivation of CL+3 is against a model that
	// presents data on the same edge the controller uses, while the real device
	// is clocked on the INVERSE of clk_sdram and answers half a period away.
	// Guessing this one 25-minute build at a time is the alternative.
	"O[5:4],SDRAM phase,CL+2,CL+3,CL+4,CL+5;",
	"-;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

// WIDE(1) IS NOT OPTIONAL. It makes ioctl_dout 16 bits and ioctl_addr advance by
// two per word, which is exactly what m2_rom_loader's header says it expects.
// Left at the default WIDE=0 the port is EIGHT bits, our 16-bit wire silently
// zero-extends a byte, and the ROM lands in SDRAM as garbage — which read back
// from the board as an address-independent 000000FF and cost two hardware builds
// chasing the SDRAM capture phase, which was never involved.
hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_vid),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

wire        ioctl_download, ioctl_wr, ioctl_wait;
wire [15:0] ioctl_index, ioctl_dout;
wire [26:0] ioctl_addr;

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

///////////////////////   SDRAM AND ROM   ///////////////////////
//
// ADDRESS WIDTH, AND WHAT IT MEANS FOR MODEL 2. This controller is `[24:1]`
// throughout with 2 bank bits and 13 row bits: 16M 16-bit words, i.e. **32 MB**.
// Model 2's ROM set is **43.62 MB** (docs/rom-layout.md), so the full set does
// NOT fit what this addresses, on any board.
//
// Fine for P1.5, and it must not be forgotten for P6. The 2D milestone needs the
// tilemap dump, palette and character data — well under a megabyte. Carrying the
// whole ROM needs this controller widened for a 128 MB module, or the DDR3 split
// docs/rom-layout.md sets aside. Recorded now rather than discovered later.

// 128 MB module: 4 banks x 8192 rows x 2048 columns of 16-bit words, so 11
// column bits and a 26-bit word address. That is the ONLY decomposition reaching
// 64M words on the connector's 13 address and 2 bank pins, and both geometries
// are proven against the device model (make test_m2_sdram, test_m2_sdram128).
localparam int unsigned SDR_COL  = 11;
localparam int unsigned SDR_AW   = 2 + 13 + SDR_COL;   // 26

wire        mem_ready, sd_dq_oe, rom_loaded, ldr_overflow;
wire [15:0] sd_dq_o;
wire        ldr_wr_req, ldr_wr_ack;
wire [SDR_AW:1] ldr_wr_addr;
wire [15:0] ldr_wr_din;
wire  [1:0] ldr_wr_be;

logic        rb_req;
logic [SDR_AW:1] rb_addr;
wire         rb_ack;
wire  [63:0] rb_dout;

// NP=5, NOT 1. The controller's arbiter indexes grant[2] unconditionally, so a
// narrower port count fails to elaborate. The lifted file is left unedited and
// the four unused ports are tied off instead -- synthesis removes what they
// drive, and the alternative is forking from the reference over an arbiter
// detail. Port 0 is the readback; 1-4 become the CPU, tilemap and renderer.
localparam int unsigned NPORTS = 5;
logic [NPORTS-1:0]        p_req;
logic [NPORTS-1:0][SDR_AW:1]  p_addr;
wire  [NPORTS-1:0][63:0]  p_dout;
wire  [NPORTS-1:0]        p_ack;

always_comb begin
	p_req  = '0;
	p_addr = '0;
	// PORT 1, NOT PORT 0. m2_sdram's blen() is hardcoded per port: ports 1-3
	// burst FOUR 16-bit words, filling the whole 64-bit p_dout, while ports 0
	// and 4 return ONE. On port 0 the readback got a correct low half and a
	// permanently zero upper half -- which reads like a broken controller and
	// is a port-selection mistake. The CPU takes port 0 precisely because it
	// wants single words; 1-3 are the streaming ports.
	p_req[1]  = rb_req;
	p_addr[1] = rb_addr;
	p_req[2]  = st_rd_req;
	p_addr[2] = st_rd_addr;
end
assign rb_dout = p_dout[1];
assign rb_ack  = p_ack[1];

// T_REFI IS IN CLOCK CYCLES. This domain is temporarily 40 MHz (see rtl/pll/pll.v):
// 8192 rows in 64 ms is one refresh every 7.8125 us, which is 312 cycles at 40 MHz
// and 625 at 80. Too large UNDER-REFRESHES, and that presents as random ROM
// corruption rather than as a timing setting.
m2_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(300)) u_sdram (
	.clk(clk_sdram), .rst_n(mem_rst_n), .ready(mem_ready),
	// OSD order is CL+2..CL+5 and the selector's own encoding puts CL+3 at zero,
	// so the two are mapped rather than passed through.
	.rd_lat_sel(status[5:4] == 2'd0 ? 2'd1 :
	            status[5:4] == 2'd1 ? 2'd0 : status[5:4]),
	.sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
	.sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
	.wr_req(st_run ? st_req : ldr_wr_req),
	.wr_addr(st_run ? st_addr : ldr_wr_addr),
	.wr_din(st_run ? st_din : ldr_wr_din),
	.wr_be(2'b11), .wr_ack(ldr_wr_ack),
	.p_req(p_req), .p_we('0), .p_addr(p_addr), .p_din('0), .p_be('1),
	.p_dout(p_dout), .p_ack(p_ack),
	.dbg_req(), .dbg_grant()
);

assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
assign SDRAM_CLK = ~clk_sdram;   // the device is clocked on the falling edge

// `ioctl_wait` STALLS THE HPS ITSELF, so the loader gates it on `ioctl_download`
// internally — and it ASKS the host to stop rather than stopping it, which is why
// it buffers into a FIFO with margin instead of trusting the wait to take effect.
m2_rom_loader #(.SDR_AW(SDR_AW)) u_loader (
	.clk(clk_sdram), .rst(~mem_rst_n),
	.mem_ready(mem_ready),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
	.sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
	.tgp_wr(), .tgp_addr(), .tgp_din(),
	.rom_loaded(rom_loaded), .overflow(ldr_overflow)
);

// READBACK, WHICH IS THE POINT OF THIS STEP. Loading a ROM that nothing reads
// proves nothing. After `rom_loaded` this walks the first two 32-bit words out of
// SDRAM onto the overlay, to be compared against the ROM file by eye. If the read
// capture phase is wrong they come back SHIFTED — which is the failure the OSD
// option exists for, so this is also how that option gets set.
logic [31:0] rb_w0, rb_w1;
logic  [1:0] rb_state;

always_ff @(posedge clk_sdram or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		rb_req <= 1'b0; rb_addr <= '0; rb_state <= 2'd0;
		rb_w0 <= 32'd0; rb_w1 <= 32'd0;
	end else begin
		case (rb_state)
			// PROBE ADDRESSES ARE CHOSEN, NOT DEFAULT. Address 0 is useless: the
			// i960 ROM legitimately begins 00000000, so a correct read and a dead
			// read are indistinguishable. These two carry signatures, taken from
			// the interleaved stream the MRA builds:
			//
			//   word 8/9   -> FFFFF6E0
			//   word 6/7   -> 00000860   (read aligned at 4, upper half of the burst)
			2'd0: if (rom_loaded) begin rb_addr <= SDR_AW'(8); rb_req <= 1'b1; rb_state <= 2'd1; end
			// ONE ACCESS PER HANDSHAKE, not per cycle of the request: it drops on
			// ack. Harmless against RAM, and the habit is the point — the Model 1
			// TGP popped every FIFO word twice by acting on the level instead.
			2'd1: if (rb_ack) begin rb_w0 <= rb_dout[31:0]; rb_req <= 1'b0;
			                        rb_addr <= SDR_AW'(4); rb_state <= 2'd2; end
			2'd2: begin rb_req <= 1'b1; rb_state <= 2'd3; end
			// LOOPS, and that matters. The first version ran once and latched, so
			// changing the SDRAM phase in the OSD could not alter what was shown
			// and the test reported "no change" whatever the setting. That is a
			// null result from a dead instrument, which is worse than no result:
			// it was read as evidence that the phase is not involved.
			2'd3: if (rb_ack) begin rb_w1 <= rb_dout[63:32]; rb_req <= 1'b0;
			                        rb_state <= 2'd0; end
			default: ;
		endcase
	end
end

///////////////////////   SDRAM SELF-TEST   //////////////////////
//
// FOUR BUILDS WERE SPENT INFERRING FROM ROM DATA, which is the wrong instrument:
// it cannot separate a write fault from a read fault, the ROM's content is not
// chosen to expose byte lanes, and the tilemap blob used to "prove" the path is
// 0x0020 repeated, every high byte zero, so a dead high lane reads it perfectly.
//
// This writes patterns chosen so each failure mode is distinguishable, to an
// address the ROM never occupies, then reads them back as one burst:
//
//   write AA55 5AA5 FF00 00FF  ->  word5 = 5AA5AA55, word6 = 00FFFF00 if correct
//
//   high lane reads zero      -> word5 = 00A50055
//   high byte never written   -> word5 = FFA5FF55   (unwritten reads FF)
//   lanes swapped             -> word5 = A55A55AA
//   address aliasing          -> patterns repeat or shift
//
// It runs after rom_loaded, when the loader is idle, drives the same write port
// through a mux, and loops so the OSD phase option stays live.

localparam logic [15:0] STP0 = 16'hAA55, STP1 = 16'h5AA5,
                        STP2 = 16'hFF00, STP3 = 16'h00FF;
localparam logic [SDR_AW:1] ST_BASE = SDR_AW'(32'h2000000);   // 64 MB mark

logic            st_run, st_req, st_rd_req;
logic [SDR_AW:1] st_addr, st_rd_addr;
logic [15:0]     st_din;
logic [3:0]      st_state;
logic [63:0]     st_got;

assign st_run = rom_loaded && (st_state >= 4'd1) && (st_state <= 4'd8);

always_ff @(posedge clk_sdram or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		st_state <= 4'd0; st_req <= 1'b0; st_rd_req <= 1'b0;
		st_addr <= '0; st_rd_addr <= '0; st_din <= 16'd0; st_got <= 64'd0;
	end else begin
		case (st_state)
			4'd0: if (rom_loaded) begin
				st_addr <= ST_BASE; st_din <= STP0; st_req <= 1'b1; st_state <= 4'd1;
			end
			4'd1: if (ldr_wr_ack) begin st_req <= 1'b0; st_state <= 4'd2; end
			4'd2: begin st_addr <= ST_BASE + SDR_AW'(1); st_din <= STP1;
			            st_req <= 1'b1; st_state <= 4'd3; end
			4'd3: if (ldr_wr_ack) begin st_req <= 1'b0; st_state <= 4'd4; end
			4'd4: begin st_addr <= ST_BASE + SDR_AW'(2); st_din <= STP2;
			            st_req <= 1'b1; st_state <= 4'd5; end
			4'd5: if (ldr_wr_ack) begin st_req <= 1'b0; st_state <= 4'd6; end
			4'd6: begin st_addr <= ST_BASE + SDR_AW'(3); st_din <= STP3;
			            st_req <= 1'b1; st_state <= 4'd7; end
			4'd7: if (ldr_wr_ack) begin st_req <= 1'b0; st_state <= 4'd8; end
			4'd8: begin st_rd_addr <= ST_BASE; st_rd_req <= 1'b1; st_state <= 4'd9; end
			4'd9: if (p_ack[2]) begin
				st_got <= p_dout[2]; st_rd_req <= 1'b0; st_state <= 4'd8;
			end
			default: st_state <= 4'd0;
		endcase
	end
end

// Static once captured, so a two-flop synchroniser on the status bit is enough:
// the data is not moving when the video domain reads it.
logic [2:0] loaded_sync;
always_ff @(posedge clk_vid) loaded_sync <= {loaded_sync[1:0], rom_loaded};

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

///////////////////////   OVERLAY   //////////////////////////////
//
// The pattern proves the picture is THERE. The overlay proves it is RIGHT, by
// printing the numbers instead of leaving them to the eye:
//
//   0  magic 0xB0ADCAFE -- a garbled overlay is obvious rather than plausible
//   1  frame counter    -- liveness, numerically, and it wraps
//   2  lines last frame -- MUST read 000001A8 (424)
//   3  visible pixels per line -- MUST read 000001F0 (496)
//
// Those are MAME's set_raw numbers (docs and sim/video/tb_m2_video_timing.cpp
// assert the same two). Simulation proving them and silicon proving them are
// different claims, and until now only the first had been made.

reg [31:0] frame_ctr;
reg  [9:0] line_ctr,  line_ctr_l;
reg [10:0] vispix_ctr, vispix_ctr_l;
reg        vblank_dd;

always @(posedge clk_vid) begin
  if (!mem_rst_n) begin
    frame_ctr <= 0; line_ctr <= 0; vispix_ctr <= 0;
    line_ctr_l <= 0; vispix_ctr_l <= 0;
  end else if (ce_pix) begin
    vblank_dd <= vblank;
    // Count visible pixels on ONE line only, so the figure is per-line and not
    // per-frame: it is latched at the end of a line and reset immediately.
    // BOTH COUNTERS WERE OFF BY ONE ON HARDWARE, and the board is what found it:
    // 1A7 and 1EF where MAME's set_raw says 1A8 and 1F0.
    //
    // The cause is the same in both. The reset and the increment fired on the
    // SAME edge -- hcnt==0 is a visible pixel, and the frame boundary lands on a
    // line boundary -- so the later non-blocking assignment won and the pixel or
    // line being closed was never counted. The timing module is not implicated;
    // sim/video/tb_m2_video_timing.cpp asserts 424 and 496 against MAME and
    // passes. This was the instrument, for the third time this session.
    //
    // Fix: the closing edge counts the item it is closing, rather than dropping
    // it in favour of the reset.
    if (hcnt == 10'd0) begin
      if (|vispix_ctr) vispix_ctr_l <= vispix_ctr;
      vispix_ctr <= visible ? 11'd1 : 11'd0;   // hcnt==0 is itself visible
      line_ctr   <= line_ctr + 1'd1;
    end else if (visible) begin
      vispix_ctr <= vispix_ctr + 1'd1;
    end
    if (vblank & ~vblank_dd) begin       // frame boundary, on a line boundary
      frame_ctr  <= frame_ctr + 1'd1;
      line_ctr_l <= line_ctr + 1'd1;     // count the line the reset consumes
      line_ctr   <= 0;
    end
  end
end

wire [7:0] ov_r, ov_g, ov_b;

m2_diag #(.NWORDS(7)) u_diag
(
	.clk(clk_vid),
	.ce_pix(ce_pix),
	.rst_n(mem_rst_n),
	.enable(1'b1),
	.hb(hblank),
	.vb(vblank),
	.words({ st_got[63:32],                             // 6  want 00FFFF00
	         st_got[31:0],                              // 5  want 5AA5AA55
	         // 32 BITS, not 31. The first version was {27'd0, ...} = 31, which
	         // shifted every word above it by one bit: the board showed word4 as
	         // 80000007, its top bit being rb_w0's LSB bleeding down. A short
	         // field in a concatenation does not warn, it silently reindexes.
	         {28'd0, ldr_overflow, loaded_sync[2],
	          mem_ready, pll_locked},                   // 4  status
	         {21'd0, vispix_ctr_l},                     // 3  pixels = 1F0
	         {22'd0, line_ctr_l},                       // 2  lines  = 1A8
	         frame_ctr,                                 // 1  liveness
	         32'hB0ADCAFE }),                           // 0  magic
	.in_r(pat_r), .in_g(pat_g), .in_b(pat_b),
	.out_r(ov_r), .out_g(ov_g), .out_b(ov_b)
);

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = ce_pix;

assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_R  = ov_r;
assign VGA_G  = ov_g;
assign VGA_B  = ov_b;

endmodule
