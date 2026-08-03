#!/usr/bin/env python3
"""Audit voodka core COFF .obj files for IMAGE_REL_AMD64_ADDR32 relocations.

The known port gotcha: on the vendored NASM, `[rel X]` -> REL32 (safe), but
`[rel X + reg]` (indexed access into a .data/.bss array) -> ADDR32, which the
linker C4049/LNK2017 rejects, or worse silently truncates a high-VA address.
The build hygiene standard (AGENTS.md) is: 0 ADDR32 relocations in every core
object (esp. p8.obj, which must be confirmed on every build).

Usage: python audit_addr32.py <obj...>
"""
import struct, sys, os

IMAGE_REL_AMD64_ADDR32 = 0x0001
REL_NAMES = {1:"ADDR32",3:"ADDR32NB",4:"REL32",5:"REL32_1",6:"REL32_2",
             7:"REL32_3",8:"REL32_4",9:"REL32_5",10:"ADDR64",14:"REL32_6",
             15:"REL32_7",16:"REL32_8",17:"REL32_9",18:"REL32_10",
             20:"SECTION",21:"SECREL",24:"ADDR32_10"}

def parse(path):
    d = open(path,'rb').read()
    if d[:2] != b'\x64\x86':
        return None, "not amd64 COFF"
    nsects, tsym = struct.unpack('<HH', d[2:6])
    symptr, nsym   = struct.unpack('<II', d[8:16])
    shdr = 20
    sections = []
    for i in range(nsects):
        base = shdr + i*40
        name = d[base:base+8].rstrip(b'\0').decode('latin1','replace')
        vsize, vma, rawsz = struct.unpack('<III', d[base+8:base+20])
        rawptr, relptr  = struct.unpack('<II', d[base+20:base+28])
        nrel,  nln = struct.unpack('<HH', d[base+32:base+36])
        flags = struct.unpack('<I', d[base+36:base+40])[0]
        sections.append(dict(name=name, rawsz=rawsz, rawptr=rawptr,
                             relptr=relptr, nrel=nrel))
    # symbols
    syms = []
    for i in range(nsym):
        base = symptr + i*18
        nm = d[base:base+8]
        val, sec = struct.unpack('<Ih', d[base+8:base+14])
        cls = d[base+16]
        # skip aux entries (1 aux record follows for many)
        name = nm
        if nm[:4] == b'\0\0\0\0':
            str_off = struct.unpack('<I', nm[4:8])[0]
            # string table after symbols
            name = d[symptr+nsym*18+4+str_off:].split(b'\0')[0]
        syms.append((name, val, sec, cls))
    bad = []
    for si, s in enumerate(sections):
        if s['nrel'] == 0:
            continue
        p = s['relptr']
        for r in range(s['nrel']):
            va, syno, typ = struct.unpack('<IIH', d[p+r*10:p+r*10+10])
            if typ == IMAGE_REL_AMD64_ADDR32:
                sym = syms[syno] if syno < len(syms) else (b'<?>',0,0,0)
                bad.append((s['name'], va, sym[0], sym[2]))
    return sections, bad

def main(argv):
    tot = 0
    for path in argv:
        if not os.path.exists(path):
            print("MISSING", path); continue
        secs, bad = parse(path)
        if bad is None:
            print("SKIP   ", os.path.basename(path), bad); continue
        print("OBJECT %-16s ADDR32=%-3d  (%d relocs total)" % (
            os.path.basename(path), len(bad),
            sum(s['nrel'] for s in secs)))
        for sec, va, sym, tsec in bad:
            nm = sym.decode('latin1','replace') if isinstance(sym,bytes) else sym
            tot += 1
            print("    section=%-8s va=0x%-4x -> %s (symsec=%d)" % (sec, va, nm, tsec))
    print("TOTAL ADDR32 relocations: %d" % tot)

if __name__ == '__main__':
    main(sys.argv[1:])
