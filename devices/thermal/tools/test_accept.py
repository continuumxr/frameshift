#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-thermald start-up tests: record acceptance A-1 .. A-9 (METACFG-SPEC §7)
and the fs-metacfg spawn with the bounded wait (design §4.5.2, F39).

Records are built from the committed derived tables (identifiers and
thresholds only, J-123) with a placeholder JSON body; a test-only known row
(`--test-row`, FS_TEST builds only) carries their hashes so that the A-5 ..
A-7 checks are reached. The real rows are checked by tools/test_tables.py.

usage: test_accept.py --bin FS_THERMALD --metacfg FS_METACFG_TEST --fake FAKEHELPER [--out FILE]
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TABLES = os.path.join(HERE, '..', 'tables', 'derived')
UNSET = -0x80000000


def load_tsv(label):
    meta, ents = {}, []
    for ln in open(os.path.join(TABLES, label + '.tsv')).read().splitlines():
        if ln.startswith('# '):
            continue
        if ln.startswith('#'):
            k, v = ln[1:].split('\t')
            meta[k] = v
            continue
        f = ln.split('\t')
        if f[0] == 'name':
            continue
        n, d = f[1].split('/')
        conv = [UNSET if x == '-' else int(x) for x in f[2:16]]
        ents.append([f[0], conv[:7], conv[7:], int(n), int(d)])
    return meta, ents


def entries_bytes(ents):
    out = b''
    for name, sl, hy, mn, md in sorted(ents, key=lambda e: e[0].encode()):
        out += name.encode().ljust(32, b'\0') + struct.pack('<14i2i', *(sl + hy), mn, md)
    return out


def record(dev, incr, ents, json=b'{"placeholder":"derived-table test record"}', vr=b'VR-PLACEHOLDER',
           status=0, json_len=None, n=None, trail=b''):
    e = entries_bytes(ents)
    h = b'FSMC' + struct.pack('<HHIIHHIIIIII', 1, status, len(json) if json_len is None else json_len, len(vr),
                              len(dev), len(incr), len(ents) if n is None else n, 96, 0, 0, 0, 0)
    h = h.ljust(64, b'\0')
    if status:
        return h[:8] + b'\0' * 16 + h[24:]
    return h + json + vr + dev.encode() + incr.encode() + e + trail


def row(label, dev, incr, ents, json=b'{"placeholder":"derived-table test record"}', vr=b'VR-PLACEHOLDER'):
    sha = lambda b: hashlib.sha256(b).hexdigest()
    return f'{label}:{dev}:{incr}:{sha(json)}:{sha(entries_bytes(ents))}:{sha(vr)}'


def accept(binv, device, rec, rows=(), work=None):
    p = os.path.join(work, 'r.bin')
    with open(p, 'wb') as f:
        f.write(rec)
    args = [binv, '--device', device, '--record', p, '--accept-only']
    for r in rows:
        args += ['--test-row', r]
    r = subprocess.run(args, capture_output=True, text=True)
    return dict(kv.split('=', 1) for kv in r.stdout.split())


def mut(ents, name, fn):
    e2 = [[x[0], list(x[1]), list(x[2]), x[3], x[4]] for x in ents]
    for x in e2:
        if x[0] == name:
            fn(x)
    return e2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--metacfg', required=True)
    ap.add_argument('--fake', required=True)
    ap.add_argument('--out')
    a = ap.parse_args()
    work = tempfile.mkdtemp(prefix='fsth-acc-')
    res = []

    def check(name, got, want_reason, want_limits=None, extra=None):
        ok = got.get('reason') == want_reason and (want_limits is None or got.get('limits') == want_limits) and \
            (extra is None or extra(got))
        res.append(f"{'PASS' if ok else 'FAIL'} {name:40s} want reason={want_reason:22s} got "
                   f"limits={got.get('limits')} reason={got.get('reason')} vr_export={got.get('vr_export')}")

    m27, e27 = load_tsv('eureka-v27')
    mq2, eq2 = load_tsv('hollywood-v27')
    dev, inc = m27['device'], m27['incremental']
    R = row('t', dev, inc, e27)
    check('A-9 accepted (v2.7 thresholds, soc-usr SKIN-typed at 115)', accept(a.bin, 'eureka', record(dev, inc, e27), [R], work),
          '-', 'meta-runtime', lambda g: g['vr_export'] == '1')
    check('A-4 VR list hash differs: accepted, not exported',
          accept(a.bin, 'eureka', record(dev, inc, e27, vr=b'other'), [R], work), '-', 'meta-runtime',
          lambda g: g['vr_export'] == '0')
    check('A-4 unknown hash (P18)', accept(a.bin, 'eureka', record(dev, inc, e27), [], work), 'unknown-hash', 'builtin')
    e_bad = mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(1, 89001))
    check('A-4 known hash, other digest (parser defect)', accept(a.bin, 'eureka', record(dev, inc, e_bad), [R], work),
          'digest-mismatch')
    check('A-4 vendor incremental differs (mixed read, M1)',
          accept(a.bin, 'eureka', record(dev, '52433670036000521', e27), [R], work), 'incremental-mismatch')
    check('A-3 device mismatch', accept(a.bin, 'eureka', record('hollywood', inc, e27), [R], work), 'device-mismatch')
    check('A-2 reader status (vab-merge)', accept(a.bin, 'eureka', record(dev, inc, e27, status=16), [R], work),
          'reader:vab-merge')
    check('A-1 truncated record', accept(a.bin, 'eureka', record(dev, inc, e27)[:-1], [R], work), 'reader-bad-record')
    check('A-1 trailing byte', accept(a.bin, 'eureka', record(dev, inc, e27, trail=b'x'), [R], work), 'reader-bad-record')
    check('A-1 json_len over the cap', accept(a.bin, 'eureka', record(dev, inc, e27, json_len=65537), [R], work),
          'reader-bad-record')
    check('A-1 n = 129', accept(a.bin, 'eureka', record(dev, inc, e27, n=129), [R], work), 'reader-bad-record')
    check('A-1 bad magic', accept(a.bin, 'eureka', b'XSMC' + record(dev, inc, e27)[4:], [R], work), 'reader-bad-record')

    def case(name, ents, reason, device='eureka', d=dev, i=inc):
        check(name, accept(a.bin, device, record(d, i, ents), [row('t', d, i, ents)], work), reason,
              'meta-runtime' if reason == '-' else 'builtin')

    case('A-5 multiplier 1/1 on a m°C zone', mut(e27, 'cpu-0-0-0', lambda x: (x.__setitem__(3, 1), x.__setitem__(4, 1))),
         'multiplier')
    case('A-6 CRITICAL set', mut(e27, 'gpuss-1', lambda x: x[1].__setitem__(4, 100000)), 'bounds-unset-slot')
    case('A-6 slot below 35 °C', mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(1, 34999)), 'bounds-range')
    case('A-6 slot above 125 °C', mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(6, 125001)), 'bounds-range')
    case('A-6 not increasing', mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(2, 89000)), 'bounds-order')
    case('A-6 negative hysteresis', mut(e27, 'cpu-0-0-0', lambda x: x[2].__setitem__(1, -1)), 'bounds-hyst')
    case('A-6 release point below 20 °C', mut(e27, 'usb-conn', lambda x: x[2].__setitem__(1, 50001)), 'bounds-release')
    case('A-6 release point at 20 °C (negative control)', mut(e27, 'usb-conn', lambda x: x[2].__setitem__(1, 50000)), '-')
    case('A-6 SoC SHUTDOWN 116 °C', mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(6, 116000)), 'bounds-shutdown')
    case('A-6 battery SHUTDOWN 66 °C', mut(e27, 'batt-virt-usr', lambda x: x[1].__setitem__(6, 66000)), 'bounds-shutdown')
    case('A-6 skin SHUTDOWN 61 °C', mut(e27, 'surf-virt-usr', lambda x: x[1].__setitem__(6, 61000)), 'bounds-shutdown')
    case('A-7 required sensor missing', [x for x in e27 if x[0] != 'gpuss-3'], 'coverage-missing')
    case('A-7 set-slot mask differs', mut(e27, 'cpu-0-0-0', lambda x: x[1].__setitem__(2, UNSET)), 'coverage-mask')
    case('A-7 unmapped sensor with a set slot', mut(e27, 'cam0-usr', lambda x: x[1].__setitem__(1, 50000)),
         'coverage-unmapped')
    case('A-7 BCL entry missing', [x for x in e27 if x[0] != 'pm8550b-bcl-lvl0'], 'coverage-missing')
    q2d, q2i = mq2['device'], mq2['incremental']
    case('Quest 2 accepted (batt-usr 1/10)', eq2, '-', 'hollywood', q2d, q2i)
    case('Quest 2 batt-usr multiplier 1/1000', mut(eq2, 'batt-usr', lambda x: x.__setitem__(4, 1000)), 'multiplier',
         'hollywood', q2d, q2i)
    case('A-6 BOARD bounded too (pcb1-usr slot 0 set)', mut(eq2, 'pcb1-usr', lambda x: x[1].__setitem__(0, 40000)),
         'bounds-unset-slot', 'hollywood', q2d, q2i)
    case('Quest 2 cpu-0 gains a LIGHT', mut(eq2, 'cpu-0-0-usr', lambda x: x[1].__setitem__(1, 90000)), 'coverage-mask',
         'hollywood', q2d, q2i)

    # ---------------- spawn with the bounded wait ----------------
    fixdir = os.path.join(work, 'fix')
    subprocess.run([sys.executable, '-I', os.path.join(HERE, 'fix', 'mkfix.py'), '--out', fixdir], check=True,
                   capture_output=True)
    root = os.path.join(work, 'root')
    os.makedirs(os.path.join(root, 'sys/class/block/sda7'))
    os.makedirs(os.path.join(root, 'dev'))
    os.makedirs(os.path.join(root, 'proc'))
    open(os.path.join(root, 'sys/class/block/sda7/uevent'), 'w').write('DEVNAME=sda7\nPARTNAME=super\n')
    os.symlink(os.path.join(fixdir, 'ok-eureka-a.img'), os.path.join(root, 'dev/sda7'))
    open(os.path.join(root, 'proc/bootconfig'), 'w').write('androidboot.slot_suffix = "_a"\n')
    size = [ln.split('\t')[4] for ln in open(os.path.join(fixdir, 'CASES.tsv')) if ln.startswith('ok-eureka-a\t')][0]
    margs = ['--root', root, '--super-size', size, '--allow-regular']

    def spawn(name, helper, hargs, want, tmin=0.0, tmax=1.9, pin=False, sim=False):
        args = [a.bin, '--device', 'eureka', '--metacfg', helper]
        for x in hargs:
            args += ['--metacfg-arg', x]
        if pin:
            args.append('--pin-before-spawn')
        t0 = time.monotonic()
        if sim:
            simroot = os.path.join(work, 'simroot')
            os.makedirs(simroot, exist_ok=True)
            pr = subprocess.Popen(args + ['--root', simroot, '--sim'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
            import select
            seen, deadline = '', time.monotonic() + 10
            while 'reader-timeout' not in seen and time.monotonic() < deadline:  # ticks only after the fallback
                r_, _, _ = select.select([pr.stderr], [], [], 1)
                if r_:  # raw read: a buffered readline could hide a second line from select
                    chunk = os.read(pr.stderr.fileno(), 65536)
                    if not chunk:
                        break
                    seen += chunk.decode(errors='replace')
            for k in range(6):  # the boot goes on; the killed helper is reaped on a later tick
                pr.stdin.write(f'tick {k * 1000}\n')
                pr.stdin.flush()
                time.sleep(0.3)
            out, err = pr.communicate('quit\n', timeout=20)
            dt = time.monotonic() - t0
            err = seen + err
            ok = want in err and 'helper reaped' in err and len(out.splitlines()) == 6
            res.append(f"{'PASS' if ok else 'FAIL'} {name:40s} want {want} + reaped later; {dt:.2f} s")
            return
        r = subprocess.run(args + ['--accept-only'], capture_output=True, text=True, timeout=20)
        dt = time.monotonic() - t0
        got = dict(kv.split('=', 1) for kv in r.stdout.split()) if r.stdout else {}
        ok = (got.get('reason') in want if isinstance(want, tuple) else got.get('reason') == want) and tmin <= dt <= tmax
        want = '|'.join(want) if isinstance(want, tuple) else want
        res.append(f"{'PASS' if ok else 'FAIL'} {name:40s} want reason={want:22s} got reason={got.get('reason')} "
                   f"in {dt:.2f} s (bound {tmin}-{tmax} s)")

    spawn('spawn: real reader, synthetic file (P18)', a.metacfg, margs, 'unknown-hash')
    spawn('spawn: probe of the spawn rules, then reader', a.fake, ['probe', a.metacfg] + margs, 'unknown-hash', pin=True)
    spawn('spawn: helper hangs -> 2 s deadline', a.fake, ['sleep'], 'reader-timeout', 1.9, 2.6)
    spawn('spawn: half a header then hangs', a.fake, ['partial'], 'reader-timeout', 1.9, 2.6)
    # RLIMIT_CPU (1 s of CPU) usually ends a spinner first; on a loaded host the 2 s wall deadline may: both fall back
    spawn('spawn: helper spins -> RLIMIT_CPU kill', a.fake, ['spin'], ('reader-bad-record', 'reader-timeout'), 0.8, 2.6)
    spawn('spawn: garbage record', a.fake, ['garbage'], 'reader-bad-record')
    spawn('spawn: json_len over the cap', a.fake, ['bigjson'], 'reader-bad-record')
    spawn('spawn: n = 129', a.fake, ['n129'], 'reader-bad-record')
    spawn('spawn: short record then EOF', a.fake, ['short'], 'reader-bad-record')
    spawn('spawn: helper missing (exec fails)', os.path.join(work, 'nope'), [], 'reader-bad-record')
    spawn('spawn: stuck helper, boot continues, reaped', a.fake, ['sleep'], 'reader-timeout', sim=True)
    # negative control for the probe: run it with inherited descriptors and no limits
    pr = os.path.join(work, 'probe.out')
    fd = os.open(pr, os.O_WRONLY | os.O_CREAT, 0o644)
    os.dup2(fd, 3)
    subprocess.run([a.fake, 'eureka', '3', 'probe'], pass_fds=(3,), capture_output=True)
    os.close(3)
    neg = open(pr, 'rb').read().startswith(b'PROBE-FAILED')
    res.append(f"{'PASS' if neg else 'FAIL'} {'probe negative control (no spawn rules)':40s} probe reports failure")

    bad = sum(not x.startswith('PASS') for x in res)
    summ = f'acceptance and spawn: {len(res) - bad}/{len(res)} pass'
    print('\n'.join(res))
    print(summ)
    if a.out:
        with open(a.out, 'w', newline='\n') as f:
            f.write('# fs-thermald acceptance and spawn tests (tools/test_accept.py)\n' + '\n'.join(res) + '\n' + summ + '\n')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
