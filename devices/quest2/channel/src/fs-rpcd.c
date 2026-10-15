/*
 * fs-rpcd — FrameShift Quest 2 fixed-verb TCP responder (stage-1 channel over USB NCM).
 * Design: devices/quest2/channel/README.md. Offline draft; never run on a device.
 *
 *   fs-rpcd -n NONCE16 -a ADDR -p PORT [-i IFNAME] -r RUNDIR [-c RUNNER -T SECONDS] [-m MAXCONN]
 *
 * One TCP connection = one request line = one record, then close. No shell, no
 * eval, no exec of anything except the optional fixed RUNNER (argv only, for
 * fs-collect). Host bytes are never copied into a record, a file or a log: the
 * request is matched against a fixed grammar and only table strings, the nonce
 * baked into argv, and host tokens that passed the hex check are used.
 *
 * Request grammar (exactly one line, LF-terminated, then nothing):
 *   ^[a-z0-9 -]{1,64}\n
 *   fs-verify  <nonce16> <chal32>   -> FSV1 nonce=.. resp=sha256("<nonce>:<chal>") kernel=.. pid1=.. stages=.. END
 *   fs-ack     <nonce16> <tok16>    -> FSA1 queued END             (first ack only; writes RUNDIR/host_ack)
 *   fs-status  <nonce16>            -> FSS1 nonce=.. stages=.. acked=.. END
 *   fs-done    <nonce16>            -> FSD1 queued END             (writes RUNDIR/fs.collected)
 *   fs-collect <nonce16> <chal32>   -> the RUNNER's stdout (an FSB1 record), once per boot
 *   anything else                   -> FSR1 nonce=.. error=<code> END
 *
 * Bounds (compile time): request line 64 chars, 3 s from accept to the newline
 * (total, not per byte), then 75 ms in which any further byte is refused as
 * "trailing", 30 s to write a response, 300 ms post-close drain, one
 * connection at a time (listen backlog 1), MAXCONN connections per process
 * (default 64; then it exits), collect output <= 8 MiB and <= SECONDS (<= COLLECT_S_MAX = 104,
 * the largest -T a DEADLINE <= 299 can serve: tools/check-timing.py),
 * runner reap <= 2 s after its stdout closes plus <= 2 s after SIGKILL (reaped in that
 * second phase: runner-killed; still not reaped: the child is left unreaped and the
 * refusal is runner-unreaped; fs-rpcd never blocks in waitpid), orphan sweep <= 2 s.
 *
 * Revision 2 (adversarial review of e0d364f): bounded reap (M2); signal state,
 * mask, cwd and the runner's umask reset (m3); later-segment trailing bytes
 * refused (m4); unspecified/multicast bind addresses refused (m5); collect-once
 * marker RUNDIR/fs.collect-started, O_EXCL (m6); exactly-8-MiB output accepted.
 * Revision 3 (re-review of a0ab780): runner-killed distinct from runner-unreaped;
 * fs-rpcd is a child subreaper and SIGKILLs every process reparented to it after the
 * runner ends (setsid/double-fork strays included), bounded, non-blocking.
 * Revision 4 (final re-review of 58817ec): truncated fields end in '+' ('+' in data becomes
 * '?'); -T capped at 104 s (R3). Revision 5: a cut field that is empty after stripping is "-+".
 *
 * Exit: 0 MAXCONN reached; 2 usage; 3 bind; 4 listen/socket.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#define REQ_MAX        64                  /* request characters, LF excluded */
#define REQ_MS         3000                /* accept -> newline, total */
#define WRITE_MS       30000               /* whole response */
#define DRAIN_MS       300                 /* after shutdown(SHUT_WR) */
#define DRAIN_MAX      65536
#define BIND_WAIT_MS   10000
#define FIELD_MAX      200                 /* kernel / pid1 / stages field */
#define COLLECT_MAX    (8 * 1024 * 1024)   /* FSB1 decoder limit */
#define COLLECT_S_MAX  104                 /* = T_max(DEADLINE 299), tools/check-timing.py R3 (rev 4) */
#define REAP_MS        2000                /* runner exit after its stdout closed */
#define REAP_KILL_MS   2000                /* after SIGKILL; then give up (child left unreaped) */
#define SWEEP_MS       2000                /* orphan sweep after the runner (subreaper) */
#define TRAIL_MS       75                  /* after the newline: any further byte = "trailing" */
#define MAXCONN_MAX    1000
#define SEEN_MAX       64                  /* challenges / tokens remembered for replay refusal */

/* ------------------------------------------------------------------ SHA-256 */
typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha256_ctx;
static const uint32_t K256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha256_block(sha256_ctx *c, const uint8_t *p) {
    uint32_t w[64], a, b, d, e, f, g, h, cc, t1, t2;
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4*i] << 24 | (uint32_t)p[4*i+1] << 16 | (uint32_t)p[4*i+2] << 8 | p[4*i+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3);
        uint32_t s1 = ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a = c->h[0]; b = c->h[1]; cc = c->h[2]; d = c->h[3]; e = c->h[4]; f = c->h[5]; g = c->h[6]; h = c->h[7];
    for (int i = 0; i < 64; i++) {
        t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}
static void sha256_init(sha256_ctx *c) {
    static const uint32_t iv[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
    memcpy(c->h, iv, sizeof iv); c->len = 0; c->n = 0;
}
static void sha256_update(sha256_ctx *c, const void *data, size_t len) {
    const uint8_t *p = data;
    c->len += len;
    while (len) {
        size_t k = 64 - c->n; if (k > len) k = len;
        memcpy(c->buf + c->n, p, k); c->n += k; p += k; len -= k;
        if (c->n == 64) { sha256_block(c, c->buf); c->n = 0; }
    }
}
static void sha256_hex(sha256_ctx *c, char out[65]) {
    uint64_t bits = c->len * 8; uint8_t pad = 0x80, z = 0, lb[8];
    sha256_update(c, &pad, 1);
    while (c->n != 56) sha256_update(c, &z, 1);
    for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, lb, 8);
    for (int i = 0; i < 8; i++) snprintf(out + 8 * i, 9, "%08x", c->h[i]);
}

/* ------------------------------------------------------------------ state */
static char g_nonce[17];
static char g_rundir[256];
static char g_runner[256];
static int  g_collect_s;
static int  g_ack_sent, g_collect_done;
static unsigned g_swept;
static char g_seen[SEEN_MAX][33];
static int  g_nseen;

static long long now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void sleep_ms(int ms) { struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }

static int is_hex(const char *s, size_t n) {
    if (strlen(s) != n) return 0;
    for (size_t i = 0; i < n; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}
static int path_ok(const char *p) {   /* absolute, short, no "..", printable, no spaces */
    size_t n = strlen(p);
    if (n < 2 || n > 200 || p[0] != '/' || strstr(p, "..")) return 0;
    for (size_t i = 0; i < n; i++) if (p[i] <= ' ' || p[i] > '~') return 0;
    return 1;
}

/* Append one line to RUNDIR/fs.rpc.log: only a regular or new file, never a FIFO/device/symlink.
 * Only table strings and numbers are logged, never host bytes. */
static void rlog(const char *fmt, unsigned a, const char *b, const char *c) {
    char path[300], line[160];
    snprintf(path, sizeof path, "%s/fs.rpc.log", g_rundir);
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
        int n = snprintf(line, sizeof line, fmt, a, b, c);
        if (n > 0) { ssize_t w = write(fd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1)); (void)w; }
    }
    close(fd);
}

/* Read a small device-local file: regular files only, never blocks on a FIFO. */
static int read_small(const char *path, char *buf, size_t cap) {
    buf[0] = 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); return -1; }
    size_t len = 0;
    while (len + 1 < cap) {
        ssize_t r = read(fd, buf + len, cap - 1 - len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        len += (size_t)r;
    }
    close(fd);
    buf[len] = 0;
    return (int)len;
}
/* Join lines (sep '\n') or NUL-separated strings (sep 0) with ',' and drop the trailing separator(s).
 * Every byte outside 0x21..0x7e becomes '?', and so does '+' (revision 4): '+' is reserved as the
 * TRUNCATION MARKER. A field longer than FIELD_MAX is cut to FIELD_MAX - 1 bytes plus '+', so a
 * reader can tell "cut" from "complete" (the host refuses a truncated stages field: an ERROR_
 * marker could have been cut off). Empty -> "-". Final re-review R1. */
static void join_field(const char *in, int len, char sep, char out[FIELD_MAX + 1], int cut) {
    char tmp[4096 + 1];
    int o = 0;
    for (int i = 0; i < len && o < (int)sizeof tmp - 1; i++) {
        unsigned char ch = (unsigned char)in[i];
        if (ch == (unsigned char)sep) tmp[o++] = ',';
        else tmp[o++] = (ch >= 0x21 && ch <= 0x7e && ch != '+') ? (char)ch : '?';
    }
    int more = cut || len > o;                /* input cut before us, or beyond the scratch buffer */
    while (o > 0 && tmp[o - 1] == ',') o--;
    /* nothing left after stripping: "-", or "-+" if the input was cut (rev 5, N-a: a cut field
     * must stay marked even when only separators were read, so the host refuses it) */
    if (o == 0) { out[0] = '-'; out[1] = more ? '+' : 0; out[2] = 0; return; }
    if (o > FIELD_MAX || more) {
        int k = o > FIELD_MAX - 1 ? FIELD_MAX - 1 : o;
        memcpy(out, tmp, (size_t)k); out[k] = '+'; out[k + 1] = 0;
        return;
    }
    memcpy(out, tmp, (size_t)o); out[o] = 0;
}
static void field_file(const char *path, char sep, char out[FIELD_MAX + 1]) {
    char buf[4096 + 2]; int n = read_small(path, buf, sizeof buf);   /* reads <= 4097 bytes */
    int cut = n > 4096;                                              /* the file is longer: a cut */
    join_field(buf, n < 0 ? 0 : (cut ? 4096 : n), sep, out, cut);
}

/* Atomic write of RUNDIR/NAME: O_EXCL temp file, then rename. 0 = written. */
static int put_file(const char *name, const char *text) {
    char tmp[300], fin[300];
    snprintf(tmp, sizeof tmp, "%s/%s.rpc-tmp", g_rundir, name);
    snprintf(fin, sizeof fin, "%s/%s", g_rundir, name);
    unlink(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t n = strlen(text), off = 0;
    while (off < n) {
        ssize_t w = write(fd, text + off, n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { close(fd); unlink(tmp); return -1; }
        off += (size_t)w;
    }
    if (close(fd) != 0) { unlink(tmp); return -1; }
    if (rename(tmp, fin) != 0) { unlink(tmp); return -1; }
    return 0;
}
static int exists(const char *name) {
    char p[300]; struct stat st;
    snprintf(p, sizeof p, "%s/%s", g_rundir, name);
    return lstat(p, &st) == 0;
}
static int seen(const char *tok) {
    for (int i = 0; i < g_nseen; i++) if (strcmp(g_seen[i], tok) == 0) return 1;
    return 0;
}
static int remember(const char *tok) {      /* -1: table full (refuse rather than forget) */
    if (g_nseen >= SEEN_MAX) return -1;
    snprintf(g_seen[g_nseen++], 33, "%s", tok);
    return 0;
}

/* ------------------------------------------------------------------ I/O */
/* Write all of buf before deadline. 0 = done, -1 = timeout/reset (connection abandoned). */
static int send_all(int fd, const char *buf, size_t len, long long deadline) {
    size_t off = 0;
    while (off < len) {
        long long left = deadline - now_ms();
        if (left <= 0) return -1;
        struct pollfd p = { fd, POLLOUT, 0 };
        int r = poll(&p, 1, (int)(left > 1000 ? 1000 : left));
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) return -1;
        if (r == 0) continue;
        if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
        ssize_t w = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (w < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}
/* Graceful end: FIN, then discard whatever the peer still sends (bounded) so the
 * close does not turn into an RST that could destroy the record on the host. */
static void finish(int fd) {
    shutdown(fd, SHUT_WR);
    long long end = now_ms() + DRAIN_MS; size_t got = 0; char junk[4096];
    while (got < DRAIN_MAX) {
        long long left = end - now_ms();
        if (left <= 0) break;
        struct pollfd p = { fd, POLLIN, 0 };
        int r = poll(&p, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        ssize_t n = recv(fd, junk, sizeof junk, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
}

/* Read exactly one request line. Returns 0 with line filled, or a refusal code (static string),
 * or NULL-equivalent "" for a reset (no response possible). */
static const char *read_request(int fd, char line[REQ_MAX + 1], int *reset) {
    char buf[REQ_MAX + 2]; size_t len = 0;
    long long deadline = now_ms() + REQ_MS;
    *reset = 0;
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) return "timeout";
        struct pollfd p = { fd, POLLIN, 0 };
        int r = poll(&p, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { *reset = 1; return "reset"; }
        if (r == 0) return "timeout";
        ssize_t n = recv(fd, buf + len, sizeof buf - len, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n < 0) { *reset = 1; return "reset"; }
        if (n == 0) return len ? "no-newline" : "empty";
        size_t start = len; len += (size_t)n;
        for (size_t i = start; i < len; i++) {
            if (buf[i] == '\n') {
                if (i + 1 != len) return "trailing";
                if (i > REQ_MAX) return "too-long";
                if (i == 0) return "grammar";
                /* the charset check runs over the RAW bytes, before any C-string use:
                 * a NUL must not truncate the line into something valid (fixture M07) */
                for (size_t k = 0; k < i; k++) {
                    char ch = buf[k];
                    if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == ' ' || ch == '-')) return "grammar";
                }
                memcpy(line, buf, i); line[i] = 0;
                /* a second line in a LATER segment is refused too: wait TRAIL_MS for any
                 * further byte (EOF, i.e. a half-close, is fine). Review m4. */
                long long tdl = now_ms() + TRAIL_MS;
                for (;;) {
                    long long tl = tdl - now_ms();
                    if (tl <= 0) return NULL;
                    struct pollfd tp = { fd, POLLIN, 0 };
                    int tr = poll(&tp, 1, (int)tl);
                    if (tr < 0 && errno == EINTR) continue;
                    if (tr <= 0) return NULL;
                    char x;
                    ssize_t tn = recv(fd, &x, 1, MSG_PEEK);
                    if (tn < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
                    if (tn < 0) { *reset = 1; return "reset"; }
                    if (tn == 0) return NULL;
                    return "trailing";
                }
            }
        }
        if (len >= REQ_MAX + 1) return "too-long";
    }
}

/* ------------------------------------------------------------------ verbs */
static int refuse(int fd, long long dl, const char *code) {
    char out[96];
    snprintf(out, sizeof out, "FSR1 nonce=%s error=%s END\n", g_nonce, code);
    return send_all(fd, out, strlen(out), dl);
}

static int do_verify(int fd, long long dl, const char *chal) {
    char in[64], resp[65], kern[FIELD_MAX + 1], pid1[FIELD_MAX + 1], stages[FIELD_MAX + 1], path[300], out[1024];
    sha256_ctx c; struct utsname u;
    snprintf(in, sizeof in, "%s:%s", g_nonce, chal);
    sha256_init(&c); sha256_update(&c, in, strlen(in)); sha256_hex(&c, resp);
    if (uname(&u) == 0) join_field(u.release, (int)strnlen(u.release, sizeof u.release), 0, kern, 0); else snprintf(kern, sizeof kern, "-");
    field_file("/proc/1/cmdline", 0, pid1);
    snprintf(path, sizeof path, "%s/fs.stages", g_rundir);
    field_file(path, '\n', stages);
    snprintf(out, sizeof out, "FSV1 nonce=%s resp=%s kernel=%s pid1=%s stages=%s END\n", g_nonce, resp, kern, pid1, stages);
    return send_all(fd, out, strlen(out), dl);
}

static int do_status(int fd, long long dl) {
    char path[300], stages[FIELD_MAX + 1], ab[128], acked[sizeof ab], out[600];
    snprintf(path, sizeof path, "%s/fs.stages", g_rundir);
    field_file(path, '\n', stages);
    snprintf(path, sizeof path, "%s/fs.acked", g_rundir);
    int n = read_small(path, ab, sizeof ab);
    if (n < 0) snprintf(acked, sizeof acked, "none");
    else {
        int k = 0; while (k < n && ab[k] != '\n') k++;
        ab[k] = 0;
        if (k >= 1 && k <= 64 && strspn(ab, "0123456789abcdef") == (size_t)k && (k == n || k == n - 1)) snprintf(acked, sizeof acked, "%s", ab);
        else snprintf(acked, sizeof acked, "invalid");
    }
    snprintf(out, sizeof out, "FSS1 nonce=%s stages=%s acked=%s END\n", g_nonce, stages, acked);
    return send_all(fd, out, strlen(out), dl);
}

/* fs-rpcd is a child subreaper (PR_SET_CHILD_SUBREAPER): descendants of the runner whose
 * parent dies, including ones that called setsid() or double-forked, are reparented to it.
 * After the runner ends, SIGKILL every live process whose parent is fs-rpcd, reap what has
 * died (WNOHANG only), and repeat while new orphans appear, for at most SWEEP_MS. A process
 * the kernel never lets die (D state) is left; nothing here blocks. Re-review m11. */
static unsigned sweep_orphans(void) {
    long long dl = now_ms() + SWEEP_MS; unsigned killed = 0; long self = (long)getpid();
    for (;;) {
        int found = 0;
        DIR *d = opendir("/proc");
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                size_t nl = strlen(e->d_name);
                if (nl == 0 || nl > 9 || e->d_name[0] == '0' || strspn(e->d_name, "0123456789") != nl) continue;
                char path[64], sb[512], stc = 0; long ppid = 0;
                snprintf(path, sizeof path, "/proc/%.9s/stat", e->d_name);   /* nl <= 9 checked above */
                if (read_small(path, sb, sizeof sb) <= 0) continue;
                char *rp = strrchr(sb, ')');                   /* comm may hold spaces or ')' */
                if (!rp || rp[1] != ' ' || !rp[2] || rp[3] != ' ') continue;
                stc = rp[2];
                ppid = strtol(rp + 4, NULL, 10);
                if (ppid != self || stc == 'Z') continue;
                kill((pid_t)strtol(e->d_name, NULL, 10), SIGKILL);
                killed++; found = 1;
            }
            closedir(d);
        }
        while (waitpid(-1, NULL, WNOHANG) > 0) { }
        if (!found || now_ms() >= dl) break;
        sleep_ms(20);
    }
    return killed;
}

/* Runs RUNNER CHAL (argv only), stdout captured in memory. Returns malloc'd bytes or NULL. */
static char *run_collect(const char *chal, size_t *outlen, const char **why) {
    int p[2];
    *why = "runner";
    if (pipe2(p, O_CLOEXEC) != 0) return NULL;
    pid_t pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return NULL; }
    if (pid == 0) {
        /* the runner starts from a defined state: default dispositions (fs-rpcd ignores
         * SIGPIPE), an empty mask, umask 077 (review m3) */
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);   /* KILL/STOP/RT-internal: EINVAL, harmless */
        sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, NULL);
        umask(077);
        setpgid(0, 0);
        int dn = open("/dev/null", O_RDWR);
        if (dn < 0 || dup2(dn, 0) < 0 || dup2(p[1], 1) < 0 || dup2(dn, 2) < 0) _exit(126);
        for (int f = 3; f < 1024; f++) close(f);
        char *const av[] = { g_runner, (char *)chal, NULL };
        char *const ev[] = { "PATH=/bin:/sbin", NULL };
        execve(g_runner, av, ev);
        _exit(127);
    }
    setpgid(pid, pid);
    close(p[1]);
    size_t cap = 65536, len = 0; char *buf = malloc(cap);
    long long deadline = now_ms() + (long long)g_collect_s * 1000;
    int bad = buf == NULL;
    while (!bad) {
        long long left = deadline - now_ms();
        if (left <= 0) { *why = "runner-timeout"; bad = 1; break; }
        struct pollfd q = { p[0], POLLIN, 0 };
        int r = poll(&q, 1, (int)(left > 1000 ? 1000 : left));
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { bad = 1; break; }
        if (r == 0) continue;
        if (len == cap && cap >= COLLECT_MAX) {
            /* full at exactly COLLECT_MAX: EOF here is fine, one more byte is too large */
            char x; ssize_t m = read(p[0], &x, 1);
            if (m < 0 && errno == EINTR) continue;
            if (m == 0) break;
            *why = "runner-too-large"; bad = 1; break;
        }
        if (len == cap) {
            size_t nc = cap * 2 > COLLECT_MAX ? COLLECT_MAX : cap * 2;
            char *nb = realloc(buf, nc); if (!nb) { bad = 1; break; }
            buf = nb; cap = nc;
        }
        ssize_t n = read(p[0], buf + len, cap - len);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { bad = 1; break; }
        if (n == 0) break;
        len += (size_t)n;
    }
    close(p[0]);
    /* Reap, never blocking (review M2): poll WNOHANG for REAP_MS; if the runner has not
     * exited, SIGKILL its group and itself and poll REAP_KILL_MS more. Reaped then:
     * runner-killed. Still not reaped (a child in uninterruptible sleep; it stays an
     * unreaped child, not even a zombie yet): give up, runner-unreaped. A stray holding
     * stdout open after the runner exits keeps the pipe open, so that case ends earlier as
     * runner-timeout. Then the group is SIGKILLed and reparented orphans are swept. */
    int st = 0, reaped = 0, nochild = 0, reaped_phase = -1;
    if (bad) kill(-pid, SIGKILL);
    for (int phase = 0; phase < 2 && !reaped && !nochild; phase++) {
        long long rdl = now_ms() + (phase == 0 ? REAP_MS : REAP_KILL_MS);
        if (phase == 1) { kill(-pid, SIGKILL); kill(pid, SIGKILL); }
        while (now_ms() < rdl) {
            pid_t w = waitpid(pid, &st, WNOHANG);
            if (w == pid) { reaped = 1; reaped_phase = phase; break; }
            if (w < 0 && errno != EINTR) { nochild = 1; break; }   /* ECHILD: cannot reap; give up */
            sleep_ms(20);
        }
    }
    if (!reaped) { bad = 1; if (!strcmp(*why, "runner")) *why = "runner-unreaped"; }
    else if (reaped_phase == 1) { bad = 1; if (!strcmp(*why, "runner")) *why = "runner-killed"; }
    kill(-pid, SIGKILL);                             /* strays still in the runner's group */
    g_swept = sweep_orphans();                       /* strays that left the group (setsid) */
    if (!bad && !(WIFEXITED(st) && WEXITSTATUS(st) == 0)) { *why = "runner-exit"; bad = 1; }
    if (!bad && (len == 0 || buf[len - 1] != '\n')) { *why = "runner-output"; bad = 1; }
    for (size_t i = 0; !bad && i < len; i++) {
        unsigned char ch = (unsigned char)buf[i];
        if (!(ch == '\n' || (ch >= 0x20 && ch <= 0x7e))) { *why = "runner-output"; bad = 1; }
    }
    if (bad) { free(buf); return NULL; }
    *outlen = len;
    return buf;
}

/* Parses and dispatches one validated line. Returns the result code for the log. */
static const char *dispatch(int fd, long long dl, char *line, const char **verb_out) {
    char *tok[4]; int nt = 0;
    *verb_out = "-";
    for (size_t i = 0; line[i]; i++) {
        char ch = line[i];
        if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == ' ' || ch == '-')) { refuse(fd, dl, "grammar"); return "grammar"; }
    }
    /* single spaces only: no leading, trailing or double space */
    if (line[0] == ' ' || line[strlen(line) - 1] == ' ' || strstr(line, "  ")) { refuse(fd, dl, "grammar"); return "grammar"; }
    for (char *s = strtok(line, " "); s; s = strtok(NULL, " ")) {
        if (nt == 4) { refuse(fd, dl, "args"); return "args"; }
        tok[nt++] = s;
    }
    static const struct { const char *verb; int ntok; size_t arglen; } T[] = {
        { "fs-verify", 3, 32 }, { "fs-ack", 3, 16 }, { "fs-status", 2, 0 }, { "fs-done", 2, 0 }, { "fs-collect", 3, 32 } };
    int v = -1;
    for (int i = 0; i < 5; i++) if (strcmp(tok[0], T[i].verb) == 0) v = i;
    if (v < 0) { refuse(fd, dl, "verb"); return "verb"; }
    *verb_out = T[v].verb;
    if (nt != T[v].ntok || !is_hex(tok[1], 16) || (T[v].arglen && !is_hex(tok[2], T[v].arglen))) { refuse(fd, dl, "args"); return "args"; }
    if (strcmp(tok[1], g_nonce) != 0) { refuse(fd, dl, "nonce"); return "nonce"; }
    const char *arg = nt == 3 ? tok[2] : NULL;
    if (arg && seen(arg)) { refuse(fd, dl, "replay"); return "replay"; }
    switch (v) {
    case 0:
        if (remember(arg)) { refuse(fd, dl, "seen-full"); return "seen-full"; }
        return do_verify(fd, dl, arg) ? "send-failed" : "ok";
    case 1: {
        if (g_ack_sent || exists("host_ack") || exists("fs.acked")) { refuse(fd, dl, "ack-already"); return "ack-already"; }
        if (remember(arg)) { refuse(fd, dl, "seen-full"); return "seen-full"; }
        char text[24]; snprintf(text, sizeof text, "%s\n", arg);
        if (put_file("host_ack", text) != 0) { refuse(fd, dl, "write"); return "write"; }
        g_ack_sent = 1;
        const char *m = "FSA1 queued END\n";
        return send_all(fd, m, strlen(m), dl) ? "send-failed" : "ok";
    }
    case 2:
        return do_status(fd, dl) ? "send-failed" : "ok";
    case 3: {
        const char *m = put_file("fs.collected", "done\n") == 0 ? "FSD1 queued END\n" : "FSD1 error=write END\n";
        return send_all(fd, m, strlen(m), dl) ? "send-failed" : (m[5] == 'q' ? "ok" : "write");
    }
    default: {
        if (!g_runner[0]) { refuse(fd, dl, "no-runner"); return "no-runner"; }
        if (g_collect_done || exists("fs.collect-started")) { refuse(fd, dl, "collect-already"); return "collect-already"; }
        if (remember(arg)) { refuse(fd, dl, "seen-full"); return "seen-full"; }
        g_collect_done = 1;                 /* once per boot, whatever the outcome */
        /* the once-per-boot rule survives a responder restart: an O_EXCL marker in RUNDIR
         * (tmpfs) is created BEFORE the fork (review m6) */
        {
            char mp[300]; snprintf(mp, sizeof mp, "%s/fs.collect-started", g_rundir);
            int mfd = open(mp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (mfd < 0) {
                const char *c = errno == EEXIST ? "collect-already" : "write";
                refuse(fd, dl, c); return c;
            }
            close(mfd);
        }
        size_t n = 0; const char *why = "runner";
        char *rec = run_collect(arg, &n, &why);
        if (!rec) { refuse(fd, now_ms() + WRITE_MS, why); return why; }
        int r = send_all(fd, rec, n, now_ms() + WRITE_MS);
        free(rec);
        return r ? "send-failed" : "ok";
    }
    }
}

/* ------------------------------------------------------------------ main */
static void usage(void) { fputs("usage: fs-rpcd -n NONCE16 -a ADDR -p PORT [-i IFNAME] -r RUNDIR [-c RUNNER -T SECONDS] [-m MAXCONN]\n", stderr); exit(2); }
static long num(const char *s, long lo, long hi) {      /* canonical decimal in [lo, hi] */
    if (!s[0] || strlen(s) > 7 || (s[0] == '0' && s[1])) usage();
    for (const char *p = s; *p; p++) if (*p < '0' || *p > '9') usage();
    long v = atol(s); if (v < lo || v > hi) usage();
    return v;
}

int main(int argc, char **argv) {
    const char *addr = NULL, *ifname = NULL; long port = 0, maxconn = 64; int opt, seen_opt[128] = { 0 };
    while ((opt = getopt(argc, argv, "+n:a:p:i:r:c:T:m:")) != -1) {
        if (opt == '?' || opt < 0 || opt >= 128 || seen_opt[opt]++) usage();
        switch (opt) {
        case 'n': if (!is_hex(optarg, 16)) usage(); snprintf(g_nonce, sizeof g_nonce, "%s", optarg); break;
        case 'a': addr = optarg; break;
        case 'p': port = num(optarg, 1, 65535); break;
        case 'i': ifname = optarg; if (strlen(ifname) < 1 || strlen(ifname) >= IF_NAMESIZE || strspn(ifname, "abcdefghijklmnopqrstuvwxyz0123456789") != strlen(ifname)) usage(); break;
        case 'r': if (!path_ok(optarg)) usage(); snprintf(g_rundir, sizeof g_rundir, "%s", optarg); break;
        case 'c': if (!path_ok(optarg)) usage(); snprintf(g_runner, sizeof g_runner, "%s", optarg); break;
        case 'T': g_collect_s = (int)num(optarg, 1, COLLECT_S_MAX); break;
        case 'm': maxconn = num(optarg, 1, MAXCONN_MAX); break;
        default: usage();
        }
    }
    if (optind != argc || !g_nonce[0] || !addr || !port || !g_rundir[0] || (!!g_runner[0] != !!g_collect_s)) usage();

    struct sockaddr_storage ss; socklen_t sl = 0; int fam = 0;
    memset(&ss, 0, sizeof ss);
    struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ss; struct sockaddr_in *s4 = (struct sockaddr_in *)&ss;
    if (inet_pton(AF_INET6, addr, &s6->sin6_addr) == 1) {
        fam = AF_INET6; s6->sin6_family = AF_INET6; s6->sin6_port = htons((uint16_t)port); sl = sizeof *s6;
        int ll = IN6_IS_ADDR_LINKLOCAL(&s6->sin6_addr);
        /* never a wildcard or multicast bind (review m5); v4-mapped is refused too */
        if (IN6_IS_ADDR_UNSPECIFIED(&s6->sin6_addr) || IN6_IS_ADDR_MULTICAST(&s6->sin6_addr) || IN6_IS_ADDR_V4MAPPED(&s6->sin6_addr)) usage();
        if (ll != !!ifname) usage();                         /* link-local <=> -i */
        if (ll) { s6->sin6_scope_id = if_nametoindex(ifname); if (!s6->sin6_scope_id) { fputs("fs-rpcd: no such interface\n", stderr); return 3; } }
    } else if (inet_pton(AF_INET, addr, &s4->sin_addr) == 1) {
        if (ifname) usage();
        uint32_t a4 = ntohl(s4->sin_addr.s_addr);
        if (a4 == INADDR_ANY || a4 == INADDR_BROADCAST || (a4 >> 28) == 0xe) usage();   /* wildcard, broadcast, multicast */
        fam = AF_INET; s4->sin_family = AF_INET; s4->sin_port = htons((uint16_t)port); sl = sizeof *s4;
    } else usage();

    /* defined process state whatever PID 1 (or a fixture) left us (review m3): default
     * dispositions for everything we rely on, nothing blocked, cwd "/" */
    for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
    sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, NULL);
    if (chdir("/") != 0) return 4;
    /* child subreaper: the runner's orphans (setsid, double fork) come back to us (rev 3) */
    if (prctl(PR_SET_CHILD_SUBREAPER, 1UL, 0UL, 0UL, 0UL) != 0) { perror("fs-rpcd: subreaper"); return 4; }
    signal(SIGPIPE, SIG_IGN);
    int lfd = socket(fam, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (lfd < 0) return 4;
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (fam == AF_INET6) setsockopt(lfd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    long long bdl = now_ms() + BIND_WAIT_MS;
    while (bind(lfd, (struct sockaddr *)&ss, sl) != 0) {     /* the address may still be appearing */
        if (errno != EADDRNOTAVAIL || now_ms() >= bdl) { perror("fs-rpcd: bind"); return 3; }
        sleep_ms(200);
    }
    if (listen(lfd, 1) != 0) return 4;
    rlog("FSRPC listening port=%u fam=%s if=%s\n", (unsigned)port, fam == AF_INET6 ? "inet6" : "inet", ifname ? ifname : "-");

    for (unsigned seq = 1; seq <= (unsigned)maxconn; ) {
        int fd = accept4(lfd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            sleep_ms(100);                                    /* EMFILE/ENOMEM etc.: back off, never spin */
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        char line[REQ_MAX + 1]; int reset = 0; const char *verb = "-", *res;
        const char *bad = read_request(fd, line, &reset);
        long long dl = now_ms() + WRITE_MS;
        if (bad) {
            res = bad;
            if (!reset) refuse(fd, dl, bad);
        } else {
            res = dispatch(fd, dl, line, &verb);
        }
        rlog("FSRPC seq=%u verb=%s result=%s\n", seq, verb, res);
        if (g_swept) { rlog("FSRPC swept=%u orphans%s%s\n", g_swept, "", ""); g_swept = 0; }
        if (reset) close(fd); else finish(fd);
        seq++;
    }
    rlog("FSRPC maxconn=%u reached; exiting%s%s\n", (unsigned)maxconn, "", "");
    close(lfd);
    return 0;
}
