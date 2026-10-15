/*
 * FIXTURES ONLY (never shipped, never on a device): an LD_PRELOAD shim for the native
 * build/fs-rpcd.native that simulates a runner the kernel never lets fs-rpcd reap (for
 * example one stuck in uninterruptible sleep). With FS_SHIM_NOWAIT set, every
 * waitpid(..., WNOHANG) returns 0 ("still running") and a BLOCKING waitpid never returns
 * (what a D-state child does to its parent). Used by device_cases.py X5 to show that
 * fs-rpcd's reap is bounded (2 s + 2 s, WNOHANG only) and that it then refuses
 * runner-unreaped; the e0d364f code (blocking waitpid after SIGKILL) hangs under it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

pid_t waitpid(pid_t pid, int *status, int options) {
    static pid_t (*real)(pid_t, int *, int);
    if (!real) real = (pid_t (*)(pid_t, int *, int))dlsym(RTLD_NEXT, "waitpid");
    if (getenv("FS_SHIM_NOWAIT")) {
        if (options & WNOHANG) return 0;
        for (;;) pause();
    }
    return real(pid, status, options);
}
