// SPDX-License-Identifier: Apache-2.0
// fs-noticed: the status-LED consumer of the FSN1 notice record (EXEC-SPEC.md
// §8, PLAN R47). One pattern per severity, written with the existing LED
// write class (/sys/class/leds/{red,green,blue}/brightness, the same nodes
// the stage inits' led() writes; leds-qti-tri-led labels, v2.7 DT). Idle
// priority; polls every 250 ms; never signals or waits for anyone; the
// supervisor never waits for it. A stale record (no change for 5 s) is shown
// as "service not reporting" (slow white blink) and changes nothing else.
//
//   fs-noticed watch NOTICE_PATH [LED_DIR]      (LED_DIR default /sys/class/leds)
//   fs-noticed eval NOTICE STALE T_MS          (prints "r g b": the pattern function, for tests)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "fst_record.h"

#define POLL_MS 250  /* the record is read every 250 ms */
#define STEP_MS 50   /* the LED is updated every 50 ms (a 4 Hz blink needs more than 2 samples per period) */
#define STALE_MS 5000

/* E-34: the pattern, a pure function of the notice, staleness and time */
static void pattern(const char *notice, int stale, long long t, int rgb[3])
{
    long long ph1 = (t / 500) % 2, ph4 = (t / 125) % 2; /* 1 Hz and 4 Hz square waves */
    rgb[0] = rgb[1] = rgb[2] = 0;
    if (!strncmp(notice, "shutdown:", 9)) { /* red, fast blink */
        rgb[0] = ph4 ? 255 : 0;
        return;
    }
    if (stale) { /* white, slow: the supervisor's record stopped (a shutdown notice still shows red) */
        int on = (t / 1000) % 2;
        rgb[0] = rgb[1] = rgb[2] = on ? 64 : 0;
        return;
    }
    if (!strncmp(notice, "warn:", 5)) { /* amber, 1 Hz */
        rgb[0] = ph1 ? 255 : 0;
        rgb[1] = ph1 ? 160 : 0;
        return;
    }
    rgb[0] = rgb[1] = rgb[2] = -1; /* normal: leave the LEDs as the init set them */
}

static int open_led(const char *dir, const char *c)
{
    char p[512];
    snprintf(p, sizeof p, "%s/%s/brightness", dir, c);
    return open(p, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
}

static void put(int fd, int v)
{
    char b[8];
    int n = snprintf(b, sizeof b, "%d\n", v);
    if (fd >= 0 && pwrite(fd, b, (size_t)n, 0) < 0) {
    }
}

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int read_rec(const char *path, struct fsn *f)
{
    char b[FSN_LEN];
    struct stat st;
    ssize_t n;
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    n = pread(fd, b, sizeof b, 0);
    close(fd);
    return n == FSN_LEN ? fsn_parse(b, FSN_LEN, f) : -1;
}

int main(int argc, char **argv)
{
    if (argc == 5 && !strcmp(argv[1], "eval")) {
        int rgb[3];
        pattern(argv[2], atoi(argv[3]), atoll(argv[4]), rgb);
        printf("%d %d %d\n", rgb[0], rgb[1], rgb[2]);
        return 0;
    }
    if ((argc == 3 || argc == 4) && !strcmp(argv[1], "watch")) {
        const char *dir = argc == 4 ? argv[3] : "/sys/class/leds";
        int fd[3] = {open_led(dir, "red"), open_led(dir, "green"), open_led(dir, "blue")};
        int last[3] = {-2, -2, -2};
        unsigned long long seq = 0;
        long long seen = now_ms(), lastread = -1000000;
        char cur[64] = "-";
        struct sched_param sp = {0};
        setpriority(PRIO_PROCESS, 0, 19);
        sched_setscheduler(0, SCHED_IDLE, &sp);
        for (;;) {
            struct fsn f;
            struct timespec ts = {0, STEP_MS * 1000000L};
            int rgb[3], i, stale;
            long long t = now_ms();
            if (t - lastread >= POLL_MS) {
                lastread = t;
                if (!read_rec(argv[2], &f)) {
                    if (f.seq != seq) {
                        seq = f.seq;
                        seen = t;
                    }
                    snprintf(cur, sizeof cur, "%s", f.n);
                }
            }
            stale = t - seen > STALE_MS;
            pattern(cur, stale, t, rgb);
            for (i = 0; i < 3; i++) {
                if (rgb[i] < 0 && last[i] > 0) /* review n5: a cleared pattern never leaves an LED lit */
                    rgb[i] = 0;
                if (rgb[i] >= 0 && rgb[i] != last[i]) {
                    put(fd[i], rgb[i]);
                    last[i] = rgb[i];
                }
            }
            nanosleep(&ts, NULL);
        }
    }
    fprintf(stderr, "usage: fs-noticed watch NOTICE [LED_DIR] | eval NOTICE STALE T_MS\n");
    return 2;
}
