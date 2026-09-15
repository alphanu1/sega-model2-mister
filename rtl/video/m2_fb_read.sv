// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE DDR3 FRAMEBUFFER, READ BACK A LINE AT A TIME.
//
// This replaces the read side of m2_raster_band. The interface is deliberately
// the same -- rd_x, rd_row -> rd_col, rd_hit -- so m2_tile_mixer composites the
// 3D over the tilemap exactly as it does today and does not know the pixels
// now come from DDR3.
//
// ONE BURST A LINE, ISSUED A LINE EARLY, AND THAT IS THE WHOLE SAFETY ARGUMENT.
// R347: this memory is ~200 ns typical and UNBOUNDED in the worst case because
// the bridge is shared with the ARM. Reading per pixel would put that in the
// beam's path. A line is 512 pixels at two per beat -- 256 beats, one command --
// and it is requested while the beam is still drawing the PREVIOUS line:
//
//     a line at 6 MHz pixel clock is ~30 us of slack
//     the burst itself is 256 beats, ~2.6 us at 100 MHz
//     the latency it amortises is ~200 ns -- under 8% of the transfer
//
// So the worst case has an order of magnitude of room before anything is late,
// where a per-pixel read would have none. The same arithmetic is why the
// Z80 and the sample fetchers are a HARDER problem than the framebuffer, not an
// easier one (R347).
//
// TWO LINE BUFFERS, IN M10K. 2 x 512 x 25 bits is about 26 Kbit, three blocks,
// against the twenty-four the three band buffers cost. The net is twenty-one
// blocks back on a device that reads 553 of 553.

`timescale 1ns/1ps

module m2_fb_read #(
  parameter int unsigned WIDTH  = 496,
  parameter int unsigned STRIDE = 512      // pixels a line in DDR3, a power of two
) (
  input  logic        clk,        // DDR3 side
  input  logic        rd_clk,     // video side -- the mixer reads here
  input  logic        rst_n,

  // Which buffer the scanout is showing. The fill writes the other.
  input  logic        fb_sel,

  // ---- fetch control: "the beam is about to need line N"
  input  logic        line_req,           // one pulse per scanline
  input  logic [8:0]  line_y,
  output logic        line_ready,         // that line is in the buffer

  // ---- DDR3
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  input  logic        m_rvalid,
  // Each 32-bit pixel is {7'd0, painted, col24}, so the pad bits are unread.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [63:0] m_dout,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        m_ack,

  // ---- the mixer side, shaped exactly like m2_raster_band's
  // R354: WHICH LINE BUFFER, BY PARITY, so nothing crosses the clock boundary.
  // The obvious design has the DDR3 side toggle a "filling" flag and the video
  // side synchronise it -- but that flag must not change mid-line, and a
  // synchroniser gives no such guarantee. Line parity is derived independently
  // in each domain from a counter each already has: the fill puts line N in
  // buffer N[0], and the mixer drawing line N reads buffer N[0]. No CDC, and no
  // way for the two to disagree about which buffer is which.
  input  logic        rd_parity,
  input  logic [$clog2(WIDTH)-1:0] rd_x,
  output logic [23:0] rd_col,
  output logic        rd_hit,

  output logic [31:0] dbg_lines,
  output logic [31:0] dbg_late          // asked for a line that was not ready
);

  // TWO PIXELS A BEAT, AND ONLY THE VISIBLE ONES. A 512-pixel stride is 256
  // beats and DDRAM_BURSTCNT IS EIGHT BITS -- 8'(256) is zero, so the burst
  // never ran and every line came back empty. 496 visible pixels are 248 beats,
  // inside the field with room. The stride stays a power of two because the
  // line ADDRESS is a shift; only the transfer is trimmed to what is shown.
  localparam int unsigned BEATS = (WIDTH + 1) / 2;

  assign m_we = 1'b0;

  // Ping-pong: the mixer reads one while the other fills.
  (* ramstyle = "M10K" *) logic [24:0] lb0 [STRIDE];
  (* ramstyle = "M10K" *) logic [24:0] lb1 [STRIDE];
  logic [24:0] rd_q0, rd_q1;
  wire         fill_buf = y_r[0];         // line N fills buffer N[0]

  logic [8:0]  wp;                        // pixel being written
  logic [8:0]  y_r;
  logic        busy, have;

  // The video side reads in ITS OWN clock domain, as m2_raster_band does.
  always_ff @(posedge rd_clk) begin
    rd_q0 <= lb0[rd_x];
    rd_q1 <= lb1[rd_x];
  end

  wire [24:0] rd_w = rd_parity ? rd_q1 : rd_q0;
  assign rd_col = rd_w[23:0];
  assign rd_hit = rd_w[24];

  // R360: THE BUFFER SELECT HAS TO SURVIVE THE MULTIPLY. This was
  // `{fb_sel, 24'(y_r)} * 25'(STRIDE/2)`, which places fb_sel at bit 24 and
  // then multiplies by 256 -- so it lands at bit 32 of a TWENTY-FIVE bit
  // address and is gone. Both buffers were the same memory, the double buffer
  // was not double, and the scanout read the frame being drawn. The line
  // number is nine bits because a buffer is 512 lines, so the select belongs
  // at bit 9 before the shift and bit 17 after it.
  assign m_addr = {fb_sel, 9'(y_r)} * 25'(STRIDE / 2);
  assign m_blen = 8'(BEATS);
  assign line_ready = have;

  typedef enum logic [1:0] { R_IDLE, R_REQ, R_FILL } st_t;
  st_t st;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= R_IDLE; m_req <= 1'b0; wp <= 9'd0; y_r <= 9'd0;
      busy <= 1'b0; have <= 1'b0;
      dbg_lines <= '0; dbg_late <= '0;
    end else begin
      if (line_req) begin
        y_r  <= line_y;
        have <= 1'b0;
        // ASKED BEFORE THE LAST ONE LANDED. Counted rather than silent: it is
        // the number that says whether a line ahead is enough warning.
        if (busy && !(&dbg_late)) dbg_late <= dbg_late + 32'd1;
      end

      case (st)
        R_IDLE: if (line_req) begin
          m_req <= 1'b1; wp <= 9'd0; busy <= 1'b1; st <= R_REQ;
        end

        // Held until taken -- a pulsed request is lost to a busy bridge (R348).
        // The FIRST beat can arrive in this state, and it is a whole beat like
        // any other: an earlier draft wrote only its low half and did not
        // advance wp, which silently dropped pixel 1 of every line.
        R_REQ: if (m_rvalid) begin
          m_req <= 1'b0;
          if (fill_buf) begin
            lb1[{wp[7:0], 1'b0}] <= m_dout[24:0];
            lb1[{wp[7:0], 1'b1}] <= m_dout[56:32];
          end else begin
            lb0[{wp[7:0], 1'b0}] <= m_dout[24:0];
            lb0[{wp[7:0], 1'b1}] <= m_dout[56:32];
          end
          wp <= wp + 9'd1;
          st <= R_FILL;
        end

        default: begin
          if (m_rvalid) begin
            // Two pixels a beat, low half first.
            if (fill_buf) begin
              lb1[{wp[7:0], 1'b0}] <= m_dout[24:0];
              lb1[{wp[7:0], 1'b1}] <= m_dout[56:32];
            end else begin
              lb0[{wp[7:0], 1'b0}] <= m_dout[24:0];
              lb0[{wp[7:0], 1'b1}] <= m_dout[56:32];
            end
            wp <= wp + 9'd1;
          end
          if (m_ack) begin
            busy <= 1'b0;
            have <= 1'b1;
            if (!(&dbg_lines)) dbg_lines <= dbg_lines + 32'd1;
            st       <= R_IDLE;
          end
        end
      endcase
    end
  end

endmodule
