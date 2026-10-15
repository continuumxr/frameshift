#!/usr/bin/env python3
"""FrameShift Quest 2 channel - executable-page check for the LINKED fs-rpcd (rev 6, nit H).
Offline; stdlib; run with -I -B.

    python3 -I -B seg-check.py BINARY        exit 0 = OK, 1 = refused, 2 = malformed

Requires (fail closed):
  - ELFCLASS64 / little-endian / EM_AARCH64 / ET_EXEC, e_phentsize 56, e_shentsize 64, tables
    inside the file;
  - exactly one PT_LOAD with PF_X;
  - its page span - in memory [floor(vaddr), ceil(vaddr+memsz)) and in the file
    [floor(off), ceil(off+filesz)), with the page size = that segment's p_align (64 KiB here, the
    largest page an AArch64 kernel may use) - contains no byte of any allocated section that is
    not one of the code sections .text/.init/.fini/.iplt, and no byte of any other PT_LOAD;
  - every section inside that segment is one of those code sections.
So no .rodata (or any other non-code byte) is mapped executable. Without -z separate-code lld
put .rodata's tail on the first executable page (final re-review nit H).
"""
import struct
import sys

PT_LOAD, PF_X, SHF_ALLOC, SHT_NOBITS = 1, 1, 2, 8
CODE = {".text", ".init", ".fini", ".iplt"}


def fail(m):
    print("SEG CHECK FAILED: " + m); return 1


def main(argv):
    try:
        d = open(argv[0], "rb").read()
        if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
            print("SEG CHECK MALFORMED: not ELF64 LE"); return 2
        e_type, e_machine = struct.unpack_from("<HH", d, 16)
        e_phoff, e_shoff = struct.unpack_from("<QQ", d, 0x20)
        e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", d, 0x36)
        if e_type != 2 or e_machine != 183 or e_phentsize != 56 or e_shentsize != 64 or e_shnum < 2:
            print("SEG CHECK MALFORMED: not an AArch64 ET_EXEC with standard tables"); return 2
        if e_phoff + e_phnum * 56 > len(d) or e_shoff + e_shnum * 64 > len(d) or not 0 < e_shstrndx < e_shnum:
            print("SEG CHECK MALFORMED: tables outside the file"); return 2
        ph = [struct.unpack_from("<IIQQQQQQ", d, e_phoff + i * 56) for i in range(e_phnum)]
        loads = [p for p in ph if p[0] == PT_LOAD]
        xs = [p for p in loads if p[1] & PF_X]
        if len(xs) != 1:
            return fail("expected one executable PT_LOAD, found %d" % len(xs))
        _t, _f, off, vaddr, _pa, filesz, memsz, align = xs[0]
        pg = max(align, 4096)
        lo_v, hi_v = vaddr // pg * pg, -(-(vaddr + memsz) // pg) * pg
        lo_f, hi_f = off // pg * pg, -(-(off + filesz) // pg) * pg
        sh = [struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * 64) for i in range(e_shnum)]
        so = sh[e_shstrndx][4]
        def nm(n):
            e = d.index(b"\0", so + n)
            return d[so + n:e].decode("latin-1")
        bad = []
        inside = []
        for s in sh[1:]:
            name, typ, flags, addr, soff, size = nm(s[0]), s[1], s[2], s[3], s[4], s[5]
            if not (flags & SHF_ALLOC) or size == 0:
                continue
            in_seg = vaddr <= addr < vaddr + memsz
            if in_seg:
                inside.append(name)
                if name not in CODE:
                    bad.append("%s lies inside the executable segment" % name)
                continue
            if addr < hi_v and addr + size > lo_v:
                bad.append("%s [0x%x,0x%x) shares an executable page (memory)" % (name, addr, addr + size))
            if typ != SHT_NOBITS and soff < hi_f and soff + size > lo_f:
                bad.append("%s file bytes [0x%x,0x%x) fall in the executable file pages" % (name, soff, soff + size))
        for p in loads:
            if p is xs[0]:
                continue
            if p[3] < hi_v and p[3] + p[6] > lo_v:
                bad.append("PT_LOAD at 0x%x shares an executable page" % p[3])
        if bad:
            return fail("; ".join(bad[:6]))
        print("seg-check: OK (one RX PT_LOAD vaddr 0x%x-0x%x, page %d KiB: pages hold only %s; no other section or segment shares them)"
              % (vaddr, vaddr + memsz, pg // 1024, "/".join(sorted(set(inside)))))
        return 0
    except Exception as e:
        print("SEG CHECK MALFORMED: parse error %r" % (e,)); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
