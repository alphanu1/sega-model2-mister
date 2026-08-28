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
// THE I/O BOARD AS A COMPUTER, NOT AN IMITATION (study R60).
//
// Sega's Model 1 I/O board -- the same physical PCB in Model 1 cabinets and in
// model2o cabinets, Daytona included -- is a Z80 running EPR-14869. Studies
// R37-R41 imitated its observed behaviour and stalled exactly where the board
// COMPUTES rather than responds: the credit digits on the settings splash are
// arithmetic the firmware performs on data the game round-trips through the
// dual-port RAM. So this runs the firmware.
//
// The map and devices are taken from MAME (model1io.cpp, 315_5338a.cpp,
// msm6253.cpp), which is this project's ruling reference:
//
//   0x0000-0x3fff  firmware ROM (first 16 KB of the 64 KB EPROM; no banking)
//   0x4000-0x5fff  8 KB work RAM
//   0x8000-0x800f  Sega 315-5338A I/O custom
//   0xc000-0xc003  OKI MSM6253 ADC, 4 channels, serial MSB-first readout
//
// THE DPRAM IS BEHIND THE 315-5338A, not memory-mapped: the Z80 sets a 16-bit
// address through commands 0x00/0x01 (low/high from the serial-output
// register), writes dpram[addr] with command 0x07, writes dpram[0..7] directly
// with commands 0x70-0x77, and reads dpram[addr] at register 0x0c. That
// byte-at-a-time shape is exactly the exchange the DPRAM traces always showed.
//
// 315-5338A ports, per model1io.cpp's bindings:
//   PB (1) / PC (2) / PD (3)  <- IN0 / IN1 / IN2   (DSW1-3 when the firmware
//                                selects secondary controls -- deferred until
//                                the game's own INPUT TEST screen can serve as
//                                the oracle for the select bit)
//   PE (4)                    <- drive board (absent: 0xff)
//   PF (5)                    -> output latch (lamps etc.; latched, unused)
//   PG (6)                    <- button board / EEPROM DO (absent: 0xff)
//
// CEN_DIV pacing: the real Z80 runs at 32 MHz / 8 = 4 MHz, which is clk_sys /
// 12. The firmware's power-on delays (R40 measured them as ~0.12 s and ~3.0 s)
// are Z80 delay loops, so they now come from the program itself rather than
// from two magic constants. Simulation may pace CEN faster; the semantics are
// unchanged, only the seconds compress.

`timescale 1ns/1ps

module m2_ioz80 #(
  parameter int unsigned CEN_DIV = 12
) (
  input  logic        clk,
  input  logic        rst_n,

  // Firmware load, byte-wide (ioctl index 1 in Model2.sv).
  input  logic        fw_we,
  input  logic [13:0] fw_addr,
  input  logic  [7:0] fw_data,

  // Cabinet inputs, ACTIVE LOW at rest (0xff = nothing pressed), matching
  // model2.cpp's port definitions: IN0 = {VR3,VR2,VR1,START1,SERVICE,TEST,
  // COIN2,COIN1}, IN1 bits 6:4 = gearbox (ACTIVE HIGH), bit 0 = VR4.
  input  logic  [7:0] in0,
  input  logic  [7:0] in1,
  input  logic  [7:0] in2,
  input  logic  [7:0] adc0,   // steering, centre 0x80
  input  logic  [7:0] adc1,   // accelerator, idle 0x20
  input  logic  [7:0] adc2,   // brake, idle 0x20
  input  logic  [7:0] adc3,

  // Dual-port RAM, the Z80's side. Byte-addressed, 2 KB.
  output logic        z_we,
  output logic [10:0] z_addr,
  output logic  [7:0] z_wdata,
  input  logic  [7:0] z_rdata,

  // Debug: last DPRAM command write, and the output latch.
  output logic  [7:0] dbg_ee,    // {cs, clk, di, do, st[2:0], ewen}
  output logic [15:0] dbg_wrcnt,  // {io-write strobes, any-write strobes}
  output logic        dbg_wr_stb,
  output logic  [7:0] dbg_dout,
  output logic  [7:0] dbg_di,
  output logic        dbg_rd_end,
  output logic [15:0] dbg_ra,
  output logic  [7:0] dbg_rdat,
  output logic        dbg_m1_n,
  output logic [15:0] dbg_a,
  output logic [15:0] dbg_last_wr,   // {addr[7:0], data}
  output logic  [7:0] dbg_pf
);

  // ------------------------------------------------------------ Z80 pacing
  logic [$clog2(CEN_DIV)-1:0] cen_ctr;
  logic cen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin cen_ctr <= '0; cen <= 1'b0; end
    else begin
      cen     <= (cen_ctr == '0);
      cen_ctr <= (cen_ctr == ($clog2(CEN_DIV))'(CEN_DIV - 1)) ? '0 : cen_ctr + 1'b1;
    end
  end

  // ------------------------------------------------------------ the CPU
  logic [15:0] A;
  logic  [7:0] di, dout;
  logic        mreq_n, rd_n, wr_n;

  tv80s u_z80 (
    .reset_n(rst_n), .clk(clk), .cen(cen),
    .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
    .m1_n(dbg_m1_n), .mreq_n(mreq_n), .iorq_n(), .rd_n(rd_n), .wr_n(wr_n),
    .rfsh_n(), .halt_n(), .busak_n(),
    .A(A), .di(di), .dout(dout)
  );

  assign dbg_a = A;
  wire mem_rd = !mreq_n && !rd_n;
  wire mem_wr = !mreq_n && !wr_n;

  // ONE EVENT PER STROBE. Under CEN pacing the Z80 holds rd/wr for many clk
  // cycles; acting on the level would repeat every side effect. The habit is
  // R43's: act on the edge, never the level.
  logic mem_wr_d, mem_rd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin mem_wr_d <= 1'b0; mem_rd_d <= 1'b0; end
    else begin mem_wr_d <= mem_wr; mem_rd_d <= mem_rd; end
  end
  // COMMIT ON THE TRAILING EDGE, WITH LATCHED OPERANDS. At the strobe's
  // leading edge tv80 has not yet settled dout -- observed as "ld (hl),n"
  // storing the byte before its operand -- and by the trailing edge A may be
  // moving on. So A and dout are latched every cycle the strobe is high and
  // the commit happens once, at its end, from the latches.
  logic [15:0] aw_l;
  logic  [7:0] dw_l;
  always_ff @(posedge clk) if (mem_wr) begin aw_l <= A; dw_l <= dout; end
  wire wr_stb = !mem_wr && mem_wr_d;   // trailing edge; aw_l/dw_l hold truth
  wire rd_end = !mem_rd && mem_rd_d;   // read completed: safe to shift

  // ------------------------------------------------------------ ROM and RAM
  // Registered reads settle within one 48 MHz cycle; the Z80 samples many
  // cycles later under CEN pacing, so no wait states are needed.
  (* ramstyle = "M10K" *) logic [7:0] fw  [16384];
  (* ramstyle = "M10K" *) logic [7:0] ram [8192];
  // NEGEDGE READS, and this is load-bearing. tv80 drives A on a rising CEN
  // edge and samples data against later rising edges of the same paced clock;
  // a posedge-registered read hands it fw[PREVIOUS A] at every sampling point
  // -- observed directly as `ld (hl),n` storing the byte BEFORE its operand.
  // Reading on the falling edge puts fresh data on the bus half a cycle after
  // the address, which is the async-ROM shape every T80-family design expects,
  // and M10K clocks on either edge without complaint.
  logic [7:0] fw_q, ram_q;
  always_ff @(posedge clk) begin
    if (fw_we) fw[fw_addr] <= fw_data;
  end
  always_ff @(negedge clk) fw_q <= fw[A[13:0]];
  always_ff @(posedge clk) begin
    if (wr_stb && aw_l[15:13] == 3'b010) ram[aw_l[12:0]] <= dw_l;   // 0x4000-0x5fff
  end
  always_ff @(negedge clk) ram_q <= ram[A[12:0]];

  // ------------------------------------------------------------ 315-5338A
  logic [15:0] io_address;     // the DPRAM address, built by commands 0x00/0x01
  logic [10:0] z_addr_r;
  logic  [7:0] ser_out;        // register 0x0a, the datum commands consume
  logic  [7:0] cmd_r;          // register 0x0b reads it back
  logic  [7:0] port_out [8];   // latched output ports (PA, PF, ...)
  logic  [7:0] dir_r;

  wire io_sel  = (A[15:4] == 12'h800);   // 0x8000-0x800f
  wire adc_sel = (A[15:2] == 14'h3000);  // 0xc000-0xc003
  logic adc_sel_d;
  always_ff @(posedge clk) adc_sel_d <= mem_rd && adc_sel;

  // Reads. dpram reads go through z_rdata: z_addr tracks io_address
  // continuously, the DPRAM's registered read settles long before the paced
  // Z80 samples it, and io_address only changes via commands.
  logic [7:0] io_q;
  always_comb begin
    io_q = 8'hff;
    case (A[3:0])
      4'h0: io_q = port_out[0];
      4'h1: io_q = in0;              // PB
      4'h2: io_q = in1;              // PC
      4'h3: io_q = in2;              // PD
      4'h4: io_q = 8'hff;            // PE: drive board absent
      4'h5: io_q = port_out[5];      // PF: output latch reads back
      4'h6: io_q = {ee_do, 7'h7f};   // PG bit 7: EEPROM DO
      4'h8: io_q = dir_r;
      4'ha: io_q = ser_out;
      4'hb: io_q = cmd_r;
      4'hc: io_q = z_rdata;          // dpram[io_address]
      4'hd: io_q = 8'h08;            // status, per 315_5338a.cpp
      default: ;
    endcase
  end

  // Writes, including the DPRAM command path.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      io_address <= 16'd0; ser_out <= 8'd0; cmd_r <= 8'd0; dir_r <= 8'd0;
      z_we <= 1'b0; z_wdata <= 8'd0; z_addr_r <= 11'd0; dbg_last_wr <= 16'd0;
      for (int i = 0; i < 8; i++) port_out[i] <= 8'd0;
    end else begin
      z_we <= 1'b0;
      if (wr_stb && aw_l[15:4] == 12'h800) begin
        case (aw_l[3:0])
          4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6:
            port_out[aw_l[2:0]] <= dw_l;
          4'h8: dir_r <= dw_l;
          4'h9: begin
            cmd_r <= dw_l;
            case (dw_l)
              8'h00: io_address[7:0]  <= ser_out;
              8'h01: io_address[15:8] <= ser_out;
              8'h07: begin
                z_we <= 1'b1; z_wdata <= ser_out; z_addr_r <= io_address[10:0];
                dbg_last_wr <= {io_address[7:0], ser_out};
              end
              8'h70, 8'h71, 8'h72, 8'h73,
              8'h74, 8'h75, 8'h76, 8'h77: begin
                z_we <= 1'b1; z_wdata <= ser_out; z_addr_r <= {8'd0, dw_l[2:0]};
                dbg_last_wr <= {5'd0, dw_l[2:0], ser_out};
              end
              default: ;   // 0x87 arms serial reception; reads already work
            endcase
          end
          4'ha: ser_out <= dw_l;
          default: ;
        endcase
      end
    end
  end

  // The z-port address travels WITH the write it belongs to -- registered in
  // the same cycle as z_we, so a command's address cannot be replaced under it.
  // Reads keep the port pointed at io_address continuously.
  assign z_addr = z_we ? z_addr_r : io_address[10:0];
  assign dbg_pf = port_out[5];

  // ------------------------------------------------------------ 93C46 EEPROM
  // The board's own settings store, bit-banged by the firmware through the
  // 315-5338A: PA7 = CLK, PA6 = CS, PA5 = DI, PG7 = DO (model1io.cpp io_pa_w).
  // The boot spins forever retrying the serial read if this is absent, which
  // is how it announced itself. 93C46 in 16-bit mode: 64 words; start bit,
  // 2-bit opcode, 6-bit address; READ shifts a dummy 0 then 16 bits MSB-first.
  // Powers up erased (all-ones): the firmware finds a virgin part, applies its
  // defaults, and writes them back -- so WRITE/ERASE/EWEN are implemented, not
  // just READ. Contents are volatile here; persistence can ride the NVRAM
  // mechanism later if board-local settings turn out to matter.
  logic [15:0] ee  [64];
  logic        ee_do;
  logic  [8:0] ee_sh;         // start + opcode + address collector
  logic  [3:0] ee_nbits;
  logic [16:0] ee_out;        // dummy 0 + 16 data bits
  logic [15:0] ee_in;
  logic  [4:0] ee_wcnt;
  logic        ee_ewen;
  logic  [5:0] ee_addr;
  typedef enum logic [2:0] {EE_CMD, EE_READ, EE_WRITE, EE_DONE} ee_st_t;
  ee_st_t ee_st;
  wire ee_clk = port_out[0][7];
  wire ee_cs  = port_out[0][6];
  wire ee_di  = port_out[0][5];
  logic ee_clk_d;
  initial for (int i = 0; i < 64; i++) ee[i] = 16'hffff;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ee_do <= 1'b1; ee_sh <= 9'd0; ee_nbits <= 4'd0; ee_out <= 17'd0;
      ee_in <= 16'd0; ee_wcnt <= 5'd0; ee_ewen <= 1'b0; ee_addr <= 6'd0;
      ee_st <= EE_CMD; ee_clk_d <= 1'b0;
    end else begin
      ee_clk_d <= ee_clk;
      if (!ee_cs) begin
        ee_st <= EE_CMD; ee_nbits <= 4'd0; ee_sh <= 9'd0; ee_do <= 1'b1;
      end else if (ee_clk && !ee_clk_d) begin
        case (ee_st)
          EE_CMD: begin
            // Collect start + opcode + address. The start bit is the first 1.
            if (ee_sh == 9'd0 && !ee_di) ;   // still waiting for the start bit
            else begin
              ee_sh    <= {ee_sh[7:0], ee_di};
              ee_nbits <= ee_nbits + 4'd1;
              if (ee_nbits == 4'd8) begin
                // ee_sh[7:6] after this shift = opcode, [5:0] = address.
                ee_addr <= {ee_sh[4:0], ee_di};
                case (ee_sh[6:5])
                  2'b10: begin ee_st <= EE_READ;
                               ee_out <= {1'b0, ee[{ee_sh[4:0], ee_di}]}; end
                  2'b01: begin ee_st <= EE_WRITE; ee_wcnt <= 5'd0; end
                  2'b11: begin if (ee_ewen) ee[{ee_sh[4:0], ee_di}] <= 16'hffff;
                               ee_st <= EE_DONE; end
                  2'b00: begin ee_ewen <= (ee_sh[4:3] == 2'b11);
                               ee_st <= EE_DONE; end
                endcase
              end
            end
          end
          EE_READ: begin
            ee_do  <= ee_out[16];
            ee_out <= {ee_out[15:0], 1'b0};
          end
          EE_WRITE: begin
            ee_in   <= {ee_in[14:0], ee_di};
            ee_wcnt <= ee_wcnt + 5'd1;
            if (ee_wcnt == 5'd15) begin
              if (ee_ewen) ee[ee_addr] <= {ee_in[14:0], ee_di};
              ee_st <= EE_DONE;
            end
          end
          EE_DONE: ee_do <= 1'b1;   // ready/busy: high = ready
          default: ee_st <= EE_CMD;
        endcase
      end
    end
  end

  assign dbg_ee = {ee_cs, ee_clk, ee_di, ee_do, ee_st, ee_ewen};
  assign dbg_wr_stb = wr_stb;
  assign dbg_dout   = dout;
  assign dbg_di     = di;
  logic [15:0] ar_l; logic [7:0] dr_l;
  always_ff @(posedge clk) if (mem_rd) begin ar_l <= A; dr_l <= di; end
  assign dbg_rd_end = rd_end;
  assign dbg_ra     = ar_l;
  assign dbg_rdat   = dr_l;
  logic [7:0] wrc_io, wrc_any;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wrc_io <= 8'd0; wrc_any <= 8'd0; end
    else begin
      if (wr_stb && !(&wrc_any)) wrc_any <= wrc_any + 8'd1;
      if (wr_stb && io_sel && !(&wrc_io)) wrc_io <= wrc_io + 8'd1;
    end
  end
  assign dbg_wrcnt = {wrc_io, wrc_any};

  // ------------------------------------------------------------ MSM6253 ADC
  // address_w latches the selected channel into a shift register; d0_r shifts
  // it out MSB-first, one bit per read, in bit 0.
  logic [7:0] adc_shift;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) adc_shift <= 8'd0;
    else if (wr_stb && aw_l[15:2] == 14'h3000) begin
      case (aw_l[1:0])
        2'd0: adc_shift <= adc0;
        2'd1: adc_shift <= adc1;
        2'd2: adc_shift <= adc2;
        2'd3: adc_shift <= adc3;
      endcase
    end else if (rd_end && adc_sel_d) begin
      adc_shift <= {adc_shift[6:0], 1'b0};
    end
  end

  // ------------------------------------------------------------ read mux
  always_comb begin
    di = 8'hff;
    if      (A[15:14] == 2'b00) di = fw_q;                    // 0x0000-0x3fff
    else if (A[15:13] == 3'b010) di = ram_q;                  // 0x4000-0x5fff
    else if (io_sel)             di = io_q;
    else if (adc_sel)            di = {7'h7f, adc_shift[7]};
  end

endmodule
