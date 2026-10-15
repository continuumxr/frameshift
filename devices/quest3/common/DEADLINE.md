# PID 1 deadline: independent of HOST_ACK and of collection

**Answers:** FS-R-006 §5 D:
- keep the PID 1 deadline independent of HOST_ACK and collection;
- test that the new acknowledgement path cannot cancel it;
- recover immediately after collecting the result (300 s is a ceiling).

**Status:** offline, revision 5 (fix round 6, 2026-10-09).
- **Revision 5** (images review N2): the stage-1 **magenta LED** before the
  no-host-ack reboot is restored (`led 255 0 255`, the caller's fork-free
  sysfs writer). `/sys/class/leds` cannot hold a FIFO, so "reboot first"
  still holds for every host-writable path. `sync` stays dropped: nothing
  persistent is mounted (§2 property 3). Whole-image fixtures check the LED
  (`s2-no-ack`, `s3-no-ack`).
- **Revision 4** (second review S1): the clock is a replaceable file.
  Changes:
  - strict number parsing, so leading zeros can no longer abort PID 1;
  - a second, file-independent clock;
  - `set +eu`;
  - the clock read is type-checked first.
- **Revision 2** fixed adversarial review findings:
  - **B1:** a single `mkfifo` stopped both timers;
  - **S5:** a fork failure kills PID 1;
  - **S7:** a false claim about stage 1.
- **Revision 3** (coordinator): PID 1 now `exec`s a never-exiting reboot
  helper, `fs-reboot-final`, so its reboot needs no fork (§2, property 3a).

`target/pid1-hold.sh` passes its harness, 31/31. The stage-1 image and its
`init.sh` are **not** changed. The stage-2a and 3a inits source this file.

## 1. How stage 1 does it today (`devices/quest3/stage1/init.sh`)

| line | code | effect |
|---|---|---|
| 26 | `DEADMAN=300` | |
| 98–105 | `( sleep "$DEADMAN"; echo … >> /run/fs.log; /bin/fs-reboot; reboot -f ) &` | dead-man subshell started at INIT_STARTED |
| 25, 276–291 | PID 1 polls `/run/host_ack` once a second. With no valid ack within `ACK_WINDOW=150` s of SHELL_READY it calls `reboot_bootloader` | |
| **283** | `kill "$DEADMAN_PID"` on a valid ack | **HOST_ACK cancels the dead-man** |
| 286 | `hold` | after HOST_ACK, PID 1 waits for ever |
| 76–83 | `reboot_bootloader`: `echo … >> /run/fs.log; sync; /bin/fs-reboot; …` | **writes to /run before rebooting** |
| 86–90 | `fail()`: wait until T0 + `ERR_DELAY` (60 s), then reboot | |

This was intended for stage 1: FS-R-005 counted "continued operation beyond
the 300-second dead-man interval" towards the PASS. For stage 2 it is what
FS-R-006 §5 D forbids.

**Further weaknesses, all fixed below:**
- **Any root process can end the dead-man.** The shell on ttyGS0 is root.
- **Both stage-1 timers write to `/run/fs.log` before rebooting**
  (lines 101 and 77). Revision 1 of this file kept that shape. The review
  showed (B1) that one `mkfifo /run/fs.log` from the host shell blocks
  **both** timers in `open()` until a reader appears. Neither fires.
- **Correction (S7).** Revision 1 said an unreadable `/proc/uptime` would
  abort the stage-1 PID 1 shell. **That is false.** In ash
  `$(( $(up) - T0 ))` with an empty `up` is `$(( - T0 ))`, a valid
  (negative) expression. The shell survives. The real effect: `fail()`'s
  ERR_DELAY wait and the ack-window reboot never fire, because the
  elapsed time stays negative. The dead-man still covers both, being an
  independent `sleep 300`.
- **A failed fork kills PID 1 (S5).** busybox ash exits when `fork()`
  fails, for example under RLIMIT_NPROC or memory pressure, and PID 1
  exiting is a kernel panic. The stage-1 loop forks every second
  (`$(up)`, `sleep 1`).

## 2. The change (`target/pid1-hold.sh`)

```sh
. /lib/fs/pid1-hold.sh
FS_RUN=/run FS_UPTIME=/proc/uptime FS_REBOOT_FINAL=/bin/fs-reboot-final \
  FS_REBOOT_BIN=/bin/fs-reboot FS_REBOOT_FALLBACK="reboot -f"
fs_hold_init "$DEADLINE" "$ACK_WINDOW"   # first, before any host shell: fixes T0, logs the armed deadline
fs_start_backstop                        # at INIT_STARTED, before any module is loaded
...                                      # modules, USB, gadget, helpers, shell (as stage 1)
fs_hold_loop                             # after SHELL_READY; replaces stage-1 §7 (never returns)
```

The stage-2a init must route **every** timer-driven reboot after
SHELL_READY through `fs_reboot_pid1` (in PID 1) or `fs_reboot` (in the
backstop child). The stage-1 `reboot_bootloader` (log
first) may only be used before the host shell exists, for example in
`fail()`.

**Properties, each with a fixture (§3):**

1. **The deadline is fixed once.**
   - `FS_DEADLINE` and `T0` are assigned only in `fs_hold_init`.
   - The deadline is clamped to ≤ 299 s; the backstop fires at + 1 s, so
     ≤ 300 s.
   - The ack window is clamped to ≤ the deadline.
   - Garbage becomes the maximum, never "no deadline".
2. **Nothing cancels or extends it.**
   - No `kill` in the file.
   - ~~No file that PID 1 reads moves it.~~ **Withdrawn (second review
     S1):** the uptime *file* can lie. A bind-mounted frozen or forged
     `/proc/uptime` stops or shifts the primary clock. Two clocks do not
     read any file:
     - the loop-iteration counter (property 9);
     - the backstop's `sleep` (a kernel timer).
   - HOST_ACK is only recorded.
   - The deadline is checked first in each iteration.
   - PID 1 cannot be killed by a signal it has no handler for.
3. **Reboot first (B1).**
   - `fs_reboot REASON` runs `$FS_REBOOT_BIN` as its **first command**,
     then the fallback (`reboot -f`).
   - Only if both return does it append a note to the log (guarded as in
     property 4), then wait for ever.
   - The backstop is exactly `( sleep N; fs_reboot backstop ) &`.
   - **Nothing under /run or /dev is opened or written on the way to the
     reboot syscall**, on either path (static check `static-reboot-first`).
   - The reason is therefore not logged at reboot time. The deadline,
     the ack window and the backstop time are logged when they are
     **armed** (`fs_hold_init`, `fs_start_backstop`), before the host
     shell exists. The host knows which event it triggered (collected),
     and the observer sees when the gadget disappears.
   - `sync` is dropped: no persistent filesystem is mounted.

3a. **PID 1 reboots by `exec`, not fork (revision 3).**
   - The three PID 1 reboot sites (deadline, collected, no-host-ack) call
     `fs_reboot_pid1`. It runs `exec "$FS_REBOOT_FINAL"` as its last
     action, so PID 1 *becomes* the helper. Exec replaces PID 1 without
     exiting, and needs no fork.
   - **`src/fs-reboot-final.c`** is freestanding (no libc, 808 bytes),
     like `stage1/fs-reboot.c`:
     1. `reboot(RESTART2, "bootloader")`;
     2. if that returns, `reboot(RESTART)`;
     3. if that returns too, `nanosleep` in a loop for ever.

     It **never exits**. `fs-reboot.c` calls exit(1), which as PID 1
     would panic the kernel (crash-dump mode with `download_mode=1`).
     The mode string is fixed. "bootloader" is the only one in the binary,
     and argv is ignored.
   - `tools/build.sh` enforces it from the disassembly. Since revision 4,
     `tools/check_final.py` simulates the code and asserts every syscall
     argument: magics `0xfee1dead`/`0x28121969`; `0xa1b2c3d4` with a
     pointer to `"bootloader\0"`; then `0x01234567`, 0; then
     `nanosleep(&{3600,0}, NULL)` in a closed loop re-entered with
     identical arguments. The qemu `-strace` fixture checks the same
     values at run time:
     - exactly 3 syscalls, `142, 142, 101` (reboot, reboot, nanosleep),
       with the last in a loop;
     - no exit syscall number;
     - no other mode string;
     - a bit-identical rebuild.
   - **The exec is guarded.** ash exits with 127 when `exec` fails (checked
     under qemu), and for PID 1 that would mean a panic. So
     `fs_reboot_pid1` execs only if the helper is a regular, executable,
     non-symlink file. Otherwise it falls back to the forking `fs_reboot`.
   - The backstop is a child, not PID 1, so it keeps fork-exec of the
     normal `fs-reboot` (its exit(1) is harmless there).
4. **No blocking on host-writable paths (B1).** In the loop:
   - **Reads:** a file is read only if `[ -f ]` (and not a symlink), and
     through `read -r -t 1 <>`. An `O_RDWR` open never blocks on a FIFO,
     and the read times out after 1 s.
   - **`fs.collected`:** tested with `[ -e ]`; any type counts and is
     never opened.
   - **Appends** (`fs.log`, `fs.stages`, `fs.acked`): only to a regular
     file or to a name that does not exist (`_fs_put`). Never to a FIFO,
     device or symlink.
   - The loop does not call the caller's `log`/`stage`. Those write
     `/dev/kmsg` and `/dev/pmsg0` unguarded and are for the pre-shell
     phase only.
   - **Residual risk (check-then-open, for appends AND reads):** if the
     host swaps a FIFO or a device in during the microseconds between the
     type test and the open, the loop can still block. This applies to an
     append, and to the read of `host_ack`, the tick FIFO or the clock
     file (the `host_ack` and tick reads open O_RDWR and time out after
     1 s; the clock read opens O_RDONLY). The backstop writes nothing and still reboots
     one second after the deadline (fixture `fifo-stalled`: PID 1 stuck
     and `fs.log` a FIFO, so only the backstop is left, and it fires).
5. **Fork-free loop (S5).**
   - The clock is the `read` builtin on `/proc/uptime`.
   - The 1 s pause is `read -t 1` on a private FIFO (`$FS_RUN/.fs-tick`,
     made at init). `sleep 1` is used only if that FIFO is gone.
   - Tests, arithmetic and appends are builtins.
   - Fixture `fork-free-loop`: after the ack, the simulated PID 1's only
     child in 3 s is the backstop. The revision-1 loop showed 4.
   - **Residual risk** (revision 3; the reboot fork is gone, property 3a):
     - the `sleep` fallback forks (only if the private tick FIFO is gone);
     - the fallback `fs_reboot` forks (only if `fs-reboot-final` is
       missing or not executable);
     - an `exec` that fails despite the `-f`/`-x` check (ENOEXEC, ENOMEM)
       ends PID 1;
     - `led` and the init code outside the loop fork.

     If a fork fails at that moment, ash exits, the kernel panics, and
     with `download_mode=1` the device enters crash-dump mode: the
     recovery table's manual route.
   - RLIMIT_NPROC cannot contain the children: the steps run as root,
     and root is exempt from RLIMIT_NPROC. Step runners avoid fork-heavy
     programs. The Valve steps do not fork.
6. **Host input only shortens the hold.**
   - `fs.collected` reboots within about 1 s. The collector runs
     `target/fs-done` as soon as it holds a valid record or decides
     INCONCLUSIVE. `fs-done` now reports `queued` only if the write
     really succeeded.
   - No ack within the window also reboots at once.
7. **Two independent timers.**
   - The PID 1 loop.
   - A backstop child, started at INIT_STARTED, that covers PID 1 being
     stuck before its loop (for example in a hung `insmod`).
   - Killing the backstop's `sleep` makes it fire early. Killing the
     backstop subshell leaves the loop.
   - With the B1 fix, one FIFO can no longer silence both.
8. **Clock fail-safe.**
   - An unreadable "now" counts as 999 999: reboot.
   - An unreadable T0 counts as 0: measured from boot.
   - **Strict numbers (revision 4).** Every number that reaches `$(( ))` or
     a test comes through `_fs_num`: `0` or `[1-9][0-9]{0,8}`, nothing
     else. That covers the clock, T0, DEADLINE and the ack window.
     - Before, `09.00` (or a caller's `DEADLINE=08`) reached ash
       arithmetic as invalid octal. Ash raised "arithmetic syntax error"
       and **exited** (rc 2), and for PID 1 that is a panic. Now such a
       value takes the fail-safe fallback: "now" means reboot, T0 means 0,
       DEADLINE means 299.
     - More than 9 digits is refused the same way.
     - Audit: the only `$(( ))` operands are `_fs_t`, `T0`, `_s0`,
       `FS_DEADLINE`, `_fs_n` and constants, all produced by `_fs_num` or
       by arithmetic on such values.
   - The clock is read only if `[ -f ]`, with `read -t 1`. A FIFO is not
     read.
     - `read -t 1 <>` (as the review suggested) is not used for the
       clock. `/proc/uptime` is mode 0444, so the O_RDWR open would fail
       unless DAC override applies. A failed open reads as "unreadable",
       i.e. an immediate reboot on every boot. The type check avoids that
       dependency.
9. **Second clock: loop-iteration counter (revision 4).**
   - `_fs_n` counts loop iterations. Each lasts about 1 s (the tick-FIFO
     `read -t 1`). It starts from the elapsed time the clock reports at
     loop start, if that is sane, else from 0.
   - PID 1 reboots (`deadline-ticks`) when `_fs_n` reaches the deadline.
   - **It does not read any file.** Flooding the tick FIFO only makes it
     faster (earlier). A forged clock can only make it start later than 0
     (earlier again).
   - It runs late by the extra time an iteration spends in its other
     bounded reads (at most 1 s for `host_ack` before the ack, and 1 s for
     the clock). Worst case it fires at about loop start + 3 × DEADLINE.
     The backstop's kernel timer stays the tight bound.
   - Fixture `frozen-clock`: the clock file frozen from the start, the ack
     sent, **the backstop killed**. Revision 3: no reboot at all.
     Revision 4: `deadline-ticks` at ~11 s for a scaled 8 s deadline.
10. **`set +eu` (revision 4).** `fs_hold_init` and `fs_hold_loop` run
    `set +eu`, so a future init using `set -eu` cannot end PID 1 through a
    nonzero `read -t` or an unset variable. Fixture `set-eu` (preventive:
    the busybox used also passes it without the line).

**Choosing the numbers (for FS-A-007).**
- DEADLINE must cover:
  - boot to SHELL_READY;
  - the verify exchange;
  - Σ over steps of (step timeout + grace + 3 s reap + 3 s stray hunt +
    1 s drain);
  - a margin.
- DEADLINE must not exceed 299 s.
- The normal path ends at `fs-done`.

**Not covered by any userspace timer.**
- A kernel hang or panic: the manual route, outcome [C].
- The software-watchdog decision (FS-R-006 §5 E) is **decided: none**
  (J-49). A software watchdog does not protect against kernel hangs, and
  the SoC watchdog would need correct petting and would add a failure mode.
  Protection is this deadline, the `fs-reboot-final` exec path, the
  backstop, and the PM's manual recovery: expected, not guaranteed
  (`devices/quest3/RECOVERY.md`).

## 3. Fixtures (`tools/fixtures-deadline.sh` → `fixtures/deadline/`)

**How the harness runs:**
- The real `pid1-hold.sh` runs under qemu-aarch64, executed by the
  reviewed stage-1 busybox.
- **Only the reboot syscall is faked.**
  - `FS_REBOOT_BIN` and `FS_REBOOT_FALLBACK` are scripts that append
    `<uptime> <reason> pid=<pid> via=fork` to a record file **outside**
    the simulated `/run`, then return as a failed syscall would.
  - `FS_REBOOT_FINAL` is a script that records `via=final` with its pid,
    then never exits.
  - Every scenario checks that PID 1's own reboots are `via=final` **with
    the simulated PID 1's own pid** (exec, no fork), and that backstop
    reboots are `via=fork` from another pid.
  - Everything the real path does before and after the syscall runs.
- For revision 1, the sim also supplies a stage-1-shaped
  `reboot_bootloader` (log to `fs.log` first, `sync`, helper).
- Times are scaled: deadline 8 s, ack window 4 s.

**Before/after:**
- **Before:** revision 1 (commit `e890a7a`), the same harness, `HOLD=`
  that file.
- **After:** this revision.

| scenario | host actions | required first reboot | rev 1 | rev 2 |
|---|---|---|---|---|
| `no-ack` | none | `no-host-ack` at T0+4…6 | PASS | PASS |
| `ack-holds` | ack at ~1 s | `deadline` at T0+8…9 (the ack does not cancel it) | PASS | PASS |
| `ack-late` | ack at 3.5 s | `deadline` at T0+8…9 | PASS | PASS |
| `cancel-attempt` | ack; second token; delete `fs.acked`/`fs.stages`; write `0` into `fs.deadline deadline DEADLINE fs.cancel cancel T0`; kill the backstop subshell | `deadline` at T0+8…9 from the loop | PASS | PASS |
| `ack-collected` | ack, then `fs.collected` | `collected` at T0+3…6 | PASS | PASS |
| `done-no-ack` | `fs.collected` only | `collected` at T0+2…5 | PASS | PASS |
| `malformed-ack` | ack `XYZ!` | `no-host-ack` | PASS | PASS |
| `fifo-ack` | `host_ack` is a FIFO | not read, no hang; `no-host-ack` | PASS | PASS |
| **`fifo-collected`** | `fs.collected` is a FIFO | `collected` | **FAIL** | PASS |
| **`fifo-logs`** (B1) | `fs.log`, `fs.stages`, `fs.acked` become FIFOs, then the ack | `deadline` at T0+8…9 | **FAIL: no reboot at all** | PASS |
| **`fifo-stalled`** (B1) | PID 1 stuck before its loop **and** `fs.log` a FIFO | `backstop` at T0+9…10 | **FAIL: no reboot at all** | PASS |
| `stalled-pid1` | PID 1 stuck before its loop | `backstop` at T0+9…10 | PASS | PASS |
| `backstop-sleep-killed` | only the backstop's `sleep` killed | `backstop`, early | PASS | PASS |
| `clock-unreadable` | uptime path missing | reboot within 2 s | PASS | PASS |
| `fork-count` + **`fork-free-loop`** (S5) | ack, then count PID 1's children for 3 s | `deadline` on time; only child = backstop | **FAIL (4 children)** | PASS (1) |
| `stage1-control` | the stage-1 dead-man code, ack at 1 s | negative control: no reboot within deadline + 3 s | PASS (bug detected) | PASS (bug detected) |
| `static-no-kill`, `static-assign-once`, `static-clamp` | — | as named | PASS | PASS |
| **`static-reboot-first`** (B1) | — | `fs_reboot` starts with the helper; the backstop is exactly `sleep; fs_reboot` | **FAIL** | PASS |
| **`static-pid1-exec`** (rev 3; 4 sites in rev 4) | — | all PID 1 reboot sites use `fs_reboot_pid1`, which execs only after the `-f`/`-x` check | — | PASS |
| **`strace-exec`** + **`pid1-exec-no-clone`** (rev 3) | ack; the simulated PID 1 runs under `qemu-aarch64 -strace` | `deadline` via=final; **0 `clone` calls** by PID 1 between its READY write and `execve(fs-reboot-final)` | — | PASS |
| **`pid1-real-final`** (rev 3) | ack; `FS_REBOOT_FINAL` = the **real** `build/fs-reboot-final` (reboot fails unprivileged: EPERM) | at deadline+4 s the PID 1 process is still alive, now as `fs-reboot-final`; it never took the fork path | — | PASS |
| **`fs-reboot-final-never-exits`** (rev 3) | `qemu-aarch64 -strace build/fs-reboot-final`, unprivileged; killed by the harness after 4 s | RESTART2 (`0xa1b2c3d4`, "bootloader") then RESTART (`0x01234567`), both EPERM, then `nanosleep`; alive after 4 s; no exit call | — | PASS |
| **`frozen-clock`** (rev 4, S1a) | the clock file frozen at `5.00`; ack; **backstop killed** | `deadline-ticks` (loop counter) at start+8…12 | rev 3: **FAIL (no reboot at all)** | PASS |
| **`octal-clock`** (rev 4, S1b) | the clock file becomes `09.00` mid-run | `deadline` (fail-safe) at start+1…6; the shell does not exit | rev 3: **FAIL (shell exited: arithmetic syntax error)** | PASS |
| `huge-clock` (rev 4) | the clock becomes 20 digits | `deadline` (fail-safe) at start+1…6 | rev 3: PASS (guard) | PASS |
| `set-eu` (rev 4) | the sim runs `set -eu` before `fs_hold_init`; ack | `deadline` at T0+8…9 | rev 3: PASS (preventive) | PASS |
| **`static-clamp`** (rev 4 cases) | `fs_hold_init "08 04"`, `"1234567890 5"`, `"010 009"` | 299/150, 299/5, 299/150, with no arithmetic error | rev 3: **FAIL (the shell died at "08 04")** | PASS |
| **`fs-done-honest`** (nit) | `fs-done` into a writable and a missing directory | `queued` rc 0 / `error=write` rc 1 | rev 1 printed `queued` unconditionally (by inspection; its path was hard-coded) | PASS |

**Totals:**
- rev 4: **31/31** (`fixtures/deadline/RESULTS.txt`). Every reboot scenario
  also checks via=final or via=fork.
- rev 3 (`05a2dd2`) in the rev-4 harness: 27/31 (`fixtures/review2-before/`).
- rev 2: 22/22.
- rev 1: 16/21 in the revision-2 harness (`fixtures/review1-before/`; the
  `fs-done` check is not runnable against rev 1).

**Limits:**
- qemu-user is not the Quest kernel.
- PID 1's immunity to signals is not reproduced (the simulated "PID 1" is
  an ordinary process, and the fixtures never kill it).
- Uptime is whole seconds, so windows are ±1 s.

## 4. Stage 3b (FS-R-010 §6)

The stage-3b image uses this file unchanged (`pid1-hold.sh` rev 5, pinned), with
`DEADLINE=200` (backstop 201 s) in `stage3b/init.sh`. The number comes from the
implemented bounds (`stage3b/tools/check-timing-3b.py`, `stage3b/IMAGE.md` §4):
runner worst case W = 74.4 s (both supervised display runs, the bounded probe
waits, the 2 s pause, encoding and the paced emission of the maximum 2070-line
record at 20 lines per 0.1 s), host record budget B = 85 s (with a 25 s planning
collector start), and the collector's immediate runner guard of 75 + 5 + 11 = 91 s. The stage-3b runner's pacing loop and its waits use the
same fork-free `read -t` on a private FIFO as property 5 here
(`common/target/fsb1-pace.sh`, `stage3b/fs-display.sh`, `stage3b/fs-probe.sh`).
