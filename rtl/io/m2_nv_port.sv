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
// THE NVRAM FILE (the MRA's <nvram index="2">) between hps_io and the board:
// the backup SRAM, and (R945, SAVE) the 93C46 EEPROM after it. Moved out of
// Model2.sv unchanged in what it does for the backup RAM, so a bench can drive
// it through the real hps_io (sim/io/tb_m2_nv_save.cpp).
//
// THE FILE (index 2, 16-bit ioctl, little-endian words as hps_io sends them):
//   0x0000-0x3fff  backup SRAM, 16 KB (word = addr[13:2], half = addr[1])
//   SAVE only (an MRA size of 16520):
//   0x4000-0x4007  "M2EEPROM", the tail's tag
//   0x4008-0x4087  the 93C46, 64 words in MAME's .nv layout (word n = bytes
//                  2n, 2n+1, get_u16le -- the layout index 5 loads, R897)
//
// WHY A TAG, AND WHY FIRST. Main_MiSTer (support/arcade/mra_loader.cpp,
// arcade_nvm_load) zero-fills a buffer of the MRA's size, reads the file into
// it, and sends ALL of it whenever the file exists -- a 16 KB file saved by an
// earlier core arrives as 16 KB followed by zeros. Written into the EEPROM,
// those zeros would replace the MRA's default (Hanguk Pro Yagu 98's factory
// image) with 64 zero words. So the EEPROM words are taken only after the
// four tag words have arrived intact; a file without them leaves the EEPROM
// as the MRA and the power-on left it. With no file Main sends nothing at all.
// The tag goes FIRST so the words can be written as they arrive -- a tag
// after them would need a 64-word staging copy.
//
// THE SAVE. Main asks only after the core pulses ioctl_upload_req (the OSD's
// "Save settings" line, save_btn), then reads the MRA's size from index 2:
// the backup RAM through its debug port, then the tag (constants) and the
// EEPROM through its dump port, while the game runs. ioctl_din is
// registered, its sources registered: three cycles from an address to its
// word, against an SPI strobe that is never that close (hps_io samples
// ioctl_din at the strobe that advances past the address).
//
// THE LOAD. Every write is registered (a cycle late, as R593's firmware
// write): the game is in reset while the MRA loads, and the download stays up
// long after its last word. The backup write is bounded to 0x0000-0x3fff --
// it was not, and a longer file would have wrapped onto word 0.
// Index 5 (LOAD, R897): bytes 0-127 are the EEPROM image, word n at 2n.

`timescale 1ns/1ps

module m2_nv_port #(
  parameter bit LOAD = 1'b0,   // R897: index 5, the MRA's EEPROM image
  parameter bit SAVE = 1'b0    // R945: the EEPROM after the backup RAM on index 2
) (
  input  logic        clk,
  input  logic        rst_n,          // power-on only (the tag flag)
  // the OSD's save line (status[17]): its rising edge asks Main to save
  input  logic        save_btn,
  output logic        save_req,
  // hps_io
  input  logic        ioctl_download,
  input  logic        ioctl_upload,
  input  logic        ioctl_wr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] ioctl_index,    // [5:0]
  input  logic [26:0] ioctl_addr,     // [26:1]: 16-bit words
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [15:0] ioctl_dout,
  output logic [15:0] ioctl_din,
  // the backup SRAM (m2_backup's hps port and debug read port)
  output logic        bak_we,
  output logic [11:0] bak_word,
  output logic  [3:0] bak_be,
  output logic [31:0] bak_wdata,
  output logic [11:0] bak_rword,      // registered read: bak_q follows a cycle later
  input  logic [31:0] bak_q,
  // the 93C46 (m2_93c46's load port and dump port)
  output logic        ee_ld_we,
  output logic  [5:0] ee_ld_a,
  output logic [15:0] ee_ld_d,
  output logic  [5:0] ee_dump_a,      // registered read: ee_dump_q follows a cycle later
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] ee_dump_q
  /* verilator lint_on UNUSEDSIGNAL */
);

  // "M2EEPROM" as four little-endian words
  localparam logic [15:0] TAG0 = 16'h324d, TAG1 = 16'h4545, TAG2 = 16'h5250, TAG3 = 16'h4d4f;
  function automatic logic [15:0] tag(input logic [1:0] i);
    case (i)
      2'd0: tag = TAG0;
      2'd1: tag = TAG1;
      2'd2: tag = TAG2;
      default: tag = TAG3;
    endcase
  endfunction

  logic [2:0] save_sync;
  always_ff @(posedge clk) save_sync <= {save_sync[1:0], save_btn};
  assign save_req = save_sync[1] & ~save_sync[2];

  wire nv_sel  = (ioctl_index[5:0] == 6'd2);
  wire ee_sel  = (ioctl_index[5:0] == 6'd5);
  wire dl_wr   = ioctl_download && ioctl_wr;
  wire in_bak  = (ioctl_addr[26:14] == 13'd0);                   // 0x0000-0x3fff
  wire in_tail = (ioctl_addr[26:14] == 13'd1) && (ioctl_addr[13:8] == 6'd0);   // 0x4000-0x40ff
  wire in_tag  = in_tail && (ioctl_addr[7:3] == 5'd0);            // 0x4000-0x4007
  wire in_ee   = in_tail && (ioctl_addr[7:1] >= 7'd4) && (ioctl_addr[7:1] < 7'd68);   // 0x4008-0x4087

  // ---------------------------------------------------------------- load
  // The tag, word by word: the first word starts it, each later one must
  // match too, and anything written to the backup part clears it.
  logic tag_ok;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) tag_ok <= 1'b0;
    else if (SAVE && dl_wr && nv_sel) begin
      if (!in_tail) tag_ok <= 1'b0;
      else if (in_tag)
        tag_ok <= ((ioctl_addr[2:1] == 2'd0) || tag_ok) && (ioctl_dout == tag(ioctl_addr[2:1]));
    end
  end

  always_ff @(posedge clk) begin
    bak_we    <= dl_wr && nv_sel && in_bak;
    bak_word  <= ioctl_addr[13:2];
    bak_be    <= ioctl_addr[1] ? 4'b1100 : 4'b0011;
    bak_wdata <= {ioctl_dout, ioctl_dout};
    ee_ld_we  <= (LOAD && dl_wr && ee_sel && (ioctl_addr[26:7] == 20'd0))
              || (SAVE && dl_wr && nv_sel && in_ee && tag_ok);
    ee_ld_a   <= nv_sel ? (ioctl_addr[6:1] - 6'd4) : ioctl_addr[6:1];   // 0x4008 is word 0
    ee_ld_d   <= ioctl_dout;
  end

  // ---------------------------------------------------------------- save
  // REGISTERED BOTH WAYS (Model2.sv's note, kept): driven combinationally,
  // ioctl_upload fed the debug-port address mux whose data fed ioctl_din
  // straight back into hps_io, and Quartus 17.0's fitter timing engine
  // crashed on the apparent cycle (sta_scc.cpp:1041).
  // Out of an upload the backup port watches word 5 (R411).
  logic [15:0] din_r;
  always_ff @(posedge clk) begin
    bak_rword <= (ioctl_upload && nv_sel) ? ioctl_addr[13:2] : 12'd5;
    ee_dump_a <= ioctl_addr[6:1] - 6'd4;
    din_r     <= (SAVE && !in_bak) ? (in_tag ? tag(ioctl_addr[2:1]) : ee_dump_q)
               : ioctl_addr[1] ? bak_q[31:16] : bak_q[15:0];
  end
  assign ioctl_din = din_r;

endmodule
