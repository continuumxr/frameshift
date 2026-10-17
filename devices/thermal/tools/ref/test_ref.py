#!/usr/bin/env python3
"""Run tools/fix/mkfix.py into a temp dir and check tools/ref/metacfg_ref.py
against every case (METACFG-SPEC.md rev 1).

For each row of CASES.tsv (and CASES-AMBIGUOUS.tsv) the reference reader is
run through its CLI; a case passes when the exit code is 0, the stdout status
equals expected_status, the record's status field agrees, and the record is
byte-identical to mkfix's expected/<case>.rec (full payload for ok cases,
header-only otherwise).

Usage: python3 -I tools/ref/test_ref.py [--keep DIR]
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MKFIX = os.path.join(HERE, '..', 'fix', 'mkfix.py')
REF = os.path.join(HERE, 'metacfg_ref.py')


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        lines = f.read().splitlines()
    cols = lines[0].split('\t')
    return [dict(zip(cols, ln.split('\t'))) for ln in lines[1:] if ln]


def run_case(d, row):
    rec_path = os.path.join(d, 'out', row['case'] + '.rec')
    argv = [sys.executable, '-I', REF, '--image',
            os.path.join(d, row['image']), '--device', row['device'],
            '--slot-suffix', row['slot_suffix'], '--super-size',
            row['super_size'], '--out', rec_path]
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True)
    line = r.stdout.strip()
    got = dict(kv.split('=', 1) for kv in line.split()) if line else {}
    status = got.get('status', '?')
    problems = []
    if r.returncode != 0:
        problems.append('exit %d: %s' % (r.returncode, r.stderr.strip()[-300:]))
    if status != row['expected_status']:
        problems.append('status %s != %s' % (status, row['expected_status']))
    try:
        with open(rec_path, 'rb') as f:
            rec = f.read()
        with open(os.path.join(d, 'expected', row['case'] + '.rec'), 'rb') as f:
            exp = f.read()
        if len(rec) < 64 or rec[:4] != b'FSMC':
            problems.append('bad record framing')
        elif rec != exp:
            fields = struct.unpack('<4sHHIIHHIIIIII20s', rec[:64])
            efields = struct.unpack('<4sHHIIHHIIIIII20s', exp[:64])
            if fields != efields:
                problems.append('header %r != expected %r'
                                % (fields[1:13], efields[1:13]))
            else:
                problems.append('payload differs (%d vs %d bytes)'
                                % (len(rec), len(exp)))
    except OSError as e:
        problems.append(str(e))
    return status, got, problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--keep', help='write fixtures here and keep them')
    a = ap.parse_args()
    d = a.keep or tempfile.mkdtemp(prefix='fsmc-fix-')
    try:
        r = subprocess.run([sys.executable, '-I', MKFIX, '--out', d])
        if r.returncode != 0:
            print('mkfix failed')
            return 1
        os.makedirs(os.path.join(d, 'out'), exist_ok=True)
        total_bad = 0
        for title, rows in (('CASES.tsv', read_tsv(os.path.join(d, 'CASES.tsv'))),
                            ('CASES-AMBIGUOUS.tsv',
                             read_tsv(os.path.join(d, 'CASES-AMBIGUOUS.tsv')))):
            print('\n== %s' % title)
            print('%-28s %-18s %-18s %s' % ('case', 'expected', 'got', 'result'))
            good = 0
            for row in rows:
                status, got, problems = run_case(d, row)
                ok = not problems
                good += ok
                extra = ''
                if status == 'ok':
                    extra = ' n=%s json=%s digest=%s' % (
                        got.get('n'), got.get('json'), got.get('digest', '')[:16])
                print('%-28s %-18s %-18s %s%s' % (
                    row['case'], row['expected_status'], status,
                    'PASS' if ok else 'FAIL ' + '; '.join(problems), extra))
            total_bad += len(rows) - good
            print('%d/%d cases as expected (%s)' % (good, len(rows), title))
        return 1 if total_bad else 0
    finally:
        if not a.keep:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
