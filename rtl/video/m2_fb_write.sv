// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// SPANS INTO THE DDR3 FRAMEBUFFER. The 3D fill emits runs of one colour --
// (y, x0, x1, col) -- and this turns each into DDR3 writes.
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
// BURSTS, NOT SINGLE WORDS (R347). MiSTer's own guidance is that this memory is
// ~200 ns typical and unbounded in the worst case, and that a core must burst
// or cache rather than issue rapid single-word requests. A span is a RUN, so
// the aligned middle of it goes out as one burst; only the odd pixel at each
// end needs a byte-enabled single write.

`timescale 1ns/1ps

module m2_fb_write #(
  parameter int unsigned SCR_W  = 496,     // visible pixels a line
  parameter int unsigned SCR_H  = 384,     // lines to clear
  parameter int unsigned STRIDE = 512      // pixels per line, a power of two so
                                           // the row address is a shift
) (
  input  logic        clk,
  input  logic        rst_n,

  // Which buffer to draw into. The scanout reads the other.
  input  logic        fb_sel,

  // R357: CLEAR THE BUFFER BEFORE DRAWING INTO IT.
  //
  // The band buffers were cleared per band (C_CLR), and the reference clears
  // too -- `destmap().fill(0)` before each render. A framebuffer that is never
  // cleared keeps the PREVIOUS frame wherever this one paints nothing, so the
  // 3D layer would accumulate rather than replace. With the painted flag in
  // bit 24 a cleared word is simply zero: not painted, so the mixer shows the
  // tilemap through it.
  //
  // It costs 248 beats a line for 384 lines -- 95,232 beats, ~1 ms at 100 MHz,
  // or 6% of a frame -- but they are POSTED WRITES that never wait for a round
  // trip, and they go to the buffer the scanout is not reading.
  input  logic        clear_req,
  output logic        clear_busy,

  // ---- spans in, from m2_span_tex
  input  logic        in_valid,
  output logic        in_ready,
  input  logic signed [15:0] in_y, in_x0, in_x1,
  input  logic [23:0] in_col,
  input  logic        in_painted,     // 0 clears the pixel instead of painting it

  // ---- DDR3
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  output logic [63:0] m_din,
  output logic [7:0]  m_be,
  input  logic        m_wnext,
  input  logic        m_ack,

  output logic [31:0] dbg_spans,
  output logic [31:0] dbg_words
);

  // One pixel: painted in bit 24, colour below it.
  wire [31:0] px = {7'd0, in_painted, in_col};

  logic signed [15:0] x_r, x1_r;
  logic [24:0]        row_r, addr_r;
  logic [8:0]         clr_y;
  logic [31:0]        px_r;

  typedef enum logic [3:0] { W_IDLE, W_HEAD, W_BODY, W_TAIL, W_WAIT, W_DONE,
                             W_CLR, W_CLRW } st_t;
  st_t st;

  // Whole words remaining from x_r to the last EVEN-aligned pair before x1.
  // A span is a run of ONE colour, so the middle bursts and only the odd pixel
  // at each end needs a byte-enabled single write.
  wire signed [16:0] left   = 17'(x1_r) - 17'(x_r) + 17'sd1;
  // A burst is capped at 255 by DDRAM_BURSTCNT, and at what is left.
  wire [8:0]         pairs  = (left <= 0) ? 9'd0 : 9'((left) >> 1);
  wire [7:0]         bcap   = (pairs > 9'd255) ? 8'd255 : 8'(pairs);

  assign in_ready  = (st == W_IDLE) && !clear_req;
  assign clear_busy = (st == W_CLR) || (st == W_CLRW);
  // R348: A REQUEST IS HELD, NOT PULSED. m_req was asserted for one cycle, so a
  // memory that was busy that cycle never saw it -- the same fault m2_ddr3
  // exists to avoid on the DDRAM side, reproduced one level up. It is cleared
  // by the first accepted beat.
  // R348: THE ADDRESS IS LATCHED WITH THE REQUEST, not derived from x_r.
  // m_addr was combinational off x_r while W_HEAD advanced x_r in the very
  // cycle it raised m_req -- so the head write landed one word late, on the
  // pixel BESIDE the span. The bench caught it as "2 pixels wrong" on a
  // one-pixel span, which is the smallest case that can show it.
  assign m_addr   = addr_r;
  assign m_din    = {px_r, px_r};          // both halves, BE picks one or takes both
  assign m_we     = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= W_IDLE; x_r <= '0; x1_r <= '0; row_r <= '0; addr_r <= '0; px_r <= '0;
      clr_y <= 9'd0; m_req <= 1'b0; m_blen <= 8'd1; m_be <= 8'hFF;
      dbg_spans <= '0; dbg_words <= '0;
    end else begin
      case (st)
        // The clear runs a line at a time, so it interleaves with the scanout's
        // reads through the arbiter instead of holding the bus for a whole frame.
        W_IDLE: if (clear_req) begin
          clr_y  <= 9'd0;
          px_r   <= 32'd0;              // zero: not painted
          st     <= W_CLR;
        end else if (in_valid) begin
          // Rows are STRIDE pixels and two pixels a word, so the row address is
          // a shift and not a multiply.
          row_r <= {fb_sel, 24'(in_y)} * 25'(STRIDE / 2);
          x_r   <= in_x0;
          x1_r  <= in_x1;
          px_r  <= px;
          if (!(&dbg_spans)) dbg_spans <= dbg_spans + 32'd1;
          st    <= (in_x0[0]) ? W_HEAD : W_BODY;
        end

        // An odd first pixel: one word, upper half only.
        W_HEAD: begin
          m_req  <= 1'b1; m_blen <= 8'd1; m_be <= 8'hF0;
          addr_r <= row_r + 25'(x_r >> 1);
          x_r    <= x_r + 16'sd1;
          st     <= W_WAIT;
        end

        // The aligned middle, as one burst of whole words.
        W_BODY: if (x_r > x1_r) begin
          st <= W_IDLE;
        end else if (pairs == 9'd0) begin
          st <= W_TAIL;                    // a single pixel left over
        end else begin
          m_req   <= 1'b1; m_blen <= bcap; m_be <= 8'hFF;
          addr_r  <= row_r + 25'(x_r >> 1);
          st      <= W_WAIT;
        end

        // An odd last pixel: one word, lower half only.
        W_TAIL: begin
          m_req  <= 1'b1; m_blen <= 8'd1; m_be <= 8'h0F;
          addr_r <= row_r + 25'(x_r >> 1);
          x_r    <= x_r + 16'sd1;
          st     <= W_WAIT;
        end

        W_WAIT: begin
          // The first accepted beat retires the request; a whole-word beat also
          // advances two pixels. The head and tail writes already moved x_r by
          // one, so they only clear the request.
          if (m_wnext) begin
            m_req <= 1'b0;
            if (m_be == 8'hFF) begin
              x_r <= x_r + 16'sd2;
              if (!(&dbg_words)) dbg_words <= dbg_words + 32'd1;
            end else if (!(&dbg_words)) dbg_words <= dbg_words + 32'd1;
          end
          if (m_ack) begin
            m_req <= 1'b0;
            st    <= W_DONE;
          end
        end

        // One cycle for x_r to settle before deciding, so the comparison is not
        // made against the value the beat just changed.
        W_DONE: st <= (x_r > x1_r) ? W_IDLE : W_BODY;

        W_CLR: begin
          m_req   <= 1'b1;
          // THE VISIBLE LINE, NOT THE STRIDE. STRIDE/2 is 256 and
          // DDRAM_BURSTCNT is eight bits, so clamping to 255 left the last word
          // of every line uncleared -- the same 8-bit ceiling R350 hit from the
          // other side. 496 visible pixels are 248 beats, and the words beyond
          // them are never read.
          m_blen  <= 8'((SCR_W + 1) / 2);
          m_be    <= 8'hFF;
          addr_r  <= ({fb_sel, 24'(clr_y)} * 25'(STRIDE / 2));
          st      <= W_CLRW;
        end

        W_CLRW: begin
          if (m_wnext) m_req <= 1'b0;
          if (m_ack) begin
            m_req <= 1'b0;
            if (clr_y == 9'(SCR_H - 1)) st <= W_IDLE;
            else begin clr_y <= clr_y + 9'd1; st <= W_CLR; end
          end
        end

        default: st <= W_IDLE;
      endcase
    end
  end

endmodule
