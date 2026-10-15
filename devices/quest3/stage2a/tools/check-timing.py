#!/usr/bin/env python3
"""FrameShift — timing consistency check for the stage-2a and stage-3a images
and the host collector (offline; reads source text only).

SCOPE (Chair ruling FS-R-007 B1). Part 1 checks that CONSTANTS agree with each
other (deadlines, step timeouts, the collector's budgets). It does not show that
the host's clock relationship to the device holds. Part 2 (revision 9) checks
the CLOCK MODEL the host implements, statically and as arithmetic, not on a
device:
  M1 fs-observe.ps1 takes BootStartUtc BEFORE its one `fastboot boot` call;
  M2 fs-observe.ps1 hands the collector -BootStartUtc as the origin (no
     HandoffBasisUtc; Th only as -HandoffUtc evidence);
  M3 fs-collect.ps1's live path derives both host deadlines from BootStartUtc,
     converts them to the transport clock only AFTER Get-FsGadget and the
     transport construction (no remaining time carried over), and re-checks the
     start refusals there;
  M4 arithmetic: with origin O <= T0 and the run-time rule "send the runner only
     if give-up - now >= worst + margin + post", every admitted runner ends by
     T0 + DEADLINE - margin, over a grid of (T0 - O, collector start,
     pre-runner time); the Chair's counterexample is refused with origin O and
     shown admitted (and unsafe) with origin Th.
The guarantee is therefore: the host stops before BootStartUtc + DEADLINE -
margin <= T0 + DEADLINE - margin, assuming the host UTC clock does not jump
between BootStartUtc and the conversion and the transport clock (Stopwatch) is
monotonic afterwards.

    python3 -I check-timing.py [--q3 DIR]      (DIR = devices/quest3 of the tree to check)

For each stage it reads the numbers where they are defined, not copies:
  - the image deadline and ack window: <stage>/init.sh (DEADLINE=, ACK_WINDOW=);
  - every step's fs-supervise timeout and grace: stage2a/fs-valve.sh (fsb1_run
    lines; -t from $T/$TINV or a literal; grace = the fs-supervise default) and
    stage3a/fs-display.sh (fsb1_run, and the direct fs-supervise -t/-g call);
  - fs-supervise's compiled waits: common/src/fs-supervise.c (DEFAULT_GRACE_S,
    REAP_WAIT_MS, STRAY_WAIT_MS, DRAIN_MS, MAX_TIMEOUT_S, MAX_GRACE_S);
  - the collector: host/fs-collect.ps1 (the stage's DeviceDeadlineSec, the
    HostMarginSec, StepTimeoutMs, PromptWaitMs, AckSettleMs, AckStatusTries,
    InitialDrainMs defaults).
Then it requires (host/COLLECTOR.md §4):
  1. the collector's device deadline for the stage equals the image's DEADLINE,
     and DEADLINE <= 299 (common/DEADLINE.md clamp);
  2. ACK_WINDOW <= DEADLINE;
  3. every step timeout <= MAX_TIMEOUT_S and grace <= MAX_GRACE_S;
  4. the runner's worst case W = sum(t + g + reap + strays + drain + 1 s encoding)
     + 2 s emission fits the host's worst-case record budget
     B = DEADLINE - HostMargin - collector start (20 s after the handoff,
     COLLECTOR.md) - the worst case of the phases before the runner;
  5. (fix round 6, e2e S1) the ACK WINDOW: the collector's ack window for the
     stage equals the image's ACK_WINDOW, and the phases before the runner fit
     inside it: collector start + their worst case <= ACK_WINDOW - HostMargin
     (the collector caps them there and refuses to start with < 30 s of it left);
  6. (fix round 7) the collector's run-time guard: its RunnerWorstSec for the stage covers
     the computed W, and B >= RunnerWorstSec + RunnerMarginSec (the collector checks exactly
     that before sending the runner, NIT3).
  Revision 8 (Chair review of FS-A-007, S3, single-operator display protocol): the record
  budget B also deducts the host time that must still fit after the runner is sent and
  before the give-up: the stage-3a display cue (before the runner) and the post-record
  time (beep 1 + the PreDoneMs read-only pause + beep 2). AckStatusTries is per stage
  (2a: 3; 3a: 2), so "phases before the runner" is per stage too.
     B = DEADLINE - HostMargin - collector start - before(stage) - cue - post
Prints one timing table per stage. Exit 0 if every requirement holds, else 1.
"""
import argparse
import os
import re
import sys

COLLECTOR_START_S = 20.0      # COLLECTOR.md §4: planning assumption, collector start about 20 s after BootStartUtc (the run-time guards enforce the real remaining time)
ENCODE_S_PER_STEP = 1.0       # fsb1_step on the device (wc/sha256sum/base64 of small files): margin
EMIT_S = 2.0                  # fsb1_end + fsb1_emit


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def num(rx, text, what):
    m = re.search(rx, text, re.M)
    if not m:
        raise SystemExit("cannot find %s" % what)
    return int(m.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--q3", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    a = ap.parse_args()
    q3 = os.path.abspath(a.q3)
    sup = read(os.path.join(q3, "common/src/fs-supervise.c"))
    g_def = num(r"^#define DEFAULT_GRACE_S\s+(\d+)", sup, "DEFAULT_GRACE_S")
    reap = num(r"^#define REAP_WAIT_MS\s+(\d+)", sup, "REAP_WAIT_MS") / 1000
    stray = num(r"^#define STRAY_WAIT_MS\s+(\d+)", sup, "STRAY_WAIT_MS") / 1000
    drain = num(r"^#define DRAIN_MS\s+(\d+)", sup, "DRAIN_MS") / 1000
    tmax = num(r"^#define MAX_TIMEOUT_S\s+(\d+)", sup, "MAX_TIMEOUT_S")
    gmax = num(r"^#define MAX_GRACE_S\s+(\d+)", sup, "MAX_GRACE_S")
    col = read(os.path.join(q3, "host/fs-collect.ps1"))
    margin = num(r"\[int\]\$HostMarginSec = (\d+)", col, "HostMarginSec")
    step_to = num(r"\[int\]\$StepTimeoutMs = (\d+)", col, "StepTimeoutMs") / 1000
    pwait = num(r"\[int\]\$PromptWaitMs = (\d+)", col, "PromptWaitMs") / 1000
    settle = num(r"\[int\]\$AckSettleMs = (\d+)", col, "AckSettleMs") / 1000
    m = re.search(r"\[int\]\$AckStatusTries = (\d+)", col)
    tries_global = int(m.group(1)) if m else None   # revision 8: -1 = per-stage default
    drain0 = num(r"\[int\]\$InitialDrainMs = (\d+)", col, "InitialDrainMs") / 1000
    spec, aspec, extra = {}, {}, {}
    for st, body in re.findall(r"'(2a|3a)' = @\{([^}]*)\}", col):
        m = re.search(r"DeviceDeadlineSec = (\d+)", body)
        spec[st] = int(m.group(1)) if m else None
        m = re.search(r"AckWindowSec = (\d+)", body)
        aspec[st] = int(m.group(1)) if m else None
        for key in ("RunnerWorstSec", "RunnerMarginSec", "DisplayCueMs", "AckStatusTries", "PreDoneMs", "Beep1Ms", "Beep2Ms"):
            m = re.search(key + r" = (\d+)", body)
            extra.setdefault(st, {})[key] = int(m.group(1)) if m else None
    if not spec:   # a collector without per-stage specs: one deadline for every stage
        d = num(r"\[int\]\$DeviceDeadlineSec = (\d+)", col, "DeviceDeadlineSec")
        spec = {"2a": d, "3a": d}
    def before_for(st):
        t = extra.get(st, {}).get("AckStatusTries") or tries_global
        if t is None:
            raise SystemExit("cannot find AckStatusTries for stage %s" % st)
        return t, (drain0 + pwait) + 2 * (step_to + pwait) + t * (settle + step_to + pwait)

    ok_all = True
    for stage, runner in (("2a", "fs-valve.sh"), ("3a", "fs-display.sh")):
        init = read(os.path.join(q3, "stage%s/init.sh" % stage))
        dl = num(r"^DEADLINE=(\d+)$", init, "DEADLINE")
        aw = num(r"^ACK_WINDOW=(\d+)$", init, "ACK_WINDOW")
        rs = read(os.path.join(q3, "stage%s/%s" % (stage, runner)))
        var = {k: int(v) for k, v in re.findall(r"^([A-Z]+)=(\d+)$", rs, re.M)}
        steps = []
        for i, sid, t in re.findall(r'^fsb1_run "\$REC" (\d+) (\w+)\s+"\$D" (\$\w+|\d+)', rs, re.M):
            tv = var[t[1:]] if t.startswith("$") else int(t)
            steps.append((int(i), sid, tv, g_def))
        for t, g in re.findall(r"^/bin/fs-supervise -t (\d+) -g (\d+) ", rs, re.M):
            steps.append((len(steps) + 1, "pattern", int(t), int(g)))
        steps.sort()
        rows, w = [], 0.0
        for i, sid, t, g in steps:
            worst = t + g + reap + stray + drain + ENCODE_S_PER_STEP
            w += worst
            rows.append((i, sid, t, g, worst))
        w += EMIT_S
        dev = spec.get(stage)
        tries, before = before_for(stage)
        caw = aspec.get(stage)
        ex = extra.get(stage, {})
        rws, rms, cue = ex.get("RunnerWorstSec"), ex.get("RunnerMarginSec"), ex.get("DisplayCueMs")
        post = ((ex.get("PreDoneMs") or 0) + (ex.get("Beep1Ms") or 0) + (ex.get("Beep2Ms") or 0)) / 1000
        budget = (dev if dev else 0) - margin - COLLECTOR_START_S - before - (cue or 0) / 1000 - post
        ack_budget = (caw if caw else 0) - margin - COLLECTOR_START_S
        checks = [
            ("collector device deadline (%s s) = image DEADLINE (%d s)" % (dev, dl), dev == dl),
            ("DEADLINE %d <= 299 (common clamp)" % dl, dl <= 299),
            ("ACK_WINDOW %d <= DEADLINE %d" % (aw, dl), aw <= dl),
            ("every step timeout <= %d s and grace <= %d s" % (tmax, gmax), all(t <= tmax and g <= gmax for _, _, t, g, _ in rows)),
            ("runner worst case %.1f s <= host record budget %.1f s" % (w, budget), w <= budget),
            ("collector RunnerWorstSec (%s s) >= computed W (%.1f s)" % (rws, w), rws is not None and rws >= w),
            ("run-time guard fits: B %.1f s >= RunnerWorstSec + RunnerMarginSec = %s s" % (budget, (rws or 0) + (rms or 0)),
             rws is not None and rms is not None and budget >= rws + rms),
            ("collector ack window (%s s) = image ACK_WINDOW (%d s)" % (caw, aw), caw == aw),
            ("phases before the runner %.1f s <= ack-window budget %s - %d - %.0f = %.1f s" % (before, caw, margin, COLLECTOR_START_S, ack_budget), before <= ack_budget),
        ]
        print("== stage %s (init.sh DEADLINE=%d ACK_WINDOW=%d; runner %s)" % (stage, dl, aw, runner))
        print("   %-3s %-8s %5s %5s %9s" % ("i", "id", "-t", "-g", "worst s"))
        for i, sid, t, g, worst in rows:
            print("   %-3d %-8s %5d %5d %9.1f" % (i, sid, t, g, worst))
        print("   runner worst case W = %.1f s (incl. %.0f s emission)" % (w, EMIT_S))
        print("   host: give-up = BootStartUtc + %s - %d s; collector start = BootStartUtc + %.0f s (planning); phases before the runner (%d fs-status tries) <= %.1f s"
              % (dev, margin, COLLECTOR_START_S, tries, before))
        print("   display cue before the runner: %.1f s; post-record host time (beep 1 + pre-done pause + beep 2): %.1f s"
              % ((cue or 0) / 1000, post))
        print("   host record budget B = %s - %d - %.0f - %.1f - %.1f - %.1f = %.1f s; spare (B - W) %.1f s; guard spare (B - RunnerWorst - margin) %.1f s"
              % (dev, margin, COLLECTOR_START_S, before, (cue or 0) / 1000, post, budget, budget - w, budget - (rws or 0) - (rms or 0)))
        for label, ok in checks:
            print("   %s  %s" % ("PASS" if ok else "FAIL", label))
            ok_all &= ok
    ok_all &= clock_model(q3, spec, extra, margin)
    print("TIMING: %s" % ("CONSISTENT" if ok_all else "INCONSISTENT"))
    return 0 if ok_all else 1


def clock_model(q3, spec, extra, margin):
    """Part 2 (FS-R-007 B1): the clock model the host implements. Static source checks plus arithmetic."""
    obs = read(os.path.join(q3, "host/fs-observe.ps1"))
    col = read(os.path.join(q3, "host/fs-collect.ps1"))
    cli = col[col.find("# ------------------------------------------------------------------ CLI -----"):]
    live = cli[cli.find("} else {"):]

    def at(text, needle):
        i = text.find(needle)
        return i if i >= 0 else None

    i_start = at(obs, "$o.BootStartUtc = (& $NowUtc)")
    m = re.search(r"& \$Fastboot @\('-s', \$Serial, 'boot'", obs)
    i_boot = m.start() if m else None
    i_gad = at(live, "Get-FsGadget -Nonce")
    i_tr = at(live, "New-FsRawSerialTransport -PortName")
    i_cv = None
    for mm in re.finditer(r"ConvertTo-FsTransportDeadlines -Deadlines \$dl -NowMs \$nowMs", live):
        i_cv = mm.start()
    i_cfg = at(live, "-GiveUpMs $cv.GiveUpMs")
    checks = [
        ("M1 fs-observe.ps1: BootStartUtc is taken before the one fastboot boot call",
         i_start is not None and i_boot is not None and i_start < i_boot),
        ("M2 fs-observe.ps1: the collector gets -BootStartUtc (origin) in the printed command and in -ThenCollect; no HandoffBasisUtc",
         "-BootStartUtc $($o.BootStartUtc)" in obs and "-BootStartUtc $res.Observe.BootStartUtc" in obs and "HandoffBasisUtc" not in obs),
        ("M3a fs-collect.ps1 live: both deadlines come from BootStartUtc (Get-FsHostDeadlines -OriginUtc $origin, $origin = -BootStartUtc)",
         re.search(r"\$origin = & \$parseU \$BootStartUtc", live) is not None and "Get-FsHostDeadlines -OriginUtc $origin" in live),
        ("M3b fs-collect.ps1 live: the transport-clock conversion follows Get-FsGadget and New-FsRawSerialTransport, and the collector uses it",
         None not in (i_gad, i_tr, i_cv, i_cfg) and i_gad < i_tr < i_cv < i_cfg and "-AckGiveUpMs $cv.AckGiveUpMs" in live),
        ("M3c fs-collect.ps1 live: the start refusals are re-checked after the preparation; no remaining time computed before it is used",
         "Get-FsLiveStartRefusal -RemainMs $cv.RemainMs" in live and "$remainMs" not in live and "$ackRemainMs" not in live),
    ]
    # M4: arithmetic over a grid. Times in seconds from O (BootStartUtc). The runner is admitted at time s
    # only if (O + D - margin) - s >= worst + rmargin + post; it then ends by s + worst + post.
    ok_grid, worst_case = True, None
    for st in ("2a", "3a"):
        d = spec.get(st)
        ex = extra.get(st, {})
        if not d or ex.get("RunnerWorstSec") is None or ex.get("RunnerMarginSec") is None:
            ok_grid = False
            continue
        post = ((ex.get("PreDoneMs") or 0) + (ex.get("Beep1Ms") or 0) + (ex.get("Beep2Ms") or 0)) / 1000
        need = ex["RunnerWorstSec"] + ex["RunnerMarginSec"] + post
        for t0 in (0, 2, 30, 60, 120):
            for start in range(0, 241, 5):
                for pre in range(0, 121, 3):
                    s_ = start + pre
                    give_up = d - margin
                    if give_up - s_ >= need:
                        end = s_ + ex["RunnerWorstSec"] + post
                        if not end <= t0 + d - margin:
                            ok_grid = False
                            worst_case = (st, t0, start, pre, end)
    checks.append(("M4a arithmetic grid (both stages): with origin BootStartUtc every admitted runner ends by T0 + DEADLINE - margin", ok_grid))
    # The Chair's stage-3a counterexample: command start 0, T0 2, Th 60, collector 80, pre-runner 61 s + cue 3 s.
    d3, ex3 = spec.get("3a"), extra.get("3a", {})
    post3 = ((ex3.get("PreDoneMs") or 0) + (ex3.get("Beep1Ms") or 0) + (ex3.get("Beep2Ms") or 0)) / 1000
    need3 = (ex3.get("RunnerWorstSec") or 0) + (ex3.get("RunnerMarginSec") or 0) + post3
    s3 = 80 + 61 + (ex3.get("DisplayCueMs") or 0) / 1000
    left_origin = (0 + d3 - margin) - s3
    left_th = (60 + d3 - margin) - s3
    checks.append(("M4b Chair counterexample (3a: start 0, T0 2, Th 60, collector 80, runner at %.0f): refused with origin BootStartUtc (%.0f s left < %.0f s)" % (s3, left_origin, need3),
                   left_origin < need3))
    checks.append(("M4c ...and with origin Th it would be admitted (%.0f s left) and end at %.0f s > T0 + DEADLINE = %d s: the old model was unsafe" % (left_th, s3 + (ex3.get("RunnerWorstSec") or 0) + post3, 2 + d3),
                   left_th >= need3 and s3 + (ex3.get("RunnerWorstSec") or 0) + post3 > 2 + d3))
    print("== clock model (FS-R-007 B1; static source checks and arithmetic, not a device measurement)")
    print("   guarantee: host stop <= BootStartUtc + DEADLINE - %d s <= T0 + DEADLINE - %d s (BootStartUtc <= T0);" % (margin, margin))
    print("   assumptions: BootStartUtc taken before fastboot is invoked; host UTC does not jump before the conversion; Stopwatch monotonic after it")
    ok = True
    for label, good in checks:
        print("   %s  %s" % ("PASS" if good else "FAIL", label))
        ok &= bool(good)
    if worst_case:
        print("   grid counterexample: stage %s T0-O=%d start=%d pre=%d end=%.1f" % worst_case)
    return ok


if __name__ == "__main__":
    sys.exit(main())
