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
// SEGA'S Z80 DIGITAL SOUND BOARD (MAME dsbz80.cpp), FOR SEGA TOURING CAR
// CHAMPIONSHIP ON MODEL 2C.
//
// From the Sega Model 1 core (sega-model1-mister 2657c46, rtl/sound/
// dsb_board.sv), where it is Star Wars Arcade's music board. The board is the
// same part: a Z80 at 4 MHz running the board's program (STCC: epr-19275.2s,
// first 32 KB at 0000-7fff, 32 KB of RAM at 8000-ffff), an i8251 at f0/f1
// that receives what the main board transmits, and an MPEG-1 Layer II player
// behind ports e0-e9 (STCC: 8 MB of MPEG data, mpr-19262..19265).
//
//   dsb_z80   the Z80, cut down to the opcodes the two programs use; on
//             Model 2 it takes IM 1 interrupts (STCC's program is
//             interrupt-driven: RxRDY is the Z80's INT, as MAME wires it)
//   m2_i8251  the UART, byte-level, the same model as the sound link's
//   dsb_mpeg  ports e0-e9 and the decoder
//
// WHAT CHANGED FROM MODEL 1, AND WHY (study R979):
//   - the SDRAM port follows m2_sdram_cdc's contract: the request is a LEVEL,
//     held with its address and data until the acknowledge, then dropped for
//     a cycle (Model 1's m1_cdc_port took a one-cycle pulse);
//   - addresses are SDR_AW wide (26 on the 128 MB 2C build) and the MPEG
//     data is 8 MB (MAW 22);
//   - the Z80's on-chip memory is ONE 1,024-byte block, not two programs'
//     worth (prog 1 K x 16 + fast 2 K x 8, four M10K): STCC's hot code
//     (CODE_BASE.., CODE_LEN bytes), its variables (VAR_BASE.., 128 bytes)
//     and the top of its stack (STK_BASE.., 128 bytes). Measured on the
//     bench (tb_dsb_z80): code 0000-0601, variables 9000-9026, lowest SP
//     fff8 (fff6 the worst the code can reach), and of the code fetches
//     94% are 0300-0601. Everything else stays in SDRAM behind the one-word
//     cache, exactly as Model 1 kept the cold parts there;
//   - a Z80 write to its ROM is dropped here (MAME's ROM drops it), where
//     Model 1 sent it to the SDRAM copy (neither program does it);
//   - irq into the Z80 (RxRDY & RxE).
// It is the same memory map, split by address, so nothing the program can
// observe changes: on chip or in SDRAM, a byte reads back what was written.

`timescale 1ns/1ps

module dsb_board #(
  parameter int unsigned AW = 26,                   // SDRAM word address [AW:1]
  parameter logic [AW:1] ROM_BASE  = AW'(32'h3400000),   // 128 KB, words
  parameter logic [AW:1] MPEG_BASE = AW'(32'h3000000),   // 8 MB
  parameter logic [AW:1] RAM_BASE  = AW'(32'h3410000),   // 32 KB
  parameter int unsigned MAW = 22,                  // MPEG word address bits
  // the on-chip block's three windows (byte addresses; CODE_BASE even)
  parameter logic [15:0] CODE_BASE = 16'h0380,
  parameter int unsigned CODE_LEN  = 768,           // bytes, <= 768
  parameter logic [15:0] VAR_BASE  = 16'h9000,      // 128 bytes
  parameter logic [15:0] STK_BASE  = 16'hff80,      // 128 bytes
  // the Z80's T clock from clk: 4 MHz = clk * T_NUM / T_DEN (clk_sys 80 MHz: 1/20)
  parameter int unsigned T_NUM = 1,
  parameter int unsigned T_DEN = 20,
  // 32 kHz from clk (80 MHz: 4 / 10,000)
  parameter int unsigned TICK_NUM = 4,
  parameter int unsigned TICK_DEN = 10000,
  // dsb_mpeg's bit-identical M10K shrinks and the Z80's dispatch-as-logic
  parameter bit FIFO_MLAB = 1'b1,
  parameter bit WRAM_MLAB = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // the main board's transmitted bytes, already paced at the line rate,
  // announced by a toggle
  input  logic        rx_tog,
  input  logic  [7:0] rx_byte,

  input  logic        vol_mame,

  // one SDRAM port, m2_sdram_cdc's slow side: a level held until s_ack
  output logic        s_req,
  output logic        s_we,
  output logic [AW:1] s_addr,
  output logic [15:0] s_din,
  output logic  [1:0] s_be,
  input  logic        s_ack,
  input  logic [15:0] s_dout,

  output logic signed [15:0] out_l,
  output logic signed [15:0] out_r,
  output logic        out_stb,

  output logic        dbg_trap,
  output logic [15:0] dbg_frames
);

  // ---------------------------------------------------------------- T clock
  logic [7:0] t_acc;
  logic       tick;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin t_acc <= '0; tick <= 1'b0; end
    // R1007: T_NUM 1 is a plain count to T_DEN (the same tick on the same clock)
    else if (T_NUM == 1) begin
      if (t_acc == 8'(T_DEN - 1)) begin t_acc <= '0; tick <= 1'b1; end
      else begin t_acc <= t_acc + 8'd1; tick <= 1'b0; end
    end
    else if (t_acc + 8'(T_NUM) >= 8'(T_DEN)) begin t_acc <= t_acc + 8'(T_NUM) - 8'(T_DEN); tick <= 1'b1; end
    else begin t_acc <= t_acc + 8'(T_NUM); tick <= 1'b0; end
  end

  // ---------------------------------------------------------------- Z80
  logic        z_req, z_we, z_ack;
  logic [15:0] z_addr;
  logic  [7:0] z_wdata, z_rdata;
  logic        io_rd, io_wr;
  logic  [7:0] io_addr, io_wdata, io_rdata;
  logic        u_irq;

  logic pre_done;
  dsb_z80 u_z80 (
    .clk(clk), .rst_n(rst_n && pre_done), .tick(tick),
    .m_req(z_req), .m_we(z_we), .m_addr(z_addr), .m_wdata(z_wdata),
    .m_ack(z_ack), .m_rdata(z_rdata),
    .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_wdata(io_wdata),
    .io_rdata(io_rdata), .irq(u_irq),
    .trap(dbg_trap), .trap_pc(), .trap_cnt(), .dbg_pc()
  );

  // ---------------------------------------------------------------- UART
  logic       rx_s1, rx_s2, rx_s3, rx_valid, rx_ack;
  logic [7:0] u_dout;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin {rx_s3, rx_s2, rx_s1} <= '0; rx_valid <= 1'b0; end
    else begin
      {rx_s3, rx_s2, rx_s1} <= {rx_s2, rx_s1, rx_tog};
      // rx_byte has been stable for a character time when the toggle lands
      if (rx_s2 ^ rx_s3) rx_valid <= 1'b1;
      else if (rx_ack)   rx_valid <= 1'b0;
    end
  end
  // read data is decoded from the address alone: dsb_z80 samples io_rdata the
  // cycle BEFORE its io_rd strobe, which is when the read's side effect lands
  wire u_adr = (io_addr[7:1] == 7'b1111000);
  wire u_sel = (io_rd || io_wr) && u_adr;
  m2_i8251 u_uart (
    .clk(clk), .rst_n(rst_n),
    .sel(u_sel), .we(io_wr), .addr(io_addr[0]), .din(io_wdata), .dout(u_dout),
    .data_o(), .stat_o(),
    .tx_data(), .tx_valid(), .tx_ack(1'b1),        // the DSB's echo goes nowhere (MAME: unrouted)
    .rx_data(rx_byte), .rx_valid(rx_valid), .rx_ack(rx_ack),
    .irq(), .irq_rx(u_irq), .irq_tx()
  );

  // ---------------------------------------------------------------- MPEG
  logic           mp_req, mp_ack;
  logic [MAW-1:0] mp_addr;
  logic  [7:0]    mp_q;
  wire            mp_sel = io_addr[7:4] == 4'he;
  dsb_mpeg #(.TICK_NUM(TICK_NUM), .TICK_DEN(TICK_DEN), .MAW(MAW),
             .FIFO_MLAB(FIFO_MLAB), .WRAM_MLAB(WRAM_MLAB)) u_mpeg (
    .clk(clk), .rst_n(rst_n),
    .reg_we(io_wr && mp_sel), .reg_a(io_addr[3:0]), .reg_d(io_wdata), .reg_q(mp_q),
    .vol_mame(vol_mame),
    .m_req(mp_req), .m_addr(mp_addr), .m_ack(mp_ack), .m_data(s_dout),
    .out_l(out_l), .out_r(out_r), .out_stb(out_stb), .out_src(),
    .smp_stb(), .smp_lr(), .dbg_frames(dbg_frames), .dbg_fails()
  );

  // unmapped ports read 0, as MAME's Z80 io space does
  assign io_rdata = u_adr ? u_dout : mp_sel ? mp_q : 8'h00;

  // ---------------------------------------------------------------- memory
  // ONE 1,024-BYTE BLOCK ON CHIP: the code window (a copy of the ROM, loaded
  // from SDRAM before the Z80 is released; the Z80's writes to it are dropped
  // as MAME's ROM drops them), the variables and the top of the stack.
  wire [15:0] c_off  = z_addr - CODE_BASE;
  wire        z_code = (z_addr < CODE_BASE + 16'(CODE_LEN)) && (z_addr >= CODE_BASE);
  wire        z_var  = (z_addr[15:7] == VAR_BASE[15:7]);
  wire        z_stk  = (z_addr[15:7] == STK_BASE[15:7]);
  wire        z_chip = z_code || z_var || z_stk;
  wire  [9:0] z_idx  = z_code ? c_off[9:0] : {2'b11, z_stk, z_addr[6:0]};
  wire        z_rom  = !z_addr[15];

  (* ramstyle = "M10K" *) logic [7:0] chip [1024];
  logic  [7:0] chip_q;
  logic  [9:0] pre_i;                // byte index of the copy
  logic        pre_we, pre_hi;
  logic        z_ack_r;
  logic [15:0] c_word;
  wire         chip_we = pre_we || (z_req && z_we && (z_var || z_stk) && !z_ack_r && pre_done);
  wire   [9:0] chip_wa = pre_we ? pre_i : z_idx;
  // R1007: the preload's word waits in the cache's word register (it was a
  // register of its own): the cache is not valid, and nothing reads it, until
  // the copy is done and the Z80 is out of reset
  wire   [7:0] chip_wd = pre_we ? (pre_hi ? c_word[15:8] : c_word[7:0]) : z_wdata;
  always_ff @(posedge clk) begin
    if (chip_we) chip[chip_wa] <= chip_wd;
    chip_q <= chip[z_idx];
  end

  // The one-word cache for the rest: the last word read or written. Writes go
  // straight through and update it.
  logic        c_valid;
  logic [15:1] c_tag;
  wire         c_hit = c_valid && (c_tag == z_addr[15:1]);

  typedef enum logic [1:0] {M_IDLE, M_Z, M_MP, M_PRE} mown_t;
  mown_t own;
  logic  z_src;                      // 0 cache, 1 the on-chip block
  assign z_ack   = z_ack_r;
  assign z_rdata = z_src ? chip_q : (z_addr[0] ? c_word[15:8] : c_word[7:0]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own <= M_PRE; s_req <= 1'b0; s_we <= 1'b0; s_addr <= '0; s_din <= '0; s_be <= '0;
      c_valid <= 1'b0; c_tag <= '0; c_word <= '0; z_ack_r <= 1'b0; mp_ack <= 1'b0;
      z_src <= 1'b0; pre_done <= 1'b0; pre_i <= '0; pre_we <= 1'b0; pre_hi <= 1'b0;
    end else begin
      z_ack_r <= 1'b0; mp_ack <= 1'b0; pre_we <= 1'b0;

      // on-chip: answered the next cycle, whatever SDRAM is doing; and a
      // write to the ROM, wherever it would have gone, is dropped
      if (pre_done && z_req && !z_ack_r && (z_chip || (z_we && z_rom))) begin
        z_ack_r <= 1'b1; z_src <= 1'b1;
      end

      case (own)
        // the code window's copy: CODE_LEN / 2 words from the ROM, once
        M_PRE: begin
          if (!s_req && !pre_we && !pre_done) begin
            s_req <= 1'b1; s_we <= 1'b0; s_be <= 2'b11;
            s_addr <= ROM_BASE + AW'(CODE_BASE[15:1]) + AW'(pre_i[9:1]);
            own <= M_Z;              // shares M_Z's wait; told apart by !pre_done
          end
        end
        M_IDLE: begin
          if (z_req && !z_ack_r && !z_chip && !(z_we && z_rom)) begin
            if (!z_we && c_hit) begin z_ack_r <= 1'b1; z_src <= 1'b0; end   // cached
            else begin
              own <= M_Z; s_req <= 1'b1; s_we <= z_we;
              s_addr <= (z_addr[15] ? RAM_BASE : ROM_BASE) + AW'(z_addr[14:1]);
              s_din  <= {z_wdata, z_wdata};
              s_be   <= z_we ? {z_addr[0], !z_addr[0]} : 2'b11;
            end
          end else if (mp_req && !mp_ack) begin
            own <= M_MP; s_req <= 1'b1; s_we <= 1'b0; s_be <= 2'b11;
            s_addr <= MPEG_BASE + AW'(mp_addr);
          end
        end
        M_Z: if (s_ack) begin
          s_req <= 1'b0;
          if (!pre_done) begin
            pre_we <= 1'b1; pre_hi <= 1'b0; c_word <= s_dout;
            own <= M_PRE;
          end else begin
            own <= M_IDLE; z_ack_r <= 1'b1; z_src <= 1'b0;
            if (!s_we) begin c_valid <= 1'b1; c_tag <= z_addr[15:1]; c_word <= s_dout; end
            else if (c_hit) begin
              if (z_addr[0]) c_word[15:8] <= z_wdata; else c_word[7:0] <= z_wdata;
            end
          end
        end
        default: if (s_ack) begin s_req <= 1'b0; own <= M_IDLE; mp_ack <= 1'b1; end   // M_MP
      endcase

      // the preload's two byte writes land the two cycles after its data;
      // then the next word
      if (pre_we) begin
        if (!pre_hi) begin pre_we <= 1'b1; pre_hi <= 1'b1; end
        else if (pre_i == 10'(CODE_LEN - 1)) begin pre_done <= 1'b1; own <= M_IDLE; end
        pre_i <= pre_i + 10'd1;
      end
    end
  end

endmodule
