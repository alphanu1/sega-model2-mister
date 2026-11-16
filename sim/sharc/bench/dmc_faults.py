#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1031: planted faults in the 2B SHARC's DM cache
# (m2b_dmc). Each is one edit to a copy of rtl/sharc; the replay bench is built from the copy with
# the core's on-chip DM cut to 256 words (DM_AW 8: every Dead or Alive data word from 0x100 goes
# through the cache) and a cache of 4 lines x 4 words (it thrashes), MAME rounding, and run on
# DOA's capture for a fixed number of words at a random SDRAM latency; it must FAIL (the out
# FIFO or the trace against MAME's, or a bench-only check). The real rtl/sharc is never touched.
#   dmc_faults.py <work dir> <events.bin> <strace.bin> [words] [lat lo:hi]
#   DMC_SHAPE=<LN_AW>:<WD_AW> another cache shape (6:4 is Model2.sv's 64 x 16); CF_ONLY=<text> some faults
#   DMC_RAND="<events.bin> ...": m2b_randprog.py programs instead of DOA, in lockstep with v1
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
RTL = os.path.join(ROOT, 'rtl', 'sharc')

C = 'm2b_dmc.sv'
FAULTS = [
    ('the page not cleared after reset', C, "cl_on <= CLEAR;", "cl_on <= 1'b0;"),
    ('a landing overwrites a word the SHARC wrote', C, "if (fl_v) ls_we = f_on && !f_v[fl_w];", "if (fl_v) ls_we = f_on;"),
    ('a write to the filling line not marked landed', C, "if (w_take && in_fill) f_v[c_w] <= 1'b1;", ""),
    ('the fill reads go ahead of the queued writes', C, "end else if (wq_n != '0) begin\n                q <= Q_WAIT; qk <= K_WLO;",
     "end else if (wq_n != '0 && !(f_on && f_ni != (WD_AW + 1)'(NW))) begin\n                q <= Q_WAIT; qk <= K_WLO;"),
    ('a read of the filling line hits before its word lands', C, "rd_hit  = v_hit || (in_fill && f_v[c_w]);", "rd_hit  = v_hit || in_fill;"),
    ('a line stays valid while it refills', C, "            vld[c_line] <= 1'b0;\n", ""),
    ('the tag not compared', C, "v_hit   = vld[c_line] && tg_q == c_tag;", "v_hit   = vld[c_line];"),
    ('a write to a valid line not written into the line store', C, "else if (w_take && (v_hit || in_fill)) begin", "else if (w_take && in_fill) begin"),
    ('a write\'s high half written as its low half', C, "s_din <= wq_q[31:16];", "s_din <= wq_q[15:0];"),
    ('a fill word lands one word along', C, "fl_w <= q_fw;", "fl_w <= f_iw;"),
    ('a new fill while a fill read is in flight', C, "!rd_hit && !in_fill && !f_rd_busy;", "!rd_hit && !in_fill;"),
    ('a read acknowledged a clock early (the store not yet read)', C, "assign c_ack   = cs == C_ACK;", "assign c_ack   = cs == C_ACK || (cs == C_IDLE && c_req && !c_we && rd_hit);"),
]


def main():
    work, ev, tr = sys.argv[1], sys.argv[2], sys.argv[3]
    n = sys.argv[4] if len(sys.argv) > 4 else '3000000'
    lat = sys.argv[5] if len(sys.argv) > 5 else '1:60'
    ln, wd = os.environ.get('DMC_SHAPE', '2:2').split(':')
    env = dict(os.environ, DM_AW='8', LN_AW=ln, WD_AW=wd)
    only = os.environ.get('CF_ONLY')
    faults = [x for x in FAULTS if not only or only in x[0]]
    caught = 0
    for idx, (name, f, old, new) in enumerate(faults):
        d = os.path.join(work, 'd%02d' % idx)
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
        rand = os.environ.get('DMC_RAND', '').split()
        b = subprocess.run([os.path.join(HERE, 'build.sh'), obj, '1', '1' if rand else '0', rtl], capture_output=True, text=True, env=env)
        if b.returncode:
            print('%-62s BUILD FAILED %s' % (name, b.stdout[-300:]))
            continue
        if rand:
            ok = False; info = []
            for pth in rand:
                r = subprocess.run([os.path.join(obj, 'Vtb_m2b_sharc'), '+ev=' + pth, '+lock', '+noidle', '+words=' + n,
                                    '+tdiff=0', '+quiet', '+lat=' + lat, '+seed=3'], capture_output=True, text=True, timeout=1500)
                lines = (r.stdout + r.stderr).strip().splitlines()
                info = [l for l in lines if l.startswith('lockstep:') or 'm2b_dmc:' in l] + [os.path.basename(pth)]
                if r.returncode != 0:
                    ok = True; break
        else:
            r = subprocess.run([os.path.join(obj, 'Vtb_m2b_sharc'), '+ev=' + ev, '+trace=' + tr, '+words=' + n,
                                '+tdiff=0', '+outshow=0', '+quiet', '+lat=' + lat, '+seed=3'],
                               capture_output=True, text=True, timeout=1500)
            lines = (r.stdout + r.stderr).strip().splitlines()
            info = [l for l in lines if l.startswith('out FIFO') or l.startswith('trace:') or 'm2b_dmc:' in l]
            ok = r.returncode != 0
        caught += ok
        print('%-62s %s  %s' % (name, 'CAUGHT' if ok else 'MISSED', ' | '.join(info)))
        sys.stdout.flush()
        shutil.rmtree(obj, ignore_errors=True)
    print('%d of %d planted faults caught' % (caught, len(faults)))


if __name__ == '__main__':
    main()
