// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_volume (study R894): m2_volume, every 16-bit input at every code.
//   * the output is floor(x * gain / 256) clamped to [-32768, 32767] --
//     never wrapped: its sign is the input's (or it is 0);
//   * the 0-100% codes (0-2, 7-14 since the list rises to 400% then wraps) equal R829's 9-bit stage (the product's [23:8]) bit for bit;
//   * code 15 (never on the menu) is code 0's 80%.
// iverilog -g2012 -o tb rtl/sound/m2_volume.sv sim/sound/tb_m2_volume.sv && vvp tb
`timescale 1ns/1ps

module tb_m2_volume;
  logic clk = 1'b0;
  logic [3:0] code;
  logic signed [15:0] in_l, in_r, out_l, out_r;
  m2_volume dut (.clk(clk), .code(code), .in_l(in_l), .in_r(in_r), .out_l(out_l), .out_r(out_r));

  function automatic int gain_of(input int c);
    case (c)
      0: gain_of = 205;  1: gain_of = 230;  2: gain_of = 256;  3: gain_of = 384;
      4: gain_of = 512;  5: gain_of = 768;  6: gain_of = 1024; 7: gain_of = 0;
      8: gain_of = 26;   9: gain_of = 51;   10: gain_of = 77;  11: gain_of = 102;
      12: gain_of = 128; 13: gain_of = 154; 14: gain_of = 179; default: gain_of = 205;
    endcase
  endfunction

  int c, x, g, want, bad, sat_n, n;
  longint p;
  logic signed [25:0] old;
  initial begin
    bad = 0; sat_n = 0; n = 0;
    for (c = 0; c < 16; c++) begin
      code = 4'(c);
      g = gain_of(c);
      for (x = -32768; x < 32768; x++) begin
        in_l = 16'(x); in_r = 16'(-1 - x);
        #1 clk = 1'b1; #1 clk = 1'b0;
        p = longint'(x) * g;
        want = int'(p >>> 8);
        if (want > 32767) begin want = 32767; sat_n++; end
        if (want < -32768) begin want = -32768; sat_n++; end
        n++;
        if (out_l != 16'(want)) begin
          if (bad < 10) $display("code %0d x %0d: out %0d want %0d", c, x, out_l, want);
          bad++;
        end
        if ((x > 0 && out_l < 0) || (x < 0 && out_l > 0)) begin
          if (bad < 10) $display("code %0d x %0d: WRAPPED to %0d", c, x, out_l);
          bad++;
        end
        // the right channel: the same stage, another input
        p = longint'(-1 - x) * g;
        want = int'(p >>> 8);
        if (want > 32767) want = 32767;
        if (want < -32768) want = -32768;
        if (out_r != 16'(want)) begin
          if (bad < 10) $display("code %0d x %0d: right out %0d want %0d", c, x, out_r, want);
          bad++;
        end
        if (g <= 256) begin   // the 0-100% codes: R829's stage bit for bit
          old = $signed(16'(x)) * $signed({1'b0, 9'(g)});
          if (out_l != old[23:8]) begin
            if (bad < 10) $display("code %0d x %0d: out %0d, R829's stage %0d", c, x, out_l, $signed(old[23:8]));
            bad++;
          end
        end
      end
    end
    $display("tb_m2_volume: %0d inputs x 16 codes (%0d), %0d clamped, %0d wrong: %s", 65536, n, sat_n, bad,
             bad ? "FAIL" : "PASS");
    $finish;
  end
endmodule
