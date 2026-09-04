#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Fit the same RTL under several fitter seeds AT ONCE, and report which closed.
#
#   tools/seed-sweep.sh [n] [first_seed]
#
# WHY THIS EXISTS. Placement on this design is marginal often enough that a
# re-seed is routine, and serially that is 25 minutes a roll. The seed carries
# no meaning -- it perturbs placement and nothing else -- so the only sane way
# to use it is to try several at once and keep the one that closes.
#
# EACH SEED NEEDS ITS OWN PROJECT DIRECTORY. Quartus writes db/ and
# output_files/ beside the project file, so five seeds in one tree overwrite
# each other's databases and report whichever finished last. Sources are
# SYMLINKED rather than copied: sys.tcl and sys_top.sdc use paths relative to
# the project, and a partial copy fails in ways that look like Quartus bugs.
#
# MEMORY IS THE LIMIT, NOT CORES. A fit peaks around 5 GB here and this machine
# has 31 GB, so four is comfortable and beyond that risks the OOM killer taking
# a fit mid-flight -- which looks exactly like a design failure until the exit
# reason is read. Default is 4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="${1:-4}"
FIRST="${2:-1}"
Q=/home/ben/intelFPGA_lite/17.0/quartus/bin
OUT="$ROOT/build/seeds"
mkdir -p "$OUT"

# COUNT FITS THAT ARE NOT OURS. This machine also builds the Model 1 core, and
# a sweep launched against an idle machine can find itself sharing it with
# three foreign fits ten minutes later. Seven concurrent fits took the Segment
# Violation rate from the usual ~1-in-3 to 2-of-4, so foreign load is
# subtracted from the requested parallelism rather than ignored.
# pgrep -x on the binary name, never -f: -f matches other waiters' command
# lines, which has deadlocked two build queues against each other's pattern.
# `pgrep -c` PRINTS 0 AND EXITS NON-ZERO when it matches nothing, so
# `|| echo 0` appends a second line and the test below dies on "0\n0" --
# leaving the throttle permanently off, which is the failure it exists to
# prevent. `| wc -l` always exits 0 and always yields one integer.
# `|| true` INSIDE the braces, not after the pipe: pgrep exits 1 when it
# matches nothing, and under `set -o pipefail` that fails the whole pipeline,
# which `set -e` turns into a silent early exit -- the script printed nothing
# and built nothing.
foreign=$( { pgrep -x quartus_fit || true; } | wc -l )
if [ "$foreign" -gt 0 ]; then
  avail=$(( 4 - foreign )); [ "$avail" -lt 1 ] && avail=1
  if [ "$N" -gt "$avail" ]; then
    echo "note: $foreign other quartus_fit running; $N -> $avail seeds"
    N=$avail
  fi
fi

for i in $(seq 0 $((N-1))); do
  s=$((FIRST + i))
  d="$OUT/s$s"
  rm -rf "$d"; mkdir -p "$d"
  for l in rtl sys sim mra tools docs; do ln -sfn "$ROOT/$l" "$d/$l"; done
  # Every root-level file, not an enumerated list: Model2.sv `include`s
  # build_id.v, which is generated and so is easy to leave out of a list and
  # then spend a fit's worth of time rediscovering.
  find "$ROOT" -maxdepth 1 -type f ! -name 'Model2.qsf' ! -name 'Model2.qpf' \
       -exec ln -sfn {} "$d/" \;
  # build_id.tcl (PRE_FLOW) REWRITES build_id.v. Through a symlink that is
  # four seeds writing the repo's copy at once, so this one is a real file.
  rm -f "$d/build_id.v"; cp "$ROOT/build_id.v" "$d/build_id.v"
  cp "$ROOT/Model2.qpf" "$d/Model2.qpf"
  sed "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $s/" \
      "$ROOT/Model2.qsf" > "$d/Model2.qsf"
  grep -q "name SEED" "$d/Model2.qsf" || \
      printf '\nset_global_assignment -name SEED %s\n' "$s" >> "$d/Model2.qsf"
  (
    cd "$d"
    # LC_ALL=C: qenv.sh tries to set en_US.UTF-8, which is not installed here,
    # and every one of today's twelve fitter "crashes" was a Segment Violation
    # in tcl_freeInternalRepProc during EXIT -- after the fit had written
    # "Fitter Status : Successful". A failed locale is the leading suspect for
    # a Tcl teardown fault, and C is always present.
    export LC_ALL=C
    "$Q/quartus_map" Model2 -c Model2 >map.log 2>&1 || exit 1
    # THE FIT'S EXIT CODE IS NOT ITS VERDICT. It segfaults on the way out about
    # half the time and the result is intact. `set -e` was turning that into an
    # aborted subshell with no STA, and the seed was reported as a crash. Judge
    # it by what it wrote, and run STA whenever the fit says it succeeded.
    "$Q/quartus_fit" Model2 -c Model2 >fit.log 2>&1 || true
    grep -q "Fitter Status : Successful" output_files/Model2.fit.summary 2>/dev/null || exit 1
    "$Q/quartus_sta" Model2 -c Model2 >sta.log 2>&1 || exit 1
  ) &
  echo "seed $s -> $d"
done

wait
echo
printf '%-6s %-10s %-12s %s\n' SEED SLACK TNS STATUS
for i in $(seq 0 $((N-1))); do
  s=$((FIRST + i)); d="$OUT/s$s"
  r="$d/output_files/Model2.sta.rpt"
  if [ -f "$r" ]; then
    line=$(grep -A3 "Worst-case setup slack is" "$r" | sed -n '4p')
    sl=$(echo "$line" | awk '{print $3}'); tn=$(echo "$line" | awk '{print $4}')
    st=$(awk -v x="$sl" 'BEGIN{print (x+0>=0)?"CLOSED":"fail"}')
    printf '%-6s %-10s %-12s %s\n' "$s" "$sl" "$tn" "$st"
  else
    why=$(grep -ohE "Internal Error[^,]*|Killed" "$d"/*.log 2>/dev/null | head -1)
    grep -q "Segment Violation" "$d/fit.log" 2>/dev/null && ! grep -q "Fitter Status : Successful" "$d/output_files/Model2.fit.summary" 2>/dev/null && why="Segment Violation (fit incomplete)"
    printf '%-6s %-10s %-12s %s\n' "$s" "-" "-" "${why:-no sta report}"
  fi
done
