#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976: the tempo of a recording against a real cabinet's. 1.5 s windows
# of a 150-6000 Hz log spectrogram (10 ms hop), each matched in the arcade
# recording near its predicted time; a line through the matches gives the
# ratio (arcade seconds per second of this), the residual its spread. Also
# snd_hatlag: the 5-10 kHz onset lag against the arcade, second by second.
#   snd_tempo_arcade.py tempo <arcade.wav> <x.wav | p16 out.bin> <t0> <t1> <arcade time at t0> <ratio guess>
#   snd_tempo_arcade.py hats  <arcade.wav> <x.wav> <t0> <arcade time at t0> <seconds>
# Recordings are ROM-derived or third-party: they stay outside the repository.
import sys, wave, numpy as np
from numpy.fft import rfft, irfft, rfftfreq
sr = 44100
def load(p):
    if not p.endswith('.wav'):
        o = np.fromfile(p, dtype=np.int32).reshape(-1, 2).astype(float); return (o[:, 0] + o[:, 1]) / 2
    w = wave.open(p); d = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float)
    return d.reshape(-1, w.getnchannels()).mean(1)
def band(x, lo, hi):
    X = rfft(x); f = rfftfreq(len(x), 1 / sr); X[(f < lo) | (f > hi)] = 0; return irfft(X, len(x))
def env(x, lo, hi):
    y = band(x, lo, hi); e = np.sqrt(np.convolve(y * y, np.ones(441) / 441, 'same'))[::441]
    le = np.log(e + 1); return np.maximum(np.diff(le, prepend=le[0]), 0)
def spec(y):
    hop, n = 441, 2048
    win = np.hanning(n)
    fr = [np.abs(np.fft.rfft(y[i:i + n] * win)) for i in range(0, len(y) - n, hop)]
    f = np.fft.rfftfreq(n, 1 / sr); m = (f > 150) & (f < 6000)
    S = np.log(np.array(fr)[:, m] + 1.0)
    return S - S.mean(1, keepdims=True)
def seg(y, t, d): return y[int(t * sr):int((t + d) * sr)]
mode, arc, x = sys.argv[1], load(sys.argv[2]), load(sys.argv[3])
if mode == 'tempo':
    t0, t1, a0, ratio0 = map(float, sys.argv[4:8])
    pts = []
    for t in np.arange(t0, t1 - 1.5, 0.5):
        A = spec(seg(x, t, 1.5)); ga = a0 + (t - t0) * ratio0
        B = spec(seg(arc, ga - 0.3, 2.1)); best = None
        for k in range(0, B.shape[0] - A.shape[0]):
            Bk = B[k:k + A.shape[0]]
            c = np.sum(A * Bk) / np.sqrt(np.sum(A * A) * np.sum(Bk * Bk))
            if best is None or c > best[0]: best = (c, k)
        pts.append((t, ga - 0.3 + best[1] * 0.01, best[0]))
    P = np.array(pts); good = P[:, 2] > 0.3
    sl, ic = np.polyfit(P[good, 0], P[good, 1], 1)
    res = P[good, 1] - (sl * P[good, 0] + ic)
    print('windows %d (corr > 0.3: %d, median corr %.2f)' % (len(P), good.sum(), np.median(P[:, 2])))
    print('arcade time per second of this: %.4f -> this runs %+.2f%% against the arcade (residual sd %.1f ms)' % (sl, (sl - 1) * 100, res.std() * 1e3))
else:
    t0, a0, dur = map(float, sys.argv[4:7])
    ex = env(x[int(t0 * sr):int((t0 + dur) * sr)], 5000, 10000)
    ea = env(arc[int((a0 - 0.5) * sr):int((a0 + dur + 0.5) * sr)], 5000, 10000)
    out = []
    for k in range(0, int(dur) - 1):
        s = ex[k * 100:(k + 1) * 100]; best = None
        for lag in range(-40, 41):
            b = ea[50 + k * 100 + lag:50 + (k + 1) * 100 + lag]
            c = np.dot(s - s.mean(), b - b.mean()) / (np.std(s) * np.std(b) * len(s) + 1e-9)
            if best is None or c > best[0]: best = (c, lag)
        out.append((k, best[1] * 10, best[0]))
    print(' '.join('%d:%+dms(%.2f)' % o for o in out))
