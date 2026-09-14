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
  // Where this core's region starts, as a 64-bit word address. The framework's
  // own buffers live low; screen_rotate uses 0x24000000 upward for three 8 MB
  // framebuffers, so this sits clear of it.
  parameter logic [28:0] BASE = 29'h0800_0000
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the consumer side, shaped like m2_sdram's ports
  input  logic        req,
  input  logic        we,
  input  logic [24:0] addr,        // 64-bit words, relative to BASE
  input  logic [63:0] din,
  input  logic [7:0]  be,
  output logic        ack,         // one pulse: write accepted, or read data valid
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
  output logic [31:0] dbg_reads
);

  assign DDRAM_CLK      = clk;
  assign DDRAM_BURSTCNT = 8'd1;                 // one word a request, for now
  assign DDRAM_ADDR     = BASE + 29'(addr);
  assign DDRAM_DIN      = din;
  assign DDRAM_BE       = be;

  typedef enum logic [1:0] { D_IDLE, D_ISSUE, D_WAIT } st_t;
  st_t st;

  logic        is_wr;
  logic [15:0] lat;

  assign DDRAM_WE = (st == D_ISSUE) &&  is_wr;
  assign DDRAM_RD = (st == D_ISSUE) && !is_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= D_IDLE; is_wr <= 1'b0; ack <= 1'b0; dout <= '0;
      lat <= '0; dbg_lat_last <= '0; dbg_lat_max <= '0; dbg_reads <= '0;
    end else begin
      ack <= 1'b0;
      case (st)
        D_IDLE: if (req) begin
          is_wr <= we;
          lat   <= '0;
          st    <= D_ISSUE;
        end

        // HELD UNTIL TAKEN. BUSY means the bridge has not accepted this
        // request, and dropping it here is the whole class of bug this module
        // exists to avoid.
        D_ISSUE: begin
          lat <= lat + 16'd1;
          if (!DDRAM_BUSY) begin
            if (is_wr) begin
              ack <= 1'b1;            // a write is done when it is accepted
              st  <= D_IDLE;
            end else st <= D_WAIT;
          end
        end

        D_WAIT: begin
          lat <= lat + 16'd1;
          if (DDRAM_DOUT_READY) begin
            dout         <= DDRAM_DOUT;
            ack          <= 1'b1;
            dbg_lat_last <= lat;
            if (lat > dbg_lat_max) dbg_lat_max <= lat;
            if (!(&dbg_reads)) dbg_reads <= dbg_reads + 32'd1;
            st <= D_IDLE;
          end
        end

        default: st <= D_IDLE;
      endcase
    end
  end

endmodule
