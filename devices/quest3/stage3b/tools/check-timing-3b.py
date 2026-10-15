#!/usr/bin/env python3
"""FrameShift — timing check for the STAGE-3B image (trial (iii-b)) and the host collector
(offline; reads source text only). stage2a/tools/check-timing.py is unchanged and still
checks stages 2a and 3a; this file adds stage 3b (FS-R-010 §6: "Include all probes, both
supervisor limits, pause, maximum paced emission, margin and post-record time ... Recompute
[the runner guard] from the final sources. Retain BootStartUtc budgeting and fresh
conversion after preparation. Update the clock regressions for the new stage.").

    python3 -I -B check-timing-3b.py [--q3 DIR]

Sources (numbers are read where they are defined, never copied):
  stage3b/init.sh            DEADLINE, ACK_WINDOW
  stage3b/fs-display.sh      TW1, TW2, TQ, PAUSE, MAXLINES; every `$SUP -t T -g G -c C` line
                             (hash, probe1, pattern1, probe2, pattern2, the skip step)
  common/target/fsb1-pace.sh FSB1_PACE_LINES, FSB1_PACE_TICK
  common/src/fs-supervise.c  REAP_WAIT_MS, STRAY_WAIT_MS, DRAIN_MS, MAX_TIMEOUT_S, MAX_GRACE_S, MAX_CAP
  stage3b/src/fs-pattern.c   FSP_HOLD_MAX_S, FSP_CLOSE_MARGIN_S (the PID 1 contract: -t >= hold + 5 + 1)
  host/fs-collect.ps1        the '3b' stage spec and the host phase defaults
Model (IMAGE.md §4):
  step worst            = t + g + reap + stray + drain                (fs-supervise's own bounds)
  runner worst W        = TW1 + worst(pattern1) + TQ + GATE + PAUSE + TW2 + worst(pattern2) + TQ
                          + ENCODE x 5 + EMIT(MAXLINES)
                          (hash and the probes run CONCURRENTLY; their bounds are checked to end
                           inside W: hash worst <= W; probe -t covers its window; fs-display waits
                           at most TW1/TW2/TQ for a probe and then kills its supervisor)
  EMIT(L)               = END_S + ceil(L / FSB1_PACE_LINES) x (FSB1_PACE_TICK + WRITE_MARGIN)
                          (assumes the host drains the tty promptly: a stalled reader blocks
                           printf; that is safe because both runs have closed by then and the
                           PID 1 deadline is independent of the runner)
  record-size consistency (review M1): 7 + sum over the 5 steps of ceil(stdout cap / 48)
                          + ceil(hash stderr cap / 48) <= MAXLINES, so no record within its
                          step caps can exceed the emitter's maximum (fs-pattern writes no
                          stderr; fs-probe.sh starts with exec 2>/dev/null)
  record budget B       = DEADLINE - HostMargin - COLLECTOR_START - before(tries) - cue - post
  runner guard (host)   = RunnerWorstSec + RunnerMarginSec + post  (seconds that must be left)
Exit 0 if every requirement holds, else 1.
"""
import argparse
import math
import os
import re
import sys

COLLECTOR_START_S = 25.0     # planning assumption: trial (iii) measured the collector start at BootStartUtc + 21.7 s,
                             # the transport-clock conversion at + 24.4 s (the run-time guard enforces the real time)
ENCODE_S_PER_STEP = 1.0      # fsb1_step per step (wc/sha256sum/base64 of <= 40 KiB): margin, as stage2a/check-timing.py
GATE_S = 1.0                 # fs-display's gate (a few grep/tail forks), markers, supervisor fork/exec: margin
END_S = 1.0                  # fsb1_end + the emitter's checks (wc, tail, tr) before the first byte
WRITE_MARGIN_S = 0.01        # per chunk: one printf of <= 10 lines (<= 4 KiB) to the CDC-ACM tty
CEILING_S = 200              # FS-R-010 §6: intended DEADLINE ceiling (backstop 201 s)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def num(rx, text, what, conv=int):
    m = re.search(rx, text, re.M)
    if not m:
        raise SystemExit("cannot find %s" % what)
    return conv(m.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--q3", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    q3 = os.path.abspath(ap.parse_args().q3)
    sup = read(os.path.join(q3, "common/src/fs-supervise.c"))
    reap = num(r"^#define REAP_WAIT_MS\s+(\d+)", sup, "REAP_WAIT_MS") / 1000
    stray = num(r"^#define STRAY_WAIT_MS\s+(\d+)", sup, "STRAY_WAIT_MS") / 1000
    drain = num(r"^#define DRAIN_MS\s+(\d+)", sup, "DRAIN_MS") / 1000
    tmax = num(r"^#define MAX_TIMEOUT_S\s+(\d+)", sup, "MAX_TIMEOUT_S")
    gmax = num(r"^#define MAX_GRACE_S\s+(\d+)", sup, "MAX_GRACE_S")
    capmax = num(r"^#define MAX_CAP\s+\((\d+) \* 1024\)", sup, "MAX_CAP") * 1024
    fsp = read(os.path.join(q3, "stage3b/src/fs-pattern.c"))
    hold_max = num(r"^#define FSP_HOLD_MAX_S\s+(\d+)", fsp, "FSP_HOLD_MAX_S")
    close_margin = num(r"^#define FSP_CLOSE_MARGIN_S\s+(\d+)", fsp, "FSP_CLOSE_MARGIN_S")
    init = read(os.path.join(q3, "stage3b/init.sh"))
    dl = num(r"^DEADLINE=(\d+)$", init, "DEADLINE")
    aw = num(r"^ACK_WINDOW=(\d+)$", init, "ACK_WINDOW")
    rs = read(os.path.join(q3, "stage3b/fs-display.sh"))
    k = {n: num(r"^%s=(\d+)$" % n, rs, n) for n in ("TW1", "TW2", "TQ", "PAUSE", "MAXLINES")}
    pace = read(os.path.join(q3, "common/target/fsb1-pace.sh"))
    lines_default = num(r"^FSB1_PACE_LINES=\$\{FSB1_PACE_LINES:-(\d+)\}$", pace, "FSB1_PACE_LINES")
    mo = re.search(r"^FSB1_PACE_LINES=(\d+)\n\. /lib/fs/fsb1-pace\.sh", rs, re.M)   # the runner's override, set before it sources the pacer
    lines_per = int(mo.group(1)) if mo else lines_default
    tick = num(r"^FSB1_PACE_TICK=\$\{FSB1_PACE_TICK:-([0-9.]+)\}$", pace, "FSB1_PACE_TICK", float)
    # the supervised steps, from the runner text
    steps = {}
    for m in re.finditer(r'\$SUP -t (\d+) -g (\d+) -c (\d+) -o "\$D/(\$1|\d)\.out".* -- (\S+)(?: (\S+))?(?: (\S+))?', rs):
        t, g, c, i, prog, a1, a2 = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5), m.group(6), m.group(7)
        key = {"1": "hash", "2": "probe1", "3": "pattern1", "4": "probe2", "5": "pattern2", "$1": "skip"}[i]
        steps[key] = dict(t=t, g=g, c=c, prog=prog, args=(a1, a2))
    for key in ("hash", "probe1", "pattern1", "probe2", "pattern2", "skip"):
        if key not in steps:
            raise SystemExit("cannot find the fs-supervise line of step %s in fs-display.sh" % key)
    hold1 = int(re.search(r'/bin/fs-pattern show "\$d8" (\d+) ', rs).group(1))
    hold2 = int(re.search(r'/bin/fs-pattern show-off "\$d8" (\d+) ', rs).group(1))
    col = read(os.path.join(q3, "host/fs-collect.ps1"))
    margin = num(r"\[int\]\$HostMarginSec = (\d+)", col, "HostMarginSec")
    step_to = num(r"\[int\]\$StepTimeoutMs = (\d+)", col, "StepTimeoutMs") / 1000
    pwait = num(r"\[int\]\$PromptWaitMs = (\d+)", col, "PromptWaitMs") / 1000
    settle = num(r"\[int\]\$AckSettleMs = (\d+)", col, "AckSettleMs") / 1000
    drain0 = num(r"\[int\]\$InitialDrainMs = (\d+)", col, "InitialDrainMs") / 1000
    m = re.search(r"'3b' = @\{([^}]*)\}", col)
    if not m:
        raise SystemExit("no '3b' stage spec in fs-collect.ps1")
    body = m.group(1)
    spec = {}
    for key in ("DeviceDeadlineSec", "AckWindowSec", "RunnerWorstSec", "RunnerMarginSec", "DisplayCueMs", "AckStatusTries", "PreDoneMs", "Beep1Ms", "Beep2Ms"):
        mm = re.search(key + r" = (\d+)", body)
        spec[key] = int(mm.group(1)) if mm else None
    stepsx = re.search(r"Steps = @\(([^)]*)\)", body).group(1)
    spec_steps = re.findall(r"'([a-z0-9_]+)'", stepsx)

    def worst(s):
        return s["t"] + s["g"] + reap + stray + drain

    w_fixed = (k["TW1"] + worst(steps["pattern1"]) + k["TQ"] + GATE_S + k["PAUSE"] + k["TW2"] + worst(steps["pattern2"]) + k["TQ"]
               + ENCODE_S_PER_STEP * 5)
    chunks = math.ceil(k["MAXLINES"] / lines_per)
    emit = END_S + chunks * (tick + WRITE_MARGIN_S)
    W = w_fixed + emit
    tries = spec["AckStatusTries"]
    before = (drain0 + pwait) + 2 * (step_to + pwait) + tries * (settle + step_to + pwait)
    cue = spec["DisplayCueMs"] / 1000
    post = (spec["PreDoneMs"] + spec["Beep1Ms"] + spec["Beep2Ms"]) / 1000
    B = dl - margin - COLLECTOR_START_S - before - cue - post
    guard = spec["RunnerWorstSec"] + spec["RunnerMarginSec"] + post
    # record size: caps-derived and enforced
    data_line_max = len("FSB1 DATA i=5 s=e n=") + len(str(capmax // 48)) + 1 + 64 + 1
    caps = [steps[x]["c"] for x in ("hash", "probe1", "pattern1", "probe2", "pattern2")]
    caps_lines = 2 + 5 + sum(2 * math.ceil(c / 48) for c in caps)        # if every stderr were at its cap too
    legit_lines = 2 + 5 + sum(math.ceil(c / 48) for c in caps) + math.ceil(steps["hash"]["c"] / 48)
    probe_src = read(os.path.join(q3, "stage3b/fs-probe.sh"))
    first_cmd = [l for l in probe_src.splitlines() if l.strip() and not l.lstrip().startswith("#")][0]
    fsp_stderr = re.search(r"write\(2,|stderr|fprintf|dprintf\(2", re.sub(r"(?s)/\*.*?\*/", "", fsp.split("#else /* FSP_UNIT_TEST")[0])) is None
    max_bytes = k["MAXLINES"] * max(data_line_max, 420)
    # the probe windows (fs-display kills a late probe after TQ; the probe's own -t must not end it earlier)
    win1 = k["TW1"] + worst(steps["pattern1"]) + k["TQ"]
    win2 = k["TW2"] + worst(steps["pattern2"]) + k["TQ"]
    checks = [
        ("collector device deadline (%s s) = image DEADLINE (%d s)" % (spec["DeviceDeadlineSec"], dl), spec["DeviceDeadlineSec"] == dl),
        ("DEADLINE %d <= %d (FS-R-010 §6 ceiling; backstop %d <= %d) and <= 299 (common clamp)" % (dl, CEILING_S, dl + 1, CEILING_S + 1), dl <= CEILING_S and dl <= 299),
        ("collector ack window (%s s) = image ACK_WINDOW (%d s) <= DEADLINE" % (spec["AckWindowSec"], aw), spec["AckWindowSec"] == aw and aw <= dl),
        ("collector step list = fs-display's 5 steps hash,probe1,pattern1,probe2,pattern2", spec_steps == ["hash", "probe1", "pattern1", "probe2", "pattern2"]),
        ("every step: -t <= %d, -g <= %d, -c <= %d" % (tmax, gmax, capmax), all(s["t"] <= tmax and s["g"] <= gmax and s["c"] <= capmax for s in steps.values())),
        ("run 1 hold %d s and run 2 hold %d s (FS-R-010 §4), both <= FSP_HOLD_MAX_S %d" % (hold1, hold2, hold_max), hold1 == 3 and hold2 == 10 and hold2 <= hold_max),
        ("pattern1 -t %d >= hold %d + close margin %d + 1; pattern2 -t %d >= %d + %d + 1 (fs-pattern PID 1 contract)" % (steps["pattern1"]["t"], hold1, close_margin, steps["pattern2"]["t"], hold2, close_margin),
         steps["pattern1"]["t"] >= hold1 + close_margin + 1 and steps["pattern2"]["t"] >= hold2 + close_margin + 1),
        ("pause PAUSE = %d s >= 2 s (FS-R-010 §4)" % k["PAUSE"], k["PAUSE"] >= 2),
        ("probe1 -t %d >= its window TW1 + worst(pattern1) + TQ = %.1f s; probe2 -t %d >= TW2 + worst(pattern2) + TQ = %.1f s" % (steps["probe1"]["t"], win1, steps["probe2"]["t"], win2),
         steps["probe1"]["t"] >= win1 and steps["probe2"]["t"] >= win2),
        ("the skip step's worst (%.1f s) <= each pattern step's worst (the go path is the worst path)" % worst(steps["skip"]), worst(steps["skip"]) <= min(worst(steps["pattern1"]), worst(steps["pattern2"]))),
        ("the concurrent hash step ends inside W: worst(hash) %.1f s <= W %.1f s" % (worst(steps["hash"]), W), worst(steps["hash"]) <= W),
        ("record-size consistency: 7 + sum(ceil(stdout cap / 48)) + ceil(hash stderr cap / 48) = %d <= MAXLINES %d (no record within its caps is refused); %d bytes max < 8 MiB" % (legit_lines, k["MAXLINES"], max_bytes),
         legit_lines <= k["MAXLINES"] and max_bytes < 8 * 1024 * 1024),
        ("pacing burst: a %d-line chunk is at most about %d bytes < the 12,289-byte first-read boundary of trial (iii)" % (lines_per, 5 * 420 + (lines_per - 5) * data_line_max),
         5 * 420 + (lines_per - 5) * data_line_max < 12289),
        ("stderr basis: fs-probe.sh's first command is exec 2>/dev/null; the device build of fs-pattern has no stderr write (no stdio, no write(2,...))",
         first_cmd.strip() == "exec 2>/dev/null" and fsp_stderr),
        ("runner worst case W %.1f s <= host record budget B %.1f s" % (W, B), W <= B),
        ("collector RunnerWorstSec (%s s) >= W (%.1f s)" % (spec["RunnerWorstSec"], W), spec["RunnerWorstSec"] >= W),
        ("run-time guard fits: B %.1f s >= RunnerWorstSec + RunnerMarginSec = %d s" % (B, spec["RunnerWorstSec"] + spec["RunnerMarginSec"]), B >= spec["RunnerWorstSec"] + spec["RunnerMarginSec"]),
        ("phases before the runner %.1f s <= ack-window budget %d - %d - %.0f = %.1f s" % (before, aw, margin, COLLECTOR_START_S, aw - margin - COLLECTOR_START_S), before <= aw - margin - COLLECTOR_START_S),
    ]
    print("== stage 3b (init.sh DEADLINE=%d ACK_WINDOW=%d; runner fs-display.sh)" % (dl, aw))
    print("   %-9s %4s %4s %7s %9s  %s" % ("step", "-t", "-g", "-c", "worst s", "program"))
    for key in ("hash", "probe1", "pattern1", "probe2", "pattern2", "skip"):
        s = steps[key]
        print("   %-9s %4d %4d %7d %9.1f  %s %s" % (key, s["t"], s["g"], s["c"], worst(s), s["prog"], " ".join(a for a in s["args"] if a)))
    print("   fs-supervise waits: reap %.0f s, strays %.0f s, drain %.0f s (common/src/fs-supervise.c)" % (reap, stray, drain))
    print("   W = TW1 %d + pattern1 %.1f + TQ %d + gate %.0f + PAUSE %d + TW2 %d + pattern2 %.1f + TQ %d + encode 5 x %.0f + EMIT %.1f = %.1f s"
          % (k["TW1"], worst(steps["pattern1"]), k["TQ"], GATE_S, k["PAUSE"], k["TW2"], worst(steps["pattern2"]), k["TQ"], ENCODE_S_PER_STEP, emit, W))
    print("   EMIT(MAXLINES=%d) = %.0f + ceil(%d / %d) = %d chunks x (%.2f + %.2f) s = %.1f s (maximum permitted record; an expected record of ~880 lines needs ~%.1f s)"
          % (k["MAXLINES"], END_S, k["MAXLINES"], lines_per, chunks, tick, WRITE_MARGIN_S, emit, END_S + math.ceil(880 / lines_per) * (tick + WRITE_MARGIN_S)))
    print("   pacing: %d lines per chunk (fs-display.sh %s; fsb1-pace.sh default %d); a chunk is at most about %d bytes (5 STEP lines of <= 420 bytes + DATA lines of <= %d bytes), below the 12,289-byte first-read boundary of trial (iii)"
          % (lines_per, "override" if mo else "no override", lines_default, 5 * 420 + (lines_per - 5) * data_line_max, data_line_max))
    print("   record: stdout caps %s -> %d lines at most for a record within its caps (7 framing + stdout + the hash's stderr); enforced maximum MAXLINES %d; (%d if every stderr were at its cap too); DATA line <= %d bytes"
          % (caps, legit_lines, k["MAXLINES"], caps_lines, data_line_max))
    print("   EMIT assumes the host drains the tty promptly; a stalled reader blocks printf, which is safe: both runs have closed and the PID 1 deadline is independent of the runner")
    print("   host: give-up = BootStartUtc + %d - %d s; collector start = BootStartUtc + %.0f s (planning); phases before the runner (%d fs-status tries) <= %.1f s" % (dl, margin, COLLECTOR_START_S, tries, before))
    print("   display cue %.1f s; post-record (beep 1 + pre-done pause + beep 2) %.1f s" % (cue, post))
    print("   B = %d - %d - %.0f - %.1f - %.1f - %.1f = %.1f s; spare B - W = %.1f s; guard spare B - RunnerWorst - margin = %.1f s"
          % (dl, margin, COLLECTOR_START_S, before, cue, post, B, B - W, B - spec["RunnerWorstSec"] - spec["RunnerMarginSec"]))
    print("   IMMEDIATE RUNNER GUARD: the collector sends fs-display only with >= RunnerWorstSec %d + RunnerMarginSec %d + post %.0f = %.0f s left before the give-up"
          % (spec["RunnerWorstSec"], spec["RunnerMarginSec"], post, guard))
    ok_all = True
    for label, ok in checks:
        print("   %s  %s" % ("PASS" if ok else "FAIL", label))
        ok_all &= bool(ok)
    ok_all &= clock_model(q3, dl, margin, spec, post, cue, before)
    print("TIMING 3B: %s" % ("CONSISTENT" if ok_all else "INCONSISTENT"))
    return 0 if ok_all else 1


def clock_model(q3, dl, margin, spec, post, cue, before):
    """FS-R-007 B1 for stage 3b: the same host code path (static checks) + arithmetic with the 3b numbers."""
    obs = read(os.path.join(q3, "host/fs-observe.ps1"))
    col = read(os.path.join(q3, "host/fs-collect.ps1"))
    cli = col[col.find("# ------------------------------------------------------------------ CLI -----"):]
    live = cli[cli.find("} else {"):]

    def at(text, needle):
        i = text.find(needle)
        return i if i >= 0 else None
    i_start = at(obs, "$o.BootStartUtc = (& $NowUtc)")
    mb = re.search(r"& \$Fastboot @\('-s', \$Serial, 'boot'", obs)
    i_boot = mb.start() if mb else None
    i_dwell = at(obs, "$dw = Test-FsObsDwell")
    i_reg = at(obs, "$reg = Register-FsAttempt")
    i_gad = at(live, "Get-FsGadget -Nonce")
    i_tr = at(live, "New-FsRawSerialTransport -PortName")
    i_cv = None
    for mm in re.finditer(r"ConvertTo-FsTransportDeadlines -Deadlines \$dl -NowMs \$nowMs", live):
        i_cv = mm.start()
    i_cfg = at(live, "-GiveUpMs $cv.GiveUpMs")
    checks = [
        ("M1 fs-observe.ps1: BootStartUtc is taken before the one fastboot boot call (every stage, 3b included)", None not in (i_start, i_boot) and i_start < i_boot),
        ("M1b fs-observe.ps1 stage 3b: the BA dwell gate runs before the attempt is registered and before BootStartUtc/boot",
         None not in (i_dwell, i_reg, i_start) and i_dwell < i_reg < i_start),
        ("M2 the collector gets -BootStartUtc (origin); no HandoffBasisUtc", "-BootStartUtc $($o.BootStartUtc)" in obs and "HandoffBasisUtc" not in obs),
        ("M3a fs-collect.ps1 live: both deadlines from BootStartUtc", re.search(r"\$origin = & \$parseU \$BootStartUtc", live) is not None and "Get-FsHostDeadlines -OriginUtc $origin" in live),
        ("M3b fresh conversion AFTER the preparation (gadget lookup, transport), used by the collector", None not in (i_gad, i_tr, i_cv, i_cfg) and i_gad < i_tr < i_cv < i_cfg),
        ("M3c start refusals re-checked after the preparation; no remaining time carried over", "Get-FsLiveStartRefusal -RemainMs $cv.RemainMs" in live and "$remainMs" not in live),
        ("M3d the live path takes the stage spec from $script:FsStageSpec (3b included) and -Stage accepts 3b",
         "$script:FsStageSpec[$Stage].DeviceDeadlineSec" in live and "[ValidateSet('2a', '3a', '3b')][string]$Stage" in col),
    ]
    W = spec["RunnerWorstSec"]
    need = W + spec["RunnerMarginSec"] + post
    ok_grid = True
    for t0 in (0, 2, 30, 60, 120):
        for start in range(0, 241, 5):
            for pre in range(0, 121, 3):
                s_ = start + pre
                if dl - margin - s_ >= need and not (s_ + W + post <= t0 + dl - margin):
                    ok_grid = False
    checks.append(("M4a arithmetic grid (stage 3b): with origin BootStartUtc every admitted runner ends by T0 + DEADLINE - margin", ok_grid))
    s3 = 80 + 61 + cue
    left_o = (0 + dl - margin) - s3
    left_th = (60 + dl - margin) - s3
    checks.append(("M4b Chair counterexample with the 3b numbers (start 0, T0 2, Th 60, collector 80, runner at %.0f): refused with origin BootStartUtc (%.0f s left < %.0f s)" % (s3, left_o, need), left_o < need))
    checks.append(("M4c ...and with origin Th it would be admitted (%.0f s left) and end at %.0f s > T0 + DEADLINE = %d s" % (left_th, s3 + W + post, 2 + dl), left_th >= need and s3 + W + post > 2 + dl))
    print("== clock model, stage 3b (FS-R-007 B1; static source checks and arithmetic, not a device measurement)")
    ok = True
    for label, good in checks:
        print("   %s  %s" % ("PASS" if good else "FAIL", label))
        ok &= bool(good)
    return ok


if __name__ == "__main__":
    sys.exit(main())
