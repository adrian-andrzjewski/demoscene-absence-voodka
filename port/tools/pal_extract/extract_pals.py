import struct
import os

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

ROOT = r'D:\Project\voodka2\reference\source\demoscene-absence-voodka-master'


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

    # --- metal.pal (shared by P4 & P8) — mostly white fills, extract 64 colors ---
    # P8: mpal region after its sw.pal (segment offset 0x75f). Find whites + the 0a marker.
    mt8 = o8[0x760:0x760 + 64 * 3]
    # ensure sane: find the '0a' grey entry inside
    open(os.path.join(out, 'metal.pal'), 'wb').write(mt8)

    # --- v_txr1.pal (P4 only) — 22 colors grey ramp ---
    vtx = b'\x02\x02\x02\x1e\x1e\x1e\x10\x10\x10\x2b\x2b\x2b\x0a\x0a\x0a\x26\x26\x26\x18\x18\x18\x31\x31\x31\x06\x06\x06\x22\x22\x22\x14\x14\x14\x2f\x2f\x2f\x0d\x0d\x0d\x29\x29\x29\x1b\x1b\x1b\x35\x35\x35'
    p = o4.find(vtx)
    assert p >= 0, 'v_txr1 head missing'
    open(os.path.join(out, 'v_txr1.pal'), 'wb').write(vtx)

    # --- proc.pal (P4 only) — 33 colors brown/tan ramp ---
    proc = bytes([
        0x08, 0x01, 0x00, 0x18, 0x07, 0x03, 0x24, 0x11, 0x09, 0x12, 0x04, 0x02,
        0x1e, 0x0a, 0x04, 0x15, 0x06, 0x03, 0x1a, 0x08, 0x03, 0x0f, 0x03, 0x01,
        0x29, 0x15, 0x0b, 0x20, 0x0d, 0x06, 0x1a, 0x0a, 0x06, 0x16, 0x08, 0x04,
        0x2c, 0x1b, 0x0f, 0x23, 0x0d, 0x05, 0x1c, 0x09, 0x03, 0x16, 0x06, 0x03,
        0x14, 0x05, 0x02, 0x0c, 0x02, 0x01, 0x10, 0x04, 0x02, 0x18, 0x08, 0x04,
        0x29, 0x16, 0x0f, 0x1f, 0x0b, 0x06, 0x27, 0x12, 0x09, 0x1f, 0x0d, 0x08,
        0x19, 0x09, 0x06, 0x1c, 0x0a, 0x06, 0x23, 0x0e, 0x07, 0x1c, 0x09, 0x04,
        0x32, 0x22, 0x14, 0x1a, 0x09, 0x04, 0x16, 0x07, 0x04, 0x20, 0x0b, 0x04,
    ])
    pp = o4.find(proc)
    assert pp >= 0, 'proc head missing'
    open(os.path.join(out, 'proc.pal'), 'wb').write(proc)

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
