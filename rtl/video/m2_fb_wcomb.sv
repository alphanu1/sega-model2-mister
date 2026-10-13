// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// SPANS INTO THE DDR3 FRAMEBUFFER. The 3D fill emits runs of one colour --
// (y, x0, x1, col) -- and this turns them into DDR3 write bursts.
//
// WHY THIS EXISTS (R340, R347). The band buffers are a rolling window of NBUF
// bands, so the fill is BEAM-PACED: it may run at most NBUF bands ahead and
// must redraw every video frame even when the display list has not changed.
// Measured on the board, a list is held for 1.98 video frames on average, so
// **the fill does very nearly twice the work it needs to**, and a frame it
// cannot finish loses bands. A framebuffer removes both: the picture is drawn
// once per list and held, which is what the hardware does.
//
// THIRTY-TWO BITS A PIXEL, AND THE REASON IS THE PAINTED FLAG. Model 1's D3
// records that the band buffer is SEVENTEEN bits because the 3D composites over
// the tilemap, so "this pixel was painted" must be distinguishable from "this
// pixel is black" -- 0x0000 is a colour the game uses. Seventeen bits packs
// badly into a 64-bit word; thirty-two gives exactly TWO PIXELS A WORD, which
// is the shape screen_rotate's byte enables already assume. 496 x 384 x 4 is
// 762 KB a buffer against a gigabyte.
//
// R661: WRITES ARE COMBINED, NOT ISSUED A SPAN AT A TIME. A textured span is a
// run of one texel's colour -- at PIXSTEP 1 mostly one or two pixels -- and
// each was its own DDR3 command (head, body, tail), a round trip through the
// arbiter and m2_ddr3 for every pixel pair (R640 measured the fill waiting on
// the writer 20% of its time at PIXSTEP 4). Now spans land a word a cycle in a
// WINDOW -- WBURST words of one row, both halves of each word with their own
// valid bit -- and a window goes to DDR3 as ONE burst when the next word does
// not belong in it (another row, another window, or not adjacent to what it
// holds), when the input has been idle IDLE_T cycles, or before a clear. Two
// windows: one fills while the other is written. A window's burst covers only
// the contiguous words it holds, so no beat is ever sent with no byte enable,
// and each beat carries its own byte enables -- which is what needs m2_ddr3's
// same-cycle `wacc` (R660): the data changes beat to beat, and wnext says a
// beat was taken one cycle too late to move on to the next.
//
// ORDER. Windows are written in the order they were closed, one at a time, and
// a window is closed only when the other is empty -- so a later span's pixel
// can never reach DDR3 before an earlier one's at the same address.
//
// The window lives in MLAB, not M10K: 2 x WBURST x 64 bits is 4 Kbit, and the
// part has 13 M10K blocks spare (s568: 540 of 553).

`timescale 1ns/1ps

module m2_fb_wcomb #(
  // R661: the window, in 64-bit words -- the longest write burst. The clear
  // bursts at this length too. (R362 capped writes at 16 while no write burst
  // had ever been seen to finish; the chain bench now runs them through the
  // real m2_ddr3.)
  parameter int unsigned WBURST = 32,
  parameter int unsigned IDLE_T = 16,      // idle input cycles before a partial window is written
  parameter int unsigned SCR_W  = 496,     // visible pixels a line
  parameter int unsigned SCR_H  = 384,     // lines to clear
  parameter int unsigned STRIDE = 512,     // pixels per line, a power of two so
                                           // the row address is a shift
  // R683: FRONT TO BACK. The word being written asks the fill mask about its
  // two pixels (pg_*) and writes only the ones not yet painted -- first write
  // wins, model2rd.ipp's `if (fill[x] == 0)`. 0: every pixel is written.
  parameter bit          FTB    = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // Which buffer to draw into. The scanout reads the other.
  input  logic        fb_sel,

  // R357: CLEAR THE BUFFER BEFORE DRAWING INTO IT. With the painted flag in
  // bit 24 a cleared word is simply zero: not painted, so the mixer shows the
  // tilemap through it. 248 beats a line for 384 lines, posted writes, to the
  // buffer the scanout is not reading.
  // R813: THE CLEAR RUNS UNDER THE DRAW. It is a burst source beside the
  // windows, not a state of the intake: spans are taken while it runs, and a
  // window goes out only once the clear has passed its line. clear_busy stays
  // high until the last line is written, so the caller must not publish the
  // frame before it drops; `empty` does not wait for it.
  input  logic        clear_req,
  output logic        clear_busy,

  // ---- spans in, from m2_span_tex
  input  logic        in_valid,
  output logic        in_ready,
  // R360: in_y is 16 bits because the span interface is shared with the band
  // path, but a buffer is 512 lines and only nine of them reach the address.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic signed [15:0] in_y,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic signed [15:0] in_x0, in_x1,
  input  logic [23:0] in_col,
  input  logic        in_painted,     // 0 clears the pixel instead of painting it
  // R640: MOIRE, the checker stipple (m2_raster_band's rule): only pixels with
  // !((x ^ y) & 1) are written -- on one line always the same half of every
  // word, so it is a byte enable, not extra traffic.
  input  logic        in_moire,

  // ---- DDR3
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  output logic [63:0] m_din,
  output logic [7:0]  m_be,
  input  logic        m_wnext,
  input  logic        m_wacc,         // R660: a beat is taken THIS cycle
  input  logic        m_ack,
  output logic        empty,          // R660: nothing held, nothing in flight

  // ---- R683: the fill mask, 32 pixels a word. R685: read and written a
  // stage apart -- the word being walked (pg_ry/pg_rx0) reads its mask word,
  // answered combinationally on pg_rword; the word being written a cycle
  // later writes it back whole (pg_we/pg_wy/pg_wx0/pg_wd), with the pixels it
  // painted set. x0 is even: the word's first pixel.
  output logic [8:0]  pg_ry,
  output logic [8:0]  pg_rx0,
  input  logic [31:0] pg_rword,
  output logic        pg_we,
  output logic [8:0]  pg_wy,
  output logic [8:0]  pg_wx0,
  output logic [31:0] pg_wd,

  output logic [31:0] dbg_pixels,
  // R364: clears that COMPLETED -- a clear that never finishes stops the
  // whole 3D path, and "pixels 0" cannot tell that from "no spans".
  output logic [15:0] dbg_clears,
  output logic [3:0]  dbg_st
);

  localparam int unsigned LW    = $clog2(WBURST);         // word within a window
  localparam int unsigned RW    = $clog2(STRIDE / 2);     // word within a row
  localparam int unsigned BEATS = (SCR_W + 1) / 2;        // visible words a line
  localparam int unsigned KW    = 1 + 9 + RW - LW;        // a window: buffer, line, which window

  // One pixel: painted in bit 24, colour below it.
  wire [31:0] px = {7'd0, in_painted, in_col};

  // ------------------------------------------------------------ the windows
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mlo [2*WBURST];   // even pixel of each word
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mhi [2*WBURST];   // odd pixel
  logic [WBURST-1:0] vlo [2], vhi [2];     // which halves hold a pixel
  logic [1:0]        dirty, pend;          // holds pixels / closed, to be written
  logic [LW-1:0]     wlo [2], whi [2];     // the contiguous words it holds
  // STRIDE/2 words a row is a power of two, so an address is a concatenation
  // -- {buffer, line, window, word} -- and a window is named by its key.
  logic [KW-1:0]     wkey [2];
  logic              ib;                   // the window spans go into

  // ------------------------------------------------------------ span intake
  typedef enum logic { I_IDLE, I_RUN } ist_t;   // R813: the clear is not an intake state
  ist_t ist;
  logic signed [15:0] x_r, x1_r;
  logic               sel_r;
  logic [8:0]         y_r;
  logic [31:0]        px_r;
  logic               s0_r, s1_r;          // the stipple keeps the even / odd pixel
  logic [8:0]         clr_y, clr_x;        // R813: the line being cleared, and the beat in it
  logic               cl_on;               // R813: a clear is running (clear_busy)
  logic               f_cl;                // R813: the burst on the bus is the clear's
  logic [$clog2(IDLE_T+1)-1:0] idle_n;
  // R808: ONE SPAN HELD AT THE INTAKE, so a span is taken while the walk is
  // on the previous one's last word. A span was accepted only in I_IDLE, and
  // the walk went to I_RUN for its words and back: two cycles a span however
  // short. At texel step 1 a textured span IS one pixel, so the writer took
  // half a pixel a cycle and the whole texel path ran at its pace (R808: the
  // take gap was two cycles 72% of the time). With this, a one-word span
  // costs one cycle. in_ready stays a register (n_v, ist, clear_req).
  logic               n_v;                 // the held span, in A's terms
  logic               n_sel, n_s0, n_s1;
  logic [8:0]         n_y;
  logic signed [15:0] n_x0, n_x1;
  logic [31:0]        n_px;

  // R685: TWO STAGES. The walk (A: x_r, y_r) makes a word a cycle and reads
  // its mask word; the word then waits one cycle in B with that mask word,
  // and B is what is gated and written into a window. R683 did both in one
  // cycle -- the mask's MLAB read, its bypass and the pixel select ran
  // straight into the window's valid bits and the mask's own write enable,
  // and s641 missed 70 MHz on exactly that path (-0.163). Only B writes the
  // mask, so the one write A's read can miss is B's in the same cycle, and
  // that is merged as the word moves (a_same).
  wire [RW-1:0]  a_cw  = RW'(x_r >>> 1);
  wire           a_lo  = !x_r[0] && s0_r;
  wire           a_hi  = (x_r[0] || (x_r < x1_r)) && s1_r;
  wire signed [15:0] x_nx = {x_r[15:1], 1'b0} + 16'sd2;

  logic          b_v;                      // B holds a word
  logic [KW-1:0] b_key;
  logic [LW-1:0] b_idx;
  logic          b_lo, b_hi;               // the pixels the span covers
  logic [31:0]   b_px;
  logic [8:0]    b_y;
  logic [3:0]    b_mw, b_off;              // mask word in the row; pair within it
  logic [31:0]   b_mk;                     // the mask word, current
  wire  [KW-1:0] ckey  = b_key;
  wire  [LW-1:0] cidx  = b_idx;
  wire           lo_in = b_lo;
  wire           hi_in = b_hi;
  wire  [1:0]    b_fill = 2'(b_mk >> {b_off, 1'b0});
  // R683: a pixel something nearer has already painted is not written
  wire           lo_on = lo_in && !(FTB && b_fill[0]);
  wire           hi_on = hi_in && !(FTB && b_fill[1]);
  wire           c_any = lo_on || hi_on;
  // Belongs in window ib: the same window, and on or beside the words it holds.
  wire           c_fits = !dirty[ib] ||
                          ((wkey[ib] == ckey) &&
                           ({1'b0, cidx} + (LW+1)'(1) >= {1'b0, wlo[ib]}) &&
                           ({1'b0, cidx} <= {1'b0, whi[ib]} + (LW+1)'(1)));
  wire           other_free = !pend[~ib];
  // The window this word is written to: ib, or the other one once ib is closed.
  wire           c_wb  = c_fits ? ib : ~ib;
  // R683: the stall is decided on the UNGATED word, so the mask's read feeds
  // only what is written, never whether the walk moves -- no longer a path
  // than R607's band. A hidden word that waits here for a window costs a stall.
  wire           c_go  = b_v && (!(lo_in || hi_in) || c_fits || other_free);
  wire           c_wr  = c_go && c_any;
  wire  [1:0]    b_wr  = c_go ? {hi_on, lo_on} : 2'b00;
  wire  [31:0]   b_wd  = b_mk | (32'(b_wr) << {b_off, 1'b0});
  // A moves a word into B when B is empty or is emptying this cycle
  wire           a_go   = (ist == I_RUN) && (!b_v || c_go);
  // R808: A takes its next span when idle, or as its last word leaves --
  // from the held span if there is one, else straight from the input.
  wire           in_take = in_valid && in_ready;
  wire           a_free  = (ist == I_IDLE) || (a_go && (x_nx > x1_r));
  wire           ld_n    = n_v && a_free;
  wire           ld_in   = in_take && a_free;   // in_ready implies !n_v
  wire           ld_a    = ld_n || ld_in;
  // The source is chosen by n_v, a register: with a span held nothing is
  // taken, so a load with n_v set is the held span's. Only the ENABLE (ld_a)
  // waits on the walk's a_go.
  wire signed [15:0] ld_x0 = n_v ? n_x0 : in_x0;
  wire signed [15:0] ld_x1 = n_v ? n_x1 : in_x1;
  wire           a_same = b_v && c_go && (y_r == b_y) && (x_r[8:5] == b_mw);

  // ------------------------------------------------------------ the burst out
  typedef enum logic { F_IDLE, F_RUN } fst_t;
  fst_t fst;
  wire           fk    = pend[1];          // the closed window (never both, see ORDER)
  // R813: a window waits while the clear has not passed its line. Lines below
  // clr_y are written whole (clr_y moves on the line's last ack), and the
  // port writes in order, so a pixel can never be cleared after it is drawn.
  wire  [8:0]    fk_y  = wkey[fk][KW-2 -: 9];
  wire           f_win = pend[fk] && !(cl_on && (fk_y >= clr_y));
  // R813: and the clear takes the port only while the writer is QUIET -- no
  // span held or walking, no word in B, no window open -- or when a window is
  // waiting on it. A 32-word chunk issued while spans stream holds the port
  // ~34 cycles, and a span a few pixels long closes a window every few
  // cycles: with both windows full the walk stalls. Issued at any free cycle,
  // the clear hid 0.86 ms of its 1.32 (r57, L12); issued only while quiet,
  // 1.28 ms. Shorter chunks (16 / 8 words) at any free cycle hid 1.13 / 1.20.
  wire           w_quiet = !dirty[ib] && !b_v && (ist == I_IDLE) && !n_v;
  // The beat on the bus is word ridx, read combinationally -- MLAB reads
  // without a clock -- so a beat taken (wacc) moves ridx and the next word is
  // there the following cycle.
  logic [LW-1:0] ridx;
  always_ff @(posedge clk) begin
    if (c_wr && lo_on) mlo[{c_wb, cidx}] <= b_px;
    if (c_wr && hi_on) mhi[{c_wb, cidx}] <= b_px;
  end
  wire  [31:0]   q_lo = mlo[{fk, ridx}];
  wire  [31:0]   q_hi = mhi[{fk, ridx}];
  wire  [1:0]    q_v  = {vhi[fk][ridx], vlo[fk][ridx]};

  assign m_din   = f_cl ? 64'd0 : {q_hi, q_lo};
  assign m_be    = f_cl ? 8'hFF : {{4{q_v[1]}}, {4{q_v[0]}}};
  assign m_we    = 1'b1;
  logic [24:0] addr_r;
  assign m_addr  = addr_r;

  // R808: not only in I_IDLE -- the held span is the room (was ist == I_IDLE)
  // R813: and not during the clear -- only between its request and its start,
  // while what was drawn before it is flushed
  assign in_ready   = !n_v && !(clear_req && !cl_on);
  assign clear_busy = cl_on;
  assign empty      = (ist == I_IDLE) && !n_v && !b_v && (dirty == 2'b00) && (pend == 2'b00) && (fst == F_IDLE);
  assign dbg_st     = {cl_on, f_cl, fst, ist};   // R813
  assign pg_ry      = y_r;
  assign pg_rx0     = {x_r[8:1], 1'b0};
  assign pg_we      = FTB && (b_wr != 2'b00);
  assign pg_wy      = b_y;
  assign pg_wx0     = {b_mw, b_off, 1'b0};
  assign pg_wd      = b_wd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ist <= I_IDLE; fst <= F_IDLE; ib <= 1'b0;
      x_r <= '0; x1_r <= '0; sel_r <= 1'b0; y_r <= '0; px_r <= '0; s0_r <= 1'b1; s1_r <= 1'b1;
      clr_y <= 9'd0; clr_x <= 9'd0; idle_n <= '0; cl_on <= 1'b0; f_cl <= 1'b0;   // R813
      n_v <= 1'b0; n_sel <= 1'b0; n_s0 <= 1'b1; n_s1 <= 1'b1; n_y <= '0;   // R808
      n_x0 <= '0; n_x1 <= '0; n_px <= '0;
      dirty <= 2'b00; pend <= 2'b00; ridx <= '0; addr_r <= '0;
      m_req <= 1'b0; m_blen <= 8'd1;
      for (int k = 0; k < 2; k++) begin
        vlo[k] <= '0; vhi[k] <= '0; wlo[k] <= '0; whi[k] <= '0; wkey[k] <= '0;
      end
      dbg_pixels <= '0; dbg_clears <= 16'd0;
      b_v <= 1'b0; b_key <= '0; b_idx <= '0; b_lo <= 1'b0; b_hi <= 1'b0; b_px <= '0;
      b_y <= '0; b_mw <= '0; b_off <= '0; b_mk <= '0;
    end else begin
      // ---- R808: the held span. Its payload is written on every take (no
      // a_go in its enable); it is HELD only when A did not take it at once.
      if (in_take) begin
        n_sel <= fb_sel;
        n_y   <= 9'(in_y);
        n_x0  <= in_x0;
        n_x1  <= in_x1;
        n_px  <= px;
        n_s0  <= !in_moire ||  in_y[0];
        n_s1  <= !in_moire || !in_y[0];
      end
      if (in_take && !a_free) n_v <= 1'b1;
      else if (ld_n)          n_v <= 1'b0;

      // ---- intake
      case (ist)
        I_IDLE: begin
          idle_n <= (in_valid || n_v || b_v || !dirty[ib]) ? '0
                  : (idle_n == ($clog2(IDLE_T+1))'(IDLE_T)) ? idle_n : idle_n + 1'b1;
          if (ld_n) begin
            // R808: a span held before a clear was asked for is drawn first
          end else if (clear_req && !cl_on) begin
            // the clear goes out after everything drawn before it (B first)
            if (b_v) begin end
            else if (dirty[ib] && other_free) begin pend[ib] <= 1'b1; ib <= ~ib; end
            else if (!dirty[ib] && pend == 2'b00 && fst == F_IDLE) begin
              clr_y <= 9'd0; clr_x <= 9'd0; cl_on <= 1'b1;   // R813: runs beside the draw
            end
          end else if (in_valid) begin
            // R808: loaded below (ld_in)
          end else if (!b_v && dirty[ib] && other_free &&
                       idle_n == ($clog2(IDLE_T+1))'(IDLE_T)) begin
            pend[ib] <= 1'b1; ib <= ~ib;       // idle: write what is held
          end
        end

        I_RUN: if (a_go) begin
          x_r <= x_nx;
          if (x_nx > x1_r) ist <= I_IDLE;   // unless the next span loads (below)
        end

        default: ist <= I_IDLE;
      endcase

      // ---- R808: A takes a span -- from I_IDLE as before, or from I_RUN as
      // its last word moves to B. Overrides the walk's own x_r / ist above.
      if (ld_a) begin
        // R360: nine bits of line, and the buffer select above them.
        sel_r <= n_v ? n_sel : fb_sel;
        y_r   <= n_v ? n_y   : 9'(in_y);
        x_r   <= ld_x0;
        x1_r  <= ld_x1;
        px_r  <= n_v ? n_px  : px;
        s0_r  <= n_v ? n_s0  : (!in_moire ||  in_y[0]);   // MAME's checker: (x ^ y) & 1 == 1 is painted (x even here)
        s1_r  <= n_v ? n_s1  : (!in_moire || !in_y[0]);
        ist   <= (ld_x0 > ld_x1) ? I_IDLE : I_RUN;
      end

      // ---- R685: stage B, the word into a window
      if (c_wr) begin
        if (!c_fits) begin pend[ib] <= 1'b1; ib <= ~ib; end
        if (!c_fits || !dirty[ib]) begin
          // a fresh window
          dirty[c_wb] <= 1'b1;
          wkey[c_wb]  <= ckey;
          wlo[c_wb]   <= cidx;
          whi[c_wb]   <= cidx;
        end else begin
          if (cidx < wlo[ib]) wlo[ib] <= cidx;
          if (cidx > whi[ib]) whi[ib] <= cidx;
        end
        if (lo_on) vlo[c_wb][cidx] <= 1'b1;
        if (hi_on) vhi[c_wb][cidx] <= 1'b1;
        // R358: PIXELS PAINTED, counted as they are taken -- a pixel painted
        // twice inside one window reaches DDR3 once but was drawn twice
        if (!(&dbg_pixels)) dbg_pixels <= dbg_pixels + 32'(lo_on) + 32'(hi_on);
      end
      if (a_go) begin
        b_v   <= 1'b1;
        b_key <= {sel_r, y_r, a_cw[RW-1:LW]};
        b_idx <= a_cw[LW-1:0];
        b_lo  <= a_lo;
        b_hi  <= a_hi;
        b_px  <= px_r;
        b_y   <= y_r;
        b_mw  <= x_r[8:5];
        b_off <= x_r[4:1];
        b_mk  <= a_same ? b_wd : pg_rword;
      end else if (c_go) b_v <= 1'b0;

      // ---- a closed window, out as one burst -- or, R813, a chunk of the
      // clear: the window first unless it waits on the clear's line
      case (fst)
        F_IDLE: if (f_win) begin
          m_req  <= 1'b1;
          m_blen <= 8'(whi[fk] - wlo[fk]) + 8'd1;
          addr_r <= 25'({wkey[fk], wlo[fk]});
          ridx   <= wlo[fk];
          f_cl   <= 1'b0;
          fst    <= F_RUN;
        end else if (cl_on && (pend[fk] || w_quiet)) begin
          m_req  <= 1'b1;
          // THE VISIBLE LINE, NOT THE STRIDE: 248 beats, a WBURST chunk at a time.
          m_blen <= 8'(((9'(BEATS) - clr_x) > 9'(WBURST)) ? 9'(WBURST) : (9'(BEATS) - clr_x));
          addr_r <= ({fb_sel, 9'(clr_y)} * 25'(STRIDE / 2)) + 25'(clr_x);   // R360/R362
          f_cl   <= 1'b1;
          fst    <= F_RUN;
        end
        F_RUN: begin
          // A beat taken moves the data on this cycle (q is read at ridx+1).
          if (m_wacc) ridx <= ridx + LW'(1);
          if (m_wnext) m_req <= 1'b0;
          if (m_ack) begin
            m_req     <= 1'b0;
            fst       <= F_IDLE;
            if (f_cl) begin
              // R813: the clear's chunk; the line is passed on its last ack
              if ((clr_x + 9'(WBURST)) >= 9'(BEATS)) begin
                clr_x <= 9'd0;
                if (clr_y == 9'(SCR_H - 1)) begin
                  cl_on <= 1'b0;
                  if (!(&dbg_clears)) dbg_clears <= dbg_clears + 16'd1;   // R364
                end else clr_y <= clr_y + 9'd1;
              end else clr_x <= clr_x + 9'(WBURST);
            end else begin
              pend[fk]  <= 1'b0;
              dirty[fk] <= 1'b0;
              vlo[fk]   <= '0;
              vhi[fk]   <= '0;
            end
          end
        end
        default: fst <= F_IDLE;
      endcase
    end
  end

endmodule
