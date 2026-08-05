#!/usr/bin/env python3
"""P2 world-palette provenance check (CTest).

The original P2 installs the inline `jjdj` palette from CODE/P2/WORLD.P!
(`_pal dd jjdj` + 768 DB bytes). The port used to load vodka-37 (2WORLD.PAL,
which is P5's palette and maps the P2 stadium textures to olive/gold instead of
the shipped red/blue world). This test re-derives the 768-byte jjdj palette from
the read-only reference source and compares it byte-for-byte with the committed
port/core/parts/jjdj.pal that p2.asm incbin's, and also asserts every byte is a
legal 6-bit VGA value.

Exits 0 on full match, 1 otherwise.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
SRC = os.path.join(
    ROOT, 'reference', 'source', 'demoscene-absence-voodka-master',
    'CODE', 'P2', 'WORLD.P!')
COMMITTED = os.path.join(ROOT, 'port', 'core', 'parts', 'jjdj.pal')


def parse_world_pal(path):
    """Return the 768 jjdj bytes after the 'jjdj:' label in WORLD.P!."""
    text = open(path, 'r', encoding='latin-1').read()
    body = text.split('jjdj:', 1)[1]
    nums = [int(x) for x in re.findall(r'\b\d+\b', body)]
    if len(nums) < 768:
        raise ValueError('WORLD.P! jjdj: only %d bytes found (expected 768)' % len(nums))
    return bytes(nums[:768])


def main():
    try:
        expected = parse_world_pal(SRC)
    except Exception as e:
        print('jjdj.repro: cannot parse WORLD.P!:', e)
        return 1
    committed = open(COMMITTED, 'rb').read()
    bad = 0
    if len(expected) != 768 or len(committed) != 768:
        print('jjdj.repro: size mismatch (expected %d, committed %d)' % (
            len(expected), len(committed)))
        bad += 1
    for i in range(min(len(expected), len(committed))):
        if not (0 <= expected[i] <= 63):
            print('jjdj.repro: WORLD.P! byte %d = %d (>63, not 6-bit)' % (i, expected[i]))
            bad += 1
        if committed[i] != expected[i]:
            print('jjdj.repro: jjdj.pal[%d] = %d != WORLD.P! %d' % (
                i, committed[i], expected[i]))
            bad += 1
    if bad == 0:
        print('jjdj.repro: OK (768 bytes identical to original P2/WORLD.P!, 6-bit clean)')
        return 0
    print('jjdj.repro: %d mismatch(es)' % bad)
    return 1


if __name__ == '__main__':
    sys.exit(main())
