#!/usr/bin/env python3
"""FrameShift stage 3d, read-only: OTA zip metadata + payload.bin manifest new_partition_info (size, sha256) per partition.
usage: payloadcheck.py OTA.zip [PART=FILE ...]"""
import hashlib, struct, sys, zipfile

def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s; s += 7
        if not c & 0x80: return r, i

def fields(b):
    i = 0
    while i < len(b):
        k, i = varint(b, i); fn, wt = k >> 3, k & 7
        if wt == 0: v, i = varint(b, i)
        elif wt == 2: n, i = varint(b, i); v = b[i:i + n]; i += n
        elif wt == 1: v = b[i:i + 8]; i += 8
        elif wt == 5: v = b[i:i + 4]; i += 4
        else: raise ValueError("wire type %d" % wt)
        yield fn, wt, v

z = zipfile.ZipFile(sys.argv[1])
for n in ("META-INF/com/android/metadata", "payload_properties.txt"):
    try:
        print("## %s" % n); print(z.read(n).decode().strip())
    except KeyError:
        print("(absent)")
f = z.open("payload.bin")
h = f.read(24)
assert h[:4] == b"CrAU", h[:4]
ver, msz = struct.unpack(">QQ", h[4:20]); sigsz, = struct.unpack(">I", h[20:24])
man = f.read(msz)
print("## payload.bin version=%d manifest_size=%d metadata_sig_size=%d manifest_sha256=%s" % (ver, msz, sigsz, hashlib.sha256(man).hexdigest()))
parts = {}
for fn, wt, v in fields(man):
    if fn == 13:
        name = None; size = None; hsh = None
        for f2, w2, v2 in fields(v):
            if f2 == 1: name = v2.decode()
            elif f2 == 7:
                for f3, w3, v3 in fields(v2):
                    if f3 == 1: size = v3
                    elif f3 == 2: hsh = v3.hex()
        parts[name] = (size, hsh)
for n in sorted(parts):
    print("part %-14s size=%-11s sha256=%s" % (n, parts[n][0], parts[n][1]))
ok = True
for a in sys.argv[2:]:
    p, fp = a.split("=", 1)
    d = open(fp, "rb").read(); hs = hashlib.sha256(d).hexdigest()
    m = parts.get(p) == (len(d), hs); ok &= m
    print("check %-12s %s size=%d sha256=%s -> %s" % (p, fp, len(d), hs, "MATCH (payload new_partition_info)" if m else "MISMATCH"))
print("ALL %s" % ("MATCH" if ok else "FAIL"))
