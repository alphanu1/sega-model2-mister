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
// 93C46 SERIAL EEPROM, 64 x 16 bits -- the Model 2A-CRX main board's settings
// store (MAME model2a: EEPROM_93C46_16BIT "eeprom"), bit-banged by the i960
// through the 315-5649's port A (model2_state::eeprom_w: bit 5 DI, bit 6 CS,
// bit 7 CLK) and read back on port B bit 5 (in0_r, when PA bit 0 is set).
//
// MAME 0.289 eepromser.cpp's 93Cxx, state for state:
//   IN_RESET --CS rise--> WAIT_START --CLK rise with DI=1--> WAIT_CMD
//   WAIT_CMD: 2 opcode + 6 address bits on rising CLK, then
//     10 READ   -> READING: DO = 0 at once (the dummy bit); each FALLING CLK
//                  loads the word on the first edge, else shifts left with a
//                  1 in -- streaming: every 16th edge loads the next address
//     01 WRITE  -> WAIT_DATA: 16 bits on rising CLK, then written (unless
//                  locked) -> WAIT_DONE
//     11 ERASE  -> 0xFFFF (unless locked) -> WAIT_DONE
//     00 xx     -> by address[5:4]: 00 LOCK, 01 WRITEALL (AND), 10 ERASEALL,
//                  11 UNLOCK
//   CS fall from any state -> IN_RESET. Locked at power-up and reset.
//   DO: the shift register's top bit while READING; otherwise 1 (MAME's
//   tristate pull-up; in WAIT_START it is "ready", and MAME's 93C46 has no
//   write time, so always 1).
// The address of a streamed read wraps at 64 words.
//
// The array is one write port and one registered read in a reset-free block
// (R716's lesson in m2_ioz80: a combinationally read array becomes ~1,000
// flip-flops). It powers up erased, as an unsaved MAME eeprom does. Persistence
// across power cycles is not here yet (the NVRAM path is the backup RAM's).

`timescale 1ns/1ps

module m2_93c46 (
  input  logic clk,
  input  logic rst_n,   // power-on only: the part has no reset pin (MAME resets it never)
  input  logic cs,
  input  logic sk,      // the serial clock
  input  logic di,
  output logic do_o
);

  (* ramstyle = "MLAB, no_rw_check" *) logic [15:0] ee [64];
  initial for (int i = 0; i < 64; i++) ee[i] = 16'hffff;

  logic        we;
  logic  [5:0] wa, ra;
  logic [15:0] wd, q;
  always_ff @(posedge clk) begin
    if (we) ee[wa] <= wd;
    q <= ee[ra];
  end

  typedef enum logic [2:0] { S_RESET, S_START, S_CMD, S_READ, S_DATA, S_DONE } st_t;
  st_t         st;
  logic        cs_d, sk_d;
  logic  [7:0] ca;          // command + address accumulator
  logic  [3:0] nb;          // bits taken
  logic  [5:0] addr;
  logic [15:0] sh;          // shift register (data in or out)
  logic  [4:0] rbit;        // bit index within the streamed word (0..15)
  logic        locked;
  logic        ld_pend;     // a word to load into sh when q is valid
  logic  [1:0] ld_wait;
  logic        wall;        // WRITEALL / ERASEALL sweep running
  logic        wall_and;    // 1 = WRITEALL (AND sh), 0 = ERASEALL (0xFFFF)
  logic  [5:0] wall_a;
  logic  [1:0] wall_ph;

  wire cs_rise = cs && !cs_d;
  wire cs_fall = !cs && cs_d;
  wire sk_rise = sk && !sk_d;
  wire sk_fall = !sk && sk_d;

  assign do_o = (st == S_READ) ? sh[15] : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_RESET; cs_d <= 1'b1; sk_d <= 1'b1;   // lines idle high (pull-ups, port latches 0xFF) ca <= 8'd0; nb <= 4'd0;
      addr <= 6'd0; sh <= 16'd0; rbit <= 5'd0; locked <= 1'b1;
      ld_pend <= 1'b0; ld_wait <= 2'd0; we <= 1'b0; wa <= 6'd0; wd <= 16'd0; ra <= 6'd0;
      wall <= 1'b0; wall_and <= 1'b0; wall_a <= 6'd0; wall_ph <= 2'd0;
    end else begin
      cs_d <= cs;
      sk_d <= sk;
      we   <= 1'b0;

      // A loaded word arrives two cycles after its address (registered read).
      ld_wait <= {ld_wait[0], 1'b0};
      if (ld_wait[1]) begin sh <= q; ld_pend <= 1'b0; end

      // WRITEALL / ERASEALL: one word every three cycles, read-modify-write.
      if (wall) begin
        case (wall_ph)
          2'd0: begin ra <= wall_a; wall_ph <= 2'd1; end
          2'd1: wall_ph <= 2'd2;
          2'd2: begin
            we <= 1'b1; wa <= wall_a; wd <= wall_and ? (q & sh) : 16'hffff;
            wall_a <= wall_a + 6'd1; wall_ph <= 2'd0;
            if (wall_a == 6'd63) wall <= 1'b0;
          end
          default: wall_ph <= 2'd0;
        endcase
      end

      if (cs_fall) begin
        st <= S_RESET;
      end else begin
        case (st)
          S_RESET: if (cs_rise) st <= S_START;
          S_START: if (sk_rise && di) begin st <= S_CMD; nb <= 4'd0; ca <= 8'd0; end
          S_CMD: if (sk_rise) begin
            ca <= {ca[6:0], di};
            nb <= nb + 4'd1;
            if (nb == 4'd7) begin
              // {ca[6:0], di}: [7:6] opcode, [5:0] address
              addr <= {ca[4:0], di};
              case (ca[6:5])
                2'b10: begin                              // READ
                  st <= S_READ; sh <= 16'd0; rbit <= 5'd0;
                  ra <= {ca[4:0], di};
                end
                2'b01: begin st <= S_DATA; sh <= 16'd0; rbit <= 5'd0; end   // WRITE
                2'b11: begin                              // ERASE
                  if (!locked) begin we <= 1'b1; wa <= {ca[4:0], di}; wd <= 16'hffff; end
                  st <= locked ? S_RESET : S_DONE;
                end
                default: begin                            // 00: by address[5:4]
                  case (ca[4:3])
                    2'b00: begin locked <= 1'b1; st <= S_RESET; end       // LOCK
                    2'b01: begin st <= S_DATA; sh <= 16'd0; rbit <= 5'd0; end   // WRITEALL
                    2'b10: begin                          // ERASEALL
                      if (!locked) begin wall <= 1'b1; wall_and <= 1'b0; wall_a <= 6'd0; wall_ph <= 2'd0; end
                      st <= locked ? S_RESET : S_DONE;
                    end
                    default: begin locked <= 1'b0; st <= S_RESET; end     // UNLOCK
                  endcase
                end
              endcase
            end
          end
          S_READ: if (sk_fall) begin
            // MAME: bit_index % 16 == 0 loads read(address + accum/16), else
            // shift left with a 1 in. The load is the word at addr + n/16.
            if (rbit[3:0] == 4'd0) begin
              ra <= addr; ld_pend <= 1'b1; ld_wait <= 2'b01;
              addr <= addr + 6'd1;
            end else
              sh <= {sh[14:0], 1'b1};
            rbit <= {1'b0, rbit[3:0] + 4'd1};
          end
          S_DATA: if (sk_rise) begin
            sh   <= {sh[14:0], di};
            rbit <= rbit + 5'd1;
            if (rbit == 5'd15) begin
              if (locked) st <= S_RESET;
              else begin
                st <= S_DONE;
                if (ca[7:6] == 2'b01) begin we <= 1'b1; wa <= addr; wd <= {sh[14:0], di}; end
                else begin sh <= {sh[14:0], di}; wall <= 1'b1; wall_and <= 1'b1; wall_a <= 6'd0; wall_ph <= 2'd0; end
              end
            end
          end
          default: ;   // S_DONE: wait for CS to fall
        endcase
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, ld_pend, rbit[4]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
