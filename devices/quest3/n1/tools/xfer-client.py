#!/usr/bin/env python3
"""FrameShift N1 — the reference host side of the FSX1 transfer test (offline fixtures; Linux/WSL).

    xfer-client.py --addr A --scope IFNAME|0 --port P --nonce N --chal C --out DIR [--window SEC] [--mode MODE]

The PowerShell client (devices/quest3/host/fs-xfer-n1.ps1, used live on the PM's PC) and this one implement the
same protocol (fs-xfer.c header; n1/README.md §4) independently and write the same xfer.json schema
(frameshift.fs-xfer-host.v1), so the classifier (fs-classify-n1.ps1) reads either. This one runs in the QEMU
harness (image-harness-n1.py) in the "host" network namespace of the veth pair, and in the fs-xfer fixtures.

It connects (retrying refused/unreachable connects every 0.2 s until --window seconds have passed: before the
runner's xfer step nothing listens, and the kernel answers with a reset), sends the header and H2D random bytes,
reads exactly D2H bytes and the trailer line, checks everything, closes (no half-close), and writes DIR/xfer.json
(the hashes and sizes of what was sent and received; the blobs themselves are not kept).

--mode (negative fixtures): ok | bad-header (a header with another challenge) | short (half the H2D bytes, then close)
| no-connect (never connects; only records the window) | slow (stops sending after 1 MiB; the device's session
deadline ends it).
Exit 0 when xfer.json was written (the result is in it), 2 on usage.
"""
import argparse
import datetime
import hashlib
import json
import os
import socket
import struct
import sys
import time

H2D = 8388608
D2H = 8388608
SCHEMA = "frameshift.fs-xfer-host.v1"


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def d2h_expected(nonce, chal):
    h = hashlib.sha256()
    pre = b"FSX1-D2H" + nonce.encode() + chal.encode()
    for i in range(D2H // 32):
        h.update(hashlib.sha256(pre + struct.pack(">Q", i)).digest())
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", required=True)
    ap.add_argument("--scope", default="0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--chal", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--window", type=float, default=60.0)
    ap.add_argument("--mode", default="ok", choices=["ok", "bad-header", "short", "no-connect", "slow"])
    ap.add_argument("--recv-timeout", type=float, default=20.0)
    a = ap.parse_args()
    if len(a.nonce) != 16 or len(a.chal) != 32 or not all(c in "0123456789abcdef" for c in a.nonce + a.chal):
        print("usage: nonce 16 hex, challenge 32 hex")
        return 2
    os.makedirs(a.out, exist_ok=True)
    scope = socket.if_nametoindex(a.scope) if a.scope not in ("", "0") else 0
    r = {"Schema": SCHEMA, "Client": "n1/tools/xfer-client.py", "Fixture": True, "Mode": a.mode, "Nonce": a.nonce,
         "Challenge": a.chal, "Port": a.port, "Address": a.addr, "ScopeId": scope, "StartUtc": utc(), "EndUtc": None,
         "Adapter": None, "ConnectAttempts": 0, "ConnectRefused": 0, "ConnectedAfterMs": None, "Result": None,
         "H2d": {"Bytes": 0, "Sha256": None, "Ms": None},
         "D2h": {"Bytes": 0, "Sha256": None, "ExpectedSha256": d2h_expected(a.nonce, a.chal), "Ms": None},
         "Trailer": None, "TrailerFields": None, "Checks": None, "Notes": []}
    t0 = time.monotonic()
    blob = os.urandom(H2D)
    s = None
    if a.mode != "no-connect":
        while time.monotonic() - t0 < a.window:
            r["ConnectAttempts"] += 1
            c = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            c.settimeout(1.0)
            try:
                c.connect((a.addr, a.port, 0, scope))
                s = c
                break
            except (ConnectionRefusedError, socket.timeout, OSError) as e:
                if isinstance(e, ConnectionRefusedError):
                    r["ConnectRefused"] += 1
                c.close()
                time.sleep(0.2)
    else:
        time.sleep(min(a.window, 5.0))
    if s is None:
        r["Result"] = "connect-timeout"
    else:
        r["ConnectedAfterMs"] = int((time.monotonic() - t0) * 1000)
        s.settimeout(a.recv_timeout)
        chal = a.chal if a.mode != "bad-header" else ("0" * 32 if a.chal != "0" * 32 else "1" * 32)
        hdr = ("FSX1 %s %s %d %d\n" % (a.nonce, chal, H2D, D2H)).encode()
        sent = blob if a.mode == "ok" else (blob[: H2D // 2] if a.mode == "short" else (blob[: 1 << 20] if a.mode == "slow" else b""))
        ts = time.monotonic()
        try:
            s.sendall(hdr)
            s.sendall(sent)
            r["H2d"].update(Bytes=len(sent), Sha256=hashlib.sha256(sent).hexdigest(), Ms=int((time.monotonic() - ts) * 1000))
            if a.mode in ("short", "bad-header"):
                s.close()
                s = None
                r["Result"] = "closed-early (fixture mode %s)" % a.mode
        except OSError as e:
            r["Result"] = "send-error"
            r["Notes"].append("send: %s (possibly partially sent)" % e)
        if s is not None and r["Result"] is None:
            got = bytearray()
            tr = time.monotonic()
            try:
                while True:
                    d = s.recv(65536)
                    if not d:
                        break
                    got += d
                    if len(got) > D2H and b"\n" in got[D2H:]:
                        break
                    if len(got) > D2H + 512:
                        break
            except socket.timeout:
                r["Notes"].append("receive timeout after %d bytes" % len(got))
            except OSError as e:
                r["Notes"].append("receive: %s after %d bytes" % (e, len(got)))
            data = bytes(got[:D2H])
            r["D2h"].update(Bytes=len(data), Sha256=hashlib.sha256(data).hexdigest(), Ms=int((time.monotonic() - tr) * 1000))
            rest = bytes(got[D2H:])
            line = rest.split(b"\n", 1)[0] if b"\n" in rest else None
            if line is not None:
                r["Trailer"] = "".join(chr(b) if 0x20 <= b <= 0x7e else "\\x%02x" % b for b in line)
                f = line.decode("latin-1").split(" ")
                kv = dict(x.split("=", 1) for x in f[4:] if "=" in x)
                if f[:2] == ["FSX1", "END"] and len(f) == 8 and set(kv) == {"rx", "rx_sha256", "tx", "tx_sha256"}:
                    r["TrailerFields"] = kv
                    r["Checks"] = {"TrailerNonceChal": f[2] == a.nonce and f[3] == a.chal,
                                   "DeviceRxMatchesSent": kv["rx"] == str(H2D) and kv["rx_sha256"] == r["H2d"]["Sha256"] and r["H2d"]["Bytes"] == H2D,
                                   "DeviceTxMatchesReceived": kv["tx"] == str(D2H) and kv["tx_sha256"] == r["D2h"]["Sha256"] and len(data) == D2H,
                                   "ReceivedIsExpected": r["D2h"]["Sha256"] == r["D2h"]["ExpectedSha256"],
                                   "NothingAfterTrailer": len(rest) == len(line) + 1}
            if len(data) < D2H:
                r["Result"] = "recv-short"
            elif r["TrailerFields"] is None:
                r["Result"] = "bad-trailer"
            elif all(r["Checks"].values()):
                r["Result"] = "ok"
            else:
                r["Result"] = "mismatch"
            s.close()
    r["EndUtc"] = utc()
    json.dump(r, open(os.path.join(a.out, "xfer.json"), "w"), indent=1, sort_keys=True)
    print("XFER %s connects=%d refused=%d h2d=%s d2h=%s" % (r["Result"], r["ConnectAttempts"], r["ConnectRefused"], r["H2d"]["Sha256"], r["D2h"]["Sha256"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
