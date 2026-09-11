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
assign {UART_RTS, UART_DTR} = 0;
// UART_TXD is driven by the debug streamer at the bottom of this file. The
// core's own printf -- see rtl/dbg/m2_dbg_stream.sv for why it exists.
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL  = 0;
assign VGA_F1  = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// THE SOUND BOARD'S OUTPUT, SIGNED. AUDIO_S says which, and it was 0 --
// unsigned -- while nothing drove the buses. jt12 emits signed 16-bit, so the
// flag has to move with the data: leave it at 0 and every negative sample
// becomes a very loud positive one, which is the classic full-scale buzz over
// the top of otherwise correct music.
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
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
	// ROW 2'S ADDRESS, SELECTABLE. The menu's missing glyphs are the only ones
	// whose character data lives in GAME_CHAR's first SDRAM row; these presets
	// read the exact words (sim-verified expected values in the comment at the
	// readback) so the board can say whether that data is THERE and READABLE.
	"O[16:14],Probe,bootIP,chr 3,chr 1,chr #,chr A,row2,bndry,chr0;",
	"-;",
	"R[17],Save settings (NVRAM);",
	"O[18],Probe page,0,1;",
	// OFF BY DEFAULT. The overlay is 24 rows of hex painted over the top-left
	// of the picture, which is exactly where the game puts its own text. It
	// stays compiled in -- the probes cost nothing now that they observe write
	// buses instead of adding memory ports -- but it should not be in the way
	// of looking at the game.
	"O[19],Debug overlay,Off,On;",
	// Off at power-up: an OSD bit is 0 until the user sets it.
	"O[20],Geometrizer walk,On,Off;",
	// WHICH MOMENT THE WALK STARTS ON. The reference says the 0x803008 write
	// is the game saying "the list is ready", so Flip should be right -- but
	// on hardware it walks a list that decodes one to three opcodes, and the
	// alternatives are worth a switch rather than four builds.
	"O[24:23],Walk trigger,Flip,Vblank,After flip,Write ptr;",
	// PROVE THE DRAWING HALF, INDEPENDENTLY OF THE GEOMETRY.
	//
	// Everything from the quad store to the video mixer has only ever been fed
	// DEGENERATE quads -- all four vertices at the same point, because the
	// transform matrix is all zeros -- which correctly rasterise to nothing. So
	// "no 3D on screen" is the expected outcome of the data, and it says
	// nothing about whether the rasterizer, the band buffers or the mixer work.
	//
	// With this on, one known-good quad is injected per frame in place of the
	// geometry's. If a grey rectangle appears, the entire downstream half is
	// proven on hardware and every remaining fault is upstream of it. If it
	// does not, the fault is downstream and no amount of fixing the matrix
	// would ever have shown a picture.
	"O[22:21],Texture brightness,100%,75%,50%,25%;",
	// A bar outside the visible area is indistinguishable from a bar that did
	// not draw. This packs all four well inside any plausible crop, so a side
	// missing in BOTH layouts is missing for a real reason.
	"R[0],Reset and close OSD;",
	// The button-definition line lives at the END of the menu block. Placed
	// between the two R items it silently broke everything after it -- the OSD
	// Reset stopped pulsing status[0], measured as a reset-edge counter that
	// ignored the button entirely.
	"J1,Coin,Start,Test,Service,VR1 Red,VR4 Green,Accel,Brake,Gear Up,Gear Down,VR2 Blue,VR3 Yellow;",
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
	.joystick_0(joystick_0),
	.joystick_l_analog_0(joy_analog),
	.paddle_0(paddle),
	.ioctl_wait(ioctl_wait),
	// NVRAM save: the framework reads backup SRAM back through ioctl_din when
	// it saves the MRA's <nvram> section. upload_req stays 0 -- saves are
	// host-initiated, the standard arcade pattern.
	.ioctl_din(ioctl_din),
	.ioctl_upload(ioctl_upload),
	// THE CORE MUST ASK. MiSTer writes the MRA's <nvram> section back only
	// when the core pulses upload_req -- wiring it to zero means no save ever
	// happens, however the ini is set. The OSD's "Save settings" line pulses
	// it with index 2.
	.ioctl_upload_req(nv_save_req),
	.ioctl_upload_index(8'd2)
);

wire [31:0] joystick_0;
wire [15:0] joy_analog;
wire  [7:0] paddle;
wire        ioctl_download, ioctl_wr, ioctl_wait, ioctl_upload;
wire [15:0] ioctl_din;
wire [15:0] ioctl_index, ioctl_dout;
wire [26:0] ioctl_addr;

///////////////////////   CLOCKS   ///////////////////////////////
//
// The PLL module MUST be named `pll` -- sys/sys_top.sdc constrains it by that
// name, and a rename makes the constraints match nothing while still passing.
// See rtl/pll/pll.v.

wire clk_mem;        // 100 MHz, m2_sdram ONLY
wire clk_sdram_pin;  // 100 MHz at 180 deg, drives SDRAM_CLK
wire clk_sys;   // 50 MHz, the core domain, and the COPROCESSOR's clock.
                // Exactly the real MB86234's 50 MHz, and an exact 2x clk_i960 --
                // the board's own ratio. Model 1 had to retrofit 2:1 onto a
                // 1:1 arrangement; this core was built at the ratio.
                //
                // THE WHOLE CHAIN IS EXACT AND THAT IS LOAD-BEARING, NOT
                // COSMETIC: 100 / 50 / 25, every step an integer 2:1 off one
                // PLL. Two handshakes depend on it. m2_sdram's ACK_HOLD = 2 is
                // documented as "2 for a clk/2 requester" and gives a 50 MHz
                // requester EXACTLY ONE rising edge with ack high -- at 96/50
                // it would give one or two depending on phase, and a requester
                // would take a stale ack for its next access. And
                // m2_cpu_bridge registers io_sel on clk_mem = clk_sys, so a
                // coprocessor select is exactly one copro cycle and a held
                // access cannot double-push or double-pop a FIFO.
                //
                // Model 1 paid for this: its 2:1 handshake fired on every
                // cycle the request was held. See R152.
                  //         later steps need is the one being timed now
wire clk_vid;     // 32 MHz
wire clk_i960;    // 25 MHz -- the real i960's clock, an exact /2 of clk_sys
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),      // 100 MHz, the SDRAM controller alone
	.outclk_1(clk_sys),      // 50 MHz, everything else. Exact /2 of outclk_0.
	.outclk_2(clk_vid),      // 32 MHz (unused)
	.outclk_3(clk_i960),     // 25 MHz, exact /2 of clk_sys.
	.outclk_4(clk_sdram_pin),// 100 MHz at 180 deg, straight to the device pin
	.locked(pll_locked)
);

// EXACTLY half of 32 MHz. MAME declares Model 2's pixel clock as
// `32_MHz_XTAL/2`, so this is the reference rate and not an approximation of it.
// ONE CLOCK FOR THE PICTURE AND THE MEMORY THAT FEEDS IT.
//
// The renderer used to run on clk_vid (32 MHz, ce_pix = /2 = 16 MHz) while the
// tilemap and palette were written from clk_sys. Two unrelated clocks on one
// array is a DUAL-CLOCK RAM, and Quartus says so plainly:
//
//   Warning (276027): Inferred dual-clock RAM node "emu:emu|tram_rtl_0" ...
//   The read-during-write behavior of a dual-clock RAM is UNDEFINED and may
//   not match the behavior of the original design.
//
// Undefined on silicon, well-defined in Verilator -- the exact divergence the
// standing rules warn simulation cannot see, sitting on the path that makes
// the picture. It also forced the clk_vid/memory crossing to be CUT in the
// SDC, so those paths were never timed at all.
//
// Running the video on clk_sys makes tram and pal SINGLE-clock: Quartus adds
// pass-through logic, read-during-write becomes defined, the crossing becomes a
// real timed path, and the renderer gets more cycles per line for its fetches.
//
// SIXTEEN OF FIFTY, NOT ONE OF THREE, because clk_sys is 50 MHz now.
//
// It was clk_sys/3, and 48/3 = 16 MHz exactly. 50/3 is not 16, and the i960's
// clock is 25 MHz -- the real part's -- which forces clk_sys to 50 because the
// CPU bridge's crossing depends on an exact 2:1. Something had to give and this
// is the cheapest thing available: the alternatives were the i960 on its own
// PLL, which the bridge measured at six extra cycles a transaction (S_DONE
// 7.12 against 1.14), or the renderer back on its own clock, which is a 36%
// cut to its fetch budget and brings the tearing back.
//
// A phase accumulator, so the AVERAGE is exact: 16 pulses every 50 cycles is
// 16 MHz, and the frame rate is still 16e6/(656*424) = 57.5242 Hz. What is not
// exact is the SPACING -- consecutive enables sit 3 or 4 clk_sys cycles apart,
// 60 or 80 ns against a uniform 62.5.
//
// That does not reach the picture. The video timing counts PIXELS, not
// nanoseconds: every H and V position, the line length and the frame length are
// all in units of ce_pix and are unchanged. The scaler latches a pixel per
// enable into a line buffer and drives its output from its own clock, so what
// varies is when a pixel is handed over, never which pixel or how many.
localparam int unsigned CE_NUM = 16;      // 16 MHz
localparam int unsigned CE_DEN = 50;      // clk_sys
reg [5:0] ce_acc;
reg       ce_pix;
always @(posedge clk_sys) begin
	if (ce_acc + CE_NUM >= CE_DEN) begin
		ce_acc <= ce_acc + 6'(CE_NUM) - 6'(CE_DEN);
		ce_pix <= 1'b1;
	end else begin
		ce_acc <= ce_acc + 6'(CE_NUM);
		ce_pix <= 1'b0;
	end
end

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
localparam int unsigned NPORTS = 10;  // 5 = sound ROM, 6/7 = samples, 8/9 = TGP
                                      // (9 is SHARED with the display-list walk)

// THE 68000 SOUND PROGRAM, 256 KB, at MRA byte offset 0x2350000 -- and the MRA's
// own comment says 0x2340000, which is 64 KB wrong. The comment is not the
// authority and neither is arithmetic over the section list; the built image is.
// Searching it for the first bytes of epr-16489.7 finds them at 0x2350000, with
// epr-16490.8 at 0x2370000 -- 256 KB contiguous -- and the samples after it at
// 0x2390000. Study R39 records the same class of error in the other direction.
//
// Declared up here rather than with the other GAME_* constants because the port
// mux below needs it.
// GAME_SND IS GONE ON PURPOSE. Three different answers were asserted for it --
// the MRA's comment said byte 0x2340000, a rebuilt image said 0x2350000, and
// the board disagreed with both readings of itself -- and the scan below
// settles it by looking: 0x2340000, which is what the MRA said. An address
// nobody can verify by reading is not a constant, it is a guess with a name.
// The samples sit immediately after the 256 KB program ROM, so their offset
// from it is a fact about the MRA's section list rather than an address:
// 0x40000 bytes is 0x20000 words. Derived, so it moves with the scan.
localparam logic [SDR_AW:1] PCM_OFFS = SDR_AW'(32'h0020000);

// The TGP's two read-only ROM windows, as WORD addresses.
//   copro_data  byte 0x0A40000, 4 MB -- mpr-16537 + mpr-16536, interleaved
//   tables      byte 0x2BB0000, 256 KB -- opr-14742a + opr-14743a, MEASURED
localparam logic [SDR_AW:1] GAME_COPRO  = SDR_AW'(32'h0520000);
// 0x15D0000, NOT 0x15D8000. The "measured 64 KB gap" before the tables was the
// I/O board's 64 KB ROM sitting in the index-0 stream ahead of them. c1c9fd6
// (2026-09-08) moved that ROM to its own ioctl index, the tables moved down
// 64 KB, and this base did not: since then the TGP has read every sine,
// cosine, inverse and inverse-square-root 64 KB into the table. Found by
// searching the index-0 image built by tools/rom_csum.py for the tables'
// first words (00000000 38c90fdb 39490fdb): byte 0x2BA0000, word 0x15D0000.
localparam logic [SDR_AW:1] GAME_TGPTBL = SDR_AW'(32'h15d0000);
// THE POLYGON ROM, WHERE THE GEOMETRY'S VERTICES LIVE (R169).
//
// geo_object_data's `oba` selects the source -- bit 24 fast polygon RAM, bit 23
// polygon ROM, else slow polygon RAM -- and Model 2's models are in the ROM.
// 12 MB of it, already loaded by the MRA and never read until now.
//
// The base is DERIVED FROM THE MRA'S STREAM ORDER, which is the only thing that
// decides where a region lands: the loader writes what it is sent, in order.
//
//   maincpu      0x40000 B          words 0x000000..0x020000
//   main_data    10 MB                    0x020000..0x520000   = GAME_DATA
//   copro_data    4 MB                    0x520000..0x720000   = GAME_COPRO
//   textures      8 MB (two pairs)        0x720000..0xB20000
//   polygons     12 MB (three pairs)      0xB20000..0x1120000  = here
//
// The method is checked by the two constants it already has to reproduce:
// GAME_DATA and GAME_COPRO both fall exactly where this arithmetic puts them.
// It is verified rather than trusted -- see the boot harness, which reads word
// 0xB20000 back and compares it against the interleaved first dword of
// mpr-16523.ic16 / mpr-16518.ic20. R154 is why: the copro data ROM was never
// loaded in simulation at all, and every read of it returned 0xFFFFFFFF while
// the arithmetic said the base was right.
//
// TEXTURES ARE NOT CONTIGUOUS WITH MAME'S REGION, and the texture unit will
// need to know. model2.cpp's "textures" is 16 MB with mpr-16522/16521 at
// 0x000000 and mpr-16517/16516 at 0x800000 -- a 4 MB hole in the middle. The
// MRA streams both pairs back to back with no gap, so an address computed
// against MAME's layout is 4 MB out for everything above the hole. Recorded
// now because it costs nothing here and is expensive to rediscover.
// THE POLYGON ROM: byte 0x1640000, 0xd00000 = 13 MB, not the 12 MB this line
// used to claim. The MRA streams three 4 MB interleaved pairs
// (mpr-16523/16518, 16524/16519, 16525/16520) plus a 1 MB pair
// (epr-16646/16645), and the 68000 sound program starts immediately after at
// byte 0x2340000 -- there is no gap.
//
// `oba` is a DWORD INDEX, not a byte address: the reference reads
// polygon_rom[oba & mask] out of a u32 array, with mask = bytes/4 - 1. The
// engine masks to 22 bits, which is that mask for a region padded to 16 MB.
// An oba past the real 13 MB therefore reads the sound program rather than
// wrapping the way MAME's non-power-of-two mask would. Left as is: it can only
// happen for an object address the game never issues, and a wrong picture is
// preferable to a mask that quietly disagrees with the reference.
localparam logic [SDR_AW:1] GAME_POLY   = SDR_AW'(32'h0b20000);   // byte 0x1640000, 13 MB

wire        snd_rom_req;
wire [17:1] snd_rom_addr;
wire        pcm1_req, pcm2_req;
// The TGP's two read-only windows: 64K words of sincos/atan/inv/isqrt tables,
// and 2 M words of copro_data the geometry code walks.
wire        tgp_tbl_req, tgp_dat_req;
wire        tgp_dat_we, tgp_dat_is_buf, tgp_dat_half;
// The geometrizer walks its display list once a frame, on the same vblank
// edge the frame counter uses. The reference gates it on videocontrol bit 0
// or an even frame; that gate is not modelled yet, so it walks every frame.
// WALKER ENABLE ON THE OSD, not a rebuild. The geo_rp mask fix (R142 work)
// made the walker actually walk for the first time -- it used to bound out
// after one opcode -- and the first build carrying it black-screened the board.
// That is either the walker's new SDRAM traffic or something else, and a
// compile-time switch costs a 25-minute fit per answer. status[20] settles it
// by toggling a menu item.
//
// DEFAULT OFF, and deliberately: an OSD option is 0 at power-up, so the board
// comes up with the walker quiet and in the state that had video. Turn it ON
// from the menu to run the experiment. If the picture dies the moment it is
// enabled, the walker is the cause and no rebuild was needed to prove it.
// WALKER ON BY DEFAULT NOW. The OSD bit was added to test whether the walker
// black-screened the board; with BUFFERRAM off the game runs and the walker is
// the thing we actually want exercised, so the sense is inverted: status[20]
// TURNS IT OFF. An OSD bit is 0 at power-up, so the default is ON.
// R229: same reason as tq_en below -- this one gates the frame pulse that
// starts the walk, the geometry and the renderer's whole band schedule.
logic [2:0] nowalk_s;
// R239: the texture-placeholder brightness, an OSD option, through three flops
// like every other status bit that reaches the datapath (R229).
logic [2:0] tl0_s, tl1_s;
always_ff @(posedge clk_sys) begin
	tl0_s <= {tl0_s[1:0], status[21]};
	tl1_s <= {tl1_s[1:0], status[22]};
end
wire [1:0] tex_lum_s2 = {tl1_s[2], tl0_s[2]};
always_ff @(posedge clk_sys) nowalk_s <= {nowalk_s[1:0], status[20]};
wire        geo_walk_start = vbl_d && !vbl_dd && !nowalk_s[2];
wire        geo_rd_req;
wire [18:0] geo_rd_addr;
wire [15:0] geo_walk_ops, geo_walk_objs, geo_walk_frames;
wire [15:0] r3d_ready_cyc;   // R200: frame_start -> P_READY, in clk_sys cycles
wire  [7:0] r3d_bands_done; // R200: bands completed last frame, against NBANDS=24
wire  [7:0] r3d_late_frames; // frame_start while still collecting: the frame drew nothing
wire  [7:0] r3d_qend_frames; // frames the geometry stage finished
wire [15:0] r3d_collect_cyc; // R210: frame_start -> q_end, units of 16 clk_sys cycles
wire  [7:0] r3d_hold;        // R213: frames the last list stayed on display
wire [15:0] r3d_missed;      // R213: scanlines drawn with no band ready
wire  [7:0] geo_walk_unknown;
wire  [3:0] geo_walk_state;
logic       geo_rd_req_r;
logic [18:0] geo_rd_addr_r;
logic       geo_rd_ack_r;
logic [31:0] geo_rd_data_r;
// R214: THE PORT'S SECOND DWORD SERVES THE NEXT READ. Both port-4 readers go
// through m2_pair_cache, indexed by the full dword address; a sequential
// stream then makes half the port trips. p4_dout_r keeps all 64 bits.
logic [63:0]       p4_dout_r;
wire               gc_req, ec_req;
wire [SDR_AW-2:0]  gc_idx, ec_idx;
logic [SDR_AW-2:0] gc_idx_r, ec_idx_r;
wire               geo_rd_ack_c, eng_mem_ack_c;
wire [31:0]        geo_rd_data_c, eng_mem_data_c;
// The geometry engine's side of port 4. eng_base is decoded once per object
// from oba and held, so the increment inside the engine never has to know
// which memory it is walking.
wire         eng_mem_req;
wire [23:0]  eng_mem_addr;
logic        eng_mem_req_r, eng_mem_ack_r;
logic        p4_ack_d;          // R206: acknowledge edge, for ownership
logic [31:0] eo_first_data;     // the engine's first read of the current object
logic [23:0] eo_first_idx;
logic  [7:0] eo_reads;          // reads the previous object took
logic  [7:0] eo_cnt;
logic        eo_armed, eo_busy_d;
logic [23:0] eng_mem_idx_r;
logic [31:0] eng_mem_data_r;
logic [SDR_AW:1] eng_base_r;
logic [15:0] dbg_p4_clash;
// REGISTERED, like the read path already is. Unregistered, this ran
// combinationally from mb86233_regs' b0 through win_adr, bufw_addr and the
// shared-write-port mux into m2_sdram's wr_addr_p -- every failing path in
// build 56 was exactly that, at -0.520.
wire        tgp_bufw_req;
`ifdef M2_NO_COPRO_BUFW
localparam bit COPRO_BUFW = 1'b0;
`else
localparam bit COPRO_BUFW = 1'b1;
`endif
wire [18:0] tgp_bufw_addr;
wire [15:0] tgp_bufw_data;
// COPRO BUFFER-RAM WRITE PROBE (R142). Counts RISING EDGES of the request --
// the level is held until ack, so counting the level counts cycles, not writes.
// Simulation cannot answer this: the boot harness runs the copro to 128 retires
// against the board's thousands, so its zero is the zero of a module that never
// ran, not evidence the write is absent.
logic [31:0] tgp_bufw_count;
logic [18:0] tgp_bufw_last;
logic [31:0] tgp_mbox;
wire  [15:0] tgp_ff_math, tgp_ff_rom, tgp_ff_buf, tgp_rd_total;   // R146 probe: all-ones io reads by source
logic        tgp_bufw_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		tgp_bufw_count <= 32'd0; tgp_bufw_last <= 19'h7FFFF; tgp_bufw_d <= 1'b0;
		tgp_mbox <= 32'hEEEEEEEE;   // EE = never written, distinct from 0 and from 0x07800f0f
	end else begin
		tgp_bufw_d <= tgp_bufw_req;
		if (tgp_bufw_req && !tgp_bufw_d) begin
			tgp_bufw_count <= tgp_bufw_count + 32'd1;
			tgp_bufw_last  <= tgp_bufw_addr;
			// THE MAILBOX VALUE, assembled from both halves as the copro writes
			// them (R143: low first, then high). Word 0xFFF8 is the low half of
			// dword 0x7FFC, 0xFFF9 the high. This is what the copro SAYS it put
			// there; cpu_dbg_ldout alongside it is what the game READS back.
			if (tgp_bufw_addr == 19'h0FFF8) tgp_mbox[15:0]  <= tgp_bufw_data;
			if (tgp_bufw_addr == 19'h0FFF9) tgp_mbox[31:16] <= tgp_bufw_data;
		end
	end
end

logic       tgp_bufw_req_r;
logic [18:0] tgp_bufw_addr_r;
logic [15:0] tgp_bufw_data_r;
logic       tgp_bufw_ack_r;
wire [15:0] tgp_dat_wdata;
wire [15:0] tgp_tbl_addr;
wire [19:0] tgp_dat_addr;
// BURST INDEX, NOT A BYTE ADDRESS. The sound board's sample ports became
// four-word bursts when m2_pcm_fetch was added and these were left as [21:0]
// byte addresses, so a 19-bit output drove a 22-bit wire: the burst index
// landed in the LOW bits and everything downstream then treated it as a byte
// address. p_addr took [21:3] of a value that was already shifted, dividing it
// by eight a second time, and the byte select used bits of the burst index.
// Both sample chips read the wrong address and picked the wrong byte out of it.
//
// That is what "horrible sound" was, for four builds. Three real faults were
// found and fixed in that time -- none of them this one -- because the search
// was for something that sounded wrong rather than for what CHANGED in the
// build that started sounding wrong.
wire [21:3] pcm1_addr, pcm2_addr;
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
	// R238: the sweep lives on port 2 now, behind the copy engine and the
	// calibration reads, both idle once the game runs. Port 4 became the
	// walker's and engine's (R167/R214) and is a one-word port; the sweep was
	// written for the four-word burst port 2 gives, and its request was wired
	// to nothing at all -- it sat in its read state taking the engine's acks
	// as its own. It is the instrument for the question R237 leaves: does the
	// polygon ROM read back through the SDRAM as the image the MRA loaded?
	p_req[2]  = cp_req ? cp_req  : st_rd_req ? st_rd_req  : sw_req;
	p_addr[2] = cp_req ? cp_addr : st_rd_req ? st_rd_addr : sw_addr;
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
	// PORT 4 IS THE GEOMETRIZER WALKER'S NOW, NOT THE DEBUG SWEEPER'S (R167).
	//
	// The walker and the coprocessor used to SHARE port 9, muxed by
	// `tgp_dat_req_r`. Two independent requesters cannot share one port: this
	// controller's interface is one req/ack pair and one address per port, so the
	// address moved under whichever transaction was already in flight and the
	// single acknowledge could not say whose it was. Measured on the board -- the
	// coprocessor retired its reads with the walker's data, its display-list base
	// and count came back as garbage, and it ground ~640x the reference workload
	// and never cleared the mailbox. Turning the walker off cured it outright,
	// which is the proof.
	//
	// Separate ports remove the class rather than arbitrating it. The controller
	// already arbitrates BETWEEN ports correctly; it was only ever wrong to put
	// two owners on one.
	//
	// Port 4 was the SDRAM checksum sweeper, a debug facility whose only consumer
	// is the overlay. It is the port identified as free.
	//
	// PORT 4 NOW CARRIES TWO READERS, AND THEY TAKE TURNS RATHER THAN SHARE.
	// The walk stops at every object_data until the geometry engine reports
	// that object drawn (m2_geo's eng_busy interlock), so exactly one of these
	// two requests can be up at a time. That is what makes one port legal here
	// where R167 made it fatal: there, the walker and the coprocessor were
	// independent and genuinely overlapped. dbg_p4_clash below counts the
	// cycles where both ask anyway -- if the interlock is ever wrong, that
	// counter is non-zero rather than the picture being subtly incorrect.
	p_req[4]  = geo_rd_req_r | eng_mem_req_r;
	p_addr[4] = eng_mem_req_r ? {ec_idx_r, 1'b0} : {gc_idx_r, 1'b0};   // R214: dword addresses from the pair caches
	// PORT 2 FOR THE COPY, which is the one port known to work.
	//
	// Port 0 failed (single word) and port 1 failed (four-word burst), while the
	// self-test on port 2 reads all four of its words back correctly every time.
	// So it is not the burst length -- it is the port. This changes nothing but
	// the index, so if the checksums come good the fault is port-specific and the
	// target is the arbiter's grant-to-tag path, which is a few lines.
	//
	// The self-test also uses port 2 and waits for cp_done, so they never overlap.
	// PORT 5, THE SOUND BOARD'S ROM FETCH. Requested ALIGNED, because the
	// controller bursts four 16-bit words into a 64-bit p_dout and the burst is
	// aligned; the word actually wanted is selected out of it. Three of every
	// four fetches are therefore free to a CPU reading sequentially, which is
	// what a 68000 does almost all the time.
	// PORT 5 IS THE SCANNER'S UNTIL IT FINISHES, then the 68000's. They never
	// overlap: the CPU is held in reset until snd_found.
	//
	// SO THE REQUEST IS AN OR, NOT A MUX, AND snd_found IS NOT IN IT. The two
	// sources are already mutually exclusive by construction and the select was
	// costing real time -- see the note on ports 6 and 7 below, which is the
	// same fault and where it was measured. `snd_rom_req` comes out of
	// m2_sound_board, whose reset is `... & snd_found`, so it is held low for
	// the whole scan; and `sc_req <= 1'b0` is assigned on the VERY EDGE that
	// sets snd_found, so the scanner's request is gone from the cycle the flag
	// appears. Before that edge the OR is 0|sc_req, after it is snd_rom_req|0.
	// Bit-identical to the mux, on every cycle, with one fewer input.
	p_req[5]  = snd_rom_req | sc_req;
	// The ADDRESS mux stays. snd_base and sc_addr really are different values
	// and the select really is needed -- it is only the REQUEST that was
	// already decided elsewhere. p_addr is not on a failing path.
	p_addr[5] = snd_found ? (snd_base + SDR_AW'({snd_rom_addr[17:3], 2'b00}))
	                      : sc_addr;
	// PORTS 6 AND 7, THE TWO MULTIPCMS' SAMPLE FETCHES.
	//
	// 8 MB of samples sit immediately after the 256 KB program ROM, so their
	// base is DERIVED from the one the scan found rather than asserted -- the
	// two came out of the same MRA section list and move together. pcm1 is the
	// first 4 MB and pcm2 the second, which is not the MRA's ordering taken on
	// trust: MAME's own region contents were read back and matched against the
	// files, and pcm1 is mpr-16491+16492 while pcm2 is mpr-16493+16494.
	//
	// The chips address bytes; SDRAM stores words. The word is fetched and the
	// byte selected, four words at a time, so a voice reading consecutive
	// samples gets seven of every eight bytes without a second request.
	// AND THE snd_found GATE IS GONE FROM BOTH, because it could never change
	// the answer and it was the design's worst timing path.
	//
	// pcm1_req and pcm2_req are m_req_r inside m2_pcm_fetch -- a REGISTER, and
	// one that `m_req_r <= 1'b0` clears in reset. PCM_CACHE is 1 so BYPASS is
	// 0 and m_req is that register, not the combinational passthrough. The
	// reset is m2_sound_board's, which is `cpu_rst_n & mem_rst_n & cp_done &
	// snd_found`. So the request is PHYSICALLY ZERO whenever snd_found is
	// zero, and ANDing the two is redundant logic.
	//
	// IT COST -0.196 ns, THE WORST PATH ON clk_mem. snd_found is a clk_sys
	// register and pend[] is a clk_mem one, so the gate turned a boot-time
	// flag into a 50->100 MHz crossing: -1.035 ns of skew before any logic,
	// then 9.061 ns of data of which 6.261 was ROUTING -- FF_X59_Y21 to
	// X57_Y22 to X70_Y25 to X73_Y26, thirteen LAB columns of it, because a
	// fanout-17 signal that also drives the sound reset and the port-5 address
	// mux cannot be placed near any one of its consumers. Sourcing f_req from
	// pcm1_req/pcm2_req instead lets the fitter put each one beside the
	// arbiter port it feeds.
	p_req[6]  = pcm1_req;
	p_addr[6] = snd_base + PCM_OFFS + SDR_AW'({pcm1_addr, 2'b00});
	// PORTS 8 AND 9, THE TGP's TABLES AND DATA. Both read-only. The TGP asks
	// for one 32-bit word and blocks on it, so only the low pair of each burst
	// is used; the address is a 32-bit word index shifted left to reach this
	// 16-bit memory.
	//
	// The table base is the arithmetic's 0x2BA0000 (study R203). This comment
	// used to record a "measured" 0x2BB0000 from an image the builder had
	// prepended the 64 KB index-3 I/O ROM to -- the same invented gap R89
	// had already reversed for the 68000 sound ROM.
	p_req[8]  = tgp_tbl_req_r;
	p_addr[8] = GAME_TGPTBL + SDR_AW'({tgp_tbl_addr_r, 1'b0});
	// PORT 9 REACHES TWO REGIONS NOW, chosen by the coprocessor's bank register
	// (R133). The reference's banked window is the copro data ROM when the
	// effective address sets bit 23 and BUFFER RAM when it sets bit 22, and the
	// buffer half is written as well as read -- that is how the coprocessor and
	// the i960 share results, and this core has never had it.
	// PORT 9 IS SHARED: the coprocessor's banked window and the geometrizer's
	// display-list walk both read buffer RAM, and an ELEVENTH PORT IS NOT FREE.
	// Every port widens the arbiter's whole chain -- pend & ~inflight, the
	// rotate, the priority encode, the rotate back, then a 25-bit NP-way mux --
	// and adding one took every failing path to `inflight[6] -> xfer_addr[8]`
	// at -1.439 with TNS -47. A local two-way mux costs none of that.
	//
	// The coprocessor wins, because it STALLS THE TGP mid-instruction while it
	// waits; the walk has a whole frame and can take its turn.
	// PORT 9 IS THE COPROCESSOR'S ALONE (R167). The walker moved to port 4.
	p_req[9]  = tgp_dat_req_r;
	p_addr[9] = (tgp_dat_is_buf_r ? GAME_BUFFER : GAME_COPRO)
	          + SDR_AW'({tgp_dat_addr_r, tgp_dat_half_r});
	// port 9 is READ ONLY. Buffer-RAM writes go out on the shared write port,
	// which keeps p_we/p_din out of the arbiter's command decode.
	p_req[7]  = pcm2_req;   // gate removed, see port 6
	// FOUR MEGABYTES ON, AND THESE ARE WORD ADDRESSES. This was 0x400000,
	// which as a WORD offset is eight megabytes, so the second sample chip read
	// four megabytes past the end of the samples and played whatever was there.
	// It is the chip Daytona actually uses -- 4,128 register writes against 560
	// for the first -- so almost all of the sound was garbage, at a sample rate
	// measured on the board as 44,633 Hz of 44,643 with zero underruns. A
	// correct rate playing wrong bytes is not distinguishable from a rate
	// problem by listening, and two builds were spent on the rate.
	p_addr[7] = snd_base + PCM_OFFS + SDR_AW'(23'h200000)
	                     + SDR_AW'({pcm2_addr, 2'b00});
	// STRAIGHT FROM THE CACHE. cc_req/cc_addr used to come out of m2_char_cdc;
	// see the note at u_char_cache for why that translator was removed.
	p_req[3]  = cache_m_req;
	p_addr[3] = char_base + SDR_AW'(cache_m_addr);
	// PORT 0 IS THE CPU'S, and it is the single-word port on purpose: the
	// bridge issues one 16-bit access at a time, and ports 1-3 burst four.
	p_req[1]  = cpu_sd_req;
	p_addr[1] = cpu_sd_addr;
end
assign rb_dout = p_dout[0];
assign rb_ack  = p_ack[0];

// T_REFI IS IN CLOCK CYCLES, and this domain is 100 MHz (see rtl/pll/pll.v):
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

// The shared write port's owners, in slot order: buffer initialiser, store
// engine, coprocessor buffer-RAM writes, geometrizer push DMA, ROM loader.
// Each sees only the acknowledge of its own transaction.
logic              wa_req;
logic [SDR_AW:1]   wa_addr;
logic [15:0]       wa_din;
logic [4:0]        wa_own_req, wa_own_ack;
logic [SDR_AW:1]   wa_own_addr [5];
logic [15:0]       wa_own_din  [5];
assign wa_own_req     = {ldr_wr_req, geo_sd_busy & geo_sd_req, tgp_bufw_req_r, st_run & st_req, bi_run & bi_req};
assign wa_own_addr[0] = bi_addr;
assign wa_own_addr[1] = st_addr;
assign wa_own_addr[2] = GAME_BUFFER + SDR_AW'(tgp_bufw_addr_r);
assign wa_own_addr[3] = geo_sd_addr;
assign wa_own_addr[4] = ldr_wr_addr;
assign wa_own_din[0]  = bi_din;
assign wa_own_din[1]  = st_din;
assign wa_own_din[2]  = tgp_bufw_data_r;
assign wa_own_din[3]  = geo_sd_din;
assign wa_own_din[4]  = ldr_wr_din;
wire wr_ack_bi  = wa_own_ack[0];
wire wr_ack_st  = wa_own_ack[1];
wire wr_ack_tgp = wa_own_ack[2];
wire wr_ack_geo = wa_own_ack[3];
wire wr_ack_ldr = wa_own_ack[4];

m2_wr_arb #(.N(5), .AW(SDR_AW)) u_wr_arb (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.req(wa_own_req), .addr(wa_own_addr), .din(wa_own_din), .ack(wa_own_ack),
	.s_req(wa_req), .s_addr(wa_addr), .s_din(wa_din), .s_ack(ldr_wr_ack)
);

m2_sdram_x2 #(.NP(NPORTS), .AW(SDR_AW)) u_sdram_x2 (
	.clk_fast(clk_mem),
	.s_req(p_req), .s_addr(p_addr), .s_ack(p_ack), .s_dout(p_dout),
	.s_we(p_we),   .s_din(p_din),   .s_be(p_be),
	// ONE OWNER AT A TIME (R209): m2_wr_arb grants the port for a whole
	// transaction and releases it with a dead cycle. The fixed-priority mux
	// that stood here let the coprocessor and the push DMA alternate without
	// the request line ever falling, so the adapter's `w_done` never cleared
	// and both owners waited forever (TGP at 0x46E, build/ack s14).
	.s_wr_req(wa_req), .s_wr_addr(wa_addr), .s_wr_din(wa_din),
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
// R228: THE DEVICE TIMES ARE NANOSECONDS, AND THE CLOCK IS NOW 120 MHz.
// Every one of these is a minimum time expressed in cycles, so a faster clock
// needs MORE of them: scaled by 6/5 from the 100 MHz values and rounded up,
// which is the safe direction. Refresh is 8,192 rows in 64 ms, one per 7.8125
// us, which is 937 cycles at 120 MHz against 781 at 100.
m2_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(781)) u_sdram (
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
	.sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(wr_ack_ldr),
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
			// PRESET TABLE for the OSD probe. Expected values, computed from the
			// simulation's own CPU-written char RAM (study R59 when it lands):
			//   0 bootIP  word 0x0000006  00000860
			//   1 chr 3   word 0x1690330  ff0000ff   <- the missing '3'
			//   2 chr 1   word 0x1690310  ff00000f   <- the missing '1'
			//   3 chr #   word 0x1690230  0f0000f0   same SDRAM row as digits
			//   4 chr A   word 0x1690410  ff0000ff   next row; renders on board
			//   5 row2    word 0x1690400  11ff0f11
			//   6 bndry   word 0x16903fe  f000000f   last dword of the row
			//   7 chr0    word 0x1690000  00000000
			2'd0: if (rom_loaded && cal_done) begin
				case (status[16:14])
					3'd0: rb_addr <= SDR_AW'(32'h0000006);
					3'd1: rb_addr <= SDR_AW'(32'h1690330);
					3'd2: rb_addr <= SDR_AW'(32'h1690310);
					// REPOINTED (R63): the formatted value string at work RAM
					// 0x53e540 -- the digit's last stop before the draw. Sim
					// writes ' ','3',NUL there: expect xx003320. xx002020 on the
					// board means the FORMATTER emitted spaces and the divergence
					// is inside or upstream of 0x10c4, with the settings byte
					// already proven correct.
					3'd3: rb_addr <= SDR_AW'(32'h161F2A0);
					3'd4: rb_addr <= SDR_AW'(32'h1690410);
					3'd5: rb_addr <= SDR_AW'(32'h1690400);
					3'd6: rb_addr <= SDR_AW'(32'h16903fe);
					default: rb_addr <= SDR_AW'(32'h1690000);
				endcase
				rb_req <= 1'b1; rb_state <= 2'd1;
			end
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
// TWELVE AND ABOVE, not twelve exactly: the states after it fill texture RAM
// (R223) and everything that waits on calibration must stay released through
// them.
assign cal_done = (st_state >= 4'd12);
logic [SDR_AW:1] st_addr, st_rd_addr;
logic [15:0]     st_din;
logic [3:0]      st_state;
logic [16:0]     tf_i;            // R223: the texture-RAM zero sweep
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

// BUFFER RAM INITIALISATION, AND IT IS NOT OPTIONAL.
//
// model2.cpp: "initialize bufferram to a sane default", m_bufferram[i] =
// 0x07800f0f. That comment exists because THE GAME READS THIS MEMORY BEFORE IT
// WRITES IT, and the value is not zero.
//
// Mapping the RAM without initialising it is WORSE than leaving it unmapped.
// Unmapped, reads returned a deterministic 0 and the machine reached 21,325 TGP
// retires; mapped over uninitialised SDRAM it died at 1,367 with "insert coin"
// no longer flashing. Both measured on the board, builds 25 and 27.
//
// AFTER cal_done, NOT BEFORE. The self-test above is the read-latency
// calibration and everything touching SDRAM waits for it; this only writes, but
// it shares the write port, so it takes its turn rather than racing. The i960
// then waits for `bi_done` -- 65,536 word writes, a few milliseconds, once.
//
// Word order: the bridge selects the half with r_addr[1] and sd_word is
// base + r_addr[16:1], so an EVEN word index is the LOW half of the dword.
localparam int unsigned BUF_WORDS = 65536;      // 128 KB as 16-bit words
logic            bi_run, bi_req, bi_done;
logic [SDR_AW:1] bi_addr;
logic [15:0]     bi_din;
logic [16:0]     bi_idx;

assign bi_run = rom_loaded && cal_done && !bi_done;

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		bi_req <= 1'b0; bi_done <= 1'b0; bi_idx <= 17'd0;
		bi_addr <= '0; bi_din <= 16'd0;
	end else if (rom_loaded && cal_done && !bi_done) begin
		if (!bi_req) begin
			bi_addr <= GAME_BUFFER + SDR_AW'(bi_idx);
			bi_din  <= bi_idx[0] ? 16'h0780 : 16'h0f0f;
			bi_req  <= 1'b1;
		end else if (wr_ack_bi) begin
			bi_req <= 1'b0;
			if (bi_idx == 17'(BUF_WORDS - 1)) bi_done <= 1'b1;
			else                              bi_idx  <= bi_idx + 17'd1;
		end
	end
end

assign st_run = rom_loaded && (st_state >= 4'd1) && (st_state <= 4'd8);

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		st_state <= 4'd0; st_req <= 1'b0; st_rd_req <= 1'b0; tf_i <= 17'd0;
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
			4'd1: if (wr_ack_st) begin st_req <= 1'b0; st_state <= 4'd2; end
			4'd2: begin st_addr <= ST_BASE + SDR_AW'(1); st_din <= STP1;
			            st_req <= 1'b1; st_state <= 4'd3; end
			4'd3: if (wr_ack_st) begin st_req <= 1'b0; st_state <= 4'd4; end
			4'd4: begin st_addr <= ST_BASE + SDR_AW'(2); st_din <= STP2;
			            st_req <= 1'b1; st_state <= 4'd5; end
			4'd5: if (wr_ack_st) begin st_req <= 1'b0; st_state <= 4'd6; end
			4'd6: begin st_addr <= ST_BASE + SDR_AW'(3); st_din <= STP3;
			            st_req <= 1'b1; st_state <= 4'd7; end
			4'd7: if (wr_ack_st) begin st_req <= 1'b0; st_state <= 4'd8; end
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
			// TEXTURE RAM STARTS AT ZERO, BECAUSE THAT IS WHAT THE REFERENCE
			// READS (R223). Nothing writes the raster's 64 K-word texture RAM
			// in a whole run of this title -- all 47 of its geo_texture_data
			// commands address log RAM -- yet 3% of its objects, the first six
			// of every list, take their texture header from it. MAME's
			// raster_state is value-initialised, so those headers read ZERO
			// there: renderer 0, flat and opaque, colour base 0, and they are
			// drawn. Unwritten SDRAM reads 0xFFFF, which is renderer 3 --
			// translucent -- and would cull every one of them. So the region is
			// swept once here, after the capture calibration and before the
			// CPU can ask for a frame; it is 65,536 words through the same
			// arbitrated write port the pattern above used, about 3 ms, and it
			// cannot stall anything because nothing waits on it.
			4'd12: begin
				tf_i <= 17'd0; st_addr <= GAME_TEXRAM; st_din <= 16'd0;
				st_req <= 1'b1; st_state <= 4'd13;
			end
			4'd13: if (wr_ack_st) begin
				st_req <= 1'b0;
				if (tf_i == 17'd65535) st_state <= 4'd14;
				else begin tf_i <= tf_i + 17'd1; st_state <= 4'd15; end
			end
			4'd15: begin
				st_addr <= GAME_TEXRAM + SDR_AW'(tf_i); st_din <= 16'd0;
				st_req <= 1'b1; st_state <= 4'd13;
			end
			4'd14: st_state <= 4'd14;      // done; cal_mask holds
			default: st_state <= 4'd0;
		endcase
	end
end

// Static once captured, so a two-flop synchroniser on the status bit is enough:
// the data is not moving when the video domain reads it.
logic [2:0] loaded_sync, st_ok_sync;
always_ff @(posedge clk_sys) begin
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
// MOVED UP 256 KB WHEN THE TGP TABLES WENT INTO THE MRA. R19 recorded the
// margin above the last ROM word as deliberate rather than incidental -- 0x30000
// words, 384 KB -- and adding the 256 KB of copro_tgp_tables took the image from
// 0x2BB0000 to 0x2BF0000 and that margin down to 64 KB. Still positive, and 64 KB
// is not margin: the next ROM anyone adds silently lands on work RAM, and the
// symptom would be the game corrupting its own variables.
localparam logic [SDR_AW:1] GAME_WORK  = SDR_AW'(32'h1620000);   // 1 MB
localparam logic [SDR_AW:1] GAME_BOARD = SDR_AW'(32'h16a0000);   // 128 KB
localparam logic [SDR_AW:1] GAME_CHAR  = SDR_AW'(32'h16b0000);   // 512 KB
// 0x16f0000 is the first word free after GAME_CHAR; ST_BASE is at 0x1F00000.
localparam logic [SDR_AW:1] GAME_BUFFER = SDR_AW'(32'h16f0000);   // 128 KB, 0x00900000
// POLYGON RAM, TWO OF THEM, AND THEY ARE NOT ON-CHIP.
//
// geo_object_data picks the memory an object is read from out of oba's top
// bits: 0x01000000 -> fast polygon RAM, else 0x00800000 -> polygon ROM, else
// slow polygon RAM. MAME's polygon_ram0/1 are 0x8000 DWORDS each -- 128 KB
// apiece, 256 KB together, which is 205 M10K blocks of the 553 on this part.
// M10K is the binding resource here (the fx68k pull established that), so they
// go in SDRAM beside buffer RAM instead. They are written by the display list
// itself, opcode 0x05 geo_polygon_data, not by the i960.
localparam logic [SDR_AW:1] GAME_PRAM0  = SDR_AW'(32'h1710000);   // 128 KB, slow
localparam logic [SDR_AW:1] GAME_PRAM1  = SDR_AW'(32'h1720000);   // 128 KB, fast
// R222: the 3D colour data the bridge mirrors and the walker's texture RAM.
// Free space: PRAM1 ends at word 0x1730000 and ST_BASE is 0x1F00000.
localparam logic [SDR_AW:1] GAME_PAL3D  = SDR_AW'(32'h1730000);   // 2 KB, palette 0x1000-0x13ff
localparam logic [SDR_AW:1] GAME_XLAT3D = SDR_AW'(32'h1731000);   // 48 KB, colorxlat
localparam logic [SDR_AW:1] GAME_TEXRAM = SDR_AW'(32'h1740000);   // 128 KB, texture RAM
localparam logic [SDR_AW:1] GAME_TEX    = SDR_AW'(32'h0720000);   // texture ROM, byte 0x0e40000 in the MRA, 8 MB

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

// TILE RAM: one write port, two read ports, ONE set of M10K blocks.
//
// This was an inferred array and Quartus 17.0 REPLICATED it -- tram_rtl_0 at 64
// blocks and tram_rtl_1 at another 64, for a 512 Kbit memory whose floor is 52.
// The palette below did the same at 15 + 16. Seventy-nine blocks of a
// 553-block device, spent holding two copies of something written on one port.
// m2_tdp_ram.sv has the reasoning and the read-during-write semantics.
wire [15:0] tram_q_cpu, tram_q_vid;
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
wire [15:0] pal_q_cpu, pal_q_vid;

logic [31:0] vrd_cnt, vrd_nz;    // renderer reads: total, and non-zero
logic [31:0] pl_cnt, pl_nz;      // palette reads: total, and non-zero
wire [14:0] tram_addr;
wire [11:0] pal_addr;
// THE MEMORY'S OWN REGISTERED OUTPUT IS THE ONE CYCLE, not a stage before it.
//
// This was `tram_data <= tram[tram_addr]`: one cycle from address to data.
// m2_tdp_ram already registers its output, so assigning tram_data from it in a
// clocked block would make the read TWO cycles and shift the whole picture by a
// pixel column -- a memory change quietly becoming a rendering change, which is
// exactly what a packing fix must not do. Continuous, so the depth is identical.
wire [15:0] tram_data = tram_q_vid;
wire [15:0] pal_data  = pal_q_vid;
always_ff @(posedge clk_sys) begin
	// WHAT THE RENDERER ACTUALLY GETS OUT.
	//
	// The CPU writes 42,013 NON-ZERO tile indices on hardware -- measured, not
	// sampled -- and the screen is two flat colours. Both cannot be true unless
	// the picture is lost between this array and the screen. So count what comes
	// OUT of the read port the same way the writes were counted: unbiased, and
	// on the board.
	//
	// If the renderer reads essentially nothing but zero while the CPU has
	// written 42,013 non-zero cells, the fault is this array's read path -- the
	// address it is given, or the memory itself. If it reads plenty of non-zero,
	// the tilemap is fine and the fault is downstream in palette or mixing.
	// Either answer removes half the remaining search.
	if (!mem_rst_n) begin
		vrd_cnt <= 32'd0; vrd_nz <= 32'd0;
	end else begin
		vrd_cnt <= vrd_cnt + 32'd1;
		if (|tram_data) vrd_nz <= vrd_nz + 32'd1;
	end
	if (!mem_rst_n) begin
		pl_cnt <= 32'd0; pl_nz <= 32'd0;
	end else begin
		pl_cnt <= pl_cnt + 32'd1;
		if (|pal_data) pl_nz <= pl_nz + 32'd1;
	end
end

// PORT B, on clk_sys: the copy engine and the CPU share it. Port A above is
// the renderer's, on clk_vid, and stays read-only. That is a true dual-port
// M10K, which is what the part gives; a third accessor would not fit and is
// why the copy engine and the bridge are muxed onto one port rather than given
// one each.
wire  [15:0] cpu_tram_q, cpu_pal_q;

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

// The memories themselves. Port A is the CPU's -- reads and writes -- and port
// B is the renderer's, read only. Both ports 16 bits wide, which is the
// condition for a single copy: mixed-width true dual-port is what forces
// replication.
//
// The renderer's read is registered ONE MORE TIME downstream (tram_data,
// pal_data) exactly as it was, so the pipeline depth is unchanged: the inferred
// version was `tram_data <= tram[addr]`, one cycle, and this is the memory's
// own cycle plus that register. Both consumers already tolerated a registered
// read; what matters is that the number did not move.
m2_tdp_ram #(.DW(16), .AW(15)) u_tram (
	.clk(clk_sys),
	.a_addr(ocb_addr),  .a_din(ocb_din), .a_we(ocb_tram_we), .a_q(tram_q_cpu),
	.b_addr(tram_addr), .b_q(tram_q_vid)
);

m2_tdp_ram #(.DW(16), .AW(13)) u_pal (
	.clk(clk_sys),
	.a_addr(ocb_addr[12:0]), .a_din(ocb_din), .a_we(ocb_pal_we), .a_q(pal_q_cpu),
	.b_addr({1'b0, pal_addr}), .b_q(pal_q_vid)
);

// Same on the CPU side: the memory's output is already a cycle behind its
// address, which is what `cpu_tram_q <= tram[ocb_addr]` was.
assign cpu_tram_q = tram_q_cpu;
assign cpu_pal_q  = pal_q_cpu;


// TRAM CELL PROBE, on its own read port (Quartus duplicates the array: ~64
// M10K, temporary, and unlike the fold probe this target is STATIC -- the menu
// cells are written once at boot, so the value is readable). The board renders
// glyph value 8043 at cell 1108 and drops the same value at cell 1130: cell-
// specific, value-independent. This reads the cell itself, OSD-selected on the
// same O[16:14] Probe control, shown on overlay row 23:
//   0:1129 want C033   1:1130 want 8043   2:1131 want 8052   3:1132 want 8045
//   4:1368 want 802F   5:1385 want 8023   6:1387 want C031   7:1108 want 8043
// Right value + not rendered = the render path drops the CELL.
// Wrong value = the CPU's write did not land on the board.
logic [14:0] tp_cell;
logic [15:0] tp_q;
always_comb case (status[16:14])
	3'd0: tp_cell = 15'd1129;  3'd1: tp_cell = 15'd1130;
	3'd2: tp_cell = 15'd1131;  3'd3: tp_cell = 15'd1132;
	3'd4: tp_cell = 15'd1368;  3'd5: tp_cell = 15'd1385;
	3'd6: tp_cell = 15'd1387;  default: tp_cell = 15'd1108;
endcase
// OBSERVE THE WRITE, DO NOT ADD A READ PORT.
//
// This was `tp_q <= tram[tp_cell]`, and an M10K has exactly TWO ports. Tile
// RAM already has both: the renderer reads on clk_vid, the CPU and copy
// engine share the clk_sys read/write pair. Asking for a third reader makes
// the fitter build a SECOND COMPLETE COPY of the array to serve it -- the
// report shows tram fitted as two 32768x16 blocks at 64 M10K each, and block
// memory implementation bits at 3,194,880 against 2,265,601 actually needed.
// 128 of 312 M10K, spent on a debug probe.
//
// Watching the write bus costs nothing: no port, no duplication, and it
// cannot disturb a CPU read the way stealing a cycle on the shared port
// could. It reports the last value WRITTEN to the selected cell rather than
// the cell's current contents, which for "what did the game put here" is the
// same answer and is exactly the semantic the blanking watch already uses.
//
// Standing rule, paid for twice now (m2_backup's third read port produced
// 131,795 combinational nodes and would not fit): a debug read port on a
// memory is never free. Observe the write bus instead.
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n)                                    tp_q <= 16'd0;
	else if (ocb_tram_we && ocb_addr == tp_cell)       tp_q <= ocb_din;
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
wire cpu_rst_n = game_rst_n & rom_loaded & game_image & cal_done & bi_done;

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
// THE '3' BYTE'S WRITE, LATCHED AT THE SDRAM PORT (R63). The formatter's
// stob to 0x53e541 arrives here as a write to word 0x161F2A0 with the upper
// byte enabled. If this latch shows 33xx the write was issued and the fault is
// in the memory path; if it never fires, the formatter never ran on the board
// and the branch above it diverges. Count in the top byte, data below.
logic [7:0]  vsw_cnt;
logic [15:0] vsw_data;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin vsw_cnt <= 8'd0; vsw_data <= 16'd0; end
	else if (cpu_sd_req && cpu_sd_we && cpu_sd_addr == SDR_AW'(32'h161F2A0)
	         && cpu_sd_be[1]) begin
		if (!(&vsw_cnt)) vsw_cnt <= vsw_cnt + 8'd1;
		vsw_data <= cpu_sd_din;
	end
end

// EXCHANGE-COLLISION TELEMETRY (R63). The board's settings arrive in backup
// as 7F FF 7F -- the Z80's input-scan pattern -- so the firmware's window
// refill and the game's settings deposit collide in the DPRAM. Count the
// Z80's writes into the window (bytes 0x100-0x17f) and latch the LAST one's
// address, so the scan's cadence and reach are readable from the bench.
// Plus a game-reset edge counter: 'reset does not work' becomes a number.
logic [7:0]  zw_win_cnt;
logic [10:0] zw_last;
logic [7:0]  rst_edges;
logic        grst_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		zw_win_cnt <= 8'd0; zw_last <= 11'd0; rst_edges <= 8'd0; grst_d <= 1'b1;
	end else begin
		if (zio_we && fw_ready && zio_addr >= 11'h100 && zio_addr < 11'h180) begin
			if (!(&zw_win_cnt)) zw_win_cnt <= zw_win_cnt + 8'd1;
			zw_last <= zio_addr;
		end
		grst_d <= game_rst_n;
		if (grst_d && !game_rst_n && !(&rst_edges)) rst_edges <= rst_edges + 8'd1;
	end
end

wire        cpu_sd_req, cpu_sd_we;
wire [SDR_AW:1] cpu_sd_addr;
wire [15:0] cpu_sd_din;
wire  [1:0] cpu_sd_be;
wire [31:0] cpu_dbg_rd, cpu_dbg_wr, cpu_dbg_unmapped;

m2_cpu_bridge #(.BUFFERRAM(1'b1), .BUFFERRAM_WRONLY(1'b0)
                  , .AW(SDR_AW), .BOARD_2A(1'b0), .DCACHE_EN(1'b1)) u_cpu_bridge (
	.dbg_dc_hits(dc_hits), .dbg_dc_miss(dc_miss),
	.char_wr(cpu_char_wr), .char_wr_addr(cpu_char_wr_addr),
	.clk_cpu(clk_i960), .rst_n_cpu(cpu_rst_n),
	.bus_req(cpu_req), .bus_we(cpu_we), .bus_addr(cpu_addr), .bus_be(cpu_be),
	.bus_wdata(cpu_wdata), .bus_rdata(cpu_rdata), .bus_ack(cpu_ack),

	.clk_mem(clk_sys), .rst_n_mem(cpu_rst_n),
	.base_prog(GAME_PROG), .base_data(GAME_DATA), .base_work(GAME_WORK),
	.base_board(GAME_BOARD), .base_char(char_base), .base_buffer(GAME_BUFFER),
	.base_pal3d(GAME_PAL3D), .base_xlat3d(GAME_XLAT3D), .col_inval(cpu_col_inval),

	.sd_req(cpu_sd_req), .sd_we(cpu_sd_we), .sd_addr(cpu_sd_addr),
	.sd_din(cpu_sd_din), .sd_be(cpu_sd_be),
	.sd_dout(p_dout[1]), .sd_ack(p_ack[1]),

	.oc_tram_we(cpu_tram_we), .oc_pal_we(cpu_pal_we),
	.oc_addr(cpu_oc_addr), .oc_din(cpu_oc_din),
	.oc_tram_q(cpu_tram_q), .oc_pal_q(cpu_pal_q),

	.oc_xlat_we(cpu_xlat_we_b), .oc_xlat_addr(cpu_xlat_addr_b),
	.oc_xlat_din(cpu_xlat_din_b),

	.io_rdata(cpu_io_rdata), .io_sel(cpu_io_sel), .io_we(cpu_io_we),
	.io_stall(cpu_io_stall),
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
wire  uart_irq;      // TXRDY|RXRDY, gated by TxEN/RxEN -- txrdy_r()||rxrdy_r()
wire  uart_irq_rx, uart_irq_tx;   // the halves; the i960 takes the OR, the 68000 takes RX
logic uart_irq_d;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		io_intreq <= 12'd0; io_intena <= 12'd0; io_videoctl <= 32'd0;
		uart_irq_d <= 1'b0;
		io_framenum <= 32'd0; vbl_d <= 1'b0; vbl_dd <= 1'b0;
	end else begin
		// FROM THE PICTURE'S OWN VBLANK, not the duplicate timing generator.
		//
		// u_timing is a SECOND m2_video_timing instance whose only real consumer
		// was this interrupt, so the CPU was timing off a generator that draws
		// nothing while m2_video ran its own. Two sources of truth for when a
		// frame ends, and the frame counter followed the wrong one.
		//
		// tile_vb is m2_video's vid_vb: the blanking the picture is actually
		// built from. Correct on any clock arrangement -- this is not a
		// domain-crossing fix, it is the frame counter counting the right thing.
		vbl_d  <= tile_vb;
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

		// ---- THE SOUND INTERRUPT, WHICH IS WHAT ACTUALLY SENDS THE BYTES.
		//
		// Line 10. model2.cpp raises it from sound_ready_w whenever TXRDY or
		// RXRDY changes and either is then active, and again from
		// irq_mask_delayed_update when the mask itself is written.
		//
		// This is the whole transmit engine and it took a board measurement to
		// see it: Daytona NEVER reads the i8251's status -- a read tap over 900
		// frames of attract mode fires zero times -- so nothing in the mainline
		// waits for the transmitter. The handler is the loop. TXRDY rises when
		// a byte finishes, that raises line 10, the handler writes the next
		// byte, TXRDY falls. The link's own pacing clocks the stream.
		//
		// Wire the i8251's irq to nothing and the symptom is exact and
		// misleading: the eleven CONTROL writes still happen, because those are
		// mainline initialisation, and not one of the forty-eight DATA bytes
		// ever does. Which is what the board reported -- uart_sel 11, data
		// writes 0 -- and reads as a broken data path rather than a missing
		// interrupt.
		//
		// BOTH triggers are needed. The edge alone never starts: after the
		// command byte enables TxEN, TXRDY is ALREADY high, so there is no edge
		// left to catch and the first interrupt never arrives. The mask write
		// is what fires it, exactly as irq_mask_delayed_update does.
		uart_irq_d <= uart_irq;
		if (io_intena[10] && ((uart_irq && !uart_irq_d) ||
		                      (uart_irq && cpu_io_sel && cpu_io_we &&
		                       cpu_io_addr[23:0] == 24'he80004 && cpu_io_wdata[10])))
			io_intreq[10] <= 1'b1;
	end
end

// ---------------------------------------------------------- the sound link
//
// The i8251 the i960 talks to the sound board through, at 0x01c80000. Byte-wide
// at bytes 0 and 2 of the dword -- model2.cpp maps it .umask16(0x00ff) -- so it
// is the same shape as the I/O board's DPRAM: data in byte 0, status/command in
// byte 2, and the byte enables say which one an access names.
//
// THE FAR END IS NOT HERE YET. The sound board's 68000, YM3438 and two
// MultiPCMs are the next pieces; until they exist the link's B side is drained
// so the i960 is never blocked -- a receiver that never acknowledges would stall
// the wire after one byte and the game would sit waiting on TXRDY forever, which
// would look exactly like a broken UART. The byte COUNT and the last byte are
// reported over the serial channel, so the board can be checked against the
// reference's 59 bytes before any of that arrives.
wire        uart_sel = cpu_io_sel && (cpu_io_addr[23:2] == 22'h32_0000);
wire        uart_ctl = uart_sel && cpu_io_be[2];      // byte 2: status/command
wire        uart_dat = uart_sel && cpu_io_be[0];      // byte 0: data
wire  [7:0] uart_dout, uart_data_byte, uart_status_byte;
// A read consumes the data byte, so `sel` is asserted for a read only when the
// access names byte 0 ALONE. Status polls are wider or name byte 2 and must
// leave the received byte where it is.
wire        uart_rd_dat = uart_sel && !cpu_io_we && cpu_io_be[0] && !cpu_io_be[2];
wire [31:0] snd_bytes, snd_sig;
wire  [7:0] snd_last;

// THREE COUNTERS, BECAUSE "no bytes came out" HAS THREE DIFFERENT CAUSES and
// they need different fixes. Does the address get selected at all; does a data
// write reach the device; does the link take the byte. Counting all three says
// which hop is broken instead of which hop is suspected. MAME writes this port
// 59 times over 900 frames -- 11 control, 48 data, first data byte at frame 13 --
// and never reads it back, so the board has a number to be wrong against.
logic [15:0] uart_sel_cnt, uart_wr_cnt;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		uart_sel_cnt <= 16'd0;
		uart_wr_cnt  <= 16'd0;
	end else begin
		if (uart_sel && !(&uart_sel_cnt))                  uart_sel_cnt <= uart_sel_cnt + 16'd1;
		if (cpu_io_we && uart_dat && !(&uart_wr_cnt))      uart_wr_cnt  <= uart_wr_cnt + 16'd1;
	end
end

wire  [7:0] a_tx_d, a_rx_d;
wire        a_tx_v, a_tx_a, a_rx_v, a_rx_a;

m2_i8251 u_uart_main (
	.clk(clk_sys), .rst_n(cpu_rst_n),
	.sel((cpu_io_we && (uart_dat | uart_ctl)) || uart_rd_dat),
	.we(cpu_io_we), .addr(uart_ctl & ~uart_dat),
	.din(uart_ctl & ~uart_dat ? cpu_io_wdata[23:16] : cpu_io_wdata[7:0]),
	.dout(uart_dout), .data_o(uart_data_byte), .stat_o(uart_status_byte),
	.tx_data(a_tx_d), .tx_valid(a_tx_v), .tx_ack(a_tx_a),
	.rx_data(a_rx_d), .rx_valid(a_rx_v), .rx_ack(a_rx_a),
	.irq(uart_irq), .irq_rx(uart_irq_rx), .irq_tx(uart_irq_tx)
);

m2_sound_link u_snd_link (
	.clk(clk_sys), .rst_n(cpu_rst_n),
	.a_tx_data(a_tx_d), .a_tx_valid(a_tx_v), .a_tx_ack(a_tx_a),
	.a_rx_data(a_rx_d), .a_rx_valid(a_rx_v), .a_rx_ack(a_rx_a),
	// THE FAR END IS REAL NOW. It was drained -- b_rx_ack tied to b_rx_valid --
	// so the i960 was never blocked while there was nothing to receive the
	// bytes. The board's 48 bytes went out over that wire and matched MAME's
	// signature exactly; they now go to a 68000 that reads them.
	.b_tx_data(b_tx_d), .b_tx_valid(b_tx_v), .b_tx_ack(b_tx_a),
	.b_rx_data(b_rx_d), .b_rx_valid(b_rx_v), .b_rx_ack(b_rx_a),
	.dbg_a_bytes(snd_bytes), .dbg_a_last(snd_last), .dbg_a_sig(snd_sig)
);

// ------------------------------------------------------- the sound board
//
// The Model 1 board: fx68k, a YM3438 and 64 KB of RAM, with the two MULTIPCMs
// still to come. Study R87 has the map and how it was established.
//
// ITS OWN RESET, HELD UNTIL THE ROM IS THERE. The 68000 fetches its reset
// vector from SDRAM, so releasing it before the loader has finished means it
// reads whatever the image holds at that moment -- 0xFFFF on an empty
// controller -- and takes an address error it never recovers from. mem_rst_n
// and cp_done are the same pair the renderer waits on.
wire [7:0]  b_rx_d, b_tx_d;
wire        b_rx_v, b_rx_a, b_tx_v, b_tx_a;
wire        snd_rom_ack = p_ack[5];
// BYTE SWAPPED, BECAUSE THE 68000 IS BIG-ENDIAN AND THE LOADER IS NOT.
//
// The ROM loader's mapping is the identity -- stream byte N is SDRAM byte N --
// and a 16-bit SDRAM word therefore holds {byte 2W+1, byte 2W}, little end
// first. That is right for the i960 and backwards for a 68000: the image at
// 0x2350000 begins 00 f0 ff fe, which packs to 0xF000 and reads as a stack
// pointer of 0xF000FEFF instead of 0x00F0FFFE.
//
// Swapping HERE rather than in the loader is deliberate. The loader serves
// every other consumer correctly and byte order is a property of the reader,
// not of the image -- the same bytes are right for one CPU and wrong for the
// other. One place that knows this CPU is big-endian beats a special case in a
// path that six other things depend on.
wire [15:0] snd_rom_w   = p_dout[5][{1'b0, snd_rom_addr[2:1]} * 16 +: 16];
wire [15:0] snd_rom_q   = {snd_rom_w[7:0], snd_rom_w[15:8]};

// THE SOUND ROM FINDS ITSELF, because neither the MRA's comment nor a
// reconstruction of the image can be trusted to say where it is.
//
// The comment said byte 0x2340000. Searching a rebuilt image said 0x2350000.
// The board, reading 0x2350000, fetched 84D6 84D3 84DD 84DA -- structured
// garbage with a constant byte, which is the signature of the wrong REGION
// rather than the wrong byte order. Study R39 already records this exact
// disagreement and which side won: "The BOARD had them in the right place
// throughout; the reference did not." tools/rom_csum.py reconstructs the
// image, and a reconstruction is not the image.
//
// So stop asserting an address and go and find one. The 68000's reset vector is
// a four-word signature that appears nowhere else: stack pointer 0x00F0FFFE --
// the top of the sound board's own 64 KB RAM -- followed by PC 0x00000300. Sweep
// 64 KB-aligned candidates, which is the granularity every section in this MRA
// actually lands on, and stop at the first match.
//
// 448 candidates, one four-word burst each, at 96 MHz. It costs microseconds
// once, and it is right across any future reshuffle of the ROM layout.
localparam logic [SDR_AW:1] SND_SCAN_LO   = SDR_AW'(32'h0800000);
localparam logic [SDR_AW:1] SND_SCAN_HI   = SDR_AW'(32'h1600000);
localparam logic [SDR_AW:1] SND_SCAN_STEP = SDR_AW'(32'h0008000);   // 64 KB

typedef enum logic [1:0] { SC_IDLE, SC_REQ, SC_WAIT, SC_DONE } scan_t;
scan_t          sc_st;
logic [SDR_AW:1] sc_addr, snd_base;
logic            sc_req, snd_found;
logic [31:0]     sc_first;      // what the first candidate held, for the log

// The swapped view of the burst, which is what the 68000 would see.
wire [15:0] sc_w0 = {p_dout[5][ 7: 0], p_dout[5][15: 8]};
wire [15:0] sc_w1 = {p_dout[5][23:16], p_dout[5][31:24]};
wire [15:0] sc_w2 = {p_dout[5][39:32], p_dout[5][47:40]};
wire [15:0] sc_w3 = {p_dout[5][55:48], p_dout[5][63:56]};
wire        sc_hit = (sc_w0 == 16'h00f0) && (sc_w1 == 16'hfffe)
                  && (sc_w2 == 16'h0000) && (sc_w3 == 16'h0300);

always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		sc_st <= SC_IDLE; sc_addr <= SND_SCAN_LO; sc_req <= 1'b0;
		snd_base <= SND_SCAN_LO; snd_found <= 1'b0; sc_first <= 32'd0;
	end else begin
		case (sc_st)
			SC_IDLE: if (cp_done) begin
				sc_req <= 1'b1;
				sc_st  <= SC_REQ;
			end
			SC_REQ: sc_st <= SC_WAIT;
			SC_WAIT: if (p_ack[5]) begin
				sc_req <= 1'b0;
				if (sc_addr == SND_SCAN_LO) sc_first <= {sc_w0, sc_w1};
				if (sc_hit) begin
					snd_base  <= sc_addr;
					snd_found <= 1'b1;
					sc_st     <= SC_DONE;
				end else if (sc_addr >= SND_SCAN_HI) begin
					// Not found. Stop, and say so by leaving snd_found clear --
					// the 68000 then stays in reset rather than executing
					// whatever happens to be at a guessed address, which is the
					// failure this replaces.
					sc_st <= SC_DONE;
				end else begin
					sc_addr <= sc_addr + SND_SCAN_STEP;
					sc_st   <= SC_IDLE;
				end
			end
			default: ;
		endcase
		if (sc_st == SC_IDLE && !cp_done) sc_req <= 1'b0;
	end
end

wire signed [15:0] snd_l, snd_r;

// Byte out of the burst: word by [2:1], byte within it by [0].
// The byte select moved INTO m2_pcm_fetch with the burst, and doing it here as
// well -- off a burst index -- is what made this wrong twice over. The whole
// 64-bit burst goes down; the byte comes back out at the far end.

// BOTH SOUND STAGES ON, and both are needed -- measured at a realistic
// 300-cycle sample-fetch latency with the addressing finally correct:
//
//   neither      59% of nominal rate, 0 underruns
//   cache only   89%,                 0 underruns
//   rate only    65%,             9,672 underruns
//   both        100%,                 0 underruns
//
// The rate stage ALONE starves: it drains at a fixed 44,643 Hz and without the
// cache the chip cannot produce samples that fast, so the buffer runs dry.
// The cache alone leaves the rate short and the period uneven. Together they
// hold 100% with no underruns at every latency from 40 to 600 cycles.
m2_sound_board #(.PCM_CACHE(1'b1), .PCM_RATE(1'b1), .TICK_DEN(50)) u_sndboard (
	.clk(clk_sys), .rst_n(cpu_rst_n & mem_rst_n & cp_done & snd_found),
	.rx_data(b_rx_d), .rx_valid(b_rx_v), .rx_ack(b_rx_a),
	.tx_data(b_tx_d), .tx_valid(b_tx_v), .tx_ack(b_tx_a),
	.rom_req(snd_rom_req), .rom_addr(snd_rom_addr),
	.rom_ack(snd_rom_ack), .rom_data(snd_rom_q),
	.pcm1_rom_req(pcm1_req), .pcm1_rom_addr(pcm1_addr),
	.pcm1_rom_data(p_dout[6]), .pcm1_rom_ack(p_ack[6]),
	.pcm2_rom_req(pcm2_req), .pcm2_rom_addr(pcm2_addr),
	.pcm2_rom_data(p_dout[7]), .pcm2_rom_ack(p_ack[7]),
	.snd_l(snd_l), .snd_r(snd_r),
	.dbg_pc(snd_pc), .dbg_insns(snd_insns),
	.dbg_ym_writes(snd_ymw), .dbg_pcm_writes(snd_pcmw),
	.dbg_pcm_samples(snd_samples),
	.dbg_pcm_lat(snd_lat), .dbg_pcm_miss(snd_miss),
	.dbg_pcm_under(snd_under), .dbg_pcm_level(snd_level)
);

wire [31:0] snd_pc, snd_insns;
wire [15:0] snd_ymw, snd_pcmw;
wire [31:0] snd_samples;
wire [15:0] snd_lat, snd_miss, snd_under;
wire  [7:0] snd_level;

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
	// geo_r: the game sets these and READS THEM BACK to find where it is.
	// Returning 0 is the suspected cause of the R129 livelock.
	(cpu_io_addr[23:0] == 24'h802008) ? geo_rd_wp :
	(cpu_io_addr[23:0] == 24'h803008) ? geo_rd_rp :
	// The sound UART, byte 0 = data and byte 2 = status. Read as a dword the
	// i960 gets both, which is what .umask16(0x00ff) presents.
	(cpu_io_addr[23:2] == 22'h32_0000)
		? {8'd0, uart_status_byte, 8'd0, uart_data_byte} :
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
	// THE COPROCESSOR, all three of its registers. The stub that used to sit
	// here answered 0x980004 with a constant 1 -- "the output FIFO is empty",
	// which is true of a copro that never starts and a lie about one that has.
	copro_sel                         ? copro_rdata :
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

// ----------------------------------------------------------- COPROCESSOR
//
// Three regions, from model2.cpp's map. cpu_io_addr carries the low 24 bits.
//
//   0x00884000-0x00887fff  copro_fifo   read pops the output FIFO; write
//                                       pushes the input FIFO, OR writes the
//                                       program -- copro_ctl1 bit 31 selects
//   0x00980000             copro_ctl1
//   0x00980004             fifo_control read: 1 when the output FIFO is empty
//
// A COMBINATIONAL rdata is correct here and a registered one would be wrong,
// which is the opposite of m2_ioboard and worth stating. io_sel is a one-cycle
// pulse and m2_cpu_bridge samples io_rdata DURING that cycle, so a peripheral
// that registers on the address (the I/O board, which must, because an
// asynchronously read array is flip-flops on this part) is ready in time,
// while one that registered on the select would answer a cycle late. The FIFO
// pop rides the same cycle: rdata presents the current head and the read
// pointer advances on the edge that ends it, so the i960 gets the entry it
// asked for rather than the one after it.
// EVERY WRITE TO THIS PORT IS ONE FIFO WORD. copro_fifo_w takes a plain u32
// and pushes once per call; there is no burst filtering.
//
// A previous version tested cpu_io_addr[3:2] == 0 here, on the theory that the
// port is not burst-capable and takes only the first dword of the i960's quad
// stores. That was WRONG, and it was wrong because of a bad measurement: MAME's
// TGP program space is WORD-addressed, so it must be read as `read_u32(word)`,
// and it had been read as `read_u32(word*4)`. Sampling word*4 across a
// 2024-word program only lands inside it for the first 506 samples -- which is
// exactly the "506-word program" that theory rested on. Read correctly, MAME's
// program is 2024 non-zero words and satisfies program[i] == write[i]. See R116.
wire        copro_fifo_sel = cpu_io_sel && (cpu_io_addr[23:14] == 10'h221);
// The function port. 0x00880000-0x00883fff, one region above the FIFO. The
// command code is the address: MAME takes (offset >> 2) & 0xff of a dword
// offset, which is bits 11:4 of the byte address.
wire        copro_fn_sel   = cpu_io_sel && (cpu_io_addr[23:14] == 10'h220);
// ------------------------------------------------------------- GEOMETRIZER
// The front door only: two pointers and the push path. The reference DISCARDS
// the microcode upload and hardcodes the pipeline, so there is no program
// memory here and no decode -- see study R130. The list walk comes next.
//
//   0x00800000-0x00800fff  function writes -> push
//   0x00801008 (w)         set write pointer      0x00802008 (r) read it back
//   0x00803008 (w/r)       read pointer
//   0x00804000-0x00807fff  geoctl[31] ? count+discard : push
//   0x00980008             geo_ctl1
wire geo_wr_ctl   = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0]  == 24'h980008);
wire geo_wr_setwp = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0]  == 24'h801008);
wire geo_wr_setrp = cpu_io_sel && cpu_io_we && (cpu_io_addr[23:0]  == 24'h803008);
// THE OPCODE IS IN THE ADDRESS, NOT IN THE DATA, and missing that is why no
// geometry has ever drawn.
//
// Dumped MAME's buffer RAM at the same frame and compared it word for word
// with ours. Every OPERAND matched. Every COMMAND word was zero in ours:
//
//     dword   MAME        ours
//       0     04000000    00000000     op 08 zsort_mode
//       1     40800000    40800000     ok
//       2     01800000    00000000     op 03 window_data
//      3-8    (six window operands)    all identical
//       9     02000000    00000000     op 04 texture_data
//      10     008050f8    008050f8     ok
//
// geo_w (model2.cpp) reconstructs the command word from the WRITE ADDRESS:
//
//     if (data & 0x80000000) {
//         r = (data & 0x800fffff) | (((address >> 4) & 0x3f) << 23);
//         push_geo_data(r);
//     } else if ((address & 0xf) == 0) {
//         r = (data & 0x000fffff) | (((address >> 4) & 0x3f) << 23);
//         if (((address >> 4) & 0xc0) && function == 1)
//             r |= ((address >> 10) & 3) << 29;    // eye mode, Sega Rally
//         push_geo_data(r);
//     }
//     // bit31 clear and address not 16-byte aligned: NOTHING is pushed
//
// The i960 selects a command by WHERE it writes -- 0x800000 + (function << 4)
// -- and the geometrizer folds that function number into bits 28:23, which is
// exactly the field the walk decodes as the opcode. This core pushed cpu_io_wdata
// verbatim, so every operand landed correctly and every command word arrived as
// its data half with no opcode: zero.
//
// That is the whole reason matrix writes read zero, every vertex collapsed to
// the projection centre, and 252 object_data commands were parsed out of what
// was actually unwritten memory.
//
// 0x804000-0x807fff is geo_prg_w and IS a verbatim push -- that one was right.
wire        geo_fn_win  = (cpu_io_addr[23:12] == 12'h800);   // 0x800000-0x800fff
wire        geo_prg_win = (cpu_io_addr[23:14] == 10'h201);   // 0x804000-0x807fff
wire [11:0] geo_fa      = cpu_io_addr[11:0];                 // byte address in the window
wire  [5:0] geo_func    = geo_fa[9:4];
wire        geo_hi      = cpu_io_wdata[31];
// Eye mode rides bits 30:29 for function 1 when the address is above 0x400.
wire  [1:0] geo_eye     = geo_fa[11:10];
wire        geo_eye_en  = (|geo_eye) && (geo_func == 6'd1);

wire [31:0] geo_push_word =
      geo_prg_win ? cpu_io_wdata
    : geo_hi      ? ((cpu_io_wdata & 32'h800fffff) | ({26'd0, geo_func} << 23))
                  : ((cpu_io_wdata & 32'h000fffff) | ({26'd0, geo_func} << 23)
                     | (geo_eye_en ? ({30'd0, geo_eye} << 29) : 32'd0));

wire geo_wr_push  = cpu_io_sel && cpu_io_we &&
                    (geo_prg_win ||
                     (geo_fn_win && (geo_hi || (geo_fa[3:0] == 4'd0))));

// WHAT IS ACTUALLY BEING PUSHED. The counters say the i960 writes and the front
// door accepts -- ~38,900 words and climbing, drops long since stopped -- and
// the walk still decodes zero matrix writes. So either the reconstructed word
// is wrong or the walk never reaches it, and only the word itself separates
// those. Captured on the FUNCTION port alone: the 0x804000 path is a verbatim
// push and was never in doubt.
// The words themselves are now known good: the board pushes 01800000 (op 03
// window_data, byte-identical to MAME's dword 2) and 07800000 (op 0f geo_end).
// So the address reconstruction works on hardware, and the remaining question
// is whether a MATRIX WRITE is ever pushed at all -- one sampled word per UART
// record is far too sparse to say.
//
// Counting by opcode answers it outright:
//   mtx_push > 0 and mtx_n = 0  -> the walk is not decoding what arrives
//   mtx_push = 0                -> the game never sends a matrix, and the fault
//                                  is upstream of the geometrizer entirely
// TWO DIRECT COUNTS, BECAUSE SAMPLING CANNOT ANSWER THIS.
//
// The board pushes 110 matrix writes and stops; the bench pushes 15,993 from
// the same ROMs. Either the game stops running its 3D code, or it keeps running
// it and the push path discards those writes. A profiler cannot separate those
// -- prof_div is 16 bits, 12.7 samples per frame, which is what invalidated the
// previous attempt (R185 retraction).
//
// geo_mtx_frame answers WHEN it stopped: the walk's frame counter latched at the
// moment the last matrix write was pushed. Frame 3 means initialisation only;
// frame 900 means something changed mid-attract.
//
// geo_fn_reject answers WHETHER WE ARE THROWING THEM AWAY. The function port is
// the one place in this design that deliberately discards a CPU write:
// geo_wr_push requires bit 31 set OR a 16-byte-aligned address, mirroring
// geo_w. Nothing has ever counted what falls in that bin, and a game writing
// matrices through a path we reject would look exactly like a game that stopped
// sending them.
logic [31:0] geo_last_push;
logic [15:0] geo_fn_pushes;
logic [15:0] geo_mtx_push, geo_obj_push;
logic [15:0] geo_mtx_frame, geo_fn_reject;
wire  [4:0]  geo_push_op = geo_push_word[27:23];
// A write to the function window that the push gate refuses.
wire geo_fn_dropped = cpu_io_sel && cpu_io_we && geo_fn_win
                   && !(geo_hi || (geo_fa[3:0] == 4'd0));
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		geo_last_push <= 32'd0; geo_fn_pushes <= 16'd0;
		geo_mtx_push <= 16'd0; geo_obj_push <= 16'd0;
		geo_mtx_frame <= 16'd0; geo_fn_reject <= 16'd0;
	end else begin
	  if (geo_fn_dropped && !(&geo_fn_reject)) geo_fn_reject <= geo_fn_reject + 16'd1;
	  if (geo_wr_push) begin
		if (geo_fn_win) begin
			geo_last_push <= geo_push_word;
			if (!(&geo_fn_pushes)) geo_fn_pushes <= geo_fn_pushes + 16'd1;
		end
		// Both ports: geo_prg_w pushes verbatim and can carry commands too.
		if (geo_push_op[3:0] == 4'hb) begin
			if (!(&geo_mtx_push)) geo_mtx_push <= geo_mtx_push + 16'd1;
			geo_mtx_frame <= geo_walk_frames;   // when the last one went through
		end
		if ((geo_push_op[3:0] == 4'h1) && !(&geo_obj_push))
			geo_obj_push <= geo_obj_push + 16'd1;
	  end
	end
end
wire [31:0] geo_rd_wp, geo_rd_rp, geo_pushes, geo_dropped, geo_ctl_dbg;
wire [15:0] geo_cnt_dbg;
wire        geo_sd_req, geo_sd_busy_raw;
// GEO_BUFW: the front door's push DMA into SHARED buffer RAM -- the LAST
// writer of that memory not yet cleared by experiment. BUFFERRAM_WRONLY does
// not clear it: these writes go through the shared SDRAM write port, not the
// bridge, so they still happen -- they merely became invisible when the CPU
// stopped reading buffer RAM back. Masking geo_sd_busy (not just the request)
// hands the port cleanly back to the loader instead of stranding the mux.
// The front door DROPS on backpressure and counts it, so it cannot stall the
// i960 -- measured, "overrun: 3205 dropped, counted, never stalled".
`ifdef M2_NO_GEO_BUFW
localparam bit GEO_BUFW = 1'b0;
`else
localparam bit GEO_BUFW = 1'b1;
`endif
wire geo_sd_busy = geo_sd_busy_raw & GEO_BUFW;
wire [SDR_AW:1] geo_sd_addr;
wire [15:0] geo_sd_din;

wire [19:0] geo_dbg_rp, geo_dbg_wp;

m2_geo #(.AW(SDR_AW), .DEPTH(128)) u_geo (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.wr_ctl(geo_wr_ctl), .wr_setwp(geo_wr_setwp), .wr_setrp(geo_wr_setrp),
	.trig_mode(status[24:23]),
	.wr_push(geo_wr_push), .wdata(geo_push_word),
	.rd_wp(geo_rd_wp), .rd_rp(geo_rd_rp),
	.base_buffer(GAME_BUFFER),
	.sd_wr_req(geo_sd_req), .sd_wr_addr(geo_sd_addr), .sd_wr_din(geo_sd_din),
	.sd_wr_ack(wr_ack_geo), .sd_busy(geo_sd_busy_raw),
	.dbg_pushes(geo_pushes), .dbg_dropped(geo_dropped),
	.dbg_geocnt(geo_cnt_dbg), .dbg_geoctl(geo_ctl_dbg),
	.frame_start(geo_walk_start),
	.rd_req(geo_rd_req), .rd_addr(geo_rd_addr),
	.rd_data(geo_rd_data_c), .rd_ack(geo_rd_ack_c),      // R214: through the pair cache
	.dbg_walk_ops(geo_walk_ops), .dbg_walk_objs(geo_walk_objs),
	.dbg_walk_frames(geo_walk_frames), .dbg_walk_unknown(geo_walk_unknown),
	.dbg_walk_state(geo_walk_state),
	.dbg_rp(geo_dbg_rp), .dbg_wp(geo_dbg_wp),
	.mtx0(), .mtx4(), .mtx8(), .mtx11(),
	.mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
	.eng_busy(eng_busy),
	// THESE FOUR WERE LEFT DANGLING AND IT REACHED HARDWARE. An unconnected
	// input ties to zero, so geo_polygon_data would have written the game's
	// polygon data at word 0 of SDRAM -- GAME_PROG, the i960's program ROM.
	// lint_top passed it because PINMISSING was not in its filter.
	.base_pram0(GAME_PRAM0), .base_pram1(GAME_PRAM1),
	.base_texram(GAME_TEXRAM), .dbg_td_words(),
	.dbg_pd_words(geo_pd_words), .dbg_pd_cmds(geo_pd_cmds),
	.foc_x(geo_foc_x), .foc_y(geo_foc_y),
	// The light vector, for the luminance stage. Captured but not yet consumed:
	// the dot products and the diffuse/ambient scale are still to come.
	.lit_x(geo_lit_x), .lit_y(geo_lit_y), .lit_z(geo_lit_z),
	.dbg_lit_n(geo_lit_n),
	// The diffuse/ambient table, streamed. Captured but not yet consumed -- the
	// luminance stage that reads it is the next piece.
	.tp_we(geo_tp_we), .tp_idx(geo_tp_idx),
	.tp_diffuse(geo_tp_diffuse), .tp_ambient(geo_tp_ambient),
	.dbg_tp_n(geo_tp_n),
	.obj_tpa(), .obj_tha(geo_obj_tha), .obj_oba(geo_obj_oba), .obj_obc(geo_obj_obc),
	.obj_valid(geo_obj_valid),
	.dbg_mtx_n(geo_mtx_n), .dbg_foc_n(geo_foc_n)
);

// WHICH MEMORY AN OBJECT LIVES IN, decoded exactly as geo_object_data decodes
// it: 0x01000000 selects fast polygon RAM, else 0x00800000 selects the polygon
// ROM, else slow polygon RAM. The base is latched with the object because the
// engine's pointer increments and must not re-decode a moving address.
//
// The masks differ per memory and that is the reference's doing too: polygon
// RAM is indexed `oba & 0x7fff` -- 15 bits, one 32K-dword window -- while the
// ROM is masked to its own size. Ours is 12 MB, 3M dwords, so 22 bits covers it
// and addresses past the end read whatever is there rather than wrapping into
// something meaningful. MAME's polygon_rom_mask is not a power of two either.
// R222: THE ENGINE READS FOUR MEMORIES, and says which with mem_space: 1 is
// the texture header, in texture RAM (addr[23]) or the texture ROM, 16-bit
// words read as dword pairs; 2 the palette mirror; 3 the translation mirror.
wire [SDR_AW:1] eng_base = (eng_mem_space == 2'd1) ? (eng_mem_addr[23] ? GAME_TEXRAM : GAME_TEX)
                         : (eng_mem_space == 2'd2) ? GAME_PAL3D
                         : (eng_mem_space == 2'd3) ? GAME_XLAT3D
                         : geo_obj_oba_r[24] ? GAME_PRAM1
                         : geo_obj_oba_r[23] ? GAME_POLY
                                             : GAME_PRAM0;
wire [23:0] eng_mem_idx  = (eng_mem_space == 2'd1) ? (eng_mem_addr[23] ? {9'd0, eng_mem_addr[14:0]}   // 64 K words
                                                                       : {3'd0, eng_mem_addr[20:0]})  // 4 M words
                         : (eng_mem_space == 2'd2) ? {15'd0, eng_mem_addr[8:0]}
                         : (eng_mem_space == 2'd3) ? {10'd0, eng_mem_addr[13:0]}
                         : (geo_obj_oba_r[24] || !geo_obj_oba_r[23])
                         ? {9'd0, eng_mem_addr[14:0]}      // 32K-dword window
                         : {2'd0, eng_mem_addr[21:0]};

// R214: one pair cache per port-4 reader. Indexed by the dword address so a
// new object's stream that happens to begin one past the last cannot hit a
// stale copy. The port side is the registered glue exactly as before.
wire [SDR_AW:1] geo_wa = GAME_BUFFER + SDR_AW'({geo_rd_addr, 1'b0});
wire [SDR_AW:1] eng_wa = eng_base + SDR_AW'({eng_mem_idx, 1'b0});
m2_pair_cache #(.AW(SDR_AW-1)) u_geo_pc (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.req(geo_rd_req), .idx(geo_wa[SDR_AW:2]), .ack(geo_rd_ack_c), .data(geo_rd_data_c),
	.p_req(gc_req), .p_idx(gc_idx), .p_ack(geo_rd_ack_r), .p_dout(p4_dout_r)
);
m2_pair_cache #(.AW(SDR_AW-1)) u_eng_pc (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.req(eng_mem_req), .idx(eng_wa[SDR_AW:2]), .ack(eng_mem_ack_c), .data(eng_mem_data_c),
	.p_req(ec_req), .p_idx(ec_idx), .p_ack(eng_mem_ack_r), .p_dout(p4_dout_r)
);     // 4M-dword ROM window
logic [31:0] geo_obj_oba_r;
always_ff @(posedge clk_sys) if (geo_obj_valid) geo_obj_oba_r <= geo_obj_oba;

wire        geo_mat_we;
wire [3:0]  geo_mat_idx;
wire [31:0] geo_mat_data, geo_foc_x, geo_foc_y, geo_obj_oba, geo_obj_obc;
wire [31:0] geo_obj_tha;          // R222
wire        cpu_col_inval;
wire  [1:0] eng_mem_space;
wire        geo_obj_valid, eng_busy;
wire [15:0] geo_mtx_n, geo_foc_n, geo_pd_words, geo_pd_cmds, geo_lit_n;
wire [31:0] geo_lit_x, geo_lit_y, geo_lit_z;
wire        geo_tp_we;
wire  [4:0] geo_tp_idx;
wire  [7:0] geo_tp_diffuse, geo_tp_ambient;
wire [15:0] geo_tp_n;

// THE GEOMETRY PIPELINE. object_data in, screen quads out; see m2_geometry.sv.
//
// THE CLIP WINDOW IS THE SCREEN, for now. Model 2 sets it per-object with
// opcode 0x03 geo_window_data, which the walk currently steps over rather than
// captures -- so every polygon is clipped to 496x384 and a game that relies on
// a smaller viewport draws outside it. That is visible and wrong rather than
// silent and wrong, which is the right way round while the pipeline is new.
//
// THE COLOUR IS FLAT AND CONSTANT. Lighting needs the normal transformed and
// two dot products; texture needs the texture ROM and its own cache. Neither
// changes the dataflow here, and the rasterizer takes a single 24-bit colour
// with no texture input at all, so shape comes first and shading second.
wire        q3d_valid, q3d_ready;
wire signed [15:0] q3d_x0, q3d_y0, q3d_x1, q3d_y1, q3d_x2, q3d_y2, q3d_x3, q3d_y3;
wire [23:0] q3d_col;
wire [31:0] q3d_z;
wire [15:0] geo_polys, geo_objs_done, geo_capped, geo_culled;
wire [15:0] geo_clip_in, geo_clip_out, geo_clip_drop, geo_nonfinite;
wire  [3:0] geo_eng_state, geo_clip_state;
wire [15:0] geo_pj_lost;
wire  [1:0] geo_qst;

// WHICH MEMORY THE OBJECTS ACTUALLY POINT AT, counted per class.
//
// Without this a black screen says nothing: "the geometry does not work" and
// "every object this game draws lives in polygon RAM, which nothing fills yet"
// look identical on the display and lead to completely different work. Opcode
// 0x05 geo_polygon_data is not implemented, so a PRAM object reads unwritten
// SDRAM -- 0xFFFF..., whose low two bits are 3 and never terminate. The
// engine's MAX_POLYS ceiling stops that becoming a 2.5-second freeze, and
// geo_capped counts it.
logic [15:0] geo_obj_rom, geo_obj_pram0, geo_obj_pram1;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		geo_obj_rom <= 16'd0; geo_obj_pram0 <= 16'd0; geo_obj_pram1 <= 16'd0;
	end else if (geo_obj_valid) begin
		if      (geo_obj_oba[24]) geo_obj_pram1 <= geo_obj_pram1 + 16'd1;
		else if (geo_obj_oba[23]) geo_obj_rom   <= geo_obj_rom   + 16'd1;
		else                      geo_obj_pram0 <= geo_obj_pram0 + 16'd1;
	end
end

m2_geometry u_geometry (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.start(geo_obj_valid), .oba(geo_obj_oba), .obc(geo_obj_obc), .busy(eng_busy),
	.mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
	.foc_x(geo_foc_x), .foc_y(geo_foc_y),
	.mem_req(eng_mem_req), .mem_addr(eng_mem_addr),
	.mem_data(eng_mem_data_c), .mem_ack(eng_mem_ack_c),  // R214: through the pair cache
	// THE VIEWPORT, AND THESE ARE NOT PIXELS. a_* are the four frustum planes
	// as SLOPES, tested as p.x < p.z * a_left and so on -- the clip happens in
	// view space, before the divide. MAME builds them from the rasterizer's
	// viewport and centre (model2_v.cpp:882); for a 496x384 screen centred at
	// (248,192) they come out as -248, +248, +192, -192.
	//
	// STILL CONSTANT, AND THAT IS THE REMAINING GAP HERE. Model 2 sets the
	// centre and viewport with rasterizer commands the core does not capture
	// yet, and the CRTC sync registers offset them further. A game that moves
	// its viewport draws to the wrong place -- visibly, rather than silently.
	.xc(32'h43780000), .yc(32'h43400000),               // 248.0, 192.0
	.a_left(32'hC3780000), .a_right(32'h43780000),      // -248.0, +248.0
	.a_bottom(32'h43400000), .a_top(32'hC3400000),      // +192.0, -192.0
	// R222: the light, the texture parameters and the header address from the
	// walker; the colour data through the engine's own port, by space.
	.tha(geo_obj_tha), .lit_x(geo_lit_x), .lit_y(geo_lit_y), .lit_z(geo_lit_z),
	.tp_we(geo_tp_we), .tp_idx(geo_tp_idx), .tp_diffuse(geo_tp_diffuse), .tp_ambient(geo_tp_ambient),
	.col_inval(cpu_col_inval), .tex_lum(tex_lum_s2), .mem_space(eng_mem_space), .dbg_col_miss(),
	.q_valid(q3d_valid), .q_ready(q3d_ready),
	.q_x0(q3d_x0), .q_y0(q3d_y0), .q_x1(q3d_x1), .q_y1(q3d_y1),
	.q_x2(q3d_x2), .q_y2(q3d_y2), .q_x3(q3d_x3), .q_y3(q3d_y3),
	.q_col(q3d_col), .q_z(q3d_z),
	.dbg_polys(geo_polys), .dbg_objects(geo_objs_done), .dbg_capped(geo_capped),
	.dbg_culled(geo_culled),
	.dbg_clip_in(geo_clip_in), .dbg_clip_out(geo_clip_out),
	.dbg_clip_dropped(geo_clip_drop), .dbg_nonfinite(geo_nonfinite),
	.dbg_pj_lost(geo_pj_lost),
	.dbg_eng_state(geo_eng_state), .dbg_qst(geo_qst),
	.dbg_clip_state(geo_clip_state)
);

// THE TEST-QUAD GENERATOR IS GONE (R229). It drew one known-good rectangle a
// frame behind status[21] and it did its job: it proved the store, the sort,
// the band fill and the mixer before the geometry could feed them. What it
// cost, once the geometry was real, was the core clock -- its enable came
// straight off the framework's status word and fanned out through the quad
// source mux into the store's write path, and at 60 MHz that was thirty of
// the thirty worst paths in the design. A test injector that limits the
// product's clock has outlived itself; git holds it.
// THE FRAME ENDS WHEN THE WALK DOES, and the walk's completion counter is the
// only signal that says so. q_end is what releases the rasterizer's producer
// from P_COLLECT into the sort, so without it nothing ever draws no matter how
// many quads arrived.
logic [15:0] walk_frames_d;
logic        q3d_end;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin walk_frames_d <= 16'd0; q3d_end <= 1'b0; end
	else begin
		walk_frames_d <= geo_walk_frames;
		q3d_end       <= (geo_walk_frames != walk_frames_d);
	end
end

wire        copro_ctl_sel  = cpu_io_sel && (cpu_io_addr[23:0]  == 24'h980000);
wire        copro_fctl_sel = cpu_io_sel && (cpu_io_addr[23:0]  == 24'h980004);
wire        copro_sel      = copro_fifo_sel | copro_ctl_sel | copro_fctl_sel;
// The function port is write-only; it never contributes to the read mux.
// Only the coprocessor can hold the bus today; the wire is named for the bus,
// not for the coprocessor, so a second such peripheral ORs into it.
wire        cpu_io_stall   = copro_stall;
wire [31:0] copro_rdata;
wire        copro_stall;
wire [31:0] copro_dbg_ctl;
wire [15:0] copro_prog_words, copro_in_pushed, copro_out_popped;
wire [31:0] copro_fctl_reads;
// THE COPRO'S ACCEPTANCE COUNTERS, ON THE UART. Layer 2's hscr stays zero
// while the TGP returns nothing (R106, R120), and these say which half is at
// fault: in_pushed climbing with out_pushed flat is a TGP that consumes and
// never answers; both flat is an i960 that never issues; drops moving means
// the 128-deep queue is losing commands the game believes it sent.
wire [31:0] copro_out_data, copro_out_pushed, copro_in_dropped, copro_out_dropped;
wire        copro_ram_req;
wire [15:0] tgp_retires, tgp_pc;
// WHY THE TGP STOPPED. It halts at pc 0x0481 after exactly 21,325 retires,
// byte-identical across two builds whose outbound FIFO differed 16x -- so it
// is not a handshake race, it is one instruction failing the same way. op is
// the instruction word; io_rd or io_wr held with no ack is an unanswered IO
// access and io_addr names which one.
wire [31:0] tgp_op, tgp_hold;
wire [15:0] tgp_io_addr;
wire [31:0] tgp_bank;
wire        tgp_io_rd, tgp_io_wr, tgp_io_ack, tgp_fifo_rd, tgp_fifo_wr;
wire        tgp_unimpl;

// A REGISTER STAGE ON THE COPROCESSOR'S SDRAM RETURN, and it is a measured fix
// rather than defensive pipelining.
//
// Wired straight through, EVERY failing setup path in the design ran from
// m2_sdram's p_ack[8]/p_dout[8] to mb86233_core's src_val -- eight of the worst
// eight, at -3.16 ns on a 20 ns clock. The table return fed combinationally
// into the core's source multiplexer, so the SDRAM's output register and the
// TGP's input register were separated by the whole of both.
//
// The cycle it costs is free: the TGP issues one lookup and BLOCKS on the
// acknowledge, so a later ack is a later ack and nothing races it. The boot
// harness already models these windows with six cycles of latency, which is
// why this changes nothing in simulation.
logic        tgp_tbl_ack_r, tgp_dat_ack_r;
logic [31:0] tgp_tbl_rdata_r, tgp_dat_rdata_r;
// AND THE REQUEST SIDE, for the same reason and with the same measurement
// behind it. Unregistered, EVERY failing setup path in the design ran from
// mb86233_agu's address adder into m2_sdram's arbiter mux -- the TGP's AGU
// computing an address that reached the memory controller combinationally,
// at -0.784 ns on a 10 ns clock. The return path was registered first and the
// critical path simply moved to the outbound one.
//
// A cycle each way costs nothing: the TGP issues one lookup and BLOCKS on it.
logic        tgp_tbl_req_r, tgp_dat_req_r;
// THE TWO LOOP COUNTS (R165). The lock is the CPU spinning at 0x1166C -- 99% of
// samples -- while the TGP grinds in the vertex/transform loop and never
// reaches the mailbox clear at 0x4C4. Both loops that could do that are counted
// down out of data RAM:
//
//   $0x4a  the display-list count, read at 0x47C. MAME: 6, 7, 8, 9, 0x14.
//   $0x70  the inner countdown at 0x4F6-0x50C, derived from $0x4b.
//
// A garbage value in either is billions of iterations and looks exactly like a
// hang. Simulation says both are small; this says what the board sees.
wire [16:0] tgp_wr_addr;
wire [31:0] tgp_wr_data;
logic [31:0] dbg_cnt4a, dbg_cnt70;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		dbg_cnt4a <= 32'hEEEEEEEE; dbg_cnt70 <= 32'hEEEEEEEE;
	end else begin
		if (tgp_wr_addr[8:0] == 9'h04A) dbg_cnt4a <= tgp_wr_data;
		if (tgp_wr_addr[8:0] == 9'h070) dbg_cnt70 <= tgp_wr_data;
	end
end
// PORT 9 ON THE WIRE (R160). Counting request RISES against acknowledges is
// what separated "issued and never answered" from "never issued" -- and it is
// how R162's fix is confirmed rather than assumed.
logic [15:0] dbg_p9_req_n, dbg_p9_ack_n;
logic        dbg_p9_req_d, dbg_p9_ack_d;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		dbg_p9_req_n <= 16'd0; dbg_p9_ack_n <= 16'd0;
		dbg_p9_req_d <= 1'b0;  dbg_p9_ack_d <= 1'b0;
	end else begin
		dbg_p9_req_d <= tgp_dat_req_r;
		dbg_p9_ack_d <= tgp_dat_ack_r;
		if (tgp_dat_req_r && !dbg_p9_req_d) dbg_p9_req_n <= dbg_p9_req_n + 16'd1;
		// RISES, not levels: R162 holds the acknowledge while the request
		// stands, so a level count would climb with time rather than with
		// transactions and say nothing.
		if (tgp_dat_ack_r && !dbg_p9_ack_d) dbg_p9_ack_n <= dbg_p9_ack_n + 16'd1;
	end
end
logic [15:0] tgp_tbl_addr_r;
logic [19:0] tgp_dat_addr_r;
logic        tgp_dat_we_r, tgp_dat_is_buf_r, tgp_dat_half_r;
logic [15:0] tgp_dat_wdata_r;
always_ff @(posedge clk_sys) begin
	tgp_tbl_ack_r   <= p_ack[8];
	tgp_tbl_rdata_r <= p_dout[8][31:0];
	// QUALIFIED BY OWNERSHIP (R166), AS THE WALKER'S ALREADY IS.
	//
	// Port 9 has TWO owners -- the coprocessor's data reads and the geometrizer
	// walker -- muxed by `tgp_dat_req_r`. The walker's acknowledge is gated
	// (`& ~tgp_dat_req_r`, below); the coprocessor's was not. So every read the
	// WALKER completed also raised `tgp_dat_ack_r`, and the coprocessor retired
	// its own pending read with the walker's data.
	//
	// That is garbage into $0x69 and $0x4a -- the display-list base and its
	// count -- and a wrong count is billions of loop iterations, which is exactly
	// what the board shows: the TGP grinding the vertex loop at 0x48F while the
	// i960 waits at 0x1166C for a mailbox clear that never comes.
	//
	// It can only bite while BOTH owners are active, which is why it appeared the
	// moment the coprocessor started doing real work and not before.
	//
	// Model 1 gets this right on its equivalent shared port, m1_integrated.sv:
	//     assign t_tbl_ack = t_mem_ack &&  t_tbl_req;
	//     assign t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req;
	// per-owner qualification, plus a dead cycle on owner change. Same family as
	// R144 on the write side.
	tgp_dat_ack_r   <= p_ack[9] & tgp_dat_req_r;
	tgp_dat_rdata_r <= p_dout[9][31:0];
	tgp_tbl_req_r   <= tgp_tbl_req;
	tgp_tbl_addr_r  <= tgp_tbl_addr;
	tgp_dat_req_r   <= tgp_dat_req;
	tgp_dat_addr_r  <= tgp_dat_addr;
	tgp_dat_we_r    <= tgp_dat_we;
	tgp_dat_wdata_r <= tgp_dat_wdata;
	tgp_dat_is_buf_r<= tgp_dat_is_buf;
	tgp_dat_half_r  <= tgp_dat_half;
	geo_rd_req_r    <= gc_req;          // R214: the walker's misses only
	geo_rd_addr_r   <= geo_rd_addr;
	gc_idx_r        <= gc_idx;
	// the walk only sees an acknowledge when the port was serving IT
	// COPRO_BUFW: the coprocessor's writes into SHARED buffer RAM.
	//
	// These have been live since 118cb77 (R133) and looked innocent, because
	// .attract came after it and works. It works because BUFFERRAM was OFF
	// there: the i960 could not SEE what the copro wrote. a9ace86 turned the
	// mapping on and pointed the CPU at a memory the coprocessor is writing
	// into -- and our TGP runs a TRANSCRIBED microcode, so a wrong address or
	// datum lands in the game's own display list.
	//
	// Set COPRO_BUFW=0 to keep BUFFERRAM on and take only these writes away.
	// That is the single variable between "the CPU reads a buffer nothing else
	// touches" and "the CPU reads a buffer the copro shares".
	tgp_bufw_req_r  <= tgp_bufw_req & COPRO_BUFW;
	tgp_bufw_addr_r <= tgp_bufw_addr;
	tgp_bufw_data_r <= tgp_bufw_data;
	tgp_bufw_ack_r  <= wr_ack_tgp;
	// Each reader retires on the acknowledge ONLY when it was the one asking.
	// Qualifying the ack is the fix R166 applied to the coprocessor's port and
	// it is the same shape of bug: an unqualified p_ack retires a request that
	// was never issued.
	// THE HANDOVER HAZARD (R206), the R167 shape one level down. The
	// controller HOLDS each acknowledge (ACK_HOLD), and the engine raises its
	// first request the cycle the walker's last read completes. With the
	// acknowledge unqualified by ownership, the walker's held ack retired the
	// engine's first read with the walker's display-list word as the object's
	// attribute word; low bits clear is "object done", so every object on the
	// board finished with zero polygons while the bench, serving the engine
	// from C++, drew the scene. Measured on build/tgp s11: objects dispatched
	// == finished, polys 0, quads 0. Two rules now: an owner's request is not
	// presented while an acknowledge is still up, and an acknowledge counts
	// only on its rising edge, for the request that is up.
	// R206 WITHDRAWN 02:30: with the gating below (edge-qualified acks and
	// "no request while an ack is up") the board's engine never completed a
	// single read -- build/eo s11: first-read data 0, index 0, reads per
	// object 0, busy never toggling, in every sample -- where without it the
	// engine finishes 264 objects a frame. The hazard argument was on paper;
	// the board says the gating deadlocks the handover. Back to the R173 form,
	// with the probe left in to see what the engine's first read returns.
	// R208: the fault R206 chased lives in the REQUESTERS. m2_sdram_x2 holds
	// its acknowledge for as long as the request stands (R162), and both
	// m2_geo and m2_geo_engine held their request as a level across
	// consecutive words while stepping their index on every acknowledge
	// cycle -- so they took one held acknowledge many times with stale data,
	// the port never issued the next read, and the stream arrived a word
	// ahead (R207). They now take the acknowledge on its rising edge and drop
	// the request for a cycle after each word; this glue stays as R173 left
	// it. Reproduced and cured in the boot bench under M2_GEO_LAT.
	p4_ack_d        <= p_ack[4];
	geo_rd_ack_r    <= p_ack[4] & geo_rd_req_r & ~eng_mem_req_r;
	geo_rd_data_r   <= p_dout[4][31:0];
	p4_dout_r       <= p_dout[4];
	eng_mem_req_r   <= ec_req;          // R214: the engine's misses only
	ec_idx_r        <= ec_idx;
	eng_mem_idx_r   <= eng_mem_idx;
	eng_base_r      <= eng_base;
	eng_mem_ack_r   <= p_ack[4] & eng_mem_req_r;
	eng_mem_data_r  <= p_dout[4][31:0];
	// Per object: arm on the engine going busy, latch the first ack's data and
	// index, count acks, publish the count when the object finishes.
	eo_busy_d <= eng_busy;
	if (eng_busy && !eo_busy_d) begin eo_armed <= 1'b1; eo_cnt <= 8'd0; end
	if (eng_mem_ack_r) begin
		if (eo_armed) begin eo_first_data <= eng_mem_data_r; eo_first_idx <= eng_mem_idx_r; eo_armed <= 1'b0; end
		if (!(&eo_cnt)) eo_cnt <= eo_cnt + 8'd1;
	end
	if (!eng_busy && eo_busy_d) eo_reads <= eo_cnt;
	if (geo_rd_req_r & eng_mem_req_r) dbg_p4_clash <= dbg_p4_clash + 16'd1;
end

// CLOCKED ON clk_sys, DELIBERATELY, and speed is a separate question.
//
// It shares a clock with m2_cpu_bridge's io side and with the SDRAM ports it
// reads through, so there is no crossing anywhere in this path. R104 measures
// the TGP at 44% of the throughput a real 50 MHz part delivers and says
// clocking alone cannot close that -- but a coprocessor that is slow is a
// coprocessor that can be measured, and one behind an unsynchronised crossing
// is neither.
m2_copro u_copro (
	.clk(clk_sys), .rst_n(cpu_rst_n),
	.sel_ctl(copro_ctl_sel), .sel_fifo(copro_fifo_sel),
	.sel_fifoctl(copro_fctl_sel),
	.sel_fn(copro_fn_sel), .fn_code(cpu_io_addr[11:4]),
	.we(cpu_io_we), .wdata(cpu_io_wdata), .rdata(copro_rdata),
	.stall(copro_stall),
	// THE LOW TWO WORDS OF A FOUR-WORD BURST. The TGP's word is 32 bits and
	// the memory's is 16, so one lookup needs a pair; the port bursts four
	// because every port must burst the same length (see blen() in
	// m2_sdram.sv -- a mixed length corrupts other ports), and the upper two
	// words are discarded. Low half first, which is the order the MRA's
	// interleave puts them in: opr-14742a supplies bits 15:0 and opr-14743a
	// bits 31:16, verified against MAME's own copro_tgp_tables region.
	//
	// The pair never straddles a row. tbl_addr and dat_addr are shifted left
	// by one so the address is always EVEN, and a burst wraps inside the open
	// row -- the last column of a row is an odd index, so an even address is
	// never the last column and word 1 is always in the same row as word 0.
	.tbl_req(tgp_tbl_req), .tbl_addr(tgp_tbl_addr),
	.tbl_rdata(tgp_tbl_rdata_r), .tbl_ack(tgp_tbl_ack_r),
	.dat_req(tgp_dat_req), .dat_addr(tgp_dat_addr),
	.dat_we(tgp_dat_we), .dat_wdata(tgp_dat_wdata), .dat_is_buf(tgp_dat_is_buf),
	.dat_half(tgp_dat_half),
	.bufw_req(tgp_bufw_req), .bufw_addr(tgp_bufw_addr), .bufw_data(tgp_bufw_data),
	.bufw_ack(tgp_bufw_ack_r),
	.dat_rdata(tgp_dat_rdata_r), .dat_ack(tgp_dat_ack_r),
	.dbg_ctl(copro_dbg_ctl), .dbg_prog_words(copro_prog_words),
	.dbg_in_pushed(copro_in_pushed), .dbg_out_popped(copro_out_popped),
	.dbg_fctl_reads(copro_fctl_reads),
	.dbg_in_popped(), .dbg_pop_data(), .dbg_push_data(),
	.dbg_out_data(copro_out_data), .dbg_out_pushed(copro_out_pushed),
	.dbg_in_dropped(copro_in_dropped), .dbg_out_dropped(copro_out_dropped),
	.dbg_ram_req(copro_ram_req),
	.dbg_tgp_retires(tgp_retires), .dbg_tgp_pc(tgp_pc),
	.dbg_tgp_wr_n(), .dbg_tgp_wr_addr(tgp_wr_addr), .dbg_tgp_wr_data(tgp_wr_data), .dbg_tgp_st(), .dbg_tgp_a(), .dbg_tgp_b(), .dbg_tgp_d(),
	.dbg_tgp_op(tgp_op), .dbg_tgp_hold(tgp_hold),
	.dbg_tgp_io_addr(tgp_io_addr), .dbg_tgp_io_rd(tgp_io_rd),
	.dbg_tgp_io_wr(tgp_io_wr), .dbg_tgp_io_ack(tgp_io_ack), .dbg_ff_math(tgp_ff_math), .dbg_ff_rom(tgp_ff_rom), .dbg_ff_buf(tgp_ff_buf), .dbg_rd_total(tgp_rd_total),
	.dbg_tgp_fifo_rd(tgp_fifo_rd), .dbg_tgp_fifo_wr(tgp_fifo_wr), .dbg_tgp_bank(tgp_bank),
	.dbg_tgp_unimpl(tgp_unimpl)
);

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

// NVRAM (MRA <nvram index="2">): load fills backup SRAM before the CPU is
// released; save reads it back. 16-bit ioctl: word = addr[13:2], half = addr[1].
// I/O FIRMWARE (MRA <rom index="1">, EPR-14869C): 16-bit ioctl stream split
// into bytes for the Z80 board's ROM. fw_ready latches when the download ends
// so the Z80 leaves reset only with a program in front of it; without the
// firmware the board stays silent and the game waits at its first poll --
// loud, not subtle, exactly as a real cabinet with the ROM pulled would.
wire fw_dl = ioctl_download && (ioctl_index[5:0] == 6'd3);   // 0=ROM 1=TGP 2=NVRAM
logic fw_ready;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) fw_ready <= 1'b0;
	else if (fw_ready_set) fw_ready <= 1'b1;
end
logic fw_dl_d;
always_ff @(posedge clk_sys) fw_dl_d <= fw_dl;
wire fw_ready_set = fw_dl_d && !fw_dl;   // download ended
logic fw_seen;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) fw_seen <= 1'b0;
	else if (fw_dl && ioctl_wr) fw_seen <= 1'b1;
end

wire nv_sel = (ioctl_index[5:0] == 6'd2);
logic [2:0] nv_save_sync;
always_ff @(posedge clk_sys) nv_save_sync <= {nv_save_sync[1:0], status[17]};
wire nv_save_req = nv_save_sync[1] & ~nv_save_sync[2];
wire nv_we  = ioctl_download && nv_sel && ioctl_wr;
// REGISTERED BOTH WAYS. Driven combinationally, hps_io's ioctl_upload fed
// the debug-port address mux whose data fed ioctl_din straight back into
// hps_io, and Quartus 17.0's fitter timing engine CRASHED on the apparent
// cycle -- Internal Error, sta_scc.cpp:1041, reproduced on a clean db. The
// HPS polls over SPI, so a cycle of latency on each side is free.
logic [15:0] nv_din_r;
logic [11:0] nv_word_r;
always_ff @(posedge clk_sys) begin
	// Upload owns the port; otherwise page 1 / Probe 6 selects word 4
	// (the coin-mode dword) and everything else watches word 5.
	nv_word_r <= (ioctl_upload && nv_sel)          ? ioctl_addr[13:2] :
	             (status[18] && status[16:14] == 3'd6) ? 12'd4 : 12'd5;
	nv_din_r  <= ioctl_addr[1] ? bak_dbg_q[31:16] : bak_dbg_q[15:0];
end
assign ioctl_din = nv_din_r;

m2_backup u_backup (
	.clk(clk_sys), .rst_n(cpu_rst_n),
	.hps_we(nv_we),
	.hps_word(ioctl_addr[13:2]),
	.hps_be(ioctl_addr[1] ? 4'b1100 : 4'b0011),
	.hps_wdata({ioctl_dout, ioctl_dout}),
	.sel(bak_sel),
	.we(cpu_io_we),
	.word(cpu_io_addr[13:2]),
	.be(cpu_io_be),
	.wdata(cpu_io_wdata),
	.rdata(bak_rdata),
	.dbg_word(nv_word_r),
	.dbg_rd_sel({status[18], status[16:14]}),
	.dbg_q(bak_dbg_q), .dbg_first(bak_first),
	.dbg_w0(bak_w0), .dbg_writes(bak_writes)
);
wire [31:0] bak_dbg_q;
wire [23:0] iob_word4;
wire [31:0] bak_first;


// THE REAL I/O BOARD (study R61). EPR-14869C on tv80, talking to the same
// DPRAM store through the 315-5338A command window. The behavioural exchange
// stays compiled in as USE_Z80=0 fallback one parameter away, but the shipped
// configuration is the real computer: it is what draws the credit digits.
wire        dp_busy;    // MB8421 arbitration, m2_ioboard -> m2_ioz80

// DO THE TWO SIDES ACTUALLY COLLIDE, ON THE BOARD? Simulation renders
// correctly every time, so it cannot answer this -- only the hardware can.
// Count game-side window accesses, Z80 window writes, and the cycles where
// both happen at once. Zero collisions would mean the BUSY fix addresses
// nothing and the contamination comes from somewhere else entirely.
logic [15:0] col_cnt, wing_cnt, winz_cnt;
wire game_in_win = cpu_io_sel && (cpu_io_addr[23:12] == 12'hc00)
                   && (cpu_io_addr[11:2] >= 10'h080)
                   && (cpu_io_addr[11:2] <= 10'h0bf);
wire z80_in_win  = zio_we && (zio_addr >= 11'h100) && (zio_addr < 11'h180);
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin col_cnt <= '0; wing_cnt <= '0; winz_cnt <= '0; end
	else begin
		if (game_in_win && !(&wing_cnt))              wing_cnt <= wing_cnt + 1;
		if (z80_in_win  && !(&winz_cnt))              winz_cnt <= winz_cnt + 1;
		if (game_in_win && z80_in_win && !(&col_cnt)) col_cnt  <= col_cnt  + 1;
	end
end
wire        zio_we;
wire [10:0] zio_addr;
wire  [7:0] zio_wdata, zio_rdata;

wire [31:0] dc_hits, dc_miss;
wire  [7:0] iob_pa;       // PA latch; bit 0 selects the DIP banks
wire [15:0] iob_seccnt;   // times the firmware has selected them
m2_ioz80 #(.TICK_NUM(4), .TICK_DEN(50)) u_ioz80 (   // 4 MHz exactly, on 50 MHz clk_sys
	.clk(clk_sys), .rst_n(cpu_rst_n & fw_ready),
	// First 16 KB only: the EPROM is 64 KB, the Z80 maps 0x0000-0x3fff, and a
	// wrapping fw_addr[13:0] would leave the LAST quarter in the ROM.
	.fw_we(fw_dl && ioctl_wr && (ioctl_addr < 27'd16384)),
	.fw_addr(ioctl_addr[13:1]),
	.fw_data(ioctl_dout),
	.in0(iob_in0), .in1(iob_in1), .in2(8'hFF), .dp_busy(dp_busy),
	// The I/O BOARD's three DIP banks, not the game's. Daytona defines all 24
	// bits PORT_DIPUNUSED_DIPLOC with the default equal to the mask, so every
	// bank reads 0xFF -- and 0xFF is what the firmware must see when it selects
	// secondary controls. Constants rather than OSD switches on purpose: every
	// bit is unused for this game, so a switch would only offer a way to be
	// wrong. They are ports so a game that does use them can drive them.
	.dsw1(8'hFF), .dsw2(8'hFF), .dsw3(8'hFF),
	// an_callback<0..2> are STEER/ACCEL/BRAKE; <3> is never bound for this
	// game and an unbound devcb_read8 reads 0xFF, which is what MAME's
	// firmware deposits at DPRAM 0x03.
	.adc0(steer), .adc1(accel), .adc2(brake), .adc3(8'hFF),
	.z_we(zio_we), .z_addr(zio_addr), .z_wdata(zio_wdata), .z_rdata(zio_rdata),
	.dbg_ee(), .dbg_wrcnt(), .dbg_wr_stb(), .dbg_dout(), .dbg_di(),
	.dbg_rd_end(), .dbg_ra(), .dbg_rdat(),
	.dbg_m1_n(), .dbg_a(), .dbg_last_wr(), .dbg_pf(),
	.dbg_pa(iob_pa), .dbg_seccnt(iob_seccnt)
);

// WHERE DOES THE TEST SWITCH STOP? The buttons are mapped, the firmware path
// is proven in simulation (R65: in0=FB puts FB in DPRAM byte 0x08, byte for
// byte what MAME's machine does), and the board still does nothing. Three
// places it can die, and this row separates them without another guess:
//
//   in0 stays FF while the button is held -> the press never reaches the core
//   in0 goes FB but dp08 stays FF         -> the firmware is not scanning
//   both go FB                            -> the game is ignoring the switch
//
// dp08 is latched off the Z80's own DPRAM write port, so it is what the
// firmware actually deposited, not what we hope it deposited. The counter
// proves the scan is running at all: frozen means no input scan, climbing
// means the firmware is sweeping the ports as it should.
logic [7:0]  dp08_latch;
logic [15:0] dp08_wr_cnt;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		dp08_latch <= 8'hFF; dp08_wr_cnt <= 16'd0;
	end else if (zio_we && zio_addr == 11'h008) begin
		dp08_latch  <= zio_wdata;
		if (!(&dp08_wr_cnt)) dp08_wr_cnt <= dp08_wr_cnt + 16'd1;
	end
end

// DOES THE CPU EVER WRITE THE CHARACTERS, AND WHERE DOES THE RENDERER LOOK?
//
// Row 22 reads mostly ZEROS on the board -- not FFFFFFFF -- and zero glyph data
// paints one flat colour per tile, which is the blue sky and green ground the
// board shows. GAME_CHAR is CPU-written scratch, not ROM, so zeros mean either
// the CPU never wrote the characters or the renderer is reading somewhere the
// writes did not land. These two counters separate those:
//
//   cw_cnt frozen at 0  -> the CPU never wrote the char region at all
//   cw_cnt climbing     -> it did, so the write and the read disagree, and
//                          cf_addr says where the renderer is actually looking
//
// cf_addr is the FULL SDRAM word address the fetch port presents, so it can be
// compared directly against GAME_CHAR = 0x1690000 and against cw_last.
logic [15:0] cw_cnt;
logic [24:0] cw_last;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin cw_cnt <= 16'd0; cw_last <= 25'd0; end
	else if (cpu_sd_req && cpu_sd_we
	         && cpu_sd_addr >= GAME_CHAR
	         && cpu_sd_addr <  GAME_CHAR + SDR_AW'(25'h80000)) begin
		if (!(&cw_cnt)) cw_cnt <= cw_cnt + 16'd1;
		cw_last <= 25'(cpu_sd_addr);
	end
end
logic [24:0] cf_addr;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n)   cf_addr <= 25'd0;
	else if (cache_m_req) cf_addr <= 25'(char_base + SDR_AW'(cache_m_addr));
end

// THE SERIAL CHANNEL. docs/mister-integration.md said this was available and
// was not acted on; the project rules' summary flattened it to "No serial", and that
// is what actually governed. The cost was a session spent reading eight hex
// digits at a time off a photograph, in which two values were attributed to
// the wrong probe and two more were read at a moment when the value was
// legitimately something else.
//
// Two channels, chosen to answer the question actually open: what the CPU
// WRITES into the character region against what the renderer READS out of it,
// interleaved on one wire so they are timestamped against each other.
//
//   W <addr> <data>   a CPU write landing inside GAME_CHAR
//   R <addr> <data>   a character fetch, address and the word it returned
//
// Read it with `debug=1` in mister.ini and a terminal on the DE10-Nano's UART
// at 115200 8N1.
// CHANNEL A REPOINTED AT THE TILEMAP. The character channel did its job in one
// capture: the CPU DOES write glyph data (82 W lines through a boot, non-zero),
// and the renderer only ever asks for TWELVE addresses -- offsets 0x0-0xE and
// 0x30000-0x3000E -- against 7,883 in simulation. It is drawing tile 0 and one
// other, everywhere, and tile 0's glyph is legitimately blank. The glyph path
// was never the fault; the TILEMAP is. So watch what goes into it.
// REGISTERED, NOT TAPPED. Wiring the streamer straight onto ocb_tram_we /
// ocb_addr / ocb_din put a combinational load on the tilemap WRITE path -- the
// one feeding the M10K -- and the board went from two flat colours to a fully
// black screen, intermittently: the first boot after that build rendered, later
// ones did not, which is how a marginal path presents. Restoring the previous
// core brought the picture back, which is what identified it.
//
// The instrument must not disturb its subject. Flopping the tap first means the
// streamer loads a register output instead of the write bus, and the write path
// sees exactly what it saw before this file grew a debug channel.
logic        tw_v;
logic [14:0] tw_a;
logic [15:0] tw_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin tw_v <= 1'b0; tw_a <= '0; tw_d <= '0; end
	else begin tw_v <= ocb_tram_we; tw_a <= ocb_addr; tw_d <= ocb_din; end
end

// WHAT DID THE CPU READ, JUST BEFORE IT WROTE A BLANK TILE?
//
// The board writes 00000000 into the tilemap 4,175 times out of 4,185 sampled,
// and writes the CORRECT values (0x3000, 0x0020, 0x3D8D -- simulation's three
// most common indices) the other ten times. The renderer, the fetch, the caches
// and the memory are all doing their jobs: the CPU is faithfully storing zeros
// because what it reads is zero. So stop watching the write and watch its
// SOURCE.
//
// Every CPU read is latched; a tilemap write of zero then emits the address and
// data of the read that preceded it. That turns "the map is blank" into "the
// CPU read <this address> and got <this>", which names the region at fault
// instead of the symptom.
logic [24:0] rd_a;
logic [31:0] rd_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin rd_a <= '0; rd_d <= '0; end
	else if (cpu_sd_req && !cpu_sd_we && p_ack[1]) begin
		rd_a <= 25'(cpu_sd_addr);
		rd_d <= p_dout[1][31:0];
	end
end
// WHICH CODE WRITES WHAT. The "last read" latch caught instruction fetches --
// 0x5000 returning 8A283000, three thousand times -- because fetches share the
// port. It did establish something real though: the game runs a CLEAR loop,
// writing zeros on purpose, which is what you do before filling a tilemap.
//
// So the question is not "why zeros" but "does the FILL ever run". Emitting the
// instruction pointer beside the data separates the two loops: the clear will
// have one IP and write 0000, the fill another and write real indices. If only
// one IP ever appears, the fill never runs at all.
logic [31:0] tw_ip;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) tw_ip <= '0;
	else            tw_ip <= cpu_dbg_ip;
end
// TRAPS GET THE PRIORITY CHANNEL.
//
// The i960 core implements exactly the opcode set the REFERENCE implements;
// anything MAME reaches fatalerror on is trapped LOUDLY rather than
// implemented blind, so "a game that needs more announces itself instead of
// drifting" (docs/p1-i960-spike.md S1). A trap would explain the board
// precisely: the clear loop runs, one fill runs, and the remaining drawing
// routines never happen.
//
// So watch for it. A trap emits the IP it happened at and the opcode that
// caused it -- which either names an instruction to implement, or rules the
// whole question out. Rising edge only: a held trap must not flood the wire.
logic trap_d;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) trap_d <= 1'b0;
	else            trap_d <= cpu_trap;
end
wire trap_edge = cpu_trap && !trap_d;

// A RING OF CONSECUTIVE INSTRUCTION POINTERS.
//
// Sampling every 1.4 ms cannot show a branch, and a branch is what has to be
// found: the board runs this loop where simulation leaves it after 39
// iterations. So record 512 CONSECUTIVE retired IPs into a block RAM at full
// speed, then read them out slowly over the wire. One buffer-full is a real
// instruction trace from hardware, which no amount of sampling can substitute
// for.
//
// Free-running: it always holds the most recent 512 instructions. The dump
// walks the buffer once per pass and repeats, so consecutive passes show
// whether the machine is in a repeating cycle and exactly how long that cycle
// is.
(* ramstyle = "M10K" *) logic [31:0] ipring [512];
logic [8:0]  ip_wr;
logic [31:0] acc_d;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin ip_wr <= '0; acc_d <= '0; end
	else begin
		acc_d <= cpu_dbg_acc;
		if (cpu_dbg_acc != acc_d) begin      // one entry per retired instruction
			ipring[ip_wr] <= cpu_dbg_ip;
			ip_wr <= ip_wr + 9'd1;
		end
	end
end

// HOW FAR THE CPU HAS ADDRESSED. One comparator: a runaway clear climbs
// forever, a bounded one stops. Cleared with the CPU so it measures a run.
logic [31:0] laddr_max;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n)                   laddr_max <= 32'd0;
	else if (cpu_dbg_laddr > laddr_max) laddr_max <= cpu_dbg_laddr;
end

// The reader: walks all 512 entries, one per streamer slot, forever.
logic [8:0]  ip_rd;
logic [31:0] ipring_q;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) ip_rd <= '0;
	else begin
		ipring_q <= ipring[ip_rd];
		if (prof_tick) ip_rd <= ip_rd + 9'd1;
	end
end

// A PROFILER, WHICH IS WHAT THIS SHOULD HAVE HAD FROM THE START.
//
// The board reaches 0x5368-0x53E0, runs 0x1CE38 four times where simulation
// runs it 18,816, and never reaches the background drawer at all. That is not
// "blocked at a point" -- it is doing far less work everywhere, and the way to
// see that is to sample WHERE THE CPU IS rather than guess from what it writes.
//
// Free-running sample of the instruction pointer, one every ~1 ms. Against the
// same histogram from simulation it shows directly which loop the board sits
// in and simulation does not.
logic [15:0] prof_div;
logic        prof_tick;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin prof_div <= '0; prof_tick <= 1'b0; end
	else begin
		prof_div  <= prof_div + 16'd1;
		prof_tick <= (prof_div == 16'd0);
	end
end
// PROFILER OFF, DESCRIPTOR READS ON THE PRIORITY CHANNEL.
//
// The last capture returned ZERO descriptor reads, which is ambiguous: either
// the board never reads that region, or the profiler starved the channel that
// would have said so. That starvation has now cost two captures, so remove the
// competition entirely rather than reason about budgets again. Channel A is the
// question; nothing else shares the wire.
// REGISTERED BEFORE COMPARED, per the standing rule -- two black screens came
// from hanging comparators on live buses.
logic        zio_we_d;
logic [10:0] zio_addr_d;
logic  [7:0] zio_wdata_d;
logic        zw_v;
logic [31:0] zw_ad, zw_dt;
logic [15:0] zw_cnt;                 // block-window writes, cumulative
// THE SCAN AREA, NOT THE BLOCK. The block capture did its job: the firmware
// sweeps 0x100-0x17f with 7F/FF, 384 times a minute, where MAME's firmware
// writes it ONCE (frame 10, "SEGA...") and never touches it again. So the
// question moves upstream -- is the firmware's own input scan right? MAME puts
// it at DPRAM 0x00-0x0d and the bytes are known exactly:
//
//     80 20 20 ff ff ff ff ff ff 8f ff ff ff ff
//      ^steer  ^brake            ^in1/gearbox
//
// Same firmware, same nominal inputs. Any byte that differs is the fault, and
// it names itself. 0x00-0x2f also catches the flag/status pair at 0x20-0x21 and
// the "SEGA" wake-up bytes at 0x1a-0x1d.
wire         zw_blk = zio_we_d && (zio_addr_d >= 11'h100) && (zio_addr_d <= 11'h17f);
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		zio_we_d <= 1'b0; zio_addr_d <= 11'd0; zio_wdata_d <= 8'd0;
		zw_v <= 1'b0; zw_ad <= 32'd0; zw_dt <= 32'd0; zw_cnt <= 16'd0;
	end else begin
		zio_we_d    <= zio_we && fw_ready;
		zio_addr_d  <= zio_addr;
		zio_wdata_d <= zio_wdata;
		zw_v <= zw_blk;
		if (zw_blk) begin
			zw_ad <= {21'd0, zio_addr_d};
			zw_dt <= {24'd0, zio_wdata_d};
			if (!(&zw_cnt)) zw_cnt <= zw_cnt + 16'd1;
		end
	end
end
logic [31:0] cr_hi;              // cycles with char_req asserted
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		cf_cnt <= 32'd0; cf_nz <= 32'd0; cr_hi <= 32'd0;
	end else begin
		if (char_req) cr_hi <= cr_hi + 32'd1;
		if (char_ack) begin
			cf_cnt <= cf_cnt + 32'd1;
			if (|char_data) cf_nz <= cf_nz + 32'd1;
		end
	end
end
wire        uart_a_valid = hb_tick;
// WHAT THE STUCK LOOP READS.
//
// The board sits in the counted loop at 0x1BA8-0x1BCC and never appears in the
// 0x1Axx code that simulation enters it from. A counted loop that does not
// terminate has a wrong count, and the count comes from memory -- so capture
// every CPU read the routine makes, with the value it got back. Simulation
// runs this loop 39 times and leaves.
logic            rd_v;
logic [24:0]     rd_ad;
logic [31:0]     rd_dt;
logic            io_sel_d, io_we_d;   // sampled, never tapped live
logic [31:0]     io_addr_d, io_dat_d;
// Combinational off ALREADY-REGISTERED signals, so this is not a live-bus tap.
wire win_rd_ev = io_sel_d && !io_we_d && (io_addr_d[23:12] == 12'hc00)
                 && (io_addr_d[11:2] >= 10'h080) && (io_addr_d[11:2] <= 10'h0bf);
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		rd_v <= 1'b0; rd_ad <= '0; rd_dt <= '0;
		io_sel_d <= 1'b0; io_we_d <= 1'b0; io_addr_d <= '0; io_dat_d <= '0;
	end
	else begin
		// REPOINTED AT THE INTERRUPT PATH. The clk_vid/ce_pix mismatch was a
		// real bug and fixing it changed nothing: the board sits in the same
		// loop, polling work RAM 0x511008 for a flag an interrupt handler
		// should set. So measure the interrupt directly instead of inferring
		// it -- how many V-blank edges the core has seen, whether the game has
		// ENABLED the interrupt (io_intena), and whether any request is
		// pending (io_intreq).
		// THE ALLOCATOR'S READS. Simulation's routine at 0x1718 walks a
		// descriptor table, carves blocks, and advances by the SIZE field it
		// reads at offset 8. Simulation gets 0x300 there; the board's later
		// loop reads ZERO, so the descriptor read is returning nothing.
		//
		// Worth noting what this tests that nothing else has: the ROM checksums
		// were folded by the SWEEP on port 4. The CPU reads on port 1. Those
		// are different paths and only one of them has ever been verified.
		// THE I/O EXCHANGE ITSELF. The board calls the I/O board command routine
		// 3,110 times in 90 seconds; the question is whether it is RETRYING a
		// failed exchange forever. Capture every CPU access to the DPRAM window
		// -- read or write, address and value -- and the retry shows as the same
		// command reissued with the same answer coming back.
		//
		// REGISTERED, per the standing rule. Two black screens today came from
		// hanging comparators on live buses; this samples first and compares a
		// cycle later.
		// FILTER ON THE ADDRESS, NOT THE IP. The IP filter behaved oddly --
		// it captured reads whose addresses belong to a different routine --
		// so gate on the thing being questioned instead. Simulation's allocator
		// reads its descriptor table at i960 0x0022F1F4, which the bridge maps
		// to SDRAM word 0x188FA (base_prog + 0x10000 + addr[16:1]). Capture
		// every CPU read in that neighbourhood, with what came back.
		// REGISTER FIRST, COMPARE SECOND. Hanging the comparator straight off
		// cpu_sd_addr put combinational load on the CPU's live SDRAM address
		// bus and the board went BLACK -- the same failure the tilemap tap
		// caused earlier, and the third time an instrument has broken the thing
		// it was measuring. The bus is sampled into flops here; every
		// comparison happens a cycle later, where nothing depends on it.
		io_sel_d  <= cpu_io_sel;
		io_we_d   <= cpu_io_we;
		io_addr_d <= cpu_io_addr;
		io_dat_d  <= cpu_io_we ? cpu_io_wdata : cpu_io_rdata;
		// The DPRAM window only -- 0x01C00000..0x01C00FFF.
		// BACK ON THE THREAD THE UART FOUND. The board calls the I/O board
		// command routine 0x22F0F0 (from 0x228700) 3,110 times in 90 seconds.
		// That is the game hammering the exchange. Capture the DPRAM traffic
		// itself -- every CPU read and write of the window -- and a retry loop
		// shows as the same command reissued with the same answer returning.
		// The block window only, and reads only -- that is the payload the game
		// judges. Collisions are counted alongside, so one capture answers both.
		rd_v  <= win_rd_ev;
		// Top bit of the address field flags a write, so reads and writes are
		// distinguishable in one stream.
		// WHAT THE GAME ACTUALLY READS OUT OF THE BLOCK WINDOW.
		//
		// It completes the handshake, reads the result, rejects it, reissues --
		// thousands of times. So capture the RESULT: every game-side read of
		// DPRAM 0x100-0x17f with the value returned. MAME's game reads real
		// settings there; if the board reads something else, that difference is
		// the thing being rejected, and it names itself.
		if (win_rd_ev) begin
			rd_ad <= {13'd0, io_addr_d[11:0]};    // which window byte
			rd_dt <= io_dat_d;                    // and what came back
		end
	end
end
// A HEARTBEAT, NOT AN EVENT, AND THE REASON IS A MEASUREMENT.
//
// This channel first fired on every change of the selection count, which
// answered its question emphatically -- the firmware selects the DIP banks
// 24,948 times in 60 seconds -- and in doing so SATURATED THE WIRE and starved
// channel A to nothing. Zero window reads were captured, which would read as
// "the game never touches the window" and is in fact "the instrument never got
// to say so". That is the same failure as the shared-budget starvation, in a
// new costume: channel A's priority only applies when the UART is IDLE, and a
// channel firing thousands of times a second means it never is.
//
// So this is now a ~100 ms tick carrying the running totals. The counts are
// cumulative, so sampling them cannot lose an event, and the wire is left for
// the payload that actually needs every line.
localparam int unsigned HB_CYC = 4_800_000;    // 100 ms at 48 MHz
logic [22:0] hb_ctr;
logic        hb_tick, hb_tick_b;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		hb_ctr <= 23'd0; hb_tick <= 1'b0; hb_tick_b <= 1'b0;
	end else begin
		hb_tick   <= (hb_ctr == 23'd0);
		hb_tick_b <= (hb_ctr == 23'(HB_CYC / 2));   // 50 ms later, so they
		                                            // cannot shadow each other
		hb_ctr <= (hb_ctr == 23'(HB_CYC - 1)) ? 23'd0 : hb_ctr + 23'd1;
	end
end

// IS IT DRAWING, AND HOW FAST IS IT THINKING?
//
// The attract screen renders, so the question is no longer whether the game
// works but whether it is simply too slow -- R55 put the board at CPI 3.95
// against a real i960's ~1. Two counters sampled on a known tick answer that
// without any inference: consecutive samples of the retired-instruction count
// give instructions per second directly, and the frame number beside it gives
// the frame rate, so the instruction BUDGET PER FRAME falls out of the pair.
// That budget is the thing animation is spent from.
// COUNT, DO NOT SAMPLE.
//
// The per-write census was biased and said so only after the fact: the eight
// stores of a burst execute inside ~50 cycles while the streamer stays busy
// 1.74 ms after each line, so it caught exactly ONE write per burst -- always
// the first -- and one instruction appeared to be 5,167 of 5,245 writes. That
// is the instrument, not the game.
//
// A counter cannot be biased. The question that matters is unbiased and small:
// of everything the game writes into the tilemap, HOW MUCH IS A REAL TILE
// INDEX? Simulation draws the attract screen with 12,289 non-zero cells, so if
// this core is drawing, the non-zero count climbs to that order and stops. If
// it stays near nothing, the screen was never drawn regardless of how busy the
// write bus looks.
logic [31:0] tram_cnt, tram_nz;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		tram_cnt <= 32'd0; tram_nz <= 32'd0;
	end else if (cpu_tram_we) begin
		tram_cnt <= tram_cnt + 32'd1;
		if (|cpu_oc_din) tram_nz <= tram_nz + 32'd1;
	end
end
wire        uart_b2_valid = hb_tick_b || trap_edge;
wire        uart_b_valid = char_ack;
wire [31:0] uart_dropped;

generate if (DEBUG) begin : g_dbg
// A WEDGE CATCHER ON THE BOARD (R235). The board draws a few wedges off the
// cars that no bench configuration reproduces -- 32,000 clipped quads at the
// desk, with and without the board's port timing modelled, carry none. So the
// board catches its own: a quad leaving the clipper with three vertices within
// 8 px of each other and the fourth more than 60 px away, all four strictly
// inside the screen (a sliver on the edge is the clip's own correct shape), is
// latched whole and streamed as two records, 'W' {x0,y0,x1,y1} then 'X'
// {x2,y2,x3,y3}, in place of the next two 'H' records; the running count
// rides in every 'H' where the tiny-refused count was. Slot 1 is the carried
// vertex v1 and slot 0 the carried v0, the only two slots a strip can bring
// in from elsewhere -- each is tested, and the slot is in the count's top bit.
function automatic logic near3(input logic signed [15:0] a, b, c);
	logic signed [15:0] lo, hi;
	begin
		lo = a; if (b < lo) lo = b; if (c < lo) lo = c;
		hi = a; if (b > hi) hi = b; if (c > hi) hi = c;
		near3 = (hi - lo) <= 16'sd8;
	end
endfunction
function automatic logic far2(input logic signed [15:0] a, b);
	far2 = ((a - b) > 16'sd60) || ((b - a) > 16'sd60);
endfunction
function automatic logic onscreen(input logic signed [15:0] x, y);
	onscreen = (x > 16'sd0) && (x < 16'sd495) && (y > 16'sd0) && (y < 16'sd383);
endfunction
wire wedge_in  = onscreen(q3d_x0, q3d_y0) && onscreen(q3d_x1, q3d_y1)
              && onscreen(q3d_x2, q3d_y2) && onscreen(q3d_x3, q3d_y3);
wire wedge_s1  = near3(q3d_x0, q3d_x2, q3d_x3) && near3(q3d_y0, q3d_y2, q3d_y3)
              && (far2(q3d_x1, q3d_x2) || far2(q3d_y1, q3d_y2));
wire wedge_s0  = near3(q3d_x1, q3d_x2, q3d_x3) && near3(q3d_y1, q3d_y2, q3d_y3)
              && (far2(q3d_x0, q3d_x2) || far2(q3d_y0, q3d_y2));
wire wedge_hit = q3d_valid && q3d_ready && wedge_in && (wedge_s1 || wedge_s0);
logic [127:0] wedge_q;
logic         wedge_have, wedge_slot;
logic  [1:0]  wedge_ph;          // 0: nothing to send, 1: send W, 2: send X
logic [14:0]  wedge_n;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		wedge_q <= '0; wedge_have <= 1'b0; wedge_slot <= 1'b0; wedge_ph <= 2'd0; wedge_n <= 15'd0;
	end else begin
		if (wedge_hit) begin
			if (!(&wedge_n)) wedge_n <= wedge_n + 15'd1;
			if (!wedge_have) begin
				wedge_q    <= {q3d_x0, q3d_y0, q3d_x1, q3d_y1, q3d_x2, q3d_y2, q3d_x3, q3d_y3};
				wedge_slot <= wedge_s1;
				wedge_have <= 1'b1; wedge_ph <= 2'd1;
			end
		end
		// Each B event that finds a wedge pending sends one half of it; one that
		// finds a fold pending (and no wedge) sends the fold.
		if (uart_b2_valid && !wedge_have && sw_pend) sw_pend <= 1'b0;
		if (uart_b2_valid && wedge_have) begin
			if (wedge_ph == 2'd1) wedge_ph <= 2'd2;
			else begin wedge_ph <= 2'd0; wedge_have <= 1'b0; end
		end
	end
end

m2_dbg_stream #(.DIVISOR(417), .BUDGET_CYC(200_000)) u_dbg_stream (
	.clk(clk_sys), .rst_n(mem_rst_n),
	// THE IP RING: 512 consecutive retired instructions, recorded at full
	// speed and read out slowly. Sampling cannot show a BRANCH, and a branch
	// is now the whole question -- the background fill at 0x1ce38 runs while
	// the artwork at 0x1c904/0x1c770 and the text at 0x18ea4 never do.
	// THE A/B: with DCACHE_EN=0 the read path is exactly the pre-cache one,
	// so if the count still reads 0x27272727 the cache is innocent and the
	// fault is below the bridge. map2's fold says whether it is drawing.
	// WITH THE LOOP FIXED, IS IT DRAWING? Snoop the renderer's own read port
	// on map 2. MAME holds 1,274 distinct values there; the board held SIX,
	// which was the flat screen. This says whether that has changed.
	// SCANLINE OVERRUNS. An overrun is a line whose fetches did not finish
	// before the next started: the bank does not flip and the previous line
	// is shown again, which on a screen is flicker. Now that the artwork
	// actually draws, the fetch engine has far more work per line than when
	// it painted two flat colours -- so this is exactly when to expect them.
	// Reported with the per-line fetch count and the glyph cache's hit rate,
	// because those say WHY and not merely how many.
	// THE SOUND LINK, against the reference's own count. MAME emits exactly
	// 59 bytes to this port over 900 frames of attract mode, so the board
	// either sends that stream or it does not -- and that is checkable
	// before a single sound chip exists. Overruns ride in the low half so
	// the tearing work stays visible at the same time.
	// THE 68000'S OWN STATE, because the link's byte count now answers a
	// different question than it did. With the far end drained the count said
	// "the i960 sent its stream"; with a real receiver attached it says "the
	// sound board is reading its UART", and a board that stops at two bytes is
	// reporting that its 68000 is not running -- which is what happened. The
	// last bus address and the cycle count say whether it is alive and where.
	// SCAN RESULT IN THE TOP BYTE, the 68000's own state below it. The scan
	// answered its question -- byte 0x2340000, which is what the MRA said all
	// along -- and the live question is now whether the CPU runs.
	// THE SAMPLE RATE, MEASURED ON THE BOARD. Two readings a second apart give
	// it directly, against the chip's own 10 MHz / 224 = 44,643 Hz. "The sound
	// is slow" has been reasoned about from simulated latencies for long
	// enough; this is the number itself.
	// A REAL INSTRUCTION TRACE FROM THE SLOW PHASE, which is the only thing
	// that names what the machine is doing for its first three minutes.
	//
	// The ring has been recording the last 512 retired IPs since the design was
	// built and has never been read out -- ipring_q was written and nothing
	// consumed it. The reader walks one entry per profiler tick and wraps, so
	// consecutive passes show whether the CPU is in a repeating cycle and how
	// long that cycle is.
	//
	// The retired-instruction count rides in the data half, so one channel
	// still gives the rate as well as the trace: 24 cycles per instruction in
	// the slow phase against 7.5 once it settles, measured on the board.
	// WHERE THE i960 IS AND WHAT IT LAST TOUCHED. out_pushed 62 against
	// out_popped 61 says a result is sitting unread, so the CPU has stopped
	// rather than gone idle -- and a CPU stopped on a bus access is named by
	// its IP and its last address, not by any coprocessor counter.
	// UNMAPPED COUNT AND AN ADDRESS HIGH-WATER MARK, not the IP ring.
	//
	// Reading ipring_q into the streamer made quartus_fit die with
	// "Internal Error: TDB, tdb_node.cpp:2080" on TWO consecutive seeds --
	// 19 and 31 -- where the same design without it built fine. Two identical
	// failures at different seeds is not placement luck, so the ring is left
	// disconnected rather than fought.
	//
	// These answer the same question more cheaply anyway. A clear loop that
	// RUNS AWAY writes unmapped space continuously, so dbg_unmapped races and
	// laddr_max climbs; a loop that merely takes a long time leaves both
	// still. The control is build 36, which works and can be read the same way.
	// WHERE THE GAME IS WAITING. It boots, renders the tilemap and drives the
	// sound board, then stops on the first attract frame -- so this is game
	// logic waiting on something, not a stalled machine.
	// C = <TGP retires : TGP pc> | <io reads : out_pushed>. MODEL 1'S LESSON,
	// R147: the coprocessor's state must be on the wire or its faults are
	// invisible -- "only visible because 2:1 put C= and R= on the printf
	// channel". The previous build measured THREE io reads in 45 s where MAME's
	// TGP hammers its math units, which says the coprocessor is executing
	// something, but not the geometry code. Retires and pc say which.
	// THE INSTRUMENT NOW WATCHES THE i960, NOT THE TGP (R159).
	//
	// Three hardware failures in one session were each explained with a
	// different mechanism and none could be told apart, because this channel
	// carried only TGP state. `tgp_pc = 0000` says the coprocessor never left
	// reset; it cannot say WHY, because the reason is always on the CPU side --
	// the i960 is what writes coproctl and releases it.
	//
	// cpu_dbg_ip, cpu_trap, cpu_trap_op and cpu_halted have existed in this file
	// the whole time and none of them reached a wire. `tgp_pc` is kept in the low
	// half so nothing already learned is given up.
	.a_valid(prof_tick), .a_addr(cpu_dbg_ip),
	// THE RETIRED-INSTRUCTION COUNT RIDES ALONG WITH THE IP.
//
// The profile says 91% of the board's time goes on the four memory
// instructions of one loop -- ld/st stalling, not spinning. If the CPU is
// simply too slow, the routines that "never run" have merely not been reached:
// simulation finishes this initialisation in 15.9 M instructions. Two
// consecutive samples give the instruction rate directly, which settles
// whether this is a wrong branch or a slow machine.
	// WHAT THE CPU ACTUALLY READ, not which address it asked for. The address
	// has been a constant 0x016FFFF8 in every capture of the spin, so it costs
	// nothing to give up and the DATA is the one fact five builds of
	// elimination could not supply. Swap back when the read path is understood.
	// {trap, cpu halted, copro stall, uploading} : microcode words loaded : tgp pc
	//
	// `copro_prog_words` is the question the last three builds could not answer:
	// zero means the upload never started, 2024 means it finished. With the IP
	// beside it, one capture separates "the CPU never got there" from "it got
	// there and hung" from "it trapped".
	// THE RETIRED-INSTRUCTION COUNT TAKES copro_prog_words' TWELVE BITS.
	//
	// prog_words has read 0x7E8 on every sample ever taken -- 2,024 words, the
	// microcode is loaded, and that question is answered permanently. What is
	// NOT measurable today is the CPU's rate: cpu_dbg_acc exists and feeds the
	// IP ring, but nothing put it on the wire, and prof_tick is a fixed divider
	// so the record rate says nothing about the machine.
	//
	// IT MATTERS BECAUSE MODEL 1 SAYS SO. On that core, 3D working SLOWED THE
	// CPU -- geometry reads, polygon writes and texture fetches contending for
	// SDRAM -- and raising the clock is what bought it back. So the rate is not
	// a health metric here, it is the 3D traffic seen from the other end, and
	// "still at 100%" is how we will know the coprocessor is still parked.
	//
	// BITS 27:16, not the bottom twelve. The low bits wrap in under a
	// millisecond at any plausible rate and two readings of them mean nothing.
	// [27:16] steps once per 65,536 retired instructions -- about 76 Hz at 5
	// MIPS -- which is visible between captures and does not wrap inside one.
	// THE 3D HANDLER'S ENTRY COUNT AND THE ATTRACT STATE take those twelve
	// bits instead. tgp_pc at 0x030B is the microcode's FIFO wait (L_04c is
	// `b = rf1`, 0x30b the `goto L_04c` that retired before it), so the
	// coprocessor is idle for want of commands and the rate is not the
	// question. tw_5890 is: the reference dispatches 0x5890 once a frame from
	// attract state 3 on, and the 09-08 captures read it ZERO with state 3.
	// THE MAILBOX CLEAR, COUNTED AT BOTH ENDS. Measured on build/walk s11: the
	// walk ends at entry 13 because its handler chain polls 0x91fff0 until the
	// TGP's clear (L_4c4, two 16-bit halves through the shared write port)
	// becomes visible, and on that build it never does while the TGP sits at
	// 0x4C9 having issued it. mb_req counts the TGP's requests for the HIGH
	// half (word 0xFFF9), mb_ack the port acknowledges that retired one.
	// Wrapping, six bits each: if they drift apart the port loses writes.
	// build/e140 s13 MEASURED: entry 140's word 0 reads 0x00000000 in all 923
	// state-3 samples and the walker loaded it TWICE in 9,000 frames, while
	// the stored count still reaches 0 every frame. The walk is not advancing:
	// a size field read as zero makes `addi r7,g13,g13` a no-op and the walker
	// spins on one entry for the rest of the count, calling its handler each
	// time -- which is why 0xC9C4 dominates and the mailbox is queried ~127
	// times a frame. e13_hdl_n counts the walker's loads of entry 13's handler
	// word (0x504E0C at IP 0x185c): once a frame if the walk advances, ~127 if
	// it spins. Wrapping.
	// AFTER THE FIX (build/fix s13: size 0x300 in every sample, render chain
	// 5,048 samples where it had 0), the game emits geometry every frame and
	// nothing is on screen. So the geometry counters take the channel:
	// matrix pushes here, then walk opcodes : polygons | clipper in : out.
	// build/geo s11 MEASURED: matrix pushes saturate, walk ops 286-2050 a
	// frame, and polys = clip in = clip out = 0. The walk decodes the list;
	// the geometry engine produces nothing from it. So the object stage:
	// objects dispatched : objects finished | the last polygon-ROM word the
	// engine read, with capped (MAX_POLYS hit -- an object reading 0xFFFF)
	// and the walk state here.
	// build/tbl s13 MEASURED (tables fixed): objects dispatched == finished,
	// up to 253 a frame, none capped, real floats read from the polygon ROM.
	// So the polygon path after the object: produced, refused nonfinite,
	// clipped out, dropped, reaching the rasteriser.
	// THE VERTICAL SCROLL THE RENDERER USED, layers 0 and 1, low six bits
	// each, ~7 samples a frame: the background jumps vertically at frame rate
	// on the board, and alternating values here say the game writes two
	// values, while a steady value says the picture moves for another reason.
	// R237: the scroll probes (R212, closed) give their twelve bits to the
	// projections abandoned on timeout -- the one path that hands a late x/y
	// to the NEXT vertex, which is the shape of the board's wedges. Zero at
	// the desk; the board has to say.
	.a_data({cpu_trap, cpu_halted, copro_stall, copro_dbg_ctl[31],
	         geo_pj_lost[11:0], tgp_pc[15:0]}),
	// THE i960's OWN INSTRUCTION COUNT, so the first three minutes can be
	// diagnosed rather than described. Two readings a known time apart give the
	// rate directly; a machine that is slow for three minutes and then is not
	// has either been waiting for something or executing something, and an
	// instruction rate separates those outright -- a low rate that RISES is a
	// stall clearing, a high rate throughout is work being done that stops.
	//
	// Paired with the sound board's bus-cycle count, because the two share the
	// SDRAM and "the picture sped up" and "the sound did not" is exactly the
	// kind of claim these two numbers settle.
	// THE DATA CACHE, IN BOTH PHASES, because the profile reframed the
	// question. The first attract scene is not a machine that is stalled -- it
	// is a machine that is BUSY: 40% of its time in 0x011000-0x011FFF and 36%
	// more across 0x010000/0x013000/0x016000, code that later scenes never
	// touch. Afterwards it spends 70% of its time in a TWO-INSTRUCTION wait
	// loop at 0x12B0/0x12B8, which is what 7.2 CPI actually measures: idling.
	//
	// So the slow phase is real work at 24 cycles per instruction, and the
	// obvious suspect is the i960's data cache being 2 KB. Two samples of these
	// give the hit rate directly, in each phase, which says whether a bigger
	// cache is the answer or whether the misses are compulsory.
	// THE SCROLL REGISTERS THE RENDERER USED, all four layers, packed as
	// {h,v} pairs across two words. The board reports the grass and sky
	// standing still and the decode is complete and correct, so this says
	// whether the game writes zero or we read the wrong words.
	.b_valid(uart_b2_valid),
	// out_data is measured and settled -- 0x42976767, a real float. What is not
	// known is why the i960 stopped popping after ~113 results, so the wire
	// carries the pop count and the CPU's IP instead.
	// hscr IS THE ACCEPTANCE TEST (R106) and it is back on the wire now that
	// the 0x2e halt is fixed. io flags stay alongside it: if the TGP stops
	// again, io_rd high with io_ack low names the next unanswered region.
	// THE BANK REGISTER, which is what R133 turns on. b_data still carries the
	// TGP's io address and flags -- that pairing found the dropped-write hang.
	// ONLY bank[23:16] MEANS ANYTHING -- it is the window base and its top two
	// bits gate the view. Carrying all 32 routes a wide bus from inside the TGP
	// to the streamer for no information, and this design is at the edge of
	// closing on the SDRAM domain.
	// THE WALK'S OWN NUMBERS. Against the offline oracle: 101 opcodes and 60
	// object_data per frame. Anything else means it is reading the wrong memory
	// or mis-counting an operand, and both look like a corrupt display list.
	// THE GEOMETRY, REPLACING THE TGP'S LOOP COUNTS. Those answered "is the
	// coprocessor stuck in its display-list loop", which R167 settled; the live
	// question is now whether the 3D pipeline sees anything to draw. Eight
	// numbers, low byte each -- these are "non-zero and roughly how many"
	// questions, not exact ones:
	//
	//   b_addr  objects to ROM : PRAM0 : PRAM1 : objects hitting MAX_POLYS
	//   b_data  clipper in : out : dropped : quads reaching the rasterizer
	//
	// The first three of b_addr separate "the geometry is broken" from "every
	// object this game draws lives in a polygon RAM that opcode 0x05 has never
	// filled" -- two states that look identical on a black screen and need
	// completely different work.
	// THIS PACKING IS THE ONE IN THE BUILD, which the previous one was not.
	// An earlier attempt to change it was in a batched edit whose LATER
	// assertion failed, so the whole script discarded it -- and a hardware
	// capture was then read with a packing that had never been synthesised.
	// The numbers were real; the labels were fiction.
	//
	//   b_addr  walk_frames : objects to ROM : to PRAM0 : engine state : qst
	//   b_data  clip in : out : nonfinite : clipper state : walk state
	//
	// Between them: is the walk alive, is it finding objects, and if it is
	// wedged, WHICH STAGE is not answering.
	// THE MATRIX IS THE LIVE QUESTION AND IT WAS NOT ON THE WIRE.
	//
	// Every vertex collapses to the origin, which is what a zero matrix gives,
	// and "matrix writes = 0" was measured in a 30-million-instruction
	// SIMULATION -- never on the board. MAME has exactly two writers of
	// geo->matrix, geo_matrix_write (0x0b, twelve words) and
	// geo_translate_write (0x0c, matrix[9..11]), and this core implements both.
	// So either the game does not send them in the lists we walk, or it does
	// and we step over them, and only the board can say which.
	// IS THE FRONT DOOR EVEN RECEIVING WRITES? That is the question the board
	// and the simulation now disagree about, and nothing on the wire answers
	// it. Simulation at 30M instructions reaches 399 matrix writes, 553
	// objects and 3,038 polygons; the board sits at 2 focal writes and nothing
	// else, unchanged across 382 records in 60 seconds.
	//
	// geo_pushes counts words ACCEPTED by the push port, geo_dropped counts
	// words refused for want of queue space. Between them and mtx_n:
	//   pushes climbing, mtx zero -> we are decoding or walking wrongly
	//   pushes flat                -> the i960 is not writing, and the fault is
	//                                 upstream in the game's own progress
	//   dropped climbing           -> the queue is too small and the list is
	//                                 being corrupted by loss
	//   b_addr  matrix pushes : the frame the LAST one landed on : decoded
	//   b_data  function writes REFUSED by the gate : function writes accepted
	// THE FRAME FLAG AT 0x00500000, because mtx_push has read a static 110 since
	// frame 134 and the geometry counters have nothing further to say.
	//   b_addr: the attract state -- last value written : times it was 2, the
	//   state whose handler enables the 3D task : total writes : entries into
	//   the 3D handler. 0xEE in the top byte is "never written".
	// WHERE THE WALK STARTS AGAINST WHERE THE PUSHES LAND. Measured 2026-09-08:
	// with the flip trigger the walk runs 901 times in twenty seconds and retires
	// one to three opcodes each time, with polys and quads at zero throughout. So
	// it is not running too rarely -- it is starting on a list that is empty at
	// the pointer the flip handed it. rp against wp says whether that is an empty
	// buffer or the wrong buffer, and no amount of reading the walk can say which.
	// dbg_p4_clash is the counter Model2.sv:642 added against exactly this and it
	// has never been read on hardware; R167 records the same port sharing as
	// fatal when the walker and the engine were independent. With it, the state
	// the walk sits in and any opcode the table does not cover.
	// R200'S TWO NUMBERS take this channel, because the two they replace have
	// read ZERO on every capture ever taken: dbg_p4_clash never fired and
	// geo_walk_unknown never fired, so the walk is neither clashing on port 4 nor
	// stopping on an opcode it cannot decode. What is not known is why the fill
	// misses bands 0-11, and these say it: cycles from frame_start to P_READY,
	// and bands completed last frame against NBANDS=24.
	// THE LAST DESCRIPTOR THE TASK WALKER LOADED. The reference's list has 140
	// entries and the 3D task is the LAST one, at 0x00510F80; entry 111's
	// handler (0x2200e4) jumps the walk to the entry stored at 0x501260 and
	// subtracts the skipped count with a divo. A walk that ends anywhere below
	// 0x00510F80 never reaches the 3D task, and this says where it ended.
	// MEASURED 2026-09-10 on build/walk s11: wk_last_desc = 0x00504E00 in 920
	// of 923 state-3 samples (0x00505D00 in 3), sk_cnt/sk_ptr never written,
	// tw_5890 = 0. THE WALK ENDS AT ENTRY 13 OF 140. Either the count starts
	// short, a handler in 1..13 rewrites it, or entry 13's handler never comes
	// back to 0x1864. So: the handler address the walker loads at 0x185c (the
	// last one called), the count it loads from ROM at 0x1844, and the last
	// count it stores at 0x1870.
	// WHAT THE TGP SAYS IT WROTE to dword 0x7FFC (low half first, then high;
	// EEEEEEEE = never), against WHAT THE CPU READS BACK from 0x91fff0 below.
	// MEASURED ON build/walk2 s11 (setup -0.242 on the HDMI PLL only, hold
	// +0.186): count from ROM = 0x8C = 140; the walker's last stored count is
	// 0 in 54 state-3 samples and 0x70/0x6C/0x24/0x17/0x10 in others, so the
	// walk DOES run to the end of the list on this build, slowly, most of the
	// frame inside handler 0xC9C4 (the car handlers' init state, which the
	// reference has left for 0xD290 by frame 400) -- and tw_5890 is STILL 0.
	// So entry 140 is walked and not called. This is its descriptor as the
	// walker reads it: word 0 (bit 31 = enabled) and the handler at +0xc, and
	// how many times the walker has loaded it.
	// ENTRY 13's SIZE FIELD (0x504E08) AS THE WALKER'S `ld 8(g13)` AT 0x1880
	// RETURNS IT. The reference holds 768 (0x300).
	// build/p4b s17 (R202+R203+R205+R206): objects still finish with polys 0,
	// quads 0. So THE ENGINE'S FIRST READ OF EACH OBJECT, as the board's port
	// 4 delivers it: its data (the attribute word; bits [1:0] clear ends the
	// object) and, below, its index with the object's base select.
	// build/ack s14 drew the cars: white (flat by design) and FLASHING. So the
	// rasteriser's frame timing: cycles from frame_start to P_READY, bands
	// completed last frame (of 24), frames whose geometry was still being
	// collected at frame_start (drew nothing), and below the quads held,
	// quads dropped for a full store, and frames the geometry stage finished.
	// R213: hold = video frames the last list stayed on display; missed =
	// scanlines the beam drew with no band ready (free-running).
	.b_addr((wedge_have && wedge_ph == 2'd1) ? wedge_q[127:96]
	      : (wedge_have && wedge_ph == 2'd2) ? wedge_q[63:32]
	      : sw_pend                         ? {19'd0, sw_out_sel, sw_runs}     // R238: 'S' region, runs
	      : {r3d_ready_cyc[15:0], r3d_bands_done[7:0], r3d_hold[7:0]}),
	// clip_dropped read 0 on hardware and the refusal count is the number that
	// now moves, so it takes that byte. Between them: accepted, emitted, refused
	// before the arithmetic, and reaching the rasterizer.
	// polygon_data commands at full width -- the number that says whether the
	// list ever fills polygon RAM at all -- against the walk's unknown-opcode
	// register, which says whether the walk stopped on something it cannot
	// measure, and the low byte of the refusal count.
	// WHERE the walk is sitting, which is the one thing the previous packing
	// could not say. frames climbed 1 -> 65 and then froze again: it is not
	// stopping on an unknown opcode (unknown=0) and not refusing polygons
	// (nonfinite=0), so it is stuck in a state, and the state names the cause.
	// W_OBJW means the geometry engine never finished; W_PDW means the write DMA
	// never took a polygon_data dword; W_FETCH means a read never returned.
	// pj_lost replaces nonfinite, which has read zero on every capture. It
	// counts projections abandoned on timeout -- if the wedge was a lost
	// projection, this is the number that proves it and says how often.
	// The last word pushed through the FUNCTION port, whole. Its top bits are
	// the opcode the walk will decode: if bits 28:23 are zero here, the address
	// reconstruction is not working on hardware even though it works in
	// simulation on the same RTL.
	// matrix pushes : object pushes : what the walk decoded
	// THE TWO POINTERS. The game pushes 110 matrix writes and 3,000+ objects
	// into buffer RAM and the walk decodes NONE of them, so the words arrive
	// and the walk reads somewhere else. rp is where the walk starts, wp is
	// where the pushes land, and if they disagree the walk is reading a
	// different buffer -- most likely one holding a geo_end, which would
	// terminate it instantly every frame and is exactly what a climbing frame
	// counter with nothing decoded looks like.
	//   b_data: walker iterations : calls taken : 3D handler entered : the
	//   one-shot that registers it. 1c14 at zero is the whole answer.
	// THE WRITE POINTER AGAINST THE OPCODES WALKED, which is the pair that says
	// WHICH END of the 3D path is empty.
	//
	// Model 1 is the oracle and it says that when 3D works the CPU SLOWS DOWN --
	// geometry reads, polygon writes and texture fetches all contend for SDRAM,
	// and raising the clock is what bought that back there. This board runs at
	// full speed. That is not health, it is the ABSENCE of 3D traffic, and it is
	// the same fact as the walk retiring 3 opcodes seen from the other end.
	//
	// So the question is no longer WHERE the walk reads. The bridge maps
	// 0x00900000-0x00980000 to base_buffer + r_addr[16:1] with BUFFERRAM on and
	// reads enabled, and the walk reads GAME_BUFFER with a matching dword-to-word
	// shift, so the address is right and the walk reaches a terminator rather
	// than stalling -- state idle, no unknown opcode, no port-4 clash.
	//
	// The question is whether anything is QUEUED. geo_wp is where the game's
	// pushes land. If it sits at 3 then the game is producing three opcodes and
	// our walk is faithfully reporting them, and the fault is upstream in the
	// geometry engine. If it climbs into the hundreds while ops stays at 3, the
	// list IS being written and the walk stops early -- the opposite fault, and a
	// different fix. Nothing else distinguishes those two.
	//
	// geo_walk_frames gives up its half of the channel: the H-record cadence
	// already gives liveness, and R200's counters now carry the per-frame story.
	// THE SKIP HANDLER'S ARITHMETIC: the count it stores at 0x220104 (the
	// reference stores 2, leaving exactly the 3D entry) and the pointer it
	// loaded from 0x501260 (the reference holds 0x00510F00, entry 139).
	// AND WHO LAST WROTE THAT WORD: the writer's IP (low 16) and the data
	// (low 16), any byte of 0x504E08-0x504E0B. Only init should ever write it.
	// R210: ready and collect times in units of 16 cycles (the 16-bit ready
	// count saturated on the board), quads held in units of 16.
	// R214: OVERRUNS. Quads the store dropped for a full bank, words the
	// front-door push DMA dropped for a full queue (low 8 bits), quads held.
	// (dbg_missed read 0 through the title on dbuf6 s14: bands are never late.)
	// R216: store dropped (full), tiny quads refused (units of 16), quads held (units of 16).
	.b_data((wedge_have && wedge_ph == 2'd1) ? wedge_q[95:64]
	      : (wedge_have && wedge_ph == 2'd2) ? wedge_q[31:0]
	      : sw_pend                         ? {8'd0, sw_out}                    // R238: the fold
	      : {r3d_dropped[15:0], wedge_slot, wedge_n[6:0], r3d_quads[11:4]}),   // R235: wedge count where tiny was
	.a_tag(8'h43),
	.b_tag((wedge_have && wedge_ph == 2'd1) ? 8'h57 : (wedge_have && wedge_ph == 2'd2) ? 8'h58
	     : sw_pend ? 8'h53 : 8'h48),   // 'W', 'X', 'S', 'H'          // 'C' copro in_pushed:out_pushed | TGP retires:pc
	                                       // 'H' out_popped:hscr2 | io_addr:flags
	                                       // 'H' scroll h:v for layers 0,1 | layers 2,3 -- low bytes
	                                       // '0' map0 min|max : sum
	                                       // 'T' write count + trap/PA
	                                       // 'H' NOW: geometry.
	                                       //   addr = objects rom:pram0:pram1:
	                                       //          capped (nibbles), then
	                                       //          polygon_data cmds:words
	                                       //   data = clip in:out:nonfinite:quads
	.enable(1'b1),
	.tx(UART_TXD), .dbg_dropped(uart_dropped)
);
end else begin : g_nodbg
	assign UART_TXD = 1'b1;        // idle high; a floating TX reads as framing errors
	assign uart_dropped = 32'd0;   // read by the overlay, which is also gone
end endgenerate

// WHO WRITES THE SPACE. Everything upstream is now measured CLEAN on the
// board: backup holds 00030300, the firmware's window holds 00030300, and the
// formatter's own store carries ASCII digits (3131). The character only
// becomes 0x20 somewhere between the formatted string and this tile cell, so
// the useful question is no longer "what value" but "which instruction".
//
// This latches the CPU's IP at the moment a SPACE is written into the cell the
// Probe selects, alongside the value, and counts those writes. A blanking
// write from the same routine that drew the digit (0x1cddc / 0x1ce38) means
// the draw itself formatted a space; an IP anywhere else names the code that
// clobbers a cell it did not draw.
logic [31:0] blank_ip;
logic [15:0] blank_val;
logic  [7:0] blank_cnt;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		blank_ip <= 32'd0; blank_val <= 16'd0; blank_cnt <= 8'd0;
	end else if (ocb_tram_we && ocb_addr == tp_cell && ocb_din[7:0] == 8'h20) begin
		blank_ip  <= cpu_dbg_ip;
		blank_val <= ocb_din;
		if (!(&blank_cnt)) blank_cnt <= blank_cnt + 8'd1;
	end
end

// WHAT THE Z80 PUTS IN THE SETTINGS BYTES OF THE WINDOW, which is the whole
// question reduced to one word. MAME's real machine holds 00 03 03 00 at
// window offsets 0x114-0x117 and holds it stable for hundreds of frames; our
// board fills the window with the 7F FF RAM-test pattern. This latches the
// bytes AS THE Z80 WRITES THEM, so it says what our I/O board actually
// deposits rather than what survives:
//
//   00030300  the firmware writes real settings -- the window is not the fault
//   7FFF7FFF  the RAM-test pattern lands on the game's settings block
//
// The existing window counter cannot answer this: it saturates at 255, and two
// legitimate 128-byte exchanges reach that on their own.
logic [31:0] zw_set;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) zw_set <= 32'd0;
	else if (zio_we && zio_addr >= 11'h114 && zio_addr < 11'h118) begin
		case (zio_addr[1:0])
			2'd0: zw_set[7:0]   <= zio_wdata;
			2'd1: zw_set[15:8]  <= zio_wdata;
			2'd2: zw_set[23:16] <= zio_wdata;
			2'd3: zw_set[31:24] <= zio_wdata;
		endcase
	end
end

// ---------------------------------------------------------- cabinet inputs
//
// model2.cpp's `daytona` port map, which is `model2` plus `gears` with IN0 and
// IN1 modified. Four buttons were wired and the rest -- the four VR buttons,
// the gearbox and every analog axis -- were not connected at all.
//
//   IN0  0x01 COIN1   0x02 COIN2   0x04 TEST    0x08 SERVICE
//        0x10 START1  0x20 VR1 Red 0x40 VR2 Blue 0x80 VR3 Yellow    all active low
//   IN1  0x01 VR4 Green (active low)   0x0e unused
//        0x70 GEARBOX -- ACTIVE HIGH, and the one field here that is not
//        0x80 unused
//   IN2  unused, 0xff
//
// Analog goes through the I/O board's ADC: channel 0 steering with 0x80 at
// centre, 1 accelerator and 2 brake both idling at 0x20. MAME's own limits are
// PORT_MINMAX(0x20, 0xe0) on all three.
wire [7:0] iob_in0 = ~{joystick_0[15], joystick_0[14], joystick_0[8],
                       joystick_0[5], joystick_0[7], joystick_0[6],
                       1'b0, joystick_0[4]};

// THE GEARBOX IS A STATE, NOT A BUTTON. The cabinet has a five-position shifter
// and MAME models it as five buttons feeding daytona_gearbox_r, which returns
// gearvalue[] = {0, 2, 1, 6, 5} for N,1,2,3,4 -- deliberately NOT a binary
// count, because the real shifter is a set of microswitches and the game reads
// their pattern. A gamepad has no shifter, so Gear Up and Gear Down step
// through the five positions and the same table converts.
logic [2:0] gear;                    // 0=N, 1..4
wire        gup   = joystick_0[12];
wire        gdn   = joystick_0[13];
logic       gup_d, gdn_d;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		gear <= 3'd0; gup_d <= 1'b0; gdn_d <= 1'b0;
	end else begin
		gup_d <= gup; gdn_d <= gdn;
		if (gup && !gup_d && gear != 3'd4) gear <= gear + 3'd1;
		if (gdn && !gdn_d && gear != 3'd0) gear <= gear - 3'd1;
	end
end
logic [2:0] gearval;
always_comb begin
	case (gear)
		3'd1:    gearval = 3'd2;
		3'd2:    gearval = 3'd1;
		3'd3:    gearval = 3'd6;
		3'd4:    gearval = 3'd5;
		default: gearval = 3'd0;     // neutral
	endcase
end

wire [7:0] iob_in1 = {1'b1, gearval, 3'b111, ~joystick_0[9]};

// STEERING: the analog stick, with the D-pad as a ramp for anyone without one.
//
// MAME's range is 0x20..0xe0, so +-96 about 0x80. The stick is signed +-127, so
// three quarters of it lands exactly on that range. The digital ramp exists
// because a menu that needs left and right is unusable on a d-pad otherwise,
// and it is a RAMP rather than a jump to the rail so the wheel sweeps as a real
// one would.
wire signed [7:0] ax = joy_analog[7:0];
wire signed [8:0] ax34 = {ax[7], ax} - {{3{ax[7]}}, ax[7:2]};   // x - x/4
logic [7:0] steer_dig;
logic [9:0] steer_div;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		steer_dig <= 8'h80; steer_div <= 10'd0;
	end else begin
		steer_div <= steer_div + 10'd1;
		if (steer_div == 10'd0) begin
			if (joystick_0[1]) begin                       // left
				if (steer_dig > 8'h21) steer_dig <= steer_dig - 8'd1;
			end else if (joystick_0[0]) begin              // right
				if (steer_dig < 8'hdf) steer_dig <= steer_dig + 8'd1;
			end else if (steer_dig > 8'h80) steer_dig <= steer_dig - 8'd1;
			else if (steer_dig < 8'h80) steer_dig <= steer_dig + 8'd1;
		end
	end
end
wire use_stick = (ax > 8'sd12) || (ax < -8'sd12);
wire [7:0] steer = |paddle ? paddle
                 : use_stick ? 8'(9'sh080 + ax34)
                 : steer_dig;

// PEDALS: buttons, full travel. 0x20 idle to 0xe0 pressed, MAME's own limits.
wire [7:0] accel = joystick_0[10] ? 8'he0 : 8'h20;
wire [7:0] brake = joystick_0[11] ? 8'he0 : 8'h20;

// COIN PATH INSTRUMENT. The board hears a coin -- it plays the sound -- and does
// not credit it, and there are three different places that can be true in: the
// button may not be reaching IN0 at all, the I/O board's Z80 may not be counting
// it, or the credit may be arriving and being consumed. Counting the edge at the
// pin separates the first from the other two, which is the split worth having
// before guessing.
//
// The backup RAM's first dword rides along because it was just converted from an
// inferred array to an explicit altsyncram, and unwritten backup MUST read 0xFF:
// one that powers up as ZERO looks to the game like a valid all-zero save, which
// is exactly the shape of "coins do nothing". If this reads 0xFFFFFFFF on a
// fresh boot the .mif took; if it reads 0x00000000 it did not, and that is the
// fault rather than anything to do with inputs.
// DOES OUR i960 RESPOND TO THE COIN THE WAY MAME'S DOES?
//
// This is the last question in the chain and it separates the only two things
// still possible. Everything upstream measures identical to MAME: the button
// gives 20 edges for 20 presses, the Z80 publishes DPRAM word 4 with a
// lowest-ever 0xFE exactly as MAME's does, and the i960 demonstrably reads that
// byte because Start, Test and Service are bits of it and all three work.
//
// MAME's i960 answers a coin by starting a repeated write to 0x01c0001c byte 2
// -- dword 7, the high lane -- which does NOT happen before the coin. So:
//
//   this counter stays 0  -> our i960 never runs its coin routine
//   this counter climbs   -> it runs, and declines to award the credit
//
// The second would be coinage: MAME on a fresh nvram wants THREE coins, and
// shows "CREDIT 0/3" climbing to "CREDITS 2/3" as they go in.
logic [15:0] i960_coinack;
logic  [9:0] coinack_word;
logic        ack_seen_d;
// THE ADDRESS WAS WRONG THE FIRST TIME and the measurement it produced was
// meaningless. The I/O board sits at 0xc00xxx in the window -- `iob_sel` is
// `cpu_io_addr[23:12] == 12'hc00` -- so 0x01c0001c is offset 0xc0001c, not
// 0x00001c. Comparing against the latter counted zero writes and read as "the
// i960 never runs its coin routine", which was a statement about my arithmetic.
//
// So this no longer depends on getting one constant right: it counts EVERY
// i960 write into the I/O board's window that names byte 2, and latches which
// word the last one went to. Word 7 is 0x1c. If the count is zero the i960
// really is writing nothing there; if it is not, the word index says where.
wire         coinack_wr = iob_sel && cpu_io_we && cpu_io_be[2];
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		i960_coinack <= 16'd0; coinack_word <= 10'd0; ack_seen_d <= 1'b0;
	end else begin
		ack_seen_d <= coinack_wr;
		if (coinack_wr && !ack_seen_d) begin
			if (!(&i960_coinack)) i960_coinack <= i960_coinack + 16'd1;
			coinack_word <= cpu_io_addr[11:2];
		end
	end
end

// THE GAME'S LOGIC FRAME RATE, which is the number the board is actually
// complaining about and which nothing so far has measured.
//
// The picture is SMOOTH and running at a quarter to an eighth speed. Smooth
// rules out dropped frames -- the renderer is fine and each frame is drawn
// completely. What is slow is the game advancing its own state, and that
// reconciles with the 13% idle exactly: if a logic frame's work takes about
// seven display frames and then waits one for the next vblank, the CPU is 87%
// busy, 13% idle, and the game runs at an eighth speed. Those three numbers
// agree, which none of the earlier framings managed.
//
// 0x12B0/0x12B8 is the wait. Counting how often it is ENTERED counts logic
// frames -- occupancy says how long it waits, entries say how often. Against
// io_framenum, which counts real vblanks at 57.5 Hz, the ratio IS the speed:
// one entry per vblank is full speed, one per eight is what the board sees.
logic [31:0] logic_frames;
logic        in_wait, in_wait_d;
always_comb in_wait = (cpu_dbg_ip == 32'h000012B0) || (cpu_dbg_ip == 32'h000012B8);
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		logic_frames <= 32'd0; in_wait_d <= 1'b0;
	end else begin
		in_wait_d <= in_wait;
		if (in_wait && !in_wait_d) logic_frames <= logic_frames + 32'd1;
	end
end

logic [15:0] coin_edges;
logic        coin_d;
always_ff @(posedge clk_sys or negedge cpu_rst_n) begin
	if (!cpu_rst_n) begin
		coin_edges <= 16'd0; coin_d <= 1'b1;
	end else begin
		coin_d <= iob_in0[0];
		if (coin_d && !iob_in0[0] && !(&coin_edges))
			coin_edges <= coin_edges + 16'd1;   // active low: falling edge is a coin
	end
end

m2_ioboard #(
	.USE_Z80(1'b1),
	// RESCALED TO clk_sys. These are measured in FRAMES -- status at 7 and
	// the board's self-test at 174 of a 57.5 Hz refresh -- so moving the module
	// to a 40 MHz clock moves the constants with it. At 25 MHz they were
	// 3,043,478 and 75,652,174; here they are 0.1217 s and 3.026 s of 40 MHz.
	// R227: these encode a DURATION, not a count -- status at 0.101 s and the
	// self-test at 2.52 s -- so the 60 MHz core clock scales both by 6/5. The
	// game spins waiting for the status byte, so being early is harmless and
	// being late is not; keeping the real duration keeps the boot as measured.
	.STATUS_CYCLES  (5_072_464),
	.SELFTEST_CYCLES(126_086_957)
) u_ioboard (
	.clk(clk_sys),
	.rst_n(cpu_rst_n),
	.sel(iob_sel),
	.we(cpu_io_we),
	.word(cpu_io_addr[11:2]),
	.be(cpu_io_be),
	.wdata(cpu_io_wdata),
	.z_we(zio_we && fw_ready), .z_addr(zio_addr), .z_wdata(zio_wdata),
	.z_rdata(zio_rdata),
	.rdata(iob_rdata),
	.dbg(iob_dbg), .dbg_win_rd(iob_win_rd),
	.dbg_flag_rd(iob_flag_rd), .dbg_seen(iob_seen),
	.win_busy(dp_busy),
	.dbg_word4(iob_word4)
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
logic            sw_done_d, sw_emit;
wire             sw_ack = p_ack[2] && sw_req && !cp_req && !st_rd_req;   // R238: port 2, ours only when the others are idle
logic            sw_pend;         // a completed fold waiting for the stream
logic [23:0]     sw_out;
logic  [4:0]     sw_out_sel;
logic  [7:0]     sw_runs;

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
		sw_done_d <= 1'b0; sw_emit <= 1'b0; sw_runs <= 8'd0; sw_pend <= 1'b0; sw_out <= 24'd0; sw_out_sel <= 5'd0;
	end else begin
		// RESTART ON A NEW SELECTION -- but never out of state 1, which is the
		// one state with a request outstanding on port 4. Dropping sw_req there
		// does not cancel it; the controller still answers, and that ack would
		// land in a sweep which had already zeroed its accumulator, folding one
		// stale burst into the new region's total. A sweep is ~66 ms, so waiting
		// for the in-flight burst to land costs nothing.
		// AUTO-REPEAT, TO TEST THE MEMORY ITSELF.
		//
		// REAL_MEM renders attract correctly at the board's own speed, so the
		// fault is not logic and not timing. What simulation cannot model is a
		// marginal physical interface -- and this board has ONE working capture
		// depth of six. Corruption at even 1-in-10,000 reads would pass a
		// ten-read spot check and still be fatal: one bad pointer during
		// initialisation and the game never recovers.
		//
		// So fold the SAME 2 MB region again and again. A memory that returns
		// the same data every time folds to the same value every time. Any
		// variation is proof the reads are unreliable, which no amount of
		// staring at logic would ever show.
		sw_emit <= 1'b0;
		if (sw_done && !sw_done_d) begin
			sw_emit  <= 1'b1;          // one pulse per completed fold
			sw_pend  <= 1'b1; sw_out <= sw_acc; sw_out_sel <= sw_sel;   // R238: hand it to the stream
			sw_runs  <= sw_runs + 8'd1;
			sw_state <= 3'd0;          // and immediately go round again
			sw_done  <= 1'b0;
		end
		sw_done_d <= sw_done;

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
			// m2_sdram's sw_ack in the 96 MHz domain and latched in the 48 MHz
			// one. At 40 MHz that fitted. At 48 it does not:
			//
			//   From  m2_sdram|sw_ack   To  sw_acc[23]
			//   Data Delay 10.125 ns against a 10.417 ns relationship
			//   Setup slack -0.623  (VIOLATED)
			//
			// It was the ONLY failing path in the whole design -- the 96 MHz
			// memory domain closed at +1.567 ns -- and it is debug
			// instrumentation, not the machine. Folding one word per cycle cuts
			// the chain to a quarter and costs three extra cycles per burst on
			// something that runs once and has no deadline.
			3'd1: if (sw_ack) begin
				sw_req  <= 1'b0;
				sw_word <= p_dout[2];
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
				// RE-APPLIED, AS THE PROOF TEST FOR R57. The first build carrying
				// this bound failed to boot, and the mechanism was never this
				// arithmetic: the SDRAM interface had no timing constraints, so
				// ANY placement change could silently break the memory. With the
				// interface constrained (and closing with margin), this change
				// going in cleanly is the demonstration that the fix bought what
				// it claimed. Bounds the last region's fold at the end of the
				// loaded image, so region 21 -- the top 1.6 MB, where graphics
				// data sits -- finally has a checkable expected value: DDC2C0.
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
// GLYPH FETCH CENSUS. Tilemap writes are 35% non-zero and the renderer reads
// 38.7% non-zero, so the picture survives as far as the tile word. The next
// thing a pixel needs is its GLYPH, and a glyph of all zeros paints one flat
// colour per layer -- the exact symptom. Counted on the ack, so this is fetches
// and not idle cycles.
logic [31:0] cf_cnt, cf_nz;
wire [17:0] vid_layer_px [4];
// THE SCROLL REGISTERS THEMSELVES, SNOOPED AS THEY ARE WRITTEN.
//
// Three layers of four produce ZERO pixels and the fourth paints all 190,464.
// A layer is switched off for the whole frame by bit 15 of its vertical scroll
// word, and m2_video reads those from tile RAM: hscr at 0x5000 + (layer >> 1),
// vscr at 0x5004 + (layer >> 1). So latch those four words as the CPU stores
// them and read bit 15 directly, rather than inferring it from the symptom.
// WHICH TILEMAP DOES THE GAME ACTUALLY FILL?
//
// The renderer maps layer N to tile RAM 0x1000*N, and layers 0 and 1 fetch ZERO
// non-blank tile words while 2 and 3 saturate. Either the game never writes maps
// 0 and 1 -- in which case the picture is expected somewhere we are not looking
// -- or it does and our read addressing misses it. Counting NON-ZERO writes per
// map settles which, and a counter cannot be biased the way the per-write census
// was.
// HOW MANY TIMES DOES THE PICTURE CHANGE COLOUR?
//
// Every stage measures healthy and the screen is two flat colours, so measure
// the OUTPUT rather than another stage. A flat screen changes colour a handful
// of times a frame; a drawn one changes thousands. This settles whether the
// picture exists at all and is being lost after the mixer, or was never drawn --
// and it cannot be argued with, unlike every stage census so far.
logic [23:0] px_prev;
logic [31:0] px_changes, px_total;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		px_prev <= 24'd0; px_changes <= 32'd0; px_total <= 32'd0;
	end else if (ce_pix) begin
		px_prev  <= {tile_r, tile_g, tile_b};
		px_total <= px_total + 32'd1;
		if ({tile_r, tile_g, tile_b} != px_prev) px_changes <= px_changes + 32'd1;
	end
end
// DOES THE GAME UPLOAD ITS GLYPHS AT ALL?
//
// The tilemaps are RIGHT -- maps 2 and 3 match MAME's content exactly, 4,096
// real tiles each -- and the screen is two flat bands. A correct tile index
// pointing at a blank glyph paints one flat colour, so the glyph memory is the
// only thing left between the two. cpu_char_wr already marks writes landing in
// 0x01080000-0x010fffff; count them, and count how many carry data.
logic [31:0] chw_cnt, chw_nz;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		chw_cnt <= 32'd0; chw_nz <= 32'd0;
	end else if (cpu_char_wr) begin
		chw_cnt <= chw_cnt + 32'd1;
		if (|cpu_wdata) chw_nz <= chw_nz + 32'd1;
	end
end
logic [31:0] mapnz [4];
logic [31:0] mapreal [4];
// IS THE CONTENT VARIED, OR ONE TILE REPEATED?
//
// tw_acc counts NON-BLANK tile words, not distinct ones, so a map filled with a
// single repeated index saturates it and still paints one flat colour -- which
// is exactly what layer 2 does. Counting cannot tell those apart; folding can.
// XOR and SUM over the values written, plus the smallest and largest seen, are
// four numbers MAME can be asked for exactly.
// WHAT THE RENDERER READS OUT OF MAP 2, CELL BY CELL.
//
// Folding the WRITES was not decisive: the board's range 0x0020..0x8020
// contains MAME's 0x3000..0x3d8d, so spaces written while clearing widen it
// without saying what the final content is. The renderer reads that content
// every frame, so snoop its own read port -- no extra port, no duplicated
// array, and it reports exactly what the picture is drawn from.
//
// tram_data is registered one cycle behind tram_addr, so the address is delayed
// to match. MAME's map2 holds 1,274 distinct values between 0x3000 and 0x3d8d;
// if this comes back as a handful of values, that is the flat screen and it is
// a data fault, not a rendering one.
// THE TWO WORDS THAT DECIDE THE STUCK LOOP.
//
// 0x1b98 loads the loop COUNT from 0x501084 and 0x1ba0 the base POINTER from
// 0x501224; the loop then advances by the size at base+8 and counts down. MAME
// holds count=0x13, base=0x00505100, size=0x300 and leaves after nineteen
// passes. R75 measured the board's base as 0x511000 with a size of ZERO, so its
// pointer never advances and only the count can end the loop -- and a large
// wrong count is a loop that runs for HOURS, which is exactly how long the board
// sat before the attract screen appeared.
//
// So read both, off the CPU's own bus, registered before compared.
logic [31:0] lc_cnt, lc_base, lc_wdat, lc_wbe;
logic [31:0] sd_seen;
logic        sdw_d;
logic [SDR_AW:1] sdwa_d;
logic [15:0] sdwd_d;
logic  [1:0] sdwb_d;
logic        cack_d, cwe_d;
logic [31:0] caddr_d, crd_d, cwd_d;
logic  [3:0] cbe_d;
logic [31:0] cip_d, wk_last_desc, sk_cnt, sk_ptr, wk_last_hdl, wk_cnt_init, wk_cnt_last;
logic [31:0] mb_rdback;
logic [31:0] e140_w0, e140_hdl;
logic [31:0] e13_size, e13_wr_ip, e13_wr_dat;
logic [11:0] e13_hdl_n;
logic [15:0] e140_cnt;
logic  [5:0] mb_req_cnt, mb_ack_cnt;
logic        mb_ack_d;

// THE MAIN LOOP'S FRAME FLAG, AT 0x00500000.
//
// The board spends 90% of its profiler samples in a two-instruction spin at
// 0x12b0 -- `ldob r3,[0x500000]` then `cmpibe r3,g0,-8`, which loops WHILE the
// byte is unchanged. It is the frame wait of the main loop at 0x1240-0x1290,
// so the machine is not hung; it is waiting for that byte to move. In the
// reference the byte counts 00,01,02,...,2b. If ours never moves, the main loop
// never advances a frame and mtx_push stays at 110 for ever, which is exactly
// what the board reports.
//
// Three facts separate the three possible causes, and no argument does:
//   writes = 0            -- nothing updates it; the interrupt path is the fault
//   writes climb, r != w  -- it is written and read back wrong; the memory is
//   writes climb, r == w  -- the flag moves and the game is waiting on something else
logic [15:0] vbl_n;
logic        irq0_d;

// DOES THE BOARD EVER ENTER THE CODE THAT BUILDS GEOMETRY.
//
// Four entry points, each counted rather than sampled. The boot bench reaching
// the 3D pushes 31,667 matrices from 0x17a04; the board's 5,656 profiler
// samples contain NOTHING in 0x44a8-0x4c00, 0x1786c-0x17a00, 0x179b8 or
// 0x1780c, which is that whole call chain. Zero out of 5,656 is strong, but it
// is an absence in a sample and this question has cost enough to deserve an
// answer that cannot be wrong.
//
// EQUALITY ON THE IP, NOT AN INDEXED ARRAY. The first version of this set one
// bit of a 32-bit register per 4 KB page, indexed by ip[16:12]. That is the
// same shape as the ipring read this file already refuses to wire up, and it
// failed the same way: quartus_fit took a Segment Violation AT THE START of the
// fit on three seeds out of four (1720, 1721, 1723), and the one that survived
// lost timing outright at -0.428. Four comparators and four counters cost a
// fraction of it and answer the same question.

// IS THE 3D TASK EVER REGISTERED, AND IS IT EVER DISPATCHED.
//
// Function 0x1838, one of the five the main loop calls every frame, walks a
// list of per-frame tasks:
//
//     0x1854  ld    r4, 0x000(g13)      ; this entry's flag word
//     0x1858  bbc   31, r4, 0x1864      ; bit 31 CLEAR -> skip
//     0x185c  ld    r5, 0x00c(g13)      ; the handler pointer
//     0x1860  callx r0, (r5)            ; -> 0x5890 -> 0x16e58 -> 0x17a04
//
// 45,260 board samples put 256 in 0x1854 and 32 in 0x1860, so the walker runs
// AND dispatches: other tasks are enabled and called every frame. What it never
// reaches is 0x5890 -- zero samples there and zero in every function below it.
//
// The 3D task is registered at 0x1bf8-0x1c14, which runs ONCE:
//
//     0x1bf8  ld   r3, [0x00501284]     ; pointer to the entry
//     0x1c08  st   r5, 0x000(r3)        ; flag word, enable bit set
//     0x1c14  st   r5, 0x00c(r3)        ; handler = 0x5890
//
// A one-shot cannot be seen by a 1-in-65536 sample -- that mistake was made
// twice today, on 0x172c and again on 0x1c0c -- so it is COUNTED. tw_1c14 at
// zero means the board never registers the task and the fault is upstream of
// the list; non-zero with tw_5890 at zero means it registers and never runs.
logic  [7:0] state_last, n_state2, n_state_wr;
logic  [7:0] tw_1854, tw_1860, tw_5890, tw_1c14;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		lc_cnt <= 32'hEEEE_EEEE; lc_base <= 32'hEEEE_EEEE;
		lc_wdat <= 32'hEEEE_EEEE; lc_wbe <= 32'hEEEE_EEEE;
		sd_seen <= 32'hEEEE_EEEE; sdw_d <= 1'b0; sdwa_d <= '0;
		sdwd_d <= 16'd0; sdwb_d <= 2'd0;
		cack_d <= 1'b0; cwe_d <= 1'b0; caddr_d <= 32'd0; crd_d <= 32'd0;
		cwd_d <= 32'd0; cbe_d <= 4'd0;
		cip_d <= 32'd0; wk_last_desc <= 32'hEEEE_EEEE; sk_cnt <= 32'hEEEE_EEEE; sk_ptr <= 32'hEEEE_EEEE;
		wk_last_hdl <= 32'hEEEE_EEEE; wk_cnt_init <= 32'hEEEE_EEEE; wk_cnt_last <= 32'hEEEE_EEEE;
		mb_rdback <= 32'hEEEE_EEEE; mb_req_cnt <= 6'd0; mb_ack_cnt <= 6'd0; mb_ack_d <= 1'b0;
		e140_w0 <= 32'hEEEE_EEEE; e140_hdl <= 32'hEEEE_EEEE; e140_cnt <= 16'd0;
		e13_size <= 32'hEEEE_EEEE; e13_wr_ip <= 32'hEEEE_EEEE; e13_wr_dat <= 32'hEEEE_EEEE; e13_hdl_n <= 12'd0;
		vbl_n <= 16'd0; irq0_d <= 1'b0;
		state_last <= 8'hEE; n_state2 <= 8'd0; n_state_wr <= 8'd0;
		tw_1854 <= 8'd0; tw_1860 <= 8'd0; tw_5890 <= 8'd0; tw_1c14 <= 8'd0;
	end else begin
		cack_d  <= cpu_ack;
		cwe_d   <= cpu_we;
		caddr_d <= cpu_addr;
		crd_d   <= cpu_rdata;
		cwd_d   <= cpu_wdata;
		cbe_d   <= cpu_be;
		cip_d   <= cpu_dbg_ip;
		// The walker's `ld r4, 0(g13)` at 0x1854 has g13 as its address, so the
		// address of that load IS the descriptor. IP-keyed, one cycle behind the
		// bus like everything else here; the core sits in T_MEM_W at that IP
		// until the ack, so the pairing holds.
		if (cack_d && !cwe_d && cip_d == 32'h0000_1854 && caddr_d[31:20] == 12'h005)
			wk_last_desc <= caddr_d;
		// The skip handler runs in the 0x220000 mirror: `st r3, 0x5011fc` at
		// 0x220104 and `ld 0x501260` at 0x2200e4.
		if (cack_d && cwe_d && caddr_d == 32'h0050_11fc && cip_d == 32'h0022_0104)
			sk_cnt <= cwd_d;
		if (cack_d && !cwe_d && caddr_d == 32'h0050_1260)
			sk_ptr <= crd_d;
		if (cack_d && !cwe_d && cip_d == 32'h0000_185c && caddr_d[31:20] == 12'h005)
			wk_last_hdl <= crd_d;
		if (cack_d && !cwe_d && cip_d == 32'h0000_1844)
			wk_cnt_init <= crd_d;
		if (cack_d && cwe_d && cip_d == 32'h0000_1870 && caddr_d == 32'h0050_11fc)
			wk_cnt_last <= cwd_d;
		// The CPU's read of the mailbox dword, as the bus delivered it.
		if (cack_d && !cwe_d && caddr_d == 32'h0091_fff0)
			mb_rdback <= crd_d;
		if (cack_d && !cwe_d && cip_d == 32'h0000_1854 && caddr_d == 32'h0051_0F80) begin
			e140_w0 <= crd_d;
			if (!(&e140_cnt)) e140_cnt <= e140_cnt + 16'd1;
		end
		if (cack_d && !cwe_d && cip_d == 32'h0000_185c && caddr_d == 32'h0051_0F8C)
			e140_hdl <= crd_d;
		if (cack_d && !cwe_d && cip_d == 32'h0000_1880 && caddr_d == 32'h0050_4E08)
			e13_size <= crd_d;
		if (cack_d && cwe_d && caddr_d[31:2] == 30'(32'h0050_4E08 >> 2)) begin
			e13_wr_ip <= cip_d; e13_wr_dat <= cwd_d;
		end
		if (cack_d && !cwe_d && cip_d == 32'h0000_185c && caddr_d == 32'h0050_4E0C)
			e13_hdl_n <= e13_hdl_n + 12'd1;
		// The TGP's request for the high half (rising edge, like tgp_bufw_count)
		// and the port acknowledge that retires it (rising edge of the held ack
		// while that request is the one on the mux).
		if (tgp_bufw_req && !tgp_bufw_d && tgp_bufw_addr == 19'h0FFF9)
			mb_req_cnt <= mb_req_cnt + 6'd1;
		mb_ack_d <= wr_ack_tgp;
		if (wr_ack_tgp && !mb_ack_d && tgp_bufw_addr_r == 19'h0FFF9)
			mb_ack_cnt <= mb_ack_cnt + 6'd1;
		if (cack_d && !cwe_d) begin
			if (caddr_d == 32'h0050_1084) lc_cnt  <= crd_d;
			if (caddr_d == 32'h0050_1224) lc_base <= crd_d;
		end
		// AND WHAT WAS WRITTEN THERE, WITH ITS BYTE ENABLES.
		//
		// The count reads back 0x27272727 where it should be 0x00000027 -- the
		// byte 0x27 smeared across all four lanes, and 0x27 is 39, exactly the
		// number of passes simulation makes. The i960 replicates a stored byte
		// across the word and relies on the ENABLES to pick a lane, so the
		// enables are the whole question:
		//
		//   data 27272727 be=1111 -> the game computed a bad value
		//   data 27272727 be=0001 -> the memory path ignored the enables
		//
		// Those are opposite faults and guessing between them costs a build.
		if (cack_d && cwe_d && caddr_d == 32'h0050_1084) begin
			lc_wdat <= cwd_d;
			lc_wbe  <= {28'd0, cbe_d};
		end
		// AND WHAT THE BRIDGE PRESENTS TO THE CONTROLLER FOR THAT WORD.
		//
		// The CPU writes 0x27272727 with be=0001 -- a byte store with the byte
		// replicated, which is what the i960 does -- and the word reads back
		// 0x27272727, so every lane was written. The bridge computes
		// sd_be = r_be[1:0], the x2 adapter passes it through, and the
		// controller drives sd_dqm = ~be. All three read correct in source, so
		// the disagreement is between the source and the silicon, and only a
		// measurement at the last unmeasured point can say which.
		sdw_d  <= cpu_sd_req && cpu_sd_we;
		sdwa_d <= cpu_sd_addr;
		sdwd_d <= cpu_sd_din;
		sdwb_d <= cpu_sd_be;
		if (sdw_d && sdwa_d == SDR_AW'(GAME_WORK + (32'h0010_84 >> 1))) begin
			sd_seen <= {sdwb_d, 6'd0, sdwd_d[7:0], sdwd_d[15:8]};
		end

		// THE ATTRACT STATE, as the dispatcher at 0x18a0 writes it. 0xEE is
		// "never written". Counted by equality against 2 -- the state whose
		// handler enables the 3D task -- never by an indexed array write: that
		// shape took a Segment Violation at the START of the fit on three seeds
		// out of four when it was tried as a page mask, exactly as the ipring
		// read in this file does.
		if (cack_d && cwe_d && caddr_d == 32'h0050_10a0) begin
			state_last <= cwd_d[7:0];
			if (!(&n_state_wr)) n_state_wr <= n_state_wr + 8'd1;
			if (cwd_d[7:0] == 8'd2 && !(&n_state2)) n_state2 <= n_state2 + 8'd1;
		end
		// The IP register is valid continuously, so an equality test cannot miss
		// an entry the way a 1-in-65536 sample can, and 0x1c14 is a ONE-SHOT --
		// sampling it was tried twice today and is worthless. Saturating,
		// because "did it ever" is the question and a wrap would answer wrongly.
		if (cpu_dbg_ip == 32'h0000_1854 && !(&tw_1854)) tw_1854 <= tw_1854 + 8'd1;
		if (cpu_dbg_ip == 32'h0000_1860 && !(&tw_1860)) tw_1860 <= tw_1860 + 8'd1;
		if (cpu_dbg_ip == 32'h0000_5890 && !(&tw_5890)) tw_5890 <= tw_5890 + 8'd1;
		if (cpu_dbg_ip == 32'h0000_1c14 && !(&tw_1c14)) tw_1c14 <= tw_1c14 + 8'd1;
		// AND WHETHER THE INTERRUPT THAT SHOULD MOVE IT ARRIVES AT ALL.
		irq0_d <= cpu_irq[0];
		if (cpu_irq[0] && !irq0_d && !(&vbl_n)) vbl_n <= vbl_n + 16'd1;
	end
end
logic [14:0] tra_d1;
logic        tr_v;
logic [31:0] tr_ad, tr_dt;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		tra_d1 <= 15'd0; tr_v <= 1'b0; tr_ad <= 32'd0; tr_dt <= 32'd0;
	end else begin
		tra_d1 <= tram_addr;
		tr_v   <= (tra_d1 >= 15'h2000) && (tra_d1 < 15'h3000);
		if ((tra_d1 >= 15'h2000) && (tra_d1 < 15'h3000)) begin
			tr_ad <= {17'd0, tra_d1};
			tr_dt <= {16'd0, tram_data};
		end
	end
end
logic [15:0] fold_xor [4];
logic [31:0] fold_sum [4];
logic [15:0] fold_min [4];
logic [15:0] fold_max [4];
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		for (int i = 0; i < 4; i++) begin
			fold_xor[i] <= 16'd0; fold_sum[i] <= 32'd0;
			fold_min[i] <= 16'hFFFF; fold_max[i] <= 16'd0;
		end
	end else if (ocb_tram_we && |ocb_din && ocb_addr < 15'h4000) begin
		fold_xor[ocb_addr[13:12]] <= fold_xor[ocb_addr[13:12]] ^ ocb_din;
		fold_sum[ocb_addr[13:12]] <= fold_sum[ocb_addr[13:12]] + {16'd0, ocb_din};
		if (ocb_din < fold_min[ocb_addr[13:12]]) fold_min[ocb_addr[13:12]] <= ocb_din;
		if (ocb_din > fold_max[ocb_addr[13:12]]) fold_max[ocb_addr[13:12]] <= ocb_din;
	end
end
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		mapnz[0] <= 32'd0; mapnz[1] <= 32'd0;
		mapnz[2] <= 32'd0; mapnz[3] <= 32'd0;
		mapreal[0] <= 32'd0; mapreal[1] <= 32'd0;
		mapreal[2] <= 32'd0; mapreal[3] <= 32'd0;
	end else if (ocb_tram_we && |ocb_din && ocb_addr < 15'h4000) begin
		mapnz[ocb_addr[13:12]] <= mapnz[ocb_addr[13:12]] + 32'd1;
		// REAL CONTENT, BY THE RENDERER'S OWN RULE. tw_nonblank counts a tile
		// only if it is non-zero AND not 0x20, the SPACE character -- so a map
		// full of spaces is "non-zero" and still draws nothing. Splitting the
		// count says whether the game composed a picture or wrote blanks, which
		// "non-zero" alone cannot.
		if ((ocb_din & 16'h3fff) != 16'h0020)
			mapreal[ocb_addr[13:12]] <= mapreal[ocb_addr[13:12]] + 32'd1;
	end
end
logic [15:0] scr_h0, scr_h1, scr_v0, scr_v1;
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		scr_h0 <= 16'd0; scr_h1 <= 16'd0; scr_v0 <= 16'd0; scr_v1 <= 16'd0;
	end else if (ocb_tram_we) begin
		if (ocb_addr == 15'h5000) scr_h0 <= ocb_din;
		if (ocb_addr == 15'h5001) scr_h1 <= ocb_din;
		if (ocb_addr == 15'h5004) scr_v0 <= ocb_din;
		if (ocb_addr == 15'h5005) scr_v1 <= ocb_din;
	end
end
wire [15:0] vid_ctrl [2];
wire        cpu_char_wr;        // the CPU wrote a glyph
wire [17:0] cpu_char_wr_addr;   // and this is which one
wire        char_req, char_ack;
wire [17:0] char_addr;
wire [31:0] char_data;

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
always_ff @(posedge clk_sys or negedge mem_rst_n) begin
	if (!mem_rst_n) begin
		cd_last <= 32'd0; cd_ff <= 16'd0;
	end else if (char_ack) begin
		cd_last <= char_data;
		if ((&char_data) && !(&cd_ff)) cd_ff <= cd_ff + 16'd1;
	end
end

// THE GLYPH CACHE SITS IN FRONT OF THE FETCH. Measured on a boot through the
// menu and into attract: 71.6 M fetches serving 7,883 distinct words -- 9,084x
// redundancy -- against a 985 KB address span far too large to hold outright.
// 64 KB of on-chip storage covers the 30.8 KB actually touched with room for
// gameplay, at ~59 M10K of the 241 free. Its own testbench measures 96.7% on
// the real glyph access shape and returns correct data under deliberate
// conflict thrashing.
//
// It also buys back what the 3D renderer will want: the fetches it absorbs are
// SDRAM transactions that no longer cross the arbiter or occupy a slow port.
wire        cache_m_req, cache_m_ack;
wire [17:0] cache_m_addr;
wire [63:0] cache_m_data;

// The answer side of port 3, straight back to the cache. m2_sdram_x2 holds the
// acknowledge while the request stands and bypasses s_dout on the acknowledge
// cycle, so both are valid on the edge m2_char_cache captures them.
assign cache_m_ack  = p_ack[3];
assign cache_m_data = p_dout[3];
wire [31:0] char_hits, char_misses;

// IDX_BITS 14 -- 128 KB. REDUCED TO 13 AND REVERTED, ON HARDWARE EVIDENCE.
//
// The paragraph above says "64 KB of on-chip storage covers the 30.8 KB
// actually touched", so 14 looked like a parameter that had drifted from its
// own rationale, and halving it gave back 51 M10K blocks -- 553/553 to 502/553,
// the first block-memory headroom this design has had.
//
// THE BOARD SAYS OTHERWISE. At 64 KB, the board shows tile and glyph overruns: the
// extra misses become SDRAM fetches that do not finish before the next
// scanline starts, the bank does not flip, and the previous line is shown
// again. That is exactly the failure the fetch engine's overrun counter exists
// to catch, and it is visible on screen.
//
// So the 30.8 KB figure does not bound what the cache needs. It was measured on
// a boot through the menu into attract; the working set with real scenes is
// evidently larger, and the margin between 30.8 KB and 128 KB was doing work
// rather than sitting idle. The rationale was right about the measurement and
// wrong about the conclusion drawn from it.
//
// M10K stays at 553/553 and has to be found somewhere else. m2_raster3d's 113
// blocks -- three band buffers where two may do -- is the next candidate, and
// unlike this one it can be reasoned about from the buffer count rather than
// from a hit-rate guess.
m2_char_cache #(.IDX_BITS(14)) u_char_cache (
	.clk(clk_sys), .rst_n(cc_rst_n_s),
	.v_req(char_req), .v_addr(char_addr),
	.v_ack(char_ack), .v_data(char_data),
	.m_req(cache_m_req), .m_addr(cache_m_addr),
	.m_ack(cache_m_ack), .m_data(cache_m_data),
	// The invalidate index is the cache's index field, so it narrows with
	// IDX_BITS: [14:2] for 13 bits, not [15:2]. A stale width here invalidates
	// the wrong line on a CPU character write, which shows up as glyphs that
	// are correct until the game rewrites one and then stay stale.
	.inval(cpu_char_wr), .inval_idx(cpu_char_wr_addr[15:2]),
	.dbg_hits(char_hits), .dbg_misses(char_misses)
);

// THE CROSSING IS GONE, and it was not harmless.
//
// It was `m2_char_cdc` with clk_vid and clk_sys BOTH tied to clk_sys -- a
// clock-domain crossing this file invented against itself. The comment that
// stood here called it "harmless, proven". It was proven; it was not harmless.
//
// WHAT IT COST, per character fetch: req_sync is two clk_sys edges before the
// memory side even sees the request, done_sync plus done_q is two more before
// the cache sees the answer, and S_ACK cannot retire until v_req drops and
// re-synchronises. Six cycles, every miss, for a metastability hazard that
// cannot exist on one clock edge. Immediately below this is the line-overrun
// counter and m2_video's own note that an overrun redisplays the previous line
// -- six cycles a fetch is how a scanline runs out of time.
//
// AND THE STATE MACHINE WAS DUPLICATING m2_sdram_x2. The adapter already turns
// a held request into exactly one transaction (`f_req = s_req & ~done &
// ~f_ack`), already holds the acknowledge while the request stands (R162's
// sticky ack), and already bypasses s_dout on the acknowledge cycle so the data
// is valid beside it. m2_char_cache holds m_req until m_ack and drops it on the
// same edge it captures m_data, which is precisely the requester that contract
// is written for. So the two ends speak the same protocol and the translator
// between them was translating nothing.
//
// Direct-wired below at the port-3 assignment. If the video ever moves to
// clk_mem this must come back -- rtl/mem/m2_char_cdc.sv is kept for that, and
// R199 records why.

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
wire [15:0] vid_hscr [4], vid_vscr [4];
wire [15:0] vid_overruns;
wire [15:0] vid_ovr_frame;   // overruns in the LAST FRAME

wire [7:0] tile_r, tile_g, tile_b;
wire [9:0] vid_x, vid_y;

// ------------------------------------------------------------ THE 3D LAYER
//
// m2_raster3d: quad_store sorts and replays per band, raster_fill turns a quad
// into spans, and three band buffers are filled and displayed in rotation. All
// of it is Model 1's, verified upstream over 152,025 quads and 31.6 M spans;
// the sequencer around it is ours. See THIRD_PARTY.md and study R124.
//
// THE QUAD INPUT IS CONNECTED. m2_geometry above walks each object out of the
// polygon ROM, transforms and focuses its vertices, clips them to the screen
// and hands them here already in pixels. q_end pulses when the display-list
// walk finishes, which is what releases the producer from P_COLLECT into the
// sort -- without it quads accumulate and nothing ever draws.
//
// Flat colour, no texture, no lighting: shape first.
wire [15:0] r3d_col;
wire        r3d_hit;
wire [15:0] r3d_quads, r3d_dropped, r3d_bands, r3d_tiny;
wire [31:0] r3d_pixels;

// TWO_CLOCKS(0): clk and scan_clk below are BOTH clk_sys, so every synchroniser
// in this module would be a crossing it invents against itself -- six cycles of
// added latency in the renderer whose entire problem is finishing a band before
// the beam reaches it. Set it to 1 the moment the video moves to clk_mem.
// 8-ROW BANDS, 48 OF THEM (R213): what Model 1 settled on. Halves the three
// band buffers (the M10K that the second quad-store bank needs) and paces
// the fill twice as finely against the beam.
// FOUR BUFFERS: Model 1's "band ahead" with its 48 bands. build/dbuf5 with
// four ran out of M10K blocks where three fit; the quad store now shares its
// sort key and scratch index between the banks (~8 blocks), which pays for it.
m2_raster3d #(.SCR_W(496), .SCR_H(384), .BAND_H(8), .NBUF(4),
              .TWO_CLOCKS(1'b0)) u_raster3d (
	.clk(clk_sys), .rst_n(mem_rst_n),
	.frame_start(geo_walk_start),
	// Each bar is a proper filled rectangle traversed around its perimeter:
	// (x0,y0) top-left, (x0,y2) bottom-left, (x2,y2) bottom-right,
	// (x2,y0) top-right -- the same v0..v3 cycle the geometry engine emits.
	.q_valid(q3d_valid), .q_ready(q3d_ready),
	.q_x0(q3d_x0), .q_y0(q3d_y0),
	.q_x1(q3d_x1), .q_y1(q3d_y1),
	.q_x2(q3d_x2), .q_y2(q3d_y2),
	.q_x3(q3d_x3), .q_y3(q3d_y3),
	.q_col(q3d_col), .q_z(q3d_z),
	.q_moire(1'b0), .q_end(q3d_end),
	.scan_clk(clk_sys), .scan_x(vid_x), .scan_y(vid_y),
	.scan_col(r3d_col), .scan_hit(r3d_hit),
	.dbg_quads(r3d_quads), .dbg_dropped(r3d_dropped), .dbg_tiny(r3d_tiny),
	.dbg_bands(r3d_bands), .dbg_pixels(r3d_pixels),
	.dbg_ready_cyc(r3d_ready_cyc), .dbg_bands_done(r3d_bands_done),
	.dbg_late_frames(r3d_late_frames), .dbg_qend_frames(r3d_qend_frames),
	.dbg_collect_cyc(r3d_collect_cyc), .dbg_hold(r3d_hold), .dbg_missed(r3d_missed)
);

// The 3D layer sits OVER the tilemap where it painted, and shows the tilemap
// where it did not -- rd_hit is exactly that question, and the band buffer
// answers it per pixel. RGB565 out of the band, widened by replicating the top
// bits so full-scale stays full-scale.
wire [7:0] r3d_r8 = {r3d_col[15:11], r3d_col[15:13]};
wire [7:0] r3d_g8 = {r3d_col[10:5],  r3d_col[10:9]};
wire [7:0] r3d_b8 = {r3d_col[4:0],   r3d_col[4:2]};
// Priority-bit tiles (the UI) stay over the 3D; everything else goes under it (R213).
wire       tile_cat1;
wire [7:0] mix_r  = (r3d_hit && !tile_cat1) ? r3d_r8 : tile_r;
wire [7:0] mix_g  = (r3d_hit && !tile_cat1) ? r3d_g8 : tile_g;
wire [7:0] mix_b  = (r3d_hit && !tile_cat1) ? r3d_b8 : tile_b;
wire       tile_hs, tile_vs, tile_hb, tile_vb;

// THE VIDEO DOMAIN'S RESET, ASYNC ASSERT AND SYNCHRONOUS RELEASE.
//
// m2_video and the character cache take a reset built from mem_rst_n, cp_done
// and cal_done. Asserting late is harmless. RELEASING on an edge that is not
// synchronous to the clock the module runs on lets its registers leave reset on
// different cycles, which is a real fault and not a timing number.
//
// Those signals are in this same domain today, so this is dormant here -- it is
// correct by construction for when the video moves to the memory clock, which is
// planned. The cost is two cycles of release latency on a reset that already
// waits for a ROM load.
logic [1:0] vid_rst_sync, cc_rst_sync;
wire vid_rst_src = mem_rst_n & cp_done & cal_done;
wire cc_rst_src  = mem_rst_n & cp_done;
always_ff @(posedge clk_sys or negedge vid_rst_src) begin
	if (!vid_rst_src) vid_rst_sync <= 2'b00;
	else              vid_rst_sync <= {vid_rst_sync[0], 1'b1};
end
always_ff @(posedge clk_sys or negedge cc_rst_src) begin
	if (!cc_rst_src) cc_rst_sync <= 2'b00;
	else             cc_rst_sync <= {cc_rst_sync[0], 1'b1};
end
wire vid_rst_n_s = vid_rst_sync[1];
wire cc_rst_n_s  = cc_rst_sync[1];

m2_video u_tilemap (
		// cal_done too: on a GAME image game_image short-circuits cp_done without
	// reading anything, so the character fetch on port 3 would otherwise issue
	// at CL+0 until the calibration caught up. Those are live re-reads rather
	// than a latched copy, so it corrected itself -- but it is the last reader
	// that was not waiting, and "it fixes itself" is not a reason to leave one.
	.clk(clk_sys), .ce_pix(ce_pix), .rst_n(vid_rst_n_s),
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
	.vid_cat1(tile_cat1), .vid_r(tile_r), .vid_g(tile_g), .vid_b(tile_b),
	.vid_hs(tile_hs), .vid_vs(tile_vs), .vid_hb(tile_hb), .vid_vb(tile_vb),
	.vblank_irq(), .dbg_fetches(vid_fetches), .dbg_overruns(vid_overruns),
	.dbg_hscr(vid_hscr), .dbg_vscr(vid_vscr),
	.dbg_ovr_frame(vid_ovr_frame),
	.vid_x(vid_x), .vid_y(vid_y),
	.dbg_layer_px(vid_layer_px), .dbg_ctrl(vid_ctrl),
	.dbg_layer_have(vid_layer_have)
);

///////////////////////   VIDEO   ////////////////////////////////

// THE SECOND m2_video_timing INSTANCE IS GONE, and with it every wire that
// existed only to feed it.
//
// m2_video has always run its own generator -- the one the picture is actually
// built from -- so this was a duplicate free-running counter whose hs, vs,
// hblank and vcnt outputs had exactly two references each in this file: the
// declaration and the port map. Nothing read them. `vbs` had none at all.
//
// Its last real consumer was the frame interrupt, and R199 fault 4 moved that
// to tile_vb; rewiring the interrupt left the generator itself behind. What
// remains of it is frame_ctr, which the overlay reads, and that now counts the
// same vblank the interrupt does rather than a second opinion about when a
// frame ends.


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

// FRAME COUNTER, off the picture's own vblank.
//
// The line and visible-pixel counters that used to live here are gone with the
// duplicate generator. They existed to prove m2_video_timing produced MAME's
// 424 lines and 496 visible pixels, they proved it on hardware, and
// sim/video/tb_m2_video_timing.cpp asserts both every run. A measurement that
// has been made and is re-made by the bench does not need to stay in the
// silicon.
//
// frame_ctr stays because the overlay reads it as a liveness digit, and it now
// increments on tile_vb -- m2_video's vid_vb, the same edge the frame interrupt
// uses. One source of truth for when a frame ends.
reg [31:0] frame_ctr;
reg        vbl_ov_d;

always @(posedge clk_sys) begin
  if (!mem_rst_n) begin
    frame_ctr <= 0; vbl_ov_d <= 1'b0;
  end else begin
    vbl_ov_d <= tile_vb;
    if (tile_vb && !vbl_ov_d) frame_ctr <= frame_ctr + 1'd1;
  end
end

wire [7:0] ov_r, ov_g, ov_b;

// DEBUG IS DEVELOPMENT SCAFFOLDING, AND IT IS NOT FREE: m2_diag is 443.5 ALM
// and m2_dbg_stream is 182.9, so 626 ALM of a 41,910 ALM part is spent on
// instruments a build that only plays the game does not need.
//
// It stays IN THE SOURCE and ON BY DEFAULT. The standing rule in docs/ -- "the
// screen is the only output channel ... build the debug overlay early" -- was
// written when nothing else could reach a cabinet, and it is why the overlay
// exists at all. That premise is now false: UART reaches /dev/ttyS1 over ssh
// with no cable, and R136, R138 and R139 were all established from it. So the
// rule's conclusion is amended rather than dropped -- see R140. Turn the
// instruments off for an area-constrained build, not because they stopped
// earning their place.
//
//     set_global_assignment -name VERILOG_MACRO "M2_NO_DEBUG=1"
`ifdef M2_NO_DEBUG
localparam bit DEBUG = 1'b0;
`else
localparam bit DEBUG = 1'b1;
`endif

// AND THE TWO INSTRUMENTS ARE NOW SEPARATELY SWITCHED, because the design
// stopped fitting and they are not worth the same.
//
// The geometry pipeline is 5,500 ALUTs and it took the fitter from 79% to over
// the edge: "requires 4220 LABs, the device contains only 4191". Something had
// to go, and the overlay is the one whose premise has already expired -- the
// standing rule that "the screen is the only output channel" was written when
// nothing else could reach a cabinet, and R140 amended it when UART reached
// /dev/ttyS1 over ssh. Every finding since R136 came off the UART, not the
// screen.
//
// So m2_diag (443.5 ALM) goes and m2_dbg_stream (182.9 ALM) STAYS. Turning off
// M2_NO_DEBUG would have taken both, and the UART is the only instrument that
// can answer the question the next build exists to ask -- which memory the
// display list's objects point at.
//
//     set_global_assignment -name VERILOG_MACRO "M2_NO_OVERLAY=1"
`ifdef M2_NO_OVERLAY
localparam bit OVERLAY = 1'b0;
`else
localparam bit OVERLAY = DEBUG;
`endif

// The overlay runs on clk_vid and these all live on clk_sys or clk_i960, so
// they cross with two flops. They are status bits and counters read by eye --
// a torn counter is a wrong digit for one frame, not a wrong decision.
logic [2:0] game_sync, cp_done_sync, cpu_trap_sync, cpu_halt_sync;
logic [SDR_AW:1] ldr_top_sync;
always_ff @(posedge clk_sys) begin
	game_sync     <= {game_sync[1:0],     game_image};
	cp_done_sync  <= {cp_done_sync[1:0],  cp_done};
	cpu_trap_sync <= {cpu_trap_sync[1:0], cpu_trap};
	cpu_halt_sync <= {cpu_halt_sync[1:0], cpu_halted};
	ldr_top_sync  <= ldr_top;
end

generate if (OVERLAY) begin : g_diag
m2_diag #(.NWORDS(24)) u_diag
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.rst_n(mem_rst_n),
	.enable(status[19]),
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
	.words({ // 23 TRAM cell probe -- except Probe=chr0, which shows the backup
	         // SRAM dword at byte 0x14: the settings the digits are printed
	         // from. Sim reads 00030300 there and prints '3'.
	         // Probe=chr0: live settings dword. Probe=row2: {read count,
	         // low 24 bits of the FIRST value the game read from it this boot}
	         // -- FF...FF means the draw consumed uninitialised settings.
	         // 23 is now {total read count, read #(Probe+1) of the settings
	         // dword, low 24 bits}. Step Probe 0..7 to walk the sequence.
	         // 23: page 0 (O18=0): {reads, read #(Probe) captured}. Page 1,
	         // Probe 0-3: reads #8-11 -- the board's draw-read is #9. Page 1,
	         // Probe 6: live word 4 (coin-mode bytes 0x10-0x13). Page 1,
	         // Probe 7: live word 5 (settings dword).
	         // page1/Probe5: {writes-to-'3'-byte count, last data} -- the
	         // formatter's own store, caught at the SDRAM port.
	         // page1/Probe4: {reset edges, Z80 window writes, last window
	         // address} -- the collision telemetry and the reset counter.
	         // PAGE 0 IS THE TRAM CELL, WHICH IS WHAT THE PROBE NAMES HAVE
	         // ALWAYS SAID AND WHAT THIS ROW HAS NEVER SHOWN. tp_q was
	         // declared, clocked off tram[tp_cell] and then wired to nothing
	         // when this mux was repurposed to walk the settings dword, so
	         // every "chr N" reading taken from this row was in fact the
	         // backup SRAM's first-read value under a character's name. The
	         // cell index rides along in the top half so a reading can never
	         // again be attributed to the wrong cell: 0469C033 is cell 1129
	         // holding C033. Right value + glyph absent on screen = the
	         // render path drops the CELL; wrong value = the CPU's write
	         // never landed. Page 1 keeps the backup and collision telemetry
	         // exactly as it was.
	         // Page 1 / Probe 0 (bootIP): the cabinet-switch diagnostic above,
	         // {raw in0, the byte the firmware deposited, scan count}. It
	         // displaces the settings read #8, which the exchange's
	         // exoneration (R64) made the least useful thing on this row.
	         (status[18] && status[16:14] == 3'd0) ?
	             {iob_in0, dp08_latch, dp08_wr_cnt} :
	         // Page 1 / Probe "chr 3": the settings bytes as the Z80 writes
	         // them. 00030300 matches MAME and exonerates the window;
	         // 7FFF7FFF is the RAM-test pattern clobbering the deposit.
	         // Page 1 / Probe "chr 1": WHO BLANKED THE PROBED CELL -- the IP
	         // of the instruction that wrote a space into it. Probe "chr #"
	         // gives the count and the value, so a zero count means the cell
	         // was never blanked by a write and the fault is in the render.
	         // Page 1 / Probe "chr A" was the saturating window counter and
	         // said nothing; it now carries the char-write count and the last
	         // address the CPU wrote in the char region.
	         (status[18] && status[16:14] == 3'd4) ? {cw_cnt, 7'd0, cw_last[24:16]} :
	         // Page 1 / Probe "bndry": where the renderer is actually fetching.
	         // Compare against GAME_CHAR = 0x1690000.
	         (status[18] && status[16:14] == 3'd6) ? {7'd0, cf_addr} :
	         (status[18] && status[16:14] == 3'd2) ? blank_ip :
	         (status[18] && status[16:14] == 3'd3) ?
	             {8'd0, blank_cnt, blank_val} :
	         (status[18] && status[16:14] == 3'd1) ? zw_set :
	         (status[18] && status[16:14] == 3'd4) ?
	             {rst_edges, zw_win_cnt, 5'd0, zw_last} :
	         (status[18] && status[16:14] == 3'd5) ? {8'd0, vsw_cnt, vsw_data} :
	         (status[18] && status[16:14] >= 3'd6) ? bak_dbg_q :
	         status[18] ? bak_first : {1'b0, tp_cell, tp_q},
	         // 22 THE LAST CHARACTER FETCH, verbatim. FFFFFFFF means the fetch is
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
	          // bits 7:6 -- the I/O firmware: bit 7 = fw_ready (Z80 out of
	          // reset), bit 6 = at least one firmware byte arrived. 00 here
	          // with a black screen means the MRA's rom index 3 never came.
	          4'd0, fw_ready, fw_seen, pll_locked, 1'b1},   // 4  status
	         {7'd0, ldr_top_sync},                      // 3  highest word loaded
	         rb_w0,                                     // 2  readback of words 6/7, want 00000860
	         frame_ctr,                                 // 1  liveness
	         32'hB0ADCAFE }),                           // 0  magic
	// Until the copy engine has filled tile RAM and the palette there is
	// nothing to draw, so the test pattern stands in. After that the tilemap
	// takes over. Seeing the pattern persist therefore means the copy never
	// finished, which is a different failure from a tilemap that draws nothing.
	.in_r(mix_r),
	.in_g(mix_g),
	.in_b(mix_b),
	.out_r(ov_r), .out_g(ov_g), .out_b(ov_b)
);
end else begin : g_nodiag
	// m2_diag is a pass-through filter, so its absence is a wire.
	// THE TEST PATTERN IS GONE. A boot-time image the game never shows, and the
	// critical path of the whole design: a combinational divide by 62 off hcnt,
	// through the colour mux and straight out to the pin, about 22 ns of it.
	// That fits a 20 ns period at 50 MHz by a whisker, which is why this design
	// has sat near -0.2 ns setup for weeks. The 3D test bars on O[21] do the same
	// job, and if the boot copy stalls the screen is black, which is its own
	// diagnosis.
	assign ov_r = mix_r;
	assign ov_g = mix_g;
	assign ov_b = mix_b;
end endgenerate

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;

assign VGA_DE = ~(tile_hb | tile_vb);
assign VGA_HS = tile_hs;
assign VGA_VS = tile_vs;
assign VGA_R  = ov_r;
assign VGA_G  = ov_g;
assign VGA_B  = ov_b;

endmodule
