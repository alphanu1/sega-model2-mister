#!/usr/bin/env bash
# R968: the two Model2.sv changes, FORMALLY (yosys sat, induction), on the text
# of the file itself -- the blocks are cut out of Model2.sv, not retyped.
#
#   sim/miter/r968_top.sh <old tree>        (run from the new tree's root)
#
# 1. ldr_big. The new block's invariant  ldr_big == (ldr_top > 0x80000)  is
#    proven inductive from reset, and the old and new ldr_top / game_image are
#    proven equal on every cycle (the two blocks side by side, same inputs).
# 2. The sweep at SWEEP_EN 0 (the build's value), sw_take 0 (M2_NO_DEBUG,
#    g_nodbg_sw) and sw_sel_i 0 (R666). The OLD block is proven never to leave
#    its reset values -- every register it has (sw_word / sw_wsel included)
#    is asserted at reset on every cycle, from reset, for every input sequence,
#    and that is inductive -- and the NEW block (`else if (SWEEP_EN)`) is
#    proven the same (all but sw_word / sw_wsel, which it never assigns and
#    nothing outside the block reads). So the two are the same constants.
# A mutation of each (the compare's constant one off; SWEEP_EN 1) must fail.
set -u
O=$(cd "$1" && pwd); M=obj_miter_r968; rm -rf $M; mkdir -p $M
python3 - "$O/Model2.sv" Model2.sv $M <<'PY'
import re, sys
old_p, new_p, out = sys.argv[1:4]
def cut(t, start_re, end_re):
    m = re.search(start_re, t, re.M); assert m, start_re
    e = re.compile(end_re, re.M).search(t, m.end()); assert e, end_re
    return t[m.start():e.end()]
def blocks(p):
    t = open(p).read()
    ldr = cut(t, r'^logic \[SDR_AW:1\] ldr_top;', r'^wire game_image.*$')
    fold = cut(t, r'^function automatic logic \[23:0\] sw_fold', r'^endfunction')
    sw = cut(t, r'^always_ff @\(posedge clk_sys or negedge mem_rst_n\) begin\n\tif \(!mem_rst_n\) begin\n\t\tsw_req <= ', r'^end$')
    return ldr, fold, sw.replace('p_dout[2]', 'p_dout2')
HDR = '''  input  logic clk_sys, mem_rst_n, ldr_wr_req, rom_loaded, cal_done, p2s_ack, cp_req, st_rd_req,
  input  logic [SDR_AW:1] ldr_wr_addr,
  input  logic [63:0] p_dout2,
  output logic game_image,
  output logic [SDR_AW:1] o_ldr_top,
  output logic o_ldr_big'''
DECL = '''localparam bit SWEEP_EN = SWP;
wire sw_take = 1'b0;
wire [4:0] sw_sel_i = 5'd0;
logic            sw_req;
logic [SDR_AW:1] sw_addr;
logic [23:0]     sw_acc, sw_val;
logic [19:0]     sw_burst;
logic  [2:0]     sw_state;
logic [63:0]     sw_word;
logic  [1:0]     sw_wsel;
logic  [4:0]     sw_sel;
logic            sw_done;
logic            sw_done_d, sw_emit;
wire             sw_ack = p2s_ack && sw_req && !cp_req && !st_rd_req;
logic            sw_pend;
logic [23:0]     sw_out;
logic  [4:0]     sw_out_sel;
logic  [7:0]     sw_runs;
'''
AT_RESET = ('!sw_req && sw_addr == 0 && sw_acc == 0 && sw_val == 0 && sw_burst == 0 && sw_state == 0 && '
            'sw_word == 0 && sw_wsel == 0 && sw_sel == 0 && !sw_done && !sw_done_d && !sw_emit && !sw_pend && '
            'sw_out == 0 && sw_out_sel == 0 && sw_runs == 0')
# sw_word / sw_wsel are read only inside the gated block; the new copy never
# assigns them (with SWEEP_EN 0 they have no driver and nothing reads them), so
# they are asserted on the old copy alone.
AT_RESET_NEW = AT_RESET.replace('sw_word == 0 && sw_wsel == 0 && ', '')
for tag, p in (('old', old_p), ('new', new_p)):
    ldr, fold, sw = blocks(p)
    at = AT_RESET if tag == 'old' else AT_RESET_NEW
    big = 'assign o_ldr_big = 1\'b0;' if tag == 'old' else 'assign o_ldr_big = ldr_big;'
    with open(f'{out}/sw_{tag}.sv', 'w') as f:
        f.write(f'module sw_{tag} #(parameter int unsigned SDR_AW = 25, parameter bit SWP = 1\'b0) (\n{HDR}\n);\n'
                f'{DECL}\n{ldr}\nassign o_ldr_top = ldr_top;\n{big}\n{fold}\n{sw}\n'
                f'always @* if (mem_rst_n) assert ({at});\nendmodule\n')
# ldr_big's invariant on the new copy, and the two copies side by side
with open(f'{out}/ldr_eq.sv', 'w') as f:
    f.write('''module ldr_eq #(parameter logic [25:1] K = 25'h0080000) (
  input logic clk_sys, mem_rst_n, ldr_wr_req, rom_loaded, cal_done, p2s_ack, cp_req, st_rd_req,
  input logic [25:1] ldr_wr_addr, input logic [63:0] p_dout2);
  logic gi_o, gi_n, big_o, big_n; logic [25:1] t_o, t_n;
  sw_old u_o (.*, .game_image(gi_o), .o_ldr_top(t_o), .o_ldr_big(big_o));
  sw_new u_n (.*, .game_image(gi_n), .o_ldr_top(t_n), .o_ldr_big(big_n));
  always @* begin
    assert (gi_o == gi_n);
    assert (t_o == t_n);
    assert (big_n == (t_n > K));
  end
endmodule
''')
PY
[ -s $M/sw_old.sv ] && [ -s $M/sw_new.sv ] || { echo "r968_top: the blocks were not found"; exit 1; }
run() {   # name, top, extra chparam, files...
  local n=$1 top=$2 cp=$3; shift 3
  cat > $M/$n.ys <<EOT
read_verilog -sv -formal $*
$cp
hierarchy -top $top
proc
flatten
opt_clean
async2sync
sat -tempinduct -prove-asserts -set-init-zero -seq 1 -maxsteps 20 -verify $top
EOT
  yosys -q -l $M/$n.log $M/$n.ys > /dev/null 2>&1; r=$?
  echo "$n: $( [ $r = 0 ] && echo PROVEN || echo NOT PROVEN )"
}
F="$M/sw_old.sv $M/sw_new.sv $M/ldr_eq.sv"
run sweep_old sw_old "" $F
run sweep_new sw_new "" $F
run ldr ldr_eq "" $F
echo "-- mutations (each must be NOT PROVEN):"
run mut_sweep_en sw_old "chparam -set SWP 1 sw_old" $F
run mut_ldr_k ldr_eq "chparam -set K 25'h0080001 ldr_eq" $F
