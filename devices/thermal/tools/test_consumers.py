#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Notice consumers (EXEC-SPEC.md §8; PLAN R46/R47): fs-noticed (LED) and
fs-warnscreen (static KMS frame from the stage-3d display path).

- fs-noticed: the pattern function per severity and staleness; a live run
  against a fake LED directory following FSN1 records written like the
  supervisor's (pwrite in place), including a stale record.
- fs-warnscreen: an offline frame fixture per notice reason (fs-pattern's own
  "render" path with the warning picture): size, levels (only C_BG 0x80 and
  white), text present inside the recovery margins of each eye, distinct and
  reproducible frames, and the eye swap/roll applied (the two buffer halves
  differ, as each eye is rolled the other way); the watch loop tries exactly
  the stage-3d sequence (reset once, then show-off-quad) per display, at most
  three displays, and gives up harmlessly on a non-DRM device path.

usage: test_consumers.py --build DIR [--out FILE]
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'ref'))
import fst_ref  # noqa: E402

res = []


def ok(name, cond, detail=''):
    res.append(('PASS ' if cond else 'FAIL ') + name + ('' if cond else f'  [{detail}]'))


def fsn(seq, n, last='-', ready=1, tier=0, t=1000):
    body = 'FSN1 seq=%d t=%d ready=%d tier=%d n=%s last=%s' % (seq, t, ready, tier, n, last)
    s = '%s crc=%08x' % (body, zlib.crc32(body.encode()) & 0xffffffff)
    return (s + ' ' * (255 - len(s)) + '\n').encode()


def noticed(b):
    x = os.path.join(b, 'fs-noticed-test')

    def ev(n, stale, t):
        return subprocess.run([x, 'eval', n, str(stale), str(t)], capture_output=True, text=True).stdout.split()
    ok('noticed: normal leaves the LEDs alone', ev('-', 0, 0) == ['-1', '-1', '-1'])
    ok('noticed: warn = amber 1 Hz', ev('warn:fan-failure:90', 0, 600) == ['255', '160', '0']
       and ev('warn:fan-failure:90', 0, 100) == ['0', '0', '0'])
    ok('noticed: shutdown = red 4 Hz', ev('shutdown:battery-overheating:55', 0, 130) == ['255', '0', '0']
       and ev('shutdown:battery-overheating:55', 0, 260) == ['0', '0', '0'])
    ok('noticed: shutdown stays red even when the record is stale', ev('shutdown:fan-failure:0', 1, 130) == ['255', '0', '0'])
    ok('noticed: stale record = slow white', ev('-', 1, 1500) == ['64', '64', '64'] and ev('warn:x', 1, 500) == ['0', '0', '0'])
    d = tempfile.mkdtemp(prefix='fsnl-')
    for c in ('red', 'green', 'blue'):
        os.makedirs(os.path.join(d, 'leds', c))
        open(os.path.join(d, 'leds', c, 'brightness'), 'w').write('0\n')
    rec = os.path.join(d, 'notice')
    open(rec, 'wb').write(fsn(1, '-'))
    p = subprocess.Popen([x, 'watch', rec, os.path.join(d, 'leds')])
    try:
        fd = os.open(rec, os.O_WRONLY)
        seen = set()
        for k in range(16):  # 4 s of a shutdown notice, seq advancing as the supervisor does
            os.pwrite(fd, fsn(2 + k, 'shutdown:fan-failure:%d' % (55 - k)), 0)
            for _ in range(5):  # sample faster than the 4 Hz blink (no aliasing)
                time.sleep(0.05)
                seen.add((open(os.path.join(d, 'leds', 'red', 'brightness')).read().split() or [''])[0])  # a regular file keeps the longer old tail; sysfs replaces
        ok('noticed: live run blinks red on a shutdown notice', seen >= {'0', '255'}, repr(seen))
        os.pwrite(fd, fsn(100, '-'), 0)  # back to normal, then the record stops being valid
        time.sleep(0.6)
        os.pwrite(fd, b'garbage' + b' ' * 249, 0)
        time.sleep(5.5)  # no valid record for > 5 s -> stale
        gs = set()
        for _ in range(50):  # 2.5 s: more than one period of the 1 s white blink
            gs.add((open(os.path.join(d, 'leds', 'green', 'brightness')).read().split() or [''])[0])
            time.sleep(0.05)
        ok('noticed: an invalid/stale record -> the white "not reporting" blink', gs == {'0', '64'}, repr(gs))
        os.close(fd)
    finally:
        p.kill()
        p.wait()


def ppm(path):
    b = open(path, 'rb').read()
    parts = b.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


REASONS = ['battery-overheating', 'skin-temperature-high', 'soc-temperature-high', 'usb-connector-hot', 'pmic-hot',
           'fan-failure', 'battery-sensor-lost', 'sensor-fault', 'sensor-anomaly', 'battery-empty', 'cap-write-failed',
           'self-test-failed', 'battery-low', 'charging-too-warm', 'shutdown-requested']


def warnscreen(b):
    x = os.path.join(b, 'fs-warnscreen-test')
    d = tempfile.mkdtemp(prefix='fsws-')
    W, H = 1032, 552  # a quarter-size panel buffer (two eyes of 516 x 552); the full size is 4128 x 2208
    hashes = {}
    cases = [('shutdown:%s:55' % r, '-') for r in REASONS] + [('warn:fan-failure:90', '-'), ('warn:battery-low', '-'),
                                                              ('-', 'fan-failure:52000')]
    lines = []
    for n, last in cases:
        out = os.path.join(d, 'f.ppm')
        r = subprocess.run([x, 'render-notice', n, last, str(W), str(H), out], capture_output=True, text=True)
        if r.returncode != 0:
            ok(f'warnscreen: render {n} {last}', False, r.stdout[-200:] + r.stderr[-200:])
            continue
        w, h, px = ppm(out)
        levels = set(px[0::3])
        half = w // 2
        lit_l = sum(1 for yy in range(h) for xx in range(half) if px[(yy * w + xx) * 3] == 255)
        lit_r = sum(1 for yy in range(h) for xx in range(half, w) if px[(yy * w + xx) * 3] == 255)
        hl = hashlib.sha256(px).hexdigest()
        hashes[(n, last)] = hl
        r2 = subprocess.run([x, 'render-notice', n, last, str(W), str(H), out + '2'], capture_output=True, text=True)
        same = r2.returncode == 0 and open(out, 'rb').read() == open(out + '2', 'rb').read()
        good = w == W and h == H and levels <= {0x80, 0xff} and lit_l > 200 and lit_r > 200 and same
        # each eye is rolled the other way (left counter-clockwise, right clockwise): the halves differ
        lhalf = b''.join(px[(yy * w) * 3:(yy * w + half) * 3] for yy in range(h))
        rhalf = b''.join(px[(yy * w + half) * 3:(yy * w + w) * 3] for yy in range(h))
        good = good and lhalf != rhalf
        ok(f'warnscreen frame {n} last={last}: levels 0x80/0xff, text in both eyes, eyes rolled apart, reproducible',
           good, f'{w}x{h} levels={sorted(levels)} lit={lit_l}/{lit_r} same={same}')
        lines.append(f'  frame {n} last={last} sha256={hl}')
    ok('warnscreen: every reason gives a distinct frame', len(set(hashes.values())) == len(hashes))
    r = subprocess.run([x, 'render-notice', 'bogus', '-', str(W), str(H), os.path.join(d, 'z.ppm')], capture_output=True)
    ok('warnscreen: a malformed notice draws nothing (exit 2)', r.returncode == 2)
    # watch: on a non-DRM device path the reviewed sequence is attempted and refused at open
    rec = os.path.join(d, 'notice')
    open(rec, 'wb').write(fsn(1, 'warn:fan-failure:90', last='battery-overheating:65100'))
    logp = os.path.join(d, 'ws.log')
    with open(logp, 'w') as lf:
        p = subprocess.Popen([x, 'watch', 'abcdef01', rec, os.path.join(d, 'not-a-drm-node')], stdout=lf,
                             stderr=subprocess.STDOUT)
        time.sleep(2.0)
        fd = os.open(rec, os.O_WRONLY)
        os.pwrite(fd, fsn(2, 'shutdown:fan-failure:55'), 0)
        os.close(fd)
        try:
            p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    log = open(logp).read()
    starts = [l for l in log.split('\n') if ' step=start ' in l]
    modes = [l.split(' mode=')[1].split()[0] for l in starts if ' mode=' in l]
    ok('warnscreen watch: reset once, then one show-off-quad per display (warn, then shutdown), then exit',
       modes == ['reset', 'show-off-quad', 'show-off-quad'] and p.returncode == 0, repr(modes))
    opens = [l for l in log.split('\n') if ' step=open ' in l]
    ok('warnscreen watch: every attempt refused at open on a non-DRM path (no ioctl)', len(opens) == 3
       and all(' rc=-' in l for l in opens), repr(opens[:3]))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', required=True)
    ap.add_argument('--out')
    a = ap.parse_args()
    noticed(a.build)
    lines = warnscreen(a.build)
    bad = sum(not x.startswith('PASS') for x in res)
    summ = f'notice consumers: {len(res) - bad}/{len(res)} pass'
    print('\n'.join(res))
    print('\n'.join(lines or []))
    print(summ)
    sys.exit(0 if not bad else 1)


if __name__ == '__main__':
    main()
