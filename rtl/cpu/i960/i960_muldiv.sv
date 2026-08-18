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
// Transcribed from MAME's i960 device, REG blocks 0x67, 0x70 and 0x74
// (BSD-3-Clause, Farfetch'd and R. Belmont). See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB multiply, divide, remainder and modulo — multi-cycle.
//
//   0x70.1 mulo   0x70.8 remo   0x70.b divo        unsigned
//   0x74.1 muli   0x74.8 remi   0x74.9 modi   0x74.b divi   signed
//   0x67.0 emul   0x67.1 ediv                              64-bit forms
//
// The multiplier is written as a plain `*` so Quartus infers DSP blocks: the
// part has 112 and Model 1 uses 49, so this is the cheap direction. The divider
// is iterative restoring division, which cannot use DSP and costs a cycle per
// bit. The reference charges 18 cycles for a multiply and 37 for a divide, so
// there is budget for both.
//
// ---------------------------------------------------------------------------
// DIVISION BY ZERO IS UNDEFINED, EXCEPT FOR ONE OPCODE.
//
// `divo` carries an explicit guard in the reference, and the comment is the
// author's own:
//
//     case 0xb: // divo
//       if (t1 == 0)    // HACK!
//         set_ri(opcode, 0);
//
// `divi`, `remo`, `remi` and `modi` have no such guard, so a zero divisor is
// undefined behaviour in C++ there — the reference does not define an answer,
// it merely produces whatever the host does. Model 1 met the same shape with
// shift counts above 31 and resolved it the same way: implement something
// deterministic, and **constrain the fuzz rather than compare against undefined
// behaviour**.
//
// This module returns quotient 0 and remainder = dividend for a zero divisor on
// every opcode, which matches `divo` exactly and is a defined answer everywhere
// else. Real silicon raises an arithmetic fault; that is not modelled because
// the reference does not model it either, and faults are out of scope per §1.

module i960_muldiv (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req,
  input  logic [7:0]  op,
  input  logic [3:0]  op2,
  input  logic [31:0] src1,        // t1 — divisor / multiplier
  input  logic [31:0] src2,        // t2 — dividend / multiplicand
  input  logic [31:0] src2_hi,     // ediv only: high half of the 64-bit dividend

  output logic        busy,
  output logic        done,
  output logic [31:0] res_lo,
  output logic [31:0] res_hi,      // emul high word, ediv quotient
  output logic        res_pair,    // result occupies a register pair
  output logic        valid        // op/op2 pair is implemented
);

  // ------------------------------------------------------------ op decode

  logic is_mul, is_div, is_rem, is_mod, is_signed, is_e;

  always_comb begin
    is_mul = 1'b0; is_div = 1'b0; is_rem = 1'b0; is_mod = 1'b0;
    is_signed = 1'b0; is_e = 1'b0; valid = 1'b1;
    case (op)
      8'h70: case (op2)                       // unsigned
               4'h1: is_mul = 1'b1;           // mulo
               4'h8: is_rem = 1'b1;           // remo
               4'hb: is_div = 1'b1;           // divo
               default: valid = 1'b0;
             endcase
      8'h74: begin
               is_signed = 1'b1;
               case (op2)
                 4'h1: is_mul = 1'b1;         // muli
                 4'h8: is_rem = 1'b1;         // remi
                 4'h9: is_mod = 1'b1;         // modi
                 4'hb: is_div = 1'b1;         // divi
                 default: valid = 1'b0;
               endcase
             end
      8'h67: case (op2)
               4'h0: begin is_mul = 1'b1; is_e = 1'b1; end   // emul, 32x32->64
               4'h1: begin is_div = 1'b1; is_e = 1'b1; end   // ediv, 64/32
               default: valid = 1'b0;
             endcase
      default: valid = 1'b0;
    endcase
  end

  // ---------------------------------------------------------- multiplier
  //
  // Written as `*` on purpose. Quartus infers DSP blocks from this and a
  // hand-built array would be both larger and slower. 32x32 -> 64 takes four
  // 18x18 blocks on Cyclone V.

  // ONE multiplier, not two. The low 32 bits of an NxN product are identical
  // whether the operands are read as signed or unsigned — two's complement
  // makes them the same bits — so `muli` and `mulo` differ only in the half
  // they discard, and both take the low half. Only `emul` wants the full 64,
  // and it is unsigned. The reference computes them with different casts, which
  // is a C++ typing detail rather than two different operations.
  logic [63:0] prod_u;
  assign prod_u = {32'd0, src2} * {32'd0, src1};

  // ------------------------------------------------------------- divider
  //
  // Restoring division, one bit per cycle. Magnitudes only; the sign is applied
  // on the way out, which is what makes truncation toward zero fall out
  // naturally — C's / and % truncate, and the remainder takes the dividend's
  // sign.

  // 33 bits, not 64: the partial remainder is always less than the divisor,
  // which is at most 32 bits, so it fits in 32 and needs one more for the bit
  // shifted in. A 64-bit comparator and subtractor here would be three times
  // the width for no reach.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] rem_acc;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [32:0] divisor_ext;
  logic [63:0] quot;
  logic [6:0]  bitcnt;
  logic        is_e_q;      // this operation has a 64-bit dividend
  logic        q_neg, r_neg, div_by_zero;
  // modi adds the divisor back when the operands' product is negative and the
  // remainder is non-zero. The condition is bit 31 of the 32-bit product, taken
  // at issue time because the operands may have moved on by the time the
  // divider finishes.
  logic        mod_prod_neg;
  logic [63:0] dvd_mag;
  logic [31:0] dsr_mag;
  logic [31:0] src1_q;      // latched: the divider outlives the request

  typedef enum logic [1:0] { S_IDLE, S_MUL, S_DIV, S_FIN } state_e;
  state_e state;
  assign busy = (state != S_IDLE);

  // rem_acc[32] is never shifted onward: after a restoring step the remainder
  // is strictly less than the divisor, so the top bit is always clear by
  // construction. It exists only so the compare and subtract have somewhere to
  // carry. Kept explicit rather than trimmed, because a 32-bit accumulator
  // would silently drop the carry the compare depends on.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] shifted;
  /* verilator lint_on UNUSEDSIGNAL */
  assign shifted = {rem_acc[31:0], quot[63]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      done     <= 1'b0;
      res_lo   <= 32'd0;
      res_hi   <= 32'd0;
      res_pair <= 1'b0;
      rem_acc  <= 33'd0;
      quot     <= 64'd0;
      bitcnt   <= 7'd0;
      is_e_q   <= 1'b0;
      q_neg    <= 1'b0;
      r_neg    <= 1'b0;
      div_by_zero <= 1'b0;
      mod_prod_neg <= 1'b0;
      divisor_ext <= 33'd0;
      dvd_mag  <= 64'd0;
      dsr_mag  <= 32'd0;
      src1_q   <= 32'd0;
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (req && valid) begin
          res_pair <= is_e;
          if (is_mul) begin
            state <= S_MUL;
          end else begin
            // Magnitudes. ediv is unsigned in the reference regardless of bits.
            q_neg <= is_signed && (src2[31] ^ src1[31]);
            r_neg <= is_signed && src2[31];
            div_by_zero <= (src1 == 32'd0);
            mod_prod_neg <= prod_u[31];
            // A 32-bit dividend goes in the HIGH half and runs 32 steps, not
            // the low half for 64. `shifted` takes quot[63], so a dividend in
            // the low half spends the first 32 iterations shifting out zeros
            // and producing zero quotient bits -- half the latency of every
            // ordinary divide, wasted. ediv genuinely has a 64-bit dividend and
            // keeps all 64.
            //
            // Divide was 17.6% of all cycles on ~1% of instructions.
            dvd_mag <= is_e ? {src2_hi, src2}
                            : (is_signed && src2[31]) ? {(~src2 + 32'd1), 32'd0}
                                                      : {src2, 32'd0};
            dsr_mag <= (is_signed && !is_e && src1[31]) ? (~src1 + 32'd1) : src1;
            src1_q  <= src1;
            is_e_q  <= is_e;
            rem_acc <= 33'd0;
            bitcnt  <= 7'd0;
            state   <= S_DIV;
          end
        end

        S_MUL: begin
          if (is_e) begin
            res_lo <= prod_u[31:0];
            res_hi <= prod_u[63:32];
          end else begin
            // mulo and muli agree on the low 32 bits; only the discarded upper
            // half differs, so one product serves both.
            res_lo <= prod_u[31:0];   // signed and unsigned agree here
            res_hi <= 32'd0;
          end
          state <= S_FIN;
        end

        S_DIV: begin
          if (bitcnt == 7'd0) begin
            quot <= dvd_mag;
            divisor_ext <= {1'b0, dsr_mag};
            bitcnt <= 7'd1;
          end else if (bitcnt <= (is_e_q ? 7'd64 : 7'd32)) begin
            if (shifted >= divisor_ext) begin
              rem_acc <= shifted - divisor_ext;
              quot    <= {quot[62:0], 1'b1};
            end else begin
              rem_acc <= shifted;
              quot    <= {quot[62:0], 1'b0};
            end
            bitcnt <= bitcnt + 7'd1;
          end else begin
            state <= S_FIN;
          end
        end

        S_FIN: begin
          if (is_div || is_rem || is_mod) begin
            if (div_by_zero) begin
              // Matches divo's explicit guard, and is a defined answer for the
              // opcodes the reference leaves undefined. See the header.
              res_lo <= is_div ? 32'd0 : src2;
              res_hi <= 32'd0;
            end else if (is_e) begin
              res_lo <= rem_acc[31:0];        // ediv: remainder low
              res_hi <= quot[31:0];           // ediv: quotient high
            end else if (is_div) begin
              res_lo <= q_neg ? (~quot[31:0] + 32'd1) : quot[31:0];
              res_hi <= 32'd0;
            end else begin
              // remi and remo take the dividend's sign, which is what makes C's
              // truncating % fall out. modi then adds the divisor back when the
              // product was negative and the remainder is non-zero.
              res_hi <= 32'd0;
              if (is_mod && mod_prod_neg && (rem_acc[31:0] != 32'd0))
                res_lo <= (r_neg ? (~rem_acc[31:0] + 32'd1) : rem_acc[31:0]) + src1_q;
              else
                res_lo <= r_neg ? (~rem_acc[31:0] + 32'd1) : rem_acc[31:0];
            end
          end
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
