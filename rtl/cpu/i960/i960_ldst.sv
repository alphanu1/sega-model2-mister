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
// Transcribed from MAME's i960 device, MEM opcodes 0x80-0xca and the
// i960_read/write_*_unaligned helpers (BSD-3-Clause, Farfetch'd, R. Belmont).
// See THIRD_PARTY.md.
//
// ---------------------------------------------------------------------------
//
// i960KB load/store width, extension and lane placement. Combinational.
//
// Decides what a MEM opcode does to data: how many bytes, whether a partial
// load sign-extends or zero-extends, which byte lanes a store drives, and how
// many consecutive dwords a multi-word form moves.
//
// The signed/unsigned split is the whole reason this is a table rather than a
// width field. From the reference:
//   ldob  u8  -> zero-extend      ldib  s8  -> sign-extend
//   ldos  u16 -> zero-extend      ldis  s16 -> sign-extend
// The opcodes differ only in bit 6 of the opcode byte (0x80 vs 0xc0), which is
// easy to fold into an arithmetic expression and get subtly wrong, so it is
// enumerated instead.
//
// `lda` is in this table and touches no memory at all: it computes an effective
// address and writes it to a register. It is listed so a caller iterating MEM
// opcodes cannot forget it.
//
// UNALIGNED ACCESS IS NOT HANDLED HERE. The reference splits an unaligned word
// or dword into byte accesses assembled little-endian, which needs multiple bus
// cycles and therefore belongs to the bus unit (step 5). This module raises
// `unaligned` and leaves the sequencing to the caller.

module i960_ldst (
  input  logic [7:0]  op,

  output logic        is_load,
  output logic        is_store,
  output logic        no_mem,      // lda: effective address to register only
  output logic [1:0]  size,        // 0 = byte, 1 = half, 2 = word
  output logic        sign_ext,    // partial loads only
  output logic [2:0]  n_words,     // consecutive dwords: 1, 2, 3 or 4
  output logic        valid,

  // Data path. `rd_data` is the aligned dword containing the target bytes.
  input  logic [1:0]  addr_lo,     // low two bits of the effective address
  input  logic [31:0] rd_data,
  output logic [31:0] ld_result,

  input  logic [31:0] st_value,
  output logic [31:0] st_data,     // value placed in the correct byte lanes
  output logic [3:0]  st_be,

  output logic        unaligned    // needs byte-wise sequencing by the bus
);

  // ------------------------------------------------------------ opcode table

  always_comb begin
    is_load = 1'b0; is_store = 1'b0; no_mem = 1'b0;
    size    = 2'd2; sign_ext = 1'b0; n_words = 3'd1; valid = 1'b1;
    case (op)
      8'h80: begin is_load  = 1'b1; size = 2'd0; end                    // ldob
      8'h82: begin is_store = 1'b1; size = 2'd0; end                    // stob
      8'h88: begin is_load  = 1'b1; size = 2'd1; end                    // ldos
      8'h8a: begin is_store = 1'b1; size = 2'd1; end                    // stos
      8'h8c: begin no_mem   = 1'b1;              end                    // lda
      8'h90: begin is_load  = 1'b1;              end                    // ld
      8'h92: begin is_store = 1'b1;              end                    // st
      8'h98: begin is_load  = 1'b1; n_words = 3'd2; end                 // ldl
      8'h9a: begin is_store = 1'b1; n_words = 3'd2; end                 // stl
      8'ha0: begin is_load  = 1'b1; n_words = 3'd3; end                 // ldt
      8'ha2: begin is_store = 1'b1; n_words = 3'd3; end                 // stt
      8'hb0: begin is_load  = 1'b1; n_words = 3'd4; end                 // ldq
      8'hb2: begin is_store = 1'b1; n_words = 3'd4; end                 // stq
      8'hc0: begin is_load  = 1'b1; size = 2'd0; sign_ext = 1'b1; end   // ldib
      8'hc2: begin is_store = 1'b1; size = 2'd0; end                    // stib
      8'hc8: begin is_load  = 1'b1; size = 2'd1; sign_ext = 1'b1; end   // ldis
      8'hca: begin is_store = 1'b1; size = 2'd1; end                    // stis
      default: valid = 1'b0;
    endcase
  end

  // --------------------------------------------------------------- alignment

  always_comb begin
    case (size)
      2'd0:    unaligned = 1'b0;              // byte access is always aligned
      2'd1:    unaligned = addr_lo[0];        // half needs bit 0 clear
      default: unaligned = |addr_lo;          // word needs both clear
    endcase
  end

  // -------------------------------------------------------------- load path

  logic [7:0]  byte_sel;
  logic [15:0] half_sel;

  always_comb begin
    case (addr_lo)
      2'd0: byte_sel = rd_data[7:0];
      2'd1: byte_sel = rd_data[15:8];
      2'd2: byte_sel = rd_data[23:16];
      2'd3: byte_sel = rd_data[31:24];
    endcase
    half_sel = addr_lo[1] ? rd_data[31:16] : rd_data[15:0];
  end

  always_comb begin
    case (size)
      2'd0:    ld_result = sign_ext ? {{24{byte_sel[7]}},  byte_sel}
                                    : {24'd0,             byte_sel};
      2'd1:    ld_result = sign_ext ? {{16{half_sel[15]}}, half_sel}
                                    : {16'd0,             half_sel};
      default: ld_result = rd_data;
    endcase
  end

  // ------------------------------------------------------------- store path

  always_comb begin
    case (size)
      2'd0: begin
        st_data = {4{st_value[7:0]}};
        st_be   = 4'b0001 << addr_lo;
      end
      2'd1: begin
        st_data = {2{st_value[15:0]}};
        st_be   = addr_lo[1] ? 4'b1100 : 4'b0011;
      end
      default: begin
        st_data = st_value;
        st_be   = 4'b1111;
      end
    endcase
  end

endmodule
