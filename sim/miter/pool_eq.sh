#!/usr/bin/env bash
# R959: m2_fp_pool old against new, FORMALLY (yosys equiv_make / equiv_simple /
# equiv_induct, fp_mul / fp_add / fp_div flattened in, every register and
# output matched by name), at m2_geometry's NC = 4.
#
#   sim/miter/pool_eq.sh <old tree> [NC]        (from the new tree's root)
#
# yosys 0.66 does not take unpacked-array ports, so both copies have their
# [31:0] x [NC] operand ports packed ([NC-1:0][31:0]); indexing is the same.
set -u
O=$(cd "$1" && pwd); NC=${2:-4}; M=obj_miter_pool_eq; mkdir -p $M
for v in old new; do
  src=rtl/video/m2_fp_pool.sv; [ $v = old ] && src=$O/rtl/video/m2_fp_pool.sv
  sed -E -e "s/\bmodule m2_fp_pool\b/module m2_fp_pool_$v/" \
         -e 's/^(\s*input\s+logic) \[31:0\]\s+(\w+)\s+\[NC\],/\1 [NC-1:0][31:0] \2,/' $src > $M/$v.sv
  [ $(grep -c 'NC-1:0\]\[31:0\]' $M/$v.sv) = 6 ] || { echo "pool_eq: the port edit did not apply to $src"; exit 1; }
done
cat > $M/eq.ys <<EOT
read_verilog -sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv
read_verilog -sv $M/old.sv $M/new.sv
chparam -set NC $NC m2_fp_pool_old m2_fp_pool_new
hierarchy -check
proc
memory
flatten
opt_clean
async2sync
equiv_make m2_fp_pool_old m2_fp_pool_new equiv
hierarchy -top equiv
equiv_simple -undef
equiv_induct -undef
equiv_status -assert
EOT
yosys -q -l $M/eq.log $M/eq.ys > /dev/null 2>&1; r=$?
echo "NC $NC: $( [ $r = 0 ] && echo PROVEN || echo NOT PROVEN ) | $(grep -E 'Of those cells' $M/eq.log | tail -1 | sed 's/^ *//')"
