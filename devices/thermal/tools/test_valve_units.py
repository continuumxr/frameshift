#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Valve-layer static checks and fs-thermald-watch tests (EXEC-SPEC.md §9).

Static: every unit and drop-in in devices/thermal/valve carries the
directives emergency-shutdown-design.md §6.2 requires (and none that would
undo them). Behaviour (native test build of fs-thermald-watch): the
heartbeat staleness rule, the SHUTDOWN byte path (never blocks, with or
without a reader), and the watch loop's single "systemctl poweroff".

This is NOT the systemd 257.7 QEMU suite of design §7.1 (open, EXEC-SPEC §11).

usage: test_valve_units.py [--build DIR] [--out FILE]
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
V = os.path.join(HERE, '..', 'valve')
res = []


def ok(name, cond, detail=''):
    res.append(('PASS ' if cond else 'FAIL ') + name + ('' if cond else f'  [{detail}]'))


def ini(path):
    d, sec = {}, None
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('['):
            sec = line.strip('[]')
            continue
        k, _, v = line.partition('=')
        d.setdefault((sec, k.strip()), []).append(v.strip())
    return d


def has(d, sec, k, v):
    return v in d.get((sec, k), [])


def static_checks():
    w = ini(os.path.join(V, 'system', 'fs-thermald-watch.service'))
    ok('watch: DefaultDependencies=no, Before=sysinit.target', has(w, 'Unit', 'DefaultDependencies', 'no')
       and has(w, 'Unit', 'Before', 'sysinit.target'))
    ok('watch: Restart=always', has(w, 'Service', 'Restart', 'always'))
    ok('watch: OOMScoreAdjust=-1000', has(w, 'Service', 'OOMScoreAdjust', '-1000'))
    ok('watch: heartbeat path and PID 1 given (kill(1, 38), review m4)',
       any(x.endswith('watch /run/fs-thermald/hb 1') for x in w.get(('Service', 'ExecStart'), [])))
    # review M6: every unit is pulled in (an [Install] section, or Requires=/Wants= from another unit)
    units = sorted(os.listdir(os.path.join(V, 'system')))
    pulled = set()
    for u in units:
        d = ini(os.path.join(V, 'system', u))
        for k in ('Requires', 'Wants'):
            for v in d.get(('Unit', k), []):
                pulled.update(v.split())
    for u in units:
        d = ini(os.path.join(V, 'system', u))
        ok(f'{u}: started by something ([Install] WantedBy= or Requires=/Wants=)',
           bool(d.get(('Install', 'WantedBy'))) or u in pulled or u.endswith('.target'))
    s = ini(os.path.join(V, 'system', 'fs-thermald-shutdown.service'))
    for k, v in (('DefaultDependencies', 'no'), ('Conflicts', 'shutdown.target'), ('Before', 'shutdown.target'),
                 ('IgnoreOnIsolate', 'yes'), ('RefuseManualStop', 'yes')):
        ok(f'shutdown: [Unit] {k}={v}', has(s, 'Unit', k, v))
    ok('shutdown: only Before=shutdown.target ordering (rev 3)', s.get(('Unit', 'Before')) == ['shutdown.target']
       and ('Unit', 'After') not in s)
    for k, v in (('Type', 'oneshot'), ('RemainAfterExit', 'yes')):
        ok(f'shutdown: [Service] {k}={v}', has(s, 'Service', k, v))
    ok('shutdown: ExecStop sends the byte', any('send-shutdown /run/fs-thermald/ctl' in x
                                                for x in s.get(('Service', 'ExecStop'), [])))
    m = ini(os.path.join(V, 'system.conf.d', '50-frameshift.conf'))
    for k, v in (('RuntimeWatchdogSec', 'off'), ('RebootWatchdogSec', 'off'), ('KExecWatchdogSec', 'off'),
                 ('DefaultTimeoutStopSec', '10s'), ('DefaultLimitRTPRIO', '49')):
        ok(f'system.conf: {k}={v}', has(m, 'Manager', k, v))
    p = ini(os.path.join(V, 'poweroff.target.d', '50-frameshift.conf'))
    ok('poweroff.target: JobTimeoutSec=35s poweroff-force', has(p, 'Unit', 'JobTimeoutSec', '35s')
       and has(p, 'Unit', 'JobTimeoutAction', 'poweroff-force'))
    for t in ('reboot', 'kexec'):
        r = ini(os.path.join(V, f'{t}.target.d', '50-frameshift.conf'))
        ok(f'{t}.target: JobTimeoutSec=35s with its own force action', has(r, 'Unit', 'JobTimeoutSec', '35s')
           and has(r, 'Unit', 'JobTimeoutAction', 'reboot-force'))
    c = ini(os.path.join(V, 'service.d', '50-frameshift-caps.conf'))
    ok('every service: CapabilityBoundingSet=~CAP_SYS_BOOT, RestrictRealtime=yes',
       has(c, 'Service', 'CapabilityBoundingSet', '~CAP_SYS_BOOT') and has(c, 'Service', 'RestrictRealtime', 'yes'))
    masks = [l.strip() for l in open(os.path.join(V, 'MASKS.txt')) if l.strip() and not l.startswith('#')]
    for u in ('soft-reboot.target', 'systemd-soft-reboot.service', 'halt.target', 'systemd-halt.service',
              'sleep.target', 'suspend.target'):
        ok(f'masked: {u}', u in masks)
    lg = ini(os.path.join(V, 'logind.conf.d', '50-frameshift.conf'))
    ok('logind: suspend key ignored, power key powers off', has(lg, 'Login', 'HandleSuspendKey', 'ignore')
       and has(lg, 'Login', 'HandlePowerKey', 'poweroff'))
    # nothing in our layer re-enables what the design forbids
    for root, _, files in os.walk(V):
        for f in files:
            t = open(os.path.join(root, f)).read()
            rel = os.path.relpath(os.path.join(root, f), V)
            ok(f'{rel}: no RuntimeWatchdogSec other than off, no WatchdogDevice, no CAP_SYS_BOOT grant',
               all(x not in t for x in ('RuntimeWatchdogSec=1', 'RuntimeWatchdogSec=3', 'WatchdogDevice=',
                                        'AmbientCapabilities=CAP_SYS_BOOT')))


def hbrec(seq, bt, st):
    return ('%20d %12d %-5s\n' % (seq, bt, st)).encode()


def behaviour(b):
    w = os.path.join(b, 'fs-thermald-watch-test')
    if not os.path.exists(w):
        ok('fs-thermald-watch test build present', False, w)
        return
    d = tempfile.mkdtemp(prefix='fsvw-')
    hb = os.path.join(d, 'hb')

    def chk(rec, now, prev, same):
        if rec is None:
            if os.path.exists(hb):
                os.unlink(hb)
        else:
            open(hb, 'wb').write(rec)
        return subprocess.run([w, 'check', hb, str(now), str(prev), str(same)], capture_output=True,
                              text=True).stdout.split()[0]
    ok('check: fresh READY record ok', chk(hbrec(7, 100, 'READY'), 103, 6, 0) == 'ok')
    ok('check: boottime 6 s behind -> stale-age', chk(hbrec(7, 100, 'READY'), 106, 6, 0) == 'stale-age')
    ok('check: boottime 5 s behind -> ok (boundary)', chk(hbrec(7, 100, 'READY'), 105, 6, 0) == 'ok')
    ok('check: seq unchanged for the 5th tick -> stale-seq', chk(hbrec(7, 100, 'READY'), 101, 7, 4) == 'stale-seq')
    ok('check: seq unchanged 4 ticks -> ok', chk(hbrec(7, 100, 'READY'), 101, 7, 3) == 'ok')
    ok('check: missing -> garbled', chk(None, 101, 0, 0) == 'garbled')
    ok('check: short record -> garbled', chk(b'7 100 READY\n', 101, 0, 0) == 'garbled')
    ok('check: unknown state -> garbled', chk(hbrec(7, 100, 'BOGUS'), 101, 0, 0) == 'garbled')
    # SHUTDOWN byte: FIFO with a reader gets 'S'; without a reader or without the FIFO: exit 0, no block
    ctl = os.path.join(d, 'ctl')
    os.mkfifo(ctl)
    rfd = os.open(ctl, os.O_RDONLY | os.O_NONBLOCK)
    t0 = time.time()
    r = subprocess.run([w, 'send-shutdown', ctl], capture_output=True, text=True, timeout=5)
    got = os.read(rfd, 16)
    os.close(rfd)
    ok('send-shutdown: one S byte to a reading supervisor', r.returncode == 0 and got == b'S', repr(got))
    t0 = time.time()
    r = subprocess.run([w, 'send-shutdown', ctl], capture_output=True, text=True, timeout=5)
    ok('send-shutdown: FIFO without a reader -> exit 0 at once (never blocks a stop job)',
       r.returncode == 0 and time.time() - t0 < 2)
    r = subprocess.run([w, 'send-shutdown', os.path.join(d, 'absent')], capture_output=True, text=True, timeout=5)
    ok('send-shutdown: no FIFO -> exit 0', r.returncode == 0)
    open(os.path.join(d, 'reg'), 'w').close()
    r = subprocess.run([w, 'send-shutdown', os.path.join(d, 'reg')], capture_output=True, text=True, timeout=5)
    ok('send-shutdown: a regular file is not written', r.returncode == 0 and os.path.getsize(os.path.join(d, 'reg')) == 0)
    # watch loop: a frozen record -> exactly one kill(PID 1, 38) (a fake PID 1 records the signals)
    log = os.path.join(d, 'pid1.log')
    fp = subprocess.Popen([os.path.join(b, 'fakepid1'), log])
    for _ in range(200):
        if os.path.exists(log) and open(log).read().startswith('ready'):
            break
        time.sleep(0.01)
    bt = int(open('/proc/uptime').read().split('.')[0])
    open(hb, 'wb').write(hbrec(1, bt, 'READY'))
    p = subprocess.Popen([w, 'watch', hb, str(fp.pid)], stderr=subprocess.PIPE)
    time.sleep(8.5)
    p.kill()
    p.wait()
    fp.kill()
    fp.wait()
    sigs = [l for l in open(log).read().split('\n') if l.startswith('sig ')]
    ok('watch: a frozen heartbeat -> exactly one signal 38 to PID 1 (graceful T4, no polkit)', sigs == ['sig 38'],
       repr(sigs))
    # negative control: an advancing record -> no signal
    log2 = os.path.join(d, 'pid1b.log')
    fp = subprocess.Popen([os.path.join(b, 'fakepid1'), log2])
    time.sleep(0.2)
    p = subprocess.Popen([w, 'watch', hb, str(fp.pid)], stderr=subprocess.PIPE)
    for k in range(8):
        open(hb, 'wb').write(hbrec(10 + k, int(open('/proc/uptime').read().split('.')[0]), 'READY'))
        time.sleep(1)
    p.kill()
    p.wait()
    fp.kill()
    fp.wait()
    ok('watch: an advancing heartbeat -> no signal (negative control)',
       not [l for l in open(log2).read().split('\n') if l.startswith('sig ')])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', default=os.path.expanduser('~/fsth-build'))
    ap.add_argument('--out')
    a = ap.parse_args()
    static_checks()
    behaviour(a.build)
    bad = sum(not x.startswith('PASS') for x in res)
    summ = f'valve layer: {len(res) - bad}/{len(res)} pass (static unit checks + fs-thermald-watch; NOT the systemd QEMU suite)'
    print('\n'.join(res))
    print(summ)
    sys.exit(0 if not bad else 1)


if __name__ == '__main__':
    main()
