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
  // FOR THE DEBUG LATCH ONLY. The memory arrays stay reset-free by design --
  // backup survives a game reset -- but "first read of this boot" must re-arm
  // on each reset to mean anything.
  input  logic        rst_n,
  input  logic        sel,
  input  logic        we,
  input  logic [11:0] word,       // dword index, address[13:2]
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  // HPS ACCESS, for NVRAM save/load through the framework (study R59). The
  // CPU is in reset for the whole download window, so the write mux cannot
  // contend; upload reads reuse the debug read port.
  input  logic        hps_we,
  input  logic [11:0] hps_word,
  input  logic  [3:0] hps_be,
  input  logic [31:0] hps_wdata,
  input  logic [11:0] dbg_word,
  input  logic  [3:0] dbg_rd_sel,
  output logic [31:0] dbg_q,
  output logic [31:0] dbg_first,
  output logic [31:0] rdata,

  // WHAT THE COPY ACTUALLY LANDED. The i960 copies the I/O board's identity
  // block to 0x01d00000 and reads it straight back, so dword 0 of this region
  // is the whole question in one word: 41474553 is "SEGA" and the copy arrived
  // intact, 00000000 is the shadow's own power-up value and means the i960
  // never wrote dword 0 at all, and anything else means it arrived corrupted.
  // Note it shadows the WRITE, not the array -- so it says what the i960 sent,
  // which is the half a corrupted read would not show. A shadow register rather than a second read port,
  // because a second asynchronous read on an M10K is answered by duplicating
  // the array.
  output logic [31:0] dbg_w0,
  output logic [15:0] dbg_writes
);

  // FOUR LANES, EACH TRUE DUAL-PORT. These were inferred arrays with one write
  // port and TWO read ports -- the CPU's and the HPS save path's -- and Quartus
  // 17.0 replicates that shape rather than inferring a true dual-port, so each
  // lane cost twice its blocks. Study R96 has the measurement on tram; this is
  // the same fault in the same idiom.
  //
  // Port A carries the write and the CPU's read together, which works because
  // `ww` IS `word` whenever the CPU writes -- the HPS only writes while the CPU
  // is in reset, and its read result is discarded. Port B is the save path.


  wire [7:0] q0, q1, q2, q3;
  wire [7:0] dq0, dq1, dq2, dq3;

  always_ff @(posedge clk) begin
    if (sel && we) begin
      dbg_writes <= dbg_writes + 16'd1;
      if (word == 12'd0) begin
        if (be[0]) dbg_w0[7:0]   <= wdata[7:0];
        if (be[1]) dbg_w0[15:8]  <= wdata[15:8];
        if (be[2]) dbg_w0[23:16] <= wdata[23:16];
        if (be[3]) dbg_w0[31:24] <= wdata[31:24];
      end
    end
  end

  // Registered read, which the I/O path absorbs: `word` comes from the bridge's
  // latched r_addr and is stable through a dispatch cycle before io_sel is
  // asserted, so the data is out of the memory before the bridge samples it.
  // One write port per lane, CPU or HPS -- never both, because the CPU is in
  // reset whenever hps_we can assert.
  wire        wsel = (sel && we) || hps_we;
  wire [11:0] ww   = hps_we ? hps_word  : word;
  wire [31:0] wd   = hps_we ? hps_wdata : wdata;
  wire  [3:0] wb   = hps_we ? hps_be    : (sel && we) ? be : 4'b0000;
  // ONE ADDRESS SERVES THE WRITE AND THE CPU'S READ, in every case that can
  // occur. `ww` is `word` whenever hps_we is low, which covers every CPU read
  // and every CPU write; when hps_we is high the address is the HPS's and the
  // read result is discarded, because the CPU is held in reset for the whole of
  // that transfer. So port A takes `ww` unconditionally.
  m2_tdp_ram #(.DW(8), .AW(12), .INIT_FILE("ff4096x8.mif")) u_b0 (
    .clk(clk), .a_addr(ww), .a_din(wd[7:0]),   .a_we(wsel & wb[0]), .a_q(q0),
    .b_addr(dbg_word), .b_q(dq0));
  m2_tdp_ram #(.DW(8), .AW(12), .INIT_FILE("ff4096x8.mif")) u_b1 (
    .clk(clk), .a_addr(ww), .a_din(wd[15:8]),  .a_we(wsel & wb[1]), .a_q(q1),
    .b_addr(dbg_word), .b_q(dq1));
  m2_tdp_ram #(.DW(8), .AW(12), .INIT_FILE("ff4096x8.mif")) u_b2 (
    .clk(clk), .a_addr(ww), .a_din(wd[23:16]), .a_we(wsel & wb[2]), .a_q(q2),
    .b_addr(dbg_word), .b_q(dq2));
  m2_tdp_ram #(.DW(8), .AW(12), .INIT_FILE("ff4096x8.mif")) u_b3 (
    .clk(clk), .a_addr(ww), .a_din(wd[31:24]), .a_we(wsel & wb[3]), .a_q(q3),
    .b_addr(dbg_word), .b_q(dq3));

  assign rdata = {q3, q2, q1, q0};

  // DEBUG READ PORT, fixed at one word, for the overlay probe. The game's
  // settings splash prints its credit digits from the dword at byte 0x14 --
  // word 5 -- (study R59): the simulation reads 00030300 there and prints
  // '3'; the board prints a green space, so what the board's copy holds at
  // draw time is the question this answers. Costs a second read port on each
  // lane, which Quartus serves by duplication: ~4 M10K, debug-only.
  // WORD 4 COMES THROUGH THE SAME PORT, ADDRESS-MUXED. A separate always_ff
  // reading the lanes was a THIRD read port, M10K has two, and Quartus
  // decomposed all 16 KB into logic: 131,795 combinational nodes against the
  // device's 83,820. The R53 lesson restated: an array's port count is part of
  // its type, and one reader too many silently changes what it is.

  assign dbg_q = {dq3, dq2, dq1, dq0};

  // WHAT THE GAME'S FIRST READ OF THE SETTINGS DWORD ACTUALLY RETURNED. The
  // board holds the correct 00030300 at menu time and still prints blanks, so
  // the question is what value the DRAW consumed: this latches the rdata of
  // the first read of word 5 after reset, plus a read counter. FFFFFFFF here
  // with 00030300 in dbg_q means the draw ran before the settings were
  // written; 00030300 here moves the fault downstream of the read.
  // NUMBERED-READ CAPTURE. The first read of the settings dword returned the
  // correct value on the board (read #1 latched 030300) and the digits still
  // print as spaces -- but the dword is ZEROED AND REWRITTEN between that
  // first read and the draw's own read (~#7 of 10 in simulation). So capture
  // read #(dbg_rd_sel+1) specifically: stepping the selector through 0..7 on
  // the bench walks the whole read sequence and finds the read that differs
  // from the simulation's.
  logic [31:0] dbg_first_rd;
  logic  [7:0] fr_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_first_rd <= 32'd0; fr_cnt <= 8'd0;
    end else if (sel && !we && word == 12'd5) begin
      if (fr_cnt == {4'd0, dbg_rd_sel}) dbg_first_rd <= {q3, q2, q1, q0};
      if (!(&fr_cnt)) fr_cnt <= fr_cnt + 8'd1;
    end
  end
  assign dbg_first = {fr_cnt, dbg_first_rd[23:0]};

endmodule
