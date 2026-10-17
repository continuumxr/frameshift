#!/usr/bin/env python3
"""FrameShift K1a — module-load simulation of the K1a image's 95-module set against a kernel build (offline).

    modload-sim-k1a.py --vendor-ramdisk DIR --modlist LIST --symvers Module.symvers --kernel Image
                       [--expect-loaded N] [--perturb SYM] [--label TEXT]

Replays init.sh's loader (k1a/init.sh = stage3d's: for each entry of /lib/fs/modules.load, softdep pre:, the
modules.dep closure in reverse, the module, softdep post:, each module once; the file name resolved with the
same _/- variants) over Meta's STOCK v2.7 module files (the vendor ramdisk of the pinned vendor_boot, unpacked
by the caller), and for every module applies the checks the 5.10 module loader makes against the RUNNING kernel
[C: kernel/module.c check_modinfo, check_version, resolve_symbol, verify_exported_symbols; read, not run]:
  - vermagic: with CONFIG_MODVERSIONS the release token is skipped (same_magic with has_crcs); the remaining
    tokens must equal the kernel's (from the Image: the "<release> SMP preempt mod_unload modversions aarch64"
    string). The release is reported only;
  - module_layout: the module's __versions CRC must equal the kernel's (check_modstruct_version);
  - every undefined symbol must be exported by vmlinux (Module.symvers vmlinux rows) or by a module loaded
    EARLIER in the replay (else "Unknown symbol": the load fails); weak undefined symbols may stay unresolved;
  - a symbol resolved from vmlinux that is listed in the module's __versions must carry the same CRC
    ("disagrees about version of symbol": the load fails); one not listed is accepted with a warning
    ("no symbol version", as the 5.10 loader does) and counted;
  - a GPL-only vmlinux export used by a module whose licence is not GPL-compatible fails; a namespaced vmlinux
    export needs the namespace in the module's import_ns;
  - a module exporting a symbol vmlinux or an earlier module already exports fails (duplicate symbol).
Inter-module CRCs are not re-checked: every module is Meta's unchanged stock file (they match each other as
shipped); only the kernel side changed.
--perturb SYM flips the CRC of SYM in the kernel view: the negative control (the simulation must then fail the
modules that import SYM).
Exit 0: every module of the replay passes (and, with --expect-loaded, exactly N modules); 1: a failure; 2: error.
Read-only; no device; nothing is loaded anywhere (the .ko files are parsed as data).
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "tools", "kgate"))
import kgate  # noqa: E402  (tools/kgate/kgate.py: parse_ko, parse_symvers, GPL_ONLY, GPL_COMPATIBLE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vendor-ramdisk", required=True, help="unpacked stock vendor ramdisk (has lib/modules)")
    ap.add_argument("--modlist", required=True)
    ap.add_argument("--symvers", required=True)
    ap.add_argument("--kernel", required=True, help="uncompressed arm64 Image of the same build")
    ap.add_argument("--expect-loaded", type=int)
    ap.add_argument("--perturb", action="append", default=[])
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    md = os.path.join(a.vendor_ramdisk, "lib", "modules")
    try:
        rows = kgate.parse_symvers(a.symvers, "Module.symvers")
    except kgate.GateError as e:
        print("ERROR " + str(e)); return 2
    vml = {r["sym"]: dict(r) for r in rows if r["module"] == "vmlinux"}
    for s in a.perturb:
        if s not in vml:
            print("ERROR --perturb %s: not a vmlinux export" % s); return 2
        vml[s]["crc"] ^= 0x1
    kimg = open(a.kernel, "rb").read()
    m = re.search(rb"Linux version (\d+\.\d+\.\S+) ", kimg)
    if not m:
        print("ERROR no banner in the Image"); return 2
    rel = m.group(1).decode()
    vm = re.search(re.escape(m.group(1)) + rb" ((?:[A-Za-z0-9_]+ )*[A-Za-z0-9_]+)\0", kimg)
    if not vm:
        print("ERROR no vermagic string in the Image"); return 2
    kflags = vm.group(1).decode().split()
    krest = vm.group(1).decode()
    dep, soft = {}, {}
    for l in open(os.path.join(md, "modules.dep")).read().splitlines():
        if ":" in l:
            k, v = l.split(":", 1)
            dep[k.strip()] = v.split()
    for l in open(os.path.join(md, "modules.softdep")).read().splitlines():
        f = l.split()
        if len(f) >= 2 and f[0] == "softdep":
            soft[f[1]] = f[2:]

    def modfile(n):
        n = os.path.basename(n)
        n = n[:-3] if n.endswith(".ko") else n
        for c in (n, n.replace("_", "-"), n.replace("-", "_")):
            p = os.path.join(md, c + ".ko")
            if os.path.isfile(p):
                return "/lib/modules/" + c + ".ko"
        return None

    def softdeps(kind, path):
        name = os.path.basename(path)[:-3].replace("-", "_")
        f = soft.get(name)
        if not f:
            return []
        txt = " ".join(f)
        if kind == "pre":
            part = txt.split("pre:", 1)[1] if "pre:" in txt else txt
            part = part.split("post:", 1)[0]
        else:
            part = txt.split("post:", 1)[1] if "post:" in txt else ""
        return [x for x in (modfile(s) for s in part.split()) if x]

    order, seen = [], set()

    def load(path):
        if path in seen:
            return
        seen.add(path)
        for d in softdeps("pre", path):
            load(d)
        for d in reversed(dep.get(path, [])):
            load(d)
        order.append(path)
        for d in softdeps("post", path):
            load(d)

    entries = [l.strip() for l in open(a.modlist) if l.strip()]
    for e in entries:                      # init.sh: load_mod "$MD/$m" (the list entry as written)
        p = "/lib/modules/" + e
        if not os.path.isfile(os.path.join(md, e)):
            order.append("MISSING:" + e)
            continue
        load(p)

    exported = {s: "vmlinux" for s in vml}
    fails, nover, results = [], 0, []
    layout = vml.get("module_layout", {}).get("crc")
    for path in order:
        if path.startswith("MISSING:"):
            fails.append("%s: no such module file in the vendor ramdisk" % path[8:]); continue
        name = os.path.basename(path)
        try:
            k = kgate.parse_ko(open(os.path.join(a.vendor_ramdisk, path.lstrip("/")), "rb").read(), name)
        except kgate.GateError as e:
            fails.append("%s: %s" % (name, e)); continue
        prob = []
        # same_magic() with CRCs: strcmp of everything after the first space (review MINOR-8: raw string, not tokens)
        mrest = k["vermagic"].split(" ", 1)[1] if " " in k["vermagic"] else ""
        if mrest != krest:
            prob.append("vermagic %r != kernel %r (after the release)" % (mrest, krest))
        if k["versions"].get("module_layout") != layout:
            prob.append("module_layout 0x%08x != kernel 0x%08x" % (k["versions"].get("module_layout", 0), layout or 0))
        for s in k["undefined"]:
            src = exported.get(s)
            if src is None:
                prob.append("Unknown symbol %s" % s); continue
            if src == "vmlinux":
                r = vml[s]
                if s in k["versions"]:
                    if k["versions"][s] != r["crc"]:
                        prob.append("disagrees about version of symbol %s (module 0x%08x, kernel 0x%08x)" % (s, k["versions"][s], r["crc"]))
                else:
                    nover += 1
                if r["type"] in kgate.GPL_ONLY and k["license"] not in kgate.GPL_COMPATIBLE:
                    prob.append("GPL-only symbol %s, licence %r" % (s, k["license"]))
                if r["ns"] and r["ns"] not in k["import_ns"]:
                    prob.append("symbol %s in namespace %s not imported" % (s, r["ns"]))
        for s in k["exports"]:
            if s in exported:
                prob.append("exports duplicate symbol %s (owned by %s)" % (s, exported[s]))
        if prob:
            fails.append("%s: %s" % (name, "; ".join(prob[:6]) + (" (+%d more)" % (len(prob) - 6) if len(prob) > 6 else "")))
            results.append((name, "FAIL"))
            continue
        for s in k["exports"]:
            exported[s] = name
        results.append((name, "ok"))
    ok = sum(1 for _, r in results if r == "ok")
    print("# K1a module-load simulation %s" % a.label)
    print("kernel: release %s, vermagic flags '%s', module_layout 0x%08x, %d vmlinux exports%s"
          % (rel, " ".join(kflags), layout or 0, len(vml), (" (PERTURBED: %s)" % ",".join(a.perturb)) if a.perturb else ""))
    print("list: %d entries -> replay order %d modules (each once)" % (len(entries), len(order)))
    for name, r in results:
        print("%-4s %s" % (r, name))
    print("unversioned vmlinux imports accepted with a warning (no symbol version): %d" % nover)
    for f in fails:
        print("FAIL " + f)
    good = not fails and (a.expect_loaded is None or ok == a.expect_loaded)
    print("RESULT %s: %d/%d modules pass the loader checks%s" % ("PASS" if good else "FAIL", ok, len(order),
          "" if a.expect_loaded is None else " (expected %d)" % a.expect_loaded))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
