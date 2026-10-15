#!/usr/bin/env python3
"""FSB1 reference decoder / validator (Python 3, stdlib only).

Spec: devices/quest3/common/FSB1-SPEC.md. This is the cross-check twin of
host/fsb1.ps1 (Windows PowerShell 5.1); both must return the same verdict and
the same first rejection reason for every input (fixtures/fsb1/CASES.tsv).

    fsb1.py check --exp EXP --nonce N --chal C --steps id1,id2,... FILE [--dump DIR]

Prints "VALID" (exit 0) or "REJECT <reason> <detail>" (exit 1).
"""
import base64
import hashlib
import re
import sys

MAX_BYTES = 8 * 1024 * 1024
NUM = r"(0|[1-9][0-9]{0,14})"
SNUM = r"(-1|0|[1-9][0-9]{0,14})"
RE_BEGIN = re.compile(r"FSB1 BEGIN v=" + NUM + r" exp=([a-z0-9_]{1,16}) nonce=([0-9a-f]{16}) "
                      r"chal=([0-9a-f]{32}) steps=" + NUM)
RE_END = re.compile(r"FSB1 END v=" + NUM + r" nonce=([0-9a-f]{16}) chal=([0-9a-f]{32}) "
                    r"lines=" + NUM + r" rec_sha256=([0-9a-f]{64})")
STEP_KEYS = ["i", "id", "end", "code", "sig", "errno", "ms", "term_ms", "kill_ms",
             "out_total", "out_kept", "err_total", "err_kept", "strays", "pipes", "why",
             "out_len", "out_sha256", "err_len", "err_sha256"]
RE_STEP = re.compile(
    r"FSB1 STEP i=" + NUM + r" id=([a-z0-9_]{1,16})"
    r" end=(exited|signaled|timer-term|timer-kill|exec-failed|unreaped|refused|internal|nosup)"
    r" code=" + SNUM + r" sig=" + NUM + r" errno=" + NUM + r" ms=" + SNUM +
    r" term_ms=" + SNUM + r" kill_ms=" + SNUM + r" out_total=" + NUM + r" out_kept=" + NUM +
    r" err_total=" + NUM + r" err_kept=" + NUM + r" strays=" + NUM +
    r" pipes=(eof|open|none) why=([a-z-]{1,32})"
    r" out_len=" + NUM + r" out_sha256=([0-9a-f]{64}) err_len=" + NUM + r" err_sha256=([0-9a-f]{64})")
RE_DATA = re.compile(r"FSB1 DATA i=" + NUM + r" s=([oe]) n=" + NUM + r" ([A-Za-z0-9+/=]{1,64})")
INT_KEYS = {"i", "code", "sig", "errno", "ms", "term_ms", "kill_ms", "out_total", "out_kept",
            "err_total", "err_kept", "strays", "out_len", "err_len"}


class Reject(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(reason)
        self.reason, self.detail = reason, detail


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def _consistent(st):
    """Cross-field rules on the fs-supervise fields (spec section 5)."""
    e = st["end"]
    for s in ("out", "err"):
        if st[s + "_kept"] > st[s + "_total"]:
            return False
    if e == "exited":
        return 0 <= st["code"] <= 255 and st["sig"] == 0 and st["term_ms"] == -1 and st["kill_ms"] == -1
    if e == "signaled":
        return st["code"] == -1 and st["sig"] > 0 and st["term_ms"] == -1 and st["kill_ms"] == -1
    if e == "timer-term":
        return st["term_ms"] >= 0 and st["kill_ms"] == -1
    if e == "timer-kill":
        return st["term_ms"] >= 0 and st["kill_ms"] >= 0
    return True


def _finish(st):
    for s in ("o", "e"):
        name = "out" if s == "o" else "err"
        chunks = st["chunks"][s]
        for c in chunks[:-1]:
            if len(c) != 64:
                raise Reject("bad-data", "step %d %s: short line before the last" % (st["i"], name))
        joined = "".join(chunks)
        if joined:
            if len(chunks[-1]) % 4:
                raise Reject("bad-data", "step %d %s: last line length" % (st["i"], name))
            try:
                dec = base64.b64decode(joined, validate=True)
            except Exception:
                raise Reject("bad-data", "step %d %s: base64" % (st["i"], name))
            if base64.b64encode(dec).decode("ascii") != joined:
                raise Reject("bad-data", "step %d %s: non-canonical base64" % (st["i"], name))
        else:
            dec = b""
        if len(dec) != st[name + "_len"]:
            raise Reject("length-mismatch", "step %d %s: decoded %d, %s_len %d" % (st["i"], name, len(dec), name, st[name + "_len"]))
        if st["end"] != "nosup" and st[name + "_len"] != st[name + "_kept"]:
            raise Reject("length-mismatch", "step %d %s: %s_len %d, %s_kept %d" % (st["i"], name, name, st[name + "_len"], name, st[name + "_kept"]))
        if _sha(dec) != st[name + "_sha256"]:
            raise Reject("payload-hash", "step %d %s" % (st["i"], name))
        st[name] = dec
    del st["chunks"]


def decode(data, exp, nonce, chal, steps):
    """Returns list of step dicts; raises Reject. steps: expected id list."""
    if len(data) > MAX_BYTES:
        raise Reject("too-large", "%d bytes" % len(data))
    text = data.decode("latin-1")
    pieces = text.split("\n")
    # (logical text, terminated?) — trailing CRs are terminator bytes, not content
    lines = [(p.rstrip("\r"), True) for p in pieces[:-1]]
    if pieces[-1] != "":
        lines.append((pieces[-1].rstrip("\r"), False))

    begins = [k for k, (t, _) in enumerate(lines) if t.startswith("FSB1 BEGIN")]
    if not begins:
        raise Reject("no-begin")
    if len(begins) > 1:
        raise Reject("multiple-begin", "%d BEGIN lines" % len(begins))
    b = begins[0]
    e = next((k for k in range(b + 1, len(lines)) if lines[k][0].startswith("FSB1 END") and lines[k][1]), None)
    if e is None:
        raise Reject("no-end")
    for k, (t, _) in enumerate(lines):
        if (k < b or k > e) and "FSB1" in t:
            raise Reject("stray-fsb1-line", "line %d" % (k + 1))
    rec = [t for t, _ in lines[b:e + 1]]
    for k, t in enumerate(rec):
        if any(ord(ch) < 0x20 or ord(ch) > 0x7E for ch in t):
            raise Reject("bad-char", "record line %d" % (k + 1))

    m = RE_END.fullmatch(rec[-1])
    if not m:
        raise Reject("bad-end")
    ev, enonce, echal, elines, ehash = m.groups()
    if ev != "1":
        raise Reject("version", "END v=" + ev)
    if int(elines) != len(rec) - 1:
        raise Reject("line-count", "END lines=%s, counted %d" % (elines, len(rec) - 1))
    canon = "".join(t + "\n" for t in rec[:-1]).encode("latin-1")
    if _sha(canon) != ehash:
        raise Reject("rec-hash")

    m = RE_BEGIN.fullmatch(rec[0])
    if not m:
        raise Reject("bad-begin")
    bv, bexp, bnonce, bchal, bsteps = m.groups()
    if bv != "1":
        raise Reject("version", "BEGIN v=" + bv)
    if bexp != exp:
        raise Reject("exp-mismatch", bexp)
    if bnonce != nonce or enonce != nonce:
        raise Reject("nonce-mismatch")
    if bchal != chal or echal != chal:
        raise Reject("chal-mismatch")
    if int(bsteps) != len(steps):
        raise Reject("step-count", "BEGIN steps=%s, expected %d" % (bsteps, len(steps)))

    out, cur, seen = [], None, set()
    for t in rec[1:-1]:
        if t.startswith("FSB1 STEP "):
            m = RE_STEP.fullmatch(t)
            if not m:
                raise Reject("bad-step", t[:40])
            if cur is not None:
                _finish(cur)
            st = {k: (int(v) if k in INT_KEYS else v) for k, v in zip(STEP_KEYS, m.groups())}
            if st["id"] in seen:
                raise Reject("duplicate-step", st["id"])
            if st["i"] != len(out) + 1:
                raise Reject("step-order", "i=%d where %d expected" % (st["i"], len(out) + 1))
            if st["i"] > len(steps):
                raise Reject("step-count", "more steps than expected")
            if st["id"] != steps[st["i"] - 1]:
                raise Reject("step-id", "i=%d id=%s, expected %s" % (st["i"], st["id"], steps[st["i"] - 1]))
            if not _consistent(st):
                raise Reject("step-inconsistent", "step %d" % st["i"])
            seen.add(st["id"])
            st["chunks"], st["phase"] = {"o": [], "e": []}, "o"
            cur = st
            out.append(st)
        elif t.startswith("FSB1 DATA "):
            m = RE_DATA.fullmatch(t)
            if not m:
                raise Reject("bad-data", t[:40])
            if cur is None:
                raise Reject("bad-line", "DATA before any STEP")
            di, ds, dn, chunk = int(m.group(1)), m.group(2), int(m.group(3)), m.group(4)
            if di != cur["i"]:
                raise Reject("data-order", "DATA i=%d inside step %d" % (di, cur["i"]))
            if ds == "o" and cur["phase"] == "e":
                raise Reject("data-order", "stdout DATA after stderr DATA")
            if ds == "e":
                cur["phase"] = "e"
            if dn != len(cur["chunks"][ds]):
                raise Reject("data-order", "step %d s=%s n=%d where %d expected" % (cur["i"], ds, dn, len(cur["chunks"][ds])))
            cur["chunks"][ds].append(chunk)
        else:
            raise Reject("bad-line", t[:40])
    if cur is not None:
        _finish(cur)
    if len(out) != len(steps):
        raise Reject("step-count", "%d steps, expected %d" % (len(out), len(steps)))
    for st in out:
        del st["phase"]
    return out


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--exp", required=True)
    c.add_argument("--nonce", required=True)
    c.add_argument("--chal", required=True)
    c.add_argument("--steps", required=True)
    c.add_argument("--dump")
    c.add_argument("file")
    a = ap.parse_args(argv)
    with open(a.file, "rb") as fh:
        data = fh.read()
    try:
        steps = decode(data, a.exp, a.nonce, a.chal, a.steps.split(","))
    except Reject as r:
        print("REJECT %s %s" % (r.reason, r.detail))
        return 1
    print("VALID")
    for st in steps:
        print("  step %d %s end=%s code=%d sig=%d out=%dB(sha256 %s) err=%dB(sha256 %s)" % (
            st["i"], st["id"], st["end"], st["code"], st["sig"], len(st["out"]), _sha(st["out"]),
            len(st["err"]), _sha(st["err"])))
        if a.dump:
            import os
            for s in ("out", "err"):
                with open(os.path.join(a.dump, "%d.%s" % (st["i"], s)), "wb") as fh:
                    fh.write(st[s])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
