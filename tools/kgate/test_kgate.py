#!/usr/bin/env python3
"""Fixture tests for tools/kgate (FS-R-006 section 3 and the two adversarial reviews).

    python3 -I tools/kgate/test_kgate.py [--results FILE] [--tool-dir DIR]

Uses the committed synthetic fixtures in tools/kgate/fixtures/data/ (regenerated
into a temp dir and compared, to show they come from make_fixtures.py).  Builds
small ext4 images with `mke2fs -d` (needs e2fsprogs) and runs each case,
asserting the exit code AND the reason: a named check with the expected status
whose message/items contain an expected substring (or, for the kind scanner,
a substring of its output).  Shims on PATH simulate debugfs stderr output, a
truncated debugfs dump, and a disagreeing modprobe.

--tool-dir runs the same cases against another copy of kgate.py and
btf_kind_scan.py (used to show which cases the pre-fix tool got wrong).
Exit 0 only if every case behaves as expected.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
DATA = os.path.join(FIX, "data")
PY = [sys.executable, "-I", "-B"]


def load_gen():
    spec = importlib.util.spec_from_file_location("kgate_make_fixtures", os.path.join(FIX, "make_fixtures.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def mke2fs_path():
    p = shutil.which("mke2fs")
    if p:
        return p
    for c in ("/usr/sbin/mke2fs", "/sbin/mke2fs"):
        if os.access(c, os.X_OK):
            return c
    raise SystemExit("mke2fs not found (install e2fsprogs)")


def tool_path(name):
    p = shutil.which(name)
    for c in ([p] if p else []) + [f"/usr/sbin/{name}", f"/sbin/{name}"]:
        if c and os.access(c, os.X_OK):
            return c
    raise SystemExit(f"{name} not found")


def mkext4(tree, img, links=(), moves=()):
    work = img + ".tree"
    shutil.copytree(tree, work, symlinks=True)
    for rel, target in links:
        p = os.path.join(work, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        os.symlink(target, p)
    with open(img, "wb") as fh:
        fh.truncate(4 << 20)
    r = subprocess.run([mke2fs_path(), "-q", "-F", "-t", "ext4", "-d", work, img], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"mke2fs failed for {img}: {r.stderr.decode(errors='replace')}")
    shutil.rmtree(work)
    return img


def write_shims(tmp):
    """Directories that shadow debugfs/modprobe on PATH to simulate faults."""
    dfs, real_mp = tool_path("debugfs"), None
    shims = {}
    d = os.path.join(tmp, "shim_debugfs_stderr")
    os.makedirs(d)
    with open(os.path.join(d, "debugfs"), "w") as fh:
        fh.write(f'#!/bin/sh\n"{dfs}" "$@"; rc=$?\necho "debugfs: simulated read error on inode 19" >&2\nexit $rc\n')
    shims["debugfs_stderr"] = d
    d = os.path.join(tmp, "shim_debugfs_trunc")
    os.makedirs(d)
    with open(os.path.join(d, "debugfs"), "w") as fh:
        fh.write(f'#!/bin/sh\n"{dfs}" "$@"; rc=$?\n'
                 'if [ "$1" = "-f" ]; then grep "^dump " "$2" | sed \'s/.*" "\\(.*\\)"$/\\1/\' | while read f; do truncate -s -1 "$f"; done; fi\n'
                 'exit $rc\n')
    shims["debugfs_trunc"] = d
    d = os.path.join(tmp, "shim_modprobe_bad")
    os.makedirs(d)
    with open(os.path.join(d, "modprobe"), "w") as fh:
        fh.write('#!/bin/sh\nprintf "0xdeadbeef\\tmodule_layout\\n"\nexit 0\n')
    shims["modprobe_bad"] = d
    for d in shims.values():
        for f in os.listdir(d):
            os.chmod(os.path.join(d, f), 0o755)
    return shims


def body_hash(body):
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def main():
    args = sys.argv[1:]
    results_file, tool_dir = None, HERE
    while args:
        if args[0] == "--results" and len(args) > 1:
            results_file, args = args[1], args[2:]
        elif args[0] == "--tool-dir" and len(args) > 1:
            tool_dir, args = os.path.abspath(args[1]), args[2:]
        else:
            sys.exit("usage: test_kgate.py [--results FILE] [--tool-dir DIR]")
    KGATE = os.path.join(tool_dir, "kgate.py")
    SCAN = os.path.join(tool_dir, "btf_kind_scan.py")
    tmp = tempfile.mkdtemp(prefix="kgate-test-")
    lines = []

    def log(s=""):
        print(s)
        lines.append(s)
    try:
        gen = load_gen()
        regen = os.path.join(tmp, "regen")
        gen.generate(regen)
        committed = open(os.path.join(DATA, "MANIFEST.sha256")).read()
        if committed == gen.manifest(regen):
            log("fixtures: committed fixtures/data matches make_fixtures.py output")
        else:
            log("WARN fixtures: regenerated fixtures differ from committed fixtures/data (zlib/Python version?); tests use the committed copy")
        for line in committed.splitlines():
            h, rel = line.split("  ", 1)
            with open(os.path.join(DATA, rel), "rb") as fh:
                if hashlib.sha256(fh.read()).hexdigest() != h:
                    raise SystemExit(f"fixtures/data/{rel} does not match its MANIFEST entry")
        D = lambda *p: os.path.join(DATA, *p)
        T = lambda *p: os.path.join(tmp, *p)
        shims = write_shims(tmp)
        # ext4 images and a symlinked directory tree
        vdlkm = mkext4(D("trees", "vendor_dlkm"), T("vendor_dlkm.img"))
        vendor = mkext4(D("trees", "vendor"), T("vendor.img"), [("lib/modules", "/vendor_dlkm/lib/modules")])
        vnomod = mkext4(D("trees", "vendor_nomodules"), T("vendor_nomodules.img"))
        vbadred = mkext4(D("trees", "vendor"), T("vendor_badredirect.img"), [("lib/modules", "/other_dlkm/lib/modules")])
        vuncov = mkext4(D("trees", "vendor"), T("vendor_uncovered.img"), [("lib/modules", "/vendor_dlkm/other/modules")])
        vsymdir = mkext4(D("trees", "vendor_dlkm_symdir"), T("vendor_dlkm_symdir.img"), [("lib/modules/extra", "/lib/extra_mods")])
        vbadlist = mkext4(D("trees", "vendor_dlkm_badlist"), T("vendor_dlkm_badlist.img"))
        dsym = T("dirsrc")
        shutil.copytree(D("trees", "vendor_dlkm_symdir", "lib"), dsym)
        os.symlink("../extra_mods", os.path.join(dsym, "modules", "extra"))
        stock = D("stock_boot.img")
        tmpl = D("profiles", "fixture.template.json")
        good_srcs = ["--vendor-boot", D("vendor_boot_good.img"), "--boot", stock, "--ext4", f"vendor_dlkm={vdlkm}",
                     "--ext4", f"vendor={vendor}", "--stock-kernel", stock]
        REF = T("ref_good", "reference.json")
        PROF = T("gitrepo", "profile.json")          # committed in a temp git repo (gate mode requires a committed profile)
        PROF_UNCOMMITTED = T("profile_good.json")

        def refb(name, *srcs, boot=stock, stock_kernel=None, device="fixture"):
            """bootstrap reference (no profile): exit 3 on success, 2 on error"""
            return ["reference", "--device", device, "--bootstrap", "--out", T("ref_" + name), "--boot", boot, *srcs,
                    "--stock-kernel", stock_kernel or boot]

        def chk(cfg="good", sv="good", kernel=None, vmlinux=None, config=None, base="stock_requested", requests="good.txt",
                baseline="baseline", extra=(), ref=None, profile=None, device="fixture", report_only=False, omit=(), build="group"):
            svpair = sv not in ("good", "baseline") and cfg == "good" and os.path.exists(D(f"Image_sv_{sv}"))
            kernel = kernel or (D(f"Image_sv_{sv}") if svpair else D(f"Image_cfg_{cfg}"))
            if vmlinux is None:
                vmlinux = D(f"vmlinux_sv_{sv}") if svpair else D(f"vmlinux_cfg_{cfg}")
            a = ["check", "--device", device, "--reference", ref or REF, "--symvers", sv if os.path.isabs(sv) else D("symvers", sv),
                 "--kernel", kernel, "--config", config or D("config", cfg)]
            opt = {"--profile": profile or PROF, "--build": build, "--vmlinux": vmlinux, "--requested": D("requests", requests),
                   "--requested-config": D("config", base)}
            if baseline:
                opt["--baseline-symvers"] = D("symvers", baseline)
            for k, v in opt.items():
                if k not in omit and not (report_only and k in ("--profile", "--build")):
                    a += [k, v]
            if report_only:
                a += ["--report-only", "--stock-kernel", stock]
            return a + list(extra)

        K, S = "kgate", "scan"
        # (name, tool, argv-or-callable, expected exit, (check id, status, substring) | ("text", substring), options)
        cases = []
        add = lambda *c, **o: cases.append((*c, o))
        # ------------------------------------------------------------------ reference
        add("reference: positive with profile (declared sources, pinned counts)", K, ["reference", "--device", "fixture", "--profile", tmpl, "--out", T("ref_good"), *good_srcs], 0, ("profile", "PASS", "pinned counts"))
        add("reference: positive, bootstrap (no profile) is never 0", K, refb("boot0", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 3, ("profile", "WARN", "BOOTSTRAP"))
        add("reference: profile missing without --bootstrap", K, ["reference", "--device", "fixture", "--out", T("ref_np"), *good_srcs], 2, ("reference", "ERROR", "--profile is required"))
        add("reference: partial sources vs profile (vendor_boot only)", K, ["reference", "--device", "fixture", "--profile", tmpl, "--out", T("ref_part"), "--vendor-boot", D("vendor_boot_good.img"), "--boot", stock, "--stock-kernel", stock], 2, ("reference", "ERROR", "declared sources"))
        add("reference: counts differ from profile pins", K, lambda: ["reference", "--device", "fixture", "--profile", T("profile_badcounts.json"), "--out", T("ref_bc"), *good_srcs], 2, ("reference", "ERROR", "pinned counts"))
        add("reference: device differs from profile", K, ["reference", "--device", "otherdev", "--profile", tmpl, "--out", T("ref_od"), *good_srcs], 2, ("reference", "ERROR", "is for device 'fixture'"))
        add("reference: empty (vendor_boot without modules)", K, refb("nomods", "--vendor-boot", D("vendor_boot_nomods.img")), 2, ("reference", "ERROR", "yielded zero modules"))
        add("reference: empty (only a module-less boot ramdisk)", K, refb("bootonly"), 2, ("reference", "ERROR", "empty reference"))
        add("reference: failed extraction (not an ext4 image)", K, refb("notext4", "--ext4", f"vendor_dlkm={D('not_an_image.img')}"), 2, ("reference", "ERROR", "not an ext2/3/4 image"))
        add("reference: Android sparse image", K, refb("sparse", "--ext4", f"vendor_dlkm={D('sparse.img')}"), 2, ("reference", "ERROR", "sparse image"))
        add("reference: EROFS image", K, refb("erofs", "--ext4", f"vendor_dlkm={D('erofs.img')}"), 2, ("reference", "ERROR", "EROFS"))
        add("reference: ext4 without /lib/modules", K, refb("nolib", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor={vnomod}"), 2, ("reference", "ERROR", "File not found"))
        add("reference: redirect to a partition not supplied", K, refb("badred", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor={vbadred}"), 2, ("reference", "ERROR", "no source labelled 'other_dlkm'"))
        add("reference: redirect target path not covered", K, refb("uncov", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vdlkm}", "--ext4", f"vendor={vuncov}"), 2, ("reference", "ERROR", "is not covered"))
        add("reference: bad vendor_boot magic", K, refb("badmagic", "--vendor-boot", D("vendor_boot_badmagic.img")), 2, ("reference", "ERROR", "bad magic"))
        add("reference: truncated gzip ramdisk", K, refb("trgz", "--vendor-boot", D("vendor_boot_truncated.img")), 2, ("reference", "ERROR", "gzip decompression failed"))
        add("reference: truncated cpio", K, refb("trcpio", "--vendor-boot", D("vendor_boot_truncated_cpio.img")), 2, ("reference", "ERROR", "cpio"))
        add("reference: ramdisk table does not cover section", K, refb("table", "--vendor-boot", D("vendor_boot_table_short.img")), 2, ("reference", "ERROR", "ramdisk table"))
        add("reference: missing source file", K, refb("nosrc", "--vendor-boot", T("does-not-exist.img")), 2, ("reference", "ERROR", "no such file"))
        add("reference: unparseable module (corrupt ELF)", K, refb("badko", "--vendor-boot", D("vendor_boot_corrupt_ko.img")), 2, ("reference", "ERROR", "section header table"))
        add("reference: garbled vermagic", K, refb("badvm", "--vendor-boot", D("vendor_boot_bad_vermagic.img")), 2, ("reference", "ERROR", "vermagic"))
        add("reference: module without __versions", K, refb("nover", "--vendor-boot", D("vendor_boot_noversions.img")), 2, ("reference", "ERROR", "no __versions"))
        add("reference: same-name modules with differing content", K, refb("samename", "--vendor-boot", D("vendor_boot_modA_variant.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 2, ("same-name-differing", "ERROR", "modA.ko"))
        add("reference: same-name differing, --allow-same-name-differing", K, refb("samenameok", "--vendor-boot", D("vendor_boot_modA_variant.img"), "--ext4", f"vendor_dlkm={vdlkm}") + ["--allow-same-name-differing"], 3, ("same-name-differing", "WARN", "ALL copies"))
        add("reference: same .modinfo name, different files", K, refb("modname", "--vendor-boot", D("vendor_boot_modname_dup.img")), 2, ("modname-collision", "ERROR", "modA_alt.ko"))
        add("reference: same path twice in concatenated cpio archives", K, refb("duppath", "--vendor-boot", D("vendor_boot_dup_path.img")), 2, ("same-name-differing", "ERROR", "#2"))
        add("reference: conflicting import CRCs for one symbol", K, refb("conflict", "--vendor-boot", D("vendor_boot_conflict.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 2, ("import-crc-conflict", "ERROR", "sym_a"))
        add("reference: mixed ELF machines", K, refb("mixed", "--vendor-boot", D("vendor_boot_mixed_machine.img")), 2, ("reference", "ERROR", "mixed ELF machines"))
        add("reference: modules disagree on vermagic flags", K, refb("vmflags", "--vendor-boot", D("vendor_boot_vermagic_flags.img")), 2, ("reference", "ERROR", "disagree on vermagic flags"))
        add("reference: .ko symlink in ramdisk", K, refb("kolink", "--vendor-boot", D("vendor_boot_ko_symlink.img")), 2, ("reference", "ERROR", "symlink /lib/modules/modL.ko"))
        add("reference: symlinked directory in ramdisk module tree", K, refb("dirlink", "--vendor-boot", D("vendor_boot_dir_symlink.img")), 2, ("reference", "ERROR", "symlink /lib/modules/extra"))
        add("reference: symlinked directory in ext4 module tree", K, refb("e4link", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vsymdir}"), 2, ("reference", "ERROR", "symlink /lib/modules/extra"))
        add("reference: symlinked directory in --dir source", K, refb("dirsrc", "--dir", f"vendor_dlkm={os.path.join(dsym, 'modules')}"), 2, ("reference", "ERROR", "directory symlink"))
        add("reference: compressed .ko", K, refb("xz", "--vendor-boot", D("vendor_boot_compressed_ko.img")), 2, ("reference", "ERROR", "compressed module"))
        add("reference: modules.load names a module not extracted", K, refb("lstload", "--vendor-boot", D("vendor_boot_list_missing.img")), 2, ("reference", "ERROR", "modZ.ko"))
        add("reference: modules.dep names a module not extracted", K, refb("lstdep", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vbadlist}"), 2, ("reference", "ERROR", "modQ.ko"))
        add("reference: export only via ___ksymtab+sym section", K, refb("plus", "--vendor-boot", D("vendor_boot_plusexport.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 3, ("reference", "PASS", "6 required from vmlinux"))
        add("reference: __ksymtab_strings name not recovered", K, refb("ghost", "--vendor-boot", D("vendor_boot_ghost_export.img")), 2, ("reference", "ERROR", "ghost"))
        add("reference: export table without recoverable names", K, refb("nameless", "--vendor-boot", D("vendor_boot_nameless_exports.img")), 2, ("reference", "ERROR", "no export names"))
        add("reference: stock kernel without BTF", K, refb("stocknobtf", "--vendor-boot", D("vendor_boot_good.img"), boot=D("stock_boot_nobtf.img")), 2, ("reference", "ERROR", "no BTF"))
        add("reference: --stock-kernel is not a supplied boot image", K, refb("stockx", "--vendor-boot", D("vendor_boot_good.img"), stock_kernel=D("Image_extrakind")), 2, ("reference", "ERROR", "is not one of the supplied --boot"))
        add("reference: no --stock-kernel", K, ["reference", "--device", "fixture", "--bootstrap", "--out", T("ref_nsk"), "--vendor-boot", D("vendor_boot_good.img")], 2, ("reference", "ERROR", "--stock-kernel is required"))
        add("reference: debugfs writes to stderr", K, refb("dfserr", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 2, ("reference", "ERROR", "simulated read error"), path=shims["debugfs_stderr"])
        add("reference: debugfs dump shorter than listed size", K, refb("dfstr", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vdlkm}"), 2, ("reference", "ERROR", "failed or incomplete"), path=shims["debugfs_trunc"])
        add("reference: modprobe disagrees with __versions parse", K, refb("mpbad", "--vendor-boot", D("vendor_boot_good.img")), 2, ("reference", "ERROR", "disagrees with modprobe"), path=shims["modprobe_bad"])
        add("reference: internal exception -> exit 2, stale JSON replaced", K, refb("crash", "--vendor-boot", D("vendor_boot_good.img")) + ["--internal-crash-test"], 2, ("text", "ERROR internal"), stale=True)
        add("reference: other-device reference (for a later check)", K, refb("otherdev", "--vendor-boot", D("vendor_boot_good.img"), "--ext4", f"vendor_dlkm={vdlkm}", device="otherdev"), 3, ("profile", "WARN", "BOOTSTRAP"))
        # ------------------------------------------------------------------ check (gate mode)
        add("check: positive (all inputs, pinned profile)", K, lambda: chk(), 0, ("crc", "PASS", "6/6"))
        add("check: positive, --set-val with '#' in the value", K, lambda: chk(), 0, ("requested-options", "PASS", "all 5"))
        add("check: positive, Image.gz", K, lambda: chk(kernel=D("Image_good.gz")), 0, ("input-binding", "PASS", "objcopy -O binary"))
        add("check: positive, stock build: explicit --none and waived baseline", K, lambda: chk(build="stock", requests="none.txt", baseline=None, extra=["--waive-baseline", "stock-config build: this build IS the baseline"]), 0, ("requested-options", "PASS", "explicit --none"), also_text="waivers: baseline")
        add("check: positive, CRLF copy of the stock base config parse-equals the stock IKCONFIG", K, lambda: chk(base="stock_requested_crlf"), 0, ("base-config", "PASS", "IKCONFIG of the device's pinned stock kernel"))
        add("check: positive, allowlisted select fallout (XOR_BLOCKS for BTRFS)", K, lambda: chk(cfg="btrfs", requests="btrfs.txt", build="btrfs", extra=["--allow-config-changes", D("allow", "btrfs.allow")]), 0, ("requested-config-allowlisted", "WARN", "XOR_BLOCKS"),
            json_has=["inputs.allow_config_changes.sha256", "inputs.vmlinux.sha256", "inputs.kernel.sha256", "inputs.requested.sha256", "inputs.requested_config.sha256", "inputs.baseline_symvers.sha256", "inputs.reference.sha256", "inputs.profile.sha256"])
        add("check: positive, no IKCONFIG with explicit waiver", K, lambda: chk(cfg="no_ikconfig", build="noik", extra=["--allow-config-changes", D("allow", "noik.allow"), "--waive-ikconfig", "fixture kernel built without IKCONFIG"]), 0, ("config-binding", "WARN", "waived"), also_text="waivers: ikconfig")
        add("check: unused --waive-ikconfig is not recorded as a waiver", K, lambda: chk(extra=["--waive-ikconfig", "should not be needed here"]), 0, ("config-binding", "PASS", "byte-identical"), also_text="build ACCEPTED -- matches")
        add("check: positive, gap between sections is zero in image and vmlinux", K, lambda: chk(kernel=D("Image_gap_zero"), vmlinux=D("vmlinux_gap_zero")), 0, ("input-binding", "PASS", "objcopy -O binary"))
        add("check: report-only never exits 0", K, lambda: chk(report_only=True), 3, ("mode", "WARN", "report-only"))
        add("check: wrong module_layout", K, lambda: chk(sv="wrong_module_layout"), 1, ("module-layout", "FAIL", "0x22222222"))
        add("check: missing required symbol", K, lambda: chk(sv="missing_symbol"), 1, ("missing", "FAIL", "sym_b"))
        add("check: required symbol only in an in-tree module", K, lambda: chk(sv="only_intree"), 1, ("missing", "FAIL", "in-tree"))
        add("check: CRC mismatch", K, lambda: chk(sv="crc_mismatch"), 1, ("crc", "FAIL", "sym_a ref=0xaaaa0001 build=0xaaaaffff"))
        add("check: changed baseline export", K, lambda: chk(sv="changed_baseline"), 1, ("baseline-changed", "FAIL", "base_e1"), only=True)
        add("check: removed baseline export", K, lambda: chk(sv="removed_baseline"), 1, ("baseline-removed", "FAIL", "base_e2"), only=True)
        add("check: removed baseline export (baseline has extra; report-only)", K, lambda: chk(baseline="baseline_plus_old", report_only=True), 1, ("baseline-removed", "FAIL", "base_e3"))
        add("check: vmlinux exports a vendor-module symbol", K, lambda: chk(sv="collision_vendor_export"), 1, ("export-collision", "FAIL", "vend_x"), only=True)
        add("check: duplicate Module.symvers rows", K, lambda: chk(sv="duplicate_rows"), 1, ("symvers-duplicates", "FAIL", "sym_a"))
        add("check: namespace not imported by vendor module", K, lambda: chk(sv="wrong_namespace"), 1, ("namespace", "FAIL", "OTHERNS"))
        add("check: GPL-only export to proprietary module", K, lambda: chk(sv="gpl_only"), 1, ("gpl-only", "FAIL", "Proprietary"))
        add("check: unversioned vendor import missing", K, lambda: chk(sv="missing_unversioned"), 1, ("unversioned-imports", "FAIL", "unv_sym"))
        add("check: requested option dropped (report-only)", K, lambda: chk(requests="unsatisfied.txt", report_only=True), 1, ("requested-options", "FAIL", "BTRFS_FS"))
        add("check: requested option wrong value (report-only)", K, lambda: chk(requests="wrong_value.txt", report_only=True), 1, ("requested-options", "FAIL", "AUTOFS_FS: requested y"))
        add("check: --undefine request but symbol present (report-only)", K, lambda: chk(requests="undefine.txt", report_only=True), 1, ("requested-options", "FAIL", "requested undefined"))
        add("check: typo in a --disable request (report-only)", K, lambda: chk(requests="typo_disable.txt", report_only=True), 2, ("requested-options-unknown", "ERROR", "DEVTMPFS_MOUNTT"))
        add("check: stock config entry dropped from the build", K, lambda: chk(cfg="dropped"), 1, ("requested-config", "FAIL", "VENDOR_ONLY_DRIVER"))
        add("check: compiler version changed (not WARN)", K, lambda: chk(cfg="cc_change"), 1, ("requested-config", "FAIL", "CC_VERSION_TEXT"), only=True)
        add("check: unrequested USER_NS/PID_NS", K, lambda: chk(cfg="extra_userns"), 1, ("requested-config", "FAIL", "USER_NS"), only=True)
        add("check: unrequested CFI_CLANG off", K, lambda: chk(cfg="cfi_off"), 1, ("requested-config", "FAIL", "CFI_CLANG"), only=True)
        add("check: select fallout without allowlist (report-only)", K, lambda: chk(cfg="btrfs", requests="btrfs.txt", report_only=True), 1, ("requested-config", "FAIL", "XOR_BLOCKS"))
        add("check: malformed 'is not set' line in base config", K, lambda: chk(base="malformed_notset"), 2, ("input", "ERROR", "malformed 'is not set'"))
        add("check: vermagic flags differ (MODVERSIONS off)", K, lambda: chk(cfg="no_modversions"), 1, ("vermagic", "FAIL", "modversions"))
        add("check: BTF kinds beyond stock", K, lambda: chk(kernel=D("Image_extrakind"), vmlinux=D("vmlinux_extrakind")), 1, ("btf-kinds", "FAIL", "DECL_TAG"), only=True)
        add("check: no BTF", K, lambda: chk(kernel=D("Image_nobtf"), vmlinux=D("vmlinux_nobtf")), 2, ("btf-kinds", "ERROR", "no BTF"))
        add("check: no BTF, --allow-no-btf (recorded as a waiver)", K, lambda: chk(kernel=D("Image_nobtf"), vmlinux=D("vmlinux_nobtf"), extra=["--allow-no-btf"]), 0, ("btf-kinds", "WARN", "allowed by --allow-no-btf"), also_text="waivers: allow-no-btf")
        add("check: malformed BTF (section out of bounds)", K, lambda: chk(kernel=D("Image_malformed_bounds"), vmlinux=D("vmlinux_malformed_bounds")), 2, ("btf-kinds", "ERROR", "out of bounds"))
        add("check: malformed BTF (record overruns types)", K, lambda: chk(kernel=D("Image_malformed_record"), vmlinux=D("vmlinux_malformed_record")), 2, ("btf-kinds", "ERROR", "runs past end"))
        add("check: ambiguous BTF (two blobs)", K, lambda: chk(kernel=D("Image_ambiguous"), vmlinux=D("vmlinux_ambiguous")), 2, ("btf-kinds", "ERROR", "ambiguous"))
        add("check: decoy BTF header with implausible hdr_len", K, lambda: chk(kernel=D("Image_decoy_hdrlen")), 2, ("btf-kinds", "ERROR", "malformed BTF candidate"))
        add("check: corrupted hdr_len is malformed, not 'no BTF' (--allow-no-btf)", K, lambda: chk(kernel=D("Image_hdrlen_corrupt"), extra=["--allow-no-btf"]), 2, ("btf-kinds", "ERROR", "malformed BTF candidate"))
        add("check: Image.gz with trailing junk", K, lambda: chk(kernel=D("Image_good_trailing_junk.gz")), 2, ("btf-kinds", "ERROR", "gzip"))
        add("check: unparseable Module.symvers", K, lambda: chk(sv="unparseable"), 2, ("input", "ERROR", "expected 4 or 5"))
        add("check: CRLF Module.symvers", K, lambda: chk(sv="crlf"), 2, ("input", "ERROR", "bad namespace field"))
        add("check: empty Module.symvers", K, lambda: chk(sv="empty"), 2, ("input", "ERROR", "empty file"))
        add("check: Module.symvers without vmlinux rows", K, lambda: chk(sv="no_vmlinux"), 2, ("input", "ERROR", "no vmlinux rows"))
        add("check: missing Module.symvers file", K, lambda: chk(sv=T("does-not-exist")), 2, ("input", "ERROR", "no such file"))
        add("check: unparseable .config", K, lambda: chk(config=D("config", "unparseable")), 2, ("input", "ERROR", "unparseable line"))
        add("check: unsupported request syntax (report-only)", K, lambda: chk(requests="unsupported.txt", report_only=True), 2, ("input", "ERROR", "unsupported token"))
        add("check: empty request list without --none (report-only)", K, lambda: chk(requests="empty.txt", report_only=True), 2, ("input", "ERROR", "--none"))
        add("check: .config not the one embedded in the image", K, lambda: chk(config=D("config", "extra_userns")), 2, ("config-binding", "ERROR", "differs from the config embedded"))
        add("check: no IKCONFIG and no waiver", K, lambda: chk(cfg="no_ikconfig", build="noik", extra=["--allow-config-changes", D("allow", "noik.allow")]), 2, ("config-binding", "ERROR", "no embedded config"), only=True)
        add("check: vmlinux __crc_ disagrees with Module.symvers", K, lambda: chk(vmlinux=D("vmlinux_crc_disagrees")), 2, ("input-binding", "ERROR", ".symtab __crc_sym_a 0x0bad0001"), only=True)
        add("check: vmlinux from another build (banner)", K, lambda: chk(vmlinux=D("vmlinux_other_build")), 2, ("input-binding", "ERROR", "banner"))
        add("check: image bytes differ from vmlinux (same banner/BTF)", K, lambda: chk(vmlinux=D("vmlinux_text_differs")), 2, ("input-binding", "ERROR", "differ from the objcopy reconstruction"), only=True)
        add("check: stock kernel passed as the build image", K, lambda: chk(kernel=stock), 2, ("input-binding", "ERROR", "objcopy reconstruction"))
        add("check: truncated vmlinux", K, lambda: chk(vmlinux=D("vmlinux_tiny")), 2, ("input", "ERROR", "not a (complete)"))
        for o in ("--profile", "--build", "--vmlinux", "--requested", "--requested-config", "--baseline-symvers"):
            add(f"check: gate mode without {o}", K, (lambda o=o: chk(omit=(o,), baseline=None if o == "--baseline-symvers" else "baseline")), 2, ("input", "ERROR", f"requires: {o} ("))
        add("check: waiver without a real reason", K, lambda: chk(build="stock", requests="none.txt", baseline=None, extra=["--waive-baseline", "x"]), 2, ("input", "ERROR", "justification"))
        add("check: --device differs from profile", K, lambda: chk(device="otherdev"), 2, ("input", "ERROR", "is for device 'fixture'"))
        add("check: reference of another device (report-only)", K, lambda: chk(ref=T("ref_otherdev", "reference.json"), report_only=True), 2, ("input", "ERROR", "reference is for device 'otherdev'"))
        add("check: reference not matching the pinned sha256", K, lambda: chk(ref=T("ref_tampered.json")), 2, ("input", "ERROR", "does not match the profile's pinned"))
        add("check: hand-edited reference (body hash, report-only)", K, lambda: chk(ref=T("ref_tampered.json"), report_only=True), 2, ("input", "ERROR", "body_sha256 mismatch"))
        add("check: re-hashed reference with altered vendor_exports", K, lambda: chk(ref=T("ref_rehash_vexp.json"), report_only=True), 2, ("input", "ERROR", "re-derivation"))
        add("check: re-hashed reference with altered stock BTF kinds", K, lambda: chk(ref=T("ref_rehash_kinds.json"), report_only=True), 2, ("input", "ERROR", "re-scan of the stock kernel"))
        add("check: re-hashed structurally invalid reference", K, lambda: chk(ref=T("ref_rehash_struct.json"), report_only=True), 2, ("input", "ERROR", "structurally invalid"))
        add("check: re-hashed reference with no modules", K, lambda: chk(ref=T("ref_rehash_empty.json"), report_only=True), 2, ("input", "ERROR", "empty (no modules)"))
        add("check: ___ksymtab+ export is not required from vmlinux (report-only)", K, lambda: chk(ref=T("ref_plus", "reference.json"), report_only=True), 3, ("crc", "PASS", "6/6"))
        add("check: ___ksymtab+ export collides with vmlinux (report-only)", K, lambda: chk(ref=T("ref_plus", "reference.json"), sv="collision_plus_export", report_only=True), 1, ("export-collision", "FAIL", "vend_s"))
        add("check: base config is not the stock config (gate)", K, lambda: chk(base="good"), 2, ("input", "ERROR", "is not the device's stock config"))
        add("check: base config is not the stock config (report-only too)", K, lambda: chk(base="good", report_only=True), 2, ("input", "ERROR", "is not the device's stock config"))
        add("check: request list not the one pinned for the build", K, lambda: chk(requests="btrfs.txt", cfg="btrfs"), 2, ("input", "ERROR", "request list is not the one pinned"))
        add("check: allowlist given to a build without a pinned allowlist", K, lambda: chk(extra=["--allow-config-changes", D("allow", "btrfs.allow")]), 2, ("input", "ERROR", "has no pinned allowlist"))
        add("check: pinned allowlist missing", K, lambda: chk(cfg="btrfs", requests="btrfs.txt", build="btrfs"), 2, ("input", "ERROR", "is not the allowlist pinned"))
        add("check: baseline not the pinned stock-build Module.symvers", K, lambda: chk(baseline="baseline_plus_old"), 2, ("input", "ERROR", "not the pinned stock-build Module.symvers"))
        add("check: baseline is the build's own Module.symvers", K, lambda: chk(sv="baseline", vmlinux=D("vmlinux_cfg_good"), baseline="baseline"), 2, ("input", "ERROR", "self-comparison"))
        add("check: --waive-baseline on an option-group build", K, lambda: chk(baseline=None, extra=["--waive-baseline", "stock-config build: this build IS the baseline"]), 2, ("input", "ERROR", "only allowed for the stock-config build"))
        add("check: stock build given a baseline instead of the pinned waiver", K, lambda: chk(build="stock", requests="none.txt"), 2, ("input", "ERROR", "must be waived explicitly"))
        add("check: --build not pinned in the profile", K, lambda: chk(build="nosuch"), 2, ("input", "ERROR", "is not one of the builds pinned"))
        add("check: truncated kernel image", K, lambda: chk(kernel=D("Image_truncated")), 2, ("input-binding", "ERROR", "truncated or padded"), only=True)
        add("check: non-zero bytes in a gap between sections", K, lambda: chk(vmlinux=D("vmlinux_gap_zero")), 2, ("input-binding", "ERROR", "differ from the objcopy reconstruction"), only=True)
        add("check: Image.gz made of two gzip members", K, lambda: chk(kernel=D("Image_two_member.gz")), 2, ("btf-kinds", "ERROR", "second gzip member"))
        add("check: export type in Module.symvers differs from vmlinux __ksymtab", K, lambda: chk(kernel=D("Image_ksym_type"), vmlinux=D("vmlinux_ksym_type")), 2, ("input-binding", "ERROR", "export type"), only=True)
        add("check: namespace in Module.symvers differs from vmlinux __ksymtab", K, lambda: chk(kernel=D("Image_ksym_ns"), vmlinux=D("vmlinux_ksym_ns")), 2, ("input-binding", "ERROR", "namespace"), only=True)
        add("check: bare 'Linux version ' text before the banner; namespaces still decoded", K, lambda: chk(kernel=D("Image_early_text"), vmlinux=D("vmlinux_early_text")), 0, ("input-binding", "PASS", "type, namespace"))
        add("check: runtime __kcrctab CRC altered in Image+vmlinux (.symtab/Module.symvers unchanged)", K, lambda: chk(kernel=D("Image_kcrc_tamper"), vmlinux=D("vmlinux_kcrc_tamper")), 2, ("input-binding", "ERROR", "runtime __kcrctab 0x"), only=True)
        add("check: export hidden from .symtab and Module.symvers but present in the Image", K, lambda: chk(kernel=D("Image_hidden_export"), vmlinux=D("vmlinux_hidden_export")), 2, ("input-binding", "ERROR", "vend_x: exported by vmlinux's (Image) __ksymtab tables but no vmlinux row"), only=True)
        add("check: export type forged via .symtab section index", K, lambda: chk(kernel=D("Image_forged_type"), vmlinux=D("vmlinux_forged_type")), 2, ("input-binding", "ERROR", "sym_d: Module.symvers export type EXPORT_SYMBOL vs the __ksymtab table holding it (EXPORT_SYMBOL_GPL)"), only=True)
        add("check: gzip bomb as Image.gz", K, lambda: chk(kernel=T("bomb.gz")), 2, ("btf-kinds", "ERROR", "decompression bomb"))
        add("check: stock kernel located via the profile (no --stock-kernel)", K, lambda: chk(), 0, ("base-config", "PASS", "pinned stock kernel"))
        add("check: gate mode requires a committed profile by default", K, lambda: chk(profile=PROF_UNCOMMITTED), 2, ("input", "ERROR", "not inside a git work tree"))
        add("check: uncommitted profile with a recorded waiver", K, lambda: chk(profile=PROF_UNCOMMITTED, extra=["--waive-committed-profile", "fixture: profile deliberately not committed"]), 0, ("waiver-committed-profile", "WARN", "deliberately not committed"), also_text="waivers: committed-profile")
        add("check: decoy export table (section headers) vs the kernel's own __start___ksymtab", K, lambda: chk(kernel=D("Image_decoy_table"), vmlinux=D("vmlinux_decoy_table")), 2, ("input-binding", "ERROR", "kernel's own __start___ksymtab is"), only=True)
        add("check: __ksymtab not sorted (loader binary search)", K, lambda: chk(kernel=D("Image_unsorted_table"), vmlinux=D("vmlinux_unsorted_table")), 2, ("input", "ERROR", "strictly ascending"))
        add("check: __ksymtab entry address redirected to another symbol", K, lambda: chk(kernel=D("Image_redirected_entry"), vmlinux=D("vmlinux_redirected_entry")), 2, ("input-binding", "ERROR", "sym_a: __ksymtab entry points to"), only=True)
        add("check: allocated section extends past the kernel's _edata", K, lambda: chk(kernel=D("Image_past_edata"), vmlinux=D("vmlinux_past_edata")), 2, ("input-binding", "ERROR", "extends past _edata"), only=True)
        add("check: allocated section set differs from the pinned stock-build set", K, lambda: chk(kernel=D("Image_extra_section"), vmlinux=D("vmlinux_extra_section")), 2, ("input-binding", "ERROR", "section set differs"), only=True)
        add("check: 4.19 8-byte __ksymtab layout + 4.19 kallsyms (namespace-free symvers; report-only, no baseline)", K, lambda: chk(kernel=D("Image_layout419"), vmlinux=D("vmlinux_layout419"), sv="no_ns", baseline=None, report_only=True), 3, ("input-binding", "PASS", "kallsyms"))
        add("check: namespace claimed in Module.symvers on a 4.19 (namespace-free) kernel", K, lambda: chk(kernel=D("Image_layout419"), vmlinux=D("vmlinux_layout419"), baseline=None, report_only=True), 2, ("input-binding", "ERROR", "ns_sym: Module.symvers namespace TESTNS vs __ksymtab namespace -"), only=True)
        add("check: 12-byte (namespace) layout under a 4.19 banner", K, lambda: chk(kernel=D("Image_layout_mismatch"), vmlinux=D("vmlinux_layout_mismatch")), 2, ("input", "ERROR", "do not fit Linux 4.19"))
        add("check: kernel image lacks the module-loader vermagic string", K, lambda: chk(kernel=D("Image_no_vermagic"), vmlinux=D("vmlinux_no_vermagic")), 1, ("vermagic-image", "FAIL", "does not contain"), only=True)
        add("check: committed profile (default requirement)", K, lambda: chk(), 0, ("profile-committed", "PASS", "committed git blob"))
        add("check: usage error (no --device) leaves no stale PASS JSON", K, lambda: [x for x in chk() if x not in ("--device", "fixture")], 2, ("text", "--device"), stale="absent")
        add("check: internal exception -> exit 2, stale JSON replaced", K, lambda: chk(extra=["--internal-crash-test"]), 2, ("text", "ERROR internal"), stale=True)
        # ------------------------------------------------------------------ kind scanner
        add("btf_kind_scan: positive vs stock kinds", S, [D("Image_cfg_good"), "--allowed-from", stock], 0, ("text", "PASS btf-kinds"))
        add("btf_kind_scan: kinds beyond stock", S, [D("Image_extrakind"), "--allowed-from", stock], 1, ("text", "FAIL btf-kinds: kinds beyond allowed set: DECL_TAG"))
        add("btf_kind_scan: no allowed set and no --scan-only", S, [D("Image_extrakind")], 2, ("text", "one of the arguments"))
        add("btf_kind_scan: --scan-only is never 0", S, [D("Image_extrakind"), "--scan-only"], 3, ("text", "SCAN-ONLY"))
        add("btf_kind_scan: no BTF", S, [D("Image_nobtf"), "--allowed-from", stock], 2, ("text", "no BTF header found"))
        add("btf_kind_scan: no BTF, --allow-missing", S, [D("Image_nobtf"), "--allowed-from", stock, "--allow-missing"], 0, ("text", "allowed by --allow-missing"))
        add("btf_kind_scan: malformed (bounds)", S, [D("Image_malformed_bounds"), "--scan-only"], 2, ("text", "out of bounds"))
        add("btf_kind_scan: malformed (record)", S, [D("Image_malformed_record"), "--scan-only"], 2, ("text", "runs past end"))
        add("btf_kind_scan: ambiguous", S, [D("Image_ambiguous"), "--scan-only"], 2, ("text", "ambiguous"))
        add("btf_kind_scan: decoy hdr_len", S, [D("Image_decoy_hdrlen"), "--scan-only"], 2, ("text", "malformed BTF candidate"))
        add("btf_kind_scan: corrupted hdr_len with --allow-missing", S, [D("Image_hdrlen_corrupt"), "--scan-only", "--allow-missing"], 2, ("text", "malformed BTF candidate"))
        add("btf_kind_scan: ELF magic but < 64 bytes", S, [D("elf_tiny"), "--scan-only"], 2, ("text", "truncated ELF header"))
        add("btf_kind_scan: unreadable input", S, [T("does-not-exist"), "--scan-only"], 2, ("text", "cannot read"))
        add("btf_kind_scan: internal exception -> exit 2, stale JSON replaced", S, [D("Image_cfg_good"), "--scan-only", "--internal-crash-test"], 2, ("text", "ERROR internal"), stale=True)

        def prepare_after_good_ref():
            with open(REF, "rb") as fh:
                raw = fh.read()
            sha = hashlib.sha256(raw).hexdigest()
            pr = json.load(open(tmpl))
            pr["reference_sha256"] = sha
            json.dump(dict(pr, stock_kernel=os.path.relpath(stock, os.path.dirname(PROF_UNCOMMITTED))), open(PROF_UNCOMMITTED, "w"), indent=1)
            repo = T("gitrepo")
            os.makedirs(repo)
            json.dump(dict(pr, stock_kernel=os.path.relpath(stock, repo)), open(PROF, "w"), indent=1)
            git = shutil.which("git")
            if git:
                for cmd in (["init", "-q"], ["add", "profile.json"], ["-c", "user.name=kgate-test", "-c", "user.email=kgate@test", "commit", "-q", "-m", "pin"]):
                    subprocess.run([git, "-C", repo] + cmd, check=True, capture_output=True)
            import zlib as _z
            co = _z.compressobj(9, _z.DEFLATED, 16 + _z.MAX_WBITS)
            with open(T("bomb.gz"), "wb") as fh:
                z = b"\0" * (1 << 20)
                for _ in range(260):
                    fh.write(co.compress(z))
                fh.write(co.flush())
            bad = dict(pr, counts=dict(pr["counts"], required_from_vmlinux=7))
            bad.pop("reference_sha256")
            json.dump(bad, open(T("profile_badcounts.json"), "w"), indent=1)
            ref = json.loads(raw)
            t = dict(ref)
            t["required"] = dict(t["required"], sym_a="0x00000000")
            json.dump(t, open(T("ref_tampered.json"), "w"))

            def rehash(mut, name):
                r = json.loads(raw)
                r.pop("body_sha256")
                mut(r)
                r["body_sha256"] = body_hash(r)
                json.dump(r, open(T(name), "w"))
            rehash(lambda r: r["vendor_exports"].pop("vend_x"), "ref_rehash_vexp.json")
            rehash(lambda r: r["stock_btf"]["kinds"].update({"DECL_TAG": 1}), "ref_rehash_kinds.json")
            rehash(lambda r: r["modules"][0].pop("versions"), "ref_rehash_struct.json")
            rehash(lambda r: r.update(modules=[]), "ref_rehash_empty.json")

        rows, bad = [], 0
        log("")
        log(f"{'case':<84} {'want':>4} {'got':>4}  result")
        prepared = False
        for name, tool, argv, want, expect, opts in cases:
            if rows and not prepared:      # after the positive reference (case 1) has run
                prepared = True
                try:
                    prepare_after_good_ref()
                except (OSError, ValueError, KeyError) as e:
                    log(f"WARN setup: positive reference unusable ({type(e).__name__}: {e}); dependent cases will mismatch")
            if callable(argv):
                argv = argv()
            jp = T("out_%d.json" % len(rows))
            exe = KGATE if tool == K else SCAN
            full = PY + [exe] + list(argv) + ["--json", jp]
            if opts.get("stale"):
                with open(jp, "w") as fh:
                    fh.write('{"result": "PASS", "exit_code": 0}')
            env = dict(os.environ)
            if opts.get("path"):
                env["PATH"] = opts["path"] + os.pathsep + env.get("PATH", "")
            proc = subprocess.run(full, capture_output=True, text=True, env=env)
            got = proc.returncode
            ok, detail = got == want, ""
            text = proc.stdout + proc.stderr
            if ok and expect[0] == "text":
                if expect[1] not in text:
                    ok, detail = False, f" (output lacks {expect[1]!r})"
            elif ok:
                try:
                    js = json.load(open(jp))
                    hits = [c for c in js.get("checks", []) if c["id"] == expect[0] and c["status"] == expect[1]
                            and (expect[2] in c["message"] or any(expect[2] in str(i) for i in c.get("items", [])))]
                    if not hits:
                        ok = False
                        have = [(c["id"], c["status"], c["message"][:90]) for c in js.get("checks", []) if c["id"] == expect[0]]
                        detail = f" (no {expect[0]}/{expect[1]} containing {expect[2]!r}; have {have})"
                except (OSError, ValueError, KeyError) as e:
                    ok, detail = False, f" (no usable JSON: {e})"
            if ok and opts.get("also_text") and opts["also_text"] not in text:
                ok, detail = False, f" (output lacks {opts['also_text']!r})"
            if ok and (opts.get("json_has") or opts.get("only")):
                try:
                    js = json.load(open(jp))
                    for path_ in opts.get("json_has", []):
                        v = js
                        for k_ in path_.split("."):
                            v = v.get(k_) if isinstance(v, dict) else None
                        if not (isinstance(v, str) and len(v) == 64):
                            ok, detail = False, f" (JSON lacks a sha256 at {path_})"
                            break
                    if ok and opts.get("only"):
                        others = [(c["id"], c["status"]) for c in js["checks"] if c["status"] in ("FAIL", "ERROR") and c["id"] != expect[0]]
                        if others:
                            ok, detail = False, f" (other FAIL/ERROR checks present: {others})"
                except (OSError, ValueError, KeyError) as e:
                    ok, detail = False, f" (JSON: {e})"
            if ok and opts.get("stale") == "absent":
                if os.path.exists(jp):
                    try:
                        if json.load(open(jp)).get("result") != "ERROR":
                            ok, detail = False, " (stale JSON survived a usage error)"
                    except (OSError, ValueError):
                        ok, detail = False, " (unreadable JSON after a usage error)"
            elif ok and opts.get("stale"):
                try:
                    js = json.load(open(jp))
                    if js.get("result") != "ERROR":
                        ok, detail = False, f" (JSON result {js.get('result')!r}, expected ERROR)"
                except (OSError, ValueError) as e:
                    ok, detail = False, f" (stale-JSON check: {e})"
            if not ok:
                bad += 1
                detail += "\n" + "\n".join("      | " + l for l in text.splitlines()[-10:])
            log(f"{name:<84} {want:>4} {got:>4}  {'ok' if ok else 'MISMATCH'}{detail}")
            rows.append({"case": name, "expected_exit": want, "actual_exit": got, "ok": ok})
        log("")
        log(f"{len(cases) - bad}/{len(cases)} cases behaved as expected (exit code and reason)")
        if results_file:
            with open(results_file, "w") as fh:
                fh.write("\n".join(lines) + "\n")
        return 0 if bad == 0 else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
