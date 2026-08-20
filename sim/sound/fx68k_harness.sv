// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A REAL BUS FOR fx68k, so "does it simulate" becomes "does it execute".
//
// THIRD_PARTY.md recorded that fx68k lints, elaborates and runs under Verilator
// once `s_nanod` and `s_irdecod` are packed -- and that a throwaway C++ harness
// never saw it fetch a reset vector. That harness drove `enPhi1`/`enPhi2` and
// the data bus from C++, evaluating twice per iteration, and it was not
// possible to tell whether the core or the harness was at fault. Nothing was
// learned from it, which is the point of replacing it with this.
//
// The bus is modelled in RTL, where the timing relationships are the ones the
// 68000 actually specifies, and C++ only turns the clock and reads the result.
//
// WHAT IT PROVES. Not "it did not crash" -- that was already true and told us
// nothing. This loads a four-instruction program, and the check is that a value
// the program COMPUTED arrives at an address the program CHOSE:
//
//   0x000000  0000 0400        SSP     -- the reset vector is read from memory,
//   0x000004  0000 0010        PC         so the fetch path works at all
//   0x000010  303C 1234        move.w #$1234,d0
//   0x000014  33C0 0000 0100   move.w d0,$00000100
//   0x00001A  60FE             bra.s  *      -- park, so the result is stable
//
// mem[0x80] holding 0x1234 means the core read the vector, fetched from the
// address in it, decoded an immediate, decoded an absolute-long write, and
// completed a write bus cycle. A core that merely elaborates does none of that.
//
// DTACK is registered off AS rather than tied low. Tying it asserts the
// acknowledge before the address is even valid, which a synchronous model
// tolerates and real memory does not, and it is exactly the kind of harness
// that is gentler than the thing it models -- the failure this project has
// recorded six times.

`timescale 1ns/1ps

module fx68k_harness (
  input  logic        clk,
  input  logic        rst,

  output logic [15:0] probe,      // mem[0x80] -- where the program stores
  output logic [23:1] eab_o,
  output logic        asn_o,
  output logic [31:0] bus_cycles, // AS falling edges: is it sequencing?
  output logic [31:0] writes      // completed write cycles
);

  // The 68000 wants a clock at least twice its effective rate; fx68k's own
  // example divides by four and that is what is reproduced here. enPhi1 and
  // enPhi2 must be SINGLE-CYCLE pulses and must never be asserted twice in a
  // row -- fx68k.txt is explicit about it.
  logic [1:0] div;
  always_ff @(posedge clk) begin
    if (rst) div <= 2'd0;
    else     div <= div + 2'd1;
  end
  wire enPhi1 = (div == 2'b11);
  wire enPhi2 = (div == 2'b01);

  wire        eRWn, ASn, LDSn, UDSn, E, VMAn;
  wire        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
  wire [15:0] oEdb;
  wire [23:1] eab;

  logic [15:0] iEdb;
  logic        DTACKn;

  // 32 KB of 16-bit memory. Deliberately not tagged for M10K -- this is a
  // testbench, and the simulator models the array as registers regardless.
  //
  // A comment here must not begin with the simulator's name: `// <name> ...`
  // is parsed as a lint pragma, and this file failed to compile with
  // BADVLTPRAGMA until the wording changed.
  logic [15:0] mem [16384];

  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 16'h4E71;   // NOP everywhere
    mem['h0000] = 16'h0000; mem['h0001] = 16'h0400;      // SSP = 0x00000400
    mem['h0002] = 16'h0000; mem['h0003] = 16'h0010;      // PC  = 0x00000010
    mem['h0008] = 16'h303C; mem['h0009] = 16'h1234;      // move.w #$1234,d0
    mem['h000A] = 16'h33C0; mem['h000B] = 16'h0000;      // move.w d0,$0100.l
    mem['h000C] = 16'h0100;
    mem['h000D] = 16'h60FE;                              // bra.s *
  end

  wire [13:0] wa = eab[14:1];

  always_comb iEdb = mem[wa];

  // Registered acknowledge: one clock after AS falls, never combinationally
  // from it. See the note above.
  always_ff @(posedge clk) begin
    if (rst) DTACKn <= 1'b1;
    else     DTACKn <= ASn;
  end

  logic asn_d;
  always_ff @(posedge clk) begin
    if (rst) begin
      asn_d <= 1'b1; bus_cycles <= '0; writes <= '0;
    end else begin
      asn_d <= ASn;
      if (asn_d && !ASn) begin
        bus_cycles <= bus_cycles + 32'd1;
        if (!eRWn) writes <= writes + 32'd1;
      end
      // The data strobes qualify the write, so a read cycle cannot fall
      // through into one.
      if (!ASn && !eRWn) begin
        if (!UDSn) mem[wa][15:8] <= oEdb[15:8];
        if (!LDSn) mem[wa][7:0]  <= oEdb[7:0];
      end
    end
  end

  assign probe  = mem['h0080];      // byte address 0x100
  assign eab_o  = eab;
  assign asn_o  = ASn;

  fx68k u_cpu (
    .clk       (clk),
    .HALTn     (1'b1),
    .extReset  (rst),
    .pwrUp     (rst),
    .enPhi1    (enPhi1),
    .enPhi2    (enPhi2),
    .eRWn      (eRWn),  .ASn (ASn), .LDSn (LDSn), .UDSn (UDSn),
    .E         (E),     .VMAn(VMAn),
    .FC0       (FC0),   .FC1 (FC1), .FC2 (FC2),
    .BGn       (BGn),
    .oRESETn   (oRESETn), .oHALTEDn (oHALTEDn),
    .DTACKn    (DTACKn),
    .VPAn      (1'b1),
    .BERRn     (1'b1),
    .BRn       (1'b1),
    .BGACKn    (1'b1),
    .IPL0n     (1'b1), .IPL1n (1'b1), .IPL2n (1'b1),
    .iEdb      (iEdb),
    .oEdb      (oEdb),
    .eab       (eab)
  );

  // Read but not otherwise used by the harness; named so the intent is on
  // the page rather than inferred from a lint waiver.
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, E, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn, LDSn, UDSn};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
