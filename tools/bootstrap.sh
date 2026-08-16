#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Fetch upstream dependencies into third_party/ and pin them in deps.lock.
#
#   tools/bootstrap.sh              fetch everything
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     re-pin deps.lock to current upstream HEADs
#
# Nothing is copied into rtl/ automatically. Licence terms differ per dependency
# and one of them forbids copying outright — read the report this prints, and
# THIRD_PARTY.md, before lifting a single line.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_MAME=1
DO_UPDATE=0

for a in "$@"; do
  case "$a" in
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '4,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------- dependencies
#
# name | repo | branch | role | licence
#
# USABILITY IS THE LICENCE COLUMN, NOT THE ROLE COLUMN. `saturn` is fetched
# because reading it and running it as an oracle is permitted. Copying or
# adapting it is not. See THIRD_PARTY.md.

DEPS=(
  "template|MiSTer-devel/Template_MiSTer|master|core skeleton and sys/ framework|GPL-2.0-or-later"
  "fx68k|ijor/fx68k|master|68000 sound CPU — port candidate|GPL-3.0"
  "n64|MiSTer-devel/N64_MiSTer|main|M2-E area comparable, RDP architecture reference|GPL-3.0"
  "saturn|srg320/Saturn|master|SCSP — READ ONLY, oracle only, DO NOT COPY|NONE"
)

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need git
mkdir -p "$VENDOR"

# Move a fresh clone onto its recorded pin.
#
# Without this the lock is decorative: every clone takes branch HEAD and then
# deps.lock is overwritten with whatever arrived, so the file records what you
# happened to get rather than constraining what you got. MAME is the oracle this
# project verifies against — it moving silently between two machines, or between
# two runs on one machine, undermines every comparison made against it.
checkout_pin() { # name dir
  local name="$1" dir="$2" want
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  [ -f "$LOCK" ] || return 0
  want="$(awk -v n="$name" '$1 == n { print $3 }' "$LOCK")"
  if [ -z "$want" ]; then return 0; fi
  if [ "$(git -C "$dir" rev-parse HEAD)" = "$want" ]; then return 0; fi
  say "   pinning $name to $want"
  git -C "$dir" fetch -q --depth 1 origin "$want" || {
    warn "   could not fetch pinned $want for $name — leaving at branch HEAD"
    return 0
  }
  git -C "$dir" checkout -q --detach FETCH_HEAD
}

# ------------------------------------------------------------------- ordinary

for spec in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role licence <<<"$spec"
  dest="$VENDOR/$name"
  say "== $name  ($licence)"
  if [ "$licence" = "NONE" ]; then
    warn "   NO LICENCE — all rights reserved. Read and oracle only. Do not copy or adapt."
  fi
  if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch -q --depth 1 origin "$branch" || warn "   fetch failed, using local"
    [ "$DO_UPDATE" = 1 ] && git -C "$dest" reset -q --hard FETCH_HEAD
  else
    git clone -q --depth 1 --branch "$branch" "https://github.com/$repo.git" "$dest"
  fi
  checkout_pin "$name" "$dest"
done

# ----------------------------------------------------------------------- mame
#
# MAME is enormous. Blobless partial clone plus a non-cone sparse checkout of
# only the devices this core needs. Every file below was licence-checked
# individually — MAME is GPL-2.0 as a whole while these files are BSD-3-Clause.
# Check the SPDX header of anything added here.

if [ "$DO_MAME" = 1 ]; then
  dest="$VENDOR/mame"
  say "== mame  (sparse reference checkout, BSD-3-Clause per file)"
  if [ ! -d "$dest/.git" ]; then
    git clone -q --filter=blob:none --no-checkout \
      https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    # Pin only AFTER the sparse patterns exist: the clone is --no-checkout, so
    # checking out a ref first would materialise the entire tree.
    git -C "$dest" sparse-checkout set \
      '/src/devices/cpu/i960/*' \
      '/src/devices/cpu/mb86233/*' \
      '/src/devices/sound/scsp.*' \
      '/src/devices/machine/i8251.*' \
      '/src/devices/machine/eepromser.*' \
      '/src/devices/machine/gen_fifo.*' \
      '/src/mame/sega/model2*' \
      '/src/mame/sega/segaic24*' \
      '/src/mame/sega/315_5649.*' \
      '/src/mame/sega/m2comm.*'
    git -C "$dest" checkout -q "$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || echo master)"
  fi
  checkout_pin mame "$dest"
fi

# ----------------------------------------------------------------------- lock

if [ "$DO_UPDATE" = 1 ] || [ ! -f "$LOCK" ]; then
  say "== writing deps.lock"
  {
    echo "# Pinned upstream revisions. Regenerate with tools/bootstrap.sh --update"
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for spec in "${DEPS[@]}"; do
      IFS='|' read -r name repo _ _ _ <<<"$spec"
      [ -d "$VENDOR/$name/.git" ] &&
        printf '%-14s %-36s %s\n' "$name" "$repo" "$(git -C "$VENDOR/$name" rev-parse HEAD)"
    done
    [ -d "$VENDOR/mame/.git" ] &&
      printf '%-14s %-36s %s\n' mame mamedev/mame "$(git -C "$VENDOR/mame" rev-parse HEAD)"
  } >"$LOCK"
fi

# --------------------------------------------------------------------- report

cat <<'REPORT'

Licence report — read before lifting any code
---------------------------------------------
  template   GPL-2.0-or-later  the or-later clause is what makes GPL-3 lawful here
  fx68k      GPL-3.0           port freely; keep Jorge Cwik's copyright
  n64        GPL-3.0           port freely; M2-E measurement target
  mame       BSD-3-Clause      PER FILE. Check the SPDX header of every file.
                               MAME is GPL-2.0 as a whole. The files fetched
                               here are BSD-3; others are not.
  saturn     NONE              ALL RIGHTS RESERVED. Read it, run it as an
                               oracle, and copy nothing. Not a licence you can
                               work around by translating or restructuring.

Key references for the current milestone (P1, i960KB):
  third_party/mame/src/devices/cpu/i960/       the only i960 reference that exists
  third_party/mame/src/mame/sega/model2*       board layout, memory map, clocks
REPORT
