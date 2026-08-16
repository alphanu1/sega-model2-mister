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
// i960KB instruction encoding constants.
//
// Opcode numbering, field positions and the implemented-opcode set are
// transcribed from MAME's i960 device, which is BSD-3-Clause:
//
//   src/devices/cpu/i960/i960.cpp    execute_op dispatch, get_ea, get_*_ri
//   src/devices/cpu/i960/i960dis.cpp mnemonic table and its format column
//   Copyright (C) Farfetch'd, R. Belmont
//
// That attribution travels with this file. See THIRD_PARTY.md.
//
// docs/p1-i960-spike.md is the specification. Read §3 before changing anything
// here: the implemented-opcode set is deliberately the set MAME implements, not
// the set the architecture defines, and the difference is the point.

package i960_pkg;

  // -------------------------------------------------------------- formats
  //
  // The architecture splits the opcode byte into four ranges. This matches the
  // format column of i960dis.cpp's mnemonic table, where 1=CTRL, 2=COBR,
  // 3=MEM, 4=REG.
  //
  //   0x00-0x1f  CTRL   24-bit displacement            (0x00-0x07 unused)
  //   0x20-0x3f  COBR   13-bit displacement, 2 operands
  //   0x40-0x7f  REG    three operands                (0x40-0x57 unused)
  //   0x80-0xff  MEM    load/store, MEMA or MEMB

  typedef enum logic [1:0] {
    FMT_CTRL = 2'd0,
    FMT_COBR = 2'd1,
    FMT_REG  = 2'd2,
    FMT_MEM  = 2'd3
  } fmt_e;

  // ------------------------------------------------------- operand mode bits
  //
  // Each operand position selects register-or-literal with a DIFFERENT bit,
  // and they are not adjacent. From i960.cpp:
  //
  //   get_1_ri  src1   bit 11   field opcode[4:0]
  //   get_2_ri  src2   bit 12   field opcode[18:14]
  //   set_ri    dst    bit 13   field opcode[23:19]   (literal here is illegal)
  //   get_1_ci  COBR   bit 13   field opcode[23:19]
  //
  // Bit 12 also distinguishes MEMA from MEMB. Same bit, different meaning,
  // resolved by format — which is why format is decoded first and everything
  // else is qualified by it.

  localparam int unsigned BIT_SRC1_LIT = 11;
  localparam int unsigned BIT_SRC2_LIT = 12;
  localparam int unsigned BIT_DST_LIT  = 13;
  localparam int unsigned BIT_MEMB     = 12;
  localparam int unsigned BIT_MEMA_REL = 13;

  // ---------------------------------------------------------- MEMB addressing
  //
  // Modes MAME implements. Everything else reaches fatalerror there, so it is
  // unreachable in practice and is trapped here rather than implemented.
  // Modes 5, C, D, E and F consume a following displacement dword, making the
  // instruction eight bytes rather than four.

  localparam logic [3:0] MEMB_ABASE        = 4'h4; // r[abase]
  localparam logic [3:0] MEMB_IP_DISP      = 4'h5; // disp + IP of next insn
  localparam logic [3:0] MEMB_ABASE_INDEX  = 4'h7; // r[abase] + (r[index]<<scale)
  localparam logic [3:0] MEMB_DISP         = 4'hc; // disp
  localparam logic [3:0] MEMB_DISP_ABASE   = 4'hd; // disp + r[abase]
  localparam logic [3:0] MEMB_DISP_INDEX   = 4'he; // disp + (r[index]<<scale)
  localparam logic [3:0] MEMB_DISP_BOTH    = 4'hf; // disp + r[abase] + (r[index]<<scale)

endpackage
