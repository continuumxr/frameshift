#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Table checks (CI-able, no Meta file needed):

1. every known-firmware row compiled into fs-thermald equals
   tables/known-firmware.tsv, and its parse digest equals the SHA-256 of the
   canonical record rebuilt from the committed derived table;
2. the built-in fallback of each device equals the design's numbers
   (emergency-shutdown-design.md §4.1; thermal-control-design.md §2.2; F12),
   written out literally below, and equals the reviewed file it was taken
   from (Quest 3: v66 file; Quest 2: v2.7 file) sensor by sensor;
3. the v2.7 Quest 3 file differs from the fallback only in usb-conn
   (LIGHT 70, hysteresis 45; §4.5.5);
4. caps, fan levels, floors and P5 equal thermal-control-design.md §0.1,
   §1.3, §6.3 with P11 rejected;
5. static checks on the binaries: no forbidden write targets.

usage: test_tables.py --bin FS_THERMALD [--bins B1 B2 ...] [--out FILE]
"""
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
T = os.path.join(HERE, '..', 'tables')
SRC = os.path.join(HERE, '..', 'src', 'thermald_tables.c')
U = None


def derived(label):
    meta, ents = {}, {}
    for ln in open(os.path.join(T, 'derived', label + '.tsv')).read().splitlines():
        if ln.startswith('# '):
            continue
        if ln.startswith('#'):
            k, v = ln[1:].split('\t')
            meta[k] = v
            continue
        f = ln.split('\t')
        if f[0] == 'name':
            continue
        ents[f[0]] = (f[1], [None if x == '-' else int(x) for x in f[2:9]], [None if x == '-' else int(x) for x in f[9:16]])
    return meta, ents


def canon(ents):
    out = b''
    for name in sorted(ents, key=lambda n: n.encode()):
        mult, sl, hy = ents[name]
        n, d = map(int, mult.split('/'))
        vals = [(-0x80000000 if x is None else x) for x in sl + hy]
        out += name.encode().ljust(32, b'\0') + struct.pack('<14i2i', *vals, n, d)
    return out


# The design's fallback numbers, written out (emergency-shutdown-design.md §4.1, F12;
# thermal-control-design.md §2.2), in m°C, slots LIGHT, MODERATE, SEVERE, SHUTDOWN.
DESIGN = {
    'eureka': {
        'SOC': ((89000, 92000, 95000, 115000), (2000, 2000, 2000, 5000)),
        'BATT': ((58000, 61000, 63000, 65000), (2000, 2000, 1000, 1000)),
        'SKIN': ((48000, 50000, 52000, 60000), (1000, 1000, 1000, 5000)),
    },
    'hollywood': {
        'batt-virt': ((53000, None, 58000, 59000), (1000, 0, 3000, 1000)),
        'vrapi-front-panel': ((47000, 51000, 52000, 60000), (1000, 1000, 5000, 5000)),
        'cpu-1': ((90000, None, 95000, 115000), (5000, 0, 5000, 5000)),
        'cpu-0': ((None, None, 95000, 115000), (0, 0, 5000, 5000)),
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--bins', nargs='*', default=[])
    ap.add_argument('--out')
    a = ap.parse_args()
    res = []

    def ok(name, cond, detail=''):
        res.append(f"{'PASS' if cond else 'FAIL'} {name}" + (f' ({detail})' if detail and not cond else ''))

    kf = [ln.split('\t') for ln in open(os.path.join(T, 'known-firmware.tsv')).read().splitlines()
          if ln and not ln.startswith('#')]
    hdr, rows = kf[0], kf[1:]
    src = open(SRC).read()
    for r in rows:
        d = dict(zip(hdr, r))
        meta, ents = derived(d['label'])
        dig = hashlib.sha256(canon(ents)).hexdigest()
        ok(f"{d['label']}: digest = sha256(canonical record of the derived table)", dig == d['digest'], dig)
        ok(f"{d['label']}: compiled-in row equals known-firmware.tsv",
           all(v in src for v in (d['incremental'], d['json_sha256'], d['digest'], d['vr_sha256'])) and
           re.search(rf'"{d["label"]}", "{d["incremental"]}"', src) is not None)
        # label -> hash, size, incremental and device exactly as the design cites them (F31, F40, §4.5.1)
        want = {'eureka-v66': ('e49b49fe2920cd83', '674af9d5d27acf7b', '27284', '50105190000000511', 'eureka'),
                'eureka-v27': ('c9301ff553f65255', 'd3a2ffa41e057cfa', '27505', '52433670036000520', 'eureka'),
                'hollywood-v27': ('cc3e513784a468d2', 'f525cc6a6cb50f4d', '16015', '52242990024200150', 'hollywood')}
        w = want.get(d['label'])
        ok(f"{d['label']}: label -> json/VR hash, size, incremental, device as cited by the design (F31, F40)",
           w is not None and d['json_sha256'][:16] == w[0] and d['vr_sha256'][:16] == w[1] and d['json_size'] == w[2]
           and d['incremental'] == w[3] and d['device'] == w[4])

    for dev, base in (('eureka', 'eureka-v66'), ('hollywood', 'hollywood-v27')):
        cfg = json.loads(subprocess.run([a.bin, '--device', dev, '--dump-config'], capture_output=True, text=True).stdout)
        _, ents = derived(base)
        mism = []
        for s in cfg['sensors']:
            if s['kind'] == 'psy' or s['name'] not in ents:
                continue
            _, sl, hy = ents[s['name']]
            th = s['th']
            hh = s['hy']
            if th != sl or hh != hy:
                mism.append(s['name'])
        ok(f'{dev}: built-in fallback = reviewed file {base}, sensor by sensor', not mism, ','.join(mism))
        bad = []
        for s in cfg['sensors']:
            key = s['class'] if dev == 'eureka' else ('cpu-1' if s['name'].startswith('cpu-1') else
                                                     'cpu-0' if s['name'].startswith(('cpu-0', 'cpuss', 'gpuss')) else s['name'])
            if key not in DESIGN[dev] or (dev == 'eureka' and s['name'] == 'ddr'):
                continue  # ddr: monitored for faults only, no Meta threshold
            want_th, want_hy = DESIGN[dev][key]
            got_th = (s['th'][1], s['th'][2], s['th'][3], s['th'][6])
            got_hy = (s['hy'][1], s['hy'][2], s['hy'][3], s['hy'][6])
            if got_th != want_th or got_hy != want_hy:
                bad.append(s['name'])
        ok(f'{dev}: built-in fallback = design §4.1 / F12 numbers', not bad, ','.join(bad))
    _, e66 = derived('eureka-v66')
    _, e27 = derived('eureka-v27')
    diff = sorted(n for n in set(e66) | set(e27) if e66.get(n) != e27.get(n))
    ok('v2.7 differs from v66 only in usb-conn (LIGHT 70, hyst 45)', diff == ['usb-conn'] and
       e27['usb-conn'][1][1] == 70000 and e27['usb-conn'][2][1] == 45000, ','.join(diff))
    cfg = json.loads(subprocess.run([a.bin, '--device', 'eureka', '--dump-config'], capture_output=True, text=True).stdout)
    ok('Quest 3 caps: NORMAL = L4 1.92 GHz / 545 MHz (P11 rejected), P3 LIGHT..SEVERE, T4/T5 minimum',
       cfg['caps'] == {'cpu': [1920000, 1651200, 1382400, 1094400, 'min', 'min'], 'gpu': [3, 4, 6, 8, 9, 9]})
    f = cfg['fan']
    ok('Quest 3 fan: levels 0/3700/4500/5000/5500, P1 3700, P4 4500/5000/5500, top 5500',
       f['levels'] == [0, 3700, 4500, 5000, 5500] and f['floor_p1'] == 3700 and
       f['floor_tier'] == [0, 4500, 5000, 5500, 5500, 5500] and f['top'] == 5500)
    ok('Quest 3 fan rules: 28 zones (12 cpu, 2 cpuss, 8 gpuss, 3 nspss, soc, batt-virt, surf-virt)', len(f['rules']) == 28)
    ok('P5 usb-conn 70 °C', cfg['p5'] == {'sensor': 'usb-conn', 't': 70000})
    q2 = json.loads(subprocess.run([a.bin, '--device', 'hollywood', '--dump-config'], capture_output=True, text=True).stdout)
    ok('Quest 2 (J-172): CPU caps none at T0-T2, min at T3-T5; policies 0/4/7; no fan rules -> READY only headless',
       q2['caps'] == {'cpu': [None, None, None, 'min', 'min', 'min'], 'gpu': None} and q2['policies'] == [0, 4, 7]
       and q2['fan'] is None)
    ok('Quest 3: soc-usr is the only weak sensor; ddr monitored; DT max-rpm 8500; policies 0/2',
       [x['name'] for x in cfg['sensors'] if x['weak']] == ['soc-usr'] and any(x['name'] == 'ddr' for x in cfg['sensors'])
       and cfg['fan']['max_rpm'] == 8500 and cfg['policies'] == [0, 2])
    r = subprocess.run([a.bin, '--device', 'seacliff', '--dump-config'], capture_output=True, text=True)
    ok('Quest Pro (no built-in set): refused, never READY (A-9)', r.returncode == 3)
    for b in [a.bin] + a.bins:
        data = open(b, 'rb').read()
        # part 2 (EXEC-SPEC §7): the softdog and sysrq paths exist only in the
        # executor builds (device product/trial, and the test build's stand-ins);
        # never in fs-metacfg, the log-only build or fs-poweroff-final
        name = os.path.basename(b)
        executor = name.startswith('fs-thermald') and 'logonly' not in name
        never = (b'poweroff_cmd', b'restrict_cur', b'restrict_chg', b'charge_control_limit', b'shutdown,thermal',
                 b'RESTART2', b'force_failure')
        forb = [s for s in never + (() if executor else (b'sysrq-trigger', b'/dev/watchdog')) if s in data]
        ok(f'{os.path.basename(b)}: no forbidden write target in the binary', not forb, ','.join(x.decode() for x in forb))
    bad = sum(not x.startswith('PASS') for x in res)
    summ = f'tables and static checks: {len(res) - bad}/{len(res)} pass'
    print('\n'.join(res))
    print(summ)
    if a.out:
        with open(a.out, 'w', newline='\n') as fo:
            fo.write('# table and static checks (tools/test_tables.py)\n' + '\n'.join(res) + '\n' + summ + '\n')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
