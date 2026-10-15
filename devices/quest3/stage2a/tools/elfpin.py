#!/usr/bin/env python3
"""FrameShift stage-2a: stdlib-only ELF64 pin extractor and checker for the T1 set.

Usage (run with `python3 -I`):
  elfpin.py inspect <file>...            -> JSON with hashes and ELF facts per file
  elfpin.py check <T1-pins.json> <dir>   -> verify <dir>/{lib,bin}/... against the pins
                                            (exit 0 = all pins hold, 1 = refused)

The checker is the builder gate for FS-R-006 §5 A: complete SHA-256 and
BLAKE2b-512, exact size, ELF class/machine/type, exact PT_INTERP bytes,
DT_NEEDED list (order included), no DT_RPATH/DT_RUNPATH, the loader has no
PT_INTERP and no DT_NEEDED, and every required symbol version is defined by
the pinned libraries. It parses the file itself; it does not trust readelf.
"""
import hashlib, json, struct, sys, os

PT = {0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 6: "PHDR", 7: "TLS",
      0x6474e550: "GNU_EH_FRAME", 0x6474e551: "GNU_STACK", 0x6474e552: "GNU_RELRO",
      0x6474e553: "GNU_PROPERTY"}
DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_FLAGS, DT_RUNPATH = 1, 5, 14, 15, 30, 29
DT_FLAGS_1, DT_VERNEED, DT_VERNEEDNUM, DT_VERDEF, DT_VERDEFNUM = 0x6ffffffb, 0x6ffffffe, 0x6fffffff, 0x6ffffffc, 0x6ffffffd
DT_STRSZ = 10
FLAGS_NAMES = {1: "ORIGIN", 2: "SYMBOLIC", 4: "TEXTREL", 8: "BIND_NOW", 16: "STATIC_TLS"}
FLAGS1_NAMES = {1: "NOW", 8: "NODELETE", 0x08000000: "PIE", 0x20: "INITFIRST", 0x800: "NODEFLIB"}
GNU_PROPERTY_AARCH64_FEATURE_1_AND = 0xc0000000


class Refused(Exception):
    pass


def hashes(data):
    return hashlib.sha256(data).hexdigest(), hashlib.blake2b(data, digest_size=64).hexdigest()


def parse(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        raise Refused(f"{path}: not ELF")
    ei_class, ei_data, ei_osabi = data[4], data[5], data[7]
    if ei_class != 2 or ei_data != 1:
        raise Refused(f"{path}: not ELF64 little-endian (class={ei_class} data={ei_data})")
    (e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags, e_ehsize,
     e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    phdrs = []
    for i in range(e_phnum):
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
            struct.unpack_from("<IIQQQQQQ", data, e_phoff + i * e_phentsize)
        phdrs.append(dict(type=p_type, flags=p_flags, offset=p_offset, vaddr=p_vaddr,
                          filesz=p_filesz, memsz=p_memsz, align=p_align))

    def v2o(vaddr):
        for p in phdrs:
            if p["type"] == 1 and p["vaddr"] <= vaddr < p["vaddr"] + p["filesz"]:
                return vaddr - p["vaddr"] + p["offset"]
        raise Refused(f"{path}: vaddr {vaddr:#x} not in any PT_LOAD")

    out = {"elf_class": "ELF64", "data": "LSB", "osabi": ei_osabi,
           "e_type": {2: "ET_EXEC", 3: "ET_DYN"}.get(e_type, e_type),
           "e_machine": {183: "EM_AARCH64"}.get(e_machine, e_machine), "e_flags": e_flags}
    interps = [p for p in phdrs if p["type"] == 3]
    if len(interps) > 1:
        raise Refused(f"{path}: more than one PT_INTERP")
    if interps:
        raw = data[interps[0]["offset"]:interps[0]["offset"] + interps[0]["filesz"]]
        if not raw.endswith(b"\x00") or b"\x00" in raw[:-1]:
            raise Refused(f"{path}: PT_INTERP not a single NUL-terminated string")
        out["pt_interp"] = raw[:-1].decode("ascii")
        out["pt_interp_hex"] = raw.hex()
    else:
        out["pt_interp"] = None
    loads = [p for p in phdrs if p["type"] == 1]
    out["pt_load_align"] = sorted({p["align"] for p in loads})
    out["pt_load"] = [{"offset": hex(p["offset"]), "vaddr": hex(p["vaddr"]), "filesz": hex(p["filesz"]),
                       "memsz": hex(p["memsz"]), "flags": "".join(c for c, b in (("R", 4), ("W", 2), ("E", 1)) if p["flags"] & b),
                       "align": hex(p["align"])} for p in loads]
    out["phdr_types"] = [PT.get(p["type"], hex(p["type"])) for p in phdrs]
    gstack = [p for p in phdrs if p["type"] == 0x6474e551]
    out["gnu_stack_exec"] = bool(gstack and gstack[0]["flags"] & 1)

    # notes (all PT_NOTE segments)
    notes, abi, props = [], None, []
    for p in phdrs:
        if p["type"] not in (4, 0x6474e553):
            continue
        o, end = p["offset"], p["offset"] + p["filesz"]
        al = 8 if p["align"] == 8 else 4
        while o + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, o)
            name = data[o + 12:o + 12 + namesz].rstrip(b"\x00").decode("ascii", "replace")
            do = o + 12 + ((namesz + al - 1) & ~(al - 1))
            desc = data[do:do + descsz]
            if p["type"] == 4:
                notes.append(f"{name}:{ntype}")
            if name == "GNU" and ntype == 1 and descsz >= 16:
                os_, a, b, c = struct.unpack_from("<IIII", desc)
                abi = {"os": {0: "Linux"}.get(os_, os_), "abi": f"{a}.{b}.{c}"}
            if name == "GNU" and ntype == 5:   # NT_GNU_PROPERTY_TYPE_0
                q = 0
                while q + 8 <= len(desc):
                    pt, pdsz = struct.unpack_from("<II", desc, q)
                    pv = desc[q + 8:q + 8 + pdsz]
                    props.append({"type": hex(pt), "value": pv.hex()})
                    q += 8 + ((pdsz + 7) & ~7)
            o = do + ((descsz + al - 1) & ~(al - 1))
    out["notes"] = notes
    out["abi_tag"] = abi
    out["gnu_property"] = props
    bti = pac = False
    for pr in props:
        if int(pr["type"], 16) == GNU_PROPERTY_AARCH64_FEATURE_1_AND and len(pr["value"]) >= 8:
            v = int.from_bytes(bytes.fromhex(pr["value"])[:4], "little")
            bti, pac = bool(v & 1), bool(v & 2)
    out["aarch64_bti"], out["aarch64_pac"] = bti, pac

    # dynamic section
    dyn = [p for p in phdrs if p["type"] == 2]
    needed, rpath, runpath, soname, flags, flags1 = [], None, None, None, 0, 0
    verneed = verdef = None
    if dyn:
        ents, o = [], dyn[0]["offset"]
        while o < dyn[0]["offset"] + dyn[0]["filesz"]:
            tag, val = struct.unpack_from("<qQ", data, o)
            o += 16
            if tag == 0:
                break
            ents.append((tag, val))
        d = {}
        for t, v in ents:
            d.setdefault(t, []).append(v)
        stroff = v2o(d[DT_STRTAB][0])

        def s(off):
            e = data.index(b"\x00", stroff + off)
            return data[stroff + off:e].decode("ascii")
        needed = [s(v) for v in d.get(DT_NEEDED, [])]
        rpath = [s(v) for v in d.get(DT_RPATH, [])] or None
        runpath = [s(v) for v in d.get(DT_RUNPATH, [])] or None
        soname = s(d[DT_SONAME][0]) if DT_SONAME in d else None
        flags = d.get(DT_FLAGS, [0])[0]
        flags1 = d.get(DT_FLAGS_1, [0])[0]
        if DT_VERNEED in d:
            verneed, o = {}, v2o(d[DT_VERNEED][0])
            for _ in range(d[DT_VERNEEDNUM][0]):
                vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from("<HHIII", data, o)
                vers, a = [], o + vn_aux
                for _ in range(vn_cnt):
                    vna_hash, vna_flags, vna_other, vna_name, vna_next = struct.unpack_from("<IHHII", data, a)
                    vers.append(s(vna_name))
                    a += vna_next
                verneed[s(vn_file)] = sorted(vers, key=verkey)
                if not vn_next:
                    break
                o += vn_next
        if DT_VERDEF in d:
            verdef, o = [], v2o(d[DT_VERDEF][0])
            for _ in range(d[DT_VERDEFNUM][0]):
                vd_version, vd_flags, vd_ndx, vd_cnt, vd_hash, vd_aux, vd_next = struct.unpack_from("<HHHHIII", data, o)
                vda_name, vda_next = struct.unpack_from("<II", data, o + vd_aux)
                if not vd_flags & 1:          # skip VER_FLG_BASE (the soname entry)
                    verdef.append(s(vda_name))
                if not vd_next:
                    break
                o += vd_next
            verdef = sorted(set(verdef), key=verkey)
    out.update(dt_needed=needed, dt_rpath=rpath, dt_runpath=runpath, dt_soname=soname,
               dt_flags=[n for b, n in FLAGS_NAMES.items() if flags & b], dt_flags_raw=hex(flags),
               dt_flags_1=[n for b, n in FLAGS1_NAMES.items() if flags1 & b], dt_flags_1_raw=hex(flags1),
               verneed=verneed, verdef=verdef)
    sha, b2 = hashes(data)
    out.update(size=len(data), sha256=sha, blake2b512=b2)
    return out


def verkey(v):
    head, _, num = v.partition("_")
    try:
        return (head, tuple(int(x) for x in num.split(".")))
    except ValueError:
        return (head, (9999,), v)


def check(pins_path, root):
    pins = json.load(open(pins_path))
    errors, parsed = [], {}
    names = [f["path"] for f in pins["files"]]
    # The staging directory must hold exactly the pinned files, nothing else.
    present = []
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            full = os.path.join(dp, n)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if os.path.islink(full):
                errors.append(f"{rel}: symlink not allowed in the staged tree")
            if os.path.isfile(full):
                present.append(rel)
    extra = sorted(set(present) - set(names))
    missing = sorted(set(names) - set(present))
    if extra:
        errors.append(f"unexpected files in staged tree: {extra}")
    if missing:
        errors.append(f"missing pinned files: {missing}")
    for f in pins["files"]:
        p = os.path.join(root, f["path"])
        if not os.path.isfile(p):
            continue
        try:
            e = parse(p)
        except Refused as x:
            errors.append(str(x)); continue
        parsed[f["path"]] = e
        for k in ("size", "sha256", "blake2b512", "e_type", "e_machine", "pt_interp", "dt_needed",
                  "dt_rpath", "dt_runpath", "aarch64_bti", "aarch64_pac", "pt_load_align"):
            if e[k] != f[k]:
                errors.append(f"{f['path']}: {k} = {e[k]!r}, pinned {f[k]!r}")
        if (f["path"] == pins["loader"] or f["path"] in pins["executables"]) and not os.access(p, os.X_OK):
            errors.append(f"{f['path']}: not executable")
    ld = parsed.get(pins["loader"])
    if ld is not None:
        if ld["pt_interp"] is not None:
            errors.append("loader has a PT_INTERP")
        if ld["dt_needed"]:
            errors.append(f"loader has DT_NEEDED {ld['dt_needed']}")
    # every required version is defined by the library that provides it
    by_soname = {e["dt_soname"]: e for e in parsed.values() if e["dt_soname"]}
    for path, e in parsed.items():
        for lib in e["dt_needed"]:
            if lib not in by_soname:
                errors.append(f"{path}: DT_NEEDED {lib} not provided by any pinned file")
        for lib, vers in (e["verneed"] or {}).items():
            have = set((by_soname.get(lib) or {}).get("verdef") or [])
            for v in vers:
                if v not in have:
                    errors.append(f"{path}: needs {lib} {v}, not defined there")
    for b in pins["executables"]:
        e = parsed.get(b)
        if e and e["pt_interp"] != pins["expected_pt_interp"]:
            errors.append(f"{b}: PT_INTERP {e['pt_interp']!r} != expected {pins['expected_pt_interp']!r}")
    total = sum(e["size"] for e in parsed.values())
    if total != pins["total_bytes"]:
        errors.append(f"total size {total} != pinned {pins['total_bytes']}")
    for x in errors:
        print("REFUSED:", x)
    if errors:
        return 1
    print(f"T1 PINS HOLD: {len(parsed)} files, {total} bytes, interp {pins['expected_pt_interp']!r}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "inspect":
        print(json.dumps({p: parse(p) for p in sys.argv[2:]}, indent=1))
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__); sys.exit(2)
