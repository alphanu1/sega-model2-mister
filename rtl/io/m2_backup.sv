// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Backup SRAM, 16 KB at 0x01d00000-0x01d03fff.
//
//   map(0x01d00000, 0x01d03fff).ram().share("backup1")
//   NVRAM(config, "backup1", nvram_device::DEFAULT_ALL_1)
//
// IT DID NOT EXIST, AND THAT IS WHY THE BOOT LOOPED. The bridge routed
// 0x01a00000-0x02000000 to T_IO with the comment "comm, I/O, backup", and
// nothing in the I/O mux claimed it, so writes were discarded and reads
// returned zero. The i960 copies the I/O board's 128-byte identity block into
// this region and then reads it back:
//
//   00228230: lda  0x1c00200,g6     ; DPRAM window
//   00228238: lda  0x1d00000,g5     ; HERE
//   0022827C: ldob (g6),g4 / stob g4,(g5)
//   002282D0: ldq  0x1d00010,g0     ; and immediately reads it again
//
// So it copied a correct block into nothing, read zeros back, rejected them and
// span in 0x2282xx -- with the I/O board answering perfectly the whole time.
// Overlay row 14 read 1A400000 and row 8 sat at 4,097 across two builds while
// the fault was one region further on.
//
// POWERS UP ALL ONES, NOT ZERO. DEFAULT_ALL_1 above, and it is the one region
// MAME fills with 0xFF rather than zero -- it is also the region whose contents
// the boot signature-checks before deciding whether to initialise it, so 0x00
// versus 0xFF is a branch and not a detail. The same fact was found in the
// simulation harness (study R40) and this is the RTL half of it.
//
// The `initial` block is how that reaches hardware: Quartus turns it into the
// memory's power-up contents. It is NOT a reset -- the array is never cleared
// in reset, per the standing rule, because a reset that writes every entry is a
// second write port and forces the whole thing into flip-flops.
//
// BYTE LANES, NOT BYTE ENABLES. Four 4096x8 arrays with plain write enables.
// The I/O board's store cost 7,899 ALM of accidental flip-flops for getting
// exactly this wrong twice, and the fitter reported Successful both times.

`timescale 1ns/1ps

module m2_backup (
  input  logic        clk,
  input  logic        sel,
  input  logic        we,
  input  logic [11:0] word,       // dword index, address[13:2]
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata
);

  (* ramstyle = "M10K" *) logic [7:0] b0 [4096];
  (* ramstyle = "M10K" *) logic [7:0] b1 [4096];
  (* ramstyle = "M10K" *) logic [7:0] b2 [4096];
  (* ramstyle = "M10K" *) logic [7:0] b3 [4096];

  initial begin
    for (int i = 0; i < 4096; i++) begin
      b0[i] = 8'hff; b1[i] = 8'hff; b2[i] = 8'hff; b3[i] = 8'hff;
    end
  end

  logic [7:0] q0, q1, q2, q3;

  // Registered read, which the I/O path absorbs: `word` comes from the bridge's
  // latched r_addr and is stable through a dispatch cycle before io_sel is
  // asserted, so the data is out of the memory before the bridge samples it.
  always_ff @(posedge clk) begin
    if (sel && we && be[0]) b0[word] <= wdata[7:0];
    q0 <= b0[word];
  end
  always_ff @(posedge clk) begin
    if (sel && we && be[1]) b1[word] <= wdata[15:8];
    q1 <= b1[word];
  end
  always_ff @(posedge clk) begin
    if (sel && we && be[2]) b2[word] <= wdata[23:16];
    q2 <= b2[word];
  end
  always_ff @(posedge clk) begin
    if (sel && we && be[3]) b3[word] <= wdata[31:24];
    q3 <= b3[word];
  end

  assign rdata = {q3, q2, q1, q0};

endmodule
