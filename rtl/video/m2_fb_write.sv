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

module m2_fb_write #(
  // R661: the window, in 64-bit words -- the longest write burst. The clear
  // bursts at this length too. (R362 capped writes at 16 while no write burst
  // had ever been seen to finish; the chain bench now runs them through the
  // real m2_ddr3.)
  parameter int unsigned WBURST = 32,
  parameter int unsigned IDLE_T = 16,      // idle input cycles before a partial window is written
  parameter int unsigned SCR_W  = 496,     // visible pixels a line
  parameter int unsigned SCR_H  = 384,     // lines to clear
  parameter int unsigned STRIDE = 512      // pixels per line, a power of two so
                                           // the row address is a shift
) (
  input  logic        clk,
  input  logic        rst_n,

  // Which buffer to draw into. The scanout reads the other.
  input  logic        fb_sel,

  // R357: CLEAR THE BUFFER BEFORE DRAWING INTO IT. With the painted flag in
  // bit 24 a cleared word is simply zero: not painted, so the mixer shows the
  // tilemap through it. 248 beats a line for 384 lines, posted writes, to the
  // buffer the scanout is not reading.
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
  typedef enum logic [1:0] { I_IDLE, I_RUN, I_CLR, I_CLRW } ist_t;
  ist_t ist;
  logic signed [15:0] x_r, x1_r;
  logic               sel_r;
  logic [8:0]         y_r;
  logic [31:0]        px_r;
  logic               s0_r, s1_r;          // the stipple keeps the even / odd pixel
  logic [8:0]         clr_y, clr_x;
  logic [$clog2(IDLE_T+1)-1:0] idle_n;

  // This cycle's word. x_r is its first pixel still to write, even or odd.
  wire [RW-1:0]  cw    = RW'(x_r >>> 1);
  wire [LW-1:0]  cidx  = cw[LW-1:0];
  wire [KW-1:0]  ckey  = {sel_r, y_r, cw[RW-1:LW]};
  wire           lo_on = !x_r[0] && s0_r;
  wire           hi_on = (x_r[0] || (x_r < x1_r)) && s1_r;
  wire           c_any = lo_on || hi_on;
  wire signed [15:0] x_nx = {x_r[15:1], 1'b0} + 16'sd2;
  // Belongs in window ib: the same window, and on or beside the words it holds.
  wire           c_fits = !dirty[ib] ||
                          ((wkey[ib] == ckey) &&
                           ({1'b0, cidx} + (LW+1)'(1) >= {1'b0, wlo[ib]}) &&
                           ({1'b0, cidx} <= {1'b0, whi[ib]} + (LW+1)'(1)));
  wire           other_free = !pend[~ib];
  // The window this word is written to: ib, or the other one once ib is closed.
  wire           c_wb  = c_fits ? ib : ~ib;
  wire           c_go  = (ist == I_RUN) && (!c_any || c_fits || other_free);
  wire           c_wr  = c_go && c_any;

  // ------------------------------------------------------------ the burst out
  typedef enum logic { F_IDLE, F_RUN } fst_t;
  fst_t fst;
  wire           fk    = pend[1];          // the closed window (never both, see ORDER)
  // The beat on the bus is word ridx, read combinationally -- MLAB reads
  // without a clock -- so a beat taken (wacc) moves ridx and the next word is
  // there the following cycle.
  logic [LW-1:0] ridx;
  always_ff @(posedge clk) begin
    if (c_wr && lo_on) mlo[{c_wb, cidx}] <= px_r;
    if (c_wr && hi_on) mhi[{c_wb, cidx}] <= px_r;
  end
  wire  [31:0]   q_lo = mlo[{fk, ridx}];
  wire  [31:0]   q_hi = mhi[{fk, ridx}];
  wire  [1:0]    q_v  = {vhi[fk][ridx], vlo[fk][ridx]};

  wire clearing = (ist == I_CLR) || (ist == I_CLRW);
  assign m_din   = clearing ? 64'd0 : {q_hi, q_lo};
  assign m_be    = clearing ? 8'hFF : {{4{q_v[1]}}, {4{q_v[0]}}};
  assign m_we    = 1'b1;
  logic [24:0] addr_r;
  assign m_addr  = addr_r;

  assign in_ready   = (ist == I_IDLE) && !clear_req;
  assign clear_busy = clearing;
  assign empty      = (ist == I_IDLE) && (dirty == 2'b00) && (pend == 2'b00) && (fst == F_IDLE);
  assign dbg_st     = {1'b0, fst, ist};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ist <= I_IDLE; fst <= F_IDLE; ib <= 1'b0;
      x_r <= '0; x1_r <= '0; sel_r <= 1'b0; y_r <= '0; px_r <= '0; s0_r <= 1'b1; s1_r <= 1'b1;
      clr_y <= 9'd0; clr_x <= 9'd0; idle_n <= '0;
      dirty <= 2'b00; pend <= 2'b00; ridx <= '0; addr_r <= '0;
      m_req <= 1'b0; m_blen <= 8'd1;
      for (int k = 0; k < 2; k++) begin
        vlo[k] <= '0; vhi[k] <= '0; wlo[k] <= '0; whi[k] <= '0; wkey[k] <= '0;
      end
      dbg_pixels <= '0; dbg_clears <= 16'd0;
    end else begin
      // ---- intake
      case (ist)
        I_IDLE: begin
          idle_n <= (in_valid || !dirty[ib]) ? '0
                  : (idle_n == ($clog2(IDLE_T+1))'(IDLE_T)) ? idle_n : idle_n + 1'b1;
          if (clear_req) begin
            // the clear goes out after everything drawn before it
            if (dirty[ib] && other_free) begin pend[ib] <= 1'b1; ib <= ~ib; end
            else if (!dirty[ib] && pend == 2'b00 && fst == F_IDLE) begin
              clr_y <= 9'd0; clr_x <= 9'd0; ist <= I_CLR;
            end
          end else if (in_valid) begin
            // R360: nine bits of line, and the buffer select above them.
            sel_r <= fb_sel;
            y_r   <= 9'(in_y);
            x_r   <= in_x0;
            x1_r  <= in_x1;
            px_r  <= px;
            s0_r  <= !in_moire || !in_y[0];   // (x ^ y) & 1 with x even
            s1_r  <= !in_moire ||  in_y[0];
            ist   <= (in_x0 > in_x1) ? I_IDLE : I_RUN;
          end else if (dirty[ib] && other_free &&
                       idle_n == ($clog2(IDLE_T+1))'(IDLE_T)) begin
            pend[ib] <= 1'b1; ib <= ~ib;       // idle: write what is held
          end
        end

        I_RUN: if (c_go) begin
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
          x_r <= x_nx;
          if (x_nx > x1_r) ist <= I_IDLE;
        end

        I_CLR: begin
          m_req  <= 1'b1;
          // THE VISIBLE LINE, NOT THE STRIDE: 248 beats, a WBURST chunk at a time.
          m_blen <= 8'(((9'(BEATS) - clr_x) > 9'(WBURST)) ? 9'(WBURST) : (9'(BEATS) - clr_x));
          addr_r <= ({fb_sel, 9'(clr_y)} * 25'(STRIDE / 2)) + 25'(clr_x);   // R360/R362
          ist    <= I_CLRW;
        end

        I_CLRW: begin
          if (m_wnext) m_req <= 1'b0;
          if (m_ack) begin
            m_req <= 1'b0;
            if ((clr_x + 9'(WBURST)) >= 9'(BEATS)) begin
              clr_x <= 9'd0;
              if (clr_y == 9'(SCR_H - 1)) begin
                ist <= I_IDLE;
                if (!(&dbg_clears)) dbg_clears <= dbg_clears + 16'd1;   // R364
              end else begin clr_y <= clr_y + 9'd1; ist <= I_CLR; end
            end else begin
              clr_x <= clr_x + 9'(WBURST);
              ist   <= I_CLR;
            end
          end
        end

        default: ist <= I_IDLE;
      endcase

      // ---- a closed window, out as one burst
      case (fst)
        F_IDLE: if (pend[fk] && !clearing) begin
          m_req  <= 1'b1;
          m_blen <= 8'(whi[fk] - wlo[fk]) + 8'd1;
          addr_r <= 25'({wkey[fk], wlo[fk]});
          ridx   <= wlo[fk];
          fst    <= F_RUN;
        end
        F_RUN: begin
          // A beat taken moves the data on this cycle (q is read at ridx+1).
          if (m_wacc) ridx <= ridx + LW'(1);
          if (m_wnext) m_req <= 1'b0;
          if (m_ack) begin
            m_req     <= 1'b0;
            pend[fk]  <= 1'b0;
            dirty[fk] <= 1'b0;
            vlo[fk]   <= '0;
            vhi[fk]   <= '0;
            fst       <= F_IDLE;
          end
        end
        default: fst <= F_IDLE;
      endcase
    end
  end

endmodule
