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
  // 1 = a real m2_ioz80 drives the store through the z_* port and the
  // behavioural exchange below stays silent (R61). 0 = R37-R41's imitation.
  parameter bit USE_Z80 = 1'b0,
  // Cycles from reset before the board answers the flag. MEASURED: MAME clears
  // it on frame 174 of a 57.5 Hz refresh, which is 3.026 s. At 25 MHz that is
  // 75,652,174 -- a 27-bit counter, and it counts once.
  // Defaults are for the 48 MHz core clock. THEY ENCODE A DURATION, NOT A
  // COUNT: status at frame 7 and the board's self-test at frame 174 of a
  // 57.5 Hz refresh. Every clock change has to move them, and the counter is
  // sized from this parameter so that a change cannot silently overflow it.
  parameter int          SELFTEST_CYCLES = 145_252_176,

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
  parameter int          STATUS_CYCLES   = 5_843_478,

  // What the board leaves in the status byte at DPRAM 0x21. Observed 0x40.
  parameter logic [7:0]  STATUS_READY    = 8'h40,

  // Pushing the 128-byte identity block into DPRAM 0x100-0x17f. OFF, and the
  // reason is the third reading this protocol has had.
  //
  //   1. "The i960 writes the block and the board completes the tail." The
  //      status reply was hung off the window write, and the boot deadlocked
  //      waiting for a status it would not get until it wrote a window it would
  //      not write until it had the status.
  //
  //   2. "The board supplies the block; the i960 copies it in." The
  //      disassembly at 0022827C plainly reads DPRAM and writes backup SRAM, so
  //      DPRAM is the source. Model 1's `122988c` says the same about the same
  //      board. Both true, and the conclusion still wrong.
  //
  //   3. What the reference actually does. The i960 copies whatever is in the
  //      window -- ZEROS, that early -- into backup SRAM, then VALIDATES it:
  //
  //        00227CF4: ldl    0x1d00000,g4    ; what was copied in
  //        00227CFC: ldq    0x23c150,g0     ; "SEGA..." from ROM
  //        00227D04: cmpibe g4,g0,0x227de4  ; already valid? skip
  //        00227D08: stq    g0,0x1d00000    ; otherwise initialise it here
  //
  //      finds it invalid, and initialises backup SRAM ITSELF. Supplying the
  //      block makes that compare succeed and the i960 skips its own
  //      initialisation -- so the window's later contents match backup SRAM
  //      because the i960 put them there, which is what reading (1) saw and
  //      misattributed.
  //
  // MEASURED, not argued: the differential against MAME diverges at 2,609,803
  // instructions with the window left empty and at 1,300,259 with the block
  // pushed. HARDWARE COULD NOT TELL THESE APART -- row 8 read 4,097 either way.
  parameter bit          COMPLETE_WINDOW = 1'b0
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
  // The Z80 board's byte port; tie z_we low when the behavioural FSM serves.
  input  logic        z_we,
  input  logic [10:0] z_addr,
  input  logic  [7:0] z_wdata,
  output logic  [7:0] z_rdata,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] rdata,

  // The screen is the only output channel, so the interesting state is a word.
  output logic [31:0] dbg,
  // Reads in the block window, 0x100-0x17f. The i960 reads all 128 bytes once
  // per attempt, so this says whether the copy loop is running at all and how
  // many times it has gone round -- which a tile-write count cannot.
  output logic [15:0] dbg_win_rd,

  // WHAT THE i960 ACTUALLY READ, taken off `rdata` rather than off the state
  // that produced it. `dbg` reports the shadow registers, which follow the
  // WRITES; the boot reads the ARRAY. On hardware those disagreed: row 14 said
  // flag 00 and status 40 -- both polls satisfied -- while the boot sat in
  // them and never reached the copy at 0022827C, with zero window reads and
  // zero backup writes to prove it. A shadow of a write is not evidence about
  // a read.
  output logic [15:0] dbg_flag_rd,     // reads of the flag dword
  output logic [15:0] dbg_seen,        // {status, flag} as returned to the CPU

  // THE ARBITRATION THE PROTOCOL WAS BUILT AROUND, AND WHICH WE NEVER HAD.
  //
  // The real part is an MB8421 dual-port RAM: when both sides reach for the
  // same place it raises BUSY at the later one, and the 315-5338A reports that
  // in its status register. The firmware waits on it -- its own code, at 0x815:
  //
  //     LD B,0Fh          ; a timeout of 15
  //     LD A,(IY+13)      ; read status
  //     BIT 0,A           ; test BUSY
  //     JR NZ,0819h       ; wait while it is set
  //
  // Our status register returned a constant 0x08. Bit 0 always clear means the
  // firmware NEVER waits, so it refills the window while the game is reading
  // it, the game gets the input-scan pattern instead of settings (R63's 7F FF),
  // rejects it, and reissues the exchange -- forever. That is the board's
  // 3,554 polls, and the reason nothing downstream ever starts.
  //
  // win_busy says the game is inside the block window right now. Held for a
  // few cycles because the firmware samples this at 4 MHz through a paced Z80
  // and a single 48 MHz pulse would be invisible to it.
  output logic        win_busy,
  // The Z80's publication of DPRAM word 4 -- byte 0x10 to the i960, which
  // MAME says is the ONE byte a coin changes. Tapped off the existing write,
  // so it costs no read port. {distinct values seen, lowest, current}.
  output logic [23:0] dbg_word4
);

  localparam logic [9:0] FLAG_W  = 10'h010;   // DPRAM 0x20 low, 0x21 high
  localparam logic [10:0] FILL_FROM = 11'h100;
  localparam logic [10:0] FILL_LAST = 11'h17f;

  // TWO 1024 x 8 LANES, ONE WRITE PORT, REGISTERED READ.
  //
  // THIS SHAPE IS NOT A PREFERENCE, IT IS THE PROJECT'S STANDING RULE, and it
  // took two builds to remember it:
  //
  //   "Split memories into byte lanes, tag them (* ramstyle = "M10K" *), and
  //    never clear an array in reset."   -- the project rules, and mister-integration.md
  //
  // The first version was one 1024 x 16 array with byte-lane write ENABLES,
  // asynchronously read, tagged MLAB. The tag was ignored and it became 16,384
  // flip-flops: +7,899 ALM, whole-core 17,532 -> 25,431. Retagging it M10K and
  // registering the read changed nothing -- RAM blocks stayed at 237, registers
  // went UP to 36,640 -- because the shape was still wrong in two ways at once:
  // byte enables instead of lanes, and TWO write address expressions in one
  // always block (`dp[word]` and `dp[b_word]`), which is not a single write
  // port however it is tagged.
  //
  // Both builds reported Successful with timing closed. A RAM TAG IS A REQUEST,
  // NOT AN INSTRUCTION, simulation cannot see the difference, and the fitter
  // will not tell you it declined -- the register count is the only witness.
  //
  // So: the address, data and enables are muxed into ONE write port before the
  // memory, and each byte lane is its own array with a plain write enable.
  (* ramstyle = "M10K" *) logic [7:0] dp_lo [1024];
  (* ramstyle = "M10K" *) logic [7:0] dp_hi [1024];
  logic [7:0] q_lo, q_hi;

  // One write port. The CPU wins; the board's writes are a handful of bytes at
  // two moments and the i960 is polling rather than writing when they land.
  // Z80-SIDE PORT (study R61). When a real m2_ioz80 drives these, the
  // behavioural state machine below must be quiet: tie Z80_SIDE high and the
  // internal b_we never fires. Byte address: word = z_addr[10:1], lane =
  // z_addr[0] -- the same mapping the i960's umask gives its two bytes.
  wire        zb_we   = z_we;
  wire  [9:0] zb_word = z_addr[10:1];
  wire        wr_en   = cpu_wr | b_we | zb_we;
  wire  [9:0] wr_addr = cpu_wr ? word : zb_we ? zb_word : b_word;
  wire  [7:0] wr_lo   = cpu_wr ? wdata[7:0]   : zb_we ? z_wdata : b_data[7:0];
  wire  [7:0] wr_hi   = cpu_wr ? wdata[23:16] : zb_we ? z_wdata : b_data[15:8];
  wire        we_lo   = wr_en & (cpu_wr ? be[0] : zb_we ? ~z_addr[0] : b_be[0]);
  wire        we_hi   = wr_en & (cpu_wr ? be[2] : zb_we ?  z_addr[0] : b_be[1]);

  // WHAT THE Z80 PUBLISHES AT DPRAM WORD 4, which is byte 0x10 in the i960's
  // view. MAME says a coin changes exactly that byte and nothing else -- ff to
  // fe, bit 0 low for COIN1 -- so the Z80 publishes the input scan and the i960
  // does the crediting. The pin is known good (the core counts the edge), free
  // play works, and the coin still does not credit, so the question is whether
  // this byte ever moves. Tapped off the existing write, which costs no port.
  logic [7:0] dbg_w4_lo;
  logic [7:0] dbg_w4_seen;         // how many distinct values it has taken
  logic [7:0] dbg_w4_min;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_w4_lo <= 8'hff; dbg_w4_seen <= 8'd0; dbg_w4_min <= 8'hff;
    end else begin
      // WORD 4 SPECIFICALLY, which is the byte a coin moves.
      //
      // The first version of this latched the last non-idle write ANYWHERE, and
      // the Z80 writes word 1 several times a frame, so the latch never held
      // anything else: 255 writes counted and the coin invisible under them. An
      // instrument has to be selective about the thing it is measuring or the
      // busiest signal wins.
      //
      // The address is no longer a guess. MAME's DPRAM is umasked to bytes 0
      // and 2 of each dword, so DPRAM byte 0x08 -- where R65 measured in0 -- is
      // i960 address 0x01c00010 is dword 4 is dp_lo[4]. R65's "byte 0x08" and
      // the MAME write tap's "byte 0x10" are the same place in two numberings.
      //
      // A coin is a transient of a few frames, so the MINIMUM ever written is
      // what survives between samples; a coin shows as 0xFE, and 0xFF forever
      // means the firmware never scanned one.
      if (we_lo && wr_addr == 10'd4) begin
        dbg_w4_lo <= wr_lo;
        if (wr_lo < dbg_w4_min) dbg_w4_min <= wr_lo;
      end
      // AND ANYWHERE AT ALL, as a backstop: the word index of the last write
      // whose value had bit 0 low. If the coin lands somewhere other than word
      // 4 this says where, and the two together cannot both miss it.
      if (we_lo && !wr_lo[0] && !(&dbg_w4_seen)) dbg_w4_seen <= {2'd0, wr_addr[5:0]};
    end
  end

  // {word index of the last bit0-low write anywhere, lowest ever at word 4,
  //  current value at word 4}
  assign dbg_word4 = {dbg_w4_seen, dbg_w4_min, dbg_w4_lo};

  logic [7:0] zq_lo, zq_hi;
  always_ff @(posedge clk) begin
    if (we_lo) dp_lo[wr_addr] <= wr_lo;
    q_lo  <= dp_lo[word];
    zq_lo <= dp_lo[z_addr[10:1]];
  end
  always_ff @(posedge clk) begin
    if (we_hi) dp_hi[wr_addr] <= wr_hi;
    zq_hi <= dp_hi[z_addr[10:1]];
    q_hi <= dp_hi[word];
  end

  assign z_rdata = z_addr[0] ? zq_hi : zq_lo;
  assign rdata = {8'd0, q_hi, 8'd0, q_lo};


  // THE IDENTITY BLOCK. The board supplies all 128 bytes of DPRAM 0x100-0x17f
  // and the i960 copies them into backup SRAM before it will go on:
  //
  //   00228230: lda  0x1c00200,g6      ; source = DPRAM window
  //   00228238: lda  0x1d00000,g5      ; dest   = backup SRAM
  //   0022827C: ldob (g6),g4           ; DPRAM is the SOURCE
  //   00228280: stob g4,(g5)
  //
  // read at stride 2 because the DPRAM is eight bits wide at bytes 0 and 2 of
  // each dword, written at stride 1 into ordinary RAM.
  //
  // THIS FILE PREVIOUSLY HAD THE ARROW BACKWARDS. docs/io-board.md said "the
  // i960 writes the block; the board does not supply it", from a frame-by-frame
  // dump in which the window's contents matched backup SRAM exactly. They match
  // because the i960 had just copied them THAT way. A correlation between two
  // memories does not carry a direction, and the disassembly does.
  //
  // Model 1's `122988c` had already found this on the same board -- "the V60
  // block-reads all of it once, immediately after its first handshake is
  // answered, and will not go on to poll its controls until it has... ours read
  // zeros and looped at fe1433 forever" -- and it was read, written into our own
  // docs, and then overridden by the misread measurement.
  //
  // Values are MAME's, sampled at frames 10, 60, 120, 300 and 900 and identical
  // at all five (tools/mame_m2_idblock.lua). Sampled repeatedly because the
  // Model 1 core took this block from ONE snapshot mid-push and got six bytes
  // wrong, one of which gated its coprocessor path.
  function automatic logic [7:0] idblk(input logic [6:0] i);
    case (i)
      7'h00: idblk = 8'h53; 7'h01: idblk = 8'h45;  // "SEGA"
      7'h02: idblk = 8'h47; 7'h03: idblk = 8'h41;
      7'h04: idblk = 8'h40; 7'h05: idblk = 8'h82;
      7'h06: idblk = 8'h01; 7'h07: idblk = 8'h00;
      7'h08: idblk = 8'hbc; 7'h09: idblk = 8'heb;
      7'h0a: idblk = 8'h00; 7'h0b: idblk = 8'h00;
      7'h0c: idblk = 8'h00;
      7'h10: idblk = 8'h00; 7'h11: idblk = 8'h01;
      7'h12: idblk = 8'h01; 7'h13: idblk = 8'h01;
      7'h14: idblk = 8'h00; 7'h15: idblk = 8'h03;
      7'h16: idblk = 8'h03; 7'h17: idblk = 8'h00;
      7'h18: idblk = 8'h00; 7'h19: idblk = 8'h00;
      7'h1a: idblk = 8'h00; 7'h1b: idblk = 8'h01;
      7'h20: idblk = 8'h01;
      7'h21, 7'h22, 7'h23, 7'h24, 7'h25, 7'h26, 7'h27,
      7'h28, 7'h29, 7'h2a, 7'h2b, 7'h2c, 7'h2d, 7'h2e, 7'h2f:
                   idblk = 8'h00;
      7'h30: idblk = 8'h02; 7'h31: idblk = 8'h02;
      7'h32: idblk = 8'h14; 7'h33: idblk = 8'h1c;
      7'h34: idblk = 8'h00; 7'h35: idblk = 8'h01;
      7'h36: idblk = 8'h00; 7'h37: idblk = 8'h01;
      7'h38: idblk = 8'h04; 7'h39: idblk = 8'h01;
      7'h7c: idblk = 8'h01;
      7'h7d, 7'h7e, 7'h7f: idblk = 8'h00;
      default: idblk = 8'hff;
    endcase
  endfunction

  // ------------------------------------------------------------- the board
  // WIDTH DERIVED FROM THE PARAMETER, NOT WRITTEN OUT.
  //
  // This was `logic [26:0]`, sized by hand for the 40 MHz clock these timers
  // were last scaled to. Moving to 48 MHz takes frame 174 from 121,044,000
  // cycles to 145,252,176, which needs 28 bits -- so the counter would have
  // wrapped at 134,217,727 and the board would have answered the handshake
  // about a second early, which is the kind of fault that looks like a
  // protocol error and is not one. Derived, it cannot happen again.
  // Named rather than repeated: `($clog2(X))'(...)` as a cast parses in a way
  // that produced a width warning at every use site, and one localparam is
  // clearer than three copies of the expression anyway.
  // TYPED CONSTANTS, not casts at the use site. `SW'(...)` was parsed as a
  // part-select and produced a different width warning under the real build
  // than under a standalone lint, which is a good sign the expression was not
  // saying what it looked like. Declaring the width once, on constants of the
  // counter's own type, leaves nothing to parse.
  localparam int unsigned      SW            = $clog2(SELFTEST_CYCLES);
  localparam logic [SW-1:0]    SELFTEST_MAX  = SW'(SELFTEST_CYCLES - 1);
  localparam logic [SW-1:0]    SELFTEST_ONE  = 1;
  logic [SW-1:0] selftest;
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
  wire win_rd  = sel & ~we & (word >= 10'h080) & (word <= 10'h0bf);
  // Any game-side access to the window, read or write, holds BUSY.
  wire win_acc = sel & (word >= 10'h080) & (word <= 10'h0bf);
  logic [4:0] busy_hold;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          busy_hold <= 5'd0;
    else if (win_acc)    busy_hold <= 5'd31;      // stretch so a 4 MHz Z80 sees it
    else if (|busy_hold) busy_hold <= busy_hold - 5'd1;
  end
  assign win_busy = |busy_hold;
  wire flag_rd = sel & ~we & (word == FLAG_W);

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
      b_we   = !USE_Z80;
      b_word = fill[10:1];
      b_data = {idblk(fill[6:0]), idblk(fill[6:0])};
      b_be   = fill[0] ? 2'b10 : 2'b01;
    end else if (status_pulse) begin
      b_we   = !USE_Z80;
      b_word = FLAG_W;
      b_data = {STATUS_READY, 8'd0};
      b_be   = 2'b10;                       // the status byte only
    end else if (answer) begin
      b_we   = !USE_Z80;
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
      sh_flag <= 8'd0; sh_status <= 8'd0; dbg_win_rd <= 16'd0;
      dbg_flag_rd <= 16'd0; dbg_seen <= 16'd0;
      dbg <= '0;
    end else begin
      status_pulse <= 1'b0;
      answer       <= 1'b0;
      if (win_rd) dbg_win_rd <= dbg_win_rd + 16'd1;
      if (flag_rd) begin
        dbg_flag_rd <= dbg_flag_rd + 16'd1;
        dbg_seen    <= {rdata[23:16], rdata[7:0]};
      end

      // The self-test. It counts once and then stops; `awake` latches.
      if (!awake) begin
        if (selftest == SELFTEST_MAX) awake <= 1'b1;
        else selftest <= selftest + SELFTEST_ONE;
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
        if (fill == FILL_LAST) filling <= 1'b0;
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

endmodule
