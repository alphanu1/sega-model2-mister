// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
//
// m2_geo_engine tied to the shared FP pool, as the integrated design ties it.
// Testing the sequencer with private arithmetic would prove something the real
// thing does not do -- see rtl/video/m2_fp_pool.sv.
`timescale 1ns/1ps
module m2_geo_engine_top (
  input  logic clk, rst_n, start,
  input  logic [31:0] oba, obc,
  output logic busy,
  input  logic mat_we, input logic [3:0] mat_idx, input logic [31:0] mat_data,
  input  logic [31:0] foc_x, foc_y,
  output logic mem_req, output logic [23:0] mem_addr,
  input  logic [31:0] mem_data, input logic mem_ack,
  output logic poly_valid, input logic poly_ready,
  output logic [31:0] v0x,v0y,v0z, v1x,v1y,v1z, v2x,v2y,v2z, v3x,v3y,v3z,
  output logic [31:0] poly_attr,
  output logic [15:0] dbg_polys, dbg_objects, dbg_capped
);
  logic        mul_req, add_req, add_sub, mul_gnt, mul_rsp, add_gnt, add_rsp;
  logic [31:0] mul_a, mul_b, mul_res, add_a, add_b, add_res;
  // TWO multiply clients: the transform (client 0) and the engine's focus
  // multiplies (client 1). The pool is built for exactly this.
  logic        fmul_req, fmul_gnt, fmul_rsp;
  logic [31:0] fmul_a, fmul_b, fmul_res;

  m2_geo_engine u_eng (
    .clk(clk), .rst_n(rst_n), .start(start), .oba(oba), .obc(obc), .busy(busy),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .foc_x(foc_x), .foc_y(foc_y),
    .fmul_req(fmul_req), .fmul_a(fmul_a), .fmul_b(fmul_b),
    .fmul_gnt(fmul_gnt), .fmul_rsp(fmul_rsp), .fmul_res(fmul_res),
    .mem_req(mem_req), .mem_addr(mem_addr), .mem_data(mem_data), .mem_ack(mem_ack),
    .mul_req(mul_req), .mul_a(mul_a), .mul_b(mul_b),
    .mul_gnt(mul_gnt), .mul_rsp(mul_rsp), .mul_res(mul_res),
    .add_req(add_req), .add_a(add_a), .add_b(add_b), .add_sub(add_sub),
    .add_gnt(add_gnt), .add_rsp(add_rsp), .add_res(add_res),
    .poly_valid(poly_valid), .poly_ready(poly_ready),
    .v0x(v0x), .v0y(v0y), .v0z(v0z), .v1x(v1x), .v1y(v1y), .v1z(v1z),
    .v2x(v2x), .v2y(v2y), .v2z(v2z), .v3x(v3x), .v3y(v3y), .v3z(v3z),
    .poly_attr(poly_attr), .dbg_polys(dbg_polys), .dbg_objects(dbg_objects), .dbg_capped(dbg_capped)
  );

  logic [1:0] p_mul_req, p_mul_gnt, p_mul_rsp;
  logic [1:0] p_add_req, p_add_gnt, p_add_rsp, p_add_sub;
  logic [31:0] p_mul_a [2], p_mul_b [2], p_add_a [2], p_add_b [2];
  assign p_mul_req = {fmul_req, mul_req};
  assign p_mul_a[0] = mul_a;  assign p_mul_b[0] = mul_b;
  assign p_mul_a[1] = fmul_a; assign p_mul_b[1] = fmul_b;
  assign p_add_req = {1'b0, add_req};
  assign p_add_a[0] = add_a; assign p_add_b[0] = add_b;
  assign p_add_a[1] = 32'd0; assign p_add_b[1] = 32'd0;
  assign p_add_sub = {1'b0, add_sub};
  assign mul_gnt  = p_mul_gnt[0]; assign mul_rsp  = p_mul_rsp[0];
  assign fmul_gnt = p_mul_gnt[1]; assign fmul_rsp = p_mul_rsp[1];
  assign fmul_res = mul_res;
  assign add_gnt = p_add_gnt[0]; assign add_rsp = p_add_rsp[0];

  m2_fp_pool #(.NC(2)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(p_mul_req), .mul_a(p_mul_a), .mul_b(p_mul_b),
    .mul_gnt(p_mul_gnt), .mul_rsp(p_mul_rsp), .mul_res(mul_res),
    .add_req(p_add_req), .add_a(p_add_a), .add_b(p_add_b), .add_sub(p_add_sub),
    .add_gnt(p_add_gnt), .add_rsp(p_add_rsp), .add_res(add_res),
    .div_req('0), .div_a('{32'd0, 32'd0}), .div_b('{32'd0, 32'd0}),
    .div_gnt(), .div_rsp(), .div_res()
  );
endmodule
