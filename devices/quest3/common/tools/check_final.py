#!/usr/bin/env python3
"""Static proof of what build/fs-reboot-final does (second review, nit).

    check_final.py ELF DISASSEMBLY OUT_LAYOUT

Simulates the straight-line aarch64 code from llvm-objdump output (only the
instruction forms this program uses: mov/movk/adrp/add/mov-register/svc/b;
anything else is refused), then the loop a second time after the branch, and
asserts the arguments of every syscall:
  svc 1: x8=142 reboot(0xfee1dead, 0x28121969, 0xa1b2c3d4, &"bootloader\\0")
  svc 2: x8=142 reboot(0xfee1dead, 0x28121969, 0x01234567, 0)
  svc 3: x8=101 nanosleep(&{3600, 0}, NULL), inside a closed loop (b back to
         before svc 3, re-entered with identical arguments)
  exactly 3 svc; no other instruction kinds; the last instruction is the b.
Writes OUT_LAYOUT (str_vaddr, ts_vaddr) for the qemu -strace fixture.
Exit 0 only if all hold.
"""
import re
import struct
import sys

elf_path, dis_path, out_path = sys.argv[1:4]
elf = open(elf_path, "rb").read()
assert elf[:4] == b"\x7fELF" and elf[4] == 2 and elf[5] == 1, "not ELF64 LE"
e_phoff, = struct.unpack_from("<Q", elf, 0x20)
e_phentsize, e_phnum = struct.unpack_from("<HH", elf, 0x36)
loads = []
for i in range(e_phnum):
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack_from("<IIQQQQ", elf, e_phoff + i * e_phentsize)
    if p_type == 1:
        loads.append((p_vaddr, p_offset, p_filesz))


def mem(vaddr, n):
    for v, o, sz in loads:
        if v <= vaddr and vaddr + n <= v + sz:
            return elf[o + vaddr - v:o + vaddr - v + n]
    raise SystemExit("FAIL address 0x%x not in a PT_LOAD segment" % vaddr)


insns = []
for line in open(dis_path):
    m = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} ){4}\s*(\S+)\s*(.*)$", line)
    if m:
        insns.append((int(m.group(1), 16), m.group(2), m.group(3).split("//")[0].strip()))
assert insns, "no instructions parsed"


def imm(s):
    s = s.strip().lstrip("#")
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def reg(r):
    r = r.strip()
    if r in ("xzr", "wzr"):
        return None
    assert re.fullmatch(r"[wx]([0-9]|[12][0-9]|30)", r), "register " + r
    return int(r[1:])


calls, pcs = [], {a: k for k, (a, _, _) in enumerate(insns)}
regs, k, loops, steps = {}, 0, 0, 0
while True:
    steps += 1
    assert steps < 200, "runaway simulation"
    addr, op, args = insns[k]
    a = [x.strip() for x in args.split(",")] if args else []
    if op == "mov":
        d = reg(a[0])
        if a[1].startswith("#"):
            regs[d] = imm(a[1]) & 0xffffffff
        else:
            s = reg(a[1])
            regs[d] = 0 if s is None else regs[s]
    elif op == "movk":
        d, v = reg(a[0]), imm(a[1])
        sh = int(a[2].split("#")[1]) if len(a) > 2 else 0
        regs[d] = (regs[d] & ~(0xffff << sh) & 0xffffffff) | (v << sh)
    elif op == "adrp":
        regs[reg(a[0])] = int(a[1].split()[0], 16)
    elif op == "add":
        regs[reg(a[0])] = regs[reg(a[1])] + imm(a[2])
    elif op == "svc":
        calls.append((addr, regs.get(8), regs.get(0), regs.get(1), regs.get(2), regs.get(3)))
        regs[0] = None                             # clobbered by the return value
    elif op == "b":
        assert k == len(insns) - 1, "branch is not the last instruction"
        target = int(a[0].split()[0], 16)
        loops += 1
        if loops == 2:
            break
        k = pcs[target]
        continue
    else:
        raise SystemExit("FAIL unexpected instruction kind: %s %s at 0x%x" % (op, args, addr))
    k += 1
    assert k < len(insns), "fell off the end without the loop branch"

nsvc = sum(1 for _, op, _ in insns if op == "svc")
res = []
def check(name, cond):
    res.append((name, bool(cond)))
check("exactly 3 svc instructions in the binary", nsvc == 3)
check("4 syscalls simulated (3 + the loop's svc again)", len(calls) == 4)
c1, c2, c3, c3b = calls[:4] + [None] * (4 - len(calls[:4]))
check("svc1 = reboot(0xfee1dead, 0x28121969, 0xa1b2c3d4, p)", c1 and c1[1:5] == (142, 0xfee1dead, 0x28121969, 0xa1b2c3d4))
check("svc1 p -> 'bootloader\\0'", c1 and mem(c1[5], 11) == b"bootloader\x00")
check("svc2 = reboot(0xfee1dead, 0x28121969, 0x01234567, 0)", c2 and c2[1:] == (142, 0xfee1dead, 0x28121969, 0x01234567, 0))
check("svc3 = nanosleep(p, NULL)", c3 and c3[1] == 101 and c3[3] == 0)
check("svc3 p -> {3600, 0}", c3 and struct.unpack("<qq", mem(c3[2], 16)) == (3600, 0))
check("loop: b back to before svc3 and after svc2", c2 and c3 and c2[0] < target <= c3[0])
check("loop: re-entered svc3 has identical arguments", c3b and c3b == c3)
check("no exit/exit_group number (93/94) in any x8", all(c[1] not in (93, 94) for c in calls))
with open(out_path, "w", newline="\n") as fh:
    fh.write("str_vaddr=%d ts_vaddr=%d\n" % (c1[5] if c1 else -1, c3[2] if c3 else -1))
for n, ok in res:
    print("%-55s %s" % (n, "PASS" if ok else "FAIL"))
sys.exit(0 if all(ok for _, ok in res) else 1)
