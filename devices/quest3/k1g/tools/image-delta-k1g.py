#!/usr/bin/env python3
"""FrameShift K1g r2 — the image delta against the FS-A-014 candidate (offline; FS-R-014 s.3: "The guard kernel need
not be rebuilt merely because userspace probe scope changes, if its bytes remain unchanged and the new package
demonstrates that fact").

    image-delta-k1g.py OLD_CANDIDATE_DIR NEW_CANDIDATE_DIR [--old-sha SHA256] [--new-probe-sha SHA256]

Opens both boot images with the nonce-only checker's parsers (tools/nonce-only-k1g.py, loaded, not copied) and
proves that the new candidate is a nonce-only-style rebuild in which ONLY the probe changed:
  - THE KERNEL BYTES IDENTICAL (and their SHA-256 printed): the guard kernel is unchanged;
  - the header page identical except the ramdisk-size field (bytes 12-15); everything after the ramdisk identical;
  - THE RAMDISKS: the same entries in the same order; every file byte-identical except /bin/fsbg-probe (the revised
    probe; with --new-probe-sha its SHA-256 must equal the pin) and /init (only where the nonces stand, same size);
    the cpio headers identical except the size field of /bin/fsbg-probe;
  - MANIFEST.txt: the lines that differ are listed.
Prints PROBE-ONLY DELTA: OK and exits 0, else names the first difference and exits 1.
"""
import argparse
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("nonce_only_k1g", os.path.join(HERE, "nonce-only-k1g.py"))
no = importlib.util.module_from_spec(spec)
spec.loader.exec_module(no)


def bad(msg):
    print("PROBE-ONLY DELTA: REFUSED: " + msg)
    sys.exit(1)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--old-sha")
    ap.add_argument("--new-probe-sha")
    a = ap.parse_args()
    o, n = no.load(a.old), no.load(a.new)
    if a.old_sha and sha(o["img"]) != a.old_sha:
        bad("the old candidate's image is not %s" % a.old_sha)
    po, pn = no.parse(o["img"], "old"), no.parse(n["img"], "new")
    if po["kernel"] != pn["kernel"]:
        bad("THE KERNEL BYTES DIFFER")
    print("kernel: identical, %d bytes, sha256 %s" % (len(pn["kernel"]), sha(pn["kernel"])))
    ho, hn = bytearray(po["hdr"]), bytearray(pn["hdr"])
    ho[12:16] = hn[12:16] = b"\0\0\0\0"
    if ho != hn:
        bad("the header pages differ beyond the ramdisk-size field")
    if po["after"] != pn["after"] or po["kpad"] != pn["kpad"]:
        bad("the bytes around the kernel or after the ramdisk differ")
    print("header: identical except the ramdisk size (%d -> %d bytes, compressed)" % (po["rsz"], pn["rsz"]))
    _, eo = no.cpio(po["ramdisk"], "old")
    _, en = no.cpio(pn["ramdisk"], "new")
    if [e[0] for e in eo] != [e[0] for e in en]:
        bad("the ramdisk entries differ (names or order)")
    changed = []
    for (name, fo, do, _), (_, fn, dn, _) in zip(eo, en):
        if do == dn and fo == fn:
            continue
        if name == "bin/fsbg-probe":
            fo2, fn2 = list(fo), list(fn)
            fo2[6] = fn2[6] = 0                     # the size field may differ
            if fo2 != fn2:
                bad("the cpio header of bin/fsbg-probe differs beyond its size")
            if a.new_probe_sha and sha(dn) != a.new_probe_sha:
                bad("the new bin/fsbg-probe is not the pinned probe %s" % a.new_probe_sha)
            changed.append("bin/fsbg-probe: %s (%d bytes) -> %s (%d bytes)" % (sha(do)[:16], len(do), sha(dn)[:16], len(dn)))
            continue
        if name == "init":
            if fo != fn or len(do) != len(dn):
                bad("/init differs in its header or size")
            if do.replace(o["nonce"].encode(), n["nonce"].encode()) != dn or o["nonce"].encode() not in do:
                bad("/init differs beyond the nonce")
            changed.append("init: the nonce only (%s -> %s)" % (o["nonce"], n["nonce"]))
            continue
        bad("ramdisk file %s differs" % name)
    for c in changed:
        print("ramdisk: " + c)
    print("ramdisk: every other file (%d of %d) byte-identical with identical cpio headers" % (len(en) - len(changed), len(en)))
    mo, mn = o["man"], n["man"]
    diff = [(x, y) for x, y in zip(mo, mn) if x != y]
    print("MANIFEST: %d of %d lines differ:" % (len(diff) + abs(len(mo) - len(mn)), max(len(mo), len(mn))))
    for x, y in diff:
        print("  - " + x[:150])
        print("  + " + y[:150])
    print("PROBE-ONLY DELTA: OK: %s differs from %s only by the probe (and the nonce); kernel sha256 %s" %
          (os.path.basename(a.new.rstrip("/")), os.path.basename(a.old.rstrip("/")), sha(pn["kernel"])))


if __name__ == "__main__":
    main()
