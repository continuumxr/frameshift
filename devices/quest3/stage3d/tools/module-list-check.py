#!/usr/bin/env python3
"""FrameShift stage 3d: check the pinned module list (stage3d/modules.load.v66) against a vendor ramdisk's
lib/modules (offline, stdlib only; the builder runs it on the unpacked v2.7 vendor ramdisk).

usage: module-list-check.py LIST VENDOR_MODULES_DIR ROOTS

PM decision J-129: stage 3d loads the proven v66 set only (the stage-3c v66 modules.load.recovery minus
debug-regulator and qti-regmap-debugfs), resolved against the v2.7 module files. Checks, exit 0 only if all hold:
  1. every list entry is a plain "<name>.ko" present as a regular file in VENDOR_MODULES_DIR, no duplicates;
  2. the list is CLOSED under init.sh's loader: for every entry, every modules.dep dependency and every
     softdep pre/post target that exists in the directory (resolved as init.sh's modfile: name, '_'->'-',
     '-'->'_') is itself in the list, so init.sh never loads a module outside it;
  3. the closure of ROOTS (comma-separated; the display / USB / backlight / LED / fan modules) is in the list;
  4. the vendor's own modules.load.recovery entries NOT in the list are reported (they must never load) and
     none of them is reachable from the list. (Check 4 is relative to the list itself: a module ADDED to the
     list stops being "excluded", so check 4 alone cannot catch an addition.)
  5. independent of the list: no entry, and nothing reachable from the list, is in FORBIDDEN, the fixed set
     of the 36 v2.7-only modules plus the two v66 debug modules removed by J-129 (names compared with
     '-' and '_' treated as equal). Adding any of them later fails here, even if the list is re-pinned.
"""

# J-129 / review C MINOR-1: the modules stage 3d must never load, fixed here (not derived from the list).
FORBIDDEN = """
ak09973 as5510 charging_dock external_battery industrialio-triggered-buffer kfifo_buf usbvdm usbvdm-cypd
usbvdm-glink adsp_loader_dlkm bcl_pmic5 bcl_soc frpc-adsprpc gpr_dlkm mdt_loader q6_dlkm q6_notifier_dlkm
q6_pdr_dlkm qcom_lpm qcom_pil_info qcom_q6v5 qcom_q6v5_pas qcom_ramdump qcom-spmi-adc5-gen3
qcom-spmi-temp-alarm qcom_sysmon qcom_tsens qcom-vadc-common qti_battery_charger_main qti-ocp-notifier
qti_qmi_sensor_v2 smp2p smp2p_sleepstate snd_event_dlkm spf_core_dlkm userspace-consumer
debug-regulator qti-regmap-debugfs
""".split()


def norm(name):
    return (name[:-3] if name.endswith(".ko") else name).replace("-", "_")
import os
import sys


def load(md):
    dep = {}
    for line in open(os.path.join(md, "modules.dep")):
        if ":" not in line:
            continue
        a, b = line.split(":", 1)
        dep[os.path.basename(a.strip())] = [os.path.basename(x) for x in b.split()]
    soft = {}
    for line in open(os.path.join(md, "modules.softdep")):
        w = line.split()
        if len(w) < 2 or w[0] != "softdep":
            continue
        mode, items = None, []
        for tok in w[2:]:
            if tok in ("pre:", "post:"):
                mode = tok
                continue
            items.append(tok)
        soft[w[1]] = items
    return dep, soft


def modfile(name, files):
    """init.sh modfile: <n>.ko, then '_'->'-', then '-'->'_'"""
    n = name[:-3] if name.endswith(".ko") else name
    for c in (n, n.replace("_", "-"), n.replace("-", "_")):
        if c + ".ko" in files:
            return c + ".ko"
    return None


def edges(m, dep, soft, files):
    out = list(dep.get(m, []))
    key = m[:-3].replace("-", "_")                 # init.sh: basename .ko | tr '-' '_'
    for s in soft.get(key, []):
        f = modfile(s, files)
        if f:
            out.append(f)
    return out


def main():
    lst, md, roots = sys.argv[1], sys.argv[2], [r for r in sys.argv[3].split(",") if r]
    files = {f for f in os.listdir(md) if f.endswith(".ko") and os.path.isfile(os.path.join(md, f))}
    entries = [l.rstrip("\n") for l in open(lst)]
    dep, soft = load(md)
    ok = True

    def res(name, good, detail=""):
        nonlocal ok
        print("CHECK %s %s %s" % (name, "PASS" if good else "FAIL", detail))
        ok &= good
    bad = [e for e in entries if not e.endswith(".ko") or "/" in e or e not in files]
    res("entries_present_as_files", not bad and len(set(entries)) == len(entries), "%d entries; bad %s" % (len(entries), bad))
    eset = set(entries)
    open_edges = sorted({(m, d) for m in entries for d in edges(m, dep, soft, files) if d not in eset})
    res("list_closed_under_modules_dep_and_softdeps", not open_edges, str(open_edges[:10]))
    seen, stack, absent = set(), [], set()
    for r in roots:
        f = modfile(r, files)
        if f:
            stack.append(f)
        else:
            absent.add(r)
    while stack:
        m = stack.pop()
        if m in seen:
            continue
        seen.add(m)
        stack.extend(edges(m, dep, soft, files))
    res("roots_closure_inside_the_list (%d roots -> %d modules)" % (len(roots), len(seen)), seen <= eset and not absent,
        "outside %s; roots absent %s" % (sorted(seen - eset), sorted(absent)))
    vend = [l.strip() for l in open(os.path.join(md, "modules.load.recovery")) if l.strip()]
    excluded = [v for v in vend if v not in eset]
    print("INFO vendor modules.load.recovery %d entries; list %d; never loaded (%d): %s" % (len(vend), len(entries), len(excluded), " ".join(excluded)))
    reach = set()
    stack = list(entries)
    while stack:
        m = stack.pop()
        if m in reach:
            continue
        reach.add(m)
        stack.extend(edges(m, dep, soft, files))
    res("no_excluded_vendor_module_reachable_from_the_list", not (reach & set(excluded)), str(sorted(reach & set(excluded))))
    forb = {norm(f) for f in FORBIDDEN}
    hit = sorted({m for m in reach if norm(m) in forb})
    res("no_forbidden_module_in_or_reachable_from_the_list (%d forbidden)" % len(forb), not hit, str(hit))
    print("MODULE-LIST-CHECK %s" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


main()
