#!/usr/bin/env python3
"""Analyze DOSBox capture screenshots: pair voodka_NNN.png with shots.csv
timestamps, compute frame-to-frame visual difference, and report candidate
scene-transition windows (sustained changes, not single-frame flashes).

Usage: analyze_capture.py [rawdir]
"""

import csv
import os
import sys

import numpy as np
from PIL import Image


def main():
    rawdir = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     '..', 'captures', 'raw'))
    shots = []
    with open(os.path.join(rawdir, 'shots.csv')) as f:
        for row in csv.DictReader(f):
            shots.append(float(row['t_seconds']))

    pngs = sorted(p for p in os.listdir(rawdir) if p.endswith('.png'))
    sigs, times, names = [], [], []
    for i, p in enumerate(pngs):
        path = os.path.join(rawdir, p)
        if os.path.getsize(path) == 0:
            continue
        img = Image.open(path).convert('RGB').resize((64, 40), Image.BILINEAR)
        sigs.append(np.asarray(img, dtype=np.float32).reshape(-1))
        names.append(p)
        times.append(shots[i] if i < len(shots) else float('nan'))
    sigs = np.stack(sigs)
    print('frames: %d, time span %.1f..%.1f s' % (len(sigs), times[0], times[-1]))

    # sustained change: diff between frames 3 apart
    d = np.abs(sigs[3:] - sigs[:-3]).mean(axis=1)
    # instantaneous change (flashes)
    d1 = np.abs(sigs[1:] - sigs[:-1]).mean(axis=1)

    print('\ntop sustained-change candidates (|sig[i+3]-sig[i]|):')
    order = np.argsort(d)[::-1]
    picked = []
    for idx in order:
        t = times[idx]
        if any(abs(t - p) < 4.0 for p in picked):
            continue
        picked.append(t)
        print('  %6.1fs  %-14s diff=%.2f' % (t, names[idx], d[idx]))
        if len(picked) >= 20:
            break

    # per-10s average color (coarse scene signature for manual mapping)
    print('\nsegment means (10s bins):')
    for t0 in range(0, int(times[-1]) + 10, 10):
        m = [s for s, t in zip(sigs, times) if t0 <= t < t0 + 10]
        if not m:
            continue
        mean = np.stack(m).mean(axis=0)
        rgb = [int(mean[i * 64 * 40:(i + 1) * 64 * 40].mean() * 64 * 40 /
                   mean.size * 3) for i in range(3)]  # rough channel split
        print('  %3d-%3ds  mean_level=%.1f' % (t0, t0 + 10, mean.mean()))


if __name__ == '__main__':
    main()
