#!/usr/bin/env python3
"""fs-blkguard VM tests: write a GPT disk image with a given LOGICAL BLOCK SIZE (512 or 4096), for the QEMU devicesim
runs on 4096-byte-block virtio disks (K1g r3, J-207: the Quest 3's UFS LUNs have 4096-byte logical blocks; sgdisk
writes image files in 512-byte sectors only). Our own minimal writer (UEFI GPT layout: protective MBR, primary header
at LBA 1, 128 entries of 128 bytes, backup entries and header at the end); deterministic GUIDs derived from the names.

    mkgpt.py IMAGE LBS SIZE NAME:BYTES [NAME:BYTES ...]

Creates IMAGE (SIZE bytes, zero-filled), the first partition at 1 MiB, each next one right after the previous (every
BYTES a multiple of LBS). Prints one line per partition: "<n> <name> <first byte offset> <bytes>". Offline; writes
IMAGE only.
"""
import hashlib
import struct
import sys
import uuid
import zlib

LINUX_DATA = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


def guid(tag):
    return uuid.UUID(bytes=hashlib.sha256(b"fsbg-mkgpt:" + tag.encode()).digest()[:16], version=4)


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    img, lbs, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if lbs not in (512, 4096) or size % lbs:
        sys.exit("LBS must be 512 or 4096 and SIZE a multiple of it")
    parts = []
    for a in sys.argv[4:]:
        name, b = a.rsplit(":", 1)
        b = int(b)
        if b <= 0 or b % lbs or len(name) > 36:
            sys.exit(f"bad partition {a}")
        parts.append((name, b))
    nlba = size // lbs
    n_ent, ent_sz = 128, 128
    ent_lbas = (n_ent * ent_sz + lbs - 1) // lbs
    first_usable = 2 + ent_lbas
    last_usable = nlba - 2 - ent_lbas
    ents = bytearray(n_ent * ent_sz)
    lba = (1 << 20) // lbs
    out = []
    for i, (name, b) in enumerate(parts):
        first, last = lba, lba + b // lbs - 1
        if first < first_usable or last > last_usable:
            sys.exit(f"partition {name} does not fit")
        e = LINUX_DATA.bytes_le + guid(name + str(i)).bytes_le + struct.pack("<QQQ", first, last, 0)
        e += name.encode("utf-16-le").ljust(72, b"\0")
        ents[i * ent_sz:(i + 1) * ent_sz] = e
        out.append(f"{i + 1} {name} {first * lbs} {b}")
        lba = last + 1
    ecrc = zlib.crc32(bytes(ents)) & 0xffffffff
    disk = guid("disk:" + img.rsplit("/", 1)[-1])

    def header(my, alt, ent_lba):
        h = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x00010000, 92, 0, 0, my, alt, first_usable, last_usable,
                        disk.bytes_le, ent_lba, n_ent, ent_sz, ecrc)
        return h[:16] + struct.pack("<I", zlib.crc32(h) & 0xffffffff) + h[20:]

    mbr = bytearray(512)
    mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, min(nlba - 1, 0xffffffff))
    mbr[510:512] = b"\x55\xaa"
    with open(img, "wb") as f:
        f.truncate(size)
        f.seek(0)
        f.write(mbr)
        f.seek(lbs)
        f.write(header(1, nlba - 1, 2))
        f.seek(2 * lbs)
        f.write(ents)
        f.seek((nlba - 1 - ent_lbas) * lbs)
        f.write(ents)
        f.seek((nlba - 1) * lbs)
        f.write(header(nlba - 1, 1, nlba - 1 - ent_lbas))
    print("\n".join(out))


if __name__ == "__main__":
    main()
