/*
 * fs-xfer — the N1 transfer-test responder: the ONLY listener of the N1 image.
 *
 * FrameShift Quest 3 N1 (devices/quest3/n1/README.md): an NCM USB network link next to the ACM console
 * (FS-R-013 §5, §9: ACM continuity, bounded enumeration, no unintended listener). fs-xfer is run ONCE per
 * boot, by the N1 runner (/bin/fs-n1, step 5 "xfer") under /bin/fs-supervise. It listens on exactly one
 * address (the image's IPv6 link-local fe80::<nonce> on the NCM interface, or ::1 for host fixtures), accepts
 * exactly ONE session from a link-local peer on that interface, closes the listening socket at once, moves a
 * known-size blob in each direction with SHA-256 on both sides, and exits. Everything is bounded by compiled-in
 * limits; nothing is executed, written to a file, or read from a file.
 *
 *   fs-xfer -n NONCE16 -c CHAL32 -a ADDR -i IFNAME -p PORT
 *   fs-xfer -n NONCE16 -c CHAL32 -i none            (no NCM interface: reports result=no-ncm and exits)
 *
 * Arguments (each exactly once; anything else is refused with exit 64 and one "FSX1 result=usage" line):
 *   -n  the image nonce, 16 lowercase hex;  -c  the runner challenge, 32 lowercase hex;
 *   -a  fe80::<nonce> exactly (the interface identifier IS the nonce, as the init assigns it) with -i IFNAME
 *       ([a-z0-9]{1,15}, an existing interface); ::1 with -i lo only in a build with -DFSX_FIXTURE (the native
 *       fixture twin; review m6: the image's binary has no loopback mode);
 *   -p  a decimal port 1024..65535 without a leading zero.
 *
 * Protocol (FSX1; normative; devices/quest3/n1/README.md §4):
 *   1. host -> device, within HEADER_MS of the accept, one line of exactly
 *        "FSX1 <nonce> <chal> <H2D_BYTES> <D2H_BYTES>\n"   (71 bytes; read one byte at a time, max 96)
 *      any other line, or none in time: result=bad-header / header-timeout (nothing is sent back);
 *   2. host -> device: exactly H2D_BYTES bytes (any content); the device hashes them (SHA-256);
 *   3. device -> host: exactly D2H_BYTES bytes of the deterministic stream
 *        block i = SHA-256("FSX1-D2H" || nonce || chal || uint64_be(i)),  i = 0 .. D2H_BYTES/32 - 1
 *      then one trailer line
 *        "FSX1 END <nonce> <chal> rx=<n> rx_sha256=<64 hex> tx=<n> tx_sha256=<64 hex>\n";
 *   4. the device half-closes (FIN), drains at most DRAIN_MAX bytes for at most DRAIN_MS until the host's EOF,
 *      then closes. Steps 1-3 must finish within SESSION_MS of the accept.
 *
 * Report: printable-ASCII lines on stdout (each one write(); fs-supervise captures them into the FSB1 record):
 *   FSX1 start port=P if=I ifindex=K addr=A h2d=N d2h=N limits=listen:L,session:S,header:H,drain:D,rejects:R
 *   FSX1 listen t_ms=T bind_retries=B
 *   FSX1 reject peer=A scope=K t_ms=T           (a peer that is not link-local on this interface; closed at once)
 *   FSX1 accept peer=A scope=K t_ms=T rejects=R
 *   FSX1 closed-listener t_ms=T
 *   FSX1 header bytes=N ok=0|1
 *   FSX1 rx bytes=N sha256=H|- ms=M
 *   FSX1 tx bytes=N sha256=H|- ms=M
 *   FSX1 drain bytes=N eof=0|1
 *   FSX1 result=R t_ms=T
 *   R: ok | no-ncm | no-interface | bind-timeout | bind-error | listen-error | accept-timeout | rejects |
 *      header-timeout | bad-header | rx-timeout | rx-short | rx-error | tx-timeout | tx-error | usage | internal
 * Exit status: 0 whenever a result line was printed for a session outcome (the outcome is the result field,
 * not the exit code), 64 usage, 70 internal (the SHA-256 self-test, a report write failed).
 *
 * Bounds (compiled in; tools/build-xfer.sh checks them; tools/check-bounds-n1.py uses them):
 *   LISTEN_MS (bind retries while the address is not usable yet, then the accept) + SESSION_MS + DRAIN_MS = 23 s;
 *   an alarm() backstop of BACKSTOP_S = 25 s ends the process by SIGALRM if its own loop ever hangs; the runner
 *   gives fs-supervise -t 26.
 * Every socket is non-blocking and every wait is a poll() with the remaining time of its phase.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define H2D_BYTES   8388608u            /* 8 MiB host -> device */
#define D2H_BYTES   8388608u            /* 8 MiB device -> host */
#define LISTEN_MS   10000               /* from the start: bind (retried on EADDRNOTAVAIL) and accept */
#define SESSION_MS  12000               /* from the accept: header, rx, tx and trailer */
#define HEADER_MS   2000                /* from the accept: the header line */
#define DRAIN_MS    1000                /* after the trailer: wait for the host's EOF */
#define DRAIN_MAX   65536               /* bytes drained at most */
#define MAX_REJECTS 4                   /* foreign peers closed before giving up */
#define BACKSTOP_S  25                  /* alarm(): the process ends if its own loop hangs */
#define HEADER_MAX  96
#define CHUNK       65536
#define BIND_RETRY_MS 100

/* ------------------------------------------------------------------ SHA-256 (FIPS 180-4) ----- */
typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha256_t;
static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 };
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(sha256_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h;
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
static void sha_init(sha256_t *s) {
    static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    memcpy(s->h, iv, sizeof iv); s->len = 0; s->n = 0;
}
static void sha_update(sha256_t *s, const void *data, size_t len) {
    const uint8_t *p = data;
    s->len += len;
    if (s->n) {
        while (len && s->n < 64) { s->buf[s->n++] = *p++; len--; }
        if (s->n == 64) { sha_block(s, s->buf); s->n = 0; }
    }
    while (len >= 64) { sha_block(s, p); p += 64; len -= 64; }
    while (len) { s->buf[s->n++] = *p++; len--; }
}
static void sha_final(sha256_t *s, uint8_t out[32]) {
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80, z = 0;
    sha_update(s, &pad, 1);
    while (s->n != 56) sha_update(s, &z, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha_update(s, lb, 8);
    for (int i = 0; i < 8; i++) { out[4 * i] = (uint8_t)(s->h[i] >> 24); out[4 * i + 1] = (uint8_t)(s->h[i] >> 16); out[4 * i + 2] = (uint8_t)(s->h[i] >> 8); out[4 * i + 3] = (uint8_t)s->h[i]; }
}
static void hex(const uint8_t *b, size_t n, char *out) {
    static const char d[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) { out[2 * i] = d[b[i] >> 4]; out[2 * i + 1] = d[b[i] & 15]; }
    out[2 * n] = 0;
}
static int sha_selftest(void) {   /* FIPS 180-2 B.1 and B.2 */
    uint8_t o[32]; char x[65]; sha256_t s;
    sha_init(&s); sha_update(&s, "abc", 3); sha_final(&s, o); hex(o, 32, x);
    if (strcmp(x, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) return -1;
    sha_init(&s); sha_update(&s, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56); sha_final(&s, o); hex(o, 32, x);
    if (strcmp(x, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")) return -1;
    return 0;
}

/* ------------------------------------------------------------------ report ----- */
static long long T0;
static long long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
__attribute__((format(printf, 1, 2))) static void say(const char *fmt, ...);
static void say(const char *fmt, ...) {
    char b[512];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap);
    va_end(ap);
    if (n < 0) _exit(70);
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    for (int i = 0; i < n; i++) if (b[i] < 0x20 || b[i] > 0x7e) b[i] = '?';   /* printable ASCII only */
    b[n++] = '\n';
    for (int off = 0; off < n;) {
        ssize_t w = write(1, b + off, (size_t)(n - off));
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) _exit(70);
        off += (int)w;
    }
}
static int result(const char *r) { say("FSX1 result=%s t_ms=%lld", r, now_ms() - T0); return 0; }
static int usage(const char *why) { say("FSX1 result=usage why=%s", why); return 64; }

/* ------------------------------------------------------------------ helpers ----- */
static int is_hex(const char *s, size_t n) {
    if (!s || strlen(s) != n) return 0;
    for (size_t i = 0; i < n; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}
static int is_ifname(const char *s) {
    size_t n = s ? strlen(s) : 0;
    if (n < 1 || n > 15) return 0;
    for (size_t i = 0; i < n; i++) if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9'))) return 0;
    return 1;
}
static int parse_port(const char *s) {
    if (!s || !*s || *s == '0' || strlen(s) > 5) return -1;
    long v = 0;
    for (const char *p = s; *p; p++) { if (*p < '0' || *p > '9') return -1; v = v * 10 + (*p - '0'); }
    return (v >= 1024 && v <= 65535) ? (int)v : -1;
}
/* wait for fd readiness until the absolute deadline; 1 ready, 0 timeout, -1 error/hangup without data */
static int wait_fd(int fd, short ev, long long deadline) {
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) return 0;
        struct pollfd p = { fd, ev, 0 };
        int r = poll(&p, 1, left > 1000 ? 1000 : (int)left);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) continue;
        if (p.revents & ev) return 1;
        if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    }
}
/* block i of the device -> host stream */
static void d2h_block(const char *nonce, const char *chal, uint64_t i, uint8_t out[32]) {
    uint8_t m[8 + 16 + 32 + 8];
    memcpy(m, "FSX1-D2H", 8); memcpy(m + 8, nonce, 16); memcpy(m + 24, chal, 32);
    for (int k = 0; k < 8; k++) m[56 + k] = (uint8_t)(i >> (56 - 8 * k));
    sha256_t s; sha_init(&s); sha_update(&s, m, sizeof m); sha_final(&s, out);
}
static int send_all(int fd, const uint8_t *p, size_t n, long long deadline, sha256_t *acc) {
    if (acc) sha_update(acc, p, n);
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, p + off, n - off, MSG_NOSIGNAL);
        if (w > 0) { off += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            int r = wait_fd(fd, POLLOUT, deadline);
            if (r == 0) return 1;           /* timeout */
            if (r < 0) return 2;            /* error */
            continue;
        }
        return 2;
    }
    return 0;
}

int main(int argc, char **argv) {
    T0 = now_ms();
    for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);      /* KILL/STOP/RT-internal: EINVAL, harmless */
    sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, NULL);
    signal(SIGPIPE, SIG_IGN);
    if (chdir("/") != 0) return 70;
    alarm(BACKSTOP_S);
    if (sha_selftest() != 0) { say("FSX1 result=internal why=sha256-selftest"); return 70; }

    const char *nonce = NULL, *chal = NULL, *addr = NULL, *ifn = NULL, *ports = NULL;
    for (int i = 1; i < argc; i++) {
        const char **slot = NULL;
        if (!strcmp(argv[i], "-n")) slot = &nonce; else if (!strcmp(argv[i], "-c")) slot = &chal;
        else if (!strcmp(argv[i], "-a")) slot = &addr; else if (!strcmp(argv[i], "-i")) slot = &ifn;
        else if (!strcmp(argv[i], "-p")) slot = &ports;
        else return usage("unknown-argument");
        if (*slot || i + 1 >= argc) return usage("repeated-or-missing-value");
        *slot = argv[++i];
    }
    if (!is_hex(nonce, 16)) return usage("nonce");
    if (!is_hex(chal, 32)) return usage("challenge");
    if (ifn && !strcmp(ifn, "none")) {
        if (addr || ports) return usage("none-takes-no-address");
        say("FSX1 start port=- if=none ifindex=0 addr=- h2d=%u d2h=%u", H2D_BYTES, D2H_BYTES);
        return result("no-ncm");
    }
    if (!addr || !ifn || !ports) return usage("missing-argument");
    int port = parse_port(ports);
    if (port < 0) return usage("port");
    if (!is_ifname(ifn)) return usage("ifname");
    struct in6_addr a6;
    if (inet_pton(AF_INET6, addr, &a6) != 1) return usage("address");
    int loop = IN6_IS_ADDR_LOOPBACK(&a6);
#ifndef FSX_FIXTURE
    if (loop) return usage("loopback-is-fixture-only");
#endif
    if (loop) { if (strcmp(ifn, "lo")) return usage("loopback-needs-lo"); }
    else {
        /* exactly fe80:0:0:0:<nonce>: the interface identifier IS the nonce */
        uint8_t want[16] = { 0xfe, 0x80 };
        for (int k = 0; k < 8; k++) { unsigned v; sscanf(nonce + 2 * k, "%2x", &v); want[8 + k] = (uint8_t)v; }
        if (memcmp(&a6, want, 16)) return usage("address-is-not-fe80-nonce");
    }
    unsigned ifindex = loop ? 0 : if_nametoindex(ifn);
    say("FSX1 start port=%d if=%s ifindex=%u addr=%s h2d=%u d2h=%u limits=listen:%d,session:%d,header:%d,drain:%d,rejects:%d",
        port, ifn, ifindex, addr, H2D_BYTES, D2H_BYTES, LISTEN_MS, SESSION_MS, HEADER_MS, DRAIN_MS, MAX_REJECTS);
    if (!loop && ifindex == 0) return result("no-interface");

    /* ---- listen: bind (retried on EADDRNOTAVAIL: the address not usable yet), then ONE accepted session ---- */
    long long ldl = T0 + LISTEN_MS;
    int ls = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (ls < 0) return result("listen-error");
    int one = 1;
    if (setsockopt(ls, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) != 0) { close(ls); return result("listen-error"); }
    struct sockaddr_in6 sa;
    memset(&sa, 0, sizeof sa);
    sa.sin6_family = AF_INET6; sa.sin6_port = htons((uint16_t)port); sa.sin6_addr = a6; sa.sin6_scope_id = ifindex;
    int retries = 0;
    for (;;) {
        if (bind(ls, (struct sockaddr *)&sa, sizeof sa) == 0) break;
        int e = errno;
        if (e != EADDRNOTAVAIL) { say("FSX1 bind errno=%d", e); close(ls); return result("bind-error"); }
        if (now_ms() + BIND_RETRY_MS >= ldl) { say("FSX1 bind errno=%d retries=%d", e, retries); close(ls); return result("bind-timeout"); }
        retries++;
        struct timespec ts = { 0, BIND_RETRY_MS * 1000000L };
        while (nanosleep(&ts, &ts) != 0 && errno == EINTR) { }
    }
    if (listen(ls, 1) != 0) { close(ls); return result("listen-error"); }
    say("FSX1 listen t_ms=%lld bind_retries=%d", now_ms() - T0, retries);
    int fd = -1, rejects = 0;
    struct sockaddr_in6 peer;
    char ps[INET6_ADDRSTRLEN];
    while (fd < 0) {
        int r = wait_fd(ls, POLLIN, ldl);
        if (r == 0) { close(ls); return result("accept-timeout"); }
        if (r < 0) { close(ls); return result("listen-error"); }
        socklen_t pl = sizeof peer;
        int c = accept4(ls, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (c < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED) continue; close(ls); return result("listen-error"); }
        if (!inet_ntop(AF_INET6, &peer.sin6_addr, ps, sizeof ps)) strcpy(ps, "?");
        int ok = (pl == sizeof peer && peer.sin6_family == AF_INET6) &&
                 (loop ? IN6_IS_ADDR_LOOPBACK(&peer.sin6_addr) : (IN6_IS_ADDR_LINKLOCAL(&peer.sin6_addr) && peer.sin6_scope_id == ifindex));
        if (!ok) {
            say("FSX1 reject peer=%s scope=%u t_ms=%lld", ps, (unsigned)peer.sin6_scope_id, now_ms() - T0);
            close(c);
            if (++rejects >= MAX_REJECTS) { close(ls); return result("rejects"); }
            continue;
        }
        fd = c;
    }
    say("FSX1 accept peer=%s scope=%u t_ms=%lld rejects=%d", ps, (unsigned)peer.sin6_scope_id, now_ms() - T0, rejects);
    close(ls);                                  /* the listener ends with the first good session */
    say("FSX1 closed-listener t_ms=%lld", now_ms() - T0);

    /* ---- the session ---- */
    long long ta = now_ms(), sdl = ta + SESSION_MS, hdl = ta + HEADER_MS;
    char want[HEADER_MAX], got[HEADER_MAX + 1];
    int wl = snprintf(want, sizeof want, "FSX1 %s %s %u %u\n", nonce, chal, H2D_BYTES, D2H_BYTES);
    int gl = 0, nl = 0;
    const char *hr = NULL;                      /* why the header phase ended without a line */
    while (gl < HEADER_MAX && !nl && !hr) {
        ssize_t r = recv(fd, got + gl, 1, 0);
        if (r == 1) { if (got[gl++] == '\n') nl = 1; continue; }
        if (r == 0) { hr = "bad-header"; break; }          /* EOF before the newline */
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int w = wait_fd(fd, POLLIN, hdl);
            if (w == 0) hr = "header-timeout";
            else if (w < 0) hr = "bad-header";
            continue;
        }
        hr = "bad-header";
    }
    int hok = nl && gl == wl && !memcmp(got, want, (size_t)wl);
    say("FSX1 header bytes=%d ok=%d", gl, hok);
    if (!hok) { close(fd); return result(hr ? hr : "bad-header"); }

    static uint8_t buf[CHUNK];
    sha256_t rs; sha_init(&rs);
    uint32_t rx = 0;
    const char *rxr = NULL;
    while (rx < H2D_BYTES) {
        size_t want_n = H2D_BYTES - rx < CHUNK ? H2D_BYTES - rx : CHUNK;
        ssize_t r = recv(fd, buf, want_n, 0);
        if (r > 0) { sha_update(&rs, buf, (size_t)r); rx += (uint32_t)r; continue; }
        if (r == 0) { rxr = "rx-short"; break; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int w = wait_fd(fd, POLLIN, sdl);
            if (w == 0) { rxr = "rx-timeout"; break; }
            if (w < 0) { rxr = "rx-error"; break; }
            continue;
        }
        rxr = "rx-error"; break;
    }
    uint8_t rd[32]; char rh[65];
    long long rms = now_ms() - ta;
    if (rxr) { say("FSX1 rx bytes=%u sha256=- ms=%lld", rx, rms); close(fd); return result(rxr); }
    sha_final(&rs, rd); hex(rd, 32, rh);
    say("FSX1 rx bytes=%u sha256=%s ms=%lld", rx, rh, rms);

    long long tt = now_ms();
    sha256_t ts2; sha_init(&ts2);
    uint32_t tx = 0;
    const char *txr = NULL;
    uint64_t blk = 0;
    while (tx < D2H_BYTES && !txr) {
        size_t n = 0;
        while (n < CHUNK && tx + n < D2H_BYTES) { d2h_block(nonce, chal, blk++, buf + n); n += 32; }
        int r = send_all(fd, buf, n, sdl, &ts2);
        if (r == 1) txr = "tx-timeout"; else if (r == 2) txr = "tx-error"; else tx += (uint32_t)n;
    }
    uint8_t td[32]; char th[65];
    if (txr) { say("FSX1 tx bytes=%u sha256=- ms=%lld", tx, now_ms() - tt); close(fd); return result(txr); }
    sha_final(&ts2, td); hex(td, 32, th);
    char tr[256];
    int tl = snprintf(tr, sizeof tr, "FSX1 END %s %s rx=%u rx_sha256=%s tx=%u tx_sha256=%s\n", nonce, chal, rx, rh, tx, th);
    int r = send_all(fd, (const uint8_t *)tr, (size_t)tl, sdl, NULL);
    say("FSX1 tx bytes=%u sha256=%s ms=%lld trailer=%d", tx, th, now_ms() - tt, r == 0);
    if (r) { close(fd); return result(r == 1 ? "tx-timeout" : "tx-error"); }

    /* ---- half-close, then drain until the host's EOF (bounded) ---- */
    shutdown(fd, SHUT_WR);
    long long ddl = now_ms() + DRAIN_MS;
    long drained = 0; int eof = 0;
    while (drained < DRAIN_MAX) {
        ssize_t q = recv(fd, buf, sizeof buf, 0);
        if (q > 0) { drained += q; continue; }
        if (q == 0) { eof = 1; break; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) { if (wait_fd(fd, POLLIN, ddl) != 1) break; continue; }
        break;
    }
    say("FSX1 drain bytes=%ld eof=%d", drained, eof);
    close(fd);
    return result("ok");
}
