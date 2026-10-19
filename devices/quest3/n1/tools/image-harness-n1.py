#!/usr/bin/env python3
"""FrameShift N1 — offline whole-image harness for the N1 boot image (the PID-1 logic and the NCM link's userspace
under QEMU user mode). Derived from k1a/tools/image-harness-k1a.py (its sandbox, Host, KernelFake and reboot fakes are
kept; the N1 additions are the network namespaces, the veth "NCM link", the host-side transfer client and the
UDC-bind fault). Run inside WSL by n1/test-image.sh, one scenario per process, ALWAYS under `unshare -rnm` (a fresh
user, network and mount namespace: the harness creates the veth pair and mounts a sysfs of that namespace).
Touches no device: no adb, no fastboot, no COM port, no host network (both veth ends live in private namespaces).

    unshare -rnm image-harness-n1.py IMAGE_DIR OUTDIR SCENARIO

What runs: the ramdisk unpacked FROM THE BUILT IMAGE, its /init as PID 1 of a bwrap sandbox under qemu-aarch64 (binfmt),
with the real DEADLINE/ACK_WINDOW, fs-supervise, fsb1-enc/fsb1-pace, the N1 runner and the real /bin/fs-xfer (the
pinned aarch64 binary from the image). The sandbox keeps CAP_NET_ADMIN only (for init.sh's sysctls, `ip link` and
`ip -6 addr`) in the scenario's own network namespace "A".
THE NCM LINK is a veth pair: "usb0" in A (MAC = the nonce's dev_addr; the init finds it through the fake configfs
ifname and the real sysfs of A, bind-mounted at /sys/class/net/usb0) and "hst0" in a second namespace "B" (MAC =
host_addr) that plays the PC. hst0 down = no carrier = the PC's driver has not bound; the harness brings hst0 up when
the shell is ready ("the PC's driver binds"), unless the scenario says otherwise. With DAD off the device address is
permanent at once, carrier or not (5.10 addrconf_dad_begin completes before its IF_READY check; checked here on the
WSL kernel). The host side of the transfer is n1/tools/xfer-client.py run in B with nsenter
(the reference client; the PC's is devices/quest3/host/fs-xfer-n1.ps1).
What is fake (and what this therefore does NOT show):
  - THE KERNEL (as K1a): QEMU user mode runs our aarch64 userspace on the WSL kernel; the K1a kernel itself cannot
    boot here. The kernel facts the runner reports are fakes (/proc/version, config.gz, meminfo, cmdline, modules,
    filesystems, taint; the kernel log by the seccomp listener). /proc/net, /proc/sys/net and the veth's sysfs are
    REAL (the WSL kernel's IPv6 in namespace A), so the link-local address and its state (permanent at once, DAD off), the
    socket tables and the interface counters are real kernel behaviour - of the WSL kernel, not of 5.10 f_ncm;
  - f_ncm and the UDC: configfs is plain files (UDC, the function attributes, ifname = "usb0"); "binding" writes a
    file. The NCM bind FAILURE is faked by the seccomp listener: in c-ncm-bind-fail the first open for writing of
    /config/usb_gadget/fs/UDC while configs/c.1/ncm.fs exists fails with ENODEV (the kernel fails the write itself;
    for the shell both are a failed redirection). The USB enumeration is not modelled: the UDC state file says
    "configured" (or "default" in c-ncm-fallback);
  - the modules (no .ko), reboot (recording fakes), ttyGS0 (a pty), as K1a.
The host side follows the K1a order: fs-verify, fs-ack, fs-status, `fs-n1 <chal>` (the client runs meanwhile in B),
fs-done; the record is decoded with common/tools/fsb1.py (exp n1, 6 steps).
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
N1 = os.path.dirname(HERE)
Q3 = os.path.dirname(N1)
ROOT = os.environ.get("FS_INPUT_ROOT", "<repo>")
AOSP = ROOT + "/build/third_party/mkbootimg"
FSB1PY = Q3 + "/common/tools/fsb1.py"
CLIENT = HERE + "/xfer-client.py"
K1A_CONFIG = Q3 + "/k1a/kernel/k1a.config"
BB_REVIEWED = "c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02"
V27_VBOOT = ROOT + "/firmware/quest3/v2.7-user_ota/vendor_boot.img"
V27_VBOOT_SHA = "bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b"
DEADLINE, ACK_WINDOW, ERR_DELAY, GUARD = 200, 150, 60, 30
PORT = 47201
STEPS = ["kernel", "mem", "modules", "net", "xfer", "log"]
H2D = D2H = 8388608
ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
FSDE1 = re.compile(r"^FSDE1 error=(\S+)( [ -~]*)? END$")
SCRATCH = os.path.expanduser("~/work/fsimg-harness-n1")

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
# c-kmsg-post (FS-R-014 s.5): a WARNING the fake kernel log gains only once the transfer has begun (the harness sees
# the device's port-47201 session ESTABLISHED in A's /proc/net/tcp6); step 3's read cannot contain it, step 6's must
FAKE_KMSG_POST = ("[  120.000001] ------------[ cut here ]------------\n"
                  "[  120.000002] WARNING: CPU: 1 PID: 0 at harness/fake.c:1 harness_fake_warning_after_transfer_began+0x1/0x2\n")
FAKE_MODULES = "nautilus 16384 0 - Live 0x0000000000000000\ncmd_db 16384 0 - Live 0x0000000000000000\n"
FAKE_FILESYSTEMS = "nodev\tsysfs\nnodev\ttmpfs\nnodev\tproc\nnodev\tdevtmpfs\nnodev\tconfigfs\n"
FAKE_MOUNTS = "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n"


# ---------------------------------------------------------------------------------------------------------------
# KernelFake (k1a's, unchanged, plus N1's UDC-bind fault): a seccomp USER-NOTIFICATION filter answers syslog(2)
# from the canned log and opens of "/proc/mounts" with the fake file; in N1's c-ncm-bind-fail the FIRST open for
# writing of /config/usb_gadget/fs/UDC while the NCM link exists is answered ENODEV. Every other open continues.
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
_EPERM, _ENODEV, _EBUSY = 1, 19, 16


class _Iovec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def _bpf(code, jt, jf, k):
    return struct.pack("<HBBI", code, jt, jf, k)


def seccomp_exec(sock_fd, argv):
    prog = b"".join([
        _bpf(0x20, 0, 0, 4),
        _bpf(0x15, 0, 5, _AUDIT_ARCH_X86_64),
        _bpf(0x20, 0, 0, 0),
        _bpf(0x15, 4, 0, _NR_SYSLOG),
        _bpf(0x15, 3, 0, _NR_OPENAT),
        _bpf(0x15, 2, 0, _NR_OPEN),
        _bpf(0x15, 1, 0, _NR_OPENAT2),
        _bpf(0x06, 0, 0, 0x7FFF0000),
        _bpf(0x06, 0, 0, 0x7FC00000),
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
    def __init__(self, kmsg_text, mounts_path, udc_fault_link=None):
        self.kmsg = "".join("<6>" + l + "\n" for l in kmsg_text.splitlines()).encode()
        self.mounts = mounts_path
        self.udc_fault_link = udc_fault_link          # host path of configs/c.1/ncm.fs (c-ncm-bind-fail), else None
        self.counts = {"syslog-read": 0, "syslog-size": 0, "syslog-other": 0, "mounts-open": 0, "open-continue": 0,
                       "udc-enodev": 0, "addr-ebusy": 0, "errors": 0}
        self.ncm_link = None          # host path of configs/c.1/ncm.fs: dev_addr/host_addr writes after the link get EBUSY
        # FS-R-014 s.5 fixtures: what every syslog read AFTER the first one sees ("unreadable": EPERM; "wrapped": the
        # first two lines gone, as if the ring buffer had wrapped); post_lines: lines appended at runtime (c-kmsg-post)
        self.later_reads = None
        self.post_at = None
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
                continue
            nid, pid, _fl, nr, _arch, _ip, a0, a1, a2, a3, a4, a5 = struct.unpack("<QIIiIQ6Q", req)
            try:
                if nr == _NR_SYSLOG:
                    typ = ctypes.c_int32(a0 & 0xFFFFFFFF).value
                    ln = ctypes.c_int32(a2 & 0xFFFFFFFF).value
                    if typ == _SYSLOG_SIZE_BUFFER:
                        self.counts["syslog-size"] += 1
                        self._send(nid, val=max(len(self.kmsg), 4096))
                    elif typ == _SYSLOG_READ_CLEAR:          # dmesg -c (a state change): counted, must stay 0
                        self.counts["syslog-clear"] = self.counts.get("syslog-clear", 0) + 1
                        self._send(nid, err=-_EPERM)
                    elif typ == _SYSLOG_READ_ALL and ln > 0 and self.later_reads == "unreadable" and self.counts["syslog-read"] >= 1:
                        self.counts["syslog-refused"] = self.counts.get("syslog-refused", 0) + 1
                        self._send(nid, err=-_EPERM)
                    elif typ == _SYSLOG_READ_ALL and ln > 0:
                        src = self.kmsg
                        if self.later_reads == "wrapped" and self.counts["syslog-read"] >= 1:
                            src = b"".join(src.splitlines(True)[2:])
                        d = src[-ln:] if len(src) > ln else src
                        self._rw("w", pid, a1, d)
                        self.counts["syslog-read"] += 1
                        self._send(nid, val=len(d))
                    else:
                        self.counts["syslog-other"] += 1
                        self._send(nid, err=-_EPERM)
                    continue
                paddr, cloexec = (a0, a1 & os.O_CLOEXEC) if nr == _NR_OPEN else (a1, a2 & os.O_CLOEXEC)
                oflags = a1 if nr == _NR_OPEN else a2
                if nr == _NR_OPENAT2:
                    oflags = struct.unpack("<Q", self._rw("r", pid, a2, 8))[0]
                    cloexec = oflags & os.O_CLOEXEC
                path = self._path(pid, paddr)
                if path == b"/proc/mounts":
                    fd = os.open(self.mounts, os.O_RDONLY)
                    try:
                        fcntl.ioctl(self.lfd, _ADDFD, bytearray(struct.pack("<QIIII", nid, _ADDFD_FLAG_SEND, fd, 0,
                                                                            os.O_CLOEXEC if cloexec else 0)), True)
                    finally:
                        os.close(fd)
                    self.counts["mounts-open"] += 1
                elif (self.ncm_link and path in (b"/config/usb_gadget/fs/functions/ncm.fs/dev_addr", b"/config/usb_gadget/fs/functions/ncm.fs/host_addr")
                      and oflags & (os.O_WRONLY | os.O_RDWR) and os.path.lexists(self.ncm_link)):
                    # f_ncm (5.10): dev_addr/host_addr return EBUSY once the function is linked (opts->refcnt); faked at open
                    self.counts["addr-ebusy"] += 1
                    self._send(nid, err=-_EBUSY)
                elif (self.udc_fault_link and path == b"/config/usb_gadget/fs/UDC" and oflags & (os.O_WRONLY | os.O_RDWR)
                      and os.path.lexists(self.udc_fault_link) and self.counts["udc-enodev"] == 0):
                    self.counts["udc-enodev"] += 1
                    self._send(nid, err=-_ENODEV)
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


def nonce_ids(nonce):
    dev = "02:" + ":".join(nonce[i:i + 2] for i in range(0, 10, 2))
    host = "06:" + dev[3:]
    ll = "fe80::%s:%s:%s:%s" % (nonce[0:4], nonce[4:8], nonce[8:12], nonce[12:16])
    return dev, host, ll


def prepare(image_dir, w, mods):
    img = os.path.join(image_dir, "boot-n1.img")
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
    put(md + "/modules.load.recovery", "fake_a.ko\nfake_b.ko\nfake_c.ko\n")
    dep_text, soft_text = v27_index()
    if "moddep-mismatch" in mods:
        dep_text += "/lib/modules/fake_a.ko:\n"
    put(md + "/modules.dep", dep_text)
    put(md + "/modules.softdep", soft_text)
    full = [l.strip() for l in open(r + "/lib/fs/modules.load") if l.strip()]
    if "modules-real" not in mods and "moddep-mismatch" not in mods:
        put(r + "/lib/fs/modules.load", "".join(m + "\n" for m in short_list(full, dep_text, soft_text)))
    s = r + "/sys"
    put(s + "/class/udc/a600000.dwc3/state", "default\n" if "never-configured" in mods else ("not attached\n" if "unattached" in mods else "configured\n"))
    put(s + "/devices/platform/soc/a600000.ssusb/mode", "host\n")
    put(s + "/class/usb_role/a600000.dwc3-role-switch/role", "host\n")
    put(s + "/class/firmware/timeout", "60\n")
    for c in ("red", "green", "blue"):
        put(s + "/class/leds/%s/brightness" % c, "0\n")
    put(s + "/class/backlight/panel0-backlight/brightness", "255\n")
    put(s + "/class/drm/card0/dev", "226:0\n", 0o444)
    os.makedirs(s + "/class/net/usb0", exist_ok=True)          # the mount point of A's real usb0 sysfs directory
    g = r + "/config/usb_gadget/fs"
    os.makedirs(r + "/config/usb_gadget", exist_ok=True)
    if "ncm-skip" in mods:      # the NCM function cannot be made: a FILE where its directory would go
        put(g + "/functions/ncm.fs", "blocker\n", 0o444)
    else:                       # f_ncm's ifname attribute (the netdev's name after the bind; "usb0")
        put(g + "/functions/ncm.fs/ifname", "(unnamed net_device)\n" if "ifname-unbound" in mods else "usb0\n")
    if "bind-fail" in mods:     # the UDC bind fails (a DIRECTORY where the UDC attribute would be): both binds fail
        os.makedirs(g + "/UDC", exist_ok=True)
    os.makedirs(r + "/.rec", exist_ok=True)
    os.makedirs(w + "/rec")
    put(w + "/fake/fs-reboot-final", FAKE_FINAL, 0o755)
    put(w + "/fake/fs-reboot", FAKE_REBOOT, 0o755)
    put(w + "/fake/version", banner_of_manifest(image_dir) + "\n", 0o444)
    cfg = open(K1A_CONFIG, "rb").read()
    put(w + "/fake/config.gz", gzip.compress(cfg, mtime=0), 0o444)
    put(w + "/fake/meminfo", FAKE_MEMINFO if "no-memtotal" not in mods else FAKE_MEMINFO.replace("MemTotal", "MemTota1"), 0o444)
    put(w + "/fake/cmdline", FAKE_CMDLINE, 0o444)
    put(w + "/fake/kmsg", FAKE_KMSG_FINDINGS if "kmsg-findings" in mods else FAKE_KMSG_CLEAN, 0o444)
    put(w + "/fake/modules", FAKE_MODULES, 0o444)
    put(w + "/fake/filesystems", FAKE_FILESYSTEMS, 0o444)
    put(w + "/fake/mounts", FAKE_MOUNTS, 0o444)
    put(w + "/fake/tainted", "0\n", 0o444)
    return r, sha(cfg)


class Net:
    """Namespace A (this process, from unshare -rnm) holds usb0; namespace B (a sleeping child) holds hst0."""

    def __init__(self, w, nonce):
        self.w = w
        self.dev, self.host, self.ll = nonce_ids(nonce)
        self.b = None
        self.decoy = None

    def ip(self, *a, ns=False):
        cmd = (["nsenter", "-t", str(self.b.pid), "-n", "--"] if ns else []) + ["ip"] + list(a)
        run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def setup(self):
        # A's lo stays down, as on the unit (nothing in the image brings it up)
        self.b = subprocess.Popen(["unshare", "-n", "sleep", "1000"], stdin=subprocess.DEVNULL)
        time.sleep(0.3)
        self.ip("link", "add", "usb0", "type", "veth", "peer", "name", "hst0")
        self.ip("link", "set", "usb0", "address", self.dev)
        self.ip("link", "set", "hst0", "address", self.host)
        self.ip("link", "set", "hst0", "netns", str(self.b.pid))
        # B plays the PC: its own link-local address (random-like, fe80::1 here), no DAD wait, lo up
        run(["nsenter", "-t", str(self.b.pid), "-n", "--", "sh", "-c",
             "echo 0 > /proc/sys/net/ipv6/conf/hst0/accept_dad && echo 1 > /proc/sys/net/ipv6/conf/hst0/addr_gen_mode && ip link set lo up"])
        # A's sysfs (shows usb0): bind-mounted into the sandbox at /sys/class/net/usb0
        os.makedirs(self.w + "/sysfs")
        run(["mount", "-t", "sysfs", "sysfs", self.w + "/sysfs"])
        return self.w + "/sysfs/devices/virtual/net/usb0"

    def host_up(self):        # the PC's NCM driver binds: carrier on usb0
        self.ip("link", "set", "hst0", "up", ns=True)
        self.ip("-6", "addr", "add", "fe80::1/64", "dev", "hst0", ns=True)

    def client(self, od, nonce, chal, mode, window):
        os.makedirs(od, exist_ok=True)
        return subprocess.Popen(["nsenter", "-t", str(self.b.pid), "-n", "--", "python3", "-I", CLIENT, "--addr", self.ll, "--scope", "hst0",
                                 "--port", str(PORT), "--nonce", nonce, "--chal", chal, "--out", od, "--window", str(window), "--mode", mode],
                                stdout=open(od + "/client.out", "wb"), stderr=subprocess.STDOUT)

    def probe(self, port):    # one TCP connect from B: "refused" proves nothing listens there
        p = subprocess.run(["nsenter", "-t", str(self.b.pid), "-n", "--", "python3", "-I", "-c",
                            "import socket,sys\ns=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);s.settimeout(3)\n"
                            "try:\n s.connect(('%s',%d,0,socket.if_nametoindex('hst0')));print('connected')\n"
                            "except ConnectionRefusedError:print('refused')\nexcept Exception as e:print('other %%s'%%type(e).__name__)" % (self.ll, port)],
                           capture_output=True, text=True)
        return p.stdout.strip()

    def open_decoy(self):     # unintended listeners in A (the sandbox's namespace): UDP [::]:5353 and TCP LISTEN [::]:2222
        self.decoy = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        self.decoy.bind(("::", 5353))
        self.decoy_t = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        self.decoy_t.bind(("::", 2222))
        self.decoy_t.listen(1)

    def close(self):
        if self.decoy:
            self.decoy.close()
            self.decoy_t.close()
        if self.b:
            self.b.kill()
            self.b.wait()
        subprocess.run(["umount", self.w + "/sysfs"], stderr=subprocess.DEVNULL)


class Host:
    def __init__(self, master):
        self.m = master
        self.buf = bytearray()
        self.writes = []
        self.chunks = []
        self.wix = []
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

    def runner(self, chal, timeout=150):
        off = len(self.buf)
        self.write("fs-n1 %s" % chal)
        done = lambda: self.find_record(off, "FSB1 END") is not None or self.find_record(off, "FSDE1") is not None
        got = self.wait(done, timeout)
        ok = got and self.wait(lambda: self.prompt_settled(off), 8)
        end, ref = self.find_record(off, "FSB1 END"), self.find_record(off, "FSDE1")
        self.log.append("%7d ms  R %s%s" % (self.ms(), (end or ref or "no completion")[:150], "" if ok else "  (no settled prompt)"))
        return bytes(self.buf[off:]), end, ref, ok


def index_text(h, nonce):
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


# name: (mods, plan, want_reboot, client mode or None, expected fs-xfer result or None, expected NCM state)
#   plan items: "verify", "ack", "run", "run-again", "run-badchal", "time", "done", "wait-guard"
#   mods: "host-down" (hst0 never up: no carrier), "decoy" (a UDP socket in A before the runner), plus prepare()'s
SCEN = {
    "c-full": ([], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-ncm-bind-fail": (["ncm-bind-fail"], ["verify", "ack", "run", "done"], "collected", "no-connect", "no-ncm", "dropped"),
    "c-bind-fail": (["bind-fail"], [], "error-udc", None, None, "dropped"),
    "c-ncm-skip": (["ncm-skip"], ["verify", "ack", "run", "done"], "collected", "no-connect", "no-ncm", "none"),
    "c-ncm-ifname": (["ifname-unbound"], ["verify", "ack", "run", "done"], "collected", "no-connect", "no-ncm", "net-failed"),
    "c-ncm-no-host": (["host-down"], ["verify", "ack", "run", "done"], "collected", "no-connect", "accept-timeout", "up"),
    "c-ncm-fallback": (["never-configured", "host-down"], ["wait-guard", "verify", "ack", "run", "done"], "collected", "no-connect", "no-ncm", "fallback"),
    "c-ncm-unattached": (["unattached", "host-down"], ["wait-guard", "verify", "ack", "run", "done"], "collected", "no-connect", "accept-timeout", "up"),
    "c-xfer-bad-header": ([], ["verify", "ack", "run", "done"], "collected", "bad-header", "bad-header", "up"),
    "c-xfer-short": ([], ["verify", "ack", "run", "done"], "collected", "short", "rx-short", "up"),
    "c-listener-decoy": (["decoy"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-no-memtotal": (["no-memtotal"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-kmsg-findings": (["kmsg-findings"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-kmsg-post": (["kmsg-post"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-kmsg-post-unreadable": (["kmsg-post-unreadable"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-kmsg-post-wrapped": (["kmsg-post-wrapped"], ["verify", "ack", "run", "done"], "collected", "ok", "ok", "up"),
    "c-repeat": ([], ["verify", "ack", "run", "run-again", "done"], "collected", "ok", "ok", "up"),
    "c-bad-challenge": ([], ["verify", "ack", "run-badchal", "done"], "collected", None, None, "up"),
    "c-time": ([], ["verify", "ack", "time", "run", "done"], "collected", None, None, "up"),
    "c-no-ack": ([], ["verify"], "no-host-ack", None, None, "up"),
    "c-ack-no-done": ([], ["verify", "ack"], "deadline", None, None, "up"),
    "c-done-early": ([], ["verify", "done"], "collected", None, None, "up"),
    "c-modules-real": (["modules-real"], ["verify", "done"], "collected", None, None, "up"),
    "c-modules-refused": (["moddep-mismatch"], [], "error-modules", None, None, None),
}


SOCK_TABLES = ("tcp", "tcp6", "udp", "udp6", "udplite", "udplite6", "raw", "raw6", "packet")


def section(text, title):
    """the lines after '== <title>' up to the next '== ' line"""
    out, on = [], False
    for l in text.splitlines():
        if l.startswith("== "):
            if on:
                break
            on = (l == "== " + title)
            continue
        if on:
            out.append(l)
    return out


def sock_rows(text, which):
    """{table: [data rows]} of a '== sockets <which>' section (grep -H lines '/proc/net/<t>:<row>'; header rows dropped)"""
    rows = {t: [] for t in SOCK_TABLES}
    seen = set()
    for l in section(text, "sockets " + which):
        m = re.match(r"^/proc/net/(\w+):(.*)$", l)
        if not m or m.group(1) not in rows:
            continue
        seen.add(m.group(1))
        body = m.group(2)
        if re.match(r"^\s*(sl|sk)\s", body):
            continue
        rows[m.group(1)].append(body)
    return rows, seen


def attrs(text, title):
    """{basename: value} of a section of grep -H lines"""
    d = {}
    for l in section(text, title):
        m = re.match(r"^(/[^:]+):(.*)$", l)
        if m:
            d[m.group(1).rsplit("/", 1)[-1]] = m.group(2)
    return d


def kv_of(text, prefix):
    m = re.search(r"^" + re.escape(prefix) + r"(.*)$", text, re.M)
    return dict(x.split("=", 1) for x in m.group(1).split() if "=" in x) if m else {}


def scenario(name, image_dir, outdir):
    mods, plan, want, cmode, xres, ncm_want = SCEN[name]
    od = os.path.join(outdir, name)
    shutil.rmtree(od, ignore_errors=True)
    os.makedirs(od)
    os.makedirs(SCRATCH, exist_ok=True)
    w = tempfile.mkdtemp(prefix=name + ".", dir=SCRATCH)
    res = {"scenario": name, "mods": mods, "plan": plan, "want_reboot": want, "client_mode": cmode, "want_xfer": xres, "want_ncm": ncm_want, "checks": []}

    def check(label, ok, detail=""):
        res["checks"].append({"label": label, "ok": bool(ok), "detail": detail})

    stop = threading.Event()
    net = None
    client = None
    try:
        if os.getuid() != 0 or not os.path.exists("/proc/self/ns/net"):
            raise SystemExit("run under `unshare -rnm` (n1/test-image.sh does)")
        r, cfg_sha = prepare(image_dir, w, mods)
        nonce = re.search(r'^NONCE="([0-9a-f]{16})"$', open(r + "/init").read(), re.M).group(1)
        dev, hostmac, ll = nonce_ids(nonce)
        net = Net(w, nonce)
        usb0_sys = net.setup()
        if "decoy" in mods:
            net.open_decoy()
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
               "--ro-bind", usb0_sys, "/sys/class/net/usb0",
               "--dev-bind", slave, "/dev/ttyGS0",
               "--ro-bind", w + "/fake/fs-reboot-final", "/bin/fs-reboot-final",
               "--ro-bind", w + "/fake/fs-reboot", "/bin/fs-reboot",
               "--bind", w + "/rec", "/.rec",
               "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--as-pid-1",
               "--die-with-parent", "--cap-drop", "ALL", "--cap-add", "CAP_NET_ADMIN", "--clearenv", "--chdir", "/",
               "--setenv", "HOME", "/", "--setenv", "TERM", "linux",
               "--info-fd", str(info_w), "/bin/busybox", "sh", "/init"]
        kfake = KernelFake(open(w + "/fake/kmsg").read(), w + "/fake/mounts",
                           udc_fault_link=(r + "/config/usb_gadget/fs/configs/c.1/ncm.fs") if "ncm-bind-fail" in mods else None)
        kfake.ncm_link = r + "/config/usb_gadget/fs/configs/c.1/ncm.fs"
        kfake.later_reads = "unreadable" if "kmsg-post-unreadable" in mods else ("wrapped" if "kmsg-post-wrapped" in mods else None)
        if "kmsg-post" in mods:     # append FAKE_KMSG_POST once the device's port-47201 session is ESTABLISHED (A's tcp6)
            def post_watch():
                while not stop.is_set() and kfake.post_at is None:
                    try:
                        est = any(l.split()[1].endswith(":%04X" % PORT) and l.split()[3] == "01" for l in open("/proc/net/tcp6").read().splitlines()[1:])
                    except (OSError, IndexError):
                        est = False
                    if est:
                        kfake.kmsg += "".join("<4>" + l + "\n" for l in FAKE_KMSG_POST.splitlines()).encode()
                        kfake.post_at = (up(), kfake.counts["syslog-read"])
                        break
                    time.sleep(0.05)
            threading.Thread(target=post_watch, daemon=True).start()
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
        inet6_before_host = open("/proc/net/if_inet6").read()
        if "host-down" not in mods and ncm_want is not None:
            net.host_up()          # the PC's driver binds the NCM function: carrier
            time.sleep(1.0)
        res["inet6_before_host"] = inet6_before_host
        t_done = None
        rec = None
        probe_before = net.probe(PORT) if plan else None
        for step in plan:
            if step == "wait-guard":       # past SHELL_READY + NCM_GUARD_S: the guard has acted
                lg0 = r + "/run/fs.log"
                h.wait(lambda: os.path.exists(lg0) and ("NCM_FALLBACK rebind" in open(lg0).read() or "NCM_GUARD done" in open(lg0).read()), GUARD + 20)
                h.pump(1.0)
            elif step == "verify":
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
            elif step == "time":
                put(r + "/run/fs.deadline", "%d\n" % (int(up()) + 30))
            elif step in ("run", "run-again", "run-badchal"):
                if step == "run" and cmode and client is None:
                    client = net.client(od + "/host-xfer", nonce, rchal, cmode, 40 if cmode == "no-connect" else 60)
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
                pr = subprocess.run(["python3", "-I", FSB1PY, "check", "--exp", "n1", "--nonce", nonce, "--chal", rchal,
                                     "--steps", ",".join(STEPS), "--dump", dd, od + "/runner-run.raw"], capture_output=True, text=True)
                open(od + "/fsb1.txt", "w").write(pr.stdout + pr.stderr)
                check("FSB1 VALID (exp n1, 6 steps kernel..log, this nonce and challenge)", pr.returncode == 0 and pr.stdout.startswith("VALID"),
                      (pr.stdout or pr.stderr).splitlines()[0] if (pr.stdout or pr.stderr) else "")
                rec = {i + 1: (open(dd + "/%d.out" % (i + 1), "rb").read() if os.path.exists(dd + "/%d.out" % (i + 1)) else b"") for i in range(6)}
                stl = re.findall(r"^\s+step (\d+) (\w+) end=(\S+) code=(-?\d+)", pr.stdout, re.M)
                check("every step exited 0", len(stl) == 6 and all(x[2] == "exited" and x[3] == "0" for x in stl), str(stl))
                errs = [i for i in range(1, 7) if os.path.exists(dd + "/%d.err" % i) and os.path.getsize(dd + "/%d.err" % i)]
                check("no step wrote stderr", not errs, str(errs))
            elif step == "done":
                d_ = h.command("fs-done", "", "FSD1", 10)
                t_done = up()
                check("FSD1 queued", d_ == "FSD1 queued END", d_ or "")
        probe_after = net.probe(PORT) if rec else None
        limit = {"collected": 15, "no-host-ack": ACK_WINDOW + 40, "deadline": DEADLINE + 40, "error-modules": 90, "error-udc": 90}[want]
        rp = w + "/rec/reboots"
        end_t = time.monotonic() + limit
        while time.monotonic() < end_t and not (os.path.exists(rp) and os.path.getsize(rp) > 0):
            h.pump(0.2)
        h.pump(1.5)
        reboots = open(rp).read() if os.path.exists(rp) else ""
        if client is not None:
            try:
                client.wait(70)
            except subprocess.TimeoutExpired:
                client.kill()
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
        for f in ("fs.log", "fs.stages", "fs.acked", "fs.collected", "fs.ncm"):
            if os.path.exists(r + "/run/" + f):
                shutil.copy(r + "/run/" + f, od + "/" + f)
        log = open(r + "/run/fs.log").read() if os.path.exists(r + "/run/fs.log") else ""
        stg = open(r + "/run/fs.stages").read().split() if os.path.exists(r + "/run/fs.stages") else []
        fsn = open(r + "/run/fs.ncm").read() if os.path.exists(r + "/run/fs.ncm") else ""
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
            if want in ("error-udc", "error-modules"):
                check("%s: reboot at T0 + ERR_DELAY 60 (..+4)" % want, ERR_DELAY <= tr - T0 <= ERR_DELAY + 4, "T0+%.1f" % (tr - T0))
        check("no access to the decoy backlight or DRM node (inotify: 0 events)", not decoy_ev, " | ".join(decoy_ev[:5]))
        stray = tty_strays(bytes(h.buf), h.writes)
        check("tty accounting: only the banner, echoed commands, protocol/record lines and prompts (no stray tty output)", not stray, " | ".join(stray[:4]))
        ml = [l.strip()[:-3] for l in open(r + "/lib/fs/modules.load") if l.strip()]
        att = re.findall(r"MODULE_FAIL (\S+)\.ko", log)
        if "moddep-mismatch" in mods:
            check("index mismatch: MODULES_REFUSED then ERROR_modules, no module attempted, no NCM step, no SHELL_READY",
                  "MODULES_REFUSED" in stg and "ERROR_modules" in stg and not att and "MODULE_INDEX" not in log and "SHELL_READY" not in stg
                  and "NCM " not in log, " ".join(stg))
        elif "modules-real" in mods:
            check("modules attempted = the image's 95-entry list, each once, nothing else",
                  len(ml) == 95 and sorted(att) == sorted(ml) and len(set(att)) == len(att) and not any(x.startswith("fake_") for x in att),
                  "attempted %d" % len(att))
        else:
            check("MODULE_INDEX logged; modules attempted = the harness short list in order", "MODULE_INDEX dep=" in log and att == ml, "attempted %s" % att)
        # ---- N1: the gadget, NCM and the link ----
        g = r + "/config/usb_gadget/fs"
        udc_now = open(g + "/UDC").read().strip() if os.path.isfile(g + "/UDC") else "(not a file)"
        if "bind-fail" in mods:
            check("both binds fail: NCM linked, NCM_DROPPED, the ACM-only retry fails: ERROR_udc ('bind failed (ACM-only retry)'), no shell",
                  "NCM function=linked" in log and "NCM_DROPPED" in log and "ERROR stage=udc bind failed (ACM-only retry)" in log
                  and "ERROR_udc" in stg and "UDC_BOUND" not in stg and "SHELL_READY" not in stg, " ".join(stg))
        elif ncm_want is not None:
            mfun = re.search(r"NCM function=(\S+) dev_addr=(\S+) host_addr=(\S+) ll=(\S+) port=(\d+)", log)
            check("NCM ids from the nonce: dev_addr 02:<nonce 0-4>, host_addr 06:<nonce 0-4>, ll fe80::<nonce>, port 47201",
                  bool(mfun) and mfun.group(2) == dev and mfun.group(3) == hostmac and mfun.group(4) == ll and mfun.group(5) == str(PORT),
                  mfun.group(0) if mfun else "no NCM function line")
            check("the ACM console came up in every NCM case: UDC_BOUND and SHELL_READY", "UDC_BOUND" in stg and "SHELL_READY" in stg, " ".join(stg))
            if ncm_want == "up":
                check("NCM linked after acm.gs0, bound, network up: NCM_NET if=usb0 addr=fe80::<nonce>/64; fs.ncm state=up",
                      "NCM function=linked" in log and ("NCM_NET if=usb0 addr=%s/64" % ll) in log and "state=up\nif=usb0\n" in fsn
                      and os.path.islink(g + "/configs/c.1/ncm.fs") and os.path.islink(g + "/configs/c.1/acm.gs0"), fsn.replace("\n", " "))
                ap = open(g + "/functions/ncm.fs/dev_addr").read().strip() if os.path.exists(g + "/functions/ncm.fs/dev_addr") else ""
                check("configfs dev_addr/host_addr written with the nonce MACs", ap == dev, ap)
                check("no NCM_SKIPPED/NCM_DROPPED/NCM_NET_FAILED/NCM_FALLBACK; the guard " + ("saw no attached host and changed nothing" if "unattached" in mods else "saw the configured gadget"),
                      not re.search(r"NCM_(SKIPPED|DROPPED|NET_FAILED|FALLBACK)", log)
                      and ((("NCM_GUARD done" in log and "no host attached (state=not attached)" in log) if "unattached" in mods else "NCM_GUARD done" in log) or want != "collected" or not plan), "")
                check("configfs: no dev_addr/host_addr write after the NCM link (the fake answers EBUSY as f_ncm does)", kfake.counts["addr-ebusy"] == 0, str(kfake.counts))
            if ncm_want == "dropped":
                check("NCM bind failure: NCM_DROPPED, the link removed, ONE ACM-only retry succeeded (UDC a600000.dwc3), console up; fs.ncm state=dropped",
                      "NCM_DROPPED the bind failed with NCM linked" in log and "ncm link left: no" in log and kfake.counts["udc-enodev"] == 1
                      and udc_now == "a600000.dwc3" and not os.path.lexists(g + "/configs/c.1/ncm.fs") and "state=dropped\n" in fsn,
                      "enodev=%d udc=%s fs.ncm=%s" % (kfake.counts["udc-enodev"], udc_now, fsn.replace("\n", " ")))
            if ncm_want == "none":
                check("NCM setup failure before the bind: NCM_SKIPPED step=mkdir, ACM-only bind, fs.ncm state=none",
                      "NCM_SKIPPED step=mkdir" in log and "NCM function=none" in log and "state=none\n" in fsn and udc_now == "a600000.dwc3", fsn.replace("\n", " "))
            if ncm_want == "net-failed":
                check("NCM bound but its ifname is not a plain name: NCM_NET_FAILED, the function stays bound, fs.ncm state=net-failed",
                      "NCM_NET_FAILED ifname '(unnamed net_device)' is not a plain name" in log and "state=net-failed\n" in fsn
                      and os.path.islink(g + "/configs/c.1/ncm.fs"), fsn.replace("\n", " "))
            if ncm_want == "fallback":
                check("ACM-continuity guard: no configured state and no ack within 30 s of SHELL_READY: NCM_FALLBACK, unbind, NCM link removed, rebind ACM-only (UDC a600000.dwc3), fs.ncm state=fallback",
                      "NCM_FALLBACK no configured state" in log and "NCM_FALLBACK rebind rc=0 retry=- udc=a600000.dwc3 ncm-link=no" in log
                      and "state=fallback\n" in fsn and not os.path.lexists(g + "/configs/c.1/ncm.fs"), fsn.replace("\n", " "))
                msr = re.search(r"t=(\d+)s STAGE=SHELL_READY", log)
                mfb = re.search(r"t=(\d+)s NCM_FALLBACK no configured", log)
                check("the fallback came at SHELL_READY + 30..33 s", bool(msr and mfb) and GUARD <= int(mfb.group(1)) - int(msr.group(1)) <= GUARD + 3,
                      "%s / %s" % (msr.group(0) if msr else "-", mfb.group(0) if mfb else "-"))
        if ncm_want == "up" and plan:
            check("before the host link (no carrier): the device address was already PERMANENT (flags 80: DAD off means no tentative phase)",
                  re.search(r"^%s [0-9a-f]{2} 40 20 80 +usb0$" % ("fe80000000000000" + nonce), res["inet6_before_host"], re.M) is not None,
                  " | ".join(l for l in res["inet6_before_host"].splitlines() if "usb0" in l))
        if probe_before is not None and ncm_want == "up" and "host-down" not in mods:
            check("before the runner: a connect to [fe80::<nonce>%%hst0]:%d is refused (nothing listens)" % PORT, probe_before == "refused", probe_before)
        if probe_after is not None and ncm_want == "up" and "host-down" not in mods:
            check("after the record: a connect to port %d is refused again (the listener is gone)" % PORT, probe_after == "refused", probe_after)
        # ---- the record ----
        if rec:
            k, me, mo, nt, xf, lg = (rec[i].decode("latin-1") for i in range(1, 7))
            ban = banner_of_manifest(image_dir)
            check("kernel step: /proc/version = the pinned K1a banner; config_sha256 = sha256(k1a.config); K1a and N1 option lines",
                  ("== proc-version\n" + ban + "\n") in k and ("== config_sha256 %s" % cfg_sha) in k and "CONFIG_DEVTMPFS=y" in k
                  and "CONFIG_USB_CONFIGFS_NCM=y" in k and "CONFIG_USB_F_NCM=y" in k and "CONFIG_IPV6=y" in k, k[:200])
            if "no-memtotal" in mods:
                check("mem step: no MemTotal line (the classifier must refuse a PASS)", "MemTotal:" not in me, me[:80])
            else:
                check("mem step: MemTotal reported", re.search(r"^MemTotal: +11683848 kB$", me, re.M) is not None, me[:80])
            check("modules step: loader lines, /proc/modules and the kmsg section", "MODULE_INDEX dep=" in mo and "== proc-modules" in mo
                  and re.search(r"^== warnings \d+ warning-lines, \d+ bug-lines, \d+ lines$", mo, re.M) is not None, mo[:200])
            if "kmsg-findings" in mods:
                check("kmsg findings: modver-matches 4, taint-lines 1, 1 WARNING in 3 lines",
                      re.search(r"^== modver-matches 4$", mo, re.M) is not None and re.search(r"^== taint-lines 1$", mo, re.M) is not None
                      and re.search(r"^== warnings 1 warning-lines, 0 bug-lines, 3 lines$", mo, re.M) is not None, "")
            else:
                check("kmsg clean: modver-matches 0, taint-lines 0, warnings 0", re.search(r"^== modver-matches 0$", mo, re.M) is not None
                      and re.search(r"^== warnings 0 warning-lines, 0 bug-lines, 0 lines$", mo, re.M) is not None, "")
            fn_want = {"up": "acm.gs0 ncm.fs ", "net-failed": "acm.gs0 ncm.fs "}.get(ncm_want, "acm.gs0 ")
            ud, gd = attrs(nt, "udc"), attrs(nt, "gadget")
            check("net step: UDC a600000.dwc3 (state as faked), config functions '%s', product FrameShift N1, serial FS-<nonce>" % fn_want.strip(),
                  ud.get("UDC") == "a600000.dwc3" and ud.get("state") == ("default" if "never-configured" in mods else ("not attached" if "unattached" in mods else "configured")) and ("== config-functions " + fn_want + "\n") in nt
                  and gd.get("product") == "FrameShift N1" and gd.get("serialnumber") == "FS-" + nonce, str(ud) + str(gd))
            if ncm_want == "up":
                ia, ic = attrs(nt, "if usb0"), attrs(nt, "ipv6conf usb0")
                check("net step: usb0 with MAC dev_addr, the IPv6 sysctls (disable_ipv6 0, addr_gen_mode 1, accept_dad 0, dad_transmits 0, accept_ra 0, autoconf 0, router_solicitations 0, forwarding 0)",
                      ia.get("address") == dev and ic == {"disable_ipv6": "0", "addr_gen_mode": "1", "accept_dad": "0", "dad_transmits": "0", "accept_ra": "0",
                                                           "autoconf": "0", "router_solicitations": "0", "forwarding": "0"}, str(ia) + str(ic))
                v6 = [l for l in section(nt, "if_inet6") if l.endswith(" usb0")]
                check("net step: exactly ONE IPv6 address on usb0: fe80::<nonce>, prefix 64, scope link (20), permanent (80)",
                      len(v6) == 1 and v6[0].split()[0] == "fe80000000000000" + nonce and v6[0].split()[2] == "40" and v6[0].split()[3] == "20"
                      and v6[0].split()[4] == "80", " | ".join(v6))
            rb, seen_b = sock_rows(nt, "before")
            ra, seen_a = sock_rows(lg, "after")
            listen = lambda rows: [r_ for t in ("tcp", "tcp6") for r_ in rows[t] if len(r_.split()) > 3 and r_.split()[3] == "0A"]
            other = lambda rows: {t: len(rows[t]) for t in ("udp", "udp6", "udplite", "udplite6", "raw", "raw6", "packet") if rows[t]}
            cnt = lambda rows: {t: len(v) for t, v in rows.items()}
            need_t = {"tcp", "tcp6", "udp", "udp6", "raw", "raw6", "packet"}
            check("net and log steps: every socket table was read (tcp, tcp6, udp, udp6, raw, raw6, packet)",
                  need_t <= seen_b and need_t <= seen_a, "before %s after %s" % (sorted(seen_b), sorted(seen_a)))
            if "decoy" in mods:
                check("decoy: the net step's socket tables show both unintended listeners (udp6 port 14E9 = 5353; tcp6 LISTEN port 08AE = 2222)",
                      len(rb["udp6"]) == 1 and ":14E9 " in rb["udp6"][0] and any(":08AE " in x and x.split()[3] == "0A" for x in rb["tcp6"]), str(cnt(rb)))
            else:
                check("no unintended listener BEFORE the transfer: no TCP LISTEN row; no udp, udplite, raw or packet socket",
                      not listen(rb) and not other(rb), str(cnt(rb)))
            check("no listener AFTER the transfer%s" % (" except the decoys" if "decoy" in mods else ": no TCP LISTEN row; no udp, udplite, raw or packet socket"),
                  ("decoy" in mods and all(":08AE " in x for x in listen(ra))) or (not listen(ra) and not other(ra)), str(cnt(ra)))
            xr = kv_of(xf, "FSX1 result=")
            xres_got = re.search(r"^FSX1 result=(\S+)", xf, re.M)
            check("xfer step: fs-xfer result=%s" % xres, bool(xres_got) and xres_got.group(1) == xres, xf[-300:])
            if xres == "ok":
                rxl = re.search(r"^FSX1 rx bytes=(\d+) sha256=([0-9a-f]{64}) ms=(\d+)$", xf, re.M)
                txl = re.search(r"^FSX1 tx bytes=(\d+) sha256=([0-9a-f]{64}) ms=(\d+) trailer=1$", xf, re.M)
                acc = re.search(r"^FSX1 accept peer=(fe80::\S+) scope=(\d+) ", xf, re.M)
                hj = json.load(open(od + "/host-xfer/xfer.json")) if os.path.exists(od + "/host-xfer/xfer.json") else {}
                check("transfer: device rx 8388608 bytes with the host's SHA-256, device tx 8388608 with the host's SHA-256 and the expected stream",
                      bool(rxl and txl) and int(rxl.group(1)) == H2D and int(txl.group(1)) == D2H and hj.get("Result") == "ok"
                      and rxl.group(2) == hj["H2d"]["Sha256"] and txl.group(2) == hj["D2h"]["Sha256"] == hj["D2h"]["ExpectedSha256"],
                      "host %s rx %s tx %s" % (hj.get("Result"), rxl.group(2)[:12] if rxl else "-", txl.group(2)[:12] if txl else "-"))
                check("transfer: the peer was link-local on usb0 (scope = usb0's ifindex), the listener closed at the accept, drain eof=1 bytes=0",
                      bool(acc) and "FSX1 closed-listener" in xf and re.search(r"^FSX1 drain bytes=0 eof=1$", xf, re.M) is not None, acc.group(0) if acc else "")
                res["xfer"] = {"rx_ms": int(rxl.group(3)) if rxl else None, "tx_ms": int(txl.group(3)) if txl else None,
                               "host_h2d_ms": hj.get("H2d", {}).get("Ms"), "host_d2h_ms": hj.get("D2h", {}).get("Ms")}
            if ncm_want == "up" and "host-down" not in mods:
                cn = attrs(lg, "counters usb0")
                big = xres == "ok"
                check("log step: usb0 counters after the transfer%s" % (" (rx and tx each above 8 MiB)" if big else ""),
                      cn.get("rx_bytes", "").isdigit() and cn.get("tx_bytes", "").isdigit()
                      and (not big or (int(cn["rx_bytes"]) > H2D and int(cn["tx_bytes"]) > D2H)), str(cn))
            check("log step: /run/fs.log with SHELL_READY", "== fs.log" in lg and "STAGE=SHELL_READY" in lg, "")
            # ---- the post-transfer kernel-log check (FS-R-014 s.5) ----
            me_ = re.search(r"^== kmsg-post-end$", lg, re.M)
            kp = lg[:me_.start()] if me_ else ""
            kv = lambda pat: (re.search(pat, kp, re.M).groups() if re.search(pat, kp, re.M) else None)
            pre_l = re.search(r"^== kmsg-lines (\d+) first=(.*)$", mo, re.M)
            check("log step: the post-transfer kernel-log check comes FIRST and is closed by its end marker",
                  lg.startswith("== kmsg-post read=") and bool(kp) and lg.index("== kmsg-post-end") < lg.index("== fs.log"), lg[:80])
            if "kmsg-post-unreadable" in mods:
                check("kmsg-post: the second kernel-log read is refused (EPERM): read=fail rc=1, nothing but the end marker",
                      re.search(r"\A== kmsg-post read=fail rc=1 bytes=[1-9][0-9]*\n\Z", kp) is not None and kfake.counts.get("syslog-refused", 0) >= 1, kp[:120])
            else:
                pl, pf, pw = kv(r"^== kmsg-post-lines (\d+)$"), kv(r"^== kmsg-post-first (.*)$"), kv(r"^== kmsg-post-warnings (\d+) warning-lines, (\d+) bug-lines, (\d+) lines, (\d+) listed$")
                check("kmsg-post: read=ok; lines, first, last, modver, taint, warnings and ncm lines reported",
                      kp.startswith("== kmsg-post read=ok rc=0 ") and pl and pf and pw and kv(r"^== kmsg-post-last (.*)$") and kv(r"^== kmsg-post-modver (\d+)$")
                      and kv(r"^== kmsg-post-taint (\d+)$") and kv(r"^== kmsg-post-ncm (\d+) lines, (\d+) listed$"), kp[:200])
                if pl and pf and pw and pre_l:
                    if "kmsg-post-wrapped" in mods:
                        check("kmsg-post (wrapped): the post read's first line is not step 3's and it has fewer lines (coverage not proven)",
                              pf[0] != pre_l.group(2) and int(pl[0]) < int(pre_l.group(1)), "%s/%s vs %s/%s" % (pl[0], pf[0], pre_l.group(1), pre_l.group(2)))
                    else:
                        check("kmsg-post: the post read extends step 3's (same first line, no fewer lines)",
                              pf[0] == pre_l.group(2) and int(pl[0]) >= int(pre_l.group(1)), "%s/%s vs %s/%s" % (pl[0], pf[0], pre_l.group(1), pre_l.group(2)))
                    want_pw = {"kmsg-findings": ("1", "0", "3"), "kmsg-post": ("1", "0", "2")}
                    wk = next((m_ for m_ in want_pw if m_ in mods), None)
                    exp = want_pw.get(wk, ("0", "0", "0"))
                    check("kmsg-post: %s WARNING, %s BUG, %s matching lines after the transfer" % exp, pw[:3] == exp and pw[3] == exp[2], str(pw))
                if "kmsg-post" in mods:
                    check("kmsg-post: the WARNING was logged only after the transfer began (session ESTABLISHED; after step 3's read, before step 6's)",
                          kfake.post_at is not None and kfake.post_at[1] == 1 and re.search(r"^== warnings 0 warning-lines, 0 bug-lines, 0 lines$", mo, re.M) is not None
                          and "harness_fake_warning_after_transfer_began" in kp, str(kfake.post_at))
            check("kernel log came from KernelFake (syslog read answered, no listener errors)",
                  kfake.counts["syslog-read"] >= (1 if "kmsg-post-unreadable" in mods else 2) and kfake.counts["errors"] == 0
                  and kfake.counts.get("syslog-clear", 0) == 0, str(kfake.counts))
        if client is not None:
            hj = json.load(open(od + "/host-xfer/xfer.json")) if os.path.exists(od + "/host-xfer/xfer.json") else {}
            want_host = {"ok": "ok", "no-connect": "connect-timeout", "bad-header": "closed-early (fixture mode bad-header)",
                         "short": "closed-early (fixture mode short)"}[cmode]
            check("host client (mode %s): result %s" % (cmode, want_host), hj.get("Result") == want_host, str(hj.get("Result")))
            res["host_xfer"] = {k2: hj.get(k2) for k2 in ("Result", "ConnectAttempts", "ConnectRefused", "ConnectedAfterMs")}
        res["kernel_fake_counts"] = dict(kfake.counts)
        res["ok"] = all(c["ok"] for c in res["checks"])
        res["t_total_s"] = round(up() - t_start, 1)
        json.dump(res, open(od + "/meta.json", "w"), indent=1, sort_keys=True, default=str)
        with open(od + "/result.txt", "w") as f:
            f.write("# %s mods=%s plan=%s client=%s; image %s\n" % (name, mods, plan, cmode, image_dir))
            f.write("# reboots: %s\n" % reboots.strip().replace("\n", " | "))
            for c in res["checks"]:
                f.write("%s  %s%s\n" % ("PASS" if c["ok"] else "FAIL", c["label"], ("  [" + c["detail"] + "]") if c["detail"] else ""))
            f.write("SCENARIO %s %s\n" % (name, "PASS" if res["ok"] else "FAIL"))
        return res["ok"]
    finally:
        stop.set()
        if client is not None and client.poll() is None:
            client.kill()
        if net:
            net.close()
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
