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
// Encoding transcribed from MAME's i960 device (BSD-3-Clause, Farfetch'd and
// R. Belmont). See i960_pkg.sv and THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB instruction decoder — combinational, one word in, fields out.
//
// This decodes ENCODING only. It says what the fields are, whether the opcode
// is one the reference implements, and how long the instruction is. It does
// not read registers, compute effective addresses or execute anything: those
// need the register file and the bus, and keeping them out makes this block
// exhaustively testable on its own.
//
// Two things here are easy to get wrong and expensive to find later.
//
// `insn_len2` marks the eight-byte forms. Five MEMB modes consume a following
// displacement dword, so instruction length is not constant and the fetch unit
// cannot assume a fixed stride. Getting this wrong desynchronises the
// instruction stream and every subsequent decode is garbage.
//
// `valid` is the set of opcodes the REFERENCE implements, which is smaller
// than the set the architecture defines. Per docs/p1-i960-spike.md §1 that is
// deliberate: anything MAME reaches fatalerror on is unreachable in practice,
// so it is trapped loudly rather than implemented blind. A game that needs
// more announces itself instead of drifting.

module i960_dec
  import i960_pkg::*;
(
  input  logic [31:0] insn,

  output fmt_e        fmt,
  output logic [7:0]  op,          // insn[31:24]
  output logic [3:0]  op2,         // REG sub-opcode, insn[10:7]
  output logic        valid,       // opcode is implemented by the reference
  output logic        insn_len2,   // instruction is 8 bytes, not 4

  // REG / COBR operands
  output logic [4:0]  src1,
  output logic [4:0]  src2,
  output logic [4:0]  srcdst,      // also MEM srcdst
  output logic        src1_lit,
  output logic        src2_lit,
  output logic        dst_lit,     // set means an illegal literal destination

  // MEM addressing
  output logic        memb,
  output logic [3:0]  memb_mode,
  output logic [4:0]  abase,
  output logic [4:0]  index,
  output logic [2:0]  scale,
  output logic        mema_rel,    // MEMA: offset is relative to r[abase]
  output logic [12:0] mema_offset,
  output logic        memb_bad,    // MEMB mode the reference does not handle

  // Branch displacement, sign-extended and with the reference's -4 applied.
  // CTRL is 24-bit, COBR is 13-bit. Meaningless for REG and MEM.
  output logic [31:0] disp
);

  // ------------------------------------------------------------------ format
  //
  // Determined by the opcode byte alone, before any other field is
  // interpreted. Bit 12 means MEMB in a MEM instruction and src2-is-literal in
  // a REG one, so nothing below may be read without knowing which this is.

  always_comb begin
    if      (insn[31:24] < 8'h20) fmt = FMT_CTRL;
    else if (insn[31:24] < 8'h40) fmt = FMT_COBR;
    else if (insn[31:24] < 8'h80) fmt = FMT_REG;
    else                          fmt = FMT_MEM;
  end

  assign op  = insn[31:24];
  assign op2 = insn[10:7];

  // ------------------------------------------------------------ field slices
  //
  // Extracted unconditionally. They are only meaningful for the format that
  // uses them, which is the consumer's problem — gating them here would cost
  // logic to hide a mistake rather than prevent one.

  assign src1        = insn[4:0];
  assign src2        = insn[18:14];
  assign srcdst      = insn[23:19];
  assign abase       = insn[18:14];
  assign index       = insn[4:0];
  assign scale       = insn[9:7];

  assign src1_lit    = insn[BIT_SRC1_LIT];
  assign src2_lit    = insn[BIT_SRC2_LIT];
  assign dst_lit     = insn[BIT_DST_LIT];

  assign memb        = insn[BIT_MEMB];
  assign memb_mode   = insn[13:10];
  assign mema_rel    = insn[BIT_MEMA_REL];
  assign mema_offset = insn[12:0];

  // ------------------------------------------------------------ displacement
  //
  // MAME: get_disp   = sext(opcode, 24) - 4
  //       get_disp_s = sext(opcode, 13) - 4
  //
  // Note it sign-extends the WHOLE low field including bits 1:0, which the
  // architecture reserves. Real code has them clear so the two readings agree,
  // but lockstep compares against the reference and not against the manual, so
  // the reference's arithmetic is what is reproduced.

  logic [31:0] disp_ctrl;
  logic [31:0] disp_cobr;

  assign disp_ctrl = {{8{insn[23]}}, insn[23:0]} - 32'd4;
  assign disp_cobr = {{19{insn[12]}}, insn[12:0]} - 32'd4;

  always_comb begin
    case (fmt)
      FMT_CTRL: disp = disp_ctrl;
      FMT_COBR: disp = disp_cobr;
      default:  disp = 32'd0;
    endcase
  end

  // ------------------------------------------------------------- MEMB checks
  //
  // Modes 4, 5, 7, C, D, E, F are handled by the reference; the rest are
  // fatalerror. Of those, 5, C, D, E and F take a displacement dword.

  logic memb_mode_ok;
  logic memb_has_disp;

  always_comb begin
    case (memb_mode)
      MEMB_ABASE,
      MEMB_IP_DISP,
      MEMB_ABASE_INDEX,
      MEMB_DISP,
      MEMB_DISP_ABASE,
      MEMB_DISP_INDEX,
      MEMB_DISP_BOTH: memb_mode_ok = 1'b1;
      default:        memb_mode_ok = 1'b0;
    endcase
  end

  always_comb begin
    case (memb_mode)
      MEMB_IP_DISP,
      MEMB_DISP,
      MEMB_DISP_ABASE,
      MEMB_DISP_INDEX,
      MEMB_DISP_BOTH: memb_has_disp = 1'b1;
      default:        memb_has_disp = 1'b0;
    endcase
  end

  assign memb_bad  = (fmt == FMT_MEM) &  memb & ~memb_mode_ok;
  assign insn_len2 = (fmt == FMT_MEM) &  memb &  memb_has_disp;

  // --------------------------------------------------------- opcode validity
  //
  // The set execute_op dispatches to. Written as an explicit case rather than
  // a range test because it is NOT contiguous: 0x38 and 0x3f are absent from
  // the COBR block, and the REG and MEM blocks are sparse. A range test would
  // silently accept opcodes the reference traps on, which is the opposite of
  // what this signal is for.

  logic op_implemented;

  always_comb begin
    case (op)
      // CTRL
      8'h08, 8'h09, 8'h0a, 8'h0b,                            // b call ret bal
      8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, // b<cc>
      8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f, // fault<cc>
      // COBR
      8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27, // test<cc>
      8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, // bbc cmpob<cc> bbs
      8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d, 8'h3e,               // cmpib<cc>
      // REG
      8'h58, 8'h59, 8'h5a, 8'h5b, 8'h5c, 8'h5d, 8'h5e, 8'h5f,
      8'h60, 8'h64, 8'h65, 8'h66, 8'h67, 8'h68, 8'h69,
      8'h6c, 8'h6d, 8'h6e, 8'h70, 8'h74, 8'h78, 8'h79,
      // MEM
      8'h80, 8'h82, 8'h84, 8'h85, 8'h86, 8'h88, 8'h8a, 8'h8c,
      8'h90, 8'h92, 8'h98, 8'h9a, 8'ha0, 8'ha2, 8'hb0, 8'hb2,
      8'hc0, 8'hc2, 8'hc8, 8'hca:
        op_implemented = 1'b1;
      default:
        op_implemented = 1'b0;
    endcase
  end

  // A MEMB mode the reference traps on makes the instruction undecodable even
  // when the opcode itself is implemented, so it is folded in here rather than
  // left for the consumer to remember.
  assign valid = op_implemented & ~memb_bad;

endmodule
