#!/usr/bin/env python3
"""FrameShift Quest 2 channel - raw object scan for fs-rpcd.o (rev 5 V1; rev 6 fail-closed).
Offline; stdlib; run with -I -B. Parses the ELF64 little-endian AArch64 relocatable itself
(no disassembler), so data emitted into code (.word/.byte/.inst, .reloc, token-pasted or
line-spliced asm) cannot hide behind a disassembler's view.

    python3 -I -B obj-scan.py OBJECT     exit 0 = clean; 1 = refused; 2 = malformed / unusable
                                         (ANY parse error is nonzero: the scan fails closed)

Structure (rev 6, fail closed):
  S1 ELFCLASS64, little-endian, EV_CURRENT, EM_AARCH64 (183), ET_REL (1);
  S2 e_shentsize == 64, e_shnum >= 2, the section header table inside the file, e_shstrndx a
     valid SHT_STRTAB; every non-NOBITS section inside the file; every name inside the strtab;
  S3 exactly ONE code section, and it is a PROGBITS ".text" with SHF_EXECINSTR and size > 0
     (the real object has exactly one; "code" = SHF_EXECINSTR or named .text/.text.*/.init/
     .fini, since the linker merges sections by NAME); size a multiple of 4;
  S4 a symbol table exists (exactly one SHT_SYMTAB, entsize 24, link = a valid STRTAB);
  S5 relocations: no SHT_REL at all; every SHT_RELA has entsize 24, a size that is a multiple of
     24, link = the symtab, and a target (sh_info) that is the .text section or a known data
     section (.rodata*, .data*, .eh_frame, .init_array, .fini_array); every r_sym is in range;
Content:
  C1 no aligned word w in .text with (w & 0xffe0001f) in {0xd4000001 svc, 0xd4000002 hvc,
     0xd4000003 smc};
  C2 no $d / $d.<n> mapping symbol (data) in a code section;
  C3 every relocation whose target is .text has a type on the INSTRUCTION-relocation allowlist
     AND sits on a word of the instruction class that type patches (so the patched result can
     never be an exception-generating instruction): data relocations (ABS16/32/64, PREL16/32/64,
     ...) in code are refused - ".reloc ., R_AARCH64_ABS32, 0xd4000001" over a nop would make the
     linker write svc #0.
     Allowlist = the types the real fs-rpcd.o uses (CALL26, ADR_PREL_PG_HI21, ADD_ABS_LO12_NC,
     LDST8/32/64/128_ABS_LO12_NC) plus siblings of the same instruction classes (JUMP26,
     ADR_PREL_PG_HI21_NC, LDST16_ABS_LO12_NC, CONDBR19, TSTBR14).
Only fs-rpcd's own object is scanned; libc is linked later and is not covered.
"""
import re
import struct
import sys

SHF_EXECINSTR = 0x4
SHT_PROGBITS, SHT_SYMTAB, SHT_STRTAB, SHT_RELA, SHT_NOBITS, SHT_REL = 1, 2, 3, 4, 8, 9
EXC = {0xd4000001: "svc", 0xd4000002: "hvc", 0xd4000003: "smc"}
CODE_NAME = re.compile(r"^\.(text|init|fini)(\..*)?$")
DATA_NAME = re.compile(r"^\.(rodata|data|eh_frame|init_array|fini_array)(\..*)?$")
# type -> (name, mask, value): the instruction class the relocation is allowed to patch
INSN_RELOCS = {
    283: ("CALL26", 0xfc000000, 0x94000000),                 # BL
    282: ("JUMP26", 0xfc000000, 0x14000000),                 # B
    275: ("ADR_PREL_PG_HI21", 0x9f000000, 0x90000000),       # ADRP
    276: ("ADR_PREL_PG_HI21_NC", 0x9f000000, 0x90000000),    # ADRP
    277: ("ADD_ABS_LO12_NC", 0x7f800000, 0x11000000),        # ADD (immediate), 32/64-bit, no flags
    278: ("LDST8_ABS_LO12_NC", 0x3b000000, 0x39000000),      # load/store, unsigned immediate
    284: ("LDST16_ABS_LO12_NC", 0x3b000000, 0x39000000),
    285: ("LDST32_ABS_LO12_NC", 0x3b000000, 0x39000000),
    286: ("LDST64_ABS_LO12_NC", 0x3b000000, 0x39000000),
    299: ("LDST128_ABS_LO12_NC", 0x3b000000, 0x39000000),
    280: ("CONDBR19", 0xff000010, 0x54000000),               # B.cond
    279: ("TSTBR14", 0x7e000000, 0x36000000),                # TBZ/TBNZ
}


class Malformed(Exception):
    pass


def scan(data):
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise Malformed("not an ELF file")
    if data[4] != 2 or data[5] != 1 or data[6] != 1:
        raise Malformed("not ELFCLASS64 / little-endian / EV_CURRENT")
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_machine != 183 or e_type != 1:
        raise Malformed("not an AArch64 relocatable (type %d machine %d)" % (e_type, e_machine))
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3a)
    if e_shentsize != 64:
        raise Malformed("e_shentsize %d != 64" % e_shentsize)
    if e_shnum < 2:
        raise Malformed("e_shnum %d < 2" % e_shnum)
    if e_shoff < 64 or e_shoff + e_shnum * 64 > len(data):
        raise Malformed("section header table outside the file")
    if not 0 < e_shstrndx < e_shnum:
        raise Malformed("e_shstrndx %d invalid" % e_shstrndx)
    secs = []
    for i in range(e_shnum):
        name, typ, flags, _addr, off, size, link, info, _al, es = struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * 64)
        if i and typ != SHT_NOBITS and off + size > len(data):
            raise Malformed("section %d outside the file" % i)
        secs.append(dict(i=i, name=name, type=typ, flags=flags, off=off, size=size, link=link, info=info, es=es))
    shstr = secs[e_shstrndx]
    if shstr["type"] != SHT_STRTAB:
        raise Malformed("e_shstrndx is not a STRTAB")

    def cstr(strsec, o):
        if o >= strsec["size"]:
            raise Malformed("string offset outside its table")
        a = strsec["off"] + o
        end = data.find(b"\0", a, strsec["off"] + strsec["size"])
        if end < 0:
            raise Malformed("unterminated string")
        return data[a:end].decode("latin-1")

    for s in secs:
        s["nm"] = cstr(shstr, s["name"]) if s["i"] else ""
        s["code"] = bool(s["flags"] & SHF_EXECINSTR) or bool(CODE_NAME.match(s["nm"]))

    problems = []
    code = [s for s in secs if s["code"]]
    texts = [s for s in code if s["nm"] == ".text" and s["type"] == SHT_PROGBITS and s["flags"] & SHF_EXECINSTR and s["size"] > 0]
    if len(code) != 1 or len(texts) != 1:
        raise Malformed("expected exactly one code section, a PROGBITS .text with SHF_EXECINSTR and size > 0; found code sections %s"
                        % ([(s["nm"], s["type"], hex(s["flags"]), s["size"]) for s in code] or "none"))
    text = texts[0]
    if text["size"] % 4:
        raise Malformed(".text size %d is not a multiple of 4" % text["size"])

    # C1: raw words
    nwords = text["size"] // 4
    for k in range(0, text["size"], 4):
        w, = struct.unpack_from("<I", data, text["off"] + k)
        if (w & 0xffe0001f) in EXC:
            problems.append("%s at .text+0x%x (word 0x%08x)" % (EXC[w & 0xffe0001f], k, w))

    # S4 / C2: the symbol table
    symtabs = [s for s in secs if s["type"] == SHT_SYMTAB]
    if len(symtabs) != 1:
        raise Malformed("expected one SYMTAB, found %d" % len(symtabs))
    st = symtabs[0]
    if st["es"] != 24 or st["size"] % 24 or not 0 < st["link"] < e_shnum or secs[st["link"]]["type"] != SHT_STRTAB:
        raise Malformed("bad SYMTAB header")
    strsec = secs[st["link"]]
    nsym = st["size"] // 24
    for k in range(nsym):
        st_name, _info, _other, st_shndx, st_value, _size = struct.unpack_from("<IBBHQQ", data, st["off"] + k * 24)
        if not st_name or st_shndx == 0 or st_shndx >= 0xff00:
            continue
        if st_shndx >= e_shnum:
            raise Malformed("symbol %d section index %d out of range" % (k, st_shndx))
        n = cstr(strsec, st_name)
        if (n == "$d" or n.startswith("$d.")) and secs[st_shndx]["code"]:
            problems.append("data mapping symbol %s inside code section %s at 0x%x" % (n, secs[st_shndx]["nm"], st_value))

    # S5 / C3: relocations
    nrel = 0
    for s in secs:
        if s["type"] == SHT_REL:
            raise Malformed("SHT_REL section %s (AArch64 uses RELA)" % s["nm"])
        if s["type"] != SHT_RELA:
            continue
        if s["es"] != 24 or s["size"] % 24 or s["link"] != st["i"] or not 0 < s["info"] < e_shnum:
            raise Malformed("bad RELA header %s" % s["nm"])
        tgt = secs[s["info"]]
        if tgt["i"] != text["i"] and not (DATA_NAME.match(tgt["nm"]) and not tgt["code"] and tgt["type"] == SHT_PROGBITS):
            raise Malformed("RELA %s targets %s, neither .text nor a known data section" % (s["nm"], tgt["nm"]))
        for k in range(s["size"] // 24):
            r_off, r_info, _add = struct.unpack_from("<QQq", data, s["off"] + k * 24)
            nrel += 1
            rsym, rtype = r_info >> 32, r_info & 0xffffffff
            if rsym >= nsym:
                raise Malformed("relocation symbol %d out of range" % rsym)
            if tgt["i"] != text["i"]:
                continue
            if r_off % 4 or r_off + 4 > text["size"]:
                problems.append("relocation at .text+0x%x is not on an instruction word" % r_off)
                continue
            if rtype not in INSN_RELOCS:
                problems.append("relocation type %d at .text+0x%x is not an instruction relocation (data relocations in code are refused)" % (rtype, r_off))
                continue
            name, mask, val = INSN_RELOCS[rtype]
            w, = struct.unpack_from("<I", data, text["off"] + r_off)
            if (w & mask) != val:
                problems.append("%s at .text+0x%x patches word 0x%08x, which is not its instruction class" % (name, r_off, w))
    return problems, nwords, nsym, nrel


def main(argv):
    if len(argv) != 1:
        print("usage: obj-scan.py OBJECT"); return 2
    try:
        data = open(argv[0], "rb").read()
        problems, nwords, nsym, nrel = scan(data)
    except Malformed as e:
        print("OBJ SCAN MALFORMED: %s" % e); return 2
    except Exception as e:                       # any parse error: fail closed
        print("OBJ SCAN MALFORMED: parse error %r" % (e,)); return 2
    if problems:
        print("OBJ SCAN FAILED: " + "; ".join(problems[:6]) + ("" if len(problems) <= 6 else " (+%d more)" % (len(problems) - 6)))
        return 1
    print("obj-scan: OK (one .text, %d words, no svc/hvc/smc encoding, no $d in code; %d relocations, every one in .text an instruction relocation on its instruction class; %d symbols)" % (nwords, nrel, nsym))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
