// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: m2_geo_xform with the matrix in LUT RAM against the flip-flop one
// (sim/video/ref/m2_geo_xform_ff.sv) on the same inputs; `diff` on any output.
module m2_geo_xform_miter (
  input  logic        clk, rst_n,
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,
  input  logic        in_valid,
  input  logic [31:0] in_x, in_y, in_z,
  input  logic        in_translate,
  input  logic        mul_gnt, mul_rsp,
  input  logic [31:0] mul_res,
  input  logic        add_gnt, add_rsp,
  input  logic [31:0] add_res,
  output logic        diff,
  output logic        out_valid_o,
  output logic        mul_req_o
);
  localparam int OW = 1 + 1 + 64 + 1 + 64 + 1 + 1 + 96;
  logic [OW-1:0] o [2];
  genvar g;
  generate for (g = 0; g < 2; g = g + 1) begin : g_dut
    logic        in_ready, mul_req, add_req, add_sub, out_valid;
    logic [31:0] mul_a, mul_b, add_a, add_b, out_x, out_y, out_z;
    if (g == 0) begin : g_new
      m2_geo_xform u (.*);
    end else begin : g_old
      m2_geo_xform_ff u (.*);
    end
    assign o[g] = {in_ready, mul_req, mul_a, mul_b, add_req, add_a, add_b, add_sub, out_valid,
                   out_x, out_y, out_z};
  end endgenerate
  assign diff = o[0] != o[1];
  assign out_valid_o = g_dut[0].out_valid;
  assign mul_req_o = g_dut[0].mul_req;
endmodule
