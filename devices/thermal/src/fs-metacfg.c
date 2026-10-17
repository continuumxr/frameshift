// SPDX-License-Identifier: Apache-2.0
// FrameShift fs-metacfg: read-only reader of Meta's thermal configuration
// from the active slot's `vendor` logical partition inside `super`
// (option B, PM J-122; emergency-shutdown-design.md rev 5 §4.5.2).
//
// Normative text: devices/thermal/METACFG-SPEC.md (rule ids M-n below).
// One-shot helper started by fs-thermald before its RT elevation. It opens
// `super` O_RDONLY, makes one ioctl (BLKGETSIZE64), installs a seccomp
// filter, then only preads `super` and writes one framed record to outfd.
// No mount, no device-mapper device, no write to any storage. Any doubt is
// a status code (fallback in the supervisor), never a crash.
//
// Build variants: production (default) and test (-DFS_TEST: --root,
// --super-size, --uevent-sock, --allow-regular, --seccomp-optional).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/fs.h>
#include <linux/netlink.h>
#include <linux/seccomp.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "metacfg_record.h"
#include "sha256.h"

#define UEVENT_WAIT_MS 1800
#define READ_BUDGET (1024u * 1024u)
#define BS 4096u
#define DIR_BLOCK_CAP 16
#define MAX_LEAVES 64

/* ---------------------------------------------------------------- state */
static int g_out = -1;              /* record pipe */
static int g_dev = -1;              /* super, O_RDONLY */
static uint64_t g_devsize;
static uint64_t g_budget;           /* bytes pread so far (M-5 budget) */
static uint32_t g_slot;
static uint32_t g_lpflags, g_vattr, g_rflags;
static const char *g_root = "";
static const char *g_device;

static uint8_t g_geo[4096];
static uint8_t g_meta[65536];
static uint8_t g_blk[BS];
static uint8_t g_json[MC_MAX_JSON];
static uint32_t g_json_len;
static uint8_t g_vr[MC_MAX_VR];
static uint32_t g_vr_len;
static uint8_t g_prop[65536];
static uint32_t g_prop_len;
static char g_dev_val[MC_MAX_PROP + 1], g_incr_val[MC_MAX_PROP + 1];
static uint8_t g_entries[MC_MAX_ENTRIES][MC_ENTRY];
static uint32_t g_nent;

/* vendor extent map (M-12): pointers into g_meta */
static const uint8_t *g_vext;
static uint32_t g_nvext;
static uint64_t g_vlen; /* vendor length in bytes */

/* ext4 geometry (M-13, M-14) */
static uint32_t g_inodes, g_blocks, g_ipg;
static unsigned g_dir_blocks;

/* ------------------------------------------------------------- output */
static void wr_all(const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t w = write(g_out, p, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            _exit(3);
        p += w;
        n -= (size_t)w;
    }
}

static void emit(unsigned status)
{
    uint8_t h[MC_HDR];
    memset(h, 0, sizeof h);
    memcpy(h, MC_MAGIC, 4);
    mc_wr16(h + 4, MC_VERSION);
    mc_wr16(h + 6, (uint16_t)status);
    if (status == MC_OK) {
        mc_wr32(h + 8, g_json_len);
        mc_wr32(h + 12, g_vr_len);
        mc_wr16(h + 16, (uint16_t)strlen(g_dev_val));
        mc_wr16(h + 18, (uint16_t)strlen(g_incr_val));
        mc_wr32(h + 20, g_nent);
    }
    mc_wr32(h + 24, MC_ENTRY);
    mc_wr32(h + 36, g_slot);
    if (status == MC_OK) { /* log-only fields; zero on failure (M-27) */
        mc_wr32(h + 28, g_lpflags);
        mc_wr32(h + 32, g_vattr);
        mc_wr32(h + 40, g_rflags);
    }
    wr_all(h, sizeof h);
    if (status == MC_OK) {
        wr_all(g_json, g_json_len);
        wr_all(g_vr, g_vr_len);
        wr_all((const uint8_t *)g_dev_val, strlen(g_dev_val));
        wr_all((const uint8_t *)g_incr_val, strlen(g_incr_val));
        wr_all(&g_entries[0][0], (size_t)g_nent * MC_ENTRY);
    }
}

static __attribute__((noreturn)) void die(unsigned status)
{
    emit(status);
    _exit(0);
}

/* ------------------------------------------------------- bounded reads */
static void rd(uint64_t off, void *buf, uint32_t n)
{
    uint8_t *p = buf;
    if (n > READ_BUDGET || g_budget + n > READ_BUDGET)
        die(MC_S_9); /* read-budget */
    if (off > g_devsize || n > g_devsize - off)
        die(MC_S_8); /* io: outside the device */
    g_budget += n;
    while (n) {
        ssize_t r = pread(g_dev, p, n, (off_t)off);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            die(MC_S_8); /* io: error or short */
        p += r;
        off += (uint64_t)r;
        n -= (uint32_t)r;
    }
}

/* vendor-relative read through the M-12 extent map */
static uint32_t g_vesz; /* extent entry size */

static void vrd(uint64_t voff, void *buf, uint32_t n)
{
    uint8_t *p = buf;
    uint64_t base = 0;
    uint32_t i;
    if (voff > g_vlen || n > g_vlen - voff)
        die(MC_S_28); /* ext4-range (M-20) */
    for (i = 0; i < g_nvext && n; i++) {
        const uint8_t *e = g_vext + (size_t)i * g_vesz;
        uint64_t len = mc_rd64(e) * 512u, start = mc_rd64(e + 12) * 512u;
        if (voff < base + len) {
            uint64_t in = voff - base, k = len - in;
            if (k > n)
                k = n;
            rd(start + in, p, (uint32_t)k);
            p += k;
            voff += k;
            n -= (uint32_t)k;
        }
        base += len;
    }
    if (n)
        die(MC_S_28);
}

/* -------------------------------------------------------------- helpers */
static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int path_join(char *out, size_t cap, const char *a, const char *b, const char *c)
{
    size_t la = strlen(a), lb = strlen(b), lc = c ? strlen(c) : 0;
    if (la + lb + lc + 1 > cap)
        return -1;
    memcpy(out, a, la);
    memcpy(out + la, b, lb);
    if (c)
        memcpy(out + la + lb, c, lc);
    out[la + lb + lc] = 0;
    return 0;
}

/* read a small text file fully; returns length or -1 */
static ssize_t slurp(const char *path, char *buf, size_t cap)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    size_t n = 0;
    if (fd < 0)
        return -1;
    for (;;) {
        ssize_t r;
        if (n == cap) { /* larger than allowed */
            close(fd);
            return -2;
        }
        r = read(fd, buf + n, cap - n);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0) {
            close(fd);
            return -1;
        }
        if (r == 0)
            break;
        n += (size_t)r;
    }
    close(fd);
    return (ssize_t)n;
}

/* find KEY=VALUE in a NUL- or newline-separated block */
static int kv_find(const char *buf, size_t n, const char *key, char *val, size_t vcap)
{
    size_t kl = strlen(key), i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && buf[j] != '\n' && buf[j] != 0)
            j++;
        if (j - i > kl && !memcmp(buf + i, key, kl) && buf[i + kl] == '=') {
            size_t vl = j - i - kl - 1;
            if (vl + 1 > vcap)
                return -1;
            memcpy(val, buf + i + kl + 1, vl);
            val[vl] = 0;
            return 1;
        }
        i = j + 1;
    }
    return 0;
}

/* -------------------------------------------------- M-1, M-2: locate */
static int g_uev = -1;

static void uevent_open(const char *sockpath)
{
#ifdef FS_TEST
    if (sockpath) {
        struct sockaddr_un a;
        g_uev = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (g_uev < 0)
            die(MC_S_2);
        memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX;
        if (strlen(sockpath) >= sizeof a.sun_path)
            die(MC_S_1);
        strcpy(a.sun_path, sockpath);
        unlink(sockpath);
        if (bind(g_uev, (struct sockaddr *)&a, sizeof a) < 0)
            die(MC_S_2);
        return;
    }
#else
    (void)sockpath;
#endif
    {
        struct sockaddr_nl a;
        g_uev = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT);
        if (g_uev < 0)
            return; /* no socket: the scan alone decides (no-super if absent) */
        memset(&a, 0, sizeof a);
        a.nl_family = AF_NETLINK;
        a.nl_groups = 1; /* kernel uevents */
        if (bind(g_uev, (struct sockaddr *)&a, sizeof a) < 0) {
            close(g_uev);
            g_uev = -1;
        }
    }
}

/* returns 1 and fills devname if exactly one PARTNAME=super in sysfs */
static int scan_sysfs(char *devname, size_t cap)
{
    char dirp[512], p[1024], buf[4096], part[64], dn[64];
    DIR *d;
    struct dirent *e;
    int found = 0;
    if (path_join(dirp, sizeof dirp, g_root, "/sys/class/block", NULL))
        die(MC_S_1);
    d = opendir(dirp);
    if (!d)
        return 0;
    while ((e = readdir(d))) {
        ssize_t n;
        if (e->d_name[0] == '.')
            continue;
        if (path_join(p, sizeof p, dirp, "/", e->d_name) ||
            strlen(p) + 8 > sizeof p)
            continue;
        strcat(p, "/uevent");
        n = slurp(p, buf, sizeof buf);
        if (n < 0)
            continue;
        if (kv_find(buf, (size_t)n, "PARTNAME", part, sizeof part) == 1 && !strcmp(part, "super")) {
            if (kv_find(buf, (size_t)n, "DEVNAME", dn, sizeof dn) != 1)
                continue;
            found++;
            if (found == 1) {
                if (strlen(dn) + 1 > cap)
                    die(MC_S_2);
                strcpy(devname, dn);
            }
        }
    }
    closedir(d);
    if (found > 1)
        die(MC_S_3); /* super-ambiguous */
    return found;
}

static int wait_uevent(uint64_t t0, char *devname, size_t cap)
{
    char buf[8192], v[64];
    if (g_uev < 0)
        return 0;
    for (;;) {
        uint64_t t = now_ms();
        struct pollfd pf = {.fd = g_uev, .events = POLLIN};
        struct timespec ts;
        ssize_t n;
        struct sockaddr_storage from;
        socklen_t fl = sizeof from;
        if (t >= t0 + UEVENT_WAIT_MS)
            return 0;
        ts.tv_sec = (time_t)((t0 + UEVENT_WAIT_MS - t) / 1000);
        ts.tv_nsec = (long)(((t0 + UEVENT_WAIT_MS - t) % 1000) * 1000000);
        if (ppoll(&pf, 1, &ts, NULL) <= 0)
            continue; /* timeout re-checked above; EINTR retried */
        n = recvfrom(g_uev, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue;
        buf[n] = 0;
        if (from.ss_family == AF_NETLINK && ((struct sockaddr_nl *)&from)->nl_pid != 0)
            continue; /* not from the kernel */
        if (kv_find(buf, (size_t)n, "ACTION", v, sizeof v) != 1 || strcmp(v, "add"))
            continue;
        if (kv_find(buf, (size_t)n, "PARTNAME", v, sizeof v) != 1 || strcmp(v, "super"))
            continue;
        if (kv_find(buf, (size_t)n, "DEVNAME", v, sizeof v) != 1 || strlen(v) + 1 > cap)
            continue;
        strcpy(devname, v);
        return 1;
    }
}

/* ---------------------------------------------------------- M-3: slot */
static int slot_value(const char *v, size_t n)
{
    if (n == 2 && v[0] == '_' && v[1] == 'a')
        return 0;
    if (n == 2 && v[0] == '_' && v[1] == 'b')
        return 1;
    return -1;
}

static void read_slot(int bootconfig)
{
    static char buf[65536];
    char p[512];
    ssize_t n;
    size_t i = 0;
    int slot = -1;
    const char *key = "androidboot.slot_suffix";
    size_t kl = strlen(key);
    if (path_join(p, sizeof p, g_root, bootconfig ? "/proc/bootconfig" : "/proc/cmdline", NULL))
        die(MC_S_1);
    n = slurp(p, buf, sizeof buf);
    if (n < 0)
        die(MC_S_6);
    while (i < (size_t)n) {
        size_t j, a, b;
        int s;
        if (bootconfig) { /* one line: key [ws] = [ws] ["]v["] */
            j = i;
            while (j < (size_t)n && buf[j] != '\n')
                j++;
            a = i;
            while (a < j && (buf[a] == ' ' || buf[a] == '\t'))
                a++;
            if (j - a > kl && !memcmp(buf + a, key, kl) &&
                (buf[a + kl] == ' ' || buf[a + kl] == '\t' || buf[a + kl] == '=')) {
                a += kl;
                while (a < j && (buf[a] == ' ' || buf[a] == '\t'))
                    a++;
                if (a >= j || buf[a] != '=')
                    die(MC_S_6);
                a++;
                while (a < j && (buf[a] == ' ' || buf[a] == '\t'))
                    a++;
                b = j;
                while (b > a && (buf[b - 1] == ' ' || buf[b - 1] == '\t' || buf[b - 1] == '\r'))
                    b--;
                if (b - a >= 2 && buf[a] == '"' && buf[b - 1] == '"') {
                    a++;
                    b--;
                }
                s = slot_value(buf + a, b - a);
                if (s < 0 || (slot >= 0 && s != slot))
                    die(MC_S_6);
                slot = s;
            }
        } else { /* tokens separated by whitespace */
            while (i < (size_t)n && (buf[i] == ' ' || buf[i] == '\n' || buf[i] == '\t'))
                i++;
            j = i;
            while (j < (size_t)n && buf[j] != ' ' && buf[j] != '\n' && buf[j] != '\t')
                j++;
            if (j - i > kl && !memcmp(buf + i, key, kl) && buf[i + kl] == '=') {
                s = slot_value(buf + i + kl + 1, j - i - kl - 1);
                if (s < 0 || (slot >= 0 && s != slot))
                    die(MC_S_6);
                slot = s;
            }
        }
        i = j + 1;
    }
    if (slot < 0)
        die(MC_S_6);
    g_slot = (uint32_t)slot;
}

/* ------------------------------------------------------- M-5: seccomp */
#if defined(__aarch64__)
#define FS_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__x86_64__)
#define FS_AUDIT_ARCH AUDIT_ARCH_X86_64
#else
#error "unsupported architecture"
#endif

#define LD_NR BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr))
#define ARG_LO(i) BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[i]))
#define ARG_HI(i) BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[i]) + 4)
#define ALLOW BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
#define KILL BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS)
#define JEQ(v, t, f) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (v), (t), (f))

static int install_seccomp(void)
{
    struct sock_filter f[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        JEQ(FS_AUDIT_ARCH, 1, 0),
        KILL,
        LD_NR,
#ifdef __x86_64__
        BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1), /* x32 */
        KILL,
#endif
        JEQ(__NR_close, 0, 1), ALLOW,
        JEQ(__NR_fstat, 0, 1), ALLOW,
        JEQ(__NR_brk, 0, 1), ALLOW,
        JEQ(__NR_munmap, 0, 1), ALLOW,
        JEQ(__NR_clock_gettime, 0, 1), ALLOW,
        JEQ(__NR_rt_sigreturn, 0, 1), ALLOW,
        JEQ(__NR_exit_group, 0, 1), ALLOW,
        JEQ(__NR_exit, 0, 1), ALLOW,
        /* pread64(fd == super) */
        JEQ(__NR_pread64, 0, 6),
        ARG_HI(0), JEQ(0, 0, 3),
        ARG_LO(0), JEQ(0 /* patched: g_dev */, 0, 1),
        ALLOW,
        KILL,
        LD_NR,
        /* write(fd == out) */
        JEQ(__NR_write, 0, 6),
        ARG_HI(0), JEQ(0, 0, 3),
        ARG_LO(0), JEQ(0 /* patched: g_out */, 0, 1),
        ALLOW,
        KILL,
        LD_NR,
        /* mmap(..., prot without PROT_EXEC, ...) */
        JEQ(__NR_mmap, 0, 4),
        ARG_LO(2),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, PROT_EXEC, 1, 0),
        ALLOW,
        KILL,
        /* ioctl(super, BLKGETSIZE64) */
        JEQ(__NR_ioctl, 0, 9),
        ARG_HI(0), JEQ(0, 0, 7),
        ARG_LO(0), JEQ(0 /* patched: g_dev */, 0, 5),
        ARG_HI(1), JEQ((uint32_t)((uint64_t)BLKGETSIZE64 >> 32), 0, 3),
        ARG_LO(1), JEQ((uint32_t)BLKGETSIZE64, 0, 1),
        ALLOW,
        KILL,
    };
    struct sock_fprog prog = {.len = (unsigned short)(sizeof f / sizeof f[0]), .filter = f};
    unsigned i, nfd = 0;
    /* patch the descriptor constants: the JEQs right after an ARG_LO(0) */
    for (i = 0; i + 1 < prog.len; i++) {
        if (f[i].code == (BPF_LD | BPF_W | BPF_ABS) &&
            f[i].k == offsetof(struct seccomp_data, args[0]) &&
            f[i + 1].code == (BPF_JMP | BPF_JEQ | BPF_K)) {
            /* order in the program: pread (dev), write (out), ioctl (dev) */
            f[i + 1].k = (uint32_t)(nfd == 1 ? g_out : g_dev);
            nfd++;
        }
    }
    if (nfd != 3)
        return -1;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
        return -1;
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog))
        return -1;
    return 0;
}

/* ------------------------------------------------------ M-6 .. M-12: LP */
static int all_zero_check_sha(uint8_t *buf, size_t n, size_t csum_off)
{
    uint8_t saved[32], d[32];
    memcpy(saved, buf + csum_off, 32);
    memset(buf + csum_off, 0, 32);
    sha256(buf, n, d);
    memcpy(buf + csum_off, saved, 32);
    return memcmp(d, saved, 32) == 0;
}

static int table_ok(const uint8_t *desc, uint32_t min_size, uint32_t tables_size)
{
    uint32_t off = mc_rd32(desc), num = mc_rd32(desc + 4), esz = mc_rd32(desc + 8);
    uint64_t sz;
    if (esz < min_size)
        return 0;
    sz = (uint64_t)num * esz;
    if (sz > tables_size || off > tables_size || sz > (uint64_t)tables_size - off)
        return 0;
    return 1;
}

static void parse_lp(void)
{
    uint32_t mms, slots, lbs, hsz, minor, tsz, i, nparts, pesz, poff, nblk, bsz_e, boff;
    uint64_t moff;
    uint8_t *hdr, *tab;
    const uint8_t *vendor = NULL;
    char want[16];
    int nv = 0;

    /* M-6 geometry (primary only) */
    rd(4096, g_geo, 4096);
    if (mc_rd32(g_geo) != 0x616C4467u || mc_rd32(g_geo + 4) != 52 || !all_zero_check_sha(g_geo, 52, 8))
        die(MC_S_10);
    mms = mc_rd32(g_geo + 40);
    slots = mc_rd32(g_geo + 44);
    lbs = mc_rd32(g_geo + 48);
    if (!mms || mms % 512 || mms > 65536 || slots < 1 || slots > 3 || g_slot >= slots || !lbs || lbs % 512)
        die(MC_S_10);
    moff = 12288u + (uint64_t)g_slot * mms;
    if (moff > g_devsize || mms > g_devsize - moff)
        die(MC_S_10);

    /* M-7 header */
    rd(moff, g_meta, mms);
    hdr = g_meta;
    if (mc_rd32(hdr) != 0x414C5030u || mc_rd16(hdr + 4) != 10)
        die(MC_S_11);
    minor = mc_rd16(hdr + 6);
    hsz = mc_rd32(hdr + 8);
    if (minor > 2 || hsz != (minor <= 1 ? 128u : 256u) || hsz > mms)
        die(MC_S_11);
    tsz = mc_rd32(hdr + 44);
    if (tsz > mms - hsz)
        die(MC_S_11);
    if (!all_zero_check_sha(hdr, hsz, 12))
        die(MC_S_12);
    {
        uint8_t d[32];
        sha256(hdr + hsz, tsz, d);
        if (memcmp(d, hdr + 48, 32))
            die(MC_S_12);
    }
    if (minor == 2)
        g_lpflags = mc_rd32(hdr + 128);
    tab = hdr + hsz;

    /* M-8 tables */
    if (!table_ok(hdr + 80, 52, tsz) || !table_ok(hdr + 92, 24, tsz) ||
        !table_ok(hdr + 104, 48, tsz) || !table_ok(hdr + 116, 64, tsz))
        die(MC_S_13);

    /* M-9 block devices */
    nblk = mc_rd32(hdr + 116 + 4);
    bsz_e = mc_rd32(hdr + 116 + 8);
    boff = mc_rd32(hdr + 116);
    if (nblk != 1 || mc_rd64(tab + boff + 16) != g_devsize)
        die(MC_S_14);
    (void)bsz_e;

    /* M-10 names, M-11 the active logical view (rev 2, FS-R-012 §8), M-12 vendor */
    poff = mc_rd32(hdr + 80);
    nparts = mc_rd32(hdr + 80 + 4);
    pesz = mc_rd32(hdr + 80 + 8);
    for (i = 0; i < nparts; i++)
        if (!memchr(tab + poff + (size_t)i * pesz, 0, 36))
            die(MC_S_15);
    /* M-11: a deny-list of the signals visible in super (plus the M-21a Virtual A/B
     * policy on build.prop): any snapshot, COW, overlay or unknown-layout signal falls back */
    if (g_lpflags & 0x1)
        die(MC_S_57); /* vab-device: snapshot state on metadata/userdata, not visible here */
    if (g_lpflags)
        die(MC_S_58); /* lp-flags: any other header flag (unknown layout) */
    for (i = 0; i < nparts; i++) {
        const char *nm = (const char *)(tab + poff + (size_t)i * pesz);
        size_t l = strlen(nm);
        if (l >= 4 && !memcmp(nm + l - 4, "-cow", 4))
            die(MC_S_16); /* vab-merge (F38) */
    }
    {
        uint32_t goff = mc_rd32(hdr + 104), ngr = mc_rd32(hdr + 104 + 4), gesz = mc_rd32(hdr + 104 + 8);
        for (i = 0; i < ngr; i++)
            if (!memcmp(tab + goff + (size_t)i * gesz, "cow", 4))
                die(MC_S_59); /* vab-cow-group: libsnapshot's COW group */
    }
    for (i = 0; i < nparts; i++)
        if (!strcmp((const char *)(tab + poff + (size_t)i * pesz), "scratch"))
            die(MC_S_60); /* overlay: adb-remount scratch storage */
    strcpy(want, g_slot ? "vendor_b" : "vendor_a");
    for (i = 0; i < nparts; i++) {
        const uint8_t *pe = tab + poff + (size_t)i * pesz;
        if (!strcmp((const char *)pe, want)) {
            nv++;
            vendor = pe;
        }
    }
    if (nv == 0)
        die(MC_S_17);
    if (nv > 1)
        die(MC_S_18);
    g_vattr = mc_rd32(vendor + 36);
    if (g_vattr & 0x8)
        die(MC_S_19);
    if (g_vattr & 0x4)
        die(MC_S_61); /* vab-updated (M-12 rev 2) */
    if (g_vattr & ~0x3u)
        die(MC_S_62); /* lp-attr: only READONLY and SLOT_SUFFIXED are known safe */
    {
        uint32_t first = mc_rd32(vendor + 40), num = mc_rd32(vendor + 44);
        uint32_t eoff = mc_rd32(hdr + 92), ecnt = mc_rd32(hdr + 92 + 4), esz = mc_rd32(hdr + 92 + 8);
        if (num < 1 || first > ecnt || num > ecnt - first)
            die(MC_S_13);
        g_vesz = esz;
        g_vext = tab + eoff + (size_t)first * esz;
        g_nvext = num;
        g_vlen = 0;
        for (i = 0; i < num; i++) {
            const uint8_t *e = g_vext + (size_t)i * esz;
            uint64_t ns = mc_rd64(e), td = mc_rd64(e + 12);
            if (!ns)
                die(MC_S_56);
            if (mc_rd32(e + 8) != 0)
                die(MC_S_20); /* extent-type */
            if (mc_rd32(e + 20) != 0)
                die(MC_S_55); /* extent-source */
            if (td > UINT64_MAX - ns || td + ns > UINT64_MAX / 512 || (td + ns) * 512 > g_devsize)
                die(MC_S_56); /* extent-range */
            if (g_vlen > UINT64_MAX - ns * 512)
                die(MC_S_56);
            g_vlen += ns * 512;
        }
    }
}

/* ------------------------------------------------- M-13 .. M-20: ext4 */
static void ext4_super(void)
{
    uint8_t sb[1024];
    uint32_t bpg, groups;
    vrd(1024, sb, 1024);
    if (mc_rd16(sb + 0x38) != 0xEF53)
        die(MC_S_21);
    if (mc_rd32(sb + 0x18) != 2)
        die(MC_S_22);
    if (mc_rd32(sb + 0x5C) != 0x28 || mc_rd32(sb + 0x60) != 0x42 || mc_rd32(sb + 0x64) != 0x407B)
        die(MC_S_23);
    if (mc_rd16(sb + 0x58) != 256)
        die(MC_S_24);
    g_inodes = mc_rd32(sb + 0);
    g_blocks = mc_rd32(sb + 4);
    bpg = mc_rd32(sb + 0x20);
    g_ipg = mc_rd32(sb + 0x28);
    if (mc_rd32(sb + 0x14) != 0 || !bpg || !g_ipg || !g_blocks)
        die(MC_S_25);
    groups = g_blocks / bpg + (g_blocks % bpg ? 1 : 0);
    if ((uint64_t)groups * g_ipg != g_inodes)
        die(MC_S_25);
    if ((uint64_t)g_blocks * BS > g_vlen)
        die(MC_S_26);
}

struct inode {
    uint8_t raw[256];
    uint32_t size;
    uint16_t mode;
};

static void read_inode(uint32_t n, struct inode *ino)
{
    uint8_t gd[32];
    uint32_t g, tbl;
    if (n < 1 || n > g_inodes)
        die(MC_S_27);
    uint64_t fsb = (uint64_t)g_blocks * BS, off;
    g = (n - 1) / g_ipg;
    off = (uint64_t)BS + (uint64_t)g * 32;
    if (off + 32 > fsb) /* M-20 (rev 1a): inside the filesystem */
        die(MC_S_28);
    vrd(off, gd, 32);
    tbl = mc_rd32(gd + 8);
    if (tbl >= g_blocks)
        die(MC_S_28);
    off = (uint64_t)tbl * BS + (uint64_t)((n - 1) % g_ipg) * 256;
    if (off + 256 > fsb)
        die(MC_S_28);
    vrd(off, ino->raw, 256);
    if (!(mc_rd32(ino->raw + 0x20) & 0x80000) || (mc_rd32(ino->raw + 0x20) & 0x10000000))
        die(MC_S_29);
    if (mc_rd32(ino->raw + 0x6C) != 0 || mc_rd32(ino->raw + 4) > 65536)
        die(MC_S_30);
    ino->size = mc_rd32(ino->raw + 4);
    ino->mode = mc_rd16(ino->raw);
}

struct leaves {
    uint32_t n;
    uint32_t need;  /* blocks needed to cover i_size */
    uint32_t cover; /* logical blocks covered so far */
    uint64_t phys[MAX_LEAVES];
    uint32_t lblk[MAX_LEAVES], len[MAX_LEAVES];
};

static void walk_node(const uint8_t *node, uint32_t node_cap_entries, int expect_depth, struct leaves *L)
{
    uint16_t entries, max, depth, i;
    static uint8_t blkbuf[3][BS]; /* one per depth level */
    if (mc_rd16(node) != 0xF30A)
        die(MC_S_31);
    entries = mc_rd16(node + 2);
    max = mc_rd16(node + 4);
    depth = mc_rd16(node + 6);
    if (entries > max || max > node_cap_entries)
        die(MC_S_32);
    if ((expect_depth < 0 && depth > 2) || (expect_depth >= 0 && depth != expect_depth))
        die(MC_S_33);
    for (i = 0; i < entries && L->cover < L->need; i++) {
        const uint8_t *e = node + 12 + 12u * i;
        if (depth > 0) {
            uint64_t child = mc_rd32(e + 4) | (uint64_t)mc_rd16(e + 8) << 32;
            if (child >= g_blocks)
                die(MC_S_28);
            vrd(child * BS, blkbuf[depth], BS);
            walk_node(blkbuf[depth], (BS - 12) / 12, depth - 1, L);
        } else {
            uint32_t lb = mc_rd32(e), len = mc_rd16(e + 4);
            uint64_t start = (uint64_t)mc_rd16(e + 6) << 32 | mc_rd32(e + 8);
            if (len == 0 || len > 32768)
                die(MC_S_34);
            if (start + len > g_blocks)
                die(MC_S_28);
            if (lb != L->cover)
                die(MC_S_35);
            if (L->n == MAX_LEAVES)
                die(MC_S_35);
            L->phys[L->n] = start;
            L->lblk[L->n] = lb;
            L->len[L->n] = len;
            L->n++;
            L->cover += len;
        }
    }
}

static void extents_of(const struct inode *ino, struct leaves *L)
{
    memset(L, 0, sizeof *L);
    L->need = (ino->size + BS - 1) / BS;
    walk_node(ino->raw + 0x28, 4, -1, L);
    if (L->cover < L->need)
        die(MC_S_35);
}

/* read logical block lb of a file */
static void file_block(const struct leaves *L, uint32_t lb, uint8_t *out, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < L->n; i++)
        if (lb >= L->lblk[i] && lb < L->lblk[i] + L->len[i]) {
            vrd((L->phys[i] + (lb - L->lblk[i])) * BS, out, n);
            return;
        }
    die(MC_S_35);
}

/* M-18: one linear scan of a directory for up to 2 names (inode numbers
 * returned in out[], 0 if absent). Each directory is scanned once, so the
 * 16-block cap counts the blocks of `/` plus those of `/etc`. */
static void dir_lookup(uint32_t dino, const char *const *names, uint32_t *out, int nn)
{
    struct inode d;
    struct leaves L;
    uint32_t b;
    int k;
    for (k = 0; k < nn; k++)
        out[k] = 0;
    read_inode(dino, &d);
    if ((d.mode & 0xF000) != 0x4000)
        die(MC_S_36);
    if (d.size % BS)
        die(MC_S_37);
    extents_of(&d, &L);
    for (b = 0; b < d.size / BS; b++) {
        uint32_t off = 0;
        if (++g_dir_blocks > DIR_BLOCK_CAP)
            die(MC_S_38);
        file_block(&L, b, g_blk, BS);
        while (off < BS) {
            uint32_t ino = mc_rd32(g_blk + off);
            uint16_t rl = mc_rd16(g_blk + off + 4);
            uint8_t ln = g_blk[off + 6];
            if (rl < 12 || rl % 4 || rl > BS - off || (uint32_t)ln + 8 > rl)
                die(MC_S_37);
            for (k = 0; ino && k < nn; k++)
                if (!out[k] && ln == strlen(names[k]) && !memcmp(g_blk + off + 8, names[k], ln))
                    out[k] = ino;
            off += rl;
        }
    }
}

static uint32_t read_file(uint32_t ino, uint8_t *out, uint32_t cap)
{
    struct inode f;
    struct leaves L;
    uint32_t b, done = 0;
    if (!ino)
        die(MC_S_39);
    read_inode(ino, &f);
    if ((f.mode & 0xF000) != 0x8000)
        die(MC_S_40);
    if (f.size > cap)
        die(MC_S_41);
    extents_of(&f, &L);
    for (b = 0; done < f.size; b++) {
        uint32_t k = f.size - done < BS ? f.size - done : BS;
        file_block(&L, b, out + done, k);
        done += k;
    }
    return f.size;
}

/* ------------------------------------------------- M-21: build.prop */
static int prop_char_ok(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' ||
           c == '_' || c == '-';
}

/* M-21a (rev 3, PM 2026-10-15): a key starting "ro.virtual_ab." with any value but
 * "false" marks a Virtual A/B device: refused, the built-in table applies. Key and
 * value are trimmed of the C-locale isspace() characters on both sides, as Android's
 * property loader does (AOSP system/core init/property_service.cpp LoadProperties) */
static int mc_space(char ch)
{
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\v' || ch == '\f' || ch == '\r';
}

static int vab_line(const char *line, uint32_t e, uint32_t ll)
{
    uint32_t a = 0, b = e, c = e + 1, d = ll;
    while (a < b && mc_space(line[a]))
        a++;
    while (b > a && mc_space(line[b - 1]))
        b--;
    if (b - a < 14 || memcmp(line + a, "ro.virtual_ab.", 14))
        return 0;
    while (c < d && mc_space(line[c]))
        c++;
    while (d > c && mc_space(line[d - 1]))
        d--;
    return !(d - c == 5 && !memcmp(line + c, "false", 5));
}

static void parse_buildprop(void)
{
    uint32_t i = 0;
    int ndev = 0, ninc = 0, vab = 0;
    while (i < g_prop_len) {
        uint32_t j = i, e, k;
        const char *line = (const char *)g_prop + i;
        uint32_t ll;
        while (j < g_prop_len && g_prop[j] != '\n')
            j++;
        ll = j - i;
        if (ll && line[ll - 1] == '\r')
            ll--;
        if (ll && line[0] != '#') {
            for (e = 0; e < ll && line[e] != '='; e++)
                ;
            if (e < ll) {
                char *dst = NULL;
                int *cnt = NULL;
                if (vab_line(line, e, ll))
                    vab = 1;
                if (e == 24 && !memcmp(line, "ro.product.vendor.device", 24)) {
                    dst = g_dev_val;
                    cnt = &ndev;
                } else if (e == 35 && !memcmp(line, "ro.vendor.build.version.incremental", 35)) {
                    dst = g_incr_val;
                    cnt = &ninc;
                }
                if (dst) {
                    uint32_t vl = ll - e - 1;
                    if (++*cnt > 1 || vl < 1 || vl > MC_MAX_PROP)
                        die(MC_S_42);
                    for (k = 0; k < vl; k++)
                        if (!prop_char_ok(line[e + 1 + k]))
                            die(MC_S_42);
                    memcpy(dst, line + e + 1, vl);
                    dst[vl] = 0;
                }
            }
        }
        i = j + 1;
    }
    if (ndev != 1 || ninc != 1)
        die(MC_S_42);
    if (vab)
        die(MC_S_63); /* vab-policy */
}

/* ------------------------------------------- M-22 .. M-25: strict JSON */
static const uint8_t *J;
static uint32_t JN, JP;

/* pass 1: generic RFC 8259 syntax with the M-22 restrictions; depth <= 4 */
static void j_ws(void)
{
    while (JP < JN && (J[JP] == ' ' || J[JP] == '\t' || J[JP] == '\r' || J[JP] == '\n'))
        JP++;
}

static void syn_value(int depth);

static void syn_string(void)
{
    JP++; /* opening quote */
    for (;;) {
        uint8_t c;
        if (JP >= JN)
            die(MC_S_43);
        c = J[JP++];
        if (c == '"')
            return;
        if (c == '\\' || c < 0x20 || c > 0x7E)
            die(MC_S_43);
    }
}

static void syn_number(void)
{
    uint32_t s = JP;
    if (JP < JN && J[JP] == '-')
        JP++;
    if (JP >= JN)
        die(MC_S_43);
    if (J[JP] == '0')
        JP++;
    else if (J[JP] >= '1' && J[JP] <= '9')
        while (JP < JN && J[JP] >= '0' && J[JP] <= '9')
            JP++;
    else
        die(MC_S_43);
    if (JP < JN && J[JP] == '.') {
        uint32_t f = ++JP;
        while (JP < JN && J[JP] >= '0' && J[JP] <= '9')
            JP++;
        if (JP == f)
            die(MC_S_43);
    }
    if (JP < JN && (J[JP] == 'e' || J[JP] == 'E')) {
        uint32_t f;
        JP++;
        if (JP < JN && (J[JP] == '+' || J[JP] == '-'))
            JP++;
        f = JP;
        while (JP < JN && J[JP] >= '0' && J[JP] <= '9')
            JP++;
        if (JP == f)
            die(MC_S_43);
    }
    (void)s;
}

static void syn_lit(const char *w)
{
    size_t l = strlen(w);
    if (JN - JP < l || memcmp(J + JP, w, l))
        die(MC_S_43);
    JP += (uint32_t)l;
}

static void syn_value(int depth)
{
    j_ws();
    if (JP >= JN)
        die(MC_S_43);
    switch (J[JP]) {
    case '{':
    case '[': {
        uint8_t close = J[JP] == '{' ? '}' : ']';
        int obj = J[JP] == '{';
        if (depth + 1 > 4)
            die(MC_S_44);
        JP++;
        j_ws();
        if (JP < JN && J[JP] == close) {
            JP++;
            return;
        }
        for (;;) {
            if (obj) {
                j_ws();
                if (JP >= JN || J[JP] != '"')
                    die(MC_S_43);
                syn_string();
                j_ws();
                if (JP >= JN || J[JP] != ':')
                    die(MC_S_43);
                JP++;
            }
            syn_value(depth + 1);
            j_ws();
            if (JP < JN && J[JP] == ',') {
                JP++;
                continue;
            }
            if (JP < JN && J[JP] == close) {
                JP++;
                return;
            }
            die(MC_S_43);
        }
    }
    case '"':
        syn_string();
        return;
    case 't':
        syn_lit("true");
        return;
    case 'f':
        syn_lit("false");
        return;
    case 'n':
        syn_lit("null");
        return;
    default:
        syn_number();
        return;
    }
}

/* pass 2: schema. Input is syntactically valid (pass 1). */
enum jt { JT_OBJ, JT_ARR, JT_STR, JT_NUM, JT_TRUE, JT_FALSE, JT_NULL };

static enum jt j_peek(void)
{
    j_ws();
    switch (J[JP]) {
    case '{':
        return JT_OBJ;
    case '[':
        return JT_ARR;
    case '"':
        return JT_STR;
    case 't':
        return JT_TRUE;
    case 'f':
        return JT_FALSE;
    case 'n':
        return JT_NULL;
    default:
        return JT_NUM;
    }
}

static void j_str(uint32_t *s, uint32_t *l) /* at '"' */
{
    j_ws();
    *s = ++JP;
    while (J[JP] != '"')
        JP++;
    *l = JP - *s;
    JP++;
}

static void j_num(uint32_t *s, uint32_t *l)
{
    j_ws();
    *s = JP;
    while (JP < JN && (J[JP] == '-' || J[JP] == '+' || J[JP] == '.' || J[JP] == 'e' || J[JP] == 'E' ||
                       (J[JP] >= '0' && J[JP] <= '9')))
        JP++;
    *l = JP - *s;
}

static void j_skip(void) /* skip any valid value */
{
    enum jt t = j_peek();
    uint32_t s, l;
    if (t == JT_STR)
        j_str(&s, &l);
    else if (t == JT_NUM)
        j_num(&s, &l);
    else if (t == JT_TRUE)
        JP += 4;
    else if (t == JT_FALSE)
        JP += 5;
    else if (t == JT_NULL)
        JP += 4;
    else {
        uint8_t close = J[JP] == '{' ? '}' : ']';
        int obj = close == '}';
        JP++;
        j_ws();
        if (J[JP] == close) {
            JP++;
            return;
        }
        for (;;) {
            if (obj) {
                j_str(&s, &l);
                j_ws();
                JP++; /* ':' */
            }
            j_skip();
            j_ws();
            if (J[JP++] == close)
                return;
        }
    }
}

/* M-24 decimal: -?(0|[1-9][0-9]{0,8})(\.[0-9]{1,maxdec})?  ->  int part, frac, ndec */
static int dec_parse(const uint8_t *p, uint32_t l, int maxdec, int64_t *ip, int64_t *fr, int *nd, int *neg)
{
    uint32_t i = 0, d0;
    *neg = 0;
    *ip = 0;
    *fr = 0;
    *nd = 0;
    if (i < l && p[i] == '-') {
        *neg = 1;
        i++;
    }
    if (i >= l)
        return -1;
    d0 = i;
    if (p[i] == '0')
        i++;
    else if (p[i] >= '1' && p[i] <= '9') {
        while (i < l && p[i] >= '0' && p[i] <= '9') {
            if (i - d0 >= 9)
                return -1;
            i++;
        }
    } else
        return -1;
    for (uint32_t k = d0; k < i; k++)
        *ip = *ip * 10 + (p[k] - '0');
    if (i < l && p[i] == '.') {
        i++;
        if (i >= l)
            return -1;
        while (i < l && p[i] >= '0' && p[i] <= '9') {
            if (*nd >= maxdec)
                return -1;
            *fr = *fr * 10 + (p[i] - '0');
            (*nd)++;
            i++;
        }
        if (*nd == 0)
            return -1;
    }
    if (i != l)
        return -1;
    return 0;
}

static int milli(const uint8_t *p, uint32_t l, int32_t *out)
{
    int64_t ip, fr, v;
    int nd, neg;
    if (dec_parse(p, l, 3, &ip, &fr, &nd, &neg))
        return -1;
    while (nd < 3) {
        fr *= 10;
        nd++;
    }
    v = ip * 1000 + fr;
    if (neg)
        v = -v;
    if (v > INT32_MAX || v <= INT32_MIN)
        return -1;
    *out = (int32_t)v;
    return 0;
}

/* a slot element: number, numeric string or "NAN" */
static void j_slot(int32_t *out)
{
    enum jt t = j_peek();
    uint32_t s, l;
    if (t == JT_STR) {
        j_str(&s, &l);
        if (l == 3 && !memcmp(J + s, "NAN", 3)) {
            *out = MC_UNSET;
            return;
        }
    } else if (t == JT_NUM)
        j_num(&s, &l);
    else
        die(MC_S_47); /* json-number: a slot of another JSON type (M-24) */
    if (milli(J + s, l, out))
        die(MC_S_47);
}

static void j_slots(int32_t out[7])
{
    int n = 0;
    if (j_peek() != JT_ARR)
        die(MC_S_54);
    JP++;
    j_ws();
    if (J[JP] == ']') {
        JP++;
        die(MC_S_53);
    }
    for (;;) {
        int32_t v;
        j_slot(&v);
        if (n < 7)
            out[n] = v;
        n++;
        j_ws();
        if (J[JP++] == ']')
            break;
    }
    if (n != 7)
        die(MC_S_53);
}

static int name_ok(const uint8_t *p, uint32_t l)
{
    uint32_t i;
    if (l < 1 || l > 31)
        return 0;
    for (i = 0; i < l; i++)
        if (!prop_char_ok((char)p[i]))
            return 0;
    return 1;
}

static int key_is(uint32_t s, uint32_t l, const char *k)
{
    return strlen(k) == l && !memcmp(J + s, k, l);
}

static void j_sensor(void)
{
    enum { K_NAME = 1, K_TYPE = 2, K_HT = 4, K_HH = 8, K_VR = 16, K_MUL = 32, K_MON = 64 };
    unsigned seen = 0;
    uint8_t *ent;
    int32_t ht[7], hh[7];
    int32_t mn = 0, md = 0;
    uint32_t i;
    int anyset = 0;
    if (j_peek() != JT_OBJ)
        die(MC_S_54);
    if (g_nent >= MC_MAX_ENTRIES)
        die(MC_S_52);
    ent = g_entries[g_nent];
    memset(ent, 0, MC_ENTRY);
    for (i = 0; i < 7; i++)
        hh[i] = MC_UNSET;
    JP++;
    j_ws();
    if (J[JP] == '}')
        JP++;
    else
        for (;;) {
            uint32_t ks, kl, bit;
            j_str(&ks, &kl);
            j_ws();
            JP++; /* ':' */
            if (key_is(ks, kl, "Name"))
                bit = K_NAME;
            else if (key_is(ks, kl, "Type"))
                bit = K_TYPE;
            else if (key_is(ks, kl, "HotThreshold"))
                bit = K_HT;
            else if (key_is(ks, kl, "HotHysteresis"))
                bit = K_HH;
            else if (key_is(ks, kl, "VrThreshold"))
                bit = K_VR;
            else if (key_is(ks, kl, "Multiplier"))
                bit = K_MUL;
            else if (key_is(ks, kl, "Monitor"))
                bit = K_MON;
            else
                die(MC_S_46);
            if (seen & bit)
                die(MC_S_45);
            seen |= bit;
            switch (bit) {
            case K_NAME: {
                uint32_t s, l;
                if (j_peek() != JT_STR)
                    die(MC_S_54);
                j_str(&s, &l);
                if (!name_ok(J + s, l))
                    die(MC_S_50);
                memcpy(ent, J + s, l);
                break;
            }
            case K_TYPE: {
                uint32_t s, l;
                if (j_peek() != JT_STR)
                    die(MC_S_54);
                j_str(&s, &l);
                break;
            }
            case K_HT:
                j_slots(ht);
                break;
            case K_HH:
                j_slots(hh);
                break;
            case K_VR: {
                uint32_t s, l;
                if (j_peek() != JT_STR) {
                    j_skip();
                    die(MC_S_48);
                }
                j_str(&s, &l);
                if (l != 3 || memcmp(J + s, "NAN", 3))
                    die(MC_S_48);
                break;
            }
            case K_MUL: {
                uint32_t s, l;
                int64_t ip, fr, num, den = 1;
                int nd, neg;
                enum jt t = j_peek();
                if (t == JT_STR)
                    j_str(&s, &l);
                else if (t == JT_NUM)
                    j_num(&s, &l);
                else
                    die(MC_S_47); /* M-24 */
                if (dec_parse(J + s, l, 6, &ip, &fr, &nd, &neg) || neg)
                    die(MC_S_47);
                for (int k = 0; k < nd; k++)
                    den *= 10;
                num = ip * den + fr;
                if (num <= 0)
                    die(MC_S_47);
                while (den > 1 && num % 10 == 0) {
                    num /= 10;
                    den /= 10;
                }
                if (num > INT32_MAX)
                    die(MC_S_47);
                mn = (int32_t)num;
                md = (int32_t)den;
                break;
            }
            case K_MON: {
                enum jt t = j_peek();
                if (t == JT_TRUE)
                    JP += 4;
                else
                    die(MC_S_49); /* anything but the literal true (M-24) */
                break;
            }
            }
            j_ws();
            if (J[JP++] == '}')
                break;
        }
    if ((seen & (K_NAME | K_TYPE | K_HT | K_VR | K_MUL)) != (K_NAME | K_TYPE | K_HT | K_VR | K_MUL))
        die(MC_S_54);
    for (i = 0; i < 7; i++)
        if (ht[i] != MC_UNSET)
            anyset = 1;
    if (anyset && !(seen & K_MON))
        die(MC_S_49);
    for (i = 0; i < g_nent; i++)
        if (!memcmp(g_entries[i], ent, MC_NAME))
            die(MC_S_51);
    for (i = 0; i < 7; i++) {
        mc_wr32(ent + 32 + 4 * i, (uint32_t)ht[i]);
        mc_wr32(ent + 60 + 4 * i, (uint32_t)hh[i]);
    }
    mc_wr32(ent + 88, (uint32_t)mn);
    mc_wr32(ent + 92, (uint32_t)md);
    g_nent++;
}

static void j_cdev(void)
{
    unsigned seen = 0;
    if (j_peek() != JT_OBJ)
        die(MC_S_54);
    JP++;
    j_ws();
    if (J[JP] == '}')
        JP++;
    else
        for (;;) {
            uint32_t ks, kl, s, l, bit;
            j_str(&ks, &kl);
            j_ws();
            JP++;
            if (key_is(ks, kl, "Name"))
                bit = 1;
            else if (key_is(ks, kl, "Type"))
                bit = 2;
            else
                die(MC_S_46);
            if (seen & bit)
                die(MC_S_45);
            seen |= bit;
            if (j_peek() != JT_STR)
                die(MC_S_54);
            j_str(&s, &l);
            j_ws();
            if (J[JP++] == '}')
                break;
        }
    if (seen != 3)
        die(MC_S_54);
}

static void j_array_of(void (*fn)(void), int sensors)
{
    if (j_peek() != JT_ARR)
        die(MC_S_54);
    JP++;
    j_ws();
    if (J[JP] == ']') {
        JP++;
        return;
    }
    for (;;) {
        if (sensors && g_nent >= MC_MAX_ENTRIES)
            die(MC_S_52);
        fn();
        j_ws();
        if (J[JP++] == ']')
            return;
    }
}

static void parse_json(void)
{
    unsigned seen = 0;
    J = g_json;
    JN = g_json_len;
    JP = 0;
    if (JN >= 3 && J[0] == 0xEF && J[1] == 0xBB && J[2] == 0xBF)
        die(MC_S_43);
    /* pass 1 */
    syn_value(0);
    j_ws();
    if (JP != JN)
        die(MC_S_43);
    /* pass 2 */
    JP = 0;
    if (j_peek() != JT_OBJ)
        die(MC_S_54);
    JP++;
    j_ws();
    if (J[JP] == '}')
        JP++;
    else
        for (;;) {
            uint32_t ks, kl, bit;
            j_str(&ks, &kl);
            j_ws();
            JP++;
            if (key_is(ks, kl, "Sensors"))
                bit = 1;
            else if (key_is(ks, kl, "CoolingDevices"))
                bit = 2;
            else
                die(MC_S_46);
            if (seen & bit)
                die(MC_S_45);
            seen |= bit;
            if (bit == 1)
                j_array_of(j_sensor, 1);
            else
                j_array_of(j_cdev, 0);
            j_ws();
            if (J[JP++] == '}')
                break;
        }
    if (!(seen & 1))
        die(MC_S_54);
    if (g_nent == 0)
        die(MC_S_52);
    /* sort entries by name (insertion sort, n <= 128) */
    for (uint32_t i = 1; i < g_nent; i++) {
        uint8_t tmp[MC_ENTRY];
        uint32_t j = i;
        memcpy(tmp, g_entries[i], MC_ENTRY);
        while (j > 0 && memcmp(g_entries[j - 1], tmp, MC_NAME) > 0) {
            memcpy(g_entries[j], g_entries[j - 1], MC_ENTRY);
            j--;
        }
        memcpy(g_entries[j], tmp, MC_ENTRY);
    }
}

/* ---------------------------------------------------------------- main */
static void usage_die(void) { die(MC_S_1); }

int main(int argc, char **argv)
{
    uint64_t t0 = now_ms(), expect;
    char devname[64], p[512];
    const char *usock = NULL;
    int allow_regular = 0, seccomp_optional = 0, seccomp_selftest = 0, i, bootconfig;
    (void)seccomp_selftest;
    uint64_t super_size_override = 0;
    struct stat st;

    /* fixed positional: <device> <outfd> [test options] */
    if (argc < 3)
        _exit(2);
    {
        char *end;
        long fd = strtol(argv[2], &end, 10);
        if (*end || fd < 0 || fd > 1023)
            _exit(2);
        g_out = (int)fd;
    }
    g_device = argv[1];
    for (i = 3; i < argc; i++) {
#ifdef FS_TEST
        if (!strcmp(argv[i], "--root") && i + 1 < argc)
            g_root = argv[++i];
        else if (!strcmp(argv[i], "--super-size") && i + 1 < argc)
            super_size_override = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--uevent-sock") && i + 1 < argc)
            usock = argv[++i];
        else if (!strcmp(argv[i], "--allow-regular"))
            allow_regular = 1;
        else if (!strcmp(argv[i], "--seccomp-optional"))
            seccomp_optional = 1;
        else if (!strcmp(argv[i], "--seccomp-selftest"))
            seccomp_selftest = 1;
        else
#endif
            usage_die();
    }
    if (!strcmp(g_device, "eureka")) {
        expect = 0x200000000ull;
        bootconfig = 1;
    } else if (!strcmp(g_device, "hollywood")) {
        expect = 0x180000000ull;
        bootconfig = 0;
    } else
        usage_die();
    if (super_size_override)
        expect = super_size_override;

    /* M-1, M-2: socket first, then scan, then wait */
    uevent_open(usock);
    if (!scan_sysfs(devname, sizeof devname) && !wait_uevent(t0, devname, sizeof devname))
        die(MC_S_2);
    if (g_uev >= 0)
        close(g_uev);
    if (devname[0] == '/' || strstr(devname, ".."))
        die(MC_S_4);

    /* M-3 */
    read_slot(bootconfig);

    /* M-4 */
    if (path_join(p, sizeof p, g_root, "/dev/", devname))
        die(MC_S_1);
    g_dev = open(p, O_RDONLY | O_CLOEXEC);
    if (g_dev < 0)
        die(MC_S_2);
    if (fstat(g_dev, &st))
        die(MC_S_8);
    if (S_ISBLK(st.st_mode)) {
        uint64_t sz = 0;
        if (ioctl(g_dev, BLKGETSIZE64, &sz))
            die(MC_S_8);
        g_devsize = sz;
    } else if (allow_regular && S_ISREG(st.st_mode)) {
        g_devsize = (uint64_t)st.st_size;
    } else
        die(MC_S_4);
    if (g_devsize != expect)
        die(MC_S_5);

    /* M-5 */
    if (install_seccomp()) {
        if (!seccomp_optional)
            die(MC_S_7);
        g_rflags |= MC_FLAG_SECCOMP_OFF;
    }
#ifdef FS_TEST
    if (seccomp_selftest)
        (void)syscall(__NR_getpid); /* not on the allow-list: the filter kills us here */
#endif

    parse_lp();                                                       /* M-6..M-12 */
    ext4_super();                                                     /* M-13, M-14 */
    {
        static const char *const rootn[2] = {"etc", "build.prop"};
        static const char *const etcn[2] = {"thermal_info_config.json", "vr_runtime_power_mitigation.json"};
        uint32_t r[2], e[2];
        dir_lookup(2, rootn, r, 2);
        if (!r[0])
            die(MC_S_39);
        dir_lookup(r[0], etcn, e, 2);
        g_json_len = read_file(e[0], g_json, MC_MAX_JSON);  /* M-19 */
        g_vr_len = read_file(e[1], g_vr, MC_MAX_VR);
        g_prop_len = read_file(r[1], g_prop, sizeof g_prop);
    }
    parse_buildprop(); /* M-21 */
    parse_json();      /* M-22..M-25 */
    emit(MC_OK);
    _exit(0);
}
