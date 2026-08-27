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
	// is clocked on the INVERSE of clk_sys and answers half a period away.
	// Guessing this one 25-minute build at a time is the alternative.
	// THREE BITS NOW, REACHING CL+4 AND CL+5. The range was CL+0..CL+3, moved
	// EARLIER on 40 MHz hardware evidence -- the burst came back shifted one
	// 16-bit word late, so capture had to start sooner. At 96 MHz the round
	// trip is 2.4x longer in clock cycles and the correction goes the other
	// way: the Kaneko16 core, on this controller at 96 MHz, defaults to CL+5
	// and found the board wants CL+4.
	//
	// RD_LAT is already CL+5, so the capture pipeline is deep enough; it was
	// only the selector that could not reach. A board that reads garbage at
	// every one of four settings is the symptom of a range that does not
	// contain the answer, and this project has now read that symptom as "the
	// phase is not involved" once already.
	// AUTO is the default and the right answer on a healthy board: the
	// self-test sweeps all six depths against a known 64-bit pattern and takes
	// the centre of the widest window that passed. The manual settings exist
	// because a board that cannot be calibrated should still be usable, and
	// because forcing a known value is how the calibration itself gets checked.
	"O[7:5],SDRAM phase,Auto,CL+1,CL+2,CL+3,CL+4,CL+5;",
	// WHICH 2 MB OF THE CHIP THE PORT-4 SWEEP FOLDS. Selectable because the
	// alternative is a 25-minute build per probe, and locating a corruption in
	// 43.62 MB takes more than one probe. Region N covers word N*0x100000 for
	// 0x100000 words; tools/rom_csum.py --region N folds the same span of the
	// image. Changing this restarts the sweep, so it costs a menu click.
	"O[13:9],Sweep region (2MB),0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31;",
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
	// clk_sys, NOT clk_vid, AND THAT IS THE WHOLE POINT.
	//
	// m2_rom_loader is clocked on clk_sys. Running hps_io on a different clock
	// puts ioctl_wr, ioctl_addr and ioctl_dout across an UNSYNCHRONISED domain
	// crossing, so the loader samples 16-bit data while it is changing and
	// captures one byte from one value and the other byte from another.
	//
	// That is exactly what the board showed: every LOW byte of the ROM correct
	// and every HIGH byte wrong, with the wrong bytes not appearing anywhere in
	// the ROM. The SDRAM self-test passed throughout because it lives entirely
	// inside clk_sys, and the 0x0020 tilemap blob hid it because every high
	// byte in it is zero.
	//
	// The Model 1 core runs hps_io on clk_sys, the same domain as its loader.
	// This core split them, and cost five hardware builds finding out.
	.clk_sys(clk_sys),
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

wire clk_mem;        // 96 MHz, m2_sdram ONLY
wire clk_sdram_pin;  // 96 MHz at 180 deg, drives SDRAM_CLK
wire clk_sys;   // 48 MHz, the core domain. Was the SDRAM clock; see pll.v.
                  //         later steps need is the one being timed now
wire clk_vid;     // 32 MHz
wire clk_i960;    // 25 MHz, unused in this step
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),      // 96 MHz, the SDRAM controller alone
	.outclk_1(clk_sys),      // 48 MHz, everything else. Exact /2, phase-aligned.
	.outclk_2(clk_vid),      // 32 MHz
	.outclk_3(clk_i960),     // 24 MHz -- see rtl/pll/pll.v for why not 25
	.outclk_4(clk_sdram_pin),// 96 MHz at 180 deg, straight to the device pin
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
// TEN COLUMN BITS: 64 MB, which holds the 43.62 MB ROM set.
//
// Nine is proven on this board -- it is what the Model 1 core runs, and at nine
// the tile copy checksums are exact and Daytona's attract screen renders. But
// nine only addresses 32 MB and the full ROM set does not fit.
//
// Ten is the right target rather than eleven for a structural reason. Column bits
// map to A0..A9, then A11 and A12, SKIPPING A10, which is the auto-precharge flag.
// Ten needs only the contiguous A0..A9 range and leaves A10 alone. Eleven is the
// first value that must drive a column bit on A11, and therefore the first that
// depends on the part actually having 2048 columns -- the inference that failed
// and cost twelve builds (study R18).
//
// If ten also aliases, the module is organised as 32 MB whatever its capacity, and
// the DDR3 split becomes a real P6 requirement instead of a contingency.
//
// 11 column bits was MY change, to reach 128 MB, and the geometry behind it was
// REASONED from the connector's pin count rather than measured: 13 address pins
// and 2 bank pins admit 4 banks x 8192 rows x 2048 columns, so I concluded that
// must be the part. That is an inference, not a measurement.
//
// If the module is not 2048 columns, A11 driven as a column bit ALIASES. That is
// invisible to a test which reads one address forever -- the SDRAM self-test,
// which passes -- and destroys a walk across 36,864 addresses, which is the copy
// engine. It also explains checksums that change between runs, since what a given
// address aliases onto depends on what was written where.
//
// 9 gives 32 MB, which holds the 592 KB tilemap blob comfortably. If the copy
// comes good at 9, the geometry is the fault and must be MEASURED before it is
// widened again, not deduced.
localparam int unsigned SDR_COL  = 10;
localparam int unsigned SDR_AW   = 2 + 13 + SDR_COL;   // 25 with COL_BITS=10

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
logic [NPORTS-1:0]        p_we;
logic [NPORTS-1:0][15:0]  p_din;
logic [NPORTS-1:0][1:0]   p_be;
logic [NPORTS-1:0][SDR_AW:1]  p_addr;
wire  [NPORTS-1:0][63:0]  p_dout;
wire  [NPORTS-1:0]        p_ack;

always_comb begin
	p_req  = '0;
	p_addr = '0;
	p_we   = '0;
	p_din  = '0;
	p_be   = '1;
	p_we[1]  = cpu_sd_we;
	p_din[1] = cpu_sd_din;
	p_be[1]  = cpu_sd_be;
	// PORT 1, NOT PORT 0. m2_sdram's blen() is hardcoded per port: ports 1-3
	// burst FOUR 16-bit words, filling the whole 64-bit p_dout, while ports 0
	// and 4 return ONE. On port 0 the readback got a correct low half and a
	// permanently zero upper half -- which reads like a broken controller and
	// is a port-selection mistake. The CPU takes port 0 precisely because it
	// wants single words; 1-3 are the streaming ports.
	p_req[2]  = cp_req ? cp_req  : st_rd_req;
	p_addr[2] = cp_req ? cp_addr : st_rd_addr;
	// PORT 1, NOT PORT 0. m2_sdram's blen() gives ports 1-3 a four-word burst and
	// ports 0 and 4 a single word, and the copy engine was the ONLY consumer of a
	// single-word read -- and the only reader that fails. The self-test on port 2
	// and the char fetch on port 3 both burst four and both behave.
	//
	// The checksums also CHANGED between two runs of identical hardware and data
	// (00E32CDB then 00E7958F), so the corruption is not deterministic, which
	// rules out a decode or wiring mistake and fits a capture path that is only
	// exercised by the single-word case.
	//
	// Port 1 is free here: the ROM readback that shares it now waits for cp_done,
	// so the two never overlap.
	// SWAPPED WITH THE CPU, deliberately, as an A/B.
	//
	// Port 1 reads the boot vector correctly on hardware and port 0 returns zero
	// for the same SDRAM at the same capture depth, and since both now burst
	// four words it is not the burst length. Whether the fault follows the PORT
	// or follows the CPU is the whole question, and swapping them answers it:
	//
	//   CPU works on 1, readback fails on 0  -> the fault is the port
	//   CPU still fails on 1                 -> the fault is the CPU path
	//
	// Either outcome is worth a build. Neither is a guess.
	p_req[0]  = rb_req;
	p_addr[0] = rb_addr;
	p_req[4]  = sw_req;
	p_addr[4] = sw_addr;
	// PORT 2 FOR THE COPY, which is the one port known to work.
	//
	// Port 0 failed (single word) and port 1 failed (four-word burst), while the
	// self-test on port 2 reads all four of its words back correctly every time.
	// So it is not the burst length -- it is the port. This changes nothing but
	// the index, so if the checksums come good the fault is port-specific and the
	// target is the arbiter's grant-to-tag path, which is a few lines.
	//
	// The self-test also uses port 2 and waits for cp_done, so they never overlap.
	p_req[3]  = cc_req;
	p_addr[3] = char_base + SDR_AW'(cc_addr);
	// PORT 0 IS THE CPU'S, and it is the single-word port on purpose: the
	// bridge issues one 16-bit access at a time, and ports 1-3 burst four.
	p_req[1]  = cpu_sd_req;
	p_addr[1] = cpu_sd_addr;
end
assign rb_dout = p_dout[0];
assign rb_ack  = p_ack[0];

// T_REFI IS IN CLOCK CYCLES, and this domain is now 96 MHz (see rtl/pll/pll.v):
// 8192 rows in 64 ms is one refresh every 7.8125 us, which is 312 cycles at 40 MHz
// and 625 at 80. Too large UNDER-REFRESHES, and that presents as random ROM
// corruption rather than as a timing setting.
// TIMING DELIBERATELY OVERSIZED, as a single test of the whole parameter space.
//
// Every read port has now failed for the copy engine while the self-test passes
// on the same ports, so it is not the port and not the burst length. The one
// difference left is the ACCESS PATTERN: the self-test reads four words at one
// address, staying inside a single open row, while the copy engine walks 36,864
// addresses across about eighteen rows and pays ACTIVATE, PRECHARGE and refresh
// interaction on every crossing. Row management is the part the passing test
// never exercises.
//
// Rather than sweep one parameter per ten-minute build, all of them are doubled
// at once. If comfortable row timing fixes it the cause is in this group and can
// then be narrowed; if it does not, the entire timing-parameter space is
// eliminated in one build and the fault is elsewhere.
// THE CONTROLLER RUNS AT TWICE THE CORE CLOCK, with m2_sdram_x2 between.
//
// Every requester here -- the i960's bridge, the tilemap copy engine, the
// character fetch, the read-back sweep and the ROM loader -- is on clk_sys, and
// they cannot all follow the memory to 96 MHz. The adapter halves every round
// trip as counted in CORE clocks without any of them changing.
//
// It is NOT a clock-domain crossing: 96 and 48 are /10 and /20 of one 960 MHz
// VCO, so the edges are aligned and every slow signal is stable across two fast
// cycles. It handles two pulse-width hazards instead, both of which the Kaneko16
// core found the hard way -- see the module header.
logic [NPORTS-1:0]           f_req, f_ack, f_we;
logic [NPORTS-1:0][SDR_AW:1] f_addr;
logic [NPORTS-1:0][15:0]     f_din;
logic [NPORTS-1:0][1:0]      f_be;
logic [NPORTS-1:0][63:0]     f_dout;
logic                        f_wr_req, f_wr_ack;
logic [SDR_AW:1]             f_wr_addr;
logic [15:0]                 f_wr_din;
logic [1:0]                  f_wr_be;

m2_sdram_x2 #(.NP(NPORTS), .AW(SDR_AW)) u_sdram_x2 (
	.clk_fast(clk_mem),
	.s_req(p_req), .s_addr(p_addr), .s_ack(p_ack), .s_dout(p_dout),
	.s_we(p_we),   .s_din(p_din),   .s_be(p_be),
	.s_wr_req(st_run ? st_req : ldr_wr_req),
	.s_wr_addr(st_run ? st_addr : ldr_wr_addr),
	.s_wr_din(st_run ? st_din : ldr_wr_din),
	.s_wr_be(2'b11), .s_wr_ack(ldr_wr_ack),
	.f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
	.f_we(f_we),   .f_din(f_din),   .f_be(f_be),
	.f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
	.f_wr_be(f_wr_be),   .f_wr_ack(f_wr_ack)
);

// CL2, WHICH IS WHAT WORKS ON THIS BOARD AT THIS CLOCK. Briefly changed to CL3
// on the reasoning that a varying pass mask meant marginal device timing, and
// CL2 at 96 MHz asks for data 20.8 ns after READ where at 40 MHz it meant 50.
// The Kaneko16 core runs this same controller at 96 MHz on this same board with
// CL2 and a capture of CL+4, so the device is not the limit and the latency did
// not need raising. Reverted rather than left in as a harmless-looking change
// that was aimed at the wrong thing.
m2_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(750)) u_sdram (
	.clk(clk_mem), .rst_n(mem_rst_n), .ready(mem_ready),
	// OSD order is CL+2..CL+5 and the selector's own encoding puts CL+3 at zero,
	// so the two are mapped rather than passed through.
	// Labels match what selecting them does: 0->CL+1, 1->CL+0, 2->CL+2, 3->CL+3.
	// The default is CL+1, one cycle EARLIER than the old default of CL+2, which
	// the self-test showed captures the burst one 16-bit word late.
	// SWEPT WHILE CALIBRATING, then held at what passed. The OSD still
	// overrides once the sweep has finished and found nothing, so a board this
	// cannot calibrate is still tunable by hand.
	// AUTO BY DEFAULT, MANUAL WHEN ASKED. status[7:5] == 0 means "use the
	// calibration"; 1..5 force CL+1..CL+5 so a board this cannot calibrate is
	// still tunable by hand without a rebuild. During the sweep itself the
	// controller follows cal_sel, because that is what is being measured.
	.rd_lat_sel(!cal_done          ? cal_sel      :
	            (status[7:5] != 0) ? status[7:5]  : cal_best),
	.sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
	.sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
	.wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
	.wr_be(f_wr_be),   .wr_ack(f_wr_ack),
	.p_req(f_req), .p_we(f_we), .p_addr(f_addr), .p_din(f_din), .p_be(f_be),
	.p_dout(f_dout), .p_ack(f_ack),
	.dbg_req(), .dbg_grant()
);

assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
// ITS OWN PLL OUTPUT AT 180 DEGREES, not an inversion of the controller clock.
// pll.v's own note diagnosed the 80 MHz failure as exactly that inversion --
// "only a half period of skew and no true phase shift" -- and named this as the
// fix. outclk_4 is a real output counter with a real phase shift.
assign SDRAM_CLK = clk_sdram_pin;

// `ioctl_wait` STALLS THE HPS ITSELF, so the loader gates it on `ioctl_download`
// internally — and it ASKS the host to stop rather than stopping it, which is why
// it buffers into a FIFO with margin instead of trusting the wait to take effect.
m2_rom_loader #(.SDR_AW(SDR_AW)) u_loader (
	.clk(clk_sys), .rst(~mem_rst_n),
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

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
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
			// Also waits for the copy, for the same reason.
			// WORD 6, not 8: this now reads exactly what the i960's boot reads for
			// its IP -- mem[12] is words 6 and 7 -- so it is the same data through a
			// DIFFERENT PORT. Port 1 bursts four words and is known to work; the CPU
			// is on port 0. If this reads 00000860 and the CPU reads 0, the data is
			// in SDRAM and the fault is the CPU's port.
			// cal_done, NOT cp_done: game_image short-circuits cp_done without
			// reading anything, so on a game image cp_done asserts before the
			// capture is calibrated and this read came back at CL+0. That is the
			// "row 2 reads FFFFFFFF, then 00000860 after three resets" the bench
			// saw -- it was never marginal SDRAM, it was an uncalibrated read.
			2'd0: if (rom_loaded && cal_done) begin rb_addr <= SDR_AW'(6); rb_req <= 1'b1; rb_state <= 2'd1; end
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
// INSIDE THE ADDRESS SPACE, and that is not a detail. SDR_AW is 25 bits, so the
// controller addresses 0x2000000 words -- exactly 64 MB -- and the last valid
// word is 0x1FFFFFF. The old value here was 0x2000000, ONE PAST THE END, and
// SDR_AW'() truncated it to ZERO: the self-test wrote AA55 5AA5 FF00 00FF over
// word addresses 0 to 3, which is byte addresses 0 to 7, which is the i960's
// BOOT RECORD -- SAT at 0 and PRCB at 4.
//
// It cost nothing for as long as nothing executed from SDRAM. The first boot of
// the CPU on hardware read its own startup state out of a memory test pattern,
// jumped to it, and trapped after one instruction. The overlay showed IP =
// AA55AA55, which is the pattern rather than an address.
//
// 0x1F00000 is inside the space and clear of the game map, whose highest region
// (char RAM) ends at 0x16D0000.
localparam logic [SDR_AW:1] ST_BASE = SDR_AW'(32'h1F00000);

// An address that does not fit is a wrap, not an error, and a wrap to zero is
// the worst possible landing place. Checked at elaboration so it can never
// again be discovered on a board.
initial begin
	if (32'h1F00000 >= (32'd1 << SDR_AW))
		$error("ST_BASE does not fit in SDR_AW=%0d bits and will wrap", SDR_AW);
	if (32'h16D0000 >= (32'd1 << SDR_AW))
		$error("the game map does not fit in SDR_AW=%0d bits", SDR_AW);
end

logic            st_run, st_req, st_rd_req;
// The capture-depth sweep: which of the six settings reads back the pattern.
logic  [2:0]     cal_sel;
logic  [5:0]     cal_mask;
logic  [5:0]     cal_wait;
logic            cal_done;
// THE CENTRE OF THE WIDEST PASSING RUN, not the lowest bit that happened to be
// set.
//
// This picked the lowest, on the reasoning that "a shallower capture that reads
// correctly has more margin against whatever slows the path down next". That is
// backwards. A capture window is a CONTIGUOUS RUN of depths that work; its edges
// are where the data is only just there and its centre is where it is safely
// there. Picking the lowest set bit deliberately selects the ragged edge.
//
// The board proved it: the sweep saw CL+2 and CL+4 pass and CL+2 was chosen, and
// CL+2 read the boot IP back wrong in a single bit while the Kaneko16 core runs
// this same controller at this same clock on this same board at CL+4. The mask
// was not even depth-ordered at the time -- index 0 was CL+2, 1 was CL+0 -- so
// "lowest" did not mean "earliest" either.
//
// Six depths, so the runs are enumerated rather than computed. Longest first,
// and among equals the later one, because a late window has the data settled
// while an early one is waiting for it.
wire [5:0] m = cal_mask;
wire [2:0] cal_scan =
  (m[1] & m[2] & m[3] & m[4] & m[5]) ? 3'd3 :   // 1-5, centre 3
  (m[0] & m[1] & m[2] & m[3] & m[4]) ? 3'd2 :   // 0-4, centre 2
  (m[2] & m[3] & m[4] & m[5])        ? 3'd3 :   // 2-5, centre 3 (later of 3,4)
  (m[1] & m[2] & m[3] & m[4])        ? 3'd2 :
  (m[0] & m[1] & m[2] & m[3])        ? 3'd1 :
  (m[3] & m[4] & m[5])               ? 3'd4 :
  (m[2] & m[3] & m[4])               ? 3'd3 :
  (m[1] & m[2] & m[3])               ? 3'd2 :
  (m[0] & m[1] & m[2])               ? 3'd1 :
  (m[4] & m[5])                      ? 3'd5 :   // pair: take the later
  (m[3] & m[4])                      ? 3'd4 :
  (m[2] & m[3])                      ? 3'd3 :
  (m[1] & m[2])                      ? 3'd2 :
  (m[0] & m[1])                      ? 3'd1 :
  m[5] ? 3'd5 : m[4] ? 3'd4 : m[3] ? 3'd3 :     // lone survivor: take it
  m[2] ? 3'd2 : m[1] ? 3'd1 : m[0] ? 3'd0 :
  3'd4;                                         // nothing passed: CL+4, which
                                                // is what the Kaneko16 core uses
                                                // on THIS board at THIS clock --
                                                // a measured value from a
                                                // working design, not a guess
wire   [2:0]     cal_best = cal_scan;
assign cal_done = (st_state == 4'd12);
logic [SDR_AW:1] st_addr, st_rd_addr;
logic [15:0]     st_din;
logic [3:0]      st_state;
logic [63:0]     st_got;

// The self-test collapses to a single bit rather than consuming two display
// slots. It keeps running and keeps looping, so a regression in the SDRAM path
// shows up as this bit dropping rather than as confusing ROM values -- which is
// how four builds were spent.
// ANY DEPTH READING CORRECTLY, not the one currently selected. During the
// sweep the live comparison flickers as each depth is tried, so a status bit
// taken from it says only what the last attempt did. `cal_mask` is what the
// memory is capable of.
wire st_ok = |cal_mask;

// WHAT ARRIVED versus WHAT WAS STORED, at the same two words.
//
// The SDRAM self-test passes, so the memory and the write port are good, which
// means the ROM data is already wrong before it is stored. Everything so far has
// inferred that from what came back out. This latches ioctl_dout itself as it
// goes past, at the byte addresses corresponding to stream words 8 and 9.
//
//   word5 = what ARRIVED over ioctl   -> expect FFFFF6E0
//   word6 = what is IN SDRAM there    -> expect FFFFF6E0
//
// Both right: the fault is downstream of here, in the readback.
// Both wrong: the data is already wrong when the HPS hands it over.
// 5 right, 6 wrong: the loader or the write path corrupts it.
logic [15:0] pr_w8, pr_w9;

// THE MISSING LINK. Arrived is correct and stored is wrong; this is what the
// loader PRESENTS to the controller, latched on the rising edge of the write
// request -- which is exactly when the controller captures it.
//
//   word5 = ARRIVED over ioctl        (known correct: FFFFF6E0)
//   word6 = PRESENTED by the loader   (want FFFFF6E0)
//
// Presented correct -> the loader is fine and the controller drops the high byte.
// Presented wrong   -> the loader corrupts it between ioctl and its own output,
//                      and the FIFO is already exonerated, so it is the path
//                      around the FIFO.
logic [15:0] pw_w8, pw_w9;
logic        ldr_req_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		pw_w8 <= 16'd0; pw_w9 <= 16'd0; ldr_req_d <= 1'b0;
	end else begin
		ldr_req_d <= ldr_wr_req;
		if (ldr_wr_req && !ldr_req_d) begin
			if (ldr_wr_addr == SDR_AW'(137)) pw_w8 <= ldr_wr_din;
			if (ldr_wr_addr == SDR_AW'(138)) pw_w9 <= ldr_wr_din;
		end
	end
end
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		pr_w8 <= 16'd0; pr_w9 <= 16'd0;
	end else if (ioctl_download && ioctl_wr) begin
		// WORDS 137/138 OF THE TILEMAP BLOB: 8CC6 and 8CC7.
		//
		// The previous probe used words 8/9, whose value in this blob is 0x0020
		// twice -- ZERO HIGH BYTE. A fault that zeroes high bytes is invisible on
		// such data, so the probe read 00200020 at every stage and proved nothing.
		// That is the same trap that made the tilemap blob 'prove' step 3 earlier.
		// These two have non-zero high bytes and therefore CAN fail.
		if (ioctl_addr == 27'h112) pr_w8 <= ioctl_dout;
		if (ioctl_addr == 27'h114) pr_w9 <= ioctl_dout;
	end
end

assign st_run = rom_loaded && (st_state >= 4'd1) && (st_state <= 4'd8);

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		st_state <= 4'd0; st_req <= 1'b0; st_rd_req <= 1'b0;
		st_addr <= '0; st_rd_addr <= '0; st_din <= 16'd0; st_got <= 64'd0;
		cal_sel <= 3'd0; cal_mask <= 6'd0; cal_wait <= 6'd0;
	end else begin
		case (st_state)
			// RUNS FIRST, AND EVERYTHING THAT READS SDRAM WAITS FOR IT.
			//
			// This used to wait for the copy engine, to stop three read ports
			// issuing at once. That ordering was exactly backwards, and it cost
			// the 2D tilemap test its picture (study R47). `rd_lat_sel` follows
			// `cal_sel` while `!cal_done`, and `cal_sel` resets to 0 -- so
			// ANY read issued before this completes is captured at CL+0. At 40
			// MHz that happened to be close enough; at 96 MHz the board reads
			// CL+2 and CL+0 is two words early, i.e. garbage.
			//
			// The copy engine reads tile RAM, the palette and colorxlat ONCE and
			// latches them into M10K, so it does not merely read garbage, it
			// KEEPS it -- calibrating afterwards cannot repair a copy already
			// made. Char RAM is fetched live and so came back correct, which is
			// why the screen showed real pixels in one flat wrong colour.
			//
			// Contention is still avoided; the wait just points the other way.
			// ST_BASE is word 0x1F00000, ~62 MB up, clear of both images.
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
			// CALIBRATE THE READ CAPTURE INSTEAD OF ASKING SOMEONE TO GUESS IT.
			//
			// The four words above are written at a known address; reading them
			// back is a test whose right answer is known in advance. Doing that
			// once, at whatever depth the OSD happens to be set to, throws away
			// the fact that it can be done SIX TIMES and the depth that works
			// identified outright.
			//
			// This project has been stuck on capture phase three times. At 40 MHz
			// the range had to move earlier because the burst came back one
			// 16-bit word late; at 96 MHz the board needs later than anything the
			// two-bit selector could express, and the symptom -- garbage at every
			// setting -- was once read as "the phase is not involved". A sweep
			// with a known answer ends that argument each time the clock changes.
			4'd8: begin
				st_rd_addr <= ST_BASE; st_rd_req <= 1'b1; st_state <= 4'd9;
			end
			4'd9: if (p_ack[2]) begin
				st_got <= p_dout[2]; st_rd_req <= 1'b0; st_state <= 4'd10;
			end
			4'd10: begin
				// One bit per depth. The pattern is 64 bits of known data, so a
				// depth that is off by a single 16-bit word cannot pass by luck.
				cal_mask[cal_sel] <= (p_dout[2] == 64'h00FF_FF00_5AA5_AA55);
				if (cal_sel == 3'd5) st_state <= 4'd12;
				else begin
					cal_sel  <= cal_sel + 3'd1;
					cal_wait <= 6'd40;      // let cap_depth settle before reading
					st_state <= 4'd11;
				end
			end
			4'd11: if (cal_wait == 6'd0) st_state <= 4'd8;
			       else                  cal_wait <= cal_wait - 6'd1;
			4'd12: st_state <= 4'd12;      // done; cal_mask holds
			default: st_state <= 4'd0;
		endcase
	end
end

// Static once captured, so a two-flop synchroniser on the status bit is enough:
// the data is not moving when the video domain reads it.
logic [2:0] loaded_sync, st_ok_sync;
always_ff @(posedge clk_vid) begin
	loaded_sync <= {loaded_sync[1:0], rom_loaded};
	st_ok_sync  <= {st_ok_sync[1:0],  st_ok};
end

///////////////////////   TILEMAP   /////////////////////////////
//
// S24TILE, the same chip Model 2 and Model 1 both use. No CPU exists in this
// slice, so nothing writes the tilemap; the contents come from a state captured
// out of MAME at a known frame (docs/rom-layout.md) and streamed in as ROM:
//
//   blob byte 0x000000  +0x10000   tile RAM  -> on-chip, SDRAM words 0x0000..0x7FFF
//   blob byte 0x010000  +0x04000   palette   -> on-chip, SDRAM words 0x8000..0x9FFF
//   blob byte 0x014000  +0x80000   char RAM  -> read from SDRAM at word 0xA000
//
// Tile RAM and the palette are small and randomly accessed, so they are copied
// once into on-chip memory. Char data is 512 KB and streamed, so it stays in
// SDRAM and is fetched per line, which is what the Model 1 core does.
localparam logic [SDR_AW:1] TRAM_BASE = SDR_AW'(32'h00000);
localparam logic [SDR_AW:1] PAL_BASE  = SDR_AW'(32'h08000);
localparam logic [SDR_AW:1] CHAR_BASE = SDR_AW'(32'h0A000);
// Colour translation table, appended after char RAM. Model 2's palette runs
// each 5-bit channel through it before the gamma curve -- m2_palette.sv, study
// R27 -- and without it every fill colour in every game is a few units out.
// Byte 0x094000 in the image, which is word 0x4A000.
localparam logic [SDR_AW:1] XLAT_BASE = SDR_AW'(32'h4A000);

// ------------------------------------------------------------- the game map
//
// Word addresses, and they sit ABOVE the ROM image the MRA lays down. The
// Daytona MRA loads 0x2BA0000 bytes -- 43.62 MB -- so the RAM regions start at
// a word address clear of it. Total with RAM is about 45.6 MB, inside the 64 MB
// R19 MEASURED. GAME_WORK sits 0x30000 words above the last ROM word, which is
// margin, not a coincidence to rely on.
//
// This figure was 0x2BE0000 until R39. `tools/rom_csum.py` expanded two
// output="16" byte-swap interleaves as though they were 32-bit, adding 256 KB
// that is not in the set, and every part after Daytona's 68000 sound ROMs then
// sat 256 KB late in the reconstruction. The BOARD had them in the right place
// throughout; the reference did not.
//
// These are ROM offsets from the MRA's own ordering:
//   0x00000000  program ROM   (epr-16530a + epr-16531a, interleaved to 32 bits)
//   0x00040000  main_data     (mpr-16528 onwards)
localparam logic [SDR_AW:1] GAME_PROG  = SDR_AW'(32'h0000000);   // byte 0
localparam logic [SDR_AW:1] GAME_DATA  = SDR_AW'(32'h0020000);   // byte 0x40000
localparam logic [SDR_AW:1] GAME_WORK  = SDR_AW'(32'h1600000);   // 1 MB
localparam logic [SDR_AW:1] GAME_BOARD = SDR_AW'(32'h1680000);   // 128 KB
localparam logic [SDR_AW:1] GAME_CHAR  = SDR_AW'(32'h1690000);   // 512 KB

// WHERE CHARACTER RAM LIVES, AS ONE SIGNAL, because two things that must agree
// should not be two constants (study R51).
//
// They were. The CPU bridge was given GAME_CHAR -- word 0x1690000 -- and wrote
// Daytona's characters there, while the renderer's fetch port read CHAR_BASE,
// word 0x0A000, unconditionally. On the tilemap-test image those are the same
// place, because the fixture puts char RAM at 0x14000 bytes and no CPU runs. On
// a GAME image word 0x0A000 is program ROM, so the renderer drew Daytona's text
// out of i960 instructions -- the same "program ROM rendered as tiles" this
// board has shown once before, for a different reason.
//
// That is why R49's crossing and R50's cache fixed the tilemap test outright
// and left Daytona UNCHANGED: its characters were never late, they were never
// being read from the right address at all.
//
// Both consumers now take this wire. The failure mode required two constants to
// be kept in step by hand, and this removes the hand.
wire [SDR_AW:1] char_base = game_image ? GAME_CHAR : CHAR_BASE;

(* ramstyle = "M10K" *) logic [15:0] tram [32768];
// 8192 ENTRIES, NOT 4096. The palette at 0x01800000 is 0x4000 BYTES -- 8,192
// 16-bit words -- confirmed against tools/mame_m2_tiledump.lua, which is what
// captures the reference frame. m2_cpu_bridge forms oc_addr as r_addr[15:1], so
// that region produces indices 0..8191, and this array was indexed
// `pal[ocb_addr[11:0]]`: every write above 4095 WRAPPED ONTO THE LOW HALF and
// overwrote the entries the tilemap draws with.
//
// Daytona's test menu came out with its green values and NO WHITE LABELS, and
// the ground alternated green/brown across resets, because which of the two
// writes to an aliased entry landed last depended on timing.
//
// The tilemap fixture never showed it: the copy engine fills only the low 4,096
// and nothing writes above them, which is why that image renders pixel-perfectly
// while a game does not. Study R53.
//
// The renderer still reads the low half -- m2_tile_mixer's `mixed` is 12 bits --
// and that is not changed here. This stops the corruption; it does not claim the
// tilemap can reach the upper half.
(* ramstyle = "M10K" *) logic [15:0] pal  [8192];

wire [14:0] tram_addr;
wire [11:0] pal_addr;
logic [15:0] tram_data, pal_data;
always_ff @(posedge clk_vid) begin
	tram_data <= tram[tram_addr];
	pal_data  <= pal[{1'b0, pal_addr}];
end

// PORT B, on clk_sys: the copy engine and the CPU share it. Port A above is
// the renderer's, on clk_vid, and stays read-only. That is a true dual-port
// M10K, which is what the part gives; a third accessor would not fit and is
// why the copy engine and the bridge are muxed onto one port rather than given
// one each.
logic [15:0] cpu_tram_q, cpu_pal_q;

// XLAT WRITES, COUNTED PER CHANNEL. Daytona's test menu renders in green only,
// where the tilemap fixture renders white labels and green values correctly on
// the same hardware. White is (31,31,31): if the translation table's R and B
// map to zero and G does not, white comes out green -- and so does green, so
// every colour on the screen collapses to the one channel that survived.
//
// The fixture's table is loaded by the COPY ENGINE and is verified correct. On a
// game image the CPU writes it instead, through m2_cpu_bridge's oc_xlat_* path,
// and that path is the one nothing has ever measured. cpu_xlat_addr_b is
// {channel, entry}, so bits [6:5] name the channel and 32 writes to each is a
// complete table.
logic [7:0] xlat_ch_cnt [3];
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		xlat_ch_cnt[0] <= 8'd0; xlat_ch_cnt[1] <= 8'd0; xlat_ch_cnt[2] <= 8'd0;
	end else if (cpu_xlat_we_b && (cpu_xlat_addr_b[6:5] != 2'd3)) begin
		// Saturating: a count that wraps reads as a small number and says the
		// opposite of what happened.
		if (!(&xlat_ch_cnt[cpu_xlat_addr_b[6:5]]))
			xlat_ch_cnt[cpu_xlat_addr_b[6:5]] <= xlat_ch_cnt[cpu_xlat_addr_b[6:5]] + 8'd1;
	end
end
// ONE always_ff, one port. The copy engine wins when it is running, which it
// only does for the tilemap-test image, and the CPU is held in reset then --
// so the two never actually contend. The priority is written down anyway,
// because "they cannot overlap" is an argument and a mux is a guarantee.
wire        ocb_tram_we = cp_tram_we | cpu_tram_we;
wire        ocb_pal_we  = cp_pal_we  | cpu_pal_we;
wire [14:0] ocb_addr    = (cp_tram_we | cp_pal_we) ? cp_wr_idx  : cpu_oc_addr;
wire [15:0] ocb_din     = (cp_tram_we | cp_pal_we) ? cp_wr_data : cpu_oc_din;

always_ff @(posedge clk_sys) begin
	cpu_tram_q <= tram[ocb_addr];
	cpu_pal_q  <= pal[ocb_addr[12:0]];
	if (ocb_tram_we) tram[ocb_addr]      <= ocb_din;
	if (ocb_pal_we)  pal[ocb_addr[12:0]] <= ocb_din;
end


// COPY ENGINE. Walks tile RAM then the palette out of SDRAM into on-chip memory
// after the ROM has landed. Port 0, which returns a single word per request --
// 36,864 reads, once, at startup.
// CHECKSUMS OVER WHAT WAS ACTUALLY COPIED. One number validates all 32,768 tile
// RAM words and all 4,096 palette words, which two spot probes cannot -- and the
// control registers at 0x5000/0x5004 are all zero in this capture, so they are
// useless as a probe.
//
// Expected, computed from the dump files:
//   tile RAM  XOR A66F  SUM16 51B7   -> word5 = A66F51B7
//   palette   XOR 5BFD  SUM16 D5AF   -> word6 = 5BFDD5AF
//
// Both right: the copy is perfect and the fault is in the renderer.
// Either wrong: the data never arrived intact and the renderer is innocent.
logic [15:0] cp_xor_t, cp_sum_t, cp_xor_p, cp_sum_p;

// The copy engine no longer writes tile RAM and the palette directly. Those
// arrays now have exactly TWO accessors -- the renderer on clk_vid and this
// domain on clk_sys -- because a third one costs RAM inference: Quartus
// reported "cannot convert all sets of registers into RAM megafunctions" and
// 512 Kbit of tile RAM became flip-flops, which is four times the whole
// device. Three always_ff blocks touching one array is the cause; the copy
// engine and the CPU are muxed onto one port below.
logic        cp_tram_we, cp_pal_we;
logic [14:0] cp_wr_idx;
logic [15:0] cp_wr_data;

logic            cp_req, cp_done;
logic [SDR_AW:1] cp_addr;
logic [15:0]     cp_wdata;
logic [15:0]     cp_idx;
logic  [1:0]     cp_phase;          // 0 tile RAM, 1 palette, 2 translation table

// The translation table is read at a STRIDE OF 256 WORDS, three channels of 32
// entries, so 96 reads rather than a walk. MAME's base offsets are 0x0080>>1,
// 0x4080>>1 and 0x8080>>1 in words.
logic [SDR_AW:1] xlat_rd_addr;
always_comb begin
	case (cp_idx[6:5])
		2'd0:    xlat_rd_addr = XLAT_BASE + SDR_AW'(32'h0040);
		2'd1:    xlat_rd_addr = XLAT_BASE + SDR_AW'(32'h2040);
		default: xlat_rd_addr = XLAT_BASE + SDR_AW'(32'h4040);
	endcase
	xlat_rd_addr = xlat_rd_addr + SDR_AW'({cp_idx[4:0], 8'd0});
end

// STAGED, then committed. The table only replaces pal5bit if the data looks
// like a translation table -- entry 0 maps to 0 and entry 31 to 255 on every
// channel. A core loaded with an image that predates this section would
// otherwise read 96 words of whatever follows char RAM as a colour curve and
// turn the picture to noise, and the device cannot be tested from here, so the
// guard stands in for trying it.
//
// It is STAGED rather than written as it arrives because a guard that trips
// part way through has already corrupted the entries before it: writing on
// arrival and blocking the rest leaves a half-replaced table, which is worse
// than either accepting or rejecting the lot.
logic [7:0] xlat_stage [96];
logic       xlat_ok;
logic [7:0] xlat_first;
logic       xlat_we_r;
logic [6:0] xlat_addr_r;
logic [7:0] xlat_din_r;

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		cp_req <= 1'b0; cp_done <= 1'b0; cp_idx <= 16'd0;
		cp_phase <= 2'd0; cp_addr <= '0;
		cp_xor_t <= 16'd0; cp_sum_t <= 16'd0;
		cp_xor_p <= 16'd0; cp_sum_p <= 16'd0;
		xlat_we_r <= 1'b0; xlat_addr_r <= 7'd0; xlat_din_r <= 8'd0;
		xlat_ok <= 1'b1; xlat_first <= 8'd0;
		cp_tram_we <= 1'b0; cp_pal_we <= 1'b0; cp_wr_idx <= 15'd0; cp_wr_data <= 16'd0;
	end else if (!cp_done) begin
		xlat_we_r  <= 1'b0;
		cp_tram_we <= 1'b0;
		cp_pal_we  <= 1'b0;
		if (game_image) begin
			// Nothing to copy: the CPU writes tile RAM, the palette and the
			// translation table itself.
			cp_done <= 1'b1;
		end else if (cp_phase == 2'd3) begin
			// Commit phase: no bus traffic, one entry per cycle.
			xlat_we_r   <= xlat_ok;
			xlat_addr_r <= cp_idx[6:0];
			xlat_din_r  <= xlat_stage[cp_idx[6:0]];
			if (cp_idx == 16'd95) cp_done <= 1'b1;
			else cp_idx <= cp_idx + 16'd1;
		// NOT UNTIL THE CAPTURE IS CALIBRATED. This copy is made once and kept
		// (study R47), so reading it at the wrong depth is permanent.
		end else if (!cp_req && rom_loaded && cal_done) begin
			case (cp_phase)
				2'd0:    cp_addr <= TRAM_BASE + SDR_AW'(cp_idx);
				2'd1:    cp_addr <= PAL_BASE  + SDR_AW'(cp_idx);
				default: cp_addr <= xlat_rd_addr;
			endcase
			cp_req  <= 1'b1;
		end else if (cp_req && p_ack[2]) begin
			cp_req   <= 1'b0;
			cp_wdata <= p_dout[2][15:0];
			case (cp_phase)
				2'd0: begin
					cp_tram_we <= 1'b1;
					cp_wr_idx  <= cp_idx[14:0];
					cp_wr_data <= p_dout[2][15:0];
					cp_xor_t <= cp_xor_t ^ p_dout[2][15:0];
					cp_sum_t <= cp_sum_t + p_dout[2][15:0];
					if (cp_idx == 16'h7FFF) begin cp_idx <= 0; cp_phase <= 2'd1; end
					else cp_idx <= cp_idx + 16'd1;
				end
				2'd1: begin
					cp_pal_we  <= 1'b1;
					cp_wr_idx  <= {3'd0, cp_idx[11:0]};
					cp_wr_data <= p_dout[2][15:0];
					cp_xor_p <= cp_xor_p ^ p_dout[2][15:0];
					cp_sum_p <= cp_sum_p + p_dout[2][15:0];
					if (cp_idx == 16'h0FFF) begin cp_idx <= 0; cp_phase <= 2'd2; end
					else cp_idx <= cp_idx + 16'd1;
				end
				default: begin
					xlat_stage[cp_idx[6:0]] <= p_dout[2][7:0];
					if (cp_idx[4:0] == 5'd0)  xlat_first <= p_dout[2][7:0];
					if (cp_idx[4:0] == 5'd31 &&
					    !(xlat_first == 8'd0 && p_dout[2][7:0] == 8'd255))
						xlat_ok <= 1'b0;
					if (cp_idx == 16'd95) begin cp_idx <= 0; cp_phase <= 2'd3; end
					else cp_idx <= cp_idx + 16'd1;
				end
			endcase
		end
	end
end

// ============================================================== THE i960
//
// It runs at 25 MHz on its own PLL output because that is what it fits at --
// 26.4 MHz measured, study R23 -- while everything it talks to runs at 40 MHz
// with the SDRAM. m2_cpu_bridge owns that crossing; see its header for why it
// is a handshake and not a FIFO, and for the req-versus-req-and-ack fault that
// deadlocked the Model 1 TGP on hardware.
//
// HELD IN RESET UNTIL THE ROM HAS LANDED. The first thing the part does is read
// its boot record from mem[0], mem[4] and mem[12]; releasing it before the
// loader has finished means it reads whatever SDRAM powered up holding and
// walks off into unmapped space, which presents as a dead CPU rather than as a
// race.
// WHICH IMAGE WAS LOADED, and therefore which of two modes this is.
//
//   small  -- the 2D tilemap test, 0xA0000 bytes of captured state. The copy
//             engine walks it into tile RAM and the palette, and there is no
//             game ROM, so the CPU MUST STAY IN RESET: released, it would
//             execute whatever the capture happens to contain and write over
//             the tilemap it is supposed to be displaying.
//   large  -- the game, 43.62 MB. The copy engine must NOT run: its bases point
//             at what is now the program ROM, so it would spend 36,864 reads
//             copying code into tile RAM, and the CPU owns those arrays anyway.
//
// Decided by the highest address the loader wrote, which is a fact about the
// image rather than a mode the user has to select correctly.
logic [SDR_AW:1] ldr_top;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) ldr_top <= '0;
	// ON req ALONE, not req AND ack. This dedicated write port does NOT use the
	// level handshake the numbered ports use: m2_rom_loader PULSES req and drops
	// it immediately -- "req pulsed so the controller sees a rising edge" -- then
	// waits for the ACK EDGE. So `req && ack` is never true, ldr_top stayed 0,
	// game_image was permanently false, and the copy engine ran on the 43.62 MB
	// game image and filled tile RAM with i960 program code. That is what the
	// board displayed as scrolling colour noise.
	//
	// The address is presented with the request, so sampling on req is correct
	// and does not depend on when the controller answers.
	else if (ldr_wr_req && (ldr_wr_addr > ldr_top)) ldr_top <= ldr_wr_addr;
end
wire game_image = rom_loaded && (ldr_top > SDR_AW'(32'h0080000));

// THE CPU FOLLOWS THE GAME RESET; THE MEMORY DOES NOT.
//
// This was `mem_rst_n & rom_loaded & game_image`, and mem_rst_n is pll_locked
// alone -- so pressing reset dropped game_rst_n and the i960 never saw it. Nor
// did m2_ioboard or m2_backup, which are on this same net. Reset did nothing to
// the machine, which makes every observation on the board unrepeatable: there
// is no way to tell a counter that stopped from one that was never restarted.
//
// mem_rst_n stays exactly as it was, and that is the standing rule rather than
// an oversight: "Memory comes out of reset on PLL lock and stays out, separate
// from the game reset." The SDRAM's bring-up and the loaded image must survive
// a reset; the CPU must not.
// HELD UNTIL THE CAPTURE IS CALIBRATED (study R47). The i960's first act out
// of reset is four reads -- SAT, PRCB, IP and the initial FP -- and they were
// being issued at CL+0 because cal_sel resets to 0 and calibration had not run
// yet. Boot vectors captured two words early are garbage, and the CPU then runs
// from them. The overlay's intermittent PRCB/IP was this, not marginal SDRAM.
wire cpu_rst_n = game_rst_n & rom_loaded & game_image & cal_done;

wire        cpu_req, cpu_we;
wire [31:0] cpu_addr, cpu_wdata, cpu_rdata;
wire  [3:0] cpu_be;
wire        cpu_ack;
wire [3:0]  cpu_irq;
wire [31:0] cpu_dbg_pc, cpu_dbg_ip, cpu_dbg_insn, cpu_dbg_icr, cpu_dbg_intr, cpu_dbg_acc;
// SAT and PRCB are what the boot walk READ OUT OF MEMORY. They answer the one
// question the IP cannot: whether the boot record came back correctly. An IP of
// zero could be a bad read or a CPU that never started, and these separate them.
wire [31:0] cpu_dbg_sat, cpu_dbg_prcb;
wire [31:0] cpu_dbg_laddr, cpu_dbg_ldout, cpu_dbg_p6, cpu_dbg_p2;
wire [31:0] cpu_dbg_tramwr, cpu_dbg_palwr;
wire        cpu_trap, cpu_halted;
wire [7:0]  cpu_trap_op;

i960_top u_i960 (
	.clk(clk_i960), .rst_n(cpu_rst_n),
	.bus_req(cpu_req), .bus_we(cpu_we), .bus_addr(cpu_addr), .bus_be(cpu_be),
	.bus_wdata(cpu_wdata), .bus_rdata(cpu_rdata), .bus_ack(cpu_ack),
	.irq(cpu_irq),
	.dbg_pc(cpu_dbg_pc), .dbg_sat(cpu_dbg_sat), .dbg_prcb(cpu_dbg_prcb),
	.dbg_icr(cpu_dbg_icr),
	.dbg_intr_cnt(cpu_dbg_intr), .dbg_intr_work(), .dbg_acc_cnt(cpu_dbg_acc),
	.dbg_ip(cpu_dbg_ip), .dbg_insn(cpu_dbg_insn),
	.trap(cpu_trap), .trap_op(cpu_trap_op), .halted(cpu_halted)
);

wire        cpu_tram_we, cpu_pal_we, cpu_xlat_we_b;
wire [14:0] cpu_oc_addr;
wire [15:0] cpu_oc_din;
wire  [6:0] cpu_xlat_addr_b;
wire  [7:0] cpu_xlat_din_b;
wire        cpu_io_sel, cpu_io_we;
wire  [3:0] cpu_io_be;
wire [31:0] cpu_io_addr, cpu_io_wdata, cpu_io_rdata;
wire        cpu_sd_req, cpu_sd_we;
wire [SDR_AW:1] cpu_sd_addr;
wire [15:0] cpu_sd_din;
wire  [1:0] cpu_sd_be;
wire [31:0] cpu_dbg_rd, cpu_dbg_wr, cpu_dbg_unmapped;

m2_cpu_bridge #(.AW(SDR_AW), .BOARD_2A(1'b0)) u_cpu_bridge (
	.clk_cpu(clk_i960), .rst_n_cpu(cpu_rst_n),
	.bus_req(cpu_req), .bus_we(cpu_we), .bus_addr(cpu_addr), .bus_be(cpu_be),
	.bus_wdata(cpu_wdata), .bus_rdata(cpu_rdata), .bus_ack(cpu_ack),

	.clk_mem(clk_sys), .rst_n_mem(cpu_rst_n),
	.base_prog(GAME_PROG), .base_data(GAME_DATA), .base_work(GAME_WORK),
	.base_board(GAME_BOARD), .base_char(char_base),

	.sd_req(cpu_sd_req), .sd_we(cpu_sd_we), .sd_addr(cpu_sd_addr),
	.sd_din(cpu_sd_din), .sd_be(cpu_sd_be),
	.sd_dout(p_dout[1]), .sd_ack(p_ack[1]),

	.oc_tram_we(cpu_tram_we), .oc_pal_we(cpu_pal_we),
	.oc_addr(cpu_oc_addr), .oc_din(cpu_oc_din),
	.oc_tram_q(cpu_tram_q), .oc_pal_q(cpu_pal_q),

	.oc_xlat_we(cpu_xlat_we_b), .oc_xlat_addr(cpu_xlat_addr_b),
	.oc_xlat_din(cpu_xlat_din_b),

	.io_rdata(cpu_io_rdata), .io_sel(cpu_io_sel), .io_we(cpu_io_we),
	.io_addr(cpu_io_addr), .io_wdata(cpu_io_wdata), .io_be(cpu_io_be),

	.dbg_cpu_reads(cpu_dbg_rd), .dbg_cpu_writes(cpu_dbg_wr),
	.dbg_unmapped(cpu_dbg_unmapped),
	.dbg_last_addr(cpu_dbg_laddr), .dbg_last_dout(cpu_dbg_ldout),
	.dbg_probe6(cpu_dbg_p6), .dbg_probe2(cpu_dbg_p2),
	.dbg_tram_wr(cpu_dbg_tramwr), .dbg_pal_wr(cpu_dbg_palwr)
);

// ------------------------------------------------------------ the I/O the
// core answers itself. Transcribed from model2.cpp; each of these was found by
// logging the address a poll loop was reading, not by reasoning about it.
logic [11:0] io_intreq, io_intena;
logic [31:0] io_videoctl;
logic [31:0] io_framenum;
logic        vbl_d, vbl_dd;

// V-blank into bit 0, the same line MAME's screen_vblank sets. irq_update()
// folds the twelve request bits onto the i960's four lines.
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		io_intreq <= 12'd0; io_intena <= 12'd0; io_videoctl <= 32'd0;
		io_framenum <= 32'd0; vbl_d <= 1'b0; vbl_dd <= 1'b0;
	end else begin
		vbl_d  <= vblank;
		vbl_dd <= vbl_d;
		if (vbl_d && !vbl_dd) begin
			io_framenum <= io_framenum + 32'd1;
			if (io_intena[0]) io_intreq[0] <= 1'b1;
		end
		if (cpu_io_sel && cpu_io_we) begin
			// irq_ack_w is `m_intreq &= data`. Treating it as a store leaves the
			// request asserted and the handler re-enters forever.
			if (cpu_io_addr[23:0] == 24'he80000) io_intreq  <= io_intreq  & cpu_io_wdata[11:0];
			if (cpu_io_addr[23:0] == 24'he80004) io_intena  <= cpu_io_wdata[11:0];
			if (cpu_io_addr[23:0] == 24'h98000c) io_videoctl <= cpu_io_wdata;
		end
	end
end

assign cpu_irq = { |(io_intreq & 12'hc00), |(io_intreq & 12'h3fc),
                   io_intreq[1],           io_intreq[0] };

// fifo_control_r returns 1 when the coprocessor's output FIFO is EMPTY. There
// is no TGP here, so "permanently drained" is the honest answer: it says the
// copro has finished, which for a copro that never starts is true. Reading as
// zero tells the game work is still queued and it waits forever -- 2.5 million
// reads of one address is what that looked like in simulation.
// THE SOUND BOARD, STUBBED -- two bytes, not an emulation.
//
// daytona93 is model2o, whose sound board is a separate 68000 behind a
// dual-port RAM at 0x01c00000, and the i960's boot will not go past a poll of
// it. There is no sound board here, so the poll is answered directly:
//
//   byte 0 of 0x01c00040 = 0x00    "no command outstanding"
//   byte 2 of 0x01c00042 = 0x40    the status the boot waits for
//
// The DPRAM is EIGHT BITS WIDE at bytes 0 and 2 of each dword -- model2.cpp
// maps it .umask32(0x00ff00ff) -- so both live in the same 32-bit word and the
// value is 0x00400000.
//
// These two bytes are a HANDSHAKE STATUS, not game content, which is why this
// lives in the core rather than in the ROM image. A 4 KB capture of MAME's
// DPRAM was tried first and gets no further: it produced the same boot and
// WORSE settings values, because a recording answers questions from a moment
// that is not this one.
//
// THE I/O BOARD ANSWERS ITS OWN REGION NOW. What used to be here was a constant
// -- 0x0040_0000 at one word address, zero everywhere else -- arrived at by
// sweeping values until the boot moved. It was called a sound-board stub and it
// was never the sound board: 0x01c00000 is an MB8421 dual-port RAM whose far
// side is SEGA_MODEL1IO, and the sound board is a UART at 0x01c80000 that the
// boot does not touch. Study R40.
//
// The constant could not have gone further than it did. The boot waits for the
// STATUS byte to read 0x40, then writes a command, then polls the FLAG byte for
// zero -- two bytes of one dword, moving at different times for different
// reasons. A constant satisfies whichever of them it was tuned for and deadlocks
// the other.
assign cpu_io_rdata =
	// THE WORD ADDRESS, ignoring the low two bits. The boot reads BOTH byte
	// 0x01c00040 and byte 0x01c00042 -- the DPRAM is eight bits wide at bytes 0
	// and 2 of the SAME dword -- and comparing the raw byte address matches only
	// the first, so the second read returned 0 where it needed 0x40 and the boot
	// stayed in the poll. The board showed it precisely: 4,097 tile RAM writes
	// against simulation's 12,292, then stopped, with the IP back at 0x2282xx.
	//
	// Simulation could not see it: the harness masks the address to the word
	// before comparing, so both byte addresses landed on the same case. Same
	// byte-versus-word confusion that made an earlier experiment report
	// identical cycle counts for every value it was given -- found once, written
	// down, then repeated in RTL.
	iob_sel                           ? iob_rdata :
	bak_sel                           ? bak_rdata :
	(cpu_io_addr[23:0] == 24'h980004) ? 32'd1 :
	// tgpid_r, 0x00980030-0x0098003f. A sixteen-byte signature the copro board
	// identifies itself with:
	//
	//   unsigned char ID[]={0,'T','A','H',0,'A','K','O',0,'Z','A','K',0,'M','T','K'};
	//
	// Returning zero here is a stub that reads as "a board that answered and
	// gave its name as nothing", which is the shape Model 1 was bitten by: an
	// identity read that gates a path, answered plausibly and wrongly.
	//
	// NOT the current boot blocker, and that is measured rather than assumed --
	// MAME's boot trace references this region once, at 0x980000, and never
	// reads the ID. It is here because it is known-wrong and costs four LUTs,
	// not because anything is waiting on it.
	(cpu_io_addr[23:4] == 20'h98003) ? tgpid :
	(cpu_io_addr[23:0] == 24'h98000c) ? (io_videoctl[0]
	                                      ? {29'd0, io_framenum[0], io_videoctl[1:0]}
	                                      : {28'd0, io_framenum[1], 1'b0, io_videoctl[1:0]}) :
	(cpu_io_addr[23:0] == 24'he80000) ? {20'd0, io_intreq} :
	(cpu_io_addr[23:0] == 24'he80004) ? {20'd0, io_intena} :
	32'd0;

// The ID is byte-wide; the i960 reads it a dword at a time and takes the lane
// its address selects, so all four lanes carry the byte for that offset.
wire [7:0] tgpid_b =
	(cpu_io_addr[3:0] == 4'h1) ? 8'h54 : (cpu_io_addr[3:0] == 4'h2) ? 8'h41 :
	(cpu_io_addr[3:0] == 4'h3) ? 8'h48 : (cpu_io_addr[3:0] == 4'h5) ? 8'h41 :
	(cpu_io_addr[3:0] == 4'h6) ? 8'h4B : (cpu_io_addr[3:0] == 4'h7) ? 8'h4F :
	(cpu_io_addr[3:0] == 4'h9) ? 8'h5A : (cpu_io_addr[3:0] == 4'hA) ? 8'h41 :
	(cpu_io_addr[3:0] == 4'hB) ? 8'h4B : (cpu_io_addr[3:0] == 4'hD) ? 8'h4D :
	(cpu_io_addr[3:0] == 4'hE) ? 8'h54 : (cpu_io_addr[3:0] == 4'hF) ? 8'h4B : 8'h00;
wire [31:0] tgpid = {4{tgpid_b}};

// ------------------------------------------------------------- I/O BOARD
//
// 0x01c00000-0x01c00fff. cpu_io_addr carries the low 24 bits, so the region is
// 0xc00xxx here -- the same address the old stub matched as [23:2] == 0x300010,
// which is 0xc00040.
wire        iob_sel   = cpu_io_sel && (cpu_io_addr[23:12] == 12'hc00);
wire [31:0] iob_rdata;
wire [31:0] iob_dbg;
wire [15:0] iob_win_rd, iob_flag_rd, iob_seen;

// Backup SRAM, 0x01d00000-0x01d03fff. It did not exist: the bridge routed this
// to T_IO and nothing answered, so the i960's copy of the I/O board's identity
// block went into a void and read back as zeros. Study R41.
wire        bak_sel = cpu_io_sel && (cpu_io_addr[23:14] == 10'b11_0100_0000);
wire [31:0] bak_rdata;
wire [31:0] bak_w0;
wire [15:0] bak_writes;

// CLOCKED ON clk_sys, NOT clk_i960, AND THAT IS THE WHOLE POINT.
//
// io_sel, io_addr and the r_rdata sample all live in m2_cpu_bridge's clk_mem
// domain, which is clk_sys. Clocking a REGISTERED read on a different clock
// is a crossing with no synchroniser, and its failure is selective in a way
// that looks like a data bug rather than a timing one:
//
//   a POLL survives it -- the same address read over and over, the value
//   settles, and the read eventually returns the right byte. Overlay row 14 was
//   perfect and the i960 cleared both handshake polls.
//
//   a ONE-SHOT SEQUENTIAL READ does not. The 128-byte block copy at 0022827C
//   reads each address once, and each read can return the previous address's
//   data.
//
// So the board answered, the block was pushed, backup SRAM existed, and the
// copy still arrived corrupted -- 4,097 tile writes for a third build.
// THE CPU'S ACTUAL I/O TRAFFIC, latched. Everything else in this overlay is a
// count or a state; this is the address the i960 presented and the word it got
// back. The counters have narrowed the fault to "the copy runs with the wrong
// pointer" -- row 17 says the polls read 4000 and pass, row 10 unwinds to
// 0x22825C so the block is executing, and rows 15/16 say the window is never
// read and backup SRAM never written. If g6 held 0x01c00200 those counters
// could not both be zero. This says what it holds instead.
logic [31:0] io_last_addr, io_last_data;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		io_last_addr <= 32'd0; io_last_data <= 32'd0;
	end else if (cpu_io_sel) begin
		io_last_addr <= cpu_io_addr;
		io_last_data <= cpu_io_rdata;
	end
end

m2_backup u_backup (
	.clk(clk_sys),
	.sel(bak_sel),
	.we(cpu_io_we),
	.word(cpu_io_addr[13:2]),
	.be(cpu_io_be),
	.wdata(cpu_io_wdata),
	.rdata(bak_rdata),
	.dbg_w0(bak_w0), .dbg_writes(bak_writes)
);

m2_ioboard #(
	// RESCALED TO clk_sys. These are measured in FRAMES -- status at 7 and
	// the board's self-test at 174 of a 57.5 Hz refresh -- so moving the module
	// to a 40 MHz clock moves the constants with it. At 25 MHz they were
	// 3,043,478 and 75,652,174; here they are 0.1217 s and 3.026 s of 40 MHz.
	.STATUS_CYCLES  (4_869_565),
	.SELFTEST_CYCLES(121_043_478)
) u_ioboard (
	.clk(clk_sys),
	.rst_n(cpu_rst_n),
	.sel(iob_sel),
	.we(cpu_io_we),
	.word(cpu_io_addr[11:2]),
	.be(cpu_io_be),
	.wdata(cpu_io_wdata),
	.rdata(iob_rdata),
	.dbg(iob_dbg), .dbg_win_rd(iob_win_rd),
	.dbg_flag_rd(iob_flag_rd), .dbg_seen(iob_seen)
);

// ---------------------------------------------------------- PORT 4 SWEEP
//
// Does the chip return what was written? Nothing in this core has been able to
// answer that. The loader's high-water mark is taken at the WRITE REQUEST --
// before the FIFO, before the controller, before the device -- so it says what
// the loader asked for and nothing about what is in the SDRAM. On this board it
// reads 256 KB short of the MRA's own length, and that number alone cannot tell
// a truncated load from a mis-measured one.
//
// Lifted in technique from the Model 1 core's `72131a3`, which makes exactly
// this distinction: a fold at the ioctl input proves the bytes arrived AT THE
// LOADER, which is not the question. Port 4 was tied off there and is tied off
// here, so it costs nothing to use.
//
// ONE region, and WHICH one is an OSD option. It began as two hardcoded spans
// -- the program ROM as a control, and the far end where the shortfall is --
// and those answered the question they were built for: the control matched
// exactly, so the instrument is sound, and the far end did not, so the chip
// genuinely does not hold the image. Neither says WHERE it stops matching, and
// finding that with hardcoded spans is one 25-minute build per probe.
//
// Region N is word N*0x100000 for 0x100000 words -- 2 MB, so 22 regions cover
// the 43.62 MB set. tools/rom_csum.py --region N folds the same span of the
// image. Walk N until the two disagree; that boundary is the fault.
//
// ONLY REGIONS WHOLLY INSIDE THE IMAGE MEAN ANYTHING. Past the end the host
// tool substitutes 0xFFFF, which is what an unwritten READ returns by contract
// -- but nothing wrote those words in the chip either, and real SDRAM comes up
// holding whatever it holds. A mismatch out there is not evidence.
logic            sw_req;
logic [SDR_AW:1] sw_addr;
logic [23:0]     sw_acc, sw_val;
logic [19:0]     sw_burst;
// THREE BITS. It was two, and pipelining the fold added a state that collided
// with the one that means "finished": completion went to 3, state 3 folded four
// words and returned to 2, which saw the burst count still at its limit and went
// back to 3. An endless loop with sw_val reassigned every pass, so the fold read
// as unreadable churn on the overlay while sw_done sat latched at DD.
//
// Every sweep reading taken since the fold was pipelined is therefore worthless,
// including the ones used to reason about which SDRAM ports work.
logic  [2:0]     sw_state;
logic [63:0]     sw_word;     // the burst, folded a word at a time
logic  [1:0]     sw_wsel;
logic  [4:0]     sw_sel;
logic            sw_done;

// status[] is written by the HPS and changes only when the user moves in the
// OSD, so it is many orders of magnitude slower than clk_sys and is read
// directly -- the same treatment status[5:4] already gets on the controller's
// capture phase.
wire   [4:0]     sw_sel_i = status[13:9];

function automatic logic [23:0] sw_fold(input logic [23:0] a, input logic [15:0] w);
  logic [23:0] t;
  begin
    t = a + {8'd0, w};
    sw_fold = {t[22:0], t[23]};      // rotate left, so ORDER matters
  end
endfunction

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		sw_req <= 1'b0; sw_addr <= '0; sw_acc <= 24'd0;
		sw_val <= 24'd0; sw_burst <= 20'd0;
		sw_state <= 3'd0; sw_sel <= 5'd0; sw_done <= 1'b0;
	end else begin
		// RESTART ON A NEW SELECTION -- but never out of state 1, which is the
		// one state with a request outstanding on port 4. Dropping sw_req there
		// does not cancel it; the controller still answers, and that ack would
		// land in a sweep which had already zeroed its accumulator, folding one
		// stale burst into the new region's total. A sweep is ~66 ms, so waiting
		// for the in-flight burst to land costs nothing.
		if (sw_sel != sw_sel_i && sw_state != 3'd1) begin
			sw_sel   <= sw_sel_i;
			sw_state <= 3'd0;
			sw_req   <= 1'b0;
			sw_done  <= 1'b0;
		end else case (sw_state)
			// cal_done, NOT rom_loaded alone. R47 gated the copy engine, the ROM
			// readback and the CPU on the calibration and MISSED THIS ONE: the
			// sweep is a fifth reader, on port 4, and it started as soon as the
			// image landed. A sweep is ~66 ms and the calibration finishes part
			// way through it, so the fold mixed words captured at CL+0 with words
			// captured at CL+2 and produced a total that matched nothing.
			//
			// That is how it was caught: region 0 of Daytona folded to 006393E3
			// against tools/rom_csum.py's 25E723, on a board whose CPU was
			// executing 106 million instructions out of that very region. The
			// memory was right and the instrument was wrong -- which is worse
			// than no instrument, because this one is what R38 says to trust.
			3'd0: if (rom_loaded && cal_done) begin
				sw_addr  <= SDR_AW'({sw_sel_i, 20'd0});
				sw_sel   <= sw_sel_i;
				sw_acc   <= 24'd0;
				sw_burst <= 20'd0;
				sw_done  <= 1'b0;
				sw_req   <= 1'b1;
				sw_state <= 3'd1;
			end
			// ONE WORD PER CYCLE, NOT FOUR IN ONE.
			//
			// This folded all four words of the burst in a single cycle:
			//
			//   sw_acc <= sw_fold(sw_fold(sw_fold(sw_fold(sw_acc, w0), w1), w2), w3)
			//
			// which is four chained 24-bit add-and-rotates, launched from
			// m2_sdram's p_ack[4] in the 96 MHz domain and latched in the 48 MHz
			// one. At 40 MHz that fitted. At 48 it does not:
			//
			//   From  m2_sdram|p_ack[4]   To  sw_acc[23]
			//   Data Delay 10.125 ns against a 10.417 ns relationship
			//   Setup slack -0.623  (VIOLATED)
			//
			// It was the ONLY failing path in the whole design -- the 96 MHz
			// memory domain closed at +1.567 ns -- and it is debug
			// instrumentation, not the machine. Folding one word per cycle cuts
			// the chain to a quarter and costs three extra cycles per burst on
			// something that runs once and has no deadline.
			3'd1: if (p_ack[4]) begin
				sw_req  <= 1'b0;
				sw_word <= p_dout[4];
				sw_wsel <= 2'd0;
				sw_state <= 3'd3;
			end

			// Fold the four captured words, one each cycle, then advance.
			3'd3: begin
				sw_acc  <= sw_fold(sw_acc, sw_word[15:0]);
				sw_word <= {16'd0, sw_word[63:16]};
				if (sw_wsel == 2'd3) sw_state <= 3'd2;
				else                 sw_wsel  <= sw_wsel + 2'd1;
			end
			3'd2: begin
				// 0x100000 words at four per burst is 0x40000 bursts -- OR the
				// end of the loaded image, whichever comes first.
				//
				// THE LAST REGION WAS NEVER CHECKABLE. Daytona's image is 43.62
				// MB and ends at word 0x15CFFFF; region 20 stops at 0x14FFFFF,
				// so 21 regions of 2 MB verify 42 MB and leave 1.6 MB -- the TOP
				// of the image, where graphics data sits -- with no expected
				// value at all. tools/rom_csum.py refused to print one because a
				// full-region fold there would include memory nobody wrote, and
				// real SDRAM comes up holding whatever it holds.
				//
				// Bounding the fold at ldr_top fixes that: the last region now
				// folds only the words that were actually loaded, and the tool
				// mirrors the same stopping rule. `sw_addr + 7` is the last word
				// of the NEXT burst, so a burst is only taken when all four of
				// its words are inside the image.
				if (sw_burst == 20'h3FFFF ||
				    (sw_addr + SDR_AW'(7)) > ldr_top) begin
					sw_val   <= sw_acc;
					sw_done  <= 1'b1;
					sw_state <= 3'd4;      // distinct from the fold state

				end else begin
					sw_addr  <= sw_addr + SDR_AW'(4);
					sw_burst <= sw_burst + 20'd1;
					sw_req   <= 1'b1;
					sw_state <= 3'd1;
				end
			end
			default: ;                          // finished, hold sw_val
		endcase
	end
end

// Char fetch. NOT straight from SDRAM: m2_video is on clk_vid and the memory
// side is on clk_sys, and 48/32 is not an integer ratio, so a one-clk_sys ack
// pulse is missed by clk_vid at four starting phases in twelve -- measured in
// test_m2_char_cdc. The fetch engine holds char_req until acknowledged, so the
// first missed ack hangs it for good. Study R49.
wire        char_req, char_ack;
wire [17:0] char_addr;
wire [31:0] char_data;
wire        cc_req;
wire [17:0] cc_addr;

// IS THE CHARACTER FETCH RETURNING DATA AT ALL?
//
// The simulation overruns 509 times rendering Daytona's attract screen and the
// board reports zero, which cannot both describe the same workload. Zero char
// data explains it: every tile then renders as one flat colour out of its
// palette bank -- blue sky, green ground, which is exactly what the board shows
// -- there is almost nothing distinct left to fetch, the 16-entry cache hits
// constantly, and no line ever runs late.
//
// So count what comes back. `cf_all` is every acknowledged fetch and `cf_nz`
// those whose 32 bits were not zero. On a screen with any detail at all the two
// should be within a small factor; cf_nz stuck at zero while cf_all climbs says
// the fetch path returns nothing, and the address or the crossing is at fault
// rather than the renderer.
// COUNTING SAID FETCHES ARRIVE AND ARE NON-ZERO -- row 22 saturated instantly
// at FFFFFFFF -- so the path works and the earlier "returns nothing" theory is
// dead. But NON-ZERO IS NOT VARIED. Unwritten memory reads 0xFFFF by this
// project's standing rule, and an all-ones fetch is non-zero, makes every pixel
// in the tile the same index, and so paints one flat colour per palette bank:
// blue sky, green ground, which is the board's picture.
//
// So stop counting and show the data. `cd_last` is the most recent fetch and
// `cd_ff` counts those that came back all-ones. FFFFFFFF in the low half with
// cd_ff climbing means the fetch is reading memory nobody wrote, and the
// address is wrong rather than the renderer.
logic [31:0] cd_last;
logic [15:0] cd_ff;
always_ff @(posedge clk_vid or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		cd_last <= 32'd0; cd_ff <= 16'd0;
	end else if (char_ack) begin
		cd_last <= char_data;
		if ((&char_data) && !(&cd_ff)) cd_ff <= cd_ff + 16'd1;
	end
end

m2_char_cdc u_char_cdc (
	.clk_vid(clk_vid), .vid_rst_n(mem_rst_n & cp_done),
	.v_req(char_req), .v_addr(char_addr),
	.v_ack(char_ack), .v_data(char_data),
	.clk_sys(clk_sys), .sys_rst_n(mem_rst_n),
	.s_req(cc_req), .s_addr(cc_addr),
	.s_ack(p_ack[3]), .s_data(p_dout[3][31:0])
);

// TILE WORDS ACCUMULATED PER LAYER, straight out of the renderer. The frame
// simulation that reproduces MAME's picture ends with layer 0 holding 0x310 and
// layers 1-3 at zero, so that is what a working board must show. It is read in
// clk_vid, which is the overlay's own clock.
wire [11:0] vid_layer_have [4];
// LINE OVERRUNS, WHICH m2_video HAS COUNTED ALL ALONG AND NOTHING READ.
//
// An overrun is a scanline whose fetches did not finish before the next line
// started. m2_video's own comment says what happens then: the bank does not
// flip and the previous line is displayed again. Whole lines of text go
// missing, which is exactly "the text further down does not show" -- and it
// takes the white labels and the green values alike, because it is not a colour
// fault at all.
//
// The frame render says the tilemap fixture overruns 0 times at the ten-cycle
// round trip the board measures, and 36 times at fourteen. Daytona drives layers
// 2 and 3 both saturated against the fixture's single layer of 784 words, and
// its i960 competes for the same SDRAM, so its budget is far tighter. This
// settles whether that is what is happening rather than inferring it.
wire  [7:0] vid_fetches;
wire [15:0] vid_overruns;

wire [7:0] tile_r, tile_g, tile_b;
wire       tile_hs, tile_vs, tile_hb, tile_vb;

m2_video u_tilemap (
		// cal_done too: on a GAME image game_image short-circuits cp_done without
	// reading anything, so the character fetch on port 3 would otherwise issue
	// at CL+0 until the calibration caught up. Those are live re-reads rather
	// than a latched copy, so it corrected itself -- but it is the last reader
	// that was not waiting, and "it fixes itself" is not a reason to leave one.
	.clk(clk_vid), .ce_pix(ce_pix), .rst_n(mem_rst_n & cp_done & cal_done),
	.tile_mask(14'h3FFF),
	// Colour translation table not loaded yet: it powers up holding pal5bit,
	// which is exactly what this rendered before the table existed, so the
	// picture on hardware is unchanged until the loader is wired up.
	// The table replaces pal5bit only when the loaded data passes the sanity
	// check above; an image without a translation section leaves the renderer
	// exactly as it was.
	// The copy engine loads it at startup; the CPU owns it afterwards, and a
	// game that programs its own table -- Daytona does, once it is past the
	// sound handshake -- overwrites what was loaded.
	.xlat_we(cpu_xlat_we_b | (xlat_we_r & xlat_ok)),
	.xlat_addr(cpu_xlat_we_b ? cpu_xlat_addr_b : xlat_addr_r),
	.xlat_din (cpu_xlat_we_b ? cpu_xlat_din_b  : xlat_din_r),
	.tram_addr(tram_addr), .tram_data(tram_data),
	.char_req(char_req), .char_addr(char_addr),
	.char_data(char_data), .char_ack(char_ack),
	.pal_addr(pal_addr), .pal_data(pal_data),
	.vid_r(tile_r), .vid_g(tile_g), .vid_b(tile_b),
	.vid_hs(tile_hs), .vid_vs(tile_vs), .vid_hb(tile_hb), .vid_vb(tile_vb),
	.vblank_irq(), .dbg_fetches(vid_fetches), .dbg_overruns(vid_overruns),
	.dbg_layer_px(), .dbg_ctrl(), .dbg_layer_have(vid_layer_have)
);

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

// The overlay runs on clk_vid and these all live on clk_sys or clk_i960, so
// they cross with two flops. They are status bits and counters read by eye --
// a torn counter is a wrong digit for one frame, not a wrong decision.
logic [2:0] game_sync, cp_done_sync, cpu_trap_sync, cpu_halt_sync;
logic [SDR_AW:1] ldr_top_sync;
always_ff @(posedge clk_vid) begin
	game_sync     <= {game_sync[1:0],     game_image};
	cp_done_sync  <= {cp_done_sync[1:0],  cp_done};
	cpu_trap_sync <= {cpu_trap_sync[1:0], cpu_trap};
	cpu_halt_sync <= {cpu_halt_sync[1:0], cpu_halted};
	ldr_top_sync  <= ldr_top;
end

m2_diag #(.NWORDS(23)) u_diag
(
	.clk(clk_vid),
	.ce_pix(ce_pix),
	.rst_n(mem_rst_n),
	.enable(1'b1),
	.hb(tile_hb),
	.vb(tile_vb),
	// REPOINTED AT THE CPU. The copy checksums did their job -- they proved the
	// copy engine RAN on a game image, which it must not, and that is why the
	// board showed program ROM rendered as tiles. What is needed now is whether
	// the loader saw a game-sized image at all and whether the CPU is executing,
	// and neither of those can be inferred from a checksum.
	// Row 13 names the region so row 12 can never be read against the wrong
	// expectation: DD in the top byte means the sweep FINISHED, 00 means it is
	// still running and row 12 is a partial total, not a result.
	// 14 THE I/O BOARD. Top nibble: bit3 answered-at-least-once, bit2 awake,
	// bit1 filling, bit0 status raised. Then the status byte and the flag byte
	// as the boot would read them -- the two that the old constant could only
	// ever satisfy one of.
	// 16 IS THE COPY, IN ONE WORD. 41474553 is "SEGA" and the block arrived
	// intact; FFFFFFFF is the power-up value and means nothing was written at
	// all; anything else means it arrived corrupted. Row 8's tile-write count
	// has now meant four different things and cannot distinguish those.
	// 17 WHAT THE i960 READ, not what the board believes it wrote. Upper half
	// counts reads of the flag dword; lower half is {status, flag} exactly as
	// returned on rdata. If this disagrees with row 14 the read path is wrong,
	// and row 14 alone could never have said so.
	// 20 THE CAPTURE SWEEP, and it answers the question the OSD option was
	// there to ask by hand:
	//
	//   bits 5:0   which of CL+0..CL+5 read the known pattern back
	//   bits 10:8  the depth in use
	//   bit  12    the sweep has finished
	//
	// 00001?3F would mean every depth works; 00001?00 means none does, and that
	// is a result about the interface rather than a range that was too narrow.
	.words({ // 22 THE LAST CHARACTER FETCH, verbatim. FFFFFFFF means the fetch is
	         // reading memory nobody ever wrote -- one flat colour per palette
	         // bank, which is the board's sky and ground. Anything varied means
	         // real glyph data is arriving. Replaces the fetch counters, which
	         // saturated instantly and proved only that fetches happen.
	         // OLD 22 LINE OVERRUNS (top half) and last line's worst-layer fetch
	         // count (low byte). Zero overruns means the renderer keeps up and
	         // missing text is NOT a budget problem; a climbing count means it
	         // does not. Replaces the per-channel xlat counts, which did their
	         // job: they read 00202020, and test_m2_boot then dumped the values
	         // and found all three ramps correct, so the table is not at fault.
	         // OLD 22 XLAT WRITES PER CHANNEL: R low byte, then G, then B. A complete
	         // table is 32 each -- 00202020. A zero byte names the channel that
	         // never arrived. Replaces the M10K copy probe, which did its job
	         // (it proved the copy sound while the renderer starved, R49) and
	         // reads zero on a game image by design.
	         cd_last,
	         // 21 ALL FOUR LAYERS, top 8 bits of each. The first version packed
	         // only layers 0 and 1 and read 00000000 on a board visibly drawing
	         // Daytona's sky and ground: the fixture uses layer 0 and Daytona
	         // does not. An instrument covering half the cases reports a fault
	         // when it means "not looking there". Fixture reads 00000031.
	         {cd_ff, vid_layer_have[3][11:4], vid_layer_have[2][11:4]},
	         {19'd0, cal_done, 1'b0, cal_best, 2'd0, cal_mask},  // 20 capture sweep
	         io_last_data,                              // 19 last I/O word returned
	         io_last_addr,                              // 18 last I/O address presented
	         {iob_flag_rd, iob_seen},                   // 17 flag reads / value seen
	         bak_w0,                                    // 16 backup SRAM dword 0
	         {iob_win_rd, bak_writes},                  // 15 window reads / backup writes
	         iob_dbg,                                   // 14 I/O board
	         {sw_done ? 8'hDD : 8'h00, 19'd0, sw_sel},  // 13 sweep region + done
	         {8'd0, sw_val},                            // 12 SWEEP fold of that region
	         cpu_dbg_ldout,                             // 11 last data off the port
	         cpu_dbg_laddr,                             // 10 last address asked for
	         cpu_dbg_palwr,                             // 9  CPU writes to the PALETTE
	         cpu_dbg_tramwr,                            // 8  CPU writes to TILE RAM
	         // 7 PRCB. 000000C0 IS ONLY THE BOOT VALUE. Daytona reinitializes
	         // the PRCB through an IAC (i960_top line 1641, prcb_reg <= iac2),
	         // after which this legitimately reads 0053F400 -- confirmed against
	         // the boot harness, whose stream matches MAME for 803,355
	         // instructions. A changed value here means the CPU got FURTHER, not
	         // that the read was wrong; the old legend said the opposite and
	         // cost a diagnosis. Study R48.
	         cpu_dbg_prcb,                              // 7  PRCB: 000000C0 at boot, 0053F400 once reinitialized
	         cpu_dbg_ip,                                // 6  where the CPU is
	         cpu_dbg_acc,                               // 5  instructions accepted
	         // 32 BITS, not 31. The first version was {27'd0, ...} = 31, which
	         // shifted every word above it by one bit: the board showed word4 as
	         // 80000007, its top bit being rb_w0's LSB bleeding down. A short
	         // field in a concatenation does not warn, it silently reindexes.
	         {16'd0, cpu_trap_sync[2], cpu_halt_sync[2],
	          game_sync[2], cp_done_sync[2],
	          st_ok_sync[2], ldr_overflow,
	          loaded_sync[2], mem_ready,
	          6'd0, pll_locked, 1'b1},                  // 4  status, see below
	         {7'd0, ldr_top_sync},                      // 3  highest word loaded
	         rb_w0,                                     // 2  readback of words 6/7, want 00000860
	         frame_ctr,                                 // 1  liveness
	         32'hB0ADCAFE }),                           // 0  magic
	// Until the copy engine has filled tile RAM and the palette there is
	// nothing to draw, so the test pattern stands in. After that the tilemap
	// takes over. Seeing the pattern persist therefore means the copy never
	// finished, which is a different failure from a tilemap that draws nothing.
	.in_r(cp_done ? tile_r : pat_r),
	.in_g(cp_done ? tile_g : pat_g),
	.in_b(cp_done ? tile_b : pat_b),
	.out_r(ov_r), .out_g(ov_g), .out_b(ov_b)
);

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = ce_pix;

assign VGA_DE = ~(tile_hb | tile_vb);
assign VGA_HS = tile_hs;
assign VGA_VS = tile_vs;
assign VGA_R  = ov_r;
assign VGA_G  = ov_g;
assign VGA_B  = ov_b;

endmodule
