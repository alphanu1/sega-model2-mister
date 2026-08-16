// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// ---------------------------------------------------------------------------
//
// i960KB instruction cache — 512 bytes, direct-mapped, 16-byte lines.
//
// UNLIKE EVERY OTHER BLOCK IN P1, THIS ONE HAS NO ORACLE AND NEEDS NONE.
// MAME does not model an instruction cache at all: its `m_cache` is an address
// space accessor, and the IAC that would invalidate the real cache — 0x89,
// "invalidate internal instruction cache" — is logged rather than executed.
//
// So this is architecturally invisible. It changes cycle counts and nothing
// else, and it cannot diverge from the reference because the reference has
// nothing to diverge from. Two consequences worth stating:
//
//  - It is verified by TRANSPARENCY, not by lockstep. The only requirement is
//    that a fetch returns the same word external memory would have returned.
//    The harness checks exactly that, and checks it on every fetch rather than
//    only on misses.
//  - The assumption underneath is that instruction memory does not change
//    under the cache. Model 2 executes from ROM (0x00000000-0x001fffff and
//    0x02000000-0x03ffffff), so there is no self-modifying code and no DMA into
//    the instruction stream. **If that ever stops being true, this block
//    becomes wrong and silently so** — hence `inval` exists even though nothing
//    drives it yet.
//
// Geometry: 512 B / 16 B = 32 lines. addr[3:2] selects the word within a line,
// addr[8:4] the line, addr[31:9] is the tag.
//
// M10K rather than MLAB for the data, which is the opposite of the register
// cache's decision and for the opposite reason: 4,096 bits is a third of one
// M10K but would take about seven MLABs, and §5.6's pressure is on M10K blocks
// rather than on bits. One block for the whole instruction cache is a good
// trade; seven MLABs of LUT is not. The tag array stays in flip-flops because
// it is read and compared combinationally on every fetch.

module i960_icache #(
  parameter int unsigned LINES = 32           // 32 x 16 B = 512 B
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        inval,                  // invalidate everything

  // ------- fetch side
  input  logic        req,
  // [31:2], not [31:0]: instructions are dword-aligned so the low two bits are
  // always zero. Declaring the full width leaves them unread, which is the
  // pattern the lint is kept un-suppressed to catch.
  input  logic [31:2] addr,
  output logic [31:0] data,
  output logic        valid,                  // `data` is good this cycle
  output logic        busy,

  // ------- refill side. One 4-word line burst per miss.
  output logic        bus_req,
  output logic [31:0] bus_addr,   // combinational — see the fill state
  input  logic [31:0] bus_rdata,
  input  logic        bus_ack
);

  localparam int unsigned IDX_W = $clog2(LINES);
  localparam int unsigned TAG_W = 32 - IDX_W - 4;

  // Data store: LINES x 4 words. Never cleared in reset — clearing an array in
  // reset forces it out of RAM into flip-flops, measured on this toolchain.
  // Validity lives in the tag array, which is where a reset can be afforded.
  (* ramstyle = "M10K" *) logic [31:0] cdata [0:LINES*4-1];

  logic [TAG_W-1:0] ctag  [0:LINES-1];
  logic             cvalid[0:LINES-1];

  logic [IDX_W-1:0] idx;
  logic [1:0]       word;
  logic [TAG_W-1:0] tag;

  assign idx  = addr[IDX_W+3:4];
  assign word = addr[3:2];
  assign tag  = addr[31:IDX_W+4];

  logic hit;
  assign hit = cvalid[idx] && (ctag[idx] == tag);

  typedef enum logic [1:0] { S_IDLE, S_FILL, S_DONE } state_e;
  state_e state;

  logic [1:0]       fill_word;
  logic [IDX_W-1:0] fill_idx;
  logic [TAG_W-1:0] fill_tag;
  logic [31:0]      fill_base;

  assign busy = (state != S_IDLE);

  // Registered read of the data array. A hit costs one cycle, which is what a
  // pipelined fetch stage wants anyway.
  logic [31:0] cdata_q;
  logic        rd_we;
  logic [IDX_W+1:0] rd_waddr, rd_raddr;
  logic [31:0] rd_wdata;

  always_ff @(posedge clk) begin
    if (rd_we) cdata[rd_waddr] <= rd_wdata;
    cdata_q <= cdata[rd_raddr];
  end

  assign rd_raddr = {idx, word};

  // Combinational so the address tracks fill_word within the same cycle the
  // data for it is acked.
  assign bus_addr = fill_base + {28'd0, fill_word, 2'b00};
  assign rd_waddr = {fill_idx, fill_word};
  assign rd_wdata = bus_rdata;
  assign rd_we    = (state == S_FILL) && bus_ack;

  assign data = cdata_q;

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      bus_req   <= 1'b0;
      valid     <= 1'b0;
      fill_word <= 2'd0;
      fill_idx  <= '0;
      fill_tag  <= '0;
      fill_base <= 32'd0;
      for (i = 0; i < LINES; i = i + 1) cvalid[i] <= 1'b0;
    end else begin
      valid <= 1'b0;

      if (inval) begin
        for (i = 0; i < LINES; i = i + 1) cvalid[i] <= 1'b0;
      end

      case (state)
        S_IDLE: begin
          if (req) begin
            if (hit) begin
              // cdata_q is registered from rd_raddr this cycle, so it is good
              // next cycle — which is when `valid` asserts.
              valid <= 1'b1;
            end else begin
              fill_idx  <= idx;
              fill_tag  <= tag;
              fill_word <= 2'd0;
              fill_base <= {addr[31:4], 4'd0};
              state     <= S_FILL;
            end
          end
        end

        S_FILL: begin
          // Request is HELD across the whole line and the address is
          // combinational, so a memory that acks every cycle delivers one word
          // per cycle. The previous version registered both and dropped the
          // request after each word, which measured ~3.7 cycles per word and
          // made instruction fetch 58% of all cycles in the CPU.
          bus_req <= 1'b1;
          if (bus_ack) begin
            if (fill_word == 2'd3) begin
              bus_req          <= 1'b0;
              ctag[fill_idx]   <= fill_tag;
              cvalid[fill_idx] <= 1'b1;
              state            <= S_DONE;
            end else begin
              fill_word <= fill_word + 2'd1;
            end
          end
        end

        S_DONE: begin
          // One cycle for the registered read of the just-filled line.
          valid <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
