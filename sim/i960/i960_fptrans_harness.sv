// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R845: i960_fptrans on the real i960 double units, wired as i960_top wires
// them while the sequencer runs (operand A on .a, B on .b, the result picked
// by the sequencer's selects). tb_i960_fptrans drives it with vectors from
// tools/i960_fptrans.py --vec, whose interpreter is the reference.


module i960_fptrans_harness #(
  parameter bit LOG = 1'b0   // R935: the 2C program (logrl)
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic  [1:0] entry,
  input  logic        lg,     // R935
  input  logic [63:0] x,
  input  logic [63:0] y,
  output logic [63:0] res,
  output logic        fin,
  output logic        busy
);
  logic        act, add_req, mul_req, div_req, sub, sel_add, sel_mul, sel_div;
  logic        add_done, mul_done, div_done;
  logic [63:0] opa, opb, add_y, mul_y, div_y;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        div_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  i960_fptrans #(.LOG(LOG)) u_tr (
    .clk(clk), .rst_n(rst_n), .start(start), .entry(entry), .lg(lg), .x(x), .y(y),
    .act(act), .opa(opa), .opb(opb),
    .add_req(add_req), .mul_req(mul_req), .div_req(div_req), .sub(sub),
    .sel_add(sel_add), .sel_mul(sel_mul), .sel_div(sel_div),
    .add_done(add_done), .mul_done(mul_done), .div_done(div_done),
    .res(res), .fin(fin)
  );
  i960_fpadd u_add (.clk(clk), .rst_n(rst_n), .req(add_req), .sub(sub), .a(opa), .b(opb),
                    .y(add_y), .done(add_done));
  i960_fpmul u_mul (.clk(clk), .rst_n(rst_n), .req(mul_req), .a(opa), .b(opb),
                    .y(mul_y), .done(mul_done));
  i960_fpdiv u_div (.clk(clk), .rst_n(rst_n), .req(div_req), .a(opa), .b(opb),
                    .y(div_y), .busy(div_busy), .done(div_done));
  assign res  = sel_add ? add_y : sel_mul ? mul_y : sel_div ? div_y : add_y;
  assign busy = act;
endmodule
