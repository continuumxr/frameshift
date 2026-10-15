#!/usr/bin/env python3
"""FrameShift — offline whole-image harness for the STAGE-3C boot image (DESIGN.md §12.3).
Derived from stage3b/tools/image-harness-3b.py (unchanged). Run inside WSL by
stage3c/test-image.sh. Touches no device: no adb, no fastboot, no COM port.

    image-harness-3c.py stage3c IMAGE_DIR OUTDIR SCENARIO

What it runs and what is fake: the ramdisk unpacked FROM THE BUILT IMAGE, its /init as PID 1 of
a bwrap sandbox under qemu-aarch64, the real DEADLINE/ACK_WINDOW/step timeouts and the real
idle limit; fake reboot helpers (they record the reboot and never return); a pty as ttyGS0;
the stage-3b fake sysfs (backlight node 255 writable, card0-DSI-1, card0-sde-crtc-0 incl. the
three decoy nodes that must never be read, pwmfan, pwm-tach-fan0), a bind-mounted
/proc/interrupts, and an empty /sys/kernel/debug (with dri/0) watched by inotify: nothing may
open it (c-no-debugfs). There is NO DRM device: the genuine fs-pattern reports "no device";
the sim-* mods replace /bin/fs-pattern by a replay of framed v0.6 FSP1 streams (run 1 split on
the active splash CRTC; run 2 quad_vig / quad_dma committed, both quads rejected (exit 50) or
CRTC active (exit 31); run 3 the red field on quad_vig), sleeping through the hold, so the
RUNNER's gates, pause, probes, markers and pacing run for real.
The host side follows fs-collect3c.ps1's order (DESIGN §4): fs-verify, fs-ack, fs-status, then
`fs-phase <ph> <chal> <prev>` once per phase with <prev> = the first 16 hex of rec_sha256 of the
previous phase's record as decoded here (common/tools/fsb1.py on that phase's slice), then
fs-done. capture.raw + capture.raw.idx (mode=synthetic) feed the host replay tests.
"""
import hashlib
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../.."))
Q3 = ROOT + "/devices/quest3"
AOSP = ROOT + "/build/third_party/mkbootimg"
FSB1PY = Q3 + "/common/tools/fsb1.py"
CHECK_STREAM = Q3 + "/stage3c/tools/check_stream.py"
BB_REVIEWED = "c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02"
DEADLINE, ACK_WINDOW, IDLE_S, STUCK_S = 200, 150, 120, 180
STEPS = {"p0": ["hash", "probe0"], "r1": ["probe1", "pattern1"], "r2": ["probe2", "pattern2"], "r3": ["probe3", "pattern3"]}
MODE = {"r1": "show", "r2": "show-off-quad", "r3": "show-off-solid"}
HOLD = {"r1": 3, "r2": 10, "r3": 5}
MARKER = re.compile(r"^FSPM1 n=([0-9a-f]{16}) p=(p0|r1|r2|r3) e=(begin|go|end|skip|rec) t=(0|[1-9][0-9]*) END$")
FSXE1 = re.compile(r"^FSXE1 p=(p0|r1|r2|r3|-) ran=([01]) error=(.+) END$")


# ------------------------------------------------------------ FSP1 sims -------
def fsp1(nonce8, recs):
    out = []
    for i, (step, rc, kv) in enumerate(recs):
        body = "FSP1 nonce=%s seq=%d step=%s rc=%d%s" % (nonce8, i, step, rc, (" " + kv) if kv else "")
        out.append("%s len=%d crc=%08x END\n" % (body, len(body), zlib.crc32(body.encode()) & 0xffffffff))
    return out


def sim_run(nonce8, ph, variant):
    """(head, tail, hold, code): the head is printed, the fake sleeps through the hold, then the tail."""
    mode, hold = MODE[ph], HOLD[ph]
    # CLOCK_MONOTONIC stamps (t0_ms, start_ms, deadline_ms): the fake cannot stamp at run time (the records are
    # framed with their crc before the boot), so each phase gets its own fixed base, in run order and spaced like a
    # session (r1 21000, r2 41000, r3 61000 ms). The host classifier derives the pause from these stamps (r2/r3
    # start - (previous start + held + close)): 16466 / 9466 ms here. The real pause is measured by the runner
    # (c-pause checks it on /proc/uptime); one shared base would read as a negative pause (integration pass).
    t0 = {"r1": 20000, "r2": 40000, "r3": 60000}[ph]
    active = 1 if ph == "r1" else 0
    m90 = "w=4128 h=2208 vrefresh=90 clock_khz=2020285 hss=4204 hse=4244 htotal=4352 vss=5126 vse=5128 vtotal=5158 flags=0x0 type=0x8 name=4128x2208x90vid"
    r = [("start", 0, "mode=%s ver=0.6 hold_req=%d hold=%d hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=%d" % (mode, hold, hold, t0)),
         ("open", 0, "dev=/dev/dri/card0 major=226 minor=0"), ("version", 0, "drv=msm_drm major=1 minor=4 patch=0"),
         ("caps", 0, "universal_rc=0 atomic_rc=0"), ("resources", 0, "crtcs=3 connectors=3 encoders=3 fbs=0 max_w=20480 max_h=8640"),
         ("connector", 0, "id=55 type=16 type_id=1 status=1 modes=24 encoders=1 encoder=54 mm_w=0 mm_h=0"),
         ("chosen_connector", 0, "id=55 type=16 connected=2 modes=24 encoder=54"),
         ("mode", 0, "idx=0 %s preferred=1 expected=1" % m90),
         ("pipeline", 0, "encoder=54 crtc=155 crtc_idx=0"),
         ("crtc_state", 0, "idx=-1 %s getcrtc_rc=0 mode_valid=%d fb=0 active_prop=22 active=%d in_list=%d interlaced=0 expected=%d" % (m90, active, active, active, active))]
    if ph != "r1":
        if variant == "active":
            r += [("precondition", -16, "required=crtc_inactive getcrtc_rc=0 active_prop=22 active=1"),
                  ("exit", 0, "code=31 reason=crtc_active shown=0 closed_at_exit=1 elapsed_ms=40")]
            r.append(("eos", 0, "records=%d dropped=0 overflows=0 out=pipe opt_bytes=0 opt_skipped=0" % (len(r) + 1)))
            return "".join(fsp1(nonce8, r)), "", 0, 31
        r.append(("precondition", 0, "required=crtc_inactive getcrtc_rc=0 active_prop=22 active=0"))
    r += [("chosen_mode", 0, "idx=%d %s why=%s expected=1" % (-1 if active else 0, m90, "crtc_current" if active else "expected_4128x2208_90")),
          ("planes", 0, "count=20"),
          ("atomic_props", 0, "primary=71 helper=97 crtc_mode_id=23 crtc_active=22 conn_crtc_id=20"),
          ("conn_topology", 0, "conn=55 props=24 topology_prop=51 topology_val=0 topology_name=sde_none control_prop=52 control_val=0 dsc_mode_prop=63 dsc_mode_val=0 mode_props_blob=60"),
          ("buffer", 0, "w=4128 h=2208 handle=1 pitch=16512 size=36458496 fb=207 mode_blob=208 format=0x34325258" + (" solid=0xff0000" if ph == "r3" else ""))]
    if ph == "r1":
        r += [("plan", 0, "attempts=4 use_current=1 modeset_allowed=1 helper=1"),
              ("test_commit", -22, "attempt=0 modeset=0 layout=single objs=4 props=16 planes_off=3 overflow=0 result=rejected"),
              ("test_commit", -22, "attempt=1 modeset=0 layout=split objs=4 props=24 planes_off=2 overflow=0 result=rejected"),
              ("test_commit", -7, "attempt=2 modeset=1 layout=single objs=6 props=19 planes_off=3 overflow=0 result=rejected"),
              ("test_commit", 0, "attempt=3 modeset=1 layout=split objs=6 props=27 planes_off=2 overflow=0 result=accepted"),
              ("commit", 0, "attempt=3 modeset=1 layout=split commit_ms=643")]
        planes = [(71, 0, 0, 2064, 0), (97, 0, 2064, 2064, 0)]
    else:
        vig = "quad_vig=71.97.100.103 quad_dma=115.134.112.131 pipe_vig=vig-0.vig-1.vig-2.vig-3 pipe_dma=dma-3.dma-3.dma-2.dma-2 max_upscale_vig=20.20.20.20 max_upscale_dma=1.1.1.1 zpos_before_vig=0.0.0.0 zpos_before_dma=0.0.0.0 zpos_set=0.0.1.1 splash_set=match"
        r += [("plan", 0, "attempts=3 split_probe=1 " + vig),
              ("test_commit", 0, "attempt=0 modeset=1 layout=split_probe objs=4 props=23 planes_off=0 overflow=0 result=accepted")]
        if variant in ("vig", "solid"):
            r += [("test_commit", 0, "attempt=1 modeset=1 layout=quad_vig objs=6 props=47 planes_off=0 overflow=0 result=accepted"),
                  ("commit", 0, "attempt=1 modeset=1 layout=quad_vig commit_ms=612")]
            ids = [71, 97, 100, 103]
        else:
            r += [("test_commit", -22, "attempt=1 modeset=1 layout=quad_vig objs=6 props=47 planes_off=0 overflow=0 result=rejected")]
            if variant == "reject":
                r += [("test_commit", -22, "attempt=2 modeset=1 layout=quad_dma objs=6 props=47 planes_off=0 overflow=0 result=rejected"),
                      ("exit", 0, "code=50 reason=no_quad_accepted shown=0 closed_at_exit=1 elapsed_ms=900")]
                r.append(("eos", 0, "records=%d dropped=0 overflows=0 out=pipe opt_bytes=14000 opt_skipped=0" % (len(r) + 1)))
                return "".join(fsp1(nonce8, r)), "", 0, 50
            r += [("test_commit", 0, "attempt=2 modeset=1 layout=quad_dma objs=6 props=47 planes_off=0 overflow=0 result=accepted"),
                  ("commit", 0, "attempt=2 modeset=1 layout=quad_dma commit_ms=598")]
            ids = [115, 134, 112, 131]
        planes = [(ids[k], k, 1032 * k, 1032, k // 2) for k in range(4)]
    r.append(("post_state", 0, "conn=55 topology_val=14 topology_name=sde_quadpipe_dsc4hsmerge dsc_mode_val=0 control_val=0 crtc=155 active=1 mode_id=208 core_clk=550000000 core_ab=16000000000 core_ib=16000000000 llcc_ab=0 llcc_ib=0 dram_ab=0 dram_ib=0 getcrtc_rc=0 mode_valid=1 fb=207"))
    for pid, slot, x, w, z in planes:
        cx = x - 2064 if x >= 2064 else x
        r.append(("post_plane", 0, "slot=%d plane=%d crtc_id=155 fb_id=207 crtc_x=%d crtc_y=0 crtc_w=%d crtc_h=2208 src_x=%d src_y=0 src_w=%d src_h=2208 src_frac=0 zpos=%d" % (slot if ph != "r1" else planes.index((pid, slot, x, w, z)), pid, cx, w, x, w, z)))
    r.append(("hold_start", 0, "hold_s=%d start_ms=%d deadline_ms=%d alarm_s=%d" % (hold, t0 + 1000, t0 + 1000 + hold * 1000, hold + 5)))
    head = r
    close_rc = -5 if variant == "unclean" else 0
    tail = [("hold_end", 0, "reason=deadline sig=0 held_ms=%d late_ms=0 fd_closed=1 close_rc=%d close_ms=534" % (hold * 1000, close_rc)),
            ("exit", 0, "code=0 reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=%d" % (hold * 1000 + 600))]
    allr = head + tail
    allr.append(("eos", 0, "records=%d dropped=0 overflows=0 out=pipe opt_bytes=14168 opt_skipped=0" % (len(allr) + 1)))
    lines = fsp1(nonce8, allr)
    return "".join(lines[:len(head)]), "".join(lines[len(head):]), hold, 0


FAKE_PATTERN = """#!/bin/busybox sh
# HARNESS FAKE of /bin/fs-pattern (sim-* mods only): replays a pre-generated FSP1 stream
case "$1" in show) m=r1 ;; show-off-quad) m=r2 ;; show-off-solid) m=r3 ;; *) exit 2 ;; esac
echo "$*" >> /sim/args
[ -f /sim/$m.pre ] && . /sim/$m.pre
cat /sim/$m.head
h=$(cat /sim/$m.hold)
[ "$h" -gt 0 ] && sleep "$h"
cat /sim/$m.tail
exit $(cat /sim/$m.code)
"""
FAKE_INTERRUPTS = """           CPU0       CPU1       CPU2       CPU3       CPU4       CPU5       CPU6       CPU7
 11:      12345          0          0          0          0          0          0          0     GICv3  27 Level     arch_timer
471:      33236          0          0          0          0          0          0          0   msmgpio 110 Edge      te-edge-isr
472:      33255          0          0          0          0          0          0          0   msmgpio 109 Edge      blu-pwm-isr
"""
FAKE_FINAL = """#!/bin/busybox sh
# HARNESS FAKE of /bin/fs-reboot-final: records, then never exits (like the real one)
read -r u _ < /proc/uptime
echo "$u final pid=$$ arg=${1:-none}" >> /.rec/reboots
while :; do sleep 3600; done
"""
FAKE_REBOOT = """#!/bin/busybox sh
# HARNESS FAKE of /bin/fs-reboot: records, then returns like a failed syscall
read -r u _ < /proc/uptime
echo "$u fork pid=$$ arg=${1:-none}" >> /.rec/reboots
exit 1
"""
ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")


def up():
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def put(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def prepare(image_dir, w, mods):
    img = os.path.join(image_dir, "boot-stage3c.img")
    pyc = os.path.join(w, "pyc")
    run(["python3", "-E", "-s", "-B", "-X", "pycache_prefix=" + pyc, AOSP + "/unpack_bootimg.py",
         "--boot_img", img, "--out", w + "/unp"], stdout=subprocess.DEVNULL)
    r = w + "/root"
    os.makedirs(r)
    lz = subprocess.Popen(["lz4", "-dc", w + "/unp/ramdisk"], stdout=subprocess.PIPE)
    run(["cpio", "-id", "--quiet", "--no-absolute-filenames"], stdin=lz.stdout, cwd=r)
    lz.wait()
    assert sha(open(r + "/bin/busybox", "rb").read()) == BB_REVIEWED, "busybox in the image is not the reviewed one"
    md = r + "/lib/modules"
    os.makedirs(md, exist_ok=True)
    for m in ("fake_a", "fake_b", "fake_c"):
        put(md + "/" + m + ".ko", "")
    put(md + "/modules.load.recovery", "fake_a.ko\nfake_b.ko\nfake_c.ko\n")
    put(md + "/modules.dep", "/lib/modules/fake_c.ko: /lib/modules/fake_a.ko\n/lib/modules/fake_a.ko:\n/lib/modules/fake_b.ko:\n")
    put(md + "/modules.softdep", "softdep fake_b pre: fake_a\n")
    s = r + "/sys"
    put(s + "/class/udc/a600000.dwc3/state", "configured\n")
    put(s + "/devices/platform/soc/a600000.ssusb/mode", "host\n")
    put(s + "/class/usb_role/a600000.dwc3-role-switch/role", "host\n")
    put(s + "/class/firmware/timeout", "60\n")
    for c in ("red", "green", "blue"):
        put(s + "/class/leds/%s/brightness" % c, "0\n")
    os.makedirs(r + "/config/usb_gadget", exist_ok=True)
    os.makedirs(r + "/.rec", exist_ok=True)
    os.makedirs(w + "/rec")
    put(w + "/fake/fs-reboot-final", FAKE_FINAL, 0o755)
    put(w + "/fake/fs-reboot", FAKE_REBOOT, 0o755)
    bl = s + "/class/backlight/panel0-backlight"
    put(bl + "/brightness", "255\n", 0o644)
    put(bl + "/actual_brightness", "0\n", 0o444)
    put(bl + "/bl_power", "0\n", 0o444)
    put(bl + "/max_brightness", "255\n", 0o444)
    for f, v in (("status", "connected"), ("enabled", "enabled"), ("dpms", "On")):
        put(s + "/class/drm/card0-DSI-1/" + f, v + "\n", 0o444)
    cr = s + "/class/drm/card0-sde-crtc-0"
    for f, v in (("backlight_timing", "55,4828,4828"), ("backlight_event", "BACKLIGHT=7197969,4972614692528,909583"),
                 ("active_event", "ACTIVE=1868543,4972593066018,3315573"), ("measured_fps", "fps: 0.0 duration:1000000 frame_count:0"),
                 ("vsync_timing", "32,2208,2918@90"), ("blu_default_duty", "82"), ("fifo_trim", "40"), ("blu_max_overlap_us", "500")):
        put(cr + "/" + f, v + "\n", 0o444)
    put(s + "/class/hwmon/hwmon2/name", "pwmfan\n", 0o444)
    put(s + "/class/hwmon/hwmon2/rpm", "0\n", 0o444)
    put(s + "/class/hwmon/hwmon2/pwm", "0\n", 0o444)
    put(s + "/class/hwmon/hwmon0/name", "bq27z561_0\n", 0o444)
    put(s + "/class/thermal/cooling_device4/type", "pwm-tach-fan0\n", 0o444)
    put(s + "/class/thermal/cooling_device4/cur_state", "0\n", 0o444)
    os.makedirs(s + "/kernel/debug/dri/0", exist_ok=True)       # watched: nothing may open it
    put(s + "/kernel/debug/dri/0/state", "decoy\n", 0o444)
    put(w + "/fake/interrupts", FAKE_INTERRUPTS, 0o444)
    os.makedirs(r + "/sim", exist_ok=True)
    notes = []
    for m in mods:
        notes.append(apply_mod(r, m))
    return r, notes


def apply_mod(r, m):
    if m.startswith("sim-"):
        put(r + "/bin/fs-pattern", FAKE_PATTERN, 0o755)
        return "replaced /bin/fs-pattern by a replay of pre-generated v0.6 FSP1 streams (%s); the hash step measures the replacement" % m
    if m == "no-backlight":
        shutil.rmtree(r + "/sys/class/backlight")
        return "removed /sys/class/backlight (the write and the read-back must fail: no run may start)"
    raise SystemExit("unknown mod " + m)


def write_sims(r, chals, variant):
    v2 = {"sim-all": "vig", "sim-dma": "dma", "sim-reject": "reject", "sim-active": "active", "sim-bigerr": "vig",
          "sim-stepfail": "vig", "sim-unclean": "vig"}[variant]
    for ph in ("r1", "r2", "r3"):
        var = {"r1": "unclean" if variant == "sim-unclean" else "split", "r2": v2, "r3": "solid"}[ph]
        head, tail, hold, code = sim_run(chals[ph][:8], ph, var)
        put(r + "/sim/%s.head" % ph, head)
        put(r + "/sim/%s.tail" % ph, tail)
        put(r + "/sim/%s.hold" % ph, "%d\n" % hold)
        put(r + "/sim/%s.code" % ph, "%d\n" % code)
    if variant == "sim-bigerr":       # run 1 also fills stdout and stderr to their caps: the record exceeds MAXLINES_r1
        put(r + "/sim/r1.pre", "head -c 60000 /dev/zero | tr '\\000' x >&2; head -c 60000 /dev/zero | tr '\\000' y\n")
    if variant == "sim-stepfail":     # run 1 deletes the record file under construction: fsb1_step fails (step1)
        put(r + "/sim/r1.pre", "rm -f /run/fsb3c/r1/record\n")


# ----------------------------------------------------------------- host ------
class Host:
    def __init__(self, master):
        self.m = master
        self.buf = bytearray()
        self.chunks = []      # (offset, length, ms)
        self.writes = []      # (offset, ms, text)
        self.t0 = time.monotonic()
        self.last_rx = time.monotonic()
        self.log = []

    def ms(self):
        return int((time.monotonic() - self.t0) * 1000)

    def pump(self, dt):
        end = time.monotonic() + dt
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            r, _, _ = select.select([self.m], [], [], min(left, 0.05))
            if r:
                try:
                    d = os.read(self.m, 65536)
                except OSError:
                    d = b""
                if d:
                    self.chunks.append((len(self.buf), len(d), self.ms()))
                    self.buf += d
                    self.last_rx = time.monotonic()
                else:
                    time.sleep(0.05)

    def write(self, text):
        assert re.fullmatch(r"[a-z0-9 -]{1,80}", text)
        self.writes.append((len(self.buf), self.ms(), text))
        self.log.append("%7d ms  W %s" % (self.ms(), text))
        os.write(self.m, text.encode() + b"\n")

    def lines_from(self, off):
        return [raw.rstrip(b"\r") for raw in bytes(self.buf[off:]).split(b"\n")[:-1]]

    def find_record(self, off, tag):
        for l in self.lines_from(off):
            if l.startswith(tag.encode() + b" ") and (tag == "FSB1 END" or l.endswith(b" END")):
                return l.decode("latin-1")
        return None

    def prompt_settled(self, off):
        tail = bytes(self.buf[off:]).rsplit(b"\n", 1)[-1]
        v = ESC.sub(b"", tail).replace(b"\r", b"")
        return (v.endswith(b"# ") or v.endswith(b"$ ")) and time.monotonic() - self.last_rx >= 0.15

    def wait(self, pred, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred():
                return True
            self.pump(0.05)
        return pred()

    def command(self, verb, arg, tag, timeout):
        off = len(self.buf)
        self.write((verb + " " + arg).strip())
        got = self.wait(lambda: self.find_record(off, tag) is not None, timeout)
        rec = self.find_record(off, tag)
        if not got:
            self.log.append("%7d ms  no %s completion within %ss" % (self.ms(), tag, timeout))
            return None
        ok = self.wait(lambda: self.prompt_settled(off), 5)
        self.log.append("%7d ms  R %s%s" % (self.ms(), rec[:150], "" if ok else "  (no settled prompt)"))
        return rec if ok else None

    def phase(self, ph, chal, prev, timeout=150):
        """send fs-phase once; complete on FSB1 END or FSXE1; returns (slice bytes, end line, refusal line)"""
        off = len(self.buf)
        self.write("fs-phase %s %s %s" % (ph, chal, prev))
        done = lambda: self.find_record(off, "FSB1 END") is not None or self.find_record(off, "FSXE1") is not None
        got = self.wait(done, timeout)
        ok = got and self.wait(lambda: self.prompt_settled(off), 8)
        end, ref = self.find_record(off, "FSB1 END"), self.find_record(off, "FSXE1")
        self.log.append("%7d ms  R %s%s" % (self.ms(), (end or ref or "no completion")[:150], "" if ok else "  (no settled prompt)"))
        return bytes(self.buf[off:]), end, ref, ok


def index_text(h, nonce):
    base = h.chunks[0][2] if h.chunks else 0
    out = ["FSIDX1 nonce=%s mode=synthetic port=-" % nonce]
    ev = [(o, max(0, ms - base), 1, "R %d %d %d" % (o, n, max(0, ms - base))) for (o, n, ms) in h.chunks]
    ev += [(o, max(0, ms - base), 0, "W %d %d %s" % (o, max(0, ms - base), t)) for (o, ms, t) in h.writes]
    ev.sort(key=lambda e: (e[0], e[2], e[1]))
    last = 0
    for o, ms, _, line in ev:
        if ms < last:
            parts = line.split(" ")
            if parts[0] == "R":
                parts[3] = str(last)
            else:
                parts[2] = str(last)
            line = " ".join(parts)
            ms = last
        last = ms
        out.append(line)
    return "\n".join(out) + "\n"


def inotify_watch(paths, events, stop, mask=0x20 | 0x01):
    """MASK (default IN_OPEN | IN_ACCESS: the fake /sys/kernel/debug tree) on every path: any event is recorded.
    The backlight node is watched with IN_CLOSE_WRITE (0x08): one event per write-open that was closed."""
    import ctypes
    import struct
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.inotify_init1(os.O_NONBLOCK)
    if fd < 0:
        events.append("inotify-unavailable")
        return None
    for p in paths:
        if libc.inotify_add_watch(fd, p.encode(), mask) < 0:
            events.append("watch-failed " + p)

    def loop():
        try:
            while not stop.is_set():
                r, _, _ = select.select([fd], [], [], 0.2)
                if r:
                    try:
                        d = os.read(fd, 4096)
                    except OSError:
                        continue
                    i = 0
                    while i + 16 <= len(d):
                        wd, mask, cookie, ln = struct.unpack_from("iIII", d, i)
                        name = d[i + 16:i + 16 + ln].rstrip(b"\0").decode("latin-1")
                        events.append("wd=%d mask=0x%x %s" % (wd, mask, name))
                        i += 16 + ln
        finally:
            os.close(fd)
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t


# ------------------------------------------------------------- scenario ------
# plan: list of phases to send ("p0", "r1", ...; "p0!" re-sends p0; "r1~" sends r1 with a wrong prev;
#   "p0?" sends a MALFORMED p0 (challenge "nothex": a usage refusal of the very first command, build review MINOR-1)
#   special host actions: "pause-fault" (future r1.end_cs before r2), "hang-probes" (measured_fps -> FIFO
#   after p0), "stuck" (running + old activity after p0), "time" (a near deadline before p0)
# then "done" | "no-done" | "idle" | "none" | "verify-only" | "verify-done"
# expect per phase: "valid" dict(r=("exited", code) | "skip:<why>") or ("refused", ran, why)
SCEN = {
    "c-nodrm": ([], ["p0", "r1", "r2"], "done", "collected",
                {"p0": {}, "r1": {"run": ("exited", 10)}, "r2": {"run": "skip:run1-supervisor"}}),
    "c-sim-all": (["sim-all"], ["p0", "r1", "r2", "r3"], "done", "collected",
                  {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0), "layout": "quad_vig"}, "r3": {"run": ("exited", 0), "layout": "quad_vig"}}),
    "c-sim-r2-dma": (["sim-dma"], ["p0", "r1", "r2", "r3"], "done", "collected",
                     {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0), "layout": "quad_dma"}, "r3": {"run": ("exited", 0)}}),
    "c-sim-r2-reject": (["sim-reject"], ["p0", "r1", "r2", "r3"], "done", "collected",
                        {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 50)}, "r3": {"run": "skip:run2-supervisor"}}),
    "c-sim-active": (["sim-active"], ["p0", "r1", "r2"], "done", "collected",
                     {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 31)}}),
    "c-sim-unclean": (["sim-unclean"], ["p0", "r1", "r2"], "done", "collected",
                      {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": "skip:run1-close-not-clean"}}),
    # build review (R-B helper, mutation 3): after the refused r2 an otherwise valid r1 must be refused too (closed)
    "c-order": ([], ["p0", "r2", "r1"], "done", "collected", {"p0": {}, "r2": ("refused", "0", "order"), "r1": ("refused", "0", "order"), "closed": True}),
    "c-repeat": ([], ["p0", "p0!"], "done", "collected", {"p0": {}, "p0!": ("refused", "0", "already-run")}),
    "c-chain-bad": ([], ["p0", "r1~"], "done", "collected", {"p0": {}, "r1~": ("refused", "0", "chain")}),
    "c-time": ([], ["time", "p0"], "done", "collected", {"p0": ("refused", "0", "time")}),
    "c-pause": (["sim-all"], ["p0", "r1", "pause-now", "r2"], "done", "collected",
                {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0), "pause": True}}),
    "c-pause-fault": (["sim-all"], ["p0", "r1", "pause-fault", "r2"], "done", "collected",
                      {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": "skip:pause-fault"}}),
    "c-idle": ([], ["p0", "r1"], "idle", "collected", {"p0": {}, "r1": {"run": ("exited", 10)}}),
    "c-idle-stuck": ([], ["p0", "stuck"], "idle-stuck", "collected", {"p0": {}}),
    "c-no-ack": ([], [], "verify-only", "no-host-ack", {}),
    "c-ack-no-done": ([], [], "no-done", "deadline", {}),
    "c-done-early": ([], [], "verify-done", "collected", {}),
    "c-markers": (["sim-all"], ["p0", "r1", "r2", "r3"], "done", "collected",
                  {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0)}, "r3": {"run": ("exited", 0)}, "markers": True}),
    "c-probe-hang": ([], ["p0", "hang-probes", "r1", "r2"], "done", "collected",
                     {"p0": {}, "r1": {"run": "skip:probe-late", "probe_nosup": True}, "r2": {"run": "skip:run1-not-run", "probe_nosup": True}}),
    "c-no-backlight": (["no-backlight"], ["p0", "r1", "r2"], "done", "collected",
                       {"p0": {"bl": "none"}, "r1": {"run": "skip:p0-write-missing", "rbl": "none"}, "r2": {"run": "skip:run1-not-run", "rbl": "none"}}),
    "c-record-too-large": (["sim-bigerr"], ["p0", "r1"], "done", "collected",
                           {"p0": {}, "r1": ("refused", "1", "record-too-large")}),
    "c-step-fail": (["sim-stepfail"], ["p0", "r1"], "done", "collected", {"p0": {}, "r1": ("refused", "1", "step1")}),
    "c-sim-r3-hold": (["sim-all"], ["p0", "r1", "r2", "r3"], "done", "collected",
                      {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0)}, "r3": {"run": ("exited", 0), "hold5": True}}),
    "c-no-debugfs": (["sim-all"], ["p0", "r1", "r2", "r3"], "done", "collected",
                     {"p0": {}, "r1": {"run": ("exited", 0)}, "r2": {"run": ("exited", 0)}, "r3": {"run": ("exited", 0)}, "debugfs": True}),
    # build review MINOR-1: a malformed FIRST command (before /run/fsb3c existed) closes the session too
    "c-usage-then-p0": ([], ["p0?", "p0"], "done", "collected",
                        {"p0?": ("refused", "0", "usage"), "p0": ("refused", "0", "order"), "closed": True}),
}


def scenario(name, image_dir, outdir):
    mods, plan, tail, want, expect = SCEN[name]
    od = os.path.join(outdir, name)
    shutil.rmtree(od, ignore_errors=True)
    os.makedirs(od)
    scratch = os.path.expanduser("~/work/fsimg-harness-3c")
    os.makedirs(scratch, exist_ok=True)
    w = tempfile.mkdtemp(prefix=name + ".", dir=scratch)
    res = {"scenario": name, "mods": mods, "plan": plan, "tail": tail, "want_reboot": want, "checks": [], "phases": {}}

    def check(label, ok, detail=""):
        res["checks"].append({"label": label, "ok": bool(ok), "detail": detail})

    stop = threading.Event()
    try:
        r, notes = prepare(image_dir, w, mods)
        res["mod_notes"] = notes
        nonce = re.search(r'^NONCE="([0-9a-f]{16})"$', open(r + "/init").read(), re.M).group(1)
        dbg_events = []
        inotify_watch([r + "/sys/kernel/debug", r + "/sys/kernel/debug/dri", r + "/sys/kernel/debug/dri/0"], dbg_events, stop)
        # build review (R-B helper, mutation 4): the single backlight write is counted on the node itself, not from the probe text
        bl_events = []
        bl_node = r + "/sys/class/backlight/panel0-backlight/brightness"
        bl_thread = inotify_watch([bl_node], bl_events, stop, 0x08) if os.path.exists(bl_node) else None
        m, s = pty.openpty()
        slave = os.ttyname(s)
        info_r, info_w = os.pipe()
        cmd = ["bwrap", "--bind", r, "/", "--dev", "/dev", "--proc", "/proc",
               "--ro-bind", w + "/fake/interrupts", "/proc/interrupts",
               "--dev-bind", slave, "/dev/ttyGS0",
               "--ro-bind", w + "/fake/fs-reboot-final", "/bin/fs-reboot-final",
               "--ro-bind", w + "/fake/fs-reboot", "/bin/fs-reboot",
               "--bind", w + "/rec", "/.rec",
               "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--as-pid-1",
               "--die-with-parent", "--cap-drop", "ALL", "--clearenv",
               "--setenv", "HOME", "/", "--setenv", "TERM", "linux",
               "--info-fd", str(info_w), "/bin/busybox", "sh", "/init"]
        t_start = up()
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=open(od + "/bwrap.out", "wb"),
                             stderr=subprocess.STDOUT, pass_fds=(info_w,), start_new_session=True)
        os.close(info_w)
        info = b""
        while True:
            d = os.read(info_r, 4096)
            if not d:
                break
            info += d
            if b"}" in info:
                break
        child = json.loads(info.decode())["child-pid"]
        h = Host(m)
        chal = os.urandom(16).hex()
        ack = os.urandom(8).hex()
        chals = {ph: os.urandom(16).hex() for ph in ("p0", "r1", "r2", "r3")}
        res.update(nonce=nonce, verify_challenge=chal, ack=ack, challenges=chals)
        for m_ in mods:
            if m_.startswith("sim-"):
                write_sims(r, chals, m_)
        h.wait(lambda: h.prompt_settled(0), 90)
        h.pump(1.0)
        fsv = None
        if tail != "none":
            fsv = h.command("fs-verify", chal, "FSV1", 20)
            if fsv:
                kv = dict(x.split("=", 1) for x in fsv.split(" ")[1:-1] if "=" in x)
                check("FSV1 response = sha256(nonce:challenge)", kv.get("resp") == sha(("%s:%s" % (nonce, chal)).encode()), fsv[:120])
                check("FSV1 stages end with SHELL_READY", kv.get("stages", "").endswith("SHELL_READY"), kv.get("stages"))
            else:
                check("FSV1 received", False)
        t_done = None
        prev = "0" * 16
        sha16 = {}
        slices = {}
        if tail == "verify-done":
            d = h.command("fs-done", "", "FSD1", 10)
            t_done = up()
            check("FSD1 queued", d == "FSD1 queued END", d or "")
        elif tail not in ("verify-only", "none"):
            a = h.command("fs-ack", ack, "FSA1", 10)
            check("FSA1 queued", a == "FSA1 queued END", a or "")
            st = None
            for _ in range(3):
                h.pump(2.5)
                st = h.command("fs-status", "", "FSS1", 10)
                if st and ("acked=%s " % ack) in st and "HOST_ACK" in st:
                    break
            check("FSS1 shows HOST_ACK recorded", bool(st) and ("acked=%s " % ack) in st, st or "")
            for step in plan:
                if step == "time":   # a deadline about 20 s ahead, written from outside: PHASE_WORST_p0 23 + 5 does not fit
                    put(r + "/run/fs.deadline", "%d\n" % (sandbox_uptime(child) + 20))
                    continue
                if step == "pause-now":   # run 1 "ended just now" (the record emission otherwise outlasts the 2 s pause)
                    ecs = int(float(open("/proc/uptime").read().split()[0]) * 100)
                    put(r + "/run/fsb3c/r1.end_cs", "%d\n" % ecs)
                    res["pause_end_cs"] = ecs
                    continue
                if step == "pause-fault":
                    put(r + "/run/fsb3c/r1.end_cs", "%d\n" % (sandbox_uptime(child) * 100 + 100000))
                    continue
                if step == "hang-probes":
                    pth = r + "/sys/class/drm/card0-sde-crtc-0/measured_fps"
                    os.unlink(pth); os.mkfifo(pth, 0o444)
                    continue
                if step == "stuck":
                    # the activity must be a valid (non-negative) uptime 150 s in the past: on a freshly started WSL VM
                    # (uptime < 150 s) wait first, else fs-idle.sh rejects the negative value and never fires
                    while sandbox_uptime(child) < 151:
                        h.pump(0.5)
                    put(r + "/run/fsb3c/running", "")
                    act = sandbox_uptime(child) - 150
                    put(r + "/run/fsb3c/activity", "%d\n" % act)
                    res["stuck_activity"] = act
                    continue
                ph = step[:2]
                pv = prev
                if step.endswith("~"):
                    pv = "f" * 16
                sl, end, ref, ok = h.phase(ph, "nothex" if step.endswith("?") else chals[ph], pv)
                slices[step] = sl
                key = step
                open(od + "/phase-%s.raw" % key.replace("!", "-again").replace("~", "-badchain").replace("?", "-usage"), "wb").write(sl)
                res["phases"][key] = {"end": end, "refusal": ref, "settled": ok}
                if end and ok:
                    dd = od + "/payloads-" + ph
                    shutil.rmtree(dd, ignore_errors=True)
                    os.makedirs(dd)
                    sp = od + "/phase-%s.raw" % key
                    pr = subprocess.run(["python3", "-I", FSB1PY, "check", "--exp", "s3c_" + ph, "--nonce", nonce, "--chal", chals[ph],
                                         "--steps", ",".join(STEPS[ph]), "--dump", dd, sp], capture_output=True, text=True)
                    open(od + "/fsb1-%s.txt" % ph, "w").write(pr.stdout + pr.stderr)
                    res["phases"][key]["fsb1"] = pr.stdout.splitlines()[0] if pr.stdout else pr.stderr[:200]
                    if pr.returncode == 0:
                        rs = re.search(r"rec_sha256=([0-9a-f]{64})", end).group(1)
                        sha16[ph] = rs[:16]
                        prev = rs[:16]
                if ref and not end:
                    pass
            if tail == "done":
                d = h.command("fs-done", "", "FSD1", 10)
                t_done = up()
                check("FSD1 queued", d == "FSD1 queued END", d or "")
        limit = {"collected": 15, "no-host-ack": ACK_WINDOW + 40, "deadline": DEADLINE + 40}[want]
        if tail == "idle":
            limit = IDLE_S + 30
        if tail == "idle-stuck":
            limit = 60
        rp = w + "/rec/reboots"
        end_t = time.monotonic() + limit
        while time.monotonic() < end_t and not (os.path.exists(rp) and os.path.getsize(rp) > 0):
            h.pump(0.2)
        h.pump(1.5)
        reboots = open(rp).read() if os.path.exists(rp) else ""
        res["reboots"] = reboots
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
        os.close(m)
        os.close(s)
        stop.set()
        res["sim_args"] = open(r + "/sim/args").read() if os.path.exists(r + "/sim/args") else ""
        open(od + "/capture.raw", "wb").write(bytes(h.buf))
        open(od + "/capture.raw.idx", "w").write(index_text(h, nonce))
        open(od + "/host.log", "w").write("\n".join(h.log) + "\n")
        for f in ("fs.log", "fs.stages", "fs.acked", "fs.collected", "fs.deadline"):
            if os.path.exists(r + "/run/" + f):
                shutil.copy(r + "/run/" + f, od + "/" + f)
        log = open(r + "/run/fs.log").read() if os.path.exists(r + "/run/fs.log") else ""
        mt0 = re.search(r"DEADLINE armed t0=(\d+) deadline=T0\+(\d+) ack_window=(\d+)", log)
        check("deadline armed with the image's values (200 / 150)", bool(mt0) and int(mt0.group(2)) == DEADLINE and int(mt0.group(3)) == ACK_WINDOW,
              mt0.group(0) if mt0 else "no DEADLINE line")
        check("backstop armed", "BACKSTOP armed" in log)
        check("idle limit started before SHELL_READY", "IDLE_LIMIT started" in log and log.find("IDLE_LIMIT started") < log.find("STAGE=SHELL_READY"))
        if mt0 and name != "c-time":
            dlf = open(r + "/run/fs.deadline").read().strip() if os.path.exists(r + "/run/fs.deadline") else ""
            check("/run/fs.deadline = T0 + DEADLINE", dlf == str(int(mt0.group(1)) + DEADLINE), "%s vs t0=%s" % (dlf, mt0.group(1)))
        first = reboots.splitlines()[0] if reboots else ""
        fm = re.match(r"([0-9.]+) (final|fork) pid=(\d+) arg=(\S+)", first)
        check("first reboot reason = %s" % want, bool(fm) and fm.group(4) == want, first or "no reboot recorded")
        check("PID 1 rebooted by exec of fs-reboot-final (via=final, pid=1)", bool(fm) and fm.group(2) == "final" and fm.group(3) == "1", first)
        later = reboots.splitlines()[1:]
        check("any later record is only the backstop (fork) at T0+DEADLINE+1",
              all(re.match(r"[0-9.]+ fork pid=\d+ arg=backstop$", x) for x in later), " | ".join(later))
        if fm and mt0:
            tr = float(fm.group(1))
            T0 = int(mt0.group(1))
            res["reboot_at_T0_plus"] = round(tr - T0, 1)
            if want == "collected" and t_done:
                check("reboot within 3 s of fs-done", tr - t_done <= 3.0, "%.1f s" % (tr - t_done))
            if want == "deadline":
                check("deadline reboot at T0+DEADLINE..+3 (HOST_ACK did not cancel it; idle limit unarmed without p0)",
                      DEADLINE <= tr - T0 <= DEADLINE + 3, "T0+%.1f" % (tr - T0))
            if want == "no-host-ack":
                msr = re.search(r"t=(\d+)s STAGE=SHELL_READY", log)
                if msr:
                    check("no-ack reboot at loop start + ACK_WINDOW..+3", ACK_WINDOW - 1 <= tr - int(msr.group(1)) <= ACK_WINDOW + 3,
                          "SHELL_READY+%.1f" % (tr - int(msr.group(1))))
            if tail in ("idle", "idle-stuck"):
                col = open(od + "/fs.collected").read().strip() if os.path.exists(od + "/fs.collected") else ""
                act = res.get("stuck_activity")
                if act is None:
                    act = int(open(r + "/run/fsb3c/activity").read().strip())
                lim = STUCK_S if tail == "idle-stuck" else IDLE_S
                check("idle limit fired: fs.collected = idle, reboot collected at activity + %d s (+0..2)" % lim,
                      col == "idle" and lim <= tr - act <= lim + 3.5, "token=%s reboot at activity+%.1f" % (col, tr - act))
        # FSXE1 / record checks per phase
        for step, exp in expect.items():
            if step in ("markers", "debugfs", "closed"):
                continue
            ph_ = res["phases"].get(step)
            if ph_ is None:
                check("phase %s was sent" % step, False)
                continue
            if isinstance(exp, tuple):
                ref = ph_["refusal"] or ""
                mm = FSXE1.match(ref)
                check("phase %s refused: FSXE1 ran=%s error=%s..." % (step, exp[1], exp[2]),
                      bool(mm) and mm.group(2) == exp[1] and mm.group(3).startswith(exp[2]) and ph_["end"] is None, ref)
                if mm and exp[2] == "record-too-large":
                    check("record-too-large carries lines=N max=1545", re.search(r"lines=\d+ max=1545$", mm.group(3)) is not None, mm.group(3))
                sl = slices.get(step, b"")
                mk = [l for l in sl.split(b"\n") if l.startswith(b"FSPM1")]
                if exp[1] == "0":
                    check("phase %s ran=0: no marker, no record" % step, not mk and b"FSB1 BEGIN" not in sl, str(mk[:2]))
                else:
                    check("phase %s ran=1: markers begin/go/end precede the refusal, no rec marker, no END" % step,
                          [MARKER.match(l.decode().rstrip("\r")).group(3) for l in mk if MARKER.match(l.decode().rstrip("\r"))] == ["begin", "go", "end"]
                          and b"FSB1 END" not in sl, str(mk))
                continue
            check("phase %s FSB1 VALID (exp s3c_%s, 2 steps, its own challenge)" % (step, step[:2]),
                  str(ph_.get("fsb1", "")).startswith("VALID"), str(ph_.get("fsb1")))
            check3c(check, step[:2], exp, od, res, chals, nonce, slices.get(step, b""), h, expect)
        if expect.get("closed"):
            first_ok = "p0" in expect and not isinstance(expect["p0"], tuple)
            check("a refusal left /run/fsb3c/closed (every later phase refused 'order'); %s" % ("only p0 ran" if first_ok else "no phase directory was made"),
                  os.path.isfile(r + "/run/fsb3c/closed") and (first_ok and not os.path.exists(r + "/run/fsb3c/r1") or
                                                                  not first_ok and not os.path.exists(r + "/run/fsb3c/p0") and not os.path.exists(r + "/run/fsb3c/activity")),
                  " ".join(sorted(os.listdir(r + "/run/fsb3c"))) if os.path.isdir(r + "/run/fsb3c") else "no /run/fsb3c")
        # chain: what the device stored equals what the host decoded
        for ph, s16 in sha16.items():
            dev = open(r + "/run/fsb3c/%s.sha16" % ph).read().strip() if os.path.exists(r + "/run/fsb3c/%s.sha16" % ph) else ""
            check("chain %s: device sha16 (from its END line) = host decode" % ph, dev == s16, "%s / %s" % (dev, s16))
        if True:   # every scenario (c-no-debugfs is the full-session instance)
            check("no debugfs access during the scenario (inotify on the fake /sys/kernel/debug tree: 0 events)", not dbg_events, " | ".join(dbg_events[:5]))
        # the one backlight write per boot, measured on the node (IN_CLOSE_WRITE): exactly 1 when p0's probe ran
        # with a backlight node, 0 otherwise (no p0, p0 refused, c-no-backlight)
        if bl_thread is not None:
            bl_thread.join(1.0)
        p0r = res["phases"].get("p0") or {}
        want_bl = 1 if ("no-backlight" not in mods and p0r.get("end")) else 0
        n_bl = sum(1 for e in bl_events if re.match(r"wd=\d+ mask=0x8\b", e))
        check("backlight node written exactly %d time(s) during the scenario (inotify IN_CLOSE_WRITE on the fake panel0-backlight/brightness)" % want_bl,
              n_bl == want_bl and not [e for e in bl_events if e.startswith("inotify-unavailable") or e.startswith("watch-failed")],
              "%d write-close event(s): %s" % (n_bl, " | ".join(bl_events[:5])))
        # build review (R-B helper, mutations 6/61): nothing but the expected protocol reaches the tty (fs-idle.sh and
        # every other background writer must never write it): every capture line is the shell banner (before the first
        # host write), an echoed host command (in order, behind the prompt), a record/marker/refusal line, an empty line,
        # or the final prompt
        stray = tty_strays(bytes(h.buf), [t for (_, _, t) in h.writes])
        check("tty accounting: every byte of the capture belongs to the banner, an echoed command, a record, marker or refusal line, or a prompt (no stray tty output)",
              not stray, " | ".join(stray[:4]))
        # the decoy nodes and debugfs never appear in any probe output
        allp = b"".join(open(os.path.join(od, f), "rb").read() for f in sorted(os.listdir(od)) if f.startswith("phase-"))
        check("probes never named the decoy crtc nodes or debugfs", b"blu_default_duty" not in allp and b"fifo_trim" not in allp
              and b"blu_max_overlap" not in allp and b"/sys/kernel/debug" not in allp, "")
        check("modules attempted in order fake_a, fake_b, fake_c", re.findall(r"MODULE_FAIL (fake_\w)\.ko", log) == ["fake_a", "fake_b", "fake_c"])
        res["ok"] = all(c["ok"] for c in res["checks"])
        res["t_total_s"] = round(up() - t_start, 1)
        json.dump(res, open(od + "/meta.json", "w"), indent=1, sort_keys=True, default=str)
        with open(od + "/result.txt", "w") as f:
            f.write("# %s mods=%s plan=%s tail=%s; image %s\n" % (name, mods, plan, tail, image_dir))
            for n_ in res.get("mod_notes", []):
                f.write("# mod: %s\n" % n_)
            f.write("# reboots: %s\n" % reboots.strip().replace("\n", " | "))
            for c in res["checks"]:
                f.write("%s  %s%s\n" % ("PASS" if c["ok"] else "FAIL", c["label"], ("  [" + c["detail"] + "]") if c["detail"] else ""))
            f.write("SCENARIO %s %s\n" % (name, "PASS" if res["ok"] else "FAIL"))
        return res["ok"]
    finally:
        stop.set()
        shutil.rmtree(w, ignore_errors=True)


TTY_REC = re.compile(r"^(FS(V1|A1|S1|D1|XE1) [ -~]* END|FSPM1 n=[0-9a-f]{16} p=(p0|r1|r2|r3) e=(begin|go|end|skip|rec) t=[0-9]+ END|FSB1 (BEGIN|STEP|DATA|END) [ -~]+)$")
TTY_PROMPT = re.compile(r"^~ [#$] ")


def tty_strays(buf, writes):
    """the capture lines that are not part of the expected exchange (see the check above)"""
    out = []
    lines = [ESC.sub(b"", l).replace(b"\r", b"").decode("latin-1") for l in buf.split(b"\n")]
    tail = lines.pop() if lines else ""
    wi = 0
    for n, l in enumerate(lines):
        if l == "" or TTY_REC.match(l):
            continue
        if wi == 0 and (l.startswith("BusyBox v") or l == "Enter 'help' for a list of built-in commands."):
            continue
        m = TTY_PROMPT.match(l)
        if m and wi < len(writes) and l[m.end():] == writes[wi]:
            wi += 1
            continue
        out.append("line %d: %r" % (n + 1, l[:80]))
    if tail not in ("", "~ # ", "~ $ "):
        out.append("tail: %r" % tail[:80])
    if wi != len(writes):
        out.append("%d of %d host writes echoed" % (wi, len(writes)))
    return out


def sandbox_uptime(child):
    """the sandbox shares the host kernel's uptime (no time namespace): whole seconds"""
    return int(float(open("/proc/uptime").read().split()[0]))


def markers_of(sl):
    out = []
    for raw in sl.split(b"\n"):
        l = raw.rstrip(b"\r")
        if l.startswith(b"FSPM1"):
            out.append(l.decode("latin-1"))
    return out


def check3c(check, ph, exp, od, res, chals, nonce, sl, h, expect):
    dd = od + "/payloads-" + ph

    def out(i):
        p = dd + "/%d.out" % i
        return open(p, "rb").read() if os.path.exists(p) else b""
    stl = open(od + "/fsb1-%s.txt" % ph).read()
    steps = {}
    for l in stl.splitlines():
        mm = re.match(r"\s+step (\d+) (\w+) end=(\S+) code=(-?\d+) sig=(\d+)", l)
        if mm:
            steps[int(mm.group(1))] = (mm.group(2), mm.group(3), int(mm.group(4)))
    check("%s steps in order %s" % (ph, ",".join(STEPS[ph])), [steps.get(i, ("?",))[0] for i in (1, 2)] == STEPS[ph], str(steps))
    # markers: grammar, <= 64 B, nonce, order, none after rec, rec right before the record's empty line
    mk = markers_of(sl)
    gram = all(MARKER.match(x) and len(x) + 1 <= 64 and "FSB1" not in x and MARKER.match(x).group(1) == nonce and MARKER.match(x).group(2) == ph for x in mk)
    ev = [MARKER.match(x).group(3) for x in mk if MARKER.match(x)]
    run = exp.get("run")
    want_ev = ["begin", "rec"] if ph == "p0" else (["begin", "skip", "rec"] if isinstance(run, str) else ["begin", "go", "end", "rec"])
    lines = [l.rstrip(b"\r") for l in sl.split(b"\n")]
    ir = [k for k, l in enumerate(lines) if l.startswith(b"FSPM1") and b" e=rec " in l]
    ib = [k for k, l in enumerate(lines) if l.startswith(b"FSB1 BEGIN")]
    after = [l for l in lines[ib[0]:] if l.startswith(b"FSPM1")] if ib else []
    ts = [int(MARKER.match(x).group(4)) for x in mk if MARKER.match(x)]
    check("%s markers: grammar, <= 64 bytes, nonce, no FSB1 text" % ph, gram and len(mk) <= 4, " | ".join(mk))
    check("%s markers in order %s, t non-decreasing" % (ph, ",".join(want_ev)), ev == want_ev and ts == sorted(ts), ",".join(ev))
    check("%s rec marker immediately before the record's empty line; no marker inside or after the record" % ph,
          len(ir) == 1 and len(ib) == 1 and ir[0] + 2 == ib[0] and lines[ir[0] + 1] == b"" and not after, "")
    res["phases"].setdefault(ph, {})["markers"] = mk
    if ph == "p0":
        p0 = out(2)
        wl = re.findall(rb"== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127", p0)
        bl = exp.get("bl", "127")
        rb_ = re.search(rb"write_rc=(\S+) readback=(\S+)", p0)
        check("p0: exactly one backlight write line (value 127), read-back %s" % bl, len(wl) == 1 and rb_ is not None and rb_.group(2).decode() == bl,
              rb_.group(0).decode() if rb_ else "none")
        check("p0: hash step exited 0 (sha256sum of /bin/fs-pattern)", steps.get(1, ("", "", -1))[1:] == ("exited", 0) and b"  /bin/fs-pattern\n" in out(1))
        check("p0: irq0 sample, mods snapshot with cmdline, dmesg and the fan", b"== irq0" in p0 and b"te-edge-isr" in p0 and b"-- cmdline" in p0
              and b"-- dmesg (new matching lines, last 80" in p0 and b"name=pwmfan" in p0)
        return
    n = int(ph[1])
    st2 = steps.get(2)
    o2 = out(2)
    if isinstance(run, tuple):
        check("%s step 2 %s %s code %d" % (ph, STEPS[ph][1], run[0], run[1]), st2 is not None and st2[1] == run[0] and st2[2] == run[1], str(st2))
        if run[1] in (0, 31, 50) or "sim" in str(res.get("mods")):
            open(od + "/fsp1-%s.txt" % ph, "wb").write(o2)
            cs = subprocess.run(["python3", "-I", CHECK_STREAM, "--expect", "complete", od + "/fsp1-%s.txt" % ph], capture_output=True, text=True)
            check("%s FSP1 stream COMPLETE, nonce = chal[0:8], mode %s" % (ph, MODE[ph]), cs.returncode == 0 and
                  set(re.findall(rb"^FSP1 nonce=(\S+) ", o2, re.M)) == {chals[ph][:8].encode()} and
                  re.search(rb"step=start rc=0 mode=" + MODE[ph].encode() + rb" ", o2) is not None, cs.stdout.strip())
        if exp.get("layout"):
            check("%s committed layout %s" % (ph, exp["layout"]), re.search(rb" step=commit rc=0 attempt=\d+ modeset=1 layout=" + exp["layout"].encode() + rb" ", o2) is not None)
    else:
        why = run[5:]
        check("%s step 2 replaced by the skip record (%s)" % (ph, why),
              st2 is not None and st2[1] == "exited" and st2[2] == 0 and o2 == ("FSK1 run=%d skipped reason=%s END\n" % (n, why)).encode(), repr(o2[:120]))
    p = out(1)
    open(od + "/probe-%s.txt" % ph, "wb").write(p)
    if exp.get("probe_nosup"):
        check("%s probe step nosup (supervisor killed after TQ); the record is still VALID" % ph, steps.get(1, ("", ""))[1] == "nosup", str(steps.get(1)))
        return
    rbl = exp.get("rbl", "127")
    check("%s probe: read-back only (no write line), readback=%s" % (ph, rbl), b"backlight-write" not in p and re.search(rb"^readback=" + rbl.encode() + rb"$", p, re.M) is not None)
    pts = [x.decode() for x in re.findall(rb"^== point (\S+) run=" + ph.encode(), p, re.M)]
    ran = isinstance(run, tuple)
    held = ran and run[1] == 0
    want = ["pre"] + (["go+1", "mid", "end"] if held else (["end"] if ran else [])) + ["post"]
    # a run that ends at once (exit 10/31/50: no hold) may still overlap the go+1 point
    alt = ["pre", "go+1", "end", "post"] if ran and not held else want
    check("%s probe points %s" % (ph, ",".join(want)), pts in (want, alt), ",".join(pts))
    check("%s probe: no dmesg at pre" % ph, re.search(rb"-- dmesg: not read at pre", p) is not None)
    if exp.get("pause"):
        ecs = res.get("pause_end_cs", 0)
        g2 = [int(MARKER.match(x).group(4)) for x in mk if MARKER.match(x).group(3) == "go"]
        b2 = [int(MARKER.match(x).group(4)) for x in mk if MARKER.match(x).group(3) == "begin"]
        up_pre = re.search(rb"^== point pre run=r2 up=([0-9.]+)", p, re.M)
        gap = (g2[0] - ecs * 10) if g2 else -1
        check("pause: run 1 ended just before r2 was sent; r2's go >= that end + 2000 ms, bounded (< end + 2000 + TW 2000 + 1500 ms); probe2 pre after the pause",
              2000 <= gap <= 5500 and up_pre is not None and float(up_pre.group(1)) * 1000 >= ecs * 10 + 2000 and bool(b2) and b2[0] < ecs * 10 + 2000,
              "end->go %d ms, begin->go %d ms" % (gap, g2[0] - b2[0] if g2 and b2 else -1))
        res["pause_ms"] = gap
    if exp.get("hold5"):
        args = res.get("sim_args", "")
        check("r3: fs-pattern called as show-off-solid <chal[0:8]> 5", ("show-off-solid %s 5" % chals["r3"][:8]) in args, args.strip().replace("\n", " | "))
        g = [int(MARKER.match(x).group(4)) for x in mk if MARKER.match(x).group(3) in ("go", "end")]
        mid = re.search(rb"^== point mid run=r3 up=([0-9.]+)", p, re.M)
        go_up = g[0] / 1000.0 if g else 0
        check("r3: pattern3 ran through the 5 s hold (go->end >= 5000 ms, < 11 s -t)", len(g) == 2 and 5000 <= g[1] - g[0] < 11000, "%s ms" % (g[1] - g[0] if len(g) == 2 else "?"))
        check("r3: probe3 mid at about 2.5 s after go", mid is not None and 2.3 <= float(mid.group(1)) - go_up <= 3.5, "%.2f s" % (float(mid.group(1)) - go_up if mid else -1))


def main():
    stage, image_dir, outdir = sys.argv[1:4]
    assert stage == "stage3c"
    names = sys.argv[4:]
    if len(names) != 1:
        raise SystemExit("one scenario per process (the caller runs them in parallel)")
    os.makedirs(outdir, exist_ok=True)
    sys.exit(0 if scenario(names[0], image_dir, outdir) else 1)


if __name__ == "__main__":
    main()
