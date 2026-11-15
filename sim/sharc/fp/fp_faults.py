#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: planted faults for tb_sharc_fp. Each fault is
# one edit to a copy of rtl/sharc in <work>/<n>; the bench is built from the copy and run, and
# must FAIL. The real rtl/sharc is never touched.
#   fp_faults.py <work dir> [vectors]
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
RTL = os.path.join(ROOT, 'rtl', 'sharc')

# (name, file, old, new, which occurrence (0 = first))
FAULTS = [
    ('fadd: round to zero not applied (manual)', 'sharc_fadd.sv',
     "up = !(!MAME_RND && v_trunc) && s[2]", "up = s[2]", 0),
    ('fadd: round to zero in MAME mode too', 'sharc_fadd.sv',
     "up = !(!MAME_RND && v_trunc) && s[2]", "up = !v_trunc && s[2]", 0),
    ('fadd: alignment sticky bit dropped', 'sharc_fadd.sv',
     "return {v[26:1], v[0] | st};", "return {v[26:1], v[0]};", 0),
    ('fmul manual: denormal operand not flushed', 'sharc_fmul.sv',
     "xf = flush(x);", "xf = x;", 0),
    ('fmul manual: tiny threshold one low', 'sharc_fmul.sv',
     "tiny = e < 12'sd1;", "tiny = e < 12'sd0;", 0),
    ('fmul manual: overflow under TRUNC gives infinity', 'sharc_fmul.sv',
     "res  = ovf ? (v_trunc ? {v_sg, MAXF[30:0]} : {v_sg, INF[30:0]})", "res  = ovf ? ({v_sg, INF[30:0]})", 0),
    ('fmul manual: ties rounded down', 'sharc_fmul.sv',
     "up = !v_trunc && s[2] && (s[1] || s[0] || s[3]);", "up = !v_trunc && s[2] && (s[1] || s[0]);", 0),
    ('fmul manual: MU not raised on a flushed product', 'sharc_fmul.sv',
     "(tiny ? MU : 32'h0)", "32'h0", 0),
    ('fmul MAME: exponent bias off by one', 'sharc_fmul.sv',
     "e = v_esum - 10'd126; end", "e = v_esum - 10'd125; end", 0),
    ('pkg man_round: TRUNC ignored', 'sharc_fp_pkg.sv',
     "up = !rz && s[2]", "up = s[2]", 0),
    ('pkg man_fix: TRUNC toward zero, not minus infinity', 'sharc_fp_pkg.sv',
     "o.r = f2i(v, trunc ? 2'd1 : 2'd0);", "o.r = f2i(v, trunc ? 2'd2 : 2'd0);", 0),
    ('pkg man_sum: alignment sticky dropped', 'sharc_fp_pkg.sv',
     "sy   = {wide[53:28], wide[27] | (wide[26:0] != 0)};", "sy   = {wide[53:28], wide[27]};", 1),
    ('pkg man_float: rounding mode ignored', 'sharc_fp_pkg.sv',
     "o.r = man_i2f(rx, trunc);", "o.r = man_i2f(rx, 1'b0);", 0),
    ('pkg man_mul: MU not raised', 'sharc_fp_pkg.sv',
     "if (m.tiny) begin o.astat |= MU; o.stky |= MUS; end", "if (m.tiny) begin o.stky |= MUS; end", 0),
    ('pkg man_comp: operands not flushed', 'sharc_fp_pkg.sv',
     "return f_comp(flush(x), flush(y), astat);", "return f_comp(x, y, astat);", 0),
    ('pkg f_add (MAME): round half up', 'sharc_fp_pkg.sv',
     "up = s[2] && (s[1] || s[0] || s[3]);\n    m  = {1'b0, s[26:3]} + {24'h0, up};\n    ee = e;",
     "up = s[2];\n    m  = {1'b0, s[26:3]} + {24'h0, up};\n    ee = e;", 0),
]


def plant(src, old, new, k):
    i = -1
    for _ in range(k + 1):
        i = src.index(old, i + 1)
    return src[:i] + new + src[i + len(old):]


def main():
    work = sys.argv[1]
    n = sys.argv[2] if len(sys.argv) > 2 else '1000000'
    caught = 0
    for idx, (name, f, old, new, k) in enumerate(FAULTS):
        d = os.path.join(work, 'f%02d' % idx)
        rtl = os.path.join(d, 'rtl')
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(RTL, rtl)
        p = os.path.join(rtl, f)
        s = open(p).read()
        open(p, 'w').write(plant(s, old, new, k))
        obj = os.path.join(d, 'obj')
        b = subprocess.run([os.path.join(HERE, 'build.sh'), obj, rtl], capture_output=True, text=True)
        if b.returncode:
            print('%-55s BUILD FAILED' % name)
            continue
        r = subprocess.run([os.path.join(obj, 'Vtb_sharc_fp'), '+n=' + n], capture_output=True, text=True)
        last = r.stdout.strip().splitlines()[-1]
        ok = r.returncode != 0
        caught += ok
        print('%-55s %s  (%s)' % (name, 'CAUGHT' if ok else 'MISSED', last))
        shutil.rmtree(obj, ignore_errors=True)
    print('%d of %d planted faults caught' % (caught, len(FAULTS)))
    return 0 if caught == len(FAULTS) else 1


if __name__ == '__main__':
    sys.exit(main())
