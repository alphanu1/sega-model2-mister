// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The reciprocal table the fill's two dividers share: recip[d] = ceil(2^32/d).
//
// ONE TABLE, TWO READ PORTS. Each m2_raster_div held its own copy, which is
// 1,024 x 32 bits twice - 8 M10K of the 553, on a design that reached 540 and
// then lost three seeds in a row to routing congestion on the framework's
// scaler. An M10K is true dual-port, so one table answers both dividers in the
// same cycle and costs 4.
//
// Both ports are registered reads with no write port, which is what Quartus
// needs to infer a ROM; a gated read with a computed address builds the whole
// thing out of logic instead, silently. That cost 1,300 ALM once already.
`timescale 1ns/1ps

module m2_recip_rom #(
  parameter int unsigned TN = 256
) (
  input  logic        clk,
  input  logic [$clog2(TN)-1:0] a_addr,
  output logic [31:0] a_data,
  input  logic [$clog2(TN)-1:0] b_addr,
  output logic [31:0] b_data
);

  // MLAB, NOT M10K, AND 512 ENTRIES (Model 2): this design has all 553 M10K
  // in use (R221), and its vertices reach the store CLIPPED to the viewport,
  // so a scanline difference is under 384 -- the 1,024 the reference needed
  // for its unclipped -104..495 range is not needed here. |den| >= 512 still
  // takes the restoring path, so the unit is exact for every input.
  // TWO SINGLE-PORT MLAB COPIES, NOT ONE DUAL-PORT M10K (R243). The Model 1
  // form is one true-dual-port array, which Quartus infers as an altsyncram in
  // M10K -- and this design has all 553 M10K in use (R221), so build/fix3d8
  // failed the fitter at 556 of 553 with nothing else changed. An MLAB has one
  // read port, so each divider gets its own copy; 256 x 32 bits is 13 MLABs a
  // copy. The `ramstyle` attribute alone was not enough on the dual-port form:
  // it was honoured only once the array had a single read port.
  //
  // 256 ENTRIES, NOT 1,024. A denominator is an edge's height in scanlines.
  // Model 1 needed 1,024 for its unclipped -104..495 vertices; a bigger table
  // here costs M10K this design does not have, and |den| >= TN still takes the
  // exact restoring path, so the unit is correct for every input either way.
  // `romstyle`, NOT `ramstyle` (R243, second attempt). An array with an
  // initial block and no write port is a ROM, and Quartus steers ROMs with
  // `romstyle`; `ramstyle = "MLAB"` was accepted and ignored, and the fitter
  // failed again at 556 M10K of 553 with the table as two altsyncrams.
  // "logic" builds it out of LUTs (and the fitter's own RAM-to-MLAB pass may
  // take it from there), which is what this design has spare.
  (* romstyle = "logic" *) logic [31:0] recip_a [TN];
  (* romstyle = "logic" *) logic [31:0] recip_b [TN];
  // ceil(2^32/d). Entry 0 is never read - a zero denominator is trapped by the
  // divider - and entry 1 would be 2^32, which the divider special-cases.
  initial begin
    for (int d = 1; d < int'(TN); d++) begin
      recip_a[d] = 32'((({32'd0, 32'h8000_0000} << 1) + longint'(d) - 1) / longint'(d));
      recip_b[d] = recip_a[d];
    end
  end
  always_ff @(posedge clk) begin
    a_data <= recip_a[a_addr];
    b_data <= recip_b[b_addr];
  end
endmodule
