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
// Video timing, from MAME's screen configuration in model1.cpp:
//
//   m_screen->set_raw(XTAL(16'000'000), 656, 0, 496, 424, 0, 384);
//
// 16 MHz pixel clock, 656 total columns of which 496 are visible, 424 total
// lines of which 384 are visible. That gives 16e6 / (656 * 424) = 57.52 Hz,
// which is the refresh the whole core has to hit — the tilemap fetch budget in
// m1_tile_fetch.sv is derived from the 656-clock line this defines.
//
// WHERE THE SYNC PULSES SIT IS NOT FROM MAME
//
// `set_raw` specifies the total and the visible window; it says nothing about
// where inside the blanking interval the sync pulses go, because MAME does not
// need to know. A real display does, so the positions below are chosen rather
// than derived, and are parameters so they can be corrected against a real
// board or a service-mode geometry screen without touching logic.
//
// The totals and the visible window ARE from MAME and must not be adjusted to
// make a monitor happy: they set the frame rate, and a core that runs at the
// wrong rate has audio that drifts and scrolling that tears in ways that look
// like unrelated bugs.

// LIFTED FROM THE MODEL 1 CORE, UNCHANGED except for the module name and these
// comments. Source: sega-model1-mister rtl/video/m1_video_timing.sv at f48c842.
// Recorded in THIRD_PARTY.md.
//
// It transfers with NO retiming, which was not expected -- docs/milestones.md
// carried "retimed to 496x384" until this was checked. MAME declares the two
// machines identically:
//
//   Model 1: set_raw(XTAL(16'000'000),  656, 0, 496, 424, 0, 384)
//   Model 2: set_raw(32_MHz_XTAL/2,     656, 0, 496, 424, 0, 384)
//
// Same pixel clock, same totals, same visible window. 16e6 / (656 * 424) =
// 57.52 Hz.

`timescale 1ns/1ps

module m2_video_timing #(
  parameter int unsigned H_TOTAL   = 656,   // MAME set_raw
  parameter int unsigned H_VISIBLE = 496,   // MAME set_raw
  parameter int unsigned V_TOTAL   = 424,   // MAME set_raw
  parameter int unsigned V_VISIBLE = 384,   // MAME set_raw

  // Chosen, not derived. See the note above.
  parameter int unsigned H_SYNC_START = 520,
  parameter int unsigned H_SYNC_END   = 584,
  parameter int unsigned V_SYNC_START = 392,
  parameter int unsigned V_SYNC_END   = 395,
  // R682: 15 kHz INTERLACED, for a 15 kHz CRT. The same 656-pixel line (the
  // pixel clock is what changes: 547/5300 of 100 MHz), 57.52 fields a second
  // -- the game's own rate -- of 274 and 273 lines (547 a frame, 15,734 Hz),
  // each showing 192 of the 384 lines: field 0 the even, field 1 the odd.
  // Field 1's vsync starts half a line in, which is what interlaces.
  parameter int unsigned VI_TOTAL0     = 274,
  parameter int unsigned VI_TOTAL1     = 273,
  parameter int unsigned VI_VISIBLE    = 192,
  // R701: 229-232, not 220-223: 220 left 51 lines between vsync and the top
  // of the picture, far more than a TV expects, and Ben's CRT showed the big
  // border at the top that follows. 229 splits the 82 blanking lines so the
  // 192 visible sit centred in a TV's 240.
  parameter int unsigned VI_SYNC_START = 229,
  parameter int unsigned VI_SYNC_END   = 232
) (
  input  logic       clk,        // 16 MHz pixel clock enable domain
  input  logic       ce_pix,
  input  logic       rst_n,
  input  logic       interlace,  // R682: held; changed only by the OSD (resync is expected)

  output logic [9:0] hcnt,
  output logic [9:0] vcnt,
  output logic       hblank,
  output logic       vblank,
  output logic       hsync,
  output logic       vsync,
  output logic       visible,

  // Fires at the START of each line, naming the NEXT line, so a renderer has a
  // whole line period to fill its buffer.
  //
  // The first version fired at the start of horizontal blanking instead, on
  // the reasoning that a renderer should work during blanking. Blanking is 160
  // dot clocks — 960 core cycles — and four layers need 2,796 even on repeated
  // tiles, so rendering ran on into the line it was supposed to be displaying
  // and the picture was a mixture of two lines. A whole line period is 656 dot
  // clocks, 3,936 core cycles, which is the budget the tilemap fetch was
  // measured against.
  output logic       line_start,
  output logic [8:0] line_number,

  // Frame boundary, for the i960's vblank interrupt.
  output logic       vblank_start,
  output logic       field,       // R682: 0 even lines, 1 odd (0 when progressive)
  output logic [8:0] ypos         // R682: the logical line on screen (vcnt when progressive)
);

  // this field's line count and visible lines
  wire [9:0] vt  = !interlace ? 10'(V_TOTAL) : (field ? 10'(VI_TOTAL1) : 10'(VI_TOTAL0));
  wire [9:0] vv  = !interlace ? 10'(V_VISIBLE) : 10'(VI_VISIBLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt  <= '0;
      vcnt  <= '0;
      field <= 1'b0;
    end else if (ce_pix) begin
      if (hcnt == 10'(H_TOTAL - 1)) begin
        hcnt <= '0;
        if (vcnt == vt - 10'd1) begin
          vcnt  <= '0;
          field <= interlace ? ~field : 1'b0;
        end else vcnt <= vcnt + 10'd1;
      end else begin
        hcnt <= hcnt + 10'd1;
      end
    end
  end

  assign hblank  = (hcnt >= 10'(H_VISIBLE));
  assign vblank  = (vcnt >= vv);
  assign visible = !hblank && !vblank;

  assign hsync = (hcnt >= 10'(H_SYNC_START)) && (hcnt < 10'(H_SYNC_END));
  // R701: FIELD 1'S VSYNC RUNS FROM THE MIDDLE OF THE LINE BEFORE -- half a
  // line EARLY, not late. With fields of 274 and 273 lines the two vsync-to-
  // vsync intervals are equal (273.5) only if field 1's vsync sits at
  // VI_SYNC_START - 0.5; R682 put it at + 0.5, which made them 274.5 and 272.5
  // and set field 1's lines a line and a half below field 0's instead of half
  // a line -- on Ben's CRT, "does not look like it's interlacing".
  wire [19:0] vpos  = {vcnt, hcnt};
  wire        vs_i0 = (vcnt >= 10'(VI_SYNC_START)) && (vcnt < 10'(VI_SYNC_END));
  wire        vs_i1 = (vpos >= {10'(VI_SYNC_START - 1), 10'(H_TOTAL / 2)}) && (vpos < {10'(VI_SYNC_END - 1), 10'(H_TOTAL / 2)});
  assign vsync = !interlace ? ((vcnt >= 10'(V_SYNC_START)) && (vcnt < 10'(V_SYNC_END)))
                            : (field ? vs_i1 : vs_i0);

  // Fires on the LAST pixel of a line, so the buffer swap it triggers takes
  // effect exactly at the line boundary.
  //
  // `hcnt == 0` looks like the right condition and is one pixel too late: hcnt
  // is a register, so that test is true during the pixel in which hcnt already
  // holds 0, and a swap driven from it lands one pixel into the line. Column
  // zero is then read from the previous line's buffer — one wrong pixel down
  // the left edge of every line, with everything after it correct, which
  // reads as a fetch fault rather than a timing one.
  assign line_start = ce_pix && (hcnt == 10'(H_TOTAL - 1));

  // Two lines ahead, not one. At this instant the swap is about to make the
  // buffer written during the current line the one displayed on the next, so
  // the buffer being started now is the one after that.
  // The line rendered next: two display lines ahead. Interlaced, those are
  // this field's (2*(vcnt+2) + field) or, past its end, the next field's.
  wire [9:0] dl2   = vcnt + 10'd2;
  wire       wrapl = (dl2 >= vt);
  /* verilator lint_off UNUSEDSIGNAL */
  wire [9:0] dln   = wrapl ? dl2 - vt : dl2;   // < 274: bits 9:8 zero
  /* verilator lint_on UNUSEDSIGNAL */
  assign line_number = !interlace ? ((vcnt >= 10'(V_TOTAL - 2)) ? 9'(vcnt + 10'd2 - 10'(V_TOTAL))
                                                                 : 9'(vcnt + 10'd2))
                                  : {dln[7:0], field ^ wrapl};
  assign ypos = !interlace ? vcnt[8:0] : {vcnt[7:0], field};

  assign vblank_start = ce_pix && (hcnt == 10'(H_VISIBLE)) &&
                        (vcnt == vv - 10'd1);

endmodule
