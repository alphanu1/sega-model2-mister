// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A DIRECT-MAPPED LINE CACHE ON THE SCSP's SOUND RAM (study R856). The sound
// RAM is 512 KB in SDRAM with no fixed latency, so the SCSP's reads go through
// lines of four 16-bit words -- one SDRAM burst. Read-only to its user. Writes
// by others are SNOOPED (two sources: the 68000, and the DSP for its own
// cache) and invalidate a line they hit; a write landing while that line is
// being filled marks the fill stale, so its line is used once and not kept.
//
//   lookup  lk_req with lk_line; one clock later lk_hit / lk_data (the line's
//           four words, word 0 in [15:0])
//   fill    fill_req with fill_line, held until fill_done: one clock, the
//           memory's answer itself, with the line on fill_data
//   memory  m_req / m_line / m_ack / m_data: one burst, single outstanding
//   snoop   snp / snp2 with a line, pulses at least 3 clocks apart per source

`timescale 1ns/1ps

module m2_scsp_cache #(
  parameter int unsigned IDX = 8            // 2^IDX lines
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        lk_req,
  input  logic [15:0] lk_line,              // byte address [18:3]
  output logic        lk_hit,
  output logic [63:0] lk_data,
  input  logic        fill_req,
  input  logic [15:0] fill_line,
  output logic        fill_done,
  output logic [63:0] fill_data,
  output logic        m_req,
  output logic [15:0] m_line,
  input  logic        m_ack,
  input  logic [63:0] m_data,
  input  logic        snp,
  input  logic [15:0] snp_line,
  input  logic        snp2,
  input  logic [15:0] snp2_line,
  output logic [31:0] dbg_fills,
  output logic        sn2_busy             // R946: a snp2 not yet through (its invalidation not written)
);

  localparam int unsigned TW = 16 - IDX;    // tag bits

  (* ramstyle = "M10K" *) logic [63:0] dram [2**IDX];
  (* ramstyle = "M10K" *) logic [TW:0] tram [2**IDX];     // {valid, tag}

  // ---- port A: the lookup
  logic [TW:0]   ta_q;
  logic [63:0]   da_q;
  logic [TW-1:0] lk_tag_r;
  always_ff @(posedge clk) begin
    ta_q <= tram[lk_line[IDX-1:0]];
    da_q <= dram[lk_line[IDX-1:0]];
    if (lk_req) lk_tag_r <= lk_line[15:IDX];
  end
  assign lk_hit  = ta_q[TW] && ta_q[TW-1:0] == lk_tag_r;
  assign lk_data = da_q;

  // ---- port B: snoop tag reads; fills and invalidations write
  logic          sn_pend [2];
  logic [15:0]   sn_l [2];
  logic          sn_cmp;                   // comparing: the tag read last clock
  logic          sn_who;                   // which source is being compared
  logic [15:0]   cmp_l;
  logic [IDX-1:0] b_addr;
  logic          b_we;
  logic [TW:0]   b_d, tb_q;
  always_ff @(posedge clk) begin
    if (b_we) tram[b_addr] <= b_d;
    tb_q <= tram[b_addr];
  end

  logic        f_busy, f_stale;
  logic [15:0] f_line;
  wire         land = f_busy && m_ack;
  wire         hit_now = (snp && snp_line == f_line) || (snp2 && snp2_line == f_line);
  wire         pick = sn_pend[0] ? 1'b0 : 1'b1;            // the source to read next
  wire         want = sn_pend[0] || sn_pend[1];

  assign sn2_busy = sn_pend[1] || (sn_cmp && sn_who);
  always_ff @(posedge clk) if (land) dram[f_line[IDX-1:0]] <= m_data;
  assign fill_done = land;                 // the line, as it arrives
  assign fill_data = m_data;

  always_comb begin
    b_we = 1'b0; b_d = '0;
    b_addr = sn_l[pick][IDX-1:0];
    if (land) begin
      b_we = 1'b1; b_addr = f_line[IDX-1:0];
      b_d  = {!(f_stale || hit_now), f_line[15:IDX]};
    end else if (sn_cmp && tb_q[TW] && tb_q[TW-1:0] == cmp_l[15:IDX]) begin
      b_we = 1'b1; b_addr = cmp_l[IDX-1:0]; b_d = '0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sn_pend[0] <= 1'b0; sn_pend[1] <= 1'b0; sn_cmp <= 1'b0; sn_who <= 1'b0;
      f_busy <= 1'b0; f_stale <= 1'b0;
      m_req <= 1'b0; dbg_fills <= 32'd0;
    end else begin
      // a compare finishes this clock unless a fill landing took port B: then
      // the read it relied on was the fill's, and the snoop goes again
      sn_cmp <= 1'b0;
      if (sn_cmp && land) sn_pend[sn_who] <= 1'b1;
      // start a compare: the tag of the chosen source's line is read this clock
      if (want && !land && !sn_cmp) begin
        sn_cmp <= 1'b1; sn_who <= pick; cmp_l <= sn_l[pick];
        sn_pend[pick] <= 1'b0;
      end
      if (snp)  begin sn_pend[0] <= 1'b1; sn_l[0] <= snp_line; end
      if (snp2) begin sn_pend[1] <= 1'b1; sn_l[1] <= snp2_line; end
      // the fill
      if (!f_busy) begin
        if (fill_req) begin
          f_busy <= 1'b1; f_stale <= 1'b0; f_line <= fill_line;
          m_req <= 1'b1; m_line <= fill_line;
        end
      end else begin
        if (hit_now) f_stale <= 1'b1;
        if (m_ack) begin
          m_req <= 1'b0; f_busy <= 1'b0;
          if (!(&dbg_fills)) dbg_fills <= dbg_fills + 32'd1;
        end
      end
    end
  end

endmodule
