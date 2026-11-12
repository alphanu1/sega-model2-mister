// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R998: the pipelined i960_fptrans (n_) beside the one before it (o_), each
// on its own adder, multiplier and divider, wired as i960_top wires them.
// Both start together; tb_i960_fptrans_ab waits for both and compares the
// results and every register-file write (n_we / o_we with their address and
// data). On the 2C branch the reference is R935's sequencer
// (i960_fptrans_r935: the 2C build's before R998), which with LOG = 0 is
// R845's exactly; LOG = 1 is the 2C program, logrl included (lg).

module i960_fptrans_ab_harness #(
  parameter bit LOG = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic  [1:0] entry,
  input  logic        lg,
  input  logic [63:0] x,
  input  logic [63:0] y,
  output logic [63:0] n_res, o_res,
  output logic        n_fin, o_fin,
  output logic        n_act, o_act,
  output logic        n_we,  o_we,
  output logic  [6:0] n_wa,  o_wa
);
  logic        n_add_req, n_mul_req, n_div_req, n_sub, n_sel_add, n_sel_mul, n_sel_div;
  logic        n_add_done, n_mul_done, n_div_done;
  logic [63:0] n_opa, n_opb, n_add_y, n_mul_y, n_div_y;
  logic        o_add_req, o_mul_req, o_div_req, o_sub, o_sel_add, o_sel_mul, o_sel_div;
  logic        o_add_done, o_mul_done, o_div_done;
  logic [63:0] o_opa, o_opb, o_add_y, o_mul_y, o_div_y;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        n_div_busy, o_div_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  i960_fptrans #(.LOG(LOG)) u_n (
    .clk(clk), .rst_n(rst_n), .start(start), .entry(entry), .lg(lg), .x(x), .y(y),
    .act(n_act), .opa(n_opa), .opb(n_opb),
    .add_req(n_add_req), .mul_req(n_mul_req), .div_req(n_div_req), .sub(n_sub),
    .sel_add(n_sel_add), .sel_mul(n_sel_mul), .sel_div(n_sel_div),
    .add_done(n_add_done), .mul_done(n_mul_done), .div_done(n_div_done),
    .res(n_res), .fin(n_fin)
  );
  i960_fpadd u_nadd (.clk(clk), .rst_n(rst_n), .req(n_add_req), .sub(n_sub), .a(n_opa), .b(n_opb),
                     .y(n_add_y), .done(n_add_done));
  i960_fpmul u_nmul (.clk(clk), .rst_n(rst_n), .req(n_mul_req), .a(n_opa), .b(n_opb),
                     .y(n_mul_y), .done(n_mul_done));
  i960_fpdiv u_ndiv (.clk(clk), .rst_n(rst_n), .req(n_div_req), .a(n_opa), .b(n_opb),
                     .y(n_div_y), .busy(n_div_busy), .done(n_div_done));
  assign n_res = n_sel_add ? n_add_y : n_sel_mul ? n_mul_y : n_sel_div ? n_div_y : n_add_y;

  i960_fptrans_r935 #(.LOG(LOG)) u_o (
    .clk(clk), .rst_n(rst_n), .start(start), .entry(entry), .lg(lg), .x(x), .y(y),
    .act(o_act), .opa(o_opa), .opb(o_opb),
    .add_req(o_add_req), .mul_req(o_mul_req), .div_req(o_div_req), .sub(o_sub),
    .sel_add(o_sel_add), .sel_mul(o_sel_mul), .sel_div(o_sel_div),
    .add_done(o_add_done), .mul_done(o_mul_done), .div_done(o_div_done),
    .res(o_res), .fin(o_fin)
  );
  i960_fpadd u_oadd (.clk(clk), .rst_n(rst_n), .req(o_add_req), .sub(o_sub), .a(o_opa), .b(o_opb),
                     .y(o_add_y), .done(o_add_done));
  i960_fpmul u_omul (.clk(clk), .rst_n(rst_n), .req(o_mul_req), .a(o_opa), .b(o_opb),
                     .y(o_mul_y), .done(o_mul_done));
  i960_fpdiv u_odiv (.clk(clk), .rst_n(rst_n), .req(o_div_req), .a(o_opa), .b(o_opb),
                     .y(o_div_y), .busy(o_div_busy), .done(o_div_done));
  assign o_res = o_sel_add ? o_add_y : o_sel_mul ? o_mul_y : o_sel_div ? o_div_y : o_add_y;

  // the register files' write ports (the data is each one's res)
  assign n_we = u_n.we;  assign n_wa = u_n.waddr;
  assign o_we = u_o.we;  assign o_wa = u_o.waddr;
endmodule
