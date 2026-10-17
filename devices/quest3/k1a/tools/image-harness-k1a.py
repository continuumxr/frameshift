#!/usr/bin/env python3
"""FrameShift K1a — offline whole-image harness for the K1a boot image (the PID-1 logic under QEMU user mode).
Derived from stage3d/tools/image-harness-3d.py (its sandbox, Host and reboot fakes; the display parts dropped).
Run inside WSL by k1a/test-image.sh. Touches no device: no adb, no fastboot, no COM port.

    image-harness-k1a.py IMAGE_DIR OUTDIR SCENARIO

What runs: the ramdisk unpacked FROM THE BUILT IMAGE, its /init as PID 1 of a bwrap sandbox under qemu-aarch64
(binfmt), with the real DEADLINE/ACK_WINDOW, the real fs-supervise, fsb1-enc/fsb1-pace and the real runner.
What is fake (and what this therefore does NOT show):
  - THE KERNEL. The K1a kernel itself cannot boot here: QEMU user mode runs our aarch64 userspace on the host
    (WSL) kernel, and a Quest 3 kernel cannot be booted in qemu-system either (no anorak SoC model; no Meta DT,
    no vendor_boot path). uname -r/-v are the host's. The kernel-side facts are bind-mounted fakes:
    /proc/version (the pinned K1a banner), /proc/config.gz (gzip of k1a/kernel/k1a.config), /proc/meminfo,
    /proc/cmdline, /proc/modules, /proc/filesystems and the taint value; the kernel log (syslog(2)) and
    /proc/mounts are answered by a seccomp user-notification listener (KernelFake below: busybox runs dmesg as a
    built-in applet, and /proc/mounts is a symlink, so binds cannot fake them). Review M2: no host data in the
    fixtures. The runner's report of them is real.
  - the modules: no .ko is put in the sandbox (nothing can reach the host's init_module); the index is the
    pinned v2.7 vendor_boot's real modules.dep/softdep (text), every insmod fails, and the order is checked;
  - sysfs/configfs: plain files (UDC, role, LEDs, a decoy backlight node and a decoy /sys/class/drm/card0,
    watched by inotify: nothing may open them); the gadget is ACM only (PM decision J-179);
  - reboot: fs-reboot / fs-reboot-final are recording fakes; a pty plays ttyGS0.
The host side follows the stage-3d order: fs-verify, fs-ack, fs-status, `fs-k1a <chal>`, fs-done; the record is
decoded with common/tools/fsb1.py (exp k1a, 8 steps).
"""
import fcntl
import gzip
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

HERE = os.path.dirname(os.path.abspath(__file__))
K1A = os.path.dirname(HERE)
Q3 = os.path.dirname(K1A)
ROOT = os.environ.get("FS_INPUT_ROOT", "<repo>")
AOSP = ROOT + "/build/third_party/mkbootimg"
FSB1PY = Q3 + "/common/tools/fsb1.py"
K1A_CONFIG = K1A + "/kernel/k1a.config"
BB_REVIEWED = "c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02"
V27_VBOOT = ROOT + "/firmware/quest3/v2.7-user_ota/vendor_boot.img"
V27_VBOOT_SHA = "bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b"
DEADLINE, ACK_WINDOW, ERR_DELAY = 200, 150, 60
STEPS = ["kernel", "config", "mem", "modules", "kmsg", "fs", "usb", "log"]
ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
FSDE1 = re.compile(r"^FSDE1 error=(\S+)( [ -~]*)? END$")
SCRATCH = os.path.expanduser("~/work/fsimg-harness-k1a")

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
FAKE_MEMINFO = "MemTotal:       11683848 kB\nMemFree:        10900000 kB\nMemAvailable:   11000000 kB\nCmaTotal:         245760 kB\n"
FAKE_CMDLINE = "harness-fake-cmdline console=null\n"
# review M2: every kernel fact the runner reads is a fake (no host data in the fixtures): /proc/modules,
# /proc/filesystems and the taint value (binds), the kernel log and /proc/mounts (KernelFake)
FAKE_KMSG_CLEAN = ("[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd4b0]\n"
                   "[    0.000000] Linux version 5.10.246-gdbc2bc83a2b6 (frameshift@k1a) (harness fake)\n"
                   "[    2.100000] devtmpfs: initialized\n"
                   "[    9.500000] msm_drm: harness fake line\n")
FAKE_KMSG_FINDINGS = FAKE_KMSG_CLEAN + (
    "[   10.000001] msm_drm: disagrees about version of symbol kmalloc_caches\n"
    "[   10.000002] msm_drm: Unknown symbol kmalloc_caches (err -22)\n"
    "[   10.000003] spmi_pmic_arb: no symbol version for module_layout\n"
    "[   10.000004] fake_mod: version magic '5.10.246 SMP preempt mod_unload aarch64' should be '5.10.246-gdbc2bc83a2b6 SMP preempt mod_unload modversions aarch64'\n"
    "[   10.000005] fake_mod: loading out-of-tree module taints kernel.\n"
    "[   11.000000] ------------[ cut here ]------------\n"
    "[   11.000001] WARNING: CPU: 0 PID: 1 at drivers/gpu/drm/drm_atomic_helper.c:229 set_best_encoder+0x1/0x2\n"
    "[   11.000002] Call trace:\n")
FAKE_KMSG_WRAPPED = "[  812.000000] msm_drm: harness fake line (the ring buffer has wrapped)\n"
FAKE_MODULES = "nautilus 16384 0 - Live 0x0000000000000000\ncmd_db 16384 0 - Live 0x0000000000000000\n"
FAKE_FILESYSTEMS = "nodev\tsysfs\nnodev\ttmpfs\nnodev\tproc\nnodev\tdevtmpfs\nnodev\tconfigfs\n"
FAKE_MOUNTS = "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n"


# ---------------------------------------------------------------------------------------------------------------
# The kernel log and /proc/mounts fakes (review M2). Bind mounts cannot fake these two:
#   - the image's busybox ash runs `dmesg` as a built-in applet (FEATURE_SH_STANDALONE), so a fake /bin/dmesg is
#     never executed; the applet reads the log with syslog(2) (klogctl), which reaches the HOST kernel;
#   - /proc/mounts is a symlink to self/mounts, so a bind over it lands on one process's entry only.
# So the sandbox runs under a seccomp USER-NOTIFICATION filter (host x86_64 syscalls; under qemu-user the guest's
# syslog/openat become host syscalls): syslog(2) is answered from the canned log (no host log read), and an open of
# exactly "/proc/mounts" is answered with a fresh fd of the fake file (SECCOMP_IOCTL_NOTIF_ADDFD). Every other open
# continues untouched. The image itself is unchanged. The counts of answered calls go into the result.
# ---------------------------------------------------------------------------------------------------------------
import ctypes
import socket
import struct

_libc = ctypes.CDLL(None, use_errno=True)
_SYS_SECCOMP, _SECCOMP_SET_MODE_FILTER, _SECCOMP_FILTER_FLAG_NEW_LISTENER = 317, 1, 8
_PR_SET_NO_NEW_PRIVS = 38
_NR_OPEN, _NR_SYSLOG, _NR_OPENAT, _NR_OPENAT2 = 2, 103, 257, 437
_AUDIT_ARCH_X86_64 = 0xC000003E
_RECV, _SEND, _ADDFD = 0xC0502100, 0xC0182101, 0x40182103
_FLAG_CONTINUE, _ADDFD_FLAG_SEND = 1, 2
_SYSLOG_READ, _SYSLOG_READ_ALL, _SYSLOG_READ_CLEAR, _SYSLOG_SIZE_BUFFER = 2, 3, 4, 10
_EPERM = 1


class _Iovec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def _bpf(code, jt, jf, k):
    return struct.pack("<HBBI", code, jt, jf, k)


def seccomp_exec(sock_fd, argv):
    """Child side (a fresh interpreter, before exec of bwrap): install the filter, hand the listener fd to the
    harness over the inherited socket, exec. Between install and send nothing opens a file (no deadlock)."""
    prog = b"".join([
        _bpf(0x20, 0, 0, 4),                       # A = arch
        _bpf(0x15, 0, 5, _AUDIT_ARCH_X86_64),      # not x86_64 -> allow
        _bpf(0x20, 0, 0, 0),                       # A = nr
        _bpf(0x15, 4, 0, _NR_SYSLOG),
        _bpf(0x15, 3, 0, _NR_OPENAT),
        _bpf(0x15, 2, 0, _NR_OPEN),
        _bpf(0x15, 1, 0, _NR_OPENAT2),
        _bpf(0x06, 0, 0, 0x7FFF0000),              # SECCOMP_RET_ALLOW
        _bpf(0x06, 0, 0, 0x7FC00000),              # SECCOMP_RET_USER_NOTIF
    ])
    buf = ctypes.create_string_buffer(prog, len(prog))
    fprog = struct.pack("<HxxxxxxQ", len(prog) // 8, ctypes.addressof(buf))
    fbuf = ctypes.create_string_buffer(fprog, len(fprog))
    if _libc.prctl(_PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        sys.exit("harness: prctl(NO_NEW_PRIVS) failed")
    lfd = _libc.syscall(_SYS_SECCOMP, _SECCOMP_SET_MODE_FILTER, _SECCOMP_FILTER_FLAG_NEW_LISTENER, fbuf)
    if lfd < 0:
        sys.exit("harness: seccomp(NEW_LISTENER) failed errno %d" % ctypes.get_errno())
    s = socket.socket(fileno=sock_fd)
    socket.send_fds(s, [b"L"], [lfd])
    s.close()
    os.close(lfd)
    os.execvp(argv[0], argv)


class KernelFake:
    """Harness side: answers the notifications from a listener thread."""

    def __init__(self, kmsg_text, mounts_path):
        # the raw syslog(2) buffer carries a "<level>" prefix per line; busybox dmesg strips it (no -r)
        self.kmsg = "".join("<6>" + l + "\n" for l in kmsg_text.splitlines()).encode()
        self.mounts = mounts_path
        self.counts = {"syslog-read": 0, "syslog-size": 0, "syslog-other": 0, "mounts-open": 0, "open-continue": 0, "errors": 0}
        self.ps, self.cs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.lfd = None
        self.thread = None

    def wrap(self, cmd):
        return [sys.executable, "-I", os.path.abspath(__file__), "--seccomp-exec", str(self.cs.fileno()), "--"] + cmd

    def child_fd(self):
        return self.cs.fileno()

    def start(self, stop):
        self.cs.close()
        self.ps.settimeout(30)
        _, fds, _, _ = socket.recv_fds(self.ps, 8, 1)
        self.ps.close()
        if not fds:
            raise RuntimeError("harness: no seccomp listener fd from the launcher")
        self.lfd = fds[0]
        self.thread = threading.Thread(target=self._loop, args=(stop,), daemon=True)
        self.thread.start()

    def _rw(self, fn, pid, addr, data_or_len):
        if fn == "w":
            lb = ctypes.create_string_buffer(data_or_len, len(data_or_len))
            n = len(data_or_len)
        else:
            lb = ctypes.create_string_buffer(data_or_len)
            n = data_or_len
        lv = _Iovec(ctypes.addressof(lb), n)
        rv = _Iovec(addr, n)
        f = _libc.process_vm_writev if fn == "w" else _libc.process_vm_readv
        f.argtypes = [ctypes.c_int, ctypes.POINTER(_Iovec), ctypes.c_ulong, ctypes.POINTER(_Iovec), ctypes.c_ulong, ctypes.c_ulong]
        f.restype = ctypes.c_ssize_t
        got = f(pid, ctypes.byref(lv), 1, ctypes.byref(rv), 1, 0)
        if got < 0:
            raise OSError(ctypes.get_errno(), "process_vm_%sv" % ("write" if fn == "w" else "read"))
        return got if fn == "w" else lb.raw[:got]

    def _path(self, pid, addr):
        out = b""
        while len(out) < 4096:
            n = 4096 - (addr % 4096)
            chunk = self._rw("r", pid, addr, n)
            z = chunk.find(b"\0")
            if z >= 0:
                return out + chunk[:z]
            out += chunk
            addr += n
        return out

    def _send(self, nid, val=0, err=0, flags=0):
        fcntl.ioctl(self.lfd, _SEND, bytearray(struct.pack("<QqiI", nid, val, err, flags)), True)

    def _loop(self, stop):
        po = select.poll()
        po.register(self.lfd, select.POLLIN)
        while not stop.is_set():
            ev = po.poll(200)
            if not ev:
                continue
            if ev[0][1] & (select.POLLHUP | select.POLLERR) and not ev[0][1] & select.POLLIN:
                break
            req = bytearray(80)
            try:
                fcntl.ioctl(self.lfd, _RECV, req, True)
            except OSError:
                continue                            # the caller died meanwhile
            nid, pid, _fl, nr, _arch, _ip, a0, a1, a2, a3, a4, a5 = struct.unpack("<QIIiIQ6Q", req)
            try:
                if nr == _NR_SYSLOG:
                    typ = ctypes.c_int32(a0 & 0xFFFFFFFF).value
                    ln = ctypes.c_int32(a2 & 0xFFFFFFFF).value
                    if typ == _SYSLOG_SIZE_BUFFER:
                        self.counts["syslog-size"] += 1
                        self._send(nid, val=max(len(self.kmsg), 4096))
                    elif typ in (_SYSLOG_READ_ALL, _SYSLOG_READ_CLEAR) and ln > 0:
                        d = self.kmsg[-ln:] if len(self.kmsg) > ln else self.kmsg
                        self._rw("w", pid, a1, d)
                        self.counts["syslog-read"] += 1
                        self._send(nid, val=len(d))
                    else:
                        self.counts["syslog-other"] += 1
                        self._send(nid, err=-_EPERM)
                    continue
                paddr, cloexec = (a0, a1 & os.O_CLOEXEC) if nr == _NR_OPEN else (a1, a2 & os.O_CLOEXEC)
                if nr == _NR_OPENAT2:
                    cloexec = struct.unpack("<Q", self._rw("r", pid, a2, 8))[0] & os.O_CLOEXEC
                if self._path(pid, paddr) == b"/proc/mounts":
                    fd = os.open(self.mounts, os.O_RDONLY)
                    try:
                        fcntl.ioctl(self.lfd, _ADDFD, bytearray(struct.pack("<QIIII", nid, _ADDFD_FLAG_SEND, fd, 0,
                                                                            os.O_CLOEXEC if cloexec else 0)), True)
                    finally:
                        os.close(fd)
                    self.counts["mounts-open"] += 1
                else:
                    self.counts["open-continue"] += 1
                    self._send(nid, flags=_FLAG_CONTINUE)
            except OSError:
                self.counts["errors"] += 1
                try:
                    self._send(nid, flags=_FLAG_CONTINUE) if nr != _NR_SYSLOG else self._send(nid, err=-_EPERM)
                except OSError:
                    pass
        try:
            os.close(self.lfd)
        except OSError:
            pass


def up():
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def put(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(text, bytes) else "w") as f:
        f.write(text)
    os.chmod(path, mode)


def v27_index():
    cache = SCRATCH + "/v27-index"
    dep, soft = cache + "/modules.dep", cache + "/modules.softdep"
    if not (os.path.exists(dep) and os.path.exists(soft)):
        assert sha(open(V27_VBOOT, "rb").read()) == V27_VBOOT_SHA, "v2.7 vendor_boot is not the pinned one"
        tmp = tempfile.mkdtemp(prefix="v27idx.", dir=SCRATCH)
        run(["python3", "-E", "-s", "-B", AOSP + "/unpack_bootimg.py", "--boot_img", V27_VBOOT, "--out", tmp + "/u"], stdout=subprocess.DEVNULL)
        os.makedirs(tmp + "/x")
        lz = subprocess.Popen(["lz4", "-dc", tmp + "/u/vendor_ramdisk00"], stdout=subprocess.PIPE)
        run(["cpio", "-id", "--quiet", "--no-absolute-filenames", "lib/modules/modules.dep", "lib/modules/modules.softdep"],
            stdin=lz.stdout, cwd=tmp + "/x")
        lz.wait()
        os.makedirs(cache, exist_ok=True)
        shutil.copy(tmp + "/x/lib/modules/modules.dep", dep)
        shutil.copy(tmp + "/x/lib/modules/modules.softdep", soft)
        shutil.rmtree(tmp, ignore_errors=True)
    return open(dep).read(), open(soft).read()


def short_list(full, dep_text, soft_text):
    nodep = {l.split(":", 1)[0].split("/")[-1] for l in dep_text.splitlines() if ":" in l and not l.split(":", 1)[1].strip()}
    soft = {l.split()[1] for l in soft_text.splitlines() if l.startswith("softdep ")}
    return [m for m in full if m in nodep and m[:-3].replace("-", "_") not in soft][:3]


def banner_of_manifest(image_dir):
    m = re.search(r"^K1a banner +(.+)$", open(os.path.join(image_dir, "MANIFEST.txt")).read(), re.M)
    return m.group(1).strip()


def prepare(image_dir, w, mods):
    img = os.path.join(image_dir, "boot-k1a.img")
    run(["python3", "-E", "-s", "-B", "-X", "pycache_prefix=" + w + "/pyc", AOSP + "/unpack_bootimg.py",
         "--boot_img", img, "--out", w + "/unp"], stdout=subprocess.DEVNULL)
    r = w + "/root"
    os.makedirs(r)
    lz = subprocess.Popen(["lz4", "-dc", w + "/unp/ramdisk"], stdout=subprocess.PIPE)
    run(["cpio", "-id", "--quiet", "--no-absolute-filenames"], stdin=lz.stdout, cwd=r)
    lz.wait()
    assert sha(open(r + "/bin/busybox", "rb").read()) == BB_REVIEWED, "busybox in the image is not the reviewed one"
    md = r + "/lib/modules"
    for m in ("fake_a", "fake_b", "fake_c"):
        put(md + "/" + m + ".ko", "")
    put(md + "/modules.load.recovery", "fake_a.ko\nfake_b.ko\nfake_c.ko\n")       # a decoy: init.sh must not read it
    dep_text, soft_text = v27_index()
    if "moddep-mismatch" in mods:
        dep_text += "/lib/modules/fake_a.ko:\n"
    put(md + "/modules.dep", dep_text)
    put(md + "/modules.softdep", soft_text)
    full = [l.strip() for l in open(r + "/lib/fs/modules.load") if l.strip()]
    if "modules-real" not in mods and "moddep-mismatch" not in mods:
        put(r + "/lib/fs/modules.load", "".join(m + "\n" for m in short_list(full, dep_text, soft_text)))
    s = r + "/sys"
    put(s + "/class/udc/a600000.dwc3/state", "configured\n")
    put(s + "/devices/platform/soc/a600000.ssusb/mode", "host\n")
    put(s + "/class/usb_role/a600000.dwc3-role-switch/role", "host\n")
    put(s + "/class/firmware/timeout", "60\n")
    for c in ("red", "green", "blue"):
        put(s + "/class/leds/%s/brightness" % c, "0\n")
    # decoys: K1a writes no panel node and opens no DRM node (inotify IN_OPEN|IN_ACCESS on them: 0 events)
    put(s + "/class/backlight/panel0-backlight/brightness", "255\n")
    put(s + "/class/drm/card0/dev", "226:0\n", 0o444)
    os.makedirs(r + "/config/usb_gadget", exist_ok=True)
    if "bind-fail" in mods:     # the UDC bind fails (a DIRECTORY where the UDC attribute would be)
        os.makedirs(r + "/config/usb_gadget/fs/UDC", exist_ok=True)
    os.makedirs(r + "/.rec", exist_ok=True)
    os.makedirs(w + "/rec")
    put(w + "/fake/fs-reboot-final", FAKE_FINAL, 0o755)
    put(w + "/fake/fs-reboot", FAKE_REBOOT, 0o755)
    put(w + "/fake/version", banner_of_manifest(image_dir) + "\n", 0o444)
    cfg = open(K1A_CONFIG, "rb").read()
    put(w + "/fake/config.gz", gzip.compress(cfg, mtime=0), 0o444)
    put(w + "/fake/meminfo", FAKE_MEMINFO, 0o444)
    put(w + "/fake/cmdline", FAKE_CMDLINE, 0o444)
    kmsg = FAKE_KMSG_FINDINGS if "kmsg-findings" in mods else (FAKE_KMSG_WRAPPED if "kmsg-wrapped" in mods else FAKE_KMSG_CLEAN)
    put(w + "/fake/kmsg", kmsg, 0o444)    # read by KernelFake, not visible in the sandbox
    put(w + "/fake/modules", FAKE_MODULES, 0o444)
    put(w + "/fake/filesystems", FAKE_FILESYSTEMS, 0o444)
    put(w + "/fake/mounts", FAKE_MOUNTS, 0o444)
    put(w + "/fake/tainted", "0\n", 0o444)
    return r, sha(cfg)


class Host:
    def __init__(self, master):
        self.m = master
        self.buf = bytearray()
        self.writes = []
        self.chunks = []      # (offset, length, ms): the capture index (FSIDX1 R lines)
        self.wix = []         # (offset, ms, text): the capture index (FSIDX1 W lines)
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
        self.writes.append(text)
        self.wix.append((len(self.buf), self.ms(), text))
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

    def runner(self, chal, timeout=120):
        off = len(self.buf)
        self.write("fs-k1a %s" % chal)
        done = lambda: self.find_record(off, "FSB1 END") is not None or self.find_record(off, "FSDE1") is not None
        got = self.wait(done, timeout)
        ok = got and self.wait(lambda: self.prompt_settled(off), 8)
        end, ref = self.find_record(off, "FSB1 END"), self.find_record(off, "FSDE1")
        self.log.append("%7d ms  R %s%s" % (self.ms(), (end or ref or "no completion")[:150], "" if ok else "  (no settled prompt)"))
        return bytes(self.buf[off:]), end, ref, ok


def index_text(h, nonce):
    """capture.raw.idx in the FSIDX1 format the host collector replays (stage3d/tools/image-harness-3d.py's)"""
    base = h.chunks[0][2] if h.chunks else 0
    out = ["FSIDX1 nonce=%s mode=synthetic port=-" % nonce]
    ev = [(o, max(0, ms - base), 1, "R %d %d %d" % (o, n, max(0, ms - base))) for (o, n, ms) in h.chunks]
    ev += [(o, max(0, ms - base), 0, "W %d %d %s" % (o, max(0, ms - base), t)) for (o, ms, t) in h.wix]
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
                rr, _, _ = select.select([fd], [], [], 0.2)
                if rr:
                    try:
                        d = os.read(fd, 4096)
                    except OSError:
                        continue
                    i = 0
                    while i + 16 <= len(d):
                        wd, mk, _c, ln = struct.unpack_from("iIII", d, i)
                        events.append("wd=%d mask=0x%x %s" % (wd, mk, d[i + 16:i + 16 + ln].rstrip(b"\0").decode("latin-1")))
                        i += 16 + ln
        finally:
            os.close(fd)
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t


TTY_REC = re.compile(r"^(FS(V1|A1|S1|D1|DE1) [ -~]* END|FSB1 (BEGIN|STEP|DATA|END) [ -~]+)$")
TTY_PROMPT = re.compile(r"^~ [#$] ")


def tty_strays(buf, writes):
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


# name: (mods, plan, want_reboot). plan items: "verify", "ack", "run", "run-again", "run-badchal", "time", "done"
SCEN = {
    "c-full": ([], ["verify", "ack", "run", "done"], "collected"),
    "c-repeat": ([], ["verify", "ack", "run", "run-again", "done"], "collected"),
    "c-bad-challenge": ([], ["verify", "ack", "run-badchal", "done"], "collected"),
    "c-time": ([], ["verify", "ack", "time", "run", "done"], "collected"),
    "c-no-ack": ([], ["verify"], "no-host-ack"),
    "c-ack-no-done": ([], ["verify", "ack"], "deadline"),
    "c-done-early": ([], ["verify", "done"], "collected"),
    "c-modules-real": (["modules-real"], ["verify", "done"], "collected"),
    "c-modules-refused": (["moddep-mismatch"], [], "error-modules"),
    "c-bind-fail": (["bind-fail"], [], "error-udc"),
    # review M2: the helper's filters run under the image's busybox on canned 5.10 kernel-log lines
    "c-kmsg-findings": (["kmsg-findings"], ["verify", "ack", "run", "done"], "collected"),
}


def scenario(name, image_dir, outdir):
    mods, plan, want = SCEN[name]
    od = os.path.join(outdir, name)
    shutil.rmtree(od, ignore_errors=True)
    os.makedirs(od)
    os.makedirs(SCRATCH, exist_ok=True)
    w = tempfile.mkdtemp(prefix=name + ".", dir=SCRATCH)
    res = {"scenario": name, "mods": mods, "plan": plan, "want_reboot": want, "checks": []}

    def check(label, ok, detail=""):
        res["checks"].append({"label": label, "ok": bool(ok), "detail": detail})

    stop = threading.Event()
    try:
        r, cfg_sha = prepare(image_dir, w, mods)
        nonce = re.search(r'^NONCE="([0-9a-f]{16})"$', open(r + "/init").read(), re.M).group(1)
        decoy_ev = []
        inotify_watch([r + "/sys/class/backlight/panel0-backlight/brightness", r + "/sys/class/drm/card0/dev"], decoy_ev, stop)
        m, s = pty.openpty()
        slave = os.ttyname(s)
        info_r, info_w = os.pipe()
        cmd = ["bwrap", "--bind", r, "/", "--dev", "/dev", "--proc", "/proc",
               "--ro-bind", w + "/fake/version", "/proc/version",
               "--ro-bind", w + "/fake/config.gz", "/proc/config.gz",
               "--ro-bind", w + "/fake/meminfo", "/proc/meminfo",
               "--ro-bind", w + "/fake/cmdline", "/proc/cmdline",
               "--ro-bind", w + "/fake/modules", "/proc/modules",
               "--ro-bind", w + "/fake/filesystems", "/proc/filesystems",
               "--ro-bind", w + "/fake/tainted", "/proc/sys/kernel/tainted",
               "--dev-bind", slave, "/dev/ttyGS0",
               "--ro-bind", w + "/fake/fs-reboot-final", "/bin/fs-reboot-final",
               "--ro-bind", w + "/fake/fs-reboot", "/bin/fs-reboot",
               "--bind", w + "/rec", "/.rec",
               "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-net", "--as-pid-1",
               "--die-with-parent", "--cap-drop", "ALL", "--clearenv",
               "--setenv", "HOME", "/", "--setenv", "TERM", "linux",
               "--info-fd", str(info_w), "/bin/busybox", "sh", "/init"]
        kfake = KernelFake(open(w + "/fake/kmsg").read(), w + "/fake/mounts")
        t_start = up()
        p = subprocess.Popen(kfake.wrap(cmd), stdin=subprocess.DEVNULL, stdout=open(od + "/bwrap.out", "wb"),
                             stderr=subprocess.STDOUT, pass_fds=(info_w, kfake.child_fd()), start_new_session=True)
        kfake.start(stop)
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
        chal, ack, rchal = os.urandom(16).hex(), os.urandom(8).hex(), os.urandom(16).hex()
        res.update(nonce=nonce, verify_challenge=chal, ack=ack, runner_challenge=rchal)
        if plan:
            h.wait(lambda: h.prompt_settled(0), 240 if "modules-real" in mods else 90)
            h.pump(1.0)
        t_done = None
        rec = None
        for step in plan:
            if step == "verify":
                fsv = h.command("fs-verify", chal, "FSV1", 20)
                kv = dict(x.split("=", 1) for x in (fsv or "").split(" ")[1:-1] if "=" in x)
                check("FSV1 response = sha256(nonce:challenge)", kv.get("resp") == sha(("%s:%s" % (nonce, chal)).encode()), (fsv or "none")[:120])
                check("FSV1 stages end with SHELL_READY", kv.get("stages", "").endswith("SHELL_READY"), kv.get("stages"))
            elif step == "ack":
                a_ = h.command("fs-ack", ack, "FSA1", 10)
                check("FSA1 queued", a_ == "FSA1 queued END", a_ or "")
                st = None
                for _ in range(3):
                    h.pump(2.5)
                    st = h.command("fs-status", "", "FSS1", 10)
                    if st and ("acked=%s " % ack) in st:
                        break
                check("FSS1 shows HOST_ACK recorded", bool(st) and ("acked=%s " % ack) in st, st or "")
            elif step == "time":       # a deadline 30 s ahead, written from outside: RUNNER_WORST 115 does not fit
                put(r + "/run/fs.deadline", "%d\n" % (int(up()) + 30))
            elif step in ("run", "run-again", "run-badchal"):
                sl, end, ref, ok = h.runner("nothex" if step == "run-badchal" else rchal)
                open(od + "/runner-%s.raw" % step, "wb").write(sl)
                want_ref = {"run-again": "already-run", "run-badchal": "bad-challenge"}.get(step)
                if name == "c-time":
                    want_ref = "time"
                if want_ref:
                    mm = FSDE1.match(ref or "")
                    check("%s refused: FSDE1 error=%s, no FSB1 text" % (step, want_ref),
                          bool(mm) and mm.group(1) == want_ref and end is None and b"FSB1" not in sl, ref or "none")
                    continue
                check("runner completed with a settled prompt", bool(end) and ok, end or ref or "none")
                if not end:
                    continue
                dd = od + "/payloads"
                os.makedirs(dd, exist_ok=True)
                pr = subprocess.run(["python3", "-I", FSB1PY, "check", "--exp", "k1a", "--nonce", nonce, "--chal", rchal,
                                     "--steps", ",".join(STEPS), "--dump", dd, od + "/runner-run.raw"], capture_output=True, text=True)
                open(od + "/fsb1.txt", "w").write(pr.stdout + pr.stderr)
                check("FSB1 VALID (exp k1a, 8 steps kernel..log, this nonce and challenge)", pr.returncode == 0 and pr.stdout.startswith("VALID"),
                      (pr.stdout or pr.stderr).splitlines()[0] if (pr.stdout or pr.stderr) else "")
                rec = {i + 1: (open(dd + "/%d.out" % (i + 1), "rb").read() if os.path.exists(dd + "/%d.out" % (i + 1)) else b"") for i in range(8)}
                stl = re.findall(r"^\s+step (\d+) (\w+) end=(\S+) code=(-?\d+)", pr.stdout, re.M)
                check("every step exited 0", len(stl) == 8 and all(x[2] == "exited" and x[3] == "0" for x in stl), str(stl))
                errs = [i for i in range(1, 9) if os.path.exists(dd + "/%d.err" % i) and os.path.getsize(dd + "/%d.err" % i)]
                check("no step wrote stderr", not errs, str(errs))
            elif step == "done":
                d_ = h.command("fs-done", "", "FSD1", 10)
                t_done = up()
                check("FSD1 queued", d_ == "FSD1 queued END", d_ or "")
        limit = {"collected": 15, "no-host-ack": ACK_WINDOW + 40, "deadline": DEADLINE + 40, "error-modules": 90, "error-udc": 90}[want]
        rp = w + "/rec/reboots"
        end_t = time.monotonic() + limit
        while time.monotonic() < end_t and not (os.path.exists(rp) and os.path.getsize(rp) > 0):
            h.pump(0.2)
        h.pump(1.5)
        reboots = open(rp).read() if os.path.exists(rp) else ""
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
        open(od + "/capture.raw", "wb").write(bytes(h.buf))
        open(od + "/capture.raw.idx", "w").write(index_text(h, nonce))
        open(od + "/host.log", "w").write("\n".join(h.log) + "\n")
        for f in ("fs.log", "fs.stages", "fs.acked", "fs.collected"):
            if os.path.exists(r + "/run/" + f):
                shutil.copy(r + "/run/" + f, od + "/" + f)
        log = open(r + "/run/fs.log").read() if os.path.exists(r + "/run/fs.log") else ""
        stg = open(r + "/run/fs.stages").read().split() if os.path.exists(r + "/run/fs.stages") else []
        mt0 = re.search(r"DEADLINE armed t0=(\d+) deadline=T0\+(\d+) ack_window=(\d+)", log)
        check("deadline armed with the image's values (200 / 150)", bool(mt0) and int(mt0.group(2)) == DEADLINE and int(mt0.group(3)) == ACK_WINDOW,
              mt0.group(0) if mt0 else "no DEADLINE line")
        check("backstop armed", "BACKSTOP armed" in log)
        first = reboots.splitlines()[0] if reboots else ""
        fm = re.match(r"([0-9.]+) (final|fork) pid=(\d+) arg=(\S+)", first)
        check("first reboot reason = %s" % want, bool(fm) and fm.group(4) == want, first or "no reboot recorded")
        check("PID 1 rebooted by exec of fs-reboot-final (via=final, pid=1)", bool(fm) and fm.group(2) == "final" and fm.group(3) == "1", first)
        later = reboots.splitlines()[1:]
        check("any later record is only the backstop (fork)", all(re.match(r"[0-9.]+ fork pid=\d+ arg=backstop$", x) for x in later), " | ".join(later))
        if fm and mt0:
            tr, T0 = float(fm.group(1)), int(mt0.group(1))
            res["reboot_at_T0_plus"] = round(tr - T0, 1)
            if want == "collected" and t_done:
                check("reboot within 3 s of fs-done", tr - t_done <= 3.0, "%.1f s" % (tr - t_done))
            if want == "deadline":
                check("deadline reboot at T0+DEADLINE..+3 (HOST_ACK did not cancel it)", DEADLINE <= tr - T0 <= DEADLINE + 3, "T0+%.1f" % (tr - T0))
            if want == "no-host-ack":
                msr = re.search(r"t=(\d+)s STAGE=SHELL_READY", log)
                check("no-ack reboot at SHELL_READY + ACK_WINDOW..+3", bool(msr) and ACK_WINDOW - 1 <= tr - int(msr.group(1)) <= ACK_WINDOW + 3,
                      "SHELL_READY+%.1f" % (tr - int(msr.group(1))) if msr else "no SHELL_READY")
            if want == "error-udc":
                check("bind failure: reboot error-udc at T0 + ERR_DELAY 60 (..+4)", ERR_DELAY <= tr - T0 <= ERR_DELAY + 4, "T0+%.1f" % (tr - T0))
            if want == "error-modules":
                check("index mismatch: reboot error-modules at T0 + ERR_DELAY 60 (..+4)", ERR_DELAY <= tr - T0 <= ERR_DELAY + 4, "T0+%.1f" % (tr - T0))
        check("no access to the decoy backlight or DRM node (inotify: 0 events)", not decoy_ev, " | ".join(decoy_ev[:5]))
        stray = tty_strays(bytes(h.buf), h.writes)
        check("tty accounting: only the banner, echoed commands, protocol/record lines and prompts (no stray tty output)", not stray, " | ".join(stray[:4]))
        ml = [l.strip()[:-3] for l in open(r + "/lib/fs/modules.load") if l.strip()]
        att = re.findall(r"MODULE_FAIL (\S+)\.ko", log)
        if "moddep-mismatch" in mods:
            check("index mismatch: MODULES_REFUSED then ERROR_modules, no module attempted, no SHELL_READY",
                  "MODULES_REFUSED" in stg and "ERROR_modules" in stg and not att and "MODULE_INDEX" not in log and "SHELL_READY" not in stg, " ".join(stg))
        elif "modules-real" in mods:
            check("modules attempted = the image's 95-entry list, each once, nothing else (the vendor decoy list unused)",
                  len(ml) == 95 and sorted(att) == sorted(ml) and len(set(att)) == len(att) and not any(x.startswith("fake_") for x in att),
                  "attempted %d" % len(att))
        else:
            check("MODULE_INDEX logged; modules attempted = the harness short list in order", "MODULE_INDEX dep=" in log and att == ml, "attempted %s" % att)
        if "bind-fail" in mods:
            check("bind failure: ERROR_udc ('bind failed'), no UDC_BOUND, no shell",
                  "ERROR stage=udc bind failed" in log and "ERROR_udc" in stg and "UDC_BOUND" not in stg and "SHELL_READY" not in stg,
                  " ".join(stg))
        elif want != "error-modules":
            check("ACM-only gadget (J-179): no NCM function made, UDC bound, shell up",
                  not re.search(r"\bncm", log, re.I) and "UDC_BOUND" in stg and "SHELL_READY" in stg, " ".join(stg))
        if rec:
            k, c_, me, mo, mv, fs_, us, lg = (rec[i].decode("latin-1") for i in range(1, 9))
            ban = banner_of_manifest(image_dir)
            check("kernel step: /proc/version = the pinned K1a banner (bind-mounted fake; uname is the host's)", ("== proc-version\n" + ban + "\n") in k, k[:160])
            check("config step: config_sha256 = sha256(k1a.config) and the K1a option lines present",
                  ("== config_sha256 %s" % cfg_sha) in c_ and "CONFIG_DEVTMPFS=y" in c_ and "CONFIG_TMPFS_POSIX_ACL=y" in c_
                  and "# CONFIG_SYSVIPC is not set" in c_ and "# CONFIG_USER_NS is not set" in c_ and "CONFIG_MODVERSIONS=y" in c_, c_[:200])
            check("mem step: MemTotal reported", re.search(r"^MemTotal: +11683848 kB$", me, re.M) is not None, me[:80])
            check("modules step: loader lines (MODULE_INDEX, MODLIST, MODULES_READY) and /proc/modules section",
                  "MODULE_INDEX dep=" in mo and "MODLIST" in mo and "STAGE=MODULES_READY" in mo and "== proc-modules" in mo, mo[:160])
            if "kmsg-findings" in mods:
                check("kmsg findings (canned 5.10 lines): modver-matches 4 (disagrees, Unknown symbol, no symbol version, version magic), "
                      "taint-lines 1 (not a modver match), warnings 1 WARNING / 0 BUG / 3 lines (cut here, WARNING, Call trace)",
                      re.search(r"^== modver-matches 4$", mv, re.M) is not None and re.search(r"^== taint-lines 1$", mv, re.M) is not None
                      and re.search(r"^== warnings 1 warning-lines, 0 bug-lines, 3 lines$", mv, re.M) is not None
                      and "set_best_encoder" in mv and "taints kernel" in mv, mv[:400])
            else:
                check("kmsg (clean canned log): first line at boot time, modver-matches 0, taint-lines 0, warnings 0",
                      "first=[    0.000000]" in mv and "== kmsg-lines 4 " in mv and re.search(r"^== modver-matches 0$", mv, re.M) is not None
                      and re.search(r"^== taint-lines 0$", mv, re.M) is not None and re.search(r"^== warnings 0 warning-lines, 0 bug-lines, 0 lines$", mv, re.M) is not None, mv[:300])
            check("fs step: exactly the faked /proc/filesystems and /proc/mounts (no host data)",
                  ("== filesystems\n" + FAKE_FILESYSTEMS + "== mounts\n" + FAKE_MOUNTS) in fs_, fs_[:160])
            check("kernel log and /proc/mounts came from KernelFake (syslog read and /proc/mounts open answered, no listener errors)",
                  kfake.counts["syslog-read"] >= 1 and kfake.counts["mounts-open"] >= 1 and kfake.counts["errors"] == 0, str(kfake.counts))
            check("kmsg step: the log line count, the modver count and the WARNING/BUG counts (FS-R-012 §3)",
                  re.search(r"^== kmsg-lines \d+ ", mv, re.M) is not None and re.search(r"^== modver-matches \d+$", mv, re.M) is not None
                  and re.search(r"^== warnings \d+ warning-lines, \d+ bug-lines, \d+ lines$", mv, re.M) is not None, mv[:200])
            check("fs step: /proc/filesystems and /proc/mounts sections", "== filesystems" in fs_ and "== mounts" in fs_, "")
            check("usb step: UDC a600000.dwc3, config functions 'acm.gs0' only, product FrameShift K1a, serial FS-<nonce>",
                  "== udc a600000.dwc3 " in us and "== config-functions acm.gs0 \n" in us
                  and ("== product FrameShift K1a serial=FS-%s\n" % nonce) in us, us[:200])
            check("log step: /run/fs.log with SHELL_READY", "== fs.log" in lg and "STAGE=SHELL_READY" in lg, "")
        res["kernel_fake_counts"] = dict(kfake.counts)
        res["ok"] = all(c["ok"] for c in res["checks"])
        res["t_total_s"] = round(up() - t_start, 1)
        json.dump(res, open(od + "/meta.json", "w"), indent=1, sort_keys=True, default=str)
        with open(od + "/result.txt", "w") as f:
            f.write("# %s mods=%s plan=%s; image %s\n" % (name, mods, plan, image_dir))
            f.write("# reboots: %s\n" % reboots.strip().replace("\n", " | "))
            for c in res["checks"]:
                f.write("%s  %s%s\n" % ("PASS" if c["ok"] else "FAIL", c["label"], ("  [" + c["detail"] + "]") if c["detail"] else ""))
            f.write("SCENARIO %s %s\n" % (name, "PASS" if res["ok"] else "FAIL"))
        return res["ok"]
    finally:
        stop.set()
        shutil.rmtree(w, ignore_errors=True)


def main():
    if len(sys.argv) > 3 and sys.argv[1] == "--seccomp-exec" and sys.argv[3] == "--":
        seccomp_exec(int(sys.argv[2]), sys.argv[4:])
    image_dir, outdir = sys.argv[1:3]
    names = sys.argv[3:]
    if len(names) != 1:
        raise SystemExit("one scenario per process (the caller runs them in parallel)")
    os.makedirs(outdir, exist_ok=True)
    sys.exit(0 if scenario(names[0], image_dir, outdir) else 1)


if __name__ == "__main__":
    main()
