# Stage 2a boot image: experiment (i), the four pinned Valve files

**Status:** built and fixture-tested **offline only**, fix round 6 of
2026-10-09. That round followed three package reviews of `cf251bb`. Its
host, common and stage-3a changes are listed in §10. No device, adb,
fastboot or COM port was used.

**Not proposed for a device.** It is the candidate image for FS-A-007,
which needs the Chair's concurrence and then the PM's live sign-off.

**What it is.** A `fastboot boot` image for Unit 1 (Quest 3, v66,
slot A). It extends the **proven stage-1 image**
(`efefe10dd241fa3525da7b7602b54a47976d6bfb36f27a5dddbb62c0fdf67250`,
FS-R-005) with:
- the common PID 1 deadline;
- `fs-supervise`;
- FSB1;
- the eight OUTCOMES §2 steps over the four T1 files (`T1-PINS.md`), the
  last of which, `inv`, is informational.

**Licensing.** The image carries Valve binaries (glibc LGPL, coreutils
GPL-3). It stays in the gitignored `build/` and with the PM and the Chair.

**Tags:** [M] hardware output · [M-static] named artifact · [D] derivation
· [C] hypothesis · [O] open.
- **Fixture runs** (qemu-user, bwrap, WSL) are [D] evidence about
  user-space behaviour under the WSL kernel. They are not [M], and they are
  not the Quest kernel.

**Recovery:** `devices/quest3/RECOVERY.md`.

## 1. The image

| | |
|---|---|
| file | `build/stage2a/20261009T085209Z-93a1501f0b1fb692/boot-stage2a.img` (gitignored) |
| SHA-256 | **`e8775c893b5a4b3785dbf7e3715820cb3c7aba2e1a1e560567d067c26a2451e5`** |
| size | 43,823,104 B |
| nonce | `93a1501f0b1fb692` (USB serial `FS-93a1501f0b1fb692`). **One attempt only**; `fs-observe.ps1` enforces it through the ledger `build/stage2a/attempted` |
| builder | `stage2a/build-image.sh` `e5ce736603263ef8697dfa2ea95dbb2dde657e9d9d1a235d18260a32fbaeb456`. Its records sit beside the image: `MANIFEST.txt`, `elfpin-check.txt`, `ramdisk-scan.txt`, `gitcheck.txt`, `header-diff.txt`, `ramdisk.sha256` |
| stock boot | `49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50` |
| kernel | `f34165b35a826052ce5b520d9313387c96970b498733f1a7b141dcf4afc94e7b`, byte-identical to stock (AOSP re-unpack) |
| header | only `ramdisk size` and `boot.img signature size` (4096 → 0) differ from stock |
| ramdisk | `ramdisk.lz4` `112fe7e78e59a282c30d748d832d9272a46772815ba8a272290a17a2d1a772e3` (2,607,481 B). cpio `c31f336d83aaf54bee70eb5d96c9cc229945b6c27fc1914cce722f4e3cbe16f0` (4,756,992 B): `newc`, uid/gid 0, mtimes 0, `--reproducible` |
| vendor_boot | unchanged stock `1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf`. Its modules list `1ec0253fa9b80e7121722259ab9d6de0f1c4e5015846fea4737cd14af80a6745` (97) and file list `403e891e9eb71e638afe1fceb715f87d6da02cfe4b12df2253c33efddae1c040` (111) are pinned |
| E1 | AOSP mkbootimg `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` CLEAN, helper `host/fs-gitcheck.sh` `adbe27e92be16da5d2d8a2bc8f3ea35bd2040cd41ed38068c1360030433487e8`. **MANIFEST "E1 notes": `NOTE: mode bits not checkable here: skip (drvfs without metadata: no exec bits)`.** Mode bits cannot be checked on this `/mnt/c` checkout |
| tools recorded | `T1-pins.json` `0cb7de7575dc473c9213b0fa6a7f833980c2f27f6e6d53f8b828559f718645d8`; `elfpin.py` `51787b5d7bab7f7ed337729a74081fd89ac3f18dc5a3279f7a71c23246dd6cbe`; `t1-ramdisk-scan.sh` `73e969caf90418c6dd0ab9c06f10570ba6656f7472db6e337a3f24af3d28c524` |
| reproducibility | two builds with the same nonce and stamp give a **bit-identical image** (`test-builder.sh` `repro-same-nonce`) |
| superseded | in `build/stage2a-superseded/`, not for use: `cc77eb4279b668fec1887852174a54a1c0f6f0301ebef7e584dcaa15e465195a`, `b8d5e2072a60e6ed5dbd6d591f882d3042e9eb7dd91e7458a01c3d80211e10be`, `8dba7ada039158e42c6cf0eb87bb33e3c34a7167a4f56248f8dfa50768f5eee2` (`cf251bb`), and `2dc073bf805ffe7284494826e6214acd1246dc0a1f6feb9057ea797eb6128219` (round 6 before the scan-label fix) |

### Contents (our ramdisk; the vendor ramdisk is stock)

Directories: `bin config dev lib lib/fs proc run sys tmp valve valve/bin valve/lib`.

| path | size | SHA-256 | source |
|---|---|---|---|
| `/init` | 11,221 | `62ccd23266835905c7ccf13b2a343a2796b852781f895fed885f75f22e25a6bb` | `stage2a/init.sh` `357490c771a5e732135e9ad9f290da42ee8f693461dd95881d2f15cdc9210963`, nonce substituted |
| `/bin/busybox` | 1,981,032 | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | stage-1 busybox 1.37 (reviewed) |
| `/bin/fs-reboot` | 1,400 | `c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29` | stage-1 helper (backstop child only) |
| `/bin/fs-reboot-final` | 808 | `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` | `common/build`. Build record: `common/build-record/` |
| `/bin/fs-supervise` | 676,952 | `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74` | `common/build`. Build record: `common/build-record/BUILD.txt` |
| `/bin/fs-valve` | 4,405 | `2334c0aaf461feea9d7209392b6163892d86cbb92752321619402491dd82130d` | `stage2a/fs-valve.sh` |
| `/bin/fs-inv` | 1,750 | `367f311dad21311a11d1f317d6b98a72e049b9af4e2e7ab0d01f2b6a174b4aed` | `stage2a/fs-inv.sh` |
| `/bin/fs-done` | 705 | `7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959` | `common/target/fs-done` |
| `/lib/fs/pid1-hold.sh` | 7,556 | `4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4` | `common/target`, **rev 5** (magenta LED on no-host-ack) |
| `/lib/fs/fsb1-enc.sh` | 4,943 | `11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7` | `common/target`, rev 5 (empty line before the record) |
| `/valve/lib/ld-linux-aarch64.so.1` | 204,048 | `2ddc56a02f476765a21e31d69144e68bee933950fe613747d54b87a2369a037e` | Valve rootfs-A `/usr/lib/ld-linux-aarch64.so.1`, build `20260922.6152327` (T1-PINS §1–2) |
| `/valve/lib/libc.so.6` | 1,722,992 | `be7ee393429d493c4d3b996ed25cbb02fabb2896a77efe6d57e5993ead5bbb3b` | Valve rootfs-A `/usr/lib/libc.so.6` |
| `/valve/bin/uname` | 67,856 | `4295f034edf7d62f721cfe994230ba139646c7872dc2a6899aa681f76fca31f1` | Valve rootfs-A `/usr/bin/uname` |
| `/valve/bin/b2sum` | 67,864 | `90154680070cfcb2a3027b8fa26a8091d24333329294a2f4be7a12c7f11f6402` | Valve rootfs-A `/usr/bin/b2sum` |

At boot, init writes `fs-verify`, `fs-ack` and `fs-status` into RAM. They
are identical to stage 1.

## 2. What the builder enforces (`build-image.sh`)

On any failure it exits nonzero and publishes nothing.

1. **E1** (`host/fs-gitcheck.sh`). Its NOTE lines are carried into
   `gitcheck.txt` and the MANIFEST (round 6). The AOSP Python runs with
   `-E -s -B -X pycache_prefix`.
2. **Pinned SHA-256 of every input:**
   - the stock images and kernel;
   - the modules list and the vendor file list;
   - busybox, fs-reboot, fs-reboot-final and fs-supervise;
   - the common scripts (`pid1-hold.sh` rev 5, `fsb1-enc.sh` rev 5,
     `fs-done`);
   - `T1-pins.json`;
   - the four Valve files (builder **and** JSON pins; regular files only).
3. **Valve files, binaries and scripts:**
   - `elfpin.py check`;
   - static-ELF checks on our helpers;
   - every applet used is present, and there is no BLAKE2 applet;
   - the scripts are LF only, with the `#!/bin/busybox sh` shebang.
4. **Ramdisk:**
   - **the exact path list.** An injected extra file is refused:
     `test-builder.sh` `inject-extra-file`, round 6;
   - no symlinks;
   - only directories are shared with the vendor ramdisk;
   - the union lacks the loader paths;
   - exactly 8 ELF files.
5. **`t1-ramdisk-scan.sh` on the final image** (its labels now name
   `boot-stage2a.img`):
   - the only BLAKE2 hits are `/valve/bin/b2sum` and the `b2sum` path
     string in `/bin/fs-valve`;
   - the vendor ramdisk has no hit;
   - AF_ALG hash is off in the kernel.
6. **Repack** with the stage-1 method. The cpio is `--reproducible`.
   - The re-unpack must show unchanged kernel bytes, only the two intended
     header fields changed, and every file in the image equal to its
     staged copy.
7. **`MANIFEST.txt`** with full hashes. `FS_TEST_*` inputs (negative and
   reproducibility fixtures only) are marked `TEST OVERRIDES`.
   `fs-observe.ps1` and `test-image.sh` refuse such images.

## 3. What it does, step by step (PID 1 = `/init`)

1. **Stage-1 §0, unchanged.**
2. **Deadline first.** `fs_hold_init 260 150`: deadline T0+260, backstop
   T0+261, ack window 150 s after SHELL_READY.
3. **`INIT_STARTED`, then the backstop child.**
4. **Stage-1 §2–§6** (97 modules, USB role, ACM gadget `FS-<nonce>`, the
   helpers, the shell), unchanged except the product string. `fail()`
   reboots at T0+60 (red LED).
5. **`fs_hold_loop`:**
   - HOST_ACK is only recorded (white LED);
   - it reboots by exec of `fs-reboot-final` at the deadline, after the
     ack window with no ack (**magenta LED first, as in stage 1**), or
     about 1 s after `fs-done`.
6. **Host:** the `fs-valve` runner and its steps (§5).
   - `fs-observe.ps1` boots (no session).
   - `fs-collect.ps1 -Stage 2a` runs verify, ack, status, `fs-valve` once,
     then `fs-done`.
   - `fs-classify.ps1 -Stage 2a -ObserveDir` classifies.

## 4. Timing (one table; `tools/check-timing.py`: CONSISTENT, `fixtures/timing/after.txt`)

| quantity | value | source |
|---|---|---|
| T0 | PID 1 start, after the fastboot handoff Th | `pid1-hold.sh` |
| device deadline | **T0 + 260 s**; backstop T0 + 261 s | `init.sh` `DEADLINE=260` |
| ack window | **150 s** after SHELL_READY (stage 1's value) | `init.sh` `ACK_WINDOW=150` |
| error path | `fail()` at T0 + 60 s (stage 1's `ERR_DELAY`) | `init.sh` |
| host give-up | BootStartUtc + 260 − 15 = **BootStartUtc + 245 s** (BootStartUtc: taken before `fastboot boot` is invoked, ≤ T0; FS-R-007 B1) | `fs-collect.ps1 -Stage 2a` |
| host ack cap | pre-runner phases end by **BootStartUtc + 150 − 15 = BootStartUtc + 135 s**; the live start is refused with < 30 s of that left | `fs-collect.ps1` (e2e S1) |
| pre-runner phases (worst) | 76.5 s; collector start about BootStartUtc + 20 s (planning; the run-time guard enforces the real time) → by BootStartUtc + 96.5 s ≤ BootStartUtc + 135 s | `COLLECTOR.md` §4 |
| record budget B | 260 − 15 − 20 − 76.5 = **148.5 s** | |
| steps 1–7 | `-t 5`, grace 2: worst 15 s each (with reap 3, strays 3, drain 1, encoding 1) | `fs-valve.sh`, `fs-supervise.c` |
| step 8 `inv` | `-t 10`, grace 2: worst 20 s | `fs-valve.sh` |
| runner worst case W | **127 s** (spare 21.5 s; planning figure: the 20 s now includes the `fastboot boot` transfer (~11 s), so the spare is optimistic; the run-time guard enforces the real time (it decides whether a run proceeds, not safety)) | `check-timing.py` |
| measured (harness, qemu) | all steps < 1.5 s; reboot 0.1–0.6 s after `fs-done` (T0+8…24 s); no-ack reboot at SHELL_READY+150.2 s; deadline reboot at T0+260.4 s | `fixtures/image/` |

## 5. Expected FSB1 steps (`exp=stage2a`, `steps=8`; OUTCOMES §2)

`X = /valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib`

| i | id | program | expected on the device |
|---|---|---|---|
| 1 | `hash` | `-t 5`: `busybox sha256sum` of the 4 `/valve` files | `exited 0`, the 4 pins |
| 2 | `absent` | `-t 5`: `busybox sh -c 'for p in …'` | `exited 0`, empty |
| 3 | `diag` | `-t 5`: `X --list-diagnostics` | 2.39 stable, `/usr/lib/`, pagesize 0x1000, no `env[` |
| 4 | `list` | `-t 5`: `X --list /valve/bin/b2sum` | the anchored list rule (v1: three lines, the registered rule; v2A: optional first unnamed-map line, FS-R-009 §4, `LISTING-RULE-A.md`) |
| 5 | `uname` | `-t 5`: `X /valve/bin/uname -r` | `5.10.198-01402-g1c5986fe21ee\n` |
| 6 | `b2kat` | `-t 5`: `X /valve/bin/b2sum` < `/dev/null` | the BLAKE2b-512("") KAT line |
| 7 | `b2chal` | `-t 5`: `X /valve/bin/b2sum` < `chal.in` | BLAKE2b-512(`<nonce>:<challenge>`)`  -\n` |
| 8 | `inv` | `-t 10`: `busybox sh /bin/fs-inv` | informational sections; missing paths print `(absent)`/`(none)` |

## 6. Outcome mapping (OUTCOMES §6 rev 4; `fs-classify.ps1 -Stage 2a`)

First match wins:
1. stage 1 not PASS → that class;
2. no record, or rejected, or late → INCONCLUSIVE;
3. integrity mismatch measured → INTEGRITY FAULT;
4. integrity unmeasured → INCONCLUSIVE;
5. a Valve-step tool fault → INCONCLUSIVE;
6. any Valve step FAILED → COMPATIBILITY FAIL;
7. all OK → PASS.

**Step 8 `inv` is INFO:** noted, never escalated.

**The stage-1 class** comes from `fs-observe.ps1` (handoff, gadget) plus
the collector's verified FSV1 (`-ObserveDir`):
- DEVICE_REJECTED: the handoff was refused;
- PASS: FSV1 verified;
- TRANSPORT/SHELL FAILURE: the gadget appeared but no FSV1 verified;
- INCONCLUSIVE: otherwise.

**Collector terminal states** (round 6, all INCONCLUSIVE):
- a foreign ack, then the gated fs-done;
- a runner refusal (`FSVE1`), then the gated fs-done;
- the ack window reached, with nothing more sent.

## 6A. Thermal and the inventory's driver I/O (images review S2)

**Thermal statement.**
- The image runs the stock v66 kernel and does not change the CPU
  frequency governor. The effective default is **`performance`**: the
  config default is `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` [M-static,
  `firmware/quest3/extracted/v66_unit1_slotA/kernel.config`], but
  the bootloader passes `cpufreq.default_governor=performance` on the kernel
  command line [M, stage-1 serial log
  FS-A-005 (private review record), cmdline], and
  the command-line parameter takes precedence (`drivers/cpufreq/cpufreq.c`,
  `default_governor`, v2.7 source; v66 assumed the same [C]). So all
  clusters may sit at maximum during the hold. This is the same as stage
  1's accepted run, and it is why the hold is short, bounded and attended
  (PROJECT_SETUP §6A.2, §6A.4).
- There is **no fan policy**: the fan driver is not loaded or not driven.
- There is **no userspace thermal engine**.
- The kernel's own thermal mitigation (the DT CPU cooling maps) is
  whatever the 97 recovery modules and the built-in drivers provide. It is
  not verified here (FS-R-006 §4).
- The exposure is bounded in time:
  - the normal run lasts about 30 s from T0;
  - **every userspace path ends by T0 + 261 s**;
  - a kernel hang falls to the PM's manual route.
- Stage 1's "no thermal event reported" during its hold is **not**
  verified protection. It is the absence of a report in a short run.
- **Battery temperature is captured** before the attempt (in BA, a
  precondition: < 35 °C, level > 50 %) and after it (in AA; before/after
  state captures, tooling withheld). `RECOVERY.md` §4 says when the PM
  waits for cooling.

**`inv` risk statement.** Step 8 adds **new driver I/O** that stage 1
never did.
- **What it reads:**
  - `power_supply` uevents. For the battery this calls into the bq27 fuel
    gauge over I2C, which logs errors in stock Android too (FS-R-006 §4),
    and into the ADSP/glink-backed supplies;
  - remoteproc `name`/`state`;
  - `/proc/modules`.
- **What it does not do:** it writes nothing.
- **A wedged read** (an I2C timeout, a glink wait) is bounded:
  - by `fs-supervise` (TERM at 10 s, KILL 2 s later, report);
  - if the reading task sits in an uninterruptible sleep, by `unreaped`
    and the PID 1 deadline.
- **An oops in that path** would, with `PANIC_ON_OOPS=y` and
  `download_mode=1`, end in crash-dump mode. That is **manual recovery**
  (`RECOVERY.md` §4).
- **Assessed: low risk.** These are read-only attributes that stock
  userspace reads routinely. It runs **last**, after every
  outcome-bearing step, and cannot change the outcome.

## 7. Offline fixtures (round 6)

| suite | result |
|---|---|
| builder negatives + reproducibility `test-builder.sh` → `fixtures/builder/` | **11/11**: 9 refusals; `inject-extra-file` refused; `repro-same-nonce`, two builds giving one image `1ad79de02132884c163fc563e3e20523ecb6fdd50ecfed601f35a3f773f4ddde` |
| whole image `test-image.sh` → `fixtures/image/` | **10/10** (below) |
| host side `test-host.ps1` → `fixtures/image/host-results.txt` | **all PASS**. FSB1 PowerShell = Python; classifier outcomes; `fs-collect -Stage 2a -Replay` COLLECTED-VALID with no divergence; `fs-classify -Stage 2a` the same |
| timing `tools/check-timing.py` | CONSISTENT, including the ack-window checks |
| before/after (round 6) | `fixtures/round6-before/s2-no-ack-on-8dba7ada.txt`: the `cf251bb` image fails the new LED check (no magenta) and the 150 s ack window |

| scenario | result (harness: the image's own `/init`, bwrap + qemu, real timings) |
|---|---|
| `s2-pass` | VALID 8-step record, **PASS**; `inv` INFO with 5 sections; reboot `collected` by exec as pid 1, 0.5 s after `fs-done` (T0+24.0) |
| `s2-inv-absent` | `inv` prints `(none)`/`(absent)`; still PASS |
| `s2-tamper-forced` / `s2-missing-forced` / `s2-preload-forced` | INTEGRITY FAULT (rule 3) |
| `s2-hung-step` | steps 3–7 `timer-kill sig=9`; the record validates; reboot at T0+50.7 |
| `s2-no-ack` | `no-host-ack` at SHELL_READY+150.2; **LEDs 255 0 255 (magenta)** |
| `s2-ack-no-done` | `deadline` at T0+260.4; HOST_ACK did not cancel it |
| `s2-done-early` | `collected` within 0.1 s |
| `s2-no-udc` | `fail()`: `error-udc` at T0+60.3, nothing on the tty |

## 8. Changes from the stage-1 init (`stage1/init.sh`, image `efefe10dd241fa3525da7b7602b54a47976d6bfb36f27a5dddbb62c0fdf67250`), each justified

| # | stage 1 | stage 2a | why |
|---|---|---|---|
| 1 | dead-man subshell, cancelled by HOST_ACK; then hold | `fs_hold_init` / `fs_start_backstop` / `fs_hold_loop`; HOST_ACK only recorded | FS-R-006 §5 D |
| 2 | dead-man 300 s | deadline **260 s** (backstop 261 s) | the host's worst-case budget (§4); 300 s stays the ceiling |
| 3 | ack window 150 s, ERR_DELAY 60 s | **the same** (150 s, 60 s) | unchanged (round 6 restored 150) |
| 4 | no-ack: magenta LED, then `reboot_bootloader` | magenta LED, then exec `fs-reboot-final` | the LED restored (round 6); the exec: a PID 1 exit is a panic |
| 5 | `reboot_bootloader`: log, `sync`, fork `fs-reboot`, `reboot -f` | PID 1: exec `fs-reboot-final` (RESTART2 "bootloader", RESTART, sleep forever); the backstop child keeps `fs-reboot` | no fork and no file access before the syscall (common/DEADLINE.md §2); **`sync` dropped**: only tmpfs, proc, sysfs and configfs are mounted, so there is nothing to flush |
| 6 | `fail()`: wait, then `reboot_bootloader` | wait (same ERR_DELAY), log, exec `fs-reboot-final` | as 5 |
| 7 | dead-man started after `mdev -s` | the deadline armed before any module | T0 fixed first; the backstop covers a hung `insmod` |
| 8 | — | `/valve/{lib,bin}`, `/bin/fs-supervise`, `fs-valve`, `fs-inv`, `fs-done`, `/lib/fs/*.sh` | experiment (i), the inventory |
| 9 | product `FrameShift stage1` | `FrameShift stage2a` | identity |

Unchanged: §0 mounts and nodes, module loading, the USB role writes, the
gadget and its read-back, `fs-verify`/`fs-ack`/`fs-status`, and the shell.

## 9. Not exercised offline; open items

**Not exercised offline:**
- the Quest kernel's ELF loader, vDSO, hwcaps/ifunc and SIGILL risk;
- the 97-module load;
- configfs, the UDC, CDC-ACM and `usbser`;
- the live serial path and the live `fs-observe` boot;
- the real reboot syscalls;
- PID 1 signal immunity;
- `fs-supervise` `unreaped` and `capture-write-failed`;
- the real cost of the `inv` driver reads;
- thermal behaviour.

**Open:**
1. Round 6 was re-reviewed (no blocker); round 7 and the final-review host changes have fixtures but no further adversarial round.
2. The collector-start assumption (BootStartUtc + 20 s) is used by
   `check-timing.py`; it is not measured. Since FS-R-007 B1 it includes the
   `fastboot boot` transfer (~11 s), so the planning spare is optimistic. The
   run-time guard enforces the real remaining time: this affects whether a
   run proceeds, not safety.

## 10. Round 6 elsewhere (for reviewers)

- **`host/`:**
  - `fs-observe.ps1` (B1): sign-off gate, no session;
  - the collector: ack-window cap, foreign-ack stop, runner refusal,
    stage-3a pause;
  - `fs-classify -ObserveDir`;
  - the `.sh` E1 refuses symlink entries;
  - BOM on the `.ps1` files;
  - the before/after capture method (withheld).
- **`common/`:**
  - `pid1-hold.sh` rev 5 (magenta LED);
  - DEADLINE: the watchdog decided (none);
  - the FSB1-SPEC wording;
  - `build-record/`.
- **`devices/quest3/RECOVERY.md`** is new.
