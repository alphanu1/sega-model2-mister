// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE SCSP (Yamaha YMF292-F) OF THE MODEL 2A SOUND BOARD (study R856-R858).
//
// Written for this core against MAME 0.289's src/devices/sound/scsp.cpp and
// scspdsp.cpp (BSD-3-Clause, copyright-holders ElSemi, R. Belmont; thanks-to
// kingshriek -- the notice and conditions are in THIRD_PARTY.md), whose
// arithmetic, tables and order of operations it follows, so that MAME's own
// register stream replayed into it gives MAME's own mix, sample for sample
// (tb_m2_scsp, against sim/sound/scsp_ref.h, itself bit-exact to MAME).
//
// A NARROW, MICROCODED ENGINE (R858). The slots, the effect returns, the
// output, MAME's key-on sweep and the word-5 rates are microprograms
// (sim/sound/scsp_uasm.py, which also checks their pipeline timing) run by one
// datapath: a 32-bit ALU, one 27 x 18 multiplier, a 16-entry register file
// in M10K, and all per-slot state in M10K -- eight 32-bit rows a slot (cur,
// nxt, the LFO phases, the envelope, its four rates). A microinstruction is
// fetched into F, which issues the reads and picks the next address, and
// executes in E the clock after. An active slot is ~23 microinstructions.
// The effects DSP (m2_scsp_dsp) and the level words (m2_scsp_level) are
// their own units; the timers, interrupts and MIDI stay plain logic (their
// order against the 68000's accesses is MAME's to the clock).
//
// SOUND RAM HAS NO FIXED LATENCY (it is SDRAM), so the engine keeps no real
// time itself: it makes a sample when the output FIFO outside has room
// (out_ready), waits on a cache miss, and the FIFO drains at 44,100 Hz. The
// timers count drained samples (tick44).
//
// THE 68000's ACCESSES are queued and applied in order at a slot boundary,
// between samples, or while the DSP runs (not to the DSP's registers, then).
// MAME applies them between samples; here a write can land between two slots
// of a sample -- the one departure, R821's.
//
// SWITCHES (R856 / R857):
//   FM         the ring buffer, MDL / MDXSL / MDYSL, STWINH and the 68000's
//              access to 0x600-0x6ff (Zero Gunner's driver has an FM program)
//   MIDI_OUT   MOBUF to the i960 (Zero Gunner's driver writes it)
//   LFO_NOISE  (kept for the parameter list: the noise wave is baked into
//              scsp_lfo.hex with the others; MAME's own 256 values)
// NOT BUILT (unreachable in all four drivers, R857): reverse and ping-pong
// loops (LPCTL 2 / 3 play as 1), noise samples (SSCTL 1 gives 0), SDIR, DMA.
// The main-CPU interrupt (MCIEB / MCIPD) is stored, not wired, as on Model 2.

`timescale 1ns/1ps

module m2_scsp #(
  parameter bit FM        = 1'b1,
  parameter bit MIDI_OUT  = 1'b1,
  parameter bit LFO_NOISE = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the 68000 (0x100000-0x100fff decoded outside), one access per req
  input  logic        cpu_req,          // pulse: an access starts
  input  logic        cpu_we,
  input  logic [11:1] cpu_addr,
  input  logic [15:0] cpu_din,
  input  logic  [1:0] cpu_be,           // {upper, lower}
  output logic        cpu_ack,          // pulse: done (read data valid)
  output logic [15:0] cpu_dout,
  output logic  [2:0] ipl,              // 0 = none

  // ---- MIDI (the i960's UART, through m2_sound_link)
  input  logic  [7:0] midi_data,
  input  logic        midi_valid,
  output logic        midi_ack,
  output logic  [7:0] mout_data,
  output logic        mout_valid,
  input  logic        mout_ack,

  // ---- sound RAM
  output logic        sm_req,           // the slots' line fills
  output logic [15:0] sm_line,          // byte address [18:3]
  input  logic        sm_ack,
  input  logic [63:0] sm_data,          // word i of the line in [16i+15:16i]
  output logic        dm_req,           // the DSP (word address)
  output logic        dm_we,
  output logic [18:1] dm_addr,
  output logic [15:0] dm_wdata,
  input  logic        dm_ack,
  input  logic [63:0] dm_data,
  input  logic        snp,              // a 68000 write to sound RAM has landed
  input  logic [18:1] snp_addr,

  // ---- output
  input  logic        out_ready,
  output logic        out_valid,        // pulse
  output logic signed [31:0] out_l_raw, out_r_raw,   // MAME's smpl / smpr
  output logic signed [15:0] out_l, out_r,           // after the DAC and MVOL
  input  logic        tick44,           // one per sample drained at 44.1 kHz

  // ---- benches
  input  logic        step_mode,        // one sample per step_go
  input  logic        step_go,
  output logic        quiet,            // between samples with nothing pending
  output logic        dbg_slot_valid,
  output logic  [4:0] dbg_slot,
  output logic signed [31:0] dbg_slot_smp,
  output logic [31:0] dbg_samples,
  output logic [31:0] dbg_miss
);

`include "scsp_tables.svh"
  /* verilator lint_off UNUSEDPARAM */
`include "scsp_uc.svh"
  /* verilator lint_on UNUSEDPARAM */

  localparam logic [1:0] ATT = 2'd0, DC1 = 2'd1, DC2 = 2'd2, REL = 2'd3;

  // =====================================================================
  // declarations
  // =====================================================================
  // sequencer
  logic  [7:0] upc, upc_n, ret_addr, ea_n;
  logic [UF_W-1:0] uf;                    // F: this clock's microinstruction (reads, flow)
  logic [UE_W-1:0] ue;                    // E: last clock's (execute)
  logic        hold;
  logic  [5:0] slot;                      // the slot (or effect return) index; 32 = slots done
  logic  [4:0] sw, slot_e, sw_e;          // the sweep's index; E's copies
  logic        par;                       // BUFPTR's top bit: (32 n + slot) mod 64
  logic [31:0] active;

  // the 68000's queue and accesses
  logic [28:0] wq [4];                    // {be 2, addr 11, data 16}
  logic  [1:0] wq_rd, wq_wr;
  logic  [2:0] wq_n;
  logic        rd_pend;
  logic [11:1] rd_a;
  logic        wq_pop, rd_done;
  logic        op_busy, op_rd;
  logic [11:1] o_addr;
  logic [15:0] o_data;
  logic  [1:0] o_be;
  logic  [2:0] oc;
  logic  [8:0] w6l;                       // the level request's word 6 (TL, SDIR)
  logic        call_go;
  logic  [7:0] call_to;
  logic  [4:0] call_sw;

  // datapath
  logic [31:0] q, a_v, b_v, alu_r, sum;
  logic        borrow, scmp;
  logic [31:0] ra_q, rb_q, st_q;
  logic [15:0] sqa, sqb;
  logic [14:0] lv_q;
  logic signed [26:0] mul_a;
  logic signed [17:0] mul_b;
  logic signed [44:0] prod;
  logic [31:0] psl_v;
  // flags and latches
  logic        f1, f2, f3, f4, stop_rel, fk, fr;
  logic [15:0] w0l;                       // word 0 of the slot
  logic [14:0] w9l;                       // LFOF, PLFOWS, PLFOS, ALFOWS, ALFOS
  logic  [3:0] mdl;
  logic        fm_mod, lpslnk, d2r_zero, stwinh;
  logic  [3:0] isel;
  logic  [1:0] egst_l;                    // the slot's envelope state (LATEG)
  logic        hold_r;                    // EGHOLD from the AR row
  logic        eg_lin, eg_hold;
  logic  [9:0] eg_lv;
  logic [11:0] frac;
  // tables
  logic [13:0] tadr;
  logic  [8:0] tbl_q;
  logic  [9:0] egt_a;
  logic [12:0] egt_q;
  logic [26:0] rate_q;
  // fetch
  logic [19:0] fa1, fa2;
  logic        f2_known, p1_ok, p2_ok;
  logic signed [16:0] p1v, p2v;
  // ring
  logic [15:0] ring_q;
  logic  [6:0] ring_ra;
  // the DSP and the level words
  logic        dsp_go, dsp_done, dsp_busy, dsp_pend;
  logic        mix_we;
  logic [19:0] mix_val;
  logic signed [15:0] ef_q;
  logic        dw_en;
  logic        dsp_wr_done;
  logic [18:1] dsp_wr_addr;
  logic [15:0] dsp_rq;
  logic        lv_req, lv_busy;
  logic  [7:0] lv_raddr;
  // the monitor
  logic  [3:0] mon_ca;
  logic [15:0] mon;
  // common registers, timers, interrupts, MIDI
  logic [15:0] c400, c402, c406;
  logic  [7:0] c404h;
  logic [10:0] c418, c41a, c41c;
  logic  [7:0] scilv0, scilv1, scilv2;
  logic [10:0] scieb, scipd, scire, mcieb, mcipd;
  logic  [4:0] mslc;
  logic  [7:1] lines;
  (* ramstyle = "MLAB" *) logic [7:0] mfifo [32];
  logic  [7:0] mf_head;
  logic  [4:0] mw, mr;
  logic [2:0][14:0] tcd;
  logic  [2:0] tarm, texp;
  logic        cw_en, mi_pop;

  // the microinstruction's fields
  wire  [3:0] f_ra    = uf[`UF_RA];
  wire  [3:0] f_rb    = uf[`UF_RB];
  wire        f_st    = uf[`UF_ST];
  wire  [2:0] f_strow = uf[`UF_STROW];
  wire        f_streg = uf[`UF_STREG];
  wire  [1:0] f_idx   = uf[`UF_IDX];
  wire  [3:0] f_swa   = uf[`UF_SWA];
  wire  [3:0] f_swb   = uf[`UF_SWB];
  wire  [2:0] f_lw    = uf[`UF_LW];
  wire  [2:0] f_flow  = uf[`UF_FLOW];
  wire  [3:0] f_bc    = uf[`UF_BC];
  wire  [7:0] f_tgt   = uf[`UF_TGT];
  wire  [3:0] e_op    = ue[`UE_OP];
  wire  [2:0] e_a     = ue[`UE_A];
  wire  [2:0] e_b     = ue[`UE_B];
  wire  [1:0] e_psl   = ue[`UE_PSL];
  wire [15:0] e_imm   = ue[`UE_IMM];
  wire        e_immhi = ue[`UE_IMMHI];
  wire        e_rdwe  = ue[`UE_RDWE];
  wire  [3:0] e_rd    = ue[`UE_RD];
  wire  [3:0] e_pred  = ue[`UE_PRED];
  wire        e_stwe  = ue[`UE_STWE];
  wire  [2:0] e_stwrow = ue[`UE_STWROW];
  wire  [1:0] e_widx  = ue[`UE_WIDX];
  wire        e_mul   = ue[`UE_MUL];
  wire  [1:0] e_ma    = ue[`UE_MA];
  wire  [2:0] e_mb    = ue[`UE_MB];
  wire  [2:0] e_fset  = ue[`UE_FSET];
  wire  [2:0] e_lata  = ue[`UE_LATA];
  wire  [1:0] e_latb  = ue[`UE_LATB];
  wire  [3:0] e_s1    = ue[`UE_S1];
  wire  [3:0] e_s2    = ue[`UE_S2];

  // the slot's register fields
  wire        pcm8    = w0l[4];
  wire        loop_on = w0l[6:5] != 2'd0;   // LPCTL 2 / 3 play as 1
  wire  [1:0] ssctl   = w0l[8:7];
  wire  [1:0] sbctl   = w0l[10:9];
  wire  [4:0] lfof    = w9l[14:10];
  wire  [1:0] plfows  = w9l[9:8];
  wire  [2:0] plfos   = w9l[7:5];
  wire  [1:0] alfows  = w9l[4:3];
  wire  [2:0] alfos   = w9l[2:0];
  wire  [1:0] eg_pre  = (f3 && lpslnk && egst_l == ATT) ? DC1 : egst_l;   // LPSLNK, before EG_Update

  // =====================================================================
  // the 68000's queue
  // =====================================================================
  wire  [28:0] wq_h   = wq[wq_rd];
  wire  [11:1] h_addr = wq_h[26:16];
  wire   [4:0] o_slot = o_addr[9:5];
  wire   [3:0] o_word = o_addr[4:1];
  wire         op_ready = ((wq_n != 3'd0) || rd_pend) && !wq_pop && !rd_done;
  wire  [11:1] nx_addr  = (wq_n != 3'd0) ? h_addr : rd_a;
  wire         head_dsp = nx_addr >= 11'h380 && nx_addr < 11'h600;
  wire         op_ok    = op_ready && !(head_dsp && dsp_busy);
  wire         o_ring   = FM && o_addr >= 11'h300 && o_addr < 11'h380;   // 0x600-0x6ff
  wire         o_dsp    = o_addr >= 11'h380 && o_addr < 11'h600;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wq_rd <= '0; wq_wr <= '0; wq_n <= '0; rd_pend <= 1'b0; cpu_ack <= 1'b0; rd_a <= '0;
    end else begin
      cpu_ack <= 1'b0;
      if (cpu_req && cpu_we) begin
        wq[wq_wr] <= {cpu_be, cpu_addr, cpu_din};
        wq_wr <= wq_wr + 2'd1;
        cpu_ack <= 1'b1;
      end
      if (cpu_req && !cpu_we) begin rd_pend <= 1'b1; rd_a <= cpu_addr; end
      if (rd_done) begin rd_pend <= 1'b0; cpu_ack <= 1'b1; end
      if (wq_pop) wq_rd <= wq_rd + 2'd1;
      wq_n <= wq_n + {2'd0, cpu_req && cpu_we} - {2'd0, wq_pop};
    end
  end

  // =====================================================================
  // the microcode ROMs and the sequencer
  // =====================================================================
  (* ramstyle = "M10K" *) logic [UF_W-1:0] ucf [256];
  (* ramstyle = "M10K" *) logic [UE_W-1:0] uce [256];
  initial begin
    $readmemh("scsp_ucf.hex", ucf);
    $readmemh("scsp_uce.hex", uce);
  end
  always_ff @(posedge clk) begin
    uf <= ucf[upc_n];
    ue <= uce[ea_n];
  end

  // conditions
  function automatic logic cond(input logic [3:0] c);
    case (c)
      4'(C_ALWAYS):  cond = 1'b1;
      4'(C_PLFO):    cond = plfos != 3'd0;
      4'(C_ALFO):    cond = alfos != 3'd0;
      4'(C_LOOP1):   cond = loop_on && f1;
      4'(C_LOOP2):   cond = loop_on && f2;
      4'(C_FMMOD):   cond = FM && fm_mod;
      4'(C_NSTWINH): cond = FM && !stwinh;
      4'(C_NMVOL15): cond = c400[3:0] != 4'hf;
      4'(C_START):   cond = fk && fr;
      4'(C_NKB):     cond = !fk;
      4'(C_MORESW):  cond = sw != 5'd31;
      4'(C_MOREI):   cond = slot != 6'd16;
      4'(C_SSCTL3):  cond = ssctl == 2'd3;
      default:       cond = 1'b0;
    endcase
  endfunction

  wire go_ok    = step_mode ? (step_go && !lv_busy && !lv_req) : out_ready;
  wire dsp_idle = !dsp_busy && !dsp_pend;
  wire op_win   = (f_flow == 3'(FLOW_DISPATCH)) ||
                  (f_flow == 3'(FLOW_WAIT) && (f_bc == 4'(C_GO) || f_bc == 4'(C_DSPIDLE)));
  wire op_start = op_win && !op_busy && !call_go && op_ok;
  wire stop_now = (!loop_on && ((f3 && f1) || (f4 && f2))) || stop_rel;
  wire [4:0] idx_f = (f_idx == 2'(IDX_SW)) ? sw : (f_idx == 2'(IDX_MSLC)) ? mslc : slot[4:0];

  logic boot;                              // (the ROMs' registers have no reset)
  always_ff @(posedge clk or negedge rst_n) if (!rst_n) boot <= 1'b1; else boot <= 1'b0;
  always_comb begin
    upc_n = upc + 8'd1; hold = 1'b0;
    if (call_go) upc_n = call_to;
    else if (op_busy || op_start) hold = 1'b1;
    else case (f_flow)
      3'(FLOW_BR):      if (cond(f_bc)) upc_n = f_tgt;
      3'(FLOW_JMP):     upc_n = f_tgt;
      3'(FLOW_RET):     upc_n = ret_addr;
      3'(FLOW_SLOTEND): upc_n = UA_DISPATCH;
      3'(FLOW_DISPATCH): begin
        if (slot[5]) ;                                   // all slots done
        else if (active[slot[4:0]]) upc_n = UA_SLOT;
        else hold = 1'b1;                                // (the next slot, next clock)
      end
      3'(FLOW_WAIT): begin
        case (f_bc)
          4'(C_GO):      hold = !(go_ok && dsp_idle && !op_ready);
          4'(C_DSPIDLE): hold = !dsp_idle;
          4'(C_FETCHED): hold = !(p1_ok && p2_ok);
          default:       hold = 1'b0;
        endcase
      end
      default: ;
    endcase
    if (hold) upc_n = upc;
    ea_n = (hold || call_go) ? UA_NOP : upc;
    if (boot) begin upc_n = UA_IDLE; ea_n = UA_NOP; end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      upc <= UA_IDLE; ret_addr <= UA_IDLE; slot <= 6'd32; sw <= '0; slot_e <= '0; sw_e <= '0;
      active <= '0; f1 <= 1'b0; f2 <= 1'b0; f3 <= 1'b0; f4 <= 1'b0; stop_rel <= 1'b0;
    end else begin
      upc <= upc_n;
      if (!hold && !call_go) begin slot_e <= slot[4:0]; sw_e <= sw; end
      if (call_go) begin ret_addr <= upc; sw <= call_sw; end
      if (!hold && !call_go && !op_busy) begin
        if (f_flow == 3'(FLOW_DISPATCH) && !slot[5] && active[slot[4:0]]) begin
          f1 <= 1'b0; f2 <= 1'b0; f3 <= 1'b0; f4 <= 1'b0; stop_rel <= 1'b0;   // a slot starts
        end
        if (f_flow == 3'(FLOW_SLOTEND)) begin
          slot <= slot + 6'd1;
          if (stop_now && upc != UA_SKIP) active[slot[4:0]] <= 1'b0;
        end
      end
      if (hold && !op_busy && !op_start && f_flow == 3'(FLOW_DISPATCH) && !slot[5] && !active[slot[4:0]])
        slot <= slot + 6'd1;
      // ---- E-stage effects on the sequencer's state
      if (e_s2 == 4'(S2_ICLR)) slot <= 6'd0;
      if (e_s2 == 4'(S2_IINC)) slot <= slot + 6'd1;
      if (e_s2 == 4'(S2_SWINC)) sw <= sw + 5'd1;
      if (e_s2 == 4'(S2_ACTSET)) active[sw_e] <= 1'b1;
      if (e_fset == 3'(FSET_F1)) f1 <= !borrow;
      if (e_fset == 3'(FSET_F2)) f2 <= !borrow;
      if (e_fset == 3'(FSET_F3)) f3 <= scmp;
      if (e_fset == 3'(FSET_F4)) f4 <= scmp;
      if (e_op == 4'(OP_EG) && egst_n_rel_stop) stop_rel <= 1'b1;
    end
  end

  // =====================================================================
  // RAMs: slot registers, slot state, the register file
  // =====================================================================
  logic  [8:0] sra, srb;
  logic        srb_we;
  logic  [1:0] srb_be;
  logic [15:0] srb_d;
  (* ramstyle = "M10K" *) logic [1:0][7:0] sreg [512];
  always_ff @(posedge clk) sqa <= sreg[sra];
  always_ff @(posedge clk) begin
    if (srb_we && srb_be[0]) sreg[srb][0] <= srb_d[7:0];
    if (srb_we && srb_be[1]) sreg[srb][1] <= srb_d[15:8];
    sqb <= sreg[srb];
  end

  // slot state: eight rows a slot (CUR, NXT, PH = {pph, aph}, VOL = {egst at
  // [27:26], vol 26}, and the rate rows AR = {hold, ar}, D1R, D2R, RR)
  logic  [7:0] st_ra, st_wa;
  logic        st_we;
  (* ramstyle = "M10K" *) logic [31:0] st [256];
  always_ff @(posedge clk) begin
    if (st_we) st[st_wa] <= alu_r;
    st_q <= st[st_ra];
  end

  // the register file: two copies, one per read port
  logic        rf_we;
  (* ramstyle = "M10K" *) logic [31:0] rfa [16];
  (* ramstyle = "M10K" *) logic [31:0] rfb [16];
  always_ff @(posedge clk) begin
    if (rf_we) begin rfa[e_rd] <= alu_r; rfb[e_rd] <= alu_r; end
    ra_q <= rfa[f_ra];
    rb_q <= rfb[f_rb];
  end

  // =====================================================================
  // tables
  // =====================================================================
  // the LFOs, waves baked in: [0, 8K) PSCALES by {PLFOS, PLFOWS, phase >> 8},
  // [8K, 16K) ASCALES by {ALFOS, ALFOWS, phase >> 8}
  (* ramstyle = "M10K" *) logic [8:0] lfo_rom [16384];
  (* ramstyle = "M10K" *) logic [12:0] eg_rom [1024];
  (* ramstyle = "M10K" *) logic [26:0] rate_rom [128];
  initial begin
    $readmemh("scsp_lfo.hex", lfo_rom);
    $readmemh("scsp_eg.hex", eg_rom);
    $readmemh("scsp_rate.hex", rate_rom);
  end
  always_ff @(posedge clk) begin
    tbl_q  <= lfo_rom[tadr];
    egt_q  <= eg_rom[egt_a];
    rate_q <= rate_rom[{eg_pre != ATT, st_q[5:0]}];    // the row read last clock (STREG)
    hold_r <= st_q[6];
  end

  // =====================================================================
  // the operands
  // =====================================================================
  wire signed [31:0] p_lo = prod[31:0];               // MAME's int product (wraps at 32 bits)
  always_comb begin
    case (e_psl)
      2'(PSL_S6):  psl_v = prod[37:6];
      2'(PSL_S12): psl_v = 32'(p_lo >>> 12);
      2'(PSL_S16): psl_v = 32'(p_lo >>> 16);
      default:     psl_v = 32'(p_lo >>> 17) & ~{31'd0, !pcm8};   // FM: x 2^(MDL + PCM16) >> 17
    endcase
  end
  wire [8:0] lfo_step = scsp_lfostep(lfof);

  always_comb begin
    case (e_a)
      3'(A_RA):   a_v = ra_q;
      3'(A_Q):    a_v = q;
      3'(A_ST):   a_v = (e_op == 4'(OP_EG)) ? {6'd0, st_q[25:0]} : st_q;
      3'(A_CSH):  a_v = pcm8 ? {12'd0, st_q[31:12]} : {11'd0, st_q[31:12], 1'b0};
      3'(A_PSL):  a_v = psl_v;
      3'(A_P2):   a_v = 32'(p2v);
      3'(A_RING): a_v = FM ? 32'($signed(ring_q)) : 32'd0;
      default:    a_v = 32'(ef_q);
    endcase
    case (e_b)
      3'(B_RB):   b_v = rb_q;
      3'(B_IMM):  b_v = e_immhi ? {e_imm, 16'd0} : {16'd0, e_imm};
      3'(B_Q):    b_v = q;
      3'(B_SA):   b_v = {12'd0, sqb[3:0], sqa};
      3'(B_SQ12): b_v = {4'd0, sqa, 12'd0};
      3'(B_LFOI): b_v = {7'd0, (plfos != 3'd0) ? lfo_step : 9'd0, 7'd0, (alfos != 3'd0) ? lfo_step : 9'd0};
      3'(B_RATE): b_v = {5'd0, rate_q};
      default:    b_v = 32'(p1v);
    endcase
  end

  // =====================================================================
  // the ALU
  // =====================================================================
  // the envelope (MAME EG_Update) on vol +- rate, in eg_pre's state
  logic [1:0] egst_n;
  logic       egst_n_rel_stop;
  logic [25:0] eg_v;
  wire  [4:0] eg_dl = 5'h1f - sqa[9:5];                 // EG.DL = 0x1f - DL (word 5, live)
  wire        eg_sub = eg_pre != ATT;

  always_comb begin
    logic [31:0] bb;
    logic        sub, split, cin;
    sub = e_op == 4'(OP_SUB) || (e_op == 4'(OP_EG) && eg_sub);
    split = e_op == 4'(OP_ADDSPLIT);
    cin = sub || (e_op == 4'(OP_ADDSGN) && a_v[31]);
    bb = (e_op == 4'(OP_ADDSGN)) ? 32'd0 : sub ? ~b_v : b_v;
    begin
      logic [16:0] lo;
      logic [16:0] hi;
      lo = {1'b0, a_v[15:0]} + {1'b0, bb[15:0]} + {16'd0, cin};
      hi = {1'b0, a_v[31:16]} + {1'b0, bb[31:16]} + {16'd0, lo[16] && !split};
      sum = {hi[15:0], lo[15:0]};
      borrow = sub && !hi[16];
    end
    scmp = sum[31:28] != 4'd0 || sum[27:12] >= sqa;     // (sum >> 12) >= LSA, the side compare
  end

  always_comb begin
    logic signed [31:0] v;
    v = $signed(sum);
    egst_n = eg_pre; egst_n_rel_stop = 1'b0;
    case (eg_pre)
      ATT: begin
        if (v >= 32'sh03ff0000) begin
          if (!lpslnk) egst_n = DC1;
          v = 32'sh03ff0000;
        end
      end
      DC1: begin
        if (v < 0) v = 0;
        if (v[25:21] <= eg_dl) egst_n = DC2;
      end
      DC2: begin
        if (d2r_zero) v = $signed({6'd0, st_q[25:0]});
        else if (v < 0) v = 0;
      end
      default: begin
        if (v <= 0) begin v = 0; egst_n_rel_stop = 1'b1; end
      end
    endcase
    eg_v = v[25:0];
  end

  function automatic logic signed [15:0] dac(input logic signed [31:0] s, input logic d18);
    logic signed [31:0] x;
    x = d18 ? s : (s >>> 2);
    if (d18) begin
      if (x[31:17] != {15{x[31]}}) x = x[31] ? -32'sd131072 : 32'sd131071;
      x = x >>> 2;
    end else if (x[31:15] != {17{x[31]}}) x = x[31] ? -32'sd32768 : 32'sd32767;
    dac = x[15:0];
  endfunction

  wire pred_ok = cond(e_pred);
  always_comb begin
    case (e_op)
      4'(OP_PASSA): alu_r = a_v;
      4'(OP_PASSB): alu_r = b_v;
      4'(OP_OR):    alu_r = a_v | b_v;
      4'(OP_EG):    alu_r = {4'd0, egst_n, eg_v};
      4'(OP_RATEIDX): begin
        logic [4:0] r5;
        logic signed [9:0] x;
        case (e_imm[1:0])
          2'(RI_AR):  r5 = sqa[4:0];
          2'(RI_D1R): r5 = sqa[10:6];
          2'(RI_D2R): r5 = sqa[15:11];
          default:    r5 = sqb[4:0];
        endcase
        x = $signed(a_v[9:0]) + $signed({4'd0, r5, 1'b0});
        if (x < 0) x = 0;
        else if (x > 63) x = 63;
        alu_r = {25'd0, e_imm[1:0] == 2'(RI_AR) && sqa[5], x[5:0]};   // AR's row: EGHOLD in bit 6
      end
      4'(OP_EGBASE): begin
        // Compute_EG: octave + 2 KRS + FNS[9], or 0 when KRS = 0xf (sqa = w8, sqb = w5)
        if (sqb[13:10] == 4'hf) alu_r = 32'd0;
        else alu_r = 32'($signed(sqa[14:11])) + {26'd0, sqb[13:10], 1'b0} + {31'd0, sqa[9]};
      end
      4'(OP_SBC): begin
        logic [17:0] s;
        s = sum[17:0];
        if (ssctl != 2'd0) s = 18'd0;
        if (sbctl[0]) s = s ^ 18'h07fff;
        if (sbctl[1]) s = {{2{~s[15]}}, ~s[15], s[14:0]};   // (s16)(sample ^ 0x8000)
        alu_r = 32'($signed(s));
      end
      4'(OP_DAC):   alu_r = 32'(dac($signed(a_v), c400[8]));
      4'(OP_CSEL):  alu_r = pred_ok ? sum : rb_q;
      default:      alu_r = sum;                          // ADD SUB ADDSGN ADDSPLIT
    endcase
  end

  // a microinstruction's effects: all of them under its predicate, but a
  // CSEL's, whose predicate chooses its result
  wire go_e = (e_op == 4'(OP_CSEL)) || pred_ok;
  assign rf_we = e_rdwe && go_e;
  assign st_we = e_stwe && go_e;
  assign st_wa = {(e_widx == 2'(IDX_SW)) ? sw_e : slot_e, e_stwrow};
  assign st_ra = {idx_f, f_streg ? {1'b1, eg_pre} : f_strow};

  // =====================================================================
  // the multiplier
  // =====================================================================
  wire [16:0] pow2p = 17'(1) << {~sqa[14], sqa[13:11]};              // 2^(octave + 8)
  wire [16:0] pow2f = 17'(1) << ({1'b0, mdl} + {4'd0, !pcm8});        // 2^(MDL + PCM16)
  wire [12:0] egv   = eg_lin ? (eg_hold ? 13'h0ffc : {1'b0, eg_lv, 2'b00}) : egt_q;
  function automatic logic [16:0] mvol_gain(input logic [3:0] mv);
    mvol_gain = 17'((({13'd0, mv} * 17'd65536) + 17'd7) / 17'd15);
  endfunction
  always_ff @(posedge clk) begin
    if (e_mul && go_e) begin
      case (e_ma)
        2'(MA_RA):  mul_a <= $signed(ra_q[26:0]);
        2'(MA_Q):   mul_a <= $signed(q[26:0]);
        2'(MA_PSL): mul_a <= $signed(psl_v[26:0]);
        default:    mul_a <= $signed({16'd0, 1'b1, sqa[9:0]});           // FNS + 1024
      endcase
      case (e_mb)
        3'(MB_POW2P): mul_b <= $signed({1'b0, pow2p});
        3'(MB_POW2F): mul_b <= $signed({1'b0, pow2f});
        3'(MB_TBL4):  mul_b <= $signed({5'd0, tbl_q, 4'd0});              // LFO_Step returns p << 4
        3'(MB_EGV):   mul_b <= $signed({5'd0, egv});
        3'(MB_LV):    mul_b <= $signed({3'd0, lv_q});
        3'(MB_FRAC):  mul_b <= $signed({6'd0, frac});
        default:      mul_b <= $signed({1'b0, mvol_gain(c400[3:0])});
      endcase
    end
    prod <= mul_a * mul_b;
  end

  // =====================================================================
  // E: registers, latches, side effects
  // =====================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= '0; w0l <= '0; w9l <= '0; mdl <= '0; fm_mod <= 1'b0; lpslnk <= 1'b0; d2r_zero <= 1'b0;
      stwinh <= 1'b0; isel <= '0; egst_l <= REL; eg_lin <= 1'b0; eg_hold <= 1'b0; eg_lv <= '0;
      tadr <= '0; egt_a <= '0; frac <= '0; fk <= 1'b0; fr <= 1'b0;
      dsp_go <= 1'b0; dsp_pend <= 1'b0; out_valid <= 1'b0; dbg_slot_valid <= 1'b0;
      dbg_samples <= '0; par <= 1'b0; mon <= '0; mon_ca <= '0;
      out_l_raw <= '0; out_r_raw <= '0; out_l <= '0; out_r <= '0; dbg_slot <= '0; dbg_slot_smp <= '0;
    end else begin
      dsp_go <= 1'b0; out_valid <= 1'b0; dbg_slot_valid <= 1'b0;
      if (dsp_done) dsp_pend <= 1'b0;
      q <= alu_r;
      // latches (port A: words 9, 4, 5, 6, 10; port B: words 0, 7)
      case (e_lata)
        3'(LATA_W9):  w9l <= sqa[14:0];
        3'(LATA_W4):  d2r_zero <= sqa[15:11] == 5'd0;
        3'(LATA_W5):  lpslnk <= sqa[14];
        3'(LATA_W6):  stwinh <= sqa[9];
        3'(LATA_W10): isel <= sqa[6:3];
        default: ;
      endcase
      case (e_latb)
        2'(LATB_W0): w0l <= sqb;
        2'(LATB_W7): begin mdl <= sqb[15:12]; fm_mod <= sqb != 16'd0; end
        default: ;
      endcase
      if (e_fset == 3'(FSET_KBREL)) begin fk <= sqb[11]; fr <= st_q[27:26] == REL; end
      if (go_e) begin
        case (e_s1)
          4'(S1_TADRP): tadr <= {1'b0, plfos, plfows, alu_r[31:24]};
          4'(S1_TADRA): tadr <= {1'b1, alfos, alfows, alu_r[15:8]};
          4'(S1_TADRE): begin
            egt_a <= alu_r[25:16]; eg_lv <= alu_r[25:16];
            eg_lin <= eg_pre == ATT; eg_hold <= hold_r;
          end
          4'(S1_LATEG): egst_l <= st_q[27:26];
          4'(S1_FETCH1): frac <= st_q[11:0];
          4'(S1_DBG): begin dbg_slot_valid <= 1'b1; dbg_slot <= slot_e; dbg_slot_smp <= alu_r; end
          4'(S1_OUTLRAW): out_l_raw <= alu_r;
          4'(S1_OUTRRAW): out_r_raw <= alu_r;
          4'(S1_OUTL): out_l <= alu_r[15:0];
          4'(S1_OUTR): out_r <= alu_r[15:0];
          default: ;
        endcase
        case (e_s2)
          4'(S2_DSPGO): begin dsp_go <= 1'b1; dsp_pend <= 1'b1; end
          4'(S2_OUTV): begin
            out_valid <= 1'b1; par <= ~par;
            if (!(&dbg_samples)) dbg_samples <= dbg_samples + 32'd1;
          end
          4'(S2_MON1): mon_ca <= st_q[27:24];
          4'(S2_MON2): mon <= {5'd0, mon_ca, st_q[27:26], 5'h1f - st_q[25:21]};   // MAME latches it after each update
          default: ;
        endcase
      end
    end
  end

  // =====================================================================
  // the sample bytes: a1 then a2 through the slot cache
  // =====================================================================
  typedef enum logic [2:0] { G_IDLE, G_L1, G_W1, G_F1, G_L2, G_W2, G_F2 } gst_t;
  gst_t        gs;
  logic        lk_req, lk_hit, fill_req, fill_done;
  logic [15:0] lk_line, fill_line;
  logic [63:0] lk_data, fill_data;
  wire  [63:0] g_line = (gs == G_W1 || gs == G_W2) ? lk_data : fill_data;
  function automatic logic signed [16:0] pick(input logic [63:0] ln, input logic [19:0] a, input logic p8);
    logic [15:0] wd;
    wd = ln[{a[2:1], 4'b0} +: 16];
    if (p8) pick = a[0] ? $signed({wd[7], wd[7:0], 8'd0}) : $signed({wd[15], wd[15:8], 8'd0});
    else    pick = $signed({wd[15], wd});
  endfunction
  wire fetch1 = go_e && e_s1 == 4'(S1_FETCH1);
  wire fetch2 = go_e && e_s1 == 4'(S1_FETCH2);
  wire same   = fa2[19:3] == fa1[19:3];
  always_comb begin
    lk_req = 1'b0; lk_line = fa1[18:3]; fill_req = 1'b0; fill_line = fa1[18:3];
    case (gs)
      G_L1: lk_req = 1'b1;
      G_F1: fill_req = 1'b1;
      G_L2: begin lk_req = 1'b1; lk_line = fa2[18:3]; end
      G_F2: begin fill_req = 1'b1; fill_line = fa2[18:3]; end
      default: ;
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gs <= G_IDLE; p1_ok <= 1'b0; p2_ok <= 1'b0; f2_known <= 1'b0; fa1 <= '0; fa2 <= '0;
      p1v <= '0; p2v <= '0;
    end else begin
      if (fetch1) begin
        fa1 <= alu_r[19:0]; p1_ok <= 1'b0; p2_ok <= 1'b0; f2_known <= 1'b0;
        if (ssctl != 2'd0) begin p1v <= '0; p2v <= '0; p1_ok <= 1'b1; p2_ok <= 1'b1; gs <= G_IDLE; end
        else if (alu_r[19]) begin p1v <= '0; p1_ok <= 1'b1; gs <= G_L2; end   // past 512 KB: MAME reads 0
        else gs <= G_L1;
      end
      if (fetch2) begin fa2 <= alu_r[19:0]; f2_known <= 1'b1; end
      case (gs)
        G_L1: gs <= G_W1;
        G_W1, G_F1: if (gs == G_W1 ? lk_hit : fill_done) begin
          p1v <= pick(g_line, fa1, pcm8); p1_ok <= 1'b1;
          if (f2_known && !fa2[19] && same) begin p2v <= pick(g_line, fa2, pcm8); p2_ok <= 1'b1; gs <= G_IDLE; end
          else gs <= G_L2;
        end else if (gs == G_W1) gs <= G_F1;
        G_L2: if (f2_known) begin
          if (fa2[19]) begin p2v <= '0; p2_ok <= 1'b1; gs <= G_IDLE; end
          else gs <= G_W2;
        end
        G_W2, G_F2: if (gs == G_W2 ? lk_hit : fill_done) begin
          p2v <= pick(g_line, fa2, pcm8); p2_ok <= 1'b1; gs <= G_IDLE;
        end else if (gs == G_W2) gs <= G_F2;
        default: ;
      endcase
    end
  end
  // (G_L2 issues its lookup only once fa2 is known; the µcode starts both
  // fetches on consecutive microinstructions, so it always is by then)

  m2_scsp_cache #(.IDX(8)) u_cache (
    .clk(clk), .rst_n(rst_n),
    .lk_req(lk_req && (gs != G_L2 || (f2_known && !fa2[19]))), .lk_line(lk_line), .lk_hit(lk_hit), .lk_data(lk_data),
    .fill_req(fill_req), .fill_line(fill_line), .fill_done(fill_done), .fill_data(fill_data),
    .m_req(sm_req), .m_line(sm_line), .m_ack(sm_ack), .m_data(sm_data),
    .snp(snp), .snp_line(snp_addr[18:3]), .snp2(dsp_wr_done), .snp2_line(dsp_wr_addr[18:3]),
    .dbg_fills(dbg_miss)
  );

  // =====================================================================
  // FM: the ring buffer (MAME's RINGBUF; the slots use the first 64 words)
  // =====================================================================
  logic        ring_we;
  logic  [6:0] ring_wa;
  logic [15:0] ring_wd;
  always_comb begin
    ring_ra = {1'b0, 6'({par, slot_e} + ((e_s1 == 4'(S1_RINGX)) ? sqa[11:6] : sqa[5:0]))};
    ring_we = go_e && e_s1 == 4'(S1_RINGW) && FM;
    ring_wa = {1'b0, par, slot_e};
    ring_wd = 16'(p_lo >>> 13);                         // (sample x level 5) >> (SHIFT + 1)
    if (op_busy) begin
      ring_ra = o_addr[7:1];
      ring_we = !op_rd && o_ring && ((oc == 3'd0 && o_be == 2'b11) || oc == 3'd1);
      ring_wa = o_addr[7:1];
      ring_wd = (oc == 3'd0) ? o_data : {o_be[1] ? o_data[15:8] : ring_q[15:8], o_be[0] ? o_data[7:0] : ring_q[7:0]};
    end
  end
  generate if (FM) begin : g_fm
    (* ramstyle = "MLAB" *) logic [15:0] ring [128];
    always_ff @(posedge clk) begin
      if (ring_we) ring[ring_wa] <= ring_wd;
      ring_q <= ring[ring_ra];
    end
  end else begin : g_nofm
    assign ring_q = 16'd0;
  end endgenerate

  // =====================================================================
  // the level words, the DSP
  // =====================================================================
  assign lv_raddr = {idx_f, f_lw};
  m2_scsp_level u_level (
    .clk(clk), .rst_n(rst_n),
    .req(lv_req), .req_slot(o_slot), .req_w6({7'd0, w6l}), .req_w10(sqb), .req_w11(sqa),
    .busy(lv_busy), .rd_addr(lv_raddr), .rd_q(lv_q)
  );

  assign mix_we  = go_e && e_s1 == 4'(S1_MIXW);
  assign mix_val = p_lo[29:10];                       // (sample x level 2) >> (SHIFT - 2)
  m2_scsp_dsp u_dsp (
    .clk(clk), .rst_n(rst_n),
    .go(dsp_go), .done(dsp_done), .busy(dsp_busy),
    .rbl(c402[8:7]), .rbp(c402[5:0]),
    .mix_sel(isel), .mix_we(mix_we), .mix_val(mix_val),
    .ef_idx(slot[3:0]), .ef_q(ef_q),
    .w_en(dw_en), .w_addr(o_addr), .w_data(o_data), .w_be(o_be), .r_addr(o_addr), .r_q(dsp_rq),
    .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
    .m_ack(dm_ack), .m_data(dm_data), .snp(snp), .snp_addr(snp_addr),
    .wr_done(dsp_wr_done), .wr_addr(dsp_wr_addr), .dbg_stall(), .dbg_on(1'b0)
  );

  // =====================================================================
  // the 68000's accesses
  // =====================================================================
  // a slot register write: port B writes (KEYONEX is not stored); then
  // KEYONEX -> the sweep, word 5 -> its rates, words 6 / 10 / 11 -> the
  // level words. A read of a slot register is port B's.
  wire slotend_clr = !op_busy && f_flow == 3'(FLOW_SLOTEND) && !hold && !call_go && stop_now && upc != UA_SKIP;
  always_comb begin
    sra = {idx_f, f_swa}; srb = {idx_f, f_swb};
    srb_we = 1'b0; srb_be = 2'b11; srb_d = o_data;
    if (slotend_clr) begin                              // MAME StopSlot: KEYONB cleared
      srb = {slot[4:0], 4'd0}; srb_we = 1'b1; srb_be = 2'b10; srb_d = {w0l[15:12], 1'b0, w0l[10:0]};
    end
    if (op_busy) begin
      sra = {o_slot, (oc >= 3'd2) ? 4'd11 : 4'd6};
      srb = {o_slot, (oc >= 3'd1 && !op_rd) ? 4'd10 : o_word};
      if (!op_rd && oc == 3'd0 && o_addr < 11'h200) begin
        srb_we = 1'b1; srb_be = o_be; srb_d = (o_word == 4'd0) ? (o_data & 16'hefff) : o_data;
      end
    end
  end
  assign dw_en = op_busy && !op_rd && oc == 3'd0 && o_dsp;
  assign cw_en = op_busy && !op_rd && oc == 3'd0 && o_addr >= 11'h200 && o_addr < 11'h218;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      op_busy <= 1'b0; op_rd <= 1'b0; o_addr <= '0; o_data <= '0; o_be <= '0; oc <= '0;
      wq_pop <= 1'b0; rd_done <= 1'b0; mi_pop <= 1'b0; lv_req <= 1'b0; w6l <= '0;
      call_go <= 1'b0; call_to <= UA_IDLE; call_sw <= '0; cpu_dout <= '0;
    end else begin
      wq_pop <= 1'b0; rd_done <= 1'b0; mi_pop <= 1'b0; call_go <= 1'b0;
      if (lv_req && !lv_busy) lv_req <= 1'b0;
      if (op_start) begin
        op_busy <= 1'b1; oc <= '0; op_rd <= wq_n == 3'd0;
        o_addr <= nx_addr; o_data <= wq_h[15:0]; o_be <= wq_h[28:27];
      end else if (op_busy) begin
        if (!op_rd) begin
          if (o_addr < 11'h200) begin
            case (oc)
              3'd0: begin
                wq_pop <= 1'b1;
                if (o_word == 4'd0 && o_be[1] && o_data[12]) begin
                  call_go <= 1'b1; call_to <= UA_SWEEP; call_sw <= 5'd0; op_busy <= 1'b0;
                end else if (o_word == 4'd5) begin
                  call_go <= 1'b1; call_to <= UA_W5; call_sw <= o_slot; op_busy <= 1'b0;
                end else if (o_word == 4'd6 || o_word == 4'd10 || o_word == 4'd11) oc <= 3'd1;
                else op_busy <= 1'b0;
              end
              3'd1: oc <= 3'd2;                           // words 6, 10 asked
              3'd2: begin w6l <= {sqa[8], sqa[7:0]}; oc <= 3'd3; end   // word 11 asked
              default: if (!lv_busy && !lv_req) begin lv_req <= 1'b1; op_busy <= 1'b0; end
            endcase
          end else if (o_ring && o_be != 2'b11 && oc == 3'd0) begin
            wq_pop <= 1'b1; oc <= 3'd1;                   // a byte of the ring: read, merge
          end else begin
            if (oc == 3'd0) wq_pop <= 1'b1;
            op_busy <= 1'b0;
          end
        end else begin
          // a read (MAME r16)
          if (oc == 3'd0) oc <= 3'd1;
          else begin
            if (o_addr < 11'h200) cpu_dout <= sqb;
            else if (o_ring) cpu_dout <= ring_q;
            else if (o_dsp) cpu_dout <= dsp_rq;
            else cpu_dout <= common_read(o_addr[5:1]);
            if (o_addr == 11'h202) mi_pop <= 1'b1;
            rd_done <= 1'b1; op_busy <= 1'b0;
          end
        end
      end
    end
  end

  // =====================================================================
  // common registers, timers, interrupts, MIDI (MAME UpdateReg & co.)
  // =====================================================================
  always_comb begin
    ipl = 3'd0;
    for (int l = 1; l < 8; l++) if (lines[l]) ipl = 3'(l);
  end

  always_ff @(posedge clk) begin
    if (midi_valid && !midi_ack) mfifo[mw] <= midi_data;
    mf_head <= mfifo[mr];                  // (a read comes clocks after mr moves)
  end

  // MAME's r16 of a common register
  function automatic logic [15:0] common_read(input logic [5:1] a);
    case (a)
      5'h00: common_read = c400;
      5'h01: common_read = c402;
      5'h02: common_read = {c404h, mf_head};
      5'h03: common_read = c406;
      5'h04: common_read = mon;            // 0x408: the monitor, latched after each sample
      5'h0c: common_read = {5'd0, c418};
      5'h0d: common_read = {5'd0, c41a};
      5'h0e: common_read = {5'd0, c41c};
      5'h0f: common_read = {5'd0, scieb};
      5'h10: common_read = {5'd0, scipd};
      5'h11: common_read = {5'd0, scire};
      5'h12: common_read = {8'd0, scilv0};
      5'h13: common_read = {8'd0, scilv1};
      5'h14: common_read = {8'd0, scilv2};
      5'h15: common_read = {5'd0, mcieb};
      5'h16: common_read = {5'd0, mcipd};
      default: common_read = 16'd0;
    endcase
  endfunction

  // this clock's events in MAME's order (a 68000 write, a MIBUF read, a MIDI
  // byte, the timers, then CheckPendingIRQ) on working copies. The interrupt
  // lines MAME's events clear all come before the one CheckPendingIRQ sets,
  // so the lines are (lines & ~clear) | set.
  wire [15:0] cw_d  = o_data;
  wire  [1:0] cw_be = o_be;
  function automatic logic [15:0] merge(input logic [15:0] old, input logic [15:0] d, input logic [1:0] be);
    merge = {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
  endfunction
  wire [15:0] mrg   = merge(common_read(o_addr[5:1]), cw_d, cw_be);
  wire [14:0] tload = 15'(({7'd0, ~mrg[7:0]} << mrg[10:8]) - 15'd1);
  logic [15:0] c400_n, c402_n;
  logic  [7:0] c404h_n, scilv0_n, scilv1_n, scilv2_n;
  logic [10:0] c418_n, c41a_n, c41c_n, scieb_n, scipd_n, scipd_c, mcieb_n, mcipd_n;
  logic  [4:0] mslc_n, mw_n, mr_n;
  logic  [2:0] arm_n, ex_n, rep, clr;      // clr: {MIDI, timer B / C, timer A}
  logic [2:0][14:0] tcd_n;
  logic        chk;
  always_comb begin
    c400_n = c400; c402_n = c402; c404h_n = c404h; c418_n = c418; c41a_n = c41a; c41c_n = c41c;
    scilv0_n = scilv0; scilv1_n = scilv1; scilv2_n = scilv2;
    scieb_n = scieb; scipd_n = scipd; mcieb_n = mcieb; mcipd_n = mcipd; mslc_n = mslc;
    mw_n = mw; mr_n = mr; arm_n = tarm; ex_n = texp; tcd_n = tcd;
    chk = 1'b0; rep = 3'b000; clr = 3'b000;

    if (cw_en) begin
      case (o_addr[5:1])
        5'h00: c400_n = mrg;
        5'h01: c402_n = mrg;
        5'h02: begin                         // MIBUF: r16 pops it first
          c404h_n = mrg[15:8];
          if (mw_n != mr_n) mr_n = mr_n + 5'd1;
          if (mw_n == mr_n) begin clr[2] = 1'b1; scipd_n[3] = 1'b0; end
        end
        5'h04: mslc_n = mrg[15:11];
        5'h0c: begin c418_n = mrg[10:0]; ex_n[0] = 1'b0; if (mrg[7:0] != 8'hff) begin arm_n[0] = 1'b1; tcd_n[0] = tload; end end
        5'h0d: begin c41a_n = mrg[10:0]; ex_n[1] = 1'b0; if (mrg[7:0] != 8'hff) begin arm_n[1] = 1'b1; tcd_n[1] = tload; end end
        5'h0e: begin c41c_n = mrg[10:0]; ex_n[2] = 1'b0; if (mrg[7:0] != 8'hff) begin arm_n[2] = 1'b1; tcd_n[2] = tload; end end
        5'h0f: begin scieb_n = mrg[10:0]; chk = 1'b1; end
        5'h10: scipd_n = mrg[10:0];
        5'h11: begin                         // SCIRE: clear, ResetInterrupts, check, re-pend
          scipd_n = scipd_n & ~mrg[10:0];
          clr = {mrg[3], mrg[7] | mrg[8], mrg[6]};
          chk = 1'b1; rep = 3'b111;
        end
        5'h12: scilv0_n = mrg[7:0];
        5'h13: scilv1_n = mrg[7:0];
        5'h14: scilv2_n = mrg[7:0];
        5'h15: mcieb_n = mrg[10:0];
        5'h16: if (mrg[5]) mcipd_n[5] = 1'b1;
        5'h17: mcipd_n = mcipd_n & ~mrg[10:0];
        default: ;
      endcase
    end
    if (mi_pop) begin
      if (mw_n != mr_n) mr_n = mr_n + 5'd1;
      if (mw_n == mr_n) begin clr[2] = 1'b1; scipd_n[3] = 1'b0; end
    end
    if (midi_valid && !midi_ack) begin mw_n = mw_n + 5'd1; chk = 1'b1; end
    if (tick44) begin
      for (int t = 0; t < 3; t++) begin
        if (arm_n[t]) begin
          if (tcd_n[t] != 15'd0) tcd_n[t] = tcd_n[t] - 15'd1;
          else begin
            arm_n[t] = 1'b0; ex_n[t] = 1'b1; scipd_n[6 + t] = 1'b1; chk = 1'b1;
            if (t == 0) begin c418_n[7:0] = 8'hff; mcipd_n[6] = 1'b1; end
            if (t == 1) c41a_n[7:0] = 8'hff;
            if (t == 2) c41c_n[7:0] = 8'hff;
          end
        end
      end
    end
    if (chk && mw_n != mr_n) scipd_n[3] = 1'b1;
    scipd_c = scipd_n;
    for (int t = 0; t < 3; t++) if (rep[t] && ex_n[t]) scipd_n[6 + t] = 1'b1;
  end

  wire [7:0] dec_ta = 8'(1) << {scilv2[6], scilv1[6], scilv0[6]};
  wire [7:0] dec_tb = 8'(1) << {scilv2[7], scilv1[7], scilv0[7]};
  wire [7:0] dec_mi = 8'(1) << {scilv2[3], scilv1[3], scilv0[3]};
  logic [7:0] irq_set;
  always_comb begin
    irq_set = 8'd0;
    if (chk) begin
      if (scipd_c[6] && scieb_n[6])      irq_set = dec_ta;
      else if (scipd_c[7] && scieb_n[7]) irq_set = dec_tb;
      else if (scipd_c[8] && scieb_n[8]) irq_set = dec_tb;
      else if (scipd_c[3] && scieb_n[3]) irq_set = dec_mi;
    end
  end
  wire [7:0] irq_clr = ({8{clr[0]}} & dec_ta) | ({8{clr[1]}} & dec_tb) | ({8{clr[2]}} & dec_mi);
  wire [7:0] ln_n    = (({lines, 1'b0}) & ~irq_clr) | irq_set;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c400 <= '0; c402 <= '0; c404h <= '0; c418 <= '0; c41a <= '0; c41c <= '0;
      scilv0 <= '0; scilv1 <= '0; scilv2 <= '0; scieb <= '0; scipd <= '0; scire <= '0; mcieb <= '0; mcipd <= '0;
      mslc <= '0; lines <= '0; mw <= '0; mr <= '0; midi_ack <= 1'b0;
      tarm <= '0; texp <= 3'b111;            // MAME init(): TimCnt = 0xffff
      tcd <= '0;
    end else begin
      c400 <= c400_n; c402 <= c402_n; c404h <= c404h_n; c418 <= c418_n; c41a <= c41a_n; c41c <= c41c_n;
      scilv0 <= scilv0_n; scilv1 <= scilv1_n; scilv2 <= scilv2_n;
      scieb <= scieb_n; scipd <= scipd_n; if (cw_en && o_addr[5:1] == 5'h11) scire <= mrg[10:0];
      mcieb <= mcieb_n; mcipd <= mcipd_n; mslc <= mslc_n;
      lines <= ln_n[7:1]; mw <= mw_n; mr <= mr_n; tarm <= arm_n; texp <= ex_n;
      tcd <= tcd_n;
      midi_ack <= midi_valid && !midi_ack;
    end
  end

  // ---- MIDI out (MOBUF): MAME's 32-byte stack, sent in order
  // (any write to 0x406 sends its stored low byte; the word reads back)
  generate if (MIDI_OUT) begin : g_mout
    (* ramstyle = "MLAB" *) logic [7:0] mo_fifo [32];
    logic [4:0] mo_w, mo_wd, mo_r;
    wire mo_push = cw_en && o_addr[5:1] == 5'h03;
    wire mo_pop  = mout_valid && mout_ack;
    wire [15:0] mo_m = merge(c406, cw_d, cw_be);
    always_ff @(posedge clk) begin
      if (mo_push) mo_fifo[mo_w] <= mo_m[7:0];
      mout_data <= mo_fifo[mo_pop ? mo_r + 5'd1 : mo_r];
    end
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin mo_w <= '0; mo_wd <= '0; mo_r <= '0; c406 <= '0; end
      else begin
        if (mo_push) c406 <= mo_m;
        if (mo_push) mo_w <= mo_w + 5'd1;
        mo_wd <= mo_w;
        if (mo_pop) mo_r <= mo_r + 5'd1;
      end
    end
    assign mout_valid = mo_wd != mo_r;
  end else begin : g_nomout
    assign c406       = 16'd0;
    assign mout_valid = 1'b0;
    assign mout_data  = 8'd0;
  end endgenerate

  assign quiet = upc == UA_IDLE && !op_busy && !call_go && !op_ready && !wq_pop && !rd_done &&
                 !lv_busy && !lv_req && !dsp_busy;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, LFO_NOISE, prod[44:38], w0l[11], egst_n_rel_stop, ue[`UE_IMM]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
