// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: the LUT-RAM register file (rtl/cpu/i960/i960_regs.sv) and the
// flip-flop one it replaced (sim/i960/ref/i960_regs_ff.sv, c3ee7d2) on the
// same inputs. `diff` has one bit per output group; any set bit on any cycle
// is a failure (tb_i960_regs_miter.cpp).
module i960_regs_miter (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [4:0]  ra1, ra2, wa,
  input  logic [31:0] wd,
  input  logic        we,
  input  logic        op_call, op_ret, op_flushreg,
  input  logic [31:0] call_ip, call_target, call_stack,
  input  logic [2:0]  call_type,
  input  logic        boot_fp_we,
  input  logic [31:0] boot_fp,
  input  logic [31:0] mem_rdata,
  input  logic        mem_ack,
  output logic [12:0] diff,
  output logic        busy_o,
  output logic        mem_req_o,
  output logic [31:0] rcache_pos_o
);
  logic [31:0] rd1[2], rd2[2], next_ip[2], cur_fp[2], cur_sp[2], dbg_rip[2], dbg_pfp[2];
  logic [31:0] mem_addr[2], mem_wdata[2];
  logic signed [31:0] pos[2];
  logic [2:0]  pfpt[2];
  logic        busy[2], nipv[2], ret_un[2], tomem[2], mreq[2], mwe[2];

  i960_regs u_new (
    .clk, .rst_n, .ra1, .ra2, .rd1(rd1[0]), .rd2(rd2[0]), .wa, .wd, .we,
    .op_call, .op_ret, .ret_unsupported(ret_un[0]), .op_flushreg, .call_ip, .call_target,
    .call_type, .call_stack, .busy(busy[0]), .next_ip(next_ip[0]), .next_ip_valid(nipv[0]),
    .cur_fp(cur_fp[0]), .cur_sp(cur_sp[0]), .cur_pfp_type(pfpt[0]), .boot_fp_we, .boot_fp,
    .dbg_rip(dbg_rip[0]), .dbg_pfp(dbg_pfp[0]), .dbg_rcache_pos(pos[0]),
    .dbg_to_memory(tomem[0]), .mem_req(mreq[0]), .mem_we(mwe[0]), .mem_addr(mem_addr[0]),
    .mem_wdata(mem_wdata[0]), .mem_rdata, .mem_ack);
  i960_regs_ff u_old (
    .clk, .rst_n, .ra1, .ra2, .rd1(rd1[1]), .rd2(rd2[1]), .wa, .wd, .we,
    .op_call, .op_ret, .ret_unsupported(ret_un[1]), .op_flushreg, .call_ip, .call_target,
    .call_type, .call_stack, .busy(busy[1]), .next_ip(next_ip[1]), .next_ip_valid(nipv[1]),
    .cur_fp(cur_fp[1]), .cur_sp(cur_sp[1]), .cur_pfp_type(pfpt[1]), .boot_fp_we, .boot_fp,
    .dbg_rip(dbg_rip[1]), .dbg_pfp(dbg_pfp[1]), .dbg_rcache_pos(pos[1]),
    .dbg_to_memory(tomem[1]), .mem_req(mreq[1]), .mem_we(mwe[1]), .mem_addr(mem_addr[1]),
    .mem_wdata(mem_wdata[1]), .mem_rdata, .mem_ack);

  assign diff = {rd1[0] != rd1[1], rd2[0] != rd2[1],
                 {busy[0], nipv[0], ret_un[0]} != {busy[1], nipv[1], ret_un[1]},
                 nipv[0] && (next_ip[0] != next_ip[1]),
                 next_ip[0] != next_ip[1],
                 cur_fp[0] != cur_fp[1], cur_sp[0] != cur_sp[1], pfpt[0] != pfpt[1],
                 {dbg_rip[0], dbg_pfp[0]} != {dbg_rip[1], dbg_pfp[1]},
                 {pos[0], tomem[0]} != {pos[1], tomem[1]},
                 {mreq[0], mwe[0]} != {mreq[1], mwe[1]},
                 mem_addr[0] != mem_addr[1], mem_wdata[0] != mem_wdata[1]};
  assign busy_o = busy[0];
  assign mem_req_o = mreq[0];
  assign rcache_pos_o = pos[0];
endmodule
