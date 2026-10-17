// SPDX-License-Identifier: Apache-2.0
// Test-only stand-ins for fs-metacfg (design §7.1: a helper that hangs,
// spins, sends a bad or oversized record; and a probe that checks what the
// supervisor's spawn rules gave it). Never part of an image.
// usage: fakehelper <device> <fd> <mode> [exec-path exec-args...]
#define _GNU_SOURCE
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static void hdr(int fd, uint32_t json, uint32_t n, uint16_t status)
{
    uint8_t h[64] = {'F', 'S', 'M', 'C', 1, 0};
    h[6] = (uint8_t)status;
    h[8] = (uint8_t)json; h[9] = (uint8_t)(json >> 8); h[10] = (uint8_t)(json >> 16);
    h[20] = (uint8_t)n;
    h[24] = 96;
    if (write(fd, h, sizeof h) != sizeof h)
        _exit(1);
}

static int lim(int r, rlim_t cur, rlim_t max)
{
    struct rlimit l;
    return !getrlimit(r, &l) && l.rlim_cur == cur && l.rlim_max == max;
}

int main(int argc, char **argv)
{
    int fd;
    const char *m;
    if (argc < 4)
        return 2;
    fd = atoi(argv[2]);
    m = argv[3];
    if (!strcmp(m, "sleep"))
        for (;;)
            pause();
    if (!strcmp(m, "spin"))
        for (volatile unsigned long i = 0;; i++)
            ;
    if (!strcmp(m, "partial")) { /* half a header, then hang */
        if (write(fd, "FSMC", 4) != 4)
            return 1;
        for (;;)
            pause();
    }
    if (!strcmp(m, "garbage")) {
        if (write(fd, "this is not a record, not at all, padding padding padding padding", 64) != 64)
            return 1;
        return 0;
    }
    if (!strcmp(m, "bigjson")) { /* json_len over its cap */
        hdr(fd, 65537, 1, 0);
        return 0;
    }
    if (!strcmp(m, "n129")) {
        hdr(fd, 10, 129, 0);
        return 0;
    }
    if (!strcmp(m, "short")) { /* announces 10 bytes of JSON, sends 3, exits */
        hdr(fd, 10, 1, 0);
        if (write(fd, "{}x", 3) != 3)
            return 1;
        return 0;
    }
    if (!strcmp(m, "probe")) { /* check the spawn rules (design §4.5.2, F39) */
        sigset_t cur;
        cpu_set_t cs;
        int ok = 1, i;
        sigprocmask(SIG_SETMASK, NULL, &cur);
        for (i = 1; i < 32; i++)
            if (sigismember(&cur, i))
                ok = 0;
        if (sched_getaffinity(0, sizeof cs, &cs) || CPU_COUNT(&cs) != sysconf(_SC_NPROCESSORS_ONLN))
            ok = 0;
        if (sched_getscheduler(0) != SCHED_OTHER)
            ok = 0;
        if (!lim(RLIMIT_AS, 32ul << 20, 32ul << 20) || !lim(RLIMIT_CPU, 1, 2) || !lim(RLIMIT_FSIZE, 0, 0) ||
            !lim(RLIMIT_NOFILE, 16, 16) || !lim(RLIMIT_NPROC, 0, 0))
            ok = 0;
        for (i = 0; i < 1024; i++)
            if (i != fd && fcntl(i, F_GETFD) != -1)
                ok = 0;
        if (!ok) {
            if (write(fd, "PROBE-FAILED-PROBE-FAILED-PROBE-FAILED-PROBE-FAILED-PROBE-FAILED", 64) < 0)
                return 1;
            return 0;
        }
        if (argc > 4) { /* exec the next program as <path> <device> <fd> [its args] */
            char *nv[16];
            int k = 0, j;
            nv[k++] = argv[4];
            nv[k++] = argv[1];
            nv[k++] = argv[2];
            for (j = 5; j < argc && k < 15; j++)
                nv[k++] = argv[j];
            nv[k] = NULL;
            execv(argv[4], nv);
        }
        hdr(fd, 0, 0, 2); /* a valid failure record: reader:no-super */
        return 0;
    }
    return 2;
}
