/* SPDX-License-Identifier: Apache-2.0
 * fs-poweroff-final — PID 1's power-off helper on the TRIP branch
 * (emergency-shutdown-design.md §5.2, §6.1; EXEC-SPEC.md E-20).
 *
 * PID 1 `exec`s this as its LAST action when the stage guard (fs-thermald
 * --stage) writes TRIP, and the initramfs gate's init execs it on a refusal.
 * Because it then IS PID 1 it never exits: reboot(POWER_OFF); if that
 * returns an error, reboot(RESTART); then nanosleep for ever.
 *
 * Freestanding (no libc), argv ignored, no string at all, exactly three
 * syscalls (checked from the disassembly by tools/check_poweroff.py and by a
 * qemu -strace fixture). Same structure as devices/quest3/common's
 * fs-reboot-final, with POWER_OFF in place of RESTART2 "bootloader".
 */
#include "poweroff_final.h"

void _start(void) __attribute__((noreturn));
void _start(void)
{
    fs_poweroff_final();
}
