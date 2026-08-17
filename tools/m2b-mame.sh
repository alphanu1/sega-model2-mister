#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Run MAME for M2-B instrumentation without writing anything into this tree.
#
#   tools/m2b-mame.sh <set> [extra mame args...]
#
# MAME writes cfg/, nvram/, sta/ and friends into the working directory on every
# run. `nvram/` holds EEPROM and battery-backed RAM dumped out of the game — it
# is ROM-DERIVED DATA and must never enter this repository. .gitignore covers
# them as a safety net; this script is the mechanism, and the two exist
# separately on purpose: an ignore rule stops a commit, it does not stop the
# bytes appearing in a tree someone later archives or copies.
#
# ROM path defaults to $HOME/roms/Model2 and is overridable with M2_ROMPATH.
# ROMs live outside the repository and always will.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROMPATH="${M2_ROMPATH:-$HOME/roms/Model2}"
OUT="${M2_MAME_OUT:-${TMPDIR:-/tmp}/m2b-mame}"

[ -d "$ROMPATH" ] || { echo "ROM path not found: $ROMPATH" >&2; exit 1; }
command -v mame >/dev/null || { echo "mame not on PATH" >&2; exit 1; }

SET="${1:?usage: m2b-mame.sh <set> [mame args...]}"
shift || true

mkdir -p "$OUT"/{cfg,nvram,sta,snap,diff,inp,comment,share}

# Every writable directory points outside the tree. -video/-sound none keeps it
# headless; -nothrottle runs as fast as the host allows, which matters because
# these runs are counted in emulated seconds, not wall-clock.
exec mame "$SET" \
  -rompath        "$ROMPATH" \
  -cfg_directory  "$OUT/cfg" \
  -nvram_directory "$OUT/nvram" \
  -state_directory "$OUT/sta" \
  -snapshot_directory "$OUT/snap" \
  -diff_directory "$OUT/diff" \
  -input_directory "$OUT/inp" \
  -share_directory "$OUT/share" \
  -comment_directory "$OUT/comment" \
  -video none -sound none -nothrottle \
  "$@"
