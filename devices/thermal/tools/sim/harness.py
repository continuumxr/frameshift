#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-thermald simulation harness (CORE-SPEC.md; design §7.1 "fixture sysfs trees").

Builds a fake sysfs tree per scenario, drives the C supervisor tick by tick
(`fs-thermald --sim`, fake CLOCK_BOOTTIME from stdin), records every input
it wrote as a CORE-SPEC §12 tick file, checks the scenario's own expected
results on the C output, then runs the independent Python reference
(tools/ref/core_ref.py) on the same configuration and ticks and requires
identical output lines (differential test).

usage: harness.py --bin FS_THERMALD [--only NAME] [--out RESULTS] [--keep DIR]
"""
import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '..', 'ref', 'core_ref.py')


def parse(line):
    d = {}
    for part in line.split(' '):
        k, _, v = part.partition('=')
        d[k] = v
    d['F'] = set() if d['f'] == '-' else set(d['f'].split(','))
    d['E'] = set() if d['e'] == '-' else set(d['e'].split(','))
    d['A'] = set() if d['a'] == '-' else set(d['a'].split(','))
    d['tier'] = int(d['tier'])
    d['ready'] = int(d['ready'])
    return d


class Fail(Exception):
    pass


class Sim:
    def __init__(self, binary, device='eureka', flags=(), fan='v27', fan_absent=False, caps_ro=False,
                 missing=(), gpu=True, workdir=None, record=None, extra_args=(), rps='100', missing_fanzones=(),
                 trip_override=None, exec_opts=None, adsp_name='3000000.remoteproc-adsp'):
        self.adsp_name = adsp_name
        self.rps, self.missing_fanzones, self.trip_override = rps, set(missing_fanzones), trip_override or {}
        self.bin, self.device, self.flags = binary, device, list(flags)
        self.dir = tempfile.mkdtemp(prefix='fsth-sim-', dir=workdir)
        self.root = os.path.join(self.dir, 'root')
        base = json.loads(self._run(['--dump-config'] + (['--record', record] if record else [])))
        self.base = base
        self.sensors = [s['name'] for s in base['sensors'] if s['kind'] in ('zone', 'aux', 'iio')]
        self.iio = {s['name'] for s in base['sensors'] if s['kind'] == 'iio'}  # K-50: PMIC dies via IIO
        self.missing = set(missing)
        self._build_tree(base, fan, fan_absent, caps_ro, gpu)
        args = ['--root', self.root] + (['--record', record] if record else []) + list(extra_args)
        self.config_text = self._run(args + ['--dump-config'])
        self.config = json.loads(self.config_text)
        self.val = {n: 40000 for n in self.sensors}
        for s in base['sensors']:
            if s['kind'] == 'aux':
                self.val[s['name']] = 35000
        self.psy = {'temp': 250, 'cap': 80, 'status': 'Discharging', 'curr': -300000}
        self.usb = 0
        self.adsp = 'running'
        self.fanv = {'pwm': 120, 'cur': 0, 'max': 4}
        self.raw = {}  # sensor name -> raw sysfs text (S-1 parsing tests)
        self.rpm_override = None
        self.rpm_exact = False
        self.fan_ro = False
        self.fan_absent = fan_absent
        self.caps_ro = caps_ro
        self.pid1 = 'systemd'
        self.flags_files = set()
        self.t = 0
        self.ticks, self.lines, self.outs = [], [], []
        self._pend_fan_err = False
        self._pend_cap_fail = False
        self.last_fan = 0
        self.fan_pos = 0  # the simulated fan's true speed: ramps at rpm_per_sec, jumps below silent_rpm
        self.ramp_rps = None  # None: the config's rpm_per_sec
        self.rpm_noise = 0.0  # relative tach noise on a following fan
        self.fan_model = None  # a fanmodel.Fan: replaces the following fan when set
        self.exec_opts = exec_opts
        self.ins = []  # exec-sim: the executor's per-tick inputs (EXEC-SPEC §6)
        mode = ['--sim']
        if exec_opts is not None:
            mode = self._exec_setup(exec_opts)
        self.proc = subprocess.Popen([self.bin, '--device', device] + mode + args + self.flags,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True)

    # ---------------- exec-sim (part 2, EXEC-SPEC §6) ----------------
    def _exec_setup(self, o):
        """fake device nodes for the executor and the fake PID 1; returns the mode args"""
        self._w('dev/watchdog', '')
        self._w('dev/pmsg0', '')
        self._w('proc/sysrq-trigger', '')
        if o.get('dload', '0') is not None:
            self._w('sys/module/qcom_dload_mode/parameters/download_mode', o.get('dload', '0') + '\n')
        if o.get('pstore') is not None:
            self._w('sys/fs/pstore/pmsg-ramoops-0', o['pstore'])
        for m in o.get('markers', ()):
            open(os.path.join(self.root, 'sim', m), 'w').close()
        self.pid1log = os.path.join(self.dir, 'pid1.log')
        fake = o['fakepid1']
        self.pid1proc = subprocess.Popen([fake, self.pid1log], stdin=subprocess.DEVNULL)
        import time
        for _ in range(200):
            if os.path.exists(self.pid1log) and open(self.pid1log).read().startswith('ready'):
                break
            time.sleep(0.01)
        return ['--exec-sim', '--test-pid1', str(self.pid1proc.pid)]

    def xlog(self):
        p = os.path.join(self.root, 'sim', 'exec.log')
        return open(p).read() if os.path.exists(p) else ''

    def file(self, rel):
        p = os.path.join(self.root, rel.lstrip('/'))
        return open(p, 'rb').read() if os.path.exists(p) else None

    def pid1_signals(self):
        return [int(l.split()[1]) for l in open(self.pid1log).read().split('\n') if l.startswith('sig ')]

    def _wait_log(self, needle, timeout=3.0):
        import time
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.xlog():
                return True
            time.sleep(0.01)
        return False

    def _run(self, extra):
        r = subprocess.run([self.bin, '--device', self.device] + self.flags + extra, capture_output=True, text=True)
        if r.returncode:
            raise Fail('dump-config failed: ' + r.stderr)
        return r.stdout

    # ---------------- tree ----------------
    def _w(self, rel, text):
        p = os.path.join(self.root, rel.lstrip('/'))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w') as f:
            f.write(text)
        return p

    def _build_tree(self, base, fan, fan_absent, caps_ro, gpu):
        n = 0
        self.zpath = {}
        for name in self.sensors:
            if name in self.missing:
                continue
            if name in self.iio:  # E-33: in_temp_<label>_input of one iio:deviceN (the vadc)
                self.zpath[name] = self._w(f'sys/bus/iio/devices/iio:device0/in_temp_{name}_input', '40000\n')
                continue
            d = f'sys/class/thermal/thermal_zone{n}'
            self._w(d + '/type', name + '\n')
            self.zpath[name] = self._w(d + '/temp', '40000\n')
            n += 1
        if base['fan']:
            for r in base['fan']['rules']:
                if r['zone'] in self.missing_fanzones:
                    continue
                d = f'sys/class/thermal/thermal_zone{n}'
                self._w(d + '/type', r['zone'] + '\n')
                self._w(d + '/temp', '40000\n')
                for j, tr in enumerate(r['trips']):
                    tr = dict(tr, t=self.trip_override.get((r['zone'], j), tr['t']))
                    self._w(d + f'/trip_point_{j}_temp', f"{tr['t']}\n")
                    self._w(d + f'/trip_point_{j}_hyst', f"{tr['h']}\n")
                n += 1
        b = 'sys/class/power_supply/battery/'
        self.ppath = {k: self._w(b + f, '0\n') for k, f in
                      [('temp', 'temp'), ('volt', 'voltage_now'), ('curr', 'current_now'), ('cap', 'capacity'),
                       ('status', 'status')]}
        self.usbpath = self._w('sys/class/power_supply/usb/online', '0\n')
        if self.device == 'eureka':
            # the v2.7 name (rproc name = platform device name; FS-A-006 raw probe)
            self._w('sys/class/remoteproc/remoteproc0/name', getattr(self, 'adsp_name', '3000000.remoteproc-adsp') + '\n')
            self.adsppath = self._w('sys/class/remoteproc/remoteproc0/state', 'running\n')
        if not fan_absent:
            self._w('sys/class/hwmon/hwmon0/name', 'pwmfan\n')
            self.rpmpath = self._w('sys/class/hwmon/hwmon0/rpm', '0\n')
            self.pwmpath = self._w('sys/class/hwmon/hwmon0/pwm', '120\n')
            if fan == 'v27':
                self._w('sys/class/hwmon/hwmon0/rpm_per_sec', f'{self.rps}\n')
                self._w('sys/class/hwmon/hwmon0/silent_rpm', '4000\n')
        self._w('sys/class/thermal/cooling_device0/type', 'pwm-tach-fan0\n')
        self.curpath = self._w('sys/class/thermal/cooling_device0/cur_state', '1\n')
        self.maxpath = self._w('sys/class/thermal/cooling_device0/max_state', '4\n')
        self.polpath = []
        for pnum in base.get('policies', [0, 2]):
            d = f'sys/devices/system/cpu/cpufreq/policy{pnum}/'
            p = self._w(d + 'scaling_max_freq', '2054400\n')
            self._w(d + 'scaling_governor', 'performance\n')
            self._w(d + 'cpuinfo_min_freq', '307200\n')
            self.polpath.append(p)
        os.makedirs(os.path.join(self.root, 'sim'), exist_ok=True)
        if caps_ro:
            open(os.path.join(self.root, 'sim', 'erofs-policy0'), 'w').close()
        if gpu:
            self.gpupath = self._w('sys/class/kgsl/kgsl-3d0/max_pwrlevel', '0\n')
        self._w('run/fs-thermald/state', '')
        self.commpath = self._w('proc/1/comm', 'systemd\n')
        os.makedirs(os.path.join(self.root, 'sim'), exist_ok=True)

    # ---------------- ticks ----------------
    def _put(self, path, text):
        mode = os.stat(path).st_mode
        ro = not (mode & stat.S_IWUSR)
        if ro:
            os.chmod(path, 0o644)
        with open(path, 'w') as f:
            f.write(text)
        if ro:
            os.chmod(path, 0o444)

    @staticmethod
    def _rd(path):
        """CORE-SPEC S-1: the value the C I/O layer must see in this file"""
        import re
        t = open(path).read()
        while t and t[-1] in '\n ':
            t = t[:-1]
        if not re.fullmatch(r' *[+-]?[0-9]+', t):
            return 'ERR'
        v = int(t)
        return v if -2 ** 31 < v < 2 ** 31 else 'ERR'

    @staticmethod
    def _rds(path):
        t = open(path).read().rstrip('\n ')
        return 'ERR' if t == '!EIO' else t

    @staticmethod
    def _txt(v):
        if v == 'ERR':
            return '!EIO\n'
        if v == 'HANG':
            return '!HANG\n'
        return f'{v}\n'

    def step(self, dt=1000, timeout=5):
        if self.ticks or self.t:
            self.t += dt
        t = self.t
        tick = {'t': t, 's': {}}
        for name in self.sensors:
            if name in self.missing:
                tick['s'][name] = 'ABSENT'
                continue
            v = self.val[name]
            self._put(self.zpath[name], self.raw[name] if name in self.raw else self._txt(v))
            tick['s'][name] = 'ERR' if v == 'HANG' else self._rd(self.zpath[name])
        volt = self.psy.get('volt', 4000000 + (t // 1000 % 7) * 1000)
        psy = {'temp': self.psy['temp'], 'volt': volt, 'curr': self.psy['curr'], 'cap': self.psy['cap'],
               'status': self.psy['status']}
        for k, v in psy.items():
            self._put(self.ppath[k], self._txt(v))
        tick['psy'] = {k: (self._rd(self.ppath[k]) if k != 'status' else self._rds(self.ppath[k]))
                       for k in psy}
        self._put(self.usbpath, self._txt(self.usb))
        tick['usb_online'] = self.usb
        if self.device == 'eureka':
            self._put(self.adsppath, self._txt(self.adsp))
        # E-32: the I/O layer finds the ADSP by name ("adsp" or "<addr>.remoteproc-adsp")
        an = self.adsp_name
        tick['adsp'] = self.adsp if (an == 'adsp' or (an.endswith('.remoteproc-adsp') and len(an) > 16)) else 'ABSENT'
        if self.fan_absent:
            tick['fan'] = 'ABSENT'
        else:
            jit = 7 if (t // 1000) % 2 else -7
            if self.rpm_override == 'ERR':
                rpm = 'ERR'
            elif self.rpm_override is None and self.fan_model is not None:
                if self.ticks:
                    self.fan_model.advance(self.last_fan, dt / 1000)
                rpm = self.fan_model.read()
            elif self.rpm_override is not None:
                rpm = self.rpm_override + (0 if self.rpm_exact or self.rpm_override == 0 else jit)
            else:
                rps = self.config['fan']['rpm_per_sec'] if self.ramp_rps is None and self.config['fan'] else (self.ramp_rps or 0)
                silent = self.config['fan']['silent_rpm'] if self.config['fan'] else 0
                tgt = self.last_fan
                if rps <= 0 or (self.fan_pos <= silent and tgt <= silent):
                    self.fan_pos = tgt
                elif self.fan_pos < tgt:
                    self.fan_pos = min(tgt, self.fan_pos + rps)
                else:
                    self.fan_pos = max(tgt, self.fan_pos - rps)
                rpm = self.fan_pos + jit if self.fan_pos else 0
                if self.rpm_noise and rpm:
                    rpm = int(self.fan_pos * (1 + self.rpm_noise))
            self._put(self.rpmpath, self._txt(rpm))
            m = os.path.join(self.root, 'sim', 'erofs-rpm')
            if self.fan_ro and not os.path.exists(m):
                open(m, 'w').close()
            self._put(self.pwmpath, self._txt(self.fanv['pwm']))
            self._put(self.curpath, self._txt(self.fanv['cur']))
            self._put(self.maxpath, self._txt(self.fanv['max']))
            tick['fan'] = {'rpm': self._rd(self.rpmpath), 'pwm': self._rd(self.pwmpath), 'cur': self._rd(self.curpath),
                           'max': self._rd(self.maxpath)}
        m = os.path.join(self.root, 'sim', 'erofs-policy0')
        if self.caps_ro and not os.path.exists(m):
            open(m, 'w').close()
        tick['fan_wr_err'] = self._pend_fan_err
        tick['cap_fail'] = self._pend_cap_fail
        tick['caps_ok_at_start'] = not self.caps_ro
        self._put(self.commpath, self.pid1 + '\n')
        tick['pid1_comm'] = self.pid1
        for f in ('shutdown_byte', 'a1_done', 'a2_exited', 'pstore_marker'):
            p = os.path.join(self.root, 'sim', f)
            on = f in self.flags_files
            if on and not os.path.exists(p):
                open(p, 'w').close()
            if not on and os.path.exists(p):
                os.unlink(p)
            if f != 'pstore_marker':
                tick[f] = on
            elif on:
                tick[f] = True
        self.ticks.append(tick)
        self.proc.stdin.write(f'tick {t}\n')
        self.proc.stdin.flush()
        if self.exec_opts is not None:
            iline = self._readline(timeout)
            if iline is None:
                return None
            if not iline.startswith('in '):
                raise Fail('exec-sim: expected an input line, got: ' + iline)
            iv = {k: int(v) for k, v in (x.split('=') for x in iline.split()[1:])}
            self.ins.append(iv)
            tick['a1_done'] = bool(iv['a1_done'])
            tick['a2_exited'] = bool(iv['a2_exited'])
            tick['shutdown_byte'] = bool(iv['shutdown_byte'])
            if iv['pid1_shutdown'] != (self.pid1 == 'systemd-shutdow'):
                raise Fail('exec-sim: pid1_comm read differs from the file')
        line = self._readline(timeout)
        if line is None:
            return None
        self.lines.append(line)
        o = parse(line)
        self.outs.append(o)
        if o['fan'] != '-':
            self.last_fan = int(o['fan'])
        # what the C apply did this tick, for the next tick's inputs
        self._pend_fan_err = (not self.fan_absent) and self.fan_ro and o['fan'] != '-'
        self._pend_cap_fail = self.caps_ro and self.config['caps'] is not None
        if self.exec_opts is not None and not self.exec_opts.get('logonly'):
            # deterministic actuators: the next tick sees what they did (EXEC-SPEC §6)
            import time
            if 'a1' in o['A'] and 'a1-hang' not in self.exec_opts.get('markers', ()):
                if not self._wait_log('a1 sync-done'):
                    raise Fail('exec-sim: A1 never reported')
            if 'a2' in o['A'] and not self.exec_opts.get('a2_dead'):
                if not self._wait_log('a2 poweroff-called'):
                    raise Fail('exec-sim: A2 never acted')
                if 'a2-returns' in self.exec_opts.get('markers', ()):
                    time.sleep(0.15)
            if 'signal-pid1' in o['A']:
                for _ in range(300):
                    if 'sig ' in open(self.pid1log).read():
                        break
                    time.sleep(0.01)
        return o

    def _readline(self, timeout):
        """one line from the supervisor, with a timeout; own buffer on the raw fd
        (a TextIOWrapper may hold a second line that select() cannot see)"""
        import select
        import time
        if not hasattr(self, '_obuf'):
            self._obuf = b''
        end = time.time() + timeout
        fd = self.proc.stdout.fileno()
        while b'\n' not in self._obuf:
            left = end - time.time()
            if left <= 0:
                return None
            r, _, _ = select.select([fd], [], [], left)
            if not r:
                return None
            chunk = os.read(fd, 65536)
            if not chunk:
                return None
            self._obuf += chunk
        line, _, self._obuf = self._obuf.partition(b'\n')
        return line.decode()

    def run(self, n, **kw):
        out = None
        for _ in range(n):
            out = self.step(**kw)
        return out

    def close(self):
        try:
            self.proc.stdin.write('quit\n')
            self.proc.stdin.flush()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.stderr = self.proc.stderr.read()
        if self.exec_opts is not None:
            self.pid1proc.kill()
            self.pid1proc.wait()

    def first(self, pred):
        for o in self.outs:
            if pred(o):
                return o
        return None

    def gate(self):
        p = subprocess.run([self.bin, '--device', self.device, '--gate', '--root', self.root] + self.flags,
                           input=f'tick {self.t}\n', capture_output=True, text=True)
        return p.stdout.strip()

    def differential(self, gate=False):
        cfg = os.path.join(self.dir, 'config.json')
        tk = os.path.join(self.dir, 'ticks.jsonl')
        with open(cfg, 'w') as f:
            f.write(self.config_text)
        with open(tk, 'w') as f:
            for t in self.ticks:
                f.write(json.dumps(t) + '\n')
        r = subprocess.run([sys.executable, '-I', REF, '--config', cfg, '--ticks', tk] + (['--gate'] if gate else []),
                           capture_output=True, text=True)
        if r.returncode:
            return [f'reference failed: {r.stderr.strip()[-400:]}']
        ref = r.stdout.rstrip('\n').split('\n') if r.stdout.strip() else []
        diffs = []
        for i, (a, b) in enumerate(zip(self.lines, ref)):
            if a != b:
                diffs.append(f'tick {i}:\n   C: {a}\n  PY: {b}')
        if len(ref) != len(self.lines):
            diffs.append(f'line count C {len(self.lines)} PY {len(ref)}')
        return diffs


def expect(cond, msg):
    if not cond:
        raise Fail(msg)
