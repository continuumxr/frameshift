#!/usr/bin/env python3
"""FrameShift K1a — nonce-only rebuild check (offline; the stage-3d fs-nonceonly3d.ps1 method, for boot-k1a.img).

    nonce-only-k1a.py REFERENCE_DIR CANDIDATE_DIR [--reference-sha SHA256]

Proves that a rebuilt K1a candidate differs from the REFERENCE (reviewed) candidate only by the nonce, by opening
both images:
  - both directories are <stamp>-<nonce> with a MANIFEST.txt carrying that nonce; the nonces differ; each image's
    SHA-256 and size equal its MANIFEST's OUTPUT IMAGE line; with --reference-sha the reference image has that hash;
  - THE IMAGES (Android boot image header v4, page 4096): the same size; the header page byte-identical except the
    ramdisk-size field (bytes 12-15); THE KERNEL BYTES IDENTICAL, and equal to the K1a kernel the MANIFESTs name
    (the reviewed kernel's sha256 equals the rebuilt image's kernel: FS-A-013 §2.2 note 1); everything after the
    ramdisk identical; the ramdisk page padding zero in both;
  - THE RAMDISKS (LZ4 legacy, then cpio newc): the same entries in the same order with identical cpio headers
    (mode, uid, gid, nlink, mtime, size, ino, dev), every file identical except /init, whose bytes may differ ONLY
    where the reference's nonce stands in the reference and the candidate's in the candidate (same size, >= 1
    occurrence); the whole decompressed cpio equals the reference's with the nonce replaced, and nothing but zero
    bytes follows the TRAILER!!! entry (the kernel's initramfs unpacker would read a concatenated archive);
  - MANIFEST.txt line-for-line identical except built:, nonce:, OUTPUT IMAGE (same size), ramdisk.cpio and
    ramdisk.lz4 (same cpio size), the checkout HEAD line, and the /init file line (same size and source text).
Prints NONCE-ONLY REBUILD: OK and exits 0, else names the first difference and exits 1 (2: unusable input).
"""
import argparse
import hashlib
import os
import re
import struct
import subprocess
import sys


def fail(msg, code=1):
    print("NONCE-ONLY REBUILD: REFUSED: " + msg)
    sys.exit(code)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load(d):
    d = d.rstrip("/")
    m = re.fullmatch(r"(\d{8}T\d{6}Z)-([0-9a-f]{16})", os.path.basename(d))
    if not m:
        fail("%s is not a <stamp>-<nonce> directory" % d, 2)
    img = open(os.path.join(d, "boot-k1a.img"), "rb").read()
    man = open(os.path.join(d, "MANIFEST.txt")).read().splitlines()
    nl = [l for l in man if l.startswith("nonce:")]
    if not nl or nl[0].split()[1] != m.group(2):
        fail("%s: MANIFEST nonce is not the directory's" % d)
    ol = [l for l in man if l.startswith("OUTPUT IMAGE:")]
    om = re.search(r"size=(\d+)\s+sha256=([0-9a-f]{64})", ol[0]) if ol else None
    if not om or int(om.group(1)) != len(img) or om.group(2) != sha(img):
        fail("%s: image size/sha256 differ from its MANIFEST OUTPUT IMAGE line" % d)
    if any(l.startswith("TEST OVERRIDES") for l in man):
        if not os.environ.get("FS_TEST_ALLOW_OVERRIDES"):
            fail("%s was built with test overrides" % d)
        man = [l for l in man if not l.startswith("TEST OVERRIDES")]     # fixtures only (test-builder.sh)
    return {"dir": d, "nonce": m.group(2), "img": img, "man": man}


def parse(img, label):
    if img[:8] != b"ANDROID!":
        fail(label + ": not an Android boot image", 2)
    ksz, rsz = struct.unpack_from("<II", img, 8)
    hv = struct.unpack_from("<I", img, 40)[0]
    if hv not in (3, 4):
        fail(label + ": header version %d (v3/v4 expected)" % hv, 2)
    pg = 4096
    up = lambda n: (n + pg - 1) // pg * pg
    k0 = pg
    r0 = k0 + up(ksz)
    return {"ksz": ksz, "rsz": rsz, "kernel": img[k0:k0 + ksz], "kpad": img[k0 + ksz:r0], "ramdisk": img[r0:r0 + rsz],
            "rpad": img[r0 + rsz:r0 + up(rsz)], "after": img[r0 + up(rsz):], "hdr": img[:pg]}


def cpio(lz, label):
    p = subprocess.run(["lz4", "-dc"], input=lz, capture_output=True)
    if p.returncode:
        fail(label + ": lz4 -d failed", 2)
    b, i, out = p.stdout, 0, []
    while True:
        if b[i:i + 6] != b"070701":
            fail(label + ": not cpio newc at %d" % i, 2)
        f = [int(b[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        namesize, filesize = f[11], f[6]
        n0 = i + 110
        name = b[n0:n0 + namesize - 1].decode()
        d0 = (n0 + namesize + 3) & ~3
        data = b[d0:d0 + filesize]
        i = (d0 + filesize + 3) & ~3
        if name == "TRAILER!!!":
            break
        out.append((name, f, data, d0))
    if b[i:].strip(bytes(1)):        # review MAJOR-4: the kernel's unpacker reads on after TRAILER!!!; nothing may follow
        fail(label + ": nonzero bytes after the cpio trailer", 1)
    return p.stdout, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("candidate")
    ap.add_argument("--reference-sha")
    a = ap.parse_args()
    R, C = load(a.reference), load(a.candidate)
    if a.reference_sha and sha(R["img"]) != a.reference_sha:
        fail("reference image is not %s" % a.reference_sha)
    if R["nonce"] == C["nonce"]:
        fail("the nonces are equal (%s): a nonce is single-use" % R["nonce"])
    if len(R["img"]) != len(C["img"]):
        fail("image sizes differ (%d vs %d): rebuild with another nonce" % (len(R["img"]), len(C["img"])))
    r, c = parse(R["img"], "reference"), parse(C["img"], "candidate")
    hr, hc = bytearray(r["hdr"]), bytearray(c["hdr"])
    hr[12:16] = hc[12:16] = b"\0\0\0\0"
    if hr != hc:
        fail("header pages differ beyond the ramdisk-size field")
    if r["kernel"] != c["kernel"]:
        fail("KERNEL BYTES DIFFER")
    ks = sha(r["kernel"])
    for X in (R, C):
        kl = [l for l in X["man"] if l.startswith("K1a kernel")]
        if not kl or kl[0].split()[2] != ks:
            fail("%s: MANIFEST 'K1a kernel' line is not the kernel inside the image (%s)" % (X["dir"], ks))
    if r["kpad"].strip(b"\0") or c["kpad"].strip(b"\0") or r["rpad"].strip(b"\0") or c["rpad"].strip(b"\0"):
        fail("nonzero page padding")
    if r["after"] != c["after"]:
        fail("bytes after the ramdisk differ")
    rc_raw, rcp = cpio(r["ramdisk"], "reference")
    cc_raw, ccp = cpio(c["ramdisk"], "candidate")
    if len(rc_raw) != len(cc_raw):
        fail("cpio sizes differ")
    # the whole decompressed archive: the reference's with the nonce replaced INSIDE /init's data only (other files,
    # e.g. busybox's hex-digit table, may contain a nonce-like string by chance)
    exp = bytearray(rc_raw)
    for n, _f, d, off in rcp:
        if n == "init":
            exp[off:off + len(d)] = d.replace(R["nonce"].encode(), C["nonce"].encode())
    if bytes(exp) != cc_raw:
        fail("the cpio archives differ beyond the nonce in /init")
    if [x[0] for x in rcp] != [x[0] for x in ccp]:
        fail("cpio entry lists differ")
    for (n, fr, dr, _o), (_n, fc, dc, _o2) in zip(rcp, ccp):
        if fr != fc:
            fail("cpio header of %s differs" % n)
        if dr == dc:
            if n == "init":
                fail("/init is identical (the nonce did not change in it)")
            continue
        if n != "init" or len(dr) != len(dc):
            fail("file %s differs" % n)
        rn, cn = R["nonce"].encode(), C["nonce"].encode()
        if rn not in dr or dr.replace(rn, cn) != dc:
            fail("/init differs beyond the nonce")
    keys = ("built:", "nonce:", "OUTPUT IMAGE:", "ramdisk.cpio", "ramdisk.lz4", "checkout HEAD")
    if len(R["man"]) != len(C["man"]):
        fail("MANIFESTs differ in length")
    for lr, lc in zip(R["man"], C["man"]):
        if lr == lc:
            continue
        if lr.startswith(keys) and lc.startswith(keys) and lr.split()[0] == lc.split()[0]:
            if lr.startswith("OUTPUT IMAGE:") and re.search(r"size=\d+", lr).group() != re.search(r"size=\d+", lc).group():
                fail("MANIFEST image sizes differ")
            if lr.startswith("ramdisk.cpio") and lr.split("size=")[1] != lc.split("size=")[1]:
                fail("MANIFEST cpio sizes differ")
            continue
        fr_, fc_ = lr.split(), lc.split()
        if len(fr_) >= 4 and fr_[2] == "/init" and fc_[2] == "/init" and fr_[1] == fc_[1] and fr_[3:] == fc_[3:]:
            continue
        fail("MANIFEST line differs: %r vs %r" % (lr[:100], lc[:100]))
    print("reference %s (nonce %s) image %s" % (R["dir"], R["nonce"], sha(R["img"])))
    print("candidate %s (nonce %s) image %s" % (C["dir"], C["nonce"], sha(C["img"])))
    print("kernel bytes identical: %s (%d bytes); ramdisk: %d entries, only /init differs, only at the nonce" % (ks, len(r["kernel"]), len(rcp)))
    print("NONCE-ONLY REBUILD: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
