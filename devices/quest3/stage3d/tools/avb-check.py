#!/usr/bin/env python3
"""FrameShift stage 3d: offline AVB provenance check of the stock v2.7 inputs (stdlib only, read-only).

usage: avb-check.py --vbmeta VBMETA.img --chain NAME=FILE [...] --hash NAME=FILE [...] --expect-digest HEX64

Parses the top-level vbmeta image and every chained vbmeta image given with --chain (the AVB
vbmeta image header and descriptors, libavb layout), and computes the vbmeta digest exactly as
libavb reports it in androidboot.vbmeta.digest (= the device's ro.boot.vbmeta.digest): SHA-256
over the vbmeta structs (header + authentication block + auxiliary block) of the top-level image
followed by each chained partition's, in the order of the chain-partition descriptors. Every
chained image's public key must equal the key in its chain descriptor. Every --hash image must
match its hash descriptor (digest = hash_alg(salt || image[0:image_size])).

Prints one line per item and a final "AVB-CHECK PASS|FAIL ..." line; exit 0 only on PASS:
the computed digest equals --expect-digest, every chain key matches, every --hash image matches,
and every chain descriptor of the top-level image has a --chain image (else the digest cannot be
computed). No device is touched.
"""
import hashlib
import struct
import sys


def header(d, off=0):
    h = d[off:off + 256]
    if h[:4] != b"AVB0":
        raise ValueError("no AVB0 magic at offset %d" % off)
    f = {}
    f["auth"], f["aux"] = struct.unpack(">QQ", h[12:28])
    (f["hash_off"], f["hash_sz"], f["sig_off"], f["sig_sz"], f["pk_off"], f["pk_sz"], f["pkm_off"], f["pkm_sz"],
     f["desc_off"], f["desc_sz"], f["rollback"]) = struct.unpack(">11Q", h[32:120])
    f["flags"], f["rb_loc"] = struct.unpack(">II", h[120:128])
    f["release"] = h[128:176].rstrip(b"\0").decode(errors="replace")
    f["size"] = 256 + f["auth"] + f["aux"]
    return f


def pubkey(d, off, f):
    a = off + 256 + f["auth"] + f["pk_off"]
    return d[a:a + f["pk_sz"]]


def descriptors(d, off, f):
    p = off + 256 + f["auth"] + f["desc_off"]
    end = p + f["desc_sz"]
    while p < end:
        tag, n = struct.unpack(">QQ", d[p:p + 16])
        b = d[p + 16:p + 16 + n]
        if tag == 2:      # hash descriptor
            isz, = struct.unpack(">Q", b[0:8])
            alg = b[8:40].rstrip(b"\0").decode()
            nl, sl, dl, _ = struct.unpack(">IIII", b[40:56])
            q = 56 + 60
            yield ("hash", b[q:q + nl].decode(), dict(image_size=isz, alg=alg, salt=b[q + nl:q + nl + sl],
                                                       digest=b[q + nl + sl:q + nl + sl + dl]))
        elif tag == 4:    # chain partition descriptor
            loc, nl, kl, _ = struct.unpack(">IIII", b[0:16])
            q = 16 + 60
            yield ("chain", b[q:q + nl].decode(), dict(rb_loc=loc, key=b[q + nl:q + nl + kl]))
        p += 16 + n


def footer(d):
    t = d[-64:]
    if t[:4] != b"AVBf":
        return None
    _, _, orig, voff, vsz = struct.unpack(">IIQQQ", t[4:36])
    return dict(orig=orig, voff=voff, vsz=vsz)


def main(argv):
    vb, chains, hashes, expect = None, {}, {}, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--vbmeta":
            vb = argv[i + 1]
        elif a == "--chain":
            k, v = argv[i + 1].split("=", 1); chains[k] = v
        elif a == "--hash":
            k, v = argv[i + 1].split("=", 1); hashes[k] = v
        elif a == "--expect-digest":
            expect = argv[i + 1]
        else:
            raise SystemExit(__doc__)
        i += 2
    if not vb or not expect:
        raise SystemExit(__doc__)
    ok = True
    d = open(vb, "rb").read()
    f = header(d)
    print("vbmeta        %s sha256=%s rollback=%d rb_loc=%d flags=%d release=%r vbmeta_size=%d" % (
        vb, hashlib.sha256(d).hexdigest(), f["rollback"], f["rb_loc"], f["flags"], f["release"], f["size"]))
    structs = [d[:f["size"]]]
    seen_hash = set()
    for kind, name, v in descriptors(d, 0, f):
        if kind == "chain":
            if name not in chains:
                print("chain         %s: NO IMAGE GIVEN (the digest cannot be computed)" % name)
                ok = False
                continue
            cd = open(chains[name], "rb").read()
            fo = footer(cd)
            off = fo["voff"] if fo else 0
            cf = header(cd, off)
            km = pubkey(cd, off, cf) == v["key"]
            ok &= km
            structs.append(cd[off:off + cf["size"]])
            print("chain         %s %s sha256=%s rb_loc=%d rollback=%d vbmeta_size=%d key %s" % (
                name, chains[name], hashlib.sha256(cd).hexdigest(), v["rb_loc"], cf["rollback"], cf["size"],
                "MATCH" if km else "MISMATCH"))
        elif kind == "hash" and name in hashes:
            im = open(hashes[name], "rb").read()
            got = hashlib.new(v["alg"], v["salt"] + im[:v["image_size"]]).digest()
            m = got == v["digest"]
            ok &= m
            seen_hash.add(name)
            print("hash          %s %s sha256=%s image_size=%d descriptor=%s %s" % (
                name, hashes[name], hashlib.sha256(im).hexdigest(), v["image_size"], v["digest"].hex(),
                "MATCH" if m else "MISMATCH"))
    for name in sorted(set(hashes) - seen_hash):
        print("hash          %s: no hash descriptor in the top-level vbmeta" % name)
        ok = False
    dig = hashlib.sha256(b"".join(structs)).hexdigest()
    dm = dig == expect
    ok &= dm
    print("vbmeta_digest %s (%d structs, %d bytes) expected %s %s" % (dig, len(structs), sum(map(len, structs)), expect,
                                                                       "MATCH" if dm else "MISMATCH"))
    print("AVB-CHECK %s digest=%s" % ("PASS" if ok else "FAIL", dig))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
