#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Put a built core and its data on the board.
#
#   M2_MISTER_IP=192.168.1.105 tools/deploy-mister.sh [path/to/m2tiles.zip]
#
# NO CREDENTIALS LIVE IN THIS FILE. Give ssh a key, or point SSH_ASKPASS at a
# script that prints the password and set SSH_ASKPASS_REQUIRE=force. The board's
# default login is documented by MiSTer, not by this repository, and a password
# committed here would be a password in every clone of it forever.
#
# IT BACKS UP WHAT IT REPLACES. `Model2.rbf.prev` and `m2tiles.zip.prev` are left
# on the board, because the fastest way to tell a broken build from a broken
# change is to put the previous one back.
#
# IT VERIFIES BY MD5 RATHER THAN BY EXIT CODE. scp reporting success and the
# board holding a truncated file is a real outcome on a device that is also
# writing an SD card, and "I flashed it and it behaves identically" is exactly
# what a silent short write looks like.

set -euo pipefail

IP="${M2_MISTER_IP:?set M2_MISTER_IP to the address of the board}"   # no apostrophe: ${VAR:?word} quote-processes the word
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TILES="${1:-}"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
RBF="$ROOT/build/release/Model2.rbf"

[ -f "$RBF" ] || { echo "no $RBF -- run: make release" >&2; exit 1; }

# Built as separate commands rather than one quoted block: the block carried a
# nested `[ -n '$TILES' ]`, and single quotes inside a double-quoted remote
# command are a quoting level this script does not need.
$SSH "root@$IP" "mkdir -p /media/fat/_Arcade/cores /media/fat/games/mame"
$SSH "root@$IP" "cp -f /media/fat/_Arcade/cores/Model2.rbf /media/fat/_Arcade/cores/Model2.rbf.prev 2>/dev/null || true"
if [ -n "$TILES" ]; then
  $SSH "root@$IP" "cp -f /media/fat/games/mame/m2tiles.zip /media/fat/games/mame/m2tiles.zip.prev 2>/dev/null || true"
fi

scp -o StrictHostKeyChecking=no "$RBF" "root@$IP:/media/fat/_Arcade/cores/Model2.rbf"
scp -o StrictHostKeyChecking=no "$ROOT/mra/"*.mra "root@$IP:/media/fat/_Arcade/"
[ -n "$TILES" ] && scp -o StrictHostKeyChecking=no "$TILES" "root@$IP:/media/fat/games/mame/m2tiles.zip"

echo "verifying:"
want_rbf=$(md5sum "$RBF" | cut -d' ' -f1)
got_rbf=$($SSH "root@$IP" "md5sum /media/fat/_Arcade/cores/Model2.rbf" | cut -d' ' -f1)
[ "$want_rbf" = "$got_rbf" ] && echo "  Model2.rbf   OK  $got_rbf" || { echo "  Model2.rbf   MISMATCH"; exit 1; }
if [ -n "$TILES" ]; then
  want_z=$(md5sum "$TILES" | cut -d' ' -f1)
  got_z=$($SSH "root@$IP" "md5sum /media/fat/games/mame/m2tiles.zip" | cut -d' ' -f1)
  [ "$want_z" = "$got_z" ] && echo "  m2tiles.zip  OK  $got_z" || { echo "  m2tiles.zip  MISMATCH"; exit 1; }
fi
echo "previous core kept as /media/fat/_Arcade/cores/Model2.rbf.prev"
