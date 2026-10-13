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
// 2D video path: four tilemap layers, line buffered, mixed, palette mapped.
//
// STRUCTURE
//
// One fetch engine is instantiated, not four, and the four layers are rendered
// through it one after another into four line buffers. That is not a saving of
// three engines' worth of logic so much as a saving of arbitration: the
// character fetches all go to one SDRAM port, and four concurrent engines would
// need an arbiter in front of it whose only job would be to serialise them
// anyway. Sequential rendering makes the port, the tile RAM port and the decode
// datapath single-owner by construction.
//
// The cost is that the four layers' fetch times add rather than overlap, which
// is exactly the budget recorded in docs/m1-m4-plan.md: about 700 cycles per
// layer on repeated tiles against ~1025 available per layer, and about 1600 on
// entirely distinct ones. Text and menu screens fit; four dense layers do not.
//
// TIMING
//
// Everything runs on the core clock. `ce_pix` divides it to the 16 MHz dot
// clock MAME specifies, so scanout advances on ce_pix while fetch runs at full
// rate — which is the whole reason a line's worth of fetching fits inside a
// line's worth of display time.
//
// Rendering happens a line ahead. m2_video_timing raises `line_start` at the
// beginning of the horizontal blanking that precedes a line and names the line
// about to be rendered; the buffers written during that period are the ones
// scanned out next. Rendering into the buffer being displayed would need fetch
// to stay ahead of the beam, which at 1600 cycles for a dense layer it cannot.
//
// SCROLL REGISTERS LIVE IN TILE RAM
//
// draw_common reads them out of the tilemap's own RAM rather than from a
// separate register file:
//
//   hscr = tile_ram[0x5000 + (layer >> 1)]
//   vscr = tile_ram[0x5004 + (layer >> 1)]
//
// so they are fetched through the same port as everything else, two reads per
// layer per line, before that layer starts.

`timescale 1ns/1ps

module m2_video #(
  parameter int unsigned COLUMNS = 62,
  // R823: FOUR LINE BUFFERS IN A RING, RENDERING UP TO THREE LINES AHEAD OF
  // THE BEAM. 0 = the two-bank swap at every line_start (unchanged).
  //
  // The overruns are not a per-line budget the engine cannot meet: at zero
  // char latency the worst Daytona line takes ~2,100 of 4,100 clk_mem cycles.
  // They are a 4-line BURST. A full-screen picture layer (the sky, the title)
  // misses the glyph cache on every column of the line that enters a new
  // 4-row group of its tiles -- ~60 misses, each a demand fetch and then its
  // sibling fill serialised behind it -- and the three lines after it hit.
  // At ~30 cycles a fetch that line needs ~5,500 cycles, its neighbours
  // ~1,800, and the four together average ~2,700. A ring lets the cheap lines
  // pay for the dear one.
  //
  // Free in M10K: each (layer, lane) memory goes from 256 x 15 to 512 x 15,
  // still one block (512 x 20 mode).
  //
  // R824: AND 15 kHz INTERLACED (R682, R783) TOO, which R823 left on the
  // swap. The ring works in DISPLAY ORDER: progressive, the line itself in a
  // 424-line frame; interlaced, the field's row (vcnt) in a field of
  // vtotal lines, the line rendered being 2 * row + the field's parity. The
  // next line after a field's last visible row is row 0 of the NEXT field,
  // so the ring renders the next field's first rows in this one's blanking
  // exactly as it renders lines 0-2 in the progressive frame's.
  //
  // Lines in vertical blanking are not rendered in ring mode, and an overrun
  // is counted only for a VISIBLE line whose buffer was not ready at its
  // line_start -- the two-bank count included blanking lines.
  parameter bit          LB_RING = 1'b0,
  parameter int unsigned RING_LEAD = 2      // render at most line_number + this
) (
  input  logic        clk,
  input  logic        ce_pix,
  input  logic        rst_n,

  input  logic [13:0] tile_mask,

  // Colour translation table load. Written by whatever owns the colorxlat RAM
  // -- the copy engine today, the i960 once it is wired in.
  // R564: ON ITS WRITER'S CLOCK, not this module's. The CPU and the copy engine
  // are on the core clock and the video is on clk_mem; the table is a 96-byte
  // MLAB whose write port takes its own clock and whose read is asynchronous,
  // so the memory is the crossing. A read of an entry being written returns
  // the old or the new value, for one pixel.
  input  logic  [1:0] gamma_sel,   // R630: the palette's curve (OSD), on clk
  input  logic        xlat_clk,
  input  logic        xlat_we,
  input  logic  [6:0] xlat_addr,
  input  logic  [7:0] xlat_din,

  // Tile RAM, on chip. The V60 owns the other port.
  output logic [14:0] tram_addr,
  input  logic [15:0] tram_data,

  // Character RAM, external. Two consecutive words per request.
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,
  input  logic        char_ack,

  // Palette RAM, on chip. The V60 owns the other port.
  output logic [11:0] pal_addr,
  input  logic [15:0] pal_data,

  // Video out
  // THE 3D SITS BETWEEN THE TWO TILE CATEGORIES (R213). The reference draws
  // every layer's plain tiles, then the polygons, then every layer's
  // priority-bit tiles (model2_v.cpp screen_update: layer<<1 before
  // render_polygons, (layer<<1)|1 after). vid_cat1 says the pixel came from
  // a priority-bit tile, so the top level keeps it over a 3D pixel.
  output logic        vid_cat1,
  output logic [7:0]  vid_r,
  output logic [7:0]  vid_g,
  output logic [7:0]  vid_b,
  output logic        vid_hs,
  output logic        vid_vs,
  output logic        vid_hb,
  output logic        vid_vb,

  output logic        vblank_irq,     // to the V60
  output logic [7:0]  dbg_fetches,    // last line's fetch count, worst layer

  // HOW OFTEN THE FETCH ENGINE MISSED ITS DEADLINE.
  //
  // A line's worth of fetching is about 3,280 core cycles at 80 MHz and four
  // dense layers want roughly 6,456, so the budget can be exceeded — see
  // docs/m1-m4-plan.md and task 2a in HANDOFF. When it is, line_start arrives
  // while the sequencer is still in Q_RUN, the bank does not flip and the
  // previous line is displayed again.
  //
  // R823: THE NUMBERS ABOVE ARE STALE. They are the serial engine at 80 MHz.
  // Today's (clk_mem, 100 MHz) line is 4,100 cycles and the pipelined engine
  // needs ~1,800 on Daytona, worst ~2,100, with a perfect glyph memory. What
  // overruns is the cost of glyph-cache MISSES, which arrive in bursts: see
  // LB_RING.
  //
  // That is a deliberate, locally-wrong-but-stable failure, and it is invisible
  // from the outside: the picture is merely wrong. Counted here so "the image
  // shifts and tears" can be told apart from "the renderer is broken" without
  // guessing, because the two look identical on a screen and have nothing in
  // common as bugs.
  output logic [15:0] dbg_overruns,
  // OVERRUNS IN THE LAST FRAME, latched at vblank.
  //
  // dbg_overruns saturates at 65535 and gets there during warm-up, so it can
  // say "there were overruns" and never "there are overruns NOW" -- which is
  // the only question worth asking while chasing flicker. A per-frame count
  // answers it and cannot saturate: a frame has 384 lines.
  output logic [15:0] dbg_ovr_frame,

  // WHICH TILEMAPS ARE ACTUALLY REACHING THE SCREEN.
  //
  // The mixer already decides which slot wins every pixel, so counting wins per
  // tilemap per frame turns "is this layer being drawn?" from an inference into a
  // number. Both of this project's 2D faults would have been obvious at a glance
  // here: the row mask left one layer painting solid over the others, and the
  // window mode had tilemap 3 covering the picture while tilemap 2 drew nothing.
  //
  // Counted per frame and latched at vblank, so the value is a whole frame's
  // worth rather than a partial sweep.
  //
  // WHAT IT DOES AND DOES NOT PROVE. All four tilemaps are composited every
  // frame in a FIXED order — tilemap 0 nearest, 3 furthest, the 3D layer between
  // the two category passes — and each pixel shows the frontmost non-transparent
  // contributor. So this counts which layer WON a pixel, not whether a layer was
  // fetched. A layer reading zero may be drawing perfectly and simply be covered
  // by something in front of it.
  //
  // It is therefore an alarm, not a proof: a layer that has content in tile RAM
  // and wins nothing anywhere is worth investigating, and both of this project's
  // 2D faults would have shown up that way. Proving the composite is RIGHT needs
  // a frame diff against the reference, which is a different instrument.
  //
  // Saturating: a count that wraps reads as a small number and says the opposite
  // of what happened.
  //
  // EIGHTEEN BITS, NOT SIXTEEN. A full visible frame is 496 x 384 = 190,464
  // pixels, so a 16-bit counter saturates at 65,535 — barely a third of one
  // screen. That is not a corner case: a layer painting an opaque fill over
  // everything, which is the exact fault this was built to find, pins at the
  // maximum and reads identically to a layer covering a small window. It did,
  // and the saturated value was quoted as evidence for a frame.
  output logic [17:0] dbg_layer_px [4],

  // The window/split-scroll control register for each PAIR, latched as the
  // renderer reads it. dbg_layer_px says a layer covered the screen; this says
  // whether the game asked for a split and where, which separates "the game set
  // a mode we implement wrongly" from "we invented a split it never requested".
  output logic [15:0] dbg_ctrl [2],
  // THE SCROLL REGISTERS THE RENDERER ACTUALLY USED, per layer, latched where
  // they are consumed rather than re-read at vblank -- so they cannot disagree
  // with what drove the picture. The board reports the grass and sky sitting
  // still; the scrolling logic in m2_tile_decode is complete and correct
  // (map_x = x - hscr, map_y = y + vscr, horizontal negated as segaic24 does),
  // so either the game writes zero or these are read from the wrong words.
  // One number settles which.
  output logic [15:0] dbg_hscr [4],
  output logic [15:0] dbg_vscr [4],

  // NON-BLANK TILE WORDS FETCHED PER LAYER PER FRAME — content, not wins.
  //
  // Read alongside dbg_layer_px:
  //   have 0,   won 0     the layer holds nothing; look upstream at the CPU
  //   have > 0, won 0     it holds content that is not reaching the screen
  //   have > 0, won > 0   it is on screen
  //
  // That distinction is the whole reason this exists. On hardware the win census
  // alone could not tell a layer with no content from a layer being masked out,
  // and those need opposite fixes — the equivalent pair in simulation is what
  // found the row-mask fault.
  //
  // Twelve bits, saturating: a map holds at most 4,096 words, and telling nothing
  // from something is all this has to do. Two fit in one overlay row.
  output logic [11:0] dbg_layer_have [4],
  // THE BEAM POSITION, for the 3D layer's scan-out. The band buffers are read
  // by pixel and row, so the renderer needs the same counters the tilemap
  // fetch uses rather than a second set that could drift from them.
  output logic  [9:0] vid_x,
  output logic  [9:0] vid_y,
  // R682: 15 kHz interlaced (clk domain, held): vid_y is then the displayed
  // line of field vid_field, and the render-ahead line steps by two
  input  logic        interlace,
  input  logic        ntsc_lines,   // R783: 262.5-line fields when interlaced
  output logic        vid_field
);

  // ------------------------------------------------------------- timing
  logic [9:0] hcnt, vcnt;
  assign vid_x = hcnt;
  assign vid_y = vcnt;
  logic [15:0] ovr_acc;     // overruns this frame, latched at vblank
  logic       hblank, vblank, visible, line_start, vblank_start;
  logic       hsync_i, vsync_i;
  logic [8:0] line_number;
  logic [9:0] vtotal;       // R824: this field's (frame's) line count

  m2_video_timing timing (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n),
    .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hblank), .vblank(vblank),
    .hsync(hsync_i), .vsync(vsync_i), .visible(visible),
    .line_start(line_start), .line_number(line_number),
    .vblank_start(vblank_start),
    .interlace(interlace), .ntsc_lines(ntsc_lines), .field(vid_field), .ypos(),  // R682, R783
    .vtotal(vtotal)                                                                // R824
  );

  assign vblank_irq  = vblank_start;

  // Per-tilemap visible-pixel census. mix_src encodes 0-3 as a tilemap's
  // category-1 win and 4-7 as its category-0 win, so both fold onto the same
  // tilemap. 8 is the 3D layer and 15 the backdrop; neither is a tilemap.
  logic [17:0] px_acc [4];
  logic [11:0] tw_acc [4];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin
        px_acc[i] <= '0; dbg_layer_px[i] <= '0;
        tw_acc[i] <= '0; dbg_layer_have[i] <= '0;
      end
    end else begin
      if (vblank_start) begin
        for (int i = 0; i < 4; i++) begin
          dbg_layer_px[i]   <= px_acc[i];
          px_acc[i]         <= '0;
          dbg_layer_have[i] <= tw_acc[i];
          tw_acc[i]         <= '0;
        end
      end else begin
        if (ce_pix && visible && mix_src < 4'd8) begin
          if (px_acc[mix_src[1:0]] != 18'h3ffff)
            px_acc[mix_src[1:0]] <= px_acc[mix_src[1:0]] + 18'd1;
        end
        // Counted against cur_layer, which is the layer the fetch engine is
        // rendering when the pulse arrives — not the pixel being scanned out,
        // which belongs to the previous line and a different layer.
        if (f_tw_nonblank && tw_acc[cur_layer] != 12'hfff)
          tw_acc[cur_layer] <= tw_acc[cur_layer] + 12'd1;
      end
    end
  end

  // ------------------------------------------------------- line buffers
  // Double buffered: `bank` is written while ~bank is displayed.
  logic bank;
  logic [14:0] rd_q [4];              // {masked, prio, transparent, pal_index}
  // R823 ring (LB_RING): rg_wb is the bank being rendered, rg_rb the bank being
  // displayed, and rg_hd / rg_cnt the FIFO of finished lines waiting to be
  // shown, in bank order, each with the line it holds in rg_tag.
  logic [1:0]  rg_wb, rg_rb, rg_hd, rg_cnt;
  logic [8:0]  rg_tag [4];
  logic [8:0]  rg_nl;                 // the next line to render

  // EIGHT SEPARATE RAMS, NOT ONE ARRAY INDEXED BY BANK
  //
  // The obvious form is `logic [14:0] lbuf [2][4][512]` written at
  // lbuf[bank][cur_layer][...] and read at lbuf[~bank][L][...]. Quartus cannot
  // infer block RAM from that: the bank index is a signal rather than a
  // constant, so the write is a dynamic selection across both banks and the
  // read is a four-way dynamic select on top. It synthesises the whole thing
  // as flip-flops — measured at 28,816 ALM and 57,658 registers with zero
  // M10K, which is 69% of the device for 57 kbit of storage.
  //
  // Split into one array per (bank, layer) with the indices resolved at
  // elaboration, each becomes an ordinary one-write one-read memory and maps to
  // a single M10K. Both banks are read every cycle at the same address and the
  // result is muxed afterwards, which costs a 14-bit mux instead of an address
  // mux and keeps the memories inferrable.
  // R818: the bank is now an ADDRESS bit of each (layer, lane) memory --
  // a constant-indexed array, read and written at {bank, ...} / {~bank, ...}
  // -- which is not the dynamic selection across arrays described above; see
  // the line buffers below.

  // ---------------------------------------------------------- sequencer
  typedef enum logic [3:0] {
    Q_IDLE, Q_HSCR, Q_HSCR_W, Q_VSCR, Q_VSCR_W,
    Q_CTRL, Q_CTRL_W, Q_HCTRL, Q_HCTRL_W, Q_HTAB, Q_HTAB_W, Q_MASK, Q_MASK_W, Q_RUN, Q_NEXT
  } qstate_t;
  qstate_t q;

  logic [1:0]  cur_layer;
  logic [8:0]  cur_line;
  logic [15:0] hscr_r, vscr_r;

  // This scanline's row mask for the pair the current layer belongs to.
  //
  // segas24 keeps two tables: tilemaps 0/1 read tile_ram 0x6000 and 2/3 read
  // 0x6800, four words per scanline in both. MAME indexes them by SCREEN line,
  // not by the scrolled map line — `mask += yy1*4` walks the destination
  // rectangle — so this is cur_line, unscrolled.
  logic [63:0] mask_r;
  logic [1:0]  mask_i;

  // ---------------------------------------------- ctrl: window/split-scroll
  // The four tilemaps are two PAIRS, not four peers — MAME names them 0s/0w and
  // 1s/1w, scroll map and window map. When the pair's ctrl register has
  // bits 13:14 set, the two maps are not independent layers: the screen is
  // split and each region shows ONE of them.
  //
  // Unimplemented, this is what put a flat opaque fill over the picture on
  // hardware. Virtua Racing's attract mode sets ctrl = 0x2000, which is mode 1
  // with v = 0 — meaning MAME draws tilemap 3 across the whole screen and
  // tilemap 2 NOT AT ALL. Drawing both, with tilemap 3's category-0 pass opaque,
  // buries everything underneath it.
  logic [15:0] ctrl_r;

  // The PAIR's even hscr, read the same way ctrl is. Needed because the window
  // decision belongs to the pair, not to each map: MAME reaches that branch only
  // through the even map's draw call, so it is the even map's hscr bit 15 that
  // decides for both. Reading each map's own would let the odd one disagree.
  logic [15:0] hctrl_r;
  // This line's word of the per-line H-scroll table, 0x4000 + 0x200*map + y.
  logic [15:0] htab_r;

  // Mode 1, the vertical split, from draw_common's per-line loop:
  //
  //   v = (-vscr) & 0x1ff
  //   rows 0..v-1  show `layer`,  rows v..383 show `layer ^ 1`
  //   and layer is swapped first when ((-vscr) & 0x200) is CLEAR
  //
  // So per scanline exactly one map of the pair is live and the other must not
  // draw at all.
  wire [15:0] neg_vscr = -ctrl_r;
  wire [8:0]  win_v    = neg_vscr[8:0];
  wire        win_swap = ~neg_vscr[9];
  wire        win_mode = (ctrl_r[14:13] != 2'b00);

  // Which map of the pair this scanline belongs to: 0 = the even one.
  wire        win_upper = (cur_line < win_v);
  wire        win_pick  = win_upper ? win_swap : ~win_swap;

  // WRONG, AND KEPT VISIBLE BECAUSE IT IS THE OPEN BUG.
  //
  // What is implemented below suppresses BOTH maps of a pair when window mode is
  // selected and hscr bit 15 is clear, on the reading that draw_common's inner
  // `if (hscr & 0x8000)` has no else. **It has one** — segaic24.cpp:418-456 — and
  // in it MAME splits the screen into two rectangles and draws BOTH maps, one in
  // each:
  //
  //   } else {                                    // hscr & 0x8000 clear
  //     set_scrollx(both maps, -(hscr & 0x1ff));
  //     switch ((ctrl & 0x6000) >> 13) {
  //     case 1:                                   // VERTICAL split
  //       v = (-vscr) & 0x1ff;
  //       c1.max_y = v-1;  c2.min_y = v;
  //       if (!((-vscr) & 0x200)) layer ^= 1;
  //       draw(layer, c1);  draw(layer^1, c2);
  //     case 2: case 3:                           // HORIZONTAL split
  //       h = hscr & 0x1ff;
  //       c1.max_x = h-1;  c2.min_x = h;
  //       if (!(hscr & 0x200)) layer ^= 1;
  //       draw(layer, c1);  draw(layer^1, c2);
  //     }
  //   }
  //
  // The measurement quoted below is right and the conclusion drawn from it was
  // not. Virtua Racing's attract does set ctrl = 0x2000-0x23xx on pair 2/3 —
  // window mode 1 — with hscr below 0x0200 so bit 15 is never set. That does not
  // mean the pair is not displayed. It means the pair is drawn as a VERTICAL
  // SPLIT at scanline v, tilemap 2 above and tilemap 3 below, which is a horizon:
  // it is the sky and the sea. Suppressing the pair paints the screen with
  // palette 0 instead, which is blue, at whatever rate the game toggles the mode.
  //
  // Fixing it, in order of what the reference actually uses:
  //   1. mode 1, hscr bit 15 clear — a per-SCANLINE layer pick, y >= v selects the
  //      other map of the pair. Cheap here: the renderer is already per-scanline
  //      and cur_line is to hand.
  //   2. modes 2/3, hscr bit 15 clear — a per-PIXEL split at x = h, which is a
  //      column mask and can reuse the row-mask machinery.
  //   3. hscr bit 15 SET — the per-line H-scroll table at 0x4000 + 0x200*layer.
  //      Not reached by anything measured so far; do it last.
  // The reference model in tb_m2_video.cpp encoded the same misreading and was
  // corrected with this. Reinstating the term below now fails 4,330 checks —
  // verified by doing it, after a first attempt reported the suite as unable to
  // discriminate the fix at all. That was wrong: the fixture had hscr bit 15 SET,
  // and the faulty term was `!win_hs || ...`, so the fault was simply unreachable
  // from it. The game keeps hscr below 0x0200, the fixture now does too.
  //
  // ---------------------------------------------------------------- FIXED, mode 1
  //
  // MODE 1 IS THE VERTICAL SPLIT AND IS NOW CORRECT IN BOTH hscr CASES. The
  // per-scanline pick above is what MAME does either side of `if (hscr & 0x8000)`:
  // bit 15 set walks the scanlines applying the per-line H-scroll table and flips
  // the map at `y >= v`; bit 15 clear clips two rectangles at the same `v`. The
  // LAYER SELECTION is identical, so `win_hs` does not belong in it at all — only
  // in where the horizontal scroll comes from, which is item 3 below.
  //
  // MODES 2 AND 3 SPLIT HORIZONTALLY, at x = hscr & 0x1ff, and that is a per-pixel
  // decision this scanline-at-a-time suppress cannot express. They stay suppressed
  // — the pre-existing behaviour — because drawing the vertically-picked map for a
  // horizontal split would be wrong in a way that looks plausible on screen, and a
  // wrong picture that looks reasonable is worse here than a missing one. Measured
  // use: pair 0/1 takes ctrl = 0x4000 on 130 frames of 2,065, so this is real but
  // it is not the sky and sea.
  //
  // Still owed, in order:
  //   1. modes 2/3 as a per-pixel column split at x = h, layer ^= 1 when
  //      !(hscr & 0x200). The row-mask path in m2_tile_fetch masks in 8-pixel
  //      groups; this needs finer, so it is a change there rather than here.
  //   2. hscr bit 15 set — the per-line H-scroll table at 0x4000 + 0x200*layer.
  //      Affects the scroll VALUE, not which map draws, so mode 1 is already right
  //      about the split without it. Nothing measured reaches it.
  wire        win_hs       = hctrl_r[15];
  // hscr bit 15: the scroll VALUE comes from the per-line table instead
  // (segaic24.cpp draw_common: window branch reads the even map's table and
  // uses it for the split position and both maps' scroll; plain branch reads
  // the layer's own table). htab_r was read from the right table already.
  wire [15:0] hctrl_eff    = win_hs ? htab_r : hctrl_r;
  wire [15:0] hscr_eff     = hscr_r[15] ? htab_r : hscr_r;
  wire        win_vsplit   = (ctrl_r[14:13] == 2'b01);   // mode 1
  wire        win_hsplit   = win_mode && !win_vsplit;    // modes 2 and 3

  // Modes 2/3, the HORIZONTAL split. Same shape as mode 1 one level down:
  //
  //   h = hscr & 0x1ff
  //   c1 = x < h  shows `layer`,  c2 = x >= h shows `layer ^ 1`
  //   and layer is swapped first when (hscr & 0x200) is CLEAR
  //
  // So the low bit of the map that owns the LEFT side is !(hscr & 0x200), and
  // any layer that is not that one owns the right. Per pixel, not per scanline,
  // so m2_tile_fetch applies it — see its split_en/split_x/split_right.
  wire [8:0]  win_h         = hctrl_eff[8:0];
  wire        win_left_pick = ~hctrl_eff[9];
  wire        win_right     = (cur_layer[0] != win_left_pick);

  // Mode 1 only. Modes 2/3 no longer blank the pair — that was the placeholder
  // while the column split did not exist, and it cost the text layers every
  // frame the game selected mode 2 (194 of 2,478 measured).
  wire        win_suppress  = win_mode && win_vsplit
                           && (cur_layer[0] != win_pick);

  // IN WINDOW MODE BOTH MAPS OF A PAIR SCROLL FROM THE EVEN MAP'S REGISTERS.
  //
  // draw_common reads hscr/vscr before the shift, then returns immediately for
  // the odd map, so only the even map's values ever reach the window branch —
  // and it applies them to both:
  //
  //   set_scrolly(layer, vscr & 0x1ff);    set_scrolly(layer|1, vscr & 0x1ff);
  //   set_scrollx(layer, -(hscr & 0x1ff)); set_scrollx(layer|1, -(hscr & 0x1ff));
  //
  // ctrl_r IS that even vscr and hctrl_r that even hscr, both already latched.
  //
  // vscr bit 15 rides along correctly rather than by accident: in window mode
  // MAME only ever tests the EVEN map's disable bit, because the odd map returns
  // before the check, so an odd map cannot be disabled on its own there.
  //
  // Invisible in attract today — ctrl = 0x2000 gives v = 0, so only the even map
  // draws and the odd map's scroll never matters. It matters as soon as v != 0.
  wire [15:0] f_hscr = win_mode ? hctrl_eff : hscr_eff;
  wire [15:0] f_vscr = win_mode ? ctrl_r  : vscr_r;

  // R595: 70/35, clk_mem. ctrl_r ran a 16-bit negate, the compare against
  // cur_line, the window pick and the scroll select straight into the fetch
  // engine's start and tile-RAM address (s320: ctrl_r -> fetch, -0.712 ns,
  // 128 of the 133 failing clk_mem paths). Everything here is settled at
  // least seven cycles before f_start -- hctrl_r lands in Q_HCTRL_W, then
  // four mask reads -- and holds through Q_RUN, so registering it every
  // cycle hands the fetch engine the same values.
  logic [15:0] f_hscr_q, f_vscr_q;
  logic        win_suppress_q, win_hsplit_q, win_right_q;
  logic [8:0]  win_h_q;
  always_ff @(posedge clk) begin
    f_hscr_q       <= f_hscr;
    f_vscr_q       <= f_vscr;
    win_suppress_q <= win_suppress;
    win_hsplit_q   <= win_hsplit;
    win_h_q        <= win_h;
    win_right_q    <= win_right;
  end

  // Base of this layer's table. MAME picks it with `layer & 4` on the 8-way
  // draw index, which is bit 1 of the tilemap number: 0/1 -> 0x6000,
  // 2/3 -> 0x6800. Four words per scanline, so the line scales by four.
  logic [14:0] mask_base;
  always_comb
    mask_base = (cur_layer[1] ? 15'h6800 : 15'h6000) + {4'd0, cur_line, 2'd0};
  logic        f_start;
  logic        f_busy, f_done;
  logic [14:0] f_tram_addr;
  logic [7:0]  f_fetches;
  logic        f_tw_nonblank;

  logic [3:0]       f_lb_we;
  logic [8:0]       f_lb_addr;
  logic [3:0][11:0] f_lb_pal;
  logic [3:0]       f_lb_transparent, f_lb_prio, f_lb_masked;

  // The sequencer borrows the tile RAM port to read the scroll registers, so
  // the address is muxed rather than driven straight from the fetch engine.
  logic [14:0] seq_tram_addr;
  logic        seq_owns_tram;
  assign tram_addr = seq_owns_tram ? seq_tram_addr : f_tram_addr;

  m2_tile_fetch #(.COLUMNS(COLUMNS)) fetch (
    .clk(clk), .rst_n(rst_n),
    .start(f_start), .line(cur_line), .layer(cur_layer),
    .hscr(f_hscr_q), .vscr(f_vscr_q), .tile_mask(tile_mask),
    .layer_off(win_suppress_q),
    .split_en(win_hsplit_q), .split_x(win_h_q), .split_right(win_right_q),
    .busy(f_busy), .done(f_done),
    .tram_addr(f_tram_addr), .tram_data(tram_data),
    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),
    .lb_we(f_lb_we), .lb_addr(f_lb_addr), .lb_pal(f_lb_pal),
    .lb_transparent(f_lb_transparent), .lb_prio(f_lb_prio),
    .lb_masked(f_lb_masked), .row_mask(mask_r),
    .fetches(f_fetches), .tw_nonblank(f_tw_nonblank)
  );

  // ------------------------------------------------ R823 ring bookkeeping
  // Distances are in display order, modulo the frame -- or, interlaced, the
  // field (R824). The renderer never gets more than a few lines ahead or
  // behind, so a distance of half the modulus or more means "behind": 256 of
  // 424, and 128 of 262-274 (a field's blanking is 70-82 rows, and the ring
  // waits there at most that far ahead of its next line).
  //
  // R825: THE DECISIONS ARE REGISTERED, AND ACTED ON ONLY WHILE THE STATE IS
  // STILL THE STATE THEY WERE COMPUTED FROM. R823 failed clk_mem by 2.6-2.9 ns,
  // every failing path the ring's: line number -> distance (a subtract, then
  // a wrap add) -> compares -> go / behind / stale -> the pointers, in one
  // cycle. The ring's inputs move only on a few events -- a line_start, a pop,
  // a finished line (push), a start, a skip, a mode or field-length change --
  // and sit still for thousands of cycles between them. So:
  //   stage A  the raw differences (one subtract each)          -> pa_*
  //   stage B  the wrap add, the compares and the decisions      -> *_q
  //   rg_quiet counts the cycles since the last event (to 2). A stage-B
  //            register read with rg_quiet == 2 was computed from the state
  //            of two cycles ago, which is the state now: it equals R824's
  //            combinational decision exactly. Otherwise the ring waits.
  // So the ring is R824 with some cycles in which it does nothing: a start or
  // a skip at most two cycles later after each event (two a rendered line),
  // and a stale head dropped two cycles later. Nothing here can render into
  // the displayed bank (room and free are exact when acted on), pop a line
  // that is not finished (only pushed lines are in the FIFO), or miss a
  // line_start: the pop at line_start does not wait. Its hit is precomputed
  // per bank one cycle ahead (rg_hit) from the next cycle's tags, and is exact
  // at every line_start because no line_start follows another within a
  // cycle. `make test_m2_video_ovr` checks both claims every cycle
  // (M2_RING_CHECK, below).
  wire        ring_on   = LB_RING;
  // The ring's own view of the mode and the field's length, one cycle behind
  // the timing generator. A change is then an event the ring sees, not an
  // input moving under a registered decision.
  logic       rg_il;
  logic [9:0] rg_vt;
  // R824: THE LINE-DERIVED TERMS ARE REGISTERS. They are functions of vcnt
  // and the field, which change only at line_start, so each is loaded AT
  // line_start with its value for the line after it -- computed from the
  // line before -- and is then equal, every cycle, to what line_number and
  // vcnt give combinationally (R823's form).
  //   rg_lp  line_number's display position: the line (progressive) or the
  //          field row (interlaced) two ahead of the beam
  //   rg_lpar  interlaced: the parity of the field that row belongs to
  //   rg_wp  the position the next line_start will show, rg_lp - 1 -- which
  //          is the rg_lp of the line before, so it is simply rg_lp delayed
  // After a frame or field of N lines the beam's next line is (vcnt+1) mod N,
  // so line_number's is (vcnt + 3) mod N in the field being left -- correct
  // across the field boundary, where rows 0-1 of the next field are reached.
  // R825: and the value they load is itself a register (rg_lpn_q), a cycle
  // old: vcnt and the field last moved at the previous line_start. Only an
  // OSD mode change in the cycle before a line_start makes it stale, for
  // that one line, which the ring then treats as any mode change.
  logic [8:0] rg_lp, rg_wp;
  logic       rg_lpar;
  wire  [9:0] rg_v3   = vcnt + 10'd3;
  wire  [8:0] rg_v3w  = 9'(rg_v3 - vtotal);   // < 512 whenever it is used
  wire        rg_v3ge = (rg_v3 >= vtotal);
  wire  [8:0] rg_lpn  = rg_v3ge ? rg_v3w : rg_v3[8:0];
  logic [8:0] rg_lpn_q;
  logic       rg_v3ge_q;
  // Where to resume after falling behind: line_number, or the first line of
  // the next frame (field) when line_number is in blanking.
  wire  [8:0] rg_skip = !rg_il ? ((rg_lp >= 9'd384) ? 9'd0 : rg_lp)
                      : (rg_lp < 9'd192) ? {rg_lp[7:0], rg_lpar} : {8'd0, ~vid_field};
  // Display positions of the next line to render and of the FIFO head.
  wire  [8:0] rg_nlp  = rg_il ? {1'b0, rg_nl[8:1]} : rg_nl;
  wire  [8:0] rg_htag = rg_tag[rg_hd];
  wire  [8:0] rg_hp   = rg_il ? {1'b0, rg_htag[8:1]} : rg_htag;
  // Stage A: how far ahead the next line is, and the FIFO head, before the
  // wrap (negative = behind, or across the frame's end).
  logic [9:0] pa_tn, pa_th, pa_vtm1;
  logic       pa_n0;
  // Stage B: the distances modulo the frame (field), as R824's ldist.
  wire  [9:0] rg_nd   = pa_tn[9] ? pa_tn + rg_vt : pa_tn;
  wire  [9:0] rg_hd_d = pa_th[9] ? pa_th + rg_vt : pa_th;
  // R824: WHAT THE RING CAN REACH, AND EVERYTHING ELSE IS "BEHIND". A line
  // starts no more than RING_LEAD ahead of line_number (one more than that
  // ahead of the line shown next), so a finished line's tag, and rg_nl after
  // it, are never more than RING_LEAD + 1 ahead -- except rg_nl at the first
  // line of the next frame (field), which waits there through the blanking.
  // R823 called only a distance of half the frame "behind"; any other
  // distance was unreachable, so the tighter test changes nothing in steady
  // state, but a mode change leaves tags and rg_nl in the other mode's
  // numbering -- interlaced to progressive reads row r as line ~2r, ~100
  // lines AHEAD -- and the head then blocked the FIFO for ~100 lines. Now it
  // is dropped at once.
  wire        rg_far_n  = rg_il ? (rg_nd[9:7] != 3'd0) : (rg_nd[9:8] != 2'd0);
  wire        rg_ahead  = (rg_nd <= 10'(RING_LEAD));
  wire        rg_go     = rg_ahead || (rg_nd == pa_vtm1);
  wire        rg_behind = (pa_n0 ? rg_far_n : (rg_nd > 10'(RING_LEAD + 1)))
                          && (rg_nd != pa_vtm1);
  // Interlaced, the field a row is rendered for comes from the beam, not
  // from rg_nl: line_number's field, or the next one when the row is ahead of
  // line_number across the field boundary (rg_nlp < rg_lp: stage A's sign).
  // A parity carried in rg_nl from line to line holds only while the fields
  // alternate, and they do not when a mode change lands past the new total:
  // vcnt runs on to 1,023 and wraps with the field bit unchanged (R824).
  wire        rg_npar   = rg_lpar ^ (rg_ahead && pa_tn[9]);
  wire        rg_hstale = (rg_cnt != 2'd0) && (rg_hd_d > 10'(RING_LEAD + 1));
  // The next free bank follows the FIFO, except when the FIFO is empty and
  // its head has come round to the displayed bank -- which happens when late
  // lines are dropped (rg_hstale) while the display repeats a line. Then the
  // bank after the displayed one is free; following the head would wait for a
  // display pop that cannot come, because nothing is being rendered.
  wire [1:0]  rg_free   = ((rg_cnt == 2'd0) && (rg_hd == rg_rb)) ? rg_rb + 2'd1
                                                                 : rg_hd + rg_cnt;
  wire        rg_room   = (rg_cnt <= 2'd2) && (rg_free != rg_rb);
  logic       go_q, behind_q, npar_q, hstale_q, room_q;
  logic [1:0] free_q;
  logic [1:0] rg_quiet;                    // cycles since the last event, to 2
  wire        rg_ok     = rg_quiet[1];
  // The line_start hit, per bank, a cycle ahead: the tag each bank will hold
  // (this cycle's push included) against the line the next line_start shows.
  logic [3:0] rg_hit;
  logic       rg_vis;                      // that line is visible
  wire  [8:0] rg_want_n = interlace ? {rg_wp[7:0], rg_lpar} : rg_wp;
  wire        rg_hhit   = (rg_cnt != 2'd0) && rg_hit[rg_hd] && rg_vis;
  wire        rg_pop    = ring_on && (line_start ? rg_hhit : (rg_ok && hstale_q));
  wire        rg_push   = ring_on && (q == Q_NEXT) && (cur_layer == 2'd3);
  wire        rg_start  = ring_on && (q == Q_IDLE) && rg_ok && room_q && go_q;
  wire        rg_skipe  = ring_on && (q == Q_IDLE) && rg_ok && !(room_q && go_q) && behind_q;
  wire  [8:0] rg_line   = rg_il ? {rg_nl[8:1], npar_q} : rg_nl;
  // Everything that moves the state the decisions are computed from. A pop
  // is a line_start or a stale drop, so the line_start hit is not on this
  // path.
  wire        rg_ev     = line_start || (rg_ok && hstale_q) || rg_push || rg_start || rg_skipe
                          || (interlace != rg_il) || (vtotal != rg_vt);

  // Reset: vcnt 0 of field 0, so line_number is line (row) 2 of field 0 and
  // the next line shown is 1.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rg_lp <= 9'd2; rg_wp <= 9'd1; rg_lpar <= 1'b0;
      rg_lpn_q <= 9'd3; rg_v3ge_q <= 1'b0;
      rg_il <= 1'b0; rg_vt <= 10'd424;
      pa_tn <= '0; pa_th <= '0; pa_vtm1 <= '0; pa_n0 <= 1'b0;
      go_q <= 1'b0; behind_q <= 1'b0; npar_q <= 1'b0; hstale_q <= 1'b0;
      room_q <= 1'b0; free_q <= '0;
      rg_quiet <= '0; rg_hit <= '0; rg_vis <= 1'b0;
    end else begin
      rg_lpn_q  <= rg_lpn;
      rg_v3ge_q <= rg_v3ge;
      if (line_start) begin
        rg_lp   <= rg_lpn_q;
        rg_wp   <= rg_lp;      // line_number steps by one a line, mod the total
        rg_lpar <= vid_field ^ rg_v3ge_q;
      end
      rg_il <= interlace;
      rg_vt <= vtotal;
      // stage A
      pa_tn   <= {1'b0, rg_nlp} - {1'b0, rg_lp};
      pa_th   <= {1'b0, rg_hp}  - {1'b0, rg_wp};
      pa_n0   <= (rg_nlp == 9'd0);
      pa_vtm1 <= rg_vt - 10'd1;
      // stage B
      go_q     <= rg_go;
      behind_q <= rg_behind;
      npar_q   <= rg_npar;
      hstale_q <= rg_hstale;
      room_q   <= rg_room;
      free_q   <= rg_free;
      rg_quiet <= rg_ev ? 2'd0 : rg_quiet[1] ? 2'd2 : rg_quiet + 2'd1;
      for (int i = 0; i < 4; i++)
        rg_hit[i] <= (((rg_push && rg_wb == 2'(i)) ? cur_line : rg_tag[i]) == rg_want_n);
      rg_vis <= interlace ? (rg_wp < 9'd192) : (rg_wp < 9'd384);
    end
  end

`ifdef M2_RING_CHECK
  // R825: THE PIPELINED DECISIONS AGAINST R824's COMBINATIONAL ONES, every
  // cycle, from the state as it is now. Wherever the ring may act on a
  // registered decision (rg_ok) they must be equal, and at every line_start
  // so must the precomputed hit. Simulation only.
  function automatic logic [9:0] ldist(input logic [8:0] a, input logic [8:0] b,
                                       input logic [9:0] m);
    logic [9:0] t;
    t = {1'b0, a} - {1'b0, b};
    ldist = t[9] ? t + m : t;
  endfunction
  wire  [9:0] ck_nd     = ldist(rg_nlp, rg_lp, rg_vt);
  wire  [9:0] ck_hdd    = ldist(rg_hp, rg_wp, rg_vt);
  wire        ck_ahead  = (ck_nd <= 10'(RING_LEAD));
  wire        ck_go     = ck_ahead || (ck_nd == rg_vt - 10'd1);
  wire        ck_behind = ((rg_nlp == 9'd0) ? (rg_il ? (ck_nd[9:7] != 3'd0) : (ck_nd[9:8] != 2'd0))
                                            : (ck_nd > 10'(RING_LEAD + 1)))
                          && (ck_nd != rg_vt - 10'd1);
  wire        ck_npar   = rg_lpar ^ (ck_ahead && (rg_nlp < rg_lp));
  wire        ck_hstale = (rg_cnt != 2'd0) && (ck_hdd > 10'(RING_LEAD + 1));
  wire        ck_hhit   = (rg_cnt != 2'd0) && (rg_htag == (rg_il ? {rg_wp[7:0], rg_lpar} : rg_wp))
                          && (rg_il ? (rg_wp < 9'd192) : (rg_wp < 9'd384));
  always_ff @(posedge clk) if (rst_n && ring_on) begin
    if (rg_ok && ({go_q, behind_q, npar_q, hstale_q, room_q, free_q}
                  != {ck_go, ck_behind, ck_npar, ck_hstale, rg_room, rg_free})) begin
      $display("M2_RING_CHECK: stale decision go %b/%b behind %b/%b npar %b/%b stale %b/%b room %b/%b free %0d/%0d",
               go_q, ck_go, behind_q, ck_behind, npar_q, ck_npar, hstale_q, ck_hstale,
               room_q, rg_room, free_q, rg_free);
      $stop;
    end
    if (line_start && (rg_hhit != ck_hhit)) begin
      $display("M2_RING_CHECK: line_start hit %b, R824 gives %b", rg_hhit, ck_hhit);
      $stop;
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= Q_IDLE; cur_layer <= '0; cur_line <= '0;
      hscr_r <= '0; vscr_r <= '0; ctrl_r <= '0; f_start <= 1'b0;
      ovr_acc <= '0; dbg_ovr_frame <= '0;
      dbg_ctrl[0] <= '0; dbg_ctrl[1] <= '0;
      for (int i = 0; i < 4; i++) begin dbg_hscr[i] <= '0; dbg_vscr[i] <= '0; end
      mask_r <= '0; mask_i <= '0;
      seq_tram_addr <= '0; seq_owns_tram <= 1'b1;
      bank <= 1'b0; dbg_fetches <= '0; dbg_overruns <= '0;
      rg_wb <= 2'd1; rg_rb <= 2'd0; rg_hd <= 2'd1; rg_cnt <= 2'd0; rg_nl <= 9'd0;
      for (int i = 0; i < 4; i++) rg_tag[i] <= '0;
    end else begin
      // R823: the ring's FIFO of finished lines. A push and a pop in one
      // cycle leave rg_hd + rg_cnt -- the next free bank -- where it was.
      if (rg_pop) begin
        if (line_start) rg_rb <= rg_hd;        // shown from the next line on
        rg_hd <= rg_hd + 2'd1;
      end
      if (rg_push) rg_tag[rg_wb] <= cur_line;
      rg_cnt <= rg_cnt + {1'b0, rg_push} - {1'b0, rg_pop};
      if (ring_on && line_start && !rg_hhit && rg_vis
          && !(&ovr_acc)) begin
        // A visible line whose buffer is not ready: the bank is not
        // changed and the line before is shown again, as in Q_RUN below.
        ovr_acc <= ovr_acc + 1'd1;
        if (!(&dbg_overruns)) dbg_overruns <= dbg_overruns + 1'd1;
      end
      // A whole frame's overruns, latched where they are counted.
      if (vblank_start) begin
        dbg_ovr_frame <= ovr_acc;
        ovr_acc       <= '0;
      end
      f_start <= 1'b0;

      case (q)
        Q_IDLE: begin
          seq_owns_tram <= 1'b1;
          if (ring_on) begin
            // R823: start the next line as soon as a bank is free and the
            // line is within RING_LEAD of line_number; skip ahead when the
            // renderer has fallen behind the beam.
            // R825: on the registered decisions, only while rg_ok.
            if (rg_start) begin
              cur_line    <= rg_line;
              cur_layer   <= 2'd0;
              dbg_fetches <= '0;
              rg_wb       <= free_q;
              if (rg_cnt == 2'd0) rg_hd <= free_q;    // keeps rg_hd + rg_cnt == rg_wb
              q           <= Q_HSCR;
            end else if (rg_skipe) begin
              rg_nl <= rg_skip;
            end
          end else if (line_start) begin
            // Only reached when the previous line finished in time. If it did
            // not, the sequencer is still in Q_RUN and this edge is ignored —
            // see the overrun note on Q_RUN.
            cur_line    <= line_number;
            cur_layer   <= 2'd0;
            dbg_fetches <= '0;
            // Flip on the line boundary: what was just rendered becomes what
            // is displayed.
            bank        <= ~bank;
            q           <= Q_HSCR;
          end
        end

        // hscr = tile_ram[0x5000 + layer]
        Q_HSCR: begin
          seq_tram_addr <= 15'h5000 + {13'd0, cur_layer};
          q             <= Q_HSCR_W;
        end
        Q_HSCR_W: begin
          hscr_r        <= tram_data;
          dbg_hscr[cur_layer] <= tram_data;
          seq_tram_addr <= 15'h5004 + {13'd0, cur_layer};
          q             <= Q_VSCR;
        end
        Q_VSCR: q <= Q_VSCR_W;
        Q_VSCR_W: begin
          vscr_r        <= tram_data;
          dbg_vscr[cur_layer] <= tram_data;
          // ctrl is the PAIR's EVEN vscr, not this layer's own register:
          // MAME reads tile_ram[0x5004 + ((layer >> 1) & 2)], which for our
          // 0..3 numbering is 0x5004 + (layer & 2). One register governs both
          // maps of a pair, and reading each map's own would make the window
          // mode look inactive on the odd one.
          seq_tram_addr <= 15'h5004 + {13'd0, cur_layer[1], 1'b0};
          q             <= Q_CTRL;
        end

        Q_CTRL: q <= Q_CTRL_W;
        Q_CTRL_W: begin
          ctrl_r        <= tram_data;
          // Same value the window logic is about to act on, kept for the
          // overlay. Latched here rather than re-read at vblank so it cannot
          // disagree with what actually drove the decision.
          dbg_ctrl[cur_layer[1]] <= tram_data;
          // The pair's even hscr, for the window decision — see win_hs.
          seq_tram_addr <= 15'h5000 + {13'd0, cur_layer[1], 1'b0};
          q             <= Q_HCTRL;
        end

        Q_HCTRL: q <= Q_HCTRL_W;
        Q_HCTRL_W: begin
          hctrl_r       <= tram_data;
          // Per-line H-scroll word, read unconditionally (used only when the
          // governing hscr has bit 15 set). Window mode: the pair's EVEN table;
          // otherwise this map's own. ctrl_r is already latched here.
          seq_tram_addr <= {2'b10, 2'b00, (win_mode ? {cur_layer[1], 1'b0} : cur_layer), cur_line};
          q             <= Q_HTAB;
        end

        Q_HTAB: q <= Q_HTAB_W;
        Q_HTAB_W: begin
          htab_r        <= tram_data;
          seq_tram_addr <= mask_base + {13'd0, 2'd0};
          mask_i        <= 2'd0;
          q             <= Q_MASK;
        end

        // Four words, read one per pass. Eight more tile-RAM reads per line
        // than before across the four layers, against a budget measured in
        // thousands of cycles, so it does not move the deadline.
        Q_MASK: q <= Q_MASK_W;
        Q_MASK_W: begin
          // INVERTED FOR THE ODD TILEMAP, AND ONLY FOR THAT.
          //
          // draw_common computes two different things from the same expression
          // and they are one line apart:
          //
          //   uint16_t tpri = layer & 1;   // BEFORE the shift -> tile CATEGORY
          //   layer >>= 1;                 // now the tilemap, 0..3
          //   int win = layer & 1;         // AFTER the shift -> ODD tilemap
          //
          // and draw_rect then uses them as two independent gates: `if (win)
          // m = ~m` decides whether the 8-pixel column is drawn from this tilemap
          // at all, while `srct[xx] == tpri` decides which tiles inside it
          // contribute. Both categories of one tilemap therefore see the SAME
          // mask polarity, set by whether that tilemap is odd or even.
          //
          // This was implemented as `mask ^ category`, which is the same
          // expression read one line too late. The effect on an even tilemap is
          // that its category-1 tiles need the mask bit SET where MAME needs it
          // clear — so with the tables the game actually writes, every
          // category-1 tile on tilemaps 0 and 2 was suppressed. That is the
          // missing text: `INSERT COIN(S)`, `CREDIT 0` and the ranking table live
          // there, tile RAM held them all along, and the census showed tilemap 0
          // winning zero pixels for 640 consecutive frames.
          // R755: AND NOT AT ALL IN WINDOW MODE. MAME's window branch
          // (segaic24.cpp draw_common, ctrl & 0x6000) draws through the plain
          // tilemap draw and never reaches draw_rect, the only place the mask
          // exists. Daytona runs pair 2/3 in mode 1 with the 0x6800 table all
          // zero, so tilemap 3 -- the sky above tilemap 2's picture, rows
          // 0..v-1 -- read the table inverted, all ones, masked on every
          // pixel: a black band (palette entry 0) that grows on hills.
          mask_r[{mask_i, 4'd0} +: 16] <= win_mode ? 16'h0000
                                         : (cur_layer[0] ? ~tram_data : tram_data);
          if (mask_i == 2'd3) begin
            seq_owns_tram <= 1'b0;
            f_start       <= 1'b1;
            q             <= Q_RUN;
          end else begin
            seq_tram_addr <= mask_base + {13'd0, mask_i + 2'd1};
            mask_i        <= mask_i + 2'd1;
            q             <= Q_MASK;
          end
        end

        Q_RUN: begin
          // OVERRUN
          //
          // A line's worth of fetching is 3,936 core cycles and four dense
          // layers need about 6,456, so the budget can be exceeded — see
          // docs/m1-m4-plan.md. When it is, line_start arrives while this is
          // still running.
          //
          // Ignoring it, which is what happens by virtue of not being in
          // Q_IDLE, means the bank does not flip and the line already in the
          // display buffer is shown again. That is a repeated scanline: wrong,
          // but locally wrong and stable. Flipping mid-fetch instead would
          // send the remaining writes to the buffer being displayed, tearing
          // every layer of every following line — a whole-screen failure from
          // a one-line overrun.
          // Saturating, not wrapping: a counter that rolls over reads as a
          // small number on a screen and says the opposite of what happened.
          if (!ring_on && line_start && !(&dbg_overruns)) dbg_overruns <= dbg_overruns + 1'd1;
          if (!ring_on && line_start && !(&ovr_acc))       ovr_acc      <= ovr_acc + 1'd1;
          // The latch lives here too: one process must own ovr_acc, and the
          // increment cannot move to the stats process without dragging the
          // whole sequencer state with it.

          if (f_done) begin
            if (f_fetches > dbg_fetches) dbg_fetches <= f_fetches;
            q <= Q_NEXT;
          end
        end

        Q_NEXT: begin
          seq_owns_tram <= 1'b1;
          if (cur_layer == 2'd3) begin
            q <= Q_IDLE;
            // R824: interlaced, the next row of this field (+2), or after
            // its last visible row (191) row 0 of the next field.
            if (ring_on) rg_nl <= !rg_il ? ((cur_line >= 9'd383) ? 9'd0 : cur_line + 9'd1)
                                 : (cur_line[8:1] >= 8'd191) ? {8'd0, ~cur_line[0]} : cur_line + 9'd2;
          end
          else begin
            cur_layer <= cur_layer + 2'd1;
            q         <= Q_HSCR;
          end
        end

        default: q <= Q_IDLE;
      endcase
    end
  end

  // genvars declared outside the loop headers. Inline `for (genvar i = ...)` is
  // legal SystemVerilog and Verilator takes it, but Quartus 17.0 rejects it
  // with "genvar is a reserved keyword" — the same toolchain-strictness class
  // as the yosys and Icarus issues recorded in docs/rtl-conventions.md.
  //
  // FOUR LANES, SO FOUR PIXELS LAND IN ONE WRITE EVEN WHEN UNALIGNED.
  //
  // The fetch engine now emits four pixels a cycle, and they are consecutive
  // on screen but not aligned to four: the tile boundary moves with hscr. Each
  // lane holds the pixels whose screen position has that value mod 4, so four
  // consecutive positions touch each lane exactly once — with one lane pair
  // landing in the next group along. That makes it four independent
  // single-write memories rather than one memory needing four ports, which is
  // the only form Quartus will infer.
  //
  // A per-lane byte-enable would have been the obvious alternative and Quartus
  // 17.0 does not infer RAM from it at all — see rtl/m1_mainram.sv, where that
  // idiom cost 28,816 ALM before it was found.
  //
  // R818: ONE MEMORY PER (LAYER, LANE), THE BANK AS ITS TOP ADDRESS BIT.
  //
  // This was one 128 x 15 memory per (bank, layer, lane), and Quartus put each
  // in an M10K of its own: 32 blocks holding 61,440 bits, 18.8% of their
  // capacity, with M10K at 553 of 553. The bank is written at `bank` and read
  // at `~bank`, so as an address bit it never puts the write and the read on
  // the same word, and each (layer, lane) is still one write port and one read
  // port -- 256 x 15, one M10K. 32 blocks -> 16, and the 2:1 bank select after
  // the read is gone.
  //
  // The one difference: the bank now selects at the read's address, one cycle
  // before the old select at its output. The two disagree only in the cycle
  // after the flip, and that read is for hcnt = H_TOTAL - 1 -- the last column
  // of the horizontal blank (line_start is ce_pix at hcnt == H_TOTAL - 1).
  //
  // (Recorded from the version before: (* ramstyle = "MLAB" *) on these
  // memories was declined by Quartus 17.0 -- the summary kept them AUTO.)
  genvar gl, gn;
  generate
    for (gl = 0; gl < 4; gl++) begin : g_layer
      logic [14:0] lane_q [4];
      logic [1:0]  sel_q;

      for (gn = 0; gn < 4; gn++) begin : g_lane
        // Which incoming pixel belongs to this lane, and which group it
        // lands in. Pixels before the base's own lane have wrapped into the
        // next group.
        logic [1:0] widx;
        logic [8:0] wpos;
        logic [6:0] waddr;
        logic       wen;
        assign widx  = 2'(gn[1:0] - f_lb_addr[1:0]);
        // The screen position this lane is writing, then its group. Written
        // as the sum rather than "base group plus a carry" because the carry
        // form makes lane 3's comparison constant, which is true but reads
        // as a mistake and trips -Wall.
        assign wpos  = f_lb_addr + 9'(widx);
        assign waddr = wpos[8:2];
        assign wen   = f_lb_we[widx] && (cur_layer == 2'(gl));

        // Writes go to the bank being rendered; reads come from the other.
        // A module of its own: inline in this generate, as {bank, waddr} /
        // {~bank, hcnt[8:2]} indices into a 256-word array, Quartus 17.0
        // built all 32 lanes as flip-flops (61,440 registers, no warning,
        // ramstyle attribute or not). The 128-word arrays before this were
        // only ever recovered from registers after elaboration
        // ("mem[0][14]__7"), never inferred from the HDL.
        if (LB_RING) begin : g_ring
          // R823: four banks, 512 x 15 -- still one M10K (512 x 20 mode).
          m2_lbuf_ram #(.AW(9)) u_ram (
            .clk(clk),
            .we(wen), .wa({rg_wb, waddr}),
            .wd({f_lb_masked[widx], f_lb_prio[widx], f_lb_transparent[widx], f_lb_pal[widx]}),
            .ra({rg_rb, hcnt[8:2]}), .q(lane_q[gn])
          );
        end else begin : g_swap
          m2_lbuf_ram u_ram (
            .clk(clk),
            .we(wen), .wa({bank, waddr}),
            .wd({f_lb_masked[widx], f_lb_prio[widx], f_lb_transparent[widx], f_lb_pal[widx]}),
            .ra({~bank, hcnt[8:2]}), .q(lane_q[gn])
          );
        end
      end

      // The select is registered from the same hcnt as the address, so the
      // mux picks the lane that address fetched. Registering only the data
      // and muxing with live hcnt would take the wrong lane for the cycles
      // between a counter step and the read landing.
      always_ff @(posedge clk) sel_q <= hcnt[1:0];
      assign rd_q[gl] = lane_q[sel_q];
    end
  endgenerate

  // ------------------------------------------------------------- mixing
  logic [3:0][11:0] mix_pal;
  logic [3:0]       mix_transp, mix_prio, mix_masked;

  // R605: THE FOUR LANES REGISTERED BEFORE THE MIXER. Line-buffer RAM ->
  // lane and bank select -> mixer -> pal_addr_q was one clk_mem cycle (s340:
  // -0.074 ns). The chain below is timed in ce_pix periods of 6.25 clk_mem
  // cycles (R570): hcnt moves at E, the line buffer answers at E+1, this
  // register at E+2, pal_addr_q E+3, the palette RAM E+4, pal_data_q E+5,
  // and the next ce is E+6 at the earliest -- exactly in time.
  logic [14:0] rd_qq [4];
  always_ff @(posedge clk) for (int L = 0; L < 4; L++) rd_qq[L] <= rd_q[L];
  always_comb begin
    for (int L = 0; L < 4; L++) begin
      mix_pal[L]    = rd_qq[L][11:0];
      mix_transp[L] = rd_qq[L][12];
      mix_prio[L]   = rd_qq[L][13];
      mix_masked[L] = rd_qq[L][14];
    end
  end

  logic [11:0] mixed;
  logic [3:0]  mix_src;

  m2_tile_mixer mixer (
    .pal_index(mix_pal),
    .transparent(mix_transp),
    .prio(mix_prio),
    .masked(mix_masked),
    .disabled(4'b0000),          // already folded into transparent by the fetch
    .poly_index(12'd0),
    .poly_valid(1'b0),           // no 3D until M2
    .backdrop(12'd0),
    .pixel(mixed),
    .source(mix_src)
  );

  // R570: REGISTERED. The video runs on clk_mem now (R564), and line buffer ->
  // mixer -> palette address was one 10 ns cycle (s303: -1.26 ns). Scanout only
  // advances on ce_pix, one pixel in six or seven clk_mem cycles, so a register
  // here -- and one on the palette's read data below -- costs no pixel: hcnt
  // moves at a ce edge E, the line buffer answers at E+1, this register at E+2,
  // the palette RAM at E+3, its data register at E+4, and vid_r takes it at
  // the next ce edge, E+6 at the earliest.
  logic [11:0] pal_addr_q;
  always_ff @(posedge clk) pal_addr_q <= mixed;
  assign pal_addr = pal_addr_q;
  logic [15:0] pal_data_q;
  always_ff @(posedge clk) pal_data_q <= pal_data;

  // COLOUR TRANSLATION TABLE. Model 2's palette runs each 5-bit channel through
  // a RAM the game programs at 0x01810000 before the gamma curve -- see
  // m2_palette.sv. The game writes it at a stride of 256 words, so only 32
  // entries per channel are ever read and the whole thing is 96 bytes.
  //
  // It POWERS UP holding pal5bit, the expansion this module used before the
  // translation existed. That is deliberate: a core that has not loaded the
  // table renders exactly as it did, so adding this cannot regress the picture
  // on hardware, and loading it can only make the colours more correct.
  //
  // Layout: {channel, value}, channel 0 = R, 1 = G, 2 = B.
  logic [7:0] xlat_tbl [96];
  initial begin
    for (int c = 0; c < 3; c++)
      for (int i = 0; i < 32; i++)
        xlat_tbl[c*32 + i] = {i[4:0], i[4:2]};      // pal5bit
  end
  always_ff @(posedge xlat_clk)
    if (xlat_we) xlat_tbl[xlat_addr] <= xlat_din;

  logic [4:0] x_r5, x_g5, x_b5;
  logic [7:0] x_r, x_g, x_b;
  // R582: the xlat lookup registered before the gamma curve (s312: pal_data_q
  // -> xlat -> gamma -> pb_q, -0.278 ns at 100 MHz). See vid_r below for where
  // the cycle comes from.
  always_ff @(posedge clk) begin
    x_r <= xlat_tbl[{2'd0, x_r5}];
    x_g <= xlat_tbl[{2'd1, x_g5}];
    x_b <= xlat_tbl[{2'd2, x_b5}];
  end

  logic [7:0] pr, pg, pb;
  // R572: and the palette's output registered too (s306: pal_data_q -> gamma
  // -> xlat -> vid_b, -0.863 ns). Ready at E+5; vid_r takes it at the next ce
  // edge, E+6 at the earliest (100 / 16 puts ce edges six or seven apart).
  logic [7:0] pr_q, pg_q, pb_q;
  always_ff @(posedge clk) begin pr_q <= pr; pg_q <= pg; pb_q <= pb; end
  m2_palette pal (
    .entry(pal_data_q),                  // R570: registered, see pal_addr
    .x_r5(x_r5), .x_g5(x_g5), .x_b5(x_b5),
    .x_r(x_r),   .x_g(x_g),   .x_b(x_b),
    .r(pr), .g(pg), .b(pb), .gsel(gamma_sel)   // R630
  );

  // The colour for column hcnt is not ready in the same pixel it is addressed:
  // the line buffer read is registered, and so is the palette RAM. Both settle
  // easily inside one dot clock — there are several core cycles per ce_pix —
  // but the result still lands one pixel later than the counter that selected
  // it.
  //
  // So blanking is delayed by exactly the same one pixel. Without that the
  // image sits one column left of its own blanking window, which does not look
  // like a timing bug on a scaler that crops a little; it looks like the game
  // is drawing one column of garbage at the edge.
  // Everything here is delayed by exactly ONE pixel, and it has to be the same
  // one for the data and for the flags.
  //
  // `pr` is already the colour for the current hcnt — the line buffer and
  // palette reads both complete inside the pixel period — so latching it here
  // makes vid_r the colour of the column just passed, and latching `hblank`
  // alongside makes the flags describe that same column. Gating the data with
  // a second delayed copy of `visible` instead put the colour one pixel behind
  // its own blanking, which blanked the first visible column of every line and
  // left the rest correct: a single black column down the left edge.
  // R582: declared before the output block that reads them.
  logic ce_d, ce_dd, vis_q, cat1_q, hb_q, vb_q, hs_q, vs_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vid_cat1 <= 1'b0;
      vid_hb <= 1'b1; vid_vb <= 1'b1; vid_hs <= 1'b0; vid_vs <= 1'b0;
    end else if (ce_dd) begin   // R648: with the colour, two cycles after ce
      // R582: ALL OUTPUTS MOVE TOGETHER, on ce_d, from values latched on ce.
      // Every sync and blank is delayed with the data, not just `visible`.
      // Exposing undelayed blanking beside delayed colour puts the picture one
      // column out of its own window, which a scaler renders as a stray column
      // at the edge rather than as anything recognisably a timing fault. (R582
      // did exactly that for one build: colour on ce_d, flags still on ce --
      // tb_m2_video_frame at the hardware enable rate showed the frame one
      // pixel out, zero pixels different at that offset.)
      vid_cat1 <= cat1_q;
      vid_hb   <= hb_q;
      vid_vb   <= vb_q;
      vid_hs   <= hs_q;
      vid_vs   <= vs_q;
    end
  end

  // R582: THE COLOUR IS TAKEN ONE CYCLE AFTER THE PIXEL ENABLE, the flags above
  // on it. hcnt moves at a ce edge E; the colour is now ready at E+6 (line
  // buffer E+1, palette address E+2, palette RAM E+3, its data E+4, xlat E+5,
  // gamma E+6), and ce edges are six or seven cycles apart, so the next one
  // can be exactly E+6 -- one too early. Taking the colour at ce_d, with the
  // visibility gate latched on ce itself, keeps colour and flags on the same
  // pixel; both settle inside the pixel period and the framework samples on
  // the next enable.
  //
  // R648: AND NOW TWO CYCLES AFTER IT. R605 (rd_qq) added a stage and counted
  // the palette RAM as if it answered in the cycle its address register was
  // written; an M10K registers that address itself, so it answers a cycle
  // later. The colour is in pr_q from E+7 (line buffer E+1, rd_qq E+2,
  // pal_addr_q E+3, palette RAM E+4, pal_data_q E+5, xlat E+6, gamma E+7), and
  // a capture at ce_d is E+7 after a six-cycle gap -- the previous pixel. That
  // dropped single-pixel strokes on the test screen (N drawn as H) on every
  // build from cb8bb60 on. ce_dd is E+8 at the earliest and E+9 at the latest,
  // and pr_q holds until the next pixel's E'+7 >= E+13. The flags move with it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ce_d <= 1'b0; ce_dd <= 1'b0; vis_q <= 1'b0;
      cat1_q <= 1'b0; hb_q <= 1'b1; vb_q <= 1'b1; hs_q <= 1'b0; vs_q <= 1'b0;
      vid_r <= '0; vid_g <= '0; vid_b <= '0;
    end else begin
      ce_d  <= ce_pix;
      ce_dd <= ce_d;
      if (ce_pix) begin
        vis_q  <= visible;
        cat1_q <= visible && !mix_src[3] && !mix_src[2];   // sources 0-3
        hb_q   <= hblank;
        vb_q   <= vblank;
        hs_q   <= hsync_i;
        vs_q   <= vsync_i;
      end
      if (ce_dd) begin
        vid_r <= vis_q ? pr_q : 8'd0;
        vid_g <= vis_q ? pg_q : 8'd0;
        vid_b <= vis_q ? pb_q : 8'd0;
      end
    end
  end

endmodule

// R818: one tilemap line-buffer lane, both banks: 256 x 15, one write port,
// one registered read port -- one M10K.
module m2_lbuf_ram #(
  parameter int unsigned AW = 8          // R823: 9 for the four-bank ring
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic   [14:0] wd,
  input  logic [AW-1:0] ra,
  output logic   [14:0] q
);
  (* ramstyle = "M10K" *) logic [14:0] mem [1 << AW];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q <= mem[ra];
  end
endmodule
