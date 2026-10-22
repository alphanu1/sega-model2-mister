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
//   R900 (big: the large layout's six games, R924's House of the Dead and R928's
//     Over Rev; MAME 0.289's rows over 160 s of
//     attract and play): eight RANGES of row numbers a game, s[0] < ... < s[7].
//     Slot k holds the rows from s[k] up to s[k+1] - 1 (slot 0 every row below
//     s[1]) and is filled from row s[k] alone; the other rows of a range share
//     its table -- exactly where their contents are equal (Pilot Kids' 17
//     rows below 249 are one table), the nearest by content otherwise
//     (Dynamite Cop has 17 distinct rows, Sky Target 32, Motor Raid 24, Hanguk
//     Pro Yagu 98 33: more tables than slots -- study R900).
//   R932 (LSB 5, the 2C build: 32 slots; orev): Over Rev by a TABLE, not
//     ranges -- each of the 256 rows names its slot, and each slot is filled
//     from one representative row (bit 5 of the entry). R928's eight ranges
//     put the Ariake road (row 174: 23-32) and its neighbours (171) on row
//     139's table (7-63): a light, high-contrast road (Ben's board, s1337).
//     The table is a k-medoids fit (sim session, R932) over MAME 0.289's walk
//     dumps of all four courses, Challenge Cup round 1 and the attract: per-
//     pixel mean |luma error| 0.16 of 63 (R928's ranges: 2.71; 26% of drawn
//     pixels on a row more than 4 off, now 0.6%).
// The table is a function of the game ID, which is written before the image.
// q_ls / w_ls are {captured, slot[LSB-1:0]}; the range and fixed maps give
// eight slots, zero-extended when LSB > 3.
module m2_luma_map #(
  parameter int unsigned LSB  = 3,      // R932: slot bits (3 the 2A build, 5 the 2C build)
  parameter bit          OREV = 1'b0    // R932: Over Rev's table (needs LSB 5)
) (
  input  logic           clk,
  input  logic [3:0]     game_id,   // its low four bits (the table is used only with big)
  input  logic           big,       // the large layout's games (Model2.sv a2_big)
  input  logic           zg,        // Zero Gunner (R867's own map)
  input  logic           orev,      // R932: Over Rev (Model2.sv is_orev; used with OREV)
  input  logic [7:0]     q_row,
  output logic [LSB:0]   q_ls,
  input  logic [7:0]     w_row,
  output logic [LSB:0]   w_ls
);
  // R932: Over Rev, row -> {representative, slot[4:0]}, six bits a row
  function automatic logic [5:0] orev_tab(input logic [7:0] r);
    case (r)
      8'd30, 8'd36, 8'd128: orev_tab = 6'h00;
      8'd14, 8'd15, 8'd16, 8'd17, 8'd212: orev_tab = 6'h01;
      8'd2, 8'd4, 8'd6, 8'd129: orev_tab = 6'h02;
      8'd13, 8'd46, 8'd182, 8'd204: orev_tab = 6'h03;
      8'd9, 8'd11, 8'd32, 8'd34, 8'd44, 8'd49, 8'd160, 8'd179, 8'd195, 8'd196, 8'd207, 8'd208: orev_tab = 6'h04;
      8'd19: orev_tab = 6'h05;
      8'd22, 8'd23, 8'd50: orev_tab = 6'h06;
      8'd12, 8'd35, 8'd39, 8'd40, 8'd41, 8'd48, 8'd191, 8'd192, 8'd194: orev_tab = 6'h07;
      8'd5, 8'd20, 8'd25, 8'd139, 8'd164, 8'd184: orev_tab = 6'h08;
      8'd21: orev_tab = 6'h09;
      8'd165, 8'd166, 8'd215: orev_tab = 6'h0a;
      8'd8, 8'd28, 8'd152, 8'd156: orev_tab = 6'h0b;
      8'd43, 8'd217: orev_tab = 6'h0c;
      8'd29, 8'd38, 8'd158, 8'd159, 8'd168, 8'd214: orev_tab = 6'h0d;
      8'd31: orev_tab = 6'h0e;
      8'd26, 8'd27, 8'd140: orev_tab = 6'h0f;
      8'd42, 8'd167: orev_tab = 6'h10;
      8'd141, 8'd169, 8'd170, 8'd175, 8'd193: orev_tab = 6'h11;
      8'd145, 8'd151, 8'd181: orev_tab = 6'h12;
      8'd142, 8'd147, 8'd163: orev_tab = 6'h13;
      8'd37, 8'd150: orev_tab = 6'h15;
      8'd157, 8'd187, 8'd203: orev_tab = 6'h16;
      8'd189: orev_tab = 6'h17;
      8'd201, 8'd210: orev_tab = 6'h18;
      8'd162, 8'd173: orev_tab = 6'h19;
      8'd161, 8'd183: orev_tab = 6'h1b;
      8'd33, 8'd180: orev_tab = 6'h1c;
      8'd190: orev_tab = 6'h1d;
      8'd47, 8'd153: orev_tab = 6'h1e;
      8'd0: orev_tab = 6'h20;
      8'd1: orev_tab = 6'h21;
      8'd3: orev_tab = 6'h22;
      8'd7: orev_tab = 6'h23;
      8'd10: orev_tab = 6'h24;
      8'd18: orev_tab = 6'h25;
      8'd24: orev_tab = 6'h26;
      8'd45: orev_tab = 6'h27;
      8'd130: orev_tab = 6'h28;
      8'd131: orev_tab = 6'h29;
      8'd132: orev_tab = 6'h2a;
      8'd133: orev_tab = 6'h2b;
      8'd134: orev_tab = 6'h2c;
      8'd135: orev_tab = 6'h2d;
      8'd136: orev_tab = 6'h2e;
      8'd137: orev_tab = 6'h2f;
      8'd138: orev_tab = 6'h30;
      8'd143: orev_tab = 6'h31;
      8'd144: orev_tab = 6'h32;
      8'd146: orev_tab = 6'h33;
      8'd148: orev_tab = 6'h34;
      8'd149: orev_tab = 6'h35;
      8'd154: orev_tab = 6'h36;
      8'd155: orev_tab = 6'h37;
      8'd171: orev_tab = 6'h38;
      8'd172: orev_tab = 6'h39;
      8'd174: orev_tab = 6'h3a;
      8'd176: orev_tab = 6'h3b;
      8'd177: orev_tab = 6'h3c;
      8'd178: orev_tab = 6'h3d;
      8'd185: orev_tab = 6'h3e;
      8'd188: orev_tab = 6'h3f;
      default: orev_tab = 6'h1f;
    endcase
  endfunction

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
      // R928: Over Rev (2C, 0x1C; Sega Rally's layout, so Model2.sv passes
      // big for it): MAME 0.289's 39 walk dumps over 160 s (attract, menus,
      // a race) use 98 rows of 0-51 and 128-195 with 95 distinct contents;
      // rows 128+ are rewritten per course (the snoop refills a slot when its
      // first row is written). R900's DP: polygon-weighted mean |diff| 2.0 of
      // the game's 0..63 luma (16 slots would give 1.1); 14% of polygons on
      // rows more than 4 off (row 51 the worst, 25).
      4'hC: starts = {8'd178, 8'd176, 8'd139, 8'd129, 8'd22, 8'd14, 8'd10, 8'd0};
      default: starts = '0;   // not used (big is 0)
    endcase
  endfunction

  logic       lr_on;
  /* verilator lint_off UNUSEDSIGNAL */   // R932: read only with OREV
  logic       or_on;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clk) begin lr_on <= big; or_on <= OREV && orev; end
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
  wire [3:0] q8 = lr_on ? {1'b1, q_rs} : lslot(q_row, zg);
  wire [3:0] w8 = lr_on ? {w_hit, w_rs} : lslot(w_row, zg);
  generate if (OREV && LSB >= 5) begin : g_orev
    /* verilator lint_off UNUSEDSIGNAL */   // q_t[5]: a polygon's row is drawn captured or not
    wire [5:0] q_t = orev_tab(q_row);
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0] w_t = orev_tab(w_row);
    assign q_ls = or_on ? {1'b1, (LSB)'(q_t[4:0])} : {q8[3], (LSB)'(q8[2:0])};
    assign w_ls = or_on ? {w_t[5], (LSB)'(w_t[4:0])} : {w8[3], (LSB)'(w8[2:0])};
  end else begin : g_r8
    assign q_ls = {q8[3], (LSB)'(q8[2:0])};
    assign w_ls = {w8[3], (LSB)'(w8[2:0])};
  end endgenerate
endmodule
