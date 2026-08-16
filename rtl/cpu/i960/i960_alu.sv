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
// Semantics transcribed from MAME's i960 device (BSD-3-Clause, Farfetch'd and
// R. Belmont), execute_op cases 0x58-0x5b. See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB integer ALU — logic, bit, shift, arithmetic and compare.
//
// Combinational. The reference's cycle counts are a timing model, not a
// datapath requirement: nothing here needs more than one cycle of logic, and
// where the pipeline spends its cycles is docs/p1-i960-spike.md §4.4's problem.
//
// Covers REG opcodes 0x58, 0x59, 0x5a and 0x5b — 37 operations.
//
// AC[2:0] is the condition code, and it is overloaded by design:
//
//   compares      4 = less, 2 = equal, 1 = greater
//   addc / subc   bit 1 = carry, bit 0 = overflow
//
// So AC bit 1 means "equal" after cmpi and "carry" after addc. That is the
// architecture, not a shortcut taken here.
//
// ---------------------------------------------------------------------------
// DIVERGENCE FROM THE REFERENCE — addc and subc carry. Read before comparing.
//
// MAME computes carry as:
//
//   uint32_t t1, t2;  uint64_t res;
//   res = t2+(t1+((m_AC>>1)&1));
//   m_AC |= ((res) & (((uint64_t)1) << 32)) ? 0x2 : 0;    // set carry
//
// Every operand is uint32_t, so the addition wraps modulo 2^32 BEFORE it is
// widened to uint64_t, and bit 32 is therefore always zero. Verified: 0xffffffff
// + 1 yields res = 0 with bit 32 clear; 0 - 1 yields 0xffffffff with bit 32
// clear. MAME's addc and subc never set carry at all.
//
// The `// set carry` comment and the deliberate `(uint64_t)1 << 32` mask make
// the intent unambiguous, so this is a C++ integer-promotion defect rather than
// a modelling decision. addc and subc exist to chain multi-word arithmetic;
// carry propagation is their entire purpose, and hardware certainly produces it.
//
// **This module implements the hardware behaviour, not MAME's.** Per CLAUDE.md
// rule 11 the reference wins over the study, but the silicon wins over the
// reference where the reference demonstrably fails to model it — and per
// THIRD_PARTY.md the behaviour of Intel's silicon is fact rather than MAME's
// expression of it.
//
// Consequence for verification: the i960 integer core is a bit-exact oracle
// EXCEPT for these two opcodes. The reference model carries a switch to
// reproduce MAME's result so lockstep can still run; see i960_alu_ref.h.
// Design study §2 and R7 record this.
// ---------------------------------------------------------------------------

// No `import i960_pkg::*` here on purpose. This module uses nothing from it,
// and importing anyway trips UNUSEDPARAM — which the Makefile deliberately does
// not suppress, because an unused symbol is usually a field extracted and then
// forgotten rather than harmless tidiness.
module i960_alu (
  input  logic [7:0]  op,         // 0x58 .. 0x5b
  input  logic [3:0]  op2,        // sub-opcode
  input  logic [31:0] src1,       // MAME t1
  input  logic [31:0] src2,       // MAME t2
  input  logic [31:0] ac_in,

  output logic [31:0] result,
  output logic        result_we,  // instruction writes a destination register
  output logic [31:0] ac_out,
  output logic        valid       // op/op2 pair is implemented by the reference
);

  // ---------------------------------------------------------------- helpers

  // The reference tests `t1 >= 32` on the FULL 32-bit value and does not mask
  // the shift count to five bits. A register-sourced count of 100 therefore
  // gives zero, not a shift by 4. Masking here would be a silent divergence on
  // every out-of-range count.
  logic        sh_ge32;
  logic [4:0]  sh;
  assign sh_ge32 = |src1[31:5];
  assign sh      = src1[4:0];

  logic signed [31:0] src2_s;
  assign src2_s = $signed(src2);

  // Bit ops use 1 << (t1 & 31) — masked, unlike the shifts.
  logic [31:0] bitmask;
  assign bitmask = 32'd1 << src1[4:0];

  // shrdi rounds toward zero: for a negative value with any bit shifted out,
  // the arithmetic-shift result is incremented.
  logic [31:0] shrdi_lostmask;
  logic        shrdi_lost;
  assign shrdi_lostmask = (32'd1 << sh) - 32'd1;
  assign shrdi_lost     = |(src2 & shrdi_lostmask);

  // Rotate masks to five bits — this one the reference does mask.
  logic [4:0]  rot;
  logic [31:0] rot_res;
  assign rot     = src1[4:0];
  assign rot_res = (rot == 5'd0) ? src2 : ((src2 << rot) | (src2 >> (6'd32 - {1'b0, rot})));

  // Condition codes. Order matters: the reference passes (t1, t2), so cmpo
  // compares src1 against src2 and not the other way round.
  logic [2:0] cc_u, cc_s, ccon_u, ccon_s;
  assign cc_u   = (src1 <  src2)             ? 3'b100 :
                  (src1 == src2)             ? 3'b010 : 3'b001;
  assign cc_s   = ($signed(src1) <  src2_s)  ? 3'b100 :
                  (src1 == src2)             ? 3'b010 : 3'b001;
  assign ccon_u = (src1 <= src2)             ? 3'b010 : 3'b001;
  assign ccon_s = ($signed(src1) <= src2_s)  ? 3'b010 : 3'b001;

  // scanbyte sets equal if any byte lane matches.
  logic scanbyte_hit;
  assign scanbyte_hit = (src1[31:24] == src2[31:24]) |
                        (src1[23:16] == src2[23:16]) |
                        (src1[15: 8] == src2[15: 8]) |
                        (src1[ 7: 0] == src2[ 7: 0]);

  // addc / subc. Carry in is AC bit 1. Computed at 33 bits so the carry out is
  // real — see the divergence note above.
  logic        carry_in;
  logic [32:0] addc_res, subc_res;
  logic        addc_ovf, subc_ovf;

  assign carry_in = ac_in[1];
  assign addc_res = {1'b0, src2} + {1'b0, src1} + {32'd0, carry_in};
  assign subc_res = {1'b0, src2} - ({1'b0, src1} + {32'd0, carry_in});

  // Overflow expressions are the reference's, which are correct as written
  // because they operate on 32-bit values only.
  assign addc_ovf = (addc_res[31] ^ src1[31]) & (addc_res[31] ^ src2[31]);
  assign subc_ovf = (src2[31] ^ src1[31]) & (src2[31] ^ subc_res[31]);

  // ------------------------------------------------------------------ decode

  always_comb begin
    result    = 32'd0;
    result_we = 1'b0;
    ac_out    = ac_in;
    valid     = 1'b1;

    unique case (op)

      // ------------------------------------------------ 0x58 logic and bit
      8'h58: begin
        result_we = 1'b1;
        unique case (op2)
          4'h0: result = src2 ^  bitmask;              // notbit
          4'h1: result = src2 &  src1;                 // and
          4'h2: result = src2 & ~src1;                 // andnot
          4'h3: result = src2 |  bitmask;              // setbit
          4'h4: result = ~src2 & src1;                 // notand
          4'h6: result = src2 ^  src1;                 // xor
          4'h7: result = src2 |  src1;                 // or
          4'h8: result = ~src2 & ~src1;                // nor
          4'h9: result = ~(src2 ^ src1);               // xnor
          4'ha: result = ~src1;                        // not
          4'hb: result = src2 | ~src1;                 // ornot
          4'hc: result = src2 & ~bitmask;              // clrbit
          4'hd: result = ~src2 | src1;                 // notor
          4'he: result = ~src2 | ~src1;                // nand
          4'hf: result = ac_in[1] ? (src2 | bitmask)   // alterbit, on AC equal
                                  : (src2 & ~bitmask);
          default: begin result_we = 1'b0; valid = 1'b0; end
        endcase
      end

      // --------------------------------------- 0x59 arithmetic and shifts
      8'h59: begin
        result_we = 1'b1;
        unique case (op2)
          // The reference marks addi and subi "#### overflow" and does not
          // detect it, so they are identical to addo and subo. Replicated:
          // inventing overflow here would diverge from the only oracle there is.
          4'h0, 4'h1: result = src2 + src1;            // addo, addi
          4'h2, 4'h3: result = src2 - src1;            // subo, subi
          4'h8: result = sh_ge32 ? 32'd0 : (src2 >> sh);           // shro
          4'ha: begin                                              // shrdi
            if (sh_ge32)                 result = 32'd0;
            else if (src2_s < 0)
              result = shrdi_lost ? ($signed(src2_s >>> sh) + 32'sd1)
                                  :  $signed(src2_s >>> sh);
            else                         result = src2 >> sh;
          end
          4'hb: result = sh_ge32 ? (src2_s < 0 ? 32'hffff_ffff : 32'd0)
                                 : $signed(src2_s >>> sh);         // shri
          // shli is shlo in the reference: "missing overflow", with a note that
          // later models preserve sign on overflow. The KB is not a later model.
          4'hc, 4'he: result = sh_ge32 ? 32'd0 : (src2 << sh);      // shlo, shli
          4'hd: result = rot_res;                                   // rotate
          default: begin result_we = 1'b0; valid = 1'b0; end
        endcase
      end

      // ------------------------------------------------------ 0x5a compare
      8'h5a: begin
        unique case (op2)
          4'h0: ac_out = {ac_in[31:3], cc_u};          // cmpo
          4'h1: ac_out = {ac_in[31:3], cc_s};          // cmpi
          // concmp only acts when AC "less" is clear, and leaves AC untouched
          // otherwise — not merely unwritten, genuinely skipped.
          4'h2: if (!ac_in[2]) ac_out = {ac_in[31:3], ccon_u};      // concmpo
          4'h3: if (!ac_in[2]) ac_out = {ac_in[31:3], ccon_s};      // concmpi
          4'h4: begin ac_out = {ac_in[31:3], cc_u}; result = src2 + 32'd1; result_we = 1'b1; end // cmpinco
          4'h5: begin ac_out = {ac_in[31:3], cc_s}; result = src2 + 32'd1; result_we = 1'b1; end // cmpinci
          4'h6: begin ac_out = {ac_in[31:3], cc_u}; result = src2 - 32'd1; result_we = 1'b1; end // cmpdeco
          4'h7: begin ac_out = {ac_in[31:3], cc_s}; result = src2 - 32'd1; result_we = 1'b1; end // cmpdeci
          4'hc: ac_out = {ac_in[31:3], scanbyte_hit ? 3'b010 : 3'b000};  // scanbyte
          4'he: ac_out = {ac_in[31:3], src2[src1[4:0]] ? 3'b010 : 3'b000}; // chkbit
          default: valid = 1'b0;
        endcase
      end

      // --------------------------------------------- 0x5b carry arithmetic
      8'h5b: begin
        unique case (op2)
          4'h0: begin                                   // addc
            result    = addc_res[31:0];
            result_we = 1'b1;
            ac_out    = {ac_in[31:2], addc_res[32], addc_ovf};
          end
          4'h2: begin                                   // subc
            result    = subc_res[31:0];
            result_we = 1'b1;
            ac_out    = {ac_in[31:2], subc_res[32], subc_ovf};
          end
          default: valid = 1'b0;
        endcase
      end

      default: valid = 1'b0;
    endcase
  end

endmodule
