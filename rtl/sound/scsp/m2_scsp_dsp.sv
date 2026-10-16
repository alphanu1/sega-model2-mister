// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP's EFFECTS DSP (study R856). Written against MAME 0.289's
// src/devices/sound/scspdsp.cpp (BSD-3-Clause, ElSemi, R. Belmont; notice in
// THIRD_PARTY.md) and following it step for step, quirks included:
//   * a run is LastStep steps -- the last non-zero MPRO step + 1, found when
//     the 68000 writes MPRO word 0xBF0 (MAME's Start()); until that write the
//     DSP is stopped: EFREG keeps its value and MIXS is never cleared;
//   * memory only on odd steps; MEMVAL is the latest read, taken by IWT;
//   * IRA > 0x31 abandons the run (no DEC step, MIXS kept);
//   * ACC is MAME's 32-bit int; SHIFTED, the sign extensions, FRC, Y_REG,
//     ADRS_REG, PACK / UNPACK exactly as MAME has them.
// Three clocks a step: ph 0 the MPRO row is read, ph 1 the operands are read,
// ph 2 the step executes (its writes, its memory access, the multiply's
// operands); the product is registered one clock later and ACC the clock
// after, in time for the next step's execute. A memory read stalls only a
// step that needs MEMVAL or the port.
//
// The ring buffer is in SDRAM behind a 64-line cache (m2_scsp_cache); a DSP
// write goes out on the port and invalidates its line at once, the 68000's
// writes are snooped when they land; one port, in order, so a refill never
// overtakes a write.

`timescale 1ns/1ps

module m2_scsp_dsp (
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
  // COEF 64 x 16, MADRS 32 x 16 (0x780 and its mirror 0x7c0): registered
  // reads, addressed from the step's row in ph 1, in for its execute
  (* ramstyle = "MLAB" *) logic [7:0] coef_h [64];
  (* ramstyle = "MLAB" *) logic [7:0] coef_l [64];
  (* ramstyle = "MLAB" *) logic [7:0] madrs_h [32];
  (* ramstyle = "MLAB" *) logic [7:0] madrs_l [32];
  wire w_coef  = w_en && w_addr >= 11'h380 && w_addr < 11'h3c0;
  wire w_madrs = w_en && w_addr >= 11'h3c0 && w_addr < 11'h400;
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
  // the 68000's read (MAME r16): 0x700 COEF, 0x780 / 0x7c0 MADRS, 0x800 MPRO
  assign r_q = (r_addr < 11'h3c0) ? coef_q : (r_addr < 11'h400) ? madrs_q : mp_q[{r_addr[2:1], 4'd0} +: 16];

  // TEMP 128 x 24, MEMS 32 x 24
  (* ramstyle = "M10K" *) logic [23:0] temp [128];
  (* ramstyle = "M10K" *) logic [23:0] mems [32];
  logic  [6:0] t_ra, t_wa;
  logic  [4:0] m_ra;
  logic        t_we, ms_we;
  logic [23:0] t_q, ms_q;
  // MIXS 16 x 20 and EFREG 16 x 16, each with a "reads as 0" mask for MAME's
  // all-at-once clears
  (* ramstyle = "MLAB" *) logic [19:0] mixs [16];
  logic [15:0] mixs_z;
  (* ramstyle = "MLAB" *) logic [15:0] efreg [16];
  logic [15:0] ef_z;
  logic  [3:0] mx_ra, ef_ra;
  logic [19:0] mx_raw, mx_q;
  logic [15:0] ef_raw, ef_rq;
  logic        mx_zr, ef_zr;

  // ------------------------------------------------------------------ state
  logic signed [24:0] inputs, x_v;
  logic signed [23:0] shifted;
  logic signed [31:0] b_v;
  logic signed [12:0] y_v;
  logic [15:0] mad, coef_w;
  logic [31:0] addr_w;
  logic        mem_now, stall, abort, exec, ef_we;
  logic        stopped;
  logic  [7:0] last_step;                 // 0..128
  logic [15:0] dec;
  typedef enum logic [1:0] { D_IDLE, D_SCAN, D_RUN, D_FIN } dst_t;
  dst_t        dst;
  logic  [6:0] scan_i;
  logic        sc_wait;
  logic  [7:0] k;
  logic  [1:0] ph;
  logic signed [31:0] acc;
  logic signed [24:0] memval;             // 25 bits: NOFL's word << 8 is a positive int in MAME
  logic        mv_pend;
  logic [12:0] frc;
  logic [23:0] yreg;
  logic [11:0] adrs;
  logic  [1:0] mul_v;
  logic signed [31:0] b_r;
  logic signed [24:0] mx_x;
  logic signed [12:0] mx_y;
  (* multstyle = "dsp" *) logic signed [37:0] prod;
  always_ff @(posedge clk) prod <= mx_x * mx_y;

  // the step: MPRO's output, which holds while k does (ph 1 to the end of ph 2)
  wire  [63:0] ins = mp_q;
  wire  [6:0] TRA   = ins[14:8];
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
  wire  [5:0] COEFI = ins[62:57];
  wire  [4:0] MASA  = ins[54:50];
  wire        ADREB = ins[49];
  wire        NXADR = ins[48];

  always_ff @(posedge clk) begin
    if (t_we)  temp[t_wa] <= shifted;
    if (ms_we) mems[IWA]  <= memval[23:0];
    t_q   <= temp[t_ra];
    ms_q  <= mems[m_ra];
    mx_raw <= mixs[mx_ra];
    ef_raw <= efreg[ef_ra];
    mx_zr  <= mixs_z[mx_ra];
    ef_zr  <= ef_z[ef_ra];
    if (mix_we) mixs[mix_sel] <= mx_q + mix_val;
    if (ef_we)  efreg[EWA] <= ef_rq + shifted[23:8];
  end
  assign mx_q  = mx_zr ? 20'd0 : mx_raw;
  assign ef_rq = ef_zr ? 16'd0 : ef_raw;

  // MAME's clamp to 24 bits (x > 0x7fffff, x < -0x800000), by the sign bits
  function automatic logic signed [23:0] sat24(input logic signed [31:0] x);
    if (x[31:23] == {9{x[31]}}) sat24 = x[23:0];
    else sat24 = x[31] ? -24'sh800000 : 24'sh7fffff;
  endfunction

  // PACK / UNPACK (MAME's)
  function automatic logic [15:0] pack(input logic [23:0] v);
    logic [23:0] t;
    logic  [3:0] e;
    logic [31:0] w;
    t = v ^ {v[22:0], 1'b0};
    e = 4'd12;
    for (int i = 11; i >= 0; i--) if (t[23 - i]) e = 4'(i);
    if (e < 4'd12) w = ({8'd0, v} << e) & 32'h003FFFFF;
    else           w = {8'd0, v} << 11;           // MAME: val <<= 11, then the >> 11 below
    w = w >> 11;
    pack = {v[23], e, w[10:0]};
  endfunction
  function automatic logic [23:0] unpack(input logic [15:0] v);
    logic  [3:0] e;
    logic [31:0] u;
    e = v[14:11];
    u = {10'd0, v[10:0], 11'd0};
    if (e > 4'd11) begin e = 4'd11; u[22] = v[15]; end
    else u[22] = ~v[15];
    u[23] = v[15];
    u = $unsigned($signed({{8{u[23]}}, u[23:0]}) >>> e);
    unpack = u[23:0];
  endfunction

  // ------------------------------------------------------------------ memory
  logic        lk_req, lk_hit, fill_req, fill_done;
  logic [15:0] lk_line, c_mline;
  logic [63:0] lk_data, fill_data;
  logic        c_mreq;
  logic        snp2;
  logic [15:0] snp2_line;
  logic        w_out, w_pend, gap;      // a write queued; on the port
  m2_scsp_cache #(.IDX(6)) u_rcache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(lk_req), .lk_line(lk_line), .lk_hit(lk_hit), .lk_data(lk_data),
    .fill_req(fill_req), .fill_line(r_a[18:3]), .fill_done(fill_done), .fill_data(fill_data),
    .m_req(c_mreq), .m_line(c_mline), .m_ack(m_ack && !w_out), .m_data(m_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(snp2), .snp2_line(snp2_line),
    .dbg_fills()
  );
  logic [18:1] w_a;
  logic [15:0] w_d;
  always_comb begin
    m_we = w_out; m_wdata = w_d;
    m_addr = w_out ? w_a : {c_mline, 2'b00};
    m_req = !gap && (w_out || c_mreq);
  end

  typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FILL } rst_t;
  rst_t        rs;
  logic [18:1] r_a;
  logic        r_nofl;
  wire  [15:0] r_word_l = lk_data[{r_a[2:1], 4'b0} +: 16];
  wire  [15:0] r_word_f = fill_data[{r_a[2:1], 4'b0} +: 16];
  wire  [15:0] r_word   = (rs == R_LOOK) ? r_word_l : r_word_f;
  wire  [23:0] up       = unpack(r_word);


  assign mad    = madrs_q;
  assign coef_w = coef_q;

  always_comb begin
    logic [31:0] a, mask;
    logic signed [31:0] acc2;
    abort = 1'b0;
    if (IRA <= 6'h1f)      inputs = {ms_q[23], ms_q};
    else if (IRA <= 6'h2f) inputs = {mx_q[19], mx_q, 4'd0};
    else if (IRA <= 6'h31) inputs = 25'd0;            // EXTS: no external input on Model 2
    else begin inputs = 25'd0; abort = 1'b1; end
    if (IWT && IRA == {1'b0, IWA}) inputs = memval;
    if (ZERO) b_v = 32'sd0;
    else begin
      b_v = BSEL ? acc : {{8{t_q[23]}}, t_q};
      if (NEGB) b_v = 32'sd0 - b_v;
    end
    x_v = XSEL ? inputs : {t_q[23], t_q};
    case (YSEL)
      2'd0:    y_v = frc;
      2'd1:    y_v = coef_w[15:3];
      2'd2:    y_v = yreg[23:11];
      default: y_v = {1'b0, yreg[15:4]};
    endcase
    acc2 = acc <<< 1;
    case (SHFT)
      2'd0:    shifted = sat24(acc);
      2'd1:    shifted = sat24(acc2);
      2'd2:    shifted = acc2[23:0];
      default: shifted = acc[23:0];
    endcase
    a = {16'd0, mad};
    if (!TABLE) a = a + {16'd0, dec};
    if (ADREB)  a = a + {20'd0, adrs};
    if (NXADR)  a = a + 32'd1;
    mask = TABLE ? 32'h0000ffff : ((32'h2000 << rbl) - 32'd1);
    addr_w = (a & mask) + {14'd0, rbp, 12'd0};
    mem_now = (MRD || MWT) && k[0];
  end

  assign stall = (IWT && mv_pend) || (mem_now && (mv_pend || w_pend));
  assign exec  = dst == D_RUN && ph == 2'd2 && !stall && !abort;

  always_comb begin
    mp_ra = (dst == D_SCAN) ? scan_i : (dst == D_IDLE) ? r_addr[9:3] : k[6:0];
    t_ra  = TRA + dec[6:0];
    t_wa  = TWA + dec[6:0];
    m_ra  = IRA[4:0];
    co_ra = (dst == D_IDLE) ? r_addr[6:1] : COEFI;
    ma_ra = (dst == D_IDLE) ? r_addr[5:1] : MASA;
    mx_ra = (dst == D_RUN) ? IRA[3:0] : mix_sel;
    ef_ra = (dst == D_RUN) ? EWA : ef_idx;
    t_we  = exec && TWT;
    ef_we = exec && EWT;
    ms_we = exec && IWT;
    lk_req = exec && MRD && mem_now && addr_w < 32'h40000;
    lk_line = addr_w[17:2];
    fill_req = rs == R_FILL;
  end
  assign ef_q = ef_rq;

  // ------------------------------------------------------------------ sequencer
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst <= D_IDLE; stopped <= 1'b1; last_step <= 8'd0; dec <= 16'd0; done <= 1'b0;
      mixs_z <= 16'hffff; ef_z <= 16'hffff; mv_pend <= 1'b0; rs <= R_IDLE;
      w_out <= 1'b0; w_pend <= 1'b0; gap <= 1'b0; wr_done <= 1'b0; snp2 <= 1'b0;
      mul_v <= 2'b00; acc <= 32'sd0; ph <= 2'd0; k <= 8'd0; dbg_stall <= '0;
      sc_wait <= 1'b0; scan_i <= 7'd0;
    end else begin
      done <= 1'b0; wr_done <= 1'b0; snp2 <= 1'b0;
      gap <= m_req && m_ack;

      if (mix_we) mixs_z[mix_sel] <= 1'b0;

      // ACC: the product of the execute two clocks ago
      mul_v <= {mul_v[0], exec};
      if (mul_v[1]) acc <= 32'(prod >>> 12) + b_r;

      // a write goes out once no read is in flight: MAME reads before it
      // writes in a step that does both, so the read (and its fill) go first
      if (w_out && m_ack) begin w_out <= 1'b0; w_pend <= 1'b0; wr_done <= 1'b1; wr_addr <= w_a; end
      else if (w_pend && !w_out && !mv_pend && !gap) begin
        // out on the port, and its line invalidated now -- after this step's read
        // and its fill, before any later read (which waits for the write)
        w_out <= 1'b1; snp2 <= 1'b1; snp2_line <= w_a[18:3];
      end

`ifdef SCSP_DEBUG
      if (dbg_on && dst == D_RUN) $display("C k %0d ph %0d rs %0d mvp %0d wo %0d st %0d exec %0d mreq %0d mack %0d cmreq %0d fd %0d lkhit %0d IWT %0d", k, ph, rs, mv_pend, w_out, stall, exec, m_req, m_ack, c_mreq, fill_done, lk_hit, IWT);
`endif
      case (rs)
        R_LOOK: begin
          if (lk_hit) begin
            memval <= r_nofl ? {1'b0, r_word, 8'd0} : {up[23], up}; mv_pend <= 1'b0; rs <= R_IDLE;
          end else rs <= R_FILL;
        end
        R_FILL: if (fill_done) begin
`ifdef SCSP_DEBUG
          if (dbg_on) $display("F r_a %h fill %h word %h up %h nofl %0d", r_a, fill_data, r_word, up, r_nofl);
`endif
          memval <= r_nofl ? {1'b0, r_word, 8'd0} : {up[23], up}; mv_pend <= 1'b0; rs <= R_IDLE;
        end
        default: ;
      endcase

      if (dst == D_RUN && ph == 2'd2 && stall && !(&dbg_stall)) dbg_stall <= dbg_stall + 32'd1;

      case (dst)
        D_IDLE: begin
          if (w_en && w_addr == 11'h5f8) begin            // 0xBF0: MAME's Start()
            dst <= D_SCAN; scan_i <= 7'd127; sc_wait <= 1'b1; stopped <= 1'b0;
          end else if (go) begin
            if (stopped) done <= 1'b1;
            else begin
              ef_z <= 16'hffff; acc <= 32'sd0; frc <= '0; yreg <= '0; adrs <= '0; memval <= '0;
              k <= 8'd0; ph <= 2'd0;
              dst <= (last_step == 8'd0) ? D_FIN : D_RUN;
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
            2'd0: ph <= 2'd1;
            2'd1: ph <= 2'd2;
            default: begin
              if (abort) begin
                dst <= D_IDLE; done <= 1'b1;              // MAME returns: no DEC, MIXS kept
              end else if (!stall) begin
                mx_x <= x_v; mx_y <= y_v; b_r <= b_v;
`ifdef SCSP_DEBUG
                if (dbg_on) $display("R k %0d acc %0d sh %0d in %0d x %0d y %0d b %0d mv %0d dec %0d a %h mem %0d rbl %0d rbp %h ira %h iwt %0d iwa %0d mxq %h mz %h", k, acc, shifted, inputs, x_v, y_v, b_v, memval, dec, addr_w, mem_now, rbl, rbp, IRA, IWT, IWA, mx_q, mixs_z);
`endif
                if (YRL)  yreg <= inputs[23:0];
                if (FRCL) frc  <= (SHFT == 2'd3) ? {1'b0, shifted[11:0]} : shifted[23:11];
                if (ADRL) adrs <= (SHFT == 2'd3) ? shifted[23:12] : {{4{inputs[24]}}, inputs[23:16]};
                if (EWT) ef_z[EWA] <= 1'b0;
                if (mem_now && MRD) begin
                  r_a <= addr_w[17:0]; r_nofl <= NOFL;
                  if (addr_w < 32'h40000) begin rs <= R_LOOK; mv_pend <= 1'b1; end
                  else memval <= NOFL ? 25'd0 : 25'h0400000;   // unmapped: MAME reads 0 (UNPACK(0) = 0x400000)
                end
                if (mem_now && MWT && addr_w < 32'h40000) begin
                  w_pend <= 1'b1; w_a <= addr_w[17:0];
                  w_d <= NOFL ? shifted[23:8] : pack(shifted);
                end
                if ({1'b0, k} + 9'd1 == {1'b0, last_step}) dst <= D_FIN;
                k <= k + 8'd1; ph <= 2'd0;
              end
            end
          endcase
        end
        default: begin   // D_FIN: MAME's end of Step(), once ACC has settled
          if (mul_v == 2'b00 && !exec) begin
            dec <= dec - 16'd1; mixs_z <= 16'hffff; done <= 1'b1; dst <= D_IDLE;
          end
        end
      endcase
    end
  end
  assign busy = dst != D_IDLE;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, ins[56:55], ins[28], ins[15], c_mline[15:15], fill_data[0], addr_w[31:18]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
