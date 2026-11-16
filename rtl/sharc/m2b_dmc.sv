// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B SHARC's data-memory cache (study R1026, R1027,
// R1031).
//
// THE PAGE. The ADSP-21062's block 1 is 32 K x 32 (MAME 0.289 sharc.cpp: 0x20000-0x27fff
// mirrored by 0x18000, so 0x28000 / 0x30000 / 0x38000 all reach it, index a[14:0]). The core
// keeps the first 2^DM_AW words on chip (R1026: 8 K); the rest live in an SDRAM page of 32 K
// words (128 KB, 64 K halfwords) behind this cache. Only Sonic Championship and Last Bronx
// reach past 8 K (R1024); Dead or Alive never passes 0x316 (R1027).
//
// THE CACHE (R1027's measurement): 2^LN_AW lines x 2^WD_AW words, direct-mapped, write-through
// without allocate. The line store is M10K (two 16-bit lanes), the tags MLAB, the valid bits
// flip-flops (cleared at reset: they are not an array).
//   * A READ that hits is acknowledged the clock after the request, its word straight from the
//     line store's output register (the core's own DM read path, one clock later).
//   * A READ that misses starts a fill of its line, CRITICAL WORD FIRST, then the rest in
//     order round the line. The read is acknowledged as soon as its own word has landed, and the
//     rest of the line keeps filling behind it: a later read of a word already landed hits, one
//     not yet landed waits for it. A miss on another line while a fill runs waits for the read in
//     flight, then abandons that fill (the half-filled line stays invalid) and starts its own.
//   * A WRITE goes into the posted-write queue (2^WQ_AW deep, MLAB) and is acknowledged the clock
//     after the request unless the queue is full. A write to a valid line, or to the line being
//     filled, also updates the line store; on the filling line it marks the word as landed, so
//     the fill's own read of that word (if already issued, it returns the old value) is dropped.
//   * THE PORT ORDER (one transaction at a time, an idle clock after each): the clear, then the
//     queued writes, then the fill's reads. A fill read issued after a write therefore reads what
//     the write left; a write behind a fill read already in flight is covered by the rule above.
//   * Both halves of a write go out as two 16-bit writes (the port's width), low half first.
//
// THE CLEAR. MAME's device_reset fills both blocks with 0 and Dead or Alive reads words of
// block 1 it never wrote (R1027): the core clears its on-chip part, and this clears the page's
// part from 2^DM_AW up, one halfword a transaction after reset (busy meanwhile; the SHARC is
// held in HALT until then). The bench's page starts all ones -- unwritten memory reads 0xFFFF --
// so a missing clear shows.
//
// THE PORT (Model2.sv port 8 on a 2B build, m2_sdram_cdc's slow side): s_req a level held with
// s_addr / s_we / s_din until s_ack, then lowered for at least a clock; s_ack may stay high
// while s_req stands (R162) -- only the first is taken (the FSM leaves Q_WAIT on it); s_dout is
// {halfword s_addr + 1, halfword s_addr} with s_ack.

`timescale 1ns/1ps

module m2b_dmc #(
    parameter int DM_AW = 13,           // the SHARC's on-chip block-1 words (the page below it is never asked for)
    parameter int LN_AW = 6,            // 2^LN_AW lines (R1027: 64)
    parameter int WD_AW = 4,            // 2^WD_AW words a line (R1027: 16)
    parameter int WQ_AW = 4,            // posted writes, 2^WQ_AW deep
    parameter bit CLEAR = 1'b1,         // the page from 2^DM_AW cleared after reset (MAME's device_reset)
    parameter bit BENCH = 1'b0          // the line store starts all ones
) (
    input  logic        clk,
    input  logic        reset,
    output logic        busy,           // the clear after reset is running

    // the SHARC side: a block-1 word at index c_idx (>= 2^DM_AW)
    input  logic        c_req,
    input  logic        c_we,
    input  logic [14:0] c_idx,
    input  logic [31:0] c_wd,
    output logic        c_ack,
    output logic [31:0] c_rd,

    // the SDRAM side: one port, halfword-addressed in the page
    output logic        s_req,
    output logic        s_we,
    output logic [15:0] s_addr,
    output logic [15:0] s_din,
    input  logic        s_ack,
    input  logic [31:0] s_dout,

    // statistics (benches, the probe)
    output logic        st_fill,        // a fill started this clock
    output logic        st_wait         // a read is waiting for its word this clock
);

localparam int CA = LN_AW + WD_AW;      // line-store address bits
localparam int TW = 15 - CA;            // tag bits
localparam int NL = 1 << LN_AW;
localparam int NW = 1 << WD_AW;

// ------------------------------------------------------------------ the line store (M10K)
(* ramstyle = "M10K" *) logic [15:0] ls0 [1 << CA];
(* ramstyle = "M10K" *) logic [15:0] ls1 [1 << CA];
logic          ls_we;
logic [CA-1:0] ls_wa;
logic [31:0]   ls_wd, ls_q;
always_ff @(posedge clk) begin
    if (ls_we) begin ls0[ls_wa] <= ls_wd[15:0]; ls1[ls_wa] <= ls_wd[31:16]; end
    ls_q <= {ls1[c_idx[CA-1:0]], ls0[c_idx[CA-1:0]]};
end
generate if (BENCH) begin : g_init
    initial for (int k = 0; k < (1 << CA); k++) begin ls0[k] = 16'hFFFF; ls1[k] = 16'hFFFF; end
end endgenerate
assign c_rd = ls_q;

// ------------------------------------------------------------------ tags (MLAB) and valid bits
// The tag of a line is written as its fill starts and read (asynchronously) at the request's
// line; the read in the clock of a write is never used (the start of a fill is a decision of
// that clock, the next clock reads again).
logic [LN_AW-1:0] c_line;
logic [WD_AW-1:0] c_w;
logic [TW-1:0]    c_tag, tg_q;
logic             tg_we;
assign c_line = c_idx[CA-1:WD_AW];
assign c_w    = c_idx[WD_AW-1:0];
assign c_tag  = c_idx[14:CA];
logic [LN_AW-1:0] f_line;
logic [TW-1:0]    f_tag;
m2b_lutram #(.AW(LN_AW), .DW(TW), .INIT1(BENCH)) u_tag (
    .clk, .we(tg_we), .wa(c_line), .wd(c_tag), .ra(c_line), .rd(tg_q));
logic [NL-1:0] vld;

// ------------------------------------------------------------------ the fill
logic          f_on;                    // a line is filling
logic [NW-1:0] f_v;                     // its words landed (or written by the SHARC)
logic [WD_AW-1:0] f_iw;                 // the next word to read
logic [WD_AW:0]   f_ni;                 // words read so far (issued)
logic [WD_AW:0]   f_nl;                 // words landed
logic          fl_v;                    // a fill word landing this clock (registered)
logic [WD_AW-1:0] fl_w;
logic [31:0]   fl_d;

// ------------------------------------------------------------------ the posted writes (MLAB)
logic [WQ_AW-1:0] wq_wp, wq_rp;
logic [WQ_AW:0]   wq_n;
logic             wq_push, wq_pop;
logic [46:0]      wq_q;
m2b_lutram #(.AW(WQ_AW), .DW(47), .INIT1(BENCH)) u_wq (
    .clk, .we(wq_push), .wa(wq_wp), .wd({c_idx, c_wd}), .ra(wq_rp), .rd(wq_q));
wire wq_full = wq_n == (WQ_AW + 1)'(1 << WQ_AW);

// ------------------------------------------------------------------ the clear
logic        cl_on;
logic [15:0] cl_a;
assign busy = cl_on;

// ------------------------------------------------------------------ the port sequencer
localparam logic [1:0] Q_IDLE = 2'd0, Q_WAIT = 2'd1, Q_GAP = 2'd2;
localparam logic [1:0] K_CLR = 2'd0, K_WLO = 2'd1, K_WHI = 2'd2, K_FILL = 2'd3;
logic [1:0] q, qk;
logic       w_hi;                       // the low half of the queue's head is through
logic [WD_AW-1:0] q_fw;                 // the fill word in flight
wire        f_rd_busy = (q != Q_IDLE && qk == K_FILL) || fl_v;   // a fill read in flight or landing

// ------------------------------------------------------------------ the SHARC side
localparam logic [1:0] C_IDLE = 2'd0, C_ACK = 2'd1;
logic [1:0] cs;
logic       in_fill, v_hit, rd_hit, start_fill, w_take;
always_comb begin
    in_fill = f_on && c_line == f_line && c_tag == f_tag;
    v_hit   = vld[c_line] && tg_q == c_tag;
    rd_hit  = v_hit || (in_fill && f_v[c_w]);
    w_take     = cs == C_IDLE && c_req && c_we && !cl_on && !wq_full && !fl_v;
    start_fill = cs == C_IDLE && c_req && !c_we && !cl_on && !rd_hit && !in_fill && !f_rd_busy;
    wq_push = w_take;
    wq_pop  = q == Q_WAIT && qk == K_WHI && s_ack;
    tg_we   = start_fill;
    // the line store's one write: a landing first, else the SHARC's write
    ls_we = 1'b0; ls_wa = {f_line, fl_w}; ls_wd = fl_d;
    if (fl_v) ls_we = f_on && !f_v[fl_w];
    else if (w_take && (v_hit || in_fill)) begin ls_we = 1'b1; ls_wa = c_idx[CA-1:0]; ls_wd = c_wd; end
end
assign c_ack   = cs == C_ACK;
assign st_fill = start_fill;
assign st_wait = cs == C_IDLE && c_req && !c_we && in_fill && !f_v[c_w];

always_ff @(posedge clk) begin
    if (reset) begin
        cs <= C_IDLE;
        vld <= '0;
        f_on <= 1'b0; f_v <= '0; f_iw <= '0; f_ni <= '0; f_nl <= '0; fl_v <= 1'b0;
        f_line <= '0; f_tag <= '0; fl_w <= '0; fl_d <= 32'h0;
        wq_wp <= '0; wq_rp <= '0; wq_n <= '0;
        cl_on <= CLEAR; cl_a <= 16'((1 << DM_AW) * 2);
        q <= Q_IDLE; qk <= K_CLR; w_hi <= 1'b0; q_fw <= '0;
        s_req <= 1'b0; s_we <= 1'b0; s_addr <= 16'h0; s_din <= 16'h0;
    end else begin
        // ---- the SHARC side
        case (cs)
        C_IDLE: if (c_req && !cl_on) begin
            if (c_we) begin if (w_take) cs <= C_ACK; end
            else if (rd_hit) cs <= C_ACK;
        end
        default: cs <= C_IDLE;                  // the ack clock; the request falls after it
        endcase
        if (w_take && in_fill) f_v[c_w] <= 1'b1;
        if (start_fill) begin
            f_on <= 1'b1; f_line <= c_line; f_tag <= c_tag; f_v <= '0;
            f_iw <= c_w; f_ni <= '0; f_nl <= '0;
            vld[c_line] <= 1'b0;
        end

        // ---- the posted writes
        if (wq_push) wq_wp <= wq_wp + 1'b1;
        if (wq_pop)  wq_rp <= wq_rp + 1'b1;
        wq_n <= wq_n + (WQ_AW + 1)'(wq_push) - (WQ_AW + 1)'(wq_pop);

        // ---- a fill word lands (the clock after its acknowledge)
        fl_v <= 1'b0;
        if (fl_v && f_on) begin
            f_v[fl_w] <= 1'b1;
            f_nl <= f_nl + 1'b1;
            if (f_nl == (WD_AW + 1)'(NW - 1)) begin f_on <= 1'b0; vld[f_line] <= 1'b1; end
        end

        // ---- the port
        case (q)
        Q_IDLE: begin
            if (cl_on) begin
                q <= Q_WAIT; qk <= K_CLR;
                s_req <= 1'b1; s_we <= 1'b1; s_addr <= cl_a; s_din <= 16'h0;
            end else if (w_hi) begin
                q <= Q_WAIT; qk <= K_WHI;
                s_req <= 1'b1; s_we <= 1'b1; s_addr <= {wq_q[46:32], 1'b1}; s_din <= wq_q[31:16];
            end else if (wq_n != '0) begin
                q <= Q_WAIT; qk <= K_WLO;
                s_req <= 1'b1; s_we <= 1'b1; s_addr <= {wq_q[46:32], 1'b0}; s_din <= wq_q[15:0];
            end else if (f_on && !start_fill && f_ni != (WD_AW + 1)'(NW)) begin
                q <= Q_WAIT; qk <= K_FILL; q_fw <= f_iw;
                s_req <= 1'b1; s_we <= 1'b0; s_addr <= {f_tag, f_line, f_iw, 1'b0};
                f_iw <= f_iw + 1'b1; f_ni <= f_ni + 1'b1;
            end
        end
        Q_WAIT: if (s_ack) begin
            s_req <= 1'b0;
            q <= Q_GAP;
            case (qk)
            K_CLR: begin cl_a <= cl_a + 1'b1; if (&cl_a) cl_on <= 1'b0; end
            K_WLO: w_hi <= 1'b1;
            K_WHI: w_hi <= 1'b0;
            default: begin fl_v <= 1'b1; fl_w <= q_fw; fl_d <= s_dout; end
            endcase
        end
        default: q <= Q_IDLE;
        endcase
    end
end

// The rules above, checked where the benches run (never synthesised: BENCH only).
generate if (BENCH) begin : g_chk
    always_ff @(posedge clk) if (!reset) begin
        if (start_fill && f_rd_busy) $fatal(1, "m2b_dmc: a fill started with a fill read in flight");
        if (fl_v && !f_on) $fatal(1, "m2b_dmc: a fill word landed with no fill");
        if (c_ack && c_req && !c_we && c_idx < 15'(1 << DM_AW)) $fatal(1, "m2b_dmc: an on-chip index %h", c_idx);
    end
end endgenerate

endmodule
