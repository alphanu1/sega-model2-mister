// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Carries texel fetches from the core clock to m2_texel on clk_mem, at ANY
// ratio. Replaces m2_texel_x2, which relied on an exact 2:1 (study R561).
//
// WHY THE CACHE STAYS ON clk_mem (R561). Moved to the core clock it lost no
// data but made the perspective close-up 58 lines late: its own state machine
// is about half of a miss and runs twice as fast here. So the queue in front
// of it becomes the crossing, and misses never cross at all.
//
// THE PROTOCOL IS m2_texel_x2's, UNCHANGED, so m2_span_tex does not move: the
// slow side ISSUES (s_req, a one-cycle pulse with its payload, whenever s_rdy
// says a credit is free) and TAKES answers in issue order (s_ack/s_texel,
// consumed by s_take). K credits bound what is in flight, so neither queue
// can overflow. The fast side presents the head in registers (f_tex/f_u/f_v)
// so the cache's address adders see a register, as R496 required.
//
// AN ASYNCHRONOUS FIFO EACH WAY, the textbook one:
//
//   * the slow side writes a request into q_* and then advances s_ip; s_ip
//     crosses in GRAY CODE through two flops, so the fast side sees it move
//     by one at most per step and never sees a torn value;
//   * the fast side reads q_*[slot] only for slots below the pointer it has
//     seen, which were written at least two fast edges before -- stable;
//   * answers go the other way the same way: r_tex written, then f_wp
//     advances, crossing in Gray code; the slow side reads r_tex[s_rp] only
//     while its synchronised copy says that slot holds an answer.
//
// The payload is never synchronised: synchronising a bus bit by bit would let
// the bits arrive skewed. It is read only after the pointer that covers it
// has crossed, which is the guarantee.
//
// LOSSLESS, WITH m2_texel_x2's ONE ESCAPE. A request the cache has not taken
// after TO_CYC fast cycles, with every older request already answered, is
// answered here as 0xF, so a sweep or a dead cache never stops the band.

`timescale 1ns/1ps

module m2_texel_cdc #(
  parameter int unsigned K      = 4,      // fetches in flight; a power of two
  parameter int unsigned TO_CYC = 1023,   // fast cycles before a local answer
  // R620: the answer's width -- 4 for m2_texel's nibble, 9 for m2_texel_bl's
  // {discard, t} -- and what a timed-out fetch answers: a full, opaque texel.
  parameter int unsigned TW     = 4,
  parameter int unsigned TO_VAL = 15
) (
  input  logic        clk_slow,       // the core clock
  input  logic        s_rst_n,
  input  logic        clk_fast,       // clk_mem
  input  logic        f_rst_n,

  // ---------------------------------------------- requester, slow (core clock)
  input  logic        s_req,          // one-cycle issue, payload valid with it
  output logic        s_rdy,          // a credit is free: s_req may be raised
  input  logic [31:0] s_tex,
  input  logic [19:0] s_u, s_v,
  output logic        s_ack,          // an answer is standing, in issue order
  output logic [TW-1:0] s_texel,
  input  logic        s_take,         // the requester takes it this cycle

  // ------------------------------------------------- m2_texel, fast (clk_mem)
  output logic        f_req,
  input  logic        f_rdy,          // the cache accepts when f_req & f_rdy
  input  logic        f_ack,
  output logic [31:0] f_tex,
  output logic [19:0] f_u, f_v,
  input  logic [TW-1:0] f_texel,
  // R583: the cache's address for the presented request, computed here as the
  // slot is loaded (m2_texel_addr), so m2_texel's RAM address comes straight
  // from a register. The slot was written at least three clk_mem edges
  // earlier, so this arithmetic has that long; from f_* to the RAM it had 10 ns.
  output logic [18:0] f_waddr,
  output logic        f_sheet,
  output logic        f_x2p,
  output logic        f_y2p,
  // R650: fetches answered HERE (TO_VAL) because the cache took none for
  // TO_CYC cycles -- on clk_fast, saturating. Each one paints TO_VAL.
  output logic [15:0] dbg_to
);

  localparam int unsigned PW = $clog2(K) + 1;   // one spare bit: full vs empty

  function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] g);
    logic [PW-1:0] b;
    b[PW-1] = g[PW-1];
    for (int i = PW - 2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // Written on the fast side, read on the slow: declared first.
  logic [PW-1:0] f_wp;                 // answers written
  logic [PW-1:0] f_wp_g;               // ... in Gray code, the value that crosses
  logic [TW-1:0] r_tex [K];

  // ------------------------------------------------------------- slow side
  logic [PW-1:0] s_ip;                 // requests issued
  logic [PW-1:0] s_ip_g;               // ... in Gray code, the value that crosses
  logic [PW-1:0] s_rp;                 // answers taken
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic [PW-1:0] s_wp_g1;
  logic [PW-1:0] s_wp_g2;              // answers written, synchronised
  logic [31:0]   q_tex [K];
  logic [19:0]   q_u [K], q_v [K];

  always_ff @(posedge clk_slow or negedge s_rst_n) begin
    if (!s_rst_n) begin
      s_ip <= '0; s_ip_g <= '0; s_rp <= '0; s_wp_g1 <= '0; s_wp_g2 <= '0;
    end else begin
      s_wp_g1 <= f_wp_g;
      s_wp_g2 <= s_wp_g1;
      if (s_req && s_rdy) begin
        s_ip   <= s_ip + 1'd1;
        s_ip_g <= bin2gray(s_ip + 1'd1);
      end
      if (s_ack && s_take) s_rp <= s_rp + 1'd1;
    end
  end
  // The payload queue is written only on issue and never reset (a memory).
  // Written on the SAME edge as s_ip_g moves, and read on the far side only
  // after s_ip_g has taken two more fast edges to arrive.
  always_ff @(posedge clk_slow) begin
    if (s_req && s_rdy) begin
      q_tex[s_ip[PW-2:0]] <= s_tex;
      q_u  [s_ip[PW-2:0]] <= s_u;
      q_v  [s_ip[PW-2:0]] <= s_v;
    end
  end

  wire [PW-1:0] s_wp = gray2bin(s_wp_g2);
  // Credits count from issue to TAKE, so an answer still waiting in the
  // response queue holds its slot and the queue cannot be overrun.
  assign s_rdy   = ((s_ip - s_rp) != PW'(K));
  assign s_ack   = (s_wp != s_rp);
  assign s_texel = r_tex[s_rp[PW-2:0]];

  // ------------------------------------------------------------- fast side
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic [PW-1:0] f_ip_g1;
  logic [PW-1:0] f_ip_g2;              // requests issued, synchronised
  logic [PW-1:0] f_ld;                 // requests loaded into the f_* registers
  logic [PW-1:0] f_sent;               // requests the cache has accepted
  logic          f_valid;              // f_tex/f_u/f_v hold an unsent request
  logic [$clog2(TO_CYC+1)-1:0] f_wait;

  wire [PW-1:0] f_ip   = gray2bin(f_ip_g2);

  // R583: the address of the slot about to be loaded.
  logic [18:0] ld_waddr;
  logic        ld_sheet, ld_x2p, ld_y2p;
  m2_texel_addr u_ldaddr (
    .tex(q_tex[f_ld[PW-2:0]]), .u(q_u[f_ld[PW-2:0]]), .v(q_v[f_ld[PW-2:0]]),
    .waddr(ld_waddr), .sheet(ld_sheet), .x2p(ld_x2p), .y2p(ld_y2p)
  );
  wire f_accept  = f_valid && f_rdy;
  wire f_pending = (f_ip != f_ld);
  // Answer locally only when every older request has been answered, so the
  // local answer lands in its own place in the order.
  wire f_timeout = f_valid && !f_rdy && (f_wp == f_sent)
                && (f_wait == ($clog2(TO_CYC+1))'(TO_CYC));
  wire f_answer  = f_ack || f_timeout;

  always_ff @(posedge clk_fast or negedge f_rst_n) begin
    if (!f_rst_n) begin
      f_ip_g1 <= '0; f_ip_g2 <= '0;
      f_ld <= '0; f_sent <= '0; f_wp <= '0; f_wp_g <= '0; f_valid <= 1'b0; f_wait <= '0;
      f_tex <= '0; f_u <= '0; f_v <= '0;
      f_waddr <= '0; f_sheet <= 1'b0; f_x2p <= 1'b0; f_y2p <= 1'b0;   // R583
    end else begin
      f_ip_g1 <= s_ip_g;
      f_ip_g2 <= f_ip_g1;

      // The presentation register: refilled from the queue the cycle its
      // request leaves, so the cache can take one every fast cycle.
      if ((!f_valid || f_accept || f_timeout) && f_pending) begin
        f_tex   <= q_tex[f_ld[PW-2:0]];
        f_u     <= q_u  [f_ld[PW-2:0]];
        f_v     <= q_v  [f_ld[PW-2:0]];
        f_waddr <= ld_waddr;             // R583
        f_sheet <= ld_sheet;
        f_x2p   <= ld_x2p;
        f_y2p   <= ld_y2p;
        f_ld    <= f_ld + 1'd1;
        f_valid <= 1'b1;
      end else if (f_accept || f_timeout) begin
        f_valid <= 1'b0;
      end

      if (f_accept || f_timeout) f_sent <= f_sent + 1'd1;

      if (!f_valid || f_rdy) f_wait <= '0;
      else if (f_wait != ($clog2(TO_CYC+1))'(TO_CYC)) f_wait <= f_wait + 1'd1;

      // Answers, in order. The cache's and the local one cannot coincide: the
      // local one needs every accepted request already answered. The Gray
      // pointer moves on the same edge as r_tex is written, and the slow side
      // needs two edges more to see it.
      if (f_answer) begin
        f_wp   <= f_wp + 1'd1;
        f_wp_g <= bin2gray(f_wp + 1'd1);
      end
    end
  end
  always_ff @(posedge clk_fast) begin
    if (f_ack)          r_tex[f_wp[PW-2:0]] <= f_texel;
    else if (f_timeout) r_tex[f_wp[PW-2:0]] <= TW'(TO_VAL);
  end

  assign f_req = f_valid;

  always_ff @(posedge clk_fast or negedge f_rst_n)
    if (!f_rst_n)                       dbg_to <= 16'd0;
    else if (f_timeout && !(&dbg_to))   dbg_to <= dbg_to + 16'd1;

endmodule
