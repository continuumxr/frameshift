/*
 * fs-reboot — reboot into the bootloader (fastboot), and nothing else.
 *
 * Calls reboot(LINUX_REBOOT_CMD_RESTART2, "bootloader"); the Qualcomm
 * reboot-reason / reboot-mode drivers turn that string into the cookie ABL
 * reads, exactly as `adb reboot bootloader` does.
 *
 * Deliberately freestanding (no libc) and deliberately argument-free: the
 * target string is fixed, so this binary can never request another mode
 * (e.g. "edl"). If the syscall returns, it exits with status 1 and the
 * caller's fallback runs.
 *
 * Build (WSL): aarch64-linux-gnu-gcc -Os -static -nostdlib -ffreestanding \
 *                -fno-stack-protector -o fs-reboot fs-reboot.c
 */
#define SYS_reboot        142
#define SYS_exit           93
#define REBOOT_MAGIC1     0xfee1deadUL
#define REBOOT_MAGIC2     672274793UL
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

void _start(void)
{
	sys4(SYS_reboot, REBOOT_MAGIC1, REBOOT_MAGIC2, REBOOT_RESTART2, (long)target);
	sys4(SYS_exit, 1, 0, 0, 0);
	for (;;)
		;
}
