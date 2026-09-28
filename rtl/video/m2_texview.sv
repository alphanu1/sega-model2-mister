// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE TEXTURE SHEETS ON THE SCREEN, AS SDRAM HOLDS THEM (R650).
//
// Every renderer bench loads MAME's texture RAM straight into its memory model,
// so none of them has ever exercised the path the textures really take: the
// game's uploads through m2_cpu_bridge into SDRAM, and the texel cache's reads
// back out of it on the shared controller. In simulation the frame's trees
// match MAME texel for texel; on the board they are blocks. This shows the
// board's own copy, one texel a pixel, to be compared with the same window
// rendered from MAME's texture RAM.
//
// A sheet is 1,024 texels across and 2,048 down; a 16-bit word holds a 2x2
// block (py0px0 [15:12], py0px1 [11:8], py1px0 [7:4], py1px1 [3:0]) and a row
// of words is 512. Rows past the sheet show black.
//
// EACH TEXEL ROW IS SHOWN ON TWO SCANLINES, so a row has two line periods to
// arrive: one burst in flight at a time, and 62 of them in one line period
// (~4,100 clk_mem cycles) left 66 cycles each -- tb_m2_texview failed every
// line at a latency of 60+20, inside what the board's texel misses see (R627).
// Two lines give ~132. The window is therefore 496 x 192 texels, `page` 0-21:
// its low bit the half across (texel x 0 or 528), the rest the 192-row band.
//
// ONE ROW AHEAD, THROUGH THE TEXEL CACHE'S OWN SDRAM PORT. When the screen
// enters texel row r (an even vcnt), row r+1 is fetched into the other half of
// a two-row buffer: 62 four-word bursts, each 8 texels of the row. The port is the one m2_texel_bl uses for
// its misses, handed over only when idle (Model2.sv), so this reads exactly as
// the cache reads -- a picture that is right here and wrong in the 3D puts
// the fault in the cache, not in the memory or its port.

`timescale 1ns/1ps

module m2_texview #(
  parameter int unsigned AW = 25
) (
  input  logic          clk,        // clk_mem
  input  logic          rst_n,
  input  logic          en,         // the view is on; quasi-static
  input  logic          sheet,
  input  logic [4:0]    page,
  input  logic [AW:1]   base0, base1,
  input  logic [8:0]    vid_x,      // 0-495 visible
  input  logic [9:0]    vid_y,

  output logic          m_req,
  output logic [AW:1]   m_addr,
  input  logic          m_ack,
  input  logic [63:0]   m_data,

  output logic [3:0]    texel       // the texel at (vid_x, vid_y), a cycle later
);

  localparam int unsigned R_VIS = 192, V_TOT = 424, NB = 62;

  // the two-line buffer: {line & 1, burst} -> the line's 8 texels, packed
  (* ramstyle = "M10K" *) logic [31:0] lb [128];
  logic        lb_we;
  logic [6:0]  lb_wa;
  logic [31:0] lb_wd;
  logic [31:0] lb_q;
  logic [2:0]  x_q;
  always_ff @(posedge clk) begin
    if (lb_we) lb[lb_wa] <= lb_wd;
    lb_q <= lb[{vid_y[1], vid_x[8:3]}];   // texel row vid_y >> 1
    x_q  <= vid_x[2:0];
  end
  logic        line_ok [2];     // the half holds a line inside the sheet
  logic        ok_q;
  always_ff @(posedge clk) ok_q <= line_ok[vid_y[1]];
  assign texel = ok_q ? lb_q[4*x_q +: 4] : 4'd0;

  // the line being fetched, and where it lives in the sheet
  logic [9:0]  y_prev;
  logic [8:0]  ny;              // texel row of the window being fetched
  logic        ty0;             // its texel row's low bit: which row of each 2x2 word
  logic [5:0]  b;               // burst
  logic        busy, wait_low, nl;   // nl: the screen moved to a new line
  wire  [11:0] ty_next = 12'(page[4:1]) * 12'd192 + 12'(ny);

  // 8 texels of row py from a four-word burst (word k in [16k+15:16k])
  function automatic logic [31:0] pack(input logic [63:0] d, input logic py);
    logic [31:0] r;
    begin
      for (int j = 0; j < 8; j++) begin
        logic [15:0] w;
        w = d[16*(j>>1) +: 16];
        r[4*j +: 4] = py ? ((j % 2 == 1) ? w[3:0]  : w[7:4])
                         : ((j % 2 == 1) ? w[11:8] : w[15:12]);
      end
      pack = r;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y_prev <= '0; ny <= '0; ty0 <= 1'b0; b <= '0; busy <= 1'b0; wait_low <= 1'b0; nl <= 1'b0;
      m_req <= 1'b0; m_addr <= '0; lb_we <= 1'b0; lb_wa <= '0; lb_wd <= '0;
      line_ok[0] <= 1'b0; line_ok[1] <= 1'b0;
    end else begin
      lb_we  <= 1'b0;
      y_prev <= vid_y;
      // a new line on the screen: fetch the next one (a line still being
      // fetched is abandoned -- the port is slow, the picture shows it). A
      // request in flight always runs to its acknowledge: the port is handed
      // back to the texel cache only when idle, and an answer must not land
      // on the wrong owner.
      if (vid_y != y_prev && !vid_y[0]) nl <= en;   // a new texel row
      if (nl && !m_req && !wait_low) begin
        nl <= 1'b0;
        // the row after this one; the last blanking row fetches row 0
        ny <= (vid_y == 10'(V_TOT - 2)) ? 9'd0 : 9'(vid_y[9:1] + 9'd1);
        b  <= '0;
        busy <= (vid_y == 10'(V_TOT - 2)) || (vid_y[9:1] < 9'(R_VIS - 1));
      end else if (busy && !m_req && !wait_low) begin
        ty0 <= ty_next[0];
        if (ty_next >= 12'd2048) begin
          line_ok[ny[0]] <= 1'b0; busy <= 1'b0;
        end else begin
          // word = (ty >> 1) * 512 + (xoff >> 1) + 4b, xoff 0 or 528
          m_addr <= (sheet ? base1 : base0)
                  + AW'({ty_next[11:1], 9'd0})
                  + AW'(page[0] ? 10'd264 : 10'd0) + AW'({b, 2'b00});
          m_req  <= 1'b1;
        end
      end
      if (m_req && m_ack) begin
        m_req <= 1'b0; wait_low <= 1'b1;
        lb_we <= 1'b1; lb_wa <= {ny[0], b}; lb_wd <= pack(m_data, ty0);
        if (b == 6'(NB - 1)) begin busy <= 1'b0; line_ok[ny[0]] <= 1'b1; end
        else b <= b + 6'd1;
      end
      if (wait_low && !m_ack) wait_low <= 1'b0;   // the next rising edge is a new request
      if (!en) begin busy <= 1'b0; nl <= 1'b0; end
    end
  end

endmodule
