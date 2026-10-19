#!/usr/bin/env python3
"""FrameShift N1 — re-derive the runner's and the responder's bounds from the sources (offline; k1a/tools/check-bounds-k1a.py's
method, extended for fs-xfer and the NCM guard).

    check-bounds-n1.py [fs-n1.sh] [init.sh] [fs-xfer.c] [fs-n1-info.sh]

Checks:
  - the steps are exactly kernel,mem,modules,net,xfer,log, each under fs-supervise with grace 1 s, within its compiled
    limits (t <= 60, cap <= 1 MiB);
  - MAXLINES = 1 BEGIN + 6 STEP + 1 END + both streams of every step at its cap, 48 bytes per DATA line;
  - RUNNER_WORST >= sum(t + g + 7.5) + the emission (ceil(MAXLINES / 20) pauses of 0.1 s, plus up to 2 s for the
    writes, rounded up) + 2 s; the time rule is in the runner; RUNNER_WORST < DEADLINE - 60;
  - fs-xfer: LISTEN_MS + SESSION_MS + DRAIN_MS < BACKSTOP_S * 1000 < the xfer step's t * 1000, HEADER_MS <= SESSION_MS;
    the runner passes port 47201 and init.sh's NCM_PORT is 47201. The 23 s sum is fs-xfer's DESIGN budget, not a hard
    maximum (FS-R-014 s.5): its phase deadlines are tested only when it waits (poll after EAGAIN), not while data keeps
    flowing, while it hashes or computes the stream, or while it writes its report lines. The HARD bounds are its
    alarm (SIGALRM at BACKSTOP_S) and fs-supervise (TERM at t, KILL g later); RUNNER_WORST counts the xfer step at
    t + g + 7.5 like every step, so no fs-xfer timing assumption enters it;
  - the post-transfer kernel-log check (FS-R-014 s.5): fs-n1-info.sh's log role runs kmsg_post FIRST, kmsg_post ends
    with its end marker, reads the kernel log once (one dmesg, one awk) and lists at most W lines of 200 bytes and U
    of 160 bytes; that worst case is at most half of the log step's cap (the later sections keep room);
  - init.sh: DEADLINE 200, ACK_WINDOW 150 (as K1a), NCM_GUARD_S 30 < ACK_WINDOW; the device runner start limit
    T0 + DEADLINE - RUNNER_WORST and the host's (BootStartUtc + DEADLINE - 15 - RUNNER_WORST - 5).
Exit 0 when all hold.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
runner = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "fs-n1.sh")
init = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "init.sh")
xsrc = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, "..", "src", "fs-xfer.c")
info = sys.argv[4] if len(sys.argv) > 4 else os.path.join(HERE, "..", "fs-n1-info.sh")
src = open(runner).read()
inf = open(info).read()
ini = open(init).read()
xs = open(xsrc).read()
ok = True


def chk(label, cond, detail=""):
    global ok
    ok &= bool(cond)
    print("%s  %s%s" % ("PASS" if cond else "FAIL", label, ("  [" + detail + "]") if detail else ""))


def define(name):
    m = re.search(r"^#define %s\s+(\d+)u?\b" % name, xs, re.M)
    return int(m.group(1)) if m else None


m = re.search(r"^for spec in ([a-z0-9_: ]+); do$", src, re.M)
specs = [tuple(x.split(":")) for x in m.group(1).split()] if m else []
ids = [s[0] for s in specs]
chk("steps = kernel,mem,modules,net,xfer,log", ids == ["kernel", "mem", "modules", "net", "xfer", "log"], ",".join(ids))
sups = re.findall(r'\$SUP -t "\$t" -g 1 -c "\$cap" ', src)
chk("every step runs under fs-supervise with grace 1 s (the three step forms)", len(sups) == 3, "%d forms" % len(sups))
g = 1
ts = [int(s[1]) for s in specs]
caps = [int(s[2]) for s in specs]
chk("fs-supervise limits: t <= 60, cap <= 1 MiB", all(0 < t <= 60 for t in ts) and all(0 < c <= 1048576 for c in caps), "t=%s cap=%s" % (ts, caps))
data = sum(math.ceil(c / 48) for c in caps)
maxlines = 8 + 2 * data
got_ml = int(re.search(r"^MAXLINES=(\d+)$", src, re.M).group(1))
chk("MAXLINES = 8 + 2 x %d = %d" % (data, maxlines), got_ml == maxlines, "runner has %d" % got_ml)
pace = int(re.search(r"^FSB1_PACE_LINES=(\d+)$", src, re.M).group(1))
emit = math.ceil(maxlines / pace) * 0.1
worst_steps = sum(t + g + 7.5 for t in ts)
need = math.ceil(worst_steps + emit + 2) + 2
got_w = int(re.search(r"^RUNNER_WORST=(\d+)$", src, re.M).group(1))
chk("RUNNER_WORST >= steps %.1f + emission %.1f s + 2 s writes, rounded up, + 2 = %d" % (worst_steps, emit, need), got_w >= need, "runner has %d" % got_w)
chk("the time rule is in the runner (now + RUNNER_WORST <= /run/fs.deadline)",
    '[ $((now + RUNNER_WORST)) -le "$dl" ]' in src and "/run/fs.deadline" in src)
dl = int(re.search(r"^DEADLINE=(\d+)$", ini, re.M).group(1))
aw = int(re.search(r"^ACK_WINDOW=(\d+)$", ini, re.M).group(1))
chk("init.sh DEADLINE 200, ACK_WINDOW 150 (the K1a values)", dl == 200 and aw == 150, "%d/%d" % (dl, aw))
chk("init.sh writes /run/fs.deadline = T0 + DEADLINE", "echo $((T0 + FS_DEADLINE)) > /run/fs.deadline" in ini)
chk("RUNNER_WORST fits the deadline with room for the host steps (< DEADLINE - 60)", got_w < dl - 60, "%d" % got_w)
# fs-xfer
L, S, H, D, B = define("LISTEN_MS"), define("SESSION_MS"), define("HEADER_MS"), define("DRAIN_MS"), define("BACKSTOP_S")
xt = dict((s[0], int(s[1])) for s in specs).get("xfer")
chk("fs-xfer: design budget LISTEN_MS + SESSION_MS + DRAIN_MS = %s ms (not a hard maximum: deadlines are tested on waits only) < BACKSTOP_S %s s (SIGALRM, hard) < the xfer step's t %s s (fs-supervise TERM, hard)" % (None if None in (L, S, D) else L + S + D, B, xt),
    None not in (L, S, D, B, xt) and L + S + D < B * 1000 < xt * 1000, "")
chk("fs-xfer: HEADER_MS <= SESSION_MS", None not in (H, S) and H <= S, "%s/%s" % (H, S))
chk("fs-xfer: 8 MiB each way, a multiple of the 32-byte stream block and of the 64 KiB chunk",
    define("H2D_BYTES") == define("D2H_BYTES") == 8388608 and 8388608 % 65536 == 0, "")
chk("the runner passes port 47201 (XFER_PORT) and init.sh's NCM_PORT is 47201",
    re.search(r"^XFER_PORT=47201$", src, re.M) is not None and '-p "$XFER_PORT"' in src and re.search(r"^NCM_PORT=47201$", ini, re.M) is not None)
# the post-transfer kernel-log check (FS-R-014 s.5)
lr = re.search(r"^log\)\n    kmsg_post\n", inf, re.M)
kp = re.search(r"^kmsg_post\(\) \{\n(.*?)^\}\n", inf, re.M | re.S)
kb = kp.group(1) if kp else ""
wu = re.search(r"awk -v W=(\d+) -v U=(\d+) '", kb)
lcap = dict((s[0], int(s[2])) for s in specs).get("log", 0)
kw = None
if wu:
    W, U = int(wu.group(1)), int(wu.group(2))
    # the 9 fixed lines at their longest (every count 15 digits, the 16-byte first/last), W listed lines of 2 + 200 + 1,
    # U of 2 + 160 + 1
    D = 15
    hdr = [len("== kmsg-post read=fail rc=%s bytes=%s\n" % ("9" * D, "9" * D)), len("== kmsg-post-lines %s\n" % ("9" * D)),
           len("== kmsg-post-first %s\n" % ("x" * 16)), len("== kmsg-post-last %s\n" % ("x" * 16)), len("== kmsg-post-modver %s\n" % ("9" * D)),
           len("== kmsg-post-taint %s\n" % ("9" * D)), len("== kmsg-post-warnings %s warning-lines, %s bug-lines, %s lines, %s listed\n" % (("9" * D,) * 4)),
           len("== kmsg-post-ncm %s lines, %s listed\n" % ("9" * D, "9" * D)), len("== kmsg-post-end\n")]
    kw = sum(hdr) + W * 203 + U * 163
chk("the log role runs kmsg_post FIRST; kmsg_post reads the kernel log once (one plain dmesg: no option, never a clear; one awk, no system/getline/pipe) and ends with its end marker",
    bool(lr) and kb.count("dmesg") == 1 and "d=$(dmesg 2>&1)" in kb and kb.count("awk ") == 1 and kb.rstrip().endswith("}'")
    and kb.count('"== kmsg-post-end"') == 2 and not re.search(r"system\(|getline|[^\"]\|\s*\"", kb), "")
chk("kmsg_post at most %s bytes (W x 200, U x 160 and the fixed lines at their longest); the later sections keep r1's 16384 bytes of the log step's cap %d" % (kw, lcap),
    kw is not None and 'substr($0, 1, 200)' in kb and 'substr($0, 1, 160)' in kb and lcap - kw >= 16384, "W=%s U=%s" % (wu.group(1), wu.group(2)) if wu else "")
gs = re.search(r"^NCM_GUARD_S=(\d+)$", ini, re.M)
chk("init.sh NCM_GUARD_S 30 < ACK_WINDOW (the guard acts long before the no-ack reboot)", bool(gs) and int(gs.group(1)) == 30 < aw, gs.group(0) if gs else "")
dev_start = dl - got_w
host_start = dl - 15 - got_w - 5
chk("device runner start limit T0 + %d s; host start limit BootStartUtc + %d s (>= 50 s: stage 3c sent its runner at about +32 s)" % (dev_start, host_start),
    host_start < dev_start and host_start >= 50, "")
print("RESULT %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
