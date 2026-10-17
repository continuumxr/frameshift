#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Wrap a raw vendor ext4 image into a minimal synthetic `super` image.

LOCAL-ONLY test tooling (METACFG-SPEC §4.5.7 of the design: the
differential against Meta's real files runs only on the PM's machine and
is never committed). It writes a liblp-format super (primary + backup
geometry, one metadata slot pair for _a/_b, one block device, partitions
vendor_a and vendor_b both mapping the same linear extent) followed by the
vendor bytes, into a scratch path. Nothing of the vendor image is printed.

usage: wrap_super.py VENDOR_IMG OUT_SUPER
prints the resulting super size (the readers take it as --super-size).
"""
import hashlib
import shutil
import struct
import sys

RESERVED = 4096
GEO_SIZE = 4096
MMS = 65536
SLOTS = 2
LP_SECTOR = 512


def geometry():
    g = struct.pack('<II32sIII', 0x616C4467, 52, b'\0' * 32, MMS, SLOTS, 4096)
    c = hashlib.sha256(g).digest()
    g = g[:8] + c + g[40:]
    return g.ljust(GEO_SIZE, b'\0')


def metadata(vendor_off_sectors, vendor_sectors, dev_size):
    parts = b''
    for i, name in enumerate([b'vendor_a', b'vendor_b']):
        parts += struct.pack('<36sIIII', name, 0x1, 0, 1, 0)  # READONLY, extent 0, group 0
    ext = struct.pack('<QIQI', vendor_sectors, 0, vendor_off_sectors, 0)
    grp = struct.pack('<36sIQ', b'default', 0, 0)
    blk = struct.pack('<QIIQ36sI', 2048, 0, 0, dev_size, b'super', 0)
    tables = parts + ext + grp + blk
    off_p, off_e = 0, len(parts)
    off_g, off_b = off_e + len(ext), off_e + len(ext) + len(grp)
    hdr = struct.pack('<IHHI32sI32s', 0x414C5030, 10, 0, 128, b'\0' * 32, len(tables),
                      hashlib.sha256(tables).digest())
    hdr += struct.pack('<III', off_p, 2, 52) + struct.pack('<III', off_e, 1, 24)
    hdr += struct.pack('<III', off_g, 1, 48) + struct.pack('<III', off_b, 1, 64)
    assert len(hdr) == 128
    hc = hashlib.sha256(hdr).digest()
    hdr = hdr[:12] + hc + hdr[44:]
    return (hdr + tables).ljust(MMS, b'\0')


def main():
    src, out = sys.argv[1], sys.argv[2]
    with open(src, 'rb') as f:
        f.seek(0, 2)
        vsize = f.tell()
    vsize_pad = (vsize + LP_SECTOR - 1) // LP_SECTOR * LP_SECTOR
    start = 1024 * 1024  # vendor at 1 MiB
    dev_size = start + vsize_pad
    head = bytearray(start)
    geo = geometry()
    head[RESERVED:RESERVED + GEO_SIZE] = geo
    head[RESERVED + GEO_SIZE:RESERVED + 2 * GEO_SIZE] = geo
    meta = metadata(start // LP_SECTOR, vsize_pad // LP_SECTOR, dev_size)
    base = RESERVED + 2 * GEO_SIZE
    for s in range(SLOTS * 2):  # primaries then backups
        head[base + s * MMS:base + (s + 1) * MMS] = meta
    with open(out, 'wb') as o:
        o.write(head)
        with open(src, 'rb') as f:
            shutil.copyfileobj(f, o, 1 << 20)
        o.write(b'\0' * (vsize_pad - vsize))
    print(dev_size)


if __name__ == '__main__':
    main()
