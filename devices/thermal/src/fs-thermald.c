// SPDX-License-Identifier: Apache-2.0
// fs-thermald: start-up (fs-metacfg spawn with the bounded wait of design
// §4.5.2, acceptance §4.5.3), the sysfs I/O layer, the decision core and,
// in part 2, the executor (thermald_exec.c, EXEC-SPEC.md).
//
// Build kinds (tools/build.sh):
//   -DFS_TEST              test build: --sim (actions printed, part 1) and
//                          --exec-sim (the executor under a fake root with
//                          logged stand-ins for the kernel-facing calls);
//   -DFS_DEVICE            device build: --run (1 s timerfd loop, the real
//                          executor: softdog, A1/A2, kill(1, 38), pmsg,
//                          sysrq) and --gate; no stdin tick input at all;
//   -DFS_DEVICE -DFS_LOGONLY  T1 log-only build: reads and logs, writes no
//                          device node, opens no softdog, forks no actuator;
//   -DFS_TRIAL             adds --trial-override / --batt-absent (trial
//                          images only; the product build has neither).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "metacfg_record.h"
#include "sha256.h"
#include "thermald.h"
#include "thermald_accept.h"
#include "thermald_exec.h"
#include "fst_record.h"

#ifndef SCHED_RESET_ON_FORK
#define SCHED_RESET_ON_FORK 0x40000000
#endif
#define HELPER_DEADLINE_MS 2000

#if defined(FS_TEST)
static const char banner[] = "fs-thermald: test build (simulation and exec-sim), no device mode";
#elif defined(FS_DEVICE) && defined(FS_LOGONLY)
static const char banner[] = "fs-thermald: device log-only build (T1)";
#elif defined(FS_DEVICE)
static const char banner[] = "fs-thermald: device build";
#else
#error "build with -DFS_TEST or -DFS_DEVICE"
#endif
static const char *g_root = "";
static int g_verbose;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "fs-thermald: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static int64_t boot_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ===================== fs-metacfg spawn and bounded wait (§4.5.2) ===================== */
static uint8_t g_rec[MC_MAX_RECORD];
static size_t g_reclen;
static pid_t g_helper = -1;
static int64_t g_helper_t0;

/* returns 0 complete record; 1 timeout; 2 bad record */
static int run_helper(const char *path, const char *device, char *const *extra, int nextra, int pin_before)
{
    int pfd[2], pidfd = -1, rc = 2;
    int64_t t0, deadline;
    size_t want = MC_HDR;
    int have_hdr = 0;
    struct sched_param sp = {0};
    sigset_t all;

    sigfillset(&all);
    sigprocmask(SIG_BLOCK, &all, NULL); /* the supervisor blocks every blockable signal (§5.1) */
    if (pin_before) {                    /* test: show that the child resets affinity */
        cpu_set_t one;
        CPU_ZERO(&one);
        CPU_SET(0, &one);
        sched_setaffinity(0, sizeof one, &one);
    }
    /* second barrier (F39): policy reset on fork, still SCHED_OTHER here */
    if (sched_setscheduler(0, SCHED_OTHER | SCHED_RESET_ON_FORK, &sp))
        logf_("SCHED_RESET_ON_FORK not set: %s", strerror(errno));
    if (pipe2(pfd, O_CLOEXEC))
        return 2;
    t0 = boot_ms();
    g_helper_t0 = t0;
    deadline = t0 + HELPER_DEADLINE_MS;
    g_helper = fork();
    if (g_helper < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return 2;
    }
    if (g_helper == 0) {
        /* child: affinity all CPUs, empty mask, only fd 3, rlimits, exec */
        cpu_set_t allc;
        sigset_t none;
        struct rlimit r;
        char *argv[16];
        char *envp[] = {NULL};
        int i, a = 0;
        long maxfd = sysconf(_SC_OPEN_MAX);
        CPU_ZERO(&allc);
        for (i = 0; i < CPU_SETSIZE; i++)
            CPU_SET(i, &allc);
        sched_setaffinity(0, sizeof allc, &allc);
        if (dup2(pfd[1], 3) != 3)
            _exit(127);
        for (i = 0; i < maxfd && i < 65536; i++)
            if (i != 3)
                close(i);
        r.rlim_cur = r.rlim_max = 32ul << 20;
        setrlimit(RLIMIT_AS, &r);
        r.rlim_cur = 1;
        r.rlim_max = 2;
        setrlimit(RLIMIT_CPU, &r);
        r.rlim_cur = r.rlim_max = 0;
        setrlimit(RLIMIT_FSIZE, &r);
        r.rlim_cur = r.rlim_max = 16;
        setrlimit(RLIMIT_NOFILE, &r);
        r.rlim_cur = r.rlim_max = 0;
        setrlimit(RLIMIT_NPROC, &r);
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        argv[a++] = (char *)path;
        argv[a++] = (char *)device;
        argv[a++] = "3";
        for (i = 0; i < nextra && a < 15; i++)
            argv[a++] = extra[i];
        argv[a] = NULL;
        execve(path, argv, envp);
        _exit(127);
    }
    close(pfd[1]);
    pidfd = (int)syscall(SYS_pidfd_open, g_helper, 0);
    g_reclen = 0;
    for (;;) {
        struct pollfd pf[2];
        int npf = 1, pr;
        int64_t now = boot_ms();
        struct timespec ts;
        ssize_t r;
        if (now >= deadline) {
            rc = 1;
            break;
        }
        ts.tv_sec = (deadline - now) / 1000;
        ts.tv_nsec = ((deadline - now) % 1000) * 1000000;
        pf[0].fd = pfd[0];
        pf[0].events = POLLIN;
        if (pidfd >= 0) {
            pf[1].fd = pidfd;
            pf[1].events = POLLIN;
            npf = 2;
        }
        pr = ppoll(pf, (nfds_t)npf, &ts, NULL);
        if (pr <= 0)
            continue;
        if (!(pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            /* only the pidfd fired: the helper exited; drain what is left */
            if (pidfd >= 0 && (pf[1].revents & POLLIN)) {
                close(pidfd);
                pidfd = -1;
            }
            continue;
        }
        r = read(pfd[0], g_rec + g_reclen, want - g_reclen);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0) { /* EOF or error before the framed length */
            rc = 2;
            break;
        }
        g_reclen += (size_t)r;
        if (g_reclen == want) {
            if (!have_hdr) {
                long rest = rec_expect(g_rec);
                if (rest < 0) {
                    rc = 2;
                    break;
                }
                have_hdr = 1;
                want = MC_HDR + (size_t)rest;
                if (want == g_reclen) {
                    rc = 0;
                    break;
                }
            } else {
                rc = 0;
                break;
            }
        }
    }
    if (rc != 0)
        kill(g_helper, SIGKILL); /* never waited on: reaped later with WNOHANG */
    close(pfd[0]);
    if (pidfd >= 0)
        close(pidfd);
    logf_("helper done: rc=%d after %lld ms", rc, (long long)(boot_ms() - t0));
    return rc;
}

static void reap_helper(int64_t now)
{
    static int logged;
    siginfo_t si;
    if (g_helper <= 0)
        return;
    memset(&si, 0, sizeof si);
    if (waitid(P_PID, (id_t)g_helper, &si, WEXITED | WNOHANG) == 0 && si.si_pid == g_helper) {
        logf_("helper reaped");
        g_helper = -1;
        return;
    }
    if (!logged && now - g_helper_t0 > 60000) {
        logged = 1;
        logf_("helper still unreaped after 60 s"); /* also to /dev/pmsg0 on a device */
    }
}

/* ===================== sysfs I/O layer ===================== */
struct io {
    int zfd[MAXS];
    int psy[5]; /* temp volt curr cap status */
    int usb;
    int adsp;
    int fan_present, rpm, pwm, cur, max;
    int pol_max[4], pol_gov[4], pol_min[4];
    int32_t pol_written[4];
    int gpu;
    int state;
    char simdir[512];
};

static int openat_root(const char *rel, int flags)
{
    char p[1024];
    snprintf(p, sizeof p, "%s%s", g_root, rel);
    return open(p, flags | O_CLOEXEC, 0644);
}

/* read a small decimal or text file with pread at offset 0 */
static int rd_text(int fd, char *buf, int cap)
{
    ssize_t n;
    if (fd < 0)
        return -1;
    n = pread(fd, buf, (size_t)cap - 1, 0);
    if (n < 0)
        return -1;
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' '))
        buf[--n] = 0;
#ifdef FS_TEST
    if (!strcmp(buf, "!EIO"))
        return -1; /* simulated read error (fixtures only) */
    if (!strcmp(buf, "!HANG"))
        for (;;)
            pause(); /* simulated read that never returns (fixtures only) */
#endif
    return (int)n;
}

static struct rd rd_num(int fd)
{
    struct rd r = {RD_ABSENT, 0};
    char b[64], *e;
    long v;
    if (fd < 0)
        return r;
    if (rd_text(fd, b, sizeof b) <= 0) {
        r.st = RD_ERR;
        return r;
    }
    errno = 0;
    v = strtol(b, &e, 10);
    if (*e || errno || v > INT32_MAX || v <= INT32_MIN) {
        r.st = RD_ERR;
        return r;
    }
    r.st = RD_NUM;
    r.v = (int32_t)v;
    return r;
}

static int wr_text(int fd, const char *s)
{
    size_t l = strlen(s);
    if (fd < 0)
        return -1;
    /* fixture files need the truncation; sysfs attributes ignore it */
    if (ftruncate(fd, 0)) {
    }
    return pwrite(fd, s, l, 0) == (ssize_t)l ? 0 : -1;
}

static int __attribute__((unused)) file_exists(const char *dir, const char *f)
{
    char p[700];
    struct stat st;
    snprintf(p, sizeof p, "%s/%s", dir, f);
    return stat(p, &st) == 0;
}

/* a write to one of our owned nodes; in test builds a marker file
 * <root>/sim/erofs-<name> makes it fail like a driver error */
static char g_simdir[600];
static int wr_node(int fd, const char *name, const char *s)
{
#ifdef FS_TEST
    char m[64], cp[700], cb[32];
    int cfd;
    snprintf(m, sizeof m, "erofs-%s", name);
    if (g_simdir[0] && file_exists(g_simdir, m))
        return -1;
    snprintf(m, sizeof m, "hang-%s", name); /* a sysfs write stuck in the driver (fixtures only) */
    if (g_simdir[0] && file_exists(g_simdir, m))
        for (;;)
            pause();
    /* clamp-<name>: the node keeps min(value, clamp), like a lower QoS limit */
    snprintf(cp, sizeof cp, "%s/clamp-%s", g_simdir, name);
    cfd = g_simdir[0] ? open(cp, O_RDONLY | O_CLOEXEC) : -1;
    if (cfd >= 0) {
        ssize_t n = read(cfd, cb, sizeof cb - 1);
        close(cfd);
        if (n > 0) {
            long cl, v;
            cb[n] = 0;
            cl = strtol(cb, NULL, 10);
            v = strtol(s, NULL, 10);
            if (v > cl) {
                snprintf(cb, sizeof cb, "%ld", cl);
                return wr_text(fd, cb);
            }
        }
    }
#else
    (void)name;
#endif
    return wr_text(fd, s);
}

/* `val` "*SUFFIX" matches a name equal to SUFFIX or ending in ".SUFFIX"
 * (EXEC-SPEC E-32: the ADSP rproc is named after its platform device,
 * "3000000.remoteproc-adsp" on v2.7, remoteproc_sysfs.c name = pdev->name);
 * any other `val` must match exactly */
static int name_match(const char *name, const char *val)
{
    size_t n, v;
    if (val[0] != '*')
        return !strcmp(name, val);
    val++;
    n = strlen(name);
    v = strlen(val);
    if (n == v)
        return !strcmp(name, val);
    return n > v && name[n - v - 1] == '.' && !strcmp(name + n - v, val);
}

/* find a class dir whose `attr` file matches `val` (name_match); returns the dir path */
static int find_class(const char *cls, const char *prefix, const char *attr, const char *val, char *out, size_t cap)
{
    char d[1024], p[1200], b[128];
    DIR *dir;
    struct dirent *e;
    snprintf(d, sizeof d, "%s%s", g_root, cls);
    dir = opendir(d);
    if (!dir)
        return -1;
    while ((e = readdir(dir))) {
        int fd;
        if (e->d_name[0] == '.' || strncmp(e->d_name, prefix, strlen(prefix)))
            continue;
        snprintf(p, sizeof p, "%s/%s/%s", d, e->d_name, attr);
        fd = open(p, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        if (rd_text(fd, b, sizeof b) >= 0 && name_match(b, val)) {
            close(fd);
            snprintf(out, cap, "%s/%s", d, e->d_name);
            closedir(dir);
            return 0;
        }
        close(fd);
    }
    closedir(dir);
    return -1;
}

static int open_in(const char *dir, const char *f, int flags)
{
    char p[1400];
    snprintf(p, sizeof p, "%s/%s", dir, f);
    return open(p, flags | O_CLOEXEC);
}

/* start-up: open every node once (design §3.3: no path lookups later) and
 * read the fan zones' trips from sysfs (they are the source, §4.5.1). */
/* E-33 (CORE-SPEC K-50): a PMIC die channel is the IIO attribute
 * in_temp_<label>_input (milli-degC, a processed read triggers one ADC
 * conversion) of exactly one /sys/bus/iio/devices/iio:deviceN; the device
 * number is not fixed, the label is. 0 found (path in out), -1 none, -2 more than one */
static int find_iio(const char *label, char *out, size_t cap)
{
    char d[1024], p[1400];
    DIR *dir;
    struct dirent *e;
    struct stat st;
    int n = 0;
    snprintf(d, sizeof d, "%s/sys/bus/iio/devices", g_root);
    dir = opendir(d);
    if (!dir)
        return -1;
    while ((e = readdir(dir))) {
        if (strncmp(e->d_name, "iio:device", 10))
            continue;
        snprintf(p, sizeof p, "%s/%s/in_temp_%s_input", d, e->d_name, label);
        if (stat(p, &st) == 0 && S_ISREG(st.st_mode)) {
            if (!n)
                snprintf(out, cap, "%s", p);
            n++;
        }
    }
    closedir(dir);
    return n == 1 ? 0 : n ? -2 : -1;
}

static void io_open(struct io *io, struct conf *c)
{
    char d[1300];
    int i, j;
    memset(io, -1, sizeof *io);
    for (i = 0; i < c->ns; i++) {
        io->zfd[i] = -1;
        if (c->s[i].kind == K_IIO) {
            int r = find_iio(c->s[i].name, d, sizeof d);
            if (!r)
                io->zfd[i] = open(d, O_RDONLY | O_CLOEXEC);
            if (io->zfd[i] < 0)
                logf_("iio channel %s %s", c->s[i].name, r == -2 ? "ambiguous (more than one device): not used" : "missing");
            continue;
        }
        if (c->s[i].kind != K_ZONE && c->s[i].kind != K_AUX)
            continue;
        if (!find_class("/sys/class/thermal", "thermal_zone", "type", c->s[i].name, d, sizeof d))
            io->zfd[i] = open_in(d, "temp", O_RDONLY);
        if (io->zfd[i] < 0)
            logf_("zone %s missing", c->s[i].name);
    }
    /* K-25: a missing, short, unreadable or different fan zone is a zone
     * fault (F8); the rule keeps the table's trips and fan control goes on */
    for (i = 0; i < c->nr; i++) {
        struct frule *r = &c->r[i];
        if (find_class("/sys/class/thermal", "thermal_zone", "type", r->zone, d, sizeof d)) {
            logf_("fan zone %s missing: zone fault F8 (table trips used)", r->zone);
            c->zone_fault = 1;
            continue;
        }
        for (j = 0; j < r->ntrips; j++) {
            char f[64];
            int fd;
            struct rd t, h;
            snprintf(f, sizeof f, "trip_point_%d_temp", j);
            fd = open_in(d, f, O_RDONLY);
            t = rd_num(fd);
            if (fd >= 0)
                close(fd);
            snprintf(f, sizeof f, "trip_point_%d_hyst", j);
            fd = open_in(d, f, O_RDONLY);
            h = rd_num(fd);
            if (fd >= 0)
                close(fd);
            if (t.st != RD_NUM || h.st != RD_NUM) {
                logf_("fan zone %s trip %d unreadable: zone fault F8", r->zone, j);
                c->zone_fault = 1;
                continue;
            }
            if (t.v != r->t[j] || h.v != r->h[j]) { /* TCD §3.3: asserted equal to the table */
                logf_("fan zone %s trip %d = %d/%d, table %d/%d: zone fault F8", r->zone, j, t.v, h.v, r->t[j],
                      r->h[j]);
                c->zone_fault = 1;
            }
        }
    }
    snprintf(d, sizeof d, "%s/sys/class/power_supply/battery", g_root);
    io->psy[0] = open_in(d, "temp", O_RDONLY);
    io->psy[1] = open_in(d, "voltage_now", O_RDONLY);
    io->psy[2] = open_in(d, "current_now", O_RDONLY);
    io->psy[3] = open_in(d, "capacity", O_RDONLY);
    io->psy[4] = open_in(d, "status", O_RDONLY);
    snprintf(d, sizeof d, "%s/sys/class/power_supply/usb", g_root);
    io->usb = open_in(d, "online", O_RDONLY);
    io->adsp = -1;
    if (!find_class("/sys/class/remoteproc", "remoteproc", "name", "*remoteproc-adsp", d, sizeof d) ||
        !find_class("/sys/class/remoteproc", "remoteproc", "name", "adsp", d, sizeof d))
        io->adsp = open_in(d, "state", O_RDONLY);
    io->fan_present = 0;
    io->rpm = io->pwm = io->cur = io->max = -1;
    if (!find_class("/sys/class/hwmon", "hwmon", "name", "pwmfan", d, sizeof d)) {
        int fd;
        struct rd v;
        io->fan_present = 1;
        io->rpm = open_in(d, "rpm", O_RDWR);
        io->pwm = open_in(d, "pwm", O_RDONLY);
        fd = open_in(d, "rpm_per_sec", O_RDONLY); /* v2.7 only; v66 has no ramp */
        v = rd_num(fd);
        if (v.st != RD_NUM)
            c->rpm_per_sec = 0; /* no ramp attribute (v66) */
        else if (v.v >= 50 && v.v <= 2000)
            c->rpm_per_sec = v.v;
        else /* K-24 (d): out of bounds, keep the table value */
            logf_("hwmon rpm_per_sec %d out of 50..2000: table value %d kept", v.v, c->rpm_per_sec);
        if (fd >= 0)
            close(fd);
        fd = open_in(d, "silent_rpm", O_RDONLY);
        v = rd_num(fd);
        if (v.st == RD_NUM)
            c->silent_rpm = v.v;
        if (fd >= 0)
            close(fd);
    }
    if (!find_class("/sys/class/thermal", "cooling_device", "type", "pwm-tach-fan0", d, sizeof d)) {
        io->cur = open_in(d, "cur_state", O_RDONLY);
        io->max = open_in(d, "max_state", O_RDONLY);
    }
    for (i = 0; i < c->npol; i++) { /* K-30: policies from the table */
        snprintf(d, sizeof d, "%s/sys/devices/system/cpu/cpufreq/policy%d", g_root, c->pol[i]);
        io->pol_max[i] = open_in(d, "scaling_max_freq", O_RDWR);
        io->pol_gov[i] = open_in(d, "scaling_governor", O_RDWR);
        io->pol_min[i] = open_in(d, "cpuinfo_min_freq", O_RDONLY);
        io->pol_written[i] = -1;
    }
    snprintf(d, sizeof d, "%s/sys/class/kgsl/kgsl-3d0", g_root);
    io->gpu = open_in(d, "max_pwrlevel", O_RDWR);
    if (io->gpu < 0 && c->has_gpu) {
        logf_("kgsl absent: GPU caps skipped"); /* thermal-control-design §4.2 */
        c->has_gpu = 0;
    }
    snprintf(d, sizeof d, "%s/sim", g_root);
    snprintf(io->simdir, sizeof io->simdir, "%s", d);
    snprintf(g_simdir, sizeof g_simdir, "%s", d);
    snprintf(d, sizeof d, "%s/run/fs-thermald", g_root);
    mkdir(d, 0755);
    io->state = openat_root("/run/fs-thermald/state", O_RDWR | O_CREAT);
}


static int status_code(const char *s)
{
    if (!strcmp(s, "Charging"))
        return ST_CHARGING;
    if (!strcmp(s, "Discharging"))
        return ST_DISCHARGING;
    if (!strcmp(s, "Not charging"))
        return ST_NOTCHARGING;
    if (!strcmp(s, "Full"))
        return ST_FULL;
    return ST_UNKNOWN;
}

static void io_read(struct io *io, const struct conf *c, int64_t t, struct tick_in *in, int fan_wr_err, int cap_fail)
{
    char b[64];
    int i, fd;
    memset(in, 0, sizeof *in);
    in->t = t;
    for (i = 0; i < c->ns; i++)
        in->s[i] = rd_num(io->zfd[i]);
    in->psy_temp = rd_num(io->psy[0]);
    in->psy_volt = rd_num(io->psy[1]);
    in->psy_curr = rd_num(io->psy[2]);
    in->psy_cap = rd_num(io->psy[3]);
    in->psy_status = rd_text(io->psy[4], b, sizeof b) < 0 ? ST_ERR : status_code(b);
    in->usb_online = rd_num(io->usb);
    if (io->adsp < 0)
        in->adsp = -1;
    else if (rd_text(io->adsp, b, sizeof b) < 0)
        in->adsp = -1;
    else
        in->adsp = !strcmp(b, "running");
    in->fan_absent = !io->fan_present;
    in->rpm = rd_num(io->rpm);
    in->pwm = rd_num(io->pwm);
    in->cur = rd_num(io->cur);
    in->max = rd_num(io->max);
    in->fan_wr_err = fan_wr_err;
    in->cap_fail = cap_fail;
    (void)fd;
#if defined(FS_TEST)
    /* --sim (part 1) only: the executor's inputs come from marker files;
     * with an executor (--exec-sim, --run) exec_inputs() overrides them */
    in->shutdown_byte = file_exists(io->simdir, "shutdown_byte");
    in->a1_done = file_exists(io->simdir, "a1_done");
    in->a2_exited = file_exists(io->simdir, "a2_exited");
    in->pstore_marker = file_exists(io->simdir, "pstore_marker");
    fd = openat_root("/proc/1/comm", O_RDONLY);
    if (fd >= 0) {
        in->pid1_shutdown = rd_text(fd, b, sizeof b) >= 0 && !strcmp(b, "systemd-shutdow");
        close(fd);
    }
#endif
}

/* governor + the not-ready (tier-3) caps at start-up, read back (C-29) */
static int io_start_caps(struct io *io, const struct conf *c)
{
    int i, ok = 1;
    char b[32], v[32];
    if (!c->has_caps)
        return 1;
    for (i = 0; i < c->npol; i++) {
        char nm[16];
        struct rd mn = rd_num(io->pol_min[i]);
        int32_t want = c->cpu[3] == -1 ? (mn.st == RD_NUM ? mn.v : -1) : c->cpu[3];
        snprintf(nm, sizeof nm, "policy%d", c->pol[i]);
        if (wr_text(io->pol_gov[i], "schedutil") || rd_text(io->pol_gov[i], b, sizeof b) < 0 || strcmp(b, "schedutil"))
            logf_("%s governor not schedutil (kept performance, cap kept)", nm);
        if (want < 0) {
            ok = 0;
            continue;
        }
        snprintf(v, sizeof v, "%d", want);
        if (wr_node(io->pol_max[i], nm, v)) {
            ok = 0;
        } else {
            struct rd rb = rd_num(io->pol_max[i]); /* S-2 */
            if (rb.st != RD_NUM || rb.v > want)
                ok = 0;
            else
                io->pol_written[i] = want;
        }
    }
    return ok;
}

/* apply one tick; returns fan write error and cap failure for the next tick */
static void io_apply(struct io *io, const struct conf *c, const struct tick_out *o, int *fan_wr_err, int *cap_fail,
                     int fan_on)
{
    char v[32], b[32];
    int i;
    *fan_wr_err = 0;
    *cap_fail = 0;
    if (fan_on && o->fan >= 0) {
        snprintf(v, sizeof v, "%d", o->fan);
        if (!io->fan_present || wr_node(io->rpm, "rpm", v))
            *fan_wr_err = 1;
    }
    if (c->has_caps && o->cpu != -2) {
        for (i = 0; i < c->npol; i++) {
            int32_t want;
            char nm[16];
            struct rd mn = rd_num(io->pol_min[i]);
            struct rd cur = rd_num(io->pol_max[i]);
            snprintf(nm, sizeof nm, "policy%d", c->pol[i]);
            /* K-30: only a value above ours is another writer */
            if (io->pol_written[i] >= 0 && cur.st == RD_NUM && cur.v > io->pol_written[i])
                logf_("owner-conflict %s: read %d, ours %d (re-asserted)", nm, cur.v, io->pol_written[i]);
            want = o->cpu_min ? (mn.st == RD_NUM ? mn.v : -1) : o->cpu;
            if (want >= 0) {
                snprintf(v, sizeof v, "%d", want);
                /* K-30: an effective value at or below ours is accepted */
                if (!wr_node(io->pol_max[i], nm, v)) {
                    struct rd rb = rd_num(io->pol_max[i]); /* S-2 */
                    if (rb.st == RD_NUM && rb.v <= want) {
                        io->pol_written[i] = want;
                        continue;
                    }
                }
            }
            /* thermal-control-design §4.1: fall back to cpuinfo_min_freq */
            if (mn.st == RD_NUM) {
                snprintf(v, sizeof v, "%d", mn.v);
                if (!wr_node(io->pol_max[i], nm, v)) {
                    struct rd rb = rd_num(io->pol_max[i]); /* S-2 */
                    if (rb.st == RD_NUM && rb.v <= mn.v) {
                        io->pol_written[i] = mn.v;
                        logf_("%s cap fallback to cpuinfo_min_freq", nm);
                        continue;
                    }
                }
            }
            *cap_fail = 1;
        }
    }
    if (c->has_gpu && o->gpu >= 0) {
        snprintf(v, sizeof v, "%d", o->gpu);
        if (wr_node(io->gpu, "gpu", v) || rd_text(io->gpu, b, sizeof b) < 0 || strcmp(b, v)) {
            snprintf(v, sizeof v, "%d", c->gpu[5]);
            if (wr_node(io->gpu, "gpu", v))
                *cap_fail = 1;
        }
    }
}

static void io_state(struct io *io, const struct conf *c, const char *line, const struct accept_info *ai)
{
    char s[8192];
    snprintf(s, sizeof s, "limits=%s reason=%s json_sha256=%s vr_export=%d\n%s\n", c->limits,
             c->reason[0] ? c->reason : "-", ai && ai->json_sha[0] ? ai->json_sha : "-", c->vr_export, line);
    if (wr_text(io->state, s))
        logf_("state file write failed");
}

/* ===================== main ===================== */
#ifdef FS_TEST
/* test builds only: an extra known-firmware row LABEL:DEVICE:INCR:JSONSHA:DIGEST:VRSHA,
 * so synthetic records can reach the A-5 .. A-7 checks */
static struct krow g_trows[4];
static int g_ntrows;
static char g_trbuf[4][512];
static void test_row(const char *spec)
{
    char *f[6], *p;
    int n = 0;
    if (g_ntrows == 4)
        return;
    snprintf(g_trbuf[g_ntrows], sizeof g_trbuf[0], "%s", spec);
    p = g_trbuf[g_ntrows];
    f[n++] = p;
    while (*p && n < 6)
        if (*p++ == ':') {
            p[-1] = 0;
            f[n++] = p;
        }
    if (n != 6)
        return;
    g_trows[g_ntrows].label = f[0];
    g_trows[g_ntrows].incr = f[2];
    g_trows[g_ntrows].json_sha = f[3];
    g_trows[g_ntrows].digest = f[4];
    g_trows[g_ntrows].vr_sha = f[5];
    g_trows[g_ntrows].json_size = 0;
    (void)f[1];
    g_ntrows++;
}
#endif

static void usage(void)
{
    fprintf(stderr,
            "%s\n"
            "usage: fs-thermald --device eureka|hollywood [--record FILE | --metacfg PATH [--metacfg-arg A]...]\n"
            "         [--stage] [--headless-fan] [--p15] [--j145] [--pin-before-spawn]\n"
#if defined(FS_TRIAL) || defined(FS_TEST)
            "         [--trial-override] [--batt-absent]\n"
#endif
#if defined(FS_DEVICE)
            "         [--softdog] [--require-softdog] [--step-pgid-file F] [--wait-zones MS] [--pstore DIR]\n"
            "         (--dump-config | --accept-only | --run | --gate)\n",
#else
            "         [--root DIR] [--softdog] [--require-softdog] [--step-pgid-file F] [--test-pid1 PID] [--pstore DIR]\n"
            "         (--dump-config | --accept-only | --sim | --exec-sim | --gate | --exec-gate)\n",
#endif
            banner);
    exit(2);
}

/* the previous boot's FST1 records (design §6.2, O19; EXEC-SPEC E-22) */
static int read_pstore(const char *dir, char *last, size_t cap, int *marker)
{
    char p[1024];
    static char buf[262144];
    struct fst r;
    ssize_t n;
    int fd;
    *marker = 0;
    snprintf(last, cap, "-");
    if (!dir)
        return 0;
    snprintf(p, sizeof p, "%s%s/pmsg-ramoops-0", g_root, dir);
    fd = open(p, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return 0;
    {   /* review m6: the newest records are at the end; read it all */
        size_t got = 0;
        ssize_t k;
        while (got < sizeof buf && (k = read(fd, buf + got, sizeof buf - got)) > 0)
            got += (size_t)k;
        n = (ssize_t)got;
    }
    close(fd);
    if (n <= 0)
        return 0;
    if (fst_scan(buf, (size_t)n, &r, marker) <= 0)
        return 0;
    if (*marker) {
        const char *hv = strchr(r.hot, ':');
        snprintf(last, cap, "%s:%s", r.reason, strcmp(r.value, "-") ? r.value : hv ? hv + 1 : "-");
    }
    return 1;
}

/* device: stdout/stderr must never block the loop (EXEC-SPEC E-29) */
static void safe_stdio(void)
{
#if defined(FS_DEVICE)
    int fd;
    for (fd = 1; fd <= 2; fd++) {
        struct stat st;
        struct statfs sf;
        if (fstat(fd, &st) == 0 &&
            ((S_ISREG(st.st_mode) && fstatfs(fd, &sf) == 0 && sf.f_type == 0x01021994 /* TMPFS_MAGIC */) ||
             (S_ISCHR(st.st_mode) && st.st_rdev == (dev_t)makedev(1, 3))))
            continue; /* E-29 (review m7): a file on a disk filesystem can block in writeback */
        {
            int n = open("/dev/null", O_WRONLY | O_CLOEXEC);
            if (n >= 0) {
                dup2(n, fd);
                close(n);
            }
        }
    }
#endif
}

#if defined(FS_DEVICE)
/* H-1 / Q6: wait (bounded) for the counted zones of an async probe; the
 * self-test then names any that never appeared */
static void wait_zones(const struct conf *c, int ms)
{
    int64_t end = boot_ms() + ms;
    for (;;) {
        int i, missing = 0;
        char d[1300];
        for (i = 0; i < c->ns; i++)
            if ((c->s[i].kind == K_ZONE &&
                 find_class("/sys/class/thermal", "thermal_zone", "type", c->s[i].name, d, sizeof d)) ||
                (c->s[i].kind == K_IIO && find_iio(c->s[i].name, d, sizeof d)))
                missing++;
        if (!missing) {
            logf_("zones: all present");
            return;
        }
        if (boot_ms() >= end) {
            logf_("zones: %d missing after %d ms (self-test names them)", missing, ms);
            return;
        }
        usleep(200000);
    }
}
#endif

struct loopctx {
    struct io *io;
    struct conf *c;
    struct core *k;
    struct exec *x; /* NULL: --sim (actions printed only) */
    const struct accept_info *ai;
    int fan_wr_err, cap_fail, caps_ok, fan_on, writes;
};

/* one supervisor cycle (EXEC-SPEC E-15 order) */
static void one_tick(struct loopctx *L, int64_t t, char *out, int cap, struct tick_in *in, struct tick_out *o)
{
    reap_helper(t);
    io_read(L->io, L->c, t, in, L->fan_wr_err, L->cap_fail);
    if (L->x)
        exec_inputs(L->x, in);
    in->caps_ok_at_start = L->caps_ok;
    core_tick(L->k, in, o);
    out_line(o, t, out, cap);
    if (L->x)
        exec_timeline(L->x, L->c, in, o, t); /* signal, actuators, final pet, sysrq: never behind a sysfs write */
    if (L->writes)
        io_apply(L->io, L->c, o, &L->fan_wr_err, &L->cap_fail, L->fan_on);
    else
        L->fan_wr_err = L->cap_fail = 0;
    io_state(L->io, L->c, out, L->ai);
    if (L->x) {
        exec_publish(L->x, o, t);
        exec_pet(L->x, o, t); /* only after a complete cycle */
    }
}

int main(int argc, char **argv)
{
    const char *device = NULL, *recfile = NULL, *helper = NULL, *pstore = NULL, *stepf = NULL;
    char *hargs[12];
    int nh = 0, i, mode = 0, stage = 0, tro = 0, headless = 0, battabs = 0, p15 = 0, j145 = 0, pin = 0;
    int softdog = 0, reqdog = 0, testpid1 = 0, waitms = 10000;
    const struct devtab *dt;
    struct recview v;
    struct accept_info ai;
    const char *reason = NULL;
    static struct conf c;
    static struct core k;
    static struct exec x;
    struct io io;
    int accepted = 0, have_rec = 0;
    (void)testpid1;
    (void)waitms;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc)
            device = argv[++i];
#if defined(FS_TEST)
        else if (!strcmp(argv[i], "--root") && i + 1 < argc)
            g_root = argv[++i];
        else if (!strcmp(argv[i], "--test-pid1") && i + 1 < argc)
            testpid1 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--sim"))
            mode = 3;
        else if (!strcmp(argv[i], "--exec-sim"))
            mode = 5;
        else if (!strcmp(argv[i], "--exec-gate"))
            mode = 6;
        else if (!strcmp(argv[i], "--test-row") && i + 1 < argc)
            test_row(argv[++i]);
        else if (!strcmp(argv[i], "--fst-scan") && i + 1 < argc) {
            /* tests: the FST1 scanner on a file (differential with tools/ref/fst_ref.py) */
            static char buf[65536];
            struct fst r;
            int mk = 0, cnt;
            FILE *f = fopen(argv[++i], "rb");
            size_t n = f ? fread(buf, 1, sizeof buf, f) : 0;
            if (f)
                fclose(f);
            memset(&r, 0, sizeof r);
            cnt = fst_scan(buf, n, &r, &mk);
            if (cnt > 0)
                printf("count=%d marker=%d ev=%s t=%lld reason=%s sensor=%s value=%s hot=%s why=%s cd=%d\n", cnt, mk,
                       r.ev, r.t, r.reason, r.sensor, r.value, r.hot, r.why, r.cd);
            else
                printf("count=0 marker=0\n");
            return 0;
        }
#endif
#if defined(FS_DEVICE)
        else if (!strcmp(argv[i], "--run"))
            mode = 7;
        else if (!strcmp(argv[i], "--wait-zones") && i + 1 < argc)
            waitms = atoi(argv[++i]);
#endif
        else if (!strcmp(argv[i], "--record") && i + 1 < argc)
            recfile = argv[++i];
        else if (!strcmp(argv[i], "--metacfg") && i + 1 < argc)
            helper = argv[++i];
        else if (!strcmp(argv[i], "--metacfg-arg") && i + 1 < argc && nh < 12)
            hargs[nh++] = argv[++i];
        else if (!strcmp(argv[i], "--stage"))
            stage = 1;
#if defined(FS_TRIAL) || defined(FS_TEST)
        else if (!strcmp(argv[i], "--trial-override"))
            tro = 1;
        else if (!strcmp(argv[i], "--batt-absent"))
            battabs = 1;
#endif
        else if (!strcmp(argv[i], "--headless-fan"))
            headless = 1;
        else if (!strcmp(argv[i], "--p15"))
            p15 = 1;
        else if (!strcmp(argv[i], "--j145"))
            j145 = 1;
        else if (!strcmp(argv[i], "--pin-before-spawn"))
            pin = 1;
        else if (!strcmp(argv[i], "--softdog"))
            softdog = 1;
        else if (!strcmp(argv[i], "--require-softdog"))
            reqdog = 1;
        else if (!strcmp(argv[i], "--step-pgid-file") && i + 1 < argc)
            stepf = argv[++i];
        else if (!strcmp(argv[i], "--pstore") && i + 1 < argc)
            pstore = argv[++i];
        else if (!strcmp(argv[i], "--verbose"))
            g_verbose = 1;
        else if (!strcmp(argv[i], "--dump-config"))
            mode = 1;
        else if (!strcmp(argv[i], "--accept-only"))
            mode = 2;
        else if (!strcmp(argv[i], "--gate"))
            mode = 4;
        else
            usage();
    }
    if (!device || !mode)
        usage();
    if (battabs && !tro) {
        logf_("--batt-absent needs --trial-override (trial builds only)");
        return 2;
    }
    if (reqdog && !softdog) {
        logf_("--require-softdog needs --softdog");
        return 2;
    }
    if (mode == 7 || mode == 4)
        safe_stdio();
    if (mode >= 4) {
        /* design §5.1 / EXEC-SPEC E-12: every blockable signal is blocked from
         * the start (a write to a dead actuator's pipe gives EPIPE, never a
         * SIGPIPE death); SIGKILL and SIGSTOP are left to the softdog */
        sigset_t all;
        sigfillset(&all);
        sigprocmask(SIG_BLOCK, &all, NULL);
    }
    dt = dev_lookup(device);
    if (!dt) {
        logf_("no built-in set for %s: never READY (A-9)", device);
        return 3;
    }
#ifdef FS_TEST
    if (g_ntrows) { /* a copy of the device table with the test rows appended */
        static struct devtab tdt;
        static struct krow rows[MAXK + 4];
        int r;
        tdt = *dt;
        for (r = 0; r < dt->nkr; r++)
            rows[r] = dt->kr[r];
        for (r = 0; r < g_ntrows; r++)
            rows[dt->nkr + r] = g_trows[r];
        tdt.kr = rows;
        tdt.nkr = dt->nkr + g_ntrows;
        dt = &tdt;
    }
#endif

    /* start-up step 1: the record (helper spawn, or a file in tests) */
    if (helper) {
        int rc = run_helper(helper, device, hargs, nh, pin);
        if (rc == 1)
            reason = "reader-timeout";
        else if (rc == 2)
            reason = "reader-bad-record";
        else
            have_rec = 1;
    } else if (recfile) {
        FILE *f = fopen(recfile, "rb");
        if (!f) {
            reason = "reader-bad-record";
        } else {
            g_reclen = fread(g_rec, 1, sizeof g_rec, f);
            if (!feof(f))
                reason = "reader-bad-record";
            else
                have_rec = 1;
            fclose(f);
        }
    } else
        reason = "no-record";
    if (have_rec) {
        if (rec_view(g_rec, g_reclen, &v))
            reason = "reader-bad-record";
        else
            reason = rec_accept(dt, &v, &ai);
        if (!reason)
            accepted = 1;
    } else
        memset(&ai, 0, sizeof ai);
    if (conf_build(&c, dt, &v, accepted)) {
        logf_("internal: configuration build failed");
        return 4;
    }
    c.stage = stage;
    c.trial_override = tro;
    c.headless_fan = headless;
    c.batt_absent = battabs;
    c.p15 = p15;
    c.j145 = j145;
    c.vr_export = accepted && ai.vr_export;
    if (battabs)
        conf_drop_batt(&c);
    if (!accepted)
        snprintf(c.reason, sizeof c.reason, "%s", reason);
    logf_("%s", banner);
    logf_("limits=%s reason=%s%s%s", c.limits, accepted ? "-" : reason, ai.json_sha[0] ? " json_sha256=" : "",
          ai.json_sha);
    if (accepted && !ai.vr_export)
        logf_("NOTICE vr-list-unreviewed: VR-runtime list not exported");
    if (!accepted)
        logf_("NOTICE limits-builtin (%s)", reason); /* one-time user notice; not a WARN */
    if (ai.fault_record)
        logf_("FAULT digest-mismatch: parser defect suspected (fault record)");

    if (mode == 2) {
        printf("limits=%s reason=%s json_sha256=%s digest=%s vr_export=%d\n", c.limits, accepted ? "-" : reason,
               ai.json_sha[0] ? ai.json_sha : "-", ai.digest[0] ? ai.digest : "-", c.vr_export);
        return 0;
    }

    if (mode == 1 && !g_root[0]) { /* the built-in tables, no sysfs read */
        conf_dump(stdout, &c);
        return 0;
    }
#if defined(FS_DEVICE)
    if (mode == 7 || mode == 4) /* H-1 (review M5): the boot gate must not refuse on a probe still pending */
        wait_zones(&c, waitms);
#endif
    io_open(&io, &c);
    if (mode == 1) {
        conf_dump(stdout, &c);
        return 0;
    }

    {
        struct loopctx L;
        struct exec_cfg xc;
        char last[64];
        int marker = 0, use_exec = 0;
#if defined(FS_LOGONLY)
        int writes = 0;
#else
        int writes = 1;
#endif
        memset(&L, 0, sizeof L);
        memset(&xc, 0, sizeof xc);
        read_pstore(pstore, last, sizeof last, &marker);
        if (marker)
            logf_("pstore: previous boot ended in a thermal shutdown: %s", last);
        xc.stage = stage;
        xc.logonly = !writes;
        xc.softdog = softdog;
        xc.require_softdog = reqdog;
        xc.wd_margin = 30; /* P17 running margin */
        xc.wd_final = 30;  /* P17 M_final (provisional; re-sized from the T5 measurement) */
        xc.p15 = p15;
        xc.step_pgid_file = stepf;
        xc.gate = (mode == 4 || mode == 6);
#if defined(FS_TEST)
        xc.kind = EX_TEST;
        xc.root = g_root;
        xc.pid1 = testpid1;
        use_exec = (mode == 5 || mode == 6);
#else
        xc.kind = EX_DEVICE;
        xc.root = "";
        xc.pid1 = 1;
        use_exec = 1;
#endif
        if (use_exec && exec_start(&x, &xc, last)) {
            logf_("executor start failed");
            return 5;
        }
        L.io = &io;
        L.c = &c;
        L.k = &k;
        L.x = use_exec ? &x : NULL;
        L.ai = &ai;
        L.writes = writes;
        L.caps_ok = writes ? io_start_caps(&io, &c) : 1;
        L.fan_on = c.has_fan && writes;
        core_init(&k, &c);
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (mode == 4 || mode == 6) { /* gate: one evaluation */
            struct tick_in in;
            char out[16384];
            int64_t t = 0;
            int refuse;
#if defined(FS_TEST)
            char line[256];
            long long tt;
            if (!fgets(line, sizeof line, stdin) || sscanf(line, "tick %lld", &tt) != 1) {
                logf_("bad command");
                return 2;
            }
            t = tt;
#else
            t = boot_ms();
#endif
            io_read(&io, &c, t, &in, 0, 0);
            if (use_exec)
                in.pstore_marker = marker;
            in.caps_ok_at_start = L.caps_ok;
            refuse = core_gate(&k, &in, out, sizeof out);
            if (use_exec && marker)
                printf("%s last=%s\n", out, last);
            else
                printf("%s\n", out);
            if (refuse && use_exec) {
                const char *rs = strstr(out, "reasons=");
                char rb[64];
                snprintf(rb, sizeof rb, "%s", rs ? rs + 8 : "-");
                if (strchr(rb, ' '))
                    *strchr(rb, ' ') = 0;
                exec_gate_refuse(&x, &c, &in, rb, t);
                if (writes) { /* design §6.2 (review m3): fan top, minimum caps, before the power-off */
                    struct tick_out po;
                    int fe = 0, cf = 0;
                    memset(&po, 0, sizeof po);
                    po.fan = c.has_fan ? c.top : -1;
                    po.cpu_min = 1;
                    po.cpu = -1;
                    po.gpu = c.has_gpu ? c.gpu[5] : -1;
                    io_apply(&io, &c, &po, &fe, &cf, c.has_fan);
                    logf_("gate refusal: fan %d, CPU cpuinfo_min_freq, GPU level %d%s", po.fan, po.gpu,
                          fe || cf ? " (a write failed)" : "");
                }
            }
            return refuse ? 1 : 0;
        }
#if defined(FS_TEST)
        /* sim / exec-sim: ticks from stdin (fake CLOCK_BOOTTIME) */
        {
            char line[256];
            while (fgets(line, sizeof line, stdin)) {
                long long t;
                struct tick_in in;
                struct tick_out o;
                char out[16384];
                if (!strncmp(line, "quit", 4))
                    break;
                if (sscanf(line, "tick %lld", &t) != 1) {
                    logf_("bad command");
                    return 2;
                }
                one_tick(&L, t, out, sizeof out, &in, &o);
                if (L.x) /* the executor's inputs of this tick, for the differential (EXEC-SPEC §6) */
                    printf("in a1_done=%d a2_exited=%d shutdown_byte=%d pid1_shutdown=%d ready_pub=%d\n", in.a1_done,
                           in.a2_exited, in.shutdown_byte, in.pid1_shutdown, exec_ready(&x, &o));
                printf("%s\n", out);
            }
        }
        return 0;
#else
        /* device: 1 s CLOCK_BOOTTIME timerfd; never returns */
        {
            int tfd = timerfd_create(CLOCK_BOOTTIME, TFD_CLOEXEC);
            struct itimerspec its;
            int64_t last_print = -1000000;
            static char prev[16384];
            if (tfd < 0) {
                logf_("timerfd failed: no cycle, no pet (the softdog, if open, restarts the device)");
                for (;;)
                    pause();
            }
            memset(&its, 0, sizeof its);
            its.it_interval.tv_sec = 1;
            its.it_value.tv_sec = 1;
            timerfd_settime(tfd, 0, &its, NULL);
            for (;;) {
                uint64_t exp;
                struct tick_in in;
                struct tick_out o;
                static char out[16384];
                const char *rest;
                int64_t t;
                if (read(tfd, &exp, sizeof exp) != (ssize_t)sizeof exp)
                    continue;
                t = boot_ms();
                one_tick(&L, t, out, sizeof out, &in, &o);
                /* E-29: a line on every change, above tier 0, and at least every 5 s */
                rest = strchr(out, ' ');
                rest = rest ? rest : out;
                if (strcmp(rest, prev) || o.tier > 0 || t - last_print >= 5000) {
                    printf("%s ready_pub=%d\n", out, exec_ready(&x, &o));
                    snprintf(prev, sizeof prev, "%s", rest);
                    last_print = t;
                }
            }
        }
#endif
    }
    return 0;
}
