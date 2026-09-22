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
  // R322: 1024 LINES / 8 KB, up from 512 / 4 KB. Deliberately ONE doubling and
  // not four: this is a MEASUREMENT as much as a change. Every hit-rate figure
  // on record is at 512 lines, so "a bigger cache would help" is a guess -- the
  // board has read 27.9%, 40.6%, 42.4%, 43.3% and 48.4%, all at the same size.
  // One doubling says whether the curve moves at all, for ~15 M10K of the 30
  // free, and leaves headroom rather than spending it on an estimate.
  //
  // The R310 sweep counter is what makes this worth trying: 205 sweeps across a
  // whole capture, about one per 57 frames, so the cache is NOT being cleared
  // out from under itself. The miss rate is genuine thrashing, which size can
  // address.
  // THIS DEFAULT IS NOT WHAT THE CORE BUILDS. m2_raster3d overrides it (R328,
  // 2048 lines). Changing the number here moves only the benches.
  parameter int unsigned IDX_BITS = 10
) (
  input  logic             clk,
  input  logic             rst_n,

  // Where the two sheets live, as word addresses.
  input  logic [AW:1]      base_s0,
  input  logic [AW:1]      base_s1,

  // One texel, please. `tex` is m2_geo_engine's packed texture state (R271);
  // u and v carry eight fractional bits, as the reference's do.
  // R474: STREAMING. A request is accepted on any cycle where req and rdy are
  // both high, and its answer comes back later on `ack` with `texel` beside it,
  // in order. The requester must DEASSERT on acceptance: a held level would be
  // read as a second request, which is what R473 measured (1,920 hits became
  // 3,839 for the same fetches, every value still correct).
  input  logic             req,
  output logic             rdy,
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

  // Memory, one 64-bit line a transaction. R480: TWO PORTS, because
  // m2_sdram allows one transaction per port at a time (arb_ready = pend &
  // ~inflight), so a single port serialises every miss -- 15,703 a frame at
  // ~160 ns of SDRAM each is 2.5 ms of a 16.7 ms frame that nothing in this
  // module could overlap. Two ports halve it.
  //
  // Both must burst FOUR. R108 records what happens otherwise: rd_total is a
  // single global register, so a port with a different burst length corrupts
  // whichever transaction is issuing beside it, silently. Port 2 bursts four
  // like every other.
  output logic             m_req,
  output logic [AW:1]      m_addr,
  input  logic             m_ack,
  input  logic [63:0]      m_data,
  // R482: the second port is only usable once the boot users of SDRAM port 2
  // -- the copy engine, the calibration read and the read-back sweep -- are
  // finished with it. Before that the cache runs on one port, exactly as it
  // did, rather than allocating a slot whose fill can never be acknowledged.
  input  logic             m2_en,
  output logic             m2_req,
  output logic [AW:1]      m2_addr,
  input  logic             m2_ack,
  input  logic [63:0]      m2_data,

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
  // R413: A 2-BIT DECREMENT, NOT A 12-BIT SUBTRACT. 1024 is 2^10, so
  // x2_0 - 1024 cannot affect bits [9:0] -- it is bits [11:10] minus one, and
  // `fold` means x2_0 >= 1024 so those two bits are never zero and cannot
  // underflow. Identical value, no 12-bit borrow chain.
  //
  // It sat between two adders on the worst path in the design:
  //   m2_span_tex|tex_r[6] -> Add3 -> Add5 -> m2_texel|idx_r[1]   -0.660 ns
  wire [11:0] x2    = fold ? {x2_0[11:10] - 2'd1, x2_0[9:0]} : x2_0;
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

  typedef enum logic [2:0] { S_INIT, S_IDLE, S_LOOK, S_FILL } st_t;   // R480
  st_t st;

  logic [IDX_BITS-1:0] sweep, idx_r;
  logic [TAG_BITS-1:0] tag_r;
  logic [1:0]          sel_r;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [WA_BITS-1:0]  wa_r;             // [1:0] selects the word, not the line
  /* verilator lint_on UNUSEDSIGNAL */
  logic                sheet_r;
  // A MEMORY THAT NEVER ANSWERS MUST NOT STOP THE PICTURE. This unit sits
  // inside the band fill, so a request that is never acknowledged holds the
  // span walk, which holds the band, which holds every band after it -- the
  // R162 failure mode, one missed pulse costing the rest of the session. On
  // expiry the line is taken as whatever is in hand and the fetch is counted.
  // R480: to_cnt is per-slot now (ms_to), the single counter went with S_MISS.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [11:0]         x2_r, y2_r;       // only the parity survives the latch
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    mem_addr = req_idx;
    cd_we    = 1'b0;
    ct_we    = 1'b0;
    cd_din   = ms_dat[ms_fill_sel];   // R480
    ct_din   = {1'b1, ms_tag[ms_fill_sel]};   // R480
    case (st)
      S_INIT: begin mem_addr = sweep; ct_we = 1'b1; ct_din = '0; end
      // R474: S_LOOK leaves mem_addr at the default req_idx, so the NEXT
      // lookup's tag read is issued while this one is compared. The compare
      // uses ct_q, read a cycle ago, so driving this line's own index here
      // was a no-op that stopped the pipeline.
      S_FILL: begin mem_addr = ms_idx[ms_fill_sel]; cd_we = 1'b1; ct_we = 1'b1; end   // R480
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

  // R315: THE HIT/MISS COUNTERS ARE A CYCLE BEHIND THE DECISION.
  //
  // Measured: this module's worst path is 10.66 ns -- a 93.8 MHz ceiling -- and
  // it runs from the tag RAM's output through the hit compare into
  // `dbg_misses[1]`. INSTRUMENTATION was on the critical path: a 32-bit
  // increment gated by a comparison of a value that had just come out of block
  // memory. These pulses move the counting one cycle later, where nothing is
  // waiting for it, and cost two flip-flops.
  //
  // That is what stands between this module and 100 MHz, which matters because
  // the span queue (R310) decoupled the texel fetch from the fill -- so this
  // unit can now be clocked on clk_mem independently of clk_sys, across a clean
  // 2:1 with a narrow interface, without touching the renderer.

  // R480: TWO MISS-STATUS REGISTERS, ONE PER SDRAM PORT.
  //
  // m2_sdram allows one transaction per port at a time, so a single port
  // serialises every miss: 15,703 a frame at ~160 ns of SDRAM is 2.5 ms of a
  // 16.7 ms frame, and on the board that is what takes the band -- "one miss
  // BLOCKS every span behind it". Two ports let two fills be in flight.
  //
  // RESPONSES STAY IN ORDER. The span walk emits in x order, so a hit found
  // behind a miss must still answer after it. The FIFO below is what enforces
  // that: every accepted request takes a slot in it, hits carry their data
  // straight in, misses carry the MSHR they are waiting on, and the head is
  // what answers.
  logic                ms_busy [2];
  logic                ms_done [2];
  logic [IDX_BITS-1:0] ms_idx  [2];
  logic [TAG_BITS-1:0] ms_tag  [2];
  logic [63:0]         ms_dat  [2];
  // R480: ONE TIMEOUT PER SLOT. The single S_MISS counter went with the state,
  // and this module's own note says why it cannot: "a request that is never
  // acknowledged holds the span walk, which holds the band, which holds every
  // band after it." Each fill answers with whatever is in hand rather than
  // hanging, exactly as the old one did.
  logic [9:0]          ms_to   [2];
  wire                 ms_have_free = !ms_busy[0] || (m2_en && !ms_busy[1]);
  wire                 ms_pick      = !ms_busy[0] ? 1'b0 : 1'b1;
  // A fill needs the array write port, which the lookup read is using. One
  // stolen cycle per fill; rdy drops for it.
  wire                 ms_fill_rdy  = (ms_busy[0] && ms_done[0]) || (ms_busy[1] && ms_done[1]);
  wire                 ms_fill_sel  = (ms_busy[0] && ms_done[0]) ? 1'b0 : 1'b1;

  // R483: THE QUEUE HOLDS THE NIBBLE, NOT THE LINE.
  //
  // Each entry carried the whole 64-bit line and the selectors to pick from it
  // later -- 256 registers of cache line held so that four bits could be read
  // out of it, plus `hold` downstream. Extracting at push (for a hit) or at
  // fill (for a miss) keeps 4 bits instead of 64. The selectors stay because a
  // miss still needs them when its line arrives.
  //
  // R482 put ~294 ALM back on and took the design over 99%, where every build
  // this week has failed to boot while both 98% builds came up first try.
  function automatic logic [3:0] nib(input logic [63:0] line,
                                     input logic [1:0]  sel,
                                     input logic        px, input logic py);
    logic [15:0] w;
    begin
      case (sel)
        2'd0: w = line[15:0];
        2'd1: w = line[31:16];
        2'd2: w = line[47:32];
        default: w = line[63:48];
      endcase
      nib = py ? (px ? w[3:0]  : w[7:4])
               : (px ? w[11:8] : w[15:12]);
    end
  endfunction

  localparam int unsigned RSP_D = 4;
  logic                rs_rdy [RSP_D];   // data already in hand
  logic [3:0]          rs_tex [RSP_D];   // R483: the nibble, not the line
  logic [1:0]          rs_sel [RSP_D];
  logic                rs_x2  [RSP_D], rs_y2 [RSP_D];
  logic                rs_ism [RSP_D];   // waiting on an MSHR
  logic                rs_slt [RSP_D];
  logic [$clog2(RSP_D):0] rs_wp, rs_rp;
  wire rs_empty = (rs_wp == rs_rp);
  wire rs_full  = ((rs_wp - rs_rp) == ($clog2(RSP_D)+1)'(RSP_D));
  wire [$clog2(RSP_D)-1:0] rs_hd = rs_rp[$clog2(RSP_D)-1:0];
  wire [$clog2(RSP_D)-1:0] rs_tl = rs_wp[$clog2(RSP_D)-1:0];

  logic h_pulse, m_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_INIT; sweep <= '0; idx_r <= '0; tag_r <= '0; sel_r <= '0;
      wa_r <= '0; sheet_r <= 1'b0; x2_r <= '0; y2_r <= '0;
      m_req <= 1'b0; m_addr <= '0; ack <= 1'b0; dbg_lost <= '0;
      m2_req <= 1'b0; m2_addr <= '0;
      rs_wp <= '0; rs_rp <= '0;
      for (int k = 0; k < 2; k++) begin
        ms_busy[k] <= 1'b0; ms_done[k] <= 1'b0;
        ms_idx[k] <= '0; ms_tag[k] <= '0; ms_dat[k] <= '0; ms_to[k] <= '0;
      end
      for (int k = 0; k < RSP_D; k++) begin
        rs_rdy[k] <= 1'b0; rs_tex[k] <= 4'd0; rs_sel[k] <= 2'd0;
        rs_x2[k] <= 1'b0; rs_y2[k] <= 1'b0; rs_ism[k] <= 1'b0; rs_slt[k] <= 1'b0;
      end
      inval_d <= 1'b0; inval_pend <= 1'b0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_sweeps <= '0;
      h_pulse <= 1'b0; m_pulse <= 1'b0;
    end else begin
      ack     <= 1'b0;
      h_pulse <= 1'b0;
      m_pulse <= 1'b0;
      if (h_pulse) dbg_hits   <= dbg_hits   + 1'd1;
      if (m_pulse) dbg_misses <= dbg_misses + 1'd1;
      inval_d <= inval;
      if (inval && !inval_d) inval_pend <= 1'b1;

      // ---- R480: per-slot timeouts.
      for (int k = 0; k < 2; k++) begin
        if (ms_busy[k] && !ms_done[k]) begin
          ms_to[k] <= ms_to[k] + 1'd1;
          if (&ms_to[k]) begin
            ms_done[k] <= 1'b1;
            if (!(&dbg_lost)) dbg_lost <= dbg_lost + 1'd1;
            if (k == 0) m_req <= 1'b0; else m2_req <= 1'b0;
            for (int j = 0; j < RSP_D; j++)
              if (rs_ism[j] && (rs_slt[j] == 1'(k))) begin
                rs_rdy[j] <= 1'b1;  rs_ism[j] <= 1'b0;   // answer with what is in hand
              end
          end
        end
      end

      // ---- R480: the two ports complete independently and out of order. The
      // returned line goes to the FIFO entry that is waiting on that slot, so
      // the ORDER the walk sees is the order it asked in, whichever port
      // answered first.
      if (m_ack && ms_busy[0] && !ms_done[0]) begin
        ms_dat[0] <= m_data;  ms_done[0] <= 1'b1;  m_req <= 1'b0;
        for (int k = 0; k < RSP_D; k++)
          if (rs_ism[k] && !rs_slt[k]) begin
            rs_tex[k] <= nib(m_data,  rs_sel[k], rs_x2[k], rs_y2[k]);
            rs_rdy[k] <= 1'b1;  rs_ism[k] <= 1'b0;
          end
      end
      if (m2_ack && ms_busy[1] && !ms_done[1]) begin
        ms_dat[1] <= m2_data; ms_done[1] <= 1'b1;  m2_req <= 1'b0;
        for (int k = 0; k < RSP_D; k++)
          if (rs_ism[k] && rs_slt[k]) begin
            rs_tex[k] <= nib(m2_data, rs_sel[k], rs_x2[k], rs_y2[k]);
            rs_rdy[k] <= 1'b1;  rs_ism[k] <= 1'b0;
          end
      end

      // ---- the response head. In order, always.
      if (!rs_empty && rs_rdy[rs_hd]) begin
        ack    <= 1'b1;
        texel  <= rs_tex[rs_hd];   // R483: already the nibble
        rs_rp  <= rs_rp + 1'd1;
        // R481: RETIRE THE ENTRY. Leaving rdy and ism set means a later m_ack
        // for the same slot re-marks an entry that has already been answered,
        // and the head then pops it again -- the read pointer walks past the
        // write pointer and free-runs until it wraps. 70 requests produced 200
        // responses.
        rs_rdy[rs_hd] <= 1'b0;
        rs_ism[rs_hd] <= 1'b0;
      end

      case (st)
        S_INIT: begin
          sweep <= sweep + 1'd1;
          if (sweep == IDX_BITS'(LINES - 1)) begin
            st <= S_IDLE;
            inval_pend <= 1'b0;
          end
        end

        // R419: THE SAME-LINE FAST PATH IS GONE, AND IT WAS THE WORST PATH.
        // It compared the FRESHLY COMPUTED req_idx and req_tag against the last
        // line and decided the next state in the same cycle, so tex_r reached
        // st through two adders and two comparators:
        //   m2_span_tex|tex_r[3] -> Add0 -> Add2 -> m2_texel|st.S_ACK  -0.735
        //
        // It only ever saved a cycle. S_IDLE already reads the tag RAM at
        // req_idx, S_LOOK already checks the real tag, and S_LOOK already
        // loads `hold` from cd_q -- so every request now takes the same two
        // cycles a non-repeated one always took, and answers identically.
        //
        // The cost is one cycle per repeated texel. Texels wait 9.6% of the
        // frame, so that is a few percent of a small number, against clk_mem
        // which gates the 2:1 ratio the whole clock plan rests on.
        S_IDLE: if (ms_fill_rdy) begin
          st <= S_FILL;                  // R480: steal a cycle for the array write
        end else if (inval_pend) begin
          if (!(&dbg_sweeps)) dbg_sweeps <= dbg_sweeps + 1'd1;
          sweep  <= '0;
          // R480: THE QUEUE IS FLUSHED WITH THE CACHE. Every line is about to
          // be invalidated, so an entry still holding one is stale -- it would
          // answer a later request with a line the sweep was clearing. The old
          // design had no queue and so nothing to flush. Safe here because the
          // sweep runs at frame_start with the walk idle.
          rs_wp  <= '0;  rs_rp <= '0;
          for (int k = 0; k < RSP_D; k++) begin rs_rdy[k] <= 1'b0; rs_ism[k] <= 1'b0; end
          for (int k = 0; k < 2; k++)  begin ms_busy[k] <= 1'b0;  ms_done[k] <= 1'b0; end
          st     <= S_INIT;
        // R481: `req && rdy`, NOT `req`. This condition predates rdy, and when
        // R474 made the cache streaming the back-to-back path in S_LOOK got the
        // check while this one kept accepting whenever a request was present --
        // with no free MSHR, no FIFO space, and a fill stealing the arrays. A
        // third miss then allocated into two slots and clobbered a fill in
        // flight. Every guard in rdy was being bypassed at the front door.
        end else if (req && rdy) begin
          idx_r   <= req_idx;
          tag_r   <= req_tag;
          sel_r   <= req_sel;
          wa_r    <= waddr;
          sheet_r <= sheet;
          x2_r    <= x2;
          y2_r    <= y2;
          st      <= S_LOOK;
        end

        // R474: A HIT ANSWERS AND ACCEPTS IN THE SAME CYCLE. S_ACK used to wait
        // here for the requester to drop `req`, which made every fetch a full
        // round trip whether it hit or not.
        // R480: the compare pushes its answer into the response FIFO and the
        // lookup pipeline keeps going. A miss takes an MSHR and issues on its
        // port; it no longer stops anything behind it.
        S_LOOK: if (hit) begin
          rs_rdy[rs_tl] <= 1'b1;
          rs_tex[rs_tl] <= nib(cd_q, sel_r, x2_r[0], y2_r[0]);   // R483
          rs_sel[rs_tl] <= sel_r;  rs_x2[rs_tl]  <= x2_r[0];
          rs_y2[rs_tl]  <= y2_r[0]; rs_ism[rs_tl] <= 1'b0;
          rs_wp    <= rs_wp + 1'd1;
          h_pulse  <= 1'b1;
          if (req && rdy) begin
            idx_r   <= req_idx;  tag_r   <= req_tag;  sel_r <= req_sel;
            wa_r    <= waddr;    sheet_r <= sheet;
            x2_r    <= x2;       y2_r    <= y2;
            st      <= S_LOOK;
          end else begin
            st      <= S_IDLE;
          end
        end else begin
          // R480: take a slot, issue on its port, and carry on.
          ms_busy[ms_pick] <= 1'b1;
          ms_done[ms_pick] <= 1'b0;
          ms_to  [ms_pick] <= '0;
          ms_idx [ms_pick] <= idx_r;
          ms_tag [ms_pick] <= tag_r;
          if (!ms_pick) begin
            m_req  <= 1'b1;
            m_addr <= (sheet_r ? base_s1 : base_s0)
                    + AW'({wa_r[WA_BITS-1:2], 2'b00});
          end else begin
            m2_req  <= 1'b1;
            m2_addr <= (sheet_r ? base_s1 : base_s0)
                     + AW'({wa_r[WA_BITS-1:2], 2'b00});
          end
          rs_rdy[rs_tl] <= 1'b0;    rs_ism[rs_tl] <= 1'b1;
          rs_slt[rs_tl] <= ms_pick;
          rs_sel[rs_tl] <= sel_r;   rs_x2[rs_tl] <= x2_r[0];
          rs_y2[rs_tl]  <= y2_r[0];
          rs_wp      <= rs_wp + 1'd1;
          m_pulse    <= 1'b1;
          if (req && rdy) begin
            idx_r   <= req_idx;  tag_r   <= req_tag;  sel_r <= req_sel;
            wa_r    <= waddr;    sheet_r <= sheet;
            x2_r    <= x2;       y2_r    <= y2;
            st      <= S_LOOK;
          end else begin
            st      <= S_IDLE;
          end
        end

        S_FILL: begin
          // The stolen cycle: the returned line goes into the arrays. mem_addr
          // is driven to ms_idx by the comb block below, so no lookup can read
          // this cycle -- rdy is low for it.
          ms_busy[ms_fill_sel] <= 1'b0;
          st <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  // The word out of the line, then the nibble out of the word. The parities are
  // the FETCHED coordinates', held with the request -- the reference takes them
  // from u0/v0, and those have the same parity as x2/y2 because the texture's
  // origin is a multiple of 32.
  // R483: `word`, the nibble mux and `hold` are gone -- the queue already
  // holds the extracted texel, and `texel` is registered by the response head.

  // R481: READY NEEDS EVERY RESOURCE THE REQUEST WILL CONSUME, and they are
  // consumed a cycle after it is accepted, in the compare stage. rdy is tested
  // at ACCEPT, so a request taken with one MSHR or one queue place left finds
  // it gone by the time it needs it -- two lookups both missing with one slot
  // between them, and ms_pick returns slot 1 unconditionally when slot 0 is
  // busy, clobbering a fill in flight.
  //
  // So from S_IDLE one of each is enough; from S_LOOK there is already a lookup
  // that may take one, and both must be free. With the second port disabled
  // there is no slot to reserve, so nothing is accepted from S_LOOK -- the
  // pre-R480 behaviour.
  wire ms_both_free = !ms_busy[0] && m2_en && !ms_busy[1];
  wire rs_room2     = ((rs_wp - rs_rp) <= ($clog2(RSP_D)+1)'(RSP_D - 2));
  assign rdy = !inval_pend && !ms_fill_rdy
               && (((st == S_IDLE) && !rs_full && ms_have_free)
                || ((st == S_LOOK) && rs_room2 && ms_both_free));


endmodule
