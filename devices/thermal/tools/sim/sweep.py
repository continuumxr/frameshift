#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-thermald fan sweep (CORE-SPEC §19, round-4 review regression).

Drives the C binary through harness.Sim with the simulated fan of
fanmodel.py and replays every run through the Python reference
(differential, line for line). Two parts:

healthy  a healthy fan under demand alternating 3700 <-> 5500 rpm (SoC
         61 / 86 °C, the 2nd fan trip active in the high half) every 3-6 s,
         for each driver ramp (100, 500, 2000 rpm/s, and v66 without ramp)
         and each corner of tach noise (+-0.5 %, +-10 %) and read-failure
         rate (0, 2 %), SEEDS seeds each; per seed the half-period and the
         rotor dynamics (lag 0.3-1.0 s, acceleration 900-3000 rpm/s, so a
         1800 rpm step takes up to about 2 s) are drawn. Required: no
         shutdown and no fan fault in any run.
faulty   dead, stuck and frozen fans and an unreadable tach, each with
         SEEDS seeds drawing the ramp, the noise (+-0.5-10 %) and the
         read-failure rate (0-2 %). Required: the shutdown within the bound
         stated in CORE-SPEC §19.

usage: sweep.py --bin FS_THERMALD [--seeds N] [--jobs N] [--only PART] [--out FILE]
"""
import argparse
import multiprocessing
import os
import random
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fanmodel import Fan  # noqa: E402
from harness import Sim  # noqa: E402

RAMPS = (100, 500, 2000, 0)          # 0 = v66: no hwmon ramp, the driver jumps
TICKS_HEALTHY = 200


def t4_of(s):
    for o in s.outs:
        e = sorted(x for x in o['E'] if x.startswith('t4:'))
        if e:
            return int(o['t']), e
    return None, []


def make(binary, rps):
    return Sim(binary, fan='v27', rps=str(rps)) if rps else Sim(binary, fan='v66')


def fan_for(s, rnd, noise, fail, seed, **kw):
    cfg = s.config['fan']
    return Fan(cfg['rpm_per_sec'], cfg['silent_rpm'] or 0, tau=rnd.uniform(0.3, 1.0),
               acc=rnd.uniform(900, 3000), noise=noise, fail=fail, seed=rnd.randrange(2 ** 31), **kw)


def finish(s, res):
    s.close()
    d = s.differential()
    res['same'] = not d
    res['diff'] = d[0][:300] if d else ''
    shutil.rmtree(s.dir, ignore_errors=True)
    return res


def healthy(job):
    binary, rps, noise, fail, seed = job
    rnd = random.Random(f'healthy/{rps}/{noise}/{fail}/{seed}')
    half = rnd.randint(3, 6)
    s = make(binary, rps)
    s.fan_model = fan_for(s, rnd, noise, fail, seed)
    for i in range(TICKS_HEALTHY):
        s.val['cpu-1-0-0'] = 86000 if (i // half) % 2 else 61000
        s.step()
    t, e = t4_of(s)
    faults = sorted({x for o in s.outs for x in o['F'] if x.startswith('fan:')})
    errs = sum(1 for k in s.ticks if isinstance(k['fan'], dict) and k['fan']['rpm'] == 'ERR')
    res = dict(part='healthy', group=f'rps={rps or "v66"} noise={noise} fail={fail}', seed=seed, half=half,
               ok=t is None and not faults, t4=e, faults=faults, errs=errs)
    return finish(s, res)


# faulty cases: (name, bound in ms after the onset, description)
FAULTY = {
    'dead-trip2': (38000, 'dead from start at 86 °C: F2 > 20 s after the 15 s spin-up grace, trip 2 at 36 s '
                          '(+1 s per failed read when the timer would start)'),
    'dead-p8': (158000, 'dead from start at 61 °C (no 2nd trip): F2 at 36 s, P8 120 s later (156 s, +2 s)'),
    'stuck2500-alt': (69000, 'stuck at 2500 under 3700/5500 alternation: F3 45 s after the grace, trip 2 by the '
                             'next high half (<= 68 s)'),
    'stuck3700-load': (62000, 'stuck at 3700, then sustained 89 °C (LIGHT, floor 4500): F3 and trip 2 '
                              '<= 62 s after the load (about 53 s at 100 rpm/s)'),
    'frozen-trip2': (32000, 'tach frozen at 4321 at 86 °C: F5 > 30 s, trip 2 <= 32 s after the onset'),
    'unreadable-trip2': (5000, 'every read fails at 86 °C: F6 on the 5th tick, trip 2 on the 6th (5 s)'),
}


def faulty(job):
    binary, case, seed = job
    rnd = random.Random(f'faulty/{case}/{seed}')
    rps = rnd.choice(RAMPS)
    noise = rnd.uniform(0.005, 0.10)
    fail = rnd.uniform(0.0, 0.02)
    s = make(binary, rps)
    onset, n = 0, 0
    if case in ('dead-trip2', 'dead-p8'):
        s.fan_model = fan_for(s, rnd, noise, fail, seed, dead=True)
        s.val['cpu-1-0-0'] = 86000 if case == 'dead-trip2' else 61000
        n = 40 if case == 'dead-trip2' else 160
        s.run(n)
    elif case == 'stuck2500-alt':
        s.fan_model = fan_for(s, rnd, noise, fail, seed, stuck=2500)
        half = rnd.randint(3, 6)
        for i in range(75):
            s.val['cpu-1-0-0'] = 86000 if (i // half) % 2 else 61000
            s.step()
    elif case == 'stuck3700-load':
        s.fan_model = fan_for(s, rnd, noise, fail, seed)
        s.run(30)
        s.fan_model.stuck = 3700
        s.val['cpu-1-0-0'] = 89000
        onset = s.t + 1000
        s.run(70)
    elif case == 'frozen-trip2':
        s.fan_model = fan_for(s, rnd, noise, fail, seed)
        s.val['cpu-1-0-0'] = 86000
        s.run(30)
        s.fan_model.frozen = 4321
        onset = s.t + 1000
        s.run(40)
        # the first repeated reading starts F5's timer: the tick after the first successful frozen read
        first = next(k['t'] for k in s.ticks if k['t'] >= onset and isinstance(k['fan'], dict)
                     and k['fan']['rpm'] == 4321)
        onset = first + 1000
    elif case == 'unreadable-trip2':
        s.fan_model = fan_for(s, rnd, noise, fail, seed)
        s.val['cpu-1-0-0'] = 86000
        s.run(30)
        s.fan_model.fail = 1.0
        onset = s.t + 1000
        s.run(10)
    t, e = t4_of(s)
    bound = FAULTY[case][0]
    ok = t is not None and t - onset <= bound
    res = dict(part='faulty', group=case, seed=seed, rps=rps, noise=round(noise, 4), fail=round(fail, 4),
               ok=ok, t4=e, after=None if t is None else t - onset, bound=bound)
    return finish(s, res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--seeds', type=int, default=20)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--only', choices=('healthy', 'faulty'))
    ap.add_argument('--out')
    a = ap.parse_args()
    jobs_h = [(a.bin, rps, noise, fail, seed) for rps in RAMPS for noise in (0.005, 0.10) for fail in (0.0, 0.02)
              for seed in range(a.seeds)]
    jobs_f = [(a.bin, case, seed) for case in FAULTY for seed in range(a.seeds)]
    t0 = time.time()
    res = []
    with multiprocessing.Pool(a.jobs) as pool:
        if a.only in (None, 'healthy'):
            res += pool.map(healthy, jobs_h, chunksize=4)
        if a.only in (None, 'faulty'):
            res += pool.map(faulty, jobs_f, chunksize=2)
    lines, bad = [], 0
    groups = {}
    for r in res:
        groups.setdefault((r['part'], r['group']), []).append(r)
    for (part, g), rs in groups.items():
        nok = sum(r['ok'] for r in rs)
        nsame = sum(r['same'] for r in rs)
        if part == 'healthy':
            extra = f"shutdowns {sum(bool(r['t4']) for r in rs)}, runs with a fan fault " \
                    f"{sum(bool(r['faults']) for r in rs)}, failed reads {sum(r['errs'] for r in rs)}"
        else:
            after = [r['after'] for r in rs if r['after'] is not None]
            extra = f"t4 after onset {min(after, default=0) / 1000:.0f}-{max(after, default=0) / 1000:.0f} s " \
                    f"(bound {rs[0]['bound'] / 1000:.0f} s), reasons {sorted({x for r in rs for x in r['t4']})}"
        st = 'PASS' if nok == len(rs) and nsame == len(rs) else 'FAIL'
        bad += st == 'FAIL'
        lines.append(f'{st} {part:7s} {g}: {nok}/{len(rs)} ok, C = Python {nsame}/{len(rs)}; {extra}')
        for r in rs:
            if not r['ok'] or not r['same']:
                lines.append(f"    seed {r['seed']}: {r}")
    summ = f'sweep: {len(groups) - bad}/{len(groups)} groups pass, {len(res)} runs, ' \
           f'{sum(r["same"] for r in res)}/{len(res)} C = Python (wall time {time.time() - t0:.0f} s, ' \
           f'{a.jobs} jobs)'
    print('\n'.join(lines))
    print(summ)
    if a.out:
        with open(a.out, 'w', newline='\n') as f:
            f.write('# fs-thermald fan sweep (tools/sim/sweep.py): status, part, group, results\n')
            f.write('\n'.join(lines) + '\n' + summ + '\n')
    sys.exit(0 if bad == 0 else 1)


if __name__ == '__main__':
    main()
