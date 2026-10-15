"""Read-only inventory and sanity check of Quest partition dumps (the PM's read-only archive).

usage: python -I -B dumpcheck.py <dumps-root> <reference-partitions.txt> <out.tsv>

For every *.img under <dumps-root> (any depth): size, SHA-256, a content
classification from magic bytes (ELF, Android boot/vendor_boot header,
AVB vbmeta, LP super metadata, ext4, erofs, f2fs, GPT, DTBO table,
all-zero, all-0xFF, other), and the expected partition size from a
reference by-name size list (name without _a/_b suffix matched against
the reference). Nothing under <dumps-root> is written. Writes <out.tsv>
plus a summary on stdout.
"""
import hashlib, os, re, struct, sys

def classify(f, size):
    f.seek(0); h = f.read(4096)
    if not h: return "empty"
    if h[:4] == b"\x7fELF": return "elf"
    if h[:8] == b"ANDROID!": return "android-boot"
    if h[:8] == b"VNDRBOOT": return "vendor-boot"
    if h[:4] == b"AVB0": return "vbmeta"
    if h[:4] == bytes.fromhex("d7b7ab1e"): return "dtbo-table"
    if len(h) >= 0x438 + 2 and h[0x438:0x43a] == b"\x53\xef": return "ext4"
    if len(h) >= 0x404 and h[0x400:0x404] == bytes.fromhex("e2e1f5e0"): return "erofs"
    if len(h) >= 0x404 and h[0x400:0x404] == bytes.fromhex("1020f5f2"): return "f2fs"
    if h[512:520] == b"EFI PART": return "gpt"
    f.seek(0x1000); lp = f.read(4)
    if lp == b"gDla": return "lp-super"
    # sample for zero / 0xFF fill
    f.seek(0); first = f.read(1 << 20)
    if first and first.count(0) == len(first):
        f.seek(max(0, size - (1 << 20))); last = f.read(1 << 20)
        if last.count(0) == len(last): return "zero-filled(sampled)"
    if first and first.count(0xFF) == len(first): return "ff-filled(sampled)"
    return "other"

def main():
    root, ref, out = sys.argv[1:4]
    refsz = {}
    for line in open(ref, encoding="utf-8"):
        p = line.split()
        if len(p) == 2 and p[1].isdigit():
            refsz[p[0]] = int(p[1])
    rows = []; n = bad = 0
    for d, _, fs in os.walk(root):
        for fn in sorted(fs):
            if not fn.lower().endswith(".img"): continue
            path = os.path.join(d, fn); size = os.path.getsize(path)
            h = hashlib.sha256()
            with open(path, "rb") as f:
                kind = classify(f, size); f.seek(0)
                for chunk in iter(lambda: f.read(8 << 20), b""): h.update(chunk)
            base = fn[:-4]
            name = re.sub(r"_(a|b)$", "", base)
            exp = refsz.get(base, refsz.get(name + "_a", refsz.get(name)))
            st = "size-ok" if exp == size else ("no-ref" if exp is None else f"SIZE-DIFF(exp {exp})")
            if st.startswith("SIZE") or kind == "empty": bad += 1
            n += 1
            rows.append((os.path.relpath(path, root).replace("\\", "/"), size, h.hexdigest(), kind, st))
            print(f"{st:24} {kind:22} {size:>12} {os.path.relpath(path, root)}", flush=True)
    with open(out, "w", encoding="utf-8", newline="\n") as o:
        o.write("# path\tsize\tsha256\tkind\tsize_check\n")
        for r in rows: o.write("\t".join(map(str, r)) + "\n")
    print(f"SUMMARY files={n} flagged={bad}")

if __name__ == "__main__":
    main()
