#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# RUNS ON THE BOARD (tools/board-capture.sh copies it there): reads the debug
# UART (m2_dbg_stream, ttyS1 at 115200, raw) for N seconds into a file.
#   python3 uartcap.py <seconds> <out>
import os, sys, termios, time
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/uart.txt"
fd = os.open("/dev/ttyS1", os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[3] = 0
a[4] = a[5] = termios.B115200
a[6] = list(a[6]); a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
buf = bytearray(); t0 = time.time()
while time.time() - t0 < dur:
    try:
        d = os.read(fd, 4096)
        if d: buf += d
        else: time.sleep(0.01)
    except BlockingIOError: time.sleep(0.01)
os.close(fd); open(out, "wb").write(buf)
print("bytes", len(buf), "lines", buf.count(b"\n"))
