#!/usr/bin/env python3
"""FrameShift K1g — re-derive the runner's bounds from k1g/fs-k1g.sh (offline; adapted copy of
k1a/tools/check-bounds-k1a.py, not edited).

    check-bounds-k1g.py [fs-k1g.sh] [init.sh]

From the runner's step specs (the `for spec in id:t:cap ...` line, grace 1 s each) and its constants it checks:
  - the steps are exactly kernel,config,mem,modules,kmsg,fs,usb,log,blkguard and fs-supervise's compiled limits hold
    (t <= 60, cap <= 1 MiB);
  - MAXLINES = 1 BEGIN + 9 STEP + 1 END + both streams of every step at its cap, 48 bytes per DATA line;
  - RUNNER_WORST >= sum(t + g + 7.5) (fs-supervise's worst case: TERM, KILL after g, give-up 3 s, exec-report
    0.5 s, stray hunt 3 s, drain 1 s; review MINOR-5) + the emission (ceil(MAXLINES / 20) pauses of 0.1 s plus up to
    2 s for the writes, rounded up) + 2 s;
  - the time rule is in the runner, and RUNNER_WORST < DEADLINE - 60 leaves the host time for verify/ack/status;
  - init.sh's DEADLINE 200, ACK_WINDOW 150 (unchanged from stage 3d);
  - the probe's own time budget (tools/blkguard/probe/fsbg-probe.c, README s.5): the per-row bound on the unit, the
    before-hash pass budget PRE_BUDGET, and that two passes plus the cases' allowance fit fs-supervise's -t;
  - the start-time arithmetic: the probe's worst case in PID 1, the device start limit and the host start limit.
Exit 0 when all hold.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
runner = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "fs-k1g.sh")
init = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "init.sh")
src = open(runner).read()
ini = open(init).read()
probe = os.path.join(HERE, "..", "..", "..", "..", "tools", "blkguard", "probe", "fsbg-probe.c")
psrc = open(probe).read()
ok = True


def chk(label, cond, detail=""):
    global ok
    ok &= bool(cond)
    print("%s  %s%s" % ("PASS" if cond else "FAIL", label, ("  [" + detail + "]") if detail else ""))


m = re.search(r"^for spec in ([a-z0-9_: ]+); do$", src, re.M)
specs = [tuple(x.split(":")) for x in m.group(1).split()] if m else []
ids = [s[0] for s in specs]
chk("steps = kernel,config,mem,modules,kmsg,fs,usb,log,blkguard", ids == ["kernel", "config", "mem", "modules", "kmsg", "fs", "usb", "log", "blkguard"], ",".join(ids))
g = 1 if re.search(r'\$SUP -t "\$t" -g 1 -c "\$cap"', src) else None
chk("every step runs under fs-supervise with grace 1 s", g == 1)
ts = [int(s[1]) for s in specs]
caps = [int(s[2]) for s in specs]
chk("fs-supervise limits: t <= 60, cap <= 1 MiB", all(0 < t <= 60 for t in ts) and all(0 < c <= 1048576 for c in caps), "t=%s cap=%s" % (ts, caps))
data = sum(math.ceil(c / 48) for c in caps)
maxlines = 11 + 2 * data
got_ml = int(re.search(r"^MAXLINES=(\d+)$", src, re.M).group(1))
chk("MAXLINES = 11 + 2 x %d = %d" % (data, maxlines), got_ml == maxlines, "runner has %d" % got_ml)
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
chk("init.sh DEADLINE 200, ACK_WINDOW 150 (stage 3d values)", dl == 200 and aw == 150, "%d/%d" % (dl, aw))
chk("init.sh writes /run/fs.deadline = T0 + DEADLINE", "echo $((T0 + FS_DEADLINE)) > /run/fs.deadline" in ini)
chk("RUNNER_WORST fits the deadline with room for the host steps (< DEADLINE - 60)", got_w < dl - 60, "%d" % got_w)
m2 = re.search(r"^/bin/fs-supervise -t (\d+) -g (\d+) -c (\d+) -o /run/fsbg.out -r /run/fsbg.err -- /bin/fsbg-probe --compact --nonce=\"\$NONCE\" > /run/fsbg.sup 2>/dev/null$", ini, re.M)
chk("init.sh runs the probe once under fs-supervise (t <= 60, cap <= 1 MiB)", m2 is not None and int(m2.group(1)) <= 60 and int(m2.group(3)) <= 1048576,
    "t=%s g=%s cap=%s" % (m2.groups() if m2 else ("?", "?", "?")))
if m2:
    pw = int(m2.group(1)) + int(m2.group(2)) + 7.5
    print("INFO  the probe's worst case in PID 1 (before SHELL_READY): %.1f s; the runner must start by T0 + %d" % (pw, dl - got_w))
    # the probe's time budget (README s.5)
    pb = re.search(r"^static double t_start, pre_budget = ([0-9.]+);", psrc, re.M)
    ae = re.search(r"^#define AFTER_END ([0-9.]+)$", psrc, re.M)
    rl = re.search(r"return left < ([0-9]+) \? \(int\)left : ([0-9]+);", psrc)
    CASES = 3.0     # the cases, the latch, the arming and the seal test after the before-pass (allowance; [C] on the unit)
    KILL = 5.0      # a row's KILL comes 5 s after its TERM (hash_node)
    chk("the probe's time budget is set (PRE_BUDGET, AFTER_END, the per-row cap)", pb is not None and ae is not None and rl is not None,
        "pre_budget=%s after_end=%s row cap=%s" % (pb.group(1) if pb else "?", ae.group(1) if ae else "?", rl.group(2) if rl else "?"))
    if pb and ae and rl:
        pre, aend, row, t = float(pb.group(1)), float(ae.group(1)), int(rl.group(2)), int(m2.group(1))
        chk("a row is bounded by the time left in its pass, at most %d s (+%.0f s KILL)" % (row, KILL), row <= 10 and rl.group(1) == rl.group(2), "")
        chk("before-pass + cases + after-pass (about the before-pass again) end by AFTER_END: 2 x %.0f + %.0f = %.0f <= %.0f" % (pre, CASES, 2 * pre + CASES, aend),
            2 * pre + CASES <= aend, "")
        chk("AFTER_END + a row's KILL fits fs-supervise's -t %d: %.0f + %.0f <= %d" % (t, aend, KILL, t), aend + KILL <= t, "")
        chk("no after-row starts with less than 1 s left before AFTER_END (its bound <= the time left, so it ends by AFTER_END + KILL)",
            "AFTER_END - (now_s() - t_start) < 1.0" in psrc, "")
    host = dl - 15 - got_w - 5
    print("INFO  start limits: device T0 + %d (deadline %d - RUNNER_WORST %d); host BootStartUtc + %d (deadline - 15 s give-up - %d - 5 s margin)" % (dl - got_w, dl, got_w, host, got_w))
print("RESULT %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
