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
// TEXEL FETCH. One (u, v) in, one 4-bit texel out, from the texture sheets in
// SDRAM.
//
// Behavioural contract is model2rd.ipp's get_texel and the point-sampled half
// of fetch_bilinear_texel (BSD-3-Clause):
//
//     u0 = (u >> 8) & (tex_width - 1)          // 8 fractional bits of u
//     x2 = tex_x + u0;  y2 = tex_y + v0
//     if (x2 >= 1024) { x2 -= 1024; y2 ^= 1024; }
//     offset = ((y2 / 2) * 512) + (x2 / 2)     // in 16-bit words
//     texel  = word >> (y2 & 1 ? 0 : 8) >> (x2 & 1 ? 0 : 4)
//
// FOUR TEXELS TO A WORD, IN A 2x2 BLOCK, which is the whole reason a cache in
// front of this pays: a horizontal run of pixels reads the same word twice
// before moving on, and the scanline below reads the same words again.
//
// THE -2048 AND -1024 ARE A NO-OP AT LEVEL 0, and saying so here saves the next
// reader the arithmetic. `tex_x = ((texx - 2048) >> mip) & 2047` with mip = 0
// is `(texx - 2048) mod 2048` = `texx mod 2048`, and texx is 32 * a six-bit
// field, so at most 2016 -- already less than 2048. The subtraction only bites
// once mipmaps shift first. There are no mipmaps here yet.
//
// WRAP AND CLAMP ARE NOT IGNORED, THEY ARE THE MASK. `& (tex_width - 1)` IS
// the wrap; the texwrapx/texwrapy header bits only choose how a BILINEAR fetch
// treats the seam between the last texel and the first, and there is no
// bilinear fetch here. Mirroring is real at point sampling, so it is done.
//
// THE CACHE IS DIRECT-MAPPED WITH 64-BIT LINES, which is one SDRAM transaction
// and eight texels across by two down. It is small on purpose: the access
// pattern is a walk along a scanline, so the working set at any moment is a few
// lines of one texture, and a big cache would buy nothing that a small one does
// not already hold.

`timescale 1ns/1ps

module m2_texel #(
  parameter int unsigned AW       = 25,
  // R310: BACK TO 512 LINES / 4 KB, and the reason is R309 rather than area.
  // The cache was grown (R304) and regrown (R307) as though the texture problem
  // were hit RATE. It is not: one miss BLOCKS every span behind it, so rate
  // changes only how often the stall happens. The span FIFO absorbs the stall
  // instead, and the 30 M10K this releases pay for it with 23 to spare.
  //
  // R307: 4096 WAS TRIED FIRST AND DID NOT FIT -- "device has 553 M10K blocks,
  // design needs more than 553". IHRES/OHRES frees BLOCKS, not bits: a shallow
  // buffer still occupies a whole M10K, so the depth reduction did not release
  // as many as its bit count suggested. 2048 is half the growth and the largest
  // that fits beside everything else.
  //
  // R293 set 512 and reasoned that "a big cache would buy nothing that a small
  // one does not already hold". The board disagrees: 24,553 texel fetches a
  // frame at a 40.6% hit rate is roughly 14,600 misses, each a full SDRAM round
  // trip that stalls the span walk MID-SPAN. It is the worst hit rate of any
  // cache in this design -- the glyph cache runs at 89-90% -- and the one that
  // stalls the unit that cannot finish its bands.
  //
  // The blocks come from R304's IHRES 512 / OHRES 2048, which frees about 35
  // M10K of the 553 that were all in use; this takes about 22 of them.
  // Doubling the GLYPH cache instead was considered and rejected: it costs ~51
  // blocks, which do not exist, and Ben measured that 128 KB still overran.
  parameter int unsigned IDX_BITS = 9
) (
  input  logic             clk,
  input  logic             rst_n,

  // Where the two sheets live, as word addresses.
  input  logic [AW:1]      base_s0,
  input  logic [AW:1]      base_s1,

  // One texel, please. `tex` is m2_geo_engine's packed texture state (R271);
  // u and v carry eight fractional bits, as the reference's do.
  input  logic             req,
  output logic             ack,
  // Bits 0, 7:8, 11 and 31:24 -- textured, wrap, checker and the luma base --
  // belong to stages above this one; they are carried in the same word because
  // every stage passes it whole.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]      tex,
  /* verilator lint_on UNUSEDSIGNAL */
  // The eight fractional bits are the BILINEAR blend's, and there is no
  // bilinear fetch here -- they are taken so the interface does not change when
  // there is.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [19:0]      u,
  input  logic [19:0]      v,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [3:0]       texel,

  // Memory, one 64-bit line a transaction.
  output logic             m_req,
  output logic [AW:1]      m_addr,
  input  logic             m_ack,
  input  logic [63:0]      m_data,

  // THE SHEETS ARE WRITABLE: the game uploads textures by CPU stores (R264),
  // so a line filled before an upload is stale exactly the way the glyph
  // cache's were, and that was a blank screen for a week.
  input  logic             inval,

  output logic [31:0]      dbg_hits,
  output logic [31:0]      dbg_misses,
  // Fetches abandoned on a memory that never answered. It should read zero;
  // if it does not, the port is the fault and not the picture.
  output logic [15:0]      dbg_lost,
  // R310: HOW OFTEN THE CACHE IS CLEARED, which nothing has ever measured.
  // The sweep walks one line per cycle on any CPU write to a texture sheet, so
  // a per-frame upload starts the cache COLD every frame -- and a cold cache
  // and a thrashing cache produce the SAME hit-rate counter. Without this the
  // cache-size question cannot be answered in either direction, which is why
  // it was answered wrongly twice (R304, R307).
  output logic [15:0]      dbg_sweeps
);

  localparam int unsigned LINES    = 1 << IDX_BITS;
  // The word address is 19 bits inside a sheet; the sheet select joins the tag
  // so the two cannot alias.
  localparam int unsigned WA_BITS  = 19;
  localparam int unsigned TAG_BITS = WA_BITS - IDX_BITS - 2 + 1;   // + sheet

  // ---------------------------------------------------------- the addressing
  wire [2:0]  wcode = tex[3:1];
  wire [2:0]  hcode = tex[6:4];
  wire        mirx  = tex[9];
  wire        miry  = tex[10];
  wire        sheet = tex[12];
  wire [5:0]  texx  = tex[18:13];
  wire [4:0]  texy  = tex[23:19];

  // 32 << code, as a mask of the same shape: (32 << c) - 1.
  wire [11:0] wmask = 12'((32 << wcode) - 1);
  wire [11:0] hmask = 12'((32 << hcode) - 1);

  // Mirroring tests the coordinate against the texture's width in the SAME
  // fixed point it arrives in, which is why this is a shift and not a compare.
  wire [11:0] uint  = u[19:8];
  wire [11:0] vint  = v[19:8];
  wire        mir_u = mirx && ((uint & 12'(32 << wcode)) != 12'd0);
  wire        mir_v = miry && ((vint & 12'(32 << hcode)) != 12'd0);
  // The fraction is dropped here; the mirror inverts the whole coordinate the
  // way the reference does, and only the integer part survives the mask.
  wire [11:0] ua    = mir_u ? ~uint : uint;
  wire [11:0] va    = mir_v ? ~vint : vint;

  wire [11:0] u0    = ua & wmask;
  wire [11:0] v0    = va & hmask;

  wire [11:0] x2_0  = {1'b0, texx, 5'd0} + u0;
  wire [11:0] y2_0  = {2'd0, texy, 5'd0} + v0;
  wire        fold  = x2_0 >= 12'd1024;
  wire [11:0] x2    = fold ? (x2_0 - 12'd1024) : x2_0;
  wire [11:0] y2    = fold ? (y2_0 ^ 12'd1024) : y2_0;

  // AN ADD, NOT A CONCATENATION, and this cost an hour. The reference's
  // `offset = ((y2 / 2) * 512) + (x2 / 2)` CARRIES: one fold of the 1024
  // column leaves x2 anywhere up to 3039, so x2/2 can exceed 511 and spill
  // into the row above -- which is what the sheet's layout means, and dropping
  // the carry paints a band of the wrong rows across every wide texture.
  wire [WA_BITS-1:0] waddr = WA_BITS'({y2[10:1], 9'd0} + {8'd0, x2[11:1]});

  wire [IDX_BITS-1:0] req_idx = waddr[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] req_tag = {sheet, waddr[WA_BITS-1:IDX_BITS+2]};
  wire [1:0]          req_sel = waddr[1:0];          // which word of the line

  // ---------------------------------------------------------------- storage
  (* ramstyle = "M10K" *) logic [63:0]       cdata [LINES];
  (* ramstyle = "M10K" *) logic [TAG_BITS:0] ctag  [LINES];   // {valid, tag}

  logic [63:0]       cd_q;
  logic [TAG_BITS:0] ct_q;
  logic              cd_we, ct_we;
  logic [IDX_BITS-1:0] mem_addr;
  logic [63:0]         cd_din;
  logic [TAG_BITS:0]   ct_din;

  always_ff @(posedge clk) begin
    cd_q <= cdata[mem_addr];
    ct_q <= ctag [mem_addr];
    if (cd_we) cdata[mem_addr] <= cd_din;
    if (ct_we) ctag [mem_addr] <= ct_din;
  end

  // THE LINE JUST FETCHED, ANSWERED IN ONE CYCLE (R293).
  //
  // A 64-bit line is eight texels across, and the span walk steps u by about
  // half a texel a pixel -- so consecutive requests land in the SAME LINE far
  // more often than not. Going round the arrays for them costs three cycles
  // each and 27,000 fetches a frame, which is most of why the band fill does
  // not finish: measured on the board, 14 to 27 bands of 48.
  //
  // So the last line is held with its index and tag, and a request that
  // matches is answered from the register with no array read and no state
  // change. It is not a second cache -- it is the one line the walk is
  // already inside.
  logic                last_v;
  logic [IDX_BITS-1:0] last_idx;
  logic [TAG_BITS-1:0] last_tag;

  typedef enum logic [2:0] { S_INIT, S_IDLE, S_LOOK, S_MISS, S_FILL, S_ACK } st_t;
  st_t st;

  logic [IDX_BITS-1:0] sweep, idx_r;
  logic [TAG_BITS-1:0] tag_r;
  logic [1:0]          sel_r;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [WA_BITS-1:0]  wa_r;             // [1:0] selects the word, not the line
  /* verilator lint_on UNUSEDSIGNAL */
  logic                sheet_r;
  logic [63:0]         hold;
  // A MEMORY THAT NEVER ANSWERS MUST NOT STOP THE PICTURE. This unit sits
  // inside the band fill, so a request that is never acknowledged holds the
  // span walk, which holds the band, which holds every band after it -- the
  // R162 failure mode, one missed pulse costing the rest of the session. On
  // expiry the line is taken as whatever is in hand and the fetch is counted.
  logic [9:0]          to_cnt;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [11:0]         x2_r, y2_r;       // only the parity survives the latch
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    mem_addr = req_idx;
    cd_we    = 1'b0;
    ct_we    = 1'b0;
    cd_din   = m_data;
    ct_din   = {1'b1, tag_r};
    case (st)
      S_INIT: begin mem_addr = sweep; ct_we = 1'b1; ct_din = '0; end
      S_LOOK: mem_addr = idx_r;
      S_FILL: begin mem_addr = idx_r; cd_we = 1'b1; ct_we = 1'b1; end
      default: ;
    endcase
  end

  wire hit = ct_q[TAG_BITS] && (ct_q[TAG_BITS-1:0] == tag_r);

  // A whole-cache sweep on an upload, NOT a line: the CPU writes texels by the
  // thousand and there is no cheap way to know which line each lands on -- the
  // address it writes is a sheet word, and this cache is indexed by one, but
  // the write port that would carry it does not exist yet. A sweep costs 128
  // cycles and uploads are bursts, so it settles. The glyph cache's lesson
  // (R266) applies to the RE-ENTRY, not to the sweep: this one cannot restart
  // forever, because the sweep is entered once per upload burst, not per write.
  logic inval_d, inval_pend;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_INIT; sweep <= '0; idx_r <= '0; tag_r <= '0; sel_r <= '0;
      wa_r <= '0; sheet_r <= 1'b0; hold <= '0; x2_r <= '0; y2_r <= '0;
      m_req <= 1'b0; m_addr <= '0; ack <= 1'b0; to_cnt <= '0; dbg_lost <= '0;
      last_v <= 1'b0; last_idx <= '0; last_tag <= '0;
      inval_d <= 1'b0; inval_pend <= 1'b0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_sweeps <= '0;
    end else begin
      ack     <= 1'b0;
      inval_d <= inval;
      if (inval && !inval_d) inval_pend <= 1'b1;

      case (st)
        S_INIT: begin
          sweep <= sweep + 1'd1;
          if (sweep == IDX_BITS'(LINES - 1)) begin
            st <= S_IDLE;
            inval_pend <= 1'b0;
          end
        end

        S_IDLE: if (inval_pend) begin
          if (!(&dbg_sweeps)) dbg_sweeps <= dbg_sweeps + 1'd1;
          sweep  <= '0;
          last_v <= 1'b0;                 // the sweep drops the held line too
          st     <= S_INIT;
        end else if (req && last_v && (req_idx == last_idx) && (req_tag == last_tag)) begin
          // Already in hand: answer now, and count it as the hit it is.
          sel_r    <= req_sel;
          x2_r     <= x2;
          y2_r     <= y2;
          ack      <= 1'b1;
          dbg_hits <= dbg_hits + 1'd1;
          st       <= S_ACK;
        end else if (req) begin
          idx_r   <= req_idx;
          tag_r   <= req_tag;
          sel_r   <= req_sel;
          wa_r    <= waddr;
          sheet_r <= sheet;
          x2_r    <= x2;
          y2_r    <= y2;
          st      <= S_LOOK;
        end

        S_LOOK: if (hit) begin
          hold     <= cd_q;
          last_v   <= 1'b1;
          last_idx <= idx_r;
          last_tag <= tag_r;
          ack      <= 1'b1;
          dbg_hits <= dbg_hits + 1'd1;
          st       <= S_ACK;
        end else begin
          m_req      <= 1'b1;
          to_cnt     <= '0;
          m_addr     <= (sheet_r ? base_s1 : base_s0)
                      + AW'({wa_r[WA_BITS-1:2], 2'b00});
          dbg_misses <= dbg_misses + 1'd1;
          st         <= S_MISS;
        end

        S_MISS: begin
          to_cnt <= to_cnt + 1'd1;
          if (m_ack) begin
            m_req  <= 1'b0;
            hold   <= m_data;
            to_cnt <= '0;
            st     <= S_FILL;
          end else if (&to_cnt) begin
            m_req  <= 1'b0;
            to_cnt <= '0;
            if (!(&dbg_lost)) dbg_lost <= dbg_lost + 1'd1;
            ack    <= 1'b1;             // answer with what is in hand, never hang
            st     <= S_ACK;
          end
        end

        S_FILL: begin
          ack      <= 1'b1;
          last_v   <= 1'b1;
          last_idx <= idx_r;
          last_tag <= tag_r;
          st       <= S_ACK;
        end

        S_ACK: if (!req) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

  // The word out of the line, then the nibble out of the word. The parities are
  // the FETCHED coordinates', held with the request -- the reference takes them
  // from u0/v0, and those have the same parity as x2/y2 because the texture's
  // origin is a multiple of 32.
  logic [15:0] word;
  always_comb begin
    case (sel_r)
      2'd0: word = hold[15:0];
      2'd1: word = hold[31:16];
      2'd2: word = hold[47:32];
      default: word = hold[63:48];
    endcase
  end

  assign texel = y2_r[0] ? (x2_r[0] ? word[3:0]   : word[7:4])
                         : (x2_r[0] ? word[11:8]  : word[15:12]);

endmodule
