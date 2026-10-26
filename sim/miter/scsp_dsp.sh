#!/usr/bin/env bash
# R959: m2_scsp_dsp old against new, every output on every clock, under the
# DSP's own bench (tb_m2_scsp_dsp: a capture, or DSP_RANDOM programs) and the
# whole SCSP's (tb_m2_scsp: a capture), with the miter in u_dsp's place.
#
#   sim/miter/scsp_dsp.sh <old tree> build        (from the new tree's root)
#   sim/miter/scsp_dsp.sh <old tree> dsp  <env>... (runs tb_m2_scsp_dsp)
#   sim/miter/scsp_dsp.sh <old tree> scsp <env>... (runs tb_m2_scsp)
#
# Beside the outputs the miter counts two of the new copy's own invariants:
#   ins: in a run's ph 2-4 the registered microword equals MPRO's output;
#   adr: in ph 3-4 the ring address equals the old copy's.
# Extra Verilator flags (OVERLAP's -G / -D, say) go in MITER_VFL, and a build
# directory other than obj_miter_scsp_dsp in MITER_DIR.
set -u
O=$(cd "$1" && pwd); M=${MITER_DIR:-obj_miter_scsp_dsp}; mkdir -p $M
D=rtl/sound/scsp
python3 sim/miter/miter.py m2_scsp_dsp $O/$D/m2_scsp_dsp.sv $D/m2_scsp_dsp.sv $M >/dev/null
# the invariants, inside the miter module
python3 - $M/m2_scsp_dsp_miter.sv <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
chk = '''  longint unsigned mt_ins, mt_adr;
  initial begin mt_ins = 0; mt_adr = 0; end
  always @(posedge clk) begin
    if (u_new.dst == 3'd2 && u_new.ph >= 3'd2 && u_new.ph <= 3'd4 && u_new.ins != u_new.mp_q) mt_ins <= mt_ins + 1;
    if (u_new.dst == 3'd2 && (u_new.ph == 3'd3 || u_new.ph == 3'd4) && u_new.addr_w != u_old.addr_w) mt_adr <= mt_adr + 1;
  end
  final $display("MITER m2_scsp_dsp invariants: ins %0d, adr %0d cycles broken", mt_ins, mt_adr);
endmodule
'''
i = s.rindex('endmodule'); s = s[:i] + chk + s[i + len('endmodule'):]
open(p, 'w').write(s)
EOF
sed -e 's/\treturn (bad_ef || bad_ram) ? 1 : 0;/\tt->final(); return (bad_ef || bad_ram) ? 1 : 0;/' sim/sound/tb_m2_scsp_dsp.cpp > $M/tb_m2_scsp_dsp.cpp
sed -e 's/\treturn (bad || slot_bad) ? 1 : 0;/\tt->final(); return (bad || slot_bad) ? 1 : 0;/' sim/sound/tb_m2_scsp.cpp > $M/tb_m2_scsp.cpp
grep -q 't->final(); return' $M/tb_m2_scsp_dsp.cpp && grep -q 't->final(); return' $M/tb_m2_scsp.cpp || { echo "bench end not found"; exit 1; }
VFL="-Wall -Wno-DECLFILENAME -I$D -Isim/sound -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-MULTITOP -Wno-UNUSEDPARAM ${MITER_VFL:-}"
MD="$M/m2_scsp_dsp_miter.sv $M/m2_scsp_dsp_new.sv $M/m2_scsp_dsp_old.sv $D/m2_scsp_cache.sv"
case "$2" in
build)
  rm -rf $M/obj_dsp $M/obj_scsp
  verilator --cc --exe --build -j 4 $VFL -CFLAGS "-O2 -std=c++17 -I$PWD/sim/sound" --top-module m2_scsp_dsp --Mdir $M/obj_dsp -o V \
    $MD $M/tb_m2_scsp_dsp.cpp > $M/build_dsp.log 2>&1 || { echo "dsp: build failed ($M/build_dsp.log)"; exit 1; }
  verilator --cc --exe --build -j 4 $VFL -CFLAGS "-O2 -std=c++17 -I$PWD/sim/sound" --top-module m2_scsp --Mdir $M/obj_scsp -o V \
    $D/m2_scsp.sv $D/m2_scsp_regs.sv $D/m2_scsp_level.sv $MD $M/tb_m2_scsp.cpp > $M/build_scsp.log 2>&1 || { echo "scsp: build failed ($M/build_scsp.log)"; exit 1; }
  cp -f $D/*.hex $M/obj_scsp/
  echo "built $M/obj_dsp/V $M/obj_scsp/V" ;;
dsp)  shift 2; (cd $M/obj_dsp  && env "$@" ./V) ;;
scsp) shift 2; (cd $M/obj_scsp && env "$@" ./V) ;;
esac
