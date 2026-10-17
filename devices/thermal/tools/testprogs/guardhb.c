// SPDX-License-Identifier: Apache-2.0
// Test stand-in for the stage guard's heartbeat (pid1-hold-ts.sh fixtures).
// Built as a binary named "fs-thermald" so /proc/<pid>/stat shows the guard's
// comm. Writes "seq boottime_s STATE" once a second to HB, like
// thermald_exec.c exec_publish(). Behaviour by MODE after AFTER seconds:
//   ready   READY for ever          trip   READY, then TRIP
//   stale   READY, then the record stops changing (process alive)
//   frozen  READY, then the boottime field stops advancing (seq advances)
//   dead    READY, then exit        init   INIT for ever
//   seqfreeze READY, then seq stops while the boottime field advances
//   garble  READY, then an unknown state word (as a torn read would give)
// Never used on a device.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *hb, *mode;
    int after, k;
    unsigned long seq = 0;
    long frozen_bt = -1;
    if (argc != 4)
        return 2;
    hb = argv[1];
    mode = argv[2];
    after = atoi(argv[3]);
    for (k = 0;; k++) {
        struct timespec ts;
        char b[64];
        const char *st = "READY";
        int fd, n;
        long bt;
        clock_gettime(CLOCK_BOOTTIME, &ts);
        bt = (long)ts.tv_sec;
        if (!strcmp(mode, "init"))
            st = "INIT";
        if (k >= after && !strcmp(mode, "garble"))
            st = (k % 2) ? "RE@DY" : "TR1P "; /* a torn/unknown state word: never a reason by itself */
        if (k >= after) {
            if (!strcmp(mode, "trip"))
                st = "TRIP";
            else if (!strcmp(mode, "dead"))
                return 0;
            else if (!strcmp(mode, "stale")) {
                sleep(1);
                continue;
            } else if (!strcmp(mode, "frozen")) {
                if (frozen_bt < 0)
                    frozen_bt = bt;
                bt = frozen_bt;
            }
        }
        if (!(k >= after && !strcmp(mode, "seqfreeze")))
            seq++; /* seqfreeze: the boottime field advances, seq does not */
        n = snprintf(b, sizeof b, "%20lu %12ld %-5s\n", seq, bt, st); /* as exec_publish (E-26) */
        fd = open(hb, O_WRONLY | O_CREAT, 0644);
        if (fd >= 0) {
            if (pwrite(fd, b, (size_t)n, 0) != n) {
            }
            close(fd);
        }
        sleep(1);
    }
}
