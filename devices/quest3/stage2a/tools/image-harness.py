#!/usr/bin/env python3
"""FrameShift — offline whole-image harness for the stage-2a and stage-3a
boot images (run inside WSL; called by stage2a/test-image.sh and
stage3a/test-image.sh). Touches no device: no adb, no fastboot, no COM port.

    image-harness.py STAGE IMAGE_DIR OUTDIR SCENARIO [SCENARIO...]

What it runs: the ramdisk unpacked FROM THE BUILT IMAGE (boot-<stage>.img,
AOSP unpack_bootimg + lz4 + cpio), its /init executed as PID 1 of a bwrap
sandbox (new pid/ipc/uts namespaces, no capabilities, --as-pid-1), with the
image's aarch64 busybox and helpers run by qemu-aarch64 through binfmt_misc
(flag F). Nothing in the init is edited or scaled: the real DEADLINE,
ACK_WINDOW and step timeouts apply.

What is fake (and how):
  - /dev: bwrap's minimal /dev; the init's own `mount -t tmpfs /dev` and
    `mknod` fail without capabilities (EPERM) and leave it in place.
    /dev/ttyGS0 is the slave of a host pty: the harness is the USB host.
  - /sys: a small tree (UDC a600000.dwc3 "configured", ssusb mode, a role
    switch, firmware timeout, LEDs; for the stage-2a `inv` step a remoteproc,
    the ADSP platform-driver link and two power_supply uevents). No
    /sys/class/drm: no DRM device. /proc/modules is the sandbox's (WSL) own.
  - /config/usb_gadget: a plain directory (configfs cannot be mounted).
  - /proc: bwrap's procfs of the sandbox pid namespace.
  - /lib/modules: three empty fake modules with a dep and a softdep; insmod
    fails (EPERM), which the init logs per module, in load order.
  - Reboot: /bin/fs-reboot and /bin/fs-reboot-final are bound over by
    scripts shaped like the real ones: fs-reboot-final records
    "<uptime> final pid=<pid> arg=<reason>" and then never exits (so PID 1's
    exec is visible as pid=1); fs-reboot records "fork" and exits 1. The
    busybox `reboot -f` fallback runs for real and fails with EPERM (no
    CAP_SYS_BOOT; even with it, a reboot() from a child pid namespace only
    ends that namespace).
The host side follows host/fs-collect.ps1's order (fs-verify, fs-ack,
fs-status after 2.5 s, the runner once, fs-done), one command at a time,
each only after its completion record and a settled prompt. The byte stream
is saved as capture.raw with a host/fs-collect.ps1 index (capture.raw.idx,
mode=synthetic) so the PowerShell side can decode it with common/host/
fsb1.ps1, classify it and replay it through fs-collect.ps1 -Replay.
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
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../.."))
Q3 = ROOT + "/devices/quest3"
AOSP = ROOT + "/build/third_party/mkbootimg"
FSB1PY = Q3 + "/common/tools/fsb1.py"
CHECK_STREAM = Q3 + "/stage3a/tools/check_stream.py"
BB_REVIEWED = "c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02"

STAGES = {
    "stage2a": dict(img="boot-stage2a.img", runner="fs-valve", exp="stage2a",
                    steps=["hash", "absent", "diag", "list", "uname", "b2kat", "b2chal", "inv"],
                    deadline=260, ack_window=150),
    "stage3a": dict(img="boot-stage3a.img", runner="fs-display", exp="stage3a",
                    steps=["hash", "pattern"], deadline=170, ack_window=150),
}

ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")


def up():
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


# ----------------------------------------------------------------- root ------
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
HANG = """#!/bin/busybox sh
# HARNESS: a program that ignores SIGTERM and never ends (only SIGKILL stops it)
trap '' TERM
while :; do sleep 1; done
"""


def put(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def prepare(stage, image_dir, w, mods):
    cfg = STAGES[stage]
    img = os.path.join(image_dir, cfg["img"])
    pyc = os.path.join(w, "pyc")
    run(["python3", "-E", "-s", "-B", "-X", "pycache_prefix=" + pyc, AOSP + "/unpack_bootimg.py",
         "--boot_img", img, "--out", w + "/unp"], stdout=subprocess.DEVNULL)
    r = w + "/root"
    os.makedirs(r)
    lz = subprocess.Popen(["lz4", "-dc", w + "/unp/ramdisk"], stdout=subprocess.PIPE)
    run(["cpio", "-id", "--quiet", "--no-absolute-filenames"], stdin=lz.stdout, cwd=r)
    lz.wait()
    assert sha(open(r + "/bin/busybox", "rb").read()) == BB_REVIEWED, "busybox in the image is not the reviewed one"
    # fake vendor modules (3), sysfs, configfs dir, record dir
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
    # read-only inventory targets (stage2a step 8 `inv`)
    put(s + "/devices/platform/soc/3000000.remoteproc-adsp/remoteproc/remoteproc0/name", "adsp\n")
    put(s + "/devices/platform/soc/3000000.remoteproc-adsp/remoteproc/remoteproc0/state", "offline\n")
    os.makedirs(s + "/class/remoteproc", exist_ok=True)
    os.symlink("../../devices/platform/soc/3000000.remoteproc-adsp/remoteproc/remoteproc0", s + "/class/remoteproc/remoteproc0")
    os.makedirs(s + "/bus/platform/devices", exist_ok=True)
    os.makedirs(s + "/bus/platform/drivers/qcom_q6v5_pas", exist_ok=True)
    os.symlink("../../../devices/platform/soc/3000000.remoteproc-adsp", s + "/bus/platform/devices/3000000.remoteproc-adsp")
    os.symlink("../../../../bus/platform/drivers/qcom_q6v5_pas", s + "/devices/platform/soc/3000000.remoteproc-adsp/driver")
    put(s + "/class/power_supply/battery/uevent", "POWER_SUPPLY_NAME=battery\nPOWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=87\n")
    put(s + "/class/power_supply/usb/uevent", "POWER_SUPPLY_NAME=usb\nPOWER_SUPPLY_ONLINE=1\n")
    os.makedirs(r + "/config/usb_gadget", exist_ok=True)
    os.makedirs(r + "/.rec", exist_ok=True)
    os.makedirs(w + "/rec")
    put(w + "/fake/fs-reboot-final", FAKE_FINAL, 0o755)
    put(w + "/fake/fs-reboot", FAKE_REBOOT, 0o755)
    notes = []
    for m in mods:
        notes.append(apply_mod(r, m))
    return r, notes


def apply_mod(r, m):
    if m == "tamper-b2sum":
        p = r + "/valve/bin/b2sum"
        b = bytearray(open(p, "rb").read()); b[0x2000] ^= 0x01
        open(p, "wb").write(b)
        return "flipped one bit at offset 0x2000 of /valve/bin/b2sum (size unchanged)"
    if m == "missing-uname":
        os.unlink(r + "/valve/bin/uname")
        return "removed /valve/bin/uname"
    if m == "preload":
        put(r + "/etc/ld.so.preload", "")
        return "created an empty /etc/ld.so.preload"
    if m == "hang-loader":
        put(r + "/valve/lib/ld-linux-aarch64.so.1", HANG, 0o755)
        return "replaced /valve/lib/ld-linux-aarch64.so.1 by a TERM-ignoring endless script"
    if m == "hang-pattern":
        put(r + "/bin/fs-pattern", HANG, 0o755)
        return "replaced /bin/fs-pattern by a TERM-ignoring endless script"
    if m == "stop-pattern":
        return "the GENUINE /bin/fs-pattern (hash intact) is SIGSTOPped from outside the sandbox as soon as it starts: a hang"
    if m == "no-inv-paths":
        for d in ("/sys/class/remoteproc", "/sys/class/power_supply", "/sys/bus/platform/devices/3000000.remoteproc-adsp"):
            if os.path.islink(r + d):
                os.unlink(r + d)
            else:
                shutil.rmtree(r + d)
        return "removed /sys/class/remoteproc, /sys/class/power_supply and the ADSP platform device (the inv step must tolerate it)"
    if m == "no-udc":
        shutil.rmtree(r + "/sys/class/udc")
        return "removed /sys/class/udc (the UDC never appears: init's fail() path)"
    if m == "missing-pattern":
        os.unlink(r + "/bin/fs-pattern")
        return "removed /bin/fs-pattern"
    raise SystemExit("unknown mod " + m)


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
        assert re.fullmatch(r"[a-z0-9 -]{1,64}", text)
        self.writes.append((len(self.buf), self.ms(), text))
        self.log.append("%7d ms  W %s" % (self.ms(), text))
        os.write(self.m, text.encode() + b"\n")

    def lines_from(self, off):
        out = []
        for raw in bytes(self.buf[off:]).split(b"\n")[:-1]:
            out.append(raw.rstrip(b"\r"))
        return out

    def find_record(self, off, tag):
        for l in self.lines_from(off):
            # FSB1 END carries rec_sha256 last; every other record ends in " END"
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


def index_text(h, nonce):
    # Times are relative to the first byte from the target: the live collector is
    # started once the FS-<nonce> gadget has enumerated, i.e. when the shell already
    # exists; the sandbox bring-up time before that is not part of the session.
    base = h.chunks[0][2] if h.chunks else 0
    out = ["FSIDX1 nonce=%s mode=synthetic port=-" % nonce]
    # a write made when o bytes had been read precedes the read chunk that starts at o
    ev = [(o, max(0, ms - base), 1, "R %d %d %d" % (o, n, max(0, ms - base))) for (o, n, ms) in h.chunks]
    ev += [(o, max(0, ms - base), 0, "W %d %d %s" % (o, max(0, ms - base), t)) for (o, ms, t) in h.writes]
    ev.sort(key=lambda e: (e[0], e[2], e[1]))
    last = 0
    for o, ms, _, line in ev:   # times must not go backwards in the index
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


# ------------------------------------------------------------- scenario ------
SCEN = {
    # name: (stage, mods, host plan, expected first reboot reason, extra)
    "s2-pass":          ("stage2a", [], "full", "collected", {"outcome": "PASS", "inv": "full"}),
    "s2-inv-absent":    ("stage2a", ["no-inv-paths"], "full", "collected", {"outcome": "PASS", "inv": "absent"}),
    "s2-tamper-forced": ("stage2a", ["tamper-b2sum"], "full", "collected", {"outcome": "INTEGRITY FAULT"}),
    "s2-missing-forced": ("stage2a", ["missing-uname"], "full", "collected", {"outcome": "INTEGRITY FAULT"}),
    "s2-preload-forced": ("stage2a", ["preload"], "full", "collected", {"outcome": "INTEGRITY FAULT"}),
    "s2-hung-step":     ("stage2a", ["hang-loader"], "full", "collected", {"outcome": "INTEGRITY FAULT", "timer_kill": [3, 4, 5, 6, 7]}),
    "s2-no-ack":        ("stage2a", [], "verify-only", "no-host-ack", {}),
    "s2-ack-no-done":   ("stage2a", [], "full-no-done", "deadline", {"outcome": "PASS"}),
    "s2-done-early":    ("stage2a", [], "verify-done", "collected", {}),
    "s2-no-udc":        ("stage2a", ["no-udc"], "none", "error-udc", {"err_delay": 60}),
    "s3-nodrm":         ("stage3a", [], "full", "collected", {"pattern_exit": 10, "outcome": "NO-DISPLAY"}),
    "s3-hung-pattern":  ("stage3a", ["hang-pattern"], "full", "collected", {"timer_kill": [2], "outcome": "INTEGRITY FAULT"}),
    "s3-missing-pattern": ("stage3a", ["missing-pattern"], "full", "collected", {"exec_failed": [2], "outcome": "INTEGRITY FAULT"}),
    "s3-no-ack":        ("stage3a", [], "verify-only", "no-host-ack", {}),
    "s3-ack-no-done":   ("stage3a", [], "full-no-done", "deadline", {"pattern_exit": 10, "outcome": "NO-DISPLAY"}),
    "s3-done-early":    ("stage3a", [], "verify-done", "collected", {}),
    "s3-no-udc":        ("stage3a", ["no-udc"], "none", "error-udc", {"err_delay": 60}),
    "s3-pattern-stopped": ("stage3a", ["stop-pattern"], "full", "collected", {"timer_kill": [2], "outcome": "DISPLAY FAIL", "stopped": True}),
}


def stop_watcher(child, stop, found, target, deadline_s=120):
    """Fix round 6 (N5): SIGSTOP the GENUINE fs-pattern of THIS sandbox as it starts.
    A stopped process keeps the pinned binary (the hash step passes) but never finishes:
    fs-supervise's TERM stays pending and its KILL ends it (timer-kill), i.e. OUTCOMES §8
    rule 6 without an integrity trip.
    How it is caught without a race: inotify IN_OPEN on the image's /bin/fs-pattern (host
    path `target`). The exec of fs-pattern opens it; at that moment the process is still
    fs-supervise's child (cmdline of fs-supervise, parent fs-supervise) or already qemu with
    /bin/fs-pattern. A SIGSTOP sent then stops it before qemu runs any guest code. The hash
    step also opens the file (busybox sha256sum): it is not a candidate (no 'show', parent sh)."""
    import ctypes
    import threading

    libc = ctypes.CDLL(None, use_errno=True)

    def cmd(pid):
        try:
            return open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
        except OSError:
            return []

    def ppid(pid):
        try:
            for l in open("/proc/%s/status" % pid):
                if l.startswith("PPid:"):
                    return l.split()[1]
        except OSError:
            pass
        return None

    def try_stop(ns):
        for e in os.scandir("/proc"):
            if not e.name.isdigit():
                continue
            a = cmd(e.name)
            if len(a) < 4 or b"show" not in a or not a[0].endswith(b"qemu-aarch64"):
                continue
            try:
                if os.readlink("/proc/%s/ns/pid" % e.name) != ns:
                    continue
            except OSError:
                continue
            ok = a[1] == b"/bin/fs-pattern"
            if not ok and a[1] == b"/bin/fs-supervise":
                pa = cmd(ppid(e.name) or "0")
                ok = len(pa) >= 2 and pa[1] == b"/bin/fs-supervise"     # the child before (or during) its exec
            if ok:
                os.kill(int(e.name), signal.SIGSTOP)
                found.append(int(e.name))
                return True
        return False

    def run():
        try:
            ns = os.readlink("/proc/%d/ns/pid" % child)
        except OSError:
            return
        fd = libc.inotify_init1(os.O_NONBLOCK)
        if fd < 0 or libc.inotify_add_watch(fd, target.encode(), 0x20) < 0:     # IN_OPEN
            return
        end = time.monotonic() + deadline_s
        try:
            while not stop.is_set() and time.monotonic() < end and not found:
                r, _, _ = select.select([fd], [], [], 0.2)
                if not r:
                    continue
                try:
                    os.read(fd, 4096)
                except OSError:
                    pass
                for _ in range(200):          # the open of an exec or of the hash step; look for a while
                    if try_stop(ns) or found:
                        break
                    time.sleep(0.0005)
        finally:
            os.close(fd)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def scenario(name, image_dir, outdir):
    stage, mods, plan, want, extra = SCEN[name]
    cfg = STAGES[stage]
    od = os.path.join(outdir, name)
    shutil.rmtree(od, ignore_errors=True)
    os.makedirs(od)
    scratch = os.path.expanduser("~/work/fsimg-harness")     # WSL scratch only (Valve files are copied here)
    os.makedirs(scratch, exist_ok=True)
    w = tempfile.mkdtemp(prefix=name + ".", dir=scratch)
    res = {"scenario": name, "stage": stage, "mods": mods, "plan": plan, "want_reboot": want, "checks": []}

    def check(label, ok, detail=""):
        res["checks"].append({"label": label, "ok": bool(ok), "detail": detail})

    try:
        r, notes = prepare(stage, image_dir, w, mods)
        res["mod_notes"] = notes
        nonce = re.search(r'^NONCE="([0-9a-f]{16})"$', open(r + "/init").read(), re.M).group(1)
        m, s = pty.openpty()
        slave = os.ttyname(s)
        info_r, info_w = os.pipe()
        cmd = ["bwrap", "--bind", r, "/", "--dev", "/dev", "--proc", "/proc",
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
        import threading
        stop_evt, stopped = threading.Event(), []
        if "stop-pattern" in mods:
            stop_watcher(child, stop_evt, stopped, r + "/bin/fs-pattern")
        chal = os.urandom(16).hex()
        ack = os.urandom(8).hex()
        vchal = os.urandom(16).hex()
        res.update(nonce=nonce, verify_challenge=chal, ack=ack, challenge=vchal, exp=cfg["exp"], steps=cfg["steps"])
        kernel = pid1 = None
        fsv = None
        if plan != "none":
            # wait for the shell's first prompt (bring-up under qemu), then 1 s of read-only drain
            h.wait(lambda: h.prompt_settled(0), 90)
            h.pump(1.0)
            fsv = h.command("fs-verify", chal, "FSV1", 20)
        if plan == "none":
            check("no shell output on the tty (no host command sent)", True)
        elif fsv:
            kv = dict(x.split("=", 1) for x in fsv.split(" ")[1:-1] if "=" in x)
            kernel, pid1 = kv.get("kernel"), kv.get("pid1")
            want_resp = sha(("%s:%s" % (nonce, chal)).encode())
            check("FSV1 response = sha256(nonce:challenge)", kv.get("resp") == want_resp, fsv[:120])
            check("FSV1 stages end with SHELL_READY", kv.get("stages", "").endswith("SHELL_READY"), kv.get("stages"))
        else:
            check("FSV1 received", False)
        res.update(kernel=kernel, pid1=pid1)
        t_done = None
        if plan == "verify-done":
            d = h.command("fs-done", "", "FSD1", 10)
            t_done = up()
            check("FSD1 queued", d == "FSD1 queued END", d or "")
        elif plan.startswith("full"):
            a = h.command("fs-ack", ack, "FSA1", 10)
            check("FSA1 queued", a == "FSA1 queued END", a or "")
            st = None
            for _ in range(3):
                h.pump(2.5)
                st = h.command("fs-status", "", "FSS1", 10)
                if st and ("acked=%s " % ack) in st and "HOST_ACK" in st:
                    break
            check("FSS1 shows HOST_ACK recorded", bool(st) and ("acked=%s " % ack) in st, st or "")
            rec = h.command(cfg["runner"], vchal, "FSB1 END", 240)
            check("FSB1 END line received", rec is not None, rec or "")
            if plan == "full":
                d = h.command("fs-done", "", "FSD1", 10)
                t_done = up()
                check("FSD1 queued", d == "FSD1 queued END", d or "")
        # wait for the first reboot record
        limit = {"collected": 15, "no-host-ack": cfg["ack_window"] + 40, "deadline": cfg["deadline"] + 40, "error-udc": 100}[want]
        rp = w + "/rec/reboots"
        end = time.monotonic() + limit
        while time.monotonic() < end and not (os.path.exists(rp) and os.path.getsize(rp) > 0):
            h.pump(0.2)
        h.pump(1.5)          # anything after the reboot (should be nothing new from the shell)
        reboots = open(rp).read() if os.path.exists(rp) else ""
        res["reboots"] = reboots
        # stop the sandbox: SIGKILL its pid-namespace init (everything inside dies)
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
        # artifacts
        open(od + "/capture.raw", "wb").write(bytes(h.buf))
        open(od + "/capture.raw.idx", "w").write(index_text(h, nonce))
        open(od + "/host.log", "w").write("\n".join(h.log) + "\n")
        for f in ("fs.log", "fs.stages", "fs.acked"):
            if os.path.exists(r + "/run/" + f):
                shutil.copy(r + "/run/" + f, od + "/" + f)
        log = open(r + "/run/fs.log").read() if os.path.exists(r + "/run/fs.log") else ""
        mt0 = re.search(r"DEADLINE armed t0=(\d+) deadline=T0\+(\d+) ack_window=(\d+)", log)
        msr = re.search(r"t=(\d+)s STAGE=SHELL_READY", log)
        check("deadline armed with the image's values",
              bool(mt0) and int(mt0.group(2)) == cfg["deadline"] and int(mt0.group(3)) == cfg["ack_window"],
              mt0.group(0) if mt0 else "no DEADLINE line")
        check("backstop armed", "BACKSTOP armed" in log)
        first = reboots.splitlines()[0] if reboots else ""
        fm = re.match(r"([0-9.]+) (final|fork) pid=(\d+) arg=(\S+)", first)
        check("first reboot reason = %s" % want, bool(fm) and fm.group(4) == want, first or "no reboot recorded")
        stop_evt.set()
        if extra.get("stopped"):
            check("the genuine fs-pattern was SIGSTOPped from outside (fault injection)", len(stopped) == 1, str(stopped))
        if want == "no-host-ack":   # fix round 6 (N2): the stage-1 magenta LED before the no-ack reboot
            leds = [open(r + "/sys/class/leds/%s/brightness" % c).read().strip() for c in ("red", "green", "blue")]
            check("LEDs magenta (255 0 255) at the no-host-ack reboot, as in stage 1", leds == ["255", "0", "255"], " ".join(leds))
        check("PID 1 rebooted by exec of fs-reboot-final (via=final, pid=1)",
              bool(fm) and fm.group(2) == "final" and fm.group(3) == "1", first)
        # Later records are harness artifacts: the fake fs-reboot-final does not end the
        # sandbox, so the backstop still fires at T0+DEADLINE+1 if the run lasts that long.
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
                check("deadline reboot at T0+DEADLINE..+3 (HOST_ACK did not cancel it)",
                      cfg["deadline"] <= tr - T0 <= cfg["deadline"] + 3, "T0+%.1f" % (tr - T0))
            if want == "error-udc":
                check("fail() reboot at T0+ERR_DELAY..+3, by exec (no shell was started)",
                      extra["err_delay"] <= tr - T0 <= extra["err_delay"] + 3 and "SHELL_READY" not in log
                      and "ERROR stage=udc" in log and len(h.buf) == 0, "T0+%.1f" % (tr - T0))
            if want == "no-host-ack" and msr:
                s0 = int(msr.group(1))
                check("no-ack reboot at loop start + ACK_WINDOW..+3",
                      cfg["ack_window"] - 1 <= tr - s0 <= cfg["ack_window"] + 3, "SHELL_READY+%.1f" % (tr - s0))
        check("modules attempted in order fake_a, fake_b, fake_c (insmod EPERM in the sandbox)",
              re.findall(r"MODULE_FAIL (fake_\w)\.ko", log) == ["fake_a", "fake_b", "fake_c"],
              " ".join(re.findall(r"MODULE_FAIL (fake_\w)\.ko", log)))
        # FSB1 via the Python reference decoder (whole capture)
        if plan.startswith("full"):
            dd = od + "/payloads"
            os.makedirs(dd)
            pr = subprocess.run(["python3", "-I", FSB1PY, "check", "--exp", cfg["exp"], "--nonce", nonce,
                                 "--chal", vchal, "--steps", ",".join(cfg["steps"]), "--dump", dd,
                                 od + "/capture.raw"], capture_output=True, text=True)
            open(od + "/fsb1-python.txt", "w").write(pr.stdout + pr.stderr)
            check("FSB1 VALID (common/tools/fsb1.py)", pr.returncode == 0 and pr.stdout.startswith("VALID"), pr.stdout.splitlines()[0] if pr.stdout else pr.stderr[:200])
            steps = {}
            for l in pr.stdout.splitlines():
                mm = re.match(r"\s+step (\d+) (\w+) end=(\S+) code=(-?\d+) sig=(\d+)", l)
                if mm:
                    steps[int(mm.group(1))] = (mm.group(2), mm.group(3), int(mm.group(4)), int(mm.group(5)))
            res["fsb1_steps"] = steps
            if "inv" in extra:
                inv = open(dd + "/8.out", "rb").read() if os.path.exists(dd + "/8.out") else b""
                st8 = steps.get(8)
                check("step 8 inv exited 0 (read-only, busybox only)", st8 is not None and st8[0] == "inv" and st8[1] == "exited" and st8[2] == 0, str(st8))
                secs = re.findall(rb"^== (\S+)", inv, re.M)
                check("inv output has its five sections", secs == [b"/proc/modules", b"/sys/class/remoteproc",
                      b"/sys/bus/platform/devices/3000000.remoteproc-adsp/driver", b"/sys/class/power_supply", b"end"], str(secs))
                if extra["inv"] == "full":
                    check("inv read remoteproc0 name/state, the driver link and both power_supply uevents",
                          b"\nadsp\n" in inv and b"\noffline\n" in inv and b"qcom_q6v5_pas" in inv and b"POWER_SUPPLY_CAPACITY=87" in inv and b"POWER_SUPPLY_ONLINE=1" in inv, "")
                else:
                    check("inv reported the missing paths as (none)/(absent), not as an error",
                          inv.count(b"(none)") == 2 and b"(absent)" in inv and os.path.getsize(dd + "/8.err") == 0 if os.path.exists(dd + "/8.err") else True, "")
            for i in extra.get("timer_kill", []):
                check("step %d ended timer-kill sig=9" % i, steps.get(i, ("", "", 0, 0))[1] == "timer-kill" and steps[i][3] == 9, str(steps.get(i)))
            for i in extra.get("exec_failed", []):
                check("step %d ended exec-failed" % i, steps.get(i, ("", "", 0, 0))[1] == "exec-failed", str(steps.get(i)))
            # the record must have been preceded by an empty line on the tty (COLLECTOR.md §5)
            lines = [l for l in bytes(h.buf).split(b"\n")]
            bi = [k for k, l in enumerate(lines) if l.rstrip(b"\r").startswith(b"FSB1 BEGIN")]
            check("an empty line immediately before FSB1 BEGIN", len(bi) == 1 and bi[0] > 0 and lines[bi[0] - 1].rstrip(b"\r") == b"", "")
            if stage == "stage3a" and "pattern_exit" in extra:
                st2 = steps.get(2)
                check("pattern step exited %d (no device)" % extra["pattern_exit"], st2 is not None and st2[1] == "exited" and st2[2] == extra["pattern_exit"], str(st2))
                fsp = open(dd + "/2.out", "rb").read() if os.path.exists(dd + "/2.out") else b""
                open(od + "/fsp1-stream.txt", "wb").write(fsp)
                cs = subprocess.run(["python3", "-I", CHECK_STREAM, "--expect", "complete", od + "/fsp1-stream.txt"], capture_output=True, text=True)
                check("FSP1 stream COMPLETE (stage3a/tools/check_stream.py)", cs.returncode == 0, cs.stdout.strip())
                nn = set(re.findall(rb"^FSP1 nonce=(\S+) ", fsp, re.M))
                check("every FSP1 nonce = chal[0:8]", nn == {vchal[:8].encode()}, str(nn))
                check("FSP1 open at=stat rc=-2 (ENOENT) and exit code=10 reason=no_device",
                      re.search(rb"step=open rc=-2 errno=2 dev=/dev/dri/card0 at=stat", fsp) is not None and
                      re.search(rb"step=exit rc=0 code=10 reason=no_device shown=0", fsp) is not None, "")
                check("no FSP1 text on the tty outside the base64 payload", b"FSP1 " not in bytes(h.buf), "")
        res["ok"] = all(c["ok"] for c in res["checks"])
        res["t_total_s"] = round(up() - t_start, 1)
        res["expect"] = extra
        res["image_dir"] = image_dir
        json.dump(res, open(od + "/meta.json", "w"), indent=1, sort_keys=True)
        with open(od + "/result.txt", "w") as f:
            f.write("# %s (%s) mods=%s plan=%s; image %s\n" % (name, stage, mods, plan, image_dir))
            for n_ in res.get("mod_notes", []):
                f.write("# mod: %s\n" % n_)
            f.write("# reboots: %s\n" % reboots.strip().replace("\n", " | "))
            for c in res["checks"]:
                f.write("%s  %s%s\n" % ("PASS" if c["ok"] else "FAIL", c["label"], ("  [" + c["detail"] + "]") if c["detail"] else ""))
            f.write("SCENARIO %s %s\n" % (name, "PASS" if res["ok"] else "FAIL"))
        return res["ok"]
    finally:
        shutil.rmtree(w, ignore_errors=True)


def main():
    stage, image_dir, outdir = sys.argv[1:4]
    names = sys.argv[4:]
    for n in names:
        assert SCEN[n][0] == stage, n
    os.makedirs(outdir, exist_ok=True)
    ok = scenario(names[0], image_dir, outdir) if len(names) == 1 else None
    if len(names) > 1:
        raise SystemExit("one scenario per process (the caller runs them in parallel)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
