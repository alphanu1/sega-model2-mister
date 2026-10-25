// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP's EFFECTS DSP (study R856, R858). Written against MAME 0.289's
// src/devices/sound/scspdsp.cpp (BSD-3-Clause, ElSemi, R. Belmont; notice in
// THIRD_PARTY.md) and following it step for step, quirks included:
//   * a run is LastStep steps -- the last non-zero MPRO step + 1, found when
//     the 68000 writes MPRO word 0xBF0 (MAME's Start()); until that write the
//     DSP is stopped: EFREG keeps its value and MIXS is never cleared;
//   * EFREG cleared before a run, MIXS after it (sixteen writes each);
//   * memory only on odd steps; MEMVAL is the latest read, taken by IWT;
//   * IRA > 0x31 abandons the run (no DEC step, MIXS kept);
//   * ACC is MAME's 32-bit int; SHIFTED, the sign extensions, FRC, Y_REG,
//     ADRS_REG, PACK / UNPACK exactly as MAME has them.
//
// SERIALISED (R858): five clocks a step and one multiplier for everything --
// the step's X x Y, PACK's shift (x 2^e) and UNPACK's (x 2^(11 - e), >> 11).
//   ph 0  the MPRO row is read
//   ph 1  the operands' RAMs are read (TEMP, MEMS, MIXS, COEF, MADRS, EFREG)
//   ph 2  X x Y starts (a memory step waits here for the port and MEMVAL)
//   ph 3  PACK's shift starts (a write step)
//   ph 4  ACC = (X x Y) >> 12 + B; the step's writes, all from the old ACC's
//         SHIFTED; the memory read is asked for; the next step's ph 0
// A write's packed word is taken the clock after ph 4. An UNPACK multiplies
// in a clock nobody else does (ph 0 or 1).
//
// The ring buffer is in SDRAM behind a 64-line cache (m2_scsp_cache); a DSP
// write goes out on the port and invalidates its line at once, the 68000's
// writes are snooped when they land; one port, in order, so a refill never
// overtakes a write.

`timescale 1ns/1ps

module m2_scsp_dsp #(
  // R914: 0x7c0-0x7ff is NOT MADRS: writes there are dropped and reads give
  // 0 (Mednafen's SCSP decodes MADRS at 0x780-0x7bf only; MASA names 32).
  // MAME 0.289 mirrors it onto MADRS (an array-bounds fix of 2014, not a
  // hardware finding), and every 2A driver writes 32 zero words there right
  // after its MADRS table -- so in MAME every game's DSP runs with all
  // MADRS 0. 1 restores MAME's mirror (benches: equal to MAME's mix).
  parameter bit MADRS_MIRROR = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        go,                 // run one sample's program (when !busy)
  output logic        done,               // pulse
  output logic        busy,               // a run, or the LastStep scan
  input  logic  [1:0] rbl,
  input  logic  [5:0] rbp,
  // MIXS: the slots' sends; mix_sel is held a clock before mix_we
  input  logic  [3:0] mix_sel,
  input  logic        mix_we,
  input  logic [19:0] mix_val,
  // EFREG for the effect returns (registered read)
  input  logic  [3:0] ef_idx,
  output logic signed [15:0] ef_q,
  // the 68000's writes: byte offset [11:1], 0x700-0xbff
  input  logic        w_en,
  input  logic [11:1] w_addr,
  input  logic [15:0] w_data,
  input  logic  [1:0] w_be,
  input  logic [11:1] r_addr,             // the 68000 reads COEF / MADRS / MPRO (when idle):
  output logic [15:0] r_q,                // r_q the clock after r_addr
  // sound RAM (word address), one access at a time; req falls for a clock
  // after every ack
  output logic        m_req,
  output logic        m_we,
  output logic [18:1] m_addr,
  output logic [15:0] m_wdata,
  input  logic        m_ack,
  input  logic [63:0] m_data,
  input  logic        snp,                // a 68000 write landed
  input  logic [18:1] snp_addr,
  output logic        wr_done,            // a DSP write landed
  output logic [18:1] wr_addr,
  output logic [31:0] dbg_stall,
  input  logic        dbg_on              // benches: trace each step (SCSP_DEBUG builds)
);

  // ------------------------------------------------------------------ RAMs
  // MPRO: 128 x 64; word j of a step in [16j+15:16j]
  (* ramstyle = "M10K" *) logic [7:0][7:0] mpro [128];
  logic  [6:0] mp_ra;
  logic [63:0] mp_q;
  wire         w_mpro = w_en && w_addr >= 11'h400 && w_addr < 11'h600;
  always_ff @(posedge clk) begin
    if (w_mpro) begin
      if (w_be[0]) mpro[w_addr[9:3]][{w_addr[2:1], 1'b0}] <= w_data[7:0];
      if (w_be[1]) mpro[w_addr[9:3]][{w_addr[2:1], 1'b1}] <= w_data[15:8];
    end
    mp_q <= mpro[mp_ra];
  end
  // COEF 64 x 16, MADRS 32 x 16 (0x780; MAME's mirror at 0x7c0 only with MADRS_MIRROR, R914)
  (* ramstyle = "MLAB" *) logic [7:0] coef_h [64];
  (* ramstyle = "MLAB" *) logic [7:0] coef_l [64];
  (* ramstyle = "MLAB" *) logic [7:0] madrs_h [32];
  (* ramstyle = "MLAB" *) logic [7:0] madrs_l [32];
  wire w_coef  = w_en && w_addr >= 11'h380 && w_addr < 11'h3c0;
  wire w_madrs = w_en && w_addr >= 11'h3c0 && w_addr < (MADRS_MIRROR ? 11'h400 : 11'h3e0);
  logic [15:0] coef_q, madrs_q;
  logic  [5:0] co_ra;
  logic  [4:0] ma_ra;
  always_ff @(posedge clk) begin
    if (w_coef  && w_be[1]) coef_h[w_addr[6:1]]  <= w_data[15:8];
    if (w_coef  && w_be[0]) coef_l[w_addr[6:1]]  <= w_data[7:0];
    if (w_madrs && w_be[1]) madrs_h[w_addr[5:1]] <= w_data[15:8];
    if (w_madrs && w_be[0]) madrs_l[w_addr[5:1]] <= w_data[7:0];
    coef_q  <= {coef_h[co_ra], coef_l[co_ra]};
    madrs_q <= {madrs_h[ma_ra], madrs_l[ma_ra]};
  end
  // the 68000's read: 0x700 COEF, 0x780 MADRS, 0x7c0 0 (MAME: MADRS again,
  // MADRS_MIRROR), 0x800 MPRO
  assign r_q = (r_addr < 11'h3c0) ? coef_q :
               (r_addr < 11'h3e0 || (MADRS_MIRROR && r_addr < 11'h400)) ? madrs_q :
               (r_addr < 11'h400) ? 16'd0 : mp_q[{r_addr[2:1], 4'd0} +: 16];

  // TEMP 128 x 24, MEMS 32 x 24
  (* ramstyle = "M10K" *) logic [23:0] temp [128];
  // (R909: mems stays M10K. As an MLAB it takes ins -- mpro's read register,
  // which IRA comes from -- as its read address, and mpro becomes logic.)
  (* ramstyle = "M10K" *) logic [23:0] mems [32];
  logic  [6:0] t_ra, t_wa;
  logic        t_we, ms_we;
  logic [23:0] t_q, ms_q;
  // MIXS 16 x 20 and EFREG 16 x 16; MAME's all-at-once clears are sixteen
  // clocks of writes (EFREG before a run, MIXS after it, both after reset)
  (* ramstyle = "MLAB" *) logic [19:0] mixs [16];
  (* ramstyle = "MLAB" *) logic [15:0] efreg [16];
  logic  [3:0] mx_ra, ef_ra, clr_i;
  logic [19:0] mx_q;
  logic [15:0] ef_rq;
  logic        ef_we;

  // ------------------------------------------------------------------ state
  typedef enum logic [2:0] { D_IDLE, D_SCAN, D_RUN, D_FIN, D_CLRE, D_CLRM } dst_t;
  dst_t        dst;
  logic  [2:0] ph;
  logic  [7:0] k;
  logic        stopped;
  logic  [7:0] last_step;                 // 0..128
  logic [15:0] dec;
  logic  [6:0] scan_i;
  logic        sc_wait;
  logic signed [31:0] acc;
  logic signed [24:0] memval;             // 25 bits: NOFL's word << 8 is a positive int in MAME
  logic        mv_pend;                   // a read in flight (to MEMVAL)
  logic [12:0] frc;
  logic [23:0] yreg;
  logic [11:0] adrs;
  logic [15:0] a_off;                     // R959: DEC / ADRS / NXADR summed (below)
  logic        pk_take;                   // the packed word is in P this clock
  logic        go_p;                      // a go taken while the reset's clears run
  logic        w_pend, w_out, gap;        // a write waiting; on the port
  logic [18:1] w_a;
  logic [15:0] w_d;
  logic  [3:0] pk_e, pk_e_r;
  logic        pk_s;
  logic signed [24:0] inputs;
  logic signed [23:0] shifted;
  logic        abort, mem_now, stall;
  logic [31:0] addr_w;
  logic        wr_snp;

  // one multiplier: X x Y, PACK, UNPACK
  logic signed [24:0] mul_a;
  logic signed [12:0] mul_b;
  (* multstyle = "dsp" *) logic signed [37:0] prod;
  always_ff @(posedge clk) prod <= mul_a * mul_b;

  // the step: MPRO's output, which holds while k does.
  // R959: TWO COPIES OF IT. The RAMs' read addresses (ph 1, and EFREG's for
  // ef_q) take MPRO's output straight, as before (a_*); everything the step
  // decides in ph 2-4 takes ins, MPRO's output a clock later in a register,
  // which takes the M10K's clock-to-out off the paths into the multiplier's
  // operands (the worst clk_sys paths, s1479). The row is read in ph 0 and
  // holds from ph 1 until k moves in ph 4, so in ph 2-4 ins is mp_q, bit for
  // bit -- MPRO is written only by the 68000, which m2_scsp holds off while
  // the DSP is busy (op_ok), so no write lands in a run's steps.
  logic [63:0] ins;
  always_ff @(posedge clk) ins <= mp_q;
  wire  [6:0] a_TRA   = mp_q[14:8];
  wire  [5:0] a_IRA   = mp_q[27:22];
  wire  [3:0] a_EWA   = mp_q[43:40];
  wire  [5:0] a_COEFI = mp_q[62:57];
  wire  [4:0] a_MASA  = mp_q[54:50];
  wire        TWT   = ins[7];
  wire  [6:0] TWA   = ins[6:0];
  wire        XSEL  = ins[31];
  wire  [1:0] YSEL  = ins[30:29];
  wire  [5:0] IRA   = ins[27:22];
  wire        IWT   = ins[21];
  wire  [4:0] IWA   = ins[20:16];
  wire        TABLE = ins[47];
  wire        MWT   = ins[46];
  wire        MRD   = ins[45];
  wire        EWT   = ins[44];
  wire  [3:0] EWA   = ins[43:40];
  wire        ADRL  = ins[39];
  wire        FRCL  = ins[38];
  wire  [1:0] SHFT  = ins[37:36];
  wire        YRL   = ins[35];
  wire        NEGB  = ins[34];
  wire        ZERO  = ins[33];
  wire        BSEL  = ins[32];
  wire        NOFL  = ins[63];
  wire        ADREB = ins[49];
  wire        NXADR = ins[48];

  always_ff @(posedge clk) begin
    if (t_we)  temp[t_wa] <= shifted;
    if (ms_we) mems[IWA]  <= memval[23:0];
    t_q   <= temp[t_ra];
    ms_q  <= mems[a_IRA[4:0]];
    mx_q  <= mixs[mx_ra];
    ef_rq <= efreg[ef_ra];
    if (dst == D_CLRM) mixs[clr_i] <= 20'd0;
    else if (mix_we) mixs[mix_sel] <= mx_q + mix_val;
    if (dst == D_CLRE) efreg[clr_i] <= 16'd0;
    else if (ef_we) efreg[EWA] <= ef_rq + shifted[23:8];
  end
  assign ef_q  = ef_rq;

  // ------------------------------------------------------------------ a step
  always_comb begin
    logic [31:0] a, mask;
    logic signed [31:0] acc2;
    abort = 1'b0;
    if (IRA <= 6'h1f)      inputs = {ms_q[23], ms_q};
    else if (IRA <= 6'h2f) inputs = {mx_q[19], mx_q, 4'd0};
    else if (IRA <= 6'h31) inputs = 25'd0;            // EXTS: no external input on Model 2
    else begin inputs = 25'd0; abort = 1'b1; end
    if (IWT && IRA == {1'b0, IWA}) inputs = memval;
    acc2 = acc <<< 1;
    case (SHFT)                                       // SHIFTED: MAME's clamp to 24 bits
      2'd0:    shifted = (acc[31:23] == {9{acc[31]}}) ? acc[23:0] : acc[31] ? -24'sh800000 : 24'sh7fffff;
      2'd1:    shifted = (acc2[31:23] == {9{acc2[31]}}) ? acc2[23:0] : acc2[31] ? -24'sh800000 : 24'sh7fffff;
      2'd2:    shifted = acc2[23:0];
      default: shifted = acc[23:0];
    endcase
    a = {16'd0, madrs_q + a_off};                     // (R959: a_off below)
    mask = TABLE ? 32'h0000ffff : ((32'h2000 << rbl) - 32'd1);
    addr_w = (a & mask) + {14'd0, rbp, 12'd0};
    mem_now = (MRD || MWT) && k[0];
  end
  assign stall = (IWT && mv_pend) || (mem_now && (mv_pend || w_pend));

  // R959: the ring address's offset, MADRS's addend -- (TABLE ? 0 : DEC) +
  // (ADREB ? ADRS : 0) + NXADR -- a register, so MADRS + DEC + ADRS + 1 is one
  // add after MADRS's read and not three. addr_w is used in ph 3 (PACK's start)
  // and ph 4 only; a_off there is the clock before's sum, and none of its terms
  // moves between ph 2 and ph 4 (ins holds, DEC moves in D_FIN, ADRS in ph 4's
  // edge or on a go). Sixteen bits: the mask keeps at most bits 15..0 of the sum.
  always_ff @(posedge clk)
    a_off <= (TABLE ? 16'd0 : dec) + (ADREB ? {4'd0, adrs} : 16'd0) + {15'd0, NXADR};

  // PACK's exponent: the leading sign bits of SHIFTED, at most 12
  always_comb begin
    logic [23:0] t;
    t = shifted ^ {shifted[22:0], 1'b0};
    pk_e = 4'd12;
    for (int i = 11; i >= 0; i--) if (t[23 - i]) pk_e = 4'(i);
  end

  // ------------------------------------------------------------------ memory
  logic        lk_req, lk_hit, fill_req, fill_done;
  logic [15:0] lk_line, c_mline;
  logic [63:0] lk_data, fill_data;
  logic        c_mreq;
  logic [18:1] r_a;
  logic        r_nofl;
  typedef enum logic [2:0] { R_IDLE, R_LOOK, R_FILL, R_AGAIN, R_UNP } rst_t;
  rst_t        rs;
  logic [15:0] r_word;
  // R914: 256 lines, not 64 -- the same M10K (a 64-deep array already took
  // the 256-deep blocks); with real MADRS the taps sit on different lines
  m2_scsp_cache #(.IDX(8)) u_rcache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(lk_req), .lk_line(lk_line), .lk_hit(lk_hit), .lk_data(lk_data),
    .fill_req(fill_req), .fill_line(r_a[18:3]), .fill_done(fill_done), .fill_data(fill_data),
    .m_req(c_mreq), .m_line(c_mline), .m_ack(m_ack && !w_out), .m_data(m_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(wr_snp), .snp2_line(w_a[18:3]),
    .dbg_fills()
  );
  always_comb begin
    m_we = w_out; m_wdata = w_d;
    m_addr = w_out ? w_a : {c_mline, 2'b00};
    m_req = !gap && (w_out || c_mreq);
  end
  assign wr_addr = w_a;

  // UNPACK's operand: {sign, ~sign (or sign past exponent 11), mantissa << 11}
  wire  [3:0] up_e  = r_word[14:11];
  wire [23:0] up_u  = {r_word[15], (up_e > 4'd11) ? r_word[15] : ~r_word[15], r_word[10:0], 11'd0};
  wire  [3:0] up_sh = (up_e > 4'd11) ? 4'd0 : 4'd11 - up_e;        // u >> e = (u x 2^(11 - e)) >> 11

  // ------------------------------------------------------------------ the operands of the multiplier
  wire run_ph2 = dst == D_RUN && ph == 3'd2;
  wire exec2   = run_ph2 && !stall && !abort;           // the step goes on past ph 2
  wire pk_go   = dst == D_RUN && ph == 3'd3 && mem_now && MWT && addr_w < 32'h40000;
  wire up_go   = rs == R_UNP && !exec2 && !pk_go;           // (a stalled ph 2 starts nothing)
  logic up_take, up_take2;
  always_ff @(posedge clk) begin
    if (exec2) begin
      mul_a <= XSEL ? inputs : {t_q[23], t_q};
      case (YSEL)
        2'd0:    mul_b <= $signed(frc);
        2'd1:    mul_b <= $signed(coef_q[15:3]);
        2'd2:    mul_b <= $signed(yreg[23:11]);
        default: mul_b <= $signed({1'b0, yreg[15:4]});
      endcase
    end else if (pk_go) begin
      mul_a <= {shifted[23], shifted};
      mul_b <= $signed(13'(1) << ((pk_e == 4'd12) ? 4'd11 : pk_e));
    end else if (up_go) begin
      mul_a <= {up_u[23], up_u};
      mul_b <= $signed(13'(1) << up_sh);
    end
  end

  // ------------------------------------------------------------------ sequencer
  wire ph4 = dst == D_RUN && ph == 3'd4;
  // B: ZERO ? 0 : BSEL ? ACC : TEMP (sign-extended), NEGB subtracts it
  wire signed [31:0] b_sel = ZERO ? 32'sd0 : BSEL ? acc : {{8{t_q[23]}}, t_q};
  wire signed [31:0] acc_n = NEGB ? 32'(prod >>> 12) - b_sel : 32'(prod >>> 12) + b_sel;

  always_comb begin
    mp_ra = (dst == D_SCAN) ? scan_i : (dst == D_IDLE) ? r_addr[9:3] : k[6:0];
    t_ra  = a_TRA + dec[6:0];
    t_wa  = TWA + dec[6:0];
    co_ra = (dst == D_IDLE) ? r_addr[6:1] : a_COEFI;
    ma_ra = (dst == D_IDLE) ? r_addr[5:1] : a_MASA;
    mx_ra = (dst == D_RUN) ? a_IRA[3:0] : mix_sel;
    ef_ra = (dst == D_RUN) ? a_EWA : ef_idx;
    t_we  = ph4 && TWT;
    ef_we = ph4 && EWT;
    ms_we = ph4 && IWT;
    lk_req = (ph4 && MRD && mem_now && addr_w < 32'h40000) || rs == R_AGAIN;
    lk_line = (rs == R_AGAIN) ? r_a[18:3] : addr_w[17:2];
    fill_req = rs == R_FILL;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst <= D_CLRE; clr_i <= 4'd0; go_p <= 1'b0; stopped <= 1'b1; last_step <= 8'd0; dec <= 16'd0; done <= 1'b0;
      mv_pend <= 1'b0; rs <= R_IDLE;
      w_out <= 1'b0; w_pend <= 1'b0; gap <= 1'b0; wr_done <= 1'b0; wr_snp <= 1'b0;
      acc <= 32'sd0; ph <= 3'd0; k <= 8'd0; dbg_stall <= '0; pk_take <= 1'b0;
      up_take <= 1'b0; up_take2 <= 1'b0;
      sc_wait <= 1'b0; scan_i <= 7'd0; frc <= '0; yreg <= '0; adrs <= '0; memval <= '0;
      w_a <= '0; w_d <= '0; r_a <= '0; r_nofl <= 1'b0; r_word <= '0; pk_s <= 1'b0;
    end else begin
      done <= 1'b0; wr_done <= 1'b0; wr_snp <= 1'b0;
      gap <= m_req && m_ack;
      if (go && dst != D_IDLE) go_p <= 1'b1;


      // a write goes out once no read is in flight: MAME reads before it
      // writes in a step that does both, so the read (and its fill) go first
      if (w_out && m_ack) begin w_out <= 1'b0; w_pend <= 1'b0; wr_done <= 1'b1; end
      else if (w_pend && !pk_take && !w_out && !mv_pend && !gap) begin
        // out on the port, and its line invalidated now -- after this step's read
        // and its fill, before any later read (which waits for the write)
        w_out <= 1'b1; wr_snp <= 1'b1;
      end
      // the packed word: {sign, exponent, the shifted value's bits 21..11}
      pk_take <= 1'b0;
      if (pk_take) w_d <= {pk_s, pk_e_r, prod[21:11]};

      // a read: lookup, fill, then UNPACK through the multiplier
      up_take <= up_go; up_take2 <= up_take;
      case (rs)
        R_LOOK: begin
          if (lk_hit) begin
            r_word <= lk_data[{r_a[2:1], 4'b0} +: 16];
            if (r_nofl) begin memval <= {1'b0, lk_data[{r_a[2:1], 4'b0} +: 16], 8'd0}; mv_pend <= 1'b0; rs <= R_IDLE; end
            else rs <= R_UNP;
          end else rs <= R_FILL;
        end
        R_FILL: if (fill_done) rs <= R_AGAIN;          // and look again
        R_AGAIN: rs <= R_LOOK;
        R_UNP: if (up_go) rs <= R_IDLE;
        default: ;
      endcase
      if (up_take2) begin memval <= {prod[34], prod[34:11]}; mv_pend <= 1'b0; end

      if (run_ph2 && stall && !(&dbg_stall)) dbg_stall <= dbg_stall + 32'd1;

      case (dst)
        D_IDLE: begin
          if (w_en && w_addr == 11'h5f8) begin            // 0xBF0: MAME's Start()
            dst <= D_SCAN; scan_i <= 7'd127; sc_wait <= 1'b1; stopped <= 1'b0;
          end else if (go || go_p) begin
            go_p <= 1'b0;
            if (stopped) done <= 1'b1;
            else begin
              acc <= 32'sd0; frc <= '0; yreg <= '0; adrs <= '0; memval <= '0;
              k <= 8'd0; ph <= 3'd0; clr_i <= 4'd0;
              dst <= D_CLRE;                              // EFREG cleared, then the run
            end
          end
        end
        D_SCAN: begin
          if (sc_wait) sc_wait <= 1'b0;                   // row scan_i being read
          else if (|mp_q) begin last_step <= {1'b0, scan_i} + 8'd1; dst <= D_IDLE; end
          else if (scan_i == 7'd0) begin last_step <= 8'd0; dst <= D_IDLE; end
          else begin scan_i <= scan_i - 7'd1; sc_wait <= 1'b1; end
        end
        D_RUN: begin
          case (ph)
            3'd2: begin
              if (abort) begin dst <= D_IDLE; done <= 1'b1; end   // MAME returns: no DEC, MIXS kept
              else if (!stall) ph <= 3'd3;
            end
            3'd3: begin
              ph <= 3'd4;
              if (pk_go) begin pk_s <= shifted[23]; pk_e_r <= pk_e; end
            end
            3'd4: begin
`ifdef SCSP_DEBUG
              if (dbg_on) $display("R k %0d acc %0d sh %0d in %0d b %0d mv %0d dec %0d a %h mem %0d ira %h iwt %0d iwa %0d mxq %h mz %h",
                                   k, acc, shifted, inputs, b_sel, memval, dec, addr_w, mem_now, IRA, IWT, IWA, mx_q, 16'd0);
`endif
              acc <= acc_n;
              if (YRL)  yreg <= inputs[23:0];
              if (FRCL) frc  <= (SHFT == 2'd3) ? {1'b0, shifted[11:0]} : shifted[23:11];
              if (ADRL) adrs <= (SHFT == 2'd3) ? shifted[23:12] : {{4{inputs[24]}}, inputs[23:16]};
              if (mem_now && MRD) begin
                r_a <= addr_w[17:0]; r_nofl <= NOFL;
                if (addr_w < 32'h40000) begin rs <= R_LOOK; mv_pend <= 1'b1; end
                else memval <= NOFL ? 25'd0 : 25'h0400000;   // unmapped: MAME reads 0 (UNPACK(0) = 0x400000)
              end
              if (mem_now && MWT && addr_w < 32'h40000) begin
                w_pend <= 1'b1; w_a <= addr_w[17:0];
                if (NOFL) w_d <= shifted[23:8];
                else pk_take <= 1'b1;
              end
              if ({1'b0, k} + 9'd1 == {1'b0, last_step}) dst <= D_FIN;
              k <= k + 8'd1; ph <= 3'd0;
            end
            default: ph <= ph + 3'd1;                     // ph 0, 1
          endcase
        end
        D_CLRE: begin
          clr_i <= clr_i + 4'd1;
          if (clr_i == 4'd15) dst <= stopped ? D_CLRM : (last_step == 8'd0) ? D_FIN : D_RUN;   // (after reset: MIXS too)
        end
        D_CLRM: begin
          clr_i <= clr_i + 4'd1;
          if (clr_i == 4'd15) begin dst <= D_IDLE; if (!stopped) done <= 1'b1; end
        end
        default: begin   // D_FIN: MAME's end of Step(), then MIXS cleared
          if (!pk_take) begin
            dec <= dec - 16'd1; clr_i <= 4'd0; dst <= D_CLRM;
          end
        end
      endcase
    end
  end
  assign busy = dst != D_IDLE;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, ins[56:55], ins[28], ins[15], ins[14:8], ins[62:57], ins[54:50], a_IRA[5], c_mline[15:15], fill_data, addr_w[31:18], prod[37:35]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
