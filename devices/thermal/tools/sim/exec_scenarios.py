#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-thermald part 2: executor scenarios (EXEC-SPEC.md §6, suite EX).

Each scenario runs the test build in --exec-sim mode: the real executor
(thermald_exec.c) under a fake root, with logged stand-ins only for the
kernel-facing calls (softdog ioctls -> lines in dev/watchdog, reboot() in A2
-> "a2 poweroff-called", sync() in A1 -> a short sleep). Real processes are
used for everything else: the pre-forked actuators A1/A2 and their pipes,
the fake PID 1 that receives the literal signal 38, a stage step's process
group, the control FIFO, the pmsg/notice/heartbeat records, and stalled
consumers. Every scenario is then compared tick by tick with the Python
reference (tools/ref/core_ref.py) on the inputs the executor reported, and
every FST1/FSN1 record is checked with the independent tools/ref/fst_ref.py.

usage: exec_scenarios.py --bin FS_THERMALD_TEST --fakepid1 BIN --stepgroup BIN
                         [--logonly-bin BIN] [--only NAME] [--out FILE]
"""
import argparse
import os
import random
import signal
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'ref'))
from harness import Sim, Fail, expect  # noqa: E402
import fst_ref  # noqa: E402

SC = []
A = None  # parsed args


def sc(fn):
    SC.append(fn)
    return fn


def at(s, t):
    for o in s.outs:
        if int(o['t']) == t:
            return o
    raise Fail(f'no tick at t={t}')


def X(B, markers=(), dload='0', pstore=None, a2_dead=False, **kw):
    o = {'fakepid1': A.fakepid1, 'markers': tuple(markers), 'dload': dload, 'pstore': pstore, 'a2_dead': a2_dead}
    return B(exec_opts=o, **kw)


def wd_lines(s):
    b = s.file('dev/watchdog') or b''
    return [l for l in b.decode().split('\n') if l]


def pmsg_records(s):
    b = s.file('dev/pmsg0') or b''
    out = []
    for l in b.decode().split('\n'):
        if l:
            r = fst_ref.parse(l)
            if r is None:
                raise Fail('pmsg: a record the reference does not accept: ' + l)
            out.append(r)
    return out


def notice(s):
    r = fst_ref.fsn_parse(s.file('run/fs-thermald/notice') or b'')
    if r is None:
        raise Fail('notice record invalid')
    return r


def hb(s):
    return (s.file('run/fs-thermald/hb') or b'').decode().split()


def xlog_at(s, t):
    return [l[len(f't={t} '):] for l in s.xlog().split('\n') if l.startswith(f't={t} ')]


def soc_t4(s):
    s.val['cpu-1-0-0'] = 115000
    t4 = int(s.step()['t'])
    s.val['cpu-1-0-0'] = 100000
    return t4


# ---------------------------------------------------------------- valve timeline
@sc
def x_valve_t4_timeline(B):
    s = X(B, flags=['--softdog'])
    s.run(3)
    t4 = soc_t4(s)
    s.run(60)
    expect(s.pid1_signals() == [38], f'fake PID 1 got exactly one signal 38 (E-11): {s.pid1_signals()}')
    expect('signal-pid1 38' in xlog_at(s, t4), 'signal-pid1 executed on the T4 latch tick')
    expect('a1 sent' in xlog_at(s, t4 + 45000) and 'a1 sync-done' in s.xlog(), 'A1 at + 45 s, sync reported')
    l55 = xlog_at(s, t4 + 55000)
    expect('final-pet margin=30' in l55 and 'a2 sent' in l55 and l55.index('final-pet margin=30') < l55.index('a2 sent'),
           f'final pet then A2 at + 55 s (E-16): {l55}')
    expect('a2 poweroff-called' in s.xlog(), 'A2 acted on its byte')
    w = wd_lines(s)
    expect(w[0] == 'settimeout 30', 'softdog: margin 30 set at open (E-3)')
    expect(w[-2:] == ['settimeout 30', 'keepalive'], f'softdog ends with the final pet (E-4): {w[-3:]}')
    npets = sum(1 for o in s.outs if 'pet' in o['A'])
    expect(w.count('keepalive') == npets + 1, f'one keepalive per petted tick + the final pet: {w.count("keepalive")} vs {npets}')
    expect(not any('pet' in o['A'] for o in s.outs if int(o['t']) >= t4 + 55000), 'no pet after the final pet')
    recs = pmsg_records(s)
    evs = [r['ev'] for r in recs]
    expect(evs == ['t4', 't5', 'a2'], f'pmsg records t4, t5, a2 (E-20): {evs}')
    expect(recs[0]['reason'] == 'soc-temperature-high' and recs[0]['sensor'] == 'cpu-1-0-0'
           and recs[0]['value'] == '115000' and recs[0]['cd'] == 55, f't4 record names cause and value: {recs[0]}')
    n = notice(s)
    expect(n['n'] == s.outs[-1]['n'] and n['seq'] == len(s.outs), 'notice record = the last tick notice, seq per tick')
    expect(hb(s)[2] == 'READY' and len(s.file('run/fs-thermald/hb')) == 40, 'heartbeat: READY, one 40-byte record (E-26)')
    return s


@sc
def x_fast_t5_a1_done(B):
    s = X(B, flags=['--softdog'])
    s.run(3)
    s.val['cpu-1-0-0'] = 115000
    t4 = int(s.step()['t'])
    s.val['cpu-1-0-0'] = 121000  # P12: SHUTDOWN + 6 C -> fast T5
    tf = int(s.step()['t'])
    expect('a1 sent' in xlog_at(s, tf), 'fast T5: A1 at once (C-36)')
    o = s.step()  # A1 reported on the previous tick -> final pet + A2 now
    expect(o['A'] >= {'final-pet', 'a2'} and s.ins[-1]['a1_done'] == 1, 'a1_done from the real A1 -> A2 next tick')
    expect(int(o['t']) < t4 + 55000, 'fast path well before the budget')
    s.run(3)
    return s


@sc
def x_a2_returns_p15(B):
    s = X(B, flags=['--softdog', '--p15'], markers=('a2-returns',))
    s.run(2)
    t4 = soc_t4(s)
    s.run(58)
    expect(s.file('proc/sysrq-trigger') == b'c', 'P15: exactly one "c" after A2 exited (E-18)')
    i = next(k for k, o in enumerate(s.outs) if 'sysrq-c' in o['A'])
    expect(int(s.outs[i]['t']) > t4 + 55000 and s.ins[i]['a2_exited'] == 1, 'sysrq only after A2 exit observed')
    evs = [r['ev'] for r in pmsg_records(s)]
    expect('a2-returned' in evs, f'pmsg a2-returned record: {evs}')
    return s


@sc
def x_a2_returns_no_p15(B):
    s = X(B, flags=['--softdog'], markers=('a2-returns',))
    s.run(2)
    soc_t4(s)
    s.run(60)
    expect(s.file('proc/sysrq-trigger') == b'', 'no sysrq without P15 (negative control)')
    expect(wd_lines(s)[-2:] == ['settimeout 30', 'keepalive'], 'softdog left to fire M_final after the final pet')
    return s


@sc
def x_external_shutdown_byte(B):
    s = X(B, flags=['--softdog'])
    s.run(5)
    fd = os.open(os.path.join(s.root, 'run/fs-thermald/ctl'), os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, b'S')
    os.close(fd)
    t0 = int(s.step()['t'])
    s.run(56)
    expect(s.ins[5]['shutdown_byte'] == 1, 'SHUTDOWN byte read from the control FIFO (E-14)')
    expect(s.pid1_signals() == [], 'no signal to PID 1 for its own shutdown')
    expect('a1 sent' in xlog_at(s, t0 + 45000) and 'a2 sent' in xlog_at(s, t0 + 55000), 'A1 + 45 s, A2 + 55 s')
    return s


@sc
def x_ctl_other_bytes(B):
    s = X(B)
    s.run(3)
    fd = os.open(os.path.join(s.root, 'run/fs-thermald/ctl'), os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, b'xyz\n\0')
    os.close(fd)
    s.run(5)
    expect(all(i['shutdown_byte'] == 0 for i in s.ins), 'only the byte S counts (negative control)')
    return s


@sc
def x_pid1_comm(B):
    s = X(B)
    s.run(3)
    s.pid1 = 'systemd-shutdow'
    t0 = int(s.step()['t'])
    s.run(56)
    expect(s.ins[3]['pid1_shutdown'] == 1, 'pre-opened /proc/1/comm read each tick')
    expect('a2 sent' in xlog_at(s, t0 + 55000), 'detected systemd-shutdown -> A2 at + 55 s')
    return s


# ---------------------------------------------------------------- softdog preconditions
@sc
def x_softdog_dload1_refused(B):
    s = X(B, flags=['--softdog', '--require-softdog'], dload='1')
    s.run(5)
    expect(wd_lines(s) == [], 'download_mode 1: softdog never opened (E-2)')
    expect('softdog download_mode-not-0' in s.xlog(), 'refusal logged')
    expect(s.outs[-1]['ready'] == 1 and s.ins[-1]['ready_pub'] == 0 and hb(s)[2] == 'HOLD',
           'core READY but no published READY without the required softdog')
    return s


@sc
def x_softdog_dload_missing(B):
    s = X(B, flags=['--softdog'], dload=None)
    s.run(3)
    expect(wd_lines(s) == [] and 'download_mode-unreadable' in s.xlog(), 'module absent: refused (E-2)')
    expect(s.ins[-1]['ready_pub'] == 1, 'softdog not required: READY published')
    return s


@sc
def x_softdog_dload_garbage(B):
    s = X(B, flags=['--softdog'], dload='0 1')
    s.run(2)
    expect(wd_lines(s) == [], 'download_mode must read exactly 0')
    return s


@sc
def x_no_softdog_flag(B):
    s = X(B)
    s.run(2)
    soc_t4(s)
    s.run(57)
    expect(wd_lines(s) == [], 'softdog untouched without --softdog (separate action class)')
    expect('final-pet (softdog not-requested)' in s.xlog(), 'final pet logged as a no-op')
    return s


# ---------------------------------------------------------------- stage mode (S1 guard)
@sc
def x_stage_trip(B):
    s = X(B, flags=['--stage', '--softdog', '--step-pgid-file', '/run/fs-step.pgid'])
    pg = os.path.join(s.root, 'run/fs-step.pgid')
    lg = os.path.join(s.dir, 'step.log')
    st = subprocess.Popen([A.stepgroup, pg, lg])
    for _ in range(200):
        if os.path.exists(pg) and open(pg).read().strip():
            break
        time.sleep(0.01)
    try:
        s.run(3)
        t4 = soc_t4(s)
        time.sleep(0.1)
        expect(open(lg).read().count('term') == 1, 'term-step: SIGTERM to the step group at the latch')
        expect(st.poll() is None, 'step survives SIGTERM (it ignores it)')
        s.run(2)
        time.sleep(0.2)
        expect(st.poll() == -signal.SIGKILL, f'kill-step at + 2 s (C-39): {st.poll()}')
        expect(hb(s)[2] == 'TRIP', f'TRIP in the heartbeat for PID 1 (E-19): {hb(s)}')
        expect('final-pet margin=30' in xlog_at(s, t4 + 2000), 'final pet with M_final at TRIP')
        expect(s.pid1_signals() == [] and 'a1 sent' not in s.xlog() and 'actuators' not in s.xlog(),
               'stage: no PID 1 signal, no actuators')
        s.run(3)
        expect(hb(s)[2] == 'TRIP', 'TRIP is sticky')
    finally:
        if st.poll() is None:
            st.kill()
    return s


@sc
def x_stage_trip_before_stuck_write(B):
    """review M1: TRIP reaches PID 1's heartbeat before the tick's sysfs writes, even if one hangs"""
    s = X(B, flags=['--stage', '--softdog'])
    s.run(3)
    t4 = soc_t4(s)
    s.step()
    open(os.path.join(s.root, 'sim', 'hang-rpm'), 'w').close()  # the fan write of the TRIP tick never returns
    o = s.step(timeout=2.0)
    expect(o is None, 'the TRIP tick never completes (stuck fan write)')
    time.sleep(0.3)
    expect(hb(s)[2] == 'TRIP', f'TRIP is in the heartbeat anyway: {hb(s)}')
    expect('final-pet margin=30' in xlog_at(s, t4 + 2000), 'and the final pet was given before the write')
    s.proc.kill()
    return None


@sc
def x_stage_step_file_refused(B):
    s = X(B, flags=['--stage', '--step-pgid-file', '/run/fs-step.pgid'])
    s._w('run/fs-step.pgid', '1\n')
    s.run(2)
    soc_t4(s)
    s.run(3)
    expect('step-signal 15: refused pgid' in s.xlog(), 'pgid 1 (PID 1) is never signalled')
    return s


# ---------------------------------------------------------------- hangs, consumers, actuator faults
@sc
def x_hung_read_stops_petting(B):
    s = X(B, flags=['--softdog'])
    s.run(5)
    n = wd_lines(s).count('keepalive')
    s.val['cpu-0-0-0'] = 'HANG'
    o = s.step(timeout=1.5)
    expect(o is None, 'the cycle never completes')
    time.sleep(1.0)
    expect(wd_lines(s).count('keepalive') == n, 'no pet after a stuck read: the softdog fires (E-6)')
    s.proc.kill()
    return None


@sc
def x_stalled_consumers(B):
    """J-171 (f) / R49: stalled consumers never delay the deadline"""
    s = X(B, flags=['--softdog'])
    s.run(2)
    # (1) a reader stopped while it holds the notice record open
    rd = subprocess.Popen([sys.executable, '-c',
                           'import sys,time\nf=open(sys.argv[1],"rb")\nwhile True:\n f.seek(0); f.read(256); time.sleep(0.01)',
                           os.path.join(s.root, 'run/fs-thermald/notice')])
    # (2) a reader that blocks for ever on the heartbeat path after it is swapped for a FIFO
    time.sleep(0.2)
    rd.send_signal(signal.SIGSTOP)
    hbp = os.path.join(s.root, 'run/fs-thermald/hb')
    os.rename(hbp, hbp + '.old')
    os.mkfifo(hbp)
    blk = subprocess.Popen(['sh', '-c', f'cat < "{hbp}" > /dev/null'])
    # (3) a CPU hog at the same nice level
    hog = subprocess.Popen([sys.executable, '-c', 'while True: pass'])
    try:
        lat = []
        t4 = None
        for k in range(62):
            if k == 1:
                s.val['cpu-1-0-0'] = 115000
            t0 = time.time()
            o = s.step(timeout=2.0)
            lat.append(time.time() - t0)
            expect(o is not None, 'a tick never stalls on a consumer')
            if k == 1:
                t4 = int(o['t'])
                s.val['cpu-1-0-0'] = 100000
        expect(max(lat) < 1.0, f'tick latency with stalled consumers: max {max(lat):.3f} s')
        expect('a2 sent' in xlog_at(s, t4 + 55000) and 'a1 sent' in xlog_at(s, t4 + 45000),
               'A1/A2 on their exact ticks despite the consumers')
    finally:
        for p in (rd, blk, hog):
            try:
                p.send_signal(signal.SIGCONT)
                p.kill()
                p.wait(timeout=2)
            except Exception:
                pass
    return s


@sc
def x_actuator_a2_died_early(B):
    s = X(B, flags=['--softdog'], a2_dead=True)
    s.run(2)
    a2 = int(s.xlog().split('a2=')[1].split()[0])
    os.kill(a2, signal.SIGKILL)
    time.sleep(0.1)
    s.run(2)
    expect(s.ins[-1]['ready_pub'] == 0 and s.ins[-1]['a2_exited'] == 0 and hb(s)[2] == 'HOLD',
           'A2 death withdraws READY (HOLD) and is no a2_exited')
    t4 = soc_t4(s)
    s.run(56)
    expect(s.ins[-1]['a2_exited'] == 0, 'an early death is never reported as a returned power-off')
    l = xlog_at(s, t4 + 55000)
    expect('final-pet margin=30' in l and any(x.startswith('a2 FAILED') for x in l),
           f'final pet still given; the softdog covers the missing A2: {l}')
    return s


@sc
def x_actuator_wrong_byte(B):
    s = X(B, a2_dead=True)
    s.run(2)
    a2 = int(s.xlog().split('a2=')[1].split()[0])
    # open A2's command pipe through /proc and send a wrong byte
    fds = os.listdir(f'/proc/{a2}/fd')
    sent = False
    for f in fds:
        tgt = os.readlink(f'/proc/{a2}/fd/{f}')
        if tgt.startswith('pipe:'):
            try:
                w = os.open(f'/proc/{a2}/fd/{f}', os.O_WRONLY | os.O_NONBLOCK)
                os.write(w, b'\x00')
                os.close(w)
                sent = True
                break
            except OSError:
                continue
    expect(sent, 'test could reach the A2 pipe')
    time.sleep(0.2)
    s.run(2)
    expect('a2 poweroff-called' not in s.xlog(), 'A2 exits without acting on another byte (E-8)')
    expect(s.ins[-1]['ready_pub'] == 0, 'and READY is withdrawn')
    return s


@sc
def x_actuators_exit_on_eof(B):
    s = X(B)
    s.run(2)
    a1 = int(s.xlog().split('a1=')[1].split()[0])
    a2 = int(s.xlog().split('a2=')[1].split()[0])
    s.close()
    time.sleep(0.3)

    def alive(p):
        try:
            st = open(f'/proc/{p}/stat').read().split(')')[1].split()[0]
            return st != 'Z'
        except FileNotFoundError:
            return False
    expect(not alive(a1) and not alive(a2), 'supervisor gone: actuators exit (E-8)')
    expect('poweroff-called' not in s.xlog() and 'sync-done' not in s.xlog(), 'without acting')
    return s


@sc
def x_actuators_drop_watchdog(B):
    s = X(B, flags=['--softdog'])
    s.run(2)
    for key in ('a1=', 'a2='):
        p = int(s.xlog().split(key)[1].split()[0])
        tg = [os.readlink(f'/proc/{p}/fd/{f}') for f in os.listdir(f'/proc/{p}/fd')]
        expect(not any(t.endswith('/dev/watchdog') for t in tg), f'{key[:2]} holds no softdog descriptor (E-7): {tg}')
        expect(len(tg) <= 3, f'{key[:2]} holds only its pipes (and the test log): {tg}')
    return s


# ---------------------------------------------------------------- gate
def run_gate(s, extra=()):
    cmd = [A.bin, '--device', s.device, '--exec-gate', '--root', s.root, '--test-pid1', str(s.pid1proc.pid),
           '--pstore', '/sys/fs/pstore'] + list(extra) + s.flags
    return subprocess.run(cmd, input=f'tick {s.t}\n', capture_output=True, text=True)


@sc
def x_gate_refuse_softdog(B):
    s = X(B)
    s.val['cpu-1-0-0'] = 94000  # >= SEVERE 95 - hyst 2
    s.step()
    s.close()
    r = run_gate(s, ['--softdog'])
    expect(r.returncode == 1 and 'gate=refuse' in r.stdout, f'gate refuses: {r.stdout}')
    expect(wd_lines(s) == ['settimeout 30', 'settimeout 30', 'keepalive'],
           f'refusal: softdog opened and given the final pet, left for PID 1 (E-28): {wd_lines(s)}')
    recs = pmsg_records(s)
    expect([x['ev'] for x in recs] == ['gate'] and 'hot:cpu-1-0-0' in recs[0]['why'], f'gate record: {recs}')
    return None


@sc
def x_gate_pass_no_softdog(B):
    s = X(B)
    s.step()
    s.close()
    r = run_gate(s, ['--softdog'])
    expect(r.returncode == 0 and wd_lines(s) == [] and pmsg_records(s) == [],
           'pass: no softdog (a single-open device left running would fire), no record')
    return None


def prev_boot(ev='t4', reason='fan-failure', value='52000', bad_crc=False):
    r = {'ev': ev, 't': 123456, 'reason': reason, 'sensor': 'cpu-1-0-0', 'value': value, 'hot': 'cpu-1-0-0:52000',
         'why': 't4:fan', 'cd': 55}
    line = fst_ref.encode(r)
    if bad_crc:
        line = line[:-2] + ('0' if line[-2] != '0' else '1') + '\n'
    return 'some other pmsg text\n' + line


@sc
def x_gate_pstore_marker(B):
    s = X(B, pstore=prev_boot())
    s.val['cpu-1-0-0'] = 90000  # below SEVERE - hyst, above LIGHT 89
    s.step()
    s.close()
    r = run_gate(s)
    expect(r.returncode == 1 and 'hot:cpu-1-0-0' in r.stdout and 'last=fan-failure:52000' in r.stdout,
           f'marker of the previous boot: below LIGHT required; last shutdown shown (E-22): {r.stdout}')
    return None


@sc
def x_gate_pstore_bad_crc(B):
    s = X(B, pstore=prev_boot(bad_crc=True))
    s.val['cpu-1-0-0'] = 90000
    s.step()
    s.close()
    r = run_gate(s)
    expect(r.returncode == 0 and 'last=' not in r.stdout, f'a corrupt record is no marker (negative control): {r.stdout}')
    return None


@sc
def x_notice_last_shutdown(B):
    s = X(B, pstore=prev_boot(ev='a2', reason='battery-overheating', value='65100'),
          extra_args=['--pstore', '/sys/fs/pstore'])
    s.run(2)
    expect(notice(s)['last'] == 'battery-overheating:65100', f'"Last shutdown" for the consumers (R48): {notice(s)}')
    return s


# ---------------------------------------------------------------- records
@sc
def x_fst_differential(B):
    """C scanner (fs-thermald --fst-scan) = Python reference on generated and mutated dumps"""
    rnd = random.Random(20261015)
    d = os.path.join(B().dir, 'fst')
    os.makedirs(d, exist_ok=True)
    good = [prev_boot(), prev_boot(ev='start', reason='-', value='-'),
            fst_ref.encode({'ev': 'gate', 't': 0, 'reason': '-', 'sensor': '-', 'value': '-', 'hot': '-',
                            'why': 'hot:soc-usr,p6', 'cd': -1})]
    cases = []
    for g in good:
        cases.append(g.encode())
        for _ in range(60):
            b = bytearray(g.encode())
            k = rnd.randrange(3)
            if k == 0:
                b[rnd.randrange(len(b))] = rnd.randrange(256)
            elif k == 1:
                del b[rnd.randrange(len(b))]
            else:
                b.insert(rnd.randrange(len(b)), rnd.choice(b' =\r\0x0'))
            cases.append(bytes(b))
    cases += [b'', b'\0' * 50, b'FST1 ev=t4\n', (prev_boot() * 3).encode(), prev_boot().encode().replace(b'\n', b'\r\n')]
    bad = 0
    for i, c in enumerate(cases):
        p = os.path.join(d, f'{i}.bin')
        open(p, 'wb').write(c)
        cl = subprocess.run([A.bin, '--device', 'eureka', '--fst-scan', p], capture_output=True, text=True).stdout.strip()
        py = fst_ref.fmt_scan(c)
        if cl != py:
            bad += 1
            if bad < 4:
                print(f'    DIFF case {i}: C {cl} | PY {py}')
    expect(bad == 0, f'FST1 scanner C = Python on {len(cases)} dumps ({bad} differ)')
    return None


@sc
def x_signal_number(B):
    expect(signal.SIGRTMIN + 4 == 38, 'host glibc: SIGRTMIN+4 = 38 (systemd poweroff.target; musl would be 39)')
    return None


# ---------------------------------------------------------------- log-only build (T1)
@sc
def x_logonly_writes_nothing(B):
    if not A.logonly_bin:
        raise Fail('no --logonly-bin given')
    s = Sim(A.logonly_bin, exec_opts={'fakepid1': A.fakepid1, 'markers': (), 'dload': '0', 'pstore': None, 'logonly': True},
            flags=['--softdog'])
    B.sims.append(s)
    before = {p: open(p).read() for p in s.polpath}
    s.run(2)
    soc_t4(s)
    s.run(57)
    expect(all(open(p).read() == before[p] for p in s.polpath), 'no cpufreq write')
    expect(open(os.path.join(s.root, 'sys/devices/system/cpu/cpufreq/policy0/scaling_governor')).read() == 'performance\n',
           'no governor write')
    expect(open(s.rpmpath).read() != '5500\n' and wd_lines(s) == [] and s.pid1_signals() == [],
           'no fan write, no softdog, no signal')
    expect('actuators' not in s.xlog() and 'log-only: not executed: a2' in s.xlog(), 'no actuator; actions logged only')
    expect(s.file('dev/pmsg0') == b'', 'no pmsg write')
    expect(hb(s)[2] == 'HOLD' and all(i['ready_pub'] == 0 for i in s.ins),
           'log-only never publishes READY (review M4): heartbeat HOLD')
    return s


def main():
    global A
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--fakepid1', required=True)
    ap.add_argument('--stepgroup', required=True)
    ap.add_argument('--logonly-bin')
    ap.add_argument('--only')
    ap.add_argument('--out')
    A = ap.parse_args()
    res, npass, ndiff = [], 0, 0
    for fn in SC:
        if A.only and A.only not in fn.__name__:
            continue
        sims = []

        def B(**kw):
            s = Sim(A.bin, **kw)
            sims.append(s)
            return s
        B.sims = sims
        status, detail, dstat = 'PASS', '', 'skip'
        try:
            s = fn(B)
            for x in sims:
                if x.proc.poll() is None:
                    x.close()
            if s is not None:
                d = s.differential()
                dstat = 'SAME' if not d else 'DIFF'
                if d:
                    ndiff += 1
                    detail = '\n'.join(d[:3])
        except Fail as e:
            status, detail = 'FAIL', str(e)
        except Exception:
            status, detail = 'ERROR', traceback.format_exc()[-800:]
        finally:
            for x in sims:
                if x.proc.poll() is None:
                    x.proc.kill()
                    x.proc.wait()
                if getattr(x, 'pid1proc', None) and x.pid1proc.poll() is None:
                    x.pid1proc.kill()
                    x.pid1proc.wait()
        if status == 'PASS':
            npass += 1
        line = f'{status:5s} {dstat:4s} {fn.__name__}'
        print(line + (('\n    ' + detail.replace('\n', '\n    ')) if detail else ''), flush=True)
        res.append(line)
    tot = len(res)
    ndr = sum(1 for r in res if ' SAME ' in r or ' DIFF ' in r)
    summ = f'exec scenarios: {npass}/{tot} pass; differential vs core_ref.py: {ndr - ndiff}/{ndr} identical'
    print(summ)
    if A.out:
        with open(A.out, 'w', newline='\n') as f:
            f.write('# fs-thermald executor scenarios (tools/sim/exec_scenarios.py): status, differential, name\n')
            f.write('\n'.join(res) + '\n' + summ + '\n')
    sys.exit(0 if npass == tot and ndiff == 0 else 1)


if __name__ == '__main__':
    main()
