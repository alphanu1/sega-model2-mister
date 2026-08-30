// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// An eight-byte buffer in front of a MULTIPCM's sample fetch, and it is not an
// optimisation -- without it the chip does not keep time.
//
// THE REASON IS IN THE CHIP'S OWN LOOP. m2_multipcm advances its slot and tick
// counters only while no fetch is outstanding:
//
//     else if (!rom_req) begin
//         tick <= tick + 1'b1;
//
// so memory latency does not merely delay a sample, it STRETCHES THE SAMPLE
// PERIOD. 224 enables at 10 MHz is 44.6 kHz; add twenty-eight slot fetches of
// SDRAM latency per output sample and the rate collapses. Measured against
// fetch latency in cycles, the last tenth of a run holds:
//
//     6 -> -978..668     20 -> -620..602     40 -> -1720..1664     80 -> SILENT
//
// There is a cliff, and on hardware the latency is not a constant -- it moves
// with what the other seven SDRAM ports are doing. That is audible as sound
// which starts slow and speeds up as the picture settles, and as voice samples,
// which are the longest sequential reads, arriving mangled or not at all.
//
// The chip asks for ONE BYTE at a time and the controller returns FOUR WORDS.
// Seven of every eight bytes were being fetched and thrown away. Keeping the
// burst answers a sequential reader in two cycles instead of twenty or forty,
// and sample playback and the twelve-byte descriptor reads are both sequential.
//
// ONE LINE PER VOICE, AND ONE LINE TOTAL DOES NOT WORK. That was the first
// version of this file and it was measured to make NO DIFFERENCE AT ALL --
// 87%, 77%, 59% of nominal at three latencies, identical with the buffer
// enabled and disabled. The reason is in the chip's loop: it round-robins 28
// slots, so consecutive fetches come from 28 UNRELATED sample streams and every
// access evicts the one before it. A single line has a hit rate of zero here,
// which is exactly what the measurement said.
//
// Indexed by the voice instead. Each of the 28 slots keeps its own eight bytes,
// so a voice advancing through a sample finds seven of every eight reads
// already in hand no matter what the other twenty-seven are doing. 32 lines of
// 64 bits plus a 19-bit tag is about 2.7 Kbit -- MLAB, not M10K.

`timescale 1ns/1ps

module m2_pcm_fetch (
  input  logic        clk,
  input  logic        rst_n,

  // The chip's side. It holds c_req high and expects c_data valid in the SAME
  // cycle as c_ack -- `if (rom_req && rom_ack)` captures rom_data right there.
  input  logic        c_req,
  input  logic  [4:0] c_slot,
  input  logic [21:0] c_addr,
  output logic        c_ack,
  output logic  [7:0] c_data,

  // The memory's side: a four-word burst at an eight-byte-aligned address.
  output logic        m_req,
  output logic [21:3] m_addr,
  input  logic        m_ack,
  input  logic [63:0] m_data,

  // THE TWO NUMBERS THAT DECIDE WHAT TO FIX NEXT, measured rather than inferred.
  //
  // The sample rate on hardware settles at 86% of nominal, and simulation says
  // that corresponds to a fetch latency north of 300 cycles -- which would be
  // enormous for this controller and is worth not believing without evidence.
  // If the latency is really that high the answer is the arbiter; if it is low
  // and the misses are high the answer is prefetch. Guessing between those
  // costs a build each.
  //
  // Accumulated over exactly 1024 fetches so the mean is a shift, not a divide.
  output logic [15:0] dbg_mean_lat,     // clk cycles, miss only
  output logic [15:0] dbg_miss_1k       // misses per 1024 fetches
);

  logic [63:0] buf_q [32];
  logic [21:3] tag_q [32];
  logic [31:0] val_q;

  wire hit = val_q[c_slot] && (tag_q[c_slot] == c_addr[21:3]);

  typedef enum logic [1:0] { F_IDLE, F_FETCH, F_ARM, F_ACK } fst_t;
  fst_t st;

  logic [25:0] lat_acc;
  logic [15:0] lat_now;
  logic  [9:0] fetch_n;
  logic [15:0] miss_n;

  // Byte out of the held burst. c_addr is stable while c_req is high, which is
  // the chip's own protocol, so this needs no capture of its own.
  assign c_data = buf_q[c_slot][{3'd0, c_addr[2:0]} * 8 +: 8];
  assign m_addr = c_addr[21:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= F_IDLE; m_req <= 1'b0; c_ack <= 1'b0;
      lat_acc <= '0; lat_now <= '0; fetch_n <= '0; miss_n <= '0;
      dbg_mean_lat <= '0; dbg_miss_1k <= '0;
      // The tags are not cleared -- the valid bits are, which is the standing
      // rule about never clearing an array in reset.
      val_q <= 32'd0;
    end else begin
      c_ack <= 1'b0;
      case (st)
        F_IDLE: if (c_req) begin
          // Every fetch counted here, hit or miss, so the denominator is real.
          fetch_n <= fetch_n + 10'd1;
          if (fetch_n == 10'd1023) begin
            dbg_mean_lat <= lat_acc[25:10];   // /1024, as a shift
            dbg_miss_1k  <= miss_n;
            lat_acc <= '0;
            miss_n  <= '0;
          end
          // A HIT ANSWERS IN ONE CYCLE, NOT THREE. The line is already valid
          // and c_data is combinational off it, so there is nothing to wait
          // for -- routing a hit through F_ARM cost two extra cycles on the
          // common path. With twenty-odd voices fetching once per sample
          // period that is several per cent of the sample rate on its own,
          // which is the same order as the misses this cache exists to avoid.
          if (hit) begin
            c_ack <= 1'b1;
            st    <= F_ACK;
          end else begin
            m_req   <= 1'b1;
            lat_now <= 16'd0;
            miss_n  <= miss_n + 16'd1;
            st      <= F_FETCH;
          end
        end
        F_FETCH: begin
          // Timed from the request going out to the acknowledge coming back --
          // the whole round trip through the arbiter, which is the number that
          // matters and not the controller's own quoted latency.
          if (!(&lat_now)) lat_now <= lat_now + 16'd1;
          if (m_ack) begin
            lat_acc       <= lat_acc + {10'd0, lat_now};
            buf_q[c_slot] <= m_data;
            tag_q[c_slot] <= c_addr[21:3];
            val_q[c_slot] <= 1'b1;
            m_req         <= 1'b0;
            st            <= F_ARM;
          end
        end
        // One cycle so the acknowledge lands with buf_q already written -- the
        // chip reads c_data on the same edge it sees c_ack, and answering out
        // of m_data combinationally would put a memory's timing on that path.
        F_ARM: begin
          c_ack <= 1'b1;
          st    <= F_ACK;
        end
        // The chip drops c_req on the acknowledge. Waiting for that rather than
        // returning straight to F_IDLE stops one request being served twice.
        default: if (!c_req) st <= F_IDLE;
      endcase
    end
  end

endmodule
