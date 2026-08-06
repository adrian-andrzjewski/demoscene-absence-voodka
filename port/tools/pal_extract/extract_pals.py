import struct
import os
import sys

# Extract the compile-time .pal palette includes that are MISSING from the repo.
# The palettes were compiled into each part's TASM OMF .OBJ as raw 6-bit data
# (the includes are ASCII 'DB r,g,b,...' text files that TASM turned into bytes).
# Provenance: verified byte-identical content against the DANE runtime textures and
# cross-checked sw.pal/metal.pal between P4.OBJ and P8.OBJ.
#
# Layout of the data section is established from the part sources:
#   P3: spal(jup.pal, read as 16 colors by make_pal) then tunel_pal(tn.pal,16 colors)
#   P4: pal(768 zero buffer) spal1(sw.pal,64c) spal2(v_txr1.pal,22c)
#       spal3(proc.pal,33c) spal4(metal.pal,64c)
#   P8: pal(sw.pal) mpal(metal.pal)
#
# Reference tree root: argv[1] override, else derived from this script's
# location (port/tools/pal_extract -> repo root is three levels up).
_default_root = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    _default_root, 'reference', 'source', 'demoscene-absence-voodka-master')


def ledata_runs(path):
    """Return a list of (start, end) raw-OBJ runs of 6-bit (0..63) bytes that carry
    palette data, by walking LEDATA payloads without trusting loc counters."""
    o = open(path, 'rb').read()
    runs = []
    pos = 0
    while True:
        p = o.find(b'\xa0', pos)
        if p < 0:
            break
        L0 = o[p + 1]
        if L0 & 0x80:
            if p + 2 >= len(o):
                break
            length = (L0 & 0x7f) | (o[p + 2] << 7)
            hdr = p + 3
        else:
            length = L0
            hdr = p + 2
        if hdr + length > len(o):
            break
        if len(o[hdr:hdr + length]) < 3:
            break
        data = o[hdr:hdr + length][3:]  # skip index+2B offset
        runs.append(data)
        pos = p + 2 + length
    return runs


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
    os.makedirs(out, exist_ok=True)

    o4 = open(os.path.join(ROOT, r'CODE\P4\P4.OBJ'), 'rb').read()
    o8 = open(os.path.join(ROOT, r'CODE\P8\P8.OBJ'), 'rb').read()
    o3 = open(os.path.join(ROOT, r'CODE\P3\P3.OBJ'), 'rb').read()

    # --- sw.pal (shared by P4 & P8) — 64 colors, first color (16,3,0) ---
    sw_head = bytes([
        0x10, 0x03, 0x00, 0x24, 0x0d, 0x03, 0x05, 0x01, 0x00, 0x15, 0x0a, 0x04,
    ])
    a4 = o4.find(sw_head)
    a8 = o8.find(sw_head)
    assert a4 >= 0 and a8 >= 0, 'sw.pal head missing'
    assert o4[a4:a4 + 128] == o8[a8:a8 + 128], 'P4/P8 sw.pal mismatch'
    sw = o4[a4:a4 + 64 * 3]
    open(os.path.join(out, 'sw.pal'), 'wb').write(sw)

    # --- metal.pal (shared by P4 & P8) — 64 colors, chrome/silver-blue ramp ---
    # Verified location: P8.OBJ 0x821 (192 bytes), cross-checked in P4.OBJ 0xdb2.
    # (The earlier 0x8fb/0xb0b pins hit the all-white `bialy` table and made the
    # P8/P4 metal objects render pure white; the true data is the monotonic
    # bluish ramp starting (5,6,7) -> (63,63,63).)
    mt_head = bytes([0x05, 0x06, 0x07, 0x05, 0x07, 0x08, 0x06, 0x08, 0x09,
                     0x07, 0x09, 0x0a])
    a8m = o8.find(mt_head)
    a4m = o4.find(mt_head)
    assert a8m >= 0 and a4m >= 0, 'metal.pal head missing'
    assert a8m == 0x821 and a4m == 0xdb2, 'metal.pal offset moved'
    assert o8[a8m:a8m + 192] == o4[a4m:a4m + 192], 'P4/P8 metal.pal mismatch'
    open(os.path.join(out, 'metal.pal'), 'wb').write(o8[a8m:a8m + 192])

    # --- v_txr1.pal (P4 only) — 22 colors grey ramp (66 bytes; the last 6
    # colors are zero/black). The 12-byte head occurs exactly once in P4.OBJ.
    vtx_head = b'\x02\x02\x02\x1e\x1e\x1e\x10\x10\x10\x2b\x2b\x2b'
    p = o4.find(vtx_head)
    assert p >= 0 and o4.find(vtx_head, p + 1) < 0, 'v_txr1 head not unique'
    open(os.path.join(out, 'v_txr1.pal'), 'wb').write(o4[p:p + 22 * 3])

    # --- proc.pal (P4 only) — 33 colors brown/tan ramp (99 bytes). The
    # 12-byte head occurs exactly once in P4.OBJ.
    proc_head = bytes([0x08, 0x01, 0x00, 0x18, 0x07, 0x03, 0x24, 0x11, 0x09, 0x12, 0x04, 0x02])
    pp = o4.find(proc_head)
    assert pp >= 0 and o4.find(proc_head, pp + 1) < 0, 'proc head not unique'
    open(os.path.join(out, 'proc.pal'), 'wb').write(o4[pp:pp + 33 * 3])

    # --- jup.pal (P3) — 16 colors (48 bytes), region verified at 0x369..0x399 ---
    jup = o3[0x369:0x399]
    open(os.path.join(out, 'jup.pal'), 'wb').write(jup)

    # --- tn.pal (P3) — 16 colors starting 0x399 ---
    tn = o3[0x399:0x399 + 48]
    open(os.path.join(out, 'tn.pal'), 'wb').write(tn)

    for f in ('sw.pal', 'metal.pal', 'v_txr1.pal', 'proc.pal', 'jup.pal', 'tn.pal'):
        p = os.path.join(out, f)
        d = open(p, 'rb').read()
        print(f'{f}: {len(d)} bytes ({len(d)//3} colors) -> {p}')


if __name__ == '__main__':
    main()
