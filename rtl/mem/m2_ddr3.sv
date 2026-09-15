// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE DDR3 MASTER. One read/write port onto the MiSTer framework's DDRAM
// interface, with the same request/acknowledge shape m2_sdram presents, so a
// consumer moves between the two memories by rewiring rather than rewriting.
//
// WHY DDR3 AT ALL (R340, R343). This core uses NOT ONE BYTE of the gigabyte the
// framework hands it, while M10K reads 553/553 and the band buffers re-render
// 1.98 identical frames per display list. The framebuffer is what the hardware
// does -- MAME redisplays a persistent bitmap when the geometrizer presents
// nothing new -- and the framework already owns the SCANOUT through FB_EN, so
// only the write side is ours to build.
//
// THE PROTOCOL, taken from sys/arcade_video.v's screen_rotate, which is the one
// proven example of driving this port on this board:
//
//   DDRAM_ADDR      a 64-BIT WORD address, not a byte address
//   DDRAM_BURSTCNT  how many 64-bit words this request covers
//   DDRAM_BE        byte enables, for a write of less than the full word
//   DDRAM_DIN       write data, 64 bits
//   DDRAM_WE/RD     request; held until it is ACCEPTED
//   DDRAM_BUSY      the request has NOT been taken -- hold everything
//   DDRAM_DOUT      read data, one word per DDRAM_DOUT_READY pulse
//
// **screen_rotate DOES NOT CHECK DDRAM_BUSY.** It can get away with it because
// a video writer produces one word per pixel clock and never backs up. A memory
// master cannot: a request dropped while BUSY is a read that never returns and
// a write that never lands. This honours it.
//
// LATENCY IS NOT KNOWN AND IS NOT ASSUMED. Every consumer moved here has to
// tolerate whatever the HPS leaves us, and the first job of this module is to
// MEASURE that rather than to design around a guess -- see dbg_lat_*, and the
// self-test that uses them. SDRAM's round trip is 13 cycles at 100 MHz; if DDR3
// is much worse than that under HPS load, the low-latency consumers stay where
// they are and only the framebuffer moves.

`timescale 1ns/1ps

module m2_ddr3 #(
  // R351: A 64-BIT WORD ADDRESS, AND THE FIRST VALUE HERE WAS IN BYTES.
  //
  // DDRAM_ADDR indexes 64-BIT WORDS: the byte address is ADDR * 8. This was set
  // to 29'h0800_0000 meaning "0x08000000", which as a word address is BYTE
  // 0x40000000 -- one gigabyte, past the end of the memory. The board reported
  // it exactly: the self-test completed, the round trip measured a plausible
  // 13 cycles typical and 50 worst, and ALL 256 WORDS CAME BACK WRONG. The
  // transactions were real; they just went nowhere.
  //
  // ANCHORED TO THE ONE REGION KNOWN TO BE FPGA TERRITORY, not chosen. The
  // memory is 1 GB and shared with Linux on the HPS, so "somewhere high" is a
  // guess about whose RAM it is -- and 0x40000000 being exactly 1 GB is what
  // made the first value silently wrong. screen_rotate places three 8 MB
  // framebuffers at byte 0x24000000, running to 0x25800000; that region is
  // demonstrably the FPGA's, so ours sits immediately above it at byte
  // 0x26000000 = word 0x04C0_0000. Two 762 KB buffers need 1.5 MB.
  //
  // The module header said "a 64-BIT WORD address, not a byte address" while
  // this parameter was set in bytes, which is worth remembering: writing the
  // warning down is not the same as heeding it.
  parameter logic [28:0] BASE = 29'h04C0_0000
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the consumer side, shaped like m2_sdram's ports
  input  logic        req,
  input  logic        we,
  input  logic [24:0] addr,        // 64-bit words, relative to BASE
  // R347: WORDS IN THIS TRANSACTION. MiSTer's own guidance is that DDR3 here
  // is ~200 ns typical and UNBOUNDED in the worst case, because the bridge is
  // shared with the HPS, and that a core must use high burst counts or heavy
  // caching rather than rapid single-word access. One word a request -- what
  // this module did first -- is the access pattern that guidance warns against.
  input  logic [7:0]  blen,
  input  logic [63:0] din,
  input  logic [7:0]  be,
  // A write burst takes one word per `wnext`; the consumer presents the next on
  // `din`. A read burst returns one word per `rvalid`. `ack` is the whole
  // transaction finishing, so a single-word caller can ignore the other two.
  output logic        wnext,
  output logic        rvalid,
  output logic        ack,
  output logic [63:0] dout,

  // ---- the framework's DDRAM port
  output logic        DDRAM_CLK,
  input  logic        DDRAM_BUSY,
  output logic [7:0]  DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  output logic [63:0] DDRAM_DIN,
  output logic [7:0]  DDRAM_BE,
  output logic        DDRAM_WE,
  output logic        DDRAM_RD,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY,

  // ---- what the round trip actually costs, in clk cycles
  output logic [15:0] dbg_lat_last,
  output logic [15:0] dbg_lat_max,
  output logic [31:0] dbg_reads,
  // R362: CYCLES IN FLIGHT, WHETHER OR NOT THE TRANSACTION EVER FINISHES.
  // dbg_lat_max is written on COMPLETION, so a transfer that hangs never
  // updates it -- the board reported a frozen 262 while the bridge had been
  // stuck for four minutes. This one is updated while waiting, so a hang reads
  // as a huge number instead of as silence, and bit 15 says whether the stuck
  // transaction was a write.
  output logic [15:0] dbg_inflight_max,
  output logic        dbg_stuck_wr
);

  assign DDRAM_CLK      = clk;
  assign DDRAM_BURSTCNT = blen_r;

  // R362: THE ADDRESS IS LATCHED FOR THE WHOLE BURST, AND IT HAS TO BE.
  //
  // This was `BASE + 29'(addr)` straight off the consumer input. Avalon holds
  // the master to a constant address and burstcount for every beat of a burst
  // -- the slave samples them once and counts -- and a consumer that moves its
  // address mid-burst therefore corrupts a transfer already in flight. That is
  // not a hypothetical: m2_fb_read updates y_r on EVERY line_req, in flight or
  // not, so a line request arriving during a 248-beat read walked the address
  // under the bridge. On the board the first burst completed (262 cycles, and
  // dbg_lat_last never moved again) and the next collision wedged the bridge
  // for the rest of the capture: 0 lines fetched, 0 pixels painted, 0 frames
  // published, with 52,695 line requests landing on a busy reader.
  //
  // Latched HERE rather than fixed only in the consumer, because protocol
  // compliance is this module's job: it is the one thing on the port, and a
  // future consumer must not be able to break the bridge by being careless.
  // BE is latched with it -- our writers vary it per TRANSACTION (the head and
  // tail of a span), never per beat.
  //
  // DIN IS NOT LATCHED, and must not be: a write burst takes a new word every
  // `wnext` and that is exactly what the consumer is being asked for.
  logic [24:0] addr_r;
  logic [7:0]  be_r;
  assign DDRAM_ADDR     = BASE + 29'(addr_r);
  assign DDRAM_DIN      = din;
  assign DDRAM_BE       = be_r;

  typedef enum logic [1:0] { D_IDLE, D_ISSUE, D_WAIT } st_t;
  st_t st;

  logic        is_wr;
  logic [7:0]  blen_r, beats;
  logic [15:0] lat;

  assign DDRAM_WE = (st == D_ISSUE) &&  is_wr;
  assign DDRAM_RD = (st == D_ISSUE) && !is_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= D_IDLE; is_wr <= 1'b0; ack <= 1'b0; dout <= '0;
      addr_r <= '0; be_r <= 8'hFF;
      blen_r <= 8'd1; beats <= 8'd1; wnext <= 1'b0; rvalid <= 1'b0;
      lat <= '0; dbg_lat_last <= '0; dbg_lat_max <= '0; dbg_reads <= '0;
      dbg_inflight_max <= '0; dbg_stuck_wr <= 1'b0;
    end else begin
      ack <= 1'b0; wnext <= 1'b0; rvalid <= 1'b0;

      // R362: watch the transfer WHILE it is in flight, not when it lands.
      if ((st != D_IDLE) && (lat > dbg_inflight_max)) begin
        dbg_inflight_max <= lat;
        dbg_stuck_wr     <= is_wr;
      end
      case (st)
        D_IDLE: if (req) begin
          is_wr  <= we;
          blen_r <= (blen == 8'd0) ? 8'd1 : blen;
          beats  <= (blen == 8'd0) ? 8'd1 : blen;
          addr_r <= addr;                 // R362: held for the whole burst
          be_r   <= be;
          lat    <= '0;
          st     <= D_ISSUE;
        end

        // HELD UNTIL TAKEN. BUSY means the bridge has not accepted this
        // request, and dropping it here is the whole class of bug this module
        // exists to avoid.
        D_ISSUE: begin
          if (!(&lat)) lat <= lat + 16'd1;   // R362: saturate, a wrapped hang reads as short
          if (!DDRAM_BUSY) begin
            if (is_wr) begin
              // One beat taken. ADDR and BURSTCNT matter on the first only;
              // the rest are consecutive words, so the consumer just advances.
              wnext <= 1'b1;
              if (beats == 8'd1) begin
                ack <= 1'b1;
                st  <= D_IDLE;
              end else beats <= beats - 8'd1;
            end else st <= D_WAIT;
          end
        end

        D_WAIT: begin
          if (!(&lat)) lat <= lat + 16'd1;   // R362: saturate, a wrapped hang reads as short
          if (DDRAM_DOUT_READY) begin
            dout   <= DDRAM_DOUT;
            rvalid <= 1'b1;
            if (!(&dbg_reads)) dbg_reads <= dbg_reads + 32'd1;
            if (beats == 8'd1) begin
              ack <= 1'b1;
              // THE WHOLE BURST, not the first word. What matters for a
              // consumer is when the last word lands.
              dbg_lat_last <= lat;
              if (lat > dbg_lat_max) dbg_lat_max <= lat;
              st <= D_IDLE;
            end else beats <= beats - 8'd1;
          end
        end

        default: st <= D_IDLE;
      endcase
    end
  end

endmodule
