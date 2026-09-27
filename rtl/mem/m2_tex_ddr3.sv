// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE TEXTURE SHEETS, MIRRORED INTO DDR3 (R645).
//
// The CPU uploads Daytona's textures into two 1 MB sheets in SDRAM (R264), and
// the texel cache reads them a 64-bit line per miss -- the renderer's heaviest
// SDRAM traffic, and the traffic the ddr3 branch measured costing the CPU a
// quarter of every frame in bus waits (R362). This keeps SDRAM the master copy
// and nothing about the CPU's path changes: every completed CPU write into the
// sheets is ALSO written here into DDR3, and the texel cache's two miss ports
// can be pointed at the DDR3 copy (an OSD switch, in Model2.sv) instead of
// SDRAM ports 10 and 2.
//
// LAYOUT. Four 16-bit SDRAM words are one 64-bit DDR3 word, word k of the four
// in bits [16k+15:16k] -- which is exactly how m2_sdram packs a four-word
// burst ({dq_r, cap[2], cap[1], cap[0]}), and a miss is always a four-word-
// aligned line (m2_texel_bl: base + {rp, cg, 2'b00}). So the answer to a read
// from DDR3 is bit-for-bit the answer SDRAM gives.
//
// THE READS CROSS A CLOCK, AND NOTHING CROSSES AS A PULSE (R377). The miss
// ports are on clk_mem; the DDR3 master, like everything else on it, is on
// clk_sys. Per port, one read in flight: the request is a toggle into clk_sys
// with the address latched on the clk_mem side (stable until the answer); the
// answer is a toggle back, with the data held in clk_sys until the next
// request. A miss slot that timed out (m2_texel_bl gives up after 1,023
// cycles) and asked again for another line is NOT answered with the old line:
// the acknowledge is given only if the port still asks for the address that
// was fetched.
//
// THE WRITES DO NOT STALL ANYTHING. They queue (64 deep) and go out one beat
// each, byte-enabled to their lane; a full queue drops and counts
// (dbg_wr_lost). The CPU writes a word per ~20 core cycles at most and a
// one-beat DDR3 write takes a few, so the count should stay at zero -- and if
// it does not, the switch is left on SDRAM.

`timescale 1ns/1ps

module m2_tex_ddr3 #(
  parameter int unsigned AW    = 25,                 // SDRAM word address width
  parameter logic [AW:1] SBASE = '0,                 // sheet 0's first SDRAM word
  parameter logic [24:0] TBASE = 25'h080000,         // the mirror's first DDR3 word
  parameter int unsigned QD    = 64
) (
  input  logic        clk_mem,
  input  logic        clk,           // clk_sys: the DDR3 master's clock
  input  logic        rst_n,

  // ---- clk_mem: the texel cache's two miss ports, as m2_sdram serves them
  input  logic        r_req  [2],
  input  logic [AW:1] r_addr [2],
  output logic        r_ack  [2],
  output logic [63:0] r_data [2],

  // ---- clk: a CPU write that completed into SDRAM
  input  logic        w_valid,
  input  logic [AW:1] w_addr,
  input  logic [15:0] w_data,
  input  logic [1:0]  w_be,

  // ---- clk: one m2_ddr3 client (through m2_ddr3_arb)
  output logic        d_req,
  output logic        d_we,
  output logic [24:0] d_addr,
  output logic [7:0]  d_blen,
  output logic [63:0] d_din,
  output logic [7:0]  d_be,
  input  logic        d_wnext,
  input  logic        d_rvalid,
  input  logic        d_ack,
  input  logic [63:0] d_dout,

  output logic [31:0] dbg_reads,
  output logic [31:0] dbg_writes,
  output logic [15:0] dbg_wr_lost,
  output logic [15:0] dbg_rd_dropped   // answers withheld: the port had moved on
);

  // A sheet word's place in the mirror: its DDR3 word, and which lane.
  function automatic logic [24:0] dword_of(input logic [AW:1] a);
    logic [AW:1] off;
    begin
      off      = a - SBASE;
      dword_of = TBASE + 25'(off[20:3]);   // off counts 16-bit words from bit 1
    end
  endfunction

  // ================================================================ reads
  // clk_mem side, per port.
  logic        q_tog  [2];      // toggles once per request sent
  logic        q_pend [2];      // a request is out and its answer is not back
  logic [AW:1] q_addr [2];      // the line asked for, held until the answer
  logic [2:0]  a_sync [2];      // the answer toggle, synchronised
  // clk side, per port.
  logic [2:0]  q_sync [2];
  logic        a_tog  [2];
  logic [63:0] a_data [2];      // held from the answer until the next request
  logic        want   [2];

  genvar p;
  generate for (p = 0; p < 2; p++) begin : g_port
    always_ff @(posedge clk_mem or negedge rst_n) begin
      if (!rst_n) begin
        q_tog[p] <= 1'b0; q_pend[p] <= 1'b0; q_addr[p] <= '0; a_sync[p] <= 3'd0;
        r_ack[p] <= 1'b0;
      end else begin
        a_sync[p] <= {a_sync[p][1:0], a_tog[p]};
        r_ack[p]  <= 1'b0;
        if (q_pend[p]) begin
          if (a_sync[p][2] ^ a_sync[p][1]) begin
            q_pend[p] <= 1'b0;
            // Answer only the request that was fetched. a_data is stable: the
            // clk side changes it only after the next request arrives.
            if (r_req[p] && r_addr[p] == q_addr[p]) r_ack[p] <= 1'b1;
          end
        end else if (r_req[p] && !r_ack[p]) begin
          q_addr[p] <= r_addr[p];
          q_tog[p]  <= ~q_tog[p];
          q_pend[p] <= 1'b1;
        end
      end
    end
    assign r_data[p] = a_data[p];
  end endgenerate

  // =============================================================== writes
  typedef struct packed { logic [24:0] a; logic [1:0] lane; logic [15:0] d; logic [1:0] be; } w_t;
  w_t                        wq [QD];
  logic [$clog2(QD):0]       wq_wp, wq_rp;
  wire                       wq_empty = (wq_wp == wq_rp);
  wire                       wq_full  = ((wq_wp - wq_rp) == ($clog2(QD)+1)'(QD));
  wire  [AW:1]               w_off    = w_addr - SBASE;

  // ============================================================= issuer
  typedef enum logic [1:0] { I_IDLE, I_RD, I_WR } ist_t;
  ist_t       ist;
  logic       ip;               // the port being read
  logic       wd_sent;          // R640 lesson: the write beat has been taken

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < 2; k++) begin q_sync[k] <= 3'd0; a_tog[k] <= 1'b0; a_data[k] <= '0; want[k] <= 1'b0; end
      wq_wp <= '0; wq_rp <= '0;
      ist <= I_IDLE; ip <= 1'b0; wd_sent <= 1'b0;
      d_req <= 1'b0; d_we <= 1'b0; d_addr <= '0; d_blen <= 8'd1; d_din <= '0; d_be <= '0;
      dbg_reads <= '0; dbg_writes <= '0; dbg_wr_lost <= '0; dbg_rd_dropped <= '0;
    end else begin
      for (int k = 0; k < 2; k++) begin
        q_sync[k] <= {q_sync[k][1:0], q_tog[k]};
        if (q_sync[k][2] ^ q_sync[k][1]) want[k] <= 1'b1;
      end

      // the write queue: a completed CPU write into either sheet
      if (w_valid && w_addr >= SBASE && w_off < AW'(32'h100000)) begin
        if (!wq_full) begin
          wq[wq_wp[$clog2(QD)-1:0]] <= '{a: dword_of(w_addr), lane: w_off[2:1], d: w_data, be: w_be};
          wq_wp <= wq_wp + 1'd1;
        end else if (!(&dbg_wr_lost)) dbg_wr_lost <= dbg_wr_lost + 16'd1;
      end

      case (ist)
        // Reads before writes: a read has a renderer waiting on it.
        I_IDLE: begin
          if (want[0] || want[1]) begin
            ip     <= want[0] ? 1'b0 : 1'b1;
            d_req  <= 1'b1; d_we <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= dword_of(want[0] ? q_addr[0] : q_addr[1]);   // stable: held on clk_mem
            ist    <= I_RD;
          end else if (!wq_empty) begin
            d_req  <= 1'b1; d_we <= 1'b1; d_blen <= 8'd1;
            d_addr <= wq[wq_rp[$clog2(QD)-1:0]].a;
            d_din  <= {4{wq[wq_rp[$clog2(QD)-1:0]].d}};
            d_be   <= 8'({wq[wq_rp[$clog2(QD)-1:0]].be[1], wq[wq_rp[$clog2(QD)-1:0]].be[0]})
                      << (2 * wq[wq_rp[$clog2(QD)-1:0]].lane);
            wd_sent <= 1'b0;
            ist    <= I_WR;
          end
        end
        I_RD: begin
          if (d_rvalid) a_data[ip] <= d_dout;
          if (d_ack) begin
            d_req <= 1'b0;
            want[ip]  <= 1'b0;
            a_tog[ip] <= ~a_tog[ip];
            if (!(&dbg_reads)) dbg_reads <= dbg_reads + 1'd1;
            ist <= I_IDLE;
          end
        end
        I_WR: begin
          if (d_wnext) wd_sent <= 1'b1;
          if (d_ack) begin
            d_req <= 1'b0;
            wq_rp <= wq_rp + 1'd1;
            if (!(&dbg_writes)) dbg_writes <= dbg_writes + 1'd1;
            ist <= I_IDLE;
          end
        end
        default: ist <= I_IDLE;
      endcase
    end
  end

  // dbg_rd_dropped is counted on the clk_mem side in a fuller version; the
  // answer-withheld case is rare (a slot timing out) and visible as dbg_lost
  // in m2_texel_bl, so it is left at zero here rather than crossing a counter.
  wire _unused = &{1'b0, wd_sent};

endmodule
