#!/usr/bin/env python3
"""FIXTURES ONLY: craft a malformed copy of a relocatable ELF (rev 6). stdlib; run with -I -B.

    python3 -I -B elf-mutate.py IN OUT MODE

MODE: m1 e_shentsize=0 | m2 e_shnum=1 | m3 .text SHF_EXECINSTR cleared and renamed | m4 .text as
SHT_NOBITS | m5 e_shoff past the end of the file | m6 e_shstrndx out of range | m7 e_machine x86-64
| m8 a RELA section retargeted at .bss | m9 ELFCLASS32 | m10 file truncated to half | m11 .rela.text
turned into SHT_REL. The input is never modified.
"""
import struct
import sys


def main(a):
    src, dst, mode = a
    d = bytearray(open(src, "rb").read())
    shoff, = struct.unpack_from("<Q", d, 0x28)
    shnum, shstrndx = struct.unpack_from("<HH", d, 0x3c)

    def sec(i):
        return list(struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * 64))

    def put(i, s):
        struct.pack_into("<IIQQQQIIQQ", d, shoff + i * 64, *s)

    so = sec(shstrndx)[4]

    def name(i):
        n = sec(i)[0]; e = d.index(b"\0", so + n); return d[so + n:e].decode()

    idx = {name(i): i for i in range(1, shnum)}
    t = idx[".text"]
    if mode == "m1":
        struct.pack_into("<H", d, 0x3a, 0)
    elif mode == "m2":
        struct.pack_into("<H", d, 0x3c, 1)
    elif mode == "m3":
        s = sec(t); s[2] &= ~0x4; s[0] = sec(idx[".bss"])[0]; put(t, s)
    elif mode == "m4":
        s = sec(t); s[1] = 8; put(t, s)
    elif mode == "m5":
        struct.pack_into("<Q", d, 0x28, len(d))
    elif mode == "m6":
        struct.pack_into("<H", d, 0x3e, shnum)
    elif mode == "m7":
        struct.pack_into("<H", d, 18, 62)
    elif mode == "m8":
        r = idx[".rela.rodata"]; s = sec(r); s[7] = idx[".bss"]; put(r, s)
    elif mode == "m9":
        d[4] = 1
    elif mode == "m10":
        d = d[:len(d) // 2]
    elif mode == "m11":
        r = idx[".rela.text"]; s = sec(r); s[1] = 9; put(r, s)
    else:
        raise SystemExit("unknown mode")
    open(dst, "wb").write(bytes(d))


if __name__ == "__main__":
    main(sys.argv[1:])
