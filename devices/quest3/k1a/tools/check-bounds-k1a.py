#!/usr/bin/env python3
"""FrameShift K1a — re-derive the runner's bounds from k1a/fs-k1a.sh (offline; stage3b's check-timing idea).

    check-bounds-k1a.py [fs-k1a.sh] [init.sh]

From the runner's step specs (the `for spec in id:t:cap ...` line, grace 1 s each) and its constants it checks:
  - the steps are exactly kernel,config,mem,modules,kmsg,fs,usb,log and fs-supervise's compiled limits hold
    (t <= 60, cap <= 1 MiB);
  - MAXLINES = 1 BEGIN + 8 STEP + 1 END + both streams of every step at its cap, 48 bytes per DATA line;
  - RUNNER_WORST >= sum(t + g + 7.5) (fs-supervise's worst case: TERM, KILL after g, give-up 3 s, exec-report
    0.5 s, stray hunt 3 s, drain 1 s; review MINOR-5) + the emission (ceil(MAXLINES / 20) pauses of 0.1 s plus up to
    2 s for the writes, rounded up) + 2 s;
  - the time rule is in the runner, and RUNNER_WORST < DEADLINE - 60 leaves the host time for verify/ack/status;
  - init.sh's DEADLINE 200, ACK_WINDOW 150 (unchanged from stage 3d).
Exit 0 when all hold.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
runner = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "fs-k1a.sh")
init = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "init.sh")
src = open(runner).read()
ini = open(init).read()
ok = True


def chk(label, cond, detail=""):
    global ok
    ok &= bool(cond)
    print("%s  %s%s" % ("PASS" if cond else "FAIL", label, ("  [" + detail + "]") if detail else ""))


m = re.search(r"^for spec in ([a-z0-9_: ]+); do$", src, re.M)
specs = [tuple(x.split(":")) for x in m.group(1).split()] if m else []
ids = [s[0] for s in specs]
chk("steps = kernel,config,mem,modules,kmsg,fs,usb,log", ids == ["kernel", "config", "mem", "modules", "kmsg", "fs", "usb", "log"], ",".join(ids))
g = 1 if re.search(r'\$SUP -t "\$t" -g 1 -c "\$cap"', src) else None
chk("every step runs under fs-supervise with grace 1 s", g == 1)
ts = [int(s[1]) for s in specs]
caps = [int(s[2]) for s in specs]
chk("fs-supervise limits: t <= 60, cap <= 1 MiB", all(0 < t <= 60 for t in ts) and all(0 < c <= 1048576 for c in caps), "t=%s cap=%s" % (ts, caps))
data = sum(math.ceil(c / 48) for c in caps)
maxlines = 10 + 2 * data
got_ml = int(re.search(r"^MAXLINES=(\d+)$", src, re.M).group(1))
chk("MAXLINES = 10 + 2 x %d = %d" % (data, maxlines), got_ml == maxlines, "runner has %d" % got_ml)
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
print("RESULT %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
