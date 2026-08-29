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
// DIRECT-MAPPED, ONE WORD PER LINE. No line fill: a miss fetches exactly the
// word asked for. Glyph reads walk consecutive words within a character, so a
// wider line would help, but it would also multiply the miss cost and this
// device returns four words a transaction already. Start simple, measure, then
// widen if the counters say to.
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
  parameter int unsigned IDX_BITS = 14,
  parameter int unsigned ADDR_BITS = 18
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Renderer side.
  input  logic                   v_req,
  input  logic [ADDR_BITS-1:0]   v_addr,
  output logic                   v_ack,
  output logic [31:0]            v_data,

  // Memory side, same shape as the port it replaces.
  output logic                   m_req,
  output logic [ADDR_BITS-1:0]   m_addr,
  input  logic                   m_ack,
  input  logic [31:0]            m_data,

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
  input  logic                   inval,
  output logic [31:0]            dbg_hits,
  output logic [31:0]            dbg_misses
);

  localparam int unsigned LINES    = 1 << IDX_BITS;
  localparam int unsigned TAG_BITS = ADDR_BITS - IDX_BITS;

  (* ramstyle = "M10K" *) logic [31:0]         cdata [LINES];
  (* ramstyle = "M10K" *) logic [TAG_BITS:0]   ctag  [LINES];   // {valid, tag}

  wire [IDX_BITS-1:0]  req_idx = v_addr[IDX_BITS-1:0];
  wire [TAG_BITS-1:0]  req_tag = v_addr[ADDR_BITS-1:IDX_BITS];

  typedef enum logic [2:0] { S_INIT, S_IDLE, S_LOOK, S_MISS, S_FILL, S_ACK } st_t;
  st_t st;

  logic [IDX_BITS-1:0] sweep;
  logic [IDX_BITS-1:0] idx_r;
  logic [TAG_BITS-1:0] tag_r;
  logic [31:0]         hold;

  // One read port, one write port, one clock: this infers a normal single-clock
  // block RAM with defined read-during-write, which is the whole point of the
  // renderer having moved onto clk_sys.
  logic [31:0]       cd_q;
  logic [TAG_BITS:0] ct_q;
  logic              cd_we, ct_we;
  logic [IDX_BITS-1:0] mem_addr;
  logic [31:0]         cd_din;
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
      S_FILL: begin mem_addr = idx_r; cd_we = 1'b1; ct_we = 1'b1; end
      default: ;
    endcase
  end

  wire hit = ct_q[TAG_BITS] && (ct_q[TAG_BITS-1:0] == tag_r);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_INIT; sweep <= '0; idx_r <= '0; tag_r <= '0;
      m_req <= 1'b0; m_addr <= '0; v_ack <= 1'b0; hold <= '0;
      dbg_hits <= '0; dbg_misses <= '0;
    end else if (inval) begin
      // Whatever it was doing, start again: a fill in flight would otherwise
      // commit a line read before the write that invalidated it.
      st <= S_INIT; sweep <= '0; m_req <= 1'b0; v_ack <= 1'b0;
    end else begin
      v_ack <= 1'b0;
      case (st)
        // Clear every valid bit before serving anything. Reset has time.
        S_INIT: begin
          sweep <= sweep + 1'd1;
          if (sweep == IDX_BITS'(LINES - 1)) st <= S_IDLE;
        end

        S_IDLE: if (v_req) begin
          idx_r <= req_idx;
          tag_r <= req_tag;
          st    <= S_LOOK;
        end

        // The arrays were addressed with req_idx last cycle, so cd_q/ct_q
        // answer this one.
        S_LOOK: begin
          if (hit) begin
            hold     <= cd_q;
            v_ack    <= 1'b1;
            dbg_hits <= dbg_hits + 1'd1;
            st       <= S_ACK;
          end else begin
            m_req      <= 1'b1;
            m_addr     <= {tag_r, idx_r};
            dbg_misses <= dbg_misses + 1'd1;
            st         <= S_MISS;
          end
        end

        S_MISS: if (m_ack) begin
          m_req <= 1'b0;
          hold  <= m_data;
          st    <= S_FILL;        // one cycle with cd_we/ct_we asserted
        end

        S_FILL: begin
          v_ack <= 1'b1;
          st    <= S_ACK;
        end

        // v_ack was a single cycle; wait for the requester to drop v_req so the
        // next request cannot be mistaken for this one.
        S_ACK: if (!v_req) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

  assign v_data = hold;

endmodule
