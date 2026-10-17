// SPDX-License-Identifier: Apache-2.0
// Test stand-in for PID 1 (exec-sim suite): blocks every signal, records each
// one it receives as "sig N" in LOG, exits on SIGKILL only. Never used on a device.
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    sigset_t all;
    int fd;
    if (argc != 2)
        return 2;
    sigfillset(&all);
    sigprocmask(SIG_BLOCK, &all, NULL);
    fd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return 1;
    if (write(fd, "ready\n", 6) != 6)
        return 1;
    for (;;) {
        siginfo_t si;
        char b[32];
        int n, s = sigwaitinfo(&all, &si);
        if (s < 0)
            continue;
        n = snprintf(b, sizeof b, "sig %d\n", s);
        if (write(fd, b, (size_t)n) != n)
            return 1;
    }
}
