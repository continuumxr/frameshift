#!/usr/bin/env python3
"""Derive the FSB1 negative (and translated-positive) fixtures from one valid
record produced by the real encoder under qemu (tools/fixtures-fsb1.sh).

    fsb1_mutate.py FIXDIR NONCE CHAL STEPS

Reads FIXDIR/valid.txt; writes FIXDIR/<case>.txt and appends to FIXDIR/CASES.tsv.
"Rehash" means the END line's lines= and rec_sha256= are recomputed after the
edit, so the case tests the layer BELOW the record hash.
"""
import hashlib
import os
import sys

FX, NONCE, CHAL, STEPS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
EXP = "fixture"
WRONG_NONCE = "ffffffffffffffff"
WRONG_CHAL = "0" * 32
emitted = open(os.path.join(FX, "valid.txt"), "rb").read()
assert b"\r" not in emitted
# Encoder revision 5: fsb1_emit writes one empty line before BEGIN. The derived
# cases are built from the record itself (BEGIN..END), i.e. without that line.
LEAD = b"\n" if emitted.startswith(b"\n") else b""
valid = emitted[len(LEAD):]
assert valid.startswith(b"FSB1 BEGIN "), "valid.txt is not (an empty line +) the record"
L = valid.decode("ascii").split("\n")
assert L[-1] == ""
L = L[:-1]


def rehash(lines):
    body = lines[:-1]
    h = hashlib.sha256("".join(t + "\n" for t in body).encode("ascii")).hexdigest()
    end = lines[-1].split(" ")
    end = [("lines=%d" % len(body)) if p.startswith("lines=") else
           ("rec_sha256=" + h) if p.startswith("rec_sha256=") else p for p in end]
    return body + [" ".join(end)]


def text(lines):
    return "".join(t + "\n" for t in lines).encode("ascii")


def block(lines, i):
    """(start, stop) indices of step i's STEP line and its DATA lines."""
    s = next(k for k, t in enumerate(lines) if t.startswith("FSB1 STEP i=%d " % i))
    e = s + 1
    while lines[e].startswith("FSB1 DATA i=%d " % i):
        e += 1
    return s, e


def sub_first(lines, prefix, old, new):
    k = next(k for k, t in enumerate(lines) if t.startswith(prefix))
    assert old in lines[k], (prefix, old)
    out = list(lines)
    out[k] = out[k].replace(old, new, 1)
    return out


cases = []


def case(name, data, expect, reason):
    open(os.path.join(FX, name + ".txt"), "wb").write(data)
    cases.append((name, expect, reason))


# ---- translated positives --------------------------------------------------
case("valid-crlf", valid.replace(b"\n", b"\r\n"), "VALID", "-")
case("valid-crcrlf", valid.replace(b"\n", b"\r\r\n"), "VALID", "-")
case("valid-echo-prompt", ("~ # fs-valve %s\r\n" % CHAL).encode() + valid.replace(b"\n", b"\r\n") + b"~ # ", "VALID", "-")

# ---- no-echo target (host/COLLECTOR.md section 6): the prompt, then the encoder's output
case("noecho-prompt-emitted", b"~ # \x1b[6n" + emitted, "VALID", "-")   # requirement: valid without echo
# what an encoder WITHOUT the leading empty line (revision 4) produced on a no-echo target
case("noecho-prompt-joined", b"~ # \x1b[6n" + valid, "REJECT", "no-begin")

# ---- incomplete -------------------------------------------------------------
case("empty", b"", "REJECT", "no-begin")
case("echo-only", ("~ # fs-valve %s\r\n~ # " % CHAL).encode(), "REJECT", "no-begin")
case("truncated-no-end", text(L[:-1]), "REJECT", "no-end")
s, e = block(L, 2)
case("truncated-mid-line", text(L[:s + 2]) + L[s + 2][:30].encode(), "REJECT", "no-end")
case("truncated-end-unterminated", text(L[:-1]) + L[-1][:-1].encode(), "REJECT", "no-end")
case("truncated-end-line", text(L[:-1] + [L[-1][:40]]), "REJECT", "bad-end")
case("dropped-char", text(L[:s + 1] + [L[s + 1][:-1]] + L[s + 2:]), "REJECT", "rec-hash")
case("missing-data-line", text(rehash(L[:s + 3] + L[s + 4:])), "REJECT", "data-order")

# ---- ambiguous / duplicated -------------------------------------------------
case("duplicate-record", valid + valid, "REJECT", "multiple-begin")
case("stray-fsb1-line", valid + (L[s + 1] + "\n").encode(), "REJECT", "stray-fsb1-line")
s3, e3 = block(L, 3)
case("duplicate-step", text(rehash(L[:e3] + L[s3:e3] + L[e3:])), "REJECT", "duplicate-step")
s2, e2 = block(L, 2)
swapped = L[:s2] + L[s3:e3] + L[s2:e2] + L[e3:]
case("reordered-steps", text(rehash(swapped)), "REJECT", "step-order")
ren = list(swapped)
for k in range(s2, s2 + (e3 - s3)):
    ren[k] = ren[k].replace(" i=3 ", " i=2 ", 1)
for k in range(s2 + (e3 - s3), e3):
    ren[k] = ren[k].replace(" i=2 ", " i=3 ", 1)
case("reordered-steps-renumbered", text(rehash(ren)), "REJECT", "step-id")
sl, el = block(L, len(STEPS.split(",")))
case("missing-step", text(rehash(L[:sl] + L[el:])), "REJECT", "step-count")

# ---- identity ---------------------------------------------------------------
case("wrong-nonce", text(rehash([t.replace("nonce=" + NONCE, "nonce=" + WRONG_NONCE) for t in L])), "REJECT", "nonce-mismatch")
case("wrong-nonce-end-only", text(rehash(L[:-1] + [L[-1].replace("nonce=" + NONCE, "nonce=" + WRONG_NONCE)])), "REJECT", "nonce-mismatch")
case("wrong-chal", text(rehash([t.replace("chal=" + CHAL, "chal=" + WRONG_CHAL) for t in L])), "REJECT", "chal-mismatch")
case("wrong-exp", text(rehash(sub_first(L, "FSB1 BEGIN", "exp=" + EXP, "exp=other"))), "REJECT", "exp-mismatch")
case("wrong-version", text(rehash(sub_first(L, "FSB1 BEGIN", " v=1 ", " v=2 "))), "REJECT", "version")

# ---- tampering --------------------------------------------------------------
s1, e1 = block(L, 1)
d = L[s1 + 1]
pre, chunk = d.rsplit(" ", 1)
flip = ("B" if chunk[0] != "B" else "C") + chunk[1:]
t1 = L[:s1 + 1] + [pre + " " + flip] + L[s1 + 2:]
case("tampered-payload", text(rehash(t1)), "REJECT", "payload-hash")
case("tampered-payload-norehash", text(t1), "REJECT", "rec-hash")
case("tampered-step-field", text(sub_first(L, "FSB1 STEP i=1 ", " code=0 ", " code=1 ")), "REJECT", "rec-hash")
s4, e4 = block(L, 4)
case("length-mismatch", text(rehash(sub_first(L, "FSB1 STEP i=4 ", " out_len=4 ", " out_len=5 "))), "REJECT", "length-mismatch")
nc = list(L)
assert nc[s4 + 1].endswith(" b3V0Cg=="), nc[s4 + 1]           # "out\n"
nc[s4 + 1] = nc[s4 + 1][:-len("b3V0Cg==")] + "b3V0Ch=="           # same bytes, non-zero pad bits
case("noncanonical-base64", text(rehash(nc)), "REJECT", "bad-data")
case("step-inconsistent", text(rehash(sub_first(L, "FSB1 STEP i=1 ", " term_ms=-1 ", " term_ms=5 "))), "REJECT", "step-inconsistent")
case("bad-step-extra-key", text(rehash(sub_first(L, "FSB1 STEP i=1 ", " why=none ", " why=none x=1 "))), "REJECT", "bad-step")
case("line-count", text(L[:-1] + [L[-1].replace("lines=", "lines=1", 1)]), "REJECT", "line-count")

# ---- transport damage -------------------------------------------------------
cr = list(L)
cr[s1] = cr[s1].replace(" ", "\r", 1)
case("cr-inside-line", text(cr), "REJECT", "bad-char")
case("foreign-line-inside", text(rehash(L[:s1 + 1] + ["~ # "] + L[s1 + 1:])), "REJECT", "bad-line")
# a payload re-wrapped at 76 columns (another base64 tool): same bytes, other framing
s2b, e2b = block(L, 2)
b64 = "".join(t.rsplit(" ", 1)[1] for t in L[s2b + 1:e2b] if " s=o " in t)
wide = ["FSB1 DATA i=2 s=o n=%d %s" % (n, b64[k:k + 76]) for n, k in enumerate(range(0, len(b64), 76))]
case("wide-data-line", text(rehash(L[:s2b + 1] + wide + [t for t in L[s2b + 1:e2b] if " s=o " not in t] + L[e2b:])), "REJECT", "bad-data")

with open(os.path.join(FX, "CASES.tsv"), "a") as fh:
    for name, expect, reason in cases:
        fh.write("\t".join([name, expect, reason, EXP, NONCE, CHAL, STEPS, "generic" if expect == "VALID" else "-"]) + "\n")
print("wrote %d derived cases" % len(cases))
