#!/usr/bin/env python3
"""One request, one connection (fixtures only; stdlib; run with -I).

    python3 -I rpc.py ADDR PORT LINE [TIMEOUT]   ->  prints the response bytes (repr) on one line
    python3 -I rpc.py ADDR PORT --hold SECONDS   ->  connects, sends nothing, holds (slow-loris)
    python3 -I rpc.py ADDR PORT --verify NONCE   ->  fresh challenge; prints OK/BAD and the record

ADDR may carry a %scope (fe80::1%veth1). LINE gets a trailing LF. Exit 0 if a response arrived.
"""
import hashlib, os, socket, sys, time


def conn(addr, port, timeout):
    info = socket.getaddrinfo(addr, port, 0, socket.SOCK_STREAM)[0]
    s = socket.socket(info[0], socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(info[4])
    return s


def req(addr, port, line, timeout=10.0):
    s = conn(addr, port, timeout)
    s.sendall(line.encode("ascii") + b"\n")
    s.shutdown(socket.SHUT_WR)
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except (socket.timeout, ConnectionResetError):
        pass
    s.close()
    return out


def main(a):
    addr, port = a[0], int(a[1])
    if a[2] == "--hold":
        s = conn(addr, port, 30)
        time.sleep(float(a[3]))
        s.close()
        return 0
    if a[2] == "--verify":
        n = a[3]
        c = os.urandom(16).hex()
        out = req(addr, port, "fs-verify %s %s" % (n, c))
        want = hashlib.sha256(("%s:%s" % (n, c)).encode()).hexdigest()
        ok = out.startswith(("FSV1 nonce=%s resp=%s " % (n, want)).encode()) and out.endswith(b" END\n")
        print("OK" if ok else "BAD", repr(out))
        return 0 if ok else 1
    out = req(addr, port, a[2], float(a[3]) if len(a) > 3 else 10.0)
    print(repr(out))
    return 0 if out else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
