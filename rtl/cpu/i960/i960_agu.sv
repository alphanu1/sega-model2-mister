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
// Transcribed from MAME's i960 device, get_ea (BSD-3-Clause, Farfetch'd and
// R. Belmont). See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB effective address generation — MEMA and the seven MEMB modes.
//
// Combinational. The caller supplies the register values and, for the five
// eight-byte forms, the displacement dword already fetched; i960_dec's
// `insn_len2` says when that fetch is needed.
//
// `ip_after_disp` is the IP of the instruction FOLLOWING the whole eight-byte
// instruction — that is, the address of the displacement dword plus four. Only
// MEMB mode 5 uses it, and the reference's own comment there is worth keeping
// because the arithmetic reads wrongly at first glance:
//
//   case 0x5:  // address of this instruction + the offset dword + 8
//              // which in reality is "address of next instruction + the
//              // offset dword"
//     ret = m_cache.read_dword(m_IP);
//     m_IP += 4;
//     ret += m_IP;
//
// It reads the dword at IP, advances IP past it, and only THEN adds. So the
// base is the post-increment IP, not the pre-increment one. An off-by-four here
// is a silently wrong branch or load target rather than a crash.
//
// Modes outside {4,5,7,C,D,E,F} reach fatalerror in the reference and are
// therefore unreachable in practice. `valid` goes low; do not invent them.

// The port is 14 bits, not 32. Everything above bit 13 selects the opcode and
// the srcdst/abase/index register numbers, which the CALLER uses to fetch
// operands — the address arithmetic itself never reads them. Passing the whole
// word and leaving 18 bits unread is exactly the "field extracted and then
// forgotten" pattern UNUSEDSIGNAL exists to catch.
module i960_agu (
  input  logic [13:0] insn,
  input  logic [31:0] abase_val,      // r[(insn>>14) & 0x1f]
  input  logic [31:0] index_val,      // r[insn & 0x1f]
  input  logic [31:0] disp_word,      // the fetched second word, if any
  input  logic [31:0] ip_after_disp,  // IP past the displacement dword

  output logic [31:0] ea,
  output logic        needs_disp,     // an eight-byte form: fetch disp_word
  output logic        valid           // mode implemented by the reference
);

  // MEMA when bit 12 is clear. Note bit 12 means src2-is-literal in a REG
  // instruction — format must already have been established by i960_dec.
  logic        memb;
  logic [3:0]  mode;
  logic [2:0]  scale;
  logic [12:0] mema_offset;
  logic        mema_rel;

  assign memb        = insn[12];
  assign mode        = insn[13:10];
  assign scale       = insn[9:7];
  assign mema_offset = insn[12:0];
  assign mema_rel    = insn[13];

  // The scaled index. Shift amount is 0..7, so the result is up to 32 bits of
  // shift on a 32-bit value — bits shifted out are simply lost, as in the
  // reference's `m_r[index] << scale` on a uint32_t.
  logic [31:0] scaled_index;
  assign scaled_index = index_val << scale;

  always_comb begin
    needs_disp = 1'b0;
    valid      = 1'b1;

    if (!memb) begin
      // MEMA: a 13-bit unsigned offset, optionally added to abase. Note this
      // is zero-extended, not sign-extended — the reference uses the raw
      // `opcode & 0x1fff`.
      ea = mema_rel ? (abase_val + {19'd0, mema_offset})
                    : {19'd0, mema_offset};
    end else begin
      case (mode)
        4'h4: ea = abase_val;
        4'h5: begin ea = disp_word + ip_after_disp;              needs_disp = 1'b1; end
        4'h7: ea = abase_val + scaled_index;
        4'hc: begin ea = disp_word;                              needs_disp = 1'b1; end
        4'hd: begin ea = disp_word + abase_val;                  needs_disp = 1'b1; end
        4'he: begin ea = disp_word + scaled_index;               needs_disp = 1'b1; end
        4'hf: begin ea = disp_word + abase_val + scaled_index;   needs_disp = 1'b1; end
        default: begin ea = 32'd0; valid = 1'b0; end
      endcase
    end
  end

endmodule
