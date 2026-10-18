// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE MODEL 2A SOUND BOARD (study R856-R859): a 68000 at 11.2896 MHz, the
// SCSP (m2_scsp) and their 512 KB of sound RAM, as MAME 0.289's model2.cpp
// has them (BSD-3-Clause; notice in THIRD_PARTY.md). The 68000's map is
// model2_snd's:
//   000000-07ffff  sound RAM (the SCSP's too)        100000-100fff  SCSP
//   400000         the sample bank latch (ignored: no 2A set has more than
//                  8 MB of samples, so MAME's banks are linear)
//   600000-67ffff  program ROM                       800000-ffffff  samples
// At reset the sound RAM is checked (a pattern through the 68000's port,
// read back: dbg_selftest counts the words that came back wrong) and then
// cleared to zero, as MAME's starts (R864); then the first 16 bytes of the
// program ROM are copied into RAM (MAME reset_model2_scsp) -- the 68000 boots
// from RAM -- and it is let go.
// Its interrupts are the SCSP's levels, autovectored (VPA on the acknowledge).
//
// ALL OF IT IS IN SDRAM, on three ports: the 68000's (program, samples and
// RAM, one access at a time; the program and samples through a 1 KB line
// cache, RAM uncached, every RAM write snooped by the SCSP's caches), the
// SCSP's slot fills and the SCSP's DSP. The SCSP runs ahead into an output
// FIFO drained at exactly 44,100 Hz (tick44 counts its timers; the
// accumulator's top six bits give each timer its write's phase, R883).
//
// THE LOADER STORES A 16-BIT WORD LITTLE END FIRST, so a big-endian program
// and its samples read byte-swapped (ROM_SWAP, as m2_sound_board's); RAM is
// written and read by this board alone and keeps the 68000's order.

`timescale 1ns/1ps

module m2_2a_sound #(
  parameter int unsigned AW       = 25,          // SDRAM word address width
  parameter logic [AW:1] RAM_BASE = '0,          // sound RAM, 256 K words
  parameter logic [AW:1] ROM_BASE = '0,          // program ROM, 256 K words
  parameter logic [AW:1] SMP_BASE = '0,          // samples, 4 M words
  parameter bit          ROM_SWAP = 1'b1,
  parameter int unsigned PHI_NUM  = 882,         // 2 x 11.2896 MHz / clk_sys (80 MHz: 882 / 3125)
  parameter int unsigned PHI_DEN  = 3125,
  parameter int unsigned T44_NUM  = 441,         // 44,100 Hz / clk_sys (80 MHz: 441 / 800000)
  parameter int unsigned T44_DEN  = 800000,
  parameter bit          FM       = 1'b1,
  parameter bit          MIDI_OUT = 1'b1,
  parameter bit          CHKSUM   = 1'b0,  // R882: sum the program and the four sample ROMs in SDRAM before boot (a probe build)
  parameter bit          POST_WR  = 1'b1   // R877: the 68000's RAM writes posted (0: DTACK on the SDRAM's acknowledge, as before)
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- MIDI: the i960's UART at the far end of m2_sound_link
  input  logic  [7:0] rx_data,
  input  logic        rx_valid,
  output logic        rx_ack,
  output logic  [7:0] tx_data,
  output logic        tx_valid,
  input  logic        tx_ack,

  // ---- SDRAM: the 68000 (reads return a four-word burst; writes one word)
  output logic        a_req,
  output logic [AW:1] a_addr,
  output logic        a_we,
  output logic [15:0] a_din,
  output logic  [1:0] a_be,
  input  logic        a_ack,
  input  logic [63:0] a_dout,
  // the SCSP's slot fills (read)
  output logic        b_req,
  output logic [AW:1] b_addr,
  input  logic        b_ack,
  input  logic [63:0] b_dout,
  // the SCSP's DSP (read a burst, write a word)
  output logic        c_req,
  output logic [AW:1] c_addr,
  output logic        c_we,
  output logic [15:0] c_din,
  input  logic        c_ack,
  input  logic [63:0] c_dout,

  // ---- the sound
  output logic signed [15:0] snd_l,
  output logic signed [15:0] snd_r,

  // ---- for benches and the debug channel
  output logic [23:0] dbg_addr,          // the 68000's last bus address
  output logic [31:0] dbg_cycles,        // its bus cycles
  output logic [31:0] dbg_samples,       // samples made
  output logic [15:0] dbg_under,         // the FIFO found empty at a drain
  output logic [15:0] dbg_selftest,      // sound-RAM words wrong in the pre-boot check (R864)
  output logic  [3:0] dbg_mvol,          // MVOL as the SCSP holds it
  output logic [15:0] dbg_w400,          // 68000 writes to 0x400-0x401 (MVOL, DAC18, ...)
  output logic [15:0] dbg_w418,          // 68000 writes to 0x418 (timer A)
  output logic [159:0] dbg_sums,         // R882 (CHKSUM): {samples 6-8 MB, 4-6, 2-4, 0-2 MB, program}, each the
                                         // 32-bit sum of its words as the 68000 reads them
  output logic        dbg_scsp_we,       // a 68000 write to the SCSP, this clock
  output logic [11:1] dbg_scsp_a,
  output logic [15:0] dbg_scsp_d,
  output logic  [1:0] dbg_scsp_be
);

  // ----------------------------------------------------------- clock enables
  localparam int PW = $clog2(PHI_DEN) + 1, TW = $clog2(T44_DEN) + 1;   // holds 2 x DEN - 1
  logic [PW-1:0] pacc;
  wire  [PW-1:0] pnx = pacc + PW'(PHI_NUM);
  logic phase, enPhi1, enPhi2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pacc <= '0; phase <= 1'b0; enPhi1 <= 1'b0; enPhi2 <= 1'b0;
    end else begin
      enPhi1 <= 1'b0; enPhi2 <= 1'b0;
      if (pnx >= PW'(PHI_DEN)) begin
        pacc <= pnx - PW'(PHI_DEN); phase <= ~phase;
        if (phase) enPhi2 <= 1'b1; else enPhi1 <= 1'b1;
      end else pacc <= pnx;
    end
  end
  logic [TW-1:0] tacc;
  wire  [TW-1:0] tnx = tacc + TW'(T44_NUM);
  logic tick44;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tacc <= '0; tick44 <= 1'b0; end
    else begin
      tick44 <= 1'b0;
      if (tnx >= TW'(T44_DEN)) begin tacc <= tnx - TW'(T44_DEN); tick44 <= 1'b1; end
      else tacc <= tnx;
    end
  end

  // --------------------------------------------------------------- the 68000
  wire        asn, ldsn, udsn, rwn;
  wire [23:1] eab;
  wire [15:0] oedb;
  logic [15:0] iedb;
  logic        dtackn;
  wire   [2:0] fc;
  logic  [2:0] ipl;
  logic        cpu_go;                    // out of reset, once the vectors are in RAM

  wire as   = !asn;
  wire ds   = !ldsn || !udsn;
  wire iack = as && fc == 3'b111;
  fx68k u_cpu (
    .clk(clk), .HALTn(1'b1),
    .extReset(!cpu_go), .pwrUp(!cpu_go),
    .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(rwn), .ASn(asn), .LDSn(ldsn), .UDSn(udsn),
    .E(), .VMAn(),
    .FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtackn), .VPAn(!iack), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(!ipl[0]), .IPL1n(!ipl[1]), .IPL2n(!ipl[2]),
    .iEdb(iedb), .oEdb(oedb), .eab(eab)
  );
  wire [23:0] addr = {eab, 1'b0};
  wire sel_ram  = addr[23:19] == 5'd0;                       // 000000-07ffff
  wire sel_scsp = addr[23:12] == 12'h100;                    // 100000-100fff
  wire sel_rom  = addr[23:19] == 5'b01100;                   // 600000-67ffff
  wire sel_smp  = addr[23];                                  // 800000-ffffff
  wire sel_bank = addr[23:1] == 23'h20_0000;                 // 400000

  // ------------------------------------------------------- the line cache
  // 128 lines of four words, direct-mapped on the SDRAM word address, for
  // the program and the samples (read-only, so never invalidated)
  localparam int CI = 7;
  wire [AW:1] rom_w = sel_rom ? ROM_BASE + AW'(addr[18:1]) : SMP_BASE + AW'(addr[22:1]);
  (* ramstyle = "M10K" *) logic [63:0] ln_d [1 << CI];
  (* ramstyle = "M10K" *) logic [AW-3-CI:0] ln_t [1 << CI];
  (* ramstyle = "M10K" *) logic ln_v [1 << CI];
  logic [63:0] ln_q;
  logic [AW-3-CI:0] lt_q;
  logic        lv_q, ln_we;
  logic [CI-1:0] ln_wi;
  logic [AW-3-CI:0] ln_wt;
  logic        vclr;                      // clearing the valid bits after reset
  logic [CI-1:0] vclr_i;
  always_ff @(posedge clk) begin
    if (ln_we) begin ln_d[ln_wi] <= a_dout; ln_t[ln_wi] <= ln_wt; end
    if (ln_we || vclr) ln_v[vclr ? vclr_i : ln_wi] <= !vclr;
    ln_q <= ln_d[rom_w[CI+2:3]];
    lt_q <= ln_t[rom_w[CI+2:3]];
    lv_q <= ln_v[rom_w[CI+2:3]];
  end
  wire ln_hit = lv_q && lt_q == rom_w[AW:CI+3];

  // ------------------------------------------------------------------ the SCSP
  logic        s_req, s_ack;
  logic [15:0] s_dout;
  logic        snp;
  logic [18:1] snp_a;
  logic        o_ready, o_valid;
  logic signed [15:0] o_l, o_r;
  logic        sm_req, dm_req, dm_we;
  logic [15:0] sm_line, dm_wdata;
  logic [18:1] dm_addr;
  m2_scsp #(.FM(FM), .MIDI_OUT(MIDI_OUT)) u_scsp (
    .clk(clk), .rst_n(rst_n),
    .cpu_req(s_req), .cpu_we(!rwn), .cpu_addr(addr[11:1]), .cpu_din(oedb), .cpu_be({!udsn, !ldsn}),
    .cpu_ack(s_ack), .cpu_dout(s_dout), .ipl(ipl),
    .midi_data(rx_data), .midi_valid(rx_valid), .midi_ack(rx_ack),
    .mout_data(tx_data), .mout_valid(tx_valid), .mout_ack(tx_ack),
    .sm_req(sm_req), .sm_line(sm_line), .sm_ack(b_ack), .sm_data(b_dout),
    .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_wdata(dm_wdata), .dm_ack(c_ack), .dm_data(c_dout),
    .snp(snp), .snp_addr(snp_a),
    .out_ready(o_ready), .out_valid(o_valid), .out_l_raw(), .out_r_raw(), .out_l(o_l), .out_r(o_r),
    .tick44(tick44), .tph(tacc[TW-2 -: 6]), .step_mode(1'b0), .step_go(1'b0), .quiet(),
    .dbg_slot_valid(), .dbg_slot(), .dbg_slot_smp(), .dbg_samples(dbg_samples), .dbg_miss(),
    .dbg_mvol(dbg_mvol)
  );
  assign b_req  = sm_req;
  assign b_addr = RAM_BASE + AW'({sm_line, 2'b00});
  assign c_req  = dm_req;
  assign c_we   = dm_we;
  assign c_addr = RAM_BASE + AW'(dm_addr);
  assign c_din  = dm_wdata;

  // ---- the output FIFO: 8 samples, drained at 44,100 Hz
  (* ramstyle = "MLAB" *) logic [31:0] fifo [8];
  logic  [2:0] f_w, f_r;
  logic  [3:0] f_n;
  assign o_ready = f_n < 4'd7;
  always_ff @(posedge clk) if (o_valid) fifo[f_w] <= {o_l, o_r};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin f_w <= '0; f_r <= '0; f_n <= '0; snd_l <= '0; snd_r <= '0; dbg_under <= '0; end
    else begin
      if (o_valid) f_w <= f_w + 3'd1;
      if (tick44 && f_n != 4'd0) begin
        {snd_l, snd_r} <= fifo[f_r]; f_r <= f_r + 3'd1;
      end else if (tick44 && !(&dbg_under)) dbg_under <= dbg_under + 16'd1;
      f_n <= f_n + {3'd0, o_valid} - {3'd0, tick44 && f_n != 4'd0};
    end
  end

  // ---------------------------------------------------------------- the bus
  // V_*: before the 68000 runs -- the cache's valid bits cleared (V_CLR); the
  // sound RAM checked: 4 K words written with a pattern (V_TW), every word's
  // upper or lower byte rewritten alone (V_TB, the byte enables), all read back
  // and compared (V_TR); the whole 256 K words cleared to zero (V_ZR); the
  // vector copy (V_RD / V_WR: ROM words 0-7 to RAM words 0-7). Then a 68000
  // cycle at a time.
  // R871: THE BYTE ENABLES DO NOT REACH THE SDRAM (R82: a byte store lands in
  // every lane -- the board, not the controller). A byte write is therefore a
  // read of its line, the byte merged in, and the whole word written back
  // (B_RMR / B_RMW for the 68000; V_TB's two phases for the check), as
  // m2_cpu_bridge does since R729. Every simulation honoured the mask; s1203
  // read the check's 4,088 of 4,096 words wrong -- the 8 that matched are
  // exactly those a lost mask leaves right.
  // R877: A 68000 WRITE TO RAM IS POSTED. MAME gives the RAM one wait state;
  // here a write waited for its SDRAM acknowledge, and on the board under
  // video load that is hundreds of clocks (port 5 is outside m2_sdram's
  // class). VF2's driver writes RAM ~270 K times a second (its rings), so the
  // 68000 spent its time waiting and the rings fell behind the play position.
  // Now the write is acknowledged at once and completes behind the 68000
  // (wpost); the next access that needs port 5 -- RAM, a cache fill -- or the
  // SCSP waits for it, so every later read and the SCSP see the 68000's
  // writes in its own order. The snoop goes out when the write has landed,
  // as before.
  logic        wpost;
  logic [18:1] wpost_a;
  typedef enum logic [4:0] { V_CLR, V_TW, V_TB, V_TR, V_ZR, V_RD, V_WR, B_IDLE, B_LOOK, B_FILL, B_RAM, B_SCSP, B_ACK,
                             B_RMR, B_RMW, B_WPW, V_SUM } bst_t;
  // R882: V_SUM reads the program (256 K words) then the samples (4 M words)
  // four words at a time and sums each region; sk counts words over both
  logic [22:0] sk;
  logic [31:0] sums [5];
  wire         sk_prog = sk < 23'h40000;
  wire  [2:0]  sk_reg  = sk_prog ? 3'd0 : 3'd1 + 3'((sk - 23'h40000) >> 20);
  assign dbg_sums = {sums[4], sums[3], sums[2], sums[1], sums[0]};
  bst_t        bs;
  logic  [2:0] vi;
  logic        tb_ph;                      // V_TB: 0 read the line, 1 write the merged word
  logic [17:0] ti;                         // the check's and the clear's word
  // the check's words: a pattern, then one byte of each rewritten
  function automatic logic [15:0] tpat(input logic [11:0] i);
    tpat = {i[7:0] ^ 8'h5a, i[11:4] ^ 8'hc3};
  endfunction
  function automatic logic [15:0] texp(input logic [11:0] i);
    logic [15:0] p;
    p = tpat(i);
    texp = i[0] ? {p[15:8], ~i[7:0]} : {~i[7:0], p[7:0]};
  endfunction
  logic [63:0] vline;
  logic [15:0] rq;
  function automatic logic [15:0] sat16(input logic [15:0] c, input logic [2:0] n);
    sat16 = (c > 16'hfffb) ? 16'hffff : c + 16'(n);
  endfunction
  function automatic logic [15:0] swp(input logic [15:0] w);
    swp = ROM_SWAP ? {w[7:0], w[15:8]} : w;
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bs <= V_CLR; vi <= '0; ti <= '0; dbg_selftest <= '0; vclr <= 1'b1; vclr_i <= '0; cpu_go <= 1'b0; dtackn <= 1'b1;
      a_req <= 1'b0; a_we <= 1'b0; a_addr <= '0; a_din <= '0; a_be <= 2'b11; ln_we <= 1'b0; tb_ph <= 1'b0;
      s_req <= 1'b0; snp <= 1'b0; rq <= 16'hffff; vline <= '0; ln_wi <= '0; ln_wt <= '0; snp_a <= '0;
      wpost <= 1'b0; wpost_a <= '0; sk <= '0;
      sums[0] <= '0; sums[1] <= '0; sums[2] <= '0; sums[3] <= '0; sums[4] <= '0;
    end else begin
      ln_we <= 1'b0; s_req <= 1'b0; snp <= 1'b0;
      if (wpost && a_ack) begin                       // R877: the posted write has landed
        a_req <= 1'b0; a_we <= 1'b0; wpost <= 1'b0;
        snp <= 1'b1; snp_a <= wpost_a;                // the SCSP's caches see it
      end
      case (bs)
        V_CLR: begin                                  // the cache's valid bits, cleared
          vclr_i <= vclr_i + 1'b1;
          if (&vclr_i) begin vclr <= 1'b0; bs <= V_TW; ti <= '0; end
        end
        V_TW: begin                                   // word ti = the pattern
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b1; a_be <= 2'b11;
            a_addr <= RAM_BASE + AW'(ti[11:0]); a_din <= tpat(ti[11:0]);
          end else if (a_ack) begin
            a_req <= 1'b0; a_we <= 1'b0; ti <= ti + 18'd1;
            if (ti[11:0] == 12'hfff) begin bs <= V_TB; ti <= '0; end
          end
        end
        V_TB: begin                                   // one byte of word ti, alone (R871: merged)
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= tb_ph; a_be <= 2'b11;
            a_addr <= tb_ph ? RAM_BASE + AW'(ti[11:0]) : RAM_BASE + AW'({ti[11:2], 2'b00});
          end else if (a_ack) begin
            a_req <= 1'b0; a_we <= 1'b0;
            if (!tb_ph) begin
              tb_ph <= 1'b1;
              a_din <= ti[0] ? {a_dout[{ti[1:0], 4'd0} + 8 +: 8], ~ti[7:0]}
                             : {~ti[7:0], a_dout[{ti[1:0], 4'd0} +: 8]};
            end else begin
              tb_ph <= 1'b0; ti <= ti + 18'd1;
              if (ti[11:0] == 12'hfff) begin bs <= V_TR; ti <= '0; end
            end
          end
        end
        V_TR: begin                                   // words ti .. ti + 3, compared
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b0; a_addr <= RAM_BASE + AW'({ti[11:2], 2'b00});
          end else if (a_ack) begin
            a_req <= 1'b0;
            dbg_selftest <= sat16(dbg_selftest,
                                  {1'b0, a_dout[15:0]  != texp({ti[11:2], 2'd0})} + {1'b0, a_dout[31:16] != texp({ti[11:2], 2'd1})} +
                                  {1'b0, a_dout[47:32] != texp({ti[11:2], 2'd2})} + {1'b0, a_dout[63:48] != texp({ti[11:2], 2'd3})});
            ti <= ti + 18'd4;
            if (ti[11:2] == 10'h3ff) begin bs <= V_ZR; ti <= '0; end
          end
        end
        V_ZR: begin                                   // the whole sound RAM to zero
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b1; a_be <= 2'b11; a_addr <= RAM_BASE + AW'(ti); a_din <= 16'h0000;
          end else if (a_ack) begin
            a_req <= 1'b0; a_we <= 1'b0; ti <= ti + 18'd1;
            if (&ti) bs <= V_RD;
          end
        end
        V_RD: begin                                   // ROM words vi .. vi + 3
          if (!a_req && !a_ack) begin a_req <= 1'b1; a_we <= 1'b0; a_addr <= ROM_BASE + AW'(vi); end
          else if (a_ack) begin a_req <= 1'b0; vline <= a_dout; bs <= V_WR; end
        end
        V_WR: begin                                   // RAM word vi = ROM word vi
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b1; a_be <= 2'b11;
            a_addr <= RAM_BASE + AW'(vi); a_din <= swp(vline[{vi[1:0], 4'd0} +: 16]);
          end else if (a_ack) begin
            a_req <= 1'b0; a_we <= 1'b0;
            vi <= vi + 3'd1;
            if (vi == 3'd3) bs <= V_RD;
            if (vi == 3'd7) begin
              if (CHKSUM) bs <= V_SUM;
              else begin bs <= B_IDLE; cpu_go <= 1'b1; end
            end
          end
        end
        V_SUM: begin                                  // R882
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b0;
            a_addr <= sk_prog ? ROM_BASE + AW'(sk) : SMP_BASE + AW'(sk - 23'h40000);
          end else if (a_ack) begin
            a_req <= 1'b0;
            sums[sk_reg] <= sums[sk_reg] + 32'(swp(a_dout[15:0])) + 32'(swp(a_dout[31:16]))
                                         + 32'(swp(a_dout[47:32])) + 32'(swp(a_dout[63:48]));
            sk <= sk + 23'd4;
            if (sk == 23'h43FFFC) begin bs <= B_IDLE; cpu_go <= 1'b1; end
          end
        end
        B_IDLE: begin
          dtackn <= 1'b1;
          if (as && ds && !iack) begin
            if (sel_rom || sel_smp) bs <= B_LOOK;     // (the cache reads this clock)
            else if (sel_ram && (wpost || a_ack)) ;   // R877: a posted write first
            else if (sel_ram && !rwn && (udsn != ldsn)) begin   // R871: a byte write, merged
              bs <= B_RMR; a_req <= 1'b1; a_we <= 1'b0; a_be <= 2'b11;
              a_addr <= RAM_BASE + AW'({addr[18:3], 2'b00});
            end else if (sel_ram && !rwn) begin       // R877: a word write, posted
              a_req <= 1'b1; a_we <= 1'b1; a_be <= 2'b11; a_addr <= RAM_BASE + AW'(addr[18:1]); a_din <= oedb;
              wpost <= 1'b1; wpost_a <= addr[18:1];
              rq <= 16'hffff; if (POST_WR) begin dtackn <= 1'b0; bs <= B_ACK; end else bs <= B_WPW;
            end else if (sel_ram) begin
              bs <= B_RAM; a_req <= 1'b1; a_we <= 1'b0; a_be <= 2'b11;
              a_addr <= RAM_BASE + AW'({addr[18:3], 2'b00}); a_din <= oedb;
            end else if (sel_scsp && wpost) ;         // R877: the SCSP after the 68000's RAM writes
            else if (sel_scsp) begin bs <= B_SCSP; s_req <= 1'b1; end
            else begin rq <= 16'hffff; dtackn <= 1'b0; bs <= B_ACK; end   // the bank latch, unmapped
          end
        end
        B_LOOK: begin
          if (ln_hit) begin rq <= swp(ln_q[{rom_w[2:1], 4'd0} +: 16]); dtackn <= 1'b0; bs <= B_ACK; end
          else if (!wpost && !a_ack) begin bs <= B_FILL; a_req <= 1'b1; a_we <= 1'b0; a_addr <= {rom_w[AW:3], 2'b00}; end   // R877
        end
        B_FILL: if (a_ack) begin
          a_req <= 1'b0; ln_we <= 1'b1; ln_wi <= rom_w[CI+2:3]; ln_wt <= rom_w[AW:CI+3];
          rq <= swp(a_dout[{rom_w[2:1], 4'd0} +: 16]); dtackn <= 1'b0; bs <= B_ACK;
        end
        B_RAM: if (a_ack) begin                       // (a read: R877 posts the writes)
          a_req <= 1'b0; a_we <= 1'b0;
          rq <= a_dout[{addr[2:1], 4'd0} +: 16];
          dtackn <= 1'b0; bs <= B_ACK;
        end
        B_RMR: if (a_ack) begin                       // R871: the word, its other byte kept
          a_req <= 1'b0;
          a_din <= udsn ? {a_dout[{addr[2:1], 4'd0} + 8 +: 8], oedb[7:0]}
                        : {oedb[15:8], a_dout[{addr[2:1], 4'd0} +: 8]};
          bs <= B_RMW;
        end
        B_RMW: begin                                  // and written whole -- posted (R877)
          if (!a_req && !a_ack) begin
            a_req <= 1'b1; a_we <= 1'b1; a_be <= 2'b11; a_addr <= RAM_BASE + AW'(addr[18:1]);
            wpost <= 1'b1; wpost_a <= addr[18:1];
            rq <= 16'hffff; if (POST_WR) begin dtackn <= 1'b0; bs <= B_ACK; end else bs <= B_WPW;
          end
        end
        B_WPW: if (a_ack) begin dtackn <= 1'b0; bs <= B_ACK; end   // R877, POST_WR 0: the write's acknowledge first
        B_SCSP: if (s_ack) begin rq <= s_dout; dtackn <= 1'b0; bs <= B_ACK; end
        default: if (!as) begin dtackn <= 1'b1; bs <= B_IDLE; end   // B_ACK
      endcase
    end
  end
  assign iedb = rq;

  // ---------------------------------------------------------------- debug
  logic as_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dbg_addr <= '0; dbg_cycles <= '0; as_d <= 1'b0; dbg_w400 <= '0; dbg_w418 <= '0; end
    else begin
      if (s_req && !rwn && addr[11:1] == 11'h200 && !(&dbg_w400)) dbg_w400 <= dbg_w400 + 16'd1;
      if (s_req && !rwn && addr[11:1] == 11'h20c && !(&dbg_w418)) dbg_w418 <= dbg_w418 + 16'd1;
      as_d <= as;
      if (as && !as_d) begin
        dbg_addr <= addr;
        if (!(&dbg_cycles)) dbg_cycles <= dbg_cycles + 32'd1;
      end
    end
  end
  assign dbg_scsp_we = s_req && !rwn;
  assign dbg_scsp_a  = addr[11:1];
  assign dbg_scsp_d  = oedb;
  assign dbg_scsp_be = {!udsn, !ldsn};

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, sel_bank, addr[0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
