// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- the Model 2B SHARC (ADSP-21062): a small one-word-at-a-time
// core for the 2B copro (study R1023 section 4, R1024, R1026, R1027).
//
// SEQUENCING is MAME 0.289's interpreter, exactly: the fetch queue (pc / daddr / faddr / nfaddr),
// the loop stack's end test at the start of a word (on ASTAT three words back for a loop longer
// than two, MAME's astat_old_old_old), delayed branches, the PC and loop stacks with MAME's push
// and pop. The word executed is PM[pc] after the queue shifts; a loop end changes pc before the
// word's handler runs (relative branches in it see the loop top), as MAME's CHANGE_PC does.
//
// TIMING. Each word is two clocks, D then X:
//   D  the opcode (PM's registered output); the queue shift and loop end; decode and condition;
//      operands read (R, I, M, the ureg source); the DM read address presented; the next
//      word's fetch address computed (fetch_a). At D's end the sequencer (S) and the PC / loop
//      stacks are committed (R1028); nothing else.
//   X  the fetch of the next word issued (PM read at fetch_a, ready for the next D); the fixed
//      ALU / shifter / misc float result (m2b_sharc_xu, one shared unit), loads, ureg writes
//      (a sequencer register's into S), post-modify, DM / FIFO / IOP / external accesses: all
//      committed at X's end. FIFO full / empty, an external access, MAME's slow multiply hold X.
//   The register files are MLAB (R1028): R0-R15 five read copies of one write port (a word
//   writing two R registers writes the second a clock later), I and M three each, the PC stack
//   two and the loop stacks six (m2b_lutram).
//   The float units (Hornet's sharc_fadd / sharc_fmul, FAVG on the adder; the misc functions
//   in X) take their operands at D's end and register stage 1 at X's end; their results and ASTAT /
//   STKY bits are written in the clock after X (the "landing", which is the next word's first D
//   clock). The next word waits in D one clock if it reads a register or ASTAT being landed
//   (the scoreboard). MAME's order inside a word is kept: a load or ureg move to the register a
//   float result goes to wins (the float write is dropped); a ureg write to ASTAT / STKY in a
//   word with a float compute is applied at the landing, after the float flags.
//
// MEMORY: PM 2^PM_AW x 48 on chip (three 16-bit lanes, the host's 16-bit upload writes one);
// DM block 1, 2^DM_AW x 32 on chip (two 16-bit lanes), its mirrors at 0x28000 / 0x30000 /
// 0x38000; block-1 words from 2^DM_AW and the board's buffer RAM / data ROM go to the ext_ port.
// The in / out FIFOs are outside (fin_ / fout_); FLAG0 = in FIFO empty, FLAG1 = out FIFO full
// (R1024), FLAG2 / FLAG3 the ASTAT bits when MODE2 makes them outputs.
//
// THE FIRST CUT (R1027) does Dead or Alive's set and the rest of R1024's list that is cheap.
// Every word it does not do sets `unsup` (sticky, with the word's pc / opcode / a reason) and
// runs as a NOP: type-1 dual moves, PM-bus data, short words, block-0 data, the fixed
// multiplier and MR, dual add / subtract, alternate register files (a MODE1 swap bit), circular
// buffers (L != 0 on a post-modify), interrupts and IDLE, RTI, the status stack, SHARC-side DMA,
// RND32 = 0 on a float op, PCSTKP written, unknown compute / IOP registers.
//
// Units: Hornet's sharc_fadd / sharc_fmul (rtl/sharc, copied with R1027's rounding) and his
// sharc_fp_pkg functions. MAME_RND = 1 gives MAME's float arithmetic bit for bit (the lockstep
// against MAME and Hornet's v1); 0 (the default) the ADSP-2106x manual's (R1024: Ben's
// decision).

`timescale 1ns/1ps

module m2b_sharc #(
    parameter bit MAME_RND = 1'b0,
    parameter int PM_AW    = 13,            // program memory 2^PM_AW x 48 at 0x20000 (8 K: R1027)
    parameter int DM_AW    = 13,            // block-1 data on chip 2^DM_AW x 32 (8 K: R1026)
    parameter bit BENCH    = 1'b0,          // the DM starts all ones (unwritten memory reads 0xFFFF...)
    parameter bit CLEAR    = 1'b1,          // PM and DM cleared after reset, as MAME's device_reset
    parameter bit RF_ONES  = 1'b0           // benches: the register and stack arrays start all ones
) (
    input  logic        clk,
    input  logic        reset,              // MAME's device_reset (host boot)
    input  logic        run,                // HALT released (copro_boot)

    // the host (i960) side
    input  logic        host_iop_we,        // IOP window write: register host_iop_reg
    input  logic [7:0]  host_iop_reg,
    input  logic [31:0] host_iop_data,
    input  logic        xdma_we,            // upload word (copro_ctl1 bit 31): external_dma_write
    input  logic [1:0]  xdma_phase,         // the 16-bit part (the upload count mod 3)
    input  logic [15:0] xdma_data,

    // FIFOs
    input  logic        fin_empty,
    input  logic [31:0] fin_data,
    output logic        fin_pop,
    input  logic        fout_full,
    output logic        fout_push,
    output logic [31:0] fout_data,
    output logic [1:0]  flag_out,           // FLAG2, FLAG3 (MODE2 outputs)

    // external data: buffer RAM, data ROM, block-1 words past the on-chip DM
    output logic        ext_req,
    output logic        ext_we,
    output logic [31:0] ext_addr,
    output logic [31:0] ext_wdata,
    input  logic        ext_ack,
    input  logic [31:0] ext_rdata,

    // a word this core does not do (sticky)
    output logic        unsup,
    output logic [23:0] unsup_pc,
    output logic [47:0] unsup_op,
    output logic [3:0]  unsup_why,

    // benches
    output logic        dbg_ret,            // this clock the state is that after word dbg_pc
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    output logic [2:0]  dbg_st              // 0 halt, 1 fetch, 2 D, 3 X; bit 2: D waiting
);

import sharc_fp_pkg::*;
import m2b_sharc_pkg::*;

localparam int PMW = 1 << PM_AW;
localparam int DMW = 1 << DM_AW;

// unsupported reasons
localparam logic [3:0] U_FORM = 4'd1, U_COMP = 4'd2, U_MEM = 4'd3, U_DAG = 4'd4, U_MODE = 4'd5,
                       U_STK = 4'd6, U_IOP = 4'd7, U_UREG = 4'd8, U_PM = 4'd9, U_RND = 4'd10;

// ================================================================== memories

// PM: three 16-bit lanes; A = fetch, B = the host's upload
(* ramstyle = "M10K" *) logic [15:0] pm0 [PMW];
(* ramstyle = "M10K" *) logic [15:0] pm1 [PMW];
(* ramstyle = "M10K" *) logic [15:0] pm2 [PMW];
logic [PM_AW-1:0] pm_ra, pm_wa;
logic             pm_re;
logic [2:0]       pm_we;
logic [15:0]      pm_wd;
logic [47:0]      pm_q;
always_ff @(posedge clk) if (pm_re) begin
    pm_q[15:0] <= pm0[pm_ra]; pm_q[31:16] <= pm1[pm_ra]; pm_q[47:32] <= pm2[pm_ra];
end
always_ff @(posedge clk) begin
    if (pm_we[0]) pm0[pm_wa] <= pm_wd;
    if (pm_we[1]) pm1[pm_wa] <= pm_wd;
    if (pm_we[2]) pm2[pm_wa] <= pm_wd;
end

// DM block 1: two 16-bit lanes, one port
(* ramstyle = "M10K" *) logic [15:0] dm0 [DMW];
(* ramstyle = "M10K" *) logic [15:0] dm1 [DMW];
logic [DM_AW-1:0] dm_a;
logic             dm_en, dm_we;
logic [31:0]      dm_wd, dm_q;
always_ff @(posedge clk) if (dm_en) begin
    if (dm_we) begin dm0[dm_a] <= dm_wd[15:0]; dm1[dm_a] <= dm_wd[31:16]; end
    else begin dm_q[15:0] <= dm0[dm_a]; dm_q[31:16] <= dm1[dm_a]; end
end
generate if (BENCH) begin : g_dm_init
    initial for (int k = 0; k < DMW; k++) begin dm0[k] = 16'hFFFF; dm1[k] = 16'hFFFF; end
end endgenerate

// ================================================================== architectural state

// R0-R15: MLAB, five copies of one write port each (m2b_lutram; R1028), read in D:
//   port 0 (A): Rx, or R0-3 (the multiplier's X in a multifunction)
//   port 1 (B): Ry, or R4-7
//   port 2 (C): Rn (the shifter's OR forms), or R8-11 (the adder's X)
//   port 3 (D): R12-15 (the adder's Y)
//   port 4 (E): a store's data register, or the ureg source
// One write a clock. A word that writes two (a fixed / shifter result and a load at X's end; a
// multifunction's Rm and Ra at the landing) writes the second in the next clock (rf_pw): after
// X's end that is the landing clock, which such a word does not use; after a landing, D does not
// finish in the landing clock, so no X writes in the next. D reads in its clocks; a word read
// in a clock that writes it is the scoreboard's (D waits and reads again), so no_rw_check's
// undefined read is never used.
logic [4:0][3:0]  rf_ra;
logic [4:0][31:0] rf_rd;
logic             rf_we;
logic [3:0]       rf_wa;
logic [31:0]      rf_wd;
logic             rf_pw, rf_pl;                 // a deferred write this clock (rf_pl: a landing's)
logic [3:0]       rf_pa;
logic [31:0]      rf_pd;
// I0-I15 and M0-M15: MLAB (m2b_lutram, one write port each; R1028). Three read ports each, all
// read in D: DAG1's (I0-7 / M0-7: the address and post-modify of a data access, a modify), DAG2's
// (I8-15 / M8-15: an indirect jump's target, a modify), and the ureg port (D's ureg source). The
// writes are at X's end (a post-modify, a ureg write); a word that writes two different I
// registers (a load to one, a post-modify of another) defers the ureg write one clock (ir_pw),
// and D waits that clock, so D never reads a word in the clock it is written.
logic [2:0]  i1_ra, i2_ra, m1_ra, m2_ra;
logic [31:0] i1_rd, i2_rd, iu_rd, m1_rd, m2_rd, mu_rd;
logic        ir_we, mr_we;
logic [3:0]  ir_wa, mr_wa;
logic [31:0] ir_wd, mr_wd;
logic        ir_pw;                         // the deferred I write (this clock)
logic [3:0]  ir_pa;
logic [31:0] ir_pd;
logic [15:0] lnz;                           // L != 0
logic [31:0] astat, stky, mode1, mode2, irptl, imask, ustat1, ustat2, syscon;
logic [47:0] px;

typedef struct packed {
    logic [23:0] pc, daddr, faddr, nfaddr;
    logic [23:0] pcstk;
    logic [5:0]  pcstkp;
    logic [2:0]  lstkp;
    logic [31:0] curlcntr, lcntr;
    logic [23:0] la_addr;
    logic [4:0]  la_code;
    logic [1:0]  la_type;
    logic [31:0] stk;                       // STKY's stack bits (STK_BITS)
} seq_t;
seq_t S;
seq_t S_dbg;                                // benches: S as the word that left X last left it

// the PC stack (30 used of 32) and the loop stacks (6 of 8): MLAB (m2b_lutram, R1028), the top
// of each in S. One write each at X's end; the reads are D's, at addresses from S (the stack
// pointers before the word): PCSTKP - 2 / - 3 (a pop, a second pop in the same word); LSTKP - 2 /
// - 3 (the same), LSTKP + 1 / LSTKP (a DO's new LCNTR, after no pop / a pop). D reads after the
// X that wrote, never in its clock.
logic [23:0] pcs_p2, pcs_p3;
logic [31:0] lcs_p2, lcs_p3, lcs_q0, lcs_q1, las_p2, las_p3;

// MAME's ASTAT history: ah1 = after the last completed word, ah2, ah3 before it; only the bits a
// condition reads are kept (R1028)
localparam logic [31:0] AH_BITS = AZ | AV | AN | AC | AF | MN | MV | SV | SZ | BTF;
logic [31:0] ah1, ah2, ah3;

// DMA channel 6 (the host boot's registers) and the host IOP pairing
logic [31:0] ii6, im6, dmac6;
logic        iop_hi;
logic [15:0] iop_lo;
logic [1:0]  epb_shift;

function automatic logic [31:0] la_pack(input logic [1:0] t, input logic [4:0] c, input logic [23:0] a);
    return {t, 1'b0, c, a};
endfunction

// ================================================================== control

localparam logic [1:0] ST_HALT = 2'd0, ST_FETCH = 2'd1, ST_D = 2'd2, ST_X = 2'd3;
logic [1:0] st;

// the landing: float results of the word that left X last clock
logic        ld_on;                         // this clock lands a float compute
logic        ld_mwe, ld_awe;                // Rm (multiplier) / Ra (adder or other) written
logic [3:0]  ld_rm, ld_ra;
logic        ld_mul, ld_alu;                // the multiplier / the ALU flags group is written
logic        ld_misc;                       // Ra and the ALU flags from the misc result
logic        ld_absf;                       // ABS(Fx +- Fy): magnitude, never AN
logic        ld_comp;                       // FCOMP: the result is ASTAT's top byte
logic        ld_ua, ld_us;                  // a late ureg write to ASTAT / STKY
logic [31:0] ld_uv;
logic [31:0] misc_r, misc_a, misc_s;        // the misc float result (computed in X)
logic [31:0] misc_d_r, misc_d_a, misc_d_s;

// the RAM clear after reset (below)
localparam int CLR_AW = (PM_AW > DM_AW) ? PM_AW : DM_AW;
logic [CLR_AW:0] clr_n;
logic            clr_on;

// D -> X
localparam logic [2:0] A_NONE = 3'd0, A_DM = 3'd1, A_FIN = 3'd2, A_FOUT = 3'd3, A_IOP = 3'd4, A_EXT = 3'd5;
typedef struct packed {
    logic        unsup;
    logic [3:0]  why;
    // compute
    logic        fix_on;                    // fixed ALU
    logic [7:0]  fix_op;
    logic        sh_on;                     // shifter
    logic [5:0]  sh_op;
    logic        sh_imm;                    // (the immediate is x_op's: {op[30:27], op[15:8]})
    logic [3:0]  rn;                        // the fixed / shifter result register
    logic        fl_on;                     // a float compute (lands after X)
    logic        fl_mul, fl_add, fl_sub, fl_misc, fl_absf, fl_comp;
    logic        fl_avg;                    // FAVG: the adder's halved sum (R1028)
    logic [4:0]  misc_op;                   // tb_sharc_fp's numbering of the float functions
    logic        trunc;
    logic [3:0]  rm, ra;
    logic        rm_we, ra_we;
    // memory
    logic [2:0]  acc;
    logic        acc_wr;
    logic [31:0] acc_addr;
    logic [31:0] acc_wd;
    logic        ld_r;                      // load to R[ld_dst]
    logic        ld_u;                      // load to ureg ld_ureg
    logic [3:0]  ld_dst;
    logic [7:0]  ld_ureg;
    // DAG post-modify
    logic        pmod;
    logic [3:0]  pmod_i;
    logic [31:0] pmod_m;
    logic [31:0] pmod_b;                    // the I register's value (read in D)
    // ureg write with a value known in D
    logic        uw;                        // the value is acc_wd's (no data access in these forms)
    logic [7:0]  uw_reg;
    // system register bit operation (X: on the register's value then)
    logic        bitop;
    logic [2:0]  bit_kind;
    logic [3:0]  bit_reg;                   // (the mask is x_op[31:0])
    // the stacks: one write each
    logic        pcw;
    logic [4:0]  pcw_i;
    logic [23:0] pcw_d;
    logic        lcw, law;
    logic [2:0]  lcw_i, law_i;
    logic [31:0] lcw_d, law_d;
} xc_t;
xc_t XC;
logic [31:0] op_x, op_y, op_n;              // fixed / shifter operands: R[rx], R[ry], R[rn]
logic [31:0] fa_x, fa_y, fm_x, fm_y;        // float operands
logic [31:0] st_x;                          // store data / ureg source value
logic [23:0] fetch_a;
logic [47:0] x_op;
logic [23:0] x_pc;
logic        x_first;                       // X's first clock (the fetch is issued)

// ================================================================== D: decode

logic [3:0] flg;
assign flg = {2'b00, fout_full, fin_empty};

// the system registers' get_ureg (0x70-0x7f), from their values
function automatic logic [31:0] sys_rd(input logic [3:0] r, input logic [31:0] a, input logic [31:0] m1,
                                       input logic [31:0] m2, input logic [31:0] sk, input logic [31:0] ip,
                                       input logic [31:0] im, input logic [31:0] u1, input logic [31:0] u2,
                                       input logic [3:0] f);
    logic [31:0] v;
    case (r)
    4'h0: v = u1;
    4'h1: v = u2;
    4'h9: v = ip;
    4'ha: v = m2;
    4'hb: v = m1;
    4'hc: begin                             // ASTAT with the input flags
        v = a & ({28'h0, m2[18:15]} << 19 | ~FLGS);
        for (int i = 0; i < 4; i++) if (!m2[15 + i]) v = v | ({31'h0, f[i]} << (19 + i));
    end
    4'hd: v = im;
    4'he: v = sk;
    default: v = 32'h0;
    endcase
    return v;
endfunction

// the sequencer's (0x64 PCSTK, 0x65 PCSTKP, 0x67 CURLCNTR, 0x68 LCNTR), after the loop end
function automatic logic [31:0] seq_rd(input logic [3:0] r, input logic [23:0] pcstk, input logic [5:0] pcstkp,
                                       input logic [31:0] curlcntr, input logic [31:0] lcntr);
    case (r)
    4'h4: return {8'h0, pcstk};
    4'h5: return {26'h0, pcstkp};
    4'h7: return curlcntr;
    4'h8: return lcntr;
    default: return 32'h0;
    endcase
endfunction

// D's one ureg read port: the field each form names (only one per word)
logic [7:0]  ur_sel;
logic [31:0] ur_v;
always_comb begin
    logic [47:0] o;
    logic [2:0]  k;
    o = pm_q;
    ur_sel = (o[47:45] == 3'b010) ? o[30:23] : (o[47:44] == 4'b0111) ? o[43:36] :
             (o[47:40] == 8'b00010100) ? {4'h7, o[35:32]} : o[39:32];     // the bit operation's register
    k = ur_sel[2:0];
    case (ur_sel[7:4])
    4'h0: ur_v = rf_rd[4];
    4'h1: ur_v = iu_rd;
    4'h2: ur_v = ur_sel[3] ? {{8{mu_rd[23]}}, mu_rd[23:0]} : mu_rd;
    4'h7: ur_v = sys_rd(ur_sel[3:0], astat, mode1, mode2, stky, irptl, imask, ustat1, ustat2, flg);
    4'hd: case (ur_sel[3:0])
          4'hb: ur_v = px[31:0];
          4'hc: ur_v = {16'h0, px[15:0]};
          4'hd: ur_v = px[47:16];
          default: ur_v = 32'h0;
          endcase
    default: ur_v = 32'h0;                  // L reads 0 (only L = 0 is done); 0x6x: seq_rd
    endcase
end

// which ureg reads / writes the first cut does
function automatic logic ureg_ok(input logic [7:0] u, input logic wr);
    case (u[7:4])
    4'h0, 4'h1, 4'h2: return 1'b1;
    4'h3: return wr;                        // L: written (L != 0 flagged at use), not read
    4'h4: return wr;                        // B: written (also sets I), not read
    4'h6: return u[3:0] == 4'h4 || u[3:0] == 4'h7 || u[3:0] == 4'h8 || (!wr && u[3:0] == 4'h5);
    4'h7: return u[3:0] == 4'h0 || u[3:0] == 4'h1 || u[3:0] == 4'h9 || u[3:0] == 4'ha ||
                 u[3:0] == 4'hb || u[3:0] == 4'hc || u[3:0] == 4'hd || u[3:0] == 4'he;
    4'hd: return u[3:0] == 4'hb || u[3:0] == 4'hc || u[3:0] == 4'hd;
    default: return 1'b0;
    endcase
endfunction

// R registers a ureg read touches
function automatic logic [15:0] ureg_rmask(input logic [7:0] u);
    return (u[7:4] == 4'h0) ? (16'h1 << u[3:0]) : 16'h0;
endfunction

logic        d_wait;                        // D waits this clock (the scoreboard)
logic        d_go;                          // D completes this clock
xc_t         dx;
seq_t        dsn;
logic [31:0] d_opx, d_opy, d_opn, d_fax, d_fay, d_fmx, d_fmy, d_stx;
logic [15:0] d_rmask;                       // R registers D reads
logic        d_need_astat;                  // D reads ASTAT / STKY
logic [DM_AW-1:0] d_dm_a;
logic        d_dm_rd;

// address decode of a data access (DM bus)
// {unsupported, kind}
function automatic logic [3:0] dm_kind(input logic [31:0] a, input logic wr);
    if (a < 32'h100) return {1'b0, A_IOP};
    if (a >= 32'h28000 && a < 32'h40000) begin
        if ({17'h0, a[14:0]} < DMW) return {1'b0, A_DM};
        return {1'b0, A_EXT};
    end
    if (a >= 32'h400000 && a < 32'hC00000) return {wr, A_FIN};
    if (a >= 32'hC00000 && a < 32'h1400000) return {!wr, A_FOUT};
    if (a >= 32'h1400000 && a < 32'h1E00000) return {1'b0, A_EXT};
    return {1'b1, A_NONE};                  // block 0 data, short words, unmapped
endfunction

always_comb begin
    seq_t s;
    xc_t  x;
    logic [47:0] op;
    logic [4:0]  cond;
    logic [22:0] comp;
    logic        cok, comp_on;
    logic [2:0]  ii, mm;
    logic        jdb, ee, ci, la;
    logic [31:0] astat_d;
    logic        alusat, trunc;
    logic [3:0]  rx, ry, rnn;
    logic        lce_ne1;
    logic [1:0]  npop;
    logic        nlpop;
    logic        mem_on;
    logic [31:0] mem_a;
    logic        mem_wr;
    logic        bad;
    logic        mb_i;                          // the address is I + offset (else the offset)
    logic [1:0]  mo_sel;                        // the offset: 0 none, 1 M (DAG1), 2 the 6-bit immediate, 3 the 32-bit
    logic [1:0]  wd_sel;                        // store / ureg data: 0 R (port E), 1 the ureg, 2 the immediate
    logic [1:0]  pm_sel;                        // post-modify by: 0 M (DAG1), 1 the 6-bit immediate, 2 M of op[38]'s DAG, 3 the 32-bit
    logic [31:0] ur_all;                        // the ureg D names, the sequencer's included
    logic [23:0] pc1, rel_t, ind_t, rts_v, tgt, qb;
    logic        br, br_db;                     // a branch taken; delayed
    logic [1:0]  tsel;                          // its target: 0 op[23:0], 1 PC + offset, 2 I + M (DAG2), 3 the PC stack's top
    logic [4:0]  cnd;                           // the word's condition

    op = pm_q;
    s = S;
    x = '0;
    d_rmask = 16'h0;
    d_need_astat = 1'b0;
    npop = 2'd0;
    nlpop = 1'b0;
    mem_on = 1'b0; mem_a = 32'h0; mem_wr = 1'b0;
    mb_i = 1'b1; mo_sel = 2'd0; wd_sel = 2'd0; pm_sel = 2'd0;
    br = 1'b0; br_db = 1'b0; tsel = 2'd0; rts_v = 24'h0;
    astat_d = astat;
    alusat = mode1[M1_ALUSAT];
    trunc = mode1[M1_TRUNC];

    // ---------------------------------------------------------------- the queue shift
    s.pc = S.daddr; s.daddr = S.faddr; s.faddr = S.nfaddr; s.nfaddr = S.nfaddr + 24'd1;

    // ---------------------------------------------------------------- pops / pushes
    // (inline: MAME's POP_PC / POP_LOOP / PUSH_PC / PUSH_LOOP, one array write each kept)

    // ---------------------------------------------------------------- loop end
    lce_ne1 = s.curlcntr != 32'd1;
    if ((S.stk & LSEM) == 0 && s.pc == s.la_addr) begin
        logic done;
        if (s.la_type == 2'd0) begin
            logic [31:0] ca;
            // the condition on ASTAT three words back for a loop longer than two (MAME)
            if (s.pc - s.pcstk > 24'd2) ca = (st == ST_D && ld_on) ? ah2 : ah3;
            else begin ca = astat; d_need_astat |= cond_astat(s.la_code); end
            done = do_cond(ca, flg, alusat, lce_ne1, s.la_code);
        end else begin
            s.curlcntr = s.curlcntr - 32'd1;
            done = s.curlcntr == 32'd0;
        end
        if (done) begin
            // POP_LOOP
            if (s.lstkp == 3'd0) begin x.unsup = 1'b1; x.why = U_STK; end
            s.lstkp = s.lstkp - 3'd1;
            s.lcntr = s.curlcntr;
            x.law = 1'b1; x.law_i = s.lstkp; x.law_d = la_pack(s.la_type, s.la_code, s.la_addr);
            if (s.lstkp != 3'd0) begin
                logic [31:0] w;
                s.curlcntr = lcs_p2;
                w = las_p2;
                s.la_addr = w[23:0]; s.la_code = w[28:24]; s.la_type = w[31:30];
            end else begin
                s.curlcntr = 32'hFFFF_FFFF;
                s.la_addr = 24'hFFFFFF; s.la_code = 5'h1f; s.la_type = 2'd3;
                s.stk = s.stk | LSEM;
            end
            nlpop = 1'b1;
            // POP_PC
            if (s.pcstkp == 6'd0) begin x.unsup = 1'b1; x.why = U_STK; end
            s.pcstkp = s.pcstkp - 6'd1;
            if (s.pcstkp < 6'd30) begin
                x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp); x.pcw_d = s.pcstk;
                if (s.pcstkp != 6'd0) s.pcstk = pcs_p2;
                else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                s.stk = s.stk & ~PCFL;
            end
            npop = 2'd1;
        end else begin
            // CHANGE_PC(TOP_PC)
            s.pc = s.pcstk; s.daddr = s.pcstk; s.faddr = s.pcstk + 24'd1; s.nfaddr = s.pcstk + 24'd2;
        end
    end
    lce_ne1 = s.curlcntr != 32'd1;
    // the ureg source (every form that reads one names it in ur_sel), after the loop end
    ur_all = (ur_sel[7:4] == 4'h6) ? seq_rd(ur_sel[3:0], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v;

    // ---------------------------------------------------------------- the handler
    cond = op[37:33];
    comp = op[22:0];
    ii = op[43:41]; mm = op[40:38];
    jdb = op[26]; ee = op[25]; ci = op[24]; la = op[38];
    rx = comp[7:4]; ry = comp[3:0]; rnn = comp[11:8];
    comp_on = 1'b0;

    // the condition (ureg <-> ureg has it at op[35:31]); D waits for a landing's ASTAT only if the
    // condition reads ASTAT and the form has one (DO UNTIL's is the loop's, tested at its end)
    cnd = (op[47:44] == 4'b0111) ? op[35:31] : cond;
    cok = if_cond(astat_d, flg, alusat, lce_ne1, cnd);
    if (op[47:44] == 4'b0100 || op[47:44] == 4'b0101 || op[47:44] == 4'b0110 || op[47:44] == 4'b0111 ||
        op[47:44] == 4'b1000 || op[47:46] == 2'b11 || op[47:40] == 8'b00000001 || op[47:40] == 8'b00000010 ||
        op[47:40] == 8'b00000100 || op[47:41] == 7'b0000011 || op[47:41] == 7'b0000100 || op[47:41] == 7'b0000101)
        d_need_astat |= cond_astat(cnd);
    // the branch targets: PC + offset (one adder, DO's loop end too), I + M of DAG2
    pc1 = s.pc;
    rel_t = pc1 + ((op[47:42] == 6'b000010 || op[47:46] == 2'b11) ? 24'(sext6(op[32:27])) : op[23:0]);
    ind_t = 24'(i2_rd + m2_rd);

    casez (op[47:39])
    9'b001??????: begin x.unsup = 1'b1; x.why = U_FORM; end   // type 1: dual moves
    9'b00000001?: begin                                         // compute
        comp_on = cok;
    end
    9'b0100?????, 9'b0101?????: begin                           // compute, ureg <-> DM|PM, pre / post
        logic g, dd, post;
        logic [7:0] u;
        g = op[32]; dd = op[31]; u = op[30:23]; post = op[44];
        if (cok) begin
            comp_on = 1'b1;
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                mo_sel = post ? 2'd0 : 2'd1;
                if (dd) begin
                    wd_sel = 2'd1;
                    d_rmask |= ureg_rmask(u);
                    if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
                    if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
                end else begin
                    x.ld_u = 1'b1; x.ld_ureg = u;
                    if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
                end
                if (post) begin x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; pm_sel = 2'd0; end
            end
        end
    end
    9'b0110?????: begin                                         // compute, dreg <-> DM|PM, imm modify
        logic upd, g, dd;
        logic [3:0] dr;
        logic [31:0] mv;
        upd = op[38]; g = op[40]; dd = op[39]; dr = op[26:23];
        mv = sext6(op[32:27]);
        if (cok) begin
            comp_on = 1'b1;
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                mo_sel = upd ? 2'd0 : 2'd2;
                if (dd) begin wd_sel = 2'd0; d_rmask |= 16'h1 << dr; end
                else begin x.ld_r = 1'b1; x.ld_dst = dr; end
                if (upd) begin x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; pm_sel = 2'd1; end
            end
        end
    end
    9'b0111?????: begin                                         // compute, ureg <-> ureg
        logic [7:0] us, ud;
        us = op[43:36]; ud = op[30:23];
        if (cok) begin
            comp_on = 1'b1;
            x.uw = 1'b1; x.uw_reg = ud; wd_sel = 2'd1;
            d_rmask |= ureg_rmask(us);
            if (us[7:4] == 4'h7 && (us[3:0] == 4'hc || us[3:0] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(us, 1'b0) || !ureg_ok(ud, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
    end
    9'b1000?????: begin                                         // immediate shift, dreg <-> DM|PM
        logic g, dd;
        logic [3:0] dr;
        g = op[32]; dd = op[31]; dr = op[26:23];
        if (cok) begin
            x.sh_on = 1'b1; x.sh_op = op[21:16]; x.sh_imm = 1'b1;
            x.rn = op[7:4]; rx = op[3:0]; rnn = op[7:4];
            d_rmask |= (16'h1 << op[3:0]) | (16'h1 << op[7:4]);
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                if (dd) begin wd_sel = 2'd0; d_rmask |= 16'h1 << dr; end
                else begin x.ld_r = 1'b1; x.ld_dst = dr; end
                x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; pm_sel = 2'd0;
            end
        end
    end
    9'b00000010?: begin                                         // immediate shift
        if (cok) begin
            x.sh_on = 1'b1; x.sh_op = op[21:16]; x.sh_imm = 1'b1;
            x.rn = op[7:4]; rx = op[3:0]; rnn = op[7:4];
            d_rmask |= (16'h1 << op[3:0]) | (16'h1 << op[7:4]);
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
        end
    end
    9'b00000100?: begin                                         // compute, modify
        if (cok) begin
            comp_on = 1'b1;
            x.pmod = 1'b1; x.pmod_i = {op[38], op[32:30]}; pm_sel = 2'd2;
        end
    end
    9'b000001100, 9'b000001110: begin                           // direct / relative jump
        if (cok) begin
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd0;
            if (ci) begin x.unsup = 1'b1; x.why = U_FORM; end
            if (la) begin
                // POP_PC, POP_LOOP
                if (s.pcstkp == 6'd0) begin x.unsup = 1'b1; x.why = U_STK; end
                s.pcstkp = s.pcstkp - 6'd1;
                if (s.pcstkp < 6'd30) begin
                    if (!x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp); x.pcw_d = s.pcstk; end
                    if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;
                    else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                    s.stk = s.stk & ~PCFL;
                end
                if (s.lstkp == 3'd0) begin x.unsup = 1'b1; x.why = U_STK; end
                s.lstkp = s.lstkp - 3'd1;
                s.lcntr = s.curlcntr;
                if (!x.law) begin x.law = 1'b1; x.law_i = s.lstkp; x.law_d = la_pack(s.la_type, s.la_code, s.la_addr); end
                if (s.lstkp != 3'd0) begin
                    logic [31:0] w;
                    s.curlcntr = nlpop ? lcs_p3 : lcs_p2;
                    w = nlpop ? las_p3 : las_p2;
                    s.la_addr = w[23:0]; s.la_code = w[28:24]; s.la_type = w[31:30];
                end else begin
                    s.curlcntr = 32'hFFFF_FFFF;
                    s.la_addr = 24'hFFFFFF; s.la_code = 5'h1f; s.la_type = 2'd3;
                    s.stk = s.stk | LSEM;
                end
            end
        end
    end
    9'b000001101, 9'b000001111: begin                           // direct / relative call
        if (cok) begin
            logic [23:0] ret;
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd0;
            ret = op[40] ? (jdb ? pc1 + 24'd3 : pc1 + 24'd1) : (jdb ? s.nfaddr : s.daddr);
            // PUSH_PC
            if (s.pcstkp != 6'd0 && !x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp - 6'd1); x.pcw_d = s.pcstk; end
            s.pcstkp = s.pcstkp + 6'd1;
            s.stk = s.stk & ~PCEM;
            if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
            s.pcstk = ret;
        end
    end
    9'b0000100??: begin                                         // indirect / relative jump or call, compute
        logic call, take;
        call = op[39];
        if (ci) begin x.unsup = 1'b1; x.why = U_FORM; end
        take = cok;
        if (ee) comp_on = !cok;
        else comp_on = cok;
        if (take) begin
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd2;
            if (call) begin
                logic [23:0] ret;
                ret = jdb ? s.nfaddr : s.daddr;
                if (s.pcstkp != 6'd0 && !x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp - 6'd1); x.pcw_d = s.pcstk; end
                s.pcstkp = s.pcstkp + 6'd1;
                s.stk = s.stk & ~PCEM;
                if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
                s.pcstk = ret;
            end else if (la) begin
                x.unsup = 1'b1; x.why = U_STK;      // loop abort on an indirect jump: not seen
            end
        end
    end
    9'b11???????: begin                                         // indirect / relative jump, else compute, dreg <-> DM
        logic [3:0] dr;
        dr = op[26:23];
        if (cok) begin
            br = 1'b1; tsel = op[45] ? 2'd1 : 2'd2;
        end else begin
            comp_on = 1'b1;
            mem_on = 1'b1; mem_wr = op[44];
            if (op[44]) begin wd_sel = 2'd0; d_rmask |= 16'h1 << dr; end
            else begin x.ld_r = 1'b1; x.ld_dst = dr; end
            x.pmod = 1'b1; x.pmod_i = {1'b0, op[43:41]}; pm_sel = 2'd0;
        end
    end
    9'b00001010?, 9'b00001011?: begin                           // RTS, RTI
        logic take;
        if (op[40]) begin x.unsup = 1'b1; x.why = U_FORM; end    // RTI
        take = cok;
        if (ee) comp_on = !cok; else comp_on = cok;
        if (take) begin
            if (s.pcstkp == 6'd0) begin x.unsup = 1'b1; x.why = U_STK; end
            br = 1'b1; br_db = jdb; tsel = 2'd3; rts_v = s.pcstk;
            s.pcstkp = s.pcstkp - 6'd1;
            if (s.pcstkp < 6'd30) begin
                if (!x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp); x.pcw_d = s.pcstk; end
                if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;
                else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                s.stk = s.stk & ~PCFL;
            end
        end
    end
    9'b00001100?, 9'b00001101?, 9'b00001110?: begin             // DO UNTIL
        logic [31:0] off;
        logic [23:0] ldist;
        off = sext24(op[23:0]);
        ldist = off[31] ? -off[23:0] : off[23:0];
        if (op[42:40] == 3'b100) s.lcntr = {16'h0, op[39:24]};
        else if (op[42:40] == 3'b101) begin
            s.lcntr = ur_all;
            d_rmask |= ureg_rmask(op[39:32]);
            if (op[39:36] == 4'h7 && (op[35:32] == 4'hc || op[35:32] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(op[39:32], 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
        // PUSH_PC
        if (s.pcstkp != 6'd0 && !x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp - 6'd1); x.pcw_d = s.pcstk; end
        s.pcstkp = s.pcstkp + 6'd1;
        s.stk = s.stk & ~PCEM;
        if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
        // PUSH_LOOP
        if (s.lstkp != 3'd0) begin
            // after a loop-end pop this writes back the word the pop read: dropped (R1028)
            x.lcw = !nlpop; x.lcw_i = s.lstkp - 3'd1; x.lcw_d = s.curlcntr;
            if (!x.law) begin x.law = 1'b1; x.law_i = s.lstkp - 3'd1; x.law_d = la_pack(s.la_type, s.la_code, s.la_addr); end
        end
        s.curlcntr = s.lcntr;
        s.lstkp = s.lstkp + 3'd1;
        if (s.lstkp == 3'd7) begin x.unsup = 1'b1; x.why = U_STK; end    // a seventh level
        s.lcntr = (s.lstkp < 3'd6) ? (nlpop ? lcs_q0 : lcs_q1) : 32'hFFFF_FFFF;
        s.stk = s.stk & ~LSEM;
        s.pcstk = pc1 + 24'd1;
        s.la_addr = rel_t;
        if (op[42:40] == 3'b110) begin s.la_code = cond; s.la_type = 2'd0; end
        else begin
            s.la_code = 5'h0f;
            s.la_type = (ldist == 24'd1) ? 2'd1 : (ldist == 24'd2) ? 2'd2 : 2'd3;
        end
    end
    9'b00001111?: begin                                         // immediate -> ureg
        x.uw = 1'b1; x.uw_reg = op[39:32]; wd_sel = 2'd2;
        if (!ureg_ok(op[39:32], 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
    end
    9'b000100???: begin                                         // ureg <-> DM|PM, direct
        logic [7:0] u;
        u = op[39:32];
        if (op[41]) begin x.unsup = 1'b1; x.why = U_PM; end
        else begin
            mem_on = 1'b1; mem_wr = op[40]; mb_i = 1'b0; mo_sel = 2'd3;
            if (op[40]) begin
                wd_sel = 2'd1; d_rmask |= ureg_rmask(u);
                if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
                if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end else begin
                x.ld_u = 1'b1; x.ld_ureg = u;
                if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end
        end
    end
    9'b101??????: begin                                         // ureg <-> DM|PM, indirect
        logic [7:0] u;
        u = op[39:32];
        if (op[44]) begin x.unsup = 1'b1; x.why = U_PM; end
        else begin
            mem_on = 1'b1; mem_wr = op[40]; mo_sel = 2'd3;
            if (op[40]) begin
                wd_sel = 2'd1; d_rmask |= ureg_rmask(u);
                if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
                if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end else begin
                x.ld_u = 1'b1; x.ld_ureg = u;
                if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end
        end
    end
    9'b1001?????: begin                                         // immediate data -> DM|PM
        if (op[37]) begin x.unsup = 1'b1; x.why = U_PM; end
        else begin
            mem_on = 1'b1; mem_wr = 1'b1; wd_sel = 2'd2;
            x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; pm_sel = 2'd0;
        end
    end
    9'b00010100?: begin                                         // system register bit operation
        // the register's value read in D (the ureg port), but ASTAT's and STKY's in X (a landing
        // may change them in D's clock)
        x.bitop = 1'b1; x.bit_kind = op[39:37]; x.bit_reg = op[35:32]; wd_sel = 2'd1;
        if (!ureg_ok({4'h7, op[35:32]}, 1'b1) || op[39:37] == 3'd3 || op[39:37] > 3'd5) begin x.unsup = 1'b1; x.why = U_UREG; end
    end
    9'b000101100: begin                                         // modify I by an immediate
        x.pmod = 1'b1; x.pmod_i = {op[38], op[34:32]}; pm_sel = 2'd3;
    end
    9'b00010111?: begin                                         // push / pop the stacks
        x.unsup = 1'b1; x.why = U_STK;
    end
    9'b000000000: ;                                             // NOP
    default: begin x.unsup = 1'b1; x.why = U_FORM; end          // IDLE, bit-reverse, the rest
    endcase

    // the queue: a taken branch (after a loop end's CHANGE_PC); delayed, only the fetch after next
    case (tsel)
    2'd0: tgt = op[23:0];
    2'd1: tgt = rel_t;
    2'd2: tgt = ind_t;
    default: tgt = rts_v;
    endcase
    if (br && !br_db) begin
        qb = tgt; s.pc = qb; s.daddr = qb; s.faddr = qb + 24'd1; s.nfaddr = qb + 24'd2;
    end else if (br) s.nfaddr = tgt;

    // ---------------------------------------------------------------- the compute field
    if (comp_on && comp != 23'h0) begin
        logic [7:0] cop;
        logic [1:0] cu;
        cop = comp[19:12]; cu = comp[21:20];
        if (comp[22]) begin
            logic [5:0] mop;
            mop = comp[21:16];
            if (mop[5:3] == 3'b011) begin                       // FMUL with FADD / FSUB / ...
                x.fl_on = 1'b1; x.fl_mul = 1'b1;
                x.rm = comp[15:12]; x.ra = comp[11:8]; x.rm_we = 1'b1; x.ra_we = 1'b1;
                case (mop[2:0])
                3'd0: x.fl_add = 1'b1;
                3'd1: x.fl_sub = 1'b1;
                3'd2: begin x.fl_misc = 1'b1; x.misc_op = 5'd17; end   // FLOAT BY (multi)
                3'd3: begin x.fl_misc = 1'b1; x.misc_op = 5'd14; end   // FIX BY (multi)
                3'd4: begin x.fl_add = 1'b1; x.fl_avg = 1'b1; end    // FAVG
                3'd5: begin x.fl_misc = 1'b1; x.misc_op = 5'd4;  end   // FABS
                3'd6: begin x.fl_misc = 1'b1; x.misc_op = 5'd6;  end   // FMAX
                default: begin x.fl_misc = 1'b1; x.misc_op = 5'd5; end // FMIN
                endcase
                d_rmask |= (16'h1 << {2'b00, comp[7:6]}) | (16'h1 << {2'b01, comp[5:4]}) |
                           (16'h1 << {2'b10, comp[3:2]}) | (16'h1 << {2'b11, comp[1:0]});
            end else begin
                x.unsup = 1'b1; x.why = U_COMP;                 // MR moves, fixed multiply, dual
            end
        end else begin
            case (cu)
            2'd0: begin
                if (!cop[7]) begin
                    if (cop[7:4] == 4'h7 || !alu_fixed_ok(cop)) begin x.unsup = 1'b1; x.why = U_COMP; end
                    else begin x.fix_on = 1'b1; x.fix_op = cop; x.rn = rnn; end
                end else if (cop[7:4] == 4'hf) begin
                    x.unsup = 1'b1; x.why = U_COMP;             // float dual add / subtract
                end else begin
                    x.fl_on = 1'b1; x.ra = rnn; x.ra_we = 1'b1;
                    case (cop)
                    8'h81: x.fl_add = 1'b1;
                    8'h82: x.fl_sub = 1'b1;
                    8'h91: begin x.fl_add = 1'b1; x.fl_absf = 1'b1; end
                    8'h92: begin x.fl_sub = 1'b1; x.fl_absf = 1'b1; end
                    8'h89: begin x.fl_add = 1'b1; x.fl_avg = 1'b1; end
                    8'h8a: begin x.fl_misc = 1'b1; x.misc_op = 5'd9; x.fl_comp = 1'b1; x.ra_we = 1'b0; end
                    8'ha1: begin x.fl_misc = 1'b1; x.misc_op = 5'd8; end
                    8'ha2: begin x.fl_misc = 1'b1; x.misc_op = 5'd7; end
                    8'hb0: begin x.fl_misc = 1'b1; x.misc_op = 5'd4; end
                    8'hbd: begin x.fl_misc = 1'b1; x.misc_op = 5'd10; end
                    8'hc1: begin x.fl_misc = 1'b1; x.misc_op = 5'd11; end
                    8'hc4: begin x.fl_misc = 1'b1; x.misc_op = 5'd18; end
                    8'hc5: begin x.fl_misc = 1'b1; x.misc_op = 5'd19; end
                    8'hc9: begin x.fl_misc = 1'b1; x.misc_op = 5'd12; end
                    8'hca: begin x.fl_misc = 1'b1; x.misc_op = 5'd15; end
                    8'hd9: begin x.fl_misc = 1'b1; x.misc_op = 5'd13; end
                    8'hda: begin x.fl_misc = 1'b1; x.misc_op = 5'd16; end
                    8'he0: begin x.fl_misc = 1'b1; x.misc_op = 5'd20; end
                    8'he1: begin x.fl_misc = 1'b1; x.misc_op = 5'd5; end
                    8'he2: begin x.fl_misc = 1'b1; x.misc_op = 5'd6; end
                    8'he3: begin x.fl_misc = 1'b1; x.misc_op = 5'd21; end
                    default: begin x.unsup = 1'b1; x.why = U_COMP; end
                    endcase
                end
                d_rmask |= (16'h1 << rx) | (16'h1 << ry);
            end
            2'd1: begin
                if (cop == 8'h30) begin
                    x.fl_on = 1'b1; x.fl_mul = 1'b1; x.rm = rnn; x.rm_we = 1'b1;
                    d_rmask |= (16'h1 << rx) | (16'h1 << ry);
                end else begin x.unsup = 1'b1; x.why = U_COMP; end    // fixed multiply, MR
            end
            2'd2: begin
                x.sh_on = 1'b1; x.sh_op = cop[7:2]; x.sh_imm = 1'b0; x.rn = rnn;
                if (!shift_ok(cop[7:2])) begin x.unsup = 1'b1; x.why = U_COMP; end
                d_rmask |= (16'h1 << rx) | (16'h1 << ry) | (16'h1 << rnn);
            end
            default: begin x.unsup = 1'b1; x.why = U_COMP; end
            endcase
        end
        if (x.fl_on && !mode1[M1_RND32]) begin x.unsup = 1'b1; x.why = U_RND; end
    end
    x.trunc = trunc;

    // the data access's address (one adder), the store / ureg data, the post-modify amount
    begin
        logic [31:0] off;
        case (mo_sel)
        2'd1: off = m1_rd;
        2'd2: off = sext6(op[32:27]);
        2'd3: off = op[31:0];
        default: off = 32'h0;
        endcase
        mem_a = (mb_i ? i1_rd : 32'h0) + off;
    end
    x.acc_wd = (wd_sel == 2'd0) ? rf_rd[4] : (wd_sel == 2'd1) ? ur_all : op[31:0];
    case (pm_sel)
    2'd0: x.pmod_m = m1_rd;
    2'd1: x.pmod_m = sext6(op[32:27]);
    2'd2: x.pmod_m = op[38] ? m2_rd : m1_rd;
    default: x.pmod_m = op[31:0];
    endcase

    // MAME's order: a load / ureg move to the float result's register wins
    if (x.ld_r && x.ld_dst == x.rm) x.rm_we = 1'b0;
    if (x.ld_r && x.ld_dst == x.ra) x.ra_we = 1'b0;
    if ((x.ld_u && x.ld_ureg[7:4] == 4'h0) || (x.uw && x.uw_reg[7:4] == 4'h0)) begin
        logic [3:0] k;
        k = x.ld_u ? x.ld_ureg[3:0] : x.uw_reg[3:0];
        if (k == x.rm) x.rm_we = 1'b0;
        if (k == x.ra) x.ra_we = 1'b0;
    end
    if (x.fl_mul && x.fl_on && x.rm_we && x.ra_we && x.rm == x.ra && !x.fl_comp) x.rm_we = 1'b0;  // Ra written after Rm

    // the memory access
    if (mem_on) begin
        {bad, x.acc} = dm_kind(mem_a, mem_wr);
        x.acc_wr = mem_wr;
        x.acc_addr = mem_a;
        if (bad) begin x.unsup = 1'b1; x.why = U_MEM; end
    end
    // circular buffers (L != 0) are not done
    if (x.pmod && lnz[x.pmod_i]) begin x.unsup = 1'b1; x.why = U_DAG; end
    x.pmod_b = x.pmod_i[3] ? i2_rd : i1_rd;

    // an unsupported word does nothing but move the queue (and is flagged)
    if (x.unsup) begin
        logic [3:0] w;
        w = x.why;
        x = '0; x.unsup = 1'b1; x.why = w;
        s = S;
        s.pc = S.daddr; s.daddr = S.faddr; s.faddr = S.nfaddr; s.nfaddr = S.nfaddr + 24'd1;
    end

    // the program memory ends at 2^PM_AW words
    if (s.daddr < 24'h20000 || s.daddr >= 24'(32'h20000 + PMW)) begin
        if (!x.unsup) begin x.unsup = 1'b1; x.why = U_PM; end
    end

    dx = x;
    dsn = s;
    d_opx = rf_rd[0]; d_opy = rf_rd[1]; d_opn = rf_rd[2];
    // the multifunction's four operands: R0-3, R4-7, R8-11, R12-15 (the ports' addresses, below)
    d_fmx = rf_rd[0]; d_fmy = rf_rd[1];
    if (comp[22]) begin d_fax = rf_rd[2]; d_fay = rf_rd[3]; end
    else begin d_fax = rf_rd[0]; d_fay = rf_rd[1]; end
    d_stx = x.acc_wd;
    d_dm_a = mem_a[DM_AW-1:0];
    d_dm_rd = mem_on && x.acc == A_DM && !mem_wr && !x.unsup;
end

// the R file's read addresses, from the opcode alone
always_comb begin
    logic [47:0] o;
    logic        ish, mf;
    logic [3:0]  rx, rnn;
    o = pm_q;
    ish = o[47:44] == 4'b1000 || o[47:40] == 8'b00000010;     // the immediate shifts
    mf = o[22] && !ish;                                         // a multifunction compute field
    rx = ish ? o[3:0] : o[7:4];
    rnn = ish ? o[7:4] : o[11:8];
    rf_ra[0] = mf ? {2'b00, o[7:6]} : rx;
    rf_ra[1] = mf ? {2'b01, o[5:4]} : o[3:0];
    rf_ra[2] = mf ? {2'b10, o[3:2]} : rnn;
    rf_ra[3] = {2'b11, o[1:0]};
    // a store's dreg (op[26:23]) or the ureg D names (ur_sel)
    if (o[47:45] == 3'b010 || o[47:44] == 4'b0110 || o[47:44] == 4'b1000 || o[47:46] == 2'b11) rf_ra[4] = o[26:23];
    else if (o[47:44] == 4'b0111) rf_ra[4] = o[39:36];
    else rf_ra[4] = o[35:32];
end

// the scoreboard: a register or ASTAT being landed this clock
always_comb begin
    logic [15:0] lm;
    lm = 16'h0;
    if (ld_on && ld_mwe) lm |= 16'h1 << ld_rm;
    if (ld_on && ld_awe) lm |= 16'h1 << ld_ra;
    if (rf_pw) lm |= 16'h1 << rf_pa;
    // a landing that writes two R registers: D does not finish in it (the second write is next clock)
    d_wait = (d_rmask & lm) != 0 || (ld_on && d_need_astat) || ir_pw || (ld_on && ld_mwe && ld_awe);
end
assign d_go = st == ST_D && !d_wait;

// ================================================================== X

logic        x_done;
logic [31:0] x_ld;                          // the loaded word
logic        x_ldv;
xres_t       x_fix, x_sh;
logic        fm_busy;
logic [31:0] fa_r, fa_a, fa_s, fm_r, fm_a, fm_s;
logic        x_ext_wait;
logic        x_ext_on;

// the fixed ALU, the shifter and the misc float functions: one shared unit (R1028)
logic [31:0] xu_fr, xu_sr, xu_fa, xu_sa, xu_fs;
logic        xu_fw, xu_sw;
m2b_sharc_xu #(.MAME_RND(MAME_RND)) u_xu (
    .fix_on(XC.fix_on), .fix_op(XC.fix_op), .sh_on(XC.sh_on), .sh_op(XC.sh_op), .sh_imm(XC.sh_imm),
    .sh_val(XC.sh_imm ? {20'h0, x_op[30:27], x_op[15:8]} : op_y), .misc_on(XC.fl_misc), .misc_op(XC.misc_op),
    .x(op_x), .y(op_y), .n(op_n), .fx(fa_x), .fy(fa_y), .astat, .alusat(mode1[M1_ALUSAT]), .trunc(XC.trunc),
    .fix_r(xu_fr), .sh_r(xu_sr), .fix_we(xu_fw), .sh_we(xu_sw), .fix_astat(xu_fa),
    .sh_astat(xu_sa), .fix_stky(xu_fs), .misc_r(misc_d_r), .misc_a(misc_d_a), .misc_s(misc_d_s));
assign x_fix = {xu_fr, xu_fw, xu_fa, xu_fs};     // xres_t: r, we, astat, stky
assign x_sh = {xu_sr, xu_sw, xu_sa, 32'h0};

// the float units: operands from D, stage 1 at X's end, results in the landing clock
logic fl_en, fm_restart;
assign fl_en = st == ST_X && x_done;
sharc_fadd #(.MAME_RND(MAME_RND)) u_fadd (
    .clk, .en(fl_en), .x(fa_x), .y(fa_y), .sub(XC.fl_sub), .avg(XC.fl_avg), .trunc(XC.trunc),
    .r(fa_r), .astat(fa_a), .stky(fa_s), .nan_in(), .inf_both());
sharc_fmul #(.MAME_RND(MAME_RND)) u_fmul (
    .clk, .en(fl_en), .restart(fm_restart),
    .valid(st == ST_X && XC.fl_on && XC.fl_mul), .x(fm_x), .y(fm_y), .trunc(XC.trunc),
    .busy(fm_busy), .r(fm_r), .astat(fm_a), .stky(fm_s));

// X's access
always_comb begin
    x_ext_wait = 1'b0;
    x_ldv = 1'b0;
    x_ld = 32'h0;
    fin_pop = 1'b0;
    fout_push = 1'b0;
    fout_data = XC.acc_wd;
    case (XC.acc)
    A_DM:  begin x_ld = dm_q; x_ldv = !XC.acc_wr; end
    A_FIN: begin
        x_ext_wait = fin_empty;
        x_ld = fin_data; x_ldv = 1'b1;
        fin_pop = x_done;
    end
    A_FOUT: begin
        x_ext_wait = fout_full;
        fout_push = x_done;
    end
    A_IOP: begin
        x_ld = (XC.acc_addr[7:0] == 8'h37) ? 32'h0 : 32'h0;   // SYSCON reads 0 in MAME; DMA status 0
        x_ldv = !XC.acc_wr;
    end
    A_EXT: begin x_ext_wait = !ext_ack; x_ld = ext_rdata; x_ldv = !XC.acc_wr; end
    default: ;
    endcase
end
assign x_done = st == ST_X && !x_ext_wait && !(XC.fl_on && XC.fl_mul && fm_busy);
assign ext_req = st == ST_X && XC.acc == A_EXT && x_ext_on;
assign ext_we = XC.acc_wr;
assign ext_addr = XC.acc_addr;
assign ext_wdata = XC.acc_wd;

// the ureg write of a word in X (a load to a ureg, or a ureg move / immediate)
logic        xu_w;
logic [7:0]  xu_r;
logic [31:0] xu_v;
always_comb begin
    xu_w = 1'b0; xu_r = 8'h0; xu_v = 32'h0;
    if (XC.ld_u && x_ldv) begin xu_w = 1'b1; xu_r = XC.ld_ureg; xu_v = x_ld; end
    if (XC.uw) begin xu_w = 1'b1; xu_r = XC.uw_reg; xu_v = XC.acc_wd; end
end

// the landing's Ra value: the adder's or the misc unit's, ABS(Fx +- Fy) made a magnitude
logic [31:0] ld_rav, ld_raa, ld_ras;
always_comb begin
    ld_rav = ld_misc ? misc_r : fa_r;
    ld_raa = ld_misc ? misc_a : fa_a;
    ld_ras = ld_misc ? misc_s : fa_s;
    if (ld_absf) begin
        if ((ld_raa & AI) == 0) ld_rav = ld_rav & ~SIGN;
        ld_raa = ld_raa & ~AN;
    end
end

// the R file's write port: this clock's first write, or last clock's deferred second
logic rx_c, rx_l, rx_done;
always_comb begin
    rx_done = st == ST_X && x_done;
    rx_c = rx_done && ((XC.fix_on && x_fix.we) || (XC.sh_on && x_sh.we));     // the compute's
    rx_l = rx_done && ((XC.ld_r && x_ldv) || (xu_w && xu_r[7:4] == 4'h0));    // a load / ureg move's
    rf_we = 1'b0; rf_wa = XC.rn; rf_wd = XC.fix_on ? x_fix.r : x_sh.r;
    if (rf_pw) begin rf_we = 1'b1; rf_wa = rf_pa; rf_wd = rf_pd; end
    else if (ld_on && ld_mwe) begin rf_we = 1'b1; rf_wa = ld_rm; rf_wd = fm_r; end
    else if (ld_on && ld_awe) begin rf_we = 1'b1; rf_wa = ld_ra; rf_wd = ld_rav; end
    else if (rx_c) rf_we = 1'b1;
    else if (rx_l) begin rf_we = 1'b1; rf_wa = XC.ld_r ? XC.ld_dst : xu_r[3:0]; rf_wd = XC.ld_r ? x_ld : xu_v; end
end
always_ff @(posedge clk) begin
    // the second write: the landing's Ra after its Rm, a load after the compute (MAME's order:
    // the later wins a register both write)
    rf_pw <= !reset && ((ld_on && ld_mwe && ld_awe) || (rx_c && rx_l));
    rf_pl <= ld_on && ld_mwe && ld_awe;
    if (ld_on) begin rf_pa <= ld_ra; rf_pd <= ld_rav; end
    else begin rf_pa <= XC.ld_r ? XC.ld_dst : xu_r[3:0]; rf_pd <= XC.ld_r ? x_ld : xu_v; end
end
genvar gp;                                  // (Quartus 17: not in the for)
generate for (gp = 0; gp < 5; gp++) begin : g_rf
    m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u (.clk, .we(rf_we), .wa(rf_wa), .wd(rf_wd), .ra(rf_ra[gp]), .rd(rf_rd[gp]));
end endgenerate

// I / M: D's read addresses from the opcode alone
always_comb begin
    logic [47:0] o;
    logic        modf, modi;
    o = pm_q;
    modf = o[47:40] == 8'b00000100;            // compute, modify
    modi = o[47:39] == 9'b000101100;           // modify by an immediate
    i1_ra = modf ? o[32:30] : modi ? o[34:32] : o[43:41];
    i2_ra = modi ? o[34:32] : o[32:30];
    m1_ra = modf ? o[29:27] : o[40:38];
    m2_ra = o[29:27];
end

// I / M: the writes at X's end, the deferred I write after
always_comb begin
    logic xdone, xi_u;
    logic [3:0] iu;
    logic [31:0] base;
    xdone = st == ST_X && x_done;
    xi_u = xu_w && (xu_r[7:4] == 4'h1 || xu_r[7:4] == 4'h4);
    iu = {xu_r[3], xu_r[2:0]};
    // post-modify after the load (a load to the same I is modified: MAME's apply_load then post_modify)
    base = (xi_u && iu == XC.pmod_i) ? xu_v : XC.pmod_b;
    ir_we = 1'b0; ir_wa = XC.pmod_i; ir_wd = base + XC.pmod_m;
    if (ir_pw) begin ir_we = 1'b1; ir_wa = ir_pa; ir_wd = ir_pd; end
    else if (xdone && XC.pmod) ir_we = 1'b1;
    else if (xdone && xi_u) begin ir_we = 1'b1; ir_wa = iu; ir_wd = xu_v; end
    mr_we = xdone && xu_w && xu_r[7:4] == 4'h2;
    mr_wa = {xu_r[3], xu_r[2:0]};
    mr_wd = xu_v;
end
always_ff @(posedge clk) begin
    ir_pw <= !reset && st == ST_X && x_done && XC.pmod && xu_w && (xu_r[7:4] == 4'h1 || xu_r[7:4] == 4'h4) &&
             {xu_r[3], xu_r[2:0]} != XC.pmod_i;
    ir_pa <= {xu_r[3], xu_r[2:0]};
    ir_pd <= xu_v;
end
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i1 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra({1'b0, i1_ra}), .rd(i1_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i2 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra({1'b1, i2_ra}), .rd(i2_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_iu (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(ur_sel[3:0]), .rd(iu_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m1 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra({1'b0, m1_ra}), .rd(m1_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m2 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra({1'b1, m2_ra}), .rd(m2_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_mu (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(ur_sel[3:0]), .rd(mu_rd));

// the system register bit operation: on the register's value (read in D; ASTAT and STKY now,
// a landing may have changed them since -- a bit operation word has no compute of its own)
logic [31:0] xb_v;
logic        xb_t, xb_btf;
always_comb begin
    logic [31:0] d;
    if (XC.bit_reg == 4'hc) xb_v = sys_rd(4'hc, astat, mode1, mode2, stky, irptl, imask, ustat1, ustat2, flg);
    else if (XC.bit_reg == 4'he) xb_v = stky;
    else xb_v = XC.acc_wd;
    d = x_op[31:0];
    xb_t = XC.bit_kind == 3'd4 || XC.bit_kind == 3'd5;
    xb_btf = (XC.bit_kind == 3'd4) ? (xb_v & d) == d : xb_v == d;
    case (XC.bit_kind)
    3'd0: xb_v = xb_v | d;
    3'd1: xb_v = xb_v & ~d;
    3'd2: xb_v = xb_v ^ d;
    default: ;
    endcase
end

// IOP registers this core takes (the rest of 0x00-0x41 is flagged; 0x42-0x4f are DMA 7)
function automatic logic iop_known(input logic [7:0] r);
    case (r)
    8'h00, 8'h02, 8'h08, 8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f, 8'h14, 8'h17, 8'h20, 8'h40, 8'h41, 8'h1c:
        return 1'b1;
    default: return r >= 8'h42 && r <= 8'h4f;
    endcase
endfunction

// an unsupported word in X: D's (it runs as a NOP), or one X finds at its end -- a MODE1 write
// changing a swap bit (the alternate files), SHARC-side DMA (DMAC6 DEN), an unknown IOP register
logic       us_go;
logic [3:0] us_why;
always_comb begin
    logic iop_w, iop_r;
    iop_w = XC.acc == A_IOP && XC.acc_wr;
    iop_r = XC.acc == A_IOP && !XC.acc_wr;
    us_go = 1'b0; us_why = XC.why;
    if (st == ST_X && XC.unsup) us_go = 1'b1;
    else if (st == ST_X && x_done) begin
        if ((xu_w && !XC.bitop && xu_r == 8'h7b && ((xu_v ^ mode1) & M1_SWAPS) != 0) ||
            (XC.bitop && XC.bit_reg == 4'hb && ((xb_v ^ mode1) & M1_SWAPS) != 0)) begin us_go = 1'b1; us_why = U_MODE; end
        if ((iop_w && XC.acc_addr[7:0] == 8'h1c && XC.acc_wd[0]) || (iop_w && !iop_known(XC.acc_addr[7:0])) ||
            (iop_r && XC.acc_addr[7:0] != 8'h00 && XC.acc_addr[7:0] != 8'h37)) begin us_go = 1'b1; us_why = U_IOP; end
    end
end

// ================================================================== the clocked part


always_ff @(posedge clk) begin
    if (reset) begin
        st <= ST_HALT;
        // MAME's device_reset (BOOT_MODE_HOST)
        S <= '0;
        S.pc <= 24'h20004; S.daddr <= 24'h20005; S.faddr <= 24'h20006; S.nfaddr <= 24'h20007;
        S.pcstk <= 24'hFFFFFF; S.pcstkp <= 6'd0; S.lstkp <= 3'd0;
        S.curlcntr <= 32'hFFFF_FFFF; S.lcntr <= 32'h0;
        S.la_addr <= 24'hFFFFFF; S.la_code <= 5'h1f; S.la_type <= 2'd3;
        S.stk <= PCEM | SSEM | LSEM;
        stky <= PCEM | SSEM | LSEM;
        astat <= 32'h0; mode1 <= 32'h0; mode2 <= 32'h0; irptl <= 32'h0; imask <= 32'h3;
        ustat1 <= 32'h0; ustat2 <= 32'h0; syscon <= 32'h10; px <= 48'h0;
        ii6 <= 32'h20000; im6 <= 32'h1; dmac6 <= 32'ha1;
        iop_hi <= 1'b0; iop_lo <= 16'h0; epb_shift <= 2'd0;
        ah1 <= 32'h0; ah2 <= 32'h0; ah3 <= 32'h0;
        lnz <= 16'h0;
        unsup <= 1'b0; unsup_pc <= 24'h0; unsup_op <= 48'h0; unsup_why <= 4'h0;
        ld_on <= 1'b0;
        dbg_ret <= 1'b0;
        x_ext_on <= 1'b0;
        // the register files and stacks are not cleared (MAME's are zero from construction;
        // these are zero from configuration)
    end else begin
        dbg_ret <= rf_pw && rf_pl;
        fm_restart <= 1'b0;

        // ---------------------------------------------------------------- the landing
        if (ld_on) begin
            logic [31:0] a, k;
            a = astat; k = stky;
            if (ld_mul) begin a = (a & ~MUL_GRP) | fm_a; k = k | fm_s; end
            if (ld_alu) begin
                a = (a & ~ALU_GRP) | ld_raa; k = k | ld_ras;
                if (ld_comp) a = (a & 32'h00FF_FFFF) | (misc_r & 32'hFF00_0000);
            end
            // a ureg write to ASTAT / STKY in the same word comes after the compute (MAME's order)
            if (ld_ua) a = ld_uv;
            if (ld_us) k = (k & STK_BITS) | (ld_uv & ~STK_BITS);
            astat <= a; stky <= k;
            ah1 <= a & AH_BITS; ah2 <= ah1; ah3 <= ah2;
            ld_on <= 1'b0;
            dbg_ret <= !(ld_mwe && ld_awe);         // (else after the deferred Ra write)
        end

        case (st)
        ST_HALT: if (run && !clr_on) st <= ST_FETCH;
        ST_FETCH: st <= ST_D;
        ST_D: if (d_go) begin
            XC <= dx;
            S <= dsn;                               // the sequencer at D's end (R1028); X's ureg writes after
            x_op <= pm_q;
            x_pc <= S.daddr;
            op_x <= d_opx; op_y <= d_opy; op_n <= d_opn;
            fa_x <= d_fax; fa_y <= d_fay; fm_x <= d_fmx; fm_y <= d_fmy;
            fetch_a <= dsn.daddr;
            fm_restart <= 1'b1;
            x_ext_on <= 1'b1;
            st <= ST_X;
        end
        ST_X: begin
            if (x_ext_on && ext_ack && XC.acc == A_EXT) x_ext_on <= 1'b0;
            // an unsupported word (D's, or X's own below): one capture, of the word in X
            if (us_go && !unsup) begin
                unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op; unsup_why <= us_why;
            end
            if (x_done) begin
                logic [31:0] a, k, uv;
                logic        uw;
                logic [7:0]  ur;
                seq_t sq;
                a = astat; k = stky;
                sq = S;
                // the fixed / shifter result
                if (XC.fix_on) begin
                    a = x_fix.astat; k = k | x_fix.stky;
                end
                if (XC.sh_on) begin
                    a = x_sh.astat;
                end
                // loads and ureg moves
                uw = 1'b0; ur = 8'h0; uv = 32'h0;
                uw = xu_w; ur = xu_r; uv = xu_v;
                // the system-register bit operation, on the register's value now
                if (XC.bitop) begin
                    if (xb_t) a = xb_btf ? (a | BTF) : (a & ~BTF);
                    uw = 1'b1; ur = {4'h7, XC.bit_reg}; uv = xb_v;
                end
                // post-modify: after the load (a load to the same I is modified)
                ld_ua <= 1'b0; ld_us <= 1'b0; ld_uv <= uv;
                if (uw) begin
                    logic [2:0] kk;
                    kk = ur[2:0];
                    case (ur[7:4])
                    4'h0: ;                                 // R: the write port (rf_we)
                    4'h1, 4'h2: ;                           // I, M: the write ports (ir_we, mr_we)
                    4'h3: lnz[{ur[3], kk}] <= uv != 32'h0;
                    4'h4: ;                                 // B: I = B (B itself is not kept; ir_we)
                    4'h6: case (ur[3:0])
                          4'h4: if (sq.pcstkp != 6'd0 && sq.pcstkp < 6'd31) sq.pcstk = uv[23:0];
                          4'h7: if (sq.lstkp != 3'd0 && sq.lstkp < 3'd7) sq.curlcntr = uv;
                          4'h8: if (sq.lstkp < 3'd6) sq.lcntr = uv;
                          default: ;
                          endcase
                    4'h7: case (ur[3:0])
                          4'h0: ustat1 <= uv;
                          4'h1: ustat2 <= uv;
                          4'h9: irptl <= uv;
                          4'ha: mode2 <= uv;
                          4'hb: begin
                              mode1 <= uv;
                          end
                          4'hc: if (XC.fl_on) begin ld_ua <= 1'b1; end else a = uv;
                          4'hd: imask <= uv;
                          4'he: if (XC.fl_on) begin ld_us <= 1'b1; end else k = (k & STK_BITS) | (uv & ~STK_BITS);
                          default: ;
                          endcase
                    4'hd: case (ur[3:0])
                          4'hc: px <= {px[47:16], uv[15:0]};
                          4'hd: px <= {uv, px[15:0]};
                          4'hb: px <= {px[47:32], uv};
                          default: ;
                          endcase
                    default: ;
                    endcase
                end
                // the accesses' writes
                if (XC.acc == A_IOP && XC.acc_wr) begin
                    case (XC.acc_addr[7:0])
                    8'h00: syscon <= XC.acc_wd;
                    8'h02, 8'h08, 8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f, 8'h14, 8'h17, 8'h20: ;
                    8'h40: ii6 <= XC.acc_wd;
                    8'h41: im6 <= XC.acc_wd;
                    8'h1c: dmac6 <= XC.acc_wd;
                    default: ;
                    endcase
                end
                // the sequencer and STKY's stack bits
                S <= sq;
                if (BENCH) S_dbg <= sq;                 // the benches' view: S after this word
                k = (k & ~STK_BITS) | (sq.stk & STK_BITS);
                astat <= a; stky <= k;
                // the float landing next clock
                ld_on <= 1'b1;
                ld_mwe <= XC.fl_on && XC.fl_mul && XC.rm_we;
                ld_awe <= XC.fl_on && (XC.fl_add || XC.fl_sub || XC.fl_misc) && XC.ra_we;
                ld_rm <= XC.rm; ld_ra <= XC.ra;
                ld_mul <= XC.fl_on && XC.fl_mul;
                ld_alu <= XC.fl_on && (XC.fl_add || XC.fl_sub || XC.fl_misc);
                ld_misc <= XC.fl_misc;
                ld_absf <= XC.fl_absf;
                ld_comp <= XC.fl_comp;
                misc_r <= misc_d_r; misc_a <= misc_d_a; misc_s <= misc_d_s;
                if (BENCH) begin dbg_pc <= x_pc; dbg_op <= x_op; end   // the benches' only
                st <= ST_D;
            end
        end
        default: st <= ST_HALT;
        endcase

        // the host: IOP window writes (external_iop_write) and the upload (external_dma_write)
        if (host_iop_we) begin
            logic [31:0] d;
            logic        go;
            go = 1'b1;
            d = host_iop_data;
            if (syscon[4] && host_iop_reg != 8'h04) begin
                if (!iop_hi) begin iop_lo <= host_iop_data[15:0]; iop_hi <= 1'b1; go = 1'b0; end
                else begin d = {host_iop_data[15:0], iop_lo}; iop_hi <= 1'b0; end
            end
            if (go)
                case (host_iop_reg)
                8'h1c: dmac6 <= d;
                8'h00: syscon <= d;
                8'h40: ii6 <= d;
                8'h41: im6 <= d;
                8'h04: begin
                    epb_shift <= (epb_shift == 2'd2) ? 2'd0 : epb_shift + 2'd1;
                    if (epb_shift == 2'd2) ii6 <= ii6 + im6;
                end
                default: ;
                endcase
        end
        if (xdma_we && xdma_phase == 2'd2) ii6 <= ii6 + im6;
    end
end

// the host's PM writes (external_dma_write, 16/48 packing; MSWF picks the order)
always_comb begin
    logic [1:0] w;
    logic       en;
    logic [31:0] idx;
    en = 1'b0; w = 2'd0;
    pm_wd = 16'h0;
    if (xdma_we) begin en = 1'b1; w = xdma_phase; pm_wd = xdma_data; end
    else if (host_iop_we && host_iop_reg == 8'h04) begin en = 1'b1; w = epb_shift; pm_wd = host_iop_data[15:0]; end
    if (dmac6[8]) w = 2'd2 - w;
    idx = (ii6 & 32'h1FFFF) | 32'h20000;
    pm_wa = PM_AW'(idx - 32'h20000);
    pm_we = 3'b000;
    if (en && dmac6[7:6] == 2'd2 && idx < 32'h20000 + PMW) pm_we = 3'b001 << w;
    else if (clr_on && clr_n < PMW) begin pm_we = 3'b111; pm_wa = clr_n[PM_AW-1:0]; pm_wd = 16'h0; end
end

// DM: the read address in D, the write at X's end
always_comb begin
    dm_en = 1'b0; dm_we = 1'b0; dm_a = d_dm_a; dm_wd = XC.acc_wd;
    if (clr_on) begin dm_en = clr_n < DMW; dm_we = 1'b1; dm_a = clr_n[DM_AW-1:0]; dm_wd = 32'h0; end
    else if (d_go && d_dm_rd) begin dm_en = 1'b1; dm_a = d_dm_a; end
    else if (st == ST_X && x_done && XC.acc == A_DM && XC.acc_wr) begin
        dm_en = 1'b1; dm_we = 1'b1; dm_a = XC.acc_addr[DM_AW-1:0];
    end
end

// X's first clock
always_ff @(posedge clk) x_first <= d_go;

// the stacks: one write each at X's end
// written at D's end (R1028): D's reads in that clock are at other words (the one case that was
// not, a DO after a loop-end pop rewriting what the pop read, writes nothing now)
logic stk_we;
assign stk_we = !reset && d_go;
m2b_lutram #(.AW(5), .DW(24), .INIT1(RF_ONES)) u_pcs2 (.clk, .we(stk_we && dx.pcw), .wa(dx.pcw_i), .wd(dx.pcw_d),
    .ra(5'(S.pcstkp - 6'd2)), .rd(pcs_p2));
m2b_lutram #(.AW(5), .DW(24), .INIT1(RF_ONES)) u_pcs3 (.clk, .we(stk_we && dx.pcw), .wa(dx.pcw_i), .wd(dx.pcw_d),
    .ra(5'(S.pcstkp - 6'd3)), .rd(pcs_p3));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lcp2 (.clk, .we(stk_we && dx.lcw), .wa(dx.lcw_i), .wd(dx.lcw_d),
    .ra(S.lstkp - 3'd2), .rd(lcs_p2));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lcp3 (.clk, .we(stk_we && dx.lcw), .wa(dx.lcw_i), .wd(dx.lcw_d),
    .ra(S.lstkp - 3'd3), .rd(lcs_p3));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lcq0 (.clk, .we(stk_we && dx.lcw), .wa(dx.lcw_i), .wd(dx.lcw_d),
    .ra(S.lstkp), .rd(lcs_q0));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lcq1 (.clk, .we(stk_we && dx.lcw), .wa(dx.lcw_i), .wd(dx.lcw_d),
    .ra(S.lstkp + 3'd1), .rd(lcs_q1));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lap2 (.clk, .we(stk_we && dx.law), .wa(dx.law_i), .wd(dx.law_d),
    .ra(S.lstkp - 3'd2), .rd(las_p2));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lap3 (.clk, .we(stk_we && dx.law), .wa(dx.law_i), .wd(dx.law_d),
    .ra(S.lstkp - 3'd3), .rd(las_p3));

// MAME's device_reset clears both blocks (std::fill 0): Dead or Alive reads matrix-stack words
// it has not written and sends them to the i960 (R1027), so the internal RAM is cleared here
// too, one word a clock after reset (2^max(PM_AW, DM_AW) clocks, long before the i960's
// upload starts), the core held in HALT meanwhile. Host writes in those clocks win.
always_ff @(posedge clk) begin
    if (reset) begin clr_n <= '0; clr_on <= CLEAR; end
    else if (clr_on) begin
        clr_n <= clr_n + 1'b1;
        if (clr_n == (CLR_AW + 1)'((1 << CLR_AW) - 1)) clr_on <= 1'b0;
    end
end

// the fetch: the first word from HALT, then each next word in X's first clock (its data is
// pm_q in the following clock, the next D)
always_comb begin
    pm_re = 1'b0;
    pm_ra = PM_AW'(fetch_a - 24'h20000);
    if (st == ST_FETCH) begin pm_re = 1'b1; pm_ra = PM_AW'(S.daddr - 24'h20000); end
    else if (st == ST_X && x_first) pm_re = 1'b1;
end

assign flag_out = {mode2[18] & astat[22], mode2[17] & astat[21]};
assign dbg_st = {st == ST_D && d_wait, st};

// unused
logic unused_ok;
assign unused_ok = ^{d_stx, fa_s[0]};

endmodule
