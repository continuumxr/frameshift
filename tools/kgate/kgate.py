#!/usr/bin/env python3
"""kgate -- offline kernel symbol-version gate for FrameShift (FS-R-006 section 3).

  kgate.py reference  -- build the reference from STOCK images: extract every
      vendor module (vendor_boot ramdisks, boot ramdisk, vendor_dlkm,
      odm_dlkm, vendor /lib/modules), keep an inventory (source, path,
      sha256, size) of every copy, parse each .ko's __versions / .modinfo /
      .symtab / export sections, and derive the (symbol, CRC) pairs vmlinux
      must provide.  Output is deterministic so its sha256 can be pinned.

  kgate.py check      -- GATE a build (Module.symvers + vmlinux + kernel
      image + .config) against a pinned reference and REJECT on any deviation.
      Gate mode (default) REQUIRES every enforcement input; a missing input is
      an ERROR, never a silent skip.  --report-only relaxes that and can never
      return the PASS code.

Exit codes:
  0  PASS         -- gate mode, every check ran and passed
  1  FAIL         -- the build is rejected (a check found a deviation)
  2  ERROR        -- inputs missing/empty/unparseable, extraction failed,
                     reference incomplete/inconsistent/unpinned, inputs not
                     bound to one build, or an internal error; nothing concluded
  3  REPORT-ONLY  -- --report-only and no FAIL/ERROR: NOT A GATE PASS
ERROR takes precedence over FAIL.  Anything but 0 means "do not accept".

A PASS means: matches the checked symbol-version interfaces; complete module
compatibility and runtime behaviour remain open.  See README.md for what is
not checked (CFI, inline/config-dependent code, constants, struct layouts
beyond CRC coverage, runtime initialisation).

Only the Python standard library is used.  External tools: debugfs (ext4
images), lz4 (lz4 ramdisks/kernels), modprobe (cross-check of __versions
parsing; optional unless --require-modprobe).
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import mmap
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

TOOL_VERSION = "2.3"
REF_SCHEMA = "kgate-reference/3"
CHECK_SCHEMA = "kgate-check/3"
EXIT_PASS, EXIT_FAIL, EXIT_ERROR, EXIT_REPORT_ONLY = 0, 1, 2, 3
STATEMENT = ("matches the checked symbol-version interfaces; complete module "
             "compatibility and runtime behaviour remain open")
MAX_LIST = 20
MIN_WAIVER = 10
# Exceptions that indicate bad/unreadable input rather than a gate decision.
INPUT_EXC = (OSError, UnicodeError, struct.error, IndexError, ValueError, KeyError, TypeError,
             AttributeError, subprocess.SubprocessError, zlib.error, EOFError, OverflowError)


sys.dont_write_bytecode = True     # never leave __pycache__ in the tracked tree


def _load_scanner():
    # python3 -I drops the script directory from sys.path; load our sibling
    # module explicitly by absolute path.
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("kgate_btf_kind_scan", os.path.join(here, "btf_kind_scan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


btfscan = _load_scanner()


class GateError(Exception):
    """An ERROR condition: input/reference problem, nothing concluded."""


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError as e:
        raise GateError(f"cannot read {path}: {e}")
    return h.hexdigest()


def read_file(path, what):
    if not path:
        raise GateError(f"{what}: no path given")
    if not os.path.isfile(path):
        raise GateError(f"{what}: {path}: no such file")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        raise GateError(f"{what}: cannot read {path}: {e}")
    if not data:
        raise GateError(f"{what}: {path}: empty file")
    return data


def find_tool(name):
    p = shutil.which(name)
    if p:
        return p
    for d in ("/usr/sbin", "/sbin", "/usr/bin", "/bin"):
        c = os.path.join(d, name)
        if os.access(c, os.X_OK):
            return c
    return None


def run_tool(argv, what, **kw):
    try:
        return subprocess.run(argv, capture_output=True, **kw)
    except OSError as e:
        raise GateError(f"{what}: cannot run {argv[0]}: {e}")


# --------------------------------------------------------------------------
# Reporting

class Report:
    def __init__(self):
        self.checks = []

    def _add(self, status, cid, msg, items=None, **data):
        rec = {"id": cid, "status": status, "message": msg}
        if items is not None:
            rec["count"] = len(items)
            rec["items"] = items
        rec.update(data)
        self.checks.append(rec)
        print(f"{status} {cid}: {msg}")
        if items and status in ("FAIL", "ERROR", "WARN"):
            for it in items[:MAX_LIST]:
                print(f"   {status.lower()} {cid}: {it}")
            if len(items) > MAX_LIST:
                print(f"   ... {len(items) - MAX_LIST} more (see JSON)")

    def ok(self, cid, msg, **d):
        self._add("PASS", cid, msg, **d)

    def fail(self, cid, msg, items=None, **d):
        self._add("FAIL", cid, msg, items, **d)

    def error(self, cid, msg, items=None, **d):
        self._add("ERROR", cid, msg, items, **d)

    def warn(self, cid, msg, items=None, **d):
        self._add("WARN", cid, msg, items, **d)

    def info(self, cid, msg, **d):
        self._add("INFO", cid, msg, **d)

    def skip(self, cid, msg, **d):
        self._add("SKIP", cid, msg, **d)

    def exit_code(self, report_only=False):
        st = {c["status"] for c in self.checks}
        if "ERROR" in st:
            return EXIT_ERROR
        if "FAIL" in st:
            return EXIT_FAIL
        return EXIT_REPORT_ONLY if report_only else EXIT_PASS


RESULT_NAMES = {EXIT_PASS: "PASS", EXIT_FAIL: "FAIL", EXIT_ERROR: "ERROR", EXIT_REPORT_ONLY: "REPORT-ONLY"}


def finish(rep, out, json_path, what, report_only=False):
    rc = rep.exit_code(report_only)
    out["result"] = RESULT_NAMES[rc]
    out["exit_code"] = rc
    out["checks"] = rep.checks
    if what == "check":
        out["statement"] = STATEMENT if rc == EXIT_PASS else None
    if json_path:
        try:
            with open(json_path, "w") as fh:
                json.dump(out, fh, indent=1, sort_keys=True)
                fh.write("\n")
        except (OSError, TypeError, ValueError) as e:
            print(f"ERROR json: cannot write {json_path}: {e}")
            rc = EXIT_ERROR
    res = RESULT_NAMES[rc]
    if what == "check":
        waived = out.get("waivers") or {}
        wtxt = f" (waivers: {', '.join(sorted(waived))})" if waived and rc == EXIT_PASS else ""
        tail = {"PASS": f"build ACCEPTED{wtxt} -- {STATEMENT}",
                "FAIL": "build REJECTED",
                "ERROR": "gate could not conclude -- build NOT accepted",
                "REPORT-ONLY": "NOT A GATE PASS (report-only mode; enforcement inputs not all required) -- build NOT accepted"}[res]
    else:
        tail = {"PASS": "reference complete", "FAIL": "reference rejected",
                "ERROR": "reference NOT usable", "REPORT-ONLY": "BOOTSTRAP reference (unpinned) -- not usable for a gate until pinned in a profile"}[res]
    print(f"RESULT: {res} (exit {rc}) -- {tail}")
    return rc


# --------------------------------------------------------------------------
# ELF kernel-module parsing

ET_REL = 1
SHT_SYMTAB, SHT_STRTAB, SHT_NOBITS = 2, 3, 8
STB_WEAK = 2
STT_SECTION, STT_FILE = 3, 4
EXPORT_SEC = re.compile(r"^(__ksymtab|__ksymtab_gpl|__ksymtab_unused|__ksymtab_unused_gpl|__ksymtab_gpl_future)$")
EXPORT_PLUS = re.compile(r"^___ksymtab(_gpl|_unused|_unused_gpl|_gpl_future)?\+(.+)$")


def _cstr(buf, off, end, what):
    if off >= end or off < 0:
        raise GateError(f"{what}: string offset out of bounds")
    e = buf.find(b"\0", off, end)
    if e < 0:
        raise GateError(f"{what}: unterminated string")
    return buf[off:e].decode("utf-8", "surrogateescape")


def parse_ko(data, label):
    try:
        return _parse_ko(data, label)
    except (struct.error, IndexError, ValueError, OverflowError, UnicodeError) as e:
        raise GateError(f"{label}: malformed module ({type(e).__name__}: {e})")


def _parse_ko(data, label):
    """Parse a kernel module.  Returns dict with versions/exports/undefined/modinfo."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise GateError(f"{label}: not an ELF file")
    cls, enc = data[4], data[5]
    if enc != 1:
        raise GateError(f"{label}: big-endian ELF not supported")
    if cls == 2:
        e_type, e_machine = struct.unpack_from("<HH", data, 0x10)
        e_shoff, = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        shfmt, shsize = "<IIQQQQIIQQ", 64
        verent, crcsize = 64, 8
        symfmt, symsize = "<IBBHQQ", 24
    elif cls == 1:
        e_type, e_machine = struct.unpack_from("<HH", data, 0x10)
        e_shoff, = struct.unpack_from("<I", data, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x2E)
        shfmt, shsize = "<IIIIIIIIII", 40
        verent, crcsize = 64, 4
        symfmt, symsize = "<IIIBBH", 16
    else:
        raise GateError(f"{label}: bad ELF class {cls}")
    if e_type != ET_REL:
        raise GateError(f"{label}: ELF type {e_type} is not ET_REL (not a kernel module)")
    if e_shentsize != shsize or e_shnum == 0 or e_shoff + e_shnum * shsize > len(data) or e_shstrndx >= e_shnum:
        raise GateError(f"{label}: ELF section header table invalid or out of bounds")
    secs = []
    for i in range(e_shnum):
        f = struct.unpack_from(shfmt, data, e_shoff + i * shsize)
        name, stype, _flags, _addr, off, size, link, info, _align, entsize = f
        if stype != SHT_NOBITS and size and off + size > len(data):
            raise GateError(f"{label}: section {i} out of bounds")
        secs.append({"name_off": name, "type": stype, "off": off, "size": size, "link": link, "entsize": entsize})
    shs = secs[e_shstrndx]
    by_name = {}
    for s in secs:
        s["name"] = _cstr(data, shs["off"] + s["name_off"], shs["off"] + shs["size"], f"{label}: section name")
        by_name.setdefault(s["name"], []).append(s)
    for key in ("__versions", ".modinfo", ".symtab", "__ksymtab_strings"):
        if len(by_name.get(key, [])) > 1:
            raise GateError(f"{label}: duplicate {key} sections")
    # __versions (modversions)
    vs = by_name.get("__versions")
    if not vs:
        raise GateError(f"{label}: no __versions section (module built without modversions?)")
    vs = vs[0]
    if vs["size"] == 0 or vs["size"] % verent:
        raise GateError(f"{label}: __versions size {vs['size']} not a positive multiple of {verent}")
    versions = {}
    for p in range(vs["off"], vs["off"] + vs["size"], verent):
        crc = int.from_bytes(data[p:p + crcsize], "little")
        nm = data[p + crcsize:p + verent]
        z = nm.find(b"\0")
        if z <= 0 or not nm[:z].isascii():
            raise GateError(f"{label}: malformed __versions entry at 0x{p:x}")
        sym = nm[:z].decode("ascii")
        if crc > 0xFFFFFFFF:
            raise GateError(f"{label}: __versions CRC for {sym} exceeds 32 bits (0x{crc:x})")
        if sym in versions and versions[sym] != crc:
            raise GateError(f"{label}: __versions lists {sym} twice with different CRCs")
        versions[sym] = crc
    if "module_layout" not in versions:
        raise GateError(f"{label}: __versions has no module_layout entry")
    # .modinfo
    mi = by_name.get(".modinfo")
    if not mi:
        raise GateError(f"{label}: no .modinfo section")
    mi = mi[0]
    modinfo = {}
    for ent in data[mi["off"]:mi["off"] + mi["size"]].split(b"\0"):
        if not ent:
            continue
        k, sep, v = ent.decode("utf-8", "surrogateescape").partition("=")
        if not sep:
            raise GateError(f"{label}: malformed .modinfo entry {ent[:40]!r}")
        modinfo.setdefault(k, []).append(v)
    vm = modinfo.get("vermagic", [])
    if len(vm) != 1:
        raise GateError(f"{label}: expected exactly one vermagic in .modinfo, found {len(vm)}")
    vmt = vm[0].split()
    if len(vmt) < 2 or "modversions" not in vmt[1:]:
        raise GateError(f"{label}: vermagic {vm[0]!r} malformed or lacks 'modversions' (CRC comparison would be meaningless)")
    # .symtab
    st = by_name.get(".symtab")
    if not st:
        raise GateError(f"{label}: no .symtab section")
    st = st[0]
    if st["type"] != SHT_SYMTAB or st["size"] % symsize or st["link"] >= len(secs):
        raise GateError(f"{label}: invalid .symtab")
    strtab = secs[st["link"]]
    if strtab["type"] != SHT_STRTAB:
        raise GateError(f"{label}: .symtab link is not a string table")
    s0, s1 = strtab["off"], strtab["off"] + strtab["size"]
    exports, undefined, weak_undef = set(), set(), set()
    for p in range(st["off"] + symsize, st["off"] + st["size"], symsize):
        if cls == 2:
            name, info, _other, shndx, _val, _sz = struct.unpack_from(symfmt, data, p)
        else:
            name, _val, _sz, info, _other, shndx = struct.unpack_from(symfmt, data, p)
        if name == 0:
            continue
        sname = _cstr(data, s0 + name, s1, f"{label}: symbol name")
        bind, stype = info >> 4, info & 0xF
        if shndx == 0:
            (weak_undef if bind == STB_WEAK else undefined).add(sname)
        elif sname.startswith("__ksymtab_") and stype not in (STT_SECTION, STT_FILE) and len(sname) > 10:
            exports.add(sname[10:])
    # exports also recoverable from per-symbol sections (___ksymtab+sym), which
    # survive --strip-unneeded; and every name in __ksymtab_strings must be accounted for
    export_bytes = 0
    for s in secs:
        if EXPORT_SEC.match(s["name"]):
            export_bytes += s["size"]
        m = EXPORT_PLUS.match(s["name"])
        if m:
            export_bytes += s["size"]
            exports.add(m.group(2))
    if export_bytes and not exports:
        raise GateError(f"{label}: module has {export_bytes} bytes of export tables but no export names could be recovered")
    kst = by_name.get("__ksymtab_strings")
    if kst:
        kst = kst[0]
        names = {x.decode("utf-8", "surrogateescape") for x in data[kst["off"]:kst["off"] + kst["size"]].split(b"\0") if x}
        lost = sorted(names - exports)
        if lost:
            raise GateError(f"{label}: __ksymtab_strings names not recovered as exports (stripped symbols or namespaces?): {lost[:5]}")
    return {
        "machine": e_machine,
        "versions": versions,
        "exports": sorted(exports),
        "undefined": sorted(undefined),
        "weak_undefined": sorted(weak_undef),
        "vermagic": vm[0],
        "modname": (modinfo.get("name") or [""])[0],
        "license": (modinfo.get("license") or [""])[0],
        "import_ns": sorted(set(modinfo.get("import_ns", []))),
    }


def modprobe_versions(modprobe, path):
    r = run_tool([modprobe, "--dump-modversions", path], "modprobe")
    if r.returncode != 0:
        raise GateError(f"modprobe --dump-modversions {path} failed (rc={r.returncode}): {r.stderr.decode(errors='replace').strip()[:200]}")
    out = {}
    for line in r.stdout.decode("ascii", "replace").splitlines():
        m = re.fullmatch(r"0x([0-9a-fA-F]+)\t(\S+)", line)
        if not m:
            raise GateError(f"modprobe --dump-modversions {path}: unparseable line {line!r}")
        out[m.group(2)] = int(m.group(1), 16)
    return out


# --------------------------------------------------------------------------
# Container parsing: boot/vendor_boot images, ramdisks, cpio, ext4, dirs

COMPRESSED_KO = re.compile(r"\.ko\.(gz|xz|zst|lz4|bz2)$")


def _lz4(data, what):
    try:
        return btfscan._lz4_decompress(data, what)
    except btfscan.ScanError as e:
        raise GateError(str(e))


def decompress_ramdisk(data, what):
    if data[:6] in (b"070701", b"070702"):
        return data, "none"
    if data[:2] == b"\x1f\x8b":
        try:
            return btfscan.gunzip_capped(data, what, multi=True), "gzip"
        except btfscan.ScanError as e:
            raise GateError(str(e))
    if data[:4] in (b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18"):
        return _lz4(data, what), "lz4"
    raise GateError(f"{what}: unknown ramdisk compression (magic {data[:4].hex()})")


def _in_modules_tree(path):
    return "/lib/modules/" in path or path.endswith("/lib/modules")


def parse_cpio(data, what):
    """Parse (possibly concatenated) newc cpio archives.

    Returns a list of (path, bytes) for regular files; a path that occurs more
    than once (e.g. in two concatenated archives) is kept every time, suffixed
    '#2', '#3', ... so later copies never silently replace earlier ones."""
    files, seen, p, archives = [], {}, 0, 0
    pending_links = {}
    while p < len(data):
        if data[p:p + 6] not in (b"070701", b"070702"):
            if not any(data[p:]):
                break               # trailing zero padding
            raise GateError(f"{what}: bad cpio magic at offset 0x{p:x}")
        if p + 110 > len(data):
            raise GateError(f"{what}: truncated cpio header at 0x{p:x}")
        try:
            fld = [int(data[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
        except ValueError:
            raise GateError(f"{what}: non-hex cpio header field at 0x{p:x}")
        ino, mode, _uid, _gid, nlink, _mtime, fsize, dmaj, dmin = fld[:9]
        namesize = fld[11]
        if namesize == 0:
            raise GateError(f"{what}: zero cpio namesize at 0x{p:x}")
        n0 = p + 110
        n1 = n0 + namesize
        if n1 > len(data) or data[n1 - 1] != 0:
            raise GateError(f"{what}: cpio name truncated/unterminated at 0x{p:x}")
        name = data[n0:n1 - 1].decode("utf-8", "surrogateescape")
        d0 = (n1 + 3) & ~3
        d1 = d0 + fsize
        if d1 > len(data):
            raise GateError(f"{what}: cpio file data for {name!r} truncated")
        if name == "TRAILER!!!":
            archives += 1
            if pending_links:
                raise GateError(f"{what}: unresolved cpio hard links {sorted(pending_links)[:5]}")
            p = (d1 + 3) & ~3
            continue
        path = "/" + re.sub(r"^(\./)+", "", name).lstrip("/")
        ftype = mode & 0o170000
        if ftype == 0o120000:
            if path.endswith(".ko") or _in_modules_tree(path):
                raise GateError(f"{what}: symlink {path} inside a module tree (not followed)")
        elif ftype == 0o100000:
            n = seen.get(path, 0) + 1
            seen[path] = n
            label = path if n == 1 else f"{path}#{n}"
            key = (dmaj, dmin, ino)
            if fsize == 0 and nlink > 1:
                pending_links.setdefault(key, []).append(label)
            else:
                files.append((label, data[d0:d1]))
                for lp in pending_links.pop(key, []):
                    files.append((lp, data[d0:d1]))
        p = (d1 + 3) & ~3
    if archives == 0:
        raise GateError(f"{what}: no cpio TRAILER found (truncated archive)")
    return files


LIST_RE = re.compile(r"^modules\.(load(\.[A-Za-z0-9_]+)?|dep)$")


def _lists_from_files(files):
    return [(p, b) for p, b in files if LIST_RE.match(re.sub(r"#\d+$", "", p).rsplit("/", 1)[-1])]


def _ko_from_files(files, what):
    out = []
    for path, blob in files:
        base = re.sub(r"#\d+$", "", path)
        if COMPRESSED_KO.search(base):
            raise GateError(f"{what}: compressed module {path} not supported")
        if base.endswith(".ko"):
            out.append((path, blob))
    return out


def read_vendor_boot(path, label):
    buf = read_file(path, f"source {label}")
    if len(buf) < 2128 or buf[:8] != b"VNDRBOOT":
        raise GateError(f"source {label}: {path}: not a vendor_boot image (bad magic)")
    hv, page, _ka, _ra, vrd_size = struct.unpack_from("<IIIII", buf, 8)
    header_size, dtb_size = struct.unpack_from("<II", buf, 2096)
    if hv not in (3, 4):
        raise GateError(f"source {label}: unsupported vendor_boot header version {hv}")
    if page not in (2048, 4096, 8192, 16384):
        raise GateError(f"source {label}: implausible page size {page}")
    rnd = lambda n: (n + page - 1) // page * page
    exp_hdr = 2112 if hv == 3 else 2128
    if header_size != exp_hdr:
        raise GateError(f"source {label}: header_size {header_size} != {exp_hdr} for v{hv}")
    rd0 = rnd(header_size)
    if vrd_size == 0 or rd0 + vrd_size > len(buf):
        raise GateError(f"source {label}: vendor ramdisk section (size {vrd_size}) out of bounds")
    section = buf[rd0:rd0 + vrd_size]
    ramdisks = []
    if hv == 3:
        ramdisks.append(("ramdisk", section))
    else:
        tsize, tnum, tent, _bc = struct.unpack_from("<IIII", buf, 2112)
        if tent != 108 or tnum == 0 or tsize != tnum * tent:
            raise GateError(f"source {label}: invalid vendor ramdisk table (size {tsize}, entries {tnum}, entry_size {tent})")
        t0 = rd0 + rnd(vrd_size) + rnd(dtb_size)
        if t0 + tsize > len(buf):
            raise GateError(f"source {label}: vendor ramdisk table out of bounds")
        ents = []
        for i in range(tnum):
            sz, off, typ = struct.unpack_from("<III", buf, t0 + i * tent)
            nm = buf[t0 + i * tent + 12:t0 + i * tent + 44].split(b"\0")[0].decode("ascii", "replace")
            ents.append((off, sz, typ, nm or f"ramdisk{i:02d}"))
        cur = 0
        for off, sz, typ, nm in sorted(ents):
            if off != cur or sz == 0:
                raise GateError(f"source {label}: ramdisk table entries do not tile the ramdisk section (entry {nm!r} at {off}, expected {cur})")
            cur = off + sz
            ramdisks.append((f"{nm}(type{typ})", section[off:off + sz]))
        if cur != vrd_size:
            raise GateError(f"source {label}: ramdisk table covers {cur} of {vrd_size} bytes")
    mods, lists, detail = [], [], []
    for rname, rdata in ramdisks:
        what = f"source {label} {rname}"
        raw, comp = decompress_ramdisk(rdata, what)
        files = parse_cpio(raw, what)
        kos = _ko_from_files(files, what)
        detail.append(f"{rname}: {comp}, {len(files)} files, {len(kos)} .ko")
        for p, b in kos:
            mods.append((f"{rname}:{p}", b))
        for p, b in _lists_from_files(files):
            lists.append((f"{rname}:{p}", b))
    return mods, lists, f"vendor_boot v{hv}; " + "; ".join(detail)


def read_boot_ramdisk(path, label):
    buf = read_file(path, f"source {label}")
    if len(buf) < 1648 or buf[:8] != b"ANDROID!":
        raise GateError(f"source {label}: {path}: not an Android boot image (bad magic)")
    kernel_size, = struct.unpack_from("<I", buf, 8)
    hv, = struct.unpack_from("<I", buf, 40)
    if hv > 4:
        raise GateError(f"source {label}: unsupported boot header version {hv}")
    if hv >= 3:
        page = 4096
        rd_size, = struct.unpack_from("<I", buf, 12)
    else:
        page, = struct.unpack_from("<I", buf, 36)
        rd_size, = struct.unpack_from("<I", buf, 16)
        if page not in (2048, 4096, 8192, 16384):
            raise GateError(f"source {label}: implausible page size {page}")
    rnd = lambda n: (n + page - 1) // page * page
    rd0 = page + rnd(kernel_size)
    if rd_size == 0:
        return [], [], f"boot v{hv}: no ramdisk"
    if rd0 + rd_size > len(buf):
        raise GateError(f"source {label}: boot ramdisk out of bounds")
    what = f"source {label} ramdisk"
    raw, comp = decompress_ramdisk(buf[rd0:rd0 + rd_size], what)
    files = parse_cpio(raw, what)
    kos = _ko_from_files(files, what)
    return ([(f"ramdisk:{p}", b) for p, b in kos], [(f"ramdisk:{p}", b) for p, b in _lists_from_files(files)],
            f"boot v{hv}; ramdisk {comp}, {len(files)} files, {len(kos)} .ko")


class Debugfs:
    BANNER = re.compile(r"^debugfs \d+\.\d+")

    def __init__(self, img, label):
        self.img, self.label = img, label
        self.exe = find_tool("debugfs")
        if not self.exe:
            raise GateError(f"source {label}: debugfs not found (needed for ext4 images)")

    def run(self, cmds, tmp):
        cf = os.path.join(tmp, "debugfs.cmd")
        try:
            with open(cf, "w", encoding="utf-8", errors="surrogateescape") as fh:
                for c in cmds:
                    fh.write(c + "\n")
        except OSError as e:
            raise GateError(f"source {self.label}: cannot write debugfs command file: {e}")
        r = run_tool([self.exe, "-f", cf, self.img], f"source {self.label}")
        errs = [l for l in r.stderr.decode(errors="replace").splitlines() if l.strip() and not self.BANNER.match(l)]
        if r.returncode != 0 or errs:
            raise GateError(f"source {self.label}: debugfs failed (rc={r.returncode}): {'; '.join(errs[:5])}")
        return r.stdout.decode("utf-8", "surrogateescape")


def _dq(path):
    if '"' in path or "\n" in path:
        raise GateError(f"unsupported character in path {path!r}")
    return f'"{path}"'


def _norm(p):
    return "/" + "/".join(x for x in p.split("/") if x)


def read_ext4(path, label, root, tmp):
    if not os.path.isfile(path):
        raise GateError(f"source {label}: {path}: no such file")
    try:
        with open(path, "rb") as fh:
            hdr = fh.read(4096)
    except OSError as e:
        raise GateError(f"source {label}: cannot read {path}: {e}")
    if not hdr:
        raise GateError(f"source {label}: {path}: empty file")
    if hdr[:4] == b"\x3a\xff\x26\xed":
        raise GateError(f"source {label}: {path} is an Android sparse image (convert with simg2img first)")
    if len(hdr) >= 1028 and hdr[1024:1028] == b"\xe2\xe1\xf5\xe0":
        raise GateError(f"source {label}: {path} is EROFS (not supported by this tool)")
    if len(hdr) < 1082 or hdr[1080:1082] != b"\x53\xef":
        raise GateError(f"source {label}: {path} is not an ext2/3/4 image (no superblock magic)")
    dfs = Debugfs(path, label)
    st = dfs.run([f"stat {_dq(root)}"], tmp)
    m = re.search(r"Type:\s+(\w+)", st)
    if not m:
        raise GateError(f"source {label}: {root} not found in image (debugfs stat gave no inode)")
    if m.group(1) == "symlink":
        t = re.search(r'Fast link dest:\s+"(.*)"', st)
        if not t:
            raise GateError(f"source {label}: {root} is a symlink whose target could not be read")
        return [], [], {"redirect": t.group(1)}
    if m.group(1) != "directory":
        raise GateError(f"source {label}: {root} is a {m.group(1)}, not a directory")
    files, stack = [], [root.rstrip("/") or "/"]
    while stack:
        d = stack.pop()
        out = dfs.run([f"ls -p {_dq(d)}"], tmp)
        n = 0
        for line in out.splitlines():
            if not line.startswith("/"):
                continue
            parts = line.split("/")
            if len(parts) != 8:
                raise GateError(f"source {label}: unparseable debugfs ls line {line!r}")
            _, _ino, mode, _uid, _gid, name, size, _ = parts
            n += 1
            if name in (".", ".."):
                continue
            full = (d.rstrip("/") + "/" + name)
            if mode.startswith("04"):
                stack.append(full)
            elif mode.startswith("10"):
                if not size.isdigit():
                    raise GateError(f"source {label}: bad size in debugfs ls line {line!r}")
                files.append((full, int(size)))
            elif mode.startswith("12"):
                raise GateError(f"source {label}: symlink {full} inside the module tree (not followed)")
            if COMPRESSED_KO.search(name):
                raise GateError(f"source {label}: compressed module {full} not supported")
        if n == 0:
            raise GateError(f"source {label}: debugfs listing of {d} returned nothing")
    want = [(p, s) for p, s in files if p.endswith(".ko") or LIST_RE.match(p.rsplit("/", 1)[-1])]
    dumpdir = os.path.join(tmp, "dump")
    os.makedirs(dumpdir, exist_ok=True)
    cmds = [f"dump {_dq(p)} {_dq(os.path.join(dumpdir, str(i)))}" for i, (p, _s) in enumerate(want)]
    if cmds:
        dfs.run(cmds, tmp)
    mods, lists = [], []
    for i, (p, s) in enumerate(want):
        f = os.path.join(dumpdir, str(i))
        if not os.path.isfile(f) or os.path.getsize(f) != s:
            raise GateError(f"source {label}: extraction of {p} failed or incomplete (expected {s} bytes, got "
                            f"{os.path.getsize(f) if os.path.isfile(f) else 'nothing'})")
        with open(f, "rb") as fh:
            (mods if p.endswith(".ko") else lists).append((p, fh.read()))
        os.unlink(f)
    return mods, lists, {"files_listed": len(files)}


def read_dir(path, label):
    """Walk a pre-extracted tree.  Symlinks (files or directories) are an ERROR:
    they are not followed, so nothing behind them can be silently missed."""
    if not os.path.isdir(path):
        raise GateError(f"source {label}: {path}: not a directory")
    if os.path.islink(path):
        raise GateError(f"source {label}: {path}: the source directory itself is a symlink")

    def onerror(e):
        raise GateError(f"source {label}: cannot walk {getattr(e, 'filename', path)}: {e}")
    mods, lists = [], []
    for dp, dns, fns in os.walk(path, onerror=onerror, followlinks=False):
        dns.sort()
        for dn in dns:
            if os.path.islink(os.path.join(dp, dn)):
                raise GateError(f"source {label}: directory symlink {os.path.join(dp, dn)} (not followed)")
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            if os.path.islink(full):
                raise GateError(f"source {label}: symlink {full} (not followed)")
            if COMPRESSED_KO.search(fn):
                raise GateError(f"source {label}: compressed module {full} not supported")
            if fn.endswith(".ko") or LIST_RE.match(fn):
                try:
                    with open(full, "rb") as fh:
                        (mods if fn.endswith(".ko") else lists).append(("/" + os.path.relpath(full, path).replace(os.sep, "/"), fh.read()))
                except OSError as e:
                    raise GateError(f"source {label}: cannot read {full}: {e}")
    return mods, lists


def _split_label(spec, opt):
    if "=" not in spec:
        raise GateError(f"{opt} expects LABEL=PATH, got {spec!r}")
    label, path = spec.split("=", 1)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", label):
        raise GateError(f"{opt}: bad label {label!r}")
    return label, path


# --------------------------------------------------------------------------
# Derivation shared by `reference` (creation) and `check` (re-verification)

def body_hash(body):
    return sha256_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())


def derive_all(modules, inventory):
    """Derive every reference field that is a function of the module records
    and the inventory.  Raises GateError on internal inconsistency."""
    byid = {m["id"]: m for m in modules}
    imports, vexp, undef, importers = {}, {}, set(), {}
    for m in modules:
        mid = m["id"]
        for s, c in m["versions"].items():
            imports.setdefault(s, {}).setdefault(c, []).append(mid)
            importers.setdefault(s, []).append(mid)
        for s in m["exports"]:
            vexp.setdefault(s, []).append(mid)
        undef.update(m["undefined"])
        for s in m["undefined"]:
            if s not in m["versions"]:
                importers.setdefault(s, []).append(mid)
    conflicts = {s: {f"0x{c:08x}": sorted(byid[x]["name"] for x in v) for c, v in cs.items()} for s, cs in imports.items() if len(cs) > 1}
    required = {s: next(iter(cs)) for s, cs in imports.items() if s not in vexp and len(cs) == 1}
    presence = sorted(s for s in undef if s not in vexp and s not in imports)
    by_name = {}
    for o in inventory:
        by_name.setdefault(o["name"], {}).setdefault(o["sha256"], []).append(f"{o['source']}:{o['path']}")
    differing = {n: {h: sorted(p) for h, p in v.items()} for n, v in sorted(by_name.items()) if len(v) > 1}
    by_modname = {}
    for m in modules:
        by_modname.setdefault(m["modname"] or m["name"][:-3], {})[m["id"]] = m["name"]
    modname_coll = {n: sorted(set(v.values())) for n, v in sorted(by_modname.items()) if len(v) > 1}
    vtails = sorted({m["vermagic"].split(" ", 1)[1] for m in modules})
    machines = sorted({m["machine"] for m in modules})
    inv_ids = {o["sha256"] for o in inventory}
    if inv_ids != set(byid):
        raise GateError("reference: inventory and module records disagree on the module set")
    for m in modules:
        occ = sorted(f"{o['source']}:{o['path']}" for o in inventory if o["sha256"] == m["id"])
        if sorted(m["occurrences"]) != occ:
            raise GateError(f"reference: occurrences of {m['name']} disagree with the inventory")
    return {
        "conflicts": conflicts,
        "required": {s: f"0x{c:08x}" for s, c in sorted(required.items())},
        "presence_required": presence,
        "vendor_exports": {s: sorted({byid[x]["name"] for x in v}) for s, v in sorted(vexp.items())},
        "module_layout": f"0x{required['module_layout']:08x}" if "module_layout" in required else None,
        "vermagic_flags": vtails[0] if len(vtails) == 1 else None,
        "vermagic_flags_all": vtails,
        "vermagic_releases": sorted({m["vermagic"].split(" ", 1)[0] for m in modules}),
        "elf_machine": machines[0] if len(machines) == 1 else None,
        "elf_machines_all": machines,
        "same_name_differing": differing,
        "modname_collisions": modname_coll,
        "counts": {
            "module_copies": len(inventory),
            "unique_modules": len(modules),
            "imported_pairs": sum(len(m["versions"]) for m in modules),
            "unique_imported_pairs": len({(s, c) for m in modules for s, c in m["versions"].items()}),
            "vendor_exported_symbols": len(vexp),
            "required_from_vmlinux": len(required),
            "presence_required_unversioned": len(presence),
        },
        "_importers": importers,
    }


STORED_DERIVED = ("required", "presence_required", "vendor_exports", "module_layout", "vermagic_flags",
                  "vermagic_releases", "elf_machine", "same_name_differing", "modname_collisions", "counts")


PROFILE_COUNTS = ("required_from_vmlinux", "unique_modules", "module_copies")


def load_profile(path, device):
    """Per-device profile: declared sources, pinned counts, pinned reference sha256."""
    try:
        pr = json.loads(read_file(path, "profile"))
    except ValueError as e:
        raise GateError(f"profile {path}: invalid JSON: {e}")
    if not isinstance(pr, dict) or not isinstance(pr.get("device"), str) or not isinstance(pr.get("sources"), dict)             or not all(isinstance(k, str) and v in ("vendor_boot", "boot", "ext4", "dir") for k, v in pr["sources"].items())             or not isinstance(pr.get("counts"), dict) or not all(isinstance(pr["counts"].get(k), int) for k in PROFILE_COUNTS)             or not all(isinstance(v, int) for v in pr["counts"].values())             or ("reference_sha256" in pr and not (isinstance(pr["reference_sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", pr["reference_sha256"]))) \
            or ("build_sections" in pr and not (isinstance(pr["build_sections"], list) and all(isinstance(x, str) for x in pr["build_sections"]))):
        raise GateError(f"profile {path}: malformed (needs device, sources{{label: kind}}, counts with {', '.join(PROFILE_COUNTS)}, optional reference_sha256)")
    hexok = lambda x: isinstance(x, str) and re.fullmatch(r"[0-9a-f]{64}", x) is not None
    if "stock_build_symvers_sha256" in pr and not hexok(pr["stock_build_symvers_sha256"]):
        raise GateError(f"profile {path}: stock_build_symvers_sha256 malformed")
    for bn, be in (pr.get("builds") or {}).items():
        if not isinstance(be, dict) or not hexok(be.get("requested_sha256")) or be.get("baseline") not in ("waived", "stock-build") \
                or not (be.get("allow_sha256") is None or hexok(be.get("allow_sha256"))):
            raise GateError(f"profile {path}: build {bn!r} malformed (needs requested_sha256, allow_sha256|null, baseline waived|stock-build)")
        if be["baseline"] == "stock-build" and not pr.get("stock_build_symvers_sha256"):
            raise GateError(f"profile {path}: build {bn!r} needs stock_build_symvers_sha256")
    if "stock_kernel" in pr:
        if not isinstance(pr["stock_kernel"], str):
            raise GateError(f"profile {path}: stock_kernel must be a path relative to the profile file")
        pr["_stock_kernel_abs"] = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), pr["stock_kernel"]))
    pr["_path"] = os.path.abspath(path)
    if pr["device"] != device:
        raise GateError(f"profile {path} is for device {pr['device']!r}, not --device {device!r}")
    return pr


# --------------------------------------------------------------------------
# reference subcommand

def cmd_reference(a):
    rep = Report()
    out = {"schema": REF_SCHEMA + "-summary", "tool_version": TOOL_VERSION}
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix="kgate-ref-")
        _reference(a, rep, out, tmp)
    except GateError as e:
        rep.error("reference", str(e))
    except INPUT_EXC as e:
        rep.error("reference", f"unexpected input/IO error ({type(e).__name__}: {e})")
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    return finish(rep, out, a.json, "reference", report_only=bool(getattr(a, "bootstrap", False)))


def _reference(a, rep, out, tmp):
    specs = []
    for p in a.vendor_boot or []:
        specs.append(("vendor_boot", *(_split_label(p, "--vendor-boot") if "=" in p else ("vendor_boot", p))))
    for p in a.boot or []:
        specs.append(("boot", *(_split_label(p, "--boot") if "=" in p else ("boot", p))))
    for p in a.ext4 or []:
        specs.append(("ext4", *_split_label(p, "--ext4")))
    for p in a.dir or []:
        specs.append(("dir", *_split_label(p, "--dir")))
    if not specs:
        raise GateError("no module sources given")
    if not a.stock_kernel:
        raise GateError("--stock-kernel is required (allowed BTF kinds come from the stock kernel)")
    labels = [s[1] for s in specs]
    if len(set(labels)) != len(labels):
        raise GateError(f"duplicate source labels: {labels}")
    profile = load_profile(a.profile, a.device) if a.profile else None
    if profile is None and not a.bootstrap:
        raise GateError("--profile is required (declared sources and pinned counts); use --bootstrap to produce a first, unpinned reference")
    if profile is not None:
        decl = {label: kind for kind, label, _p in specs}
        if decl != profile["sources"]:
            raise GateError(f"sources {decl} differ from the profile's declared sources {profile['sources']}")
    sources, occ, lists = [], [], []
    for kind, label, path in specs:
        src = {"label": label, "kind": kind, "file": os.path.basename(os.path.normpath(path))}   # identity is the sha256, not the location
        if kind == "dir":
            src["sha256"] = None
            mods, lst = read_dir(path, label)
            src["detail"] = "pre-extracted directory (no image hash available)"
        else:
            if not os.path.isfile(path):
                raise GateError(f"source {label}: {path}: no such file")
            src["sha256"] = sha256_file(path)
            src["size"] = os.path.getsize(path)
            if kind == "vendor_boot":
                mods, lst, src["detail"] = read_vendor_boot(path, label)
            elif kind == "boot":
                mods, lst, src["detail"] = read_boot_ramdisk(path, label)
            else:
                sub = os.path.join(tmp, label)
                os.makedirs(sub)
                mods, lst, info = read_ext4(path, label, a.modules_path, sub)
                src["modules_root"] = _norm(a.modules_path)
                if "redirect" in info:
                    src["redirect"] = info["redirect"]
                src["detail"] = f"ext4 {a.modules_path}: " + (f"symlink -> {info['redirect']}" if "redirect" in info else f"{info['files_listed']} files listed")
        src["modules"] = len(mods)
        src["module_lists"] = sorted(p for p, _b in lst)
        lists += [(label, p, b) for p, b in lst]
        sources.append(src)
        for p, blob in mods:
            occ.append({"source": label, "path": p, "name": re.sub(r"#\d+$", "", p).rsplit("/", 1)[-1],
                        "sha256": sha256_bytes(blob), "size": len(blob), "_blob": blob})
        print(f"INFO source {label} ({kind}): {src['modules']} modules; {src['detail']}")
    # per-source completeness and redirect coverage
    bylabel = {s["label"]: s for s in sources}
    for s in sources:
        if s["modules"] == 0:
            if s.get("redirect"):
                tgt = _norm(s["redirect"])
                part, _, rest = tgt.strip("/").partition("/")
                cov = bylabel.get(part)
                if cov is None:
                    raise GateError(f"source {s['label']}: {a.modules_path} redirects to {s['redirect']}, but no source labelled {part!r} was given")
                if cov["kind"] != "ext4" or cov.get("modules_root") != _norm("/" + rest) or cov["modules"] == 0 or cov.get("redirect"):
                    raise GateError(f"source {s['label']}: redirect target {s['redirect']} is not covered: source {part!r} "
                                    f"({cov['kind']}) was read at {cov.get('modules_root', '-')} with {cov['modules']} modules")
                rep.info("source-redirect", f"{s['label']}: {a.modules_path} -> {s['redirect']} (covered by source {part!r} at {cov['modules_root']})")
            elif s["kind"] == "boot":
                rep.info("source-empty", f"{s['label']}: generic boot ramdisk has no modules (allowed for boot sources)")
            else:
                raise GateError(f"source {s['label']} ({s['kind']}) yielded zero modules")
    if not occ:
        raise GateError("empty reference: zero modules extracted from all sources")
    # every module named by a modules.load*/modules.dep file must be in the inventory
    have = {o["name"] for o in occ}
    absent, nlisted = [], 0
    for label, p, b in lists:
        for n, line in enumerate(b.decode("utf-8", "replace").splitlines(), 1):
            toks = line.replace(":", " ").split()
            for t in toks:
                if not t.endswith(".ko"):
                    raise GateError(f"source {label}: {p}:{n}: unparseable module list entry {t!r}")
                nlisted += 1
                if t.rsplit("/", 1)[-1] not in have:
                    absent.append(f"{label}:{p}:{n}: {t}")
    if absent:
        raise GateError(f"{len(absent)} module(s) named in modules.load/modules.dep are absent from the extracted inventory: {absent[:8]}")
    if lists:
        rep.ok("module-lists", f"all {nlisted} module references in {len(lists)} modules.load*/modules.dep file(s) are present in the inventory")
    else:
        rep.warn("module-lists", "no modules.load/modules.dep files found in any source; completeness rests on the declared sources only")
    # the stock kernel (allowed BTF kinds) must be the kernel of a supplied stock boot image
    sk_sha = sha256_file(a.stock_kernel)
    if not any(s["kind"] == "boot" and s["sha256"] == sk_sha for s in sources):
        raise GateError(f"--stock-kernel {a.stock_kernel} is not one of the supplied --boot source images (sha256 {sk_sha[:16]}...)")
    # parse each unique content
    modprobe = find_tool("modprobe")
    if not modprobe and a.require_modprobe:
        raise GateError("--require-modprobe given but modprobe not found")
    uniq = {}
    for o in occ:
        if o["sha256"] in uniq:
            continue
        lbl = f"{o['source']}:{o['path']}"
        info = parse_ko(o["_blob"], lbl)
        if modprobe:
            f = os.path.join(tmp, o["sha256"] + ".ko")
            with open(f, "wb") as fh:
                fh.write(o["_blob"])
            mv = modprobe_versions(modprobe, f)
            os.unlink(f)
            if mv != info["versions"]:
                raise GateError(f"{lbl}: __versions parse disagrees with modprobe --dump-modversions")
        info["id"] = o["sha256"]
        info["name"] = o["name"]
        info["occurrences"] = []
        uniq[o["sha256"]] = info
    for o in occ:
        uniq[o["sha256"]]["occurrences"].append(f"{o['source']}:{o['path']}")
        del o["_blob"]
    for m in uniq.values():
        m["occurrences"].sort()
    if modprobe:
        rep.ok("modprobe-crosscheck", f"__versions of {len(uniq)} unique modules agree with modprobe --dump-modversions")
    else:
        rep.warn("modprobe-crosscheck", "modprobe not found; __versions parsing not cross-checked")
    modules = sorted(uniq.values(), key=lambda m: (m["name"], m["id"]))
    inventory = sorted(occ, key=lambda o: (o["name"], o["source"], o["path"]))
    d = derive_all(modules, inventory)
    stop = False
    if d["same_name_differing"]:
        items = [f"{n}: " + " | ".join(f"{h[:16]}={','.join(ps)}" for h, ps in v.items()) for n, v in d["same_name_differing"].items()]
        if a.allow_same_name_differing:
            rep.warn("same-name-differing", f"{len(items)} module file name(s) with differing content; ALL copies used (--allow-same-name-differing)", items)
        else:
            rep.error("same-name-differing", f"{len(items)} module file name(s) with differing content (use --allow-same-name-differing to require all copies)", items)
            stop = True
    if d["modname_collisions"]:
        items = [f"modinfo name {n!r}: {', '.join(v)}" for n, v in d["modname_collisions"].items()]
        if a.allow_same_name_differing:
            rep.warn("modname-collision", f"{len(items)} module name(s) (.modinfo name) shared by differing modules; the kernel loads only one -- ALL copies used", items)
        else:
            rep.error("modname-collision", f"{len(items)} module name(s) (.modinfo name) shared by differing modules; the kernel can load only one of each", items)
            stop = True
    if stop:
        return
    rep.info("same-name-identical", f"{sum(1 for n in {o['name'] for o in occ} if sum(1 for o in occ if o['name'] == n) > 1)} module name(s) present more than once with identical content (deduplicated, all paths kept in inventory)")
    if len(d["elf_machines_all"]) != 1:
        raise GateError(f"modules for mixed ELF machines {d['elf_machines_all']}")
    if len(d["vermagic_flags_all"]) != 1:
        raise GateError(f"modules disagree on vermagic flags: {d['vermagic_flags_all']}")
    if d["conflicts"]:
        items = [f"{s}: " + "; ".join(f"{c} <- {', '.join(v[:3])}" for c, v in cs.items()) for s, cs in sorted(d["conflicts"].items())]
        rep.error("import-crc-conflict", f"{len(items)} symbol(s) imported with conflicting CRCs", items)
        return
    rep.ok("import-crc-conflict", "no symbol is imported with conflicting CRCs")
    if d["module_layout"] is None:
        raise GateError("reference incomplete: module_layout not among the vmlinux-required symbols")
    multi = {s: v for s, v in d["vendor_exports"].items() if len(v) > 1}
    if multi:
        rep.warn("vendor-export-duplicate", f"{len(multi)} symbol(s) exported by more than one vendor module (cannot be loaded together)",
                 [f"{s}: {', '.join(v)}" for s, v in sorted(multi.items())])
    try:
        r = btfscan.scan_file(a.stock_kernel)
        stock_btf = {"file": os.path.basename(a.stock_kernel), "sha256": sha256_file(a.stock_kernel), "kinds": r["kinds"], "types": r["types"], "blob_sha256": r["blob_sha256"]}
        rep.ok("stock-btf", f"stock kernel kinds: {', '.join(sorted(r['kinds']))} ({r['types']} types)")
    except btfscan.MissingBTF as e:
        if not a.allow_no_stock_btf:
            raise GateError(f"stock kernel {a.stock_kernel}: {e} (use --allow-no-stock-btf to record an empty kind set)")
        stock_btf = {"file": os.path.basename(a.stock_kernel), "sha256": sha256_file(a.stock_kernel), "kinds": {}, "types": 0, "blob_sha256": None}
        rep.warn("stock-btf", "stock kernel has no BTF; allowed kind set is EMPTY")
    except btfscan.ScanError as e:
        raise GateError(f"stock kernel {a.stock_kernel}: {e}")
    body = {
        "schema": REF_SCHEMA,              # no tool_version here: a tool bump must not change the pinned reference hash
        "device": a.device,
        "sources": sources,
        "modules_path": a.modules_path,
        "inventory": inventory,
        "same_name_differing_policy": "all-copies-used" if a.allow_same_name_differing else "error",
        "modules": modules,
        "stock_btf": stock_btf,
    }
    for k in STORED_DERIVED:
        body[k] = d[k]
    ref = dict(body)
    ref["body_sha256"] = body_hash(body)
    os.makedirs(a.out, exist_ok=True)
    rj = os.path.join(a.out, "reference.json")
    with open(rj, "w") as fh:
        json.dump(ref, fh, indent=1, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(a.out, "required_crcs.txt"), "w") as fh:
        for s, c in d["required"].items():
            fh.write(f"{s} {c}\n")
    with open(os.path.join(a.out, "inventory.tsv"), "w") as fh:
        fh.write("name\tsha256\tsize\tsource\tpath\n")
        for o in inventory:
            fh.write(f"{o['name']}\t{o['sha256']}\t{o['size']}\t{o['source']}\t{o['path']}\n")
    file_sha = sha256_file(rj)
    c = d["counts"]
    if profile is not None:
        diff = [f"{k}: profile {v}, derived {c.get(k)}" for k, v in sorted(profile["counts"].items()) if c.get(k) != v]
        if diff:
            raise GateError("derived counts differ from the profile's pinned counts: " + "; ".join(diff))
        if profile.get("reference_sha256") and profile["reference_sha256"] != file_sha:
            raise GateError(f"reference.json sha256 {file_sha} differs from the profile pin {profile['reference_sha256']} (not reproducible?)")
        rep.ok("profile", f"device {profile['device']}: declared sources and pinned counts ({', '.join(f'{k}={v}' for k, v in sorted(profile['counts'].items()))}) match"
               + ("; reference sha256 matches pin" if profile.get("reference_sha256") else "; reference sha256 not yet pinned"))
    else:
        rep.warn("profile", "BOOTSTRAP: no profile; counts and sha256 are unpinned. Review, then pin them in a profile: "
                 + ", ".join(f"{k}={v}" for k, v in sorted(c.items())))
    rep.ok("reference", f"{c['module_copies']} module copies, {c['unique_modules']} unique; {c['unique_imported_pairs']} unique (symbol,CRC) imports; "
           f"{c['required_from_vmlinux']} required from vmlinux; {c['presence_required_unversioned']} unversioned imports; module_layout {d['module_layout']}; "
           f"vermagic flags '{d['vermagic_flags']}'; reference.json sha256 {file_sha} (pin this for check --reference-sha256)")
    out.update({"reference_dir": os.path.abspath(a.out), "reference_sha256": file_sha, "body_sha256": ref["body_sha256"], "counts": c,
                "sources": sources, "module_layout": d["module_layout"], "vermagic": f"{d['vermagic_releases'][0]} {d['vermagic_flags']}"})


# --------------------------------------------------------------------------
# check subcommand

EXPORT_TYPES = {"EXPORT_SYMBOL", "EXPORT_SYMBOL_GPL", "EXPORT_SYMBOL_GPL_FUTURE", "EXPORT_UNUSED_SYMBOL", "EXPORT_UNUSED_SYMBOL_GPL"}
GPL_ONLY = {"EXPORT_SYMBOL_GPL", "EXPORT_SYMBOL_GPL_FUTURE", "EXPORT_UNUSED_SYMBOL_GPL"}
GPL_COMPATIBLE = {"GPL", "GPL v2", "GPL and additional rights", "Dual BSD/GPL", "Dual MIT/GPL", "Dual MPL/GPL"}


def parse_symvers(path, what):
    data = read_file(path, what)
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise GateError(f"{what}: {path}: not ASCII text")
    rows = []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for n, line in enumerate(lines, 1):
        f = line.split("\t")
        if len(f) not in (4, 5):
            raise GateError(f"{what}: {path}:{n}: expected 4 or 5 tab-separated fields, got {len(f)}: {line[:80]!r}")
        crc, sym, mod, et = f[:4]
        ns = f[4] if len(f) == 5 else ""
        if not re.fullmatch(r"0x[0-9a-fA-F]{8}", crc):
            raise GateError(f"{what}: {path}:{n}: bad CRC field {crc!r}")
        if not sym or not re.fullmatch(r"[A-Za-z0-9_.$]+", sym):
            raise GateError(f"{what}: {path}:{n}: bad symbol field {sym!r}")
        if not mod or any(c.isspace() for c in mod):
            raise GateError(f"{what}: {path}:{n}: bad module field {mod!r}")
        if et not in EXPORT_TYPES:
            raise GateError(f"{what}: {path}:{n}: unknown export type {et!r}")
        if any(c.isspace() for c in ns):
            raise GateError(f"{what}: {path}:{n}: bad namespace field {ns!r}")
        rows.append({"crc": int(crc, 16), "sym": sym, "module": mod, "type": et, "ns": ns, "line": n})
    if not rows:
        raise GateError(f"{what}: {path}: no rows")
    if not any(r["module"] == "vmlinux" for r in rows):
        raise GateError(f"{what}: {path}: no vmlinux rows")
    return rows


def parse_config_bytes(data, what):
    cfg = {}
    for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
        line = line.rstrip()
        m = re.fullmatch(r"(CONFIG_[A-Za-z0-9_]+)=(.*)", line)
        if m:
            k, v = m.group(1), m.group(2)
        else:
            m = re.fullmatch(r"#\s*(CONFIG_[A-Za-z0-9_]+) is not set", line)
            if m:
                k, v = m.group(1), "n"
            elif line.strip() == "" or line.lstrip().startswith("#"):
                if re.search(r"\bCONFIG_[A-Za-z0-9_]+\b.*\bis not set\b", line):
                    raise GateError(f"{what}:{n}: malformed 'is not set' line {line[:80]!r}")
                continue
            else:
                raise GateError(f"{what}:{n}: unparseable line {line[:80]!r}")
        if k in cfg:
            raise GateError(f"{what}:{n}: {k} defined twice")
        if v == "":
            raise GateError(f"{what}:{n}: {k} has an empty value")
        cfg[k] = v
    if not cfg:
        raise GateError(f"{what}: no CONFIG_ entries")
    return cfg


def parse_config(path, what):
    return parse_config_bytes(read_file(path, what), f"{what}: {path}")


def _sym(name):
    n = name.upper()
    n = n[7:] if n.startswith("CONFIG_") else n
    if not re.fullmatch(r"[A-Z0-9_]+", n):
        raise GateError(f"requested options: bad symbol name {name!r}")
    return "CONFIG_" + n


def parse_requested(path):
    """Parse a scripts/config-style request list into {CONFIG_X: value|'n'|None(undefine)}.

    Lines whose first non-blank character is '#' are comments; '#' elsewhere is
    data (e.g. --set-val FOO a#b).  A file whose only token is --none states
    explicitly that nothing beyond the base config is requested."""
    text = read_file(path, "requested options").decode("utf-8", "replace")
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    try:
        toks = shlex.split(body, comments=False)
    except ValueError as e:
        raise GateError(f"requested options: {path}: {e}")
    if toks == ["--none"]:
        return {}
    if not toks:
        raise GateError(f"requested options: {path}: no requests (write --none to request nothing explicitly)")
    if "--none" in toks:
        raise GateError(f"requested options: {path}: --none must be the only token")
    req, i = {}, 0
    one = {"--enable": "y", "-e": "y", "--disable": "n", "-d": "n", "--module": "m", "-m": "m", "--undefine": None, "-u": None}
    after = {"--enable-after": "y", "-E": "y", "--disable-after": "n", "-D": "n", "--module-after": "m", "-M": "m"}
    while i < len(toks):
        t = toks[i]

        def arg(k):
            if i + k >= len(toks):
                raise GateError(f"requested options: {t} missing argument")
            return toks[i + k]
        if t in one:
            s, v = _sym(arg(1)), one[t]
            i += 2
        elif t in after:
            _sym(arg(1))
            s, v = _sym(arg(2)), after[t]
            i += 3
        elif t == "--set-val":
            s, v = _sym(arg(1)), arg(2)
            i += 3
            if v == "":
                raise GateError(f"requested options: --set-val {s} with empty value")
        elif t == "--set-str":
            s = _sym(arg(1))
            v = '"' + arg(2).replace("\\", "\\\\").replace('"', '\\"') + '"'
            i += 3
        else:
            raise GateError(f"requested options: unsupported token {t!r} (supported: --enable/-e --disable/-d --module/-m --undefine/-u --set-val --set-str --*-after --none)")
        req[s] = v
    return req


# The only config difference reported as WARN instead of FAIL: the host pahole
# version probe (stock v2.7 configs record 0 = pahole not seen by Kconfig; our
# hosts record 131).  It has no prompt.  Every other difference, including any
# compiler/linker version text, must be requested or explicitly allowlisted.
TOOLCHAIN_WARN = frozenset({"CONFIG_PAHOLE_VERSION"})


def vermagic_from_config(cfg, arch_token):
    t = []
    if cfg.get("CONFIG_SMP") == "y":
        t.append("SMP")
    if cfg.get("CONFIG_PREEMPT") == "y":
        t.append("preempt")
    elif cfg.get("CONFIG_PREEMPT_RT") == "y":
        t.append("preempt_rt")
    if cfg.get("CONFIG_MODULE_UNLOAD") == "y":
        t.append("mod_unload")
    if cfg.get("CONFIG_MODVERSIONS") == "y":
        t.append("modversions")
    t.append(arch_token)
    return t


KSYMTAB_TYPE = {"__ksymtab": "EXPORT_SYMBOL", "__ksymtab_gpl": "EXPORT_SYMBOL_GPL", "__ksymtab_unused": "EXPORT_UNUSED_SYMBOL",
                "__ksymtab_unused_gpl": "EXPORT_UNUSED_SYMBOL_GPL", "__ksymtab_gpl_future": "EXPORT_SYMBOL_GPL_FUTURE"}


class Vmlinux:
    """Parsed build vmlinux: __crc_* values, export type/namespace from the
    kernel's own __ksymtab* tables, and the objcopy -O binary reconstruction."""

    def __init__(self, path):
        if not os.path.isfile(path):
            raise GateError(f"vmlinux: {path}: no such file")
        try:
            with open(path, "rb") as fh:
                self.mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        except ValueError:
            raise GateError(f"vmlinux: {path}: empty file")
        except OSError as e:
            raise GateError(f"vmlinux: cannot read {path}: {e}")
        self.path = path
        try:
            self._parse()
        except (struct.error, IndexError, ValueError, OverflowError, UnicodeError) as e:
            self.mm.close()
            raise GateError(f"vmlinux: {path}: malformed ELF ({type(e).__name__}: {e})")
        except GateError:
            self.mm.close()
            raise

    def close(self):
        self.mm.close()

    def _parse(self):
        mm, path = self.mm, self.path
        if len(mm) < 64 or mm[:4] != b"\x7fELF" or mm[4] != 2 or mm[5] != 1:
            raise GateError(f"vmlinux: {path}: not a (complete) 64-bit little-endian ELF")
        shoff, = struct.unpack_from("<Q", mm, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", mm, 0x3A)
        if shentsize != 64 or shnum == 0 or shoff + shnum * 64 > len(mm) or shstrndx >= shnum:
            raise GateError(f"vmlinux: {path}: bad or truncated section header table")
        raw = [struct.unpack_from("<IIQQQQIIQQ", mm, shoff + i * 64) for i in range(shnum)]
        so, ss = raw[shstrndx][4], raw[shstrndx][5]
        if so + ss > len(mm):
            raise GateError(f"vmlinux: {path}: invalid section name table")
        self.secs = []
        for nm, t, fl, addr, off, size, link, _info, _al, _es in raw:
            if t != SHT_NOBITS and size and off + size > len(mm):
                raise GateError(f"vmlinux: {path}: section out of bounds")
            self.secs.append({"name": _cstr(mm, so + nm, so + ss, "vmlinux section name"), "type": t, "flags": fl,
                              "addr": addr, "off": off, "size": size, "link": link})
        symtabs = [s for s in self.secs if s["type"] == SHT_SYMTAB]
        if len(symtabs) != 1:
            raise GateError(f"vmlinux: {path}: expected one .symtab, found {len(symtabs)} (stripped?)")
        st = symtabs[0]
        if st["link"] >= shnum or st["size"] % 24:
            raise GateError(f"vmlinux: {path}: invalid .symtab")
        stro, strs = self.secs[st["link"]]["off"], self.secs[st["link"]]["size"]
        self.crcs, ksym, self.klabels = {}, {}, {}
        for name, _info, _o, shndx, val, _sz in struct.iter_unpack("<IBBHQQ", mm[st["off"]:st["off"] + st["size"]]):
            if name == 0:
                continue
            if name >= strs:
                raise GateError(f"vmlinux: {path}: symbol name offset out of bounds")
            n0 = stro + name
            if shndx == 0xFFF1 and mm[n0:n0 + 6] == b"__crc_":
                e = mm.find(b"\0", n0, stro + strs)
                self.crcs[mm[n0 + 6:e].decode("ascii", "replace")] = val & 0xFFFFFFFF
            elif mm[n0:n0 + 9] == b"kallsyms_":
                e = mm.find(b"\0", n0, stro + strs)
                self.klabels[mm[n0:e].decode("ascii", "replace")] = val
            elif mm[n0:n0 + 10] == b"__ksymtab_" and mm[n0:n0 + 18] != b"__ksymtab_strings\0":
                e = mm.find(b"\0", n0, stro + strs)
                ksym[mm[n0 + 10:e].decode("ascii", "replace")] = (shndx, val)
        self.symtab_ksym = ksym
        self.exports, self.cross = self._walk_export_tables()

    def addr2off(self, a):
        for s in self.secs:
            if s["type"] != SHT_NOBITS and s["addr"] and s["addr"] <= a < s["addr"] + s["size"]:
                return s["off"] + a - s["addr"]
        return None

    def _str_at(self, a):
        o = self.addr2off(a)
        if o is None:
            return None
        e = self.mm.find(b"\0", o, min(len(self.mm), o + 4096))
        return None if e < 0 else self.mm[o:e].decode("ascii", "replace")

    def _alloc_off(self, a, n=1):
        """File offset of n bytes at address a inside an ALLOCATED section, else None."""
        for sec in self.secs:
            if (sec["flags"] & 2) and sec["type"] != SHT_NOBITS and sec["addr"] <= a and a + n <= sec["addr"] + sec["size"]:
                return sec["off"] + a - sec["addr"]
        return None

    def _alloc_str(self, a):
        kst = getattr(self, "_kst", None)
        if kst is not None and not (kst["addr"] <= a < kst["addr"] + kst["size"]):
            return None                    # names/namespaces must come from __ksymtab_strings
        o = self._alloc_off(a)
        if o is None:
            return None
        sec_end = next(sec["off"] + sec["size"] for sec in self.secs
                       if (sec["flags"] & 2) and sec["type"] != SHT_NOBITS and sec["off"] <= o < sec["off"] + sec["size"])
        e = self.mm.find(b"\0", o, sec_end)
        return None if e < 0 else self.mm[o:e].decode("ascii", "replace")

    def _walk_export_tables(self):
        """Decode the export tables the KERNEL uses, from allocated (Image) bytes:
        every entry of __ksymtab{,_gpl,_unused,_unused_gpl,_gpl_future} with the
        CRC at the same index of the matching __kcrctab* table.  Entry layout:
        PREL32 {value_off, name_off[, ns_off]} (8 or 12 bytes) or absolute
        pointers (16 or 24 bytes), chosen as table size / CRC count and verified
        on every entry.  Returns ({sym: (type, ns, crc)}, [cross-check problems])."""
        byname = {}
        for sec in self.secs:
            byname.setdefault(sec["name"], []).append(sec)
        kst = byname.get("__ksymtab_strings", [])
        if len(kst) != 1 or not (kst[0]["flags"] & 2) or kst[0]["type"] == SHT_NOBITS:
            raise GateError("vmlinux: expected exactly one allocated __ksymtab_strings section")
        self._kst = kst[0]
        exports, cross, sizes = {}, [], set()
        self.tables = {}
        for ksname, typ in KSYMTAB_TYPE.items():
            ks = byname.get(ksname, [])
            kcname = "__kcrctab" + ksname[len("__ksymtab"):]
            kc = byname.get(kcname, [])
            if len(ks) > 1 or len(kc) > 1:
                raise GateError(f"vmlinux: duplicate {ksname}/{kcname} sections")
            ks = ks[0] if ks else None
            kc = kc[0] if kc else None
            if ks is None or ks["size"] == 0:
                if kc is not None and kc["size"]:
                    raise GateError(f"vmlinux: {kcname} has entries but {ksname} is empty")
                continue
            for sec, nm in ((ks, ksname), (kc, kcname)):
                if sec is None:
                    raise GateError(f"vmlinux: {ksname} present but no {kcname} (modversions CRC table missing)")
                if not (sec["flags"] & 2) or sec["type"] == SHT_NOBITS:
                    raise GateError(f"vmlinux: {nm} is not an allocated section with contents (not part of the Image)")
            if kc["size"] % 4:
                raise GateError(f"vmlinux: {kcname} size {kc['size']} is not a multiple of 4")
            n = kc["size"] // 4
            if n == 0 or ks["size"] % n or ks["size"] // n not in (8, 12, 16, 24):
                raise GateError(f"vmlinux: {ksname} size {ks['size']} is not a whole number of 8/12/16/24-byte entries for {n} CRCs")
            E = ks["size"] // n
            sizes.add(E)
            self.tables[ksname] = {"ks": ks, "kc": kc, "E": E, "n": n, "entries": []}
            prev = None
            for i in range(n):
                a = ks["addr"] + i * E
                o = ks["off"] + i * E
                if E in (8, 12):
                    no, = struct.unpack_from("<i", self.mm, o + 4)
                    name = self._alloc_str(a + 4 + no)
                    ns = ""
                    if E == 12:
                        nso, = struct.unpack_from("<i", self.mm, o + 8)
                        ns = self._alloc_str(a + 8 + nso) if nso else ""
                else:
                    pn, = struct.unpack_from("<Q", self.mm, o + 8)
                    name = self._alloc_str(pn)
                    ns = ""
                    if E == 24:
                        pns, = struct.unpack_from("<Q", self.mm, o + 16)
                        ns = self._alloc_str(pns) if pns else ""
                if not name or ns is None or not re.fullmatch(r"[A-Za-z0-9_.$]+", name):
                    raise GateError(f"vmlinux: {ksname} entry {i} does not decode to a symbol name in allocated data (layout {E} bytes)")
                if name in exports:
                    raise GateError(f"vmlinux: symbol {name} exported twice in the __ksymtab tables")
                if prev is not None and not prev < name.encode():
                    raise GateError(f"vmlinux: {ksname} is not in strictly ascending name order at entry {i} ({prev.decode()} then {name}); "
                                    "the module loader binary-searches it")
                prev = name.encode()
                if E in (8, 12):
                    vo, = struct.unpack_from("<i", self.mm, o)
                    target = a + vo
                else:
                    target, = struct.unpack_from("<Q", self.mm, o)
                crc, = struct.unpack_from("<I", self.mm, kc["off"] + 4 * i)
                exports[name] = (typ, ns, crc, a)
                self.tables[ksname]["entries"].append((name, target))
        if len(sizes) > 1:
            raise GateError(f"vmlinux: export tables disagree on the entry size {sorted(sizes)}")
        if sizes:
            m = re.search(rb"Linux version (\d+)\.(\d+)\.", self.mm)
            if m and ((int(m.group(1)), int(m.group(2))) >= (5, 4)) != (next(iter(sizes)) in (12, 24)):
                raise GateError(f"vmlinux: {next(iter(sizes))}-byte __ksymtab entries do not fit Linux {m.group(1).decode()}.{m.group(2).decode()} (namespaces from 5.4)")
        # cross-checks against the non-loaded .symtab (never trusted on their own)
        for sym, (typ, ns, crc, a) in sorted(exports.items()):
            if self.crcs and self.crcs.get(sym) != crc:
                cross.append(f"{sym}: __kcrctab CRC 0x{crc:08x} vs .symtab __crc_{sym} "
                             + (f"0x{self.crcs[sym]:08x}" if sym in self.crcs else "missing"))
            st = self.symtab_ksym.get(sym)
            if st is None:
                cross.append(f"{sym}: exported by the __ksymtab tables but .symtab has no __ksymtab_{sym} symbol")
            elif st[1] != a:
                cross.append(f"{sym}: .symtab __ksymtab_{sym} at 0x{st[1]:x}, table entry at 0x{a:x}")
        for sym in sorted(set(self.crcs) - set(exports)):
            cross.append(f"{sym}: .symtab __crc_{sym} but no entry in the __ksymtab tables")
        for sym, (shndx, val) in sorted(self.symtab_ksym.items()):
            if sym not in exports:
                cross.append(f"{sym}: .symtab __ksymtab_{sym} but no entry in the __ksymtab tables")
                continue
            sec = self.secs[shndx] if 0 < shndx < len(self.secs) else None
            if sec is None or not (sec["addr"] <= val < sec["addr"] + sec["size"]):
                cross.append(f"{sym}: .symtab __ksymtab_{sym} address 0x{val:x} lies outside its section index {shndx}")
            elif KSYMTAB_TYPE.get(sec["name"]) != exports[sym][0]:
                cross.append(f"{sym}: .symtab places __ksymtab_{sym} in {sec['name']}, the table entry is {exports[sym][0]}")
        return {k: v[:3] for k, v in exports.items()}, cross

    def _image_reader(self, img):
        segs = self._segments()
        for pt, _pf, _po, va, pa, _fs, _ms, _al in segs:
            if pt == 1 and va != pa:
                raise GateError("vmlinux: PT_LOAD with virtual != physical address is not supported")
        base = self._load_base()

        def rd(a, n):
            o = a - base
            if o < 0 or o + n > len(img):
                raise GateError(f"address 0x{a:x}+{n} is outside the kernel image")
            return img[o:o + n]
        return rd

    def decode_kallsyms(self, img):
        """Decode the kernel's own symbol table (CONFIG_KALLSYMS, base-relative)
        from the Image bytes.  The kallsyms_* labels from .symtab give only the
        LOCATION; the contents are validated structurally (count, ordering,
        markers, token table) as scripts/kallsyms.c lays them out (4.19 and 5.10)."""
        L = self.klabels
        need = ("kallsyms_offsets", "kallsyms_relative_base", "kallsyms_num_syms", "kallsyms_names",
                "kallsyms_markers", "kallsyms_token_table", "kallsyms_token_index")
        miss = [k for k in need if k not in L]
        if miss:
            raise GateError(f"kallsyms: labels missing ({', '.join(miss)}); CONFIG_KALLSYMS with KALLSYMS_BASE_RELATIVE is required")
        A = [L[k] for k in need]
        if A != sorted(A) or len(set(A)) != len(A):
            raise GateError("kallsyms: tables are not laid out in scripts/kallsyms.c order")
        if not all(self._alloc_off(a) is not None for a in A):
            raise GateError("kallsyms: tables are not inside allocated sections")
        rd = self._image_reader(img)
        off_a, rb_a, ns_a, nm_a, mk_a, tt_a, ti_a = A
        N, = struct.unpack("<I", rd(ns_a, 4))
        if N == 0 or not (4 * N <= rb_a - off_a < 4 * N + 256):     # ALGN padding (up to 256 on 4.19)
            raise GateError(f"kallsyms: num_syms {N} does not match the offsets table size")
        rb, = struct.unpack("<Q", rd(rb_a, 8))
        offs = struct.unpack("<%dI" % N, rd(off_a, 4 * N))
        addrs = [rb + o for o in offs]
        if any(x > y for x, y in zip(addrs, addrs[1:])):
            raise GateError("kallsyms: addresses are not sorted")
        ti = struct.unpack("<256H", rd(ti_a, 512))
        tt = rd(tt_a, ti_a - tt_a)
        toks = []
        for i in range(256):
            if ti[i] >= len(tt) or (i and ti[i] <= ti[i - 1]):
                raise GateError("kallsyms: token index is not increasing within the token table")
            e = tt.find(b"\0", ti[i])
            if e < 0:
                raise GateError("kallsyms: unterminated token")
            toks.append(tt[ti[i]:e])
        blob = rd(nm_a, mk_a - nm_a)
        pos, starts, syms = 0, [], []
        for i in range(N):
            if pos >= len(blob):
                raise GateError("kallsyms: names table ends before num_syms entries")
            starts.append(pos)
            ln = blob[pos]
            if ln == 0 or pos + 1 + ln > len(blob):
                raise GateError(f"kallsyms: malformed name entry {i}")
            nm = b"".join(toks[b] for b in blob[pos + 1:pos + 1 + ln])
            pos += 1 + ln
            if len(nm) < 2:
                raise GateError(f"kallsyms: empty name entry {i}")
            syms.append((nm[1:].decode("ascii", "replace"), addrs[i]))
        if any(blob[pos:]) or len(blob) - pos >= 256:
            raise GateError("kallsyms: unexpected data between the names table and the markers")
        M = (N + 255) // 256
        ok = False
        for w in (4, 8):
            if M * w <= tt_a - mk_a:
                mk = struct.unpack("<%d%s" % (M, "I" if w == 4 else "Q"), rd(mk_a, M * w))
                if list(mk) == starts[::256]:
                    ok = True
                    break
        if not ok:
            raise GateError("kallsyms: markers do not match the names table")
        table = {}
        for n_, a_ in syms:
            table.setdefault(n_, set()).add(a_)
        return table

    def loader_view_problems(self, img, sections_pin=None):
        """Checks that tie the export tables to what the running kernel uses."""
        probs = []
        try:
            ks = self.decode_kallsyms(img)
        except GateError as e:
            return [str(e)], 0
        one = lambda n: (sorted(ks[n])[0] if len(ks.get(n, ())) == 1 else None)
        for ksname, t in self.tables.items():
            suf = ksname[len("__ksymtab"):]
            for sym, want in ((f"__start___ksymtab{suf}", t["ks"]["addr"]), (f"__stop___ksymtab{suf}", t["ks"]["addr"] + t["ks"]["size"]),
                              (f"__start___kcrctab{suf}", t["kc"]["addr"])):
                got = one(sym)
                if got != want:
                    probs.append(f"kernel's own {sym} is {('0x%x' % got) if got is not None else 'absent/ambiguous'} but the table kgate decoded is at 0x{want:x}")
            for name, target in t["entries"]:
                if target not in ks.get(name, ()):
                    probs.append(f"{name}: __ksymtab entry points to 0x{target:x}, kallsyms has {name} at "
                                 + (", ".join("0x%x" % a for a in sorted(ks[name])) if name in ks else "no address"))
        ed = one("_edata")
        if ed is None:
            probs.append("kallsyms has no unique _edata")
        else:
            prog = sorted((sec for sec in self.secs if (sec["flags"] & 2) and sec["type"] != SHT_NOBITS and sec["size"]), key=lambda x: x["addr"])
            for sec in prog:
                if sec["addr"] + sec["size"] > ed:
                    probs.append(f"allocated section {sec['name']} extends past _edata (0x{ed:x}) into .bss")
            for x, y in zip(prog, prog[1:]):
                if x["addr"] + x["size"] > y["addr"]:
                    probs.append(f"allocated sections {x['name']} and {y['name']} overlap")
        if sections_pin is not None:
            have = sorted(sec["name"] for sec in self.secs if sec["flags"] & 2)
            if have != sorted(sections_pin):
                probs.append(f"allocated section set differs from the pinned stock-build set: extra {sorted(set(have) - set(sections_pin))}, "
                             f"missing {sorted(set(sections_pin) - set(have))}")
        return probs, sum(len(v) for v in ks.values())

    def _segments(self):
        mm = self.mm
        phoff, = struct.unpack_from("<Q", mm, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", mm, 0x36)
        if phentsize != 56 or phnum == 0 or phoff + phnum * 56 > len(mm):
            raise GateError("vmlinux program header table invalid")
        return [struct.unpack_from("<IIQQQQQQ", mm, phoff + i * 56) for i in range(phnum)]

    def _parts(self):
        segs = self._segments()
        parts = []
        for sec in self.secs:
            if not (sec["flags"] & 2) or sec["type"] == SHT_NOBITS or sec["size"] == 0:
                continue
            lma = sec["addr"]
            for pt, _pf, _po, va, pa, _fs, ms, _al in segs:
                if pt == 1 and va <= sec["addr"] < va + ms:
                    lma = sec["addr"] - va + pa
                    break
            parts.append((lma, sec["off"], sec["size"]))
        if not parts:
            raise GateError("vmlinux has no allocated sections with contents")
        return sorted(parts)

    def _load_base(self):
        return self._parts()[0][0]

    def objcopy_length(self):
        p = self._parts()
        return max(a + n for a, _o, n in p) - p[0][0]

    def objcopy_binary(self):
        """What `objcopy -O binary vmlinux Image` produces: every allocated
        section with contents, placed at its load address, gaps zero-filled,
        from the lowest to the highest load address (exact length)."""
        mm = self.mm
        phoff, = struct.unpack_from("<Q", mm, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", mm, 0x36)
        if phentsize != 56 or phnum == 0 or phoff + phnum * 56 > len(mm):
            raise GateError("vmlinux program header table invalid")
        segs = [struct.unpack_from("<IIQQQQQQ", mm, phoff + i * 56) for i in range(phnum)]
        parts = []
        for s in self.secs:
            if not (s["flags"] & 2) or s["type"] == SHT_NOBITS or s["size"] == 0:
                continue
            lma = s["addr"]
            for pt, _pf, _po, va, pa, _fs, ms, _al in segs:
                if pt == 1 and va <= s["addr"] < va + ms:
                    lma = s["addr"] - va + pa
                    break
            parts.append((lma, s["off"], s["size"]))
        if not parts:
            raise GateError("vmlinux has no allocated sections with contents")
        base = min(p[0] for p in parts)
        end = max(p[0] + p[2] for p in parts)
        if end - base > (1 << 31):
            raise GateError("vmlinux load span implausibly large")
        img = bytearray(end - base)
        for lma, off, size in parts:
            img[lma - base:lma - base + size] = mm[off:off + size]
        return bytes(img)


def image_vs_vmlinux(img, vm):
    """The kernel Image must equal objcopy -O binary of vmlinux exactly (length,
    every allocated section at its load address, zero-filled gaps).  The length
    is checked first; the comparison then streams section by section."""
    exp_len = vm.objcopy_length()
    if exp_len > (1 << 31):
        return "vmlinux load span implausibly large"
    if len(img) != exp_len:
        return f"kernel image length {len(img)} != objcopy reconstruction of vmlinux {exp_len} (truncated or padded image)"
    parts = vm._parts()
    base = parts[0][0]
    cur = 0
    for lma, off, size in parts:
        o = lma - base
        if o > cur and any(img[cur:o]):
            return f"kernel image has non-zero bytes in a gap between sections near offset 0x{cur:x} (differ from the objcopy reconstruction)"
        if img[o:o + size] != vm.mm[off:off + size]:
            return f"kernel image bytes differ from the objcopy reconstruction of vmlinux in the section at offset 0x{o:x}"
        cur = max(cur, o + size)
    return None


def banner(buf):
    """The kernel version banner: first 'Linux version N.M.' text (an earlier
    bare 'Linux version ' string elsewhere in .rodata is skipped)."""
    m = re.search(rb"Linux version \d+\.\d+\.", buf)
    if not m:
        return None
    i = m.start()
    e = min([x for x in (buf.find(b"\n", i), buf.find(b"\0", i)) if x >= 0] or [i + 256])
    return bytes(buf[i:e]).decode("ascii", "replace")


def ikconfig(buf):
    """Return the embedded .config bytes (CONFIG_IKCONFIG), or None if absent."""
    i = buf.find(b"IKCFG_ST")
    if i < 0:
        return None
    if buf.find(b"IKCFG_ST", i + 8) >= 0:
        raise GateError("kernel image contains more than one IKCFG_ST marker")
    j = buf.find(b"IKCFG_ED", i + 8)
    if j < 0:
        raise GateError("kernel image has IKCFG_ST but no IKCFG_ED marker")
    try:
        return gzip.decompress(bytes(buf[i + 8:j]))
    except (OSError, EOFError, zlib.error) as e:
        raise GateError(f"embedded IKCONFIG not decompressible: {e}")


def _expect(cond, what):
    if not cond:
        raise GateError(f"reference structurally invalid: {what}")


def validate_reference_schema(ref):
    """Type/shape validation so a hash-valid but malformed reference is an ERROR, not a crash."""
    isstr = lambda x: isinstance(x, str)
    strlist = lambda x: isinstance(x, list) and all(isstr(y) for y in x)
    _expect(isinstance(ref, dict), "top level is not an object")
    for k, t in (("sources", list), ("inventory", list), ("modules", list), ("required", dict), ("presence_required", list),
                 ("vendor_exports", dict), ("same_name_differing", dict), ("modname_collisions", dict), ("counts", dict),
                 ("stock_btf", dict), ("vermagic_releases", list)):
        _expect(isinstance(ref.get(k), t), f"{k} missing or not a {t.__name__}")
    _expect(ref.get("same_name_differing_policy") in ("error", "all-copies-used"), "same_name_differing_policy invalid")
    _expect(isstr(ref.get("module_layout")) and isstr(ref.get("vermagic_flags")), "module_layout/vermagic_flags missing")
    _expect(isinstance(ref.get("elf_machine"), int), "elf_machine missing")
    for o in ref["inventory"]:
        _expect(isinstance(o, dict) and all(isstr(o.get(k)) for k in ("source", "path", "name", "sha256")) and isinstance(o.get("size"), int),
                "inventory entry malformed")
    for m in ref["modules"]:
        _expect(isinstance(m, dict), "module entry not an object")
        for k in ("id", "name", "vermagic", "modname", "license"):
            _expect(isstr(m.get(k)), f"module field {k} missing")
        _expect(re.fullmatch(r"[0-9a-f]{64}", m["id"]) is not None, "module id is not a sha256")
        _expect(" " in m["vermagic"], f"module {m['name']} vermagic malformed")
        for k in ("exports", "undefined", "weak_undefined", "import_ns", "occurrences"):
            _expect(strlist(m.get(k)), f"module {m['name']} field {k} malformed")
        _expect(isinstance(m.get("machine"), int), f"module {m['name']} machine malformed")
        v = m.get("versions")
        _expect(isinstance(v, dict) and all(isstr(s) and isinstance(c, int) and 0 <= c <= 0xFFFFFFFF for s, c in v.items()),
                f"module {m['name']} versions malformed")
    for s, c in ref["required"].items():
        _expect(isstr(c) and re.fullmatch(r"0x[0-9a-f]{8}", c) is not None, f"required CRC for {s} malformed")
    sb = ref["stock_btf"]
    _expect(isstr(sb.get("file")) and isstr(sb.get("sha256")) and isinstance(sb.get("kinds"), dict), "stock_btf malformed")


def git_blob(path):
    data = read_file(path, "profile")
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def committed_blob(path):
    """The blob id of `path` at git HEAD, or GateError if untracked/not in a repo."""
    git = find_tool("git")
    if not git:
        raise GateError("--require-committed-profile: git not found")
    d = os.path.dirname(os.path.abspath(path))
    r = run_tool([git, "-c", "safe.directory=*", "-C", d, "rev-parse", "--show-toplevel"], "git")
    if r.returncode != 0:
        raise GateError(f"profile {path} is not inside a git work tree (not committed)")
    top = r.stdout.decode().strip()
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(top)).replace(os.sep, "/")
    r = run_tool([git, "-c", "safe.directory=*", "-C", top, "rev-parse", f"HEAD:{rel}"], "git")
    if r.returncode != 0:
        raise GateError(f"profile {path} is not committed at HEAD ({r.stderr.decode(errors='replace').strip()[:120]})")
    return r.stdout.decode().strip()


def stock_ikconfig(path):
    """The .config embedded in the stock kernel (boot.img or Image)."""
    try:
        kb = read_file(path, "stock kernel")
        if kb[:8] == b"ANDROID!":
            kb, _hv = btfscan.android_boot_kernel(kb)
        kb, _c = btfscan.decompress_auto(kb, path)
    except btfscan.ScanError as e:
        raise GateError(f"stock kernel {path}: {e}")
    emb = ikconfig(kb)
    if emb is None:
        raise GateError(f"stock kernel {path} has no embedded IKCONFIG: the base config cannot be pinned to it")
    return emb


def load_reference(path, profile, device, stock_override, rep):
    data = read_file(path, "reference")
    file_sha = sha256_bytes(data)
    pinned_sha = None
    if profile is not None:
        pinned_sha = profile.get("reference_sha256")
        if not pinned_sha:
            raise GateError(f"profile for {device} has no pinned reference_sha256")
        if file_sha != pinned_sha:
            raise GateError(f"reference: {path}: sha256 {file_sha} does not match the profile's pinned reference_sha256 {pinned_sha}")
    try:
        ref = json.loads(data)
    except ValueError as e:
        raise GateError(f"reference: {path}: invalid JSON: {e}")
    if not isinstance(ref, dict) or ref.get("schema") != REF_SCHEMA:
        raise GateError(f"reference: {path}: not a {REF_SCHEMA} file")
    h = ref.pop("body_sha256", None)
    if h != body_hash(ref):
        raise GateError(f"reference: {path}: body_sha256 mismatch (file edited or truncated)")
    validate_reference_schema(ref)
    if ref.get("device") != device:
        raise GateError(f"reference is for device {ref.get('device')!r}, not --device {device!r}")
    if profile is not None:
        cd = [f"{k}: profile {v}, reference {ref['counts'].get(k)}" for k, v in sorted(profile["counts"].items()) if ref["counts"].get(k) != v]
        if cd:
            raise GateError("reference counts differ from the profile pins: " + "; ".join(cd))
    if not ref["modules"]:
        raise GateError("reference: empty (no modules)")
    if not ref["required"]:
        raise GateError("reference: empty required-symbol set")
    d = derive_all(ref["modules"], ref["inventory"])
    if d["conflicts"]:
        raise GateError("reference: modules import conflicting CRCs")
    bad = [k for k in STORED_DERIVED if ref.get(k) != d[k]]
    if bad:
        raise GateError(f"reference: stored field(s) disagree with re-derivation from module records: {', '.join(bad)}")
    if ref["same_name_differing_policy"] == "error" and (d["same_name_differing"] or d["modname_collisions"]):
        raise GateError("reference: same-name/modname collisions present but policy is 'error'")
    if d["module_layout"] is None or len(d["vermagic_flags_all"]) != 1 or len(d["elf_machines_all"]) != 1:
        raise GateError("reference: module_layout, vermagic flags or ELF machine not uniquely determined")
    # stock BTF kinds: re-scan the stock kernel (hash must match the reference)
    sb = ref["stock_btf"]
    sk = stock_override or (profile or {}).get("_stock_kernel_abs")
    if not sk:
        raise GateError("stock kernel location unknown: give --stock-kernel, or stock_kernel (relative path) in the profile")
    if not os.path.isfile(sk):
        raise GateError(f"reference: stock kernel {sk} not available to re-derive the allowed BTF kinds and base config")
    if sha256_file(sk) != sb["sha256"]:
        raise GateError(f"reference: stock kernel {sk} sha256 differs from the reference record")
    try:
        r = btfscan.scan_file(sk)
        kinds = r["kinds"]
    except btfscan.MissingBTF:
        kinds = {}
    except btfscan.ScanError as e:
        raise GateError(f"reference: stock kernel {sk}: {e}")
    if kinds != sb["kinds"]:
        raise GateError("reference: stock_btf.kinds disagrees with a re-scan of the stock kernel")
    rep.ok("reference-integrity", f"device {device}; reference sha256 {file_sha}" + (" matches the profile pin" if pinned_sha else " (NOT pinned: report-only)")
           + f"; all derived fields re-derived from {len(ref['modules'])} module records; stock BTF kinds re-scanned")
    ref["_importers"] = d["_importers"]
    ref["_mods"] = {m["id"]: m for m in ref["modules"]}
    ref["_file_sha256"] = file_sha
    ref["_stock_kernel"] = os.path.abspath(sk)
    return ref


def _waiver(val, name):
    if val is None:
        return None
    if len(val.strip()) < MIN_WAIVER:
        raise GateError(f"--waive-{name} needs a justification of at least {MIN_WAIVER} characters")
    return val.strip()


def cmd_check(a):
    rep = Report()
    out = {"schema": CHECK_SCHEMA, "tool_version": TOOL_VERSION, "label": a.label,
           "mode": "report-only" if a.report_only else "gate", "waivers": {}}
    try:
        _check(a, rep, out)
    except GateError as e:
        rep.error("input", str(e))
    except INPUT_EXC as e:
        rep.error("input", f"unexpected input/IO error ({type(e).__name__}: {e})")
    return finish(rep, out, a.json, "check", a.report_only)


def _check(a, rep, out):
    wb = _waiver(a.waive_baseline, "baseline")
    wi = _waiver(a.waive_ikconfig, "ikconfig")
    if wb and a.baseline_symvers:
        raise GateError("--waive-baseline and --baseline-symvers are mutually exclusive")
    if not a.report_only:
        missing = [f for f, v in (("--profile", a.profile), ("--build", a.build), ("--vmlinux", a.vmlinux),
                                  ("--requested", a.requested), ("--requested-config", a.requested_config),
                                  ("--baseline-symvers (or --waive-baseline REASON)", a.baseline_symvers or wb)) if not v]
        if missing:
            raise GateError("gate mode requires: " + ", ".join(missing) + " (use --report-only for a non-gating report)")
    else:
        rep.warn("mode", "report-only: enforcement inputs are optional and the result can never be a gate PASS")
    profile = load_profile(a.profile, a.device) if a.profile else None
    ref = load_reference(a.reference, profile, a.device, a.stock_kernel, rep)
    rows = parse_symvers(a.symvers, "Module.symvers")
    cfg_bytes = read_file(a.config, ".config")
    cfg = parse_config_bytes(cfg_bytes, f".config: {a.config}")
    kernel_bytes = read_file(a.kernel, "kernel image")
    fsha = lambda f: sha256_file(f) if f else None
    out["inputs"] = {
        "reference": {"path": os.path.abspath(a.reference), "device": ref.get("device"), "sha256": ref["_file_sha256"], "pinned": profile is not None},
        "symvers": {"path": os.path.abspath(a.symvers), "sha256": sha256_file(a.symvers), "rows": len(rows)},
        "kernel": {"path": os.path.abspath(a.kernel), "sha256": sha256_bytes(kernel_bytes)},
        "config": {"path": os.path.abspath(a.config), "sha256": sha256_bytes(cfg_bytes)},
        "profile": {"path": os.path.abspath(a.profile), "sha256": fsha(a.profile), "git_blob_sha1": git_blob(a.profile), "build": a.build} if a.profile else None,
        "vmlinux": {"path": os.path.abspath(a.vmlinux), "sha256": fsha(a.vmlinux)} if a.vmlinux else None,
        "requested": {"path": os.path.abspath(a.requested), "sha256": fsha(a.requested)} if a.requested else None,
        "requested_config": {"path": os.path.abspath(a.requested_config), "sha256": fsha(a.requested_config)} if a.requested_config else None,
        "allow_config_changes": {"path": os.path.abspath(a.allow_config_changes), "sha256": fsha(a.allow_config_changes)} if a.allow_config_changes else None,
        "baseline_symvers": {"path": os.path.abspath(a.baseline_symvers), "sha256": fsha(a.baseline_symvers)} if a.baseline_symvers else None,
        "stock_kernel": {"path": ref["_stock_kernel"], "sha256": ref["stock_btf"]["sha256"]},
    }
    I = out["inputs"]
    wc = _waiver(a.waive_committed_profile, "committed-profile")
    if wc:
        out["waivers"]["committed-profile"] = wc
        rep.warn("waiver-committed-profile", f"profile not required to be committed: {wc}")
    if (a.require_committed_profile or not a.report_only) and not wc:
        if not a.profile:
            raise GateError("--require-committed-profile needs --profile")
        head = committed_blob(a.profile)
        if head != I["profile"]["git_blob_sha1"]:
            raise GateError(f"profile {a.profile} differs from its committed version (HEAD blob {head}, file blob {I['profile']['git_blob_sha1']})")
        rep.ok("profile-committed", f"profile equals its committed git blob {head}")
    if a.baseline_symvers and I["baseline_symvers"]["sha256"] == I["symvers"]["sha256"]:
        raise GateError("--baseline-symvers is the build's own Module.symvers (a self-comparison proves nothing)")
    rq_parsed = parse_requested(a.requested) if a.requested else None
    if wb:
        if rq_parsed != {}:
            raise GateError("--waive-baseline is only allowed for the stock-config build (a --requested list containing only --none)")
        out["waivers"]["baseline"] = wb
        rep.warn("waiver-baseline", f"baseline check waived by the operator: {wb}")
    if profile is not None:
        builds = profile.get("builds") or {}
        if not a.build or a.build not in builds:
            raise GateError(f"--build {a.build!r} is not one of the builds pinned in the profile ({', '.join(sorted(builds)) or 'none'})")
        be = builds[a.build]
        probs = []
        if be["requested_sha256"] != (I["requested"] or {}).get("sha256"):
            probs.append(f"request list is not the one pinned for build {a.build!r}")
        if be.get("allow_sha256") != (I["allow_config_changes"] or {}).get("sha256"):
            probs.append(f"--allow-config-changes is not the allowlist pinned for build {a.build!r}" if be.get("allow_sha256")
                         else f"build {a.build!r} has no pinned allowlist, but --allow-config-changes was given")
        if be["baseline"] == "waived":
            if not wb:
                probs.append(f"build {a.build!r} is pinned as the stock-config build: its baseline must be waived explicitly")
        elif (I["baseline_symvers"] or {}).get("sha256") != profile.get("stock_build_symvers_sha256"):
            probs.append("--baseline-symvers is not the pinned stock-build Module.symvers of this device")
        if probs:
            raise GateError("build inputs do not match the profile pins: " + "; ".join(probs))
        rep.ok("build-pins", f"build {a.build!r}: request list, allowlist and baseline match the profile pins")
    if a.requested_config:
        stock_cfg = stock_ikconfig(ref["_stock_kernel"])
        if parse_config_bytes(stock_cfg, "stock kernel IKCONFIG") != parse_config(a.requested_config, "requested .config"):
            raise GateError(f"--requested-config {a.requested_config} is not the device's stock config (it differs from the IKCONFIG "
                            f"embedded in the pinned stock kernel {ref['_stock_kernel']})")
        rep.ok("base-config", "requested base config equals the IKCONFIG of the device's pinned stock kernel")
    out["reference_counts"] = ref["counts"]
    out["reference_device"] = ref.get("device")
    req = {s: int(c, 16) for s, c in ref["required"].items()}
    mods = ref["_mods"]
    importers = ref["_importers"]
    seen = {}
    for r in rows:
        seen.setdefault(r["sym"], []).append(r)
    vml = {r["sym"]: r for r in rows if r["module"] == "vmlinux"}
    dups = [f"{s}: " + ", ".join(f"{r['module']}@{r['line']}" for r in rs) for s, rs in sorted(seen.items()) if len(rs) > 1]
    if dups:
        rep.fail("symvers-duplicates", f"{len(dups)} symbol(s) appear in more than one Module.symvers row", dups)
    else:
        rep.ok("symvers-duplicates", f"no duplicate rows ({len(rows)} rows, {len(vml)} vmlinux)")
    match, mism, miss = 0, [], []
    for s, c in sorted(req.items()):
        r = vml.get(s)
        if r is None:
            other = [x["module"] for x in seen.get(s, [])]
            miss.append(f"{s} (ref 0x{c:08x})" + (f" -- exported only by in-tree module(s) {', '.join(other)}" if other else ""))
        elif r["crc"] != c:
            mism.append(f"{s} ref=0x{c:08x} build=0x{r['crc']:08x}")
        else:
            match += 1
    out["required_result"] = {"required": len(req), "match": match, "mismatch": len(mism), "missing": len(miss)}
    if mism:
        rep.fail("crc", f"{len(mism)} vendor-required symbol CRC(s) differ ({match}/{len(req)} match)", mism)
    if miss:
        rep.fail("missing", f"{len(miss)} vendor-required symbol(s) not exported by vmlinux", miss)
    if not mism and not miss:
        rep.ok("crc", f"{match}/{len(req)} vendor-required (symbol, CRC) pairs match vmlinux")
    ml = vml.get("module_layout")
    if ml is None:
        rep.fail("module-layout", f"module_layout not exported by vmlinux (reference {ref['module_layout']})")
    elif ml["crc"] != int(ref["module_layout"], 16):
        rep.fail("module-layout", f"module_layout build=0x{ml['crc']:08x} reference={ref['module_layout']}")
    else:
        rep.ok("module-layout", f"module_layout {ref['module_layout']} matches")
    pres = ref["presence_required"]
    pmiss = [s for s in pres if s not in vml]
    if pmiss:
        rep.fail("unversioned-imports", f"{len(pmiss)} unversioned vendor import(s) not exported by vmlinux", pmiss)
    else:
        rep.ok("unversioned-imports", f"{len(pres)} unversioned vendor import(s) present in vmlinux")
    coll = [f"{s}: vmlinux and vendor module(s) {', '.join(m)}" + (" (imported by vendor modules)" if s in importers else "")
            for s, m in sorted(ref["vendor_exports"].items()) if s in vml]
    if coll:
        rep.fail("export-collision", f"{len(coll)} symbol(s) exported by both vmlinux and a stock vendor module", coll)
    else:
        rep.ok("export-collision", f"none of the {len(ref['vendor_exports'])} vendor-exported symbols is exported by vmlinux")
    nsbad, gplbad = [], []
    for s in sorted(set(req) | set(pres)):
        r = vml.get(s)
        if r is None:
            continue
        for mid in sorted(set(importers.get(s, []))):
            m = mods[mid]
            if r["ns"] and r["ns"] not in m["import_ns"]:
                nsbad.append(f"{s} in namespace {r['ns']} but {m['name']} lacks import_ns={r['ns']}")
            if r["type"] in GPL_ONLY and m["license"] not in GPL_COMPATIBLE:
                gplbad.append(f"{s} is {r['type']} but {m['name']} license is {m['license']!r}")
    if nsbad:
        rep.fail("namespace", f"{len(nsbad)} namespaced export(s) not imported by the vendor module", nsbad)
    else:
        rep.ok("namespace", "no vendor import needs a symbol namespace it does not declare")
    if gplbad:
        rep.fail("gpl-only", f"{len(gplbad)} GPL-only export(s) used by non-GPL-compatible vendor modules", gplbad)
    else:
        rep.ok("gpl-only", "no GPL-only export is used by a non-GPL-compatible vendor module")
    # baseline
    if a.baseline_symvers:
        brows = parse_symvers(a.baseline_symvers, "baseline Module.symvers")
        bv, bd = {}, []
        for r in brows:
            if r["module"] == "vmlinux":
                if r["sym"] in bv:
                    bd.append(r["sym"])
                bv[r["sym"]] = r
        if bd:
            raise GateError(f"baseline Module.symvers has duplicate vmlinux rows: {bd[:5]}")
        out["inputs"]["baseline_symvers"] = {"path": os.path.abspath(a.baseline_symvers), "sha256": sha256_file(a.baseline_symvers), "vmlinux_rows": len(bv)}
        changed, removed, kind = [], [], []
        for s, b in sorted(bv.items()):
            r = vml.get(s)
            if r is None:
                removed.append(f"{s} (baseline 0x{b['crc']:08x})")
                continue
            if r["crc"] != b["crc"]:
                changed.append(f"{s} baseline=0x{b['crc']:08x} build=0x{r['crc']:08x}")
            if r["type"] != b["type"] or r["ns"] != b["ns"]:
                kind.append(f"{s} baseline={b['type']}/{b['ns'] or '-'} build={r['type']}/{r['ns'] or '-'}")
        added = sorted(set(vml) - set(bv))
        out["baseline_result"] = {"baseline_vmlinux": len(bv), "changed": len(changed), "removed": len(removed), "type_or_ns_changed": len(kind), "added": len(added), "added_symbols": added}
        if changed:
            rep.fail("baseline-changed", f"{len(changed)} existing vmlinux export CRC(s) changed vs baseline", changed)
        if removed:
            rep.fail("baseline-removed", f"{len(removed)} existing vmlinux export(s) removed vs baseline", removed)
        if kind:
            rep.fail("baseline-export-type", f"{len(kind)} existing vmlinux export(s) changed export type/namespace", kind)
        if not (changed or removed or kind):
            rep.ok("baseline", f"0 of {len(bv)} baseline vmlinux exports changed or removed; {len(added)} added")
    elif wb:
        rep.skip("baseline", f"waived: {wb}")
    else:
        rep.skip("baseline", "no --baseline-symvers given (report-only)")
    # requested options (delta) and requested full config (base)
    rq = parse_requested(a.requested) if a.requested else None
    if rq is not None:
        bad, warn = [], []
        for s, v in rq.items():
            got = cfg.get(s)
            if v is None:
                if got is not None:
                    bad.append(f"{s}: requested undefined, resulting .config has {got}")
            elif v == "n":
                if got not in (None, "n"):
                    bad.append(f"{s}: requested disabled, resulting .config has {s}={got}")
                elif got is None:
                    warn.append(f"{s}: requested disabled, but the symbol is absent from the resulting .config (typo or unknown to this tree)")
            elif got != v:
                bad.append(f"{s}: requested {v}, resulting .config has " + ("it absent (dropped by olddefconfig?)" if got is None else ("not set" if got == "n" else got)))
        out["requested_result"] = {"requested": len(rq), "unsatisfied": len(bad), "explicit_none": not rq}
        if warn:
            rep.error("requested-options-unknown", f"{len(warn)} disabled request(s) name symbols absent from the resulting .config", warn)
        if bad:
            rep.fail("requested-options", f"{len(bad)} of {len(rq)} requested option(s) not satisfied by the resulting .config", bad)
        else:
            rep.ok("requested-options", f"all {len(rq)} requested option(s) satisfied" + (" (explicit --none)" if not rq else ""))
    else:
        rep.skip("requested-options", "no --requested list given (report-only)")
    if a.requested_config:
        # Two-way diff of the resulting .config against base (+ requests): every
        # difference must be requested, explicitly allowlisted (--allow-config-changes,
        # exact value), or the single justified toolchain-probe symbol; else FAIL.
        base = parse_config(a.requested_config, "requested .config")
        allow = parse_config(a.allow_config_changes, "allowed config changes") if a.allow_config_changes else {}
        rqd = rq or {}
        bad, tc, allowed_used = [], [], []
        for s in sorted(set(base) | set(cfg) | set(allow)):
            if s in rqd:
                continue              # requested value, checked by requested-options
            exp = base.get(s, "n")
            got = cfg.get(s, "n")
            if exp == got:
                continue
            msg = f"{s}: base {'not set' if exp == 'n' else exp}, resulting .config {'not set' if got == 'n' else got}"
            if s in TOOLCHAIN_WARN:
                tc.append(msg)
            elif s in allow and allow[s] == got:
                allowed_used.append(msg)
            else:
                bad.append(msg)
        stale = sorted(s for s in allow if not any(m.startswith(s + ":") for m in allowed_used))
        out["config_diff"] = {"unrequested_changes": len(bad), "allowlisted": allowed_used, "toolchain_warn": tc, "stale_allow_entries": stale}
        if tc:
            rep.warn("requested-config-toolchain", f"{len(tc)} difference(s) in {', '.join(sorted(TOOLCHAIN_WARN))} (host pahole probe; justified in README)", tc)
        if allowed_used:
            rep.warn("requested-config-allowlisted", f"{len(allowed_used)} unrequested change(s) accepted by the explicit allowlist {a.allow_config_changes}", allowed_used)
        if stale:
            rep.warn("requested-config-allowlist-stale", f"{len(stale)} allowlist entr(y/ies) not needed by this build", stale)
        if bad:
            rep.fail("requested-config", f"{len(bad)} unrequested, non-allowlisted .config change(s) versus the base config", bad)
        else:
            rep.ok("requested-config", f".config equals base {a.requested_config} + requests, except the allowlisted/toolchain entries reported above")
    else:
        rep.skip("requested-config", "no --requested-config given (report-only)")
    # vermagic
    known = {"SMP", "preempt", "preempt_rt", "mod_unload", "modversions", "aarch64"}
    rtoks = ref["vermagic_flags"].split()
    unknown = [t for t in rtoks if t not in known]
    if unknown:
        rep.error("vermagic", f"reference vermagic has tokens this tool cannot derive from .config: {unknown}")
    elif ref.get("elf_machine") != 183:
        rep.error("vermagic", f"reference modules are ELF machine {ref.get('elf_machine')}, only aarch64 (183) supported")
    else:
        exp = vermagic_from_config(cfg, "aarch64")
        kimg = kernel_bytes
        try:
            if kimg[:8] == b"ANDROID!":
                kimg, _h = btfscan.android_boot_kernel(kimg)
            kimg, _c = btfscan.decompress_auto(kimg, a.kernel)
        except btfscan.ScanError:
            kimg = b""
        mb = re.search(rb"Linux version (\d+\.\d+\.\S+) ", kimg)
        img_vm = (mb.group(1) + b" " + " ".join(rtoks).encode() + b"\0") if mb else None
        if img_vm is None or kimg.find(img_vm) < 0:
            rep.fail("vermagic-image", "the kernel image does not contain the module-loader vermagic string '<release> "
                     + " ".join(rtoks) + "' that the stock modules carry")
        else:
            rep.ok("vermagic-image", f"kernel image carries the module-loader vermagic '{img_vm[:-1].decode()}'")
        if exp != rtoks:
            rep.fail("vermagic", f"build vermagic flags '{' '.join(exp)}' (from .config) != stock modules '{' '.join(rtoks)}'")
        else:
            rep.ok("vermagic", f"vermagic flags '{' '.join(exp)}' match (release string not compared under modversions)")
    # BTF kind scan
    allowed = set(ref["stock_btf"]["kinds"])
    kb, res = None, None
    try:
        kb = kernel_bytes
        if kb[:8] == b"ANDROID!":
            kb, _hv = btfscan.android_boot_kernel(kb)
        kb, _comp = btfscan.decompress_auto(kb, a.kernel)
        res = btfscan.scan_bytes(kb)
        out["btf"] = {k: res[k] for k in ("offset", "types", "kinds", "blob_sha256", "located_by")}
        beyond = sorted(set(res["kinds"]) - allowed)
        if beyond:
            rep.fail("btf-kinds", f"kinds beyond stock: {', '.join(beyond)} (kind scan only, not BTF validation)", beyond)
        else:
            rep.ok("btf-kinds", f"{res['types']} types; no kinds beyond stock ({', '.join(sorted(res['kinds']))}) -- kind scan only, not BTF validation")
    except btfscan.MissingBTF as e:
        if a.allow_no_btf:
            out["waivers"]["allow-no-btf"] = "build kernel has no BTF; accepted by --allow-no-btf"
            rep.warn("btf-kinds", f"no BTF in build kernel ({e}); allowed by --allow-no-btf")
        else:
            rep.error("btf-kinds", f"no BTF in build kernel: {e}")
    except btfscan.ScanError as e:
        rep.error("btf-kinds", f"BTF kind scan failed: {e}")
    # config binding: the .config must be the one embedded in this kernel image
    if kb is not None:
        emb = ikconfig(kb)
        if emb is None:
            if cfg.get("CONFIG_IKCONFIG") == "y":
                rep.error("config-binding", ".config has CONFIG_IKCONFIG=y but the kernel image has no embedded config")
            elif wi:
                out["waivers"]["ikconfig"] = wi
                rep.warn("config-binding", f".config not bound to the image (no IKCONFIG); waived: {wi}")
            else:
                rep.error("config-binding", "kernel image has no embedded config (CONFIG_IKCONFIG) to bind the supplied .config to it (use --waive-ikconfig REASON)")
        elif emb != cfg_bytes:
            rep.error("config-binding", "supplied .config differs from the config embedded in the kernel image (IKCONFIG)",
                      [f"embedded sha256 {sha256_bytes(emb)}, supplied sha256 {sha256_bytes(cfg_bytes)}"])
        else:
            rep.ok("config-binding", f"supplied .config is byte-identical to the image's embedded IKCONFIG ({len(emb)} bytes)")
    else:
        rep.error("config-binding", "kernel image could not be decoded; .config not bound")
    # input binding: Module.symvers and kernel image come from this vmlinux
    if a.vmlinux:
        vm = Vmlinux(a.vmlinux)
        try:
            mm = vm.mm
            if cfg.get("CONFIG_MODULE_REL_CRCS") == "y":
                raise GateError("CONFIG_MODULE_REL_CRCS=y (relative __kcrctab entries) is not supported")
            I["vmlinux"].update({"ksymtab_exports": len(vm.exports), "symtab_crc_symbols": len(vm.crcs)})
            probs = []
            if not vm.exports:
                probs.append("vmlinux has no __ksymtab/__kcrctab export tables")
            for s_, r in sorted(vml.items()):
                ex = vm.exports.get(s_)
                if ex is None:
                    probs.append(f"{s_}: in Module.symvers but not in vmlinux's (Image) __ksymtab tables")
                    continue
                if ex[2] != r["crc"]:
                    probs.append(f"{s_}: Module.symvers 0x{r['crc']:08x} vs runtime __kcrctab 0x{ex[2]:08x}")
                if ex[0] != r["type"]:
                    probs.append(f"{s_}: Module.symvers export type {r['type']} vs the __ksymtab table holding it ({ex[0]})")
                if ex[1] != r["ns"]:
                    probs.append(f"{s_}: Module.symvers namespace {r['ns'] or '-'} vs __ksymtab namespace {ex[1] or '-'}")
            for s_ in sorted(set(vm.exports) - set(vml)):
                probs.append(f"{s_}: exported by vmlinux's (Image) __ksymtab tables but no vmlinux row in Module.symvers")
            probs += [f".symtab cross-check: {c}" for c in vm.cross]
            if kb is not None:
                bi, bv_ = banner(kb), banner(mm)
                if bi is None or bi != bv_:
                    probs.append(f"kernel image banner {bi!r} != vmlinux banner {bv_!r}")
                seg = image_vs_vmlinux(kb, vm)
                if seg:
                    probs.append(seg)
                lv, nks = vm.loader_view_problems(kb, (profile or {}).get("build_sections"))
                probs += [f"loader view: {x}" for x in lv]
                I["vmlinux"]["kallsyms_symbols"] = nks
                if profile is not None and "build_sections" not in profile:
                    probs.append("profile pins no build_sections (allocated section set of the stock build)")
                ev = ikconfig(mm)
                if ev is not None and ev != cfg_bytes:
                    probs.append("vmlinux embedded IKCONFIG differs from the supplied .config")
                if res is not None:
                    try:
                        vres = btfscan.scan_bytes(mm)
                        if vres["blob_sha256"] != res["blob_sha256"]:
                            probs.append("BTF blob in kernel image differs from vmlinux .BTF")
                    except btfscan.ScanError as e:
                        probs.append(f"vmlinux BTF: {e}")
        finally:
            vm.close()
        if probs:
            rep.error("input-binding", f"inputs do not belong to one build ({len(probs)} inconsistencies)", probs)
        else:
            rep.ok("input-binding", f"Module.symvers vmlinux rows equal the {len(vm.exports)} decoded entries of the __ksymtab*/__kcrctab* "
                   "tables (name, CRC, type, namespace; both ways); kernel image equals objcopy -O binary of vmlinux (exact length, gaps "
                   "zero); in the Image's own kallsyms, __start/__stop___ksymtab* and __start___kcrctab* equal the decoded tables' bounds and "
                   "every entry's address equals its symbol's kallsyms address; tables sorted; sections end before _edata and match the "
                   "pinned section set; .symtab agrees (cross-check); banner, IKCONFIG" + (" and BTF blob" if res is not None else "") + " match")
    else:
        rep.skip("input-binding", "no --vmlinux given (report-only)")


# --------------------------------------------------------------------------

def _drop_stale_json(argv):
    """Remove any --json target before argument parsing, so even a usage error
    (argparse exit 2) cannot leave an older PASS result behind."""
    argv = sys.argv[1:] if argv is None else argv
    for i, t in enumerate(argv):
        path = argv[i + 1] if t == "--json" and i + 1 < len(argv) else (t[7:] if t.startswith("--json=") else None)
        if path and os.path.lexists(path) and not os.path.isdir(path):
            os.unlink(path)


def main(argv=None):
    _drop_stale_json(argv)
    ap = argparse.ArgumentParser(description="FrameShift offline kernel symbol-version gate. Exit 0 PASS, 1 FAIL, 2 ERROR, 3 REPORT-ONLY (not a pass).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("reference", help="build the reference from stock images")
    r.add_argument("--out", required=True, help="output directory (reference.json, required_crcs.txt, inventory.tsv)")
    r.add_argument("--device", required=True, help="device name recorded in the reference (must match the profile)")
    r.add_argument("--profile", help="device profile JSON: declared sources, pinned counts (required unless --bootstrap)")
    r.add_argument("--bootstrap", action="store_true", help="no profile: produce an UNPINNED reference; exits 3, never 0")
    r.add_argument("--vendor-boot", action="append", metavar="[LABEL=]IMG", help="vendor_boot image (all vendor ramdisks)")
    r.add_argument("--boot", action="append", metavar="[LABEL=]IMG", help="boot image (generic ramdisk; zero modules allowed)")
    r.add_argument("--ext4", action="append", metavar="LABEL=IMG", help="ext4 image; modules under --modules-path (vendor_dlkm, odm_dlkm, vendor)")
    r.add_argument("--dir", action="append", metavar="LABEL=DIR", help="pre-extracted directory (no image hash; symlinks are an ERROR)")
    r.add_argument("--modules-path", default="/lib/modules", help="module directory inside ext4 images (default /lib/modules)")
    r.add_argument("--stock-kernel", help="stock boot.img/Image for the allowed BTF kind set (required)")
    r.add_argument("--allow-no-stock-btf", action="store_true", help="accept a stock kernel without BTF (allowed kind set empty)")
    r.add_argument("--allow-same-name-differing", action="store_true", help="use ALL copies of same-name/same-modname modules with differing content instead of ERROR")
    r.add_argument("--require-modprobe", action="store_true", help="ERROR if modprobe is unavailable for the __versions cross-check")
    r.add_argument("--json", help="write summary JSON")
    c = sub.add_parser("check", help="gate a build against a pinned reference")
    c.add_argument("--reference", required=True, help="reference.json from 'kgate.py reference'")
    c.add_argument("--device", required=True, help="device this build is for; must equal the reference's and the profile's device")
    c.add_argument("--profile", help="device profile JSON: pinned reference sha256, counts, per-build pins (required in gate mode)")
    c.add_argument("--require-committed-profile", action="store_true",
                   help="(default in gate mode) ERROR unless the profile equals its committed git blob at HEAD -- the profile is the trust root")
    c.add_argument("--waive-committed-profile", metavar="REASON", help="opt out of the committed-profile requirement (recorded waiver)")
    c.add_argument("--build", help="name of this build in the profile's 'builds' pins, e.g. stock, a2 (required in gate mode)")
    c.add_argument("--stock-kernel", help="stock kernel for re-deriving the allowed BTF kinds (default: path recorded in the reference)")
    c.add_argument("--symvers", required=True, help="build Module.symvers")
    c.add_argument("--vmlinux", help="build vmlinux (required in gate mode). Checked: the kernel image equals objcopy -O binary of it; Module.symvers "
                   "vmlinux rows equal the entries of its allocated __ksymtab*/__kcrctab* tables (name, runtime CRC, type, namespace); "
                   ".symtab __crc_/__ksymtab_ symbols cross-checked; banner, BTF blob and IKCONFIG match")
    c.add_argument("--kernel", required=True, help="build kernel (Image, Image.gz, vmlinux or boot.img)")
    c.add_argument("--config", required=True, help="build .config (after olddefconfig); must be byte-identical to the image's embedded IKCONFIG")
    c.add_argument("--baseline-symvers", help="baseline Module.symvers; existing vmlinux exports must not change/disappear (required in gate mode unless waived)")
    c.add_argument("--waive-baseline", metavar="REASON", help="waive the baseline check (recorded); only for the stock-config build (--requested containing only --none)")
    c.add_argument("--requested", help="scripts/config-style request list (required in gate mode; a file containing only --none requests nothing)")
    c.add_argument("--requested-config", help="base config = the device's stock config; must parse-equal the IKCONFIG of the pinned stock kernel (required in gate mode)")
    c.add_argument("--allow-config-changes", metavar="FILE", help="explicit allowlist (.config syntax, exact values) of unrequested config differences, e.g. select fallout of a request")
    c.add_argument("--waive-ikconfig", metavar="REASON", help="accept a kernel without IKCONFIG (the .config is then not bound to the image)")
    c.add_argument("--allow-no-btf", action="store_true", help="accept a build kernel without BTF (WARN instead of ERROR)")
    c.add_argument("--report-only", action="store_true", help="enforcement inputs optional; exit 3 instead of 0 -- NEVER a gate pass")
    c.add_argument("--label", default=None, help="label recorded in the output")
    c.add_argument("--json", help="write result JSON")
    for p in (r, c):
        p.add_argument("--internal-crash-test", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    global JSON_PATH
    JSON_PATH = a.json
    if a.json and os.path.lexists(a.json):
        os.unlink(a.json)          # never leave a stale result behind
    if a.internal_crash_test:
        raise RuntimeError("internal crash test")
    return cmd_reference(a) if a.cmd == "reference" else cmd_check(a)


JSON_PATH = None


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:  # never let a traceback (exit 1) look like FAIL
        print(f"ERROR internal: {type(e).__name__}: {e}")
        print("RESULT: ERROR (exit 2) -- could not conclude -- build NOT accepted")
        if JSON_PATH:
            try:
                with open(JSON_PATH, "w") as fh:
                    json.dump({"result": "ERROR", "exit_code": EXIT_ERROR, "error": f"internal: {type(e).__name__}: {e}"}, fh)
            except OSError:
                pass
        sys.exit(EXIT_ERROR)
