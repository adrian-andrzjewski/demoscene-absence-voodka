#!/usr/bin/env python3
"""Compute the ProTracker row->time timeline for amnezja2.mod (14-channel).

Parses the module, walks the played row sequence (honoring Fxx speed/tempo,
Bxx position jump, Dxx pattern break), and writes a CSV:
    modpos_hex, order, row, ms
where ModPos = (order << 8) | row, the demo's timeline currency.

Usage: modtimeline.py [module] [out.csv]
Defaults: ../../music/amnezja2.mod -> ./modtimeline.csv
Also prints the wall-clock position of the port's kPartStartModPos table
and reports any Bxx/Dxx usage.
"""

import csv
import os
import sys


def parse_rows(data, nch=14):
    assert data[1080:1084] == b'14CH', 'expected a 14CH module'
    song_len = data[950]
    orders = list(data[952:952 + song_len])
    pat_bytes = 64 * nch * 4
    base = 1084
    return orders, base, pat_bytes


def timeline(path):
    data = open(path, 'rb').read()
    orders, base, pat_bytes = parse_rows(data)
    speed, bpm = 6, 125          # ProTracker defaults
    t = 0.0
    rows = []
    order_i, row = 0, 0
    visited = set()
    jumps = []
    while order_i < len(orders):
        state = (order_i, row, speed, bpm)
        if state in visited:      # loop point (e.g. B00 at the end)
            rows.append(((order_i << 8) | row, order_i, row, t * 1000.0, speed, bpm, 'LOOP'))
            break
        visited.add(state)
        pat = orders[order_i]
        rowoff = base + pat * pat_bytes + row * 14 * 4
        jump_order, break_row = None, None
        new_speed, new_bpm = None, None
        for ch in range(14):
            c, e = data[rowoff + ch * 4 + 2], data[rowoff + ch * 4 + 3]
            eff = c & 0x0F
            if eff == 0x0F and e:
                if e < 32:
                    new_speed = e
                else:
                    new_bpm = e
            elif eff == 0x0B:
                jump_order = e
            elif eff == 0x0D:
                break_row = ((e >> 4) * 10) + (e & 0x0F)
        rows.append(((order_i << 8) | row, order_i, row, t * 1000.0, speed, bpm, ''))
        t += speed * (2.5 / bpm)
        if new_speed:
            speed = new_speed
        if new_bpm:
            bpm = new_bpm
        if jump_order is not None or break_row is not None:
            next_order = jump_order if jump_order is not None else order_i + 1
            next_row = break_row if break_row is not None else 0
            jumps.append((order_i, row, next_order, next_row))
            order_i, row = next_order, next_row
            continue
        row += 1
        if row >= 64:
            order_i, row = order_i + 1, 0
    return rows, jumps


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    module = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(
        os.path.join(here, '..', '..', 'music', 'amnezja2.mod'))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, 'modtimeline.csv')

    rows, jumps = timeline(module)
    with open(out, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['modpos_hex', 'order', 'row', 'ms', 'speed', 'bpm', 'note'])
        for modpos, oi, r, ms, speed, bpm, note in rows:
            w.writerow(['0x%04x' % modpos, oi, r, '%.1f' % ms, speed, bpm, note])

    print('module: %s' % module)
    print('rows simulated: %d, last: %s' % (len(rows), rows[-1][:4]))
    if jumps:
        print('Bxx/Dxx usage (order,row -> order,row):')
        for j in jumps:
            print('  ', j)
    else:
        print('no Bxx/Dxx jumps; linear play')

    # wall-clock position of the port's scene-start table
    part_starts = [0x0000, 0x0400, 0x0B40, 0x0D40, 0x1200,
                   0x1B40, 0x1C40, 0x2040, 0x2640]

    def normalize(mp):
        # the demo's scene thresholds use "row 64" = end of pattern,
        # i.e. the first row of the next order
        order, row = (mp >> 8) & 0xFF, mp & 0xFF
        while row >= 64:
            order, row = order + 1, row - 64
        return (order << 8) | row

    by_modpos = {mp: ms for mp, _oi, _r, ms, _s, _b, _n in rows}
    print('\nkPartStartModPos -> wall clock (if playback starts at t=0):')
    for i, mp in enumerate(part_starts):
        nmp = normalize(mp)
        ms = by_modpos.get(nmp)
        label = 'part %d' % (i + 1) if i < 8 else 'end'
        suffix = '' if nmp == mp else ' (= 0x%04x)' % nmp
        print('  %-6s 0x%04x%s  %s' % (label, mp, suffix,
              ('%.1fs' % (ms / 1000.0)) if ms is not None else 'NOT REACHED'))
    print('\nwrote %s' % out)


if __name__ == '__main__':
    main()
