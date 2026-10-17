// SPDX-License-Identifier: Apache-2.0
// fs-thermald executor, part 2 (EXEC-SPEC.md). See thermald_exec.h for the
// three build kinds. Rule ids E-n are EXEC-SPEC.md's.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "fst_record.h"
#include "thermald_exec.h"

#if defined(FS_DEVICE) && defined(FS_TEST)
#error "FS_DEVICE and FS_TEST are exclusive"
#endif
#if defined(FS_DEVICE) && !defined(FS_LOGONLY)
#include <linux/watchdog.h>
#include "poweroff_final.h"
#if !defined(__aarch64__)
#error "device builds are aarch64 only"
#endif
#endif

#define A1_BYTE 0xA1 /* E-8: the only byte A1 acts on */
#define A2_BYTE 0xA2 /* E-8: the only byte A2 acts on */
#define DLOAD "/sys/module/qcom_dload_mode/parameters/download_mode"

static void pathof(const struct exec *x, char *out, size_t cap, const char *abs)
{
    snprintf(out, cap, "%s%s", x->c.kind == EX_TEST ? x->c.root : "", abs);
}

static int xopen(const struct exec *x, const char *abs, int flags, mode_t mode)
{
    char p[1024];
    pathof(x, p, sizeof p, abs);
    return open(p, flags | O_CLOEXEC, mode);
}

static int64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void exec_log(struct exec *x, int64_t t, const char *fmt, ...)
{
    char b[400];
    int n;
    va_list ap;
    va_start(ap, fmt);
    n = vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (n >= (int)sizeof b)
        n = (int)sizeof b - 1;
    fprintf(stderr, "fs-thermald: exec t=%lld %s\n", (long long)t, b);
    if (x->xlog >= 0) { /* tests: the executor log the suite checks (E-30) */
        char l[440];
        int m = snprintf(l, sizeof l, "t=%lld %s\n", (long long)t, b);
        if (m > 0 && write(x->xlog, l, (size_t)m) < 0) {
        }
    }
    if (x->kmsg >= 0) { /* device: kernel log, priority notice */
        char l[440];
        int m = snprintf(l, sizeof l, "<5>fs-thermald: t=%lld %s\n", (long long)t, b);
        if (m > 0 && write(x->kmsg, l, (size_t)m) < 0) {
        }
    }
}

static void hb_write(struct exec *x, int state, int64_t t);

static void withhold(struct exec *x, const char *why)
{
    if (x->ok) {
        x->ok = 0;
        snprintf(x->why, sizeof x->why, "%s", why);
    }
}

/* ---------------- softdog (E-1 .. E-6) ---------------- */

/* E-2: the softdog is opened only if download_mode reads exactly "0" */
static int dload_zero(struct exec *x, char *why, size_t cap)
{
    char b[16];
    int fd = xopen(x, DLOAD, O_RDONLY | O_NOFOLLOW, 0);
    ssize_t n;
    if (fd < 0) {
        snprintf(why, cap, "download_mode-unreadable");
        return 0;
    }
    n = pread(fd, b, sizeof b - 1, 0);
    close(fd);
    if (n <= 0) {
        snprintf(why, cap, "download_mode-unreadable");
        return 0;
    }
    b[n] = 0;
    if (n > 0 && b[n - 1] == '\n')
        b[--n] = 0;
    if (strcmp(b, "0")) {
        snprintf(why, cap, "download_mode-not-0");
        return 0;
    }
    return 1;
}

static int wd_settimeout(struct exec *x, int s)
{
#if defined(FS_TEST)
    char l[48];
    int n = snprintf(l, sizeof l, "settimeout %d\n", s);
    return write(x->wd, l, (size_t)n) == n ? 0 : -1;
#elif defined(FS_DEVICE) && !defined(FS_LOGONLY)
    int v = s;
    if (ioctl(x->wd, WDIOC_SETTIMEOUT, &v))
        return -1;
    v = 0;
    if (ioctl(x->wd, WDIOC_GETTIMEOUT, &v) || v != s)
        return -1;
    return 0;
#else
    (void)x;
    (void)s;
    return -1;
#endif
}

static int wd_keepalive(struct exec *x)
{
#if defined(FS_TEST)
    return write(x->wd, "keepalive\n", 10) == 10 ? 0 : -1;
#elif defined(FS_DEVICE) && !defined(FS_LOGONLY)
    int dummy = 0;
    return ioctl(x->wd, WDIOC_KEEPALIVE, &dummy);
#else
    (void)x;
    return -1;
#endif
}

static void wd_open(struct exec *x)
{
    char why[64];
    x->wd = -1;
    if (!x->c.softdog || x->c.logonly) {
        x->wd_state = 0;
        snprintf(x->wd_why, sizeof x->wd_why, "%s", x->c.logonly ? "log-only" : "not-requested");
        return;
    }
    if (!dload_zero(x, why, sizeof why)) {
        x->wd_state = -1;
        snprintf(x->wd_why, sizeof x->wd_why, "%s", why);
        return;
    }
#if defined(FS_TEST)
    x->wd = xopen(x, "/dev/watchdog", O_WRONLY | O_APPEND | O_NOFOLLOW, 0);
#elif defined(FS_DEVICE) && !defined(FS_LOGONLY)
    x->wd = open("/dev/watchdog", O_WRONLY | O_CLOEXEC);
#endif
    if (x->wd < 0) {
        x->wd_state = -2;
        snprintf(x->wd_why, sizeof x->wd_why, "open-failed:%d", errno);
        return;
    }
    /* E-3: open started the timer with the kernel's margin; ours is set now
     * and read back. A failure here leaves it running: it is still petted. */
    if (wd_settimeout(x, x->c.wd_margin)) {
        x->wd_state = -2;
        snprintf(x->wd_why, sizeof x->wd_why, "settimeout-failed");
        return;
    }
    x->wd_state = 1;
    snprintf(x->wd_why, sizeof x->wd_why, "open margin=%d", x->c.wd_margin);
}

/* ---------------- actuators A1 / A2 (E-7 .. E-10) ---------------- */

#if !defined(FS_LOGONLY)
static void close_all_but(int a, int b, int c)
{
    long maxfd = sysconf(_SC_OPEN_MAX);
    int i;
    for (i = 0; i < maxfd && i < 65536; i++)
        if (i != a && i != b && i != c)
            close(i);
}

static void act_harden(void)
{
#if defined(FS_DEVICE) && !defined(FS_LOGONLY)
    cpu_set_t one;
    struct sched_param sp;
    CPU_ZERO(&one);
    CPU_SET(0, &one);
    sched_setaffinity(0, sizeof one, &one);
    memset(&sp, 0, sizeof sp);
    sp.sched_priority = 59; /* E-9: below the supervisor's 60, above IRQ threads' 50 */
    sched_setscheduler(0, SCHED_FIFO, &sp);
    mlockall(MCL_CURRENT | MCL_FUTURE);
#endif
}

#if defined(FS_TEST)
static int sim_marker(const char *root, const char *name)
{
    char p[1024];
    struct stat st;
    snprintf(p, sizeof p, "%s/sim/%s", root, name);
    return stat(p, &st) == 0;
}
#endif

static void __attribute__((noreturn)) actuator(struct exec *x, int which, int cmd, int stat, int xlog)
{
    unsigned char b;
    ssize_t r;
    /* E-7: right after the fork: drop the softdog and every unused descriptor */
    if (x->wd >= 0)
        close(x->wd);
    close_all_but(cmd, stat, xlog);
    act_harden();
    for (;;) {
        r = read(cmd, &b, 1);
        if (r < 0 && errno == EINTR)
            continue;
        break;
    }
    if (r != 1 || b != (which == 1 ? A1_BYTE : A2_BYTE))
        _exit(0); /* E-8: EOF (supervisor gone) or any other byte: exit without acting */
    if (which == 1) {
#if defined(FS_TEST)
        if (sim_marker(x->c.root, "a1-hang"))
            for (;;)
                pause();
        usleep(20000);
#elif defined(FS_DEVICE) && !defined(FS_LOGONLY)
        sync();
#endif
        if (write(stat, "D", 1) < 0) {
        }
        if (xlog >= 0 && write(xlog, "a1 sync-done\n", 13) < 0) {
        }
        _exit(0);
    }
#if defined(FS_TEST)
    if (xlog >= 0 && write(xlog, "a2 poweroff-called\n", 19) < 0) {
    }
    if (sim_marker(x->c.root, "a2-returns"))
        _exit(0); /* a returned power-off (F4): the supervisor sees the exit */
    for (;;)
        pause();
#elif defined(FS_DEVICE) && !defined(FS_LOGONLY)
    fs_poweroff_final();
#else
    _exit(0);
#endif
}

static pid_t fork_actuator(struct exec *x, int which, int *cmd_w, int *stat_r)
{
    int cp[2], sp[2] = {-1, -1};
    pid_t p;
    if (pipe2(cp, O_CLOEXEC))
        return -1;
    if (which == 1 && pipe2(sp, O_CLOEXEC | O_NONBLOCK)) {
        close(cp[0]);
        close(cp[1]);
        return -1;
    }
    p = fork();
    if (p < 0) {
        close(cp[0]);
        close(cp[1]);
        if (sp[0] >= 0) {
            close(sp[0]);
            close(sp[1]);
        }
        return -1;
    }
    if (p == 0)
        actuator(x, which, cp[0], sp[1], x->xlog);
    close(cp[0]);
    if (sp[1] >= 0)
        close(sp[1]);
    fcntl(cp[1], F_SETFL, O_NONBLOCK); /* E-8: a command write never blocks */
    *cmd_w = cp[1];
    if (stat_r)
        *stat_r = sp[0];
    return p;
}

#endif

/* ---------------- supervisor hardening (E-12) ---------------- */
static void harden(struct exec *x)
{
#if defined(FS_DEVICE)
    cpu_set_t one;
    struct sched_param sp;
    struct rlimit rl;
    int fd;
    if (mlockall(MCL_CURRENT | MCL_FUTURE))
        exec_log(x, 0, "harden mlockall-failed errno=%d", errno);
    fd = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
    if (fd < 0 || write(fd, "-1000", 5) != 5)
        exec_log(x, 0, "harden oom_score_adj-failed");
    if (fd >= 0)
        close(fd);
    CPU_ZERO(&one);
    CPU_SET(0, &one);
    if (sched_setaffinity(0, sizeof one, &one))
        withhold(x, "affinity-cpu0-failed");
#if !defined(FS_LOGONLY)
    memset(&sp, 0, sizeof sp);
    sp.sched_priority = 60;
    if (sched_setscheduler(0, SCHED_FIFO | 0x40000000 /* SCHED_RESET_ON_FORK */, &sp))
        withhold(x, "sched-fifo-60-failed");
    rl.rlim_cur = rl.rlim_max = 500000; /* microseconds (F26) */
    if (setrlimit(RLIMIT_RTTIME, &rl))
        withhold(x, "rlimit-rttime-failed");
#else
    (void)sp;
    (void)rl;
#endif
#else
    exec_log(x, 0, "harden skipped (test build)");
#endif
}

/* ---------------- start-up (E-12 order) ---------------- */
int exec_start(struct exec *x, const struct exec_cfg *cfg, const char *last)
{
    char p[1024];
    struct stat st;
    memset(x, 0, sizeof *x);
    x->c = *cfg;
    x->ok = 1;
    x->wd = x->pmsg = x->kmsg = x->comm = x->sysrq = x->ctl = x->notice = x->hb = x->xlog = -1;
    x->a1_cmd = x->a1_stat = x->a2_cmd = -1;
    x->a1_pid = x->a2_pid = -1;
    snprintf(x->last, sizeof x->last, "%s", last && last[0] ? last : "-");
#if defined(FS_TEST)
    if (cfg->kind != EX_TEST || !cfg->root || !cfg->root[0] || cfg->pid1 <= 1) {
        fprintf(stderr, "fs-thermald: exec-sim needs --root and --test-pid1 (never PID 1)\n");
        return -1;
    }
    x->xlog = xopen(x, "/sim/exec.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
#else
    if (cfg->kind != EX_DEVICE || cfg->pid1 != 1)
        return -1;
    x->kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
#endif
    /* /run/fs-thermald: state, notice and heartbeat records, control FIFO */
    pathof(x, p, sizeof p, "/run/fs-thermald");
    mkdir(p, 0755);
    if (!cfg->gate) { /* a one-shot gate leaves no record behind (E-26: never an empty heartbeat) */
        x->notice = xopen(x, "/run/fs-thermald/notice", O_RDWR | O_CREAT | O_NOFOLLOW, 0644);
        x->hb = xopen(x, "/run/fs-thermald/hb", O_RDWR | O_CREAT | O_NOFOLLOW, 0644);
        if (x->notice < 0 || x->hb < 0)
            withhold(x, "run-records-unavailable");
    }
#if defined(FS_LOGONLY)
    withhold(x, "log-only"); /* E-31 (review M4): a binary that executes nothing never publishes READY */
#endif
    if (!cfg->stage && !cfg->gate) {
        pathof(x, p, sizeof p, "/run/fs-thermald/ctl");
        if (mkfifo(p, 0600) && errno != EEXIST)
            withhold(x, "ctl-fifo-failed");
        x->ctl = open(p, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
        if (x->ctl < 0 || fstat(x->ctl, &st) || !S_ISFIFO(st.st_mode)) {
            if (x->ctl >= 0)
                close(x->ctl);
            x->ctl = -1;
            withhold(x, "ctl-not-a-fifo");
        }
    }
    /* /proc/1/comm, pre-opened: the descriptor follows PID 1 across exec (§5.1) */
    x->comm = xopen(x, "/proc/1/comm", O_RDONLY, 0);
#if !defined(FS_LOGONLY) /* E-31: the log-only build has no pmsg, sysrq or actuator path at all */
    if (!cfg->logonly) {
        x->pmsg = xopen(x, "/dev/pmsg0", O_WRONLY | (cfg->kind == EX_TEST ? O_APPEND : 0), 0);
        if (x->pmsg < 0)
            exec_log(x, 0, "pmsg unavailable: no pstore record (E-21)");
        if (cfg->p15 && !cfg->stage && !cfg->gate) {
            x->sysrq = xopen(x, "/proc/sysrq-trigger", O_WRONLY, 0);
            if (x->sysrq < 0)
                withhold(x, "sysrq-trigger-unavailable");
        }
    }
#endif
    if (cfg->gate) {
        x->wd_state = 0;
        snprintf(x->wd_why, sizeof x->wd_why, "gate: only on a refusal");
        return 0; /* E-28: no actuator, no hardening, no softdog on a pass */
    }
    wd_open(x);
    exec_log(x, 0, "softdog %s", x->wd_why);
    if (cfg->require_softdog && x->wd_state != 1)
        withhold(x, "softdog-required");
    if (x->wd_state == -2)
        withhold(x, "softdog-error");
    /* E-7: the actuators exist before any emergency; never forked later */
#if !defined(FS_LOGONLY)
    if (!cfg->stage && !cfg->logonly) {
        x->a1_pid = fork_actuator(x, 1, &x->a1_cmd, &x->a1_stat);
        x->a2_pid = fork_actuator(x, 2, &x->a2_cmd, NULL);
        if (x->a1_pid < 0 || x->a2_pid < 0)
            withhold(x, "actuator-fork-failed");
        exec_log(x, 0, "actuators a1=%d a2=%d", (int)x->a1_pid, (int)x->a2_pid);
    }
#endif
    harden(x); /* after the forks: the actuators set their own policy, without RLIMIT_RTTIME (E-9) */
    return 0;
}

/* ---------------- per-tick inputs (E-13) ---------------- */
void exec_inputs(struct exec *x, struct tick_in *in)
{
    char b[64];
    siginfo_t si;
    if (x->a1_stat >= 0) {
        ssize_t n = read(x->a1_stat, b, sizeof b);
        if (n > 0 && memchr(b, 'D', (size_t)n))
            x->a1_done = 1;
    }
    if (x->a2_pid > 0) {
        memset(&si, 0, sizeof si);
        if (waitid(P_PID, (id_t)x->a2_pid, &si, WEXITED | WNOHANG) == 0 && si.si_pid == x->a2_pid) {
            if (x->a2_sent && si.si_code == CLD_EXITED)
                x->a2_exited = 1; /* its power-off returned (F4): A2 _exit()s only then */
            else
                x->a2_dead_early = 1;
            x->a2_pid = -1;
        }
    }
    if (x->a1_pid > 0) {
        memset(&si, 0, sizeof si);
        if (waitid(P_PID, (id_t)x->a1_pid, &si, WEXITED | WNOHANG) == 0 && si.si_pid == x->a1_pid) {
            if (!x->a1_done && !x->a1_dead_early) {
                /* exited without a sync report: died before use, or EOF */
                ssize_t n = x->a1_stat >= 0 ? read(x->a1_stat, b, sizeof b) : 0;
                if (n > 0 && memchr(b, 'D', (size_t)n))
                    x->a1_done = 1;
                else
                    x->a1_dead_early = 1;
            }
            x->a1_pid = -1;
        }
    }
    if (x->a2_dead_early)
        withhold(x, "a2-died");
    if (x->a1_dead_early && !x->a1_done)
        withhold(x, "a1-died");
    if (x->ctl >= 0) {
        ssize_t n;
        while ((n = read(x->ctl, b, sizeof b)) > 0)
            if (memchr(b, 'S', (size_t)n))
                x->sb = 1; /* E-14: SHUTDOWN byte from fs-thermald-shutdown.service */
    }
    in->shutdown_byte = x->sb;
    in->a1_done = x->a1_done;
    in->a2_exited = x->a2_exited;
    in->pid1_shutdown = 0;
    if (x->comm >= 0) {
        ssize_t n = pread(x->comm, b, sizeof b - 1, 0);
        if (n > 0) {
            b[n] = 0;
            if (b[n - 1] == '\n')
                b[n - 1] = 0;
            in->pid1_shutdown = !strcmp(b, "systemd-shutdow");
        }
    }
}

/* ---------------- FST1 pstore records (E-20 .. E-23) ---------------- */
static int has_action(const struct tick_out *o, const char *a)
{
    int i;
    for (i = 0; i < o->na; i++)
        if (!strcmp(o->a[i], a))
            return 1;
    return 0;
}

static int event_prefix(const struct tick_out *o, const char *pfx)
{
    int i;
    for (i = 0; i < o->ne; i++)
        if (!strncmp(o->e[i], pfx, strlen(pfx)))
            return 1;
    return 0;
}

static int sens_val(const struct conf *c, const struct tick_in *in, const char *name, int32_t *v)
{
    int i;
    for (i = 0; i < c->ns; i++)
        if (!strcmp(c->s[i].name, name)) {
            if (c->s[i].kind == K_PSY) {
                if (in->psy_temp.st != RD_NUM)
                    return -1;
                *v = in->psy_temp.v * 100;
                return 0;
            }
            if (in->s[i].st != RD_NUM)
                return -1;
            *v = in->s[i].v;
            return 0;
        }
    return -1;
}

static void notice_parts(const char *n, char *sev, size_t sc, char *reason, size_t rc, int *cd)
{
    char tmp[64];
    char *a, *b;
    snprintf(tmp, sizeof tmp, "%s", n);
    *cd = -1;
    snprintf(sev, sc, "-");
    snprintf(reason, rc, "-");
    a = strchr(tmp, ':');
    if (!a)
        return;
    *a++ = 0;
    snprintf(sev, sc, "%s", tmp);
    b = strchr(a, ':');
    if (b) {
        *b++ = 0;
        *cd = atoi(b);
    }
    snprintf(reason, rc, "%s", a);
}

static void fill_record(struct fst *r, const struct conf *c, const struct tick_in *in, const struct tick_out *o,
                        const char *ev, int64_t t)
{
    int i, best = -1;
    int32_t bv = 0, v;
    char sev[16];
    size_t wl = 0;
    memset(r, 0, sizeof *r);
    snprintf(r->ev, sizeof r->ev, "%s", ev);
    r->t = t;
    notice_parts(o->notice, sev, sizeof sev, r->reason, sizeof r->reason, &r->cd);
    snprintf(r->sensor, sizeof r->sensor, "-");
    snprintf(r->value, sizeof r->value, "-");
    snprintf(r->why, sizeof r->why, "-");
    /* cause: the first t4/t5 event naming a sensor (events are sorted) */
    for (i = 0; i < o->ne; i++) {
        const char *e = o->e[i], *nm = NULL;
        if (strncmp(e, "t4:", 3) && strncmp(e, "t5:", 3))
            continue;
        if (wl + strlen(e) + 2 < sizeof r->why) {
            if (wl)
                r->why[wl++] = ',';
            memcpy(r->why + wl, e, strlen(e));
            wl += strlen(e);
            r->why[wl] = 0;
        }
        if (!strncmp(e + 3, "shutdown:", 9))
            nm = e + 12;
        else if (!strncmp(e + 3, "anomaly:", 8))
            nm = e + 11;
        else if (!strncmp(e + 3, "sensor:", 7))
            nm = e + 10;
        else if (!strncmp(e + 3, "p12:", 4))
            nm = e + 7;
        else if (!strcmp(e + 3, "p5") && c->p5 >= 0)
            nm = c->s[c->p5].name;
        if (nm && !strcmp(r->sensor, "-") && strlen(nm) < sizeof r->sensor) {
            snprintf(r->sensor, sizeof r->sensor, "%s", nm);
            if (!sens_val(c, in, nm, &v))
                snprintf(r->value, sizeof r->value, "%d", (int)v);
        }
    }
    if (!wl)
        snprintf(r->why, sizeof r->why, "-");
    /* hottest counted sensor this tick (the "at 52 °C" of the next-boot line) */
    for (i = 0; i < c->ns; i++) {
        if (c->s[i].cls == CL_AUX || c->s[i].cls == CL_BCL)
            continue;
        if (sens_val(c, in, c->s[i].name, &v))
            continue;
        if (best < 0 || v > bv) {
            best = i;
            bv = v;
        }
    }
    if (best >= 0 && strlen(c->s[best].name) + 12 < sizeof r->hot)
        snprintf(r->hot, sizeof r->hot, "%s:%d", c->s[best].name, (int)bv);
    else
        snprintf(r->hot, sizeof r->hot, "-");
}

static void pmsg_write(struct exec *x, const struct conf *c, const struct tick_in *in, const struct tick_out *o,
                       const char *ev, int64_t t)
{
    struct fst r;
    char buf[FST_MAX + 2];
    int n;
    fill_record(&r, c, in, o, ev, t);
    n = fst_encode(&r, buf, sizeof buf);
    if (n < 0) {
        exec_log(x, t, "pmsg encode-failed ev=%s", ev);
        return;
    }
    buf[n - 1] = 0;
    exec_log(x, t, "pmsg %s", buf);
    buf[n - 1] = '\n';
    if (x->pmsg >= 0 && write(x->pmsg, buf, (size_t)n) != n)
        exec_log(x, t, "pmsg write-failed errno=%d", errno);
}

/* ---------------- timeline actions (E-15 .. E-19), before the writes ---------------- */
#if !defined(FS_LOGONLY)
static int send_byte(struct exec *x, int fd, unsigned char b, const char *what, int64_t t)
{
    if (fd < 0 || write(fd, &b, 1) != 1) {
        exec_log(x, t, "%s FAILED errno=%d", what, errno);
        return -1;
    }
    exec_log(x, t, "%s sent", what);
    return 0;
}

static void step_signal(struct exec *x, int sig, int64_t t)
{
    char b[32], p[1024];
    struct stat st;
    int fd;
    ssize_t n;
    long pg;
    char *e;
    if (!x->c.step_pgid_file) {
        exec_log(x, t, "step-signal %d: no step file", sig);
        return;
    }
    snprintf(p, sizeof p, "%s%s", x->c.kind == EX_TEST ? x->c.root : "", x->c.step_pgid_file);
    fd = open(p, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode)) {
        if (fd >= 0)
            close(fd);
        exec_log(x, t, "step-signal %d: no step", sig);
        return;
    }
    n = pread(fd, b, sizeof b - 1, 0);
    close(fd);
    if (n <= 0) {
        exec_log(x, t, "step-signal %d: empty step file", sig);
        return;
    }
    b[n] = 0;
    pg = strtol(b, &e, 10);
    if ((*e && *e != '\n') || pg <= 1 || pg == getpgrp() || pg > 4194304) {
        exec_log(x, t, "step-signal %d: refused pgid", sig);
        return;
    }
    if (kill((pid_t)-pg, sig))
        exec_log(x, t, "step-signal %d pgid=%ld FAILED errno=%d", sig, pg, errno);
    else
        exec_log(x, t, "step-signal %d pgid=%ld", sig, pg);
}

#endif

static void final_pet(struct exec *x, int64_t t)
{
    if (x->wd_final_done)
        return;
    x->wd_final_done = 1; /* E-5: from here on, never another pet */
    if (x->wd < 0) {
        exec_log(x, t, "final-pet (softdog %s)", x->wd_why);
        return;
    }
    /* E-4: SETTIMEOUT(M_final) pings with the new margin; KEEPALIVE once more */
    if (wd_settimeout(x, x->c.wd_final) || wd_keepalive(x))
        exec_log(x, t, "final-pet FAILED errno=%d", errno);
    else
        exec_log(x, t, "final-pet margin=%d", x->c.wd_final);
}

void exec_timeline(struct exec *x, const struct conf *c, const struct tick_in *in, const struct tick_out *o, int64_t t)
{
    /* E-20: FST1 records first (RAM-backed, non-blocking) */
    if (!x->rec_t4 && event_prefix(o, "t4:")) {
        x->rec_t4 = 1;
        pmsg_write(x, c, in, o, "t4", t);
    }
    if (!x->rec_t5 && event_prefix(o, "t5:")) {
        x->rec_t5 = 1;
        pmsg_write(x, c, in, o, "t5", t);
    }
    if (x->c.logonly) {
        int i;
        for (i = 0; i < o->na; i++)
            if (strcmp(o->a[i], "pet"))
                exec_log(x, t, "log-only: not executed: %s", o->a[i]);
        return;
    }
#if !defined(FS_LOGONLY)
    if (x->c.stage) { /* C-39: term-step; + 2 s kill-step, final-pet, trip */
        if (has_action(o, "term-step"))
            step_signal(x, SIGTERM, t);
        if (has_action(o, "kill-step"))
            step_signal(x, SIGKILL, t);
        if (has_action(o, "final-pet"))
            final_pet(x, t);
        if (has_action(o, "trip")) {
            x->tripped = 1; /* E-19 (review M1): written into the heartbeat NOW, before the sysfs writes */
            hb_write(x, 0, t);
            exec_log(x, t, "trip");
        }
        return;
    }
    if (has_action(o, "signal-pid1")) { /* E-11 */
        if (kill((pid_t)x->c.pid1, FS_PID1_SIGNAL))
            exec_log(x, t, "signal-pid1 %d FAILED errno=%d", FS_PID1_SIGNAL, errno);
        else
            exec_log(x, t, "signal-pid1 %d", FS_PID1_SIGNAL);
    }
    if (has_action(o, "a1"))
        send_byte(x, x->a1_cmd, A1_BYTE, "a1", t);
    if (has_action(o, "final-pet"))
        final_pet(x, t);
    if (has_action(o, "a2")) { /* E-16: always after the final pet of the same tick */
        if (send_byte(x, x->a2_cmd, A2_BYTE, "a2", t) == 0)
            x->a2_sent = 1; /* review m2: a byte never delivered is never followed by "a2 returned" */
        if (!x->rec_a2) {
            x->rec_a2 = 1;
            pmsg_write(x, c, in, o, "a2", t);
        }
    }
    if (in->a2_exited && !x->rec_a2r) {
        x->rec_a2r = 1;
        pmsg_write(x, c, in, o, "a2-returned", t);
    }
    if (has_action(o, "sysrq-c")) { /* E-18: P15 only, after A2's exit */
        if (x->sysrq < 0 || write(x->sysrq, "c", 1) != 1)
            exec_log(x, t, "sysrq-c FAILED");
        else
            exec_log(x, t, "sysrq-c");
    }
#else
    (void)c;
    (void)in;
#endif
}

int exec_ready(const struct exec *x, const struct tick_out *o)
{
    return o->ready && x->ok;
}

/* ---------------- notice and heartbeat records (E-24 .. E-27) ---------------- */
/* E-26: one fixed-width record (40 bytes) overwritten in place, never
 * truncated, so PID 1's `read` never sees an empty file; space padding,
 * no leading zeros (pid1-hold's strict number parsing). state: 0 INIT,
 * 1 HOLD, 2 READY; TRIP overrides. */
static void hb_write(struct exec *x, int state, int64_t t)
{
    char hb[64];
    long long bt = x->c.kind == EX_TEST ? (long long)(t / 1000) : (long long)(mono_ms() / 1000);
    int n = snprintf(hb, sizeof hb, "%20llu %12lld %-5s\n", x->seq % 100000000000000000ULL, bt,
                     x->tripped ? "TRIP" : state == 2 ? "READY" : state == 1 ? "HOLD" : "INIT");
    if (x->hb >= 0 && n == 40 && pwrite(x->hb, hb, (size_t)n, 0) != n)
        exec_log(x, t, "heartbeat write-failed");
}

void exec_publish(struct exec *x, const struct tick_out *o, int64_t t)
{
    char rec[FSN_LEN];
    x->seq++;
    if (x->notice >= 0 && !fsn_encode(rec, x->seq, (long long)t, exec_ready(x, o), o->tier, o->notice, x->last))
        if (pwrite(x->notice, rec, FSN_LEN, 0) != FSN_LEN)
            exec_log(x, t, "notice write-failed");
    hb_write(x, exec_ready(x, o) ? 2 : o->ready ? 1 : 0, t);
}

/* E-6: pet only at the end of a complete cycle, never after the final pet */
void exec_pet(struct exec *x, const struct tick_out *o, int64_t t)
{
    if (!has_action(o, "pet") || x->wd_final_done || x->wd < 0)
        return;
    if (wd_keepalive(x))
        exec_log(x, t, "pet FAILED errno=%d", errno);
    x->wd_pets++;
}

/* ---------------- gate refusal (E-28) ---------------- */
void exec_gate_refuse(struct exec *x, const struct conf *c, const struct tick_in *in, const char *reasons, int64_t t)
{
    struct fst r;
    char buf[FST_MAX + 2];
    struct tick_out o;
    int n;
    memset(&o, 0, sizeof o);
    snprintf(o.notice, sizeof o.notice, "-");
    fill_record(&r, c, in, &o, "gate", t);
    snprintf(r.why, sizeof r.why, "%.*s", (int)sizeof r.why - 1, reasons && reasons[0] ? reasons : "-");
    {   /* a why with a space or '=' would not encode: keep the token form */
        char *p;
        for (p = r.why; *p; p++)
            if (*p == ' ' || *p == '=')
                *p = '_';
    }
    n = fst_encode(&r, buf, sizeof buf);
    if (n > 0) {
        buf[n - 1] = 0;
        exec_log(x, t, "pmsg %s", buf);
        buf[n - 1] = '\n';
        if (x->pmsg >= 0 && write(x->pmsg, buf, (size_t)n) != n)
            exec_log(x, t, "pmsg write-failed");
    }
    if (x->c.softdog && !x->c.logonly && x->wd < 0) {
        wd_open(x);
        exec_log(x, t, "softdog %s", x->wd_why);
    }
    if (x->wd >= 0 && !x->wd_final_done)
        final_pet(x, t); /* left open: PID 1 execs fs-poweroff-final next (bound: + M_final) */
}
