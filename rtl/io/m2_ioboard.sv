// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The I/O board, as the far side of the dual-port RAM at 0x01c00000.
//
// On the real cabinet a Z80 behind a 315-5338A sits here running EPR-14869 --
// the SAME board and the SAME ROM as Model 1's, confirmed from model2.cpp:
// model2o instantiates SEGA_MODEL1IO with bios epr14869c. This is not that
// chip. It answers what the boot has been OBSERVED to need, and docs/io-board.md
// records the measurement rather than this file asserting it.
//
// Derived in shape from tools/model1-ref rtl/io/m1_ioboard.sv at commit
// 72131a3; see THIRD_PARTY.md. The protocol is NOT copied from it, because on
// this machine it is the other way round -- see below.
//
// ADDRESSING. The DPRAM is 2K x 8 behind umask32(0x00ff00ff), so it lives in
// bytes 0 and 2 of each dword:
//
//   DPRAM byte N  ->  0x01c00000 + (N >> 1) * 4 + (N & 1) * 2
//
// One dword access therefore touches exactly two DPRAM bytes, which is why the
// store below is 1024 x 16 -- word k holds byte 2k in [7:0] and byte 2k+1 in
// [15:8]. DPRAM 0x20 is 0x01c00040, the byte the boot polls, and 0x21 is
// 0x01c00042 beside it: the pair R37 traced before it was known what they were.
//
// WHAT THE MEASUREMENT SAYS, and it is the opposite of Model 1. There, the V60
// block-READS a 128-byte identity block the board pushes, and a core that leaves
// the window empty loops forever with every input byte underneath it already
// correct. Here the i960 WRITES the block -- its own backup SRAM, copied
// outward -- and the board completes it:
//
//   frame 1   flag=01 status=00   window all zero
//   frame 6   flag=01 status=00   0x00-0x42 written, rest still zero
//   frame 7   flag=01 status=40   0x43-0x7b = ff, 0x7c = 01
//   frame 174 flag=00             the poll at 0x228240 finally falls through
//
// So there are two separate replies, on two separate triggers, and conflating
// them would reproduce neither.
//
// THE FLAG IS NOT CLEARED ON A TIMER FROM THE REQUEST. Model 1 measured its
// equivalent at 740,684 cycles and found the number was not a mailbox
// turnaround at all -- it is the board's Z80 running its own power-on self-test
// before it ever looks at the flag, which is why it is enormous and why it
// happens exactly once. The same shape holds here: the i960 raises the flag at
// frame 1 and writes 01, 03, 02, 01 into it over the next twenty frames while
// the board is not yet listening, and the clear lands at frame 174 regardless.
// SELFTEST_CYCLES is therefore measured FROM RESET, not from the request.
//
// ONE WRITE PORT, DELIBERATELY. The MB8421 is a true dual-port RAM and this is
// not; Model 1 measured what asking Quartus 17.0 for a second write port costs
// -- 192 ALM becoming 16,059 -- against roughly 7,400 ALM of headroom here. The
// board's writes are a handful of bytes at two moments and the i960 is polling
// rather than writing when they land, so a shared port with the CPU winning is
// not a compromise that has to be paid for later.

`timescale 1ns/1ps

module m2_ioboard #(
  // Cycles from reset before the board answers the flag. MEASURED: MAME clears
  // it on frame 174 of a 57.5 Hz refresh, which is 3.026 s. At 25 MHz that is
  // 75,652,174 -- a 27-bit counter, and it counts once.
  parameter int          SELFTEST_CYCLES = 75_652_174,

  // Cycles from reset before the board raises the status byte. MEASURED at
  // frame 7 of a 57.5 Hz refresh -- 0.122 s, or 3,043,478 cycles at 25 MHz.
  //
  // THIS IS NOT A REPLY TO THE WINDOW WRITE, and modelling it as one deadlocks
  // against the code it was built from. The boot parks at
  //
  //   0022824C: ldob    0x1c00042,g4      ; status
  //   00228254: setbit  6,0,g1            ; 0x40
  //   00228258: cmpibne g4,g1,0x22824c    ; spin until status == 0x40
  //   0022825C: mov     3,g2
  //   00228260: stob    g2,0x1c00040      ; only THEN write the flag again
  //
  // waiting for 0x40 BEFORE it writes anything into the window. The window
  // write at frame 6 and the status at frame 7 are consecutive, and reading
  // two consecutive events as a cause and an effect produced a board that the
  // boot could never get past.
  parameter int          STATUS_CYCLES   = 3_043_478,

  // What the board leaves in the status byte at DPRAM 0x21. Observed 0x40.
  parameter logic [7:0]  STATUS_READY    = 8'h40,

  // Completing the window: 0x143-0x17b to 0xff and 0x17c to 0x01.
  //
  // ATTRIBUTED BY INFERENCE, NOT BY MEASUREMENT. The state is observed -- those
  // bytes hold those values from frame 7 -- but nothing here establishes that
  // the BOARD wrote them rather than the i960 finishing its own block. It is a
  // parameter so the differential can settle it: turn it off, and if the boot
  // still reaches the same instruction, the i960 was writing them.
  parameter bit          COMPLETE_WINDOW = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // The i960 side. `word` is the dword index inside the region, address[11:2].
  input  logic        sel,
  input  logic        we,
  input  logic  [9:0] word,
  // Byte lanes 1 and 3, and the wdata bits behind them, ARE NOT READ, and that
  // is the device rather than an oversight: umask32(0x00ff00ff) means the DPRAM
  // occupies bytes 0 and 2 of each dword and bytes 1 and 3 are not connected.
  // Left full width and silenced here rather than narrowed, because the bus IS
  // 32 bits and a trimmed port would hide that half of it goes nowhere.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] rdata,

  // The screen is the only output channel, so the interesting state is a word.
  output logic [31:0] dbg
);

  localparam logic [9:0] FLAG_W  = 10'h010;   // DPRAM 0x20 low, 0x21 high
  localparam logic [10:0] FILL_FROM = 11'h143;
  localparam logic [10:0] FILL_TO   = 11'h17b;
  localparam logic [10:0] FILL_MARK = 11'h17c;

  // 1024 x 16, asynchronously read because the i960's I/O read path is a
  // combinational mux. Tagged MLAB rather than left to inference: as M10K this
  // is two blocks, and M10K is the binding resource on this part while LAB area
  // is not -- 26 MLABs is the cheaper side of that trade. Never cleared in
  // reset, per the standing rule; power-up content is the FPGA's zeros and the
  // boot writes what it reads.
  (* ramstyle = "MLAB" *) logic [15:0] dp [1024];

  assign rdata = {8'd0, dp[word][15:8], 8'd0, dp[word][7:0]};

  // ------------------------------------------------------------- the board
  logic [26:0] selftest;
  logic        awake;              // self-test finished; the flag is watched now
  logic        flag_cleared;       // for the overlay: it has answered at least once
  logic        status_pulse;       // one cycle: write the status byte
  logic        answer;             // one cycle: clear the flag

  logic [26:0] stat_ctr;
  logic        status_done;

  logic [10:0] fill;               // byte address while completing the window
  logic        filling;

  // Shadows of the two handshake bytes, for the overlay. Reading them back out
  // of `dp` would be a SECOND asynchronous read port on an MLAB that has one,
  // which Quartus answers by duplicating the whole array. A pair of registers
  // is the same information for 16 bits.
  logic  [7:0] sh_flag, sh_status;

  wire cpu_wr = sel & we;

  // The board's own write, for the cycles the CPU is not using the port.
  logic        b_we;
  logic  [9:0] b_word;
  logic [15:0] b_data;
  logic  [1:0] b_be;

  always_comb begin
    b_we   = 1'b0;
    b_word = FLAG_W;
    b_data = 16'd0;
    b_be   = 2'b00;
    if (filling) begin
      b_we   = 1'b1;
      b_word = fill[10:1];
      // 0xff across 0x143-0x17b, then 0x01 at 0x17c. Written as a range test
      // rather than a counter comparison so the constants in the file match
      // the ones in docs/io-board.md by eye.
      b_data = (fill <= FILL_TO) ? {8'hff, 8'hff} : {8'h01, 8'h01};
      b_be   = fill[0] ? 2'b10 : 2'b01;
    end else if (status_pulse) begin
      b_we   = 1'b1;
      b_word = FLAG_W;
      b_data = {STATUS_READY, 8'd0};
      b_be   = 2'b10;                       // the status byte only
    end else if (answer) begin
      b_we   = 1'b1;
      b_word = FLAG_W;
      b_data = 16'd0;
      b_be   = 2'b01;                       // the flag byte only
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      selftest <= '0; awake <= 1'b0; flag_cleared <= 1'b0;
      stat_ctr <= '0; status_done <= 1'b0; status_pulse <= 1'b0; answer <= 1'b0;
      fill <= FILL_FROM; filling <= 1'b0;
      sh_flag <= 8'd0; sh_status <= 8'd0;
      dbg <= '0;
    end else begin
      status_pulse <= 1'b0;
      answer       <= 1'b0;

      // The self-test. It counts once and then stops; `awake` latches.
      if (!awake) begin
        if (selftest == 27'(SELFTEST_CYCLES - 1)) awake <= 1'b1;
        else selftest <= selftest + 27'd1;
      end

      // ONCE AWAKE, THE BOARD ANSWERS; IT IS NOT A ONE-SHOT.
      //
      // The first version cleared the flag exactly once, because MAME clears
      // it exactly once. That is a description of the reference's TIMELINE,
      // not of the board's behaviour, and it deadlocks: our i960 is about
      // three times slower per frame, so it had not yet written its command
      // when the single clear fired. The clear landed on nothing, the command
      // that followed was never answered, and the boot parked at
      //
      //   00228268: ldob    0x1c00040,g4
      //   00228270: cmpibne 0,g4,0x228268
      //
      // Modelled as "not listening until the self-test finishes, answering
      // after that" it does not depend on the two machines running at the same
      // speed. KNOWN DIVERGENCE, stated rather than hidden: on the reference
      // the flag STAYS set after boot, re-raised once a frame as a doorbell and
      // never cleared again. This clears it every time -- right for the phase
      // the boot is in, wrong afterwards, and the differential will say when it
      // begins to matter.
      if (awake && sh_flag != 8'd0 && !answer) answer <= 1'b1;

      // The status byte, on the board's own schedule.
      if (!status_done) begin
        if (stat_ctr == 27'(STATUS_CYCLES - 1)) begin
          status_done  <= 1'b1;
          status_pulse <= 1'b1;
        end else stat_ctr <= stat_ctr + 27'd1;
      end

      // THE FILL STARTS THE CYCLE AFTER THE STATUS WRITE, NOT THE SAME ONE.
      // Both drive the single shared write port, and the arbiter below gives
      // `filling` priority -- so raising them together meant the status byte
      // was never written at all. The test caught it: "status after reply got
      // 00000000 want 00000040", with every fill byte correct. One port means
      // two replies cannot be issued on one cycle, and saying so in the
      // sequencing is clearer than widening the arbiter to hide it.
      if (status_pulse && COMPLETE_WINDOW) begin
        filling <= 1'b1;
        fill    <= FILL_FROM;
      end

      if (filling) begin
        if (fill == FILL_MARK) filling <= 1'b0;
        else                   fill    <= fill + 11'd1;
      end

      // The shadows follow whichever side wrote, so they cannot disagree with
      // the array about what the boot would read. Folded into this process
      // rather than given their own: two always_ff blocks driving one variable
      // is MULTIDRIVEN, and the simulator is right to refuse it.
      if (cpu_wr && word == FLAG_W) begin
        if (be[0]) sh_flag   <= wdata[7:0];
        if (be[2]) sh_status <= wdata[23:16];
      end else if (b_we && b_word == FLAG_W) begin
        if (b_be[0]) begin sh_flag <= b_data[7:0]; flag_cleared <= 1'b1; end
        if (b_be[1]) sh_status <= b_data[15:8];
      end

      dbg <= {3'd0, flag_cleared, awake, filling, status_done, 1'b0,
              sh_status, sh_flag, 8'd0};
    end
  end

  // ------------------------------------------------------- the shared port
  // The CPU wins. Its writes are bursty and the board's are a handful of bytes
  // at two moments, and the i960 is polling rather than writing when they land.
  always_ff @(posedge clk) begin
    if (cpu_wr) begin
      if (be[0]) dp[word][7:0]  <= wdata[7:0];
      if (be[2]) dp[word][15:8] <= wdata[23:16];
    end else if (b_we) begin
      if (b_be[0]) dp[b_word][7:0]  <= b_data[7:0];
      if (b_be[1]) dp[b_word][15:8] <= b_data[15:8];
    end
  end

endmodule
