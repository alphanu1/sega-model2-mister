#!/bin/bash
# Build the SAME tree at two arbitrary seeds, in parallel, from one invocation.
#
# Why this exists and seed-sweep.sh will not do: the sweep builds a contiguous
# run of seeds. The question here is a controlled pair -- one seed known to
# boot against one known to black-screen -- and those two numbers are nowhere
# near each other.
#
# The pair must be built in the SAME session because build_id.tcl (PRE_FLOW)
# stamps the build date into build_id.v. Two bitstreams built a day apart
# differ by that string no matter how identical the RTL is, and a comparison
# between them cannot isolate the seed. That flaw invalidated the previous
# attempt at this measurement.
set -u
ROOT=/home/ben/source/sega-model2-mister
Q=/home/ben/intelFPGA_lite/17.0/quartus/bin
OUT=${OUT:-$ROOT/build/pair}

for s in "$@"; do
  d="$OUT/s$s"
  rm -rf "$d"; mkdir -p "$d"
  for l in rtl sys sim mra tools docs; do ln -sfn "$ROOT/$l" "$d/$l"; done
  find "$ROOT" -maxdepth 1 -type f ! -name 'Model2.qsf' ! -name 'Model2.qpf' \
       -exec ln -sfn {} "$d/" \;
  rm -f "$d/build_id.v"; cp "$ROOT/build_id.v" "$d/build_id.v"
  cp "$ROOT/Model2.qpf" "$d/Model2.qpf"
  sed "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $s/" \
      "$ROOT/Model2.qsf" > "$d/Model2.qsf"
  (
    cd "$d" || exit 1
    export LC_ALL=C
    "$Q/quartus_map" Model2 -c Model2 >map.log 2>&1 || exit 1
    # The fit's exit code is not its verdict -- it segfaults during teardown
    # about half the time with the result already written. Judge it by the
    # summary file.
    "$Q/quartus_fit" Model2 -c Model2 >fit.log 2>&1 || true
    grep -q "Fitter Status : Successful" output_files/Model2.fit.summary 2>/dev/null || exit 1
    "$Q/quartus_sta" Model2 -c Model2 >sta.log 2>&1 || true
    # quartus_asm run separately: the combined flow loses the .rbf when the
    # fitter faults on exit.
    "$Q/quartus_asm" Model2 -c Model2 >asm.log 2>&1 || true
  ) &
  echo "seed $s -> $d"
done
wait

echo
printf '%-6s %-9s %-9s %-10s %s\n' SEED SETUP HOLD ALM MD5
for s in "$@"; do
  d="$OUT/s$s"
  set=$(grep -A3 "Worst-case setup slack is" "$d/output_files/Model2.sta.rpt" 2>/dev/null | sed -n '4p' | awk '{print $3}')
  hld=$(grep -A3 "Worst-case hold slack is"  "$d/output_files/Model2.sta.rpt" 2>/dev/null | sed -n '4p' | awk '{print $3}')
  alm=$(grep -oE "[0-9,]+ / 41,910" "$d/output_files/Model2.fit.summary" 2>/dev/null | head -1 | awk '{print $1}')
  md5=$(md5sum "$d/output_files/Model2.rbf" 2>/dev/null | awk '{print $1}')
  printf '%-6s %-9s %-9s %-10s %s\n' "$s" "${set:--}" "${hld:--}" "${alm:--}" "${md5:-NO RBF}"
done
