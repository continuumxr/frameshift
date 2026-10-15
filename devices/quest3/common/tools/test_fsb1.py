#!/usr/bin/env python3
"""Run every FSB1 fixture in fixtures/fsb1/CASES.tsv through tools/fsb1.py.

    python3 -I tools/test_fsb1.py [FIXDIR]

For VALID cases the decoded payloads must also match PAYLOADS.tsv, whose
hashes were computed from fs-supervise's raw capture files (not from the
record), so encoder and decoder are checked end to end. Writes
FIXDIR/RESULTS-python.txt; exit 0 only if every case matches.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import fsb1  # noqa: E402

FX = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "fixtures", "fsb1")
payloads = {}
for row in open(os.path.join(FX, "PAYLOADS.tsv")):
    g, i, s, h, n = row.rstrip("\n").split("\t")
    payloads[(g, int(i), s)] = (h, int(n))

lines, ok, bad = [], 0, 0
for row in open(os.path.join(FX, "CASES.tsv")):
    name, expect, reason, exp, nonce, chal, steps, group = row.rstrip("\n").split("\t")
    data = open(os.path.join(FX, name + ".txt"), "rb").read()
    try:
        out = fsb1.decode(data, exp, nonce, chal, steps.split(","))
        got, why = "VALID", "-"
    except fsb1.Reject as r:
        out, got, why = None, "REJECT", r.reason
    good = (got == expect and why == reason)
    extra = ""
    if good and out is not None:
        for st in out:
            for s in ("out", "err"):
                h, n = payloads[(group, st["i"], s)]
                if hashlib.sha256(st[s]).hexdigest() != h or len(st[s]) != n:
                    good, extra = False, " payload mismatch step %d %s" % (st["i"], s)
        if good:
            extra = " (%d steps, payloads = raw captures)" % len(out)
    lines.append("%-28s %-4s got=%s/%s want=%s/%s%s" % (name, "PASS" if good else "FAIL", got, why, expect, reason, extra))
    ok, bad = ok + good, bad + (not good)
lines.append("TOTAL pass=%d fail=%d" % (ok, bad))
open(os.path.join(FX, "RESULTS-python.txt"), "w", newline="\n").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if bad == 0 else 1)
