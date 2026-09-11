#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Put ONE BUILT RBF on the board, reload the core, capture the debug UART
# stream (m2_dbg_stream, 115200 on the board's ttyS1) for a while, and bring
# the capture back for tools/decode_uart.py.
#
#   M2_MISTER_IP=192.168.1.105 tools/board-capture.sh build/x/s14/output_files/Model2.rbf out.txt 240
#
# NO CREDENTIALS LIVE IN THIS FILE -- see tools/deploy-mister.sh: give ssh a
# key, or point SSH_ASKPASS at a script that prints the password and set
# SSH_ASKPASS_REQUIRE=force.
#
# It backs up the RBF it replaces (Model2.rbf.prev), verifies the copy by MD5,
# and only then issues the reload; the UART reader (tools/uart_capture.py) is
# copied over every time so the board runs the version in this tree.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RBF=${1:?rbf}; OUT=${2:?out.txt}; SECS=${3:-170}
IP="${M2_MISTER_IP:?set M2_MISTER_IP to the address of the board}"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$IP"
$SSH "cp -f /media/fat/_Arcade/cores/Model2.rbf /media/fat/_Arcade/cores/Model2.rbf.prev" 2>/dev/null
scp -o StrictHostKeyChecking=no "$RBF" root@$IP:/media/fat/_Arcade/cores/Model2.rbf 2>/dev/null
want=$(md5sum "$RBF" | cut -d' ' -f1); got=$($SSH "md5sum /media/fat/_Arcade/cores/Model2.rbf" 2>/dev/null | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "MD5 MISMATCH after copy"; exit 1; }
echo "deployed $RBF md5 $want"
$SSH 'echo "load_core /media/fat/_Arcade/Daytona USA (Deluxe 93).mra" > /dev/MiSTer_cmd' 2>/dev/null
echo "core reload issued $(date +%T); capturing ${SECS}s"
sleep 5
scp -o StrictHostKeyChecking=no "$ROOT/tools/uart_capture.py" root@$IP:/tmp/uartcap.py 2>/dev/null
$SSH "python3 /tmp/uartcap.py $SECS /tmp/uart.txt" 2>/dev/null
scp -o StrictHostKeyChecking=no root@$IP:/tmp/uart.txt "$OUT" 2>/dev/null
echo "capture $(wc -l < "$OUT") lines -> $OUT"
