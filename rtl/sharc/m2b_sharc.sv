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
//      word's fetch address computed (fetch_a). Nothing architectural changes in D.
//   X  the fetch of the next word issued (PM read at fetch_a, ready for the next D); the fixed
//      ALU / shifter result, loads, ureg writes, post-modify, DM / FIFO / IOP / external
//      accesses, the sequencer and stacks: all committed at X's end. FIFO full / empty, an
//      external access, MAME's slow multiply hold X.
//   The float units (Hornet's sharc_fadd / sharc_fmul, and the package's other float functions)
//   take their operands at D's end and register stage 1 at X's end; their results and ASTAT /
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
    parameter bit CLEAR    = 1'b1           // PM and DM cleared after reset, as MAME's device_reset
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

logic [31:0] rf [16];                       // R0-R15
logic [31:0] ir [16];                       // I0-I7 (DAG1), I8-I15 (DAG2)
logic [31:0] mr [16];                       // M0-M15
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

logic [23:0] pcs [32];                      // PC stack (30 used)
logic [31:0] lcs [6];                       // loop counter stack
logic [31:0] las [6];                       // loop address stack (MAME's packed laddr)

// MAME's ASTAT history: ah1 = after the last completed word, ah2, ah3 before it
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
    logic        sh_imm;
    logic [31:0] sh_val;
    logic [3:0]  rn;                        // the fixed / shifter result register
    logic        fl_on;                     // a float compute (lands after X)
    logic        fl_mul, fl_add, fl_sub, fl_misc, fl_absf, fl_comp;
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
    // ureg write with a value known in D
    logic        uw;
    logic [7:0]  uw_reg;
    logic [31:0] uw_val;
    // system register bit operation (X: on the register's value then)
    logic        bitop;
    logic [2:0]  bit_kind;
    logic [3:0]  bit_reg;
    logic [31:0] bit_val;
    // the stacks: one write each
    logic        pcw;
    logic [4:0]  pcw_i;
    logic [23:0] pcw_d;
    logic        lcw, law;
    logic [2:0]  lcw_i, law_i;
    logic [31:0] lcw_d, law_d;
} xc_t;
xc_t XC;
seq_t SN;                                   // the sequencer after this word (committed at X end)
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
    ur_sel = (o[47:45] == 3'b010) ? o[30:23] : (o[47:44] == 4'b0111) ? o[43:36] : o[39:32];
    k = ur_sel[2:0];
    case (ur_sel[7:4])
    4'h0: ur_v = rf[ur_sel[3:0]];
    4'h1: ur_v = ir[{ur_sel[3], k}];
    4'h2: ur_v = ur_sel[3] ? {{8{mr[{1'b1, k}][23]}}, mr[{1'b1, k}][23:0]} : mr[{1'b0, k}];
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
    logic [23:0] pcs_p2, pcs_p3;
    logic        bad;
    logic [31:0] rel6;

    op = pm_q;
    s = S;
    x = '0;
    d_rmask = 16'h0;
    d_need_astat = 1'b0;
    npop = 2'd0;
    nlpop = 1'b0;
    mem_on = 1'b0; mem_a = 32'h0; mem_wr = 1'b0;
    astat_d = astat;
    alusat = mode1[M1_ALUSAT];
    trunc = mode1[M1_TRUNC];
    pcs_p2 = pcs[5'(S.pcstkp - 6'd2)];
    pcs_p3 = pcs[5'(S.pcstkp - 6'd3)];

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
                s.curlcntr = lcs[3'(s.lstkp - 3'd1)];
                w = las[3'(s.lstkp - 3'd1)];
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

    // ---------------------------------------------------------------- the handler
    cond = op[37:33];
    comp = op[22:0];
    ii = op[43:41]; mm = op[40:38];
    jdb = op[26]; ee = op[25]; ci = op[24]; la = op[38];
    rx = comp[7:4]; ry = comp[3:0]; rnn = comp[11:8];
    comp_on = 1'b0;

    // the condition reads ASTAT (or a flag / LCE); conditions 0x09-0x0c / 0x0f / 0x19-0x1c / 0x1e-
    // 0x1f do not, but a flat rule is cheap
    cok = if_cond(astat_d, flg, alusat, lce_ne1, cond);

    casez (op[47:39])
    9'b001??????: begin x.unsup = 1'b1; x.why = U_FORM; end   // type 1: dual moves
    9'b00000001?: begin                                         // compute
        d_need_astat |= cond_astat(cond);
        comp_on = cok;
    end
    9'b0100?????, 9'b0101?????: begin                           // compute, ureg <-> DM|PM, pre / post
        logic g, dd, post;
        logic [7:0] u;
        g = op[32]; dd = op[31]; u = op[30:23]; post = op[44];
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            comp_on = 1'b1;
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                mem_a = ir[{1'b0, ii}] + (post ? 32'h0 : mr[{1'b0, mm}]);
                if (dd) begin
                    x.acc_wd = ((u[7:4] == 4'h6) ? seq_rd(u[3:0], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v);
                    d_rmask |= ureg_rmask(u);
                    if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
                    if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
                end else begin
                    x.ld_u = 1'b1; x.ld_ureg = u;
                    if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
                end
                if (post) begin x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; x.pmod_m = mr[{1'b0, mm}]; end
            end
        end
    end
    9'b0110?????: begin                                         // compute, dreg <-> DM|PM, imm modify
        logic upd, g, dd;
        logic [3:0] dr;
        logic [31:0] mv;
        upd = op[38]; g = op[40]; dd = op[39]; dr = op[26:23];
        mv = sext6(op[32:27]);
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            comp_on = 1'b1;
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                mem_a = ir[{1'b0, ii}] + (upd ? 32'h0 : mv);
                if (dd) begin x.acc_wd = rf[dr]; d_rmask |= 16'h1 << dr; end
                else begin x.ld_r = 1'b1; x.ld_dst = dr; end
                if (upd) begin x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; x.pmod_m = mv; end
            end
        end
    end
    9'b0111?????: begin                                         // compute, ureg <-> ureg
        logic [7:0] us, ud;
        us = op[43:36]; ud = op[30:23];
        d_need_astat |= cond_astat(op[35:31]);
        if (if_cond(astat_d, flg, alusat, lce_ne1, op[35:31])) begin
            comp_on = 1'b1;
            x.uw = 1'b1; x.uw_reg = ud; x.uw_val = ((us[7:4] == 4'h6) ? seq_rd(us[3:0], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v);
            d_rmask |= ureg_rmask(us);
            if (us[7:4] == 4'h7 && (us[3:0] == 4'hc || us[3:0] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(us, 1'b0) || !ureg_ok(ud, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
    end
    9'b1000?????: begin                                         // immediate shift, dreg <-> DM|PM
        logic g, dd;
        logic [3:0] dr;
        g = op[32]; dd = op[31]; dr = op[26:23];
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            x.sh_on = 1'b1; x.sh_op = op[21:16]; x.sh_imm = 1'b1; x.sh_val = {20'h0, op[30:27], op[15:8]};
            x.rn = op[7:4]; rx = op[3:0]; rnn = op[7:4];
            d_rmask |= (16'h1 << op[3:0]) | (16'h1 << op[7:4]);
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
            if (g) begin x.unsup = 1'b1; x.why = U_PM; end
            else begin
                mem_on = 1'b1; mem_wr = dd;
                mem_a = ir[{1'b0, ii}];
                if (dd) begin x.acc_wd = rf[dr]; d_rmask |= 16'h1 << dr; end
                else begin x.ld_r = 1'b1; x.ld_dst = dr; end
                x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; x.pmod_m = mr[{1'b0, mm}];
            end
        end
    end
    9'b00000010?: begin                                         // immediate shift
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            x.sh_on = 1'b1; x.sh_op = op[21:16]; x.sh_imm = 1'b1; x.sh_val = {20'h0, op[30:27], op[15:8]};
            x.rn = op[7:4]; rx = op[3:0]; rnn = op[7:4];
            d_rmask |= (16'h1 << op[3:0]) | (16'h1 << op[7:4]);
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
        end
    end
    9'b00000100?: begin                                         // compute, modify
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            comp_on = 1'b1;
            x.pmod = 1'b1; x.pmod_i = {op[38], op[32:30]}; x.pmod_m = mr[{op[38], op[29:27]}];
        end
    end
    9'b000001100, 9'b000001110: begin                           // direct / relative jump
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            logic [23:0] t;
            t = op[40] ? s.pc + op[23:0] : op[23:0];
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
                    s.curlcntr = lcs[3'(s.lstkp - 3'd1)];
                    w = las[3'(s.lstkp - 3'd1)];
                    s.la_addr = w[23:0]; s.la_code = w[28:24]; s.la_type = w[31:30];
                end else begin
                    s.curlcntr = 32'hFFFF_FFFF;
                    s.la_addr = 24'hFFFFFF; s.la_code = 5'h1f; s.la_type = 2'd3;
                    s.stk = s.stk | LSEM;
                end
            end
            if (jdb) s.nfaddr = t;
            else begin s.pc = t; s.daddr = t; s.faddr = t + 24'd1; s.nfaddr = t + 24'd2; end
        end
    end
    9'b000001101, 9'b000001111: begin                           // direct / relative call
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            logic [23:0] t, ret;
            t = op[40] ? s.pc + op[23:0] : op[23:0];
            ret = op[40] ? (jdb ? s.pc + 24'd3 : s.pc + 24'd1) : (jdb ? s.nfaddr : s.daddr);
            // PUSH_PC
            if (s.pcstkp != 6'd0 && !x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp - 6'd1); x.pcw_d = s.pcstk; end
            s.pcstkp = s.pcstkp + 6'd1;
            s.stk = s.stk & ~PCEM;
            if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
            s.pcstk = ret;
            if (jdb) s.nfaddr = t;
            else begin s.pc = t; s.daddr = t; s.faddr = t + 24'd1; s.nfaddr = t + 24'd2; end
        end
    end
    9'b0000100??: begin                                         // indirect / relative jump or call, compute
        logic [23:0] t;
        logic call, take;
        call = op[39];
        rel6 = sext6(op[32:27]);
        t = op[40] ? s.pc + rel6[23:0] : 24'(ir[{1'b1, op[32:30]}] + mr[{1'b1, op[29:27]}]);
        d_need_astat |= cond_astat(cond);
        if (ci) begin x.unsup = 1'b1; x.why = U_FORM; end
        take = cok;
        if (ee) comp_on = !cok;
        else comp_on = cok;
        if (take) begin
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
            if (jdb) s.nfaddr = t;
            else begin s.pc = t; s.daddr = t; s.faddr = t + 24'd1; s.nfaddr = t + 24'd2; end
        end
    end
    9'b11???????: begin                                         // indirect / relative jump, else compute, dreg <-> DM
        logic [3:0] dr;
        dr = op[26:23];
        d_need_astat |= cond_astat(cond);
        if (cok) begin
            logic [23:0] t;
            rel6 = sext6(op[32:27]);
            t = op[45] ? s.pc + rel6[23:0] : 24'(ir[{1'b1, op[32:30]}] + mr[{1'b1, op[29:27]}]);
            s.pc = t; s.daddr = t; s.faddr = t + 24'd1; s.nfaddr = t + 24'd2;
        end else begin
            comp_on = 1'b1;
            mem_on = 1'b1; mem_wr = op[44];
            mem_a = ir[{1'b0, op[43:41]}];
            if (op[44]) begin x.acc_wd = rf[dr]; d_rmask |= 16'h1 << dr; end
            else begin x.ld_r = 1'b1; x.ld_dst = dr; end
            x.pmod = 1'b1; x.pmod_i = {1'b0, op[43:41]}; x.pmod_m = mr[{1'b0, op[40:38]}];
        end
    end
    9'b00001010?, 9'b00001011?: begin                           // RTS, RTI
        logic take;
        d_need_astat |= cond_astat(cond);
        if (op[40]) begin x.unsup = 1'b1; x.why = U_FORM; end    // RTI
        take = cok;
        if (ee) comp_on = !cok; else comp_on = cok;
        if (take) begin
            logic [23:0] v;
            if (s.pcstkp == 6'd0) begin x.unsup = 1'b1; x.why = U_STK; end
            v = s.pcstk;
            s.pcstkp = s.pcstkp - 6'd1;
            if (s.pcstkp < 6'd30) begin
                if (!x.pcw) begin x.pcw = 1'b1; x.pcw_i = 5'(s.pcstkp); x.pcw_d = s.pcstk; end
                if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;
                else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                s.stk = s.stk & ~PCFL;
            end
            if (jdb) s.nfaddr = v;
            else begin s.pc = v; s.daddr = v; s.faddr = v + 24'd1; s.nfaddr = v + 24'd2; end
        end
    end
    9'b00001100?, 9'b00001101?, 9'b00001110?: begin             // DO UNTIL
        logic [31:0] off;
        logic [23:0] ldist;
        off = sext24(op[23:0]);
        ldist = off[31] ? -off[23:0] : off[23:0];
        if (op[42:40] == 3'b100) s.lcntr = {16'h0, op[39:24]};
        else if (op[42:40] == 3'b101) begin
            s.lcntr = ((op[39:36] == 4'h6) ? seq_rd(op[35:32], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v);
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
            x.lcw = 1'b1; x.lcw_i = s.lstkp - 3'd1; x.lcw_d = s.curlcntr;
            if (!x.law) begin x.law = 1'b1; x.law_i = s.lstkp - 3'd1; x.law_d = la_pack(s.la_type, s.la_code, s.la_addr); end
        end
        s.curlcntr = s.lcntr;
        s.lstkp = s.lstkp + 3'd1;
        if (s.lstkp == 3'd7) begin x.unsup = 1'b1; x.why = U_STK; end    // a seventh level
        s.lcntr = (s.lstkp < 3'd6) ? lcs[s.lstkp] : 32'hFFFF_FFFF;
        s.stk = s.stk & ~LSEM;
        s.pcstk = s.pc + 24'd1;
        s.la_addr = s.pc + off[23:0];
        if (op[42:40] == 3'b110) begin s.la_code = cond; s.la_type = 2'd0; end
        else begin
            s.la_code = 5'h0f;
            s.la_type = (ldist == 24'd1) ? 2'd1 : (ldist == 24'd2) ? 2'd2 : 2'd3;
        end
    end
    9'b00001111?: begin                                         // immediate -> ureg
        x.uw = 1'b1; x.uw_reg = op[39:32]; x.uw_val = op[31:0];
        if (!ureg_ok(op[39:32], 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
    end
    9'b000100???: begin                                         // ureg <-> DM|PM, direct
        logic [7:0] u;
        u = op[39:32];
        if (op[41]) begin x.unsup = 1'b1; x.why = U_PM; end
        else begin
            mem_on = 1'b1; mem_wr = op[40]; mem_a = op[31:0];
            if (op[40]) begin
                x.acc_wd = ((u[7:4] == 4'h6) ? seq_rd(u[3:0], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v); d_rmask |= ureg_rmask(u);
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
            mem_on = 1'b1; mem_wr = op[40]; mem_a = ir[{1'b0, ii}] + op[31:0];
            if (op[40]) begin
                x.acc_wd = ((u[7:4] == 4'h6) ? seq_rd(u[3:0], s.pcstk, s.pcstkp, s.curlcntr, s.lcntr) : ur_v); d_rmask |= ureg_rmask(u);
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
            mem_on = 1'b1; mem_wr = 1'b1; mem_a = ir[{1'b0, ii}]; x.acc_wd = op[31:0];
            x.pmod = 1'b1; x.pmod_i = {1'b0, ii}; x.pmod_m = mr[{1'b0, mm}];
        end
    end
    9'b00010100?: begin                                         // system register bit operation
        x.bitop = 1'b1; x.bit_kind = op[39:37]; x.bit_reg = op[35:32]; x.bit_val = op[31:0];
        if (!ureg_ok({4'h7, op[35:32]}, 1'b1) || op[39:37] == 3'd3 || op[39:37] > 3'd5) begin x.unsup = 1'b1; x.why = U_UREG; end
    end
    9'b000101100: begin                                         // modify I by an immediate
        x.pmod = 1'b1; x.pmod_i = {op[38], op[34:32]}; x.pmod_m = op[31:0];
    end
    9'b00010111?: begin                                         // push / pop the stacks
        x.unsup = 1'b1; x.why = U_STK;
    end
    9'b000000000: ;                                             // NOP
    default: begin x.unsup = 1'b1; x.why = U_FORM; end          // IDLE, bit-reverse, the rest
    endcase

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
                3'd4: begin x.fl_misc = 1'b1; x.misc_op = 5'd2;  end   // FAVG
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
                    8'h89: begin x.fl_misc = 1'b1; x.misc_op = 5'd2; end
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
    d_opx = rf[rx]; d_opy = rf[ry]; d_opn = rf[rnn];
    // the multifunction's four operands: R0-3, R4-7, R8-11, R12-15
    if (comp[22]) begin
        d_fmx = rf[{2'b00, comp[7:6]}]; d_fmy = rf[{2'b01, comp[5:4]}];
        d_fax = rf[{2'b10, comp[3:2]}]; d_fay = rf[{2'b11, comp[1:0]}];
    end else begin
        d_fmx = rf[rx]; d_fmy = rf[ry]; d_fax = rf[rx]; d_fay = rf[ry];
    end
    d_stx = x.acc_wd;
    d_dm_a = mem_a[DM_AW-1:0];
    d_dm_rd = mem_on && x.acc == A_DM && !mem_wr && !x.unsup;
end

// the scoreboard: a register or ASTAT being landed this clock
always_comb begin
    logic [15:0] lm;
    lm = 16'h0;
    if (ld_on && ld_mwe) lm |= 16'h1 << ld_rm;
    if (ld_on && ld_awe) lm |= 16'h1 << ld_ra;
    d_wait = (d_rmask & lm) != 0 || (ld_on && d_need_astat);
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

always_comb begin
    x_fix = alu_fixed(XC.fix_op, op_x, op_y, astat, mode1[M1_ALUSAT]);
    x_sh = shifter(XC.sh_op, op_x, op_n, XC.sh_imm ? XC.sh_val : op_y, XC.sh_imm, astat);
end

// the misc float functions: computed in X from the operand registers, landed after
always_comb begin
    fres_t o;
    o = '0;
    if (MAME_RND)
        case (XC.misc_op)
        5'd2:  o = f_avg(fa_x, fa_y, XC.trunc);
        5'd4:  o = f_abs(fa_x);
        5'd5:  o = f_minmax(fa_x, fa_y, 1'b0);
        5'd6:  o = f_minmax(fa_x, fa_y, 1'b1);
        5'd7:  o = f_neg(fa_x);
        5'd8:  o = f_pass(fa_x);
        5'd9:  o = f_comp(fa_x, fa_y, astat & ~ALU_GRP);
        5'd10: o = f_scalb(fa_x, fa_y);
        5'd11: o = f_logb(fa_x);
        5'd12: o = f_fix(fa_x, 1'b0, 32'h0, XC.trunc, 1'b0);
        5'd13: o = f_fix(fa_x, 1'b1, fa_y, XC.trunc, 1'b0);
        5'd14: o = f_fix(fa_x, 1'b1, fa_y, XC.trunc, 1'b1);
        5'd15: o = f_float(fa_x, 1'b0, 32'h0, 1'b0);
        5'd16: o = f_float(fa_x, 1'b1, fa_y, 1'b0);
        5'd17: o = f_float(fa_x, 1'b1, fa_y, 1'b1);
        5'd18: o = f_recips(fa_x);
        5'd19: o = f_rsqrts(fa_x);
        5'd20: o = f_copysign(fa_x, fa_y);
        5'd21: o = f_clip(fa_x, fa_y);
        default: o = '0;
        endcase
    else
        case (XC.misc_op)
        5'd2:  o = man_avg(fa_x, fa_y, XC.trunc);
        5'd4:  o = f_abs(fa_x);
        5'd5:  o = man_minmax(fa_x, fa_y, 1'b0);
        5'd6:  o = man_minmax(fa_x, fa_y, 1'b1);
        5'd7:  o = f_neg(fa_x);
        5'd8:  o = f_pass(fa_x);
        5'd9:  o = man_comp(fa_x, fa_y, astat & ~ALU_GRP);
        5'd10: o = man_scalb(fa_x, fa_y);
        5'd11: o = man_logb(fa_x);
        5'd12: o = man_fix(fa_x, 1'b0, 32'h0, XC.trunc);
        5'd13: o = man_fix(fa_x, 1'b1, fa_y, XC.trunc);
        5'd14: o = man_fix(fa_x, 1'b1, fa_y, XC.trunc);
        5'd15: o = man_float(fa_x, 1'b0, 32'h0, 1'b0, XC.trunc);
        5'd16: o = man_float(fa_x, 1'b1, fa_y, 1'b0, XC.trunc);
        5'd17: o = man_float(fa_x, 1'b1, fa_y, 1'b1, XC.trunc);
        5'd18: o = man_recips(fa_x);
        5'd19: o = man_rsqrts(fa_x);
        5'd20: o = f_copysign(fa_x, fa_y);
        5'd21: o = f_clip(fa_x, fa_y);
        default: o = '0;
        endcase
    misc_d_r = o.r; misc_d_a = o.astat; misc_d_s = o.stky;
end

// the float units: operands from D, stage 1 at X's end, results in the landing clock
logic fl_en, fm_restart;
assign fl_en = st == ST_X && x_done;
sharc_fadd #(.MAME_RND(MAME_RND)) u_fadd (
    .clk, .en(fl_en), .x(fa_x), .y(fa_y), .sub(XC.fl_sub), .trunc(XC.trunc),
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
        dbg_ret <= 1'b0;
        fm_restart <= 1'b0;

        // ---------------------------------------------------------------- the landing
        if (ld_on) begin
            logic [31:0] a, k, ra_v, ra_a, ra_s;
            a = astat; k = stky;
            ra_v = ld_misc ? misc_r : fa_r;
            ra_a = ld_misc ? misc_a : fa_a;
            ra_s = ld_misc ? misc_s : fa_s;
            if (ld_absf) begin
                if ((ra_a & AI) == 0) ra_v = ra_v & ~SIGN;
                ra_a = ra_a & ~AN;
            end
            if (ld_mul) begin a = (a & ~MUL_GRP) | fm_a; k = k | fm_s; end
            if (ld_alu) begin
                a = (a & ~ALU_GRP) | ra_a; k = k | ra_s;
                if (ld_comp) a = (a & 32'h00FF_FFFF) | (misc_r & 32'hFF00_0000);
            end
            if (ld_mwe) rf[ld_rm] <= fm_r;
            if (ld_awe) rf[ld_ra] <= ra_v;
            // a ureg write to ASTAT / STKY in the same word comes after the compute (MAME's order)
            if (ld_ua) a = ld_uv;
            if (ld_us) k = (k & STK_BITS) | (ld_uv & ~STK_BITS);
            astat <= a; stky <= k;
            ah1 <= a; ah2 <= ah1; ah3 <= ah2;
            ld_on <= 1'b0;
            dbg_ret <= 1'b1;
        end

        case (st)
        ST_HALT: if (run && !clr_on) st <= ST_FETCH;
        ST_FETCH: st <= ST_D;
        ST_D: if (d_go) begin
            XC <= dx;
            SN <= dsn;
            x_op <= pm_q;
            x_pc <= S.daddr;
            op_x <= d_opx; op_y <= d_opy; op_n <= d_opn;
            fa_x <= d_fax; fa_y <= d_fay; fm_x <= d_fmx; fm_y <= d_fmy;
            fetch_a <= dsn.daddr;
            fm_restart <= 1'b1;
            x_ext_on <= 1'b1;
            st <= ST_X;
            if (dx.unsup && !unsup) begin
                unsup <= 1'b1; unsup_pc <= S.daddr; unsup_op <= pm_q; unsup_why <= dx.why;
            end
        end
        ST_X: begin
            if (x_ext_on && ext_ack && XC.acc == A_EXT) x_ext_on <= 1'b0;
            if (x_done) begin
                logic [31:0] a, k, uv, base;
                logic        uw;
                logic [7:0]  ur;
                seq_t sq;
                a = astat; k = stky;
                sq = SN;
                // the fixed / shifter result
                if (XC.fix_on) begin
                    a = x_fix.astat; k = k | x_fix.stky;
                    if (x_fix.we) rf[XC.rn] <= x_fix.r;
                end
                if (XC.sh_on) begin
                    a = x_sh.astat;
                    if (x_sh.we) rf[XC.rn] <= x_sh.r;
                end
                // loads and ureg moves
                uw = 1'b0; ur = 8'h0; uv = 32'h0;
                if (XC.ld_r && x_ldv) rf[XC.ld_dst] <= x_ld;
                if (XC.ld_u && x_ldv) begin uw = 1'b1; ur = XC.ld_ureg; uv = x_ld; end
                if (XC.uw) begin uw = 1'b1; ur = XC.uw_reg; uv = XC.uw_val; end
                // the system-register bit operation, on the register's value now
                if (XC.bitop) begin
                    logic [31:0] src, d;
                    src = sys_rd(XC.bit_reg, a, mode1, mode2, stky, irptl, imask, ustat1, ustat2, flg);
                    d = XC.bit_val;
                    case (XC.bit_kind)
                    3'd0: src = src | d;
                    3'd1: src = src & ~d;
                    3'd2: src = src ^ d;
                    3'd4: if ((src & d) == d) a = a | BTF; else a = a & ~BTF;
                    3'd5: if (src == d) a = a | BTF; else a = a & ~BTF;
                    default: ;
                    endcase
                    uw = 1'b1; ur = {4'h7, XC.bit_reg}; uv = src;
                end
                // post-modify: after the load (a load to the same I is modified)
                base = ir[XC.pmod_i];
                if (uw && (ur[7:4] == 4'h1 || ur[7:4] == 4'h4) && {ur[3], ur[2:0]} == XC.pmod_i) base = uv;
                ld_ua <= 1'b0; ld_us <= 1'b0; ld_uv <= uv;
                if (uw) begin
                    logic [2:0] kk;
                    kk = ur[2:0];
                    case (ur[7:4])
                    4'h0: rf[ur[3:0]] <= uv;
                    4'h1: ir[{ur[3], kk}] <= uv;
                    4'h2: mr[{ur[3], kk}] <= uv;
                    4'h3: lnz[{ur[3], kk}] <= uv != 32'h0;
                    4'h4: ir[{ur[3], kk}] <= uv;           // B: I = B (B itself is not kept)
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
                              if (((uv ^ mode1) & M1_SWAPS) != 0 && !unsup) begin
                                  unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op; unsup_why <= U_MODE;
                              end
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
                if (XC.pmod) ir[XC.pmod_i] <= base + XC.pmod_m;
                // the accesses' writes
                if (XC.acc == A_IOP && XC.acc_wr) begin
                    case (XC.acc_addr[7:0])
                    8'h00: syscon <= XC.acc_wd;
                    8'h02, 8'h08, 8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f, 8'h14, 8'h17, 8'h20: ;
                    8'h40: ii6 <= XC.acc_wd;
                    8'h41: im6 <= XC.acc_wd;
                    8'h1c: begin
                        dmac6 <= XC.acc_wd;
                        if (XC.acc_wd[0] && !unsup) begin unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op; unsup_why <= U_IOP; end
                    end
                    default: if ((XC.acc_addr[7:0] < 8'h42 || XC.acc_addr[7:0] > 8'h4f) && !unsup) begin
                        unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op; unsup_why <= U_IOP;
                    end
                    endcase
                end
                if (XC.acc == A_IOP && !XC.acc_wr && XC.acc_addr[7:0] != 8'h00 && XC.acc_addr[7:0] != 8'h37 && !unsup) begin
                    unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op; unsup_why <= U_IOP;
                end
                // the sequencer and STKY's stack bits
                S <= sq;
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
                dbg_pc <= x_pc; dbg_op <= x_op;
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

// the stacks: one write each at X's end (no reset: the PC stack can be MLAB)
always_ff @(posedge clk) if (!reset && st == ST_X && x_done) begin
    if (XC.pcw) pcs[XC.pcw_i] <= XC.pcw_d;
    if (XC.lcw) lcs[XC.lcw_i] <= XC.lcw_d;
    if (XC.law) las[XC.law_i] <= XC.law_d;
end

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
