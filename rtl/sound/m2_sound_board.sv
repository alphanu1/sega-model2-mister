// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The Model 1 sound board, which is what daytona93 has.
//
// model2.cpp instantiates SEGAM1AUDIO for model2o -- the same device model1.cpp
// uses -- so this is a Model 1 board hanging off a Model 2 main board, talking
// over the serial pair in m2_sound_link.sv and nothing else. Study §5.5 budgets
// "SCSP + 68000" for sound, which is the wrong board for this game; see R87.
//
// THE MAP, read out of MAME's own address_map rather than transcribed from a
// wiki. `manager.machine.devices[":m1audio:sndcpu"].spaces["program"].map`:
//
//   000000-03FFFF  ROM, 256 KB, region offset 0
//   080000-09FFFF  ROM, 128 KB, region offset 0x20000 -- a WINDOW onto the same
//                  image, not more ROM. The .mra loads 256 KB and that is all
//                  there is; MAME's region is 768 KB because the device
//                  allocates for the largest Model 1 game, not this one.
//   C20000-C20003  i8251, the far end of the link that already carries the
//                  right 48 bytes
//   C40000-C40007  MULTIPCM 1        C50000  its sample bank
//   C60000-C60007  MULTIPCM 2        C70000  its sample bank
//   D00000-D00007  YM3438
//   F00000-F0FFFF  RAM, 64 KB
//
// Everything is 16 bits and the 68000 addresses by byte, so UDSn/LDSn say which
// half an access names. The devices are 8-bit and sit on the LOW half.
//
// THE ROM IS NOT HERE. It is 256 KB and it lives in SDRAM with the rest of the
// image, so it is fetched over a request/acknowledge port and the board stalls
// on DTACK until the word arrives. That keeps this module the same in
// simulation, where the harness answers the port directly, and on hardware,
// where the arbiter does -- and it means the CPU can be proven against MAME
// before the arbiter grows a sixth channel.

`timescale 1ns/1ps

module m2_sound_board #(
  // 48 MHz in, 10 MHz 68000 out (20 MHz crystal, divided by two). 48/10 is not
  // an integer, so this is a phase accumulator rather than a counter: add
  // TICK_NUM every cycle and pulse when it crosses TICK_DEN. The average is
  // exact even though no individual period is, which is what a sound CPU needs
  // -- a 4% error from rounding 4.8 down to 5 would put every tempo out.
  parameter int unsigned TICK_NUM = 20,     // 2 x 10 MHz: one enable per phase
  parameter int unsigned TICK_DEN = 48      // clk_sys
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the serial link to the main board (B side)
  input  logic  [7:0] rx_data,
  input  logic        rx_valid,
  output logic        rx_ack,
  output logic  [7:0] tx_data,
  output logic        tx_valid,
  input  logic        tx_ack,

  // ---- program ROM, wherever it lives
  output logic        rom_req,
  output logic [17:1] rom_addr,     // 256 KB, word addressed
  input  logic        rom_ack,
  input  logic [15:0] rom_data,

  // ---- what the audio chips will hang off, counted until they exist
  output logic        ym_sel,   output logic       ym_we,
  output logic  [1:0] ym_addr,  output logic [7:0] ym_din,
  output logic        pcm_sel,  output logic       pcm_we,
  output logic        pcm_bank, // which of the two
  output logic  [2:0] pcm_addr, output logic [7:0] pcm_din,

  // ---- the mix
  output logic signed [15:0] snd_l,
  output logic signed [15:0] snd_r,

  // ---- for the debug channel
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_insns,
  output logic [15:0] dbg_ym_writes,
  output logic [15:0] dbg_pcm_writes
);

  // ----------------------------------------------------------- clock enables
  logic [$clog2(TICK_DEN):0] acc;
  logic phase;                 // 0 -> next enable is phi1, 1 -> phi2
  logic enPhi1, enPhi2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc <= '0; phase <= 1'b0; enPhi1 <= 1'b0; enPhi2 <= 1'b0;
    end else begin
      enPhi1 <= 1'b0;
      enPhi2 <= 1'b0;
      if (acc + TICK_NUM >= TICK_DEN) begin
        acc <= acc + TICK_NUM - TICK_DEN;
        phase <= ~phase;
        if (phase) enPhi2 <= 1'b1;
        else       enPhi1 <= 1'b1;
      end else begin
        acc <= acc + TICK_NUM;
      end
    end
  end

  // --------------------------------------------------------------- the 68000
  wire        asn, ldsn, udsn, rwn;
  wire [23:1] eab;
  wire [15:0] oedb;
  logic [15:0] iedb;
  logic        dtackn;
  logic  [2:0] ipl_n;

  fx68k u_cpu (
    .clk(clk), .HALTn(1'b1),
    .extReset(!rst_n), .pwrUp(!rst_n),
    .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(rwn), .ASn(asn), .LDSn(ldsn), .UDSn(udsn),
    .E(), .VMAn(),
    .FC0(), .FC1(), .FC2(),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtackn), .VPAn(1'b1), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
    .iEdb(iedb), .oEdb(oedb), .eab(eab)
  );

  wire [23:0] addr  = {eab, 1'b0};
  wire        as    = !asn;
  wire        ds    = !ldsn || !udsn;
  wire        we    = as && !rwn;
  wire        rd    = as &&  rwn;

  // --------------------------------------------------------------- decoding
  // The ROM window at 0x080000 is the SAME 256 KB seen through a hole at offset
  // 0x20000, not a second image. Both branches index one port.
  wire sel_rom0 = as && (addr[23:18] == 6'b000000);              // 000000-03FFFF
  wire sel_rom1 = as && (addr[23:17] == 7'b0000100);             // 080000-09FFFF
  wire sel_rom  = sel_rom0 | sel_rom1;
  wire sel_ram  = as && (addr[23:16] == 8'hF0);                  // F00000-F0FFFF
  wire sel_uart = as && (addr[23:2]  == 22'h30_8000);            // C20000-C20003
  wire sel_pcm1 = as && (addr[23:3]  == 21'h18_8000);            // C40000-C40007
  wire sel_pcm2 = as && (addr[23:3]  == 21'h18_C000);            // C60000-C60007
  wire sel_bnk1 = as && (addr[23:1]  == 23'h62_8000);            // C50000
  wire sel_bnk2 = as && (addr[23:1]  == 23'h63_8000);            // C70000
  wire sel_ym   = as && (addr[23:3]  == 21'h1A_0000);            // D00000-D00007

  assign rom_addr = sel_rom1 ? {2'b01, addr[16:1]} : addr[17:1];

  // ------------------------------------------------------------------- RAM
  // 64 KB, byte lanes, tagged, never cleared in reset -- the standing rule.
  (* ramstyle = "M10K" *) logic [7:0] ram_hi [32768];
  (* ramstyle = "M10K" *) logic [7:0] ram_lo [32768];
  logic [7:0] ram_hq, ram_lq;
  wire [14:0] ram_a = addr[15:1];

  always_ff @(posedge clk) begin
    ram_hq <= ram_hi[ram_a];
    ram_lq <= ram_lo[ram_a];
    if (sel_ram && we && !udsn) ram_hi[ram_a] <= oedb[15:8];
    if (sel_ram && we && !ldsn) ram_lo[ram_a] <= oedb[7:0];
  end

  // ------------------------------------------------------------------ UART
  wire [7:0] uart_dout, uart_data_o, uart_stat_o;
  wire       uart_irq, uart_irq_rx, uart_irq_tx;
  // addr[1] picks data (0xC20000) from status/command (0xC20002), the same
  // shape the i960's end has.
  m2_i8251 u_uart (
    .clk(clk), .rst_n(rst_n),
    .sel(sel_uart && ds && (we || rwn)),
    .we(we), .addr(addr[1]),
    .din(oedb[7:0]),
    .dout(uart_dout), .data_o(uart_data_o), .stat_o(uart_stat_o),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ack(tx_ack),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ack(rx_ack),
    .irq(uart_irq), .irq_rx(uart_irq_rx), .irq_tx(uart_irq_tx)
  );

  // ---------------------------------------------------------------- IPL
  // segam1audio wires the UART's rxrdy to the 68000's IRQ2 and the YM's timer
  // to IRQ4. Only the UART exists yet, so IRQ4 is never raised -- and that is
  // recorded rather than left looking complete: a board that never sees its
  // timer interrupt will not sequence music, whatever the UART does.
  always_comb begin
    ipl_n = 3'b111;                       // no interrupt
    if (uart_irq_rx) ipl_n = 3'b101;      // level 2, active low
  end

  // ------------------------------------------------------------- YM3438
  //
  // MAME's own figure, from -listxml: YM3438 OPN2C at 8,000,000 Hz. 48/8 is
  // six exactly, so this is a counter and not the accumulator the 68000 needs.
  //
  // ONE WRITE PER BUS CYCLE, WHICH TAKES A PULSE. jt12_top forms its internal
  // strobe as `write = !cs_n && !wr_n` -- a LEVEL -- and acts on it inside a
  // clocked block. A 68000 write cycle at 10 MHz lasts about 400 ns, which
  // spans three 8 MHz enables, so passing the bus signals straight through
  // applies every register write three times. Most registers do not care; the
  // key-on register at 0x28 and the timer controls do, and a bug there would
  // show up as notes that retrigger rather than as anything obviously wrong.
  //
  // So: latch address and data at the START of the cycle and hold the strobe
  // for exactly one enable. The payload is latched with the edge that raises
  // the strobe -- gating a capture by the same condition that raises it is a
  // rule this project has already paid for twice.
  logic [2:0] ym_div;
  wire        ym_cen = (ym_div == 3'd0);
  logic       ym_wr_pend, ym_bus_d;
  logic [1:0] ym_a_r;
  logic [7:0] ym_d_r;
  wire        ym_bus = sel_ym && ds && we;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ym_div <= 3'd0; ym_wr_pend <= 1'b0; ym_bus_d <= 1'b0;
      ym_a_r <= 2'd0; ym_d_r <= 8'd0;
    end else begin
      ym_div   <= (ym_div == 3'd5) ? 3'd0 : ym_div + 3'd1;
      ym_bus_d <= ym_bus;
      if (ym_bus && !ym_bus_d) begin
        ym_a_r     <= addr[2:1];
        ym_d_r     <= oedb[7:0];
        ym_wr_pend <= 1'b1;
      end else if (ym_cen) begin
        ym_wr_pend <= 1'b0;
      end
    end
  end

  wire  [7:0] ym_dout_i;
  wire signed [15:0] ym_l, ym_r;
  wire               ym_sample;
  wire               ym_irq_n;

  jt12 u_ym (
    .rst(!rst_n), .clk(clk), .cen(ym_cen),
    .din(ym_d_r), .addr(ym_a_r),
    .cs_n(!ym_wr_pend), .wr_n(!ym_wr_pend),
    .dout(ym_dout_i), .irq_n(ym_irq_n),
    .en_hifi_pcm(1'b0),
    .snd_right(ym_r), .snd_left(ym_l), .snd_sample(ym_sample)
  );

  // -------------------------------------------------------- device stubs
  assign ym_sel   = sel_ym && ds;
  assign ym_we    = we;
  assign ym_addr  = addr[2:1];
  assign ym_din   = oedb[7:0];
  assign pcm_sel  = (sel_pcm1 | sel_pcm2) && ds;
  assign pcm_we   = we;
  assign pcm_bank = sel_pcm2;
  assign pcm_addr = addr[3:1];
  assign pcm_din  = oedb[7:0];

  // --------------------------------------------------- bus cycle / DTACK
  // Everything but the ROM answers in one cycle. The ROM goes out to memory and
  // the CPU waits, which is the whole reason DTACK is a state and not a wire.
  typedef enum logic [1:0] { B_IDLE, B_ROM, B_ACK } bstate_t;
  bstate_t bst;
  logic [15:0] rom_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst <= B_IDLE; rom_req <= 1'b0; dtackn <= 1'b1; rom_q <= 16'd0;
    end else begin
      case (bst)
        B_IDLE: begin
          dtackn <= 1'b1;
          if (as && ds) begin
            if (sel_rom) begin
              rom_req <= 1'b1;
              bst     <= B_ROM;
            end else begin
              // RAM's registered read has had its cycle by the time the 68000
              // samples DTACK, and everything else is combinational.
              dtackn <= 1'b0;
              bst    <= B_ACK;
            end
          end
        end
        B_ROM: if (rom_ack) begin
          rom_q   <= rom_data;
          rom_req <= 1'b0;
          dtackn  <= 1'b0;
          bst     <= B_ACK;
        end
        B_ACK: if (!as) begin
          dtackn <= 1'b1;
          bst    <= B_IDLE;
        end
      endcase
    end
  end

  // ------------------------------------------------------------- read mux
  // UNWRITTEN MEMORY READS 0xFFFF, NEVER ZERO -- the standing rule, and it is
  // the honest answer for an unmapped address on a bus with pull-ups.
  always_comb begin
    if      (sel_rom)  iedb = rom_q;
    else if (sel_ram)  iedb = {ram_hq, ram_lq};
    else if (sel_uart) iedb = {8'hff, addr[1] ? uart_stat_o : uart_data_o};
    else if (sel_ym)   iedb = {8'hff, ym_dout_i};
    // THE MULTIPCM MUST ANSWER "NOT BUSY" OR THE BOARD NEVER BOOTS. This is a
    // stub, and the value in it is not arbitrary:
    //
    //   00035A: move.b  $c40001.l, D3
    //   000360: btst    #$0, D3
    //   000364: bne     $35a
    //
    // is the first thing the firmware does after clearing RAM, and it spins
    // there until bit 0 clears. Left to the unmapped default of 0xFF the bit is
    // set forever and the 68000 hangs 65,561 instructions in -- having matched
    // MAME exactly up to that point, which is what makes the failure legible.
    //
    // 0x00 says "idle, ready for a command", which is what a real part is a
    // few microseconds after reset and what MAME's ymw258f reports. When the
    // real device arrives this whole branch goes with it.
    else if (sel_pcm1 || sel_pcm2) iedb = 16'hff00;
    else               iedb = 16'hffff;
  end

  // ---------------------------------------------------------------- debug
  logic as_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_pc <= 32'd0; dbg_insns <= 32'd0; as_d <= 1'b0;
      dbg_ym_writes <= 16'd0; dbg_pcm_writes <= 16'd0;
    end else begin
      as_d <= as;
      if (as && !as_d) begin
        dbg_pc <= {8'd0, addr};
        if (!(&dbg_insns)) dbg_insns <= dbg_insns + 32'd1;
        if (sel_ym  && we && !(&dbg_ym_writes))  dbg_ym_writes  <= dbg_ym_writes  + 16'd1;
        if ((sel_pcm1|sel_pcm2) && we && !(&dbg_pcm_writes)) dbg_pcm_writes <= dbg_pcm_writes + 16'd1;
      end
    end
  end

  // Only the FM for now; the MULTIPCMs mix in when they exist.
  assign snd_l = ym_l;
  assign snd_r = ym_r;

  wire _unused = &{1'b0, uart_dout, uart_irq, uart_irq_tx, ym_irq_n, ym_sample, sel_bnk1, sel_bnk2, eab[23:18], 1'b0};

endmodule
