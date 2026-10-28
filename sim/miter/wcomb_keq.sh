#!/usr/bin/env bash
# R968: m2_fb_wcomb's keq register, FORMALLY (yosys sat, induction): from
# reset, on every cycle, keq[k] == (wkey[k] == b_key) for both windows. With
# that, c_fits (keq[ib] in place of the compare) is the same function as
# before. A mutation (keq not following b_key on a_go) must fail.
#
#   sim/miter/wcomb_keq.sh          (run from the tree's root)
set -u
M=obj_miter_wcomb_keq; rm -rf $M; mkdir -p $M
mk() {   # out, sed expression for a mutation (or empty)
  python3 - "$1" "$2" <<'PY'
import sys, re
out, mut = sys.argv[1], sys.argv[2]
t = open('rtl/video/m2_fb_wcomb.sv').read()
if mut:
    a, b = mut.split('|||')
    assert t.count(a) == 1, 'mutation target not found'
    t = t.replace(a, b)
i = t.rindex('endmodule')
t = t[:i] + "  always @* if (rst_n) assert ((keq[0] == (wkey[0] == b_key)) && (keq[1] == (wkey[1] == b_key)));\nendmodule\n"
open(out, 'w').write(t)
PY
}
run() {   # name, source
  cat > $M/$1.ys <<EOT
read_verilog -sv -formal $2
chparam -set FTB 1 m2_fb_wcomb
hierarchy -top m2_fb_wcomb
proc
flatten
memory
opt_clean
async2sync
sat -tempinduct -prove-asserts -set-init-zero -set-at 1 rst_n 0 -seq 1 -maxsteps 12 -verify m2_fb_wcomb
EOT
  yosys -q -l $M/$1.log $M/$1.ys > /dev/null 2>&1; r=$?
  echo "$1: $( [ $r = 0 ] && echo PROVEN || echo NOT PROVEN )"
}
mk $M/keq.sv ""
mk $M/mut.sv "        else if (a_go)
          keq[k] <= (wkey[k] == nkey);|||"
run keq $M/keq.sv
echo "-- mutation (must be NOT PROVEN):"
run mut $M/mut.sv
