#!/usr/bin/env python3
"""FrameShift Quest 2 channel -- fs-rpcd responder fixtures (offline; stdlib only; run with -I).

    python3 -I device_cases.py --rpcd "<command prefix>" --work DIR --bb BUSYBOX --out RESULTS.txt
        [--fsb1-enc PATH --fsup PATH --fsb1-py PATH]

<command prefix> is how the responder is started, e.g. "qemu-aarch64 build/fs-rpcd" (the shipped
aarch64 binary) or "build/fs-rpcd.asan" (native sanitizer build). Every case starts a fresh
responder with a fresh RUNDIR on 127.0.0.1 / ::1 and a fresh port. Touches no device.
"""
import argparse, hashlib, os, re, shlex, signal, socket, struct, subprocess, sys, time

sys.dont_write_bytecode = True   # importing quest3/common/tools/fsb1.py must not write a __pycache__ there

NONCE = "0123456789abcdef"
OTHER = "fedcba9876543210"
LOGLINE = re.compile(r"^FSRPC (listening port=[0-9]+ fam=inet6? if=[a-z0-9-]+|seq=[0-9]+ verb=(fs-verify|fs-ack|fs-status|fs-done|fs-collect|-) result=[a-z-]+|maxconn=[0-9]+ reached; exiting|swept=[0-9]+ orphans)$")

A = None
RESULTS = []
PORT = [47400]


def hexs(n):
    return os.urandom(n // 2).hex()


class Rpcd:
    def __init__(self, name, addr="127.0.0.1", extra=(), stages="INIT_STARTED\nSHELL_READY\n", runner=None, runner_s=None,
                 hostile_signals=False, env=None, run=None):
        self.dir = os.path.join(A.work, name)
        os.makedirs(self.dir, exist_ok=True)
        self.run = run or os.path.join(self.dir, "run")
        os.makedirs(self.run, exist_ok=True)
        if stages is not None:
            with open(os.path.join(self.run, "fs.stages"), "w") as f:
                f.write(stages)
        PORT[0] += 1
        self.port = PORT[0]
        self.addr = addr
        cmd = shlex.split(A.rpcd) + ["-n", NONCE, "-a", addr, "-p", str(self.port), "-r", self.run] + list(extra)
        if runner:
            cmd += ["-c", runner, "-T", str(runner_s or 30)]
        self.err = open(os.path.join(self.dir, "stderr.txt"), "wb")
        pre = None
        if hostile_signals:          # what a careless parent could leave behind (review m3 probe)
            def pre():
                signal.signal(signal.SIGCHLD, signal.SIG_IGN)
                signal.signal(signal.SIGPIPE, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGALRM})
                os.umask(0)
        e = dict(os.environ)
        if env:
            e.update(env)
        self.p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=self.err, stderr=self.err, start_new_session=True,
                                  preexec_fn=pre, restore_signals=not hostile_signals, env=e)
        fam = socket.AF_INET6 if ":" in addr else socket.AF_INET
        self.fam = fam
        t = time.time() + 15
        while time.time() < t:
            if self.p.poll() is not None:
                raise RuntimeError("rpcd exited at start: %s" % self.p.returncode)
            if os.path.exists(os.path.join(self.run, "fs.rpc.log")):
                with open(os.path.join(self.run, "fs.rpc.log")) as f:
                    if f.read().count("listening port=%d " % self.port) >= 1:
                        return
            time.sleep(0.05)
        raise RuntimeError("rpcd did not start")

    def conn(self, timeout=10):
        s = socket.socket(self.fam, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((self.addr, self.port))
        return s

    def req(self, data, timeout=10, shut=False):
        """One connection: send data, (optionally half-close), read to EOF. Returns (bytes, seconds, end).
        Default: NO half-close, like host/fs-transport-tcp.ps1 (review m12)."""
        s = self.conn(timeout)
        t0 = time.time()
        if data:
            s.sendall(data)
        if shut:
            s.shutdown(socket.SHUT_WR)
        out, end = b"", "eof"
        try:
            while True:
                b = s.recv(65536)
                if not b:
                    break
                out += b
        except socket.timeout:
            end = "timeout"
        except ConnectionResetError:
            end = "reset"
        s.close()
        return out, time.time() - t0, end

    def log(self):
        try:
            with open(os.path.join(self.run, "fs.rpc.log")) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def files(self):
        return sorted(os.listdir(self.run))

    def stop(self):
        if self.p.poll() is None:
            os.killpg(self.p.pid, signal.SIGKILL)
            self.p.wait()
        self.err.close()
        with open(os.path.join(self.dir, "stderr.txt"), "rb") as f:
            e = f.read()
        return e


def res(name, ok, detail=""):
    RESULTS.append("%s %s %s" % (name, "PASS" if ok else "FAIL", detail))
    print(RESULTS[-1], flush=True)


def fsr(code, nonce=NONCE):
    return ("FSR1 nonce=%s error=%s END\n" % (nonce, code)).encode()


def check_log(r, name):
    bad = [l for l in r.log() if not LOGLINE.match(l)]
    return not bad, ("log ok" if not bad else "bad log lines: %r" % bad[:2])


def expect_sha(nonce, chal):
    return hashlib.sha256(("%s:%s" % (nonce, chal)).encode()).hexdigest()


def pid1_field():
    with open("/proc/1/cmdline", "rb") as f:
        b = f.read()
    s = "".join(("," if c == 0 else (chr(c) if 0x21 <= c <= 0x7e else "?")) for c in b).rstrip(",")
    return s[:200] or "-"


def kernel_field():
    return os.uname().release[:200]


# ------------------------------------------------------------------ cases
def case_valid():
    r = Rpcd("valid")
    try:
        c = hexs(32)
        out, dt, end = r.req(("fs-verify %s %s\n" % (NONCE, c)).encode())
        want = ("FSV1 nonce=%s resp=%s kernel=%s pid1=%s stages=INIT_STARTED,SHELL_READY END\n" % (NONCE, expect_sha(NONCE, c), kernel_field(), pid1_field())).encode()
        res("V1-verify", out == want and end == "eof", "%.2fs %r" % (dt, out[:90]))
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("V2-status-before-ack", out == ("FSS1 nonce=%s stages=INIT_STARTED,SHELL_READY acked=none END\n" % NONCE).encode(), repr(out))
        t = hexs(16)
        out, _, _ = r.req(("fs-ack %s %s\n" % (NONCE, t)).encode())
        ha = open(os.path.join(r.run, "host_ack")).read()
        res("V3-ack", out == b"FSA1 queued END\n" and ha == t + "\n", "host_ack=%r" % ha)
        # simulate PID 1 (pid1-hold.sh) recording the ack
        with open(os.path.join(r.run, "fs.acked"), "a") as f:
            f.write(t + "\n")
        with open(os.path.join(r.run, "fs.stages"), "a") as f:
            f.write("HOST_ACK\n")
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("V4-status-acked", out == ("FSS1 nonce=%s stages=INIT_STARTED,SHELL_READY,HOST_ACK acked=%s END\n" % (NONCE, t)).encode(), repr(out))
        out, _, _ = r.req(("fs-done %s\n" % NONCE).encode())
        res("V5-done", out == b"FSD1 queued END\n" and os.path.isfile(os.path.join(r.run, "fs.collected")), repr(out))
        out, _, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode())
        res("V6-collect-no-runner", out == fsr("no-runner"), repr(out))
        # no unsolicited bytes: connect and wait without sending
        s = r.conn(5); s.settimeout(0.8)
        try:
            b = s.recv(10); unsolicited = b
        except socket.timeout:
            unsolicited = None
        s.close()
        res("V7-no-unsolicited-bytes", unsolicited is None, repr(unsolicited))
        # FSS1 with a malformed fs.acked (PID 1 never writes that, but never trust a file)
        with open(os.path.join(r.run, "fs.acked"), "w") as f:
            f.write("zz;rm\n")
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("V8-status-acked-invalid", b"acked=invalid END\n" in out, repr(out))
        ok, d = check_log(r, "valid"); res("V9-log-table-only", ok, d)
    finally:
        e = r.stop()
        res("V-stderr-clean", e == b"", repr(e[:200]))


def case_v6():
    r = Rpcd("v6", addr="::1")
    try:
        c = hexs(32)
        out, _, _ = r.req(("fs-verify %s %s\n" % (NONCE, c)).encode())
        res("V10-verify-ipv6-loopback", out.startswith(("FSV1 nonce=%s resp=%s " % (NONCE, expect_sha(NONCE, c))).encode()), repr(out[:80]))
    finally:
        r.stop()


MALFORMED = [
    ("M01-uppercase-verb", b"FS-STATUS %N\n", "grammar"),
    ("M02-double-space", b"fs-status  %N\n", "grammar"),
    ("M03-leading-space", b" fs-status %N\n", "grammar"),
    ("M04-trailing-space", b"fs-status %N \n", "grammar"),
    ("M05-crlf", b"fs-status %N\r\n", "grammar"),
    ("M06-tab", b"fs-status\t%N\n", "grammar"),
    ("M07-nul", b"fs-status %N\x00\n", "grammar"),
    ("M08-quote", b"fs-status '%N'\n", "grammar"),
    ("M09-semicolon", b"fs-status %N;fs-done %N\n", "grammar"),
    ("M10-subst", b"fs-status $(reboot)\n", "grammar"),
    ("M11-backtick", b"fs-status `id`\n", "grammar"),
    ("M12-empty-line", b"\n", "grammar"),
    ("M13-high-bytes", b"\xff\xfe\n", "grammar"),
    ("M14-utf8", "fs-status é\n".encode(), "grammar"),
    ("M15-unknown-verb", b"fs-reboot %N\n", "verb"),
    ("M16-verb-prefix", b"fs-statusx %N\n", "verb"),
    ("M17-shell", b"sh\n", "verb"),
    ("M18-missing-nonce", b"fs-status\n", "args"),
    ("M19-verify-no-chal", b"fs-verify %N\n", "args"),
    ("M20-verify-short", b"fs-verify %N " + b"a" * 31 + b"\n", "args"),
    ("M21-verify-long", b"fs-verify %N " + b"a" * 33 + b"\n", "args"),
    ("M22-verify-upper-hex", b"fs-verify %N " + b"A" * 32 + b"\n", "grammar"),
    ("M23-ack-extra", b"fs-ack %N 0123456789abcdef extra\n", "args"),
    ("M24-status-extra", b"fs-status %N %N\n", "args"),
    ("M25-five-tokens", b"a b c d e\n", "args"),
    ("M26-nonce-short", b"fs-status 0123\n", "args"),
    ("M27-nonce-nonhex", b"fs-status 0123456789abcdeg\n", "args"),
    ("M28-done-arg", b"fs-done %N 00\n", "args"),
    ("M29-hyphens", b"-- --\n", "verb"),
    ("M30-bare-newline-cr", b"\r\n", "grammar"),
]


def case_malformed():
    r = Rpcd("malformed")
    try:
        for name, data, code in MALFORMED:
            data = data.replace(b"%N", NONCE.encode())
            out, _, end = r.req(data)
            res(name, out == fsr(code) and end == "eof", "%r -> %r" % (data[:40], out))
        files = r.files()
        res("M31-no-state-change", files == ["fs.rpc.log", "fs.stages"], repr(files))
        ok, d = check_log(r, "malformed"); res("M32-log-table-only", ok, d)
    finally:
        r.stop()


def case_oversize():
    r = Rpcd("oversize")
    try:
        out, _, _ = r.req(b"a" * 64 + b"\n")
        res("O1-64-chars-ok-grammar", out == fsr("verb"), repr(out))
        out, _, _ = r.req(b"a" * 65 + b"\n")
        res("O2-65-chars", out == fsr("too-long"), repr(out))
        out, dt, _ = r.req(b"a" * 1000)
        res("O3-1000-no-newline", out == fsr("too-long") and dt < 2, "%.2fs %r" % (dt, out))
        # 1 MiB flood: the refusal may be lost to an RST (Linux drops unread data on close); the
        # responder must survive and serve the next request.
        s = r.conn(10)
        try:
            s.sendall(b"b" * (1 << 20))
        except (BrokenPipeError, ConnectionResetError):
            pass
        try:
            s.recv(100)
        except Exception:
            pass
        s.close()
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("O4-flood-then-serves", out.startswith(b"FSS1 "), repr(out[:40]))
        out, _, _ = r.req(("fs-status %s\nfs-done %s\n" % (NONCE, NONCE)).encode())
        res("O5-pipelined-refused", out == fsr("trailing") and not os.path.exists(os.path.join(r.run, "fs.collected")), repr(out))
    finally:
        r.stop()


def case_slowloris():
    r = Rpcd("slow")
    try:
        out, dt, _ = r.req(b"", shut=False)
        res("S1-silent-client", out == fsr("timeout") and 2.8 <= dt <= 4.5, "%.2fs %r" % (dt, out))
        out, dt, _ = r.req(b"fs-sta", shut=False)
        res("S2-no-newline", out == fsr("timeout") and 2.8 <= dt <= 4.5, "%.2fs %r" % (dt, out))
        # trickle a valid request, one byte per 0.4 s: the 3 s bound is total, not per byte
        s = r.conn(10); t0 = time.time(); data = ("fs-status %s\n" % NONCE).encode(); out = b""
        try:
            for i in range(len(data)):
                s.sendall(data[i:i + 1]); time.sleep(0.4)
        except (BrokenPipeError, ConnectionResetError):
            pass
        try:
            while True:
                b = s.recv(1000)
                if not b:
                    break
                out += b
        except Exception:
            pass
        dt = time.time() - t0; s.close()
        res("S3-trickle-total-bound", out == fsr("timeout") and dt < 12, "%.2fs %r" % (dt, out))
        # a held connection delays (does not block) the next client
        hold = r.conn(10)
        time.sleep(0.2)
        out, dt, _ = r.req(("fs-status %s\n" % NONCE).encode(), timeout=10)
        hold.close()
        res("S4-held-conn-then-served", out.startswith(b"FSS1 ") and dt <= 4.5, "%.2fs" % dt)
        # half-open: request sent but never half-closed: still answered (newline ends it)
        out, dt, _ = r.req(("fs-status %s\n" % NONCE).encode(), shut=False)
        res("S5-no-half-close", out.startswith(b"FSS1 ") and dt < 1.5, "%.2fs" % dt)
    finally:
        r.stop()


def case_multi():
    r = Rpcd("multi")
    try:
        ok = all(r.req(("fs-status %s\n" % NONCE).encode())[0].startswith(b"FSS1 ") for _ in range(20))
        res("C1-20-sequential", ok)
        # five clients at once, each sending as soon as its own connect completes. Backlog 1:
        # the kernel holds two, later SYNs are retried by the client; all are served in turn.
        import threading
        outs = [None] * 5
        def one(k):
            try:
                outs[k] = r.req(("fs-status %s\n" % NONCE).encode(), timeout=30)[0]
            except Exception as e:
                outs[k] = repr(e).encode()
        th = [threading.Thread(target=one, args=(k,)) for k in range(5)]
        t0 = time.time()
        for t in th: t.start()
        for t in th: t.join()
        res("C2-5-concurrent-all-served", all(o.startswith(b"FSS1 ") for o in outs), "%.1fs %r" % (time.time() - t0, [o[:12] for o in outs]))
        # a client that connects and idles while others queue is refused at 3 s, and the
        # queued clients are then served (bounded head-of-line delay, documented)
        idle = r.conn(10)
        time.sleep(0.1)
        th = [threading.Thread(target=one, args=(k,)) for k in range(2)]
        t0 = time.time()
        for t in th: t.start()
        for t in th: t.join()
        try:
            ib = idle.recv(200)
        except Exception as e:
            ib = repr(e).encode()
        idle.close()
        res("C3-idle-head-of-line-bounded", ib == fsr("timeout") and all(o.startswith(b"FSS1 ") for o in outs[:2]) and time.time() - t0 < 6, "%.1fs" % (time.time() - t0))
    finally:
        r.stop()
    r = Rpcd("maxconn", extra=["-m", "3"])
    try:
        outs = [r.req(("fs-status %s\n" % NONCE).encode())[0] for _ in range(3)]
        time.sleep(0.5)
        try:
            r.req(("fs-status %s\n" % NONCE).encode(), timeout=3); refused = False
        except (ConnectionRefusedError, socket.timeout, ConnectionResetError):
            refused = True
        rc = r.p.wait(timeout=5)
        res("C4-maxconn-exits", all(o.startswith(b"FSS1 ") for o in outs) and refused and rc == 0, "rc=%s" % rc)
    finally:
        r.stop()


def case_reset():
    big = os.path.join(A.work, "big-runner.sh")
    with open(big, "w") as f:
        f.write("#!%s sh\n%s yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | %s head -c 4194304\n" % (A.bb, A.bb, A.bb))
    os.chmod(big, 0o755)
    r = Rpcd("reset", runner=big, runner_s=60)
    try:
        # RST mid-request
        s = r.conn(5); s.sendall(b"fs-sta")
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close()
        time.sleep(0.3)
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("R1-rst-mid-request-then-serves", out.startswith(b"FSS1 "), repr(out[:30]))
        # RST mid-record (a 4 MiB response)
        s = r.conn(60); s.sendall(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode()); s.shutdown(socket.SHUT_WR)
        got = b""
        while len(got) < 100000:
            b = s.recv(65536)
            if not b:
                break
            got += b
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close()
        time.sleep(1.0)
        out, _, _ = r.req(("fs-status %s\n" % NONCE).encode(), timeout=40)
        alive = r.p.poll() is None
        res("R2-rst-mid-record-then-serves", got.startswith(b"AAAA") and out.startswith(b"FSS1 ") and alive, "got=%d alive=%s" % (len(got), alive))
        out, _, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode())
        res("R3-collect-once", out == fsr("collect-already"), repr(out))
        lg = r.log()
        res("R4-log-records-send-failed", any("verb=fs-collect result=send-failed" in l for l in lg), repr(lg[-3:]))
    finally:
        r.stop()


def case_nonce_replay():
    r = Rpcd("nonce")
    try:
        c = hexs(32)
        out, _, _ = r.req(("fs-verify %s %s\n" % (OTHER, c)).encode())
        res("N1-wrong-nonce-verify", out == fsr("nonce"), repr(out))
        out, _, _ = r.req(("fs-ack %s %s\n" % (OTHER, hexs(16))).encode())
        res("N2-wrong-nonce-ack-no-state", out == fsr("nonce") and not os.path.exists(os.path.join(r.run, "host_ack")), repr(out))
        out, _, _ = r.req(("fs-done %s\n" % OTHER).encode())
        res("N3-wrong-nonce-done-no-state", out == fsr("nonce") and not os.path.exists(os.path.join(r.run, "fs.collected")), repr(out))
        out, _, _ = r.req(("fs-verify %s %s\n" % (NONCE, c)).encode())
        ok1 = out.startswith(b"FSV1 ")
        out, _, _ = r.req(("fs-verify %s %s\n" % (NONCE, c)).encode())
        res("P1-replayed-challenge", ok1 and out == fsr("replay"), repr(out))
        t = hexs(16)
        out1, _, _ = r.req(("fs-ack %s %s\n" % (NONCE, t)).encode())
        out2, _, _ = r.req(("fs-ack %s %s\n" % (NONCE, t)).encode())
        out3, _, _ = r.req(("fs-ack %s %s\n" % (NONCE, hexs(16))).encode())
        res("P2-second-ack-refused", out1 == b"FSA1 queued END\n" and out2 == fsr("replay") and out3 == fsr("ack-already"), repr((out2, out3)))
    finally:
        r.stop()
    # a restarted responder (fresh memory) still refuses a second ack: PID 1 consumed the first
    r = Rpcd("ack-consumed")
    try:
        with open(os.path.join(r.run, "fs.acked"), "w") as f:
            f.write("1111222233334444\n")
        out, _, _ = r.req(("fs-ack %s %s\n" % (NONCE, hexs(16))).encode())
        res("P3-ack-after-pid1-consumed", out == fsr("ack-already") and not os.path.exists(os.path.join(r.run, "host_ack")), repr(out))
    finally:
        r.stop()


def case_collect_fsb1():
    if not (A.fsb1_enc and A.fsup and A.fsb1_py):
        res("F1-collect-fsb1", False, "encoder paths not given")
        return
    runner = os.path.join(A.work, "fsb1-runner.sh")
    rec = os.path.join(A.work, "fsb1-rec")
    bbdir = os.path.join(A.work, "bbbin"); os.makedirs(bbdir, exist_ok=True)
    for ap in ("sh", "cat", "printf", "base64", "awk", "sha256sum", "cut", "wc", "sed", "grep", "tr", "mkdir", "uname"):
        lp = os.path.join(bbdir, ap)
        if not os.path.lexists(lp):
            os.symlink(A.bb, lp)
    with open(runner, "w") as f:
        f.write("""#!{bb} sh
# fixture runner: a real FSB1 record from the common encoder (read only) and fs-supervise
PATH={bbdir}
FSB1_SUP={fsup}
. {enc}
c=$1
case "$c" in *[!0-9a-f]*|'') exit 2 ;; esac
D={rec}.$c; mkdir "$D" || exit 3
fsb1_begin "$D/rec" fixture {nonce} "$c" 2 || exit 4
fsb1_run "$D/rec" 1 uname "$D" 5 -- {bb} uname -s || exit 5
fsb1_run "$D/rec" 2 echo "$D" 5 -- {bb} printf 'x\\ny\\n' || exit 6
fsb1_end "$D/rec" {nonce} "$c" || exit 7
fsb1_emit "$D/rec"
""".format(bb=A.bb, bbdir=bbdir, fsup=A.fsup, enc=A.fsb1_enc, rec=rec, nonce=NONCE))
    os.chmod(runner, 0o755)
    r = Rpcd("collect", runner=runner, runner_s=60)
    try:
        c = hexs(32)
        out, dt, end = r.req(("fs-collect %s %s\n" % (NONCE, c)).encode(), timeout=70)
        import importlib.util
        spec = importlib.util.spec_from_file_location("fsb1", A.fsb1_py)
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        try:
            m.decode(out, "fixture", NONCE, c, ["uname", "echo"]); verdict = "VALID"
        except Exception as e:
            verdict = "REJECT %s" % e
        res("F1-collect-fsb1-valid", verdict == "VALID" and end == "eof", "%.1fs %d bytes %s" % (dt, len(out), verdict))
        try:
            m.decode(out, "fixture", NONCE, hexs(32), ["uname", "echo"]); v2 = "VALID"
        except Exception as e:
            v2 = "REJECT %s" % getattr(e, "reason", e)
        res("F2-collect-other-chal-rejected", v2.startswith("REJECT") and "chal" in v2, v2)
    finally:
        r.stop()
    # runner failures -> refusal, never partial bytes
    for name, body, code in (("F3-runner-exit-1", "printf 'FSB1 BEGIN partial\\n'; exit 1", "runner-exit"),
                             ("F4-runner-binary", "printf 'a\\001b\\n'", "runner-output"),
                             ("F5-runner-no-final-lf", "printf 'abc'", "runner-output"),
                             ("F6-runner-timeout", "sleep 30", "runner-timeout")):
        rp = os.path.join(A.work, name + ".sh")
        with open(rp, "w") as f:
            f.write("#!%s sh\n%s\n" % (A.bb, body.replace("sleep", A.bb + " sleep").replace("printf", A.bb + " printf")))
        os.chmod(rp, 0o755)
        r = Rpcd(name, runner=rp, runner_s=3)
        try:
            out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=20)
            res(name, out == fsr(code), "%.1fs %r" % (dt, out))
        finally:
            r.stop()


def runner_file(name, body, interp=None):
    rp = os.path.join(A.work, name + ".sh")
    with open(rp, "w") as f:
        f.write("#!%s\n%s\n" % (interp or (A.bb + " sh"), body))
    os.chmod(rp, 0o755)
    return rp


def case_trailing_halfclose():
    r = Rpcd("trailing")
    try:
        # a second line in a LATER segment (20 ms later): refused, nothing done (review m4)
        s = r.conn(5); s.sendall(("fs-status %s\n" % NONCE).encode()); time.sleep(0.02)
        try:
            s.sendall(("fs-done %s\n" % NONCE).encode())
        except Exception:
            pass
        out = b""
        try:
            while True:
                b = s.recv(1000)
                if not b:
                    break
                out += b
        except Exception:
            pass
        s.close()
        res("T1-trailing-in-later-segment", out == fsr("trailing") and not os.path.exists(os.path.join(r.run, "fs.collected")), repr(out))
        # bytes arriving after the 75 ms window are drained, not a second request
        s = r.conn(5); s.sendall(("fs-status %s\n" % NONCE).encode()); time.sleep(0.3)
        try:
            s.sendall(("fs-done %s\n" % NONCE).encode())
        except Exception:
            pass
        out = b""
        try:
            while True:
                b = s.recv(1000)
                if not b:
                    break
                out += b
        except Exception:
            pass
        s.close()
        res("T2-late-bytes-not-a-request", out.startswith(b"FSS1 ") and not os.path.exists(os.path.join(r.run, "fs.collected")), repr(out[:30]))
        # half-close right after the line (some hosts do): EOF inside the window is fine
        out, dt, _ = r.req(("fs-status %s\n" % NONCE).encode(), shut=True)
        res("T3-half-close-accepted", out.startswith(b"FSS1 ") and dt < 1.5, "%.2fs" % dt)
        out, dt, _ = r.req(("fs-verify %s %s\n" % (NONCE, hexs(32))).encode(), shut=True)
        res("T4-half-close-verify", out.startswith(b"FSV1 "), repr(out[:20]))
        out, dt, _ = r.req(b"fs-status  x\n", shut=True)
        res("T5-half-close-malformed", out == fsr("grammar"), repr(out))
    finally:
        r.stop()


def case_collect_hardening():
    # K1: the once-per-boot marker is honoured even by a fresh responder (review m6)
    rp = runner_file("K-runner", "%s printf 'ok\\n'" % A.bb)
    r = Rpcd("K1", runner=rp, runner_s=10)
    try:
        open(os.path.join(r.run, "fs.collect-started"), "w").close()
        out, _, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=20)
        res("K1-marker-refuses-collect", out == fsr("collect-already"), repr(out))
    finally:
        r.stop()
    r = Rpcd("K2", runner=rp, runner_s=10)
    try:
        out1, _, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=20)
        mk = os.path.exists(os.path.join(r.run, "fs.collect-started"))
    finally:
        r.stop()
    r2 = Rpcd("K2b", runner=rp, runner_s=10, run=r.run, stages=None)
    try:
        out2, _, _ = r2.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=20)
        res("K2-collect-once-survives-restart", out1 == b"ok\n" and mk and out2 == fsr("collect-already"), "%r / %r" % (out1, out2))
    finally:
        r2.stop()
    # X1: more than 8 MiB -> runner-too-large; X2: exactly 8 MiB -> delivered whole
    big = runner_file("X1", "%s yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | %s head -c 9437184" % (A.bb, A.bb))
    r = Rpcd("X1", runner=big, runner_s=60)
    try:
        out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=90)
        res("X1-runner-too-large", out == fsr("runner-too-large"), "%.1fs %r" % (dt, out[:60]))
    finally:
        r.stop()
    exact = runner_file("X2", "%s yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | %s head -c 8388608" % (A.bb, A.bb))
    r = Rpcd("X2", runner=exact, runner_s=60)
    try:
        out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=90)
        res("X2-exactly-8MiB-delivered", len(out) == 8388608 and out.endswith(b"A\n") and set(out) <= {0x41, 0x0a}, "%.1fs %d bytes" % (dt, len(out)))
    finally:
        r.stop()
    # X3: the runner closes stdout and keeps running -> not reaped within 2 s -> killed -> runner-unreaped
    tag = "x3" + hexs(8)
    closer = runner_file("X3", "exec 1>&-\n%s sleep 33 # %s" % (A.bb, tag))
    r = Rpcd("X3", runner=closer, runner_s=30)
    try:
        out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
        time.sleep(0.5)
        alive = subprocess.run(["pgrep", "-f", "sleep 33"], capture_output=True).returncode == 0
        out2, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
        res("X3-stdout-closed-runner-killed", out == fsr("runner-killed") and 1.8 <= dt <= 6 and not alive and out2.startswith(b"FSS1 "),
            "%.1fs %r runner-still-alive=%s" % (dt, out, alive))
    finally:
        r.stop()
    # X4: a stray child holding stdout keeps the pipe open after the runner exits 0: runner-timeout
    # (documented), and the stray is killed with the process group
    stray = runner_file("X4", "%s sleep 37 &\n%s printf 'done\\n'\nexit 0" % (A.bb, A.bb))
    r = Rpcd("X4", runner=stray, runner_s=3)
    try:
        out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
        time.sleep(0.5)
        alive = subprocess.run(["pgrep", "-f", "sleep 37"], capture_output=True).returncode == 0
        res("X4-stray-holds-stdout-timeout-and-killed", out == fsr("runner-timeout") and 2.8 <= dt <= 8 and not alive, "%.1fs %r stray-alive=%s" % (dt, out, alive))
    finally:
        r.stop()
    # X6/X7 (rev 3): strays that LEAVE the runner's process group (setsid; setsid after a double
    # fork) are reparented to fs-rpcd (child subreaper) and SIGKILLed by the sweep; the record is
    # still delivered because they do not hold stdout
    for name, body, word in (
            ("X6-setsid-stray-swept", "%s setsid %s sleep 32 </dev/null >/dev/null 2>&1 &\n%s printf 'ok\\n'" % (A.bb, A.bb, A.bb), "sleep 32"),
            ("X7-double-fork-setsid-stray-swept", "( %s setsid %s sleep 34 </dev/null >/dev/null 2>&1 & )\n%s sleep 1\n%s printf 'ok\\n'" % (A.bb, A.bb, A.bb, A.bb), "sleep 34")):
        rp = runner_file(name, body)
        r = Rpcd(name, runner=rp, runner_s=10)
        try:
            out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
            time.sleep(0.7)
            alive = subprocess.run(["pgrep", "-f", word], capture_output=True).returncode == 0
            swept = any(l.startswith("FSRPC swept=") for l in r.log())
            res(name, out == b"ok\n" and not alive and swept, "%.1fs %r stray-alive=%s swept-logged=%s" % (dt, out, alive, swept))
        finally:
            subprocess.run(["pkill", "-9", "-f", word], capture_output=True)
            r.stop()
    # X5 (native build + LD_PRELOAD shim only): waitpid never reaps -> bounded give-up, child left unreaped
    if A.shim:
        quick = runner_file("X5", "%s printf 'x\\n'" % A.bb)
        r = Rpcd("X5", runner=quick, runner_s=10, env={"LD_PRELOAD": A.shim, "FS_SHIM_NOWAIT": "1"})
        try:
            out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
            out2, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
            res("X5-unreapable-runner-bounded", out == fsr("runner-unreaped") and 3.8 <= dt <= 6.5 and out2.startswith(b"FSS1 ") and r.p.poll() is None,
                "%.1fs %r (2 s + 2 s polls, then give up)" % (dt, out))
        finally:
            r.stop()
    # SIG1: hostile inherited state (SIGCHLD/SIGPIPE/SIGTERM ignored, signals blocked, umask 0):
    # collect still works and the runner starts with default dispositions, empty mask, umask 077
    probe = runner_file("SIG1", "grep -E '^Sig(Blk|Ign):' /proc/$$/status | tr '\\t' ' '\numask", interp="/bin/sh")
    r = Rpcd("SIG1", runner=probe, runner_s=10, hostile_signals=True)
    try:
        out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
        txt = out.decode("latin-1")
        okv = "SigBlk: 0000000000000000" in txt and "SigIgn: 0000000000000000" in txt and txt.rstrip().endswith("0077")
        res("SIG1-runner-state-reset", okv, repr(txt))
    finally:
        r.stop()
    if A.fsb1_enc and A.fsup:
        # the reviewer's probe: with SIGCHLD ignored by the parent, every collect used to fail runner-unreaped
        r = Rpcd("SIG2", runner=os.path.join(A.work, "fsb1-runner.sh"), runner_s=60, hostile_signals=True)
        try:
            out, dt, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=70)
            res("SIG2-collect-with-sigchld-ignored-by-parent", out.startswith(b"\nFSB1 BEGIN "), "%.1fs %r" % (dt, out[:40]))
        finally:
            r.stop()


def case_fields():
    """Revision 4 (final re-review R1): field sanitisation. A field longer than 200 bytes is cut to
    199 + '+'; '+' in data becomes '?'; a stages FILE longer than fs-rpcd reads is also marked."""
    def status(stages_bytes):
        r = Rpcd("fields%d" % PORT[0], stages=None)
        try:
            with open(os.path.join(r.run, "fs.stages"), "wb") as f:
                f.write(stages_bytes)
            out, _, _ = r.req(("fs-status %s\n" % NONCE).encode())
            m = re.match(rb"^FSS1 nonce=[0-9a-f]{16} stages=(\S*) acked=\S+ END\n\Z", out)
            return out, (m.group(1).decode("latin-1") if m else None)
        finally:
            r.stop()
    names = "".join("STAGE_%03d\n" % i for i in range(40))          # 400 bytes -> cut
    out, st = status(names.encode())
    res("V11-long-stages-cut-with-plus", st is not None and len(st) == 200 and st.endswith("+") and "+" not in st[:-1], "len=%s tail=%r" % (len(st) if st else None, st[-12:] if st else out))
    out, st = status(b"INIT_STARTED\nA+B\nRPC_READY\n")
    res("V12-plus-in-data-becomes-question-mark", st == "INIT_STARTED,A?B,RPC_READY", repr(st))
    out, st = status(b"INIT_STARTED\nRPC_READY\n")
    res("V13-short-stages-unmarked", st == "INIT_STARTED,RPC_READY", repr(st))
    out, st = status(b"INIT_STARTED\n" + b"\n" * 5000 + b"ERROR_x\n")   # the ERROR_ entry lies beyond what is read
    res("V14-file-beyond-read-limit-marked", st is not None and st.endswith("+") and "ERROR_x" not in st, repr(st[-20:] if st else out))
    out, st = status(("X" * 199 + "\n").encode())
    res("V15-exactly-199-unmarked", st == "X" * 199, "len=%s" % (len(st) if st else None))
    out, st = status(("X" * 200 + "\n").encode())
    res("V16-exactly-200-unmarked", st == "X" * 200, "len=%s" % (len(st) if st else None))
    out, st = status(("X" * 201 + "\n").encode())
    res("V17-201-cut", st == "X" * 199 + "+", "len=%s" % (len(st) if st else None))
    # rev 5 (N-a): 4096 LFs then ERROR_: only separators are read, the rest is cut -> "-+"
    out, st = status(b"\n" * 4096 + b"ERROR_x\n")
    res("V19-only-separators-then-cut-is-marked", st == "-+", repr(st if st else out))
    out, st = status(b"\n" * 10)
    res("V20-only-separators-uncut-is-dash", st == "-", repr(st if st else out))
    # the -T cap itself (104 s = T_max for DEADLINE 299, tools/check-timing.py) is accepted
    rp = runner_file("V18-runner", "%s printf 'ok\\n'" % A.bb)
    r = Rpcd("V18", runner=rp, runner_s=104)
    try:
        out, _, _ = r.req(("fs-collect %s %s\n" % (NONCE, hexs(32))).encode(), timeout=30)
        res("V18-T-104-accepted", out == b"ok\n", repr(out))
    finally:
        r.stop()


def case_usage():
    base = shlex.split(A.rpcd)
    run = os.path.join(A.work, "usage-run"); os.makedirs(run, exist_ok=True)
    for name, args in (("U1-linklocal-needs-if", ["-n", NONCE, "-a", "fe80::1", "-p", "47999", "-r", run]),
                       ("U2-ipv4-with-if", ["-n", NONCE, "-a", "127.0.0.1", "-i", "lo", "-p", "47999", "-r", run]),
                       ("U3-bad-nonce", ["-n", "XYZ", "-a", "127.0.0.1", "-p", "47999", "-r", run]),
                       ("U4-port-leading-zero", ["-n", NONCE, "-a", "127.0.0.1", "-p", "047999", "-r", run]),
                       ("U5-relative-rundir", ["-n", NONCE, "-a", "127.0.0.1", "-p", "47999", "-r", "run"]),
                       ("U6-runner-without-T", ["-n", NONCE, "-a", "127.0.0.1", "-p", "47999", "-r", run, "-c", "/bin/true"]),
                       ("U7-T-over-cap-104", ["-n", NONCE, "-a", "127.0.0.1", "-p", "47999", "-r", run, "-c", "/bin/true", "-T", "105"]),
                       ("U8-duplicate-option", ["-n", NONCE, "-n", NONCE, "-a", "127.0.0.1", "-p", "47999", "-r", run]),
                       ("U9-extra-arg", ["-n", NONCE, "-a", "127.0.0.1", "-p", "47999", "-r", run, "x"]),
                       ("U10-ipv6-unspecified", ["-n", NONCE, "-a", "::", "-p", "47999", "-r", run]),
                       ("U11-ipv4-any", ["-n", NONCE, "-a", "0.0.0.0", "-p", "47999", "-r", run]),
                       ("U12-ipv6-multicast", ["-n", NONCE, "-a", "ff02::1", "-p", "47999", "-r", run]),
                       ("U13-ipv4-multicast", ["-n", NONCE, "-a", "224.0.0.1", "-p", "47999", "-r", run]),
                       ("U14-ipv4-broadcast", ["-n", NONCE, "-a", "255.255.255.255", "-p", "47999", "-r", run]),
                       ("U15-v4-mapped", ["-n", NONCE, "-a", "::ffff:127.0.0.1", "-p", "47999", "-r", run])):
        p = subprocess.run(base + args, stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        res(name, p.returncode == 2, "rc=%s" % p.returncode)


def main():
    global A
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpcd", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--bb", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--fsb1-enc"); ap.add_argument("--fsup"); ap.add_argument("--fsb1-py")
    ap.add_argument("--port-base", type=int, default=47400)
    ap.add_argument("--shim", default="")          # LD_PRELOAD waitpid shim (native build only)
    ap.add_argument("--native", action="store_true")
    A = ap.parse_args()
    PORT[0] = A.port_base
    os.makedirs(A.work, exist_ok=True)
    for f in (case_valid, case_v6, case_malformed, case_oversize, case_slowloris, case_multi,
              case_reset, case_nonce_replay, case_collect_fsb1, case_trailing_halfclose, case_collect_hardening,
              case_fields, case_usage):
        try:
            f()
        except Exception as e:
            res(f.__name__, False, "harness exception %r" % e)
    npass = sum(1 for l in RESULTS if " PASS " in l + " ")
    with open(A.out, "w") as f:
        f.write("fs-rpcd device fixtures: rpcd=%s\n" % A.rpcd)
        f.write("\n".join(RESULTS) + "\n")
        f.write("TOTAL %d/%d PASS\n" % (npass, len(RESULTS)))
    print("TOTAL %d/%d PASS" % (npass, len(RESULTS)))
    return 0 if npass == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
