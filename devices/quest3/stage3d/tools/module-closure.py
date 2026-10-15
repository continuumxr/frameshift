#!/usr/bin/env python3
"""FrameShift stage 3d: the modules.dep + modules.softdep closure of named root modules (offline, stdlib only).
usage: module-closure.py - ROOT1,ROOT2,... MODULES_DIR...
A symbol/softdep closure only: platform probe dependencies (clocks, regulators, interconnect, SMMU) are not modelled."""
import sys, os
def load(md):
    dep = {}
    for l in open(os.path.join(md, "modules.dep")):
        if ":" not in l: continue
        a, b = l.split(":", 1)
        dep[os.path.basename(a).strip()] = [os.path.basename(x) for x in b.split()]
    soft = {}
    for l in open(os.path.join(md, "modules.softdep")):
        if not l.startswith("softdep "): continue
        w = l.split(); name = w[1]; mode = None; pre = []; post = []
        for t in w[2:]:
            if t in ("pre:", "post:"): mode = t; continue
            (pre if mode == "pre:" else post).append(t)
        soft[name] = (pre, post)
    files = set(f for f in os.listdir(md) if f.endswith(".ko"))
    return dep, soft, files
def norm(n): return n.replace("-", "_")
def find(n, files):
    for c in (n, n.replace("_", "-"), n.replace("-", "_")):
        if c + ".ko" in files: return c + ".ko"
    return None
def closure(roots, dep, soft, files):
    seen = []; missing = set()
    def go(m):
        if m in seen: return
        seen.append(m)
        s = soft.get(norm(m[:-3]), ([], []))
        for p in s[0] + s[1]:
            f = find(p, files)
            if f: go(f)
            else: missing.add(p)
        for d in dep.get(m, []): go(d)
    for r in roots:
        f = find(r, files)
        if f: go(f)
        else: missing.add(r)
    return seen, missing
roots = sys.argv[2].split(",")
for md in sys.argv[3:]:
    dep, soft, files = load(md)
    seen, missing = closure(roots, dep, soft, files)
    print("%s: closure of %d roots = %d modules; absent (softdeps/roots not in ramdisk): %s" % (md, len(roots), len(seen), sorted(missing)))
    print("  " + " ".join(sorted(x[:-3] for x in seen)))
