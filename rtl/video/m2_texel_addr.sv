// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A texel's word address inside its sheet, from the texture header and the
// (u, v) the span walk asks for. Taken VERBATIM out of m2_texel (R583) so it
// can be computed where the texel queue loads its presentation register --
// a path with at least three clk_mem cycles by protocol (R563) -- instead of
// in the one 10 ns cycle between that register and the cache's RAM address
// (s312/s310: m2_texel_cdc f_u -> m2_texel cdata, up to -0.66 ns). Every
// comment below is m2_texel's own, moved with the arithmetic.

`timescale 1ns/1ps

module m2_texel_addr (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] tex,       // header bits outside the addressing are unused
  input  logic [19:0] u,         // the fraction is dropped
  input  logic [19:0] v,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [18:0] waddr,     // word address inside the sheet
  output logic        sheet,
  output logic        x2p,       // parity of x2 -- which texel of a word pair
  output logic        y2p
);
  localparam int unsigned WA_BITS = 19;

  // ---------------------------------------------------------- the addressing
  wire [2:0]  wcode = tex[3:1];
  wire [2:0]  hcode = tex[6:4];
  wire        mirx  = tex[9];
  wire        miry  = tex[10];
  assign      sheet = tex[12];
  wire [5:0]  texx  = tex[18:13];
  wire [4:0]  texy  = tex[23:19];

  // 32 << code, as a mask of the same shape: (32 << c) - 1.
  wire [11:0] wmask = 12'((32 << wcode) - 1);
  wire [11:0] hmask = 12'((32 << hcode) - 1);

  // Mirroring tests the coordinate against the texture's width in the SAME
  // fixed point it arrives in, which is why this is a shift and not a compare.
  wire [11:0] uint  = u[19:8];
  wire [11:0] vint  = v[19:8];
  wire        mir_u = mirx && ((uint & 12'(32 << wcode)) != 12'd0);
  wire        mir_v = miry && ((vint & 12'(32 << hcode)) != 12'd0);
  // The fraction is dropped here; the mirror inverts the whole coordinate the
  // way the reference does, and only the integer part survives the mask.
  wire [11:0] ua    = mir_u ? ~uint : uint;
  wire [11:0] va    = mir_v ? ~vint : vint;

  wire [11:0] u0    = ua & wmask;
  wire [11:0] v0    = va & hmask;

  wire [11:0] x2_0  = {1'b0, texx, 5'd0} + u0;
  wire [11:0] y2_0  = {2'd0, texy, 5'd0} + v0;
  wire        fold  = x2_0 >= 12'd1024;
  // R413: A 2-BIT DECREMENT, NOT A 12-BIT SUBTRACT. 1024 is 2^10, so
  // x2_0 - 1024 cannot affect bits [9:0] -- it is bits [11:10] minus one, and
  // `fold` means x2_0 >= 1024 so those two bits are never zero and cannot
  // underflow. Identical value, no 12-bit borrow chain.
  //
  // It sat between two adders on the worst path in the design:
  //   m2_span_tex|tex_r[6] -> Add3 -> Add5 -> m2_texel|idx_r[1]   -0.660 ns
  wire [11:0] x2    = fold ? {x2_0[11:10] - 2'd1, x2_0[9:0]} : x2_0;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [11:0] y2    = fold ? (y2_0 ^ 12'd1024) : y2_0;   // bit 11 never reaches waddr
  /* verilator lint_on UNUSEDSIGNAL */

  // AN ADD, NOT A CONCATENATION, and this cost an hour. The reference's
  // `offset = ((y2 / 2) * 512) + (x2 / 2)` CARRIES: one fold of the 1024
  // column leaves x2 anywhere up to 3039, so x2/2 can exceed 511 and spill
  // into the row above -- which is what the sheet's layout means, and dropping
  // the carry paints a band of the wrong rows across every wide texture.
  assign waddr = WA_BITS'({y2[10:1], 9'd0} + {8'd0, x2[11:1]});

  assign x2p = x2[0];
  assign y2p = y2[0];
endmodule
