#!/usr/bin/env python3
"""A scripted MISBEHAVING device for the host transport fixtures (offline; stdlib; run with -I).

    python3 -I evil_device.py BASEPORT LOGDIR NONCE [ADDR]

Listens on BASEPORT + i for each mode in MODES (one thread per port). Every request line the
"device" receives is appended, as a Python repr of the raw bytes, to LOGDIR/<mode>.log, so the
host fixtures can prove which bytes the host sent (D1-class checks). Writes LOGDIR/READY when
all ports listen. Never touches a device.
"""
import hashlib, os, socket, sys, threading, time

MODES = ["silent", "partial", "nolf", "extra", "tworec", "banner", "rst", "huge", "esc",
         "inject", "inject2", "wrongnonce", "replayfsv1", "foreignack", "slowdrip", "closenoresp",
         "crlf", "errorstage", "errorstatus", "truncstages", "good"]
OLD_CHAL = "00000000000000000000000000000000"
ACKED = {}                                     # mode -> the ack token it was given ("good" mode)


def handle(mode, c, logf, nonce):
    c.settimeout(5)
    if mode == "banner":                       # bytes before any request
        c.sendall(("FSS1 nonce=%s stages=X acked=none END\n" % nonce).encode())
        time.sleep(2)
    buf = b""
    try:
        while b"\n" not in buf and len(buf) < 200:
            b = c.recv(200)
            if not b:
                break
            buf += b
    except Exception:
        pass
    with open(logf, "a") as f:
        f.write(repr(buf) + "\n")
    parts = buf.decode("latin-1").strip().split(" ")
    verb = parts[0] if parts else ""
    arg = parts[2] if len(parts) > 2 else ""

    def good():
        if verb == "fs-verify":
            r = hashlib.sha256(("%s:%s" % (nonce, arg)).encode()).hexdigest()
            return ("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=INIT_STARTED END\n" % (nonce, r)).encode()
        if verb == "fs-ack":
            ACKED.setdefault(mode, arg)
            return b"FSA1 queued END\n"
        if verb == "fs-done":
            return b"FSD1 queued END\n"
        return ("FSS1 nonce=%s stages=INIT_STARTED acked=%s END\n" % (nonce, ACKED.get(mode, "none"))).encode()

    if mode == "silent":
        time.sleep(30); return
    if mode == "partial":
        c.sendall(("FSV1 nonce=%s resp=" % nonce).encode()); return
    if mode == "nolf":
        c.sendall(good()[:-1]); return
    if mode == "extra":
        c.sendall(good() + b"garbage\n"); return
    if mode == "tworec":
        c.sendall(good() + good()); return
    if mode == "rst":
        c.sendall(good()[:10]); time.sleep(0.2)
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00"); return
    if mode == "huge":
        try:
            for _ in range(400):
                c.sendall(b"A" * 65536)
        except Exception:
            pass
        return
    if mode == "esc":
        c.sendall(("FSS1 nonce=%s stages=\x1b]52;c;ZnMtZG9uZQ==\x07\x1b[2J acked=none END\n" % nonce).encode("latin-1")); return
    if mode == "inject":                       # framing-valid record carrying command-like text
        if verb == "fs-verify":
            c.sendall(good()); return
        c.sendall(("FSS1 nonce=%s stages=fs-done_%s,fs-ack_%s acked=none END\n" % (nonce, nonce, "f" * 16)).encode()); return
    if mode == "inject2":                      # embedded newline + a full command line
        c.sendall(("FSS1 nonce=%s stages=X acked=none END\nfs-done %s\n" % (nonce, nonce)).encode()); return
    if mode == "wrongnonce":
        c.sendall(("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=X END\n" % ("f" * 16, "0" * 64)).encode()); return
    if mode == "replayfsv1":                   # an old, genuine-looking FSV1 for another challenge
        r = hashlib.sha256(("%s:%s" % (nonce, OLD_CHAL)).encode()).hexdigest()
        c.sendall(("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=INIT_STARTED END\n" % (nonce, r)).encode()); return
    if mode == "foreignack":
        if verb == "fs-status":
            c.sendall(("FSS1 nonce=%s stages=INIT_STARTED,HOST_ACK acked=%s END\n" % (nonce, "1" * 16)).encode()); return
        c.sendall(good()); return
    if mode == "slowdrip":
        for ch in good():
            c.sendall(bytes([ch])); time.sleep(0.3)
        return
    if mode == "closenoresp":
        return
    if mode == "errorstage":                   # a genuine FSV1 from a boot whose PID 1 already ran fail()
        r = hashlib.sha256(("%s:%s" % (nonce, arg)).encode()).hexdigest()
        c.sendall(("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=INIT_STARTED,ERROR_rpc END\n" % (nonce, r)).encode()); return
    if mode == "errorstatus":                  # verify fine; the later FSS1 shows PID 1 ran fail()
        if verb == "fs-status":
            c.sendall(("FSS1 nonce=%s stages=INIT_STARTED,RPC_READY,ERROR_x acked=none END\n" % nonce).encode()); return
        r = hashlib.sha256(("%s:%s" % (nonce, arg)).encode()).hexdigest()
        if verb == "fs-verify":
            c.sendall(("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=INIT_STARTED,RPC_READY END\n" % (nonce, r)).encode()); return
        c.sendall(good()); return
    if mode == "truncstages":                  # a stages field fs-rpcd had to cut (trailing '+')
        r = hashlib.sha256(("%s:%s" % (nonce, arg)).encode()).hexdigest()
        st = ("S%03d," * 60) % tuple(range(60))
        c.sendall(("FSV1 nonce=%s resp=%s kernel=k pid1=/init stages=INIT_STARTED,RPC_READY,%s+ END\n" % (nonce, r, st[:150])).encode()); return
    if mode == "crlf":
        c.sendall(good()[:-1] + b"\r\n"); return
    c.sendall(good())                          # "good"


def serve(mode, port, logdir, nonce, addr):
    fam = socket.AF_INET6 if ":" in addr else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((addr, port)); s.listen(4)
    logf = os.path.join(logdir, mode + ".log")
    open(logf, "a").close()
    while True:
        c, _ = s.accept()
        with open(os.path.join(logdir, mode + ".conn"), "a") as f:
            f.write("c\n")
        threading.Thread(target=lambda: (handle(mode, c, logf, nonce), c.close()), daemon=True).start()


def main(a):
    base, logdir, nonce = int(a[0]), a[1], a[2]
    addr = a[3] if len(a) > 3 else "127.0.0.1"
    os.makedirs(logdir, exist_ok=True)
    for i, m in enumerate(MODES):
        threading.Thread(target=serve, args=(m, base + i, logdir, nonce, addr), daemon=True).start()
    time.sleep(0.5)
    with open(os.path.join(logdir, "READY"), "w") as f:
        f.write("\n".join("%s %d" % (m, base + i) for i, m in enumerate(MODES)) + "\n")
    time.sleep(float(os.environ.get("EVIL_LIFETIME", "600")))


if __name__ == "__main__":
    main(sys.argv[1:])
