// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- SIMULATION-ONLY reference for the 2B SHARC (R1027):
// the lockstep partner of rtl/sharc/m2b_sharc.sv. Never synthesised.
// COPIED from Paul Priest's Konami Hornet core (ppriest/Arcade-KonamiHornet_MiSTer,
// rtl/cpu/sharc/sharc_core.sv @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md). CHANGED: the parameter MAN (the ADSP-2106x manual's float rounding, through
// sharc_core_ops.svh's x_* functions; 0 = MAME's, as Hornet's), and flag_in, FLAG0 / FLAG1's
// input pins (the 2B board's FIFO flags), written into the state every clock. Nothing else.
//
// ADSP-21062 SHARC, transcribed from MAME's interpreter (src/devices/cpu/sharc: sharc.cpp
// execute_run, sharcops.hxx, compute.hxx through sharc_fp_pkg, sharcdma.hxx), instruction for
// instruction: each instruction runs as MAME's C does, on a copy of the state, in phases split at
// the memory accesses.
//
//   P_FETCH  interrupts and the pc shift, then read PM at the next PC
//   P_FETCH2 the PM read
//   P_EXEC   execute_run's per-instruction work up to the memory accesses (sequencing, loop
//            end, the opcode handler with its compute; ex_s), queuing up to two accesses and
//            starting the first
//   P_MEM    starts the second access
//   P_MEMWAIT an access's data: internal RAM the next clock, external at ext_ack; after the
//            last, loaded values to their registers, post-modify, system-register latency
//   P_DMA    dma_run_cycle(6), dma_run_cycle(7), each a read, a write, and a chained TCB load
//   P_BOOT   device_reset with BOOT_MODE_EPROM (sharc.cpp:926-1000), on `boot`: internal RAM
//            cleared, then DMA channel 6 packs 0x600 external words from 0x400000, a byte each,
//            into 0x100 program words at 0x20000 (sharcdma.hxx DMA_PMODE_8_48); then the reset
//            state and P_FETCH at 0x20004
//
// P_FETCH's work runs at the end of an instruction's last clock (P_EXEC, P_MEMWAIT) or of P_DMA,
// and PM at daddr is read in that clock: when the fetched pc is daddr, P_EXEC follows directly.
// So an instruction takes one clock without accesses and two with one internal access, plus
// DMA words and branches.

// Memory: block 0 holds program (48-bit words, 0x20000-0x24FFF); block 1 holds data (32-bit,
// 0x28000-0x2FFFF and its mirrors). MAME packs both into the same arrays; the game keeps code in
// block 0 and data in block 1 (HARDWARE_NOTES, "SHARC usage"), so the two are separate RAMs
// here and data accesses to block 0 are not supported (HACKS.md).
//
// External bus (everything at data address >= 0x80000): ext_req with ext_we/addr/wdata, held
// until ext_ack; a read's data in ext_rdata with the ack.
//
// irq_check_en: MAME looks for interrupts only at the start of each timeslice and after RTI
// or an IMASK write, so benches that follow a MAME trace take interrupts only when told to.
// Tie high on the board.

module sharc_core #(
    parameter int PM_WORDS = 20480,     // 0x20000-0x24FFF
    parameter int DM_WORDS = 32768,     // block 1
    parameter bit MAN = 1'b0            // R1027: the manual's float rounding
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        boot,           // pulse: MAME's reset on the release of RESET (EPROM boot)
    input  logic [1:0]  flag_in,        // R1027: FLAG0 / FLAG1 inputs

    output logic        ext_req,
    output logic        ext_we,
    output logic [31:0] ext_addr,
    output logic [31:0] ext_wdata,
    input  logic        ext_ack,
    input  logic [31:0] ext_rdata,

    input  logic [2:0]  irq_in,         // IRQ0..2 (execute_set_input: IRQ n is bit 8-n)
    input  logic [2:0]  irq_assert,     // IRQ0..2 asserted again: sets the pending bit (konppc)
    input  logic        irq_check_en,
    input  logic [31:0] dbg_irq_set,    // benches: ORed into irq_pending at the fetch; tie 0

    // one pulse per executed instruction, in P_EXEC before it changes anything
    output logic        dbg_exec,
    output logic [23:0] dbg_pc,
    output logic [47:0] dbg_op,
    input  logic [5:0]  dbg_sel,        // 0-15 R, 16-31 I, 32-47 M, 48 ASTAT, 49 MODE1, 50 IRPTL,
                                        // 51 IMASK, 52 PCSTKP, 53 LSTKP, 54 CURLCNTR, 55 PCSTK
    output logic [31:0] dbg_val,
    output logic        dbg_idle,
    // state and memory load (benches): written whatever ce
    input  logic        dbg_pm_we,
    input  logic [14:0] dbg_pm_addr,
    input  logic [47:0] dbg_pm_wdata,
    input  logic        dbg_dm_we,
    input  logic [14:0] dbg_dm_addr,
    input  logic [31:0] dbg_dm_wdata,
    input  logic        dbg_we,
    input  logic [7:0]  dbg_wsel,       // see the dbg_we block at the end
    input  logic [5:0]  dbg_widx,
    input  logic [63:0] dbg_wdata
);

import sharc_fp_pkg::*;

// ------------------------------------------------------------------------------------------
// Constants
// ------------------------------------------------------------------------------------------

localparam logic [31:0] SV = 32'h0000_0800, SZ = 32'h0000_1000, SS = 32'h0000_2000,
                        BTF = 32'h0004_0000, FLGS = 32'h0078_0000;
localparam logic [31:0] AOS = 32'h0000_0004, MOS = 32'h0000_0040;
localparam logic [31:0] PCFL = 32'h0020_0000, PCEM = 32'h0040_0000, SSOV = 32'h0080_0000,
                        SSEM = 32'h0100_0000, LSOV = 32'h0200_0000, LSEM = 32'h0400_0000;
localparam logic [31:0] MODE1_SRD1H = 32'h08, MODE1_SRD1L = 32'h10, MODE1_SRD2H = 32'h20,
                        MODE1_SRD2L = 32'h40, MODE1_SRRFH = 32'h80, MODE1_SRRFL = 32'h400,
                        MODE1_IRPTEN = 32'h1000, MODE1_ALUSAT = 32'h2000,
                        MODE1_TRUNCATE = 32'h8000;

// ------------------------------------------------------------------------------------------
// State (MAME's sharc_internal_state)
// ------------------------------------------------------------------------------------------

typedef struct packed {
    logic [31:0] addr;
    logic [4:0]  code;
    logic [1:0]  loop_type;
} laddr_t;

typedef struct packed {
    logic [15:0][31:0] r, ralt;
    logic [7:0][31:0]  i1, m1, l1, b1, i2, m2, l2, b2;            // DAG1, DAG2
    logic [7:0][31:0]  i1a, m1a, l1a, b1a, i2a, m2a, l2a, b2a;    // alternates
    logic [63:0] mrf, mrb;
    logic [47:0] px;
    logic [31:0] pc, daddr, faddr, nfaddr, delay_slot1, delay_slot2;
    logic [31:0] pcstk, pcstkp;
    logic [29:0][31:0] pcstack;
    logic [5:0][31:0]  lcstack, lastack;
    logic [31:0] curlcntr, lcntr, lstkp;
    laddr_t      laddr;
    logic [4:0][31:0] ss_mode1, ss_astat;
    logic [31:0] status_stkp;
    logic [31:0] astat, astat_old, astat_old_old, astat_old_old_old;
    logic [31:0] mode1, mode2, stky, irptl, imask, imaskp, ustat1, ustat2;
    logic [3:0]  flag;
    logic [31:0] syscon, sysstat;
    logic        idle;
    logic [31:0] irq_pending, active_irq_num;
    logic        interrupt_active;
    logic [31:0] lat_cycles, lat_reg, lat_data, lat_prev;
    // DMA channels 6 and 7 (index 0 = 6)
    logic [1:0][31:0] dma_control, dma_int_index, dma_int_modifier, dma_int_count,
                      dma_chain_ptr, dma_gen, dma_ext_index, dma_ext_modifier, dma_ext_count;
    logic [1:0]       op_active, op_chained, op_tcb;
    logic [1:0][31:0] op_src, op_dst, op_src_mod, op_dst_mod, op_src_count, op_dst_count,
                      op_pmode, op_chain_ptr, op_chain_dir;
    logic [31:0] dma_status;
    logic [31:0] iop_delay_reg, iop_delay_data, iop_delay_cycles;
} st_t;

st_t S;          // committed state

// ------------------------------------------------------------------------------------------
// Memories
// ------------------------------------------------------------------------------------------

logic [47:0] pm [PM_WORDS];
logic [31:0] dm [DM_WORDS];

logic [14:0] pm_raddr, pm_raddr_c;
logic [47:0] pm_q;
always_ff @(posedge clk) begin
    pm_q <= pm[pm_raddr_c];
    if (dbg_pm_we) pm[dbg_pm_addr] <= dbg_pm_wdata;
    else if (pm_we_i) pm[pm_waddr_i] <= pm_wdata_i;
end

logic        pm_we_i;
logic [14:0] pm_waddr_i;
logic [47:0] pm_wdata_i;

logic [14:0] dm_addr_i, dm_raddr_c;
logic        dm_we_i;
logic [31:0] dm_wdata_i, dm_q;
always_ff @(posedge clk) begin
    if (dbg_dm_we) dm[dbg_dm_addr] <= dbg_dm_wdata;
    else if (dm_we_i) dm[dm_addr_i] <= dm_wdata_i;
    dm_q <= dm[dm_raddr_c];
end

// internal address decode (data_2m, pgm_2m: sharc.cpp:83-104)
function automatic logic is_pm(input logic [31:0] a);   // program memory block 0
    is_pm = a >= 32'h20000 && a <= 32'h24FFF;
endfunction
function automatic logic is_dm1(input logic [31:0] a);  // block 1 and its mirrors
    is_dm1 = a >= 32'h28000 && a <= 32'h3FFFF;
endfunction

// ------------------------------------------------------------------------------------------
// Pending memory accesses of the executing instruction
// ------------------------------------------------------------------------------------------

typedef enum logic [2:0] {
    A_DM_RD, A_DM_WR, A_PM_RD32, A_PM_WR32, A_PM_RD48, A_PM_WR48, A_IOP_RD
} acc_kind_t;

typedef struct packed {
    logic        valid;
    acc_kind_t   kind;
    logic [31:0] addr;
    logic [47:0] wdata;
    // what to do with a read
    logic [1:0]  dest_kind;      // 0 dreg, 1 ureg, 2 px, 3 none
    logic [7:0]  dest;
    // post-modify after the read (MAME's order: load, then I += M)
    logic        post_mod;
    logic        post_pm;        // DAG2
    logic [2:0]  post_i;
    logic [31:0] post_m;
} acc_t;

acc_t acc [2];
// P_EXEC's result (the always_comb below the sequencer)
st_t        ex_s;
acc_t       ex_a [2];
logic [1:0] ex_n;
logic [1:0]  acc_n;               // number queued
logic [0:0]  acc_cur;
logic [47:0] acc_rdata [2];

typedef enum logic [3:0] {
    P_RESET, P_FETCH, P_FETCH2, P_EXEC, P_MEM, P_MEMWAIT, P_DMA, P_DMAWAIT, P_IDLE, P_BOOT
} phase_t;
phase_t ph;

// ------------------------------------------------------------------------------------------
// Helper functions on a local state copy. MAME's inline helpers, one for one.
// ------------------------------------------------------------------------------------------

function automatic logic cond_lt(input st_t s);
    cond_lt = (s.astat & AF) ? ((s.astat & AN) != 0 && (s.astat & AZ) == 0)
                             : (((s.astat & AN) != 0) != (((s.astat & AV) != 0) && (s.mode1 & MODE1_ALUSAT) == 0));
endfunction
function automatic logic cond_le(input st_t s);
    cond_le = (s.astat & AZ) != 0 ||
              ((s.astat & AF) ? (s.astat & AN) != 0
                              : (((s.astat & AN) != 0) != (((s.astat & AV) != 0) && (s.mode1 & MODE1_ALUSAT) == 0)));
endfunction

function automatic logic if_cond(input st_t s, input logic [4:0] c);
    case (c)
    5'h00: if_cond = (s.astat & AZ) != 0;
    5'h01: if_cond = cond_lt(s);
    5'h02: if_cond = cond_le(s);
    5'h03: if_cond = (s.astat & AC) != 0;
    5'h04: if_cond = (s.astat & AV) != 0;
    5'h05: if_cond = (s.astat & MV) != 0;
    5'h06: if_cond = (s.astat & MN) != 0;
    5'h07: if_cond = (s.astat & SV) != 0;
    5'h08: if_cond = (s.astat & SZ) != 0;
    5'h09: if_cond = s.flag[0];
    5'h0a: if_cond = s.flag[1];
    5'h0b: if_cond = s.flag[2];
    5'h0c: if_cond = s.flag[3];
    5'h0d: if_cond = (s.astat & BTF) != 0;
    5'h0e: if_cond = 1'b0;
    5'h0f: if_cond = s.curlcntr != 1;
    5'h10: if_cond = (s.astat & AZ) == 0;
    5'h11: if_cond = !cond_lt(s);
    5'h12: if_cond = !cond_le(s);
    5'h13: if_cond = (s.astat & AC) == 0;
    5'h14: if_cond = (s.astat & AV) == 0;
    5'h15: if_cond = (s.astat & MV) == 0;
    5'h16: if_cond = (s.astat & MN) == 0;
    5'h17: if_cond = (s.astat & SV) == 0;
    5'h18: if_cond = (s.astat & SZ) == 0;
    5'h19: if_cond = !s.flag[0];
    5'h1a: if_cond = !s.flag[1];
    5'h1b: if_cond = !s.flag[2];
    5'h1c: if_cond = !s.flag[3];
    5'h1d: if_cond = (s.astat & BTF) == 0;
    default: if_cond = 1'b1;
    endcase
endfunction

// DO_CONDITION_CODE differs in 0x0f (LCE) and 0x1f (FOREVER)
function automatic logic do_cond(input st_t s, input logic [4:0] c);
    if (c == 5'h0f)      do_cond = s.curlcntr == 1;
    else if (c == 5'h1f) do_cond = 1'b0;
    else                 do_cond = if_cond(s, c);
endfunction

`include "sharc_core_ops.svh"

// ------------------------------------------------------------------------------------------
// Sequencer
// ------------------------------------------------------------------------------------------

// after the accesses: system register latency (sharc.cpp:1340-1348) and the delayed IOP write,
// counted in instruction cycles
task automatic post_counters(inout st_t s);
    if (s.lat_cycles != 0) begin
        s.lat_cycles = s.lat_cycles - 1;
        if (s.lat_cycles == 0) sysreg_latency_effect(s);
    end
    if (s.iop_delay_cycles != 0) begin
        s.iop_delay_cycles = s.iop_delay_cycles - 1;
        if (s.iop_delay_cycles == 0 && s.iop_delay_data[0])
            dma_exec(s, s.iop_delay_reg == 32'h1c ? 1'b0 : 1'b1);
    end
endtask

logic [47:0] opcode;
logic [2:0]  irq_prev;
logic [1:0]  dma_ch;             // 0 = channel 6, 1 = channel 7, 2 done (P_DMA)
logic [3:0]  dma_step;           // within a channel: 0 read, 1 write, 2..9 TCB words 0..7
logic [31:0] dma_data;
logic [2:0]  dma_k;              // read within a packed word (dma_run_cycle's src + k)
logic [47:0] dma_pack;           // the packed word being assembled
logic [7:0][31:0] tcb;
logic [15:0] boot_n;             // P_BOOT: RAM word being cleared, then external word read
logic        boot_clear;
logic [47:0] boot_w;
logic [2:0]  boot_k;             // byte of the program word (0-5)
logic [7:0]  boot_pw;            // program word (0-0xFF)

// the start of execute_run's loop: interrupts, then the pc shift and the PM read, or idle
task automatic fetch_step(inout st_t s);
    s.irq_pending = s.irq_pending | dbg_irq_set;
    if (irq_check_en && s.irq_pending != 0) begin
        check_interrupts(s);
        s.idle = 1'b0;
    end
    if (s.idle) begin
        // DMA runs while idle (sharc.cpp:1250-1261)
        ph <= (s.dma_status[7:6] != 0) ? P_DMA : P_IDLE;
        dma_ch <= 2'd0; dma_step <= 4'd0; dma_k <= 3'd0;
    end else begin
        // the pc shift of execute_run (sharc.cpp:1273-1280)
        s.pc = s.daddr; s.daddr = s.faddr; s.faddr = s.nfaddr; s.nfaddr = s.nfaddr + 1;
        s.astat_old_old_old = s.astat_old_old;
        s.astat_old_old = s.astat_old;
        s.astat_old = s.astat;
        pm_raddr <= 15'(s.pc - 32'h20000);
        // the PM word read this clock at daddr (pre_ok) is the next instruction's unless the
        // instruction or an interrupt moved the pc
        ph <= (pre_ok && s.pc == S.daddr) ? P_EXEC : P_FETCH2;
    end
endtask

// device_reset's state after the boot DMA (sharc.cpp:935-1000); the DMA leaves channel 6's
// registers as it set them and irptl is cleared after it
task automatic boot_state(inout st_t s);
    s.dma_int_index[0] = 32'h20000;  s.dma_int_modifier[0] = 32'd1; s.dma_int_count[0] = 32'h100;
    s.dma_ext_index[0] = 32'h400000; s.dma_ext_modifier[0] = 32'd1; s.dma_ext_count[0] = 32'h600;
    s.dma_control[0] = 32'h2A1;
    s.op_active[0] = 1'b0;
    s.dma_status[6] = 1'b0;
    s.pc = 32'h20004; s.daddr = 32'h20005; s.faddr = 32'h20006; s.nfaddr = 32'h20007;
    s.idle = 1'b0;
    s.mode1 = 32'h0;
    s.mode2 = s.mode2 & 32'hF000_0000;
    s.astat = s.astat & FLGS;
    s.stky = PCEM | SSEM | LSEM;
    s.irptl = 32'h0;
    s.imask = 32'h3;
    s.ustat1 = 32'h0; s.ustat2 = 32'h0;
    s.pcstkp = 32'h0; s.lstkp = 32'h0;
    s.pcstk = 32'h00FF_FFFF;
    s.curlcntr = 32'hFFFF_FFFF;
    s.lcntr = s.lcstack[0];
    s.laddr = laddr_unpack(32'hFFFF_FFFF);
    s.status_stkp = 32'h0;
    s.interrupt_active = 1'b0;
    s.syscon = 32'h10;
    s.sysstat = s.sysstat & 32'h0000_0FF0;
    s.iop_delay_cycles = 32'h0;
endtask

// after the accesses: loads and post-modifies, with the last access's data not yet in acc_rdata
task automatic post_apply(inout st_t s, input logic [47:0] rd [2]);
    for (int k = 0; k < 2; k++)
        if (k < acc_n && acc[k].valid && (acc[k].kind == A_DM_RD || acc[k].kind == A_PM_RD32 ||
                                          acc[k].kind == A_PM_RD48 || acc[k].kind == A_IOP_RD))
            apply_load(s, acc[k], rd[k]);
        else if (k < acc_n && acc[k].valid && acc[k].post_mod)
            post_modify(s, acc[k].post_pm, acc[k].post_i, acc[k].post_m);
endtask

// reads per transfer of a packing mode (sharcdma.hxx dma_run_cycle): 16/32 two, 8/48 six
function automatic logic [2:0] dma_reads(input logic [31:0] pmode);
    dma_reads = (pmode == 32'd1) ? 3'd2 : (pmode == 32'd4) ? 3'd6 : 3'd1;
endfunction

// DMA address of the current step (P_DMA, P_DMAWAIT); a read is src + dma_k
function automatic logic [31:0] dma_addr(input st_t s, input logic ch, input logic [3:0] stp);
    if (stp == 4'd0)      dma_addr = s.op_src[ch] + {29'h0, dma_k};
    else if (stp == 4'd1) dma_addr = s.op_dst[ch];
    else                  dma_addr = 32'h20000 + (s.op_chain_ptr[ch] & 32'h1FFFF) - {28'h0, stp} + 32'd2;
endfunction
function automatic logic [3:0] dma_eff_step(input st_t s, input logic ch, input logic [3:0] stp);
    dma_eff_step = (s.op_tcb[ch] && stp < 4'd2) ? 4'd2 : stp;
endfunction

// P_DMA's channel: the first active one from dma_ch on, 2 when none is left
logic [1:0] dma_sel;
always_comb
    if (dma_ch == 2'd0 && S.dma_status[6])      dma_sel = 2'd0;
    else if (dma_ch <= 2'd1 && S.dma_status[7]) dma_sel = 2'd1;
    else                                        dma_sel = 2'd2;

// RAM read addresses: the access being started, so that its data is there the clock after; in
// the clocks that can end an instruction, PM at daddr, the next pc if nothing branches
logic pre_ok;
always_comb begin
    logic pm_rd;
    pm_rd = is_pm(acc[acc_cur].addr) && (acc[acc_cur].kind == A_PM_RD32 || acc[acc_cur].kind == A_PM_RD48);
    pm_raddr_c = pm_raddr;
    dm_raddr_c = dm_addr_i;
    pre_ok = 1'b0;
    if (ph == P_EXEC && ce && ex_n != 0) begin
        // the first access starts in P_EXEC
        pm_raddr_c = 15'(ex_a[0].addr - 32'h20000);
        dm_raddr_c = 15'(ex_a[0].addr - 32'h28000);
    end else if ((ph == P_EXEC && ce) || ph == P_FETCH || ph == P_IDLE || (ph == P_DMA && dma_sel == 2'd2) ||
                 ph == P_DMAWAIT) begin             // DMA does not read PM
        // in P_EXEC pm_q holds the executing opcode until ce
        pm_raddr_c = 15'(S.daddr - 32'h20000);
        pre_ok = 1'b1;
    end else if (ph == P_MEMWAIT && !pm_rd) begin
        pm_raddr_c = 15'(S.daddr - 32'h20000);
        // a PM write at this edge to the same word would not be seen
        pre_ok = !(pm_we_i && pm_waddr_i == pm_raddr_c);
    end else if (ph == P_MEM) begin
        pm_raddr_c = 15'(acc[acc_cur].addr - 32'h20000);
        dm_raddr_c = 15'(acc[acc_cur].addr - 32'h28000);
    end else if (ph == P_DMA)
        dm_raddr_c = 15'(dma_addr(S, dma_sel[0], dma_eff_step(S, dma_sel[0], dma_step)) - 32'h28000);
end

// P_EXEC's work: execute_run's per-instruction sequencing and the opcode handler, on pm_q
always_comb begin
    st_t s;
    acc_t a [2];
    logic [1:0] n;
    s = S;
    a[0] = '0; a[1] = '0; n = 2'd0;

    // loop end (sharc.cpp:1286-1335)
    if ((s.stky & LSEM) == 0 && s.pc == s.laddr.addr) begin
        case (s.laddr.loop_type)
        2'd0: begin
            if (s.pc - s.pcstk > 2) s.astat = s.astat_old_old_old;
            if (do_cond(s, s.laddr.code)) begin logic [31:0] t; pop_loop(s); pop_pc(s, t); end
            else change_pc(s, s.pcstk);
            s.astat = s.astat_old;
        end
        default: begin
            s.curlcntr = s.curlcntr - 1;
            if (s.curlcntr == 0) begin logic [31:0] t; pop_loop(s); pop_pc(s, t); end
            else change_pc(s, s.pcstk);
        end
        endcase
    end

    execute_op(s, pm_q, a, n);
    ex_s = s; ex_a = a; ex_n = n;
end

// start an access: its RAM read address is dm_raddr_c / pm_raddr_c this clock, its data
// P_MEMWAIT's
task automatic issue_acc(input acc_t a);
    if (is_pm(a.addr) && (a.kind == A_PM_RD32 || a.kind == A_PM_RD48))
        pm_raddr <= 15'(a.addr - 32'h20000);
    else if (is_pm(a.addr) && (a.kind == A_PM_WR32 || a.kind == A_PM_WR48)) begin
        pm_we_i <= 1'b1; pm_waddr_i <= 15'(a.addr - 32'h20000);
        // pm_write32: data in the upper 32 bits, low 16 kept (sharcinternal.ipp:251-254)
        pm_wdata_i <= a.wdata;
    end else if (is_dm1(a.addr)) begin
        dm_addr_i <= 15'(a.addr - 32'h28000);
        if (a.kind == A_DM_WR || a.kind == A_PM_WR32) begin
            dm_we_i <= 1'b1; dm_wdata_i <= a.wdata[31:0];
        end
    end else if (a.addr >= 32'h100) begin       // below: IOP registers, in P_MEMWAIT
        x_req <= 1'b1;
        x_we  <= (a.kind == A_DM_WR || a.kind == A_PM_WR32 || a.kind == A_PM_WR48);
        x_addr <= a.addr;
        x_wdata <= a.wdata[31:0];
    end
    ph <= P_MEMWAIT;
endtask

// after an instruction's accesses: DMA first if a channel is active, else the next fetch
task automatic after_insn(inout st_t s);
    if (s.dma_status[7:6] != 0) begin
        dma_ch <= 2'd0; dma_step <= 4'd0; dma_k <= 3'd0;
        ph <= P_DMA;
    end else
        fetch_step(s);
endtask

assign dbg_exec = ce && ph == P_EXEC;
assign dbg_pc   = S.pc[23:0];
assign dbg_op   = pm_q;
assign dbg_idle = S.idle;

always_comb begin
    case (dbg_sel)
    6'd48: dbg_val = S.astat;
    6'd49: dbg_val = S.mode1;
    6'd50: dbg_val = S.irptl;
    6'd51: dbg_val = S.imask;
    6'd52: dbg_val = S.pcstkp;
    6'd53: dbg_val = S.lstkp;
    6'd54: dbg_val = S.curlcntr;
    6'd55: dbg_val = S.pcstk;
    default:
        if (dbg_sel < 6'd16)      dbg_val = S.r[dbg_sel[3:0]];
        else if (dbg_sel < 6'd24) dbg_val = S.i1[dbg_sel[2:0]];
        else if (dbg_sel < 6'd32) dbg_val = S.i2[dbg_sel[2:0]] & 32'h00FF_FFFF;
        else if (dbg_sel < 6'd40) dbg_val = S.m1[dbg_sel[2:0]];
        else                      dbg_val = S.m2[dbg_sel[2:0]] & 32'h00FF_FFFF;
    endcase
end

// external bus: driven from registers set by the phases
logic        x_req, x_we;
logic [31:0] x_addr, x_wdata;
assign ext_req   = x_req;
assign ext_we    = x_we;
assign ext_addr  = x_addr;
assign ext_wdata = x_wdata;

always_ff @(posedge clk) begin
    pm_we_i  <= 1'b0;
    dm_we_i  <= 1'b0;

    irq_prev <= irq_in;

    if (reset) begin
        ph <= P_RESET;
        x_req <= 1'b0;
        S.idle <= 1'b0;
    end else if (boot) begin
        ph <= P_BOOT;
        x_req <= 1'b0;
        boot_clear <= 1'b1;
        boot_n <= 16'h0; boot_k <= 3'd0; boot_pw <= 8'd0;
    end else if (ce) begin
        case (ph)

        P_RESET: ;                                   // a bench loads the state, then P_FETCH

        // ---------------------------------------------------------------- EPROM boot
        P_BOOT:
            if (boot_clear) begin
                // m_blocks cleared: program block (0x5000 words) and data block (0x8000)
                if (boot_n < 16'h5000) begin
                    pm_we_i <= 1'b1; pm_waddr_i <= boot_n[14:0]; pm_wdata_i <= 48'h0;
                end
                dm_we_i <= 1'b1; dm_addr_i <= boot_n[14:0]; dm_wdata_i <= 32'h0;
                if (boot_n == 16'h7FFF) begin boot_clear <= 1'b0; boot_n <= 16'h0; end
                else boot_n <= boot_n + 16'd1;
            end else if (!x_req) begin
                if (boot_n == 16'h600) begin
                    st_t s;
                    s = S;
                    boot_state(s);
                    S <= s;
                    ph <= P_FETCH;
                end else begin
                    x_req <= 1'b1; x_we <= 1'b0; x_addr <= 32'h400000 + {16'h0, boot_n};
                end
            end else if (ext_ack) begin
                // byte k of each group of six is bits 8k+7:8k of the program word
                logic [47:0] w;
                x_req <= 1'b0;
                w = boot_w;
                w[8 * boot_k +: 8] = ext_rdata[7:0];
                boot_w <= w;
                if (boot_k == 3'd5) begin
                    pm_we_i <= 1'b1; pm_waddr_i <= {7'h0, boot_pw}; pm_wdata_i <= w;
                    boot_k <= 3'd0; boot_pw <= boot_pw + 8'd1;
                end else
                    boot_k <= boot_k + 3'd1;
                boot_n <= boot_n + 16'd1;
            end

        // ---------------------------------------------------------------- interrupts, fetch
        P_FETCH, P_IDLE: begin
            st_t s;
            s = S;
            fetch_step(s);
            S <= s;
        end
        P_FETCH2: ph <= P_EXEC;                      // PM read data at the next edge

        // ---------------------------------------------------------------- execute
        P_EXEC: begin
            st_t s;
            s = ex_s;
            opcode <= pm_q;
            acc[0] <= ex_a[0]; acc[1] <= ex_a[1];
            acc_n <= ex_n;
            acc_cur <= 1'b0;
            if (ex_n != 0) issue_acc(ex_a[0]);
            else begin
                post_counters(s);
                after_insn(s);
            end
            S <= s;
        end

        // ---------------------------------------------------------------- memory accesses
        P_MEM: issue_acc(acc[acc_cur]);
        P_MEMWAIT: begin
            st_t s;
            acc_t a;
            logic done;
            logic [47:0] d, rd;
            s = S;
            a = acc[acc_cur];
            done = 1'b1; d = '0;
            if (is_pm(a.addr)) d = pm_q;                              // 48-bit
            else if (is_dm1(a.addr)) d = {16'h0, dm_q};
            else if (a.addr < 32'h100) begin
                if (a.kind == A_DM_WR) iop_write(s, a.addr[7:0], a.wdata[31:0]);
                else d = {16'h0, iop_read(s, a.addr[7:0])};
            end else begin
                done = ext_ack;
                d = {16'h0, ext_rdata};
                if (ext_ack) x_req <= 1'b0;
            end
            if (done) begin
                logic [47:0] r [2];
                // a 32-bit PM read is the upper 32 bits (sharcinternal.ipp:245-248)
                rd = (a.kind == A_PM_RD32 && is_pm(a.addr)) ? {16'h0, d[47:16]} : d;
                acc_rdata[acc_cur] <= rd;
                if (acc_cur == 1'(acc_n - 2'd1)) begin
                    r[0] = acc_rdata[0]; r[1] = acc_rdata[1];
                    r[acc_cur] = rd;
                    post_apply(s, r);
                    post_counters(s);
                    after_insn(s);
                end else begin acc_cur <= acc_cur + 1'b1; ph <= P_MEM; end
            end
            S <= s;
        end

        // ---------------------------------------------------------------- DMA cycle
        // one word per channel per instruction, as dma_run_cycle (sharcdma.hxx:94-180); a
        // chained channel first reads its TCB (schedule_chained_dma_op). A packed word (16/32, 8/48)
        // is 2 or 6 reads, then one write.
        P_DMA: begin
            if (dma_sel == 2'd2) begin
                st_t s;
                s = S;
                fetch_step(s);
                S <= s;
            end else begin
                logic [31:0] ad;
                logic        wr;
                logic [3:0]  stp;
                dma_ch <= dma_sel;
                stp = dma_eff_step(S, dma_sel[0], dma_step);
                dma_step <= stp;
                ad = dma_addr(S, dma_sel[0], stp);
                wr = stp == 4'd1;
                if (is_dm1(ad)) begin
                    dm_addr_i <= 15'(ad - 32'h28000);
                    if (wr) begin dm_we_i <= 1'b1; dm_wdata_i <= dma_data; end
                end else if (ad >= 32'h100 && !is_pm(ad)) begin
                    x_req <= 1'b1; x_we <= wr; x_addr <= ad; x_wdata <= dma_data;
                end
                ph <= P_DMAWAIT;
            end
        end
        P_DMAWAIT: begin
            logic [31:0] ad, d;
            logic done;
            done = 1'b1;
            ad = dma_addr(S, dma_ch[0], dma_step);
            if (is_dm1(ad)) d = dm_q;
            else if (ad >= 32'h100 && !is_pm(ad)) begin
                done = ext_ack; d = ext_rdata;
                if (ext_ack) x_req <= 1'b0;
            end else d = 32'h0;
            if (done) begin
                if (dma_step == 4'd0) begin
                    // the word so far: 16/32 packs two low halves, high first; 8/48 six low
                    // bytes, first at bit 0
                    logic [31:0] pm;
                    logic [47:0] w;
                    pm = S.op_pmode[dma_ch[0]];
                    w = dma_pack;
                    if (pm == 32'd1) begin
                        if (dma_k == 3'd0) w[31:16] = d[15:0]; else w[15:0] = d[15:0];
                    end else if (pm == 32'd4)
                        w[8 * dma_k +: 8] = d[7:0];
                    else
                        w = {16'h0, d};
                    dma_pack <= w;
                    if (dma_k + 3'd1 < dma_reads(pm)) begin
                        dma_k <= dma_k + 3'd1;
                        ph <= P_DMA;
                    end else begin
                        // the write starts in this clock, with the word just completed
                        logic [31:0] wa;
                        wa = dma_addr(S, dma_ch[0], 4'd1);
                        dma_data <= w[31:0]; dma_step <= 4'd1;
                        if (is_pm(wa) && pm == 32'd4) begin
                            pm_we_i <= 1'b1; pm_waddr_i <= 15'(wa - 32'h20000); pm_wdata_i <= w;
                        end else if (is_dm1(wa)) begin
                            dm_addr_i <= 15'(wa - 32'h28000);
                            dm_we_i <= 1'b1; dm_wdata_i <= w[31:0];
                        end else if (wa >= 32'h100 && !is_pm(wa)) begin
                            x_req <= 1'b1; x_we <= 1'b1; x_addr <= wa; x_wdata <= w[31:0];
                        end
                    end
                end
                else if (dma_step == 4'd1) begin
                    st_t s;
                    logic chain;
                    s = S;
                    dma_advance(s, dma_ch[0], dma_reads(S.op_pmode[dma_ch[0]]), chain);
                    dma_k <= 3'd0;
                    // a chained follow-on loads its TCB in this same cycle, as MAME's does
                    if (chain) begin dma_step <= 4'd2; ph <= P_DMA; end
                    else if (dma_ch == 2'd0 && s.dma_status[7]) begin
                        dma_ch <= 2'd1; dma_step <= 4'd0; ph <= P_DMA;
                    end else
                        fetch_step(s);                  // no channel left
                    S <= s;
                end else begin
                    // TCB words, op_ptr - 0 down to op_ptr - 7 (sharcdma.hxx:13-22)
                    tcb[dma_step - 4'd2] <= d;
                    if (dma_step == 4'd9) begin
                        st_t s;
                        logic [7:0][31:0] t;
                        s = S;
                        t = tcb;
                        t[7] = d;
                        schedule_chained(s, dma_ch[0], t);
                        S <= s;
                        dma_ch <= dma_ch + 2'd1; dma_step <= 4'd0;
                    end else
                        dma_step <= dma_step + 4'd1;
                    ph <= P_DMA;
                end
            end
        end
        default: ph <= P_FETCH;
        endcase
    end

    // IRQ line changes set or clear irq_pending (execute_set_input, sharc.cpp:1084-1097); after
    // the phases, whose whole-state writes would otherwise drop them
    for (int n = 0; n < 3; n++)
        if (irq_assert[n]) S.irq_pending[8 - n] <= 1'b1;
        else if (irq_in[n] != irq_prev[n]) S.irq_pending[8 - n] <= irq_in[n];

    if (dbg_we) dbg_write(dbg_wsel, dbg_widx, dbg_wdata);
    S.flag[0] <= flag_in[0];
    S.flag[1] <= flag_in[1];
end

endmodule
