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
// TIMING (R1029: 80 MHz). Each word is D then X, X one to three clocks:
//   D  the opcode (PM's registered output); the loop end's and the condition's decisions;
//      decode; operands read (R, I, M, the ureg source); the DM read address presented. The
//      registers D loads (XC, the operands, x_op) load in every D clock; the last, d_go's, stays.
//   X  its first clock makes the sequencer's next state (S) and the stacks' one write each from
//      S, the word and D's decisions (XC.le / done / cok), and issues the next word's fetch from
//      it; the fixed ALU / shifter / misc float result (m2b_sharc_xu, one shared unit), loads,
//      ureg writes, post-modify, DM / FIFO / IOP / external accesses are committed at X's end. X
//      is two clocks for a float add and a shift, three for FIX / FLOAT (x_need). FIFO full /
//      empty, an external access, MAME's slow multiply hold it. A ureg write to PCSTK / CURLCNTR /
//      LCNTR modifies S in the clock after X, D waiting for it.
//   The register files are MLAB (R1028): R0-R15 five read copies of one write port (a word
//   writing two R registers writes the second a clock later), I and M three each, the PC stack
//   two and the loop stacks six (m2b_lutram).
//   The float units (Hornet's sharc_fadd / sharc_fmul, FAVG on the adder; the misc functions
//   in X) take their operands at D's end; their results and ASTAT / STKY bits are written in the
//   clock after X (the "landing", which is the next word's first D clock), and (R1029) so are the
//   fixed ALU's and the shifter's, through misc_r / misc_a / misc_s. The next word waits in D one clock if it reads a register or ASTAT being landed
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
// runs as a NOP: short words, block-0 data over the DM bus, the fixed multiplier and MR, dual
// add / subtract, alternate register files (a MODE1 swap bit), circular buffers (L != 0 on a
// post-modify), interrupts and IDLE, RTI, the status stack, SHARC-side DMA, RND32 = 0 on a float
// op, PCSTKP written, unknown compute / IOP registers; PX over the PM bus and a PM-bus address
// outside the on-chip PM and block 1.
//
// R1042: PM-BUS DATA AND TYPE-1 DUAL MOVES (Fighting Vipers, Sonic Championship / the Fighters).
// A PM-bus access uses DAG2 (I8-15 / M8-15, read on DAG1's copies with the g bit as the address's
// bit 3), a 24-bit address: block 0's words are bits 47:16 of the 48-bit word there, on the PM
// RAM's port B (lane 0 kept on a store: MAME's pm_write32); block 1's go to the DM RAM / page as
// the DM-bus access to the same address would (the manual's normal-word addressing, SYSCON IMDW1
// = 0; PMB1_MAME = 1 gives MAME's pm_r<1> word instead, for the benches). A type-1 word's compute
// always runs; its DM move is X's first pass (the access fields as any DM access), its PM move a
// second pass on the same machinery (XC.acc2: the kind, address, load register; the store's
// register read on port E during the first pass, before any of the word's writes; the post-modify
// I + M from D's DAG2 copies). DM first: the manual's order (p. 5-8, the DM access completes first
// when both are in one block) -- MAME's is PM first. Loads over compute results, and the DM load
// over the PM load to one register (p. 11-42's precedence: DM, PM, ALU, multiplier, shifter).
// The second pass waits one clock before a DM-RAM read or an external request; nothing else
// changes for the other forms.
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
    parameter bit RF_ONES  = 1'b0,          // benches: the register and stack arrays start all ones
    // R1038: PX and IMASK. 1 = as MAME has them (the benches' default); 0 = neither register is
    // built and a ureg move or bit operation naming one is an unsupported word -- no Model 2B
    // program names either (every set's uploaded program, read whole: the study's R1038)
    parameter bit PXIM     = 1'b1,
    // R1039: reads of STKY, CURLCNTR and LCNTR. 1 = as MAME (the benches' default); 0 = a ureg
    // move or bit operation that READS one is an unsupported word, so STKY (written, never read)
    // is not built and the two counters leave the ureg read port -- no Model 2B program reads
    // any of the three (every set's uploaded program, read whole: the study's R1039). Writes are
    // done as before; the counters still run the loops.
    parameter bit SKLR     = 1'b1,
    // R1042: which block-1 word a 32-bit PM-bus access names. 0 = the manual's (and Hornet's v1):
    // the 32-bit word at that address, the word a DM-bus access to it names (SYSCON IMDW1 = 0,
    // its reset value); 1 = MAME's pm_r<1>, the upper 32 bits of the 48-bit word there in its
    // column layout (benches comparing with a MAME capture)
    parameter bit PMB1_MAME = 1'b0
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
    output logic [2:0]  dbg_st,             // 0 halt, 1 fetch, 2 D, 3 X; bit 2: D waiting
    output logic [23:0] obs_pc              // R1031: the pc of the word in X (the probe's 'C' record)
);

import sharc_fp_pkg::*;
import m2b_sharc_pkg::*;

localparam int PMW = 1 << PM_AW;
localparam int DMW = 1 << DM_AW;

// unsupported reasons
localparam logic [3:0] U_FORM = 4'd1, U_COMP = 4'd2, U_MEM = 4'd3, U_DAG = 4'd4, U_MODE = 4'd5,
                       U_STK = 4'd6, U_IOP = 4'd7, U_UREG = 4'd8, U_PM = 4'd9, U_RND = 4'd10;

// ================================================================== memories

// PM: three 16-bit lanes; port A = the fetch; port B = the host's upload, the clear and (R1042)
// PM-bus data: a 32-bit word is bits 47:16 of the 48-bit word at its address (MAME's
// pm_read32 / pm_write32; bits 15:0 kept on a write), so lanes 1 and 2 read and write on port B
// and lane 0 only takes the upload -- the same M10K count (TDP at 8 K x 1 is what SDP is)
(* ramstyle = "M10K" *) logic [15:0] pm0 [PMW];
(* ramstyle = "M10K" *) logic [15:0] pm1 [PMW];
(* ramstyle = "M10K" *) logic [15:0] pm2 [PMW];
logic [PM_AW-1:0] pm_ra, pm_wa;
logic [PM_AW-1:0] pm_wb [3];                // R1048: port B's address per lane (pm_wa: the benches' reference)
logic [PM_AW-1:0] pm_ha, pm_hidx;           // ... the host's / the clear's, and the host's window index
logic             pm_re;
logic [2:0]       pm_we;
logic [15:0]      pm_wd;                    // the host's / the clear's 16 bits (lane 0, and 1 / 2)
logic [31:0]      pm_wd2;                   // lanes 2:1's data (a PM-bus store's word, or {pm_wd, pm_wd})
logic [47:0]      pm_q;
logic [31:0]      pmb_q;                    // port B's read: bits 47:16 of the word at pm_wa last clock
always_ff @(posedge clk) if (pm_re) begin
    pm_q[15:0] <= pm0[pm_ra]; pm_q[31:16] <= pm1[pm_ra]; pm_q[47:32] <= pm2[pm_ra];
end
// (port B as Quartus 17's true-dual-port template: a read in every clock it does not write, the
// written data on a write, no enable -- with a read enable Quartus 17.0 makes a second copy of the
// lane instead, +32 M10K, measured R1042)
always_ff @(posedge clk) if (pm_we[0]) pm0[pm_wb[0]] <= pm_wd;
always_ff @(posedge clk) begin
    if (pm_we[1]) begin pm1[pm_wb[1]] <= pm_wd2[15:0]; pmb_q[15:0] <= pm_wd2[15:0]; end
    else pmb_q[15:0] <= pm1[pm_wb[1]];
end
always_ff @(posedge clk) begin
    if (pm_we[2]) begin pm2[pm_wb[2]] <= pm_wd2[31:16]; pmb_q[31:16] <= pm_wd2[31:16]; end
    else pmb_q[31:16] <= pm2[pm_wb[2]];
end

// DM block 1: two 16-bit lanes, one port
(* ramstyle = "M10K" *) logic [15:0] dm0 [DMW];
(* ramstyle = "M10K" *) logic [15:0] dm1 [DMW];
logic [DM_AW-1:0] dm_a;
logic             dm_en, dm_we;
logic [31:0]      dm_wd, dm_q;
// R1048: each lane's address its own (dm_as below, one adder per lane), so the last stage drives
// 16 blocks, not 32 (s4901: the select -> 32 M10K, 3.594 ns of route); dm_a is the benches'
logic [DM_AW-1:0] dm_a0, dm_a1;
always_ff @(posedge clk) if (dm_en) begin
    if (dm_we) begin dm0[dm_a0] <= dm_wd[15:0]; dm1[dm_a1] <= dm_wd[31:16]; end
    else begin dm_q[15:0] <= dm0[dm_a0]; dm_q[31:16] <= dm1[dm_a1]; end
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
// One write a clock: at X's end a load / ureg move's (R1029: every compute result lands, the
// fixed and shifter ones too); at the landing the result's, a multifunction's Ra a clock after
// its Rm (rf_pw), D not finishing in the landing clock. D reads in its clocks; a word read in a
// clock that writes it is the scoreboard's (D waits and reads again: its registers load again),
// so no_rw_check's undefined read is never kept.
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
logic [3:0]  i1_ra, m1_ra;                 // (R1042: bit 3 the PM bus's, DAG2's I8-15 / M8-15)
logic [3:0]  i2_ra, m2_ra;
logic [3:0]  i4_ra, m4_ra;                 // R1048: type 1's DAG2 I / M, on copies read at the opcode's fields
logic [31:0] i4_rd, m4_rd;
logic [31:0] i1_rd, i2_rd, iu_rd, m1_rd, m2_rd, mu_rd;
// R1044: DAG1's copies read I0-7 / M0-7 at the opcode's field with no select; I8-15 / M8-15 (a
// PM-bus access's DAG2 registers, the g bit) on copies of their own (u_i3 / u_m3), the g bit
// choosing after the read (i1x_rd / m1x_rd) -- off the path from the opcode into the MLAB
logic [3:0]  i3_ra, m3_ra;
logic [31:0] i3_rd, m3_rd, i1x_rd, m1x_rd;
logic        d_pg;                          // the g bit: the word's one access is DAG2's
logic        ir_we, mr_we;
logic [3:0]  ir_wa, mr_wa;
logic [31:0] ir_wd, mr_wd;
logic        ir_pw;                         // the deferred I write (this clock)
logic [3:0]  ir_pa;
logic [31:0] ir_pd;
logic [15:0] lnz;                           // L != 0
logic [31:0] astat, stky, mode1, mode2, irptl, imask, ustat1, ustat2, syscon;
wire  [31:0] stky_rd = SKLR ? stky : 32'h0;   // R1039: STKY as the ureg port reads it
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
// R1044: the loop end's compares on S, D's own. Registered where S is written (from s_x1) they
// were the slower paths: s3431's first fit x_op -> sf_c2 -1.425 ns, s3435's fifth S.pcstkp ->
// sf_le / sf_long -1.994 -- the whole sequencer in front of a 24- / 32-bit compare
wire  sf_le = S.daddr == S.la_addr, sf_long = S.daddr - S.pcstk > 24'd2;
wire  sf_c1 = S.curlcntr == 32'd1, sf_c2 = S.curlcntr == 32'd2;

// the PC stack (30 used of 32) and the loop stacks (6 of 8): MLAB (m2b_lutram, R1028), the top
// of each in S. One write each at X's end; the reads are D's, at addresses from S (the stack
// pointers before the word): PCSTKP - 2 / - 3 (a pop, a second pop in the same word); LSTKP - 2 /
// - 3 (the same), LSTKP + 1 / LSTKP (a DO's new LCNTR, after no pop / a pop). D reads after the
// X that wrote, never in its clock.
logic [23:0] pcs_p2, pcs_p3;
logic [31:0] lcs_p2, lcs_p3, lcs_q0, lcs_q1, las_p2, las_p3;
logic        lcs_p2ne1;                     // lcs_p2 != 1 (the stack's 33rd bit, below)

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
logic        ld_misc;                       // Ra from misc_r (the misc float result, or the fixed / shifter's)
logic        ld_fix;                        // a fixed / shifter result: ASTAT is misc_a, STKY ORs misc_s (R1029)
logic        ld_fz;                         // ... a fixed ALU result: AN / AZ from misc_r
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
localparam logic [2:0] A_NONE = 3'd0, A_DM = 3'd1, A_FIN = 3'd2, A_FOUT = 3'd3, A_IOP = 3'd4, A_EXT = 3'd5,
                       A_PM = 3'd6;         // R1042: block 0, the PM RAM's port B (PM-bus data)
typedef struct packed {
    logic        unsup;
    logic [3:0]  why;                       // the opcode's reason (a DAG's / a data address's below)
    logic        dag, mbad;
    // compute
    logic        fix_on;                    // fixed ALU
    logic [7:0]  fix_op;
    logic        fix_wr;                    // R1048: the fixed op writes Rn (m2b_sharc_xu's fix_we), from D
    logic [10:0] fix_k;                     // the adder's operands, one-hot (m2b_sharc_pkg::fix_k_of, R1029)
    logic        sh_on;                     // shifter
    logic [5:0]  sh_op;
    logic        sh_imm;                    // (the immediate is x_op's: {op[30:27], op[15:8]})
    logic [3:0]  rn;                        // the fixed / shifter result register
    logic        rn_we;                     // ... written (a load / ureg move to it in the word wins)
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
    logic        ld_ast, uw_ast;            // R1048: ld_ureg / uw_reg is ASTAT (0x7c), from D
    // system register bit operation (X: on the register's value then)
    logic        bitop;
    logic [2:0]  bit_kind;
    logic [3:0]  bit_reg;                   // (the mask is x_op[31:0])
    // the sequencer's decisions, made in D, taken by X's first clock (R1029)
    logic        le, done;                  // a loop end; it pops
    logic        cok;                       // the word's condition
    logic [31:0] ind_t;                     // I + M of DAG2 (an indirect branch's target; R1042: a
                                            // type-1 word's PM post-modify, all 32 bits)
    // R1042: a type-1 word's second access, its PM-bus one (X's second pass; the first is its DM
    // access, in the fields above -- the manual's order, the DM bus first)
    logic        dual;
    logic [2:0]  acc2;
    logic        acc2_wr;
    logic [23:0] acc2_a;
    logic        ld2_r;                     // a load to R[ld2_dst] (not where the DM load is: DM wins)
    logic [3:0]  ld2_dst;
    logic        b6;                        // the PC-relative offset is the 6-bit one (op[32:27])
    logic [5:0]  sqc;                       // the sequencing form, one-hot: jump, call, indirect /
                                            // relative jump-call, IF-JUMP-ELSE, RTS, DO (R1029)
    // R1044: the next fetch's address, its candidates made in D (S and the opcode are D's) so
    // that X's first clock only selects (pm_ra): PC + offset from S.daddr and from S.pcstk (a
    // loop end's CHANGE_PC), the top after a loop end's pop (an RTS's target then), the target's
    // select one-hot, whether the form branches and whether its branch is delayed
    logic [PM_AW-1:0] f_reld, f_relp, f_rts;
    logic [3:0]  f_ts;
    logic        f_br, f_db;
    // R1044: X's length if the word's float compute runs (the misc functions' from their op)
    logic [1:0]  need_fl;
} xc_t;
xc_t XC;
logic [31:0] op_x, op_y, op_n;              // fixed / shifter operands: R[rx], R[ry], R[rn]
logic [31:0] fa_x, fa_y, fm_x, fm_y;        // float operands
logic        fa_xz, fa_yz;                  // R1048: fa_x / fa_y [30:23] == 0, loaded with them (sharc_fadd PRE)
logic        fa_xn, fa_yn;                  // R1052 (as b9857549): is_nan(fa_x) / is_nan(fa_y), loaded with them (m2b_sharc_xu PRE)
logic        d_faxn, d_fayn;
logic [5:0]  sh_pl;                         // R1048: the shifter's field length and decoder bit, from D's
logic [4:0]  sh_pdj;                        // sh_val (m2b_sharc_xu PRE)
logic [5:0]  d_shpl;
logic [4:0]  d_shpdj;
logic        d_faxz, d_fayz;
logic [31:0] st_x;                          // store data / ureg source value
logic [47:0] x_op;
logic [23:0] x_pc;
logic        x_first;                       // X's first clock (the fetch is issued)
logic        x_pmbad;                       // X's first clock found the next fetch outside the PM
logic        us_pw;                         // a ureg write to PCSTK / CURLCNTR / LCNTR this clock (R1029)
logic [3:0]  us_pr;
logic [31:0] us_pv;

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
    4'h7: return SKLR ? curlcntr : 32'h0;   // R1039
    4'h8: return SKLR ? lcntr : 32'h0;
    default: return 32'h0;
    endcase
endfunction

// D's one ureg read port: the field each form names (only one per word)
logic [7:0]  ur_sel;
logic [31:0] ur_v;
logic        d_urim;                        // the word reads I or M through it (R1029)
always_comb begin
    logic [47:0] o;
    logic [2:0]  k;
    o = pm_q;
    ur_sel = (o[47:45] == 3'b010) ? o[30:23] : (o[47:44] == 4'b0111) ? o[43:36] :
             (o[47:40] == 8'b00010100) ? {4'h7, o[35:32]} : o[39:32];     // the bit operation's register
    k = ur_sel[2:0];
    d_urim = ((o[47:45] == 3'b010 && o[31]) || o[47:44] == 4'b0111 || (o[47:42] == 6'b000100 && o[40]) ||
              (o[47:45] == 3'b101 && o[40]) || o[47:40] == 8'h0d) && (ur_sel[7:4] == 4'h1 || ur_sel[7:4] == 4'h2);
    case (ur_sel[7:4])
    4'h0: ur_v = rf_rd[4];
    4'h1: ur_v = iu_rd;
    4'h2: ur_v = ur_sel[3] ? {{8{mu_rd[23]}}, mu_rd[23:0]} : mu_rd;
    4'h7: ur_v = sys_rd(ur_sel[3:0], astat, mode1, mode2, stky_rd, irptl, imask, ustat1, ustat2, flg);
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
    4'h6: return u[3:0] == 4'h4 || ((SKLR || wr) && (u[3:0] == 4'h7 || u[3:0] == 4'h8)) || (!wr && u[3:0] == 4'h5);
    4'h7: return u[3:0] == 4'h0 || u[3:0] == 4'h1 || u[3:0] == 4'h9 || u[3:0] == 4'ha ||
                 u[3:0] == 4'hb || u[3:0] == 4'hc || (PXIM && u[3:0] == 4'hd) || ((SKLR || wr) && u[3:0] == 4'he);
    4'hd: return PXIM && (u[3:0] == 4'hb || u[3:0] == 4'hc || u[3:0] == 4'hd);
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
logic [31:0] d_opx, d_opy, d_opn, d_fax, d_fay, d_fmx, d_fmy, d_stx;
logic [4:0]  d_ru;                          // the R file's read ports (rf_ra) this word may use (R1028),
                                            // from the opcode alone (R1029: not its condition)
logic        d_need_astat;                  // D reads ASTAT / STKY (from the opcode and S alone)
logic [DM_AW-1:0] d_dm_a;
logic        d_dm_rd;
logic        d_pmb;                         // R1042: the word may read the PM RAM's port B
logic [PM_AW-1:0] d_pb_a;                  // ... at this word
logic        pm_host;                       // the host writes PM this clock
logic [2:0]  d_acc_ref;                     // benches: the access kind as R1028 cleared it
logic        d_dag_ref, d_mbad_ref;         // ... and its DAG and address-map tests
logic [31:0] d_urall_ref;                   // benches: the ureg source as R1028 read it
logic [31:0] dx_urall;
logic [31:0] d_accwd_ref;
(* keep *) logic [31:0] d_accwd_b;          // R1044: the store / ureg data but the sequencer's source
logic [31:0] d_ursq1, d_ursq0, d_accwd_chk;
logic        d_cok_ref;                     // benches: the condition as R1029 evaluated it
logic        d_cok1, d_cok0;                // R1048: cok if the loop end pops / if it does not
logic [2:0] d_acc_nc;                        // R1044: D's access kind before its condition (now the bench's)
logic [2:0]  d_acc_hit;                     // R1048: ... before any gate
logic [31:0] d_sum_i, d_sum_o;              // R1048: the 32-bit offset's sum and the others'
logic        d_s3;
logic        d_bad_x;                       // (the benches': D's bad)
logic        d_rmwe_ref;                    // (the benches': R1042's rm_we)
logic        d_rnwe_ref;                    // (the benches': rn_we as it was before R1057)
logic        d_rawe_ref;                    // (the benches': ra_we as it was before R1057)
logic        d_wrf, d_wrf_ref, d_memf_x;    // R1048: the access's direction from the opcode; the benches' mem_wr / mem_f
logic        d_memf;                        // R1048: mem_f from op[47:42]
logic        d_lnzp, d_lnzp_ref;            // R1048: lnz[pmi] by its three indexes; the benches' lnz[pmi]
logic        d_l1, d_cok1t, d_cok1f;        // R1048: l1 (the popped LCE), cok after the pop at l1 = 1 / 0
// R1048: the access kind's and the map test's gate with the loop end's pop chosen in it (done,
// l1: early beside the sums), so the sums' bits pass one gate after acc_bits, not two
(* keep *) logic       d_ag1, d_ag0, d_mbg;   // R1050: the kind's gate for each outcome of the pop, bad2 in it
logic        d_compf, d_compf_x;            // R1048: comp_f from the opcode's bits; the benches' comp_f
logic [12:0] d_fix_ref;                     // (the benches': the handler's fix_on / fix_wr / fix_k)
logic [7:0]  d_fixop_h;                     // (the benches': the handler's fix_op)
logic        d_cbad_ref, d_cbad_x;          // (the benches': cbad with its old guard, and without)
(* keep *) logic [3:0] d_kb_i, d_kb_o;       // R1048: acc_bits of each sum
logic        d_rzb;
logic [2:0]  d_acc_chk;
logic        d_mbad_nc;                     // ... and the address map's test
logic        d_unsup_x;                     // D's flag and reason, the condition last (R1029)
logic [3:0]  d_why_x;
logic        d_unsup_ref;                   // benches: R1028's form of them
logic [3:0]  d_why_ref;

// address decode of a data access (DM bus)
// {unsupported, kind}
function automatic logic [3:0] dm_kind(input logic [31:0] a, input logic wr);
    // the ranges as bit tests (R1029: Aggressive Area builds the compares as chains)
    logic z24, z18;
    z24 = a[31:25] == 7'h0;
    z18 = z24 && a[24:18] == 7'h0;
    if (z18 && a[17:8] == 10'h0) return {1'b0, A_IOP};                         // < 0x100
    if (z18 && a[17:15] >= 3'd5) begin                                          // 0x28000-0x3FFFF
        if (a[14:DM_AW] == '0) return {1'b0, A_DM};
        return {1'b0, A_EXT};
    end
    if (z24 && !a[24] && (a[23:22] == 2'd1 || a[23:22] == 2'd2)) return {wr, A_FIN};        // 0x400000-0xBFFFFF
    if (z24 && ((!a[24] && a[23:22] == 2'd3) || (a[24] && a[23:22] == 2'd0))) return {!wr, A_FOUT};  // -0x13FFFFF
    if (z24 && a[24] && a[23:21] >= 3'd2 && a[23:21] <= 3'd6) return {1'b0, A_EXT};          // 0x1400000-0x1DFFFFF
    return {1'b1, A_NONE};                  // block 0 data, short words, unmapped
endfunction

// R1042: a PM-bus data access, its 24-bit address (DAG2's; MAME's program space is 24 bits):
// block 0 in the on-chip PM -> the PM RAM's port B; block 1 (0x28000-0x3FFFF) -> the DM RAM or
// the page, as a DM-bus access to the same word; anything else (PM past the on-chip words,
// external PM) unsupported. {unsupported, kind}
function automatic logic [3:0] pm_kind(input logic [23:0] a);
    if (a[23:PM_AW] == 24'(32'h20000 >> PM_AW)) return {1'b0, A_PM};
    if (a[23:18] == 6'h0 && a[17:15] >= 3'd5) return {1'b0, (a[14:DM_AW] == '0) ? A_DM : A_EXT};
    return {1'b1, A_NONE};
endfunction

// R1042: the DM-bus address a block-1 PM-bus access goes to. The manual's: the same address
// (normal-word addressing, SYSCON IMDW1 = 0). MAME's (PMB1_MAME, benches): pm_r<1>'s column
// layout -- 48-bit word w of the block at 32-bit word (w & 0xfff) + (w >> 13) * 0x3000 +
// ((w >> 12) & 1) * 0x2000, its upper 32 bits being that whole word; past 0x4fff unmapped
function automatic logic [24:0] pm_b1(input logic [23:0] a);
    logic [14:0] w;
    logic [2:0]  sl;
    if (!PMB1_MAME || !(a[23:18] == 6'h0 && a[17:15] >= 3'd5)) return {1'b0, a};
    w = a[14:0]; sl = w[14:12];
    return {sl > 3'd4, 24'h28000 + 24'({3'b000, w[11:0]} + (sl[2:1] == 2'd0 ? 15'h0 : sl[2:1] == 2'd1 ? 15'h3000 : 15'h6000) +
                                        (sl[0] ? 15'h2000 : 15'h0))};
endfunction

// R1048: an address's access-kind bits (d_acc_hit's, the gate apart) and its map test (bad), as
// D made them from mem_a -- here a function, so D can make them from each form's sum and choose
// by the form last (acc_sum_i / acc_sum_o below)
function automatic logic [3:0] acc_bits(input logic [31:0] a, input logic pmb, input logic wr);
    logic z24, z18, h_iop, h_dm, h_dx, h_fin, h_fout, h_ext, p_pm, p_dm, p_dx, bd;
    logic [24:0] pa;
    logic [3:0]  k;
    pa = pm_b1(a[23:0]);
    z24 = a[31:25] == 7'h0;
    z18 = z24 && a[24:18] == 7'h0;
    h_iop = z18 && a[17:8] == 10'h0;
    h_dm = z18 && a[17:15] >= 3'd5 && a[14:DM_AW] == '0;
    h_dx = z18 && a[17:15] >= 3'd5 && a[14:DM_AW] != '0;
    h_fin = z24 && !a[24] && (a[23:22] == 2'd1 || a[23:22] == 2'd2) && !wr;
    h_fout = z24 && ((!a[24] && a[23:22] == 2'd3) || (a[24] && a[23:22] == 2'd0)) && wr;
    h_ext = z24 && a[24] && a[23:21] >= 3'd2 && a[23:21] <= 3'd6;
    p_pm = !pa[24] && pa[23:PM_AW] == 24'(32'h20000 >> PM_AW);
    p_dm = !pa[24] && pa[23:18] == 6'h0 && pa[17:15] >= 3'd5 && pa[14:DM_AW] == '0;
    p_dx = !pa[24] && pa[23:18] == 6'h0 && pa[17:15] >= 3'd5 && pa[14:DM_AW] != '0;
    if (pmb) begin k = pm_kind(pa[23:0]); bd = k[3] || pa[24]; end
    else begin k = dm_kind(a, wr); bd = k[3]; end
    return {bd, pmb ? (p_pm || p_dx) : (h_iop || h_dx || h_ext),
                pmb ? p_pm : (h_fin || h_fout),
                pmb ? (p_dm || p_dx) : (h_dm || h_dx || h_ext || h_fout)};
endfunction

// D (R1029): the word's decisions -- the loop end's, the condition -- and everything X needs:
// the compute and access fields, the operands, the data address. The sequencer's next state
// is not made here: X's first clock makes it (below) from S, the opcode and these decisions.
always_comb begin
    xc_t  x;
    logic [47:0] op;
    logic [4:0]  cond;
    logic [22:0] comp;
    logic        cok, comp_on, comp_f;
    logic [2:0]  ii;
    logic        ee, ci, la;
    logic        alusat, trunc;
    logic [3:0]  rnn;
    logic        lce_ne1;
    logic        le, le_cnt, le_long, done;
    logic [2:0]  lstkp1;
    logic        lz1, pz1, l71;
    logic [5:0]  pcstkp1;
    logic [23:0] pcstk1;
    logic [31:0] curl1, lcntr1;
    logic        mem_f, mem_on;
    logic [31:0] mem_a;
    logic        mem_wr;
    logic        bad, mbad, dag, dag_f;
    logic        cbad, fl_d;                    // the compute field's reasons, whatever its condition
    logic [1:0]  wd_sel;                        // store / ureg data: 0 R (port E), 1 the ureg, 2 the immediate
    logic [1:0]  pm_sel;                        // post-modify by: 0 M (DAG1), 1 the 6-bit immediate, 2 M of op[38]'s DAG, 3 the 32-bit
    logic [31:0] ur_all;                        // the ureg D names, the sequencer's included
    logic [31:0] ur_sq;                         // ... the sequencer's (after the loop end)
    logic [4:0]  cnd;                           // the word's condition
    logic [2:0]  akind;
    logic [3:0]  why0;
    logic        pmb;                           // R1042: the word's one access is on the PM bus (DAG2)
    logic        t1;                            // R1042: type 1 (compute, DM and PM moves)
    logic        bad2;                          // ... its PM access's address unsupported
    logic [2:0]  akind2;
    logic [24:0] pa2;                           // ... its DM-bus address (pm_b1)
    logic        pxpm;                          // a PX transfer over the PM bus (48-bit in MAME: not done)

    op = pm_q;
    x = '0;
    t1 = op[47:45] == 3'b001;
    pmb = (op[47:45] == 3'b010 && op[32]) || (op[47:44] == 4'b0110 && op[40]) || (op[47:44] == 4'b1000 && op[32]) ||
          (op[47:42] == 6'b000100 && op[41]) || (op[47:45] == 3'b101 && op[44]) || (op[47:44] == 4'b1001 && op[37]);
    pxpm = pmb && (((op[47:45] == 3'b010) ? op[30:23] : op[39:32]) == 8'hdb) &&
           (op[47:45] == 3'b010 || op[47:42] == 6'b000100 || op[47:45] == 3'b101);
    d_ru = 5'h0;
    d_need_astat = 1'b0;
    mem_f = 1'b0; mem_on = 1'b0; mem_a = 32'h0; mem_wr = 1'b0;
    wd_sel = 2'd0; pm_sel = 2'd0;
    alusat = mode1[M1_ALUSAT];
    trunc = mode1[M1_TRUNC];

    // ---------------------------------------------------------------- the loop end (S alone, its condition)
    // s.pc after the queue shift is S.daddr
    le = (S.stk & LSEM) == 0 && sf_le;
    le_cnt = S.la_type != 2'd0;
    le_long = sf_long;
    if (le_cnt) done = sf_c1;                                   // CURLCNTR - 1 == 0
    else begin
        logic dl, ds;
        // the condition on ASTAT three words back for a loop longer than two (MAME); both
        // evaluated, the loop's length choosing (R1029: the length's compare is the late one)
        // (R1044: ld_on alone -- D's decisions are used only in D, so st == ST_D adds nothing)
        dl = do_cond(ld_on ? ah2 : ah3, flg, alusat, !sf_c1, S.la_code);
        ds = do_cond(astat, flg, alusat, !sf_c1, S.la_code);
        done = le_long ? dl : ds;
    end
    if (le && !le_cnt && !le_long) d_need_astat |= cond_astat(S.la_code);
    done = le && done;
    // the sequencer after the loop end, as far as D needs it (the stack checks, the ureg read, LCE)
    lstkp1 = S.lstkp - {2'b00, done};
    pcstkp1 = S.pcstkp - {5'h0, done};
    // the pointers' tests after the pop from S's, the pop choosing (R1029: no subtract before them)
    lz1 = done ? S.lstkp == 3'd1 : S.lstkp == 3'd0;            // lstkp1 == 0
    pz1 = done ? S.pcstkp == 6'd1 : S.pcstkp == 6'd0;          // pcstkp1 == 0
    l71 = done ? S.lstkp == 3'd7 : S.lstkp == 3'd6;            // lstkp1 + 1 == 7
    if (done && (S.lstkp == 3'd0 || S.pcstkp == 6'd0)) begin x.unsup = 1'b1; x.why = U_STK; end
    curl1 = (le && le_cnt) ? S.curlcntr - 32'd1 : S.curlcntr;
    lcntr1 = done ? curl1 : S.lcntr;
    if (done) curl1 = !lz1 ? lcs_p2 : 32'hFFFF_FFFF;
    pcstk1 = (done && S.pcstkp != 6'd0 && S.pcstkp <= 6'd30) ? (!pz1 ? pcs_p2 : 24'hFFFFFF) : S.pcstk;
    // CURLCNTR != 1 after the loop end, the three cases compared in parallel
    if (done) lce_ne1 = !lz1 ? lcs_p2ne1 : 1'b1;
    else if (le && le_cnt) lce_ne1 = !sf_c2;
    else lce_ne1 = !sf_c1;
    // the ureg source (every form that reads one names it in ur_sel), after the loop end: the
    // sequencer's for both outcomes of its pop, the pop choosing (R1029: last)
    begin
        logic [31:0] q1, q0, cd;
        cd = (le && le_cnt) ? S.curlcntr - 32'd1 : S.curlcntr;
        q1 = seq_rd(ur_sel[3:0], (S.pcstkp != 6'd0 && S.pcstkp <= 6'd30) ? ((S.pcstkp != 6'd1) ? pcs_p2 : 24'hFFFFFF) : S.pcstk,
                    S.pcstkp - 6'd1, (S.lstkp != 3'd1) ? lcs_p2 : 32'hFFFF_FFFF, cd);
        q0 = seq_rd(ur_sel[3:0], S.pcstk, S.pcstkp, cd, S.lcntr);
        ur_all = (ur_sel[7:4] == 4'h6) ? (done ? q1 : q0) : ur_v;
        ur_sq = done ? q1 : q0;
        d_ursq1 = q1; d_ursq0 = q0;
        // (R1028's form, for the benches' check)
        d_urall_ref = (ur_sel[7:4] == 4'h6) ? seq_rd(ur_sel[3:0], pcstk1, pcstkp1, curl1, lcntr1) : ur_v;
    end

    // ---------------------------------------------------------------- the handler
    cond = op[37:33];
    comp = op[22:0];
    ii = op[43:41];
    ee = op[25]; ci = op[24]; la = op[38];
    rnn = comp[11:8];
    comp_on = 1'b0;
    comp_f = 1'b0;                              // the form has a compute field (whatever its condition)
    cbad = 1'b0; fl_d = 1'b0;

    // the condition (ureg <-> ureg has it at op[35:31]); D waits for a landing's ASTAT if the
    // condition reads ASTAT and the form has one (DO UNTIL's is the loop's, tested at its end)
    cnd = (op[47:44] == 4'b0111) ? op[35:31] : cond;
    // (both fields evaluated, the form choosing, and for LCE both outcomes of the loop end's
    // pop, the pop choosing: R1029)
    begin
        logic l1, l0, c1, c0;
        logic isf, fv;
        logic [4:0] cc;
        l1 = (S.lstkp != 3'd1) ? lcs_p2ne1 : 1'b1;                  // after a pop
        l0 = (le && le_cnt) ? !sf_c2 : !sf_c1;
        // R1044: a flag-pin condition (9-12, FLAG0-3 in: the FIFOs' empty / full) is its pin, negated
        // by bit 4, chosen last -- the FIFOs' flags come from the copro's counters, late; every
        // other condition is if_cond's without them (if_cond reads flg only for 9-12)
        cc = (op[47:44] == 4'b0111) ? op[35:31] : cond;
        isf = cc[3:0] >= 4'h9 && cc[3:0] <= 4'hc;
        fv = flg[2'(cc[3:0] - 4'h9)] ^ cc[4];
        c1 = (op[47:44] == 4'b0111) ? if_cond(astat, 4'h0, alusat, l1, op[35:31]) : if_cond(astat, 4'h0, alusat, l1, cond);
        c0 = (op[47:44] == 4'b0111) ? if_cond(astat, 4'h0, alusat, l0, op[35:31]) : if_cond(astat, 4'h0, alusat, l0, cond);
        cok = isf ? fv : done ? c1 : c0;
        d_cok1 = isf ? fv : c1; d_cok0 = isf ? fv : c0;   // (R1048: for each outcome of the loop end's pop)
        // (R1048: and the popped outcome's for each value of l1 -- the LCE after the pop, an MLAB
        // read at S.lstkp's neighbour -- which chooses after them)
        d_l1 = l1;
        d_cok1t = isf ? fv : (op[47:44] == 4'b0111) ? if_cond(astat, 4'h0, alusat, 1'b1, op[35:31]) : if_cond(astat, 4'h0, alusat, 1'b1, cond);
        d_cok1f = isf ? fv : (op[47:44] == 4'b0111) ? if_cond(astat, 4'h0, alusat, 1'b0, op[35:31]) : if_cond(astat, 4'h0, alusat, 1'b0, cond);
        d_cok_ref = done ? ((op[47:44] == 4'b0111) ? if_cond(astat, flg, alusat, l1, op[35:31]) : if_cond(astat, flg, alusat, l1, cond))
                         : ((op[47:44] == 4'b0111) ? if_cond(astat, flg, alusat, l0, op[35:31]) : if_cond(astat, flg, alusat, l0, cond));
    end
    if (op[47:44] == 4'b0100 || op[47:44] == 4'b0101 || op[47:44] == 4'b0110 || op[47:44] == 4'b0111 ||
        op[47:44] == 4'b1000 || op[47:46] == 2'b11 || op[47:40] == 8'b00000001 || op[47:40] == 8'b00000010 ||
        op[47:40] == 8'b00000100 || op[47:41] == 7'b0000011 || op[47:41] == 7'b0000100 || op[47:41] == 7'b0000101)
        d_need_astat |= cond_astat(cnd);

    // the data fields the handler's enables use, from the opcode whatever the condition (R1029:
    // off D's path from it; R1028 set them with the enables, which alone are cleared otherwise)
    x.ld_ureg = (op[47:45] == 3'b010) ? op[30:23] : op[39:32];
    x.ld_dst = t1 ? op[36:33] : op[26:23];
    x.uw_reg = (op[47:44] == 4'b0111) ? op[30:23] : op[39:32];
    x.ld_ast = x.ld_ureg == 8'h7c; x.uw_ast = x.uw_reg == 8'h7c;     // (R1048: X's ASTAT write, decoded here)
    x.pmod_i = (op[47:40] == 8'b00000100) ? {op[38], op[32:30]} : (op[47:39] == 9'b000101100) ? {op[38], op[34:32]}
                                                                 : {pmb, op[43:41]};
    casez (op[47:39])
    9'b001??????: begin                                         // type 1: compute, dreg <-> DM, dreg <-> PM
        // (R1042) no condition: the compute always; the DM move is this word's access (X's first
        // pass), the PM move its second (XC.acc2: X's second pass). Post-modify only.
        comp_on = 1'b1; comp_f = 1'b1;
        mem_f = 1'b1; mem_on = 1'b1; mem_wr = op[44];
        pm_sel = 2'd0;
        if (op[44]) begin wd_sel = 2'd0; d_ru[4] = 1'b1; end
        else x.ld_r = 1'b1;
        x.pmod = 1'b1;
    end
    9'b00000001?: begin                                         // compute
        comp_on = cok; comp_f = 1'b1;
    end
    9'b0100?????, 9'b0101?????: begin                           // compute, ureg <-> DM|PM, pre / post
        logic g, dd, post;
        logic [7:0] u;
        g = op[32]; dd = op[31]; u = op[30:23]; post = op[44];
        comp_f = 1'b1;
        mem_f = 1'b1; mem_wr = dd;              // (R1042: g, the PM bus, as the DM's with DAG2)
        pm_sel = 2'd0;
        if (dd) begin
            wd_sel = 2'd1;
            d_ru[4] |= u[7:4] == 4'h0;
            if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
        end
        if (cok) begin
            comp_on = 1'b1;
            mem_on = 1'b1;
            if (dd) begin
                if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end else begin
                x.ld_u = 1'b1;
                if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
            end
            if (pxpm) begin x.unsup = 1'b1; x.why = U_PM; end
            if (post) begin x.pmod = 1'b1; end
        end
    end
    9'b0110?????: begin                                         // compute, dreg <-> DM|PM, imm modify
        logic upd, g, dd;
        logic [3:0] dr;
        upd = op[38]; g = op[40]; dd = op[39]; dr = op[26:23];
        comp_f = 1'b1;
        mem_f = 1'b1; mem_wr = dd;
        pm_sel = 2'd1;
        if (dd) begin wd_sel = 2'd0; d_ru[4] = 1'b1; end
        if (cok) begin
            comp_on = 1'b1;
            mem_on = 1'b1;
            if (!dd) begin x.ld_r = 1'b1; end
            if (upd) begin x.pmod = 1'b1; end
        end
    end
    9'b0111?????: begin                                         // compute, ureg <-> ureg
        logic [7:0] us, ud;
        us = op[43:36]; ud = op[30:23];
        comp_f = 1'b1;
        wd_sel = 2'd1;
        d_ru[4] |= us[7:4] == 4'h0;
        if (us[7:4] == 4'h7 && (us[3:0] == 4'hc || us[3:0] == 4'he)) d_need_astat = 1'b1;
        if (cok) begin
            comp_on = 1'b1;
            x.uw = 1'b1;
            if (!ureg_ok(us, 1'b0) || !ureg_ok(ud, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
    end
    9'b1000?????: begin                                         // immediate shift, dreg <-> DM|PM
        logic g, dd;
        logic [3:0] dr;
        g = op[32]; dd = op[31]; dr = op[26:23];
        mem_f = 1'b1; mem_wr = dd;
        pm_sel = 2'd0;
        d_ru[0] = 1'b1; d_ru[2] = 1'b1;
        if (dd) begin wd_sel = 2'd0; d_ru[4] = 1'b1; end
        x.sh_op = op[21:16]; x.sh_imm = 1'b1; x.rn = op[7:4];   // (data: whatever the condition)
        if (cok) begin
            x.sh_on = 1'b1;
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
            mem_on = 1'b1;
            if (!dd) begin x.ld_r = 1'b1; end
            x.pmod = 1'b1;
        end
    end
    9'b00000010?: begin                                         // immediate shift
        d_ru[0] = 1'b1; d_ru[2] = 1'b1;
        x.sh_op = op[21:16]; x.sh_imm = 1'b1; x.rn = op[7:4];   // (data: whatever the condition)
        if (cok) begin
            x.sh_on = 1'b1;
            if (!shift_ok(op[21:16])) begin x.unsup = 1'b1; x.why = U_COMP; end
        end
    end
    9'b00000100?: begin                                         // compute, modify
        comp_f = 1'b1;
        pm_sel = 2'd2;
        if (cok) begin
            comp_on = 1'b1;
            x.pmod = 1'b1;
        end
    end
    9'b000001100, 9'b000001110: begin                           // direct / relative jump
        if (cok) begin
            if (ci) begin x.unsup = 1'b1; x.why = U_FORM; end
            if (la) begin
                // POP_PC, POP_LOOP (the second pop of a word: the stack checks here, the rest in X)
                if (pz1) begin x.unsup = 1'b1; x.why = U_STK; end
                if (lz1) begin x.unsup = 1'b1; x.why = U_STK; end
            end
        end
    end
    9'b000001101, 9'b000001111: ;                               // direct / relative call (X)
    9'b0000100??: begin                                         // indirect / relative jump or call, compute
        comp_f = 1'b1;
        if (ci) begin x.unsup = 1'b1; x.why = U_FORM; end
        if (ee) comp_on = !cok;
        else comp_on = cok;
        if (cok && !op[39] && la) begin
            x.unsup = 1'b1; x.why = U_STK;      // loop abort on an indirect jump: not seen
        end
    end
    9'b11???????: begin                                         // indirect / relative jump, else compute, dreg <-> DM
        logic [3:0] dr;
        dr = op[26:23];
        comp_f = 1'b1;
        mem_f = 1'b1; mem_wr = op[44];
        pm_sel = 2'd0;
        if (op[44]) begin wd_sel = 2'd0; d_ru[4] = 1'b1; end
        if (!cok) begin
            comp_on = 1'b1;
            mem_on = 1'b1;
            if (!op[44]) begin x.ld_r = 1'b1; end
            x.pmod = 1'b1;
        end
    end
    9'b00001010?, 9'b00001011?: begin                           // RTS, RTI
        comp_f = 1'b1;
        if (op[40]) begin x.unsup = 1'b1; x.why = U_FORM; end    // RTI
        if (ee) comp_on = !cok; else comp_on = cok;
        if (cok && pz1) begin x.unsup = 1'b1; x.why = U_STK; end
    end
    9'b00001100?, 9'b00001101?, 9'b00001110?: begin             // DO UNTIL
        if (op[42:40] == 3'b101) begin
            // LCNTR from a ureg: its value is acc_wd's, X's first clock takes it from there
            wd_sel = 2'd1;
            // a DO's LCNTR from CURLCNTR at a loop end that pops: the popped CURLCNTR is the stack
            // word this core's DO does not read (R1028: two LCNTR stack copies, not four)
            if (done && op[39:32] == 8'h67) begin x.unsup = 1'b1; x.why = U_STK; end
            d_ru[4] |= op[39:36] == 4'h0;
            if (op[39:36] == 4'h7 && (op[35:32] == 4'hc || op[35:32] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(op[39:32], 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
        if (l71) begin x.unsup = 1'b1; x.why = U_STK; end                   // a seventh level
    end
    9'b00001111?: begin                                         // immediate -> ureg
        x.uw = 1'b1; wd_sel = 2'd2;
        if (!ureg_ok(op[39:32], 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
    end
    9'b000100???: begin                                         // ureg <-> DM|PM, direct
        logic [7:0] u;
        u = op[39:32];
        mem_wr = op[40];
        mem_f = 1'b1; mem_on = 1'b1;            // (R1042: op[41], the PM bus, as the DM's)
        if (op[40]) begin
            wd_sel = 2'd1; d_ru[4] |= u[7:4] == 4'h0;
            if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end else begin
            x.ld_u = 1'b1;
            if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
        if (pxpm) begin x.unsup = 1'b1; x.why = U_PM; end
    end
    9'b101??????: begin                                         // ureg <-> DM|PM, indirect
        logic [7:0] u;
        u = op[39:32];
        mem_wr = op[40];
        mem_f = 1'b1; mem_on = 1'b1;            // (R1042: op[44], the PM bus, with DAG2)
        if (op[40]) begin
            wd_sel = 2'd1; d_ru[4] |= u[7:4] == 4'h0;
            if (u[7:4] == 4'h7 && (u[3:0] == 4'hc || u[3:0] == 4'he)) d_need_astat = 1'b1;
            if (!ureg_ok(u, 1'b0)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end else begin
            x.ld_u = 1'b1;
            if (!ureg_ok(u, 1'b1)) begin x.unsup = 1'b1; x.why = U_UREG; end
        end
        if (pxpm) begin x.unsup = 1'b1; x.why = U_PM; end
    end
    9'b1001?????: begin                                         // immediate data -> DM|PM
        mem_wr = 1'b1; wd_sel = 2'd2; pm_sel = 2'd0;
        mem_f = 1'b1; mem_on = 1'b1;            // (R1042: op[37], the PM bus, with DAG2)
        x.pmod = 1'b1;
    end
    9'b00010100?: begin                                         // system register bit operation
        // the register's value read in D (the ureg port), but ASTAT's and STKY's in X (a landing
        // may change them in D's clock)
        x.bitop = 1'b1; x.bit_kind = op[39:37]; x.bit_reg = op[35:32]; wd_sel = 2'd1;
        if (!ureg_ok({4'h7, op[35:32]}, 1'b1) || !ureg_ok({4'h7, op[35:32]}, 1'b0) || op[39:37] == 3'd3 || op[39:37] > 3'd5) begin x.unsup = 1'b1; x.why = U_UREG; end   // R1039: and read
    end
    9'b000101100: begin                                         // modify I by an immediate
        x.pmod = 1'b1; pm_sel = 2'd3;
    end
    9'b00010111?: begin                                         // push / pop the stacks
        x.unsup = 1'b1; x.why = U_STK;
    end
    9'b000000000: ;                                             // NOP
    default: begin x.unsup = 1'b1; x.why = U_FORM; end          // IDLE, bit-reverse, the rest
    endcase

    // ---------------------------------------------------------------- the compute field
    // the read ports a compute field may use, whatever its condition (R1029: d_go from the opcode)
    if (comp_f && comp != 23'h0) begin
        if (comp[22]) begin
            if (comp[21:19] == 3'b011) d_ru[3:0] = 4'hf;
        end else
            case (comp[21:20])
            2'd0, 2'd1: d_ru[1:0] = 2'h3;
            2'd2: d_ru[2:0] = 3'h7;
            default: ;
            endcase
    end
    // decoded whatever the condition (R1029: the result-register rules below off the condition's
    // path); the enables and the reasons only if it runs
    // R1048: without the 23-bit zero test in front: every form below but the fixed ALU's
    // unsupported one has a nonzero field bit in its own test (comp[22], cu != 0, or a nonzero
    // ALU opcode), so a zero field (the NOP) reaches only that branch, which now tests it itself
    if (comp_f) begin
        logic [7:0] cop;
        logic [1:0] cu;
        cop = comp[19:12]; cu = comp[21:20];
        if (comp[22]) begin
            logic [5:0] mop;
            mop = comp[21:16];
            if (mop[5:3] == 3'b011) begin                       // FMUL with FADD / FSUB / ...
                x.fl_on = comp_on; fl_d = 1'b1; x.fl_mul = 1'b1;
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
            end else begin
                x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP;   // MR moves, fixed multiply, dual
            end
        end else begin
            case (cu)
            2'd0: begin
                if (!cop[7]) begin
                    if (cop[7:4] == 4'h7 || !alu_fixed_ok(cop)) begin
                        if (comp != 23'h0) begin x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP; end
                    end
                    else begin x.fix_on = comp_on; x.fix_op = cop; x.fix_k = fix_k_of(cop); x.rn = rnn; end
                end else if (cop[7:4] == 4'hf) begin
                    x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP;   // float dual add / subtract
                end else begin
                    x.fl_on = comp_on; fl_d = 1'b1; x.ra = rnn; x.ra_we = 1'b1;
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
                    default: begin x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP; end
                    endcase
                end
            end
            2'd1: begin
                if (cop == 8'h30) begin
                    x.fl_on = comp_on; fl_d = 1'b1; x.fl_mul = 1'b1; x.rm = rnn; x.rm_we = 1'b1;
                end else begin x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP; end    // fixed multiply, MR
            end
            2'd2: begin
                x.sh_on = comp_on; x.sh_op = cop[7:2]; x.sh_imm = 1'b0; x.rn = rnn;
                if (!shift_ok(cop[7:2])) begin x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP; end
            end
            default: begin x.unsup |= comp_on; cbad = 1'b1; if (comp_on) x.why = U_COMP; end
            endcase
        end
        if (x.fl_on && !mode1[M1_RND32]) begin x.unsup = 1'b1; x.why = U_RND; end
        if (fl_d && !mode1[M1_RND32]) cbad = 1'b1;
    end
    x.trunc = trunc;
    // R1048: the fixed ALU's result-write flag (m2b_sharc_xu's set_r: every op it decodes but
    // COMP), a function of fix_op alone, made here so X's register-busy mask and the landing's
    // enables do not wait on the unit's decode
    case (x.fix_op)
    8'h01, 8'h05, 8'h25, 8'h29, 8'h02, 8'h06, 8'h26, 8'h2a, 8'h21, 8'h22, 8'h30,
    8'h40, 8'h41, 8'h42, 8'h43, 8'h61, 8'h62, 8'h63: x.fix_wr = 1'b1;
    default: x.fix_wr = 1'b0;
    endcase
    d_fixop_h = x.fix_op;
    // R1048: THE FIXED ALU's FIELDS FROM THE OPCODE's BITS DIRECTLY, the loop end's pop last: the
    // form has a compute field (d_compf, the handler's comp_f), the field is a fixed ALU op the
    // core does (d_fb), and the field runs (comp_on: 1, the condition or its inverse by the form)
    // for each outcome of the pop -- the same fix_on / fix_k / fix_wr as the handler's case
    // (g_fix_check), which had the form's case, the field's case and the condition in a row
    begin
        logic       fb, con1, con0, ee_;
        logic [7:0] cp;
        cp = op[19:12]; ee_ = op[25];
        d_compf = op[47:45] == 3'b001 || op[47:40] == 8'h01 || op[47:45] == 3'b010 || op[47:44] == 4'b0110 ||
                  op[47:44] == 4'b0111 || op[47:40] == 8'h04 || op[47:41] == 7'b0000100 || op[47:46] == 2'b11 ||
                  op[47:41] == 7'b0000101;
        fb = d_compf && !op[22] && op[21:20] == 2'd0 && !cp[7] && cp[7:4] != 4'h7 && alu_fixed_ok(cp);
        // R1050: the op too, from fb -- the handler's select sat behind the form's case (s5267's
        // worst path, pm2 -> XC.fix_op -0.509); the same value in every clock (benches check)
        x.fix_op = {8{fb}} & cp;
        con1 = (op[47:45] == 3'b001) ? 1'b1 :
               (op[47:46] == 2'b11) ? !d_cok1 :
               (op[47:41] == 7'b0000100 || op[47:41] == 7'b0000101) ? (ee_ ? !d_cok1 : d_cok1) : d_cok1;
        con0 = (op[47:45] == 3'b001) ? 1'b1 :
               (op[47:46] == 2'b11) ? !d_cok0 :
               (op[47:41] == 7'b0000100 || op[47:41] == 7'b0000101) ? (ee_ ? !d_cok0 : d_cok0) : d_cok0;
        d_fix_ref = {x.fix_on, x.fix_wr, x.fix_k}; d_compf_x = comp_f;
        x.fix_on = done ? (fb && con1) : (fb && con0);
        x.fix_k = {11{fb}} & fix_k_of(cp);
        x.fix_wr = fb && cp != 8'h0a;
    end

    // the data access's address (one adder), the store / ureg data, the post-modify amount
    // (R1029: the selects decoded here from the opcode's bits, an AND-OR, not through the
    // handler's case)
    begin
        logic [31:0] off;
        logic        s1, s2, s3, sd;
        s1 = op[47:45] == 3'b010 && !op[44];                // compute, ureg <-> DM, pre-modify: M
        s2 = op[47:44] == 4'b0110 && !op[38];               // compute, dreg <-> DM, pre-modify: the 6-bit
        sd = op[47:42] == 6'b000100;                        // ureg <-> DM direct: the 32-bit, no I
        s3 = sd || op[47:45] == 3'b101;                     // ... and indirect: I + the 32-bit
        // (R1044: M from either DAG's copy, the g bit in the select, beside the read)
        off = ({32{s1 && !d_pg}} & m1_rd) | ({32{s1 && d_pg}} & m3_rd) | ({32{s2}} & sext6(op[32:27])) | ({32{s3}} & op[31:0]);
        // R1048: the 32-bit offset's forms (s3) on an adder of their own, its immediate straight
        // from the opcode, and the others' (M / the 6-bit / none) on the other; the form chooses
        // after the sums -- mem_a is the same value ((s1 / s2) and s3 are never both)
        d_sum_i = ({32{!sd}} & i1x_rd) + op[31:0];
        d_sum_o = i1x_rd + (({32{s1 && !d_pg}} & m1_rd) | ({32{s1 && d_pg}} & m3_rd) | ({32{s2}} & sext6(op[32:27])));
        d_s3 = s3;
        mem_a = s3 ? d_sum_i : d_sum_o;
    end
    // (R1029: as one AND-OR over the sources, the selects from the opcode beside the reads; the
    // same as (wd_sel == 0) ? R : (wd_sel == 1) ? ur_all : the immediate, wd_sel being 0-2)
    begin
        logic       w1;
        logic [3:0] gr;
        w1 = wd_sel == 2'd1; gr = ur_sel[7:4];
        // R1044: everything but the sequencer's source first (d_accwd_b, kept as a node), the
        // loop end's pop (done, the late one) choosing that source in the last gate
        d_accwd_b = ({32{wd_sel == 2'd0 || (w1 && gr == 4'h0)}} & rf_rd[4]) |
                   ({32{w1 && gr == 4'h1}} & iu_rd) |
                   ({32{w1 && gr == 4'h2}} & (ur_sel[3] ? {{8{mu_rd[23]}}, mu_rd[23:0]} : mu_rd)) |
                   ({32{w1 && gr == 4'h7}} & sys_rd(ur_sel[3:0], astat, mode1, mode2, stky_rd, irptl, imask, ustat1, ustat2, flg)) |
                   ({32{w1 && gr == 4'hd}} & ((ur_sel[3:0] == 4'hb) ? px[31:0] : (ur_sel[3:0] == 4'hc) ? {16'h0, px[15:0]} :
                                               (ur_sel[3:0] == 4'hd) ? px[47:16] : 32'h0)) |
                   ({32{wd_sel == 2'd2}} & op[31:0]);
        x.acc_wd = d_accwd_b | ({32{w1 && gr == 4'h6}} & (done ? d_ursq1 : d_ursq0));
        d_accwd_chk = ({32{wd_sel == 2'd0 || (w1 && gr == 4'h0)}} & rf_rd[4]) |
                   ({32{w1 && gr == 4'h1}} & iu_rd) |
                   ({32{w1 && gr == 4'h2}} & (ur_sel[3] ? {{8{mu_rd[23]}}, mu_rd[23:0]} : mu_rd)) |
                   ({32{w1 && gr == 4'h7}} & sys_rd(ur_sel[3:0], astat, mode1, mode2, stky_rd, irptl, imask, ustat1, ustat2, flg)) |
                   ({32{w1 && gr == 4'hd}} & ((ur_sel[3:0] == 4'hb) ? px[31:0] : (ur_sel[3:0] == 4'hc) ? {16'h0, px[15:0]} :
                                               (ur_sel[3:0] == 4'hd) ? px[47:16] : 32'h0)) |
                   ({32{w1 && gr == 4'h6}} & ur_sq) |
                   ({32{wd_sel == 2'd2}} & op[31:0]);
        d_accwd_ref = (wd_sel == 2'd0) ? rf_rd[4] : (wd_sel == 2'd1) ? ur_all : op[31:0];   // (benches)
    end
    dx_urall = ur_all;
    case (pm_sel)
    2'd0: x.pmod_m = m1x_rd;
    2'd1: x.pmod_m = sext6(op[32:27]);
    2'd2: x.pmod_m = m2_rd;                                    // (the modify forms: DAG2's copy)
    default: x.pmod_m = op[31:0];
    endcase

    // MAME's order: a load / ureg move to the float result's register wins. From the form's
    // load target, its opcode alone (R1029): a form's compute and its load run under the same
    // condition, so where the compute runs the load does
    begin
        logic       lr, lu, lw, kv;
        logic [3:0] k;
        lr = (op[47:44] == 4'b0110 && !op[39]) || (op[47:44] == 4'b1000 && !op[31]) || (op[47:46] == 2'b11 && !op[44]);
        lu = op[47:45] == 3'b010 && !op[31] && op[30:27] == 4'h0;           // a ureg load to R
        lw = op[47:44] == 4'b0111 && op[30:27] == 4'h0;                     // a ureg move to R
        kv = lr || lu || lw;
        k = lr ? op[26:23] : op[26:23];                                     // (the three put it at op[26:23])
        // R1042: type 1's loads, the DM bus's (op[36:33]) and the PM bus's (op[26:23]): the
        // manual's precedence (p. 11-42: DM, PM, ALU, multiplier, shifter) -- both over the compute
        begin
            logic t1d, t1p, h11;
            t1d = t1 && !op[44]; t1p = t1 && !op[37];
            if (kv && k == x.rm) x.rm_we = 1'b0;
            // R1057: Ra's compares on op[11:8], not x.ra: the decode sets ra_we only where it sets
            // Ra to comp[11:8] (the multifunction's and the single float ops' rnn), so where ra_we
            // is set the two are equal and elsewhere the enable stays 0 -- the same ra_we in every
            // clock, the compute field's decode no longer in front of the compares (s5335: pm2 ->
            // XC.ra_we -0.610 at slow 100C)
            // (h11: a load to op[11:8] -- Ra's, and the compute field's Rn's, test)
            h11 = (kv && k == op[11:8]) || (t1p && op[26:23] == op[11:8]) || (t1d && op[36:33] == op[11:8]);
            d_rawe_ref = x.ra_we && !(kv && k == x.ra) && !(t1p && op[26:23] == x.ra) && !(t1d && op[36:33] == x.ra);
            if (h11) x.ra_we = 1'b0;
            if (t1p && op[26:23] == x.rm) x.rm_we = 1'b0;
            if (t1d && op[36:33] == x.rm) x.rm_we = 1'b0;
            if (x.fl_mul && x.rm_we && x.ra_we && x.rm == x.ra && !x.fl_comp) x.rm_we = 1'b0;  // Ra written after Rm
            // R1048: the same enable from each of Rm's two sources apart -- the multifunction's
            // comp[15:12] (with Ra = comp[11:8]) and the single FMUL's comp[11:8] -- each with its
            // own compares, the form choosing last (it was: the form -> x.rm -> the compares)
            begin
                logic wa, wb, ca, cb, raa;
                logic [3:0] ma, mb;
                ma = comp[15:12]; mb = comp[11:8];
                wa = comp_f && comp != 23'h0 && comp[22] && comp[21:19] == 3'b011;
                wb = comp_f && comp != 23'h0 && !comp[22] && comp[21:20] == 2'd1 && comp[19:12] == 8'h30;
                ca = (kv && k == ma) || (t1p && op[26:23] == ma) || (t1d && op[36:33] == ma);
                cb = (kv && k == mb) || (t1p && op[26:23] == mb) || (t1d && op[36:33] == mb);
                raa = !((kv && k == mb) || (t1p && op[26:23] == mb) || (t1d && op[36:33] == mb));   // Ra = comp[11:8]
                d_rmwe_ref = x.rm_we;
                x.rm_we = (wa && !ca && !(raa && ma == mb && !x.fl_comp)) || (wb && !cb);
            end
            // the fixed / shifter result lands after X (R1029), after the word's load: a load or ureg
            // move to its register wins (MAME's order), as for a float result
            d_rnwe_ref = !(kv && k == x.rn) && !((t1p && op[26:23] == x.rn) || (t1d && op[36:33] == x.rn));
            // R1057 (R1052's 15, reduced): Rn's two places compared apart, the form last. x.rn is
            // set inside the compute field's decode (s5346: pm2 -> Decoder3 -> sh_on -> WideOr3 ->
            // dx.rn -> rn_we -> XC.rn_we -0.757 at slow -40C). The enable is read only with a fixed
            // ALU or shifter result (fix_on && fix_wr, or sh_on): in a compute field Rn is op[11:8];
            // in the immediate shifts op[7:4], where 1000's only load is its own (op[31] clear, to
            // op[26:23]: no type 1) and 00000010's has none -- for which !h11 is 1 already
            begin
                logic wi;
                wi = !(!op[31] && op[26:23] == op[7:4]);
                x.rn_we = (op[47:44] == 4'b1000) ? wi : !h11;
            end
            // the PM load, unless the DM load is to the same register (DM's precedence)
            x.ld2_r = t1p && !(t1d && op[36:33] == op[26:23]);
            x.ld2_dst = op[26:23];
        end
    end

    // R1048: the kind's bits and the map test of each sum (the form chooses last, below), the
    // direction from the opcode's bits directly (d_wrf) -- the handler's mem_wr is a case's select,
    // five LUTs deep; the two are the same wherever the form has an access (mem_f; benches check)
    d_wrf = op[47] ? (op[46] ? op[44] : op[45] ? op[40] : op[44] ? 1'b1 : op[31])     // 11: op[44]; 101: op[40]; 1001: 1; 1000: op[31]
                   : (op[46] ? (op[45] ? op[39] : op[31])                              // 0110: op[39]; 010: op[31]
                             : (op[45] ? op[44] : op[40]));                            // 001: op[44]; 000100: op[40]
    d_wrf_ref = mem_wr; d_memf_x = mem_f;
    // R1048: the form has an access (the handler's mem_f) from op[47:42] directly: type 1, the
    // ureg / dreg <-> DM|PM forms (010x, 0110, 1000, 11xx, 000100, 101, 1001) -- one LUT, not the
    // case's wide OR (benches check it against mem_f in every D clock)
    d_memf = op[47:45] == 3'b001 || op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000 ||
             op[47:46] == 2'b11 || op[47:42] == 6'b000100 || op[47:45] == 3'b101 || op[47:44] == 4'b1001;
    d_kb_i = acc_bits(d_sum_i, pmb, d_wrf);
    d_kb_o = acc_bits(d_sum_o, pmb, d_wrf);
    // the memory access: its kind from the address (the one late decision of D)
    // (R1042: a PM-bus access by the PM space's map, its block-1 words at the DM-bus address of
    // the same word)
    begin
        logic [24:0] pa;
        pa = pm_b1(mem_a[23:0]);
        if (pmb) begin
            {bad, akind} = pm_kind(pa[23:0]);
            bad = bad || pa[24];
            x.acc_addr = (akind == A_PM) ? {8'h0, mem_a[23:0]} : {8'h0, pa[23:0]};
        end else begin
            {bad, akind} = dm_kind(mem_a, mem_wr);
            x.acc_addr = mem_a;
        end
    end
    // R1042: type 1's PM access (DAG2: I8-15 by op[32:30], M8-15 by op[29:27], DAG2's copies)
    pa2 = pm_b1(i4_rd[23:0]);
    {bad2, akind2} = pm_kind(pa2[23:0]);
    bad2 = t1 && (bad2 || pa2[24]);
    x.dual = t1;
    x.acc2 = akind2;
    x.acc2_wr = op[37];
    x.acc2_a = (akind2 == A_PM) ? i4_rd[23:0] : pa2[23:0];
    // (mem_on and x.pmod are the condition's, through the handler; the same tests from the
    // opcode with the condition last below, R1029)
    begin
        logic exm;
        exm = (op[47:46] == 2'b11) ? !cok :
              (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? cok : 1'b1;
        d_mbad_nc = mem_f && bad;                // (R1044's; the benches' since R1048)
        // (R1048: the loop end's pop and the condition chosen in the gate, the sums' map test --
        // the form choosing -- last; d_mbad_nc the benches')
        begin
            logic e1t, e1f, e0;
            e1t = (op[47:46] == 2'b11) ? !d_cok1t : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok1t : 1'b1;
            e1f = (op[47:46] == 2'b11) ? !d_cok1f : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok1f : 1'b1;
            e0 = (op[47:46] == 2'b11) ? !d_cok0 : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok0 : 1'b1;
            d_mbg = d_memf && (done ? (d_l1 ? e1t : e1f) : e0);
            mbad = ((d_s3 ? d_kb_i[3] : d_kb_o[3]) && d_mbg) || bad2;
        end
    end
    d_mbad_ref = (mem_on && bad) || bad2;       // (R1028's, for the benches' check)
    d_bad_x = bad;
    x.acc_wr = mem_wr;
    // circular buffers (L != 0) are not done
    // (the index from the opcode alone, R1029: x.pmod_i is the same where x.pmod is set)
    begin
        logic [3:0] pmi;
        pmi = (op[47:40] == 8'b00000100) ? {op[38], op[32:30]} : (op[47:39] == 9'b000101100) ? {op[38], op[34:32]}
                                                                : {pmb, op[43:41]};
        // the forms that post-modify where they run (the 11 form's where its condition fails;
        // R1042: the PM bus's too, on DAG2's L, and type 1's two)
        // (R1048: L's flag read at each of pmi's three indexes, the form choosing after the reads
        // -- the same lnz[pmi]; the decode was in front of the 16-way select)
        begin
            logic la, lb, lc;
            la = lnz[{op[38], op[32:30]}]; lb = lnz[{op[38], op[34:32]}];
            lc = pmb ? lnz[{1'b1, op[43:41]}] : lnz[{1'b0, op[43:41]}];
            d_lnzp = (op[47:40] == 8'b00000100) ? la : (op[47:39] == 9'b000101100) ? lb : lc;
            d_lnzp_ref = lnz[pmi];
        end
        dag_f = (d_lnzp && ((op[47:45] == 3'b010 && op[44]) || (op[47:44] == 4'b0110 && op[38]) ||
                              op[47:44] == 4'b1000 || op[47:46] == 2'b11 || op[47:44] == 4'b1001 ||
                              op[47:40] == 8'b00000100 || op[47:39] == 9'b000101100 || t1)) ||
                (t1 && lnz[{1'b1, op[32:30]}]);
        // x.pmod && lnz[pmi], the condition last: every post-modifying form's modify runs on its
        // condition (the 11 form's on its failing; the modify-by-immediate, immediate-store and
        // type-1 forms' always)
        dag = dag_f && ((op[47:46] == 2'b11) ? !cok : (op[47:39] == 9'b000101100 || op[47:44] == 4'b1001 || t1) ? 1'b1 : cok);
    end
    d_dag_ref = (x.pmod && lnz[x.pmod_i]) || (t1 && lnz[{1'b1, op[32:30]}]);   // (R1028's, for the benches' check)
    x.pmod_b = (op[47:40] == 8'b00000100 || op[47:39] == 9'b000101100) ? i2_rd : i1x_rd;

    // an unsupported word does nothing but move the queue (and is flagged): X's first clock
    // moves the queue on XC.unsup, and X writes no compute result (fixed, shifter or float), no
    // post-modify, no ureg and no bit operation on it; here only the access is cleared (R1029:
    // the rest is gated in X, off D's path). MAME's order: a data address outside the map over
    // the opcode's reason, a DAG's over both.
    why0 = x.why;
    if (x.unsup || dag || mbad) x.unsup = 1'b1;
    // The access (R1029: the condition last, a select). In every form with one the reasons that
    // depend on the condition share the access's, so the access is made where the condition holds
    // and none of the opcode's reasons, as if it ran, is there -- nor the loop end's stack test, the
    // DAG's, the address's: exactly where R1028 made it.
    begin
        logic ex, rz, ub;
        logic [7:0] u;
        u = (op[47:45] == 3'b010) ? op[30:23] : op[39:32];
        // (R1048: each form's ureg field tested apart, the form choosing after the tests -- it
        // was the field's select in front of ureg_ok; u is op[30:23] for 010, else op[39:32])
        ub = (op[47:45] == 3'b010) ? !ureg_ok(op[30:23], !op[31]) :
             (op[47:42] == 6'b000100 || op[47:45] == 3'b101) ? !ureg_ok(op[39:32], !op[40]) : 1'b0;
        // (R1048: cbad is set only inside the compute decode's `if (comp_f)`, and never for a zero
        // field (cf996899), so it stands for comp_f && comp != 0 && cbad)
        rz = ub || (op[47:44] == 4'b1000 && !shift_ok(op[21:16])) || cbad ||
             (done && (S.lstkp == 3'd0 || S.pcstkp == 6'd0)) || dag_f || pxpm || bad2;
        d_rzb = ub || (op[47:44] == 4'b1000 && !shift_ok(op[21:16])) || cbad ||
                dag_f || pxpm;                   // (R1048: rz but the loop end's stack test and bad2, both last)
        d_cbad_ref = comp_f && comp != 23'h0 && cbad; d_cbad_x = cbad;
        ex = (op[47:46] == 2'b11) ? !cok :
             (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? cok : 1'b1;
        // R1044: each bit of the kind as an OR of its regions' tests on the sum, the form's gate
        // last -- no "unsupported, else the kind" select after the adder. dm_kind's / pm_kind's
        // regions are disjoint and a region that is unsupported (FIN written, FOUT read, outside
        // the map) sets no bit, so this is (ex && mem_f && !bad && !rz) ? akind : A_NONE exactly
        // (A_DM 001, A_FIN 010, A_FOUT 011, A_IOP 100, A_EXT 101, A_PM 110; d_acc_ref checks it)
        begin
            logic        g, z24, z18, h_iop, h_dm, h_dx, h_fin, h_fout, h_ext, p_pm, p_dm, p_dx;
            logic [31:0] a;
            logic [24:0] pa;
            a = mem_a;
            pa = pm_b1(mem_a[23:0]);
            z24 = a[31:25] == 7'h0;
            z18 = z24 && a[24:18] == 7'h0;
            h_iop = z18 && a[17:8] == 10'h0;
            h_dm = z18 && a[17:15] >= 3'd5 && a[14:DM_AW] == '0;
            h_dx = z18 && a[17:15] >= 3'd5 && a[14:DM_AW] != '0;
            h_fin = z24 && !a[24] && (a[23:22] == 2'd1 || a[23:22] == 2'd2) && !mem_wr;
            h_fout = z24 && ((!a[24] && a[23:22] == 2'd3) || (a[24] && a[23:22] == 2'd0)) && mem_wr;
            h_ext = z24 && a[24] && a[23:21] >= 3'd2 && a[23:21] <= 3'd6;
            p_pm = !pa[24] && pa[23:PM_AW] == 24'(32'h20000 >> PM_AW);
            p_dm = !pa[24] && pa[23:18] == 6'h0 && pa[17:15] >= 3'd5 && pa[14:DM_AW] == '0;
            p_dx = !pa[24] && pa[23:18] == 6'h0 && pa[17:15] >= 3'd5 && pa[14:DM_AW] != '0;
            // (R1044: the condition in the last gate -- the kind without it, d_acc_nc, kept as a
            // node; ex is cok, !cok or 1 by the form, its selects from the opcode)
            g = mem_f && !rz;
            d_acc_nc[0] = g && (pmb ? (p_dm || p_dx) : (h_dm || h_dx || h_ext || h_fout));
            d_acc_nc[1] = g && (pmb ? p_pm : (h_fin || h_fout));
            d_acc_nc[2] = g && (pmb ? (p_pm || p_dx) : (h_iop || h_dx || h_ext));
            // R1048: the regions' bits without the gate (kept), the gate for each outcome of the
            // loop end's pop -- its stack test (in rz) and the condition -- and the pop last
            d_acc_hit[0] = pmb ? (p_dm || p_dx) : (h_dm || h_dx || h_ext || h_fout);
            d_acc_hit[1] = pmb ? p_pm : (h_fin || h_fout);
            d_acc_hit[2] = pmb ? (p_pm || p_dx) : (h_iop || h_dx || h_ext);
            // (R1048: the gate for each outcome of the loop end's pop -- its stack test and the
            // condition -- and the pop chosen among the gates (done, l1: early), the sums' bits
            // -- the form choosing -- and bad2 in the one last gate)
            begin
                logic e1t, e1f, e0, g1t, g1f, g0;
                e1t = (op[47:46] == 2'b11) ? !d_cok1t : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok1t : 1'b1;
                e1f = (op[47:46] == 2'b11) ? !d_cok1f : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok1f : 1'b1;
                e0 = (op[47:46] == 2'b11) ? !d_cok0 : (op[47:45] == 3'b010 || op[47:44] == 4'b0110 || op[47:44] == 4'b1000) ? d_cok0 : 1'b1;
                g1t = d_memf && !(d_rzb || S.lstkp == 3'd0 || S.pcstkp == 6'd0) && e1t;
                g1f = d_memf && !(d_rzb || S.lstkp == 3'd0 || S.pcstkp == 6'd0) && e1f;
                g0 = d_memf && !d_rzb && e0;
                // (R1050: the pop's done last again, beside the sums' bits -- six inputs a bit, one
                // gate: s5267's S.la_addr -> the loop end's compare -> done -> XC.acc[2]; l1 and
                // bad2 go in the gates, early beside the kind bits)
                d_ag1 = (d_l1 ? g1t : g1f) && !bad2;
                d_ag0 = g0 && !bad2;
                x.acc = (d_s3 ? d_kb_i[2:0] : d_kb_o[2:0]) & {3{done ? d_ag1 : d_ag0}};
            end
            d_acc_chk = d_acc_nc & {3{ex}};      // (R1044's form, the bench's check)
        end
        d_acc_ref = (mem_on && !bad && !x.unsup) ? akind : A_NONE;    // (R1028's, for the benches' check)
    end
    x.why = why0; x.dag = dag; x.mbad = mbad;   // (the reason chosen at the capture, R1029)

    // The opcode's reason and the flag again, the condition last (R1029: off D's path from the
    // condition). Each reason of R1028's handler, in its order (the last wins), evaluated for the
    // condition true (u1 / w1) and false (u0 / w0); x.unsup / x.why above are R1028's form of the
    // same, which the benches check this against.
    // R1048: the whole of it for each outcome of the loop end's pop (dn), the pop and then the
    // word's condition choosing last -- done (S's compares) had stood in front of the pointer
    // tests and the reasons' order (s4991: S.daddr -> XC.unsup -0.302)
    begin
        logic       u1, u0, cp1, cp0, dn, pzd, lzd, l7d;
        logic [3:0] w1, w0;
        logic [7:0] u;
        logic [1:0] u1a, u0a;
        logic [1:0][3:0] w1a, w0a;
        for (int dd = 0; dd < 2; dd++) begin
            dn = dd[0];
            lzd = dn ? S.lstkp == 3'd1 : S.lstkp == 3'd0;
            pzd = dn ? S.pcstkp == 6'd1 : S.pcstkp == 6'd0;
            l7d = dn ? S.lstkp == 3'd7 : S.lstkp == 3'd6;
            u1 = 1'b0; u0 = 1'b0; w1 = 4'd0; w0 = 4'd0;
            // the loop end's pops
            if (dn && (S.lstkp == 3'd0 || S.pcstkp == 6'd0)) begin u1 = 1'b1; w1 = U_STK; u0 = 1'b1; w0 = U_STK; end
            // the compute field's condition: true (cp1), false (cp0)
            cp1 = 1'b0; cp0 = 1'b0;
            casez (op[47:39])
            9'b001??????: begin cp1 = 1'b1; cp0 = 1'b1; end            // (R1042: type 1, no condition)
            9'b00000001?: cp1 = 1'b1;
            9'b0100?????, 9'b0101?????: begin
                u = op[30:23]; cp1 = 1'b1;
                if (!ureg_ok(u, !op[31])) begin u1 = 1'b1; w1 = U_UREG; end
                if (pxpm) begin u1 = 1'b1; w1 = U_PM; end
            end
            9'b0110?????: cp1 = 1'b1;
            9'b0111?????: begin
                cp1 = 1'b1;
                if (!ureg_ok(op[43:36], 1'b0) || !ureg_ok(op[30:23], 1'b1)) begin u1 = 1'b1; w1 = U_UREG; end
            end
            9'b1000?????: begin
                if (!shift_ok(op[21:16])) begin u1 = 1'b1; w1 = U_COMP; end
            end
            9'b00000010?: if (!shift_ok(op[21:16])) begin u1 = 1'b1; w1 = U_COMP; end
            9'b00000100?: cp1 = 1'b1;
            9'b000001100, 9'b000001110: begin
                if (op[24]) begin u1 = 1'b1; w1 = U_FORM; end
                if (op[38] && pzd) begin u1 = 1'b1; w1 = U_STK; end
                if (op[38] && lzd) begin u1 = 1'b1; w1 = U_STK; end
            end
            9'b000001101, 9'b000001111: ;
            9'b0000100??: begin
                if (op[24]) begin u1 = 1'b1; w1 = U_FORM; u0 = 1'b1; w0 = U_FORM; end
                if (op[25]) cp0 = 1'b1; else cp1 = 1'b1;
                if (!op[39] && op[38]) begin u1 = 1'b1; w1 = U_STK; end
            end
            9'b11???????: cp0 = 1'b1;
            9'b00001010?, 9'b00001011?: begin
                if (op[40]) begin u1 = 1'b1; w1 = U_FORM; u0 = 1'b1; w0 = U_FORM; end
                if (op[25]) cp0 = 1'b1; else cp1 = 1'b1;
                if (pzd) begin u1 = 1'b1; w1 = U_STK; end
            end
            9'b00001100?, 9'b00001101?, 9'b00001110?: begin
                if (op[42:40] == 3'b101) begin
                    if (dn && op[39:32] == 8'h67) begin u1 = 1'b1; w1 = U_STK; u0 = 1'b1; w0 = U_STK; end
                    if (!ureg_ok(op[39:32], 1'b0)) begin u1 = 1'b1; w1 = U_UREG; u0 = 1'b1; w0 = U_UREG; end
                end
                if (l7d) begin u1 = 1'b1; w1 = U_STK; u0 = 1'b1; w0 = U_STK; end
            end
            9'b00001111?: if (!ureg_ok(op[39:32], 1'b1)) begin u1 = 1'b1; w1 = U_UREG; u0 = 1'b1; w0 = U_UREG; end
            9'b000100???: begin
                if (!ureg_ok(op[39:32], !op[40])) begin u1 = 1'b1; w1 = U_UREG; u0 = 1'b1; w0 = U_UREG; end
                if (pxpm) begin u1 = 1'b1; w1 = U_PM; u0 = 1'b1; w0 = U_PM; end
            end
            9'b101??????: begin
                if (!ureg_ok(op[39:32], !op[40])) begin u1 = 1'b1; w1 = U_UREG; u0 = 1'b1; w0 = U_UREG; end
                if (pxpm) begin u1 = 1'b1; w1 = U_PM; u0 = 1'b1; w0 = U_PM; end
            end
            9'b1001?????: ;
            9'b00010100?: if (!ureg_ok({4'h7, op[35:32]}, 1'b1) || !ureg_ok({4'h7, op[35:32]}, 1'b0) || op[39:37] == 3'd3 || op[39:37] > 3'd5) begin
                u1 = 1'b1; w1 = U_UREG; u0 = 1'b1; w0 = U_UREG; end
            9'b000101100: ;
            9'b00010111?: begin u1 = 1'b1; w1 = U_STK; u0 = 1'b1; w0 = U_STK; end
            9'b000000000: ;
            default: begin u1 = 1'b1; w1 = U_FORM; u0 = 1'b1; w0 = U_FORM; end
            endcase
            // the compute field's (U_COMP, then U_RND: cbad's), where it runs
            if (cbad) begin                     // (R1048: comp_f && comp != 0 && cbad, as rz's)
                logic [3:0] wc;
                wc = (fl_d && !mode1[M1_RND32]) ? U_RND : U_COMP;
                if (cp1) begin u1 = 1'b1; w1 = wc; end
                if (cp0) begin u0 = 1'b1; w0 = wc; end
            end
            u1a[dd] = u1; u0a[dd] = u0; w1a[dd] = w1; w0a[dd] = w0;
        end
        // (an address outside the map, mbad, is XC.mbad: X ORs it in, x_uns -- off this path)
        d_unsup_x = (done ? (d_cok1 ? u1a[1] : u0a[1]) : (d_cok0 ? u1a[0] : u0a[0])) || dag;
        d_why_x = done ? (d_cok1 ? w1a[1] : w0a[1]) : (d_cok0 ? w1a[0] : w0a[0]);
    end

    // the decisions X's first clock makes the sequencer from
    x.le = le; x.done = done; x.cok = cok;
    x.b6 = op[47:42] == 6'b000010 || op[47:46] == 2'b11;
    x.sqc[0] = op[47:39] == 9'b000001100 || op[47:39] == 9'b000001110;
    x.sqc[1] = op[47:39] == 9'b000001101 || op[47:39] == 9'b000001111;
    x.sqc[2] = op[47:41] == 7'b0000100;
    x.sqc[3] = op[47:46] == 2'b11;
    x.sqc[4] = op[47:41] == 7'b0000101;
    x.sqc[5] = op[47:41] == 7'b0000110 || op[47:41] == 7'b0000111 && !op[40];
    x.ind_t = i4_rd + m4_rd;                 // (R1048: type 1's copies)
    // R1044: the next fetch's candidates (X's first clock selects among them, pm_ra), from the
    // opcode and S -- s_x1's own terms: rel_t for each loop-end outcome, rts_v after a pop, tsel
    // one-hot, br's forms (taken on XC.cok) and br_db
    begin
        logic [23:0] off;
        logic [5:0]  pp;
        off = x.b6 ? 24'(sext6(op[32:27])) : op[23:0];
        x.f_reld = PM_AW'(S.daddr + off);
        x.f_relp = PM_AW'(S.pcstk + off);
        pp = S.pcstkp - 6'd1;
        x.f_rts = (pp < 6'd30) ? ((pp != 6'd0) ? pcs_p2[PM_AW-1:0] : {PM_AW{1'b1}}) : S.pcstk[PM_AW-1:0];
        x.f_ts = (x.sqc[0] || x.sqc[1]) ? (op[40] ? 4'b0010 : 4'b0001) :
                 x.sqc[2] ? (op[40] ? 4'b0010 : 4'b0100) :
                 x.sqc[3] ? (op[45] ? 4'b0010 : 4'b0100) : 4'b1000;
        x.f_br = |x.sqc[4:0];
        x.f_db = op[26] && !x.sqc[3];
    end
    // R1044: X's length if the float compute runs (x_need's terms from the opcode alone; a word's
    // float and shifter computes are exclusive -- one compute field)
    x.need_fl = x.fl_misc ? ((x.misc_op >= 5'd12 && x.misc_op <= 5'd17) ? 2'd2 : 2'd0) :
                (x.fl_add || x.fl_sub) ? 2'd1 : 2'd0;

    dx = x;
    dx.unsup = d_unsup_x; dx.why = d_why_x;     // (R1029: the same as x.unsup / x.why, benches check)
    d_unsup_ref = x.unsup; d_why_ref = x.why;
    d_opx = rf_rd[0]; d_opy = rf_rd[1]; d_opn = rf_rd[2];
    // the multifunction's four operands: R0-3, R4-7, R8-11, R12-15 (the ports' addresses, below)
    d_fmx = rf_rd[0]; d_fmy = rf_rd[1];
    if (comp[22]) begin d_fax = rf_rd[2]; d_fay = rf_rd[3]; end
    else begin d_fax = rf_rd[0]; d_fay = rf_rd[1]; end
    // R1048: their zero-exponent tests, each port's before the select
    d_faxz = comp[22] ? rf_rd[2][30:23] == 8'h00 : rf_rd[0][30:23] == 8'h00;
    // R1048: the shifter's field length and decoder bit from D's sh_val (as m2b_sharc_xu makes
    // them from XC.sh_imm ? x_op's immediate : op_y, the values those registers are loaded with)
    // (R1048: for the immediate and for R[ry] apart, the form's sh_imm choosing last -- the decode
    // no longer in front of the clamp)
    begin
        logic [31:0] si, sr;
        logic [5:0]  li, lr, pli, plr;
        logic [4:0]  dji, djr;
        si = {20'h0, op[30:27], op[15:8]}; sr = rf_rd[1];
        li = si[11:6]; lr = sr[11:6];
        pli = (li > 6'd32) ? 6'd32 : li; plr = (lr > 6'd32) ? 6'd32 : lr;
        dji = (x.sh_op[5:4] == 2'b11) ? si[4:0] : 5'(pli - 6'd1);
        djr = (x.sh_op[5:4] == 2'b11) ? sr[4:0] : 5'(plr - 6'd1);
        d_shpl = x.sh_imm ? pli : plr;
        d_shpdj = x.sh_imm ? dji : djr;
    end
    d_fayz = comp[22] ? rf_rd[3][30:23] == 8'h00 : rf_rd[1][30:23] == 8'h00;
    // R1052 (b9857549 again): and their NaN tests, each port's before the select (the shared unit's misc operands)
    d_faxn = comp[22] ? is_nan(rf_rd[2]) : is_nan(rf_rd[0]);
    d_fayn = comp[22] ? is_nan(rf_rd[3]) : is_nan(rf_rd[1]);
    d_stx = x.acc_wd;
    d_dm_a = x.acc_addr[DM_AW-1:0];         // (R1042: a PM-bus block-1 word's, PMB1_MAME's remap)
    // the DM read is presented for any read form, whatever its condition or address (it has no
    // effect but dm_q, which only an A_DM access reads)
    d_dm_rd = mem_f && !mem_wr;
    // R1042: the PM RAM's port B read: type 1's PM move, else the word's one access
    d_pmb = pmb || t1;
    d_pb_a = t1 ? i4_rd[PM_AW-1:0] : mem_a[PM_AW-1:0];   // (R1048: i4, no decode before its read)
end

// the word in X is unsupported: D's reasons, or its data address outside the map (R1029: the
// latter registered apart, XC.mbad, off D's path)
logic x_uns;
assign x_uns = XC.unsup || XC.mbad;

// X's first clock (R1029): the sequencer's next state from S, the word (x_op) and D's
// decisions (XC.le / done / cok), and the stacks' one write each -- exactly R1028's sequencing,
// moved a clock. The next word's fetch is issued from it in the same clock; X's ureg writes to
// PCSTK / CURLCNTR / LCNTR modify it at X's end.
seq_t        s_x1;                          // S after this word (before X's ureg writes)
logic        x1_pcw, x1_lcw, x1_law;
logic [4:0]  x1_pcw_i;
logic [2:0]  x1_lcw_i, x1_law_i;
logic [23:0] x1_pcw_d;
logic [31:0] x1_lcw_d, x1_law_d;
logic        x1_pmbad;                      // the next fetch is outside the PM (U_PM: flagged only)
always_comb begin
    seq_t s;
    logic [47:0] op;
    logic        cok, jdb, la, nlpop;
    logic [1:0]  npop;
    logic [23:0] pc1, rel_t, rts_v, tgt, qb;
    logic        br, br_db;
    logic [1:0]  tsel;
    logic        pcw, lcw, law;
    logic [4:0]  pcw_i;
    logic [2:0]  lcw_i, law_i;
    logic [23:0] pcw_d;
    logic [31:0] lcw_d, law_d;

    op = x_op;
    s = S;
    cok = XC.cok;
    jdb = op[26]; la = op[38];
    npop = 2'd0; nlpop = 1'b0;
    br = 1'b0; br_db = 1'b0; tsel = 2'd0; rts_v = 24'h0;
    pcw = 1'b0; lcw = 1'b0; law = 1'b0;
    pcw_i = 5'h0; lcw_i = 3'h0; law_i = 3'h0; pcw_d = 24'h0; lcw_d = 32'h0; law_d = 32'h0;

    // ---------------------------------------------------------------- the queue shift
    s.pc = S.daddr; s.daddr = S.faddr; s.faddr = S.nfaddr; s.nfaddr = S.nfaddr + 24'd1;

    // ---------------------------------------------------------------- loop end
    if (XC.le) begin
        if (s.la_type != 2'd0) s.curlcntr = s.curlcntr - 32'd1;
        if (XC.done) begin
            // POP_LOOP
            s.lstkp = s.lstkp - 3'd1;
            s.lcntr = s.curlcntr;
            law = 1'b1; law_i = s.lstkp; law_d = la_pack(s.la_type, s.la_code, s.la_addr);
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
            s.pcstkp = s.pcstkp - 6'd1;
            if (s.pcstkp < 6'd30) begin
                pcw = 1'b1; pcw_i = 5'(s.pcstkp); pcw_d = s.pcstk;
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

    // ---------------------------------------------------------------- the handler's sequencing
    pc1 = s.pc;
    // PC + offset: from either PC the loop end leaves, both added (R1029: the select after)
    begin
        logic [23:0] off;
        off = XC.b6 ? 24'(sext6(op[32:27])) : op[23:0];
        rel_t = (XC.le && !XC.done) ? S.pcstk + off : S.daddr + off;
    end

    // (the form from D's one-hot class, R1029: no decode of the opcode on this path)
    case (XC.sqc)                                               // (one-hot: a parallel case)
    6'b000001: begin                                        // direct / relative jump
        if (cok) begin
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd0;
            if (la) begin
                // POP_PC, POP_LOOP
                s.pcstkp = s.pcstkp - 6'd1;
                if (s.pcstkp < 6'd30) begin
                    if (!pcw) begin pcw = 1'b1; pcw_i = 5'(s.pcstkp); pcw_d = s.pcstk; end
                    if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;
                    else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                    s.stk = s.stk & ~PCFL;
                end
                s.lstkp = s.lstkp - 3'd1;
                s.lcntr = s.curlcntr;
                if (!law) begin law = 1'b1; law_i = s.lstkp; law_d = la_pack(s.la_type, s.la_code, s.la_addr); end
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
    6'b000010: begin                                        // direct / relative call
        if (cok) begin
            logic [23:0] ret;
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd0;
            ret = op[40] ? (jdb ? pc1 + 24'd3 : pc1 + 24'd1) : (jdb ? s.nfaddr : s.daddr);
            // PUSH_PC
            if (s.pcstkp != 6'd0 && !pcw) begin pcw = 1'b1; pcw_i = 5'(s.pcstkp - 6'd1); pcw_d = s.pcstk; end
            s.pcstkp = s.pcstkp + 6'd1;
            s.stk = s.stk & ~PCEM;
            if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
            s.pcstk = ret;
        end
    end
    6'b000100: begin                                        // indirect / relative jump or call, compute
        if (cok) begin
            br = 1'b1; br_db = jdb; tsel = op[40] ? 2'd1 : 2'd2;
            if (op[39]) begin
                logic [23:0] ret;
                ret = jdb ? s.nfaddr : s.daddr;
                if (s.pcstkp != 6'd0 && !pcw) begin pcw = 1'b1; pcw_i = 5'(s.pcstkp - 6'd1); pcw_d = s.pcstk; end
                s.pcstkp = s.pcstkp + 6'd1;
                s.stk = s.stk & ~PCEM;
                if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
                s.pcstk = ret;
            end
        end
    end
    6'b001000: begin                                        // indirect / relative jump, else compute, dreg <-> DM
        if (cok) begin br = 1'b1; tsel = op[45] ? 2'd1 : 2'd2; end
    end
    6'b010000: begin                                        // RTS, RTI
        if (cok) begin
            br = 1'b1; br_db = jdb; tsel = 2'd3; rts_v = s.pcstk;
            s.pcstkp = s.pcstkp - 6'd1;
            if (s.pcstkp < 6'd30) begin
                if (!pcw) begin pcw = 1'b1; pcw_i = 5'(s.pcstkp); pcw_d = s.pcstk; end
                if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;
                else begin s.pcstk = 24'hFFFFFF; s.stk = s.stk | PCEM; end
                s.stk = s.stk & ~PCFL;
            end
        end
    end
    6'b100000: begin                                        // DO UNTIL
        if (op[42:40] == 3'b100) s.lcntr = {16'h0, op[39:24]};
        else if (op[42:40] == 3'b101) s.lcntr = XC.acc_wd;     // the ureg D read (wd_sel 1)
        // PUSH_PC
        if (s.pcstkp != 6'd0 && !pcw) begin pcw = 1'b1; pcw_i = 5'(s.pcstkp - 6'd1); pcw_d = s.pcstk; end
        s.pcstkp = s.pcstkp + 6'd1;
        s.stk = s.stk & ~PCEM;
        if (s.pcstkp >= 6'd30) s.stk = s.stk | PCFL;
        // PUSH_LOOP
        if (s.lstkp != 3'd0) begin
            // after a loop-end pop this writes back the word the pop read: dropped (R1028)
            lcw = !nlpop; lcw_i = s.lstkp - 3'd1; lcw_d = s.curlcntr;
            if (!law) begin law = 1'b1; law_i = s.lstkp - 3'd1; law_d = la_pack(s.la_type, s.la_code, s.la_addr); end
        end
        s.curlcntr = s.lcntr;
        s.lstkp = s.lstkp + 3'd1;
        s.lcntr = (s.lstkp < 3'd6) ? (nlpop ? lcs_q0 : lcs_q1) : 32'hFFFF_FFFF;
        s.stk = s.stk & ~LSEM;
        s.pcstk = pc1 + 24'd1;
        s.la_addr = rel_t;
        if (op[42:40] == 3'b110) begin s.la_code = op[37:33]; s.la_type = 2'd0; end
        else begin
            s.la_code = 5'h0f;
            // |offset| 1 or 2 (MAME's loop types)
            s.la_type = (op[23:0] == 24'd1 || op[23:0] == 24'hFFFFFF) ? 2'd1 :
                        (op[23:0] == 24'd2 || op[23:0] == 24'hFFFFFE) ? 2'd2 : 2'd3;
        end
    end
    default: ;
    endcase

    // the queue: a taken branch (after a loop end's CHANGE_PC); delayed, only the fetch after next
    case (tsel)
    2'd0: tgt = op[23:0];
    2'd1: tgt = rel_t;
    2'd2: tgt = XC.ind_t[23:0];
    default: tgt = rts_v;
    endcase
    if (br && !br_db) begin
        qb = tgt; s.pc = qb; s.daddr = qb; s.faddr = qb + 24'd1; s.nfaddr = qb + 24'd2;
    end else if (br) s.nfaddr = tgt;

    // an unsupported word: the queue moves, nothing else
    if (x_uns) begin
        s = S;
        s.pc = S.daddr; s.daddr = S.faddr; s.faddr = S.nfaddr; s.nfaddr = S.nfaddr + 24'd1;
        pcw = 1'b0; lcw = 1'b0; law = 1'b0;
    end
    s_x1 = s;
    x1_pcw = pcw; x1_pcw_i = pcw_i; x1_pcw_d = pcw_d;
    x1_lcw = lcw; x1_lcw_i = lcw_i; x1_lcw_d = lcw_d;
    x1_law = law; x1_law_i = law_i; x1_law_d = law_d;
    // the program memory ends at 2^PM_AW words (the word itself runs; R1027)
    x1_pmbad = !x_uns && (s.daddr < 24'h20000 || s.daddr >= 24'(32'h20000 + PMW));
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
    else if (o[47:45] == 3'b001) rf_ra[4] = o[36:33];          // R1042: type 1's DM store
    else rf_ra[4] = o[35:32];
    // R1042: in X, type 1's PM store register, read before its first pass ends (the word's loads
    // are written at a pass's end, so this is the register as the word found it: MAME's
    // parallel_pm_dreg, the manual's read before write) and kept for the second pass
    if (st == ST_X) rf_ra[4] = x_op[26:23];
end

// the scoreboard: a read port at a register written this clock (the landing's Rm / Ra, a
// deferred write), or ASTAT being landed
logic [15:0] rbusy;                          // (below, after the X unit)
logic        d_hit_ref;                     // benches: R1028's compares
always_comb begin
    logic hit, hr;
    hit = 1'b0; hr = 1'b0;
    for (int p = 0; p < 5; p++) begin
        if (d_ru[p] && rbusy[rf_ra[p]]) hit = 1'b1;
        if (d_ru[p] && ((ld_on && ld_mwe && rf_ra[p] == ld_rm) || (ld_on && ld_awe && rf_ra[p] == ld_ra) ||
                        (rf_pw && rf_ra[p] == rf_pa))) hr = 1'b1;
    end
    d_hit_ref = hr;
    // a landing that writes two R registers: D does not finish in it (the second write is next clock)
    d_wait = hit || (ld_on && d_need_astat) || ir_pw || (ld_on && ld_mwe && ld_awe) || us_pw || (d_urim && !ur_ok);
    if (pm_host && d_pmb) d_wait = 1'b1;    // (R1042: the host's PM write has port B this clock)
end
assign d_go = st == ST_D && !d_wait;

// ================================================================== X

logic        x_done;
logic        x_fin, x_p2go;                 // R1042: the word's end; type 1's second pass begins
logic        x_p2, x_p2w;                   // ... in the second pass; its first clock waits
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
logic [1:0]  xu_mx, xu_sx;
m2b_sharc_xu #(.MAME_RND(MAME_RND), .PRE(1'b1)) u_xu (
    .clk, .fix_on(XC.fix_on), .fix_op(XC.fix_op), .fix_k(XC.fix_k), .sh_on(XC.sh_on), .sh_op(XC.sh_op), .sh_imm(XC.sh_imm),
    .sh_val(XC.sh_imm ? {20'h0, x_op[30:27], x_op[15:8]} : op_y), .pre_l(sh_pl), .pre_dj(sh_pdj), .pre_fxz(fa_xz), .pre_fyz(fa_yz), .pre_fxn(fa_xn), .pre_fyn(fa_yn),
    .misc_on(XC.fl_misc), .misc_op(XC.misc_op),
    .x(op_x), .y(op_y), .n(op_n), .fx(fa_x), .fy(fa_y), .astat, .alusat(mode1[M1_ALUSAT]), .trunc(XC.trunc),
    .fix_r(xu_fr), .sh_r(xu_sr), .fix_we(xu_fw), .sh_we(xu_sw), .fix_astat(xu_fa),
    .sh_astat(xu_sa), .fix_stky(xu_fs), .misc_r(misc_d_r), .misc_a(misc_d_a), .misc_s(misc_d_s), .misc_x(xu_mx), .sh_x(xu_sx));
assign x_fix = {xu_fr, xu_fw, xu_fa, xu_fs};     // xres_t: r, we, astat, stky
assign x_sh = {xu_sr, xu_sw, xu_sa, 32'h0};

// (R1029: the registers written this clock as a 16-bit mask registered the clock before -- at X's
// end the landing's Rm / Ra, at the landing its deferred Ra -- so a read port's test is a lookup)
always_ff @(posedge clk) begin
    if (reset) rbusy <= 16'h0;
    else if (st == ST_X && x_fin) rbusy <=
        ((XC.fl_on && XC.fl_mul && XC.rm_we && !x_uns) ? 16'h1 << XC.rm : 16'h0) |
        ((((XC.fl_on && (XC.fl_add || XC.fl_sub || XC.fl_misc) && XC.ra_we) ||
           (((XC.fix_on && XC.fix_wr) || (XC.sh_on && x_sh.we)) && XC.rn_we)) && !x_uns) ? 16'h1 << (XC.fl_on ? XC.ra : XC.rn) : 16'h0);
    else if (ld_on && ld_mwe && ld_awe) rbusy <= 16'h1 << ld_ra;
    else rbusy <= 16'h0;
end

// the float units: operands from D; the multiplier's stage 1 at X's end, the adder's stages 1
// and 2a at every X clock (R1029: an add's X is two clocks); results in the landing clock
logic fl_en, fm_restart;
assign fl_en = st == ST_X && x_fin;
sharc_fadd #(.MAME_RND(MAME_RND), .PRE(1'b1)) u_fadd (
    .clk, .en(st == ST_X), .x(fa_x), .y(fa_y), .xz(fa_xz), .yz(fa_yz), .sub(XC.fl_sub), .avg(XC.fl_avg), .trunc(XC.trunc),
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
    A_PM:  begin x_ld = pmb_q; x_ldv = !XC.acc_wr; end    // (R1042: read on port B in D)
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
// X's length (R1029): one clock, two for a float add (the adder's stage 2a) and a shift (its
// funnel), three for FIX and FLOAT (m2b_sharc_xu's stages); an external access is requested in
// the last
logic [1:0] x_cnt, x_need;
// (R1044: from D's registers, XC.need_fl, not through the misc unit's decode; the old form is
// the benches' check)
assign x_need = XC.fl_on ? XC.need_fl : XC.sh_on ? 2'd1 : 2'd0;
generate if (BENCH) begin : g_fixwr_check
    always_ff @(posedge clk) if (st == ST_X && XC.fix_on && XC.fix_wr != xu_fw) $fatal(1, "fix_wr %b, the unit's %b", XC.fix_wr, xu_fw);
end endgenerate
generate if (BENCH) begin : g_need_check
    always_ff @(posedge clk) if (st == ST_X && x_need != ((XC.fl_on && XC.fl_misc) ? xu_mx :
                                 (XC.fl_on && (XC.fl_add || XC.fl_sub)) || XC.sh_on ? 2'd1 : 2'd0))
        $fatal(1, "x_need %d, the misc unit's form differs", x_need);
end endgenerate
assign x_done = st == ST_X && x_cnt >= x_need && !x_ext_wait && !(XC.fl_on && XC.fl_mul && fm_busy) && !x_p2w;
// R1042: x_done ends an access (a pass); x_fin the word. A type-1 word's first pass (its DM move)
// is followed by a second (its PM move, XC.acc2), unless the word is unsupported
assign x_p2go = x_done && XC.dual && !x_p2 && !x_uns;
assign x_fin = x_done && !x_p2go;
// (R1031: not while MAME's slow multiply holds X -- an acknowledge in those clocks would clear
// x_ext_on without finishing the word; MAME_RND 0 has no slow path)
assign ext_req = st == ST_X && XC.acc == A_EXT && x_ext_on && x_cnt >= x_need && !(XC.fl_on && XC.fl_mul && fm_busy) && !x_p2w;
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
    if (XC.uw && !x_uns) begin xu_w = 1'b1; xu_r = XC.uw_reg; xu_v = XC.acc_wd; end
end
// R1048: xu_v != 0 (an L register's "nonzero" flag, lnz) with each source's own zero test first and
// the access kind's select after -- not one 32-bit test after x_ld's and xu_v's selects. The same
// value wherever xu_w is set (the only clock lnz is written)
logic xu_vnz;
always_comb begin
    logic nz_ld;
    case (XC.acc)
    A_DM:    nz_ld = dm_q != 32'h0;
    A_PM:    nz_ld = pmb_q != 32'h0;
    A_FIN:   nz_ld = fin_data != 32'h0;
    A_EXT:   nz_ld = ext_rdata != 32'h0;
    default: nz_ld = 1'b0;                  // (A_IOP's x_ld is 0; the others load nothing)
    endcase
    xu_vnz = (XC.uw && !x_uns) ? XC.acc_wd != 32'h0 : nz_ld;
end
generate if (BENCH) begin : g_pre_check
    always_ff @(posedge clk) if (st == ST_X && (fa_xz != (fa_x[30:23] == 8'h00) || fa_yz != (fa_y[30:23] == 8'h00)))
        $fatal(1, "fadd zero tests %b %b", fa_xz, fa_yz);
    always_ff @(posedge clk) if (st == ST_X && (fa_xn != is_nan(fa_x) || fa_yn != is_nan(fa_y)))
        $fatal(1, "the misc unit's NaN tests %b %b", fa_xn, fa_yn);
    always_ff @(posedge clk) if (st == ST_X && XC.sh_on) begin : chk_sh
        logic [31:0] sv;
        logic [5:0]  l;
        sv = XC.sh_imm ? {20'h0, x_op[30:27], x_op[15:8]} : op_y;
        l = (sv[11:6] > 6'd32) ? 6'd32 : sv[11:6];
        if (sh_pl != l || sh_pdj != ((XC.sh_op[5:4] == 2'b11) ? sv[4:0] : 5'(l - 6'd1)))
            $fatal(1, "shifter field %d / %d", sh_pl, sh_pdj);
    end
end endgenerate
generate if (BENCH) begin : g_vnz_check
    always_ff @(posedge clk) if (st == ST_X && xu_w && xu_vnz != (xu_v != 32'h0)) $fatal(1, "xu_v's zero test %b", xu_vnz);
end endgenerate

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

// the R file's write port: in X a load / ureg move's (R1029: the compute results all land);
// otherwise the landing's, or its deferred second (Ra after Rm). The selects are registers.
logic rx_l;
always_comb begin
    logic sx, x_aw, s_xa, s_xl, s_pd, s_fm, s_ra;
    rx_l = st == ST_X && x_done && ((XC.ld_r && x_ldv) || (xu_w && xu_r[7:4] == 4'h0));
    if (st == ST_X) begin
        rf_we = rx_l; rf_wa = XC.ld_r ? XC.ld_dst : xu_r[3:0];
    end else if (rf_pw) begin
        rf_we = 1'b1; rf_wa = rf_pa;
    end else begin
        rf_we = ld_on && (ld_mwe || ld_awe); rf_wa = ld_mwe ? ld_rm : ld_ra;
    end
    // R1044: the data as one AND-OR, its five selects from registers beside the data, so the
    // multiplier's and the adder's results are one level from the write port. Where X writes,
    // the value is xu_v's (a ureg move's XC.acc_wd) or x_ld's (a load, to R or through the ureg
    // port): (XC.ld_r ? x_ld : xu_v) wherever rf_we is set in X
    sx = st == ST_X;
    x_aw = XC.uw && !x_uns && !XC.ld_r;
    s_xa = sx && x_aw;
    s_xl = sx && !x_aw;
    s_pd = !sx && rf_pw;
    s_fm = !sx && !rf_pw && ld_mwe;
    s_ra = !sx && !rf_pw && !ld_mwe;
    rf_wd = ({32{s_fm}} & fm_r) | ({32{s_ra}} & ld_rav) |
            ({32{s_xa}} & XC.acc_wd) | ({32{s_xl}} & x_ld) | ({32{s_pd}} & rf_pd);
end
always_ff @(posedge clk) begin
    // the second write: the landing's Ra after its Rm (MAME's order: the later wins a register
    // both write)
    rf_pw <= !reset && ld_on && ld_mwe && ld_awe;
    rf_pl <= ld_on && ld_mwe && ld_awe;
    rf_pa <= ld_ra; rf_pd <= ld_rav;
end
genvar gp;                                  // (Quartus 17: not in the for)
generate for (gp = 0; gp < 5; gp++) begin : g_rf
    m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u (.clk, .we(rf_we), .wa(rf_wa), .wd(rf_wd), .ra(rf_ra[gp]), .rd(rf_rd[gp]));
end endgenerate

// I / M: D's read addresses from the opcode alone
always_comb begin
    logic [47:0] o;
    logic        modf, modi, pg;
    o = pm_q;
    modf = o[47:40] == 8'b00000100;            // compute, modify
    modi = o[47:39] == 9'b000101100;           // modify by an immediate
    // R1029: DAG1's copies read the opcode's fields with no select (the data address's path);
    // the modify forms read their I / M (either DAG, op[38]) on DAG2's copies
    // (gated by D: an address straight from pm_q is taken into the MLAB as its read-address
    // register, which leaves the M10K without its output register -- PM's upper lane was then
    // built in flip-flops, R1029)
    // R1042: a PM-bus access (one move, not type 1's) reads DAG2's I / M on these copies: the
    // opcode's g bit is the address's bit 3
    pg = (o[47:45] == 3'b010 && o[32]) || (o[47:44] == 4'b0110 && o[40]) || (o[47:44] == 4'b1000 && o[32]) ||
         (o[47:45] == 3'b101 && o[44]) || (o[47:44] == 4'b1001 && o[37]);
    // (R1044: bit 3 fixed in each copy, the g bit choosing after the read: i1x_rd / m1x_rd)
    i1_ra = (st == ST_D) ? {1'b0, o[43:41]} : 4'd0;
    i3_ra = (st == ST_D) ? {1'b1, o[43:41]} : 4'd8;
    i2_ra = {(modf || modi) ? o[38] : 1'b1, modi ? o[34:32] : o[32:30]};
    m1_ra = (st == ST_D) ? {1'b0, o[40:38]} : 4'd0;
    m3_ra = (st == ST_D) ? {1'b1, o[40:38]} : 4'd8;
    d_pg = pg;
    i1x_rd = pg ? i3_rd : i1_rd;
    m1x_rd = pg ? m3_rd : m1_rd;
    m2_ra = {modf ? o[38] : 1'b1, o[29:27]};
    // R1048: type 1's I8-15 / M8-15 (op[32:30] / op[29:27]) on their own copies, the fields with
    // no decode (R1042 read them on DAG2's copies, behind the modify forms' compares)
    i4_ra = (st == ST_D) ? {1'b1, o[32:30]} : 4'd8;
    m4_ra = (st == ST_D) ? {1'b1, o[29:27]} : 4'd8;
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
    // R1042: type 1's second pass post-modifies DAG2's I (op[32:30]) by D's I + M (XC.ind_t)
    if (x_p2) begin ir_wa = {1'b1, x_op[32:30]}; ir_wd = XC.ind_t; end
    if (ir_pw) begin ir_we = 1'b1; ir_wa = ir_pa; ir_wd = ir_pd; end
    else if (xdone && XC.pmod && !x_uns) ir_we = 1'b1;
    else if (xdone && xi_u) begin ir_we = 1'b1; ir_wa = iu; ir_wd = xu_v; end
    mr_we = xdone && xu_w && xu_r[7:4] == 4'h2;
    mr_wa = {xu_r[3], xu_r[2:0]};
    mr_wd = xu_v;
end
always_ff @(posedge clk) begin
    ir_pw <= !reset && st == ST_X && x_done && XC.pmod && !x_uns && xu_w && (xu_r[7:4] == 4'h1 || xu_r[7:4] == 4'h4) &&
             {xu_r[3], xu_r[2:0]} != XC.pmod_i;
    ir_pa <= {xu_r[3], xu_r[2:0]};
    ir_pd <= xu_v;
end
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i1 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(i1_ra), .rd(i1_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i2 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(i2_ra), .rd(i2_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i3 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(i3_ra), .rd(i3_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_i4 (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(i4_ra), .rd(i4_rd));
// the ureg port's I / M copies read at last clock's ureg field (R1029: a register, off the
// opcode's path); a word reading I or M through it waits in D until that is its own (ur_ok: the
// clock before was this word's D, or an X clock after the first, when pm_q is already this word)
logic [3:0] ur_aq;
logic       ur_ok;
always_ff @(posedge clk) begin
    ur_aq <= ur_sel[3:0];
    ur_ok <= st == ST_D || (st == ST_X && !x_first);
end
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_iu (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(ur_aq), .rd(iu_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m1 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(m1_ra), .rd(m1_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m2 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(m2_ra), .rd(m2_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m3 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(m3_ra), .rd(m3_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_m4 (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(m4_ra), .rd(m4_rd));
m2b_lutram #(.AW(4), .DW(32), .INIT1(RF_ONES)) u_mu (.clk, .we(mr_we), .wa(mr_wa), .wd(mr_wd), .ra(ur_aq), .rd(mu_rd));

// the system register bit operation: on the register's value (read in D; ASTAT and STKY now,
// a landing may have changed them since -- a bit operation word has no compute of its own)
logic [31:0] xb_v;
logic        xb_t, xb_btf;
always_comb begin
    logic [31:0] d;
    if (XC.bit_reg == 4'hc) xb_v = sys_rd(4'hc, astat, mode1, mode2, stky_rd, irptl, imask, ustat1, ustat2, flg);
    else if (XC.bit_reg == 4'he) xb_v = stky_rd;
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
logic       ux_go;                          // X's end finds the word unsupported (its own reasons)
logic [3:0] ux_why;
always_comb begin
    logic iop_w, iop_r;
    iop_w = XC.acc == A_IOP && XC.acc_wr;
    iop_r = XC.acc == A_IOP && !XC.acc_wr;
    ux_go = 1'b0; ux_why = U_MODE;
    if (st == ST_X && x_done) begin
        if ((xu_w && !XC.bitop && xu_r == 8'h7b && ((xu_v ^ mode1) & M1_SWAPS) != 0) ||
            (XC.bitop && XC.bit_reg == 4'hb && ((xb_v ^ mode1) & M1_SWAPS) != 0)) begin ux_go = 1'b1; ux_why = U_MODE; end
        if ((iop_w && XC.acc_addr[7:0] == 8'h1c && XC.acc_wd[0]) || (iop_w && !iop_known(XC.acc_addr[7:0])) ||
            (iop_r && XC.acc_addr[7:0] != 8'h00 && XC.acc_addr[7:0] != 8'h37)) begin ux_go = 1'b1; ux_why = U_IOP; end
    end
end
// the capture a clock later, from registers (R1029: off the paths it ends), of the word still
// in x_pc / x_op (the next D's end replaces them): D's reason first (MAME's order there: a DAG's,
// a data address's, the opcode's), then the PM bound X's first clock found, then X's end's own
logic       uc_v, uc_u, uc_pm, uc_x;
logic [3:0] uc_xwhy;
always_ff @(posedge clk) begin
    uc_v <= !reset && st == ST_X;
    uc_u <= x_uns;
    uc_pm <= x_first ? x1_pmbad : x_pmbad;
    uc_x <= ux_go; uc_xwhy <= ux_why;
    if (reset) unsup <= 1'b0;
    else if (uc_v && !unsup && (uc_u || uc_pm || uc_x)) begin
        unsup <= 1'b1; unsup_pc <= x_pc; unsup_op <= x_op;
        unsup_why <= uc_u ? (XC.dag ? U_DAG : XC.mbad ? U_MEM : XC.why) : uc_pm ? U_PM : uc_xwhy;
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
        ld_on <= 1'b0;
        dbg_ret <= 1'b0;
        x_ext_on <= 1'b0;
        us_pw <= 1'b0;
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
            // a fixed / shifter word's ASTAT, made in X from ASTAT then (nothing changes it between)
            if (ld_fix) begin
                a = misc_a; k = k | misc_s;
                // a written fixed result's AN / AZ, from the result (R1029: off X's path)
                if (ld_fz) begin
                    if (misc_r[31]) a = a | AN;
                    if (misc_r == 32'h0) a = a | AZ;
                end
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
        ST_D: begin
            // loaded in every D clock (R1029: not on d_go, a late enable); the last, d_go's, stays
            XC <= dx;
            x_op <= pm_q;
            x_pc <= S.daddr;
            op_x <= d_opx; op_y <= d_opy; op_n <= d_opn;
            fa_x <= d_fax; fa_y <= d_fay; fm_x <= d_fmx; fm_y <= d_fmy;
            fa_xz <= d_faxz; fa_yz <= d_fayz;   // (R1048)
            fa_xn <= d_faxn; fa_yn <= d_fayn;
            sh_pl <= d_shpl; sh_pdj <= d_shpdj;
            // (R1029: in every D clock, not on d_go)
            fm_restart <= 1'b1;
            x_ext_on <= 1'b1;
            if (d_go) st <= ST_X;
        end
        ST_X: begin
            if (x_ext_on && ext_ack && XC.acc == A_EXT) x_ext_on <= 1'b0;
            // the misc / fixed / shifter result for the landing: loaded in every X clock (R1044:
            // not on x_fin, off its path), so it holds X's last clock's -- x_fin's -- value; only
            // the landing (the clock after x_fin, never an X clock) reads misc_r / misc_a / misc_s
            if (XC.fl_misc) begin misc_r <= misc_d_r; misc_a <= misc_d_a; misc_s <= misc_d_s; end
            else if (XC.fix_on) begin misc_r <= x_fix.r; misc_a <= x_fix.astat; misc_s <= x_fix.stky; end
            else begin misc_r <= x_sh.r; misc_a <= x_sh.astat; misc_s <= 32'h0; end
            // an unsupported word (D's, or X's own below): one capture, of the word in X
            if (x_first && !x_fin) begin S <= s_x1; end   // (X's end below otherwise)
            // R1042: type 1's second pass, its PM move: the access fields from XC.acc2, the store
            // data the register read in the first (port E at x_op[26:23]); a DM-RAM read or an
            // external access first waits a clock (x_p2w: the read issued; the request dropped once)
            if (x_p2go) begin
                XC.acc <= XC.acc2; XC.acc_wr <= XC.acc2_wr; XC.acc_addr <= {8'h0, XC.acc2_a};
                XC.acc_wd <= rf_rd[4];
                XC.ld_r <= XC.ld2_r; XC.ld_dst <= XC.ld2_dst;
                x_ext_on <= 1'b1;
            end
            if (x_fin) begin
                logic [31:0] a, k, uv;
                logic        uw;
                logic [7:0]  ur;
                seq_t sq;
                a = astat; k = stky;
                // the sequencer from X's first clock (R1029); a ureg write to PCSTK / CURLCNTR /
                // LCNTR modifies S in the next clock (us_pw), D waiting for it
                sq = x_first ? s_x1 : S;
                // the fixed / shifter result
                // (the fixed / shifter result and flags land next clock, R1029)
                // loads and ureg moves
                uw = 1'b0; ur = 8'h0; uv = 32'h0;
                uw = xu_w; ur = xu_r; uv = xu_v;
                // the system-register bit operation, on the register's value now
                if (XC.bitop && !x_uns) begin
                    if (xb_t) a = xb_btf ? (a | BTF) : (a & ~BTF);
                    uw = 1'b1; ur = {4'h7, XC.bit_reg}; uv = xb_v;
                end
                us_pw <= uw && ur[7:4] == 4'h6 && (ur[3:0] == 4'h4 || ur[3:0] == 4'h7 || ur[3:0] == 4'h8);
                us_pr <= ur[3:0]; us_pv <= uv;
                // post-modify: after the load (a load to the same I is modified)
                ld_ua <= 1'b0; ld_us <= 1'b0; ld_uv <= uv;
                if (uw) begin
                    logic [2:0] kk;
                    kk = ur[2:0];
                    case (ur[7:4])
                    4'h0: ;                                 // R: the write port (rf_we)
                    4'h1, 4'h2: ;                           // I, M: the write ports (ir_we, mr_we)
                    4'h3: lnz[{ur[3], kk}] <= xu_vnz;   // (R1048: uv is xu_v here -- a bit operation names 0x7x)
                    4'h4: ;                                 // B: I = B (B itself is not kept; ir_we)
                    4'h6: ;                                 // PCSTK / CURLCNTR / LCNTR: below
                    4'h7: case (ur[3:0])
                          4'h0: ustat1 <= uv;
                          4'h1: ustat2 <= uv;
                          4'h9: irptl <= uv;
                          4'ha: mode2 <= uv;
                          4'hb: begin
                              mode1 <= uv;
                          end
                          4'hc: if (XC.fl_on || XC.fix_on || XC.sh_on) begin ld_ua <= 1'b1; end   // (a: below, R1048)
                          4'hd: if (PXIM) imask <= uv;
                          4'he: if (XC.fl_on || XC.fix_on || XC.sh_on) begin ld_us <= 1'b1; end else k = (k & STK_BITS) | (uv & ~STK_BITS);
                          default: ;
                          endcase
                    4'hd: case (ur[3:0])
                          4'hc: if (PXIM) px <= {px[47:16], uv[15:0]};
                          4'hd: if (PXIM) px <= {uv, px[15:0]};
                          4'hb: if (PXIM) px <= {px[47:32], uv};
                          default: ;
                          endcase
                    default: ;
                    endcase
                end
                // R1048: ASTAT written by this word's bit operation / ureg move / load -- the same as
                // uw && ur == 0x7c above, from D's decodes (ld_ast / uw_ast) and the bit operation's
                // register, not through ur's select and decode
                begin
                    logic as;
                    as = (XC.bitop && !x_uns) ? XC.bit_reg == 4'hc : (XC.uw && !x_uns) ? XC.uw_ast : (XC.ld_u && x_ldv && XC.ld_ast);
                    if (BENCH && as != (uw && ur == 8'h7c)) $fatal(1, "ASTAT write %b, ur's %b", as, uw && ur == 8'h7c);
                    if (as && !(XC.fl_on || XC.fix_on || XC.sh_on)) a = uv;
                end
                // the sequencer and STKY's stack bits
                S <= sq;
                if (BENCH) S_dbg <= sq;                 // the benches' view: S after this word
                k = (k & ~STK_BITS) | (sq.stk & STK_BITS);
                astat <= a; stky <= k;
                // the float landing next clock
                // the landing next clock: float results, and (R1029) the fixed / shifter result
                // with its flags, through misc_r / misc_a / misc_s; none for an unsupported word
                ld_on <= 1'b1;
                ld_mwe <= XC.fl_on && XC.fl_mul && XC.rm_we && !x_uns;
                ld_awe <= ((XC.fl_on && (XC.fl_add || XC.fl_sub || XC.fl_misc) && XC.ra_we) ||
                           (((XC.fix_on && XC.fix_wr) || (XC.sh_on && x_sh.we)) && XC.rn_we)) && !x_uns;
                ld_rm <= XC.rm; ld_ra <= XC.fl_on ? XC.ra : XC.rn;
                ld_mul <= XC.fl_on && XC.fl_mul && !x_uns;
                ld_alu <= XC.fl_on && (XC.fl_add || XC.fl_sub || XC.fl_misc) && !x_uns;
                ld_fix <= (XC.fix_on || XC.sh_on) && !x_uns;
                ld_fz <= XC.fix_on && XC.fix_wr;
                ld_misc <= XC.fl_misc || XC.fix_on || XC.sh_on;
                ld_absf <= XC.fl_absf;
                ld_comp <= XC.fl_comp;
                if (BENCH) begin dbg_pc <= x_pc; dbg_op <= x_op; end   // the benches' only
                st <= ST_D;
            end
            // the accesses' writes: an IOP register (R1042: at its pass's end, type 1's DM move)
            if (x_done && XC.acc == A_IOP && XC.acc_wr) begin
                case (XC.acc_addr[7:0])
                8'h00: syscon <= XC.acc_wd;
                8'h02, 8'h08, 8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f, 8'h14, 8'h17, 8'h20: ;
                8'h40: ii6 <= XC.acc_wd;
                8'h41: im6 <= XC.acc_wd;
                8'h1c: dmac6 <= XC.acc_wd;
                default: ;
                endcase
            end
        end
        default: st <= ST_HALT;
        endcase

        // a ureg write to the sequencer, the clock after X (R1029: off X's path into S)
        if (us_pw) begin
            seq_t sw;
            sw = S;
            case (us_pr)
            4'h4: if (sw.pcstkp != 6'd0 && sw.pcstkp < 6'd31) sw.pcstk = us_pv[23:0];
            4'h7: if (sw.lstkp != 3'd0 && sw.lstkp < 3'd7) sw.curlcntr = us_pv;
            default: if (sw.lstkp < 3'd6) sw.lcntr = us_pv;
            endcase
            S <= sw;
            if (BENCH) S_dbg <= sw;
            us_pw <= 1'b0;
        end

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
// R1048: REGISTERED ONCE ON THIS SIDE (hq_*): the request -- lane, address, data -- is made from
// the host's strobes as before, and the RAM is written the clock after. The host's strobes come
// from the i960 bridge's decode across the chip, and their path into the PM RAM's 48 addresses
// was the SHARC's worst cross-block one (2b-place s5181 / s5141). Nothing can see the clock: the
// host writes PM only while the SHARC is in HALT and its clear is over (the upload, and the IOP
// window's EPB0 words, are made before copro_boot) -- g_hq_check asserts both at every request
// -- so no fetch, port-B read or D wait meets a pending word, and the index registers (ii6,
// epb_shift) still step on the request's clock. There is no host read of PM.
logic [2:0]       hr_we, hq_we = 3'b000;
logic [PM_AW-1:0] hr_wa, hq_wa;
logic [15:0]      hr_wd, hq_wd;
always_comb begin
    logic [1:0] w;
    logic       en;
    logic [31:0] idx;
    en = 1'b0; w = 2'd0;
    hr_wd = 16'h0;
    if (xdma_we) begin en = 1'b1; w = xdma_phase; hr_wd = xdma_data; end
    else if (host_iop_we && host_iop_reg == 8'h04) begin en = 1'b1; w = epb_shift; hr_wd = host_iop_data[15:0]; end
    if (dmac6[8]) w = 2'd2 - w;
    idx = (ii6 & 32'h1FFFF) | 32'h20000;
    hr_wa = PM_AW'(idx - 32'h20000);
    hr_we = (en && dmac6[7:6] == 2'd2 && idx < 32'h20000 + PMW) ? 3'b001 << w : 3'b000;
end
always_ff @(posedge clk) begin hq_we <= hr_we; hq_wa <= hr_wa; hq_wd <= hr_wd; end
generate if (BENCH) begin : g_hq_check
    always_ff @(posedge clk) if (hr_we != 3'b000 && (st != ST_HALT || clr_on || run))
        $fatal(1, "a host PM write outside HALT / during the clear / with run (st %0d clr %b run %b)", st, clr_on, run);
    always_ff @(posedge clk) if (hq_we != 3'b000 && (st != ST_HALT || clr_on))
        $fatal(1, "the registered host PM write lands outside HALT (st %0d clr %b)", st, clr_on);
end endgenerate
always_comb begin
    logic [31:0] idx;
    idx = (ii6 & 32'h1FFFF) | 32'h20000;
    pm_wd = hq_wd;
    pm_wa = hq_wa;
    pm_we = hq_we;
    if (hq_we == 3'b000 && clr_on && clr_n < PMW) begin pm_we = 3'b111; pm_wa = clr_n[PM_AW-1:0]; pm_wd = 16'h0; end
    // R1042: port B's other users, after the host's: a PM-bus store at its pass's end (lanes 2:1,
    // bits 47:16; lane 0 kept, as MAME's mask); the word a PM-bus access names, read in every D
    // clock (D's address) and every X clock (the word's own: its one access's, or type 1's second),
    // so pmb_q holds the word through X. The host's write has the port: D waits (d_wait); a host
    // write while a word is in X is not arbitrated (the upload is made with the SHARC halted)
    pm_host = pm_we != 3'b000;
    pm_ha = pm_wa; pm_hidx = PM_AW'(idx - 32'h20000);
    pm_wd2 = {pm_wd, pm_wd};
    if (!pm_host) begin
        if (st == ST_X && x_done && XC.acc == A_PM && XC.acc_wr) begin
            pm_we = 3'b110; pm_wa = XC.acc_addr[PM_AW-1:0]; pm_wd2 = XC.acc_wd;
        end else if (st == ST_D) pm_wa = d_pb_a;
        else if (st == ST_X) pm_wa = (XC.dual && !x_p2) ? XC.acc2_a[PM_AW-1:0] : XC.acc_addr[PM_AW-1:0];
    end
end

// R1048: THE DM RAM's ADDRESS, ONE ADDER PER LANE WITH THE STATE's CHOICE IN ITS OPERANDS. dm_a
// was the D address (mem_a's low bits, through the access decode's x.acc_addr) or X's / the
// clear's, selected after the adder -- a LUT and a hop between the carry chain and 32 M10K. Here
// in D the operands are mem_a's own ({!sd} & I) and off, and otherwise the X / clear address and
// 0, so the sum is the address and goes straight to the RAM. Outside D, X and the clear dm_en is
// low and the address unused. The same bits: mem_a's low DM_AW (x.acc_addr's, PMB1_MAME off), as
// g_dma_check checks at every enabled clock.
logic [DM_AW-1:0] dm_as [2];
(* keep *) logic [DM_AW-1:0] dm_ia [2], dm_ob [2];   // (kept per lane: two adders, 16 M10K each)
logic [DM_AW-1:0] dm_xa;
logic             dm_dsel;
// ... and the PM RAM's port B the same way, one adder per lane: in D the operands are d_pb_a's
// (type 1: i4 and 0; else mem_a's), in X the access's address and 0, otherwise the host window's
// index and 0; the host's / the clear's write (pm_host) chooses after the adder, as before
(* keep *) logic [PM_AW-1:0] pm_ia [3], pm_ob [3];
logic [PM_AW-1:0] pm_cs [3], pm_xa;
always_comb begin
    logic [47:0] o;
    logic        s1, s2, s3, sd, t1;
    o = pm_q;
    s1 = o[47:45] == 3'b010 && !o[44];
    s2 = o[47:44] == 4'b0110 && !o[38];
    sd = o[47:42] == 6'b000100;
    s3 = sd || o[47:45] == 3'b101;
    dm_dsel = st == ST_D && !clr_on;
    dm_xa = clr_on ? clr_n[DM_AW-1:0] : XC.acc_addr[DM_AW-1:0];
    t1 = o[47:45] == 3'b001;
    // (X: the old select's store term, x_done && A_PM && write -> XC.acc_addr, is the same address
    // -- a PM-bus store is never type 1's first pass, whose access is the DM move's (dm_kind:
    // never A_PM) -- so x_done stays off the address; the bench check below compares every clock)
    pm_xa = (XC.dual && !x_p2) ? XC.acc2_a[PM_AW-1:0] : XC.acc_addr[PM_AW-1:0];
    for (int k = 0; k < 3; k++) begin
        // (R1048: the host's / the clear's write -- registered since 4b0dc9e8, so pm_host is
        // early -- chooses in the operands too: its address and 0; the sum goes to the RAM)
        pm_ia[k] = pm_host ? pm_ha :
                   (st == ST_D) ? (t1 ? i4_rd[PM_AW-1:0] : ({PM_AW{!sd}} & (d_pg ? i3_rd[PM_AW-1:0] : i1_rd[PM_AW-1:0]))) :
                   (st == ST_X) ? pm_xa : pm_hidx;
        pm_ob[k] = ({PM_AW{!pm_host && st == ST_D && !t1 && s1 && !d_pg}} & m1_rd[PM_AW-1:0]) | ({PM_AW{!pm_host && st == ST_D && !t1 && s1 && d_pg}} & m3_rd[PM_AW-1:0]) |
                   ({PM_AW{!pm_host && st == ST_D && !t1 && s2}} & PM_AW'(sext6(o[32:27]))) | ({PM_AW{!pm_host && st == ST_D && !t1 && s3}} & o[PM_AW-1:0]);
        pm_cs[k] = pm_ia[k] + pm_ob[k];
        pm_wb[k] = pm_cs[k];
    end
    for (int k = 0; k < 2; k++) begin
        dm_ia[k] = dm_dsel ? ({DM_AW{!sd}} & (d_pg ? i3_rd[DM_AW-1:0] : i1_rd[DM_AW-1:0])) : dm_xa;
        dm_ob[k] = ({DM_AW{dm_dsel && s1 && !d_pg}} & m1_rd[DM_AW-1:0]) | ({DM_AW{dm_dsel && s1 && d_pg}} & m3_rd[DM_AW-1:0]) |
                   ({DM_AW{dm_dsel && s2}} & DM_AW'(sext6(o[32:27]))) | ({DM_AW{dm_dsel && s3}} & o[DM_AW-1:0]);
        dm_as[k] = dm_ia[k] + dm_ob[k];
    end
end
generate if (BENCH && !PMB1_MAME) begin : g_dma_check
    always_ff @(posedge clk) if (dm_en && (dm_as[0] != dm_a || dm_as[1] != dm_a)) $fatal(1, "DM address %h %h, the select's %h", dm_as[0], dm_as[1], dm_a);
    always_ff @(posedge clk) if (pm_wb[0] != pm_wa || pm_wb[1] != pm_wa || pm_wb[2] != pm_wa) $fatal(1, "PM port B %h %h %h, the select's %h", pm_wb[0], pm_wb[1], pm_wb[2], pm_wa);
end endgenerate

// DM: the read address in D, the write at X's end
always_comb begin
    dm_en = 1'b0; dm_we = 1'b0; dm_wd = XC.acc_wd;
    // the address by state alone (R1029: no decode before the M10K's address register)
    dm_a = clr_on ? clr_n[DM_AW-1:0] : (st == ST_X) ? XC.acc_addr[DM_AW-1:0] : d_dm_a;
    // R1048: each lane's address its own sum, the D / X / clear choice made in the adder's
    // operands (dm_ao), not after it; PMB1_MAME (benches) keeps the select after the remap
    dm_a0 = PMB1_MAME ? (clr_on ? clr_n[DM_AW-1:0] : (st == ST_X) ? XC.acc_addr[DM_AW-1:0] : d_dm_a) : dm_as[0];
    dm_a1 = PMB1_MAME ? (clr_on ? clr_n[DM_AW-1:0] : (st == ST_X) ? XC.acc_addr[DM_AW-1:0] : d_dm_a) : dm_as[1];
    if (clr_on) begin dm_en = clr_n < DMW; dm_we = 1'b1; dm_wd = 32'h0; end
    // R1044: the read in EVERY D clock, whatever the word (the last stays): only an A_DM read
    // access reads dm_q, in X, and its value then is the last D clock's read at d_dm_a, as before;
    // in any other word dm_q is never read, so the enable leaves the opcode's path
    else if (st == ST_D) dm_en = 1'b1;
    else if (st == ST_X && x_done && XC.acc == A_DM && XC.acc_wr) begin dm_en = 1'b1; dm_we = 1'b1; end
    else if (st == ST_X && x_p2w && XC.acc == A_DM) dm_en = 1'b1;          // (R1042: type 1's second read)
end

// X's first clock; the PM bound found in it, held for X's later clocks
always_ff @(posedge clk) begin
    x_first <= d_go;
    // R1042: type 1's second pass; its first clock waits for a DM-RAM read or before an
    // external request (m2b_xbus takes a new request after the last one falls)
    if (reset || st != ST_X) begin x_p2 <= 1'b0; x_p2w <= 1'b0; end
    else begin
        x_p2w <= 1'b0;
        if (x_p2go) begin
            x_p2 <= 1'b1;
            x_p2w <= (XC.acc2 == A_DM && !XC.acc2_wr) || XC.acc2 == A_EXT;
        end
    end
    if (st != ST_X) x_cnt <= 2'd0;                      // (R1029: in every D clock, not on d_go)
    else if (x_cnt != 2'd3) x_cnt <= x_cnt + 2'd1;
    if (x_first) x_pmbad <= x1_pmbad;
end

// the stacks: one write each, at X's first clock's end (R1029; R1028 had them at D's end, from
// the same S). X's first clock reads them at other words (the pops read below the word they
// write); D reads after.
logic stk_we;
assign stk_we = !reset && st == ST_X && x_first;
// The one write of each is always of the top in S at PCSTKP - 1 / LSTKP - 1 (the first write of a
// word -- a pop's of the top it leaves, a push's of the top it covers; a second is never made):
// the addresses and data from S, the enables X's first clock's (R1029: off its path)
logic [4:0]  pcw_a;
logic [2:0]  lsw_a;
logic [31:0] lcw_dv;
assign pcw_a = 5'(S.pcstkp - 6'd1);
assign lsw_a = S.lstkp - 3'd1;
assign lcw_dv = (XC.le && S.la_type != 2'd0) ? S.curlcntr - 32'd1 : S.curlcntr;   // (a DO's push: after no pop)
m2b_lutram #(.AW(5), .DW(24), .INIT1(RF_ONES)) u_pcs2 (.clk, .we(stk_we && x1_pcw), .wa(pcw_a), .wd(S.pcstk),
    .ra(5'(S.pcstkp - 6'd2)), .rd(pcs_p2));
m2b_lutram #(.AW(5), .DW(24), .INIT1(RF_ONES)) u_pcs3 (.clk, .we(stk_we && x1_pcw), .wa(pcw_a), .wd(S.pcstk),
    .ra(5'(S.pcstkp - 6'd3)), .rd(pcs_p3));
// LCNTR's stack: two copies. A DO reads LSTKP + 1 (its new LCNTR) and LSTKP (the same after a
// loop-end pop) and no popped word (the DO replaces CURLCNTR; the one exception is flagged);
// every other word LSTKP - 2 (a pop) and LSTKP - 3 (a second pop)
logic is_do;
logic [32:0] lcs_a, lcs_b;
// a DO in X: a register (R1029: off D's path to LCE), loaded in every D clock and cleared at X's
// end, so it is 0 in a word's first D clock and a DO's own in X; D reads LSTKP - 2 whatever the
// word but a DO (which reads nothing of these)
always_ff @(posedge clk) begin
    if (st == ST_D) is_do <= pm_q[47:40] == 8'h0c || pm_q[47:40] == 8'h0d || pm_q[47:40] == 8'h0e;
    else if (x_done || reset) is_do <= 1'b0;
end
// Each word carries a 33rd bit (R1029: LCE after a pop without a compare in D): bit 0 && word
// != 1, so word != 1 is !(bit 32 ^ bit 0) -- right for a word of all zeros or all ones too (an
// MLAB as configured, or RF_ONES), so an unwritten word reads as it did.
logic [32:0] x1_lcw_dx;
assign x1_lcw_dx = {lcw_dv[0] && lcw_dv != 32'd1, lcw_dv};
m2b_lutram #(.AW(3), .DW(33), .INIT1(RF_ONES)) u_lca (.clk, .we(stk_we && x1_lcw), .wa(lsw_a), .wd(x1_lcw_dx),
    .ra(is_do ? S.lstkp + 3'd1 : S.lstkp - 3'd2), .rd(lcs_a));
m2b_lutram #(.AW(3), .DW(33), .INIT1(RF_ONES)) u_lcb (.clk, .we(stk_we && x1_lcw), .wa(lsw_a), .wd(x1_lcw_dx),
    .ra(is_do ? S.lstkp : S.lstkp - 3'd3), .rd(lcs_b));
assign lcs_p2 = lcs_a[31:0]; assign lcs_q1 = lcs_a[31:0];
assign lcs_p3 = lcs_b[31:0]; assign lcs_q0 = lcs_b[31:0];
assign lcs_p2ne1 = !(lcs_a[32] ^ lcs_a[0]);
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lap2 (.clk, .we(stk_we && x1_law), .wa(lsw_a), .wd(la_pack(S.la_type, S.la_code, S.la_addr)),
    .ra(S.lstkp - 3'd2), .rd(las_p2));
m2b_lutram #(.AW(3), .DW(32), .INIT1(RF_ONES)) u_lap3 (.clk, .we(stk_we && x1_law), .wa(lsw_a), .wd(la_pack(S.la_type, S.la_code, S.la_addr)),
    .ra(S.lstkp - 3'd3), .rd(las_p3));

// benches: the one write of each stack is the one X's first clock's sequencing names, and D's
// access is R1028's (R1029)
generate if (BENCH) begin : g_stk_check
    always_ff @(posedge clk) if (d_go && dx.acc != d_acc_ref) $fatal(1, "access kind %d, R1028's %d", dx.acc, d_acc_ref);
    always_ff @(posedge clk) if (st == ST_D && !reset) begin : chk_sb
        logic h;
        h = 1'b0;
        for (int p = 0; p < 5; p++) if (d_ru[p] && rbusy[rf_ra[p]]) h = 1'b1;
        if (h != d_hit_ref) $fatal(1, "scoreboard %b, R1028's %b", h, d_hit_ref);
    end
    always_ff @(posedge clk) if (d_go && dx.acc_wd != d_accwd_ref) $fatal(1, "store / ureg data %h, %h", dx.acc_wd, d_accwd_ref);
    always_ff @(posedge clk) if (d_go && dx.acc != d_acc_chk) $fatal(1, "access kind %d, R1044's %d", dx.acc, d_acc_chk);
    always_ff @(posedge clk) if (st == ST_D && dx.rm_we != d_rmwe_ref) $fatal(1, "rm_we %b, R1042's %b", dx.rm_we, d_rmwe_ref);
    // R1057: ra_we in every D clock; rn_we wherever the landing reads it
    always_ff @(posedge clk) if (st == ST_D && dx.ra_we != d_rawe_ref) $fatal(1, "ra_we %b, the old %b", dx.ra_we, d_rawe_ref);
    always_ff @(posedge clk) if (st == ST_D && ((dx.fix_on && dx.fix_wr) || dx.sh_on) && dx.rn_we != d_rnwe_ref) $fatal(1, "rn_we %b, the old %b", dx.rn_we, d_rnwe_ref);
    always_ff @(posedge clk) if (st == ST_D && d_memf_x && d_wrf != d_wrf_ref) $fatal(1, "the direction %b, mem_wr %b", d_wrf, d_wrf_ref);
    always_ff @(posedge clk) if (st == ST_D && d_memf != d_memf_x) $fatal(1, "d_memf %b, mem_f %b", d_memf, d_memf_x);
    always_ff @(posedge clk) if (st == ST_D && d_cbad_ref != d_cbad_x) $fatal(1, "cbad without its guard differs");
    always_ff @(posedge clk) if (st == ST_D && d_lnzp != d_lnzp_ref) $fatal(1, "lnz[pmi] by index %b, %b", d_lnzp, d_lnzp_ref);
    always_ff @(posedge clk) if (st == ST_D && {dx.fix_on, dx.fix_wr, dx.fix_k} != d_fix_ref)
        $fatal(1, "the fixed ALU's fields %b, the handler's %b", {dx.fix_on, dx.fix_wr, dx.fix_k}, d_fix_ref);
    always_ff @(posedge clk) if (st == ST_D && d_compf != d_compf_x) $fatal(1, "d_compf %b, comp_f %b", d_compf, d_compf_x);
    always_ff @(posedge clk) if (st == ST_D && dx.fix_op != d_fixop_h) $fatal(1, "fix_op %h, the handler's %h", dx.fix_op, d_fixop_h);
    always_ff @(posedge clk) if (st == ST_D && (d_l1 ? d_cok1t : d_cok1f) != d_cok1)
        $fatal(1, "the popped outcome by l1 differs");
    always_ff @(posedge clk) if (st == ST_D && d_memf_x && ((d_s3 ? d_kb_i[2:0] : d_kb_o[2:0]) != d_acc_hit || (d_s3 ? d_kb_i[3] : d_kb_o[3]) != d_bad_x))
        $fatal(1, "R1048's per-sum kind bits %b, mem_a's %b / %b", d_s3 ? d_kb_i : d_kb_o, d_acc_hit, d_bad_x);
    always_ff @(posedge clk) if (d_go && dx.cok != d_cok_ref) $fatal(1, "condition %b, R1029's %b", dx.cok, d_cok_ref);
    always_ff @(posedge clk) if (d_go && dx.acc_wd != d_accwd_chk) $fatal(1, "store / ureg data %h, R1029's AND-OR %h", dx.acc_wd, d_accwd_chk);
    always_ff @(posedge clk) if (d_go && ur_sel[7:4] == 4'h6 && d_urall_ref != dx_urall)
        $fatal(1, "sequencer ureg read %h, R1028's %h", dx_urall, d_urall_ref);
    always_ff @(posedge clk) if (d_go && ((dx.unsup || dx.mbad) != d_unsup_ref || (d_unsup_ref && !dx.dag && !dx.mbad && dx.why != d_why_ref)))
        $fatal(1, "unsupported %b why %d, R1028's %b %d", dx.unsup, dx.why, d_unsup_ref, d_why_ref);
    always_ff @(posedge clk) if (d_go && (dx.dag != d_dag_ref || dx.mbad != d_mbad_ref))
        $fatal(1, "DAG / address test %b %b, R1028's %b %b", dx.dag, dx.mbad, d_dag_ref, d_mbad_ref);
    always_ff @(posedge clk) if (stk_we) begin
        if (x1_pcw && (x1_pcw_i != pcw_a || x1_pcw_d != S.pcstk)) $fatal(1, "PC stack write: %h %h", x1_pcw_i, x1_pcw_d);
        if (x1_lcw && (x1_lcw_i != lsw_a || x1_lcw_d != lcw_dv)) $fatal(1, "LCNTR stack write: %h %h", x1_lcw_i, x1_lcw_d);
        if (x1_law && (x1_law_i != lsw_a || x1_law_d != la_pack(S.la_type, S.la_code, S.la_addr)))
            $fatal(1, "loop stack write: %h %h", x1_law_i, x1_law_d);
    end
end endgenerate

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
// R1044: X's first clock's address is s_x1.daddr's, selected here from D's registered
// candidates (XC.f_*) and S with the selects s_x1 uses -- not through the sequencer's next
// state (BENCH checks it against s_x1.daddr at every read)
logic [PM_AW-1:0] pm_ra_x;
always_comb begin
    logic             take, chg;
    logic [PM_AW-1:0] rel, rts, tg;
    take = !x_uns && XC.cok && XC.f_br && !XC.f_db;       // br && !br_db
    chg = !x_uns && XC.le && !XC.done;                    // the loop end's CHANGE_PC(TOP_PC)
    rel = (XC.le && !XC.done) ? XC.f_relp : XC.f_reld;
    rts = (XC.le && XC.done) ? XC.f_rts : S.pcstk[PM_AW-1:0];
    tg = ({PM_AW{XC.f_ts[0]}} & x_op[PM_AW-1:0]) | ({PM_AW{XC.f_ts[1]}} & rel) |
         ({PM_AW{XC.f_ts[2]}} & XC.ind_t[PM_AW-1:0]) | ({PM_AW{XC.f_ts[3]}} & rts);
    pm_ra_x = take ? tg : chg ? S.pcstk[PM_AW-1:0] : S.faddr[PM_AW-1:0];
end
always_comb begin
    pm_re = 1'b0;
    pm_ra = pm_ra_x - PM_AW'(24'h20000);       // X's first clock: the next word (R1029)
    if (st == ST_FETCH) begin pm_re = 1'b1; pm_ra = PM_AW'(S.daddr - 24'h20000); end
    else if (st == ST_X && x_first) pm_re = 1'b1;
end
generate if (BENCH) begin : g_fetch_check
    always_ff @(posedge clk) if (pm_re && pm_ra != PM_AW'(((st == ST_FETCH) ? S.daddr : s_x1.daddr) - 24'h20000))
        $fatal(1, "fetch address %h, s_x1's %h", pm_ra, PM_AW'(s_x1.daddr - 24'h20000));
end endgenerate

assign flag_out = {mode2[18] & astat[22], mode2[17] & astat[21]};
assign dbg_st = {st == ST_D && d_wait, st};
assign obs_pc = x_pc;

// unused
logic unused_ok;
assign unused_ok = ^{d_stx, fa_s[0]};

endmodule
