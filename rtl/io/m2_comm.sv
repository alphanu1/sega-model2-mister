// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE COMMUNICATION BOARD (837-10537, Daytona USA Revision A), FOR LINK PLAY.
// Study R916; the shape is R863's addendum.
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
// and 3 ("no id, no count yet"). THIS BLOCK DOES ALL OF THAT ITSELF, before
// the CPU's next access to the RAM completes, so what the game reads back
// does not depend on how quickly anything else answers. zfg (FG bit 7) is
// the board's: it flips when a frame arrives.
//
// WHERE IT LIVES. The RAM is in DDR3 (no M10K is free: 553/553), at byte
// 0x30800000 -- 8 MB above the 3D framebuffer, which ends below 0x30200000.
// Two more 64-bit words follow it, and they are the whole interface to the
// Linux helper (linux/m2link) that runs the ring protocol and the sockets:
//
//   0x30804000  STATUS, written by this block whenever one of its fields
//               changes:  [7:0] game vblanks, [15:8] FG reads, [23:16] CN
//               writes, [24] cn, [25] fg, [26] the zfg FG reads now return,
//               [39:32] video frames (heartbeat), [47:40] version 1,
//               [63:48] 0x4B4C ("LK")
//   0x30804008  MAILBOX, written by the helper: [0] zfg
//
// The helper maps the same physical page through /dev/mem. Nothing else
// crosses: no kernel change, no HPS bridge, no framework change.
//
// FG READS ARE ANSWERED AT ONCE, from a copy of zfg at most GAP cycles old.
// A linked Daytona spins on FG -- MAME showed ~150 reads a frame on a master
// and ~3,000 on a slave -- and a DDR3 round trip on every one would hand the
// port to the spin. The copy is refreshed (one read of the mailbox) on an FG
// read once it is GAP cycles old; the status word's FG-read count, which
// tells the helper the game is waiting, is held back to the same pace.
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
  parameter int          GAP_BITS     = 10           // 1,024 cycles, 12.8 us at 80 MHz
) (
  input  logic        clk,
  input  logic        rst_n,        // memory-level: DDR3 usable (m2_ddr3's reset)
  input  logic        game_rst_n,   // the game's reset: cn and fg to 0, as device_reset
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

  localparam logic [23:0] MAGIC_HI  = {16'h4B4C, 8'h01};   // [63:40]

  // ------------------------------------------------------------- decode
  wire is_ram = (addr[15:14] == 2'b00);
  wire is_reg = (addr[15:2] == 14'h1000);       // 0x4000-0x4003
  wire hit    = sel && fitted;
  wire ram_rd = hit && is_ram && !we;
  wire ram_wr = hit && is_ram &&  we;
  wire reg_wr = hit && is_reg &&  we;
  wire fg_rd  = hit && is_reg && !we && be[2];

  // The game's reset is a reset elsewhere (asynchronous); here it is data,
  // so it is brought into clk first.
  logic [1:0] grst_s;
  always_ff @(posedge clk) grst_s <= {grst_s[0], game_rst_n};
  wire game_run = grst_s[1];

  // ------------------------------------------------------------- registers
  logic cn, fg, zfg_q;
  logic [7:0] tick_cnt, fgrd_cnt, cnwr_cnt, hb_cnt;
  wire  zfg = zfg_q;               // cn_w(0) sets it 0, and it is not refreshed until cn_w(1)

  wire [7:0] cn_r = {7'h7f, cn};
  wire [7:0] fg_r = {~zfg, 6'h3f, fg};

  // ------------------------------------------------------------- the FSM
  typedef enum logic [2:0] { S_IDLE, S_WR, S_RD, S_RDONE, S_FILL, S_STW, S_ZRD } st_t;
  st_t st;

  logic        fill_pend, fill_rst, fill_hdr;
  logic  [4:0] fill_blk;            // 0..15 the RAM, 16 status+mailbox (power-on only)
  logic  [6:0] fill_beat;
  logic [GAP_BITS-1:0] gap;
  logic        st_dirty, st_urgent, z_want;
  logic [31:0] wd_r;
  logic [34:0] st_snap;             // the status word's live fields, as it is sent
  logic [31:0] rd_r;
  logic        rd_lane;

  // RAM accesses complete only from S_IDLE (a write is posted) or S_RDONE
  // (a read's data is here). Registers and the rest of the window answer at
  // once, busy or not.
  assign stall = hit && is_ram && !(we ? (st == S_IDLE && !fill_pend) : (st == S_RDONE));
  assign rdata = !is_ram ? (is_reg ? {8'h00, fg_r, 8'h00, cn_r} : 32'h0) : rd_r;

  assign dbg_cn  = cn;
  assign dbg_zfg = zfg;

  // The header the init command writes, as two little-endian 64-bit words:
  // bytes 0-7 = 00 02 ff ff 00 00 00 00, bytes 0x10-0x17 = 00 00 00 0e
  // (FRAME_OFFSET) 00 00.
  wire [63:0] HDR0 = 64'h0000_0000_ffff_0200;
  wire [63:0] HDR2 = {16'h0000, FRAME_OFFSET, 32'h0e00_0000};

  always_comb begin
    d_din = 64'd0;
    case (st)
      S_WR:   d_din = {wd_r, wd_r};
      S_FILL: if (fill_hdr && fill_blk == 5'd0)
                d_din = (fill_beat == 7'd0) ? HDR0 : (fill_beat == 7'd2) ? HDR2 : 64'd0;
      S_STW:  d_din = {MAGIC_HI, st_snap[34:27], 5'd0, st_snap[26:0]};
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE;
      d_req <= 1'b0; d_we <= 1'b0; d_addr <= '0; d_blen <= 8'd1; d_be <= 8'hFF;
      cn <= 1'b0; fg <= 1'b0; zfg_q <= 1'b0;
      tick_cnt <= '0; fgrd_cnt <= '0; cnwr_cnt <= '0; hb_cnt <= '0;
      fill_pend <= 1'b1; fill_rst <= 1'b1; fill_hdr <= 1'b0;   // POWER-ON: clear it all, as MAME's m_shared{}
      fill_blk <= 5'd0; fill_beat <= 7'd0;
      gap <= '0; st_dirty <= 1'b0; st_urgent <= 1'b0; z_want <= 1'b0;
      wd_r <= '0; st_snap <= '0; rd_r <= '0;
    end else begin
      if (gap != 0) gap <= gap - 1'b1;

      // ---- events that make the status word stale
      if (fitted && tick)  begin tick_cnt <= tick_cnt + 8'd1; st_dirty <= 1'b1; st_urgent <= 1'b1; end
      if (fitted && frame) begin hb_cnt   <= hb_cnt   + 8'd1; st_dirty <= 1'b1; st_urgent <= 1'b1; end

      // ---- the registers, at once
      if (!game_run) begin
        cn <= 1'b0; fg <= 1'b0; zfg_q <= 1'b0;   // device_reset: zfg, cn, fg = 0
        if (cn | fg) begin cnwr_cnt <= cnwr_cnt + 8'd1; st_dirty <= 1'b1; st_urgent <= 1'b1; end
      end else if (reg_wr) begin
        // cn_w then fg_w, as the recomp's dev_write does for one dword
        if (be[0]) begin
          cn <= wdata[0];
          cnwr_cnt <= cnwr_cnt + 8'd1;
          if (!wdata[0]) begin
            zfg_q <= 1'b0;
            if (!be[2]) fg <= 1'b0;    // reset command: cn = fg = zfg = 0
          end else begin
            fill_pend <= 1'b1; fill_hdr <= 1'b1; fill_rst <= 1'b0;   // init command
          end
        end
        if (be[2]) fg <= wdata[16];
        st_dirty <= 1'b1; st_urgent <= 1'b1;
      end
      if (fg_rd) begin
        fgrd_cnt <= fgrd_cnt + 8'd1;
        st_dirty <= 1'b1;
        if (cn) z_want <= 1'b1;
      end

      case (st)
        S_IDLE: begin
          // The CPU first, then the clear, then a status word with news
          // (CN, FG, a vblank), then zfg, then a status word with only FG
          // reads in it.
          if (ram_wr && !fill_pend) begin
            wd_r   <= wdata;
            d_we   <= 1'b1; d_blen <= 8'd1;
            d_addr <= BASE + 25'(addr[13:3]);
            d_be   <= addr[2] ? {be, 4'b0000} : {4'b0000, be};
            d_req  <= 1'b1;
            st     <= S_WR;
          end else if (ram_rd && !fill_pend) begin
            d_we   <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= BASE + 25'(addr[13:3]);
            d_req  <= 1'b1;
            st     <= S_RD;
          end else if (fill_pend) begin
            d_we   <= 1'b1; d_be <= 8'hFF;
            if (fill_rst && fill_blk == 5'd16) begin
              d_blen <= 8'd2; d_addr <= BASE + 25'h800;
            end else begin
              d_blen <= 8'd128; d_addr <= BASE + 25'({fill_blk[3:0], 7'd0});
            end
            fill_beat <= 7'd0;
            d_req  <= 1'b1;
            st     <= S_FILL;
          end else if (z_want && gap == 0 && !st_urgent) begin
            // zfg before a status word that only carries FG reads: the spin
            // that makes both is waiting on this one
            z_want <= 1'b0;
            d_we   <= 1'b0; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= BASE + 25'h801;
            d_req  <= 1'b1;
            gap    <= '1;
            st     <= S_ZRD;
          end else if (fitted && st_dirty && (st_urgent || gap == 0)) begin
            st_snap <= {hb_cnt, zfg_q, fg, cn, cnwr_cnt, fgrd_cnt, tick_cnt};
            st_dirty <= 1'b0; st_urgent <= 1'b0;
            d_we   <= 1'b1; d_blen <= 8'd1; d_be <= 8'hFF;
            d_addr <= BASE + 25'h800;
            d_req  <= 1'b1;
            if (!st_urgent) gap <= '1;   // news goes at once and holds nothing up
            st     <= S_STW;
          end
        end

        S_WR, S_STW: if (d_ack) begin d_req <= 1'b0; st <= S_IDLE; end

        S_RD: begin
          if (d_rvalid) rd_r <= rd_lane ? d_dout[63:32] : d_dout[31:0];
          if (d_ack) begin d_req <= 1'b0; st <= S_RDONE; end
        end

        // One cycle: the bridge, held by stall, has its select up now and
        // takes rd_r on this edge.
        S_RDONE: st <= S_IDLE;

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
              st_dirty  <= 1'b1; st_urgent <= 1'b1;   // CN's count is seen after the clear
            end else fill_blk <= fill_blk + 5'd1;
          end
        end

        S_ZRD: begin
          if (d_rvalid) begin
            zfg_q <= d_dout[0] & cn;
            if ((d_dout[0] & cn) != zfg_q) st_dirty <= 1'b1;   // m2link waits to see it taken
          end
          if (d_ack) begin d_req <= 1'b0; st <= S_IDLE; end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  // The lane of the read in flight, latched with it.
  always_ff @(posedge clk) if (st == S_IDLE && ram_rd) rd_lane <= addr[2];

endmodule
