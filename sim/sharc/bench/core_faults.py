#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: planted faults in m2b_sharc. Each is one edit to a
# copy of rtl/sharc; the replay bench (MAME rounding, the MAME trace) is built from the copy and
# run on Dead or Alive's capture for a fixed number of words, and must FAIL. The real rtl/sharc
# is never touched. A fault the bench misses is reported, not hidden: DOA may not exercise it.
#   core_faults.py <work dir> <events.bin> <strace.bin> [words]
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
RTL = os.path.join(ROOT, 'rtl', 'sharc')

F = 'm2b_sharc.sv'
XU = 'm2b_sharc_xu.sv'
FAULTS = [
    ('scoreboard off (D never waits)', F, "d_wait = hit || (ld_on && d_need_astat) || ir_pw || (ld_on && ld_mwe && ld_awe);", "d_wait = 1'b0;"),
    ('scoreboard: ASTAT not waited on', F, "d_wait = hit || (ld_on && d_need_astat) || ir_pw", "d_wait = hit || ir_pw"),
    ('loop end: ASTAT history one word off', F, "ca = (st == ST_D && ld_on) ? ah2 : ah3;", "ca = (st == ST_D && ld_on) ? ah1 : ah2;"),
    ('a load no longer wins over the float result', F, "if (x.ld_r && x.ld_dst == x.rm) x.rm_we = 1'b0;", ""),
    ('post-modify before the load (same I)', F, "base = (xi_u && iu == XC.pmod_i) ? xu_v : XC.pmod_b;", "base = XC.pmod_b;"),
    ('delayed branch taken at once', F, "    if (br && !br_db) begin", "    if (br) begin"),
    ('CALL pushes the wrong return (daddr for nfaddr)', F, "(jdb ? s.nfaddr : s.daddr);\n            // PUSH_PC", "(jdb ? s.daddr : s.daddr);\n            // PUSH_PC"),
    ('counted loop: one iteration short', F, "done = s.curlcntr == 32'd0;", "done = s.curlcntr == 32'd1;"),
    ('fixed ALU: AC not set on a subtract', XU, "        if (ad_co) a |= AC;", "        if (ad_co && !k_sub) a |= AC;"),
    ('shifter: LSHIFT by a negative amount arithmetic', XU, "fn_h = ((sh_op == 6'h01 || (sh_op == 6'h08 && !sh_imm)) && x[31]) ? 32'hFFFF_FFFF : 32'h0;", "fn_h = x[31] ? 32'hFFFF_FFFF : 32'h0;"),
    ('FCOMP: the accumulator not written', F, "if (ld_comp) a = (a & 32'h00FF_FFFF) | (misc_r & 32'hFF00_0000);", ""),
    ('FMUL || FADD: the multiplier flags group not cleared', F, "if (ld_mul) begin a = (a & ~MUL_GRP) | fm_a; k = k | fm_s; end", "if (ld_mul) begin a = a | fm_a; k = k | fm_s; end"),
    ('a store takes the compute operand, not its register', F, "    fout_data = XC.acc_wd;", "    fout_data = op_x;"),
    ('ureg read of M (DAG2) not sign-extended', F, "4'h2: ur_v = ur_sel[3] ? {{8{mu_rd[23]}}, mu_rd[23:0]} : mu_rd;", "4'h2: ur_v = mu_rd;"),
    ('RAM not cleared after reset', F, "if (reset) begin clr_n <= '0; clr_on <= CLEAR; end", "if (reset) begin clr_n <= '0; clr_on <= 1'b0; end"),
    ('a ureg write to ASTAT applied before the float flags', F, "4'hc: if (XC.fl_on) begin ld_ua <= 1'b1; end else a = uv;", "4'hc: a = uv;"),
    ('FIX under TRUNC in the misc unit rounds to nearest (MAME mode)', XU, "if (!trunc) up = half && (rest || q[0]);", "if (1'b1) up = half && (rest || q[0]);"),
    # R1028
    ('R file: the deferred second write dropped', F, "rf_pw <= !reset && ((ld_on && ld_mwe && ld_awe) || (rx_c && rx_l));", "rf_pw <= 1'b0;"),
    ('scoreboard: the deferred R write not waited on', F, " ||\n                        (rf_pw && rf_ra[p] == rf_pa))) hit = 1'b1;", ")) hit = 1'b1;"),
    ('I file: the deferred second I write dropped', F, "    ir_pw <= !reset && st == ST_X", "    ir_pw <= 1'b0 && st == ST_X"),
    ('PC stack: a second pop reads the first pop\'s word', F, "if (s.pcstkp != 6'd0) s.pcstk = (npop == 2'd0) ? pcs_p2 : pcs_p3;", "if (s.pcstkp != 6'd0) s.pcstk = pcs_p2;"),
    ('loop stack: a second pop reads the first pop\'s word', F, "s.curlcntr = nlpop ? lcs_p3 : lcs_p2;", "s.curlcntr = lcs_p2;"),
    ('LCNTR after a DO that follows a loop-end pop: the word above', F, "assign lcs_p3 = lcs_b; assign lcs_q0 = lcs_b;", "assign lcs_p3 = lcs_b; assign lcs_q0 = lcs_a;"),
    ('FAVG decoded as FADD', F, "8'h89: begin x.fl_add = 1'b1; x.fl_avg = 1'b1; end", "8'h89: begin x.fl_add = 1'b1; end"),
    ('a bit operation on ASTAT uses its value at D', F, "if (XC.bit_reg == 4'hc) xb_v = sys_rd(", "if (1'b0) xb_v = sys_rd("),
    ('a 6-bit relative branch takes the 24-bit offset', F, "rel_t = pc1 + ((op[47:42] == 6'b000010 || op[47:46] == 2'b11) ? 24'(sext6(op[32:27])) : op[23:0]);", "rel_t = pc1 + op[23:0];"),
    ('an unsupported word not reported', F, "    if (st == ST_X && XC.unsup) us_go = 1'b1;", "    if (1'b0) us_go = 1'b1;"),
]


def main():
    # core_faults.py <work> <events.bin> <strace.bin> [words]   -- the DOA replay against MAME
    # core_faults.py <work> rand <seeds> [words]                 -- random programs, lockstep v1
    #   core_faults.py <work> unsup -                              -- one-word unsupported programs (R1028)
    work, ev, tr = sys.argv[1], sys.argv[2], sys.argv[3]
    rand = ev == 'rand'
    uns = ev == 'unsup'
    cases = []
    if uns:
        os.makedirs(work, exist_ok=True)
        subprocess.run([sys.executable, os.path.join(HERE, 'm2b_unsupprog.py'), os.path.join(work, 'unsup')], capture_output=True)
        cases = [l.split(None, 3) for l in open(os.path.join(work, 'unsup', 'cases.txt')).read().splitlines()]
    n = sys.argv[4] if len(sys.argv) > 4 else ('500000' if rand else '20000000')
    progs = []
    if rand:
        os.makedirs(work, exist_ok=True)
        for sd in range(1, int(tr) + 1):
            pth = os.path.join(work, 'rand%d.bin' % sd)
            subprocess.run([sys.executable, os.path.join(HERE, 'm2b_randprog.py'), str(sd), pth], capture_output=True)
            progs.append(pth)
    caught = 0
    only = os.environ.get('CF_ONLY')            # a substring: run only the faults it names
    faults = [x for x in FAULTS if not only or only in x[0]]
    for idx, (name, f, old, new) in enumerate(faults):
        d = os.path.join(work, 'c%02d' % idx)
        rtl = os.path.join(d, 'rtl')
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(RTL, rtl)
        p = os.path.join(rtl, f)
        s = open(p).read()
        if old not in s:
            print('%-62s PATTERN NOT FOUND' % name)
            continue
        open(p, 'w').write(s.replace(old, new, 1))
        obj = os.path.join(d, 'obj')
        b = subprocess.run([os.path.join(HERE, 'build.sh'), obj, '1', '1' if (rand or uns) else '0', rtl], capture_output=True, text=True)
        if b.returncode:
            print('%-62s BUILD FAILED %s' % (name, b.stdout[-300:]))
            continue
        if uns:
            ok = False; info = []
            for pth, pc, why, cname in cases:
                r = subprocess.run([os.path.join(obj, 'Vtb_m2b_sharc'), '+ev=' + pth, '+lock', '+noidle', '+words=200',
                                    '+quiet'], capture_output=True, text=True, timeout=600)
                want = 'UNSUPPORTED word at %s:' % pc
                got = [l for l in r.stdout.splitlines() if l.startswith('UNSUPPORTED')]
                if not got or not got[0].startswith(want) or ('(reason %s)' % why) not in got[0]:
                    ok = True; info.append(cname); break
        elif rand:
            ok = False; info = []
            for pth in progs:
                r = subprocess.run([os.path.join(obj, 'Vtb_m2b_sharc'), '+ev=' + pth, '+lock', '+noidle', '+words=' + n,
                                    '+tdiff=0', '+quiet'], capture_output=True, text=True, timeout=1200)
                lines = r.stdout.strip().splitlines()
                info = [l for l in lines if l.startswith('lockstep:') or l.startswith('UNSUP')]
                if r.returncode != 0:
                    ok = True; info.append(os.path.basename(pth)); break
        else:
            r = subprocess.run([os.path.join(obj, 'Vtb_m2b_sharc'), '+ev=' + ev, '+trace=' + tr, '+words=' + n,
                                '+tdiff=0', '+outshow=0', '+quiet'], capture_output=True, text=True, timeout=1200)
            lines = r.stdout.strip().splitlines()
            info = [l for l in lines if l.startswith('out FIFO') or l.startswith('trace:') or l.startswith('UNSUP')]
            ok = r.returncode != 0
        caught += ok
        print('%-62s %s  %s' % (name, 'CAUGHT' if ok else 'MISSED', ' | '.join(info)))
        sys.stdout.flush()
        shutil.rmtree(obj, ignore_errors=True)
    print('%d of %d planted faults caught' % (caught, len(faults)))


if __name__ == '__main__':
    main()
