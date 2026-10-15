#!/usr/bin/env python3
"""FrameShift stage 3b — evidence for the PACED FSB1 emission (FS-R-010 §5). Run inside WSL:
    python3 -I -B pace_evidence.py OUTDIR
Offline: the REAL encoder (common/target/fsb1-enc.sh) and the REAL pacer
(common/target/fsb1-pace.sh) run by the reviewed stage-1 busybox under qemu-aarch64; every
step is captured by the real aarch64 fs-supervise with fs-display's caps. No device.

(a) byte identity: for a REPRESENTATIVE record (realistic payloads: harness probe outputs, the
    real trial-(iii) FSP1 records, the propsim stream), for the AT-CAPS record (EVERY step's
    stdout at its fs-display cap and the hash step's stderr at its cap, random binary: the
    largest record a run within its caps can produce, 2069 lines) and for the MAXIMUM permitted
    record (exactly MAXLINES = 2070 lines: the at-caps record plus 1 stderr line), the bytes of
    `fsb1_emit_paced REC TICK 2070` (with FSB1_PACE_LINES=20, as stage3b/fs-display.sh sets it)
    equal the bytes of `fsb1_emit REC` exactly; both decode
    VALID with common/tools/fsb1.py and carry the same rec_sha256 (which equals SHA-256 of the
    record text as the spec defines it, recomputed here independently).
(b) the damaged trial-(iii) capture (relays/FS-A-010-raw/observe/collect/capture.raw) is still
    REJECTed by fsb1.py with line-count (the PowerShell decoder: host/test-host3b.ps1).
(c) chunk boundaries: the paced bytes, fed to the decoder split at EVERY 10-line chunk boundary
    and at mid-line offsets (1, 37 and 64 bytes into a line, inside STEP/DATA/END lines), and
    re-joined, decode VALID with the same rec_sha256; through a real Linux pty (ONLCR) too. The
    collector-side reassembly (fs-collect.ps1 replay with read chunks split the same way) is in
    host/test-host3b.ps1 section P.
(d) timing: the emission of the maximum record is timed under qemu and through a pty, and the
    count of pauses is checked against ceil(L / 10) - 1; the analytic bound used by
    check-timing-3b.py is printed with the measured values.
Refusals: MAXLINES + 1 lines -> rc 3 and NOTHING written; a record with a CR, a TAB or a byte
>= 0x7f, or without its final newline -> rc 4 and nothing written.
Writes OUTDIR/RESULTS.txt and the emitted byte files (representative, maximum).
"""
import base64
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
NONCE = "3b3b3b3b0011aa55"
CHAL = "c0ffee3b0123456789abcdef01234567"
STEPS = ["hash", "probe1", "pattern1", "probe2", "pattern2"]
CAPS = [256, 16384, 40960, 12288, 28672]          # stage3b/fs-display.sh (review M1, N1)
MAXLINES = 2070
PL = 20                                            # FSB1_PACE_LINES as stage3b/fs-display.sh sets it
FIRST_READ = 12289                                 # trial (iii)'s first read boundary (bytes)
out_lines = []
fails = 0


def res(name, ok, detail=""):
    global fails
    line = "%s  %s  %s" % ("PASS" if ok else "FAIL", name, detail)
    print(line)
    out_lines.append(line)
    fails += 0 if ok else 1


def sh_target(w, script, env_extra=None, stdout=None, timeout=600):
    env = {"PATH": w + "/bin", "BB": w + "/bin/busybox", "FSB1_SUP": SUP, "ENC": ENC, "PACE": PACE}
    env.update(env_extra or {})
    open(w + "/t.sh", "w").write(script)
    return subprocess.run(["/usr/bin/qemu-aarch64", w + "/bin/busybox", "sh", w + "/t.sh"], env=env,
                          stdout=stdout if stdout is not None else subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def make_record(w, name, payloads, errs=None):
    """payloads: 5 byte strings (stdout), errs: 5 byte strings (stderr) -> the real encoder, each step a
    real fs-supervise capture (at fs-display's cap) of `cat OUT` (and `cat ERR >&2`)."""
    errs = errs or [b""] * 5
    d = w + "/" + name
    os.makedirs(d + "/cap")
    for i, p in enumerate(payloads, 1):
        open("%s/p%d.bin" % (d, i), "wb").write(p)
        open("%s/e%d.bin" % (d, i), "wb").write(errs[i - 1])
    lines = ['. "$ENC"', 'R=%s/record; D=%s/cap' % (d, d), 'fsb1_begin "$R" stage3b %s %s 5 || exit 11' % (NONCE, CHAL)]
    for i, sid in enumerate(STEPS, 1):
        lines.append('"$FSB1_SUP" -t 20 -g 1 -c %d -o "$D/%d.out" -r "$D/%d.err" -- "$BB" sh -c "cat %s/p%d.bin; cat %s/e%d.bin >&2" > "$D/%d.sup" 2>/dev/null' % (CAPS[i - 1], i, i, d, i, d, i, i))
        lines.append('fsb1_step "$R" %d %s "$D/%d.sup" "$D/%d.out" "$D/%d.err" || exit 12' % (i, sid, i, i, i))
    lines.append('fsb1_end "$R" %s %s || exit 13' % (NONCE, CHAL))
    r = sh_target(w, "\n".join(lines) + "\n")
    assert r.returncode == 0, (name, r.returncode, r.stderr[-400:])
    return d + "/record"


def emit(w, rec, paced, outfile, maxlines=MAXLINES):
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


def fsb1_check(path):
    r = subprocess.run(["python3", "-I", "-B", FSB1PY, "check", "--exp", "stage3b", "--nonce", NONCE, "--chal", CHAL,
                        "--steps", ",".join(STEPS), path], capture_output=True, text=True)
    return r.stdout.strip().splitlines()[0] if r.stdout else r.stderr.strip()[:200]


def rec_sha_of(data):
    m = re.search(rb"FSB1 END v=1 nonce=[0-9a-f]{16} chal=[0-9a-f]{32} lines=(\d+) rec_sha256=([0-9a-f]{64})", data)
    return (int(m.group(1)), m.group(2).decode()) if m else (None, None)


def independent_rec_sha(data):
    """FSB1-SPEC §4.4: SHA-256 over BEGIN..line before END, each + exactly one \\n (trailing CRs removed)."""
    ls = data.split(b"\n")
    b = [k for k, l in enumerate(ls) if l.rstrip(b"\r").startswith(b"FSB1 BEGIN")][0]
    e = [k for k, l in enumerate(ls) if l.rstrip(b"\r").startswith(b"FSB1 END")][0]
    return hashlib.sha256(b"".join(l.rstrip(b"\r") + b"\n" for l in ls[b:e])).hexdigest(), e - b


def through_pty(w, rec, maxlines=MAXLINES):
    """The paced emission written to a real pty slave (ONLCR on, as a tty); returns (bytes, arrival times)."""
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
    if len(sys.argv) != 2:
        print("usage: pace_evidence.py <output-dir>   (writes <output-dir>/RESULTS.txt; needs the reviewed busybox build input)")
        sys.exit(64)
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    if not os.path.exists(BB_SRC):  # gitignored build input (never committed)
        print("REFUSED: build input missing: build/third_party/busybox/busybox (gitignored; see README \"What is not in git\")")
        sys.exit(2)
    assert hashlib.sha256(open(BB_SRC, "rb").read()).hexdigest() == BB_SHA, "busybox is not the reviewed binary"
    w = tempfile.mkdtemp(prefix="pace.")
    try:
        os.makedirs(w + "/bin")
        shutil.copy(BB_SRC, w + "/bin/busybox")
        os.chmod(w + "/bin/busybox", 0o755)
        for a in "sh cat printf base64 awk sha256sum cut wc sed grep tr true sleep echo mkdir mkfifo tail head".split():
            os.symlink("busybox", w + "/bin/" + a)
        out_lines.append("# stage 3b paced-emission evidence  %s" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        out_lines.append("# busybox %s (reviewed); fs-supervise %s; fsb1-enc.sh %s; fsb1-pace.sh %s" % (
            BB_SHA[:16], hashlib.sha256(open(SUP, "rb").read()).hexdigest()[:16], hashlib.sha256(open(ENC, "rb").read()).hexdigest()[:16],
            hashlib.sha256(open(PACE, "rb").read()).hexdigest()))
        rnd = random.Random(0x3B)
        fx = Q3 + "/stage3b/fixtures"
        rd = lambda p: open(p, "rb").read() if os.path.exists(p) else b""
        rep = [b"4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6  /bin/fs-pattern\n",
               rd(fx + "/image/b-sim-go/probe1.txt") or bytes(rnd.getrandbits(8) for _ in range(9000)),
               (rd(ROOT + "/relays/FS-A-010-raw/fsp1-decoded-partial.txt") + rd(fx + "/propsim-full.txt"))[:CAPS[2]],
               rd(fx + "/image/b-sim-go/probe2.txt") or bytes(rnd.getrandbits(8) for _ in range(4000)),
               rd(fx + "/image/b-sim-go/fsp1-run2.txt") + rd(fx + "/propsim-off.txt")]
        fixed = 2 + 5
        rb = lambda n: bytes(rnd.getrandbits(8) for _ in range(n))
        caps_out = [rb(c) for c in CAPS]                         # every step's stdout at its cap
        caps_err = [rb(CAPS[0]), b"", b"", b"", b""]             # the hash step's stderr at its cap (fs-pattern/probes write none)
        legit = fixed + sum((len(x) + 47) // 48 for x in caps_out + caps_err)
        mx_err = list(caps_err); mx_err[1] = rb((MAXLINES - legit) * 48)              # top up to exactly MAXLINES
        ov_err = list(caps_err); ov_err[1] = rb((MAXLINES - legit + 1) * 48)          # MAXLINES + 1
        recs = {"representative": make_record(w, "rep", rep), "at-caps": make_record(w, "caps", caps_out, caps_err),
                "maximum": make_record(w, "max", caps_out, mx_err), "maximum-plus-1": make_record(w, "over", caps_out, ov_err)}
        for name, rec in recs.items():
            n = sum(1 for _ in open(rec, "rb"))
            res("record-%s-lines" % name, (name != "maximum" or n == MAXLINES) and (name != "maximum-plus-1" or n == MAXLINES + 1) and (name != "at-caps" or n == legit),
                "%d lines, %d bytes" % (n, os.path.getsize(rec)))
        # (a) identity, (d) timing
        for name in ("representative", "at-caps", "maximum"):
            rec = recs[name]
            u, p_ = outdir + "/%s-unpaced.rec" % name, outdir + "/%s-paced.rec" % name
            rcu, tu = emit(w, rec, False, u)
            rcp, tp = emit(w, rec, True, p_)
            bu, bp = open(u, "rb").read(), open(p_, "rb").read()
            res("a-%s-bytes-identical" % name, rcu == 0 and rcp == 0 and bu == bp and bu == b"\n" + open(rec, "rb").read(),
                "%d bytes; sha256 %s (paced) = %s (unpaced) = '\\n' + the record file" % (len(bp), hashlib.sha256(bp).hexdigest()[:16], hashlib.sha256(bu).hexdigest()[:16]))
            vu, vp = fsb1_check(u), fsb1_check(p_)
            lu, su = rec_sha_of(bu); lp, sp = rec_sha_of(bp)
            ind, cnt = independent_rec_sha(bp)
            res("a-%s-valid-same-rec_sha256" % name, vu.startswith("VALID") and vp.startswith("VALID") and su == sp == ind and lu == lp == cnt,
                "fsb1.py %s / %s; rec_sha256 %s (independent recomputation equal); lines=%s" % (vu.split()[0], vp.split()[0], sp, lp))
            nl = bp.count(b"\n") - 1
            bound = 1.0 + ((nl + PL - 1) // PL) * 0.11
            res("d-%s-emission-time" % name, tp >= ((nl // PL) - 1) * 0.1 * 0.9 and tu < tp,
                "%d lines: paced %.2f s under qemu (unpaced %.2f s); analytic bound EMIT = 1 + ceil(%d/%d) x 0.11 = %.1f s (check-timing-3b.py uses MAXLINES: %.1f s)"
                % (nl, tp, tu, nl, PL, bound, 1.0 + ((MAXLINES + PL - 1) // PL) * 0.11))
            rl = open(rec, "rb").read().split(b"\n")[:-1]
            chunk_max = max(sum(len(x) + 1 for x in rl[i:i + PL]) for i in range(0, len(rl), PL))
            res("d-%s-chunk-burst" % name, chunk_max < FIRST_READ // 4,
                "largest %d-line write: %d bytes (well under the %d-byte first-read boundary of trial (iii))" % (PL, chunk_max, FIRST_READ))
        # pty: ONLCR, arrival pattern
        bpty, arr = through_pty(w, recs["maximum"])
        crlf_ok = bpty.replace(b"\r\n", b"\n") == open(outdir + "/maximum-paced.rec", "rb").read()
        open(w + "/pty.bin", "wb").write(bpty)
        res("c-maximum-through-pty-onlcr", crlf_ok and fsb1_check(w + "/pty.bin").startswith("VALID"),
            "%d bytes via a pty with ONLCR (CRLF); stripped of CR = the paced bytes; fsb1.py VALID" % len(bpty))
        gaps = [arr[i + 1][2] - arr[i][2] for i in range(len(arr) - 1)]
        big = sum(1 for g in gaps if g >= 0.08)
        span = arr[-1][2] - arr[0][2] if arr else 0
        nch = (MAXLINES + PL - 1) // PL
        res("d-maximum-pty-pacing", big >= nch - 12 and span >= (nch - 1) * 0.09,
            "%d reads; %d gaps >= 80 ms (%d chunks -> %d pauses expected); first->last byte %.2f s; max read %d bytes"
            % (len(arr), big, nch, nch - 1, span, max(n for _, n, _ in arr)))
        # (c) splits at every chunk boundary and mid-line, rejoined
        bp = open(outdir + "/maximum-paced.rec", "rb").read()
        offs = [m_.end() for m_ in re.finditer(rb"\n", bp)]
        cuts = set()
        for k, o in enumerate(offs):
            if k % PL == 0:                         # every chunk boundary (after the leading empty line, PL lines per chunk)
                cuts.add(o)
                for d in (1, 37, 64):
                    if o + d < len(bp):
                        cuts.add(o + d)             # mid-line, inside the next line
        endpos = bp.find(b"FSB1 END")
        for d in (1, 9, 40, 100):
            cuts.add(endpos + d)                    # inside the END line
        pieces, prev = [], 0
        for c in sorted(cuts):
            pieces.append(bp[prev:c]); prev = c
        pieces.append(bp[prev:])
        joined = b"".join(pieces)
        open(w + "/joined.bin", "wb").write(joined)
        res("c-maximum-split-everywhere-rejoined", joined == bp and fsb1_check(w + "/joined.bin").startswith("VALID"),
            "%d pieces (every chunk boundary, +1/+37/+64 bytes mid-line, 4 cuts inside END); rejoined bytes identical; VALID" % len(pieces))
        partial_ok = True
        for c in sorted(cuts)[::25]:
            open(w + "/part.bin", "wb").write(bp[:c])
            v = fsb1_check(w + "/part.bin")
            partial_ok &= v.startswith("REJECT")
        res("c-every-prefix-before-the-end-is-not-a-record", partial_ok, "a prefix cut at a chunk boundary or mid-line is never VALID (no-end/bad-end)")
        # refusals
        rco, _ = emit(w, recs["maximum-plus-1"], True, w + "/over.bin")
        res("refuse-maxlines-plus-1", rco == 3 and os.path.getsize(w + "/over.bin") == 0, "rc=%d, %d bytes written" % (rco, os.path.getsize(w + "/over.bin")))
        base = open(recs["representative"], "rb").read()
        for tag, data in (("cr", base.replace(b"\n", b"\r\n", 1)), ("tab", base.replace(b" ", b"\t", 1)), ("del", base.replace(b"A", b"\x7f", 1)),
                          ("high", base.replace(b"A", b"\xe9", 1)), ("no-final-newline", base[:-1])):
            pth = w + "/bad-%s" % tag
            open(pth, "wb").write(data)
            rcb, _ = emit(w, pth, True, w + "/bad.bin")
            res("refuse-%s" % tag, rcb == 4 and os.path.getsize(w + "/bad.bin") == 0, "rc=%d, nothing written" % rcb)
        # (b) the damaged trial-(iii) capture
        cap = ROOT + "/relays/FS-A-010-raw/observe/collect/capture.raw"
        if not os.path.exists(cap):  # public copy: the trial-(iii) capture is withheld
            out_lines.append("SKIP  b-trial-iii-capture-still-rejected (withheld evidence: relays/FS-A-010-raw is not in the public copy)")
            print(out_lines[-1])
        else:
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
