#!/usr/bin/env python3
"""FrameShift Quest 2 channel - timing consistency check (rev 4, final re-review R3).
Offline; reads source text only; stdlib; run with -I -B. Modelled on
devices/quest3/stage2a/tools/check-timing.py (read, not modified): constants are read where
they are defined, and the record budget must cover the runner's worst case.

    python3 -I -B check-timing.py [--deadline D ...] [--runner-t T] [--ack-window A]
                                  [--margin 15] [--pre-t0 20] [--adapter 5] [--out FILE]

Read from the sources (never copied by hand):
  target/fs-ncm.sh           FS_UDC_WAIT, FS_ROLE_WAIT, FS_RPC_WAIT defaults and the fs_ncm_net
                             address-wait bound: the worst boot-to-RPC_READY (success path;
                             every loop sleeps 1 s per iteration, command time not counted)
  src/fs-rpcd.c              REQ_MS, TRAIL_MS, REAP_MS, REAP_KILL_MS, SWEEP_MS, WRITE_MS,
                             COLLECT_S_MAX
  host/fs-transport-tcp.ps1  ConnectTimeoutMs, PreSendQuietMs, Invoke-FsTcpRequest TimeoutMs
                             defaults, the device-bound copies ($script:FsTcpDev incl. MarginMs)
  host/test-transport-tcp.ps1 the reference per-verb loop (Invoke-RefFlow): status tries and
                             the settle before each status (a future Quest 2 collector must
                             re-run this check with its own values)
  devices/quest3/common/target/pid1-hold.sh  FS_DEADLINE_MAX (the PID 1 deadline clamp)
Planning assumptions (arguments; stated, like Quest 3's COLLECTOR_START_S):
  --pre-t0   BootStartUtc -> PID 1 start: fastboot transfer + kernel boot (default 20 s)
  --adapter  RPC_READY -> the host has found the adapter and converted its deadlines (5 s)
  --margin   host margin before the device deadline (15 s, the Quest 3 HostMarginSec)

Requirements:
  R1 the transport's device-bound copies equal fs-rpcd.c's #defines (incl. COLLECT_S_MAX);
  R2 for each DEADLINE D:  pre_t0 + boot_to_ready + adapter + pre_runner + runner_worst(T)
                           <= D - margin,  runner_worst(T) = T + REQ + TRAIL + REAP + REAP_KILL
                           + SWEEP + WRITE + MarginMs (= T + 44.075 s today).
     T_max(D) = floor(D - margin - pre_t0 - boot_to_ready - adapter - pre_runner - (worst - T));
  R3 COLLECT_S_MAX <= T_max(FS_DEADLINE_MAX): no -T the binary accepts can be unusable for
     every allowed DEADLINE (the -T cap is a function of the PID 1 deadline clamp);
  R4 with --runner-t T: T <= T_max(D) for every --deadline given;
  R5 ack window: pre_t0 + boot_to_ready + adapter + pre_runner <= ACK_WINDOW - margin (the
     pre-runner verbs are capped at the ack-window give-up); reported as the minimum
     ACK_WINDOW, checked when --ack-window is given.
Exit 0 if all hold, else 1.
"""
import argparse
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(HERE))          # devices/


def read(rel):
    with open(os.path.join(HERE, rel), encoding="utf-8") as f:
        return f.read()


def num(rx, text, what):
    m = re.search(rx, text, re.M)
    if not m:
        raise SystemExit("CANNOT READ %s (pattern %s)" % (what, rx))
    return int(m.group(1))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--deadline", type=int, action="append")
    ap.add_argument("--runner-t", type=int)
    ap.add_argument("--ack-window", type=int)
    ap.add_argument("--margin", type=float, default=15.0)
    ap.add_argument("--pre-t0", type=float, default=20.0)
    ap.add_argument("--adapter", type=float, default=5.0)
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    out = []
    p = out.append
    ok = True

    ncm = read("target/fs-ncm.sh")
    udc = num(r'FS_UDC_WAIT:=(\d+)', ncm, "FS_UDC_WAIT")
    role = num(r'FS_ROLE_WAIT:=(\d+)', ncm, "FS_ROLE_WAIT")
    rpcw = num(r'FS_RPC_WAIT:=(\d+)', ncm, "FS_RPC_WAIT")
    netw = num(r'\[ "\$_i" -ge (\d+) \] && fail net "address state', ncm, "fs_ncm_net address wait")
    boot_to_ready = udc + role + netw + rpcw

    c = read("src/fs-rpcd.c")
    dev = {k: num(r'^#define %s\s+(\d+)\b' % k, c, k) for k in
           ("REQ_MS", "TRAIL_MS", "REAP_MS", "REAP_KILL_MS", "SWEEP_MS", "WRITE_MS", "COLLECT_S_MAX")}

    tr = read("host/fs-transport-tcp.ps1")
    conn = num(r'\[int\]\$ConnectTimeoutMs = (\d+)', tr, "ConnectTimeoutMs")
    quiet = num(r'\[int\]\$PreSendQuietMs = (\d+)', tr, "PreSendQuietMs")
    step = num(r'\[string\]\$Verb, \[string\]\$Arg = \'\',\s*\n\s*\[int\]\$TimeoutMs = (\d+)', tr, "Invoke-FsTcpRequest TimeoutMs")
    m = re.search(r'\$script:FsTcpDev = @\{([^}]*)\}', tr)
    if not m:
        raise SystemExit("CANNOT READ $script:FsTcpDev")
    hostdev = {k: int(v) for k, v in re.findall(r'(\w+) = (\d+)', m.group(1))}

    t = read("host/test-transport-tcp.ps1")
    rf = t[t.index("function Invoke-RefFlow"):]
    rf = rf[:rf.index("\n}\n")]
    tries = num(r'for \(\$i = 0; \$i -lt (\d+) -and \$state -eq \'none\'', rf, "RefFlow status tries")
    settle = num(r'Start-Sleep -Milliseconds (\d+)\s*\n\s*\$r = Invoke-FsTcpRequest -Transport \$T -Verb \'fs-status\'', rf, "RefFlow settle")

    hold = open(os.path.join(ROOT, "quest3", "common", "target", "pid1-hold.sh"), encoding="utf-8").read()
    dmax = num(r'^FS_DEADLINE_MAX=(\d+)', hold, "FS_DEADLINE_MAX")

    p("Quest 2 channel timing check (offline; source text only)")
    p("inputs read: fs-ncm.sh UDC_WAIT=%d ROLE_WAIT=%d net-wait=%d RPC_WAIT=%d -> boot_to_ready=%d s (success path)" % (udc, role, netw, rpcw, boot_to_ready))
    p("             fs-rpcd.c %s" % " ".join("%s=%d" % kv for kv in dev.items()))
    p("             transport ConnectTimeoutMs=%d PreSendQuietMs=%d TimeoutMs=%d FsTcpDev=%s" % (conn, quiet, step, hostdev))
    p("             reference loop: status tries=%d settle=%d ms; pid1-hold FS_DEADLINE_MAX=%d" % (tries, settle, dmax))
    p("assumptions: pre_t0=%.1f s adapter=%.1f s margin=%.1f s" % (a.pre_t0, a.adapter, a.margin))

    # R1
    pairs = (("ReqMs", "REQ_MS"), ("TrailMs", "TRAIL_MS"), ("ReapMs", "REAP_MS"), ("ReapKillMs", "REAP_KILL_MS"),
             ("SweepMs", "SWEEP_MS"), ("WriteMs", "WRITE_MS"), ("CollectSMax", "COLLECT_S_MAX"))
    bad = [h for h, d in pairs if hostdev.get(h) != dev[d]]
    p("R1 transport copies == fs-rpcd.c: %s" % ("OK" if not bad else "MISMATCH " + " ".join(bad)))
    ok &= not bad

    req_s = (conn + quiet + step) / 1000.0
    pre_runner = 2 * req_s + tries * (settle / 1000.0 + req_s)
    fixed = (dev["REQ_MS"] + dev["TRAIL_MS"] + dev["REAP_MS"] + dev["REAP_KILL_MS"] + dev["SWEEP_MS"] + dev["WRITE_MS"] + hostdev["MarginMs"]) / 1000.0
    before = a.pre_t0 + boot_to_ready + a.adapter + pre_runner
    p("pre-runner worst (verify + ack + %d x (settle + status)), one request = connect + quiet + timeout = %.3f s: %.3f s" % (tries, req_s, pre_runner))
    p("runner_worst(T) = T + %.3f s;  host time before the runner, from BootStartUtc: %.3f s" % (fixed, before))

    def tmax(d):
        return math.floor(d - a.margin - before - fixed)

    ds = a.deadline or [dmax, 260, 200]
    p("")
    p("| DEADLINE | give-up (D - margin) | before runner | runner_worst(T)-T | T_max |")
    p("|---|---|---|---|---|")
    for d in ds:
        p("| %d | %.1f | %.3f | %.3f | %s |" % (d, d - a.margin, before, fixed, tmax(d) if tmax(d) >= 1 else "none (no collect fits)"))
    # R3
    r3 = dev["COLLECT_S_MAX"] <= tmax(dmax)
    p("R3 COLLECT_S_MAX=%d <= T_max(FS_DEADLINE_MAX=%d)=%d: %s" % (dev["COLLECT_S_MAX"], dmax, tmax(dmax), "OK" if r3 else "FAIL"))
    ok &= r3
    # R4
    if a.runner_t is not None:
        for d in ds:
            r4 = a.runner_t <= tmax(d)
            p("R4 -T %d with DEADLINE %d (T_max %d): %s" % (a.runner_t, d, tmax(d), "OK" if r4 else "FAIL"))
            ok &= r4
    # R5
    min_aw = before + a.margin
    p("R5 minimum ACK_WINDOW for this pre-runner phase: %.3f s" % min_aw)
    if a.ack_window is not None:
        r5 = a.ack_window >= min_aw
        p("R5 ACK_WINDOW %d: %s" % (a.ack_window, "OK" if r5 else "FAIL"))
        ok &= r5
    p("RESULT %s" % ("CONSISTENT" if ok else "INCONSISTENT"))
    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
