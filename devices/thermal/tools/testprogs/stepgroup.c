// SPDX-License-Identifier: Apache-2.0
// Test stand-in for a stage step's process group (exec-sim suite): setsid(),
// writes its pgid to PGIDFILE, logs SIGTERM to LOG and keeps running until
// SIGKILL (so the guard's + 2 s kill-step is observable). Never on a device.
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int g_log = -1;
static void on_term(int s)
{
    (void)s;
    if (write(g_log, "term\n", 5) != 5) {
    }
}

int main(int argc, char **argv)
{
    char b[32];
    int fd, n;
    if (argc != 3)
        return 2;
    setsid();
    g_log = open(argv[2], O_WRONLY | O_CREAT | O_APPEND, 0644);
    signal(SIGTERM, on_term);
    fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    n = snprintf(b, sizeof b, "%d\n", (int)getpgrp());
    if (fd < 0 || write(fd, b, (size_t)n) != n)
        return 1;
    close(fd);
    for (;;)
        pause();
}
