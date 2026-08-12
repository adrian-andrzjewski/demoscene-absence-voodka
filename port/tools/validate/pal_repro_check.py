#!/usr/bin/env python3
"""Palette-extraction reproducibility check (CTest).

Re-runs tools/pal_extract/extract_pals.py (which recovers the compile-time
palettes from the original OMF OBJs) and compares its output byte-for-byte
with the committed copies incbin'd by the ported parts (port/core/parts).

Exits 0 on full match.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
SCRIPT = os.path.join(HERE, '..', 'pal_extract', 'extract_pals.py')
OUT = os.path.join(HERE, '..', 'pal_extract', 'out')
REF = os.path.join(ROOT, 'port', 'core', 'parts')
PALS = ('jup.pal', 'tn.pal', 'sw.pal', 'p8_sw.pal', 'metal.pal', 'proc.pal')


def main():
    r = subprocess.run([sys.executable, SCRIPT, os.path.join(
        ROOT, 'reference', 'source', 'demoscene-absence-voodka-master')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        print('extract_pals.py failed')
        return 1
    bad = 0
    for p in PALS:
        a = open(os.path.join(OUT, p), 'rb').read()
        b = open(os.path.join(REF, p), 'rb').read()
        if a != b:
            print('MISMATCH', p)
            bad += 1
        else:
            print('  %-12s %3d bytes identical' % (p, len(a)))
    if bad:
        print('pal.repro: %d mismatches' % bad)
        return 1
    print('pal.repro: OK (extraction reproducible from the original OBJs)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
