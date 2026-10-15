#!/usr/bin/env python3
"""misc before/after classifier — reference implementation of MISC-RULE.md (v1).

    misc_rule.py BEFORE.img AFTER.img

Prints one line per finding and a final "VERDICT <class>"; exit status
10 UNCHANGED, 11 EXPECTED, 12 RECORDED, 13 STOP, 14 INCONCLUSIVE, 64 usage.
(Second review S2: no verdict code is 0, 1 or 2, so an uncaught Python
error (exit 1) or an interpreter/argparse failure (exit 2) can never be read
as a verdict; and every exception while reading or classifying is caught and
reported as INCONCLUSIVE.)

Regions (Quest 3 Unit 1, 1 MiB misc; FS-A-005 control data):
  C  0x0000-0x001f  bootloader_message.command (32 bytes)
  V  0x1010-0x101b  vendor field the stock control changed (3 x u32 LE)
  O  every other byte
"""
import hashlib
import struct
import sys

MISC_SIZE = 1048576
C_LO, C_HI = 0x0000, 0x0020          # [lo, hi)
V_LO, V_HI = 0x1010, 0x101C
E0 = bytes(32)
E1 = b"bootonce-bootloader" + bytes(32 - len("bootonce-bootloader"))
NAMES = {E0: "E0(empty)", E1: "E1(bootonce-bootloader)"}
ACCEPTED_C = {(E0, E0), (E1, E1), (E0, E1)}
RANK = {"UNCHANGED": 0, "EXPECTED": 1, "RECORDED": 2, "STOP": 3, "INCONCLUSIVE": 4}
EXIT = {"UNCHANGED": 10, "EXPECTED": 11, "RECORDED": 12, "STOP": 13, "INCONCLUSIVE": 14}


def cname(b):
    return NAMES.get(b, "other:" + b.hex())


def classify(before, after):
    """Returns (verdict, [finding lines])."""
    out = ["before sha256=%s size=%d" % (hashlib.sha256(before).hexdigest(), len(before)),
           "after  sha256=%s size=%d" % (hashlib.sha256(after).hexdigest(), len(after))]
    if len(before) != MISC_SIZE or len(after) != MISC_SIZE:
        out.append("INCONCLUSIVE capture size is not %d bytes: persistent-state accounting impossible" % MISC_SIZE)
        return "INCONCLUSIVE", out
    verdict = "UNCHANGED"

    def raise_to(v):
        nonlocal verdict
        if RANK[v] > RANK[verdict]:
            verdict = v

    diffs = [i for i in range(MISC_SIZE) if before[i] != after[i]]
    other = [i for i in diffs if not (C_LO <= i < C_HI or V_LO <= i < V_HI)]
    if other:
        runs, s, p = [], other[0], other[0]
        for i in other[1:] + [None]:
            if i is not None and i == p + 1:
                p = i
                continue
            runs.append("0x%05x-0x%05x" % (s, p))
            if i is not None:
                s = p = i
        out.append("STOP %d byte(s) changed outside C and V: %s" % (len(other), ", ".join(runs[:8])))
        raise_to("STOP")

    cb, ca = before[C_LO:C_HI], after[C_LO:C_HI]
    if (cb, ca) in ACCEPTED_C:
        if cb != ca:
            out.append("EXPECTED boot command %s -> %s (Android 'reboot bootloader')" % (cname(cb), cname(ca)))
            raise_to("EXPECTED")
        else:
            out.append("ok boot command unchanged %s" % cname(cb))
    else:
        out.append("STOP boot command transition not specifically expected: %s -> %s" % (cname(cb), cname(ca)))
        raise_to("STOP")

    vb, va = before[V_LO:V_HI], after[V_LO:V_HI]
    if vb != va:
        wb, wa = struct.unpack("<3I", vb), struct.unpack("<3I", va)
        sb, sa = struct.unpack("<3i", vb), struct.unpack("<3i", va)
        words = ", ".join("w%d 0x%08x->0x%08x (%d->%d)" % (k, wb[k], wa[k], sb[k], sa[k]) for k in range(3))
        out.append("RECORDED vendor field 0x1010-0x101b changed: %s; presumed reboot-related "
                   "(the stock control changed the same field); location alone does not establish harmlessness" % words)
        raise_to("RECORDED")
    else:
        out.append("ok vendor field 0x1010-0x101b unchanged")
    vab_b, vab_a = before[0x8000:0x8020], after[0x8000:0x8020]
    out.append("info VAB message 0x8000: %s" % ("unchanged" if vab_b == vab_a else "CHANGED (already STOP above)"))
    return verdict, out


def main(argv):
    if len(argv) != 2:
        print("usage: misc_rule.py BEFORE.img AFTER.img")
        return 64
    try:
        with open(argv[0], "rb") as fh:
            before = fh.read()
        with open(argv[1], "rb") as fh:
            after = fh.read()
        verdict, lines = classify(before, after)
    except Exception as e:                      # missing, unreadable, a directory, anything
        print("INCONCLUSIVE cannot read or classify the captures: %s: %s" % (type(e).__name__, e))
        print("VERDICT INCONCLUSIVE")
        return EXIT["INCONCLUSIVE"]
    for l in lines:
        print(l)
    print("VERDICT " + verdict)
    return EXIT[verdict]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
