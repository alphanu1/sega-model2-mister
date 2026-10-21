// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE COMMUNICATION BOARD (837-10537, Daytona USA Revision A), FOR LINK PLAY.
// Study R916 (and its addenda); the shape is R863's addendum.
//
// WHAT THE GAME SEES, from the recomp's src/runtime/comm_board.{h,cpp} and
// m2_board.cpp (the reference for link play -- itself MAME's m2comm in its
// M2COMM_SIMULATION mode, BSD-3, Ariane Fugmann):
//
//   0x01a00000-0x01a03fff  16 KB shared RAM, mirrored at 0x01a10000
//   0x01a04000 byte 0      CN: read cn | 0xfe; write bit 0 -- 0 resets the
//                          board, 1 starts it (the init command)
//   0x01a04002 byte 2      FG: read fg | ~zfg << 7 | 0x7e; write fg = bit 0
//                          (1 = this cabinet is the link's master)
//
// The init command (cn_w(1)) clears the 16 KB, writes 0x02 at byte 1, the
// frame size 0x0e00 at bytes 0x12-0x13 and the frame offset (0x01c0) at
// 0x14-0x15, and -- through the comm_tick() it ends with -- 0xff at bytes 2
// and 3. THIS BLOCK DOES ALL OF THAT ITSELF, before the CPU's next access to
// the RAM completes.
//
// WHEN THE GAME SEES A FRAME (R916 addendum 2). In the recomp the board acts
// only inside the game: at vblank (comm_tick) and at the game's FG reads
// (read_fg, except the two after a vblank: zfg_delay). A received frame is
// stored and zfg flips there, and a slave answers with its own block as it
// stands at that moment. This block keeps exactly those points:
//
//   * m2link (the Linux helper) receives frames and writes each block into
//     the rx area of a SECOND bank (0x21c0-0x2fbf has two copies; the game
//     reads the one `rxbank` names), then OFFERS it in the mailbox: a
//     sequence number, the bank, whether zfg flips (the parity of the frames
//     it carries) and whether a vsync token (0xfc) came with it.
//   * The offer is TAKEN here, at a vblank or at an FG read past zfg_delay:
//     the game's own 0x1c0-byte block (0x2000-0x21bf) is first copied to a
//     snapshot buffer, then the bank swaps and zfg flips in one cycle, and
//     the status word says so. The FG read that takes it returns the new
//     zfg; the game cannot see a half-written slot, and m2link sends the
//     snapshot, not the block the game is rewriting.
//   * Every vblank the same copy goes to the tick snapshot (the master's
//     block for the frame it sends).
//
// LINK_FRAMESYNC (the recomp's linktimer). With it on (a mailbox bit), each
// vblank sets fs_wait; a taken vsync token clears it. While it is set, an FG
// read past zfg_delay is HELD (io_stall) -- read_fg's wait -- and a vblank
// that finds it still set is deferred and the game's next FG read held until
// the token comes -- comm_tick's wait. Only the i960 waits: video, sound and
// the rest of the core run on. A held read gives up after TMO_FRAMES video
// frames, so a dead link cannot freeze the core.
//
// WHERE IT LIVES (DDR3, byte addresses; 64-bit words relative to BASE):
//   0x30800000  word 0x000  the 16 KB shared RAM (bank 0 of the rx area)
//   0x30804000  word 0x800  STATUS, written here when a field changes:
//       [7:0] vblanks processed (tick events) [15:8] the offer taken last
//       [23:16] the offer taken at the last tick [31:24] CN writes
//       [32] cn [33] fg [34] zfg [35] rxbank [36] fs_wait [37] a tick held
//       [38] the last offer was taken at a vblank (its snapshot is the tick's)
//       [47:40] video frames (heartbeat) [55:48] version 2 [63:56] 'L'
//   0x30804008  word 0x801  MAILBOX, written by m2link: [7:0] offer
//       [8] its bank [9] zfg flips [10] it holds a vsync token [11] linked
//       [12] link_framesync [13] flip zfg every vblank (not linked yet,
//       both sockets up: comm_tick's zfg ^= 1)
//   0x30804800  word 0x900  tick snapshot, 56 words (0x2000-0x21bf)
//   0x30804c00  word 0x980  take snapshot, 56 words
//   0x30808000  word 0x1000 bank 1 (its rx area at word 0x1438-0x15f7)
//
// Off (fitted = 0, the OSD's "Link board: Off"), the block is not there: the
// core answers this window as it always has, 0 and writes dropped, and the
// only DDR3 traffic is the power-on clear.

`timescale 1ns/1ps

module m2_comm #(
  // DDR3 word address of the shared RAM, relative to the m2_ddr3 base (the
  // framebuffer's, word 0x0600_0000 = byte 0x30000000): byte 0x30800000.
  parameter logic [24:0] BASE         = 25'h010_0000,
  parameter logic [15:0] FRAME_OFFSET = 16'h01c0,   // comm_board.h's default; Daytona's
  parameter int          GAP_BITS     = 10,          // mailbox refresh pace, 1,024 cycles
  parameter int          TMO_FRAMES   = 48           // a held FG read gives up (~0.8 s)
) (
  input  logic        clk,
  input  logic        rst_n,        // memory-level: DDR3 usable (m2_ddr3's reset)
  input  logic        game_rst_n,   // the game's reset: cn, fg, zfg to 0, as device_reset
  input  logic        fitted,       // the OSD switch; 0 = no board

  // ---- the CPU, through the bridge's I/O port (clk)
  input  logic        sel,          // io_sel within 0x01a00000-0x01a1ffff
  input  logic        we,
  // verilator lint_off UNUSEDSIGNAL
  input  logic [15:0] addr,         // byte offset in the window (bit 16, the mirror, dropped)
  // verilator lint_on UNUSEDSIGNAL
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  output logic        stall,

  input  logic        tick,         // one clk: the vblank the game sees (its interrupt)
  input  logic        frame,        // one clk: every video frame (the helper's heartbeat)

  // ---- DDR3, m2_ddr3's request/acknowledge (through m2_ddr3_arb)
  output logic        d_req,
  output logic        d_we,
  output logic [24:0] d_addr,
  output logic  [7:0] d_blen,
  output logic [63:0] d_din,
  output logic  [7:0] d_be,
  input  logic        d_wacc,
  input  logic        d_rvalid,
  input  logic        d_ack,
  input  logic [63:0] d_dout,

  output logic        dbg_cn,
  output logic        dbg_zfg
);

  localparam logic [24:0] W_STATUS = 25'h800, W_MBOX = 25'h801;
  localparam logic [24:0] W_SNAPT  = 25'h900, W_SNAPD = 25'h980, W_BANK1 = 25'h1000;
  localparam logic [24:0] W_TX     = 25'h400;              // 0x2000: the game's block
  localparam int          TX_WORDS = 56;                   // 0x1c0 bytes

  // ------------------------------------------------------------- decode
  wire is_ram  = (addr[15:14] == 2'b00);
  wire is_reg  = (addr[15:2] == 14'h1000);      // 0x4000-0x4003
  wire hit     = sel && fitted;
  wire ram_rd  = hit && is_ram && !we;
  wire ram_wr  = hit && is_ram &&  we;
  wire reg_wr  = hit && is_reg &&  we;
  wire fg_rd   = hit && is_reg && !we && be[2];
  wire rx_area = (addr[13:3] >= 11'h438) && (addr[13:3] < 11'h5f8);   // 0x21c0-0x2fbf

  // The game's reset is a reset elsewhere (asynchronous); here it is data.
  logic [1:0] grst_s;
  always_ff @(posedge clk) grst_s <= {grst_s[0], game_rst_n};
  wire game_run = grst_s[1];

  // ------------------------------------------------------------- state
  logic       cn, fg, zfg_q, rxbank, fs_wait, tick_pend, tick_req, take_tick;
  logic [1:0] zfg_delay;
  logic [7:0] mb_seq;
  logic       mb_bank, mb_flip, mb_tok, mb_linked, mb_fsync, mb_ttog;
  logic [7:0] taken_seq, taken_tick, tick_evt, cnwr_cnt, cnwr_pub, hb_cnt;
  logic [5:0] tmo;

  wire [7:0] cn_r = {7'h7f, cn};
  wire [7:0] fg_r = {~zfg_q, 6'h3f, fg};

  wire offer   = cn && (mb_seq != taken_seq);
  wire fs_hold = fs_wait && mb_fsync && mb_linked;

  typedef enum logic [3:0] { S_IDLE, S_WR, S_RD, S_RDONE, S_FILL, S_STW, S_MRD, S_CPR, S_CPW } st_t;
  st_t st;

  logic        fill_pend, fill_rst, fill_hdr;
  logic  [4:0] fill_blk;
  logic  [6:0] fill_beat;
  logic [GAP_BITS-1:0] gap;
  logic        st_dirty, z_want;
  logic        ev_act, ev_tick, ev_mb;     // an event; a tick event; its mailbox read done
  logic  [5:0] cp_i;
  logic [63:0] cp_d;
  logic [31:0] wd_r, rd_r;
  logic        rd_lane;

  // An FG read waits while: a vblank is still being processed or is held
  // (comm_tick runs before the game goes on), or -- past zfg_delay -- an
  // offer is to be taken or the framesync wait is on (read_fg).
  wire fg_blk = cn && (ev_act || tick_req || tick_pend || (zfg_delay == 2'd0 && (offer || fs_hold)));

  assign stall = hit && ((is_ram && !(we ? (st == S_IDLE && !fill_pend && !ev_act && !tick_req)
                                         : (st == S_RDONE)))
                         || (is_reg && !we && be[2] && fg_blk));
  assign rdata = !is_ram ? (is_reg ? {8'h00, fg_r, 8'h00, cn_r} : 32'h0) : rd_r;

  assign dbg_cn  = cn;
  assign dbg_zfg = zfg_q;

  wire [63:0] HDR0 = 64'h0000_0000_ffff_0200;
  wire [63:0] HDR2 = {16'h0000, FRAME_OFFSET, 32'h0e00_0000};

  always_comb begin
    d_din = 64'd0;
    case (st)
      S_WR:   d_din = {wd_r, wd_r};
      S_FILL: if (fill_hdr && fill_blk == 5'd0)
                d_din = (fill_beat == 7'd0) ? HDR0 : (fill_beat == 7'd2) ? HDR2 : 64'd0;
      S_STW:  d_din = {8'h4C, 8'h02, hb_cnt, 1'b0, take_tick, tick_pend, fs_wait, rxbank, zfg_q, fg, cn,
                       cnwr_pub, taken_tick, taken_seq, tick_evt};
      S_CPW:  d_din = cp_d;
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE;
      d_req <= 1'b0; d_we <= 1'b0; d_addr <= '0; d_blen <= 8'd1; d_be <= 8'hFF;
      cn <= 1'b0; fg <= 1'b0; zfg_q <= 1'b0; rxbank <= 1'b0; fs_wait <= 1'b0;
      tick_pend <= 1'b0; tick_req <= 1'b0; take_tick <= 1'b0; zfg_delay <= 2'd0;
      mb_seq <= '0; {mb_bank, mb_flip, mb_tok, mb_linked, mb_fsync, mb_ttog} <= '0;
      taken_seq <= '0; taken_tick <= '0; tick_evt <= '0; cnwr_cnt <= '0; cnwr_pub <= '0; hb_cnt <= '0;
      tmo <= '0;
      fill_pend <= 1'b1; fill_rst <= 1'b1; fill_hdr <= 1'b0;   // POWER-ON: clear it all
      fill_blk <= 5'd0; fill_beat <= 7'd0;
      gap <= '0; st_dirty <= 1'b0; z_want <= 1'b0;
      ev_act <= 1'b0; ev_tick <= 1'b0; ev_mb <= 1'b0; cp_i <= '0; cp_d <= '0;
      wd_r <= '0; rd_r <= '0; rd_lane <= 1'b0;
    end else begin
      if (gap != 0) gap <= gap - 1'b1;

      if (fitted && frame) begin hb_cnt <= hb_cnt + 8'd1; st_dirty <= 1'b1; end
      // The vblank: processed at once, or held while framesync waits.
      if (fitted && tick && cn) begin
        if (fs_hold) tick_pend <= 1'b1; else tick_req <= 1'b1;
      end

      // ---- an FG read: complete, or held (and what it is waiting for)
      if (fg_rd && !fg_blk) begin
        if (zfg_delay != 2'd0) zfg_delay <= zfg_delay - 2'd1;
        if (cn) z_want <= 1'b1;
      end
      if (fg_rd && fg_blk && !ev_act && !tick_req) begin
        if (fitted && frame) begin
          if (tmo == 6'(TMO_FRAMES)) fs_wait <= 1'b0;   // give up: the link can lose it, the core will not freeze
          else tmo <= tmo + 6'd1;
        end
      end else if (!fg_rd) tmo <= '0;

      // ---- the registers, at once
      if (!game_run) begin
        cn <= 1'b0; fg <= 1'b0; zfg_q <= 1'b0;   // device_reset
        fs_wait <= 1'b0; tick_pend <= 1'b0; tick_req <= 1'b0; zfg_delay <= 2'd0;
        if (cn | fg) begin cnwr_cnt <= cnwr_cnt + 8'd1; cnwr_pub <= cnwr_cnt + 8'd1; st_dirty <= 1'b1; end
      end else if (reg_wr) begin
        if (be[0]) begin
          cn <= wdata[0];
          cnwr_cnt <= cnwr_cnt + 8'd1;
          fs_wait <= 1'b0; tick_pend <= 1'b0; tick_req <= 1'b0; zfg_delay <= 2'd0;
          if (!wdata[0]) begin
            zfg_q <= 1'b0;
            if (!be[2]) fg <= 1'b0;                  // reset command: cn = fg = zfg = 0
            cnwr_pub <= cnwr_cnt + 8'd1;
          end else begin
            fill_pend <= 1'b1; fill_hdr <= 1'b1; fill_rst <= 1'b0;   // init command
            rxbank <= 1'b0;                          // the clear is bank 0's
            taken_seq <= mb_seq;                     // nothing offered before it counts
          end
        end
        if (be[2]) fg <= wdata[16];
        st_dirty <= 1'b1;
      end

      case (st)
        S_IDLE: begin
          if (fill_pend) begin
            d_we <= 1'b1; d_be <= 8'hFF;
            if (fill_rst && fill_blk == 5'd16) begin
              d_blen <= 8'd2; d_addr <= BASE + W_STATUS;
            end else begin
              d_blen <= 8'd128; d_addr <= BASE + 25'({fill_blk[3:0], 7'd0});
            end
            fill_beat <= 7'd0;
            d_req <= 1'b1;
            st    <= S_FILL;
          end else if (ev_act && ev_tick && !ev_mb) begin
            // a tick reads the mailbox fresh: comm_tick takes all that came
            d_we <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF; d_addr <= BASE + W_MBOX;
            d_req <= 1'b1;
            st <= S_MRD;
          end else if (ev_act && cp_i != 6'(TX_WORDS)) begin
            // the snapshot: the game's block, a word at a time
            d_we <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF; d_addr <= BASE + W_TX + 25'(cp_i);
            d_req <= 1'b1;
            st <= S_CPR;
          end else if (ev_act) begin
            // ---- APPLY, in one cycle: take the offer, then the tick
            if (cn && mb_seq != taken_seq) begin
              taken_seq <= mb_seq;
              rxbank <= mb_bank;
              take_tick <= ev_tick;   // which snapshot goes with it
            end
            if (cn) zfg_q <= zfg_q ^ ((mb_seq != taken_seq) & mb_flip) ^ (ev_tick & mb_ttog);
            if (ev_tick) begin
              tick_evt   <= tick_evt + 8'd1;
              taken_tick <= mb_seq;      // = the offer taken now, or the one before
              if (mb_linked) zfg_delay <= 2'd2;
              fs_wait <= mb_linked & mb_fsync;        // linktimer = framesync
            end else if (mb_seq != taken_seq && mb_tok) fs_wait <= 1'b0;   // 0xfc: linktimer = 0
            ev_act <= 1'b0; ev_mb <= 1'b0; cp_i <= '0;
            st_dirty <= 1'b1;
          end else if (tick_req && cn) begin
            tick_req <= 1'b0;
            ev_act <= 1'b1; ev_tick <= 1'b1; ev_mb <= 1'b0; cp_i <= '0;
          end else if (fg_rd && fg_blk && tick_pend && !fs_hold) begin
            // the held vblank, released by the token (or the timeout)
            tick_pend <= 1'b0;
            ev_act <= 1'b1; ev_tick <= 1'b1; ev_mb <= 1'b0; cp_i <= '0;
          end else if (fg_rd && fg_blk && offer) begin
            ev_act <= 1'b1; ev_tick <= 1'b0; ev_mb <= 1'b1; cp_i <= '0;
          end else if (ram_wr) begin
            wd_r   <= wdata;
            d_we   <= 1'b1; d_blen <= 8'd1;
            d_addr <= BASE + ((rx_area && rxbank) ? W_BANK1 : 25'd0) + 25'(addr[13:3]);
            d_be   <= addr[2] ? {be, 4'b0000} : {4'b0000, be};
            d_req  <= 1'b1;
            st     <= S_WR;
          end else if (ram_rd) begin
            d_we   <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= BASE + ((rx_area && rxbank) ? W_BANK1 : 25'd0) + 25'(addr[13:3]);
            rd_lane <= addr[2];
            d_req  <= 1'b1;
            st     <= S_RD;
          end else if (fitted && st_dirty) begin
            st_dirty <= 1'b0;
            d_we <= 1'b1; d_blen <= 8'd1; d_be <= 8'hFF; d_addr <= BASE + W_STATUS;
            d_req <= 1'b1;
            st <= S_STW;
          end else if (z_want && gap == 0) begin
            // the mailbox, at a pace: faster while a read is held waiting
            z_want <= 1'b0;
            d_we <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF; d_addr <= BASE + W_MBOX;
            d_req <= 1'b1;
            gap <= (fg_rd && fg_blk) ? GAP_BITS'(63) : '1;
            st <= S_MRD;
          end else if (fg_rd && fg_blk) z_want <= 1'b1;
        end

        S_WR, S_STW: if (d_ack) begin d_req <= 1'b0; st <= S_IDLE; end

        S_RD: begin
          if (d_rvalid) rd_r <= rd_lane ? d_dout[63:32] : d_dout[31:0];
          if (d_ack) begin d_req <= 1'b0; st <= S_RDONE; end
        end

        S_RDONE: st <= S_IDLE;   // the bridge, held by stall, takes rd_r on this edge

        S_MRD: begin
          if (d_rvalid) begin
            mb_seq <= d_dout[7:0];
            {mb_ttog, mb_fsync, mb_linked, mb_tok, mb_flip, mb_bank} <= d_dout[13:8];
          end
          if (d_ack) begin d_req <= 1'b0; ev_mb <= 1'b1; st <= S_IDLE; end
        end

        S_CPR: begin
          if (d_rvalid) cp_d <= d_dout;
          if (d_ack) begin
            d_req <= 1'b0;
            d_we <= 1'b1; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= BASE + (ev_tick ? W_SNAPT : W_SNAPD) + 25'(cp_i);
            st <= S_CPW;
          end
        end
        // m2_ddr3 drops ack for a cycle before it takes the next request
        // (R660), so the write is asked for one cycle on.
        S_CPW: begin
          if (!d_req && !d_ack) d_req <= 1'b1;
          if (d_req && d_ack) begin d_req <= 1'b0; cp_i <= cp_i + 6'd1; st <= S_IDLE; end
        end

        S_FILL: begin
          if (d_wacc) fill_beat <= fill_beat + 7'd1;
          if (d_ack) begin
            d_req <= 1'b0;
            st    <= S_IDLE;
            if (fill_blk == (fill_rst ? 5'd16 : 5'd15)) begin
              fill_blk  <= 5'd0;
              fill_pend <= 1'b0;
              fill_rst  <= 1'b0;
              fill_hdr  <= 1'b0;
              cnwr_pub  <= cnwr_cnt;                  // CN's count is seen after the clear
              st_dirty  <= 1'b1;
            end else fill_blk <= fill_blk + 5'd1;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
