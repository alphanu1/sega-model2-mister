// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// GLYPH CACHE. On-chip storage in front of the character fetch, because the
// glyph pixels are the ONLY part of the 2D path still read from SDRAM and the
// access pattern is absurdly redundant.
//
// MEASURED, on a boot through the test menu and into attract (20M i960
// instructions, tb_m2_boot):
//
//   71,605,920 fetches
//        7,883 distinct words touched   -> 30.8 KB
//      252,127 words of address span    -> 985 KB, far too big to hold whole
//        9,084x redundancy
//
// Nine thousand fetches per distinct word. Every one of them crosses the
// arbiter, occupies a slow port and costs SDRAM bandwidth that the TGP and the
// 3D renderer are going to want. A cache covering the working set serves
// essentially all of them from a block RAM in the renderer's own clock domain.
//
// 64 KB / 16,384 lines was chosen with headroom rather than fitted to the
// measurement: the 30.8 KB above is what the menu and attract touch, and
// gameplay will touch more. At ~59 M10K out of 241 free it is cheap insurance,
// and DBG_HITS/DBG_MISSES report the hit rate so the size can be revisited
// against evidence instead of opinion.
//
// DIRECT-MAPPED, FOUR WORDS A LINE, AND A MISS FILLS TWO OF THEM (R269). The
// line is what one transaction returns -- 64 bits, two glyph rows -- and the
// miss that fetches it also fetches the line beside it behind the acknowledge,
// so four rows are resident per miss. A tile is four lines walked in order by
// consecutive scanlines, so the second fetch is a prediction that cannot be
// wrong about WHAT is wanted, only about whether the tile stays on screen.
//
// THE TAG ARRAY CARRIES ITS OWN VALID BIT and is swept clear at reset. 16,384
// valid bits as flip-flops would be 16,384 registers; in the tag RAM they are
// free, at the price of a sweep the reset already has time for.
//
// THE REQUESTER'S CONTRACT IS UNCHANGED, so this drops in where m2_char_cdc
// sat: v_req is a LEVEL held until acknowledged, v_addr is stable for as long
// as v_req, and v_ack is ONE cycle with v_data valid on it.

`timescale 1ns/1ps

module m2_char_cache #(
  // 14 -> 16,384 lines -> 64 KB of data. The tag narrows as this widens.
  // FOUR-WORD LINES, SAME STORAGE. 8,192 x 64 bits is the 64 KB that 16,384 x
  // 32 was, so this costs no M10K and halves the misses.
  //
  // The locality is exact rather than hopeful. m2_tile_decode puts a tile's
  // rows at char_addr, +2, +4 ... +14, and consecutive SCANLINES read
  // consecutive rows -- so a line holding rows N and N+1 is fetched on the even
  // row and hit on the odd one. Measured cause: the hit rate is 82.6% and each
  // miss costs ~14 cycles against a 24-cycle per-column budget, which is why
  // 27 lines of every 384 overrun and repeat.
  // R313: 4096 LINES / 32 KB, DOWN FROM 8192 / 64 KB, and this is an AREA trade
  // rather than a cache decision. ALM is the binding resource (41,132 of 41,910,
  // 1.9% free) and the fitter is crashing two seeds in three at that density;
  // M10K only LOOKS full because Quartus pushes logic into spare blocks to
  // relieve ALM. Halving this releases ~34 M10K, which buys back the ~484 ALM
  // the register span queue costs by returning that queue to block memory.
  //
  // IT COSTS MISSES, and R283 says how many: 128 KB gave 694 a frame, 64 KB gave
  // 2,146. Expect 32 KB to roughly double again, and the scanline overruns with
  // it. That is the price of a build that fits at all.
  parameter int unsigned IDX_BITS = 12,
  parameter int unsigned ADDR_BITS = 18
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Renderer side.
  input  logic                   v_req,
  // Bit 0 is DELIBERATELY unread: m2_tile_decode always produces an even
  // char_addr, and a line is the pair it names. Reading it would index on a
  // bit that never varies, which is what wasted half this cache.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [ADDR_BITS-1:0]   v_addr,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic                   v_ack,
  output logic [31:0]            v_data,

  // Memory side, same shape as the port it replaces.
  output logic                   m_req,
  output logic [ADDR_BITS-1:0]   m_addr,
  input  logic                   m_ack,
  // 64 BITS, because that is what a burst returns and what a line holds. The
  // port already fetched four 16-bit words per miss and this cache stored
  // two of them, throwing away the next row of the same tile -- which the
  // next scanline then had to fetch again.
  input  logic [63:0]            m_data,

  // INVALIDATE. THE CACHE WAS INCOHERENT, AND THAT IS WHY THE SCREEN WAS FLAT.
  //
  // The char region is RAM: the game UPLOADS its glyphs into it. This cache had
  // no invalidation of any kind, so a filled line served forever -- including
  // lines filled BEFORE the upload, which read as zeros. A glyph of all zeros
  // paints one flat colour and two layers paint two, which is exactly what the
  // board showed. It also explains why it rendered ONCE and never again: whether
  // the picture appears depends on whether a line happened to be filled after
  // the upload or before it, which is a race rather than a state.
  //
  // Re-enters the sweep the reset path already has, so this costs no new
  // mechanism. Uploads are bursts, so it sweeps a few times and then warms once.
  // ONE LINE, NOT THE WHOLE CACHE, AND THE DIFFERENCE IS THE WHOLE POINT.
  //
  // The first version of this re-entered the reset sweep. That is correct and
  // useless: the game writes glyphs CONTINUOUSLY, every write restarted a
  // 16,384-cycle sweep, the sweep never finished, and a cache that is forever
  // initialising never acks -- so the renderer's glyph fetch starves and paints
  // exactly the same flat colours the stale zeros did. Invalidate-everything is
  // the correct answer to the wrong question.
  //
  // So drop the ONE line the write lands on. It costs a single cycle stolen
  // from the lookup, cannot starve anything, and is what a write-through cache
  // over writable memory has to do.
  input  logic                   inval,
  // THE INDEX ONLY. Direct-mapped: the line at this index either holds the word
  // that was written -- in which case it must go -- or holds a different one, in
  // which case dropping it costs one refill and is still correct. Comparing tags
  // to avoid that would add a read port to save nothing.
  input  logic [IDX_BITS-1:0]    inval_idx,
  output logic [31:0]            dbg_hits,
  output logic [31:0]            dbg_misses,
  // Sibling fills completed. Against dbg_misses it says whether the prefetch
  // is running at all -- one per miss when it is -- and the pair of counters is
  // the only way to tell a cache that is hitting because the fills land in time
  // from one that is hitting because the screen has nothing on it.
  output logic [31:0]            dbg_fills
);

  localparam int unsigned LINES    = 1 << IDX_BITS;
  // THE LOW ADDRESS BIT IS ALWAYS ZERO, so indexing on it wasted HALF the cache.
  //
  // m2_tile_decode: `char_addr = {tile_num, 4'b0000} + {map_y[2:0], 1'b0}` --
  // both terms have bit 0 clear, so every glyph fetch is at an EVEN word, and a
  // line is the pair (char_addr, char_addr+1) that holds one 8-pixel row. The
  // index therefore used a bit that never varies: only even lines were ever
  // reachable and half the M10K sat idle.
  //
  // Indexing from bit 1 doubles the effective cache for nothing. Measured cause
  // to fix it: the hit rate on hardware is 61-63% against 96.7% in simulation,
  // and the misses cost ~14 cycles each -- enough that about 5% of scanlines
  // overrun their fetch budget, repeat, and show as flicker.
  localparam int unsigned TAG_BITS = ADDR_BITS - IDX_BITS - 2;

  (* ramstyle = "M10K" *) logic [63:0]         cdata [LINES];
  (* ramstyle = "M10K" *) logic [TAG_BITS:0]   ctag  [LINES];   // {valid, tag}

  wire [IDX_BITS-1:0]  req_idx = v_addr[IDX_BITS+1:2];
  wire [TAG_BITS-1:0]  req_tag = v_addr[ADDR_BITS-1:IDX_BITS+2];
  // Which 32-bit half of the line the requester asked for. Bit 0 is still
  // always zero -- a row is a PAIR of 16-bit words -- so bit 1 selects the row.
  wire                 req_sel = v_addr[1];

  typedef enum logic [2:0] { S_INIT, S_IDLE, S_LOOK, S_MISS, S_FILL, S_ACK } st_t;
  st_t st;

  // ------------------------------------------------------------------------
  // THE SIBLING FILL: HALF THE MISSES, AND THEY OVERLAP.
  //
  // A tile is 16 words -- FOUR lines -- and consecutive scanlines walk them in
  // order: rows 0,1 are line I, rows 2,3 are I+1, and so on. A miss on line I
  // therefore predicts, with certainty rather than hope, that the line beside
  // it is wanted two scanlines later.
  //
  // So a demand miss fetches its own line, ACKNOWLEDGES, and then fetches the
  // sibling behind the acknowledge. Four glyph rows are resident per miss
  // instead of two: two misses per tile per eight scanlines where there were
  // four, at exactly the same storage.
  //
  // The overlap is the other half. A HIT NEEDS NO MEMORY PORT, so the 82.6% of
  // lookups that hit are served straight through an outstanding sibling fill --
  // the fetch engine decodes its tile word and emits its pixels while the fill
  // is still in the SDRAM. Only a second MISS has to wait for the port, and
  // there are now half as many of those. Measured cause for both halves: each
  // miss costs ~14 cycles against a 24-cycle per-column budget, which is why 27
  // lines of every 384 overrun and repeat the previous one.
  //
  // I^1, NOT I+1. The two differ only in the index's low bit, so the sibling's
  // tag is the demand tag, always. I+1 carries into the tag at the end of an
  // index span and would install a line under a tag that does not describe it
  // -- wrong pixels rather than a wasted fetch.
  //
  // THE PORT MUST GO IDLE BETWEEN THE TWO. m2_sdram_x2 clears its `done` latch
  // only on seeing the request LOW, so handing the port straight from the
  // demand fetch to the sibling -- dropping one and raising the other on the
  // same edge -- would leave `s_req` continuously high and the sibling would
  // never be issued at all. BG_GAP is that idle cycle, and it is two fast-side
  // cycles, which is what the adapter needs.
  // ------------------------------------------------------------------------
  typedef enum logic [1:0] { BG_IDLE, BG_GAP, BG_REQ, BG_WR } bgst_t;
  bgst_t bgst;
  logic [IDX_BITS-1:0] bg_idx;
  logic [TAG_BITS-1:0] bg_tag;
  logic [63:0]         bg_data;
  logic                bg_arm, bg_kill, d_kill;
  logic                d_req, bg_req;
  // R291: ONE SIBLING, NOT THREE, AND THE BOARD IS WHY.
  //
  // R283 fetched the whole tile -- all four lines -- on one miss, and the
  // bench's tile walk went from 2.00 misses per tile to 1.00 at the same
  // transaction count. On the board it did the OPPOSITE: 13,282 misses a
  // frame against 1,820-3,442 with one sibling, and the machine did not boot,
  // because a saturated SDRAM starves the CPU.
  //
  // THE CACHE IS DIRECT-MAPPED. Filling lines idx^1, idx^2 and idx^3 EVICTS
  // whatever is in them -- and with four tilemap layers interleaving their
  // fetches, what is in them is the other layers' glyphs. The bench walks one
  // layer's tiles in order and cannot see that; the board runs four at once
  // and does nothing else.
  //
  // Set WHOLE_TILE back to 1 if this is ever tried again on a set-associative
  // cache, where the eviction is what changes.
  parameter bit WHOLE_TILE = 1'b0;

  // R283: WHICH SIBLING IS IN FLIGHT. A tile is 16 words -- FOUR lines, sharing
  // one tag because the four differ only in the index's low two bits -- and the
  // eight scanlines that cross it read all four in order. Fetching ONE sibling
  // halved the misses; fetching the other three behind the same acknowledge
  // leaves the WHOLE TILE resident for one demand miss instead of four.
  //
  // Measured, and this is why: at 128 KB the board took 694 misses a frame and
  // 12 scanline overruns; halved to 64 KB to pay for the texture coordinates it
  // took 2,146 and 51. The traffic is the same either way -- these are lines
  // the next two scanlines would have fetched anyway -- but only the first one
  // is paid for in the fetch engine's critical path.
  logic [1:0]          bg_n;

  wire bg_busy = (bgst != BG_IDLE);
  wire bg_wr   = (bgst == BG_WR) && !bg_kill;

  logic [IDX_BITS-1:0] sweep;
  logic [IDX_BITS-1:0] idx_r;
  logic [TAG_BITS-1:0] tag_r;
  logic [63:0]         hold;
  logic                sel_r;

  // ONE REQUEST ON THE PORT AT A TIME, and the two sides are interlocked so
  // that stays true: the demand side issues only when the sibling fill is not
  // outstanding, and the sibling is armed only after the demand fetch has been
  // acknowledged and its request dropped.
  assign m_req  = d_req | bg_req;
  assign m_addr = d_req ? {tag_r, idx_r, 2'b00} : {bg_tag, bg_idx, 2'b00};

  // One read port, one write port, one clock: this infers a normal single-clock
  // block RAM with defined read-during-write, which is the whole point of the
  // renderer having moved onto clk_sys.
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

  always_comb begin
    // Default: point the arrays at the incoming request so a hit costs one
    // cycle and nothing else.
    mem_addr = req_idx;
    cd_we    = 1'b0;
    ct_we    = 1'b0;
    cd_din   = m_data;
    ct_din   = {1'b1, tag_r};
    case (st)
      S_INIT: begin mem_addr = sweep; ct_we = 1'b1; ct_din = '0; end
      S_LOOK: mem_addr = idx_r;
      S_FILL: begin mem_addr = idx_r; cd_we = !d_kill; ct_we = !d_kill; end
      default: ;
    endcase
    // The sibling's fill takes the port from whatever lookup wanted it. It
    // cannot collide with S_FILL -- one transaction is outstanding at a time,
    // so only one of the two can be answering an acknowledge.
    if (bg_wr && st != S_INIT) begin
      mem_addr = bg_idx;
      cd_din   = bg_data;
      ct_din   = {1'b1, bg_tag};
      cd_we    = 1'b1;
      ct_we    = 1'b1;
    end
    // A write to the glyph memory beats anything else wanting the tag port
    // this cycle. Never during the reset sweep, which is clearing them anyway.
    if (inval && st != S_INIT) begin
      mem_addr = inval_idx;
      ct_we    = 1'b1;
      ct_din   = '0;                       // valid = 0
      cd_we    = 1'b0;
    end
  end

  // THE LOOKUP THAT WAS ANSWERED BY SOMEBODY ELSE'S ADDRESS.
  //
  // `inval` and the sibling fill both divert mem_addr, so the read issued that
  // cycle comes back from a DIFFERENT LINE -- and the tag is only
  // ADDR_BITS-IDX_BITS-2 bits wide, two of them in the shipped configuration.
  // A wrong line's tag therefore matches one time in four, which is a HIT ON
  // ANOTHER GLYPH'S PIXELS. It has been in this cache since the invalidate was
  // added; it needs a CPU glyph write in the same cycle as a lookup, so it is
  // rare, wrong, and invisible to every counter here.
  //
  // The fix is to notice and ask again. One cycle, and it also does the
  // coherency work for free: a line the invalidate just cleared comes back a
  // miss on the second look, which is exactly what it should be.
  logic steal_d;
  wire  steal = (st != S_INIT) && (inval || bg_wr);

  wire hit = ct_q[TAG_BITS] && (ct_q[TAG_BITS-1:0] == tag_r);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_INIT; sweep <= '0; idx_r <= '0; tag_r <= '0; sel_r <= 1'b0;
      d_req <= 1'b0; v_ack <= 1'b0; hold <= '0;
      bgst <= BG_IDLE; bg_req <= 1'b0; bg_idx <= '0; bg_tag <= '0;
      bg_data <= '0; bg_arm <= 1'b0; bg_kill <= 1'b0; d_kill <= 1'b0; bg_n <= 2'd0;
      steal_d <= 1'b0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_fills <= '0;
    end else begin
      v_ack   <= 1'b0;
      steal_d <= steal;

      // A glyph write that lands on a line already in flight would otherwise be
      // undone by the fill that follows it: the fetch carries the data from
      // BEFORE the write, and installing it marks stale bytes valid. Both sides
      // abandon their fill instead. The requester still gets the word it asked
      // for -- its read raced the write and either answer is legitimate -- but
      // nothing stale is cached.
      if (inval && (inval_idx == idx_r)) d_kill  <= 1'b1;
      if (inval && (inval_idx == bg_idx)) bg_kill <= 1'b1;

      case (st)
        // Clear every valid bit before serving anything. Reset has time.
        S_INIT: begin
          sweep <= sweep + 1'd1;
          if (sweep == IDX_BITS'(LINES - 1)) st <= S_IDLE;
        end

        S_IDLE: if (v_req) begin
          idx_r  <= req_idx;
          tag_r  <= req_tag;
          sel_r  <= req_sel;
          d_kill <= 1'b0;
          st     <= S_LOOK;
        end

        // The arrays were addressed with req_idx last cycle, so cd_q/ct_q
        // answer this one -- unless somebody took the port, in which case they
        // answer a different line and must be asked again.
        S_LOOK: begin
          if (steal_d) begin
            // Look again. mem_addr is already idx_r in this state.
          end else if (hit) begin
            hold     <= cd_q;
            v_ack    <= 1'b1;
            dbg_hits <= dbg_hits + 1'd1;
            st       <= S_ACK;
          end else if (bg_busy) begin
            // The port is finishing the sibling fill. Looking again costs
            // nothing, and the fill may be this very line -- which is the
            // sibling's whole purpose.
          end else begin
            d_req      <= 1'b1;
            dbg_misses <= dbg_misses + 1'd1;
            st         <= S_MISS;
          end
        end

        S_MISS: if (m_ack) begin
          d_req <= 1'b0;
          hold  <= m_data;
          st    <= S_FILL;        // one cycle with cd_we/ct_we asserted
        end

        S_FILL: begin
          v_ack  <= 1'b1;
          // Arm the sibling. The port is idle this cycle and stays idle for
          // BG_GAP as well, which is what the adapter needs to retire the
          // transaction just finished.
          bg_arm <= 1'b1;
          bg_idx <= idx_r ^ IDX_BITS'(1);   // the sibling; BG_WR walks to the rest
          bg_tag <= tag_r;
          st     <= S_ACK;
        end

        // v_ack was a single cycle; wait for the requester to drop v_req so the
        // next request cannot be mistaken for this one.
        S_ACK: if (!v_req) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase

      // ---- the sibling fill, behind the acknowledge
      case (bgst)
        BG_IDLE: if (bg_arm) begin
          bg_arm  <= 1'b0;
          bg_kill <= 1'b0;
          bg_n    <= WHOLE_TILE ? 2'd1 : 2'd3;   // R291: one sibling, or three
          bgst    <= BG_GAP;
        end
        BG_GAP:  begin bg_req <= 1'b1; bgst <= BG_REQ; end
        BG_REQ:  if (m_ack) begin
          bg_req  <= 1'b0;
          bg_data <= m_data;
          dbg_fills <= dbg_fills + 1'd1;
          bgst    <= bg_kill ? BG_IDLE : BG_WR;
        end
        // One cycle of writing, then on to the next line of the tile. The
        // fourth time round there is nothing left to fetch.
        BG_WR:   if (!inval || bg_kill) begin
          if (bg_n == 2'd3 || bg_kill) begin
            bgst <= BG_IDLE;
          end else begin
            bg_n   <= bg_n + 2'd1;
            // The four lines of a tile differ only in the index's low two
            // bits, so this is a slice replacement and not arithmetic. Written
            // without casts: QUARTUS 17.0 REJECTS `~IDX_BITS'(3)` outright
            // ("syntax error near '", expecting ')'), where Verilator takes it
            // -- and a lint that passes is not a build that passes.
            bg_idx <= {bg_idx[IDX_BITS-1:2], idx_r[1:0] ^ (bg_n + 2'd1)};
            bgst   <= BG_GAP;              // the port must go idle between fetches
          end
        end
        default: bgst <= BG_IDLE;
      endcase
    end
  end

  // The row the requester asked for, out of the pair the line holds.
  assign v_data = sel_r ? hold[63:32] : hold[31:0];

endmodule
