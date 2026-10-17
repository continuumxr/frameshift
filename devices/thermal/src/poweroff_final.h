/* SPDX-License-Identifier: Apache-2.0
 * poweroff_final.h — the one power-off sequence of FrameShift's thermal
 * service (emergency-shutdown-design.md §5.2; EXEC-SPEC.md E-20).
 *
 *   1. reboot(LINUX_REBOOT_CMD_POWER_OFF)
 *   2. only reached if (1) returned, which the kernel allows only for an
 *      error before the reboot lock (EPERM without CAP_SYS_BOOT, EINVAL):
 *      reboot(LINUX_REBOOT_CMD_RESTART)  (a returned power-off itself never
 *      comes back: the kernel ends the calling task, F4)
 *   3. nanosleep for ever. Never exit (as PID 1, an exit is a panic).
 *
 * Used twice, never exec'd by the supervisor: as the body of the pre-forked
 * actuator A2 inside fs-thermald (§5.1, "linked in"), and as the _start of
 * the freestanding fs-poweroff-final that PID 1 execs on TRIP (§6.1).
 * Fixed arguments; no string; no exit syscall in this file.
 */
#ifndef FS_POWEROFF_FINAL_H
#define FS_POWEROFF_FINAL_H

#define FSPO_SYS_nanosleep 101
#define FSPO_SYS_reboot 142
#define FSPO_MAGIC1 0xfee1deadUL
#define FSPO_MAGIC2 672274793UL
#define FSPO_POWER_OFF 0x4321FEDCUL
#define FSPO_RESTART 0x01234567UL

#if defined(__aarch64__)
static inline long fspo_sys4(long n, long a, long b, long c, long d)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

struct fspo_ts { long sec, nsec; };

static inline void __attribute__((noreturn)) fs_poweroff_final(void)
{
    static const struct fspo_ts hour = {3600, 0};
    fspo_sys4(FSPO_SYS_reboot, (long)FSPO_MAGIC1, (long)FSPO_MAGIC2, (long)FSPO_POWER_OFF, 0);
    fspo_sys4(FSPO_SYS_reboot, (long)FSPO_MAGIC1, (long)FSPO_MAGIC2, (long)FSPO_RESTART, 0);
    for (;;)
        fspo_sys4(FSPO_SYS_nanosleep, (long)&hour, 0, 0, 0);
}
#endif
#endif
