// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R945: the NVRAM file end to end, as the 2A build wires it (Model2.sv): the
// framework's own sys/hps_io.sv (WIDE, as the core) -> m2_nv_port -> m2_backup
// and m2_315_5649's 93C46. The bench (tb_m2_nv_save.cpp) is Main_MiSTer on
// the HPS_BUS -- the SPI words arcade_nvm_load / arcade_nvm_save and the ROM
// download send -- and the i960 on the I/O board's and backup RAM's buses.

`timescale 1ns/1ps

module tb_m2_nv_save_top (
  input  logic        clk,
  input  logic        por_n,          // power-on (mem_rst_n)
  input  logic        rst_n,          // the game's reset (cpu_rst_n)
  // the HPS: HPS_BUS[35] fp_enable, [34] io_enable, [33] io_strobe, [31:16] io_din
  input  logic        fp_enable,
  input  logic        io_enable,
  input  logic        io_strobe,
  input  logic [15:0] io_din,
  output logic [15:0] io_dout,        // HPS_BUS[15:0]
  input  logic        save_btn,       // status[17], the OSD's "Save settings"
  // the i960 at 0x01c00000-0x01c0001f (the 315-5649)
  input  logic        sel,
  input  logic        we,
  input  logic  [2:0] word,
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  // the i960 at 0x01d00000-0x01d03fff (backup RAM)
  input  logic        bsel,
  input  logic        bwe,
  input  logic [11:0] bword,
  input  logic  [3:0] bbe,
  input  logic [31:0] bwdata,
  output logic [31:0] brdata,
  output logic        dl_active,      // ioctl_download, for the bench's waits
  output logic        ul_active       // ioctl_upload
);
  /* verilator lint_off UNUSEDSIGNAL */
  wire [45:0] HPS_BUS;
  wire [35:0] EXT_BUS;
  /* verilator lint_on UNUSEDSIGNAL */
  assign HPS_BUS[35]    = fp_enable;
  assign HPS_BUS[34]    = io_enable;
  assign HPS_BUS[33]    = io_strobe;
  assign HPS_BUS[31:16] = io_din;
  assign HPS_BUS[45:38] = 8'd0;
  assign EXT_BUS[32]    = 1'b0;
  assign io_dout        = HPS_BUS[15:0];

  wire        ioctl_download, ioctl_upload, ioctl_wr, nv_save_req;
  wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
  wire [26:0] ioctl_addr;
  hps_io #(.CONF_STR("M2;;"), .WIDE(1)) hps_io (
    .clk_sys(clk), .HPS_BUS(HPS_BUS), .EXT_BUS(EXT_BUS),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(1'b0),
    .ioctl_din(ioctl_din), .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(nv_save_req), .ioctl_upload_index(8'd2)
  );
  assign dl_active = ioctl_download;
  assign ul_active = ioctl_upload;

  wire        nv_we;
  wire [11:0] nv_word, nv_word_r;
  wire  [3:0] nv_be;
  wire [31:0] nv_wdata, bak_dbg_q;
  wire        ee_ld_we;
  wire  [5:0] ee_ld_a, ee_dump_a;
  wire [15:0] ee_ld_d, ee_dump_q;
  m2_nv_port #(.LOAD(1'b1), .SAVE(1'b1)) u_nv_port (
    .clk, .rst_n(por_n),
    .save_btn, .save_req(nv_save_req),
    .ioctl_download, .ioctl_upload, .ioctl_wr,
    .ioctl_index, .ioctl_addr, .ioctl_dout, .ioctl_din,
    .bak_we(nv_we), .bak_word(nv_word), .bak_be(nv_be), .bak_wdata(nv_wdata),
    .bak_rword(nv_word_r), .bak_q(bak_dbg_q),
    .ee_ld_we, .ee_ld_a, .ee_ld_d, .ee_dump_a, .ee_dump_q
  );

  /* verilator lint_off PINCONNECTEMPTY */
  m2_backup u_backup (
    .clk, .rst_n,
    .hps_we(nv_we), .hps_word(nv_word), .hps_be(nv_be), .hps_wdata(nv_wdata),
    .sel(bsel), .we(bwe), .word(bword), .be(bbe), .wdata(bwdata), .rdata(brdata),
    .dbg_word(nv_word_r), .dbg_rd_sel(4'd0),
    .dbg_q(bak_dbg_q), .dbg_first(), .dbg_w0(), .dbg_writes()
  );

  m2_315_5649 #(.GUN(1'b0), .EE_LOAD(1'b1), .EE_SAVE(1'b1)) u_315_5649 (
    .clk, .por_n, .rst_n,
    .sel, .we, .word, .be, .wdata, .rdata,
    .in0(8'hff), .in1(8'hff), .in2(8'hff), .sw(8'hff),
    .an0(8'hff), .an1(8'hff), .an2(8'hff),
    .gun_p1x(10'd0), .gun_p1y(10'd0), .gun_p2x(10'd0), .gun_p2y(10'd0), .gun_off(2'd0),
    .lamps(), .pe(),
    .ee_ld_we, .ee_ld_a, .ee_ld_d, .ee_dump_a, .ee_dump_q,
    .dbg_pa(), .dbg_dir()
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
