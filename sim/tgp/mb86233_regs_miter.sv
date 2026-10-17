// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: the TGP register file with rf in LUT RAM (rtl/tgp/mb86233_regs.sv)
// and the flip-flop one it replaced (sim/tgp/ref/mb86233_regs_ff.sv) on the
// same inputs; `diff` is set on any cycle where any output differs.
module mb86233_regs_miter (
  input  logic        clk, rst_n,
  input  logic [5:0]  rd_addr,
  input  logic        wr_en,
  input  logic [5:0]  wr_addr,
  input  logic [31:0] wr_data, rf_fifo_rdata,
  input  logic        alu_d_we, alu_p_we,
  input  logic [31:0] alu_d, alu_p,
  input  logic        clr_a, clr_b, clr_d,
  input  logic        agu_x0_we, agu_x1_we,
  input  logic [15:0] agu_x0, agu_x1,
  input  logic [7:0]  c0, c1,
  output logic        diff,
  output logic [31:0] rd_new
);
  localparam int OW = 32 + 1 + 1 + 1 + 1 + 32 + 1 + 8 + 1 + 8 + 4 * 32 + 7 * 16 + 8 + 16 + 32;
  logic [OW-1:0] o [2];
  genvar g;
  generate for (g = 0; g < 2; g = g + 1) begin : g_dut
    logic [31:0] rd_data, rf_fifo_wdata, reg_a, reg_b, reg_d, reg_p, bank_reg;
    logic        rd_unimpl, wr_unimpl, rf_fifo_rd, rf_fifo_wr, c0_we, c1_we;
    logic [7:0]  c0_wd, c1_wd, sft;
    logic [15:0] b0, b1, x0, x1, i0, i1, vsmr, mask;
    if (g == 0) begin : g_new
      mb86233_regs u (.*);
    end else begin : g_old
      mb86233_regs_ff u (.*);
    end
    assign o[g] = {rd_data, rd_unimpl, wr_unimpl, rf_fifo_rd, rf_fifo_wr, rf_fifo_wdata,
                   c0_we, c0_wd, c1_we, c1_wd, reg_a, reg_b, reg_d, reg_p,
                   b0, b1, x0, x1, i0, i1, vsmr, sft, mask, bank_reg};
  end endgenerate
  assign diff = o[0] != o[1];
  assign rd_new = g_dut[0].rd_data;
endmodule
