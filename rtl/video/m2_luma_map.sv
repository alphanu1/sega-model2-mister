// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R867 / R900: WHICH OF THE EIGHT LUMA-RAM SHADOW SLOTS A ROW USES.
//
// The textured colour path (m2_span_tex TEXLUT) holds eight 128-entry rows of
// the luma RAM on chip (one M10K). A polygon names its row (texheader[1] low
// byte); the CPU's writes to the luma RAM fill the slots as they land. This
// maps a row to {captured, slot}: q_* for the polygon's row (captured unused),
// w_* for the CPU's write (captured: the write goes into the slot).
//
//   R867 (every game outside the large layout): VF2 0-3, Virtua Cop 2 0, 1, 16,
//     Sega Rally 0, 1 -> slots {row[4], row[1:0]}, rows 0-3 and 16-19 captured;
//     Zero Gunner (zg) 0-5, 9, 100. A row outside the eight takes the slot it
//     aliases.
//   R900 (big: the large layout's six games, and R924's House of the Dead; MAME 0.289's rows over 160 s of
//     attract and play): eight RANGES of row numbers a game, s[0] < ... < s[7].
//     Slot k holds the rows from s[k] up to s[k+1] - 1 (slot 0 every row below
//     s[1]) and is filled from row s[k] alone; the other rows of a range share
//     its table -- exactly where their contents are equal (Pilot Kids' 17
//     rows below 249 are one table), the nearest by content otherwise
//     (Dynamite Cop has 17 distinct rows, Sky Target 32, Motor Raid 24, Hanguk
//     Pro Yagu 98 33: more tables than slots -- study R900).
// The table is a function of the game ID, which is written before the image.
module m2_luma_map (
  input  logic       clk,
  input  logic [3:0] game_id,   // its low four bits (the table is used only with big)
  input  logic       big,       // the large layout's games (Model2.sv a2_big)
  input  logic       zg,        // Zero Gunner (R867's own map)
  input  logic [7:0] q_row,
  output logic [3:0] q_ls,
  input  logic [7:0] w_row,
  output logic [3:0] w_ls
);
  function automatic logic [3:0] lslot(input logic [7:0] r, input logic z);   // R867
    if (z)
      lslot = (r <= 8'd5) ? {1'b1, r[2:0]} : (r == 8'd9) ? 4'b1110 : (r == 8'd100) ? 4'b1111 : {1'b0, r[2:0]};
    else
      lslot = {(r[7:5] == 3'd0) && (r[3:2] == 2'd0), r[4], r[1:0]};
  endfunction

  // the first row of each slot's range, s[7] down to s[0]
  function automatic logic [7:0][7:0] starts(input logic [3:0] g);
    case (g)
      4'h3: starts = {8'd100, 8'd96, 8'd92, 8'd76, 8'd54, 8'd52, 8'd51, 8'd47};     // Hanguk Pro Yagu 98
      4'h4: starts = {8'd142, 8'd138, 8'd132, 8'd100, 8'd96, 8'd76, 8'd7, 8'd6};     // Dynamite Cop
      4'h5: starts = {8'd255, 8'd254, 8'd253, 8'd252, 8'd251, 8'd250, 8'd249, 8'd0}; // Pilot Kids
      4'h6: starts = {8'd255, 8'd254, 8'd100, 8'd98, 8'd92, 8'd89, 8'd72, 8'd6};     // Dead or Alive
      4'h8: starts = {8'd107, 8'd96, 8'd94, 8'd76, 8'd22, 8'd18, 8'd7, 8'd6};       // Sky Target
      4'hA: starts = {8'd151, 8'd137, 8'd133, 8'd131, 8'd126, 8'd125, 8'd115, 8'd100}; // Motor Raid
      // R924: The House of the Dead (2C, 0x17): MAME 0.289's attract, six
      // dumps over 3D frames 300-2000 use rows 0, 40, 76, 94, 96, 100 (76 and
      // 100 equal); the luma RAM is constant after boot. 60 and 120 are
      // guesses for play (rows with content no attract polygon names).
      4'h7: starts = {8'd120, 8'd100, 8'd96, 8'd94, 8'd76, 8'd60, 8'd40, 8'd0};
      default: starts = '0;   // not used (big is 0)
    endcase
  endfunction

  logic       lr_on;
  always_ff @(posedge clk) lr_on <= big;
  wire [7:0][7:0] s = starts(game_id);

  // the polygon's slot: how many of s[1..7] its row reaches
  logic [2:0] q_rs;
  always_comb begin
    q_rs = 3'd0;
    for (int k = 1; k < 8; k++) if (q_row >= s[k]) q_rs = 3'(k);
  end
  // the CPU's write: captured only for a range's first row, into its slot
  logic [2:0] w_rs;
  logic       w_hit;
  always_comb begin
    w_rs = 3'd0; w_hit = 1'b0;
    for (int k = 0; k < 8; k++) if (w_row == s[k]) begin w_rs = 3'(k); w_hit = 1'b1; end
  end
  assign q_ls = lr_on ? {1'b1, q_rs} : lslot(q_row, zg);
  assign w_ls = lr_on ? {w_hit, w_rs} : lslot(w_row, zg);
endmodule
