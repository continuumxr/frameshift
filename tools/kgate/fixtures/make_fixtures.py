#!/usr/bin/env python3
"""Generate the synthetic kgate fixtures (no Meta/Valve binaries).

    python3 -I make_fixtures.py OUTDIR

Writes deterministic files into OUTDIR (the committed copy lives in
fixtures/data/).  ext4 images are NOT written here (they need mke2fs and are
not byte-deterministic); the module trees for them are written under
OUTDIR/trees/<name>/ and test_kgate.py builds the images with `mke2fs -d`
(adding the symlinks, which git on Windows would not preserve).

Synthetic world:
  modA.ko  (vendor_boot ramdisk, also copied into vendor_dlkm): imports
           module_layout, sym_a, sym_b, vend_x (vend_x is exported by modB)
  modB.ko  (vendor_dlkm): imports module_layout, sym_c, ns_sym (namespace
           TESTNS, declared via import_ns); exports vend_x
  modC.ko  (vendor_dlkm, license "Proprietary"): imports module_layout,
           sym_d; also has an UNVERSIONED undefined symbol unv_sym
  required from vmlinux: module_layout sym_a sym_b sym_c sym_d ns_sym (6)
  presence-only (unversioned): unv_sym
Each build-config variant gets its own kernel Image (with the config embedded
as IKCONFIG) and a matching vmlinux whose PT_LOAD segment is that Image.
"""
import gzip
import hashlib
import json
import os
import struct
import sys

sys.dont_write_bytecode = True

ML = 0x11111111
CRC = {"module_layout": ML, "sym_a": 0xAAAA0001, "sym_b": 0xAAAA0002, "sym_c": 0xAAAA0003,
       "ns_sym": 0xAAAA0004, "sym_d": 0xAAAA0005, "vend_x": 0xBBBB0001, "vend_s": 0xBBBB0002}
VERMAGIC = "5.10.999-fixture SMP preempt mod_unload modversions aarch64"


# ---------------------------------------------------------------- ELF .ko
def make_ko(name, versions, exports=(), undefined=(), weak=(), license="GPL v2", import_ns=(), vermagic=VERMAGIC,
            with_versions=True, extra_modinfo=(), machine=183, export_via="symbol", ksymtab_strings=None,
            nameless_export_table=False):
    modinfo = b""
    for k, v in [("license", license), ("name", name), ("vermagic", vermagic)] + [("import_ns", n) for n in import_ns] + list(extra_modinfo):
        modinfo += f"{k}={v}".encode() + b"\0"
    vers = b"".join(struct.pack("<Q", c) + s.encode().ljust(56, b"\0") for s, c in versions)
    strtab = b"\0"
    syms = [struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)]

    def sname(n):
        nonlocal strtab
        off = len(strtab)
        strtab += n.encode() + b"\0"
        return off
    # sections: 0 null, 1 .modinfo, 2 __versions, 3 __ksymtab(-ish), 4 .symtab, 5 .strtab, 6 .shstrtab, [7 __ksymtab_strings]
    sec3_name = b"__ksymtab"
    sec3 = b""
    if exports and export_via == "symbol":
        sec3 = b"\0" * (12 * len(exports))
        for i, e in enumerate(exports):
            syms.append(struct.pack("<IBBHQQ", sname("__ksymtab_" + e), (1 << 4) | 1, 0, 3, 12 * i, 12))
    elif exports and export_via == "section":
        sec3_name = ("___ksymtab+" + exports[0]).encode()     # one per-symbol section, no __ksymtab_ symbol
        sec3 = b"\0" * 12
    if nameless_export_table:
        sec3 = b"\0" * 12
    for u in undefined:
        syms.append(struct.pack("<IBBHQQ", sname(u), (1 << 4) | 0, 0, 0, 0, 0))
    for w in weak:
        syms.append(struct.pack("<IBBHQQ", sname(w), (2 << 4) | 0, 0, 0, 0, 0))
    symtab = b"".join(syms)
    secnames = [b"", b".modinfo", b"__versions" if with_versions else b".not_versions", sec3_name, b".symtab", b".strtab", b".shstrtab"]
    bodies = [b"", modinfo, vers if vers else b"\0" * 64, sec3, symtab, strtab]
    types = [0, 1, 1, 1, 2, 3, 3]
    if ksymtab_strings is not None:
        secnames.append(b"__ksymtab_strings")
        types.append(1)
    shstr = b"\0"
    name_off = []
    for n in secnames:
        if n:
            name_off.append(len(shstr))
            shstr += n + b"\0"
        else:
            name_off.append(0)
    bodies.append(shstr)
    if ksymtab_strings is not None:
        bodies.append(b"".join(x.encode() + b"\0" for x in ksymtab_strings))
    out = bytearray(64)
    offs = []
    for b in bodies:
        while len(out) % 8:
            out += b"\0"
        offs.append(len(out))
        out += b
    while len(out) % 8:
        out += b"\0"
    shoff = len(out)
    for i, b in enumerate(bodies):
        link = 5 if i == 4 else 0
        info = 1 if i == 4 else 0
        entsize = 24 if i == 4 else 0
        flags = 2 if i in (1, 2, 3, 7) else 0
        out += struct.pack("<IIQQQQIIQQ", name_off[i], types[i], flags, 0, offs[i] if i else 0, len(b) if i else 0, link, info, 8 if i else 0, entsize)
    hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
    hdr += struct.pack("<HHIQQQIHHHHHH", 1, machine, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(bodies), 6)
    out[0:64] = hdr
    return bytes(out)


def v(*names, **over):
    return [(n, over.get(n, CRC[n])) for n in names]


def modA(**kw):
    return make_ko("modA", v("module_layout", "sym_a", "sym_b", "vend_x"), undefined=["sym_a", "sym_b", "vend_x"], **kw)


def modB():
    return make_ko("modB", v("module_layout", "sym_c", "ns_sym"), exports=["vend_x"], undefined=["sym_c", "ns_sym"], import_ns=["TESTNS"])


def modC():
    return make_ko("modC", v("module_layout", "sym_d"), undefined=["sym_d", "unv_sym"], weak=["weak_opt"], license="Proprietary")


# ---------------------------------------------------------------- cpio / images
def cpio_newc(entries):
    """entries: list of (path, mode, data); a symlink's data is its target."""
    out = bytearray()
    ino = 1
    for path, mode, data in entries + [("TRAILER!!!", 0, b"")]:
        name = path.encode() + b"\0"
        hdr = b"070701" + b"".join(b"%08X" % x for x in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0))
        ino += 1
        out += hdr + name
        while len(out) % 4:
            out += b"\0"
        out += data
        while len(out) % 4:
            out += b"\0"
    return bytes(out)


def rd_entries(files, extra=()):
    ents = [("lib", 0o40755, b""), ("lib/modules", 0o40755, b"")]
    ents += [(f"lib/modules/{n}", 0o100644, d) for n, d in files]
    ents += list(extra)
    ents += [("init", 0o100755, b"#!/bin/sh\n")]
    return ents


def ramdisk(files, extra=()):
    return gzip.compress(cpio_newc(rd_entries(files, extra)), mtime=0)


def rnd(n, p=4096):
    return (n + p - 1) // p * p


def vendor_boot(ramdisk_bytes, magic=b"VNDRBOOT", truncate_table=False):
    page = 4096
    h = bytearray(page)
    h[0:8] = magic
    struct.pack_into("<IIIII", h, 8, 4, page, 0x8000, 0x1000000, len(ramdisk_bytes))
    struct.pack_into("<II", h, 2096, 2128, 0)
    struct.pack_into("<IIII", h, 2112, 108, 1, 108, 0)
    table = bytearray(108)
    struct.pack_into("<III", table, 0, len(ramdisk_bytes) - (16 if truncate_table else 0), 0, 1)
    table[12:12 + 9] = b"ramdisk00"
    return bytes(h) + ramdisk_bytes.ljust(rnd(len(ramdisk_bytes)), b"\0") + bytes(table).ljust(page, b"\0")


def boot_v2(kernel, ramdisk_bytes):
    page = 4096
    h = bytearray(page)
    h[0:8] = b"ANDROID!"
    struct.pack_into("<IIIIIIIII", h, 8, len(kernel), 0x8000, len(ramdisk_bytes), 0x1000000, 0, 0, 0x100, page, 2)
    struct.pack_into("<I", h, 1644, 1660)
    return bytes(h) + kernel.ljust(rnd(len(kernel)), b"\0") + ramdisk_bytes.ljust(rnd(len(ramdisk_bytes)), b"\0")


# ---------------------------------------------------------------- BTF
def btf_blob(extra_kind=False, break_bounds=False, break_record=False):
    strs = b"\0int\0foo\0bar\0fn\0"
    o = {"int": 1, "foo": 5, "bar": 9, "fn": 13}
    t = b""
    t += struct.pack("<III", o["int"], 1 << 24, 4) + struct.pack("<I", 32)            # INT
    t += struct.pack("<III", 0, 2 << 24, 1)                                           # PTR
    t += struct.pack("<III", o["foo"], (4 << 24) | (1000 if break_record else 1), 8)  # STRUCT
    t += struct.pack("<III", o["bar"], 2, 0)                                          #  member
    t += struct.pack("<III", 0, (13 << 24) | 1, 1) + struct.pack("<II", 0, 1)        # FUNC_PROTO
    t += struct.pack("<III", o["fn"], 12 << 24, 4)                                    # FUNC
    if extra_kind:
        t += struct.pack("<III", o["bar"], 17 << 24, 5) + struct.pack("<I", 0xFFFFFFFF)  # DECL_TAG
    str_len = len(strs) + (1 << 20 if break_bounds else 0)
    hdr = struct.pack("<HBBIIIII", 0xEB9F, 1, 0, 24, 0, len(t), len(t), str_len)
    return hdr + t + strs


def filler(n, seed):
    out = b""
    i = 0
    while len(out) < n:
        out += hashlib.sha256(f"{seed}-{i}".encode()).digest()
        i += 1
    return out[:n]


BANNER = b"Linux version 5.10.999-fixture (kgate@fixture) #1 SMP PREEMPT\n\0"


def kernel_image(blob=None, seed="k", banner=BANNER, config=None, vermagic=True):
    ik = b""
    if config is not None:
        ik = b"IKCFG_ST" + gzip.compress(config.encode(), mtime=0) + b"IKCFG_ED"
    vm = b""
    if vermagic:
        rel = banner.split(b" ")[2]
        flags = "SMP preempt mod_unload " + ("modversions " if (config is None or "CONFIG_MODVERSIONS=y" in config) else "") + "aarch64"
        vm = rel + b" " + flags.encode() + b"\0"
    return b"FIXTURE-ARM64-IMAGE\0" + filler(4076, seed) + banner + vm + ik + (blob or b"") + filler(1024, seed + "t")


SECNAMES = [".BTF", ".kallsyms", ".rodata", ".text", "__kcrctab", "__kcrctab_gpl", "__ksymtab", "__ksymtab_gpl", "__ksymtab_strings"]


def kallsyms_blob(syms, rb, layout):
    """scripts/kallsyms.c layout (base-relative): offsets, relative_base, num_syms,
    names, markers, token_table, token_index.  layout 8 = 4.19 (num_syms and markers
    are 8-byte PTR), layout 12 = 5.10 (.long).  Tokens are single bytes (valid, uncompressed).
    Returns (bytes, {label: offset within the blob})."""
    syms = sorted(syms, key=lambda x: (x[1], x[0]))
    N = len(syms)
    w = 8 if layout == 8 else 4
    out, lab = bytearray(), {}

    def align(n):
        while len(out) % n:
            out.append(0)
    lab["kallsyms_offsets"] = 0
    out += struct.pack("<%dI" % N, *[a - rb for _n, a in syms])
    align(8)
    lab["kallsyms_relative_base"] = len(out)
    out += struct.pack("<Q", rb)
    lab["kallsyms_num_syms"] = len(out)
    out += struct.pack("<Q" if w == 8 else "<I", N)
    align(8)
    lab["kallsyms_names"] = len(out)
    starts = []
    nb = bytearray()
    for n_, _a in syms:
        starts.append(len(nb))
        enc = b"T" + n_.encode()
        nb += bytes([len(enc)]) + enc
    out += nb
    align(8)
    lab["kallsyms_markers"] = len(out)
    out += struct.pack("<%d%s" % ((N + 255) // 256, "Q" if w == 8 else "I"), *starts[::256])
    align(8)
    lab["kallsyms_token_table"] = len(out)
    tt, ti = bytearray(), []
    for i in range(256):
        ti.append(len(tt))
        tt += (bytes([i]) if i else b"@") + b"\0"
    out += tt
    align(2)
    lab["kallsyms_token_index"] = len(out)
    out += struct.pack("<256H", *ti)
    return bytes(out), lab


def make_kernel(base, rows, btf=None, gap=None, kcrc=None, symtab_crc=None, hide=(), forge_shndx=None, layout=12,
                decoy=False, swap=False, redir=None, edata_short=False, extra_section=False):
    """Return (Image, vmlinux).  Image = `base` + the export tables (__ksymtab,
    __ksymtab_gpl, __kcrctab, __kcrctab_gpl, __ksymtab_strings) + kallsyms,
    all allocated sections, i.e. exactly what objcopy -O binary of vmlinux gives.
      layout 12: 5.10 PREL32 {value,name,ns}; layout 8: 4.19 PREL32 {value,name}
      gap=(off,len)            base bytes [off,off+len) belong to no section
      kcrc={sym: crc}          runtime __kcrctab value differs (tables + Image)
      symtab_crc={sym: crc}    only .symtab __crc_ differs
      hide={sym}               .symtab lacks __crc_/__ksymtab_ for sym
      forge_shndx={sym: sec}   .symtab __ksymtab_sym claims another section
      decoy                    section headers point at a decoy copy of the tables
                               (original CRCs); kallsyms __start/__stop at the real
                               tables, whose sym_a CRC is altered
      swap                     first two __ksymtab entries swapped (unsorted)
      redir=sym                sym's entry points at another symbol's address
      edata_short              kallsyms _edata placed before the export tables
      extra_section            an additional allocated section '.decoy'"""
    vrows = sorted((r for r in rows if r[2] == "vmlinux"), key=lambda r: r[1])
    VA = 0xFFFFFFC008000000
    E = layout
    img = bytearray(base)
    while len(img) % 16:
        img += b"\0"
    plain = [r for r in vrows if r[3] != "EXPORT_SYMBOL_GPL"]
    gpl = [r for r in vrows if r[3] == "EXPORT_SYMBOL_GPL"]
    if swap and len(plain) > 1:
        plain[0], plain[1] = plain[1], plain[0]
    target = {r[1]: VA + 0x200 + 8 * i for i, r in enumerate(vrows)}

    def tables_at(start, crcs):
        ks_off = start
        kg_off = ks_off + E * len(plain)
        kc_off = kg_off + E * len(gpl)
        kcg_off = kc_off + 4 * len(plain)
        kt_off = kcg_off + 4 * len(gpl)
        kstr, name_at, ns_at = b"", {}, {}
        for r in vrows:
            name_at[r[1]] = len(kstr)
            kstr += r[1].encode() + b"\0"
        for r in vrows:
            if r[4] and E == 12:
                ns_at[r[1]] = len(kstr)
                kstr += r[4].encode() + b"\0"
        t, addr = bytearray(), {}
        for rs, off, sec in ((plain, ks_off, "__ksymtab"), (gpl, kg_off, "__ksymtab_gpl")):
            for i, (_c, sym, _m, _t, ns) in enumerate(rs):
                ea = VA + off + E * i
                addr[sym] = (ea, sec)
                tg = target[redir_to] if (redir and sym == redir) else target[sym]
                no = (VA + kt_off + name_at[sym]) - (ea + 4)
                if E == 12:
                    nso = (VA + kt_off + ns_at[sym]) - (ea + 8) if ns else 0
                    t += struct.pack("<iii", tg - ea, no, nso)
                else:
                    t += struct.pack("<ii", tg - ea, no)
        for rs in (plain, gpl):
            for c, sym, _m, _t, _ns in rs:
                t += struct.pack("<I", crcs.get(sym, c))
        t += kstr
        lay = {"__ksymtab": (ks_off, E * len(plain)), "__ksymtab_gpl": (kg_off, E * len(gpl)),
               "__kcrctab": (kc_off, 4 * len(plain)), "__kcrctab_gpl": (kcg_off, 4 * len(gpl)), "__ksymtab_strings": (kt_off, len(kstr))}
        return bytes(t), lay, addr
    redir_to = None
    if redir:
        redir_to = next(r[1] for r in vrows if r[1] != redir)
    real_t, real_lay, real_addr = tables_at(len(img), dict(kcrc or {}, **({"sym_a": CRC["sym_a"] ^ 0x5A5A5A5A} if decoy else {})))
    img += real_t
    while len(img) % 16:
        img += b"\0"
    hdr_lay, hdr_addr = real_lay, real_addr
    if decoy:
        dt, d_lay, d_addr = tables_at(len(img), dict(kcrc or {}))
        img += dt
        while len(img) % 16:
            img += b"\0"
        hdr_lay, hdr_addr = d_lay, d_addr
    extra_off = None
    if extra_section:
        extra_off = len(img)
        img += b"DECOYSEC" * 2
    # kallsyms (its own size does not depend on the addresses)
    ksyms = [("_text", VA)] + [(r[1], target[r[1]]) for r in vrows]
    for nm, key in (("__ksymtab", "__ksymtab"), ("__ksymtab_gpl", "__ksymtab_gpl")):
        o, n = real_lay[key]
        ksyms += [(f"__start_{nm}", VA + o), (f"__stop_{nm}", VA + o + n)]
    ksyms += [("__start___kcrctab", VA + real_lay["__kcrctab"][0]), ("__start___kcrctab_gpl", VA + real_lay["__kcrctab_gpl"][0])]
    probe, _ = kallsyms_blob(ksyms + [("_edata", VA)], VA, layout)
    kal_off = len(img)
    end = kal_off + len(probe)
    edata = VA + (len(base) if edata_short else end)
    kal, lab = kallsyms_blob(ksyms + [("_edata", edata)], VA, layout)
    assert len(kal) == len(probe)
    img += kal
    image = bytes(img)
    # sections
    secs = [("", 0, 0, 0, 0, 0)]                               # name, type, flags, addr, image offset, size
    # disjoint pieces of base: .text [0,bo) .BTF [bo,bo+lb) (gap) .rodata [.., len(base))
    bo = base.find(btf) if btf else len(base)
    lb = len(btf) if btf else 0
    g0 = bo + lb + (gap or 0)
    secs.append((".text", 1, 6, VA, 0, bo))
    secs.append((".BTF", 1, 3, VA + bo, bo, lb))
    secs.append((".rodata", 1, 2, VA + g0, g0, len(base) - g0))
    idx = {}
    for nm in ("__ksymtab", "__ksymtab_gpl", "__kcrctab", "__kcrctab_gpl", "__ksymtab_strings"):
        o, n = hdr_lay[nm]
        idx[nm] = len(secs)
        secs.append((nm, 1, 2, VA + o, o, n))
    if extra_off is not None:
        secs.append((".decoy", 1, 2, VA + extra_off, extra_off, 16))
    i_kal = len(secs)
    secs.append((".kallsyms", 1, 2, VA + kal_off, kal_off, len(kal)))
    strtab = b"\0"
    syms = [struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)]

    def sname(n):
        nonlocal strtab
        o = len(strtab)
        strtab += n.encode() + b"\0"
        return o
    for c, sym, _m, _t, _ns in vrows:
        if sym in hide:
            continue
        syms.append(struct.pack("<IBBHQQ", sname(f"__crc_{sym}"), (1 << 4) | 0, 0, 0xFFF1, (symtab_crc or {}).get(sym, c), 0))
    for sym, (ea, sec) in sorted(hdr_addr.items()):
        if sym in hide:
            continue
        syms.append(struct.pack("<IBBHQQ", sname(f"__ksymtab_{sym}"), (0 << 4) | 1, 0, idx[(forge_shndx or {}).get(sym, sec)], ea, E))
    for k, o in sorted(lab.items()):
        syms.append(struct.pack("<IBBHQQ", sname(k), (1 << 4) | 1, 0, i_kal, VA + kal_off + o, 0))
    symtab = b"".join(syms)
    allnames = [x[0] for x in secs] + [".symtab", ".strtab", ".shstrtab"]
    shstr, noff = b"\0", []
    for n in allnames:
        noff.append(len(shstr) if n else 0)
        if n:
            shstr += n.encode() + b"\0"
    img_off = 0x1000
    out = bytearray(img_off) + bytearray(image)
    tail = []
    for b in (symtab, strtab, shstr):
        while len(out) % 8:
            out += b"\0"
        tail.append(len(out))
        out += b
    while len(out) % 8:
        out += b"\0"
    shoff = len(out)
    hdrs = [struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)]
    for i, (nm, t, fl, addr, off, size) in enumerate(secs[1:], 1):
        hdrs.append(struct.pack("<IIQQQQIIQQ", noff[i], t, fl, addr, img_off + off, size, 0, 0, 1, 0))
    i_sym = len(secs)
    hdrs.append(struct.pack("<IIQQQQIIQQ", noff[i_sym], 2, 0, 0, tail[0], len(symtab), i_sym + 1, 1, 8, 24))
    hdrs.append(struct.pack("<IIQQQQIIQQ", noff[i_sym + 1], 3, 0, 0, tail[1], len(strtab), 0, 0, 1, 0))
    hdrs.append(struct.pack("<IIQQQQIIQQ", noff[i_sym + 2], 3, 0, 0, tail[2], len(shstr), 0, 0, 1, 0))
    out += b"".join(hdrs)
    out[64:64 + 56] = struct.pack("<IIQQQQQQ", 1, 5, img_off, VA, VA, len(image), len(image) + 0x1000, 0x1000)
    hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
    hdr += struct.pack("<HHIQQQIHHHHHH", 2, 183, 1, VA, 64, shoff, 0, 64, 56, 1, 64, len(hdrs), len(hdrs) - 1)
    out[0:64] = hdr
    return image, bytes(out)


# ---------------------------------------------------------------- symvers / configs
def symvers(rows):
    return "".join(f"0x{c:08x}\t{s}\t{m}\t{t}\t{ns}\n" for c, s, m, t, ns in rows)


def good_rows():
    return [
        (ML, "module_layout", "vmlinux", "EXPORT_SYMBOL", ""),
        (CRC["sym_a"], "sym_a", "vmlinux", "EXPORT_SYMBOL", ""),
        (CRC["sym_b"], "sym_b", "vmlinux", "EXPORT_SYMBOL_GPL", ""),
        (CRC["sym_c"], "sym_c", "vmlinux", "EXPORT_SYMBOL", ""),
        (CRC["ns_sym"], "ns_sym", "vmlinux", "EXPORT_SYMBOL", "TESTNS"),
        (CRC["sym_d"], "sym_d", "vmlinux", "EXPORT_SYMBOL", ""),
        (0x12340001, "unv_sym", "vmlinux", "EXPORT_SYMBOL", ""),
        (0x12340002, "base_e1", "vmlinux", "EXPORT_SYMBOL", ""),
        (0x12340003, "base_e2", "vmlinux", "EXPORT_SYMBOL_GPL", ""),
        (0x12340004, "intree_sym", "drivers/fixture/intree", "EXPORT_SYMBOL", ""),
        (0x12340006, "added_sym", "vmlinux", "EXPORT_SYMBOL", ""),
    ]


def edit(rows, sym, **chg):
    out = []
    for r in rows:
        if r[1] == sym:
            r = (chg.get("crc", r[0]), r[1], chg.get("mod", r[2]), chg.get("typ", r[3]), chg.get("ns", r[4]))
        out.append(r)
    return out


CONFIG_GOOD = """#
# Automatically generated file; DO NOT EDIT.
#
CONFIG_CC_VERSION_TEXT="Android (8508608, based on r450784e) clang version 14.0.7"
CONFIG_CLANG_VERSION=140007
CONFIG_SMP=y
CONFIG_PREEMPT=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODVERSIONS=y
CONFIG_IKCONFIG=y
CONFIG_CFI_CLANG=y
CONFIG_DEVTMPFS=y
# CONFIG_DEVTMPFS_MOUNT is not set
CONFIG_AUTOFS_FS=m
CONFIG_LOCALVERSION=""
CONFIG_FIXTURE_VAL=a#b
CONFIG_VENDOR_ONLY_DRIVER=y
CONFIG_PAHOLE_VERSION=131
"""
# build-config variants: each gets Image_cfg_<name> and vmlinux_cfg_<name>
CONFIG_VARIANTS = {
    "good": CONFIG_GOOD,
    "no_modversions": CONFIG_GOOD.replace("CONFIG_MODVERSIONS=y", "# CONFIG_MODVERSIONS is not set"),
    "cc_change": CONFIG_GOOD.replace('clang version 14.0.7"', 'clang version 17.0.0"').replace("CONFIG_CLANG_VERSION=140007", "CONFIG_CLANG_VERSION=170000"),
    "extra_userns": CONFIG_GOOD + "CONFIG_USER_NS=y\nCONFIG_PID_NS=y\n",
    "cfi_off": CONFIG_GOOD.replace("CONFIG_CFI_CLANG=y", "# CONFIG_CFI_CLANG is not set"),
    "btrfs": CONFIG_GOOD + "CONFIG_BTRFS_FS=m\nCONFIG_XOR_BLOCKS=m\n",
    "no_ikconfig": CONFIG_GOOD.replace("CONFIG_IKCONFIG=y", "# CONFIG_IKCONFIG is not set"),
    "dropped": CONFIG_GOOD.replace("CONFIG_VENDOR_ONLY_DRIVER=y\n", ""),
}
STOCK_BASE = CONFIG_GOOD.replace("CONFIG_PAHOLE_VERSION=131", "CONFIG_PAHOLE_VERSION=0") + "# CONFIG_DROPPED_DRIVER is not set\n"


def write(base, rel, data):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(data if isinstance(data, bytes) else data.encode())


def generate(out):
    W = lambda rel, data: write(out, rel, data)
    A, B, C = modA(), modB(), modC()
    # ---- vendor_boot / boot images
    W("vendor_boot_good.img", vendor_boot(ramdisk([("modA.ko", A)])))
    W("vendor_boot_nomods.img", vendor_boot(ramdisk([])))
    W("vendor_boot_badmagic.img", vendor_boot(ramdisk([("modA.ko", A)]), magic=b"NOTVNDR!"))
    rd = ramdisk([("modA.ko", A)])
    W("vendor_boot_truncated.img", vendor_boot(rd[: len(rd) // 2]))
    cp = cpio_newc([("lib/modules/modA.ko", 0o100644, A)])
    W("vendor_boot_truncated_cpio.img", vendor_boot(gzip.compress(cp[: len(cp) - 200], mtime=0)))
    W("vendor_boot_table_short.img", vendor_boot(rd, truncate_table=True))
    W("vendor_boot_corrupt_ko.img", vendor_boot(ramdisk([("modA.ko", A[:0x28] + struct.pack("<Q", 0xFFFFFF00) + A[0x30:])])))
    W("vendor_boot_bad_vermagic.img", vendor_boot(ramdisk([("modA.ko", modA(vermagic="garbled"))])))
    W("vendor_boot_noversions.img", vendor_boot(ramdisk([("modN.ko", make_ko("modN", [], undefined=["sym_a"], with_versions=False))])))
    W("vendor_boot_modA_variant.img", vendor_boot(ramdisk([("modA.ko", modA(extra_modinfo=[("description", "variant build")]))])))
    W("vendor_boot_conflict.img", vendor_boot(ramdisk([("modA.ko", A), ("modA2.ko", make_ko("modA2", v("module_layout", "sym_a", sym_a=0xDEAD0001), undefined=["sym_a"]))])))
    W("vendor_boot_modname_dup.img", vendor_boot(ramdisk([("modA.ko", A), ("modA_alt.ko", modA(extra_modinfo=[("description", "alt")]))])))
    W("vendor_boot_ko_symlink.img", vendor_boot(ramdisk([("modA.ko", A)], [("lib/modules/modL.ko", 0o120777, b"modA.ko")])))
    W("vendor_boot_dir_symlink.img", vendor_boot(ramdisk([("modA.ko", A)], [("lib/extra", 0o40755, b""), ("lib/extra/modC.ko", 0o100644, C),
                                                                        ("lib/modules/extra", 0o120777, b"/lib/extra")])))
    W("vendor_boot_compressed_ko.img", vendor_boot(ramdisk([("modA.ko", A), ("modX.ko.xz", b"\xfd7zXZ\0fake")])))
    two = cpio_newc(rd_entries([("modA.ko", A)])) + cpio_newc([("lib/modules/modA.ko", 0o100644, modA(extra_modinfo=[("description", "second archive")]))])
    W("vendor_boot_dup_path.img", vendor_boot(gzip.compress(two, mtime=0)))
    W("vendor_boot_mixed_machine.img", vendor_boot(ramdisk([("modA.ko", A), ("modM.ko", make_ko("modM", v("module_layout", "sym_a"), undefined=["sym_a"], machine=62))])))
    W("vendor_boot_vermagic_flags.img", vendor_boot(ramdisk([("modA.ko", A), ("modV.ko", make_ko("modV", v("module_layout", "sym_a"), undefined=["sym_a"],
                                                                                                  vermagic="5.10.999-fixture SMP mod_unload modversions aarch64"))])))
    W("vendor_boot_plusexport.img", vendor_boot(ramdisk([("modA.ko", A), ("modS.ko", make_ko("modS", v("module_layout"), exports=["vend_s"], export_via="section")),
                                                         ("modT.ko", make_ko("modT", v("module_layout", "vend_s"), undefined=["vend_s"]))])))
    W("vendor_boot_ghost_export.img", vendor_boot(ramdisk([("modA.ko", A), ("modG.ko", make_ko("modG", v("module_layout"), exports=["vend_g"], ksymtab_strings=["vend_g", "ghost"]))])))
    W("vendor_boot_nameless_exports.img", vendor_boot(ramdisk([("modA.ko", A), ("modE.ko", make_ko("modE", v("module_layout"), nameless_export_table=True))])))
    W("vendor_boot_list_missing.img", vendor_boot(ramdisk([("modA.ko", A), ("modules.load", b"modA.ko\nmodZ.ko\n")])))
    good_blob = btf_blob()
    initrd = gzip.compress(cpio_newc([("init", 0o100755, b"#!/bin/sh\n")]), mtime=0)
    W("stock_boot.img", boot_v2(kernel_image(good_blob, "stock", config=STOCK_BASE), initrd))
    W("stock_boot_nobtf.img", boot_v2(kernel_image(None, "stocknb", config=STOCK_BASE), initrd))
    # ---- ext4 trees (images built by the test runner with mke2fs -d; symlinks added there)
    W("trees/vendor_dlkm/lib/modules/modA.ko", A)
    W("trees/vendor_dlkm/lib/modules/modB.ko", B)
    W("trees/vendor_dlkm/lib/modules/modC.ko", C)
    W("trees/vendor_dlkm/lib/modules/modules.load", "modA.ko\nmodB.ko\nmodC.ko\n")
    W("trees/vendor_dlkm/lib/modules/modules.dep", "modA.ko: modB.ko\nmodB.ko:\nmodC.ko:\n")
    W("trees/vendor_dlkm_symdir/lib/modules/modA.ko", A)
    W("trees/vendor_dlkm_symdir/lib/modules/modB.ko", B)
    W("trees/vendor_dlkm_symdir/lib/extra_mods/modC.ko", C)
    W("trees/vendor_dlkm_badlist/lib/modules/modA.ko", A)
    W("trees/vendor_dlkm_badlist/lib/modules/modB.ko", B)
    W("trees/vendor_dlkm_badlist/lib/modules/modC.ko", C)
    W("trees/vendor_dlkm_badlist/lib/modules/modules.dep", "modA.ko: modB.ko modQ.ko\n")
    W("trees/vendor_nomodules/etc/placeholder", "no lib/modules here\n")
    W("trees/vendor/etc/placeholder", "vendor partition\n")
    W("not_an_image.img", filler(8192, "garbage"))
    W("sparse.img", b"\x3a\xff\x26\xed" + b"\0" * 8188)
    W("erofs.img", b"\0" * 1024 + b"\xe2\xe1\xf5\xe0" + b"\0" * 7164)
    # ---- kernels: Image + vmlinux pairs (export tables inside the Image)
    g = good_rows()

    def K(name, base, rows, btf=good_blob, **kw):
        img_, vml_ = make_kernel(base, rows, btf, **kw)
        W(f"Image_{name}", img_)
        W(f"vmlinux_{name}", vml_)
        return img_
    for name, cfg in CONFIG_VARIANTS.items():
        K(f"cfg_{name}", kernel_image(good_blob, "build", config=None if name == "no_ikconfig" else cfg), g)
        W(f"config/{name}", cfg)
    base = kernel_image(good_blob, "build", config=CONFIG_GOOD)
    img = make_kernel(base, g, good_blob)[0]              # == Image_cfg_good
    W("Image_good.gz", gzip.compress(img, mtime=0))
    W("Image_good_trailing_junk.gz", gzip.compress(img, mtime=0) + b"JUNKJUNK")
    h = len(img) // 2
    W("Image_two_member.gz", gzip.compress(img[:h], mtime=0) + gzip.compress(img[h:], mtime=0))
    W("Image_truncated", img[:-100])
    W("Image_decoy_hdrlen", img + struct.pack("<HBBI", 0xEB9F, 1, 0, 4096) + b"\0" * 64)
    hb = bytearray(img)
    i = hb.find(struct.pack("<HBBI", 0xEB9F, 1, 0, 24))
    struct.pack_into("<I", hb, i + 4, 23)
    W("Image_hdrlen_corrupt", bytes(hb))
    gb = base.find(good_blob) + len(good_blob)
    K("gap_zero", base[:gb] + b"\0" * 100 + base[gb + 100:], g, gap=100)
    K("ksym_type", base, edit(g, "sym_b", typ="EXPORT_SYMBOL"))
    K("ksym_ns", base, edit(g, "ns_sym", ns=""))
    K("kcrc_tamper", base, g, kcrc={"sym_a": CRC["sym_a"] ^ 0x5A5A5A5A})
    K("hidden_export", base, g + [(CRC["vend_x"], "vend_x", "vmlinux", "EXPORT_SYMBOL", "")], hide={"vend_x"})
    K("forged_type", base, edit(g, "sym_d", typ="EXPORT_SYMBOL_GPL"), forge_shndx={"sym_d": "__ksymtab"})
    K("crc_disagrees", base, g, symtab_crc={"sym_a": 0x0BAD0001})
    K("other_build", base.replace(b"#1 SMP", b"#2 SMP"), g)
    tampered = bytearray(base)
    tampered[100] ^= 0xFF
    K("text_differs", bytes(tampered), g)
    K("early_text", base[:20] + b"Linux version \0" + base[35:], g)
    K("decoy_table", base, g, decoy=True)
    K("unsorted_table", base, g, swap=True)
    K("redirected_entry", base, g, redir="sym_a")
    K("past_edata", base, g, edata_short=True)
    K("extra_section", base, g, extra_section=True)
    b419 = BANNER.replace(b"5.10.999", b"4.19.999")
    K("layout419", kernel_image(good_blob, "build", banner=b419, config=CONFIG_GOOD), g, layout=8)
    K("layout_mismatch", kernel_image(good_blob, "build", banner=b419, config=CONFIG_GOOD), g, layout=12)
    K("no_vermagic", kernel_image(good_blob, "build", config=CONFIG_GOOD, vermagic=False), g)   # bare text before the real banner (as in the Quest 3 vmlinux)
    W("vmlinux_tiny", b"\x7fELF\x02\x01\x01\x00garbage")
    for name, blob in (("extrakind", btf_blob(extra_kind=True)), ("nobtf", None), ("malformed_bounds", btf_blob(break_bounds=True)),
                       ("malformed_record", btf_blob(break_record=True)), ("ambiguous", good_blob + b"\0" * 64 + good_blob)):
        K(name, kernel_image(blob, name, config=CONFIG_GOOD), g, btf=blob)
    W("elf_tiny", b"\x7fELF\x02\x01\x01\x00garbage")
    # ---- symvers
    # every parseable symvers variant gets a vmlinux whose __crc_* symbols match
    # its vmlinux rows, so the input-binding check passes and the case isolates
    # the deviation under test
    SV = {
        "good": g,
        "baseline": [r for r in g if r[1] != "added_sym"],
        "baseline_plus_old": g + [(0x12340005, "base_e3", "vmlinux", "EXPORT_SYMBOL", "")],
        "wrong_module_layout": edit(g, "module_layout", crc=0x22222222),
        "missing_symbol": [r for r in g if r[1] != "sym_b"],
        "crc_mismatch": edit(g, "sym_a", crc=0xAAAAFFFF),
        "changed_baseline": edit(g, "base_e1", crc=0x99990002),
        "removed_baseline": [r for r in g if r[1] != "base_e2"],
        "collision_vendor_export": g + [(CRC["vend_x"], "vend_x", "vmlinux", "EXPORT_SYMBOL", "")],
        "collision_plus_export": g + [(CRC["vend_s"], "vend_s", "vmlinux", "EXPORT_SYMBOL", "")],
        "duplicate_rows": g + [(CRC["sym_a"], "sym_a", "drivers/fixture/other", "EXPORT_SYMBOL", "")],
        "wrong_namespace": edit(g, "ns_sym", ns="OTHERNS"),
        "gpl_only": edit(g, "sym_d", typ="EXPORT_SYMBOL_GPL"),
        "missing_unversioned": [r for r in g if r[1] != "unv_sym"],
        "only_intree": edit(g, "sym_c", mod="drivers/fixture/intree"),
        "no_ns": edit(g, "ns_sym", ns=""),                  # 4.19 has no export namespaces
    }
    for name, rows in SV.items():
        W(f"symvers/{name}", symvers(rows))
        if name not in ("good", "baseline"):
            K(f"sv_{name}", base, rows)
    W("symvers/unparseable", symvers(g) + "this is not a symvers row\n")
    W("symvers/no_vmlinux", symvers([r for r in g if r[2] != "vmlinux"]))
    W("symvers/crlf", symvers(g).replace("\n", "\r\n"))
    W("symvers/empty", b"")
    # ---- base configs, allowlists, requests, profile template
    W("config/stock_requested", STOCK_BASE)
    W("config/stock_requested_crlf", STOCK_BASE.replace("\n", "\r\n"))
    W("config/unparseable", CONFIG_GOOD + "CONFIG_BROKEN\n")
    W("config/malformed_notset", STOCK_BASE + "# CONFIG_FOO is not set, really\n")
    W("allow/btrfs.allow", "# select fallout of --module BTRFS_FS (fixture)\nCONFIG_XOR_BLOCKS=m\n")
    W("allow/noik.allow", "# fixture: this build disables IKCONFIG (paired with --waive-ikconfig)\n# CONFIG_IKCONFIG is not set\n")
    W("requests/good.txt", "# fixture request list (scripts/config syntax)\n--enable DEVTMPFS --disable DEVTMPFS_MOUNT --module AUTOFS_FS\n"
                           "--set-str LOCALVERSION \"\"\n--set-val FIXTURE_VAL a#b\n")
    W("requests/btrfs.txt", "--enable DEVTMPFS --disable DEVTMPFS_MOUNT --module AUTOFS_FS --module BTRFS_FS\n")
    W("requests/none.txt", "# explicit: nothing requested beyond the base config\n--none\n")
    W("requests/empty.txt", "# no requests and no --none\n")
    W("requests/unsatisfied.txt", "--enable DEVTMPFS --module BTRFS_FS\n")
    W("requests/wrong_value.txt", "--enable AUTOFS_FS\n")
    W("requests/typo_disable.txt", "--disable DEVTMPFS_MOUNTT\n")
    W("requests/undefine.txt", "--undefine DEVTMPFS_MOUNT\n")
    W("requests/unsupported.txt", "--file /tmp/x --enable DEVTMPFS\n")
    sha = lambda rel: hashlib.sha256(open(os.path.join(out, rel), "rb").read()).hexdigest()
    W("profiles/fixture.template.json", json.dumps({
        "device": "fixture",
        "sources": {"vendor_boot": "vendor_boot", "boot": "boot", "vendor_dlkm": "ext4", "vendor": "ext4"},
        "counts": {"required_from_vmlinux": 6, "unique_modules": 3, "module_copies": 4},
        "stock_build_symvers_sha256": sha("symvers/baseline"),
        "build_sections": SECNAMES,
        "builds": {
            "stock": {"requested_sha256": sha("requests/none.txt"), "allow_sha256": None, "baseline": "waived"},
            "group": {"requested_sha256": sha("requests/good.txt"), "allow_sha256": None, "baseline": "stock-build"},
            "btrfs": {"requested_sha256": sha("requests/btrfs.txt"), "allow_sha256": sha("allow/btrfs.allow"), "baseline": "stock-build"},
            "noik": {"requested_sha256": sha("requests/good.txt"), "allow_sha256": sha("allow/noik.allow"), "baseline": "stock-build"},
        },
        "note": "reference_sha256 is added by test_kgate.py after it builds the reference (ext4 images are made at test time)"}, indent=1, sort_keys=True) + "\n")


def manifest(out):
    rows = []
    for dp, _dn, fns in os.walk(out):
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, out).replace(os.sep, "/")
            if rel == "MANIFEST.sha256" or fn.startswith("."):
                continue
            with open(p, "rb") as fh:
                rows.append(f"{hashlib.sha256(fh.read()).hexdigest()}  {rel}")
    return "\n".join(sorted(rows, key=lambda r: r[66:])) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_fixtures.py OUTDIR")
    generate(sys.argv[1])
    write(sys.argv[1], "MANIFEST.sha256", manifest(sys.argv[1]))
    print(f"fixtures written to {sys.argv[1]}")
