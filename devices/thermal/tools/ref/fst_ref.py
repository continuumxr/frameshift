#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent reference of the FST1 / FSN1 records (EXEC-SPEC.md §4),
written from the spec text: encode, parse (canonical form only, CRC-32 of
the body), scan a pstore pmsg dump. Used by tools/sim/exec_scenarios.py
(differential with the C scanner, fs-thermald --fst-scan) and to check the
records the executor writes.
"""
import re
import sys
import zlib

FST_MAX = 240
FSN_LEN = 256
KEYS = ('ev', 't', 'reason', 'sensor', 'value', 'hot', 'why', 'cd')
CAPS = {'ev': 16, 'reason': 32, 'sensor': 32, 'value': 16, 'hot': 48, 'why': 64}
MARKERS = {'t4', 't5', 'a2', 'a2-returned', 'gate'}
VAL = re.compile(r'[!-<>-~]+')  # printable, no space, no '='


def crc(b):
    return zlib.crc32(b) & 0xffffffff


def encode(r):
    for k, cap in CAPS.items():
        v = r[k]
        if not VAL.fullmatch(v) or len(v) >= cap:
            return None
    if r['t'] < 0:
        return None
    cd = '-' if r['cd'] < 0 else str(r['cd'])
    body = ('FST1 ev=%s t=%d reason=%s sensor=%s value=%s hot=%s why=%s cd=%s'
            % (r['ev'], r['t'], r['reason'], r['sensor'], r['value'], r['hot'], r['why'], cd))
    if len(body) + 15 > FST_MAX:
        return None
    return '%s crc=%08x\n' % (body, crc(body.encode()))


def parse(line):
    if line.endswith('\n'):
        line = line[:-1]
    if len(line) < 20 or len(line) > FST_MAX or not line.startswith('FST1 ev='):
        return None
    if any(c < ' ' or c > '~' for c in line):
        return None
    m = re.fullmatch(r'(FST1 .*) crc=([0-9a-f]{8})', line)
    if not m or '%08x' % crc(m.group(1).encode()) != m.group(2):
        return None
    toks = m.group(1).split(' ')[1:]
    d = {}
    for tk in toks:
        k, eq, v = tk.partition('=')
        if not eq or k in d:
            return None
        d[k] = v
    if tuple(d) != KEYS:
        return None
    if not re.fullmatch(r'0|[1-9][0-9]{0,14}', d['t']):
        return None
    if d['cd'] != '-' and not re.fullmatch(r'0|[1-9][0-9]{0,5}', d['cd']):
        return None
    r = dict(d, t=int(d['t']), cd=-1 if d['cd'] == '-' else int(d['cd']))
    e = encode(r)
    if e is None or e[:-1] != line:
        return None
    return r


def scan(data):
    last, marker, cnt = None, 0, 0
    for raw in re.split(b'[\n\0]', data):
        try:
            s = raw.decode('ascii')
        except UnicodeDecodeError:
            continue
        r = parse(s)
        if r:
            cnt += 1
            last = r
            if r['ev'] in MARKERS:
                marker = 1
    return cnt, marker, last


def fsn_parse(rec):
    if len(rec) != FSN_LEN or rec[-1:] != b'\n':
        return None
    s = rec[:-1].decode('ascii').rstrip(' ')
    m = re.fullmatch(r'(FSN1 seq=(\d+) t=(\d+) ready=([01]) tier=([0-5]) n=(\S+) last=(\S+)) crc=([0-9a-f]{8})', s)
    if not m or '%08x' % crc(m.group(1).encode()) != m.group(8):
        return None
    return {'seq': int(m.group(2)), 't': int(m.group(3)), 'ready': int(m.group(4)), 'tier': int(m.group(5)),
            'n': m.group(6), 'last': m.group(7)}


def fmt_scan(data):
    cnt, mk, r = scan(data)
    if not cnt:
        return 'count=0 marker=0'
    return ('count=%d marker=%d ev=%s t=%d reason=%s sensor=%s value=%s hot=%s why=%s cd=%d'
            % (cnt, mk, r['ev'], r['t'], r['reason'], r['sensor'], r['value'], r['hot'], r['why'], r['cd']))


if __name__ == '__main__':
    print(fmt_scan(open(sys.argv[1], 'rb').read()))
