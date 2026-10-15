#!/usr/bin/env python3
"""Validate fs-pattern FSP1 record streams. Offline only.

usage: check_stream.py --expect complete|incomplete|invalid|empty FILE...

Lines starting with "# " are fixture annotations and are skipped. For each
file prints "STREAM <file> <STATUS> <reason>" and exits 1 if any file's
status differs from --expect.

  COMPLETE    every record well-formed; len and crc32 match; nonce constant;
              seq 0,1,2,... without gaps; last record step=eos with
              records == number of records and dropped == 0, right after
              step=exit.
  INCOMPLETE  well-formed so far, but the stream stops before step=eos (or
              the last line is torn).
  INVALID     a malformed record, len/crc mismatch, seq gap/duplicate,
              nonce change, or anything after eos.
  EMPTY       no records at all (e.g. stdout refused, exit 3).
"""
import re
import sys
import zlib

REC = re.compile(rb"^FSP1 nonce=([0-9a-f]{8}|none) seq=(0|[1-9][0-9]*) step=([a-z_]+) "
                 rb"rc=(-?[0-9]+)((?: [a-z_0-9]+=[A-Za-z0-9_./%-]+)*) "
                 rb"len=(0|[1-9][0-9]*) crc=([0-9a-f]{8}) END$")
KV = re.compile(rb" ([a-z_0-9]+)=([A-Za-z0-9_./%-]+)")


def classify(data):
    lines = data.split(b"\n")
    tail = lines.pop()                  # b"" when the data ends with a newline
    torn = tail != b"" and not tail.startswith(b"# ")
    recs = [l for l in lines if not l.startswith(b"# ")]
    if not recs and not torn:
        return "EMPTY", "no records"
    nonce = None
    seen_eos = False
    for i, l in enumerate(recs):
        if seen_eos:
            return "INVALID", f"record after eos at line {i}"
        m = REC.match(l)
        if not m:
            return "INVALID", f"malformed record {i}: {l[:80]!r}"
        body = l[:l.rindex(b" len=")]
        if int(m.group(6)) != len(body):
            return "INVALID", f"len mismatch at seq {m.group(2).decode()}"
        if int(m.group(7), 16) != (zlib.crc32(body) & 0xffffffff):
            return "INVALID", f"crc mismatch at seq {m.group(2).decode()}"
        if int(m.group(2)) != i:
            return "INVALID", f"seq gap/duplicate: got {m.group(2).decode()} expected {i}"
        if nonce is None:
            nonce = m.group(1)
        elif m.group(1) != nonce:
            return "INVALID", f"nonce changed at seq {i}"
        if m.group(3) == b"eos":
            kv = dict(KV.findall(m.group(5)))
            if i == 0 or REC.match(recs[i - 1]).group(3) != b"exit":
                return "INVALID", "eos not preceded by exit"
            if kv.get(b"records") != str(i + 1).encode():
                return "INVALID", f"eos records={kv.get(b'records')} but {i + 1} records"
            if kv.get(b"dropped") != b"0":
                return "INVALID", f"eos reports dropped={kv.get(b'dropped')}"
            seen_eos = True
    if torn:
        return "INCOMPLETE", "torn last line"
    if not seen_eos:
        return "INCOMPLETE", f"no eos after {len(recs)} records"
    return "COMPLETE", f"{len(recs)} records"


def main():
    if len(sys.argv) < 4 or sys.argv[1] != "--expect":
        print(__doc__)
        sys.exit(2)
    want = sys.argv[2].upper()
    bad = 0
    for f in sys.argv[3:]:
        status, why = classify(open(f, "rb").read())
        print(f"STREAM {f} {status} {why}")
        bad += status != want
    sys.exit(1 if bad else 0)


main()
