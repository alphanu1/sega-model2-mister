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
// R924: THE TGPx4 ON THE 2C COPROCESSOR BOARD -- tgpx4_core and the board
// logic that m2_copro's ports need, in place of m2_tgp (M2_2C builds only).
//
// What the board gives the MB86235 (MAME 0.289 model2c_state):
//   * its program, 4 K x 64, uploaded by the i960 as dword PAIRS through the
//     FIFO port while copro_ctl1 bit 31 is set (copro_fifo_w: dword n is the
//     low half of word n/2 when even, the high half when odd);
//   * its external bus, 24-bit word addresses (copro_tgpx4_data_map):
//       0x400000-0x7fffff  buffer RAM, 32 K words, mirrored (& 0x7fff)
//       0x800000-0x9fffff  the copro data ROM ("TGPx4 program" region, 8 MB)
//     anything else is unmapped: reads 0, writes dropped (House of the Dead
//     writes 0 to 0x00002c once, after boot -- R924's capture).
//
// THE PROGRAM IS HELD TWICE when PLINES < 4096: tgpx4_pmem's direct-mapped
// line cache, and a copy in SDRAM the cache refills from (R920). The upload
// writes both, so no flush is ever needed. The SDRAM copy is written through
// the shared write port (bufw, two 16-bit halves a dword, `bufw_is_prog`)
// and read back through port 9 (`dat_is_prog`, a dword at a time, two per
// line); the top level puts it at GAME_X4PROG. An upload dword is held off
// (`up_busy`, m2_copro's `stall`) until the previous one's halves have landed.
//
// All three users of port 9 -- data ROM reads, buffer RAM reads, cache
// refills -- and both users of the write port go through one sequencer, one
// request at a time, with an idle clock between requests (the shared port
// takes a level, acknowledges it once, and needs it to fall: m2_tgp's own
// finding, R133).

`timescale 1ns/1ps

module m2_tgpx4 #(
  parameter int unsigned PLINES  = 1024,
  parameter bit          SUBNORM = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        run,          // booted (copro_ctl1 bit 31 has fallen once)

  // upload, one i960 dword at a time
  input  logic        up_we,
  input  logic [12:0] up_idx,
  input  logic [31:0] up_data,
  output logic        up_busy,

  // FIFOs (m2_copro's)
  input  logic [31:0] fi_data,
  input  logic        fi_valid,
  input  logic        fi_full,
  output logic        fi_pop,
  output logic [31:0] fo_data,
  output logic        fo_push,
  input  logic        fo_full,
  input  logic        fo_empty,

  // port 9: data ROM, buffer RAM, program copy (reads)
  output logic        dat_req,
  output logic [19:0] dat_addr,
  output logic        dat_is_buf,
  output logic        dat_is_prog,
  input  logic [31:0] dat_rdata,
  input  logic        dat_ack,
  // the shared write port: buffer RAM, program copy (16-bit halves)
  output logic        bufw_req,
  output logic [18:0] bufw_addr,
  output logic [15:0] bufw_data,
  output logic        bufw_is_prog,
  input  logic        bufw_ack,

  output logic [11:0] dbg_pc,
  output logic        dbg_retire,
  output logic [31:0] dbg_pdr,
  output logic        dbg_bad
);

  // ======================================================== the processor
  logic        prog_we;
  logic [11:0] prog_addr;
  logic [63:0] prog_data;
  logic        pf_req, pf_ack;
  logic [11:0] pf_addr;
  logic [63:0] pf_data;
  logic        ext_req, ext_we, ext_ack;
  logic [23:0] ext_addr;
  logic [31:0] ext_wdata, ext_rdata;

  tgpx4_core #(.PLINES(PLINES), .SUBNORM(SUBNORM)) u_core (
    .clk(clk), .rst_n(rst_n), .run(run),
    .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
    .pf_req(pf_req), .pf_addr(pf_addr), .pf_data(pf_data), .pf_ack(pf_ack),
    .fi_data(fi_data), .fi_valid(fi_valid), .fi_full(fi_full), .fi_pop(fi_pop), .fi_clr(),
    .fo_data(fo_data), .fo_push(fo_push), .fo_full(fo_full), .fo_empty(fo_empty), .fo_clr(),
    .ext_req(ext_req), .ext_we(ext_we), .ext_addr(ext_addr), .ext_wdata(ext_wdata),
    .ext_rdata(ext_rdata), .ext_ack(ext_ack),
    .dbg_pc(dbg_pc), .dbg_retire(dbg_retire), .dbg_pdr(dbg_pdr), .dbg_bad(dbg_bad)
  );

  // ======================================================== the upload
  // The low dword of a pair waits here for its high dword; the pair is one
  // program word. Each dword is also written to the SDRAM copy (2 halves).
  logic [31:0] up_lo;
  logic        upw_v;                  // an upload dword waiting for the write port
  logic [12:0] upw_idx;
  logic [31:0] upw_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      up_lo <= 32'd0; prog_we <= 1'b0; prog_addr <= 12'd0; prog_data <= 64'd0;
    end else begin
      prog_we <= 1'b0;
      if (up_we) begin
        if (!up_idx[0]) up_lo <= up_data;
        else begin
          prog_we   <= 1'b1;
          prog_addr <= up_idx[12:1];
          prog_data <= {up_data, up_lo};
        end
      end
    end
  end

  // ======================================================== the sequencer
  // One request at a time on each port, an idle clock after each.
  typedef enum logic [2:0] { Q_IDLE, Q_RD, Q_WR, Q_GAP } q_e;
  q_e          q;
  logic        q_ext;                  // this read / write is the core's (else fill / upload)
  logic        f_hi;                   // fill: which dword of the line
  logic [31:0] f_lo;
  logic        w_hi;                   // write: which 16-bit half
  logic [31:0] w_data;
  logic [18:0] w_addr;                 // without the half bit
  logic        w_prog;

  // the core's external address
  wire x_buf = (ext_addr[23:22] == 2'b01);                      // 0x400000-0x7fffff
  wire x_rom = (ext_addr[23:21] == 3'b100);                     // 0x800000-0x9fffff
  logic ext_done;                                               // acknowledged, until req falls

  assign up_busy = upw_v | up_we;   // the dword in this clock counts (m2_copro presents the next a clock later)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= Q_IDLE; q_ext <= 1'b0; f_hi <= 1'b0; f_lo <= 32'd0; w_hi <= 1'b0;
      w_data <= 32'd0; w_addr <= 19'd0; w_prog <= 1'b0;
      dat_req <= 1'b0; dat_addr <= 20'd0; dat_is_buf <= 1'b0; dat_is_prog <= 1'b0;
      bufw_req <= 1'b0; bufw_addr <= 19'd0; bufw_data <= 16'd0; bufw_is_prog <= 1'b0;
      ext_ack <= 1'b0; ext_rdata <= 32'd0; ext_done <= 1'b0;
      pf_ack <= 1'b0; pf_data <= 64'd0;
      upw_v <= 1'b0; upw_idx <= 13'd0; upw_data <= 32'd0;
    end else begin
      ext_ack <= 1'b0; pf_ack <= 1'b0;
      if (!ext_req) ext_done <= 1'b0;
      if (up_we) begin upw_v <= 1'b1; upw_idx <= up_idx; upw_data <= up_data; end

      case (q)
        Q_IDLE: begin
          if (ext_req && !ext_done) begin
            q_ext <= 1'b1;
            if (ext_we) begin
              if (x_buf) begin
                w_data <= ext_wdata; w_addr <= {3'd0, ext_addr[14:0], 1'b0}; w_prog <= 1'b0; w_hi <= 1'b0;
                bufw_req <= 1'b1; bufw_addr <= {3'd0, ext_addr[14:0], 1'b0}; bufw_data <= ext_wdata[15:0];
                bufw_is_prog <= 1'b0;
                q <= Q_WR;
              end else begin                          // unmapped / ROM: dropped
                ext_ack <= 1'b1; ext_done <= 1'b1; q <= Q_GAP;
              end
            end else if (x_buf || x_rom) begin
              dat_req <= 1'b1; dat_is_buf <= x_buf; dat_is_prog <= 1'b0;
              dat_addr <= x_buf ? {5'd0, ext_addr[14:0]} : ext_addr[19:0];
              q <= Q_RD;
            end else begin                            // unmapped: 0
              ext_rdata <= 32'd0; ext_ack <= 1'b1; ext_done <= 1'b1; q <= Q_GAP;
            end
          end else if (pf_req && !pf_ack) begin
            q_ext <= 1'b0;
            dat_req <= 1'b1; dat_is_buf <= 1'b0; dat_is_prog <= 1'b1;
            dat_addr <= {7'd0, pf_addr, f_hi};
            q <= Q_RD;
          end else if (upw_v) begin
            q_ext <= 1'b0;
            w_data <= upw_data; w_addr <= {5'd0, upw_idx, 1'b0}; w_prog <= 1'b1; w_hi <= 1'b0;
            bufw_req <= 1'b1; bufw_addr <= {5'd0, upw_idx, 1'b0}; bufw_data <= upw_data[15:0];
            bufw_is_prog <= 1'b1;
            q <= Q_WR;
          end
        end
        Q_RD: if (dat_ack) begin
          dat_req <= 1'b0;
          if (q_ext) begin
            ext_rdata <= dat_rdata; ext_ack <= 1'b1; ext_done <= 1'b1;
          end else if (!f_hi) begin
            f_lo <= dat_rdata; f_hi <= 1'b1;
          end else begin
            pf_data <= {dat_rdata, f_lo}; pf_ack <= 1'b1; f_hi <= 1'b0;
          end
          q <= Q_GAP;
        end
        Q_WR: if (bufw_ack) begin
          bufw_req <= 1'b0;
          if (!w_hi) begin
            w_hi <= 1'b1;
            q <= Q_GAP;                               // the high half after a gap
          end else begin
            w_hi <= 1'b0;
            if (q_ext) begin ext_ack <= 1'b1; ext_done <= 1'b1; end
            else upw_v <= up_we;                      // (a new dword in this clock stays)
            q <= Q_GAP;
          end
        end
        Q_GAP: begin
          if (w_hi) begin                             // raise the high half
            bufw_req <= 1'b1; bufw_addr <= w_addr | 19'd1; bufw_data <= w_data[31:16];
            bufw_is_prog <= w_prog;
            q <= Q_WR;
          end else q <= Q_IDLE;
        end
        default: q <= Q_IDLE;
      endcase
    end
  end

endmodule
