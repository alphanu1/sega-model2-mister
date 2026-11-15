// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- SIMULATION-ONLY reference for the 2B SHARC (R1027).
// COPIED from Paul Priest's Konami Hornet core (ppriest/Arcade-KonamiHornet_MiSTer,
// rtl/cpu/sharc/sharc_core_ops.svh @ 87f9866, GPL-3.0-or-later, used with his permission;
// THIRD_PARTY.md). CHANGED: every float operation goes through the x_* functions below, which
// are MAME's (sharc_fp_pkg f_*) or, with the module parameter MAN, the ADSP-2106x manual's
// rounding (the R1027 man_* functions). Nothing else.
//
// sharc_core's operations, included inside the module: MAME's helpers and opcode handlers
// (sharcops.hxx, compute.hxx, sharcdma.hxx, sharc.cpp), each on a local copy `s` of the state.
// Names follow MAME's; line references are to sharcops.hxx unless named.


// R1027: the rounding the reference computes with (MAN: the manual's; else MAME's)
function automatic fres_t x_add(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    return MAN ? man_add(x, y, trunc) : f_add(x, y, trunc);
endfunction
function automatic fres_t x_sub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    return MAN ? man_sub(x, y, trunc) : f_sub(x, y, trunc);
endfunction
function automatic fres_t x_avg(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    return MAN ? man_avg(x, y, trunc) : f_avg(x, y, trunc);
endfunction
function automatic fdual_t x_addsub(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    return MAN ? man_addsub(x, y, trunc) : f_addsub(x, y, trunc);
endfunction
function automatic fres_t x_mul(input logic [31:0] x, input logic [31:0] y, input logic trunc);
    return MAN ? man_mul(x, y, trunc) : f_mul(x, y);
endfunction
function automatic fres_t x_fix(input logic [31:0] x, input logic scaled, input logic [31:0] ry,
                                input logic trunc, input logic multi);
    return MAN ? man_fix(x, scaled, ry, trunc) : f_fix(x, scaled, ry, trunc, multi);
endfunction
function automatic fres_t x_float(input logic [31:0] rx, input logic scaled, input logic [31:0] ry,
                                  input logic multi, input logic trunc);
    return MAN ? man_float(rx, scaled, ry, multi, trunc) : f_float(rx, scaled, ry, multi);
endfunction
function automatic fres_t x_minmax(input logic [31:0] x, input logic [31:0] y, input logic max);
    return MAN ? man_minmax(x, y, max) : f_minmax(x, y, max);
endfunction
function automatic fres_t x_comp(input logic [31:0] x, input logic [31:0] y, input logic [31:0] astat);
    return MAN ? man_comp(x, y, astat) : f_comp(x, y, astat);
endfunction
function automatic fres_t x_scalb(input logic [31:0] x, input logic [31:0] ry);
    return MAN ? man_scalb(x, ry) : f_scalb(x, ry);
endfunction
function automatic fres_t x_logb(input logic [31:0] x);
    return MAN ? man_logb(x) : f_logb(x);
endfunction
function automatic fres_t x_recips(input logic [31:0] x);
    return MAN ? man_recips(x) : f_recips(x);
endfunction
function automatic fres_t x_rsqrts(input logic [31:0] x);
    return MAN ? man_rsqrts(x) : f_rsqrts(x);
endfunction

// ------------------------------------------------------------------------------------------
// Program sequencing
// ------------------------------------------------------------------------------------------

task automatic change_pc(inout st_t s, input logic [31:0] newpc);             // sharc.cpp:247
    s.pc = newpc; s.daddr = newpc; s.faddr = newpc + 1; s.nfaddr = newpc + 2;
endtask

task automatic change_pc_delayed(inout st_t s, input logic [31:0] newpc);     // sharc.cpp:255
    s.nfaddr = newpc;
    s.delay_slot1 = s.pc;
    s.delay_slot2 = s.daddr;
endtask

task automatic push_pc(inout st_t s);                                         // 1078
    if (s.pcstkp > 0) s.pcstack[s.pcstkp - 1] = s.pcstk;
    s.pcstkp = s.pcstkp + 1;
    s.stky = s.stky & ~PCEM;
    if (s.pcstkp >= 30) s.stky = s.stky | PCFL;
endtask

task automatic pop_pc(inout st_t s, output logic [31:0] v);                   // 1093
    v = s.pcstk;
    s.pcstkp = s.pcstkp - 1;
    if (s.pcstkp < 30) begin
        s.pcstack[s.pcstkp] = s.pcstk;
        if (s.pcstkp > 0) s.pcstk = s.pcstack[s.pcstkp - 1];
        else begin s.pcstk = 32'h00FF_FFFF; s.stky = s.stky | PCEM; end
        s.stky = s.stky & ~PCFL;
    end
endtask

function automatic logic [31:0] laddr_pack(input laddr_t l);
    laddr_pack = {l.loop_type, 1'b0, l.code, l.addr[23:0]};
endfunction
function automatic laddr_t laddr_unpack(input logic [31:0] v);
    laddr_unpack.addr = {8'h0, v[23:0]};
    laddr_unpack.code = v[28:24];
    laddr_unpack.loop_type = v[31:30];
endfunction

task automatic push_loop(inout st_t s);                                       // 1125
    if (s.lstkp > 0) begin
        s.lcstack[s.lstkp - 1] = s.curlcntr;
        s.lastack[s.lstkp - 1] = laddr_pack(s.laddr);
    end
    s.curlcntr = s.lcntr;
    s.laddr = laddr_unpack(s.lastack[s.lstkp]);
    s.lstkp = s.lstkp + 1;
    if (s.lstkp < 6) s.lcntr = s.lcstack[s.lstkp];
    else s.lcntr = 32'hFFFF_FFFF;
    s.stky = s.stky & ~LSEM;
endtask

task automatic pop_loop(inout st_t s);                                        // 1148
    s.lstkp = s.lstkp - 1;
    s.lcntr = s.curlcntr;
    s.lastack[s.lstkp] = laddr_pack(s.laddr);
    if (s.lstkp > 0) begin
        s.curlcntr = s.lcstack[s.lstkp - 1];
        s.laddr = laddr_unpack(s.lastack[s.lstkp - 1]);
    end else begin
        s.curlcntr = 32'hFFFF_FFFF;
        s.laddr = laddr_unpack(32'hFFFF_FFFF);
        s.stky = s.stky | LSEM;
    end
endtask

function automatic logic [31:0] astat_read(input st_t s);                     // GET_UREG ASTAT
    logic [31:0] r;
    r = s.astat & ({28'h0, s.mode2[18:15]} << 19 | ~FLGS);
    for (int i = 0; i < 4; i++)
        if (!s.mode2[15 + i]) r = r | ({31'h0, s.flag[i]} << (19 + i));
    astat_read = r;
endfunction

task automatic push_status(inout st_t s);                                     // 1172
    s.status_stkp = s.status_stkp + 1;
    s.ss_mode1[s.status_stkp - 1] = s.mode1;
    s.ss_astat[s.status_stkp - 1] = astat_read(s);
    s.stky = s.stky & ~SSEM;
endtask

task automatic pop_status(inout st_t s);                                      // 1184
    s.status_stkp = s.status_stkp - 1;
    set_ureg(s, 8'h7b, s.ss_mode1[s.status_stkp]);
    set_ureg(s, 8'h7c, (s.astat & FLGS) | (s.ss_astat[s.status_stkp] & ~FLGS));
    if (s.status_stkp == 0) s.stky = s.stky | SSEM;
endtask

task automatic check_interrupts(inout st_t s);                                // sharc.cpp:1194
    if ((s.imask & s.irq_pending) != 0 && (s.mode1 & MODE1_IRPTEN) != 0 && !s.interrupt_active &&
        s.pc != s.delay_slot1 && s.pc != s.delay_slot2) begin
        logic [4:0] which;
        which = 5'd0;
        for (int i = 31; i >= 0; i--) if (s.irq_pending[i]) which = 5'(i);
        push_pc(s);
        s.pcstk = s.idle ? s.pc + 1 : s.daddr;
        s.irptl = s.irptl | (32'h1 << which);
        if (which >= 6 && which <= 8) push_status(s);
        change_pc(s, 32'h20000 + {25'h0, which, 2'b00});
        s.active_irq_num = {27'h0, which};
        s.irq_pending = s.irq_pending & ~(32'h1 << which);
        s.interrupt_active = 1'b1;
    end
endtask

// ------------------------------------------------------------------------------------------
// Universal registers
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] get_ureg(input st_t s, input logic [7:0] u);   // 215
    logic [2:0] k;
    k = u[2:0];
    case (u[7:4])
    4'h0: get_ureg = s.r[u[3:0]];
    4'h1: get_ureg = u[3] ? s.i2[k] : s.i1[k];
    4'h2: get_ureg = u[3] ? {{8{s.m2[k][23]}}, s.m2[k][23:0]} : s.m1[k];
    4'h3: get_ureg = u[3] ? s.l2[k] : s.l1[k];
    4'h4: get_ureg = u[3] ? s.b2[k] : s.b1[k];
    4'h6: case (u[3:0])
          4'h4: get_ureg = s.pcstk;
          4'h5: get_ureg = s.pcstkp;
          4'h7: get_ureg = s.curlcntr;
          4'h8: get_ureg = s.lcntr;
          default: get_ureg = 32'h0;
          endcase
    4'h7: case (u[3:0])
          4'h0: get_ureg = s.ustat1;
          4'h1: get_ureg = s.ustat2;
          4'h9: get_ureg = s.irptl;
          4'ha: get_ureg = s.mode2;
          4'hb: get_ureg = s.mode1;
          4'hc: get_ureg = astat_read(s);
          4'hd: get_ureg = s.imask;
          4'he: get_ureg = s.stky;
          default: get_ureg = 32'h0;
          endcase
    4'hd: case (u[3:0])
          4'hb: get_ureg = s.px[31:0];
          4'hc: get_ureg = {16'h0, s.px[15:0]};
          4'hd: get_ureg = s.px[47:16];
          default: get_ureg = 32'h0;
          endcase
    default: get_ureg = 32'h0;
    endcase
endfunction

task automatic add_latency(inout st_t s, input logic [31:0] reg_, input logic [31:0] data,
                           input logic [31:0] prev);                          // 69
    if (s.lat_cycles > 0) sysreg_latency_effect(s);
    s.lat_cycles = 2;
    s.lat_reg = reg_;
    s.lat_data = data;
    s.lat_prev = prev;
endtask

task automatic sysreg_latency_effect(inout st_t s);                           // 83
    logic [31:0] diff;
    diff = s.lat_data ^ s.lat_prev;
    s.mode1 = s.lat_data;
    if (diff & MODE1_SRD1H) for (int k = 4; k < 8; k++) begin
        {s.i1[k], s.i1a[k]} = {s.i1a[k], s.i1[k]}; {s.m1[k], s.m1a[k]} = {s.m1a[k], s.m1[k]};
        {s.l1[k], s.l1a[k]} = {s.l1a[k], s.l1[k]}; {s.b1[k], s.b1a[k]} = {s.b1a[k], s.b1[k]};
    end
    if (diff & MODE1_SRD1L) for (int k = 0; k < 4; k++) begin
        {s.i1[k], s.i1a[k]} = {s.i1a[k], s.i1[k]}; {s.m1[k], s.m1a[k]} = {s.m1a[k], s.m1[k]};
        {s.l1[k], s.l1a[k]} = {s.l1a[k], s.l1[k]}; {s.b1[k], s.b1a[k]} = {s.b1a[k], s.b1[k]};
    end
    if (diff & MODE1_SRD2H) for (int k = 4; k < 8; k++) begin
        {s.i2[k], s.i2a[k]} = {s.i2a[k], s.i2[k]}; {s.m2[k], s.m2a[k]} = {s.m2a[k], s.m2[k]};
        {s.l2[k], s.l2a[k]} = {s.l2a[k], s.l2[k]}; {s.b2[k], s.b2a[k]} = {s.b2a[k], s.b2[k]};
    end
    if (diff & MODE1_SRD2L) for (int k = 0; k < 4; k++) begin
        {s.i2[k], s.i2a[k]} = {s.i2a[k], s.i2[k]}; {s.m2[k], s.m2a[k]} = {s.m2a[k], s.m2[k]};
        {s.l2[k], s.l2a[k]} = {s.l2a[k], s.l2[k]}; {s.b2[k], s.b2a[k]} = {s.b2a[k], s.b2[k]};
    end
    if (diff & MODE1_SRRFH) for (int k = 8; k < 16; k++) {s.r[k], s.ralt[k]} = {s.ralt[k], s.r[k]};
    if (diff & MODE1_SRRFL) for (int k = 0; k < 8; k++)  {s.r[k], s.ralt[k]} = {s.ralt[k], s.r[k]};
    // BR8, BR0, SRCU and SSE are fatal or unused in MAME's gradius4 run (HACKS.md)
    s.lat_reg = 32'hFFFF_FFFF;
endtask

task automatic set_ureg(inout st_t s, input logic [7:0] u, input logic [31:0] d);  // 333
    logic [2:0] k;
    k = u[2:0];
    case (u[7:4])
    4'h0: s.r[u[3:0]] = d;
    4'h1: if (u[3]) s.i2[k] = d; else s.i1[k] = d;
    4'h2: if (u[3]) s.m2[k] = d; else s.m1[k] = d;
    4'h3: if (u[3]) s.l2[k] = d; else s.l1[k] = d;
    4'h4: if (u[3]) begin s.b2[k] = d; s.i2[k] = d; end else begin s.b1[k] = d; s.i1[k] = d; end
    4'h6: case (u[3:0])
          4'h4: if (s.pcstkp > 0 && s.pcstkp < 31) s.pcstk = d & 32'h00FF_FFFF;
          4'h5: if (s.pcstkp < 31) begin
                    logic [31:0] prev;
                    prev = s.pcstkp;
                    s.pcstkp = d & 32'h1F;
                    if (prev > 0) s.pcstack[prev - 1] = s.pcstk;
                    if (prev < s.pcstkp) begin
                        s.pcstk = s.pcstack[s.pcstkp - 1];
                        s.stky = s.stky & ~PCEM;
                        if (s.pcstkp >= 30) s.stky = s.stky | PCFL;
                    end else if (prev > s.pcstkp) begin
                        if (s.pcstkp > 0) s.pcstk = s.pcstack[s.pcstkp - 1];
                        else begin s.pcstk = 32'h00FF_FFFF; s.stky = s.stky | PCEM; end
                        s.stky = s.stky & ~PCFL;
                    end
                end
          4'h7: if (s.lstkp > 0 && s.lstkp < 7) s.curlcntr = d;
          4'h8: if (s.lstkp < 6) s.lcntr = d;
          default: ;
          endcase
    4'h7: case (u[3:0])
          4'h0: s.ustat1 = d;
          4'h1: s.ustat2 = d;
          4'h9: s.irptl = d;
          4'ha: s.mode2 = d;               // flag output callbacks: the flags are not wired
          4'hb: begin add_latency(s, 32'hb, d, s.mode1); s.mode1 = d; end
          4'hc: s.astat = d;
          4'hd: begin check_interrupts(s); s.imask = d; end
          4'he: s.stky = (s.stky & (LSEM | 32'h0200_0000 | SSEM | SSOV | PCEM | PCFL)) |
                         (d & ~(LSEM | 32'h0200_0000 | SSEM | SSOV | PCEM | PCFL));
          default: ;
          endcase
    4'hd: case (u[3:0])
          4'hc: s.px = {s.px[47:16], d[15:0]};
          4'hd: s.px = {d, s.px[15:0]};
          default: ;
          endcase
    default: ;
    endcase
endtask

// ------------------------------------------------------------------------------------------
// DAG helpers
// ------------------------------------------------------------------------------------------

task automatic post_modify(inout st_t s, input logic pm, input logic [2:0] i, input logic [31:0] m);
    if (pm) begin
        s.i2[i] = s.i2[i] + m;
        if (s.l2[i] != 0) begin
            if (s.i2[i] > s.b2[i] + s.l2[i]) s.i2[i] = s.i2[i] - s.l2[i];
            else if (s.i2[i] < s.b2[i]) s.i2[i] = s.i2[i] + s.l2[i];
        end
    end else begin
        s.i1[i] = s.i1[i] + m;
        if (s.l1[i] != 0) begin
            if (s.i1[i] > s.b1[i] + s.l1[i]) s.i1[i] = s.i1[i] - s.l1[i];
            else if (s.i1[i] < s.b1[i]) s.i1[i] = s.i1[i] + s.l1[i];
        end
    end
endtask

task automatic apply_load(inout st_t s, input acc_t a, input logic [47:0] d);
    case (a.dest_kind)
    2'd0: s.r[a.dest[3:0]] = d[31:0];
    2'd1: set_ureg(s, a.dest, d[31:0]);
    2'd2: s.px = d;
    default: ;
    endcase
    if (a.post_mod) post_modify(s, a.post_pm, a.post_i, a.post_m);
endtask

// queue an access; loads carry their destination and post-modify
task automatic q_acc(inout acc_t a [2], inout logic [1:0] n, input acc_kind_t kind,
                     input logic [31:0] addr, input logic [47:0] wdata, input logic [1:0] dkind,
                     input logic [7:0] dest, input logic pmod, input logic ppm, input logic [2:0] pi,
                     input logic [31:0] pmv);
    acc_t e;
    e.valid = 1'b1; e.kind = kind; e.addr = addr; e.wdata = wdata;
    e.dest_kind = dkind; e.dest = dest;
    e.post_mod = pmod; e.post_pm = ppm; e.post_i = pi; e.post_m = pmv;
    a[n[0]] = e;
    n = n + 2'd1;
endtask

// ------------------------------------------------------------------------------------------
// Shifter (SHIFT_OPERATION_IMM, 515-727, and COMPUTE cu = 2, 910-1070)
// ------------------------------------------------------------------------------------------

task automatic shift_op(inout st_t s, input logic [5:0] sop, input logic [31:0] sval,
                        input logic imm, input logic [3:0] rn, input logic [3:0] rx);
    logic [31:0] x, r;
    logic signed [7:0] sh8;
    logic signed [31:0] sh;
    logic [5:0] bitn, len;
    x = s.r[rx];
    sh8 = sval[7:0];
    sh = imm ? {{24{sh8[7]}}, sh8} : $signed(sval);
    bitn = sval[5:0]; len = sval[11:6];
    s.astat = s.astat & ~(SZ | SV | SS);
    case (sop)
    6'h00, 6'h08: begin                                          // LSHIFT, OR LSHIFT
        logic signed [31:0] shx;
        shx = (sop == 6'h08 && !imm) ? {{24{sh8[7]}}, sh8} : sh;  // reg form of OR LSHIFT uses int8
        // the register form of OR LSHIFT shifts an int32: arithmetic
        if (shx < 0) r = (shx > -32) ? ((sop == 6'h08 && !imm) ? 32'($signed(x) >>> (-shx)) : x >> (-shx)) : 32'h0;
        else begin
            r = (shx < 32) ? x << shx : 32'h0;
            if (shx > 0) s.astat = s.astat | SV;
        end
        if (sop == 6'h08) begin
            if (imm) begin if (r == 0) s.astat = s.astat | SZ; s.r[rn] = s.r[rn] | r; end
            else begin s.r[rn] = s.r[rn] | r; if (s.r[rn] == 0) s.astat = s.astat | SZ; end
        end else begin s.r[rn] = r; if (r == 0) s.astat = s.astat | SZ; end
    end
    6'h01: begin                                                 // ASHIFT (immediate only)
        if (sh < 0) r = 32'($signed(x) >>> ((sh > -32) ? -sh : 31));
        else begin
            r = (sh < 32) ? x << sh : 32'h0;
            if (sh > 0) s.astat = s.astat | SV;
        end
        s.r[rn] = r; if (r == 0) s.astat = s.astat | SZ;
    end
    6'h02: begin                                                 // ROT
        logic [4:0] n5;
        n5 = sh[4:0];
        r = (x << n5) | (x >> (6'd32 - {1'b0, n5}));
        if (n5 == 0) r = x;
        if (!imm && sh > 0) s.astat = s.astat | SV;
        s.r[rn] = r; if (r == 0) s.astat = s.astat | SZ;
    end
    6'h10, 6'h11, 6'h12, 6'h13, 6'h19: begin                   // FEXT, FDEP and sign forms
        logic [31:0] mk;
        logic [5:0]  l;
        l = (len > 6'd32) ? 6'd32 : len;
        mk = (l >= 32) ? 32'hFFFF_FFFF : ((32'h1 << l) - 1);
        case (sop)
        6'h10: r = (len == 0 || bitn >= 32) ? 32'h0 : 32'($signed(x) >>> bitn) & mk;   // BIT() of an int32
        6'h11: r = (len == 0 || bitn >= 32) ? 32'h0 : (x & mk) << bitn;
        6'h12: begin
            if (len == 0 || bitn >= 32) r = 32'h0;
            else if (bitn + len > 32) r = x >> bitn;
            else begin
                logic [31:0] v;
                v = (x >> bitn) & mk;
                r = (l < 32 && v[l - 1]) ? (v | ~mk) : v;
            end
        end
        6'h13: begin
            logic [31:0] v;
            if (len == 0 || bitn >= 32) r = 32'h0;
            else begin
                v = x & mk;
                if (l < 32 && v[l - 1]) v = v | ~mk;
                r = v << bitn;
            end
        end
        default: r = s.r[rn] | ((len != 0 && bitn < 32) ? (x & mk) << bitn : 32'h0);
        endcase
        s.r[rn] = r;
        if (r == 0) s.astat = s.astat | SZ;
        if ({1'b0, bitn} + {1'b0, len} > 7'd32) s.astat = s.astat | SV;
    end
    6'h30, 6'h31, 6'h32: begin                                  // BSET, BCLR, BTGL
        r = x;
        if (sval < 32) begin
            case (sop)
            6'h30: r = r | (32'h1 << sval[4:0]);
            6'h31: r = r & ~(32'h1 << sval[4:0]);
            default: r = r ^ (32'h1 << sval[4:0]);
            endcase
        end else s.astat = s.astat | SV;
        s.r[rn] = r; if (r == 0) s.astat = s.astat | SZ;
    end
    6'h33: begin                                                 // BTST
        if (sval < 32) begin
            if ((x & (32'h1 << sval[4:0])) == 0) s.astat = s.astat | SZ;
        end else s.astat = s.astat | SZ | SV;
    end
    default: ;
    endcase
endtask

// ------------------------------------------------------------------------------------------
// Fixed-point ALU and multiplier (compute.hxx:462-786, 1335-1510)
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] saturate(input logic [31:0] r);
    saturate = {32{r[31]}} ^ 32'h8000_0000;
endfunction

task automatic alu_fixed(inout st_t s, input logic [7:0] op, input logic [3:0] rn,
                         input logic [3:0] rx, input logic [3:0] ry);
    logic [31:0] x, y, r;
    logic [31:0] c;
    logic sat, set_r;
    x = s.r[rx]; y = s.r[ry]; r = 32'h0;
    c = (s.astat & AC) ? 32'd1 : 32'd0;
    sat = (s.mode1 & MODE1_ALUSAT) != 0;
    set_r = 1'b1;
    s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
    case (op)
    8'h01, 8'h05, 8'h25, 8'h29: begin                // ADD, ADD+CI, Rx+CI, INC
        logic [31:0] yy;
        yy = (op == 8'h29) ? 32'd1 : (op == 8'h25) ? 32'd0 : y;
        r = x + yy + ((op == 8'h05 || op == 8'h25) ? c : 32'd0);
        if (~(x ^ yy) & (x ^ r) & 32'h8000_0000) begin s.astat |= AV; s.stky |= AOS; end
        if (r < x) s.astat |= AC;
        if (op == 8'h05 && c == 1 && y == 32'hFFFF_FFFF) s.astat |= AC;
        if (sat && (s.astat & AV)) r = saturate(r);
    end
    8'h02, 8'h06, 8'h26, 8'h2a: begin                // SUB, SUB+CI-1, Rx+CI-1, DEC
        logic [31:0] yy;
        yy = (op == 8'h2a) ? 32'd1 : (op == 8'h26) ? 32'd0 : y;
        r = x - yy;
        if (op == 8'h06 || op == 8'h26) r = r + c - 1;
        if ((x ^ yy) & (x ^ r) & 32'h8000_0000) begin s.astat |= AV; s.stky |= AOS; end
        if (op == 8'h06) begin
            if (c != 0 || y != 32'hFFFF_FFFF) begin if (r <= x) s.astat |= AC; end
        end else if (r <= x) s.astat |= AC;
        if (sat && (s.astat & AV)) r = saturate(r);
    end
    8'h0a: begin                                     // COMP
        logic [31:0] acc;
        set_r = 1'b0;
        if (x == y) s.astat |= AZ;
        else if ($signed(x) < $signed(y)) s.astat |= AN;
        acc = (s.astat >> 1) & 32'h7F00_0000;
        if ((s.astat & (AZ | AN)) == 0) acc |= 32'h8000_0000;
        s.astat = (s.astat & 32'h00FF_FFFF) | acc;
    end
    8'h21: r = x;                                    // PASS
    8'h22: begin                                     // NEG
        r = -x;
        if ((32'h0 ^ x) & (32'h0 ^ r) & 32'h8000_0000) begin s.astat |= AV; s.stky |= AOS; end
        if (r <= 32'h0) s.astat |= AC;
        if (sat && (s.astat & AV)) r = saturate(r);
    end
    8'h30: begin                                     // ABS
        r = x[31] ? -x : x;
        if (r[31]) begin s.astat |= AV; s.stky |= AOS; if (sat) r = 32'h7FFF_FFFF; end
        if (x[31]) s.astat |= AS;
    end
    8'h40: r = x & y;
    8'h41: r = x | y;
    8'h42: r = x ^ y;
    8'h43: r = ~x;
    8'h61: r = ($signed(x) < $signed(y)) ? x : y;    // MIN
    8'h62: r = ($signed(x) < $signed(y)) ? y : x;    // MAX
    8'h63: begin                                     // CLIP
        logic [31:0] ay;
        ay = y[31] ? -y : y;
        r = ($signed(x) < -$signed(ay)) ? -ay : ($signed(ay) < $signed(x)) ? ay : x;
    end
    default: set_r = 1'b0;
    endcase
    if (set_r) begin
        if (r[31]) s.astat |= AN;
        if (r == 0) s.astat |= AZ;
        s.r[rn] = r;
    end
    s.astat = s.astat & ~AF;
endtask

task automatic mul_flags(inout st_t s, input logic [63:0] r);
    s.astat = s.astat & ~(MN | MV | MU | MI);
    if (r[31]) s.astat |= MN;
    if (r[63:32] != 0 && r[63:32] != 32'hFFFF_FFFF) s.astat |= MV;
    if (r[63:32] == 0 && r[31:0] != 0) s.astat |= MU;
endtask

// ------------------------------------------------------------------------------------------
// COMPUTE (731-1076)
// ------------------------------------------------------------------------------------------

task automatic fp_apply(inout st_t s, input fres_t o, input logic [3:0] rn, input logic mul);
    s.r[rn] = o.r;
    s.astat = s.astat | o.astat;
    s.stky = s.stky | o.stky;
endtask

task automatic compute(inout st_t s, input logic [22:0] opc);
    logic [7:0] op;
    logic [1:0] cu;
    logic [3:0] rn, rx, ry;
    logic trunc;
    op = opc[19:12]; cu = opc[21:20];
    rn = opc[11:8]; rx = opc[7:4]; ry = opc[3:0];
    trunc = (s.mode1 & MODE1_TRUNCATE) != 0;
    if (opc[22]) begin
        // multifunction
        logic [3:0] fm, fa;
        logic [3:0] fxm, fym, fxa, fya;
        logic [5:0] mop;
        fm = opc[15:12]; fa = opc[11:8];
        fxm = {2'b00, opc[7:6]}; fym = {2'b01, opc[5:4]};
        fxa = {2'b10, opc[3:2]}; fya = {2'b11, opc[1:0]};
        mop = opc[21:16];
        case (mop)
        6'h00: begin                                             // MR -> reg
            logic [31:0] v;
            case (op[3:0])
            4'd0: v = s.mrf[31:0];
            4'd1: v = s.mrf[63:32];
            4'd4: v = s.mrb[31:0];
            default: v = s.mrb[63:32];
            endcase
            set_ureg(s, {4'h0, rn}, v);
            s.astat = s.astat & ~(MN | MV | MU | MI);
        end
        6'h01: begin                                             // reg -> MR
            logic [31:0] v;
            v = get_ureg(s, {4'h0, rn});
            case (op[3:0])
            4'd0: s.mrf[31:0] = v;
            4'd1: s.mrf[63:32] = v;
            4'd4: s.mrb[31:0] = v;
            default: s.mrb[63:32] = v;
            endcase
            s.astat = s.astat & ~(MN | MV | MU | MI);
        end
        6'h04, 6'h05: begin                                      // Rm = Rxm*Rym (SSFR), Ra = Rxa +- Rya
            logic signed [63:0] p;
            logic [31:0] rm, ra, x, y;
            p = $signed(s.r[fxm]) * $signed(s.r[fym]);
            rm = 32'(p >>> 31);
            x = s.r[fxa]; y = s.r[fya];
            ra = (mop == 6'h04) ? x + y : x - y;
            s.astat = s.astat & ~(MN | MV | MU | MI);
            if (rm[31]) s.astat |= MN;
            s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
            if (ra[31]) s.astat |= AN;
            if (ra == 0) s.astat |= AZ;
            if (mop == 6'h04) begin
                if (~(x ^ y) & (x ^ ra) & 32'h8000_0000) begin s.astat |= AV; s.stky |= AOS; end
                if (ra < x) s.astat |= AC;
            end else begin
                if ((x ^ y) & (x ^ ra) & 32'h8000_0000) begin s.astat |= AV; s.stky |= AOS; end
                if (ra <= x) s.astat |= AC;
            end
            s.r[fm] = rm; s.r[fa] = ra;
            s.astat = s.astat & ~AF;
        end
        6'h18, 6'h19, 6'h1a, 6'h1b, 6'h1c, 6'h1d, 6'h1e, 6'h1f: begin
            fres_t mr, ar;
            s.astat = s.astat & ~(MN | MV | MU | MI);
            s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
            mr = x_mul(s.r[fxm], s.r[fym], trunc);
            case (mop)
            6'h18: ar = x_add(s.r[fxa], s.r[fya], trunc);
            6'h19: ar = x_sub(s.r[fxa], s.r[fya], trunc);
            6'h1a: ar = x_float(s.r[fxa], 1'b1, s.r[fya], 1'b1, trunc);
            6'h1b: ar = x_fix(s.r[fxa], 1'b1, s.r[fya], trunc, 1'b1);
            6'h1c: ar = x_avg(s.r[fxa], s.r[fya], trunc);
            6'h1d: ar = f_abs(s.r[fxa]);
            6'h1e: ar = x_minmax(s.r[fxa], s.r[fya], 1'b1);
            default: ar = x_minmax(s.r[fxa], s.r[fya], 1'b0);
            endcase
            s.astat = s.astat | mr.astat | ar.astat;
            s.stky = s.stky | mr.stky | ar.stky;
            s.r[fm] = mr.r; s.r[fa] = ar.r;
        end
        default: if (mop[5:4] == 2'b11) begin                  // FMUL + dual FADD/FSUB
            fres_t mr;
            fdual_t d;
            logic [3:0] fs;
            fs = opc[19:16];
            s.astat = s.astat & ~(MN | MV | MU | MI);
            s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
            mr = x_mul(s.r[fxm], s.r[fym], trunc);
            d = x_addsub(s.r[fxa], s.r[fya], trunc);
            s.astat = s.astat | mr.astat | d.astat;
            s.stky = s.stky | mr.stky | d.stky;
            s.r[fm] = mr.r; s.r[fa] = d.add; s.r[fs] = d.sub;
        end
        endcase
    end else begin
        case (cu)
        2'd0: begin
            if (op[7] == 1'b0 && !(op >= 8'h70 && op <= 8'h7f))
                alu_fixed(s, op, rn, rx, ry);
            else if (op >= 8'h70 && op <= 8'h7f) begin           // fixed dual add/sub
                logic [3:0] rs_, ra_;
                logic [31:0] x, y, ad, sb;
                logic avd, avs;
                rs_ = opc[15:12]; ra_ = opc[11:8];
                x = s.r[rx]; y = s.r[ry];
                ad = x + y; sb = x - y;
                avd = (~(x ^ y) & (x ^ ad) & 32'h8000_0000) != 0;
                avs = ((x ^ y) & (x ^ sb) & 32'h8000_0000) != 0;
                s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
                if (avd || avs) begin s.astat |= AV; s.stky |= AOS; end
                if (ad < x || sb <= x) s.astat |= AC;
                if (s.mode1 & MODE1_ALUSAT) begin
                    if (avd) ad = saturate(ad);
                    if (avs) sb = saturate(sb);
                end
                if (ad == 0 || sb == 0) s.astat |= AZ;
                if ((ad | sb) & 32'h8000_0000) s.astat |= AN;
                s.r[ra_] = ad; s.r[rs_] = sb;
                s.astat = s.astat & ~AF;
            end else if (op[7:4] == 4'hf) begin                   // float dual add/sub
                fdual_t d;
                logic [3:0] rs_, ra_;
                rs_ = opc[15:12]; ra_ = opc[11:8];
                s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
                d = x_addsub(s.r[rx], s.r[ry], trunc);
                s.astat |= d.astat; s.stky |= d.stky;
                s.r[ra_] = d.add; s.r[rs_] = d.sub;
            end else begin
                fres_t o;
                logic wr;
                s.astat = s.astat & ~(AZ | AN | AV | AC | AS | AI);
                wr = 1'b1;
                case (op)
                8'h81: o = x_add(s.r[rx], s.r[ry], trunc);
                8'h82: o = x_sub(s.r[rx], s.r[ry], trunc);
                8'h89: o = x_avg(s.r[rx], s.r[ry], trunc);
                8'h8a: begin o = x_comp(s.r[rx], s.r[ry], s.astat); wr = 1'b0;
                             s.astat = (s.astat & 32'h00FF_FFFF) | (o.r & 32'hFF00_0000); end
                // ABS(Fx + Fy), ABS(Fx - Fy) (compute.hxx:806-884): the flags of the magnitude,
                // so never AN; a NaN result stays the canonical NaN
                8'h91: begin o = x_add(s.r[rx], s.r[ry], trunc);
                             if ((o.astat & AI) == 0) o.r = o.r & ~SIGN;
                             o.astat = o.astat & ~AN; end
                8'h92: begin o = x_sub(s.r[rx], s.r[ry], trunc);
                             if ((o.astat & AI) == 0) o.r = o.r & ~SIGN;
                             o.astat = o.astat & ~AN; end
                8'ha1: o = f_pass(s.r[rx]);
                8'ha2: o = f_neg(s.r[rx]);
                8'hb0: o = f_abs(s.r[rx]);
                8'hbd: o = x_scalb(s.r[rx], s.r[ry]);
                8'hc1: o = x_logb(s.r[rx]);
                8'hc4: o = x_recips(s.r[rx]);
                8'hc5: o = x_rsqrts(s.r[rx]);
                8'hc9: o = x_fix(s.r[rx], 1'b0, 32'h0, trunc, 1'b0);
                8'hca: o = x_float(s.r[rx], 1'b0, 32'h0, 1'b0, trunc);
                8'hd9: o = x_fix(s.r[rx], 1'b1, s.r[ry], trunc, 1'b0);
                8'hda: o = x_float(s.r[rx], 1'b1, s.r[ry], 1'b0, trunc);
                8'he0: o = f_copysign(s.r[rx], s.r[ry]);
                8'he1: o = x_minmax(s.r[rx], s.r[ry], 1'b0);
                8'he2: o = x_minmax(s.r[rx], s.r[ry], 1'b1);
                8'he3: o = f_clip(s.r[rx], s.r[ry]);
                default: begin o = '0; wr = 1'b0; end
                endcase
                if (op != 8'h8a) begin s.astat |= o.astat; s.stky |= o.stky; end
                else begin s.astat |= o.astat; s.stky |= o.stky; end
                if (wr) s.r[rn] = o.r;
            end
        end
        2'd1: begin
            case (op)
            8'h14: s.mrf = 64'h0;
            8'h16: s.mrb = 64'h0;
            8'h30: begin
                fres_t o;
                s.astat = s.astat & ~(MN | MV | MU | MI);
                o = x_mul(s.r[rx], s.r[ry], trunc);
                s.astat |= o.astat; s.stky |= o.stky; s.r[rn] = o.r;
            end
            8'h40: begin
                logic [63:0] p;
                p = {32'h0, s.r[rx]} * {32'h0, s.r[ry]};
                mul_flags(s, p); s.r[rn] = p[31:0];
            end
            8'h70: begin
                logic signed [63:0] p;
                p = $signed(s.r[rx]) * $signed(s.r[ry]);
                mul_flags(s, p); s.r[rn] = p[31:0];
            end
            8'hb0, 8'hb2: begin
                logic signed [63:0] p;
                p = ((op == 8'hb0) ? s.mrf : s.mrb) + $signed(s.r[rx]) * $signed(s.r[ry]);
                mul_flags(s, p); s.r[rn] = p[31:0];
            end
            default: ;
            endcase
        end
        2'd2: shift_op(s, op[7:2], s.r[ry], 1'b0, rn, rx);
        default: ;
        endcase
    end
endtask

// ------------------------------------------------------------------------------------------
// Opcode handlers (1283-2600), memory accesses queued for P_MEM
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] sext24(input logic [23:0] v);
    sext24 = {{8{v[23]}}, v};
endfunction
function automatic logic [31:0] sext6(input logic [5:0] v);
    sext6 = {{26{v[5]}}, v};
endfunction

task automatic clear_int(inout st_t s);          // the CI bit of a jump
    if (s.active_irq_num >= 6 && s.active_irq_num <= 8) pop_status(s);
    s.interrupt_active = 1'b0;
    s.irptl = s.irptl & ~(32'h1 << s.active_irq_num[4:0]);
endtask

task automatic jump_to(inout st_t s, input logic j, input logic [31:0] addr);
    if (j) change_pc_delayed(s, addr); else change_pc(s, addr);
endtask

// The fields compute writes, taken from the shared compute's result
task automatic apply_compute(inout st_t s, input st_t sc);
    s.r = sc.r; s.mrf = sc.mrf; s.mrb = sc.mrb; s.astat = sc.astat; s.stky = sc.stky;
endtask

task automatic execute_op(inout st_t s, input logic [47:0] op, inout acc_t a [2],
                          inout logic [1:0] n);
    logic [4:0]  cond;
    logic [22:0] comp;
    logic [2:0]  dmi, dmm, pmi, pmm, i, m;
    logic        j, e, ci, la;
    st_t         sc;
    cond = op[37:33];
    comp = op[22:0];
    dmi = op[43:41]; dmm = op[40:38]; pmi = op[32:30]; pmm = op[29:27];
    i = op[43:41]; m = op[40:38];
    j = op[26]; e = op[25]; ci = op[24]; la = op[38];

    // One compute unit: every form computes on the state it starts with, except the indirect
    // jumps with CI, which clear the interrupt (and may pop the status stack) first. Each form
    // below applies the result where MAME's handler calls compute.
    sc = s;
    if ((op[47:39] == 9'b000010000 || op[47:39] == 9'b000010010) && ci) clear_int(sc);
    if (comp != 0) compute(sc, comp);

    casez (op[47:39])
    // compute / dreg <-> DM / dreg <-> PM
    9'b001??????: begin
        logic [3:0]  pmd_r, dmd_r;
        logic [31:0] pv, dv;
        pmd_r = op[26:23]; dmd_r = op[36:33];
        pv = s.r[pmd_r]; dv = s.r[dmd_r];
        if (comp != 0) apply_compute(s, sc);
        if (op[37]) q_acc(a, n, A_PM_WR32, s.i2[pmi], {pv, 16'h0}, 2'd3, 8'h0, 1'b1, 1'b1, pmi, s.m2[pmm]);
        else        q_acc(a, n, A_PM_RD32, s.i2[pmi], 48'h0, 2'd0, {4'h0, pmd_r}, 1'b1, 1'b1, pmi, s.m2[pmm]);
        if (op[44]) q_acc(a, n, A_DM_WR, s.i1[dmi], {16'h0, dv}, 2'd3, 8'h0, 1'b1, 1'b0, dmi, s.m1[dmm]);
        else        q_acc(a, n, A_DM_RD, s.i1[dmi], 48'h0, 2'd0, {4'h0, dmd_r}, 1'b1, 1'b0, dmi, s.m1[dmm]);
    end
    // compute
    9'b000000010, 9'b000000011: if (if_cond(s, cond) && comp != 0) apply_compute(s, sc);
    // compute / ureg <-> DM|PM, pre-modify (0) or post-modify (1)
    9'b0100?????, 9'b0101?????: begin
        logic g, d, post;
        logic [7:0] u;
        logic [31:0] uv, ad, mv;
        g = op[32]; d = op[31]; u = op[30:23]; post = op[44];
        if (if_cond(s, op[37:33])) begin
            uv = get_ureg(s, u);
            if (comp != 0) apply_compute(s, sc);
            mv = g ? s.m2[m] : s.m1[m];
            ad = (g ? s.i2[i] : s.i1[i]) + (post ? 32'h0 : mv);
            if (g) begin
                if (d) q_acc(a, n, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, ad,
                             (u == 8'hdb) ? s.px : {uv, 16'h0}, 2'd3, 8'h0, post, 1'b1, i, mv);
                else   q_acc(a, n, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, ad, 48'h0,
                             (u == 8'hdb) ? 2'd2 : 2'd1, u, post, 1'b1, i, mv);
            end else begin
                if (d) q_acc(a, n, A_DM_WR, ad, {16'h0, uv}, 2'd3, 8'h0, post, 1'b0, i, mv);
                else   q_acc(a, n, A_DM_RD, ad, 48'h0, 2'd1, u, post, 1'b0, i, mv);
            end
        end
    end
    // compute / dreg <-> DM|PM, immediate modify
    9'b0110???0?, 9'b0110???1?: begin
        logic u, g, d;
        logic [3:0] dr;
        logic [31:0] dv, mv, ad;
        u = op[38]; g = op[40]; d = op[39]; dr = op[26:23];
        mv = sext6(op[32:27]);
        dv = s.r[dr];
        if (if_cond(s, cond)) begin
            if (comp != 0) apply_compute(s, sc);
            ad = (g ? s.i2[i] : s.i1[i]) + (u ? 32'h0 : mv);
            if (g) begin
                if (d) q_acc(a, n, A_PM_WR32, ad, {dv, 16'h0}, 2'd3, 8'h0, u, 1'b1, i, mv);
                else   q_acc(a, n, A_PM_RD32, ad, 48'h0, 2'd0, {4'h0, dr}, u, 1'b1, i, mv);
            end else begin
                if (d) q_acc(a, n, A_DM_WR, ad, {16'h0, dv}, 2'd3, 8'h0, u, 1'b0, i, mv);
                else   q_acc(a, n, A_DM_RD, ad, 48'h0, 2'd0, {4'h0, dr}, u, 1'b0, i, mv);
            end
        end
    end
    // compute / ureg <-> ureg
    9'b0111?????: if (if_cond(s, op[35:31])) begin
        logic [31:0] v;
        v = get_ureg(s, op[43:36]);
        if (comp != 0) apply_compute(s, sc);
        set_ureg(s, op[30:23], v);
    end
    // immediate shift / dreg <-> DM|PM
    9'b1000?????: begin
        logic g, d;
        logic [3:0] dr;
        logic [31:0] dv, mv;
        logic [11:0] data;
        g = op[32]; d = op[31]; dr = op[26:23];
        data = {op[30:27], op[15:8]};
        if (if_cond(s, cond)) begin
            dv = s.r[dr];
            shift_op(s, op[21:16], {20'h0, data}, 1'b1, op[7:4], op[3:0]);
            mv = g ? s.m2[m] : s.m1[m];
            if (g) begin
                if (d) q_acc(a, n, A_PM_WR32, s.i2[i], {dv, 16'h0}, 2'd3, 8'h0, 1'b1, 1'b1, i, mv);
                else   q_acc(a, n, A_PM_RD32, s.i2[i], 48'h0, 2'd0, {4'h0, dr}, 1'b1, 1'b1, i, mv);
            end else begin
                if (d) q_acc(a, n, A_DM_WR, s.i1[i], {16'h0, dv}, 2'd3, 8'h0, 1'b1, 1'b0, i, mv);
                else   q_acc(a, n, A_DM_RD, s.i1[i], 48'h0, 2'd0, {4'h0, dr}, 1'b1, 1'b0, i, mv);
            end
        end
    end
    // immediate shift
    9'b000000100, 9'b000000101: if (if_cond(s, cond))
        shift_op(s, op[21:16], {20'h0, op[30:27], op[15:8]}, 1'b1, op[7:4], op[3:0]);
    // compute / modify
    9'b000001000, 9'b000001001: if (if_cond(s, cond)) begin
        if (comp != 0) apply_compute(s, sc);
        post_modify(s, op[38], op[32:30], op[38] ? s.m2[op[29:27]] : s.m1[op[29:27]]);
    end
    // direct jump / call, absolute (0x0600, 0x0680)
    9'b000001100: if (if_cond(s, cond)) begin
        if (ci) clear_int(s);
        if (la) begin logic [31:0] t; pop_pc(s, t); pop_loop(s); end
        jump_to(s, j, {8'h0, op[23:0]});
    end
    9'b000001101: if (if_cond(s, cond)) begin
        push_pc(s);
        s.pcstk = j ? s.nfaddr : s.daddr;
        jump_to(s, j, {8'h0, op[23:0]});
    end
    // direct jump / call, relative (0x0700, 0x0780)
    9'b000001110: if (if_cond(s, cond)) begin
        if (ci) clear_int(s);
        if (la) begin logic [31:0] t; pop_pc(s, t); pop_loop(s); end
        jump_to(s, j, s.pc + sext24(op[23:0]));
    end
    9'b000001111: if (if_cond(s, cond)) begin
        push_pc(s);
        s.pcstk = j ? s.pc + 3 : s.pc + 1;
        jump_to(s, j, s.pc + sext24(op[23:0]));
    end
    // indirect jump / call, relative jump / call with compute (0x0800-0x0980)
    9'b000010000, 9'b000010010: begin
        logic [31:0] t;
        t = op[40] ? s.pc + sext6(op[32:27]) : s.i2[pmi] + s.m2[pmm];
        if (ci) clear_int(s);
        if (e) begin
            if (if_cond(s, cond)) begin
                if (la) begin logic [31:0] v; pop_pc(s, v); pop_loop(s); end
                jump_to(s, j, t);
            end else if (comp != 0) apply_compute(s, sc);
        end else if (if_cond(s, cond)) begin
            if (comp != 0) apply_compute(s, sc);
            if (la) begin logic [31:0] v; pop_pc(s, v); pop_loop(s); end
            jump_to(s, j, t);
        end
    end
    9'b000010001, 9'b000010011: begin
        logic [31:0] t;
        t = op[40] ? s.pc + sext6(op[32:27]) : s.i2[pmi] + s.m2[pmm];
        if (e) begin
            if (if_cond(s, cond)) begin
                push_pc(s);
                s.pcstk = j ? s.nfaddr : s.daddr;
                jump_to(s, j, t);
            end else if (comp != 0) apply_compute(s, sc);
        end else if (if_cond(s, cond)) begin
            if (comp != 0) apply_compute(s, sc);
            push_pc(s);
            s.pcstk = j ? s.nfaddr : s.daddr;
            jump_to(s, j, t);
        end
    end
    // indirect / relative jump, else compute and dreg <-> DM (110, 111)
    9'b110??????, 9'b111??????: begin
        logic [3:0]  dr;
        logic [31:0] dv;
        dr = op[26:23];
        if (if_cond(s, cond)) change_pc(s, op[45] ? s.pc + sext6(op[32:27]) : s.i2[pmi] + s.m2[pmm]);
        else begin
            dv = s.r[dr];
            if (comp != 0) apply_compute(s, sc);
            if (op[44]) q_acc(a, n, A_DM_WR, s.i1[dmi], {16'h0, dv}, 2'd3, 8'h0, 1'b1, 1'b0, dmi, s.m1[dmm]);
            else        q_acc(a, n, A_DM_RD, s.i1[dmi], 48'h0, 2'd0, {4'h0, dr}, 1'b1, 1'b0, dmi, s.m1[dmm]);
        end
    end
    // RTS (0x0a00), RTI (0x0b00)
    9'b00001010?, 9'b00001011?: begin
        logic rti;
        logic [31:0] v;
        rti = op[40];
        if (rti) s.irptl = s.irptl & ~(32'h1 << s.active_irq_num[4:0]);
        if (e) begin
            if (if_cond(s, cond)) begin pop_pc(s, v); jump_to(s, j, v); end
            else if (comp != 0) apply_compute(s, sc);
        end else if (if_cond(s, cond)) begin
            if (comp != 0) apply_compute(s, sc);
            pop_pc(s, v); jump_to(s, j, v);
        end
        if (rti) begin
            if (s.active_irq_num >= 6 && s.active_irq_num <= 8) pop_status(s);
            s.interrupt_active = 1'b0;
            check_interrupts(s);
        end
    end
    // DO UNTIL: counter immediate (0x0c00), counter ureg (0x0d00), condition (0x0e00)
    9'b00001100?, 9'b00001101?, 9'b00001110?: begin
        logic [31:0] off, ldist;
        off = sext24(op[23:0]);
        ldist = off[31] ? -off : off;
        if (op[42:40] == 3'b100) s.lcntr = {16'h0, op[39:24]};
        else if (op[42:40] == 3'b101) s.lcntr = get_ureg(s, op[39:32]);
        push_pc(s);
        push_loop(s);
        s.pcstk = s.pc + 1;
        s.laddr.addr = s.pc + off;
        if (op[42:40] == 3'b110) begin
            s.laddr.code = cond;
            s.laddr.loop_type = 2'd0;
        end else begin
            s.laddr.code = 5'hf;
            s.laddr.loop_type = (ldist == 1) ? 2'd1 : (ldist == 2) ? 2'd2 : 2'd3;
        end
    end
    // imm -> ureg (0x0f00)
    9'b00001111?: set_ureg(s, op[39:32], op[31:0]);
    // ureg <-> DM|PM direct (0x1000-0x1300)
    9'b000100???: begin
        logic [7:0] u;
        u = op[39:32];
        case (op[41:40])
        2'b00: q_acc(a, n, A_DM_RD, op[31:0], 48'h0, 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0);
        2'b01: q_acc(a, n, A_DM_WR, op[31:0], {16'h0, get_ureg(s, u)}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0);
        2'b10: q_acc(a, n, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, op[31:0], 48'h0,
                     (u == 8'hdb) ? 2'd2 : 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0);
        default: q_acc(a, n, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, op[31:0],
                       (u == 8'hdb) ? s.px : {get_ureg(s, u), 16'h0}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0);
        endcase
    end
    // ureg <-> DM|PM indirect (101 g iii d)
    9'b101??????: begin
        logic [7:0] u;
        logic g, d;
        logic [31:0] ad;
        u = op[39:32]; g = op[44]; d = op[40];
        ad = g ? s.i2[i] + (d ? op[31:0] : {8'h0, op[23:0]}) : s.i1[i] + op[31:0];
        if (g) begin
            if (d) q_acc(a, n, (u == 8'hdb) ? A_PM_WR48 : A_PM_WR32, ad,
                         (u == 8'hdb) ? s.px : {get_ureg(s, u), 16'h0}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0);
            else   q_acc(a, n, (u == 8'hdb) ? A_PM_RD48 : A_PM_RD32, ad, 48'h0,
                         (u == 8'hdb) ? 2'd2 : 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0);
        end else begin
            if (d) q_acc(a, n, A_DM_WR, ad, {16'h0, get_ureg(s, u)}, 2'd3, 8'h0, 1'b0, 1'b0, 3'd0, 32'h0);
            else   q_acc(a, n, A_DM_RD, ad, 48'h0, 2'd1, u, 1'b0, 1'b0, 3'd0, 32'h0);
        end
    end
    // immediate data -> DM|PM (1001)
    9'b1001?????: begin
        logic g;
        g = op[37];
        if (g) q_acc(a, n, A_PM_WR32, s.i2[i], {op[31:0], 16'h0}, 2'd3, 8'h0, 1'b1, 1'b1, i, s.m2[m]);
        else   q_acc(a, n, A_DM_WR, s.i1[i], {16'h0, op[31:0]}, 2'd3, 8'h0, 1'b1, 1'b0, i, s.m1[m]);
    end
    // system register bit operation (0x1400)
    9'b00010100?: begin
        logic [31:0] src, d;
        logic [7:0]  u;
        u = {4'h7, op[35:32]};
        d = op[31:0];
        src = get_ureg(s, u);
        case (op[39:37])
        3'd0: src = src | d;
        3'd1: src = src & ~d;
        3'd2: src = src ^ d;
        3'd4: if ((src & d) == d) s.astat |= BTF; else s.astat &= ~BTF;
        3'd5: if (src == d) s.astat |= BTF; else s.astat &= ~BTF;
        default: ;
        endcase
        set_ureg(s, u, src);
    end
    // modify I (0x1600)
    9'b000101100: post_modify(s, op[38], op[34:32], op[31:0]);
    // push / pop stacks (0x1700)
    9'b00010111?: begin
        if (op[39]) push_loop(s);
        if (op[38]) pop_loop(s);
        if (op[37]) push_status(s);
        if (op[36]) pop_status(s);
        if (op[35]) push_pc(s);
        if (op[34]) begin logic [31:0] t; pop_pc(s, t); end
    end
    // NOP, IDLE
    9'b000000000: ;
    9'b000000001: begin
        s.daddr = s.pc; s.faddr = s.pc + 1; s.nfaddr = s.pc + 2;
        s.idle = 1'b1;
    end
    default: ;                                   // bit-reverse and the rest: fatal in MAME
    endcase
endtask

// ------------------------------------------------------------------------------------------
// IOP registers (sharc.cpp:355-445) and DMA (sharcdma.hxx)
// ------------------------------------------------------------------------------------------

function automatic logic [31:0] iop_read(input st_t s, input logic [7:0] a);
    iop_read = (a == 8'h37) ? s.dma_status : 32'h0;
endfunction

task automatic iop_write(inout st_t s, input logic [7:0] a, input logic [31:0] d);
    case (a)
    8'h00: s.syscon = d;
    8'h1c: begin s.dma_control[0] = d;
                 if (d[0]) begin s.iop_delay_reg = 32'h1c; s.iop_delay_data = d; s.iop_delay_cycles = 1; end end
    8'h1d: begin s.dma_control[1] = d;
                 if (d[0]) begin s.iop_delay_reg = 32'h1d; s.iop_delay_data = d; s.iop_delay_cycles = 30; end end
    8'h40: s.dma_int_index[0] = d;
    8'h41: s.dma_int_modifier[0] = d;
    8'h42: s.dma_int_count[0] = d;
    8'h43: s.dma_chain_ptr[0] = d;
    8'h44: s.dma_gen[0] = d;
    8'h45: s.dma_ext_index[0] = d;
    8'h46: s.dma_ext_modifier[0] = d;
    8'h47: s.dma_ext_count[0] = d;
    8'h48: s.dma_int_index[1] = d;
    8'h49: s.dma_int_modifier[1] = d;
    8'h4a: s.dma_int_count[1] = d;
    8'h4b: s.dma_chain_ptr[1] = d;
    8'h4c: s.dma_gen[1] = d;
    8'h4d: s.dma_ext_index[1] = d;
    8'h4e: s.dma_ext_modifier[1] = d;
    8'h4f: s.dma_ext_count[1] = d;
    default: ;
    endcase
endtask

// sharc_dma_exec (sharcdma.hxx:262-321); chained transfers start by reading their TCB, which
// the core does in P_DMA, so a chained start here only marks the channel to load it
task automatic dma_exec(inout st_t s, input logic ch);
    logic chen, xmit, dtype;
    chen = s.dma_control[ch][1]; xmit = s.dma_control[ch][2]; dtype = s.dma_control[ch][5];
    if (chen) begin
        s.op_chain_ptr[ch] = s.dma_chain_ptr[ch] & 32'h1FFFF;
        s.op_chain_dir[ch] = {31'h0, xmit};
        s.op_active[ch] = 1'b0;
        s.dma_status[6 + ch] = 1'b1;
        s.op_tcb[ch] = 1'b1;                  // P_DMA loads the TCB before any word moves
    end else begin
        if (xmit) begin
            s.op_dst[ch] = s.dma_ext_index[ch]; s.op_dst_mod[ch] = s.dma_ext_modifier[ch];
            s.op_dst_count[ch] = s.dma_ext_count[ch];
            s.op_src[ch] = (s.dma_int_index[ch] & 32'h1FFFF) | 32'h20000;
            s.op_src_mod[ch] = s.dma_int_modifier[ch]; s.op_src_count[ch] = s.dma_int_count[ch];
        end else begin
            s.op_src[ch] = s.dma_ext_index[ch]; s.op_src_mod[ch] = s.dma_ext_modifier[ch];
            s.op_src_count[ch] = s.dma_ext_count[ch];
            s.op_dst[ch] = (s.dma_int_index[ch] & 32'h1FFFF) | 32'h20000;
            s.op_dst_mod[ch] = s.dma_int_modifier[ch]; s.op_dst_count[ch] = s.dma_int_count[ch];
        end
        s.op_pmode[ch] = dtype ? 32'd4 : {30'h0, s.dma_control[ch][7:6]};
        s.op_chain_ptr[ch] = 32'h0;
        s.op_chained[ch] = 1'b0;
        s.op_active[ch] = 1'b1;
        s.dma_status[6 + ch] = 1'b1;
    end
endtask

// after the word is moved: counts, completion interrupt; returns whether to load a TCB
task automatic dma_advance(inout st_t s, input logic ch, input logic [2:0] reads, output logic chain);
    chain = 1'b0;
    // src moves a modifier per read (dma_run_cycle: src_modifier * 2, * 6)
    case (reads)
    3'd2:    s.op_src[ch] = s.op_src[ch] + (s.op_src_mod[ch] << 1);
    3'd6:    s.op_src[ch] = s.op_src[ch] + (s.op_src_mod[ch] << 2) + (s.op_src_mod[ch] << 1);
    default: s.op_src[ch] = s.op_src[ch] + s.op_src_mod[ch];
    endcase
    s.op_dst[ch] = s.op_dst[ch] + s.op_dst_mod[ch];
    s.op_src_count[ch] = s.op_src_count[ch] - {29'h0, reads};
    if ($signed(s.op_src_count[ch]) <= 0) begin
        s.dma_status[6 + ch] = 1'b0;
        s.op_active[ch] = 1'b0;
        if (!s.op_chained[ch] || s.op_chain_ptr[ch][17]) begin
            s.irptl[16 + ch] = 1'b1;
            if (s.imask[16 + ch]) s.irq_pending[16 + ch] = 1'b1;
        end
        if ((s.op_chain_ptr[ch] & 32'h1FFFF) != 0) begin
            chain = 1'b1;
            s.op_tcb[ch] = 1'b1;
            s.dma_status[6 + ch] = 1'b1;       // busy while the TCB loads
        end
    end
endtask


// schedule_chained_dma_op (sharcdma.hxx:11-63); t[k] is the word at op_ptr - k
task automatic schedule_chained(inout st_t s, input logic ch, input logic [7:0][31:0] t);
    if (s.op_chain_dir[ch][0]) begin
        s.op_dst[ch] = t[5]; s.op_dst_mod[ch] = t[6]; s.op_dst_count[ch] = t[7];
        s.op_src[ch] = t[0]; s.op_src_mod[ch] = t[1]; s.op_src_count[ch] = t[2];
    end else begin
        s.op_src[ch] = t[5]; s.op_src_mod[ch] = t[6]; s.op_src_count[ch] = t[7];
        s.op_dst[ch] = t[0]; s.op_dst_mod[ch] = t[1]; s.op_dst_count[ch] = t[2];
    end
    s.op_pmode[ch] = 32'h0;
    s.op_tcb[ch] = 1'b0;
    s.op_chain_ptr[ch] = t[3];
    s.op_chained[ch] = 1'b1;
    s.op_active[ch] = 1'b1;
    s.dma_status[6 + ch] = 1'b1;
endtask

// ------------------------------------------------------------------------------------------
// Bench and savestate access to the state (dbg_we)
// ------------------------------------------------------------------------------------------

task automatic dbg_write(input logic [7:0] sel, input logic [5:0] idx, input logic [63:0] d);
    case (sel)
    8'd0:  S.r[idx[3:0]] <= d[31:0];
    8'd1:  S.ralt[idx[3:0]] <= d[31:0];
    8'd2:  S.i1[idx[2:0]] <= d[31:0];
    8'd3:  S.m1[idx[2:0]] <= d[31:0];
    8'd4:  S.l1[idx[2:0]] <= d[31:0];
    8'd5:  S.b1[idx[2:0]] <= d[31:0];
    8'd6:  S.i2[idx[2:0]] <= d[31:0];
    8'd7:  S.m2[idx[2:0]] <= d[31:0];
    8'd8:  S.l2[idx[2:0]] <= d[31:0];
    8'd9:  S.b2[idx[2:0]] <= d[31:0];
    8'd10: S.i1a[idx[2:0]] <= d[31:0];
    8'd11: S.m1a[idx[2:0]] <= d[31:0];
    8'd12: S.l1a[idx[2:0]] <= d[31:0];
    8'd13: S.b1a[idx[2:0]] <= d[31:0];
    8'd14: S.i2a[idx[2:0]] <= d[31:0];
    8'd15: S.m2a[idx[2:0]] <= d[31:0];
    8'd16: S.l2a[idx[2:0]] <= d[31:0];
    8'd17: S.b2a[idx[2:0]] <= d[31:0];
    8'd18: S.mrf <= d;
    8'd19: S.mrb <= d;
    8'd20: S.px <= d[47:0];
    8'd21: S.pc <= d[31:0];
    8'd22: S.daddr <= d[31:0];
    8'd23: S.faddr <= d[31:0];
    8'd24: S.nfaddr <= d[31:0];
    8'd25: S.delay_slot1 <= d[31:0];
    8'd26: S.delay_slot2 <= d[31:0];
    8'd27: S.pcstk <= d[31:0];
    8'd28: S.pcstkp <= d[31:0];
    8'd29: S.pcstack[idx[4:0]] <= d[31:0];
    8'd30: S.lcstack[idx[2:0]] <= d[31:0];
    8'd31: S.lastack[idx[2:0]] <= d[31:0];
    8'd32: S.curlcntr <= d[31:0];
    8'd33: S.lcntr <= d[31:0];
    8'd34: S.lstkp <= d[31:0];
    8'd35: S.laddr <= laddr_unpack(d[31:0]);
    8'd36: S.ss_mode1[idx[2:0]] <= d[31:0];
    8'd37: S.ss_astat[idx[2:0]] <= d[31:0];
    8'd38: S.status_stkp <= d[31:0];
    8'd39: S.astat <= d[31:0];
    8'd40: S.astat_old <= d[31:0];
    8'd41: S.astat_old_old <= d[31:0];
    8'd42: S.astat_old_old_old <= d[31:0];
    8'd43: S.mode1 <= d[31:0];
    8'd44: S.mode2 <= d[31:0];
    8'd45: S.stky <= d[31:0];
    8'd46: S.irptl <= d[31:0];
    8'd47: S.imask <= d[31:0];
    8'd48: S.imaskp <= d[31:0];
    8'd49: S.ustat1 <= d[31:0];
    8'd50: S.ustat2 <= d[31:0];
    8'd51: S.flag[idx[1:0]] <= d[0];
    8'd52: S.syscon <= d[31:0];
    8'd53: S.sysstat <= d[31:0];
    8'd54: S.idle <= d[0];
    8'd55: S.irq_pending <= d[31:0];
    8'd56: S.active_irq_num <= d[31:0];
    8'd57: S.interrupt_active <= d[0];
    8'd58: S.lat_cycles <= d[31:0];
    8'd59: S.lat_reg <= d[31:0];
    8'd60: S.lat_data <= d[31:0];
    8'd61: S.lat_prev <= d[31:0];
    8'd62: S.dma_control[idx[0]] <= d[31:0];
    8'd63: S.dma_int_index[idx[0]] <= d[31:0];
    8'd64: S.dma_int_modifier[idx[0]] <= d[31:0];
    8'd65: S.dma_int_count[idx[0]] <= d[31:0];
    8'd66: S.dma_chain_ptr[idx[0]] <= d[31:0];
    8'd67: S.dma_gen[idx[0]] <= d[31:0];
    8'd68: S.dma_ext_index[idx[0]] <= d[31:0];
    8'd69: S.dma_ext_modifier[idx[0]] <= d[31:0];
    8'd70: S.dma_ext_count[idx[0]] <= d[31:0];
    8'd71: S.op_active[idx[0]] <= d[0];
    8'd72: S.op_chained[idx[0]] <= d[0];
    8'd73: S.op_src[idx[0]] <= d[31:0];
    8'd74: S.op_dst[idx[0]] <= d[31:0];
    8'd75: S.op_src_mod[idx[0]] <= d[31:0];
    8'd76: S.op_dst_mod[idx[0]] <= d[31:0];
    8'd77: S.op_src_count[idx[0]] <= d[31:0];
    8'd78: S.op_dst_count[idx[0]] <= d[31:0];
    8'd79: S.op_pmode[idx[0]] <= d[31:0];
    8'd80: S.op_chain_ptr[idx[0]] <= d[31:0];
    8'd81: S.op_chain_dir[idx[0]] <= d[31:0];
    8'd82: S.dma_status <= d[31:0];
    8'd83: S.iop_delay_cycles <= d[31:0];
    8'd84: S.iop_delay_reg <= d[31:0];
    8'd85: S.iop_delay_data <= d[31:0];
    8'd86: S.op_tcb[idx[0]] <= d[0];
    8'd255: ph <= P_FETCH;                         // start executing
    default: ;
    endcase
endtask
