// SPDX-License-Identifier: Apache-2.0
// fs-thermald-watch (Valve layer; emergency-shutdown-design.md §5.4, §6.2;
// EXEC-SPEC.md §9): the graceful half of the supervision chain.
//
//   fs-thermald-watch watch [HB] [PID1]
//       every 1 s: read the supervisor's heartbeat record "seq boottime_s
//       STATE" (fixed width, thermald_exec.c E-26). Stale = its boottime more
//       than 5 s behind our own CLOCK_BOOTTIME, or seq unchanged for 5 of our
//       ticks, or the record missing/garbled after a 10 s start grace. Stale
//       -> kill(PID1, 38) once: systemd's poweroff.target request, the same
//       literal signal the supervisor uses (E-11; review m4: no logind/polkit
//       or inhibitor dependency, unlike "systemctl poweroff"); a graceful T4
//       by systemd; the softdog stays armed as the backstop (§5.4).
//   fs-thermald-watch send-shutdown [CTL]
//       ExecStop= of fs-thermald-shutdown.service: one 'S' byte into the
//       supervisor's control FIFO, opened O_WRONLY|O_NONBLOCK (no reader ->
//       ENXIO, never blocks). Exit 0 always (a stop job must not fail).
//   fs-thermald-watch check HB NOW_S PREVSEQ SAME   (pure staleness rule, for tests)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define STALE_AGE_S 5
#define STALE_SAME 5
#define GRACE_S 10

static long long now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (long long)ts.tv_sec;
}

/* 0 ok, 1 stale by age, 2 garbled/missing; seq/state out */
static int read_hb(const char *p, long long now, unsigned long long *seq, char *state, size_t cap)
{
    char b[64];
    long long bt;
    struct stat st;
    int fd = open(p, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    ssize_t n;
    if (fd < 0)
        return 2;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
        close(fd);
        return 2;
    }
    n = pread(fd, b, sizeof b - 1, 0);
    close(fd);
    if (n != 40)
        return 2;
    b[n] = 0;
    if (sscanf(b, "%llu %lld %15s", seq, &bt, state) != 3 || cap < 16)
        return 2;
    if (strcmp(state, "READY") && strcmp(state, "HOLD") && strcmp(state, "INIT") && strcmp(state, "TRIP"))
        return 2;
    return now - bt > STALE_AGE_S ? 1 : 0;
}

static void poweroff(pid_t pid1)
{
    if (kill(pid1, 38)) /* literal 38 = glibc SIGRTMIN+4 (never the macro: musl differs) */
        fprintf(stderr, "fs-thermald-watch: kill(%d, 38) failed: errno %d\n", (int)pid1, errno);
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    if (argc >= 2 && argc <= 3 && !strcmp(argv[1], "send-shutdown")) {
        const char *ctl = argc == 3 ? argv[2] : "/run/fs-thermald/ctl";
        struct stat st;
        int fd = open(ctl, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (fd >= 0 && !fstat(fd, &st) && S_ISFIFO(st.st_mode) && write(fd, "S", 1) == 1)
            fprintf(stderr, "fs-thermald-watch: SHUTDOWN byte sent\n");
        else
            fprintf(stderr, "fs-thermald-watch: SHUTDOWN byte not delivered (errno %d)\n", errno);
        if (fd >= 0)
            close(fd);
        return 0;
    }
    if (argc == 6 && !strcmp(argv[1], "check")) {
        unsigned long long seq = 0, prev = strtoull(argv[4], NULL, 10);
        char state[16] = "";
        int same = atoi(argv[5]);
        int r = read_hb(argv[2], atoll(argv[3]), &seq, state, sizeof state);
        if (!r && seq == prev && same + 1 >= STALE_SAME)
            r = 3;
        printf("%s seq=%llu state=%s\n", r == 0 ? "ok" : r == 1 ? "stale-age" : r == 2 ? "garbled" : "stale-seq", seq,
               state[0] ? state : "-");
        return 0;
    }
    if (argc >= 2 && argc <= 4 && !strcmp(argv[1], "watch")) {
        const char *hb = argc >= 3 ? argv[2] : "/run/fs-thermald/hb";
        pid_t pid1 = argc >= 4 ? (pid_t)atoi(argv[3]) : 1;
        if (pid1 <= 0) { /* never a process group or "every process" (kill(0/-1, ...)) */
            fprintf(stderr, "fs-thermald-watch: PID1 must be > 0\n");
            return 2;
        }
        unsigned long long prev = 0;
        int same = 0, fired = 0;
        long long t0 = now_s();
        for (;;) {
            unsigned long long seq = 0;
            char state[16] = "";
            long long now = now_s();
            int r = read_hb(hb, now, &seq, state, sizeof state);
            const char *why = NULL;
            if (r == 0) {
                same = (seq == prev) ? same + 1 : 0;
                prev = seq;
                if (same >= STALE_SAME)
                    why = "seq-frozen";
            } else if (r == 1)
                why = "stale-age";
            else if (now - t0 > GRACE_S)
                why = "missing";
            if (why && !fired) {
                fired = 1;
                fprintf(stderr, "fs-thermald-watch: heartbeat %s: kill(%d, 38)\n", why, (int)pid1);
                poweroff(pid1);
            }
            sleep(1);
        }
    }
    fprintf(stderr, "usage: fs-thermald-watch watch [HB] [PID1] | send-shutdown [CTL] | check HB NOW PREV SAME\n");
    return 2;
}
