#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Static proof of what fs-poweroff-final does (EXEC-SPEC.md E-20), in the
manner of devices/quest3/common/tools/check_final.py.

    check_poweroff.py ELF DISASSEMBLY

Simulates the straight-line aarch64 code of llvm-objdump's output from the
ELF entry point. Accepted instruction forms only: the frame prologue
(stp x29, x30, [sp, #-16]!; mov x29, sp), bl (followed), mov/movk with an
immediate, mov register (incl. xzr), adrp, add immediate, svc #0, b.
Anything else is refused. Asserts:
  svc 1: x8=142 reboot(0xfee1dead, 0x28121969, 0x4321fedc (POWER_OFF), 0)
  svc 2: x8=142 reboot(0xfee1dead, 0x28121969, 0x01234567 (RESTART), 0)
  svc 3: x8=101 nanosleep(&{3600, 0}, NULL) inside a closed loop
  exactly 3 svc in the whole text; no exit/exit_group number (93/94) anywhere.
Exit 0 only if all hold.
"""
import re
import struct
import sys

elf_path, dis_path = sys.argv[1:3]
elf = open(elf_path, 'rb').read()
assert elf[:4] == b'\x7fELF' and elf[4] == 2 and elf[5] == 1, 'not ELF64 LE'
e_entry, = struct.unpack_from('<Q', elf, 0x18)
e_phoff, = struct.unpack_from('<Q', elf, 0x20)
e_phentsize, e_phnum = struct.unpack_from('<HH', elf, 0x36)
loads = []
for i in range(e_phnum):
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack_from('<IIQQQQ', elf, e_phoff + i * e_phentsize)
    if p_type == 1:
        loads.append((p_vaddr, p_offset, p_filesz))


def mem(vaddr, n):
    for v, o, sz in loads:
        if v <= vaddr and vaddr + n <= v + sz:
            return elf[o + vaddr - v:o + vaddr - v + n]
    raise SystemExit('FAIL address 0x%x not in a PT_LOAD segment' % vaddr)


insns = []
for line in open(dis_path):
    m = re.match(r'\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} ){4}\s*(\S+)\s*(.*)$', line)
    if m:
        insns.append((int(m.group(1), 16), m.group(2), m.group(3).split('//')[0].strip()))
assert insns, 'no instructions parsed'
nsvc = sum(1 for _, op, _ in insns if op == 'svc')
if nsvc != 3:
    raise SystemExit('FAIL %d svc instructions (want 3)' % nsvc)
for _, op, a in insns:
    if op in ('mov', 'movz') and re.match(r'[wx]8,\s*#(0x5[de]|9[34])\b', a):
        raise SystemExit('FAIL an exit syscall number is loaded into x8')

pcs = {a: k for k, (a, _, _) in enumerate(insns)}
if e_entry not in pcs:
    raise SystemExit('FAIL entry 0x%x not in the disassembly' % e_entry)


def imm(s):
    s = s.strip().lstrip('#').split()[0]
    return int(s, 16) if s.lower().startswith('0x') else int(s)


def reg(r):
    r = r.strip()
    if r in ('xzr', 'wzr'):
        return None
    if r == 'sp':
        return 'sp'
    assert re.fullmatch(r'[wx]([0-9]|[12][0-9]|30)', r), 'register ' + r
    return int(r[1:])


regs, calls, k, steps = {}, [], pcs[e_entry], 0
loop_seen = False
while True:
    steps += 1
    if steps > 200:
        raise SystemExit('FAIL runaway simulation')
    addr, op, args = insns[k]
    a = [x.strip() for x in args.split(',')] if args else []
    if op == 'stp' and args.replace(' ', '') == 'x29,x30,[sp,#-16]!':
        pass
    elif op == 'mov' and a == ['x29', 'sp']:
        pass
    elif op in ('mov', 'movz'):
        d = reg(a[0])
        if a[1].startswith('#'):
            regs[d] = imm(a[1]) & 0xffffffffffffffff
        else:
            s = reg(a[1])
            regs[d] = 0 if s is None else regs[s]
    elif op == 'movk':
        d, v = reg(a[0]), imm(a[1])
        sh = int(a[2].split('#')[1]) if len(a) > 2 else 0
        regs[d] = (regs[d] & ~(0xffff << sh)) | (v << sh)
    elif op == 'adrp':
        regs[reg(a[0])] = imm(a[1]) & ~0xfff
    elif op == 'add' and a[2].startswith('#'):
        regs[reg(a[0])] = regs[reg(a[1])] + imm(a[2])
    elif op == 'bl':
        k = pcs[imm(a[0])]
        continue
    elif op == 'svc':
        calls.append((addr, regs.get(8), regs.get(0), regs.get(1), regs.get(2), regs.get(3)))
        if loop_seen:
            break
        if len(calls) > 4:
            raise SystemExit('FAIL more syscalls than expected')
    elif op == 'b':
        tgt = imm(a[0])
        if tgt > addr:
            raise SystemExit('FAIL forward branch')
        loop_seen = True
        k = pcs[tgt]
        continue
    else:
        raise SystemExit('FAIL unexpected instruction %s %s at 0x%x' % (op, args, addr))
    k += 1

M1, M2 = 0xfee1dead, 0x28121969
w = lambda v: None if v is None else v & 0xffffffff
c1, c2, c3 = calls[0], calls[1], calls[2]
ok = (c1[1] == 142 and w(c1[2]) == M1 and w(c1[3]) == M2 and w(c1[4]) == 0x4321fedc and c1[5] == 0
      and c2[1] == 142 and w(c2[2]) == M1 and w(c2[3]) == M2 and w(c2[4]) == 0x01234567 and c2[5] == 0
      and c3[1] == 101 and c3[3] == 0)
if not ok:
    raise SystemExit('FAIL syscall arguments: %r' % calls)
ts = struct.unpack('<qq', mem(c3[2], 16))
if ts != (3600, 0):
    raise SystemExit('FAIL nanosleep argument %r' % (ts,))
if len(calls) != 4 or calls[3] != c3:
    raise SystemExit('FAIL the loop does not re-enter the same nanosleep: %r' % calls)
print('OK fs-poweroff-final: reboot(POWER_OFF), reboot(RESTART), nanosleep(3600 s) loop; 3 svc; no exit')
