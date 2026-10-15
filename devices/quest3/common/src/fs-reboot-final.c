/*
 * fs-reboot-final — the PID-1-safe reboot helper (DEADLINE.md §2.3).
 *
 * PID 1 `exec`s this as its LAST action on the deadline path, so no fork is
 * needed to reboot. Because it then IS PID 1, it must never exit (PID 1
 * exiting panics the kernel; with download_mode=1 that is crash-dump mode).
 *
 *   1. reboot(LINUX_REBOOT_CMD_RESTART2, "bootloader")   (as fs-reboot.c)
 *   2. if that returns: reboot(LINUX_REBOOT_CMD_RESTART)  (plain restart)
 *   3. if that returns too: nanosleep in a loop, for ever. NEVER exit.
 *
 * Freestanding (no libc), argument-free in effect: argv is ignored, and the
 * only mode string in the binary is the fixed "bootloader", so it can never
 * request another mode (e.g. "edl"). There is no exit syscall in this file.
 *
 * Build: see tools/build.sh (clang r450784e, -nostdlib -ffreestanding).
 */
#define SYS_nanosleep     101
#define SYS_reboot        142
#define REBOOT_MAGIC1     0xfee1deadUL
#define REBOOT_MAGIC2     672274793UL
#define REBOOT_RESTART    0x01234567UL
#define REBOOT_RESTART2   0xA1B2C3D4UL

static long sys4(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}

static const char target[] = "bootloader";

struct ts { long sec, nsec; };

void _start(void)
{
	static const struct ts hour = { 3600, 0 };
	sys4(SYS_reboot, REBOOT_MAGIC1, REBOOT_MAGIC2, REBOOT_RESTART2, (long)target);
	sys4(SYS_reboot, REBOOT_MAGIC1, REBOOT_MAGIC2, REBOOT_RESTART, 0);
	for (;;)
		sys4(SYS_nanosleep, (long)&hour, 0, 0, 0);
}
