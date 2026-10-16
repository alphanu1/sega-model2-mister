// SPDX-License-Identifier: GPL-3.0-or-later
//
// R848: m2_fp_pool's grant, written directly (rr_onehot), against the grant
// it replaced -- the one-hot decode of rr_pick's winner when anything
// requests. Every request vector against every pointer value, NC = 2..6.
//
//   iverilog -g2012 -o obj_fp_pool_gnt sim/video/tb_fp_pool_gnt.sv && vvp obj_fp_pool_gnt
//   (make test_fp_pool_gnt)

`timescale 1ns/1ps

module pool_gnt_check #(parameter int unsigned NC = 4) (output int fails, output int checks);
  localparam int unsigned CW   = (NC > 1) ? $clog2(NC) : 1;
  localparam int unsigned SUMW = CW + 1;

  // m2_fp_pool's rr_pick, verbatim
  function automatic [CW-1:0] rr_pick(input logic [NC-1:0] req, input logic [CW-1:0] first);
    logic [2*NC-1:0] dbl;
    logic [NC-1:0]   rot;
    logic [CW-1:0]   best_k;
    logic [CW:0]     sum;
    logic            found;
    dbl    = {req, req};
    rot    = dbl[first +: NC];
    best_k = '0;
    found  = 1'b0;
    for (int k = NC - 1; k >= 0; k--) begin
      if (rot[k]) begin
        best_k = CW'(k);
        found  = 1'b1;
      end
    end
    sum     = {1'b0, first} + {1'b0, best_k};
    rr_pick = found ? ((sum >= SUMW'(NC)) ? CW'(sum - SUMW'(NC)) : CW'(sum))
                    : first;
  endfunction

  // m2_fp_pool's rr_onehot, verbatim
  function automatic [NC-1:0] rr_onehot(input logic [NC-1:0] req, input logic [CW-1:0] first);
    logic [NC-1:0] g;
    logic          seen;
    g = '0;
    for (int f = 0; f < NC; f++) begin
      if (first == CW'(f)) begin
        seen = 1'b0;
        for (int j = 0; j < NC; j++) begin
          if (req[(f + j) % NC] && !seen) g[(f + j) % NC] = 1'b1;
          seen = seen | req[(f + j) % NC];
        end
      end
    end
    rr_onehot = g;
  endfunction

  initial begin
    logic [NC-1:0] old_g, new_g, req;
    logic [CW-1:0] first, w;
    fails = 0; checks = 0;
    // the pointer only ever holds 0..NC-1 (it is loaded with win + 1, wrapped)
    for (int f = 0; f < NC; f++)
      for (int r = 0; r < (1 << NC); r++) begin
        req   = NC'(r);
        first = CW'(f);
        w     = rr_pick(req, first);
        old_g = '0;
        if (|req) old_g[w] = 1'b1;
        new_g = rr_onehot(req, first);
        checks++;
        if (old_g !== new_g) begin
          fails++;
          if (fails < 10) $display("NC=%0d first=%0d req=%b: old %b new %b", NC, f, req, old_g, new_g);
        end
      end
  end
endmodule

module tb_fp_pool_gnt;
  int f2, c2, f3, c3, f4, c4, f5, c5, f6, c6;
  pool_gnt_check #(.NC(2)) u2 (.fails(f2), .checks(c2));
  pool_gnt_check #(.NC(3)) u3 (.fails(f3), .checks(c3));
  pool_gnt_check #(.NC(4)) u4 (.fails(f4), .checks(c4));
  pool_gnt_check #(.NC(5)) u5 (.fails(f5), .checks(c5));
  pool_gnt_check #(.NC(6)) u6 (.fails(f6), .checks(c6));
  initial begin
    #1;
    $display("m2_fp_pool grant: checks=%0d fails=%0d", c2 + c3 + c4 + c5 + c6, f2 + f3 + f4 + f5 + f6);
    if (f2 + f3 + f4 + f5 + f6 != 0) $fatal(1, "FAIL");
    $display("PASS");
    $finish;
  end
endmodule
