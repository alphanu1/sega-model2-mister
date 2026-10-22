// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// ---------------------------------------------------------------------------
//
// R845: THE LONG-REAL TRANSCENDENTALS -- sinrl, cosrl, tanrl, atanrl -- AS
// MICROCODE ON THE i960's OWN DOUBLE UNITS.
//
// Virtua Cop runs them from 14.73 s (tanrl, cosrl), 18.3 s (atanrl) and in
// play (sinrl), some 60 a second. MAME computes them with the host's libm;
// the programs (tools/i960_fptrans.py, which also generates
// i960_fptrans_rom.svh and is this module's reference) work in double-double
// and round once, so the result is the correctly rounded value -- what glibc
// returns on ~99.8% of arguments and the 80960KB's extended-precision
// microcode would.
//
// The machine: 128 x 64-bit registers in M10K (the first 68 hold the
// constants, initialised and never written), a 512-word microcode ROM, a
// four-deep return stack, and two operand registers that drive the adder,
// multiplier and divider i960_top already has (it muxes them in while `act`).
// One instruction at a time:
//
//   FETCH  the ROM word        DEC  decode, present register a
//   RA     operand A <- a      RB   operand B <- b
//   ISSUE  request the unit    WAIT its done; the result into register d
//
//   op  0 ADD  d = a + b     1 SUB  d = a - b     2 MUL  d = a * b
//       3 DIV  d = a / b     4 BR   if cond(a) goto t     5 JMP t
//       6 CALL t             7 RET                8 LDX d = x - 0
//       9 LDY  d = y - 0    10 END  result = a - 0 (on the adder)
//   word: op[31:28] d[27:21] a[20:14] b[13:7] ma[6:5] mb[4:3]
//         BR: cond[27:25] inv[24] a[20:14] t[8:0]; JMP / CALL: t[8:0]
//   modifiers (ma / mb): 1 negate, 2 abs, 3 -abs -- on the sign bit only
//   conditions (on register a, unmodified): 0 sign, 1 zero, 2 NaN, 3 inf,
//   4 bit 0, 5 bit 1 (the quadrant, from a 1.5 x 2^52 rounding add)
//
// The units see A on their .a port and B on .b: a - b, a / b, as the i960's
// src2 - src1 and src2 / src1 are wired.

// R935: LOG -- the 2C build's program (i960_fptrans_rom_log.svh, 465 words):
// the same four (their Horner steps through one subroutine, the same
// operations) plus logrl (entry 4: y * log2 x, House of the Dead from its
// stone-wall section), and two loads that take x apart for it: LDE (op 11)
// d = x's unbiased exponent as a double -- the adder's (MAGIC + e - 1023) -
// MAGIC, exact -- and LDM (op 12) d = x's mantissa in [1, 2). LOG = 0 is
// R845's sequencer and ROM exactly (the 2A builds).
module i960_fptrans #(
  parameter bit LOG = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,        // one cycle; entry and x / y valid from here
  input  logic  [2:0] entry,        // 0 sin, 1 cos, 2 tan, 3 atan (y = src2, x = src1); 4 log (LOG)
  input  logic [63:0] x,
  input  logic [63:0] y,
  output logic        act,          // the units' operands are opa / opb
  output logic [63:0] opa,          // to the units' .a
  output logic [63:0] opb,          // to the units' .b
  output logic        add_req, mul_req, div_req,   // one-cycle requests
  output logic        sub,          // the adder subtracts
  output logic        sel_add, sel_mul, sel_div,   // which unit's y is the result
  input  logic        add_done, mul_done, div_done,
  input  logic [63:0] res,          // the selected unit's y (i960_top's fp_res_wide)
  output logic        fin           // one cycle: END's result is on res
);

  `include "i960_fptrans_rom.svh"
  `include "i960_fptrans_rom_log.svh"
  localparam int UW = 9;               // program counter width (both programs fit 512 words)

  // ------------------------------------------------------------ storage
  (* ramstyle = "M10K" *) logic [63:0] rf [128];
  initial for (int i = 0; i < 128; i++) rf[i] = LOG ? uconst_log(7'(i)) : uconst(7'(i));

  logic [6:0]  raddr;
  logic [63:0] q;
  logic        we;
  logic [6:0]  waddr;
  always_ff @(posedge clk) begin
    if (we) rf[waddr] <= res;
    q <= rf[raddr];
  end

  logic [UW-1:0] upc;
  logic [31:0] uw;
  generate if (LOG) begin : g_rom_log
    always_ff @(posedge clk) uw <= ucode_log(upc);
  end else begin : g_rom
    always_ff @(posedge clk) uw <= ucode(upc);
  end endgenerate

  // ------------------------------------------------------------ decode
  wire [3:0] op   = uw[31:28];
  wire [6:0] f_d  = uw[27:21];
  wire [6:0] f_a  = uw[20:14];
  wire [6:0] f_b  = uw[13:7];
  wire [1:0] f_ma = uw[6:5];
  wire [1:0] f_mb = uw[4:3];
  wire [2:0] f_c  = uw[27:25];
  wire       f_i  = uw[24];
  wire [UW-1:0] f_t = uw[UW-1:0];

  function automatic logic [63:0] modv(input logic [63:0] v, input logic [1:0] m);
    case (m)
      2'd1:    return {~v[63], v[62:0]};
      2'd2:    return {1'b0,   v[62:0]};
      2'd3:    return {1'b1,   v[62:0]};
      default: return v;
    endcase
  endfunction

  wire q_nan  = (q[62:52] == 11'h7ff) && (q[51:0] != 52'd0);
  wire q_inf  = (q[62:52] == 11'h7ff) && (q[51:0] == 52'd0);
  logic cond;
  always_comb begin
    case (f_c)
      3'd0:    cond = q[63];
      3'd1:    cond = (q[62:0] == 63'd0);
      3'd2:    cond = q_nan;
      3'd3:    cond = q_inf;
      3'd4:    cond = q[0];
      3'd5:    cond = q[1];
      default: cond = 1'b0;
    endcase
  end

  // ------------------------------------------------------------ sequencer
  typedef enum logic [3:0] {S_IDLE, S_FETCH, S_DEC, S_RA, S_RB, S_ISSUE, S_WAIT, S_BR, S_END} st_t;
  st_t st;
  logic [UW-1:0] ras [4];
  // R935: LDE's operand, MAGIC + (e - 1023) as a two's-complement add on the
  // low bits (MAGIC's low 51 are zero, so this IS the double MAGIC + e - 1023)
  wire  [11:0] x_eu  = {1'b0, x[62:52]} - 12'd1023;
  wire  [63:0] x_lde = 64'h4338_0000_0000_0000 + {{52{x_eu[11]}}, x_eu};
  wire  [63:0] x_ldm = {1'b0, 11'h3ff, x[51:0]};
  logic [1:0] sp;
  logic [1:0] unit;          // 0 add, 1 sub, 2 mul, 3 div

  assign raddr = (st == S_RA) ? f_b : f_a;   // DEC presents a, RA presents b

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; upc <= '0; sp <= 2'd0; unit <= 2'd0;
      opa <= 64'd0; opb <= 64'd0;
      add_req <= 1'b0; mul_req <= 1'b0; div_req <= 1'b0;
      we <= 1'b0; waddr <= 7'd0; fin <= 1'b0; act <= 1'b0;
      for (int i = 0; i < 4; i++) ras[i] <= '0;
    end else begin
      add_req <= 1'b0; mul_req <= 1'b0; div_req <= 1'b0;
      we <= 1'b0; fin <= 1'b0;
      case (st)
        S_IDLE: if (start) begin
          upc <= LOG ? UW'(entry) : UW'(entry[1:0]); sp <= 2'd0; act <= 1'b1; st <= S_FETCH;
        end
        S_FETCH: st <= S_DEC;                     // uw <= ucode(upc) this edge
        S_DEC: begin
          case (op)
            4'd4: st <= S_BR;                     // q <- register a next edge
            4'd5: begin upc <= f_t; st <= S_FETCH; end
            4'd6: begin ras[sp] <= upc + UW'(1); sp <= sp + 2'd1; upc <= f_t; st <= S_FETCH; end
            4'd7: begin upc <= ras[sp - 2'd1]; sp <= sp - 2'd1; st <= S_FETCH; end
            4'd8, 4'd9: begin
              opa <= (op == 4'd8) ? x : y; opb <= 64'd0; unit <= 2'd1; st <= S_ISSUE;
            end
            4'd11, 4'd12: if (LOG) begin   // R935: LDE / LDM
              opa <= (op == 4'd11) ? x_lde : x_ldm;
              opb <= (op == 4'd11) ? 64'h4338_0000_0000_0000 : 64'd0;
              unit <= 2'd1; st <= S_ISSUE;
            end else begin
              unit <= 2'd1; st <= S_RA;      // never in the 2A program: as default
            end
            default: begin
              unit <= (op == 4'd0) ? 2'd0 : (op == 4'd2) ? 2'd2 : (op == 4'd3) ? 2'd3 : 2'd1;
              st <= S_RA;
            end
          endcase
        end
        S_RA: begin opa <= modv(q, f_ma); st <= S_RB; end
        S_RB: begin opb <= (op == 4'd10) ? 64'd0 : modv(q, f_mb); st <= S_ISSUE; end
        S_BR: begin
          upc <= (cond ^ f_i) ? f_t : upc + UW'(1);
          st  <= S_FETCH;
        end
        S_ISSUE: begin
          add_req <= (unit == 2'd0) || (unit == 2'd1);
          mul_req <= (unit == 2'd2);
          div_req <= (unit == 2'd3);
          st <= S_WAIT;
        end
        S_WAIT: if ((sel_add && add_done) || (sel_mul && mul_done) || (sel_div && div_done)) begin
          if (op == 4'd10) begin
            // fin with the adder still selected: i960_top writes res back
            // in this cycle; act drops in the next
            fin <= 1'b1; st <= S_END;
          end else begin
            we <= 1'b1; waddr <= f_d;
            upc <= upc + UW'(1); st <= S_FETCH;
          end
        end
        S_END: begin act <= 1'b0; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign sub     = (unit == 2'd1);
  assign sel_add = act && ((unit == 2'd0) || (unit == 2'd1));
  assign sel_mul = act && (unit == 2'd2);
  assign sel_div = act && (unit == 2'd3);

endmodule
