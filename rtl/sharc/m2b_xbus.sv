// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the 2B board's side of the SHARC's external bus (study
// R1031). MAME 0.289 model2.cpp, copro_sharc_map:
//
//   0x0400000-0x0bfffff  the in FIFO (read)         -- the core's A_FIN, not here
//   0x0c00000-0x13fffff  the out FIFO (write)       -- the core's A_FOUT, not here
//   0x1400000-0x1bfffff  buffer RAM, m_bufferram[offset & 0x7fff] (the i960's 0x00900000)
//   0x1c00000-0x1dfffff  copro_data ROM (writes ignored)
//
// and the SHARC's own block 1 past the core's on-chip words (0x28000 / 0x30000 / 0x38000 +
// a[14:0] >= 2^DM_AW): the SDRAM page behind m2b_dmc (R1026).
//
// The buffer RAM and data ROM go out on the coprocessor's existing pair of ports, as the
// TGPx4's do (m2_tgpx4, R924 / R1006): reads on `dat` (Model2.sv port 9, one dword a request,
// an idle clock after each), buffer writes posted into a queue and written on `bufw` (the
// shared write port, two 16-bit halves a dword). A buffer read waits for the queue to drain,
// so it reads what the SHARC wrote; `wq_busy` is the queue, which m2_copro uses to hold the
// i960's out-FIFO pops until the SHARC's stores are through (R888). Writes to the ROM are
// dropped (MAME's .rom()).
//
// NOT HERE YET (R1024 / R1026's plan, none of it used by Dead or Alive): the data ROM's and
// buffer RAM's read caches (Gunblade NY reads the ROM 4,181 times a vblank, fvipers /
// schamp the buffer ~1,900), and the buffer cache's coherence with the i960's writes.

`timescale 1ns/1ps

module m2b_xbus #(
    parameter int DM_AW = 13,
    parameter int LN_AW = 6,
    parameter int WD_AW = 4,
    parameter int WQ_AW = 4,
    parameter bit CLEAR = 1'b1,
    parameter bit BENCH = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    output logic        busy,           // the DM page's clear

    // the SHARC's external port (m2b_sharc ext_)
    input  logic        ext_req,
    input  logic        ext_we,
    input  logic [31:0] ext_addr,
    input  logic [31:0] ext_wdata,
    output logic        ext_ack,
    output logic [31:0] ext_rdata,

    // buffer RAM / data ROM (m2_copro's dat / bufw, Model2.sv port 9 and write port 2)
    output logic        dat_req,
    output logic [19:0] dat_addr,       // a dword index
    output logic        dat_is_buf,
    output logic        dat_hi,         // the ROM's dword bit 20
    input  logic        dat_ack,
    input  logic [31:0] dat_rdata,
    output logic        bufw_req,
    output logic [18:0] bufw_addr,      // a halfword index
    output logic [15:0] bufw_data,
    input  logic        bufw_ack,
    output logic        wq_busy,

    // the DM page (Model2.sv port 8)
    output logic        sdm_req,
    output logic        sdm_we,
    output logic [15:0] sdm_addr,
    output logic [15:0] sdm_din,
    input  logic        sdm_ack,
    input  logic [31:0] sdm_dout,

    output logic        st_fill,
    output logic        st_wait
);

// ------------------------------------------------------------------ the decode
wire x_dm  = ext_addr[31:18] == 14'h0 && ext_addr[17:15] >= 3'd5;
wire x_buf = ext_addr[31:25] == 7'h0 && ext_addr[24] && ext_addr[23:21] >= 3'd2 && ext_addr[23:21] <= 3'd5;
wire x_rom = ext_addr[31:25] == 7'h0 && ext_addr[24] && ext_addr[23:21] == 3'd6;

logic ext_done;                         // acknowledged, until the request falls

// ------------------------------------------------------------------ the DM page
logic        c_ack;
logic [31:0] c_rd;
m2b_dmc #(.DM_AW(DM_AW), .LN_AW(LN_AW), .WD_AW(WD_AW), .WQ_AW(WQ_AW), .CLEAR(CLEAR), .BENCH(BENCH)) u_dmc (
    .clk, .reset, .busy,
    .c_req(ext_req && x_dm && !ext_done), .c_we(ext_we), .c_idx(ext_addr[14:0]), .c_wd(ext_wdata),
    .c_ack, .c_rd,
    .s_req(sdm_req), .s_we(sdm_we), .s_addr(sdm_addr), .s_din(sdm_din), .s_ack(sdm_ack), .s_dout(sdm_dout),
    .st_fill, .st_wait);

// ------------------------------------------------------------------ buffer RAM / data ROM
logic [WQ_AW-1:0] wq_wp, wq_rp;
logic [WQ_AW:0]   wq_n;
logic             wq_push, wq_pop, wq_dr;
logic [46:0]      wq_q;
wire              wq_full = wq_n == (WQ_AW + 1)'(1 << WQ_AW);
m2b_lutram #(.AW(WQ_AW), .DW(47), .INIT1(BENCH)) u_wq (
    .clk, .we(wq_push), .wa(wq_wp), .wd({ext_addr[14:0], ext_wdata}), .ra(wq_rp), .rd(wq_q));
assign wq_busy = (wq_n != '0) || wq_dr;

localparam logic [1:0] Q_IDLE = 2'd0, Q_RD = 2'd1, Q_WR = 2'd2, Q_GAP = 2'd3;
logic [1:0]  q;
logic        w_hi;
logic [15:0] w_data;                 // the high half, for after the gap
logic [14:0] w_idx;
logic        x_ack;
logic [31:0] x_rd;

wire o_req   = ext_req && !x_dm && !ext_done;
wire o_wtake = o_req && ext_we && !(x_buf && wq_full);              // buffer: queued; ROM / other: dropped
wire o_rd    = o_req && !ext_we && !(x_buf && wq_busy);             // a buffer read after the queue
assign wq_push = o_wtake && x_buf;
assign wq_pop  = q == Q_WR && w_hi && bufw_ack;

always_ff @(posedge clk) begin
    if (reset) begin
        q <= Q_IDLE; w_hi <= 1'b0; w_data <= 16'h0; w_idx <= 15'h0;
        wq_wp <= '0; wq_rp <= '0; wq_n <= '0; wq_dr <= 1'b0;
        dat_req <= 1'b0; dat_addr <= 20'h0; dat_is_buf <= 1'b0; dat_hi <= 1'b0;
        bufw_req <= 1'b0; bufw_addr <= 19'h0; bufw_data <= 16'h0;
        x_ack <= 1'b0; x_rd <= 32'h0; ext_done <= 1'b0;
    end else begin
        x_ack <= 1'b0;
        if (!ext_req) ext_done <= 1'b0;
        if (ext_ack) ext_done <= 1'b1;
        if (o_wtake) begin x_ack <= 1'b1; ext_done <= 1'b1; end
        if (wq_push) wq_wp <= wq_wp + 1'b1;
        if (wq_pop)  wq_rp <= wq_rp + 1'b1;
        wq_n <= wq_n + (WQ_AW + 1)'(wq_push) - (WQ_AW + 1)'(wq_pop);
        case (q)
        Q_IDLE:
            if (o_rd) begin
                if (x_buf || x_rom) begin
                    dat_req <= 1'b1; dat_is_buf <= x_buf;
                    dat_addr <= x_buf ? {5'd0, ext_addr[14:0]} : ext_addr[19:0];
                    dat_hi <= x_rom & ext_addr[20];
                    q <= Q_RD;
                end else begin x_rd <= 32'h0; x_ack <= 1'b1; ext_done <= 1'b1; q <= Q_GAP; end   // (unmapped: 0)
            end else if (wq_n != '0) begin
                wq_dr <= 1'b1; w_hi <= 1'b0; w_data <= wq_q[31:16]; w_idx <= wq_q[46:32];
                bufw_req <= 1'b1; bufw_addr <= {3'd0, wq_q[46:32], 1'b0}; bufw_data <= wq_q[15:0];
                q <= Q_WR;
            end
        Q_RD: if (dat_ack) begin dat_req <= 1'b0; x_rd <= dat_rdata; x_ack <= 1'b1; ext_done <= 1'b1; q <= Q_GAP; end
        Q_WR: if (bufw_ack) begin
            bufw_req <= 1'b0;
            if (!w_hi) w_hi <= 1'b1;
            else begin w_hi <= 1'b0; wq_dr <= 1'b0; end
            q <= Q_GAP;
        end
        default: begin                          // Q_GAP: the high half after a gap
            if (w_hi) begin
                bufw_req <= 1'b1; bufw_addr <= {3'd0, w_idx, 1'b1}; bufw_data <= w_data;
                q <= Q_WR;
            end else q <= Q_IDLE;
        end
        endcase
    end
end

assign ext_ack   = c_ack | x_ack;
// R1044: chosen by which side acknowledged, not by the address's decode (off the path from the
// core's address register into its load paths). The core reads ext_rdata only in the clock of
// ext_ack (X ends on it), when c_ack is set exactly if the access was the DM page's (x_dm): the
// same word in every clock it is used
assign ext_rdata = c_ack ? c_rd : x_rd;

endmodule
