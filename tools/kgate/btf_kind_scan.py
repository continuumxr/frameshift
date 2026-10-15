#!/usr/bin/env python3
"""BTF KIND SCANNER (FrameShift kgate).

Replaces relays/FS-A-006-raw/kernel-gate/btfkinds.py (FS-R-006 section 3).

What this is: a scanner that locates the vmlinux .BTF blob inside a kernel
file, checks that the blob is structurally well formed (header magic,
version, flags, lengths, section bounds, every type record walkable to the
exact end of the type section, every name offset inside the string section),
and counts the type KINDS present.  It can compare that kind set with an
allowed set (normally the kinds present in the stock kernel).

What this is NOT: BTF validation.  It does not resolve type references, check
member offsets/sizes, verify DATASEC/VAR consistency, or do anything the
kernel's btf_check_all_metas()/btf_check_all_types() verifier does.  A clean
kind scan must never be reported as "BTF validated".

Inputs: raw arm64 Image, gzip Image.gz, ELF vmlinux (uses the .BTF section),
or an Android boot.img (kernel extracted from the boot header; gzip or lz4
compressed kernels are decompressed).

Exit codes (standalone use; one of --allowed-from, --allowed, --scan-only is required):
  0  scan succeeded and (if an allowed set was given) no kinds beyond it
  1  FAIL: kinds present beyond the allowed set
  2  ERROR: no BTF (unless --allow-missing), malformed BTF, ambiguous (more
     than one candidate), any BTF signature that does not parse completely,
     unreadable/unsupported input
  3  SCAN-ONLY: --scan-only, kinds listed but nothing compared (never a pass)
"""
import argparse
import gzip
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import zlib

SCHEMA = "kgate-btf-kind-scan/1"
BTF_MAGIC = 0xEB9F
KIND_NAMES = {
    1: "INT", 2: "PTR", 3: "ARRAY", 4: "STRUCT", 5: "UNION", 6: "ENUM",
    7: "FWD", 8: "TYPEDEF", 9: "VOLATILE", 10: "CONST", 11: "RESTRICT",
    12: "FUNC", 13: "FUNC_PROTO", 14: "VAR", 15: "DATASEC", 16: "FLOAT",
    17: "DECL_TAG", 18: "TYPE_TAG", 19: "ENUM64",
}
NAME_TO_KIND = {v: k for k, v in KIND_NAMES.items()}
MAX_HDR_LEN = 1024          # far larger than any real header (24 today)


MAX_DECOMPRESSED = 256 << 20      # a kernel or ramdisk larger than this is treated as a decompression bomb


class ScanError(Exception):
    """Input could not be scanned (unreadable, unsupported, malformed)."""


class MissingBTF(ScanError):
    """No BTF header candidate found at all."""


def _extra_bytes(kind, vlen):
    """Bytes following the 12-byte btf_type for this kind (uapi/linux/btf.h)."""
    if kind == 1:            # INT: u32 encoding
        return 4
    if kind in (2, 7, 8, 9, 10, 11, 12, 16, 18):
        return 0
    if kind == 3:            # ARRAY: struct btf_array
        return 12
    if kind in (4, 5):       # STRUCT/UNION: btf_member[vlen]
        return 12 * vlen
    if kind == 6:            # ENUM: btf_enum[vlen]
        return 8 * vlen
    if kind == 13:           # FUNC_PROTO: btf_param[vlen]
        return 8 * vlen
    if kind == 14:           # VAR: btf_var
        return 4
    if kind == 15:           # DATASEC: btf_var_secinfo[vlen]
        return 12 * vlen
    if kind == 17:           # DECL_TAG: btf_decl_tag
        return 4
    if kind == 19:           # ENUM64: btf_enum64[vlen]
        return 12 * vlen
    return None


def parse_blob(buf, off, limit=None):
    """Parse and structurally check a BTF blob starting at buf[off].

    Returns a dict on success; raises ScanError describing the first defect.
    `limit` bounds the blob (e.g. ELF section end); default end of buffer.
    """
    end_avail = len(buf) if limit is None else limit
    if off + 24 > end_avail:
        raise ScanError(f"BTF header at 0x{off:x} truncated")
    magic, version, flags, hdr_len = struct.unpack_from("<HBBI", buf, off)
    if magic != BTF_MAGIC:
        raise ScanError(f"bad BTF magic 0x{magic:04x} at 0x{off:x}")
    if version != 1:
        raise ScanError(f"unsupported BTF version {version} at 0x{off:x}")
    if flags != 0:
        raise ScanError(f"nonzero BTF flags 0x{flags:x} at 0x{off:x}")
    if hdr_len < 24 or hdr_len > MAX_HDR_LEN:
        raise ScanError(f"implausible BTF hdr_len {hdr_len} at 0x{off:x}")
    if off + hdr_len > end_avail:
        raise ScanError(f"BTF header (hdr_len {hdr_len}) runs past end of input")
    type_off, type_len, str_off, str_len = struct.unpack_from("<IIII", buf, off + 8)
    if hdr_len > 24 and any(buf[off + 24: off + hdr_len]):
        raise ScanError("BTF header has nonzero bytes beyond the known 24-byte header")
    if type_off % 4:
        raise ScanError(f"type_off {type_off} not 4-byte aligned")
    if type_len % 4:
        raise ScanError(f"type_len {type_len} not a multiple of 4")
    if type_len == 0:
        raise ScanError("type section is empty")
    if str_len == 0:
        raise ScanError("string section is empty")
    data = off + hdr_len
    t0, t1 = data + type_off, data + type_off + type_len
    s0, s1 = data + str_off, data + str_off + str_len
    if t1 > end_avail or s1 > end_avail:
        raise ScanError(
            f"BTF sections out of bounds: types [0x{t0:x},0x{t1:x}) strings "
            f"[0x{s0:x},0x{s1:x}) input end 0x{end_avail:x}")
    if not (t1 <= s0 or s1 <= t0):
        raise ScanError("type and string sections overlap")
    if buf[s0] != 0:
        raise ScanError("string section does not start with NUL")
    if buf[s1 - 1] != 0:
        raise ScanError("string section does not end with NUL")
    counts = {}
    p, n = t0, 0
    while p < t1:
        if p + 12 > t1:
            raise ScanError(f"type record {n + 1} header truncated at 0x{p:x}")
        name_off, info = struct.unpack_from("<II", buf, p)
        vlen = info & 0xFFFF
        kind = (info >> 24) & 0x1F
        if (info >> 16) & 0xFF or (info >> 29) & 0x3:
            raise ScanError(f"type record {n + 1}: reserved info bits set (info=0x{info:08x})")
        if name_off >= str_len:
            raise ScanError(f"type record {n + 1}: name_off {name_off} beyond string section ({str_len})")
        extra = _extra_bytes(kind, vlen)
        if extra is None:
            raise ScanError(f"type record {n + 1}: unknown kind {kind} (cannot determine record size)")
        p += 12 + extra
        if p > t1:
            raise ScanError(f"type record {n + 1} ({KIND_NAMES[kind]}, vlen {vlen}) runs past end of type section")
        counts[kind] = counts.get(kind, 0) + 1
        n += 1
    blob_end = max(t1, s1)
    return {
        "offset": off,
        "hdr_len": hdr_len,
        "type_off": type_off, "type_len": type_len,
        "str_off": str_off, "str_len": str_len,
        "types": n,
        "kinds": {KIND_NAMES[k]: v for k, v in sorted(counts.items())},
        "blob_sha256": hashlib.sha256(bytes(buf[off:blob_end])).hexdigest(),
    }


def _elf_btf_section(buf):
    """Return (offset, size) of the .BTF section of an ELF file, or None."""
    if buf[:4] != b"\x7fELF":
        return None
    if len(buf) < 64:
        raise ScanError(f"ELF magic but only {len(buf)} bytes (truncated ELF header)")
    cls, data = buf[4], buf[5]
    if data != 1:
        raise ScanError("big-endian ELF not supported")
    if cls == 2:
        shoff, = struct.unpack_from("<Q", buf, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", buf, 0x3A)
        fmt, need = "<IIQQQQIIQQ", 64
    elif cls == 1:
        shoff, = struct.unpack_from("<I", buf, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", buf, 0x2E)
        fmt, need = "<IIIIIIIIII", 40
    else:
        raise ScanError(f"bad ELF class {cls}")
    if shoff == 0 or shnum == 0:
        raise ScanError("ELF has no section headers")
    if shentsize < need or shoff + shnum * shentsize > len(buf) or shstrndx >= shnum:
        raise ScanError("ELF section header table out of bounds")
    secs = []
    for i in range(shnum):
        f = struct.unpack_from(fmt, buf, shoff + i * shentsize)
        name, stype, off, size = f[0], f[1], f[4], f[5]
        secs.append((name, stype, off, size))
    _, _, stroff, strsize = secs[shstrndx]
    if stroff + strsize > len(buf):
        raise ScanError("ELF shstrtab out of bounds")
    found = []
    for name, stype, off, size in secs:
        if name >= strsize:
            raise ScanError("ELF section name offset out of bounds")
        e = buf.find(b"\0", stroff + name, stroff + strsize)
        if e < 0:
            raise ScanError("ELF section name not terminated")
        if bytes(buf[stroff + name:e]) == b".BTF":
            if stype == 8:   # SHT_NOBITS
                raise ScanError(".BTF section is NOBITS")
            if off + size > len(buf):
                raise ScanError(".BTF section out of bounds")
            found.append((off, size))
    if len(found) > 1:
        raise ScanError("ELF has more than one .BTF section")
    return found[0] if found else ("noelfbtf", 0)


def _lz4_decompress(data, what="input", cap=MAX_DECOMPRESSED):
    """lz4 -dc with the output capped (read in chunks; the process is killed beyond cap)."""
    import tempfile
    lz4 = shutil.which("lz4") or next((c for c in ("/usr/bin/lz4", "/bin/lz4") if os.access(c, os.X_OK)), None)
    if not lz4:
        raise ScanError(f"{what}: lz4-compressed but no lz4 tool found")
    with tempfile.NamedTemporaryFile(prefix="kgate-lz4-") as tf:
        tf.write(data)
        tf.flush()
        try:
            pr = subprocess.Popen([lz4, "-dc", tf.name], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            raise ScanError(f"{what}: cannot run lz4: {e}")
        out = bytearray()
        while True:
            chunk = pr.stdout.read(1 << 20)
            if not chunk:
                break
            out += chunk
            if len(out) > cap:
                pr.kill()
                pr.wait()
                raise ScanError(f"{what}: lz4 output exceeds {cap} bytes (decompression bomb?)")
        err = pr.stderr.read()
        rc = pr.wait()
    if rc != 0 or not out:
        raise ScanError(f"{what}: lz4 decompression failed (rc={rc}): {err.decode(errors='replace').strip()[:200]}")
    return bytes(out)


def gunzip_capped(data, what, multi=False, cap=MAX_DECOMPRESSED):
    """gzip with the output capped.  multi=False: exactly one member plus zero
    padding (kernel Image.gz).  multi=True: concatenated members (initramfs)."""
    out = bytearray()
    while True:
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            out += d.decompress(data, cap + 1 - len(out))
        except zlib.error as e:
            raise ScanError(f"{what}: gzip decompression failed: {e}")
        if len(out) > cap or d.unconsumed_tail:
            raise ScanError(f"{what}: gzip output exceeds {cap} bytes (decompression bomb?)")
        if not d.eof:
            raise ScanError(f"{what}: gzip decompression failed: truncated gzip stream")
        data = d.unused_data
        if not any(data):
            return bytes(out)
        if not multi:
            kind = "a second gzip member" if data.lstrip(b"\0")[:2] == b"\x1f\x8b" else "non-zero trailing data"
            raise ScanError(f"{what}: gzip decompression failed: {kind} after the first member (only one member plus zero padding is accepted)")
        data = data.lstrip(b"\0")
        if data[:2] != b"\x1f\x8b":
            raise ScanError(f"{what}: gzip decompression failed: non-gzip data after a member")


def decompress_auto(data, what):
    """Return (bytes, compression) for gzip/lz4/raw data."""
    if data[:2] == b"\x1f\x8b":
        # Exactly ONE complete gzip member, optionally followed by zero padding.
        # A second member is rejected: a bootloader that inflates one member
        # would load only part of what gzip.decompress() would join.
        return gunzip_capped(data, what, multi=False), "gzip"
    if data[:4] in (b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18"):
        return _lz4_decompress(data, what), "lz4"
    return data, "none"


def android_boot_kernel(buf):
    """Extract the kernel payload from an Android boot image (header v0-v4)."""
    if len(buf) < 1648 or buf[:8] != b"ANDROID!":
        raise ScanError("not an Android boot image")
    kernel_size, = struct.unpack_from("<I", buf, 8)
    hv, = struct.unpack_from("<I", buf, 40)
    if hv >= 3:
        page = 4096
    else:
        page, = struct.unpack_from("<I", buf, 36)
        if page not in (2048, 4096, 8192, 16384):
            raise ScanError(f"boot image page_size {page} implausible")
    if hv > 4:
        raise ScanError(f"unsupported boot header version {hv}")
    if kernel_size == 0 or page + kernel_size > len(buf):
        raise ScanError(f"boot image kernel_size {kernel_size} out of bounds")
    return bytes(buf[page:page + kernel_size]), hv


def load_kernel(path):
    """Read a kernel file; return (bytes, description)."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        raise ScanError(f"cannot read {path}: {e}")
    if not raw:
        raise ScanError(f"{path}: empty file")
    desc = []
    if raw[:8] == b"ANDROID!":
        raw, hv = android_boot_kernel(raw)
        desc.append(f"android-boot-v{hv}")
    raw, comp = decompress_auto(raw, path)
    if comp != "none":
        desc.append(comp)
    return raw, "+".join(desc) or "raw"


def scan_bytes(buf, allow_missing=False):
    """Locate and parse the BTF blob.  Returns a result dict or raises ScanError."""
    try:
        return _scan_bytes(buf)
    except (struct.error, IndexError, ValueError, OverflowError, UnicodeError) as e:
        raise ScanError(f"malformed input ({type(e).__name__}: {e})")


def _scan_bytes(buf):
    elf = _elf_btf_section(buf)
    if elf and elf[0] != "noelfbtf":
        off, size = elf
        res = parse_blob(buf, off, limit=off + size)
        res["located_by"] = "ELF .BTF section"
        return res
    if elf:
        # ELF without a .BTF section: report missing (do not raw-scan an ELF).
        raise MissingBTF("ELF file has no .BTF section")
    # Raw scan: EVERY occurrence of magic|version=1|flags=0 is a candidate and
    # must parse completely; one that does not (including an implausible
    # hdr_len) is malformed -> ERROR.  Nothing is silently skipped, so a
    # corrupted real blob can never be reported as "no BTF".
    sig = struct.pack("<HBB", BTF_MAGIC, 1, 0)
    good, bad, i = [], [], 0
    while True:
        i = buf.find(sig, i)
        if i < 0:
            break
        try:
            good.append(parse_blob(buf, i))
        except ScanError as e:
            bad.append((i, str(e)))
        i += 1
    if bad:
        raise ScanError("malformed BTF candidate(s): " + "; ".join(f"0x{o:x}: {m}" for o, m in bad[:5]))
    if not good:
        raise MissingBTF("no BTF header found")
    if len(good) > 1:
        raise ScanError("ambiguous: %d well-formed BTF blobs at %s" % (len(good), ", ".join(hex(g["offset"]) for g in good)))
    good[0]["located_by"] = "raw scan (single well-formed candidate)"
    return good[0]


def scan_file(path):
    try:
        buf, desc = load_kernel(path)
    except (struct.error, IndexError, ValueError, OverflowError) as e:
        raise ScanError(f"{path}: malformed input ({type(e).__name__}: {e})")
    res = scan_bytes(buf)
    res["input"] = path
    res["container"] = desc
    return res


def parse_allowed(spec):
    kinds = set()
    for tok in spec.replace(",", " ").split():
        t = tok.upper()
        if t not in NAME_TO_KIND:
            raise ScanError(f"unknown BTF kind name {tok!r}")
        kinds.add(t)
    if not kinds:
        raise ScanError("empty allowed-kind list")
    return kinds


JSON_PATH = None


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
    global JSON_PATH
    ap = argparse.ArgumentParser(description="BTF KIND SCANNER (not BTF validation). Exit 0 ok, 1 FAIL (kinds beyond allowed), "
                                 "2 ERROR, 3 scan-only (no comparison; not a pass).")
    ap.add_argument("kernel", help="Image, Image.gz, vmlinux or Android boot.img")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--allowed-from", metavar="STOCK_KERNEL", help="allowed kinds = kinds present in this (stock) kernel")
    g.add_argument("--allowed", metavar="KINDS", help="comma-separated allowed kind names, e.g. INT,PTR,STRUCT")
    g.add_argument("--scan-only", action="store_true", help="only list kinds; exits 3 (never 0) because nothing was compared")
    ap.add_argument("--allow-missing", action="store_true", help="treat 'no BTF found' as success (explicit opt-in)")
    ap.add_argument("--json", metavar="FILE", help="write machine-readable result")
    ap.add_argument("--internal-crash-test", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    JSON_PATH = a.json
    if a.json and os.path.lexists(a.json):
        os.unlink(a.json)          # never leave a stale result behind
    if a.internal_crash_test:
        raise RuntimeError("internal crash test")
    out = {"schema": SCHEMA, "note": "kind scan only; not BTF validation"}
    rc = 0
    try:
        allowed = None
        if a.allowed_from:
            st = scan_file(a.allowed_from)
            allowed = set(st["kinds"])
            out["allowed_source"] = {"file": a.allowed_from, "kinds": sorted(allowed), "blob_sha256": st["blob_sha256"]}
            print(f"allowed kinds from {a.allowed_from}: {', '.join(sorted(allowed))}")
        elif a.allowed:
            allowed = parse_allowed(a.allowed)
        try:
            res = scan_file(a.kernel)
            out["scan"] = res
            print(f"{a.kernel}: BTF at 0x{res['offset']:x} ({res['located_by']}; {res['container']}), "
                  f"{res['types']} types; kinds: " + ", ".join(f"{k}={v}" for k, v in res["kinds"].items()))
            if allowed is not None:
                beyond = sorted(set(res["kinds"]) - allowed)
                out["kinds_beyond_allowed"] = beyond
                if beyond:
                    print(f"FAIL btf-kinds: kinds beyond allowed set: {', '.join(beyond)}")
                    rc = 1
                else:
                    print("PASS btf-kinds: no kinds beyond allowed set")
            else:
                print("SCAN-ONLY btf-kinds: no allowed set given; nothing compared (exit 3, not a pass)")
                rc = 3
        except MissingBTF as e:
            if a.allow_missing:
                print(f"WARN btf: {a.kernel}: {e} (allowed by --allow-missing)")
                out["scan"] = None
                out["missing_allowed"] = True
            else:
                raise
    except ScanError as e:
        print(f"ERROR btf: {e}")
        out["error"] = str(e)
        rc = 2
    out["result"] = {0: "PASS", 1: "FAIL", 2: "ERROR", 3: "SCAN-ONLY"}[rc]
    out["exit_code"] = rc
    if a.json:
        try:
            with open(a.json, "w") as fh:
                json.dump(out, fh, indent=1, sort_keys=True)
        except OSError as e:
            print(f"ERROR json: cannot write {a.json}: {e}")
            rc = 2
    return rc


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:  # never let a traceback (exit 1) look like FAIL
        print(f"ERROR internal: {type(e).__name__}: {e}")
        if JSON_PATH:
            try:
                with open(JSON_PATH, "w") as fh:
                    json.dump({"schema": SCHEMA, "result": "ERROR", "exit_code": 2, "error": f"internal: {type(e).__name__}: {e}"}, fh)
            except OSError:
                pass
        sys.exit(2)
