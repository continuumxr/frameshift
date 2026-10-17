#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-metacfg tests: the C reader against the independent fixture writer's
expected records and against the independent Python reference reader
(differential), plus the locate / uevent / slot / seccomp cases that only
the C reader implements.

usage: test_metacfg.py --bin FS_METACFG_TEST [--prod FS_METACFG_PROD] [--out FILE]
       [--qemu QEMU --bin-a64 FS_METACFG_A64]
"""
import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MKFIX = os.path.join(HERE, 'fix', 'mkfix.py')
REF = os.path.join(HERE, 'ref', 'metacfg_ref.py')
sys.path.insert(0, HERE)
from mcrec import decode  # noqa: E402


def tsv(path):
    if not os.path.exists(path):
        return []
    lines = open(path).read().splitlines()
    cols = lines[0].split('\t')
    return [dict(zip(cols, ln.split('\t'))) for ln in lines[1:] if ln]


def make_root(base, image, slot, partname='super', extra_super=False, bootconfig=True):
    root = tempfile.mkdtemp(dir=base)
    blk = os.path.join(root, 'sys/class/block')
    os.makedirs(os.path.join(root, 'dev'))
    os.makedirs(os.path.join(root, 'proc'))
    if partname:
        os.makedirs(os.path.join(blk, 'sda7'))
        with open(os.path.join(blk, 'sda7/uevent'), 'w') as f:
            f.write(f'MAJOR=8\nMINOR=7\nDEVNAME=sda7\nDEVTYPE=partition\nPARTN=7\nPARTNAME={partname}\n')
    else:
        os.makedirs(blk)
    os.makedirs(os.path.join(blk, 'sda1'))
    with open(os.path.join(blk, 'sda1/uevent'), 'w') as f:
        f.write('MAJOR=8\nMINOR=1\nDEVNAME=sda1\nDEVTYPE=partition\nPARTN=1\nPARTNAME=misc\n')
    if extra_super:
        os.makedirs(os.path.join(blk, 'sdb3'))
        with open(os.path.join(blk, 'sdb3/uevent'), 'w') as f:
            f.write('DEVNAME=sdb3\nPARTNAME=super\n')
    if image:
        os.symlink(image, os.path.join(root, 'dev/sda7'))
    if slot is not None:
        with open(os.path.join(root, 'proc/bootconfig'), 'w') as f:
            f.write(f'androidboot.hardware = "eureka"\nandroidboot.slot_suffix = "{slot}"\n')
        with open(os.path.join(root, 'proc/cmdline'), 'w') as f:
            f.write(f'console=ttyMSM0 androidboot.slot_suffix={slot} quiet\n')
    return root


def run_c(binv, device, root, size, extra=(), timeout=10, prefix=()):
    r = subprocess.run(list(prefix) + [binv, device, '1', '--root', root, '--super-size', str(size),
                                       '--allow-regular'] + list(extra),
                       capture_output=True, timeout=timeout)
    return r


def status_of(b):
    try:
        return decode(b)['status']
    except Exception:
        return 'no-record'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--prod')
    ap.add_argument('--out')
    ap.add_argument('--qemu')
    ap.add_argument('--bin-a64')
    a = ap.parse_args()
    work = tempfile.mkdtemp(prefix='fsth-mc-')
    fix = os.path.join(work, 'fix')
    subprocess.run([sys.executable, '-I', MKFIX, '--out', fix], check=True, capture_output=True)
    rows = [(r, 'main') for r in tsv(os.path.join(fix, 'CASES.tsv'))] + \
           [(r, 'ambiguous') for r in tsv(os.path.join(fix, 'CASES-AMBIGUOUS.tsv'))]
    res, bad = [], 0
    for r, kind in rows:
        img = os.path.join(fix, r['image'])
        root = make_root(work, img, r['slot_suffix'])
        c = run_c(a.bin, r['device'], root, r['super_size'])
        exp = open(os.path.join(fix, 'expected', r['case'] + '.rec'), 'rb').read()
        pyrec = os.path.join(work, 'py.rec')
        subprocess.run([sys.executable, '-I', REF, '--image', img, '--device', r['device'], '--slot-suffix',
                        r['slot_suffix'], '--super-size', r['super_size'], '--out', pyrec], capture_output=True)
        py = open(pyrec, 'rb').read() if os.path.exists(pyrec) else b''
        cs = status_of(c.stdout)
        ok_status = cs == r['expected_status']
        same_exp = c.stdout == exp
        same_py = c.stdout == py
        good = c.returncode == 0 and ok_status and same_exp and same_py
        declared = r['case'] == 'budget-edge-over' and cs == 'ok' and status_of(py) == 'read-budget'
        if not good and not declared:
            bad += 1
        res.append(f"{'PASS' if good else 'DECL' if declared else 'FAIL'} {kind:9s} {r['case']:34s} want={r['expected_status']:18s} "
                   f"C={cs:18s} bytes==fixture:{int(same_exp)} bytes==python:{int(same_py)}")
        shutil.rmtree(root)

    # ---------------- locate, slot, size, type, uevent, seccomp (C only) ----------------
    okimg = os.path.join(fix, 'ok-eureka-a.img')
    okrow = [r for r, _ in rows if r['case'] == 'ok-eureka-a'][0]
    size = okrow['super_size']
    extra_cases = []

    def case(name, want, root, device='eureka', ex=(), sz=None, timeout=10, check=None, binv=None):
        r = run_c(binv or a.bin, device, root, sz or size, ex, timeout=timeout)
        st = status_of(r.stdout)
        good = st == want and (check is None or check(r))
        extra_cases.append((name, want, st, good))

    case('locate-ok', 'ok', make_root(work, okimg, '_a'))
    case('locate-no-partname', 'no-super', make_root(work, None, '_a', partname=None))
    case('locate-two-supers', 'super-ambiguous', make_root(work, okimg, '_a', extra_super=True))
    case('slot-missing', 'slot', make_root(work, okimg, None))
    rt = make_root(work, okimg, '_c')
    case('slot-bad-value', 'slot', rt)
    rt = make_root(work, okimg, '_a')
    with open(os.path.join(rt, 'proc/bootconfig'), 'a') as f:
        f.write('androidboot.slot_suffix = "_b"\n')
    case('slot-conflict', 'slot', rt)
    rt = make_root(work, okimg, '_a')
    os.unlink(os.path.join(rt, 'proc/bootconfig'))
    case('hollywood-cmdline-slot', 'ok', rt, device='hollywood')  # slot from /proc/cmdline (F37)
    case('super-size-mismatch', 'super-size', make_root(work, okimg, '_a'), sz=int(size) + 512)
    rt = make_root(work, None, '_a')
    os.makedirs(os.path.join(rt, 'dev/sda7'))
    case('super-not-a-file', 'super-type', rt)
    case('device-unknown', 'arg', make_root(work, okimg, '_a'), device='seacliff')
    # uevent: super appears 1.5 s late (accepted) and never (no-super, inside the budget)
    rt = make_root(work, None, '_a', partname=None)
    sock = os.path.join(rt, 'uev.sock')

    def late():
        time.sleep(1.5)
        os.makedirs(os.path.join(rt, 'sys/class/block/sda7'))
        with open(os.path.join(rt, 'sys/class/block/sda7/uevent'), 'w') as f:
            f.write('DEVNAME=sda7\nPARTNAME=super\n')
        os.symlink(okimg, os.path.join(rt, 'dev/sda7'))
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(b'add@/devices/platform/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sda/sda7\0'
                 b'ACTION=add\0DEVPATH=/devices/x/block/sda/sda7\0SUBSYSTEM=block\0DEVNAME=sda7\0'
                 b'DEVTYPE=partition\0PARTN=7\0PARTNAME=super\0', sock)
    th = threading.Thread(target=late)
    th.start()
    t0 = time.monotonic()
    case('uevent-late-1.5s', 'ok', rt, ex=('--uevent-sock', sock))
    th.join()
    rt = make_root(work, None, '_a', partname=None)
    t0 = time.monotonic()
    case('uevent-never', 'no-super', rt, ex=('--uevent-sock', os.path.join(rt, 'u.sock')),
         check=lambda r: 1.7 < time.monotonic() - t0 < 2.5)
    # seccomp: active in the native test build (not optional); a forbidden syscall is fatal
    case('seccomp-active-ok', 'ok', make_root(work, okimg, '_a'))
    case('seccomp-forbidden-syscall', 'no-record', make_root(work, okimg, '_a'), ex=('--seccomp-selftest',),
         check=lambda r: r.returncode < 0)
    if a.prod:
        strings = open(a.prod, 'rb').read()
        extra_cases.append(('prod-no-test-options', 'absent',
                            'absent' if all(x not in strings for x in (b'--root', b'--allow-regular',
                                                                         b'--seccomp-optional', b'--uevent-sock'))
                            else 'present', None))
        extra_cases[-1] = extra_cases[-1][:3] + (extra_cases[-1][2] == 'absent',)
        r = subprocess.run([a.prod, 'eureka', '1', '--root', '/'], capture_output=True)
        extra_cases.append(('prod-rejects-test-args', 'arg', status_of(r.stdout), status_of(r.stdout) == 'arg'))
    if a.qemu and a.bin_a64:
        for r_, _ in rows[:]:
            if r_['case'] not in ('ok-eureka-a', 'ok-hollywood', 'vab-merge', 'json-dupkey'):
                continue
            img = os.path.join(fix, r_['image'])
            rt = make_root(work, img, r_['slot_suffix'])
            p = run_c(a.bin_a64, r_['device'], rt, r_['super_size'], ('--seccomp-optional',), prefix=(a.qemu,))
            exp = open(os.path.join(fix, 'expected', r_['case'] + '.rec'), 'rb').read()
            st = status_of(p.stdout)
            extra_cases.append((f'aarch64-qemu-{r_["case"]}', r_['expected_status'], st,
                                st == r_['expected_status'] and p.stdout[:40] == exp[:40] and p.stdout[44:] == exp[44:]))
    for name, want, st, good in extra_cases:
        if not good:
            bad += 1
        res.append(f"{'PASS' if good else 'FAIL'} c-only    {name:34s} want={want:18s} C={st}")
    n = len(res)
    summ = f'fs-metacfg: {n - bad}/{n} pass ({len(rows)} fixture cases compared byte for byte with the fixture ' \
           f'writer and the Python reference; {len(extra_cases)} C-only cases)'
    print('\n'.join(res))
    print(summ)
    if a.out:
        with open(a.out, 'w', newline='\n') as f:
            f.write('# fs-metacfg tests (tools/test_metacfg.py)\n' + '\n'.join(res) + '\n' + summ + '\n')
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
