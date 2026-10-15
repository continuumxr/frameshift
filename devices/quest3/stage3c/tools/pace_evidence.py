#!/usr/bin/env python3
"""FrameShift stage 3c — evidence for the PACED FSB1 emission of the per-phase records (DESIGN.md §5.3).
Derived from stage3b/tools/pace_evidence.py (unchanged). Run inside WSL:
    python3 -I -B pace_evidence.py OUTDIR
Offline: the REAL encoder (common/target/fsb1-enc.sh rev 5) and the REAL pacer (common/target/fsb1-pace.sh)
run by the reviewed stage-1 busybox under qemu-aarch64; every step is captured by the real aarch64
fs-supervise with fs-phase's caps. No device.

Per phase (p0: hash 256 + probe0 16384, MAXLINES 360; r1/r2: probe 16384 + pattern 57344, MAXLINES 1545;
r3: probe 16384 + pattern 28672, MAXLINES 945; exp s3c_<ph>, 2 steps):
(a) byte identity: the AT-CAPS record (every step's stdout at its cap, and for p0 the hash step's stderr at
    its cap: the largest record a phase within its caps can produce) and the MAXIMUM permitted record
    (exactly MAXLINES lines, topped up with stderr) are emitted by `fsb1_emit_paced REC TICK MAXLINES`
    (FSB1_PACE_LINES=20, as fs-phase.sh sets it) byte for byte as `fsb1_emit REC`; both decode VALID with
    common/tools/fsb1.py and carry the same rec_sha256 (recomputed here independently). A REPRESENTATIVE
    r2 record (the mock-model quad stream and a harness probe output when present) too.
(b) the damaged trial-(iii) capture is still REJECTed with line-count.
(c) the r2 maximum through a real pty (ONLCR) and split at every 20-line chunk boundary and mid-line,
    rejoined: VALID, same bytes; no prefix is ever VALID.
(d) timing of each maximum under qemu against the analytic emission bound of check-timing-3c.py (<= the bound itself,
    no allowance: build review).
Refusals: MAXLINES + 1 lines -> rc 3 and NOTHING written (per phase); CR/TAB/0x7f/high byte/no final
newline -> rc 4 and nothing written.
Writes OUTDIR/RESULTS.txt.
"""
import hashlib
import os
import pty
import random
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../.."))
Q3 = ROOT + "/devices/quest3"
BB_SRC = ROOT + "/build/third_party/busybox/busybox"
BB_SHA = "c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02"
SUP = Q3 + "/common/build/fs-supervise"
ENC = Q3 + "/common/target/fsb1-enc.sh"
PACE = Q3 + "/common/target/fsb1-pace.sh"
FSB1PY = Q3 + "/common/tools/fsb1.py"
NONCE = "3c3c3c3c0011aa55"
CHAL = "c0ffee3c0123456789abcdef01234567"
PHASES = {   # stage3c/fs-phase.sh
    "p0": (["hash", "probe0"], [256, 16384], 360),
    "r1": (["probe1", "pattern1"], [16384, 57344], 1545),
    "r2": (["probe2", "pattern2"], [16384, 57344], 1545),
    "r3": (["probe3", "pattern3"], [16384, 28672], 945),
}
PL = 20
FIRST_READ = 12289
out_lines = []
fails = 0


def res(name, ok, detail=""):
    global fails
    line = "%s  %s  %s" % ("PASS" if ok else "FAIL", name, detail)
    print(line)
    out_lines.append(line)
    fails += 0 if ok else 1


def sh_target(w, script, stdout=None, timeout=900):
    env = {"PATH": w + "/bin", "BB": w + "/bin/busybox", "FSB1_SUP": SUP, "ENC": ENC, "PACE": PACE}
    open(w + "/t.sh", "w").write(script)
    return subprocess.run(["/usr/bin/qemu-aarch64", w + "/bin/busybox", "sh", w + "/t.sh"], env=env,
                          stdout=stdout if stdout is not None else subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def make_record(w, ph, name, payloads, errs):
    steps, caps, _ = PHASES[ph]
    d = w + "/" + ph + "-" + name
    os.makedirs(d + "/cap")
    for i, p in enumerate(payloads, 1):
        open("%s/p%d.bin" % (d, i), "wb").write(p)
        open("%s/e%d.bin" % (d, i), "wb").write(errs[i - 1])
    lines = ['. "$ENC"', 'R=%s/record; D=%s/cap' % (d, d), 'fsb1_begin "$R" s3c_%s %s %s 2 || exit 11' % (ph, NONCE, CHAL)]
    for i, sid in enumerate(steps, 1):
        lines.append('"$FSB1_SUP" -t 20 -g 1 -c %d -o "$D/%d.out" -r "$D/%d.err" -- "$BB" sh -c "cat %s/p%d.bin; cat %s/e%d.bin >&2" > "$D/%d.sup" 2>/dev/null' % (caps[i - 1], i, i, d, i, d, i, i))
        lines.append('fsb1_step "$R" %d %s "$D/%d.sup" "$D/%d.out" "$D/%d.err" || exit 12' % (i, sid, i, i, i))
    lines.append('fsb1_end "$R" %s %s || exit 13' % (NONCE, CHAL))
    r = sh_target(w, "\n".join(lines) + "\n")
    assert r.returncode == 0, (name, r.returncode, r.stderr[-400:])
    return d + "/record"


def emit(w, rec, paced, outfile, maxlines):
    if paced:
        script = '. "$ENC"; FSB1_PACE_LINES=%d; . "$PACE"; mkfifo -m 600 %s/tick 2>/dev/null; fsb1_emit_paced "%s" %s/tick %d; echo "rc=$?" >&2\n' % (PL, w, rec, w, maxlines)
    else:
        script = '. "$ENC"; fsb1_emit "%s"; echo "rc=$?" >&2\n' % rec
    t0 = time.monotonic()
    with open(outfile, "wb") as f:
        r = sh_target(w, script, stdout=f)
    dt = time.monotonic() - t0
    rc = re.search(rb"rc=(\d+)", r.stderr)
    return (int(rc.group(1)) if rc else -1), dt


def fsb1_check(path, ph):
    r = subprocess.run(["python3", "-I", "-B", FSB1PY, "check", "--exp", "s3c_" + ph, "--nonce", NONCE, "--chal", CHAL,
                        "--steps", ",".join(PHASES[ph][0]), path], capture_output=True, text=True)
    return r.stdout.strip().splitlines()[0] if r.stdout else r.stderr.strip()[:200]


def rec_sha_of(data):
    m = re.search(rb"FSB1 END v=1 nonce=[0-9a-f]{16} chal=[0-9a-f]{32} lines=(\d+) rec_sha256=([0-9a-f]{64})", data)
    return (int(m.group(1)), m.group(2).decode()) if m else (None, None)


def independent_rec_sha(data):
    ls = data.split(b"\n")
    b = [k for k, l in enumerate(ls) if l.rstrip(b"\r").startswith(b"FSB1 BEGIN")][0]
    e = [k for k, l in enumerate(ls) if l.rstrip(b"\r").startswith(b"FSB1 END")][0]
    return hashlib.sha256(b"".join(l.rstrip(b"\r") + b"\n" for l in ls[b:e])).hexdigest(), e - b


def through_pty(w, rec, maxlines):
    m, s = pty.openpty()
    env = {"PATH": w + "/bin", "BB": w + "/bin/busybox", "ENC": ENC, "PACE": PACE}
    open(w + "/tp.sh", "w").write('. "$ENC"; FSB1_PACE_LINES=%d; . "$PACE"; mkfifo -m 600 %s/tick2 2>/dev/null; fsb1_emit_paced "%s" %s/tick2 %d\n' % (PL, w, rec, w, maxlines))
    p = subprocess.Popen(["/usr/bin/qemu-aarch64", w + "/bin/busybox", "sh", w + "/tp.sh"], env=env, stdin=subprocess.DEVNULL, stdout=s, stderr=subprocess.DEVNULL)
    os.close(s)
    buf, arr, t0 = bytearray(), [], time.monotonic()
    while True:
        r, _, _ = select.select([m], [], [], 0.5)
        if r:
            try:
                d = os.read(m, 65536)
            except OSError:
                d = b""
            if not d:
                break
            arr.append((len(buf), len(d), time.monotonic() - t0))
            buf += d
        elif p.poll() is not None:
            break
    p.wait()
    os.close(m)
    return bytes(buf), arr


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    assert hashlib.sha256(open(BB_SRC, "rb").read()).hexdigest() == BB_SHA, "busybox is not the reviewed binary"
    w = tempfile.mkdtemp(prefix="pace3c.")
    try:
        os.makedirs(w + "/bin")
        shutil.copy(BB_SRC, w + "/bin/busybox")
        os.chmod(w + "/bin/busybox", 0o755)
        for a in "sh cat printf base64 awk sha256sum cut wc sed grep tr true sleep echo mkdir mkfifo tail head".split():
            os.symlink("busybox", w + "/bin/" + a)
        out_lines.append("# stage 3c paced-emission evidence  %s" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        out_lines.append("# busybox %s (reviewed); fs-supervise %s; fsb1-enc.sh %s; fsb1-pace.sh %s" % (
            BB_SHA[:16], hashlib.sha256(open(SUP, "rb").read()).hexdigest()[:16], hashlib.sha256(open(ENC, "rb").read()).hexdigest()[:16],
            hashlib.sha256(open(PACE, "rb").read()).hexdigest()))
        rnd = random.Random(0x3C)
        rb = lambda n: bytes(rnd.getrandbits(8) for _ in range(n))
        rd = lambda p: open(p, "rb").read() if os.path.exists(p) else b""
        fx = Q3 + "/stage3c/fixtures"
        maxrec = {}
        for ph, (steps, caps, ML) in PHASES.items():
            caps_out = [rb(c) for c in caps]
            caps_err = [rb(caps[0]) if ph == "p0" else b"", b""]
            legit = 2 + 2 + sum((len(x) + 47) // 48 for x in caps_out + caps_err)
            mx_err = list(caps_err); mx_err[1] = rb((ML - legit) * 48)
            ov_err = list(caps_err); ov_err[1] = rb((ML - legit + 1) * 48)
            recs = {"at-caps": make_record(w, ph, "caps", caps_out, caps_err), "maximum": make_record(w, ph, "max", caps_out, mx_err),
                    "maximum-plus-1": make_record(w, ph, "over", caps_out, ov_err)}
            if ph == "r2":
                rep = [rd(fx + "/image/c-sim-all/probe-r2.txt") or rb(6000), (rd(fx + "/sim/quad-vig.txt") or rb(30000))[:caps[1]]]
                recs["representative"] = make_record(w, ph, "rep", rep, [b"", b""])
            for name, rec in recs.items():
                n = sum(1 for _ in open(rec, "rb"))
                res("%s-record-%s-lines" % (ph, name), (name != "maximum" or n == ML) and (name != "maximum-plus-1" or n == ML + 1) and (name != "at-caps" or n == legit),
                    "%d lines, %d bytes (MAXLINES %d; caps-derived %d)" % (n, os.path.getsize(rec), ML, legit))
            for name in [x for x in ("representative", "at-caps", "maximum") if x in recs]:
                rec = recs[name]
                u, p_ = w + "/%s-%s-unpaced.rec" % (ph, name), w + "/%s-%s-paced.rec" % (ph, name)
                rcu, tu = emit(w, rec, False, u, ML)
                rcp, tp = emit(w, rec, True, p_, ML)
                bu, bp = open(u, "rb").read(), open(p_, "rb").read()
                res("%s-a-%s-bytes-identical" % (ph, name), rcu == 0 and rcp == 0 and bu == bp and bu == b"\n" + open(rec, "rb").read(),
                    "%d bytes; sha256 %s" % (len(bp), hashlib.sha256(bp).hexdigest()[:16]))
                vu, vp = fsb1_check(u, ph), fsb1_check(p_, ph)
                lu, su = rec_sha_of(bu); lp, sp = rec_sha_of(bp)
                ind, cnt = independent_rec_sha(bp)
                res("%s-a-%s-valid-same-rec_sha256" % (ph, name), vu.startswith("VALID") and vp.startswith("VALID") and su == sp == ind and lu == lp == cnt,
                    "fsb1.py %s / %s; rec_sha256 %s...; lines=%s" % (vu.split()[0], vp.split()[0], sp[:16], lp))
                nl = bp.count(b"\n") - 1
                bound = 1.0 + ((ML + PL - 1) // PL) * 0.11
                # build review (R-B helper finding 5): the measured paced time must be within the analytic bound itself
                # (no allowance; the bound is check-timing-3c.py's emission term, part of PHASE_WORST)
                res("%s-d-%s-emission-time" % (ph, name), tp >= ((nl // PL) - 1) * 0.1 * 0.9 and tp <= bound,
                    "%d lines: paced %.2f s under qemu (unpaced %.2f s); check-timing-3c.py bound for MAXLINES %d: %.2f s" % (nl, tp, tu, ML, bound))
                rl = open(rec, "rb").read().split(b"\n")[:-1]
                chunk_max = max(sum(len(x) + 1 for x in rl[i:i + PL]) for i in range(0, len(rl), PL))
                res("%s-d-%s-chunk-burst" % (ph, name), chunk_max < FIRST_READ // 4, "largest %d-line write: %d bytes" % (PL, chunk_max))
                if name == "maximum":
                    maxrec[ph] = (rec, p_)
            rco, _ = emit(w, recs["maximum-plus-1"], True, w + "/over.bin", ML)
            res("%s-refuse-maxlines-plus-1" % ph, rco == 3 and os.path.getsize(w + "/over.bin") == 0, "rc=%d, %d bytes written" % (rco, os.path.getsize(w + "/over.bin")))
        # (c) r2 maximum: pty, splits
        rec, pp = maxrec["r2"]
        bpty, arr = through_pty(w, rec, 1545)
        crlf_ok = bpty.replace(b"\r\n", b"\n") == open(pp, "rb").read()
        open(w + "/pty.bin", "wb").write(bpty)
        res("r2-c-maximum-through-pty-onlcr", crlf_ok and fsb1_check(w + "/pty.bin", "r2").startswith("VALID"), "%d bytes via a pty with ONLCR" % len(bpty))
        gaps = [arr[i + 1][2] - arr[i][2] for i in range(len(arr) - 1)]
        big = sum(1 for g in gaps if g >= 0.08)
        nch = (1545 + PL - 1) // PL
        res("r2-d-maximum-pty-pacing", big >= nch - 12, "%d reads; %d gaps >= 80 ms (%d chunks); max read %d bytes" % (len(arr), big, nch, max(n for _, n, _ in arr)))
        bp = open(pp, "rb").read()
        offs = [m_.end() for m_ in re.finditer(rb"\n", bp)]
        cuts = set()
        for k, o in enumerate(offs):
            if k % PL == 0:
                cuts.add(o)
                for d in (1, 37, 64):
                    if o + d < len(bp):
                        cuts.add(o + d)
        endpos = bp.find(b"FSB1 END")
        for d in (1, 9, 40, 100):
            cuts.add(endpos + d)
        pieces, prev = [], 0
        for c in sorted(cuts):
            pieces.append(bp[prev:c]); prev = c
        pieces.append(bp[prev:])
        joined = b"".join(pieces)
        open(w + "/joined.bin", "wb").write(joined)
        res("r2-c-maximum-split-everywhere-rejoined", joined == bp and fsb1_check(w + "/joined.bin", "r2").startswith("VALID"), "%d pieces; rejoined identical; VALID" % len(pieces))
        partial_ok = True
        for c in sorted(cuts)[::25]:
            open(w + "/part.bin", "wb").write(bp[:c])
            partial_ok &= fsb1_check(w + "/part.bin", "r2").startswith("REJECT")
        res("r2-c-every-prefix-before-the-end-is-not-a-record", partial_ok)
        base = open(maxrec["p0"][0], "rb").read()
        for tag, data in (("cr", base.replace(b"\n", b"\r\n", 1)), ("tab", base.replace(b" ", b"\t", 1)), ("del", base.replace(b"A", b"\x7f", 1)),
                          ("high", base.replace(b"A", b"\xe9", 1)), ("no-final-newline", base[:-1])):
            pth = w + "/bad-%s" % tag
            open(pth, "wb").write(data)
            rcb, _ = emit(w, pth, True, w + "/bad.bin", 360)
            res("refuse-%s" % tag, rcb == 4 and os.path.getsize(w + "/bad.bin") == 0, "rc=%d, nothing written" % rcb)
        cap = ROOT + "/relays/FS-A-010-raw/observe/collect/capture.raw"
        r = subprocess.run(["python3", "-I", "-B", FSB1PY, "check", "--exp", "stage3a", "--nonce", "17449af173f0633a", "--chal",
                            "4e0addd83954321379838d2fb769fb9a", "--steps", "hash,pattern", cap], capture_output=True, text=True)
        res("b-trial-iii-capture-still-rejected", r.returncode == 1 and r.stdout.startswith("REJECT line-count"), r.stdout.strip()[:160])
        out_lines.append("TOTAL: %d checks, %d failed" % (sum(1 for l in out_lines if l[:4] in ("PASS", "FAIL")), fails))
        open(outdir + "/RESULTS.txt", "w").write("\n".join(out_lines) + "\n")
        print(out_lines[-1])
    finally:
        shutil.rmtree(w, ignore_errors=True)
    sys.exit(1 if fails else 0)


main()
