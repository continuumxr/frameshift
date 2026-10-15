#!/usr/bin/env python3
"""FrameShift — timing check for the STAGE-3C image (DESIGN.md rev 3 §9) and, when present, the 3c host
files (offline; reads source text and fixture outputs only). stage3b/tools/check-timing-3b.py and
stage2a/tools/check-timing.py are unchanged.

    python3 -I -B check-timing-3c.py [--q3 DIR]

Sources (numbers are read where they are defined, never copied):
  stage3c/init.sh              DEADLINE, ACK_WINDOW
  stage3c/fs-phase.sh          TW, TQ, PAUSE_CS, PAUSE_ITER, HEADROOM, PHASE_WORST_<ph>, MAXLINES_<ph>; every
                               `$SUP -t T -g G -c C ... -- PROG ARGS` line (hash, probe0, the probe line of
                               lit_phase with its per-phase -t from the lit_phase calls, pattern1..3, the skip step)
  stage3c/fs-idle.sh           IDLE_S, STUCK_S
  common/target/fsb1-pace.sh   FSB1_PACE_LINES (fs-phase's override 20), FSB1_PACE_TICK
  common/src/fs-supervise.c    REAP_WAIT_MS, STRAY_WAIT_MS, DRAIN_MS, MAX_TIMEOUT_S, MAX_GRACE_S, MAX_CAP
  stage3c/src/fs-pattern.c     FSP_HOLD_MAX_S, FSP_CLOSE_MARGIN_S, FSP_OPT_MAX, FSP_OPT_MAX_SOLID, FSP_ESS_MODES,
                               FSP_ESS_PLANES, FSP_ESS_CONNECTORS (the essential-record cap, build review fs-pattern MINOR)
  stage3c/fixtures/encode-timing.txt   the encoder measured at the maximum streams (tools/encode-timing.sh), incl. the
                               recorded cold repetition (ENCODE_COLD lines, build review MINOR-2)
  stage3c/fixtures/sim/*.check.log     the essential bytes of the mock-model maximum streams
  host/fs-collect3c.ps1, host/fs-observe3c.ps1 (written in parallel by the host side): the guard constants
                               and the clock regressions M1-M3, retargeted; PENDING while absent
Model (DESIGN §9.1): step worst = t + g + reap + stray + drain; encode per step = max(1 s, 1.5 x the measured
time for that stream size, the cold repetition included); the encoder END pass = 1.5 x its measured time
(build review MINOR-2); GATE 1 s; emission(L) = END 1 s + ceil(L / 20) x (0.1 + 0.01) s;
  W_p0 = max(worst(probe0), worst(hash)) + GATE + encode(hash) + encode(probe0) + END pass + emission(MAXLINES_p0)
  W_r1 = TW + worst(pattern1) + TQ + GATE + encode(probe1) + encode(pattern1) + END pass + emission(MAXLINES_r1)
  W_r2 = PAUSE + TW + worst(pattern2) + TQ + GATE + encode x 2 + END pass + emission(MAXLINES_r2)   (PAUSE = PAUSE_CS / 100)
  W_r3 = PAUSE + TW + worst(pattern3) + TQ + GATE + encode x 2 + END pass + emission(MAXLINES_r3)
and every PHASE_WORST >= W + 0.5 s (the margin rule of the build review).
Host guards (DESIGN §9.3): G_k = PHASE_WORST_k + RunnerMargin 5 + PostMin_k + DoneReserve 3, PostMin = banner 2 s
+ H_k (p0: the 3 s cue, no banner term); give-up = BootStartUtc + DEADLINE - 15.
Exit 0 if every requirement holds (PENDING host items are listed, not failed), else 1.
"""
import argparse
import math
import os
import re
import sys

GATE_S = 1.0
END_S = 1.0
WRITE_MARGIN_S = 0.01
CEILING_S = 200
HOST_MARGIN_S = 15
PW_MARGIN_S = 0.5                                    # build review MINOR-2: PHASE_WORST >= W + 0.5 s
RUNNER_MARGIN_S = 5
DONE_RESERVE_S = 3
BANNER_S = 2
H = {"p0": 3, "r1": 20, "r2": 25, "r3": 15}          # minimum human windows (DESIGN §9.3); p0 = the cue
GAP_CAP_S = 110                                      # host: every gap <= IDLE_S - 10 (DESIGN §5.9, §8.3)
DESIGN_G = {"p0": 34, "r1": 68, "r2": 82, "r3": 64}     # build review (rev 3 + fixes): PHASE_WORST + 5 + PostMin + 3
DESIGN_PW = {"p0": 23, "r1": 38, "r2": 47, "r3": 39}    # rev 3 had 22/36/45/37 (TQ 2, no END pass, no cold repetition)
DESIGN_LIM = (117, 103, 121)                            # 185 - G for r1, r2, r3 (rev 3: 119 / 105 / 123)
ESS_COUNTS = {"FSP_ESS_MODES": 24, "FSP_ESS_PLANES": 20, "FSP_ESS_CONNECTORS": 3}   # the mock-model maximum fixtures
ESSENTIAL_DESIGN = 12254 + 1536 + 4096               # DESIGN §6.5: 3b run-1 essential + post + plan/caps/test


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
    S = os.path.join(q3, "stage3c")
    sup = read(os.path.join(q3, "common/src/fs-supervise.c"))
    reap = num(r"^#define REAP_WAIT_MS\s+(\d+)", sup, "REAP_WAIT_MS") / 1000
    stray = num(r"^#define STRAY_WAIT_MS\s+(\d+)", sup, "STRAY_WAIT_MS") / 1000
    drain = num(r"^#define DRAIN_MS\s+(\d+)", sup, "DRAIN_MS") / 1000
    tmax = num(r"^#define MAX_TIMEOUT_S\s+(\d+)", sup, "MAX_TIMEOUT_S")
    gmax = num(r"^#define MAX_GRACE_S\s+(\d+)", sup, "MAX_GRACE_S")
    capmax = num(r"^#define MAX_CAP\s+\((\d+) \* 1024\)", sup, "MAX_CAP") * 1024
    fsp = read(os.path.join(S, "src/fs-pattern.c"))
    hold_max = num(r"^#define FSP_HOLD_MAX_S\s+(\d+)", fsp, "FSP_HOLD_MAX_S")
    close_margin = num(r"^#define FSP_CLOSE_MARGIN_S\s+(\d+)", fsp, "FSP_CLOSE_MARGIN_S")
    opt_max = num(r"^#define FSP_OPT_MAX\s+(\d+)", fsp, "FSP_OPT_MAX")
    opt_solid = num(r"^#define FSP_OPT_MAX_SOLID\s+(\d+)", fsp, "FSP_OPT_MAX_SOLID")
    ess_cnt = {kk: num(r"^#define %s\s+(\d+)" % kk, fsp, kk) for kk in ESS_COUNTS}
    init = read(os.path.join(S, "init.sh"))
    dl = num(r"^DEADLINE=(\d+)$", init, "DEADLINE")
    aw = num(r"^ACK_WINDOW=(\d+)$", init, "ACK_WINDOW")
    rs = read(os.path.join(S, "fs-phase.sh"))
    k = {n: num(r"^%s=(\d+)$" % n, rs, n) for n in ("TW", "TQ", "PAUSE_CS", "PAUSE_ITER", "HEADROOM")}
    PW = {ph: num(r"^PHASE_WORST_%s=(\d+)$" % ph, rs, "PHASE_WORST_" + ph) for ph in ("p0", "r1", "r2", "r3")}
    ML = {ph: num(r"^MAXLINES_%s=(\d+)$" % ph, rs, "MAXLINES_" + ph) for ph in ("p0", "r1", "r2", "r3")}
    idle = read(os.path.join(S, "fs-idle.sh"))
    idle_s = num(r"^IDLE_S=(\d+)$", idle, "IDLE_S")
    stuck_s = num(r"^STUCK_S=(\d+)$", idle, "STUCK_S")
    pace = read(os.path.join(q3, "common/target/fsb1-pace.sh"))
    lines_default = num(r"^FSB1_PACE_LINES=\$\{FSB1_PACE_LINES:-(\d+)\}$", pace, "FSB1_PACE_LINES")
    mo = re.search(r"^\s*FSB1_PACE_LINES=(\d+)\n\s*\. /lib/fs/fsb1-pace\.sh", rs, re.M)
    lines_per = int(mo.group(1)) if mo else lines_default
    tick = num(r"^FSB1_PACE_TICK=\$\{FSB1_PACE_TICK:-([0-9.]+)\}$", pace, "FSB1_PACE_TICK", float)
    # the supervised steps
    st = {}
    for m in re.finditer(r'\$SUP -t ("\$2"|\d+) -g (\d+) -c (\d+) -o "\$S/(\$1|\d)\.out".* -- (\S+)(?: (\S+))?(?: (\S+))?(?: (\S+))?', rs):
        t, g, c, i, prog = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5)
        args = [a for a in m.group(6, 7, 8) if a]
        if i == "$1":
            st["skip"] = dict(t=int(t), g=g, c=c)
        elif "sha256sum" in args:
            st["hash"] = dict(t=int(t), g=g, c=c)
        elif "fs-probe.sh" in " ".join(args) and '"$PH"' not in " ".join(args):
            st["probe0"] = dict(t=int(t), g=g, c=c)
        elif "fs-probe.sh" in " ".join(args):
            st["probe_r"] = dict(t=None, g=g, c=c)
        elif prog == "/bin/fs-pattern":
            ph = {"show": "r1", "show-off-quad": "r2", "show-off-solid": "r3"}[args[0]]
            st["pattern" + ph[1]] = dict(t=int(t), g=g, c=c, mode=args[0], hold=int(args[2]))
    for ph, t in re.findall(r"^\s*lit_phase (\d) (\d+)$", rs, re.M):
        st["probe" + ph] = dict(t=int(t), g=st["probe_r"]["g"], c=st["probe_r"]["c"])
    need = ["hash", "probe0", "probe1", "pattern1", "probe2", "pattern2", "probe3", "pattern3", "skip"]
    miss = [n for n in need if n not in st]
    if miss:
        raise SystemExit("cannot find the fs-supervise lines of %s in fs-phase.sh" % miss)

    def worst(s):
        return s["t"] + s["g"] + reap + stray + drain

    def emit(L):
        return END_S + math.ceil(L / lines_per) * (tick + WRITE_MARGIN_S)
    # the encoder, measured at the maximum streams
    et = read(os.path.join(S, "fixtures/encode-timing.txt"))
    meas = {"probe": 0.0, 57344: 0.0, 28672: 0.0, "end": 0.0}
    nrep = 0
    for m in re.finditer(r"^ENCODE (r2|r3) rep=\d+ step1\(probe 16384 B\) ([0-9.]+) s  step2\(pattern (\d+) B\) ([0-9.]+) s  end ([0-9.]+) s", et, re.M):
        nrep += 1
        meas["probe"] = max(meas["probe"], float(m.group(2)))
        meas[int(m.group(3))] = max(meas[int(m.group(3))], float(m.group(4)))
        meas["end"] = max(meas["end"], float(m.group(5)))
    cold = [(int(m.group(2)), float(m.group(3))) for m in
            re.finditer(r"^ENCODE_COLD (r2|r3) step2\(pattern (\d+) B\) ([0-9.]+) s", et, re.M)]
    for c_, v_ in cold:                       # the recorded cold repetition counts like any other (build review MINOR-2)
        meas[c_] = max(meas[c_], v_)
    enc = {c: max(1.0, 1.5 * v) for c, v in meas.items() if c != "end"}
    end_pass = 1.5 * meas["end"]              # the encoder END pass: 1.5 x measured, once per phase (no 1 s floor)
    E = {"hash": 1.0, "probe": enc["probe"], "pattern1": enc[57344], "pattern2": enc[57344], "pattern3": enc[28672]}
    pause_s = k["PAUSE_CS"] / 100
    W = {
        "p0": max(worst(st["probe0"]), worst(st["hash"])) + GATE_S + E["hash"] + E["probe"] + end_pass + emit(ML["p0"]),
        "r1": k["TW"] + worst(st["pattern1"]) + k["TQ"] + GATE_S + E["probe"] + E["pattern1"] + end_pass + emit(ML["r1"]),
        "r2": pause_s + k["TW"] + worst(st["pattern2"]) + k["TQ"] + GATE_S + E["probe"] + E["pattern2"] + end_pass + emit(ML["r2"]),
        "r3": pause_s + k["TW"] + worst(st["pattern3"]) + k["TQ"] + GATE_S + E["probe"] + E["pattern3"] + end_pass + emit(ML["r3"]),
    }
    W1 = {   # the design's model with encode 1 s per step (for the comparison)
        "p0": max(worst(st["probe0"]), worst(st["hash"])) + GATE_S + 2 + emit(ML["p0"]),
        "r1": k["TW"] + worst(st["pattern1"]) + k["TQ"] + GATE_S + 2 + emit(ML["r1"]),
        "r2": pause_s + k["TW"] + worst(st["pattern2"]) + k["TQ"] + GATE_S + 2 + emit(ML["r2"]),
        "r3": pause_s + k["TW"] + worst(st["pattern3"]) + k["TQ"] + GATE_S + 2 + emit(ML["r3"]),
    }
    caps_lines = {
        "p0": 4 + math.ceil(st["hash"]["c"] / 48) + math.ceil(st["probe0"]["c"] / 48) + math.ceil(st["hash"]["c"] / 48),
        "r1": 4 + math.ceil(st["probe1"]["c"] / 48) + math.ceil(st["pattern1"]["c"] / 48),
        "r2": 4 + math.ceil(st["probe2"]["c"] / 48) + math.ceil(st["pattern2"]["c"] / 48),
        "r3": 4 + math.ceil(st["probe3"]["c"] / 48) + math.ceil(st["pattern3"]["c"] / 48),
    }
    holds = {ph: st["pattern" + ph[1]]["hold"] for ph in ("r1", "r2", "r3")}
    win = {ph: k["TW"] + worst(st["pattern" + ph[1]]) + k["TQ"] for ph in ("r1", "r2", "r3")}
    data_line_max = len("FSB1 DATA i=2 s=e n=") + len(str(capmax // 48)) + 1 + 64 + 1
    probe_src = read(os.path.join(S, "fs-probe.sh"))
    first_cmd = [l for l in probe_src.splitlines() if l.strip() and not l.lstrip().startswith("#")][0]
    fsp_stderr = re.search(r"write\(2,|stderr|fprintf|dprintf\(2", re.sub(r"(?s)/\*.*?\*/", "", fsp.split("#else /* FSP_UNIT_TEST")[0])) is None
    ess = {}
    ess_n = {}
    for name in ("quad-max", "show-max", "solid-max"):
        p = os.path.join(S, "fixtures/sim/%s.check.log" % name)
        if os.path.exists(p):
            mm = re.search(r"essential_bytes=(\d+)", read(p))
            if mm:
                ess[name] = int(mm.group(1))
        ps = os.path.join(S, "fixtures/sim/%s.txt" % name)
        if os.path.exists(ps):
            tx = read(ps)
            ess_n[name] = {kk: len(re.findall(r"^FSP1 nonce=\S+ seq=\d+ step=%s rc=" % st_, tx, re.M))
                           for kk, st_ in (("modes", "mode"), ("connectors", "connector"), ("planes", "plane"), ("plane_caps", "plane_caps"))}
    G = {ph: PW[ph] + RUNNER_MARGIN_S + (H[ph] if ph == "p0" else BANNER_S + H[ph]) + DONE_RESERVE_S for ph in PW}
    giveup = dl - HOST_MARGIN_S
    lim = {ph: giveup - G[ph] for ph in G}
    checks = [
        ("DEADLINE %d <= %d (FS-R-010 §6 ceiling; backstop %d) and <= 299 (common clamp); ACK_WINDOW %d <= DEADLINE" % (dl, CEILING_S, dl + 1, aw),
         dl <= CEILING_S and dl <= 299 and aw <= dl and dl == 200 and aw == 150),
        ("every step: -t <= %d, -g <= %d, -c <= %d" % (tmax, gmax, capmax),
         all(s["t"] <= tmax and s["g"] <= gmax and s["c"] <= capmax for n, s in st.items() if n != "probe_r")),
        ("holds r1 %d s, r2 %d s, r3 %d s (DESIGN §10), each <= FSP_HOLD_MAX_S %d; total lit %d s <= 18 s" % (holds["r1"], holds["r2"], holds["r3"], hold_max, sum(holds.values())),
         holds == {"r1": 3, "r2": 10, "r3": 5} and max(holds.values()) <= hold_max and sum(holds.values()) <= 18),
        ("modes: r1 show, r2 show-off-quad, r3 show-off-solid", [st["pattern%d" % i]["mode"] for i in (1, 2, 3)] == ["show", "show-off-quad", "show-off-solid"]),
        ("pattern -t >= hold + close margin %d + 1 (the PID 1 contract): r1 %d >= %d, r2 %d >= %d, r3 %d >= %d" % (close_margin, st["pattern1"]["t"], holds["r1"] + close_margin + 1,
          st["pattern2"]["t"], holds["r2"] + close_margin + 1, st["pattern3"]["t"], holds["r3"] + close_margin + 1),
         all(st["pattern" + ph[1]]["t"] >= holds[ph] + close_margin + 1 for ph in holds)),
        ("probe -t covers its window TW + worst(pattern) + TQ: r1 %d >= %.0f, r2 %d >= %.0f, r3 %d >= %.0f" % (st["probe1"]["t"], win["r1"], st["probe2"]["t"], win["r2"], st["probe3"]["t"], win["r3"]),
         all(st["probe" + ph[1]]["t"] >= win[ph] for ph in win)),
        ("probe0 (p0) and hash end inside W_p0; the skip step's worst %.0f s <= every pattern step's worst" % worst(st["skip"]),
         worst(st["skip"]) <= min(worst(st["pattern%d" % i]) for i in (1, 2, 3))),
        ("PHASE_WORST covers the recomputed worst case (encode measured incl. the cold repetition, END pass %.2f s) with >= %.1f s margin: " % (end_pass, PW_MARGIN_S)
         + ", ".join("%s %d >= %.2f + %.1f" % (ph, PW[ph], W[ph], PW_MARGIN_S) for ph in PW),
         all(PW[ph] >= W[ph] + PW_MARGIN_S for ph in PW) and len(cold) >= 1 and nrep >= 6),
        ("PHASE_WORST = the DESIGN values 23/38/47/39 (= ceil(W + 0.5 s): %s)" % ", ".join("%.2f" % (W[ph] + PW_MARGIN_S) for ph in PW),
         PW == DESIGN_PW and all(PW[ph] == math.ceil(W[ph] + PW_MARGIN_S) for ph in PW)),
        ("MAXLINES matches the caps (3b review M1 rule: 4 framing + every stdout at cap/48 + the hash stderr): " + ", ".join("%s %d <= %d" % (ph, caps_lines[ph], ML[ph]) for ph in ML),
         all(caps_lines[ph] <= ML[ph] for ph in ML) and ML == {"p0": 360, "r1": 1545, "r2": 1545, "r3": 945}),
        ("pacing burst: a %d-line chunk is at most about %d bytes < the 12,289-byte first-read boundary of trial (iii)" % (lines_per, 2 * 420 + (lines_per - 2) * data_line_max),
         2 * 420 + (lines_per - 2) * data_line_max < 12289 and lines_per == 20),
        ("stderr basis: fs-probe.sh's first command is exec 2>/dev/null; the device build of fs-pattern writes no stderr", first_cmd.strip() == "exec 2>/dev/null" and fsp_stderr),
        ("stream bounds (DESIGN §6.5): essential %d + FSP_OPT_MAX %d = %d <= 57344; + FSP_OPT_MAX_SOLID %d = %d <= 28672" % (ESSENTIAL_DESIGN, opt_max, ESSENTIAL_DESIGN + opt_max, opt_solid, ESSENTIAL_DESIGN + opt_solid),
         ESSENTIAL_DESIGN + opt_max <= st["pattern1"]["c"] == st["pattern2"]["c"] == 57344 and ESSENTIAL_DESIGN + opt_solid <= st["pattern3"]["c"] == 28672),
        ("stream bounds, mock-model maximum fixtures (24 modes, 3 connectors, 20 planes, 8 KiB blobs): " + ", ".join("%s essential %d + budget = %d" % (n, e, e + (opt_solid if "solid" in n else opt_max)) for n, e in sorted(ess.items())),
         len(ess) == 3 and ess["quad-max"] + opt_max <= 57344 and ess["show-max"] + opt_max <= 57344 and ess["solid-max"] + opt_solid <= 28672),
        ("essential-record cap independent of the counts (build review): fs-pattern %s = the counts of the maximum fixtures; "
         "every per-object record beyond them is optional (inside the opt budget); fixture record counts %s"
         % (", ".join("%s %d" % kv for kv in sorted(ess_cnt.items())),
            "; ".join("%s %s" % (n, ",".join("%s=%d" % kv for kv in sorted(c.items()))) for n, c in sorted(ess_n.items()))),
         ess_cnt == ESS_COUNTS and len(ess_n) == 3 and all(c["modes"] == ESS_COUNTS["FSP_ESS_MODES"] and c["connectors"] == ESS_COUNTS["FSP_ESS_CONNECTORS"]
                                                          and c["planes"] == ESS_COUNTS["FSP_ESS_PLANES"] for c in ess_n.values())
         and ess_n["quad-max"]["plane_caps"] == ESS_COUNTS["FSP_ESS_PLANES"] and ess_n["solid-max"]["plane_caps"] == ESS_COUNTS["FSP_ESS_PLANES"]),
        ("pause: PAUSE_CS %d (2.00 s) and the bounded loop PAUSE_ITER %d x 0.1 s = %.1f s >= the largest admitted wait (rem <= PAUSE_CS)" % (k["PAUSE_CS"], k["PAUSE_ITER"], k["PAUSE_ITER"] * 0.1),
         k["PAUSE_CS"] == 200 and k["PAUSE_ITER"] * 10 >= k["PAUSE_CS"]),
        ("device time refusal: headroom %d s (DESIGN §5.2)" % k["HEADROOM"], k["HEADROOM"] == 5),
        ("idle limit: IDLE_S %d >= host gap cap %d + 10; STUCK_S %d = IDLE_S + 60 >= the longest phase (%d s)" % (idle_s, GAP_CAP_S, stuck_s, max(PW.values())),
         idle_s == 120 and idle_s >= GAP_CAP_S + 10 and stuck_s == idle_s + 60 and stuck_s >= max(PW.values())),
        ("host guards G_k = PHASE_WORST + 5 + PostMin + DoneReserve 3 = %s (DESIGN 34/68/82/64); each G_k >= PHASE_WORST + 5 + 3" % "/".join(str(G[p]) for p in ("p0", "r1", "r2", "r3")),
         G == DESIGN_G and all(G[ph] >= PW[ph] + RUNNER_MARGIN_S + DONE_RESERVE_S for ph in G)),
        ("per-lit-phase limits (give-up %d - G): r1 %d, r2 %d, r3 %d; each admitted at its limit, refused at limit + 1, and a send at 144 s refused for r1, r2 and r3" % (giveup, lim["r1"], lim["r2"], lim["r3"]),
         all(lim[ph] + G[ph] <= giveup and (lim[ph] + 1) + G[ph] > giveup and 144 + G[ph] > giveup for ph in ("r1", "r2", "r3"))
         and (lim["r1"], lim["r2"], lim["r3"]) == DESIGN_LIM),
        ("§9.4: run 1 admitted after the worst pre-runner (86 s) and worst p0: 86 + %d + 3 cue = %d <= %d" % (PW["p0"], 86 + PW["p0"] + 3, lim["r1"]),
         86 + PW["p0"] + 3 <= lim["r1"]),
        ("§9.4: run 2 admitted if the run-1 prompts take <= %d s (r1 done 51 + banner 2 + P1 <= %d)" % (lim["r2"] - 53, lim["r2"]), lim["r2"] - 53 == 50),
        ("§9.4: run 3 admitted if P1 + P2 <= %d s (51 + 2 + P1 + 20 + 2 + P2 <= %d); planning P1 15 + P2 25 leaves %d s" % (lim["r3"] - 75, lim["r3"], lim["r3"] - 75 - 40),
         lim["r3"] - 75 == 46 and lim["r3"] - 75 - 40 == 6),
        ("§9.4 (d, d) path: r2 prompts end at about 160 s <= the prompt cut-off %d and <= the gap cap 88 + %d = %d" % (giveup - DONE_RESERVE_S, GAP_CAP_S, 88 + GAP_CAP_S),
         160 <= giveup - DONE_RESERVE_S and 160 <= 88 + GAP_CAP_S),
    ]
    print("== stage 3c device side (init.sh DEADLINE=%d ACK_WINDOW=%d; fs-phase.sh; fs-idle.sh IDLE_S=%d)" % (dl, aw, idle_s))
    print("   %-9s %4s %4s %7s %9s" % ("step", "-t", "-g", "-c", "worst s"))
    for n in need:
        s = st[n]
        print("   %-9s %4d %4d %7d %9.1f%s" % (n, s["t"], s["g"], s["c"], worst(s), ("  " + s["mode"] + " hold " + str(s["hold"])) if "mode" in s else ""))
    print("   fs-supervise waits: reap %.0f s, strays %.0f s, drain %.0f s; pacing %d lines per %.2f s (+%.2f s write margin)" % (reap, stray, drain, lines_per, tick, WRITE_MARGIN_S))
    print("   encoder measured (fixtures/encode-timing.txt, max of %d repetitions and %d recorded cold repetition(s)): probe 16384 B %.2f s, pattern 57344 B %.2f s, pattern 28672 B %.2f s, end %.2f s"
          % (nrep, len(cold), meas["probe"], meas[57344], meas[28672], meas["end"]))
    print("   encode term per step = max(1 s, 1.5 x measured): probe %.3f s, pattern 57344 B %.3f s, pattern 28672 B %.3f s, hash 1.000 s; END pass 1.5 x %.2f = %.3f s per phase"
          % (E["probe"], E["pattern1"], E["pattern3"], meas["end"], end_pass))
    for ph in ("p0", "r1", "r2", "r3"):
        print("   W_%s = %.2f s (1 s-encode model without END pass %.2f s); PHASE_WORST_%s = %d (margin %.2f s); emission(MAXLINES %d) = %.2f s; MAXLINES from caps %d"
              % (ph, W[ph], W1[ph], ph, PW[ph], PW[ph] - W[ph], ML[ph], emit(ML[ph]), caps_lines[ph]))
    print("   host (DESIGN §9.3, constants of this checker; cross-checked below against the host files when present): give-up = BootStartUtc + %d; G = %s"
          % (giveup, G))
    notes = []
    if max(enc.values()) > 1.0:
        notes.append("NOTE encode: the %s measured %.2f s (cold repetition included), x1.5 = %.3f s > the 1 s term of DESIGN §9.1; with the END pass "
                     "(%.3f s) and TQ %d s the build review raised PHASE_WORST to 23/38/47/39 so that each covers W + 0.5 s (%s); DESIGN §9.1-§9.4 "
                     "and the host guards carry the new numbers (for the PM)."
                     % ("57344-byte pattern step" if enc[57344] > 1 else "probe step", max(v for c, v in meas.items() if c != "end"), max(enc.values()),
                        end_pass, k["TQ"], ", ".join("%s %.2f + 0.5 <= %d" % (ph, W[ph], PW[ph]) for ph in PW)))
    ok_all = True
    for label, ok in checks:
        print("   %s  %s" % ("PASS" if ok else "FAIL", label))
        ok_all &= bool(ok)
    for n in notes:
        print("   " + n)
    ok_host, pending = host_side(q3, G, PW, idle_s, dl, aw)
    ok_all &= ok_host
    print("TIMING 3C: %s%s" % ("CONSISTENT" if ok_all else "INCONSISTENT",
                               (" (device side and DESIGN host constants; host cross-check PENDING: %s)" % "; ".join(pending)) if pending else ""))
    return 0 if ok_all else 1


def host_side(q3, G, PW, idle_s, dl, aw):
    """the 3c host files, when present: the clock regressions M1-M3 of check-timing-3b.py retargeted to
    fs-observe3c.ps1 / fs-collect3c.ps1, and the guard constants. PENDING (not failed) while absent."""
    col_p = os.path.join(q3, "host/fs-collect3c.ps1")
    obs_p = os.path.join(q3, "host/fs-observe3c.ps1")
    pending = []
    print("== host side (fs-collect3c.ps1, fs-observe3c.ps1)")
    if not os.path.exists(obs_p):
        pending.append("host/fs-observe3c.ps1 absent (M1, M1b, M2)")
    if not os.path.exists(col_p):
        pending.append("host/fs-collect3c.ps1 absent (M3, guards)")
    ok = True
    if os.path.exists(obs_p):
        obs = read(obs_p)
        i_start = obs.find("$o.BootStartUtc = (& $NowUtc)")
        mb = re.search(r"& \$Fastboot @\('-s', \$Serial, 'boot'", obs)
        i_dwell = obs.find("$dw = Test-FsObsDwell")
        i_reg = obs.find("$reg = Register-FsAttempt")
        for label, good in (
                ("M1 fs-observe3c.ps1: BootStartUtc is taken before the one fastboot boot call", i_start >= 0 and mb is not None and i_start < mb.start()),
                ("M1b fs-observe3c.ps1: the dwell gate (unconditional) runs before the attempt is registered and before BootStartUtc",
                 0 <= i_dwell < i_reg < i_start and "if ($Stage -ceq '3b')" not in obs),
                ("M2 fs-observe3c.ps1 passes the origin to fs-collect3c.ps1 (-S3cBootStartUtc); no HandoffBasisUtc",
                 "S3cBootStartUtc" in obs and "HandoffBasisUtc" not in obs)):
            print("   %s  %s" % ("PASS" if good else "FAIL", label))
            ok &= good
    if os.path.exists(col_p):
        col = read(col_p)
        i_gad = col.find("Get-FsGadget -Nonce")
        i_tr = col.find("New-FsRawSerialTransport -PortName")
        i_cv = max((m.start() for m in re.finditer(r"ConvertTo-FsTransportDeadlines", col)), default=-1)
        for label, good in (
                ("M3a fs-collect3c.ps1 live: deadlines from the BootStartUtc origin (Get-FsHostDeadlines)", "Get-FsHostDeadlines" in col),
                ("M3b fresh conversion AFTER the gadget lookup and the transport", 0 <= i_gad < i_tr < i_cv),
                ("M3c start refusals re-checked after the preparation (Get-FsLiveStartRefusal)", "Get-FsLiveStartRefusal" in col),
                ("host DEADLINE/ACK_WINDOW = image (200/150)", re.search(r"\b200\b", col) is not None and re.search(r"\b150\b", col) is not None)):
            print("   %s  %s" % ("PASS" if good else "FAIL", label))
            ok &= good
        hp = {}
        mm = re.search(r"PhaseWorstSec\s*=\s*@\{([^}]*)\}", col)
        hh = re.search(r"HumanSec\s*=\s*@\{([^}]*)\}", col)
        sc = {key: re.search(r"\b%s\s*=\s*(\d+)" % key, col) for key in ("RunnerMarginSec", "DoneReserveSec", "BannerSec", "IdleSec", "GapCapSec")}
        if mm and hh and all(sc.values()):
            hp = {kk: int(vv) for kk, vv in re.findall(r"(p0|r1|r2|r3)\s*=\s*(\d+)", mm.group(1))}
            hu = {kk: int(vv) for kk, vv in re.findall(r"(p0|r1|r2|r3)\s*=\s*(\d+)", hh.group(1))}
            v = {key: int(m_.group(1)) for key, m_ in sc.items()}
            hg = {ph: hp[ph] + v["RunnerMarginSec"] + (hu[ph] if ph == "p0" else v["BannerSec"] + hu[ph]) + v["DoneReserveSec"] for ph in hp}
            for label, good in (
                    ("host PhaseWorstSec %s = device PHASE_WORST %s" % (hp, PW), hp == PW),
                    ("host RunnerMargin %d, DoneReserve %d, Banner %d, HumanSec %s -> G %s = %s" % (v["RunnerMarginSec"], v["DoneReserveSec"], v["BannerSec"], hu, hg, G), hg == G),
                    ("host IdleSec %d = device IDLE_S %d; host GapCapSec %d <= IDLE_S - 10" % (v["IdleSec"], idle_s, v["GapCapSec"]), v["IdleSec"] == idle_s and v["GapCapSec"] <= idle_s - 10)):
                print("   %s  %s" % ("PASS" if good else "FAIL", label))
                ok &= good
        else:
            pending.append("the guard constants (PhaseWorstSec/HumanSec/RunnerMarginSec/DoneReserveSec/BannerSec/IdleSec/GapCapSec) not located in fs-collect3c.ps1")
    if not pending:
        print("   (all host items located)")
    return ok, pending


if __name__ == "__main__":
    sys.exit(main())
