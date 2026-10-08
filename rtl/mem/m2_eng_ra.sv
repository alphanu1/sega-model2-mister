// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_eng_ra -- read-ahead in front of the geometry engine's memory port
// (R709).
//
// The engine reads one dword, waits the whole port round trip, uses it and
// reads the next (R696: ~77 reads a quad, bound by latency, not bandwidth).
// Most of those reads walk forward through a polygon's record or a texture
// header, so the next pairs are fetched while the engine is still working on
// the current one. tb_m2_geodiff (M2GD_PC=3, the limits below): 25-26% off a
// heavy list's walk against R214's pair cache, of a 29-32% ceiling with
// memory free. Model 1 does the same in its walker (m1_geo_walk's polygon ROM
// prefetch: "the latency is hidden entirely"); this is a stream in front of
// the engine instead, because Model 2's engine reads from a dozen states.
//
// TWO STREAMS: 0 the polygon data (polygon RAM or ROM), 1 the texture headers
// in texture ROM. Each holds up to DEPTH consecutive pairs {2k, 2k+1}, from
// the even dword at or below the miss that started it. A read inside a
// stream's window is answered from it, and the pairs before it are dropped;
// any other read restarts that stream there. One port fetch is in flight at
// a time, demand first, the stream the engine is reading next, then the other.
//
// WHAT IS NEVER COPIED, AND WHY (R708). R696's keep-last copied everything the
// engine read and turned the 3D black after scene changes; the mechanism is
// not proven, so this keeps no copy of anything another master writes behind
// it except the polygon RAM, whose only writer lands its writes here as
// `inval`:
//   * The palette and translation mirrors (spaces 2, 3) and the texture
//     headers in texture RAM are rewritten by the CPU, and its invalidates fire
//     when a write is ISSUED, not when it lands. They go straight to the port,
//     every read, no copy at all -- not even R214's next dword. The bench lost
//     nothing by it: the engine's own colour cache already holds those.
//   * The polygon RAM is written by the geometrizer's DMA. `inval` is that
//     write's acknowledge -- the write has landed -- and drops both streams. A
//     fetch in flight across it is discarded on arrival, not kept (R698's
//     hole: it may have read the dword before the write).
//   * No copy outlives an object: both streams are dropped whenever `active`
//     (the engine busy) is low. The bench measured no cost to it.
// `bypass` keeps no copy of anything.
//
// THE PORT IS SHARED WITH THE WALKER (Model2.sv, port 4), which may only ask
// while the engine is idle. A read-ahead fetch can still be in flight when the
// engine finishes, so `busy` is held from a fetch's issue until the port's
// acknowledge has fallen, and the walker waits for it as for the engine.
//
// Handshakes as m2_pair_cache's: the requester's is R208's -- a level request,
// the acknowledge taken on its rising edge, the request dropped for a cycle
// after; `idx` is stable while `req` is up. The port's: a level request held
// until its acknowledge rises, the acknowledge held until the request falls
// (R162), `p_dout` valid with it.
//
// R714: THE REQUEST IS REGISTERED ON THE WAY IN. At 80 MHz the path from the
// engine's state register through its address select, Model2.sv's base add
// and the window subtraction into the stream registers missed by 0.71 ns
// (s728); everything here now runs from req_q / idx_q / sen_q / sid_q, a cycle
// behind the engine. A hit is acknowledged three cycles after the request.
`timescale 1ns/1ps
module m2_eng_ra #(
  parameter int unsigned AW    = 24,
  parameter int unsigned DEPTH = 4       // pairs a stream holds: 4 (the ring index is two bits)
)(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          bypass,
  input  logic          active,          // the engine is working on an object
  input  logic          inval,           // a write landed in the polygon RAM
  // the engine
  input  logic          req,
  input  logic [AW-1:0] idx,             // dword index
  input  logic          stream_en,       // this read may be served from a stream
  input  logic          sid,             // which: 0 polygon data, 1 texture ROM headers
  output logic          ack,
  output logic [31:0]   data,
  // the port
  output logic          p_req,
  output logic [AW-1:0] p_idx,
  input  logic          p_ack,
  input  logic [63:0]   p_dout,
  output logic          busy             // a port fetch is in flight
);

  localparam logic [2:0] DEPTH3 = DEPTH[2:0];

  // ---------------------------------------------------------------- streams
  logic          s_act  [2];
  logic [AW-1:0] s_head [2];             // even: the pair in logical slot 0
  logic [1:0]    s_rp   [2];             // logical slot 0's physical slot
  logic [2:0]    s_fill [2];             // slots allocated, 0..DEPTH, the last may be in flight
  logic [3:0]    s_arr  [2];             // physical slots whose pair has arrived

  // {stream, physical slot}. READ IN ITS OWN RESET-FREE BLOCK, addressed on
  // the hit cycle: read inside the async-reset block, Quartus 17 would not
  // infer it ("uninferred due to asynchronous read logic") and built 512
  // flip-flops and their mux instead -- 424 ALM for the module in s717.
  (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] pairs [8];

  // ------------------------------------------------------------ the request
  // R714: registered as it arrives; the engine holds idx, stream_en and sid
  // steady while req is up, so the copies are that request's.
  logic          req_q, sen_q, sid_q;
  logic [AW-1:0] idx_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) req_q <= 1'b0;
    else        req_q <= req;
  always_ff @(posedge clk) begin idx_q <= idx; sen_q <= stream_en; sid_q <= sid; end

  logic req_d, pend;
  wire  new_req = req_q && !req_d;
  wire  want    = new_req || pend;
  wire  strm    = sen_q && active && !bypass;

  // The window test runs on `idx` directly, as m2_pair_cache's match does, so
  // a hit costs what a hit there costs.
  wire [AW-1:0] off    = idx_q - s_head[sid_q];
  wire          in_win = s_act[sid_q] && (off < AW'({s_fill[sid_q], 1'b0}));
  wire [1:0]    hj     = off[2:1];                  // logical slot
  wire [1:0]    hph    = s_rp[sid_q] + hj;          // physical slot
  wire          flush  = !active || inval || bypass;
  wire          hit    = want && strm && !flush && in_win && s_arr[sid_q][hph];
  // A stream just restarted here holds nothing until its first fetch issues;
  // that is not another miss, or it would restart every cycle and never issue.
  wire          fresh  = s_act[sid_q] && (s_fill[sid_q] == 3'd0) && (s_head[sid_q] == {idx_q[AW-1:1], 1'b0});
  wire          miss   = want && strm && !flush && !in_win && !fresh;
  // the physical slots a hit drops: the hj logical slots before it, rotated
  // to where logical slot 0 sits
  logic [3:0] drop_l, drop;
  always_comb begin
    case (hj)
      2'd0: drop_l = 4'b0000;
      2'd1: drop_l = 4'b0001;
      2'd2: drop_l = 4'b0011;
      default: drop_l = 4'b0111;
    endcase
    case (s_rp[sid_q])
      2'd0: drop = drop_l;
      2'd1: drop = {drop_l[2:0], drop_l[3]};
      2'd2: drop = {drop_l[1:0], drop_l[3:2]};
      default: drop = {drop_l[0], drop_l[3:1]};
    endcase
  end

  // ---------------------------------------------------------------- the port
  typedef enum logic [1:0] { P_IDLE, P_REQ, P_DROP, P_GAP } pst_t;
  pst_t          pst;
  logic          f_pass;                 // a demand read straight through
  logic          f_s;                    // a stream fetch's stream
  logic [1:0]    f_ph;                   // ...and physical slot
  logic          f_keep;                 // ...and whether it is still wanted
  // A fetch issued FOR the read that is waiting -- the pair it asked for --
  // answers that read when it arrives, kept or not (R698's rule). Without it a
  // write landing during every fetch drops every fetch and the read starves;
  // with it, any read finishes within two fetches. The answer is a correct
  // order: the fetch began after the read was asked.
  logic          f_dem;
  logic          p_ack_d;
  wire           p_rise = p_ack && !p_ack_d;

  // What the port does next, if it is free. A read straight through goes
  // whenever the port is -- bypassed or idle, the engine must still be
  // answered. No stream fetch is issued in a cycle that restarts or drops a
  // stream: the registers it would read are changing.
  wire        go_pass   = (pst == P_IDLE) && want && !strm;
  wire        can_issue = (pst == P_IDLE) && !miss && !flush;
  wire        cand0     = s_act[0] && (s_fill[0] < DEPTH3);
  wire        cand1     = s_act[1] && (s_fill[1] < DEPTH3);
  wire        pref      = (want && strm) ? sid_q : 1'b0;
  wire        go_strm   = can_issue && !go_pass && (cand0 || cand1);
  wire        g_s       = (pref ? cand1 : !cand0) ? 1'b1 : 1'b0;   // pref if it can, else the other
  wire [AW-1:0] g_idx   = s_head[g_s] + AW'({s_fill[g_s], 1'b0});
  wire [1:0]  g_ph      = s_rp[g_s] + s_fill[g_s][1:0];
  wire        g_dem     = want && strm && (g_s == sid_q) && (g_idx == {idx_q[AW-1:1], 1'b0});

  always_ff @(posedge clk) if (pst == P_REQ && p_rise && !f_pass && f_keep && !flush) pairs[{f_s, f_ph}] <= p_dout;

  // arrived-flags: an arrival sets its slot, a hit drops the slots before it,
  // a restart or a drop clears the stream -- merged, because a hit and an
  // arrival can land on the same stream in the same cycle (never the same
  // slot: the one in flight is always the last allocated).
  wire        arrive = (pst == P_REQ) && p_rise && !f_pass && f_keep;
  logic [3:0] arr_n [2];
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      arr_n[s] = s_arr[s];
      if (go_strm && (g_s == s[0])) arr_n[s][g_ph] = 1'b0;   // allocated: nothing has arrived
      if (arrive && (f_s == s[0])) arr_n[s][f_ph] = 1'b1;
      if (hit  && (sid_q == s[0])) arr_n[s] = arr_n[s] & ~drop;
      if (miss && (sid_q == s[0])) arr_n[s] = 4'b0000;
      if (flush)                   arr_n[s] = 4'b0000;
    end
  end

  logic        rd_half;
  logic        hit_q;
  logic [63:0] rd_q;
  // a hit's pair, read on the hit cycle; never the slot being written (the
  // one in flight is never the one hit)
  always_ff @(posedge clk) if (hit) rd_q <= pairs[{sid_q, hph}];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < 2; s++) begin
        s_act[s] <= 1'b0; s_head[s] <= '0; s_rp[s] <= '0; s_fill[s] <= '0; s_arr[s] <= '0;
      end
      req_d <= 1'b0; pend <= 1'b0; ack <= 1'b0; data <= '0;
      pst <= P_IDLE; p_req <= 1'b0; p_idx <= '0; p_ack_d <= 1'b0;
      f_pass <= 1'b0; f_s <= 1'b0; f_ph <= '0; f_keep <= 1'b0; f_dem <= 1'b0;
      rd_half <= 1'b0; hit_q <= 1'b0;
    end else begin
      req_d   <= req_q;
      p_ack_d <= p_ack;
      ack     <= 1'b0;
      hit_q   <= 1'b0;

      // a hit's answer, the cycle after
      if (hit_q) begin
        data <= rd_half ? rd_q[63:32] : rd_q[31:0];
        ack  <= 1'b1;
      end

      if (new_req) pend <= 1'b1;

      // ---- the port
      case (pst)
        P_IDLE: begin
          if (go_pass) begin
            p_idx <= idx_q; p_req <= 1'b1; f_pass <= 1'b1; f_keep <= 1'b0; f_dem <= 1'b0; pst <= P_REQ;
          end else if (go_strm) begin
            p_idx <= g_idx; p_req <= 1'b1; f_pass <= 1'b0; f_s <= g_s; f_ph <= g_ph; f_keep <= 1'b1;
            f_dem <= g_dem;
            pst <= P_REQ;
          end
        end
        P_REQ: if (p_rise) begin
          p_req <= 1'b0;
          pst   <= P_DROP;
          if (f_pass) begin
            data <= p_dout[31:0]; ack <= 1'b1; pend <= 1'b0;
          end else if (f_dem && pend) begin
            data <= idx_q[0] ? p_dout[63:32] : p_dout[31:0]; ack <= 1'b1; pend <= 1'b0;
          end
        end
        P_DROP: if (!p_ack) pst <= P_GAP;      // the adapter has seen the request fall
        P_GAP:  pst <= P_IDLE;
        default: pst <= P_IDLE;
      endcase

      // ---- the engine's read
      if (hit) begin
        pend    <= 1'b0;
        hit_q   <= 1'b1;
        rd_half <= idx_q[0];
        s_head[sid_q] <= s_head[sid_q] + AW'({hj, 1'b0});
        s_rp[sid_q]   <= hph;
      end

      s_arr[0] <= arr_n[0];
      s_arr[1] <= arr_n[1];

      // fill: a hit drops hj slots, an issue allocates one -- in the same cycle
      // on the same stream both apply. g_idx and g_ph do not move with a hit:
      // head + 2*fill and rp + fill are the same pair either side of it.
      s_fill[0] <= s_fill[0] - ((hit && !sid_q) ? {1'b0, hj} : 3'd0) + ((go_strm && !g_s) ? 3'd1 : 3'd0);
      s_fill[1] <= s_fill[1] - ((hit &&  sid_q) ? {1'b0, hj} : 3'd0) + ((go_strm &&  g_s) ? 3'd1 : 3'd0);

      // ---- a read outside its stream's window starts the stream over there
      if (miss) begin
        s_act[sid_q]  <= 1'b1;
        s_head[sid_q] <= {idx_q[AW-1:1], 1'b0};
        s_rp[sid_q]   <= '0;
        s_fill[sid_q] <= '0;
        if (pst != P_IDLE && !f_pass && f_s == sid_q) f_keep <= 1'b0;   // in flight for the old window
      end

      // ---- dropped: the engine idle, a write landed, or bypassed. LAST, so it
      // wins over an arrival, a hit or an issue in the same cycle.
      if (flush) begin
        for (int s = 0; s < 2; s++) begin
          s_act[s] <= 1'b0; s_fill[s] <= '0;
        end
        f_keep <= 1'b0;
      end
    end
  end

  assign busy = (pst != P_IDLE);

endmodule
