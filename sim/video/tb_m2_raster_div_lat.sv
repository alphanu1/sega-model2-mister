// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R948: m2_raster_div on m2_recip_rom's two forms -- the LUT copies and the
// M10K table -- side by side, the same operands to both: every cycle's ready,
// out_valid, quotient and div0 compared (the forms are cycle-identical).
// Every denominator -600..600 (the table's 1..255 both signs, the restoring
// path past it, zero) against edge and random numerators, then random 32-bit
// pairs; port A and port B of the table each carry a pair of dividers.
`timescale 1ns/1ps
module tb_m2_raster_div_lat;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [7:0]  aa1, ab1, aa2, ab2;
  logic [31:0] da1, db1, da2, db2;
  m2_recip_rom #(.M10K(1'b0)) u_rom1 (.clk(clk), .a_addr(aa1), .a_data(da1), .b_addr(ab1), .b_data(db1));
  m2_recip_rom #(.M10K(1'b1)) u_rom2 (.clk(clk), .a_addr(aa2), .a_data(da2), .b_addr(ab2), .b_data(db2));
  logic               go;
  logic signed [31:0] num, den;
  logic r1, r2, v1, v2, z1, z2, vb1, vb2, rb1, rb2, zb1, zb2;
  logic signed [31:0] q1, q2, qb1, qb2;
  // port A and port B each carry a divider, as in m2_raster_fill
  m2_raster_div u_d1  (.clk(clk), .rst_n(rst_n), .rom_addr(aa1), .rom_data(da1), .in_valid(go), .num(num), .den(den),
                                      .ready(r1), .out_valid(v1), .quo(q1), .div0(z1));
  m2_raster_div u_d2  (.clk(clk), .rst_n(rst_n), .rom_addr(aa2), .rom_data(da2), .in_valid(go), .num(num), .den(den),
                                      .ready(r2), .out_valid(v2), .quo(q2), .div0(z2));
  m2_raster_div u_db1 (.clk(clk), .rst_n(rst_n), .rom_addr(ab1), .rom_data(db1), .in_valid(go), .num(-num), .den(den),
                                      .ready(rb1), .out_valid(vb1), .quo(qb1), .div0(zb1));
  m2_raster_div u_db2 (.clk(clk), .rst_n(rst_n), .rom_addr(ab2), .rom_data(db2), .in_valid(go), .num(-num), .den(den),
                                      .ready(rb2), .out_valid(vb2), .quo(qb2), .div0(zb2));
  int n = 0, bad = 0, cyc = 0;
  // cycle by cycle: the two forms must agree on every output, every clock
  always @(posedge clk) if (rst_n) begin
    #2;
    if (r1 !== r2 || v1 !== v2 || rb1 !== rb2 || vb1 !== vb2
        || (v1 && (q1 !== q2 || z1 !== z2)) || (vb1 && (qb1 !== qb2 || zb1 !== zb2))) begin
      cyc++;
      if (cyc < 10) $display("CYCLE DIFF t=%0t r %b%b v %b%b rb %b%b vb %b%b", $time, r1, r2, v1, v2, rb1, rb2, vb1, vb2);
    end
  end
  logic signed [31:0] g1, g2, gb1, gb2;
  logic gz1, gz2, gzb1, gzb2;
  task automatic one(input logic signed [31:0] a, input logic signed [31:0] d);
    bit h1, h2, hb1, hb2;
    int t;
    while (!(r1 && r2 && rb1 && rb2)) @(posedge clk);
    num <= a; den <= d; go <= 1'b1;
    @(posedge clk); go <= 1'b0;
    h1 = 0; h2 = 0; hb1 = 0; hb2 = 0; t = 0;
    while (!(h1 && h2 && hb1 && hb2)) begin
      @(posedge clk); #1;
      if (v1)  begin h1 = 1;  g1 = q1;  gz1 = z1;  end
      if (v2)  begin h2 = 1;  g2 = q2;  gz2 = z2;  end
      if (vb1) begin hb1 = 1; gb1 = qb1; gzb1 = zb1; end
      if (vb2) begin hb2 = 1; gb2 = qb2; gzb2 = zb2; end
      if (++t > 200) begin $display("HANG %0d / %0d", a, d); $finish; end
    end
    n++;
    if (g1 !== g2 || gz1 !== gz2 || gb1 !== gb2 || gzb1 !== gzb2) begin
      bad++;
      if (bad < 10) $display("DIFF %0d / %0d: %0d %0d | %0d %0d", a, d, g1, g2, gb1, gb2);
    end
  endtask
  initial begin
    go = 1'b0; num = 0; den = 1;
    repeat (4) @(posedge clk); rst_n = 1'b1; @(posedge clk);
    for (int d = -600; d <= 600; d++) begin
      one(32'sd0, d); one(32'sd1, d); one(-32'sd1, d); one(32'sh01FF_FFFF, d); one(-32'sh0200_0000, d);
      one(32'sh7FFF_FFFF, d); one(32'sh8000_0000, d);
      for (int k = 0; k < 8; k++) one($random, d);
    end
    for (int k = 0; k < 200000; k++) one($random, (k & 1) ? ($random % 300) : $random);
    $display("tb_m2_raster_div_lat: %0d divides x 2 ports, %0d results differ, %0d cycles differ", n, bad, cyc);
    if (bad == 0 && cyc == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
