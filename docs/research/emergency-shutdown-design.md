# Graceful emergency shutdown and thermal ownership (design, 2026-10-12)

> **Decisions for the PM: none open in this design** (revision 5). Every
> item below was decided by the PM on 2026-10-12 ("Approve all as
> recommended", J-122), **for design and harness work only**: nothing runs
> on a headset without its own review and the PM's sign-off, and the
> Chair classes (§7.3) still need the Chair.
>
> | item | what it means, in one line | decided (J-122) |
> |---|---|---|
> | **P12** shutdown time budgets | Valve: after a thermal shutdown starts, force our own power-off at 45/55 s; stage: power off within 3 s; jump straight there if temperatures keep rising (+5 °C SoC, +2 battery, +3 skin over Meta's SHUTDOWN line) | **approved** |
> | **P13** user-visible warning | show a warning (LED, state file, later a UI notice) at Meta's SEVERE level, at any sensor/fan fault and at 10 % battery; it never shuts anything down by itself | **approved** |
> | **P14** "unplug" notice | when a thermal shutdown happens with a charger attached, tell the user to unplug, because off-mode charging may heat the device again | **approved** |
> | **P15** sysrq `c` (deliberate panic) | Valve only: if our last power-off call comes back without powering off, force an immediate restart instead of waiting up to 30 s for the softdog | **approved** (Valve only; still a Chair class) |
> | **P16** Quest 2 stage-guard limits | the first Quest 2 trial's guard aborts at SoC ≥ 60 °C, board ≥ 40, battery ≥ 45, skin ≥ 40, far below Meta's limits, because a headless stage has no fan | **approved**, used only after the Q2-P1 idle readings confirm them |
> | **P17** softdog margins | the kernel's software watchdog restarts the device 30 s after our supervisor stops; after our last power-off call it gets one final 30 s, to be re-sized from the T5 measurement | **approved** (30 s provisional) |
> | **`pid1-hold.sh` change** | the reviewed stage PID 1 file gains a "power off on TRIP" branch, a guard-alive check and a second helper (`fs-poweroff-final`); it reruns its harness and review | **approved for design and harness work**; no image before its review is GO |
> | **Opening the softdog in S1** | the stage thermal guard also opens the software watchdog, so a hung guard or a hung kernel power-off still ends in a restart; on the Quest 2 this cannot be undone until reboot | **approved**; on the Quest 3 only after T0 reads `download_mode` = 0 |
> | **Quest 3 tsens/ADC module loads** | a longer Quest 3 stage hold needs three of Meta's thermal modules loaded so the guard can read temperatures; loading them programs volatile sensor thresholds | **deferred** until a longer Quest 3 hold is planned (the Quest 2 needs none) |
> | **P18** Meta config not in our reviewed list (rev 4) | if the headset's Meta thermal file has a hash we have not reviewed (for example a newer firmware), use our built-in values and tell the user, instead of applying the unreviewed file | **approved** (fall back) |
> | **How we read Meta's file** (rev 4) | read the small files (the thermal file, the VR-runtime list, `build.prop`) straight off the `super` partition, opened read-only, with our own read-only reader (option B), rather than creating a device-mapper device and mounting `vendor` read-only (option A) | **option B approved** (Chair class) |
>
> **Decided by the PM (J-118):** where the thresholds come from. **The
> PM's choice:** follow Meta literally where hardware-specific. Our
> supervisor reads Meta's thermal configuration from the user's own headset
> at runtime and applies Meta's thresholds and mitigation order. Nothing of
> Meta's is copied into the repo, and fixed values are used only as a
> fallback. Designed in §4.5 (revisions 4 and 5).
>
> **Decided (O28, PM 2026-10-12, J-123):** the public document may name Meta's
> interface identifiers (JSON keys such as `HotThreshold`, sensor names,
> mitigation token names), threshold numbers and hashes; never file contents.

> **For the Chair** (new action classes, §7.3; none proposed for a device
> yet): `reboot(POWER_OFF)` from our images (PID 1 in stage images and the
> initramfs gate, A2 in Valve) with the new helper `fs-poweroff-final` and
> the `pid1-hold.sh` change; Quest 3 tsens/ADC module load in a stage
> image; opening the softdog (S1, Valve); `sync()` of the writable layer
> (A1); `/dev/pmsg0` writes; sysrq `c` (P15); cmdline K4 / dump-mode
> parameter K5 (Quest 3); and, **new in revision 3**, the Valve-layer
> systemd hardening (no device write by itself, reviewed with the Valve
> integration): `CapabilityBoundingSet=~CAP_SYS_BOOT` and
> `RestrictRealtime=yes`/`~CAP_SYS_NICE` for every service, `JobTimeoutSec=`
> drop-ins on every shutdown target, masks of `soft-reboot.target` and
> `halt.target`. **New in revision 4**, a read-only class: our initramfs
> reads Meta's `vendor` logical partition. Option B (approved by the PM,
> J-122) opens
> the `super` partition `O_RDONLY` and parses it in user space: no mount,
> no device-mapper device, no write. Option A creates a transient
> dm-linear device and mounts `vendor` read-only. Either is the first
> read of a Meta partition by a FrameShift image, so it is listed (§7.3).
> Not proposed: `RESTART2 "shutdown,thermal"` (persistent PMIC write).

Agent report, 2026-10-12, **revision 5**. Adversarial review 4 (of
revision 4, `2ca58e6`) returned **GO for presentation once M1 and M2 are
fixed** (2 major, 10 minor, 3 nits); **every item is applied here** (table
"Revision 5 changes" below), one of them (m8) with a verified correction.
Its facts were re-checked against the local extracts and the Unit 2
baseline (`devices/quest3/evidence/unit2-v27-baseline-20261012/`, J-115).
Revision 4 was the PM's J-118 decision (Meta's thermal configuration read
at runtime, §4.5). Revision 3 history follows. Adversarial review 1 returned
**NO-GO** (1 blocker, 3 major, 8 minor, 2 nits); every finding was applied
in revision 2. Re-review 2 returned **GO for presentation** with 8 minor
findings, 4 nits, an F18 caveat (with a line-number nit) and a residuals item; every item is applied
here (table "Revision 3 changes" below), with one nit not applied after
verification (Q2 `watchdog_core.c` line number, see the table).
Offline research and design only: **no device was touched, no adb or
fastboot was run, nothing was downloaded, the PM's offline backup drive was not used.** Kernel
sources were read from the local WSL trees listed below (the same trees as
`thermal-control-design.md`); every kernel fact cited by reviews 1 and 2 was
re-checked in those trees before use. systemd behaviour is [C] throughout
(no systemd source tree is local) and is covered by the QEMU suite (§7.1).

**What this is.** The design for the PM's requirement J-83 ("design a
graceful shutdown for critical failures (thermal, battery, hang)") and for
FrameShift's thermal ownership, whose priority FS-R-011 §6 raised. It
extends `thermal-control-design.md` (read first; its §0.1 P1–P11 rulings,
§3 fan policy, §4 caps and §6 daemon stand). This file replaces only the
**mechanism** of that document's §6.1 (implementation shape), §6.3
"Shutdown path" and §6.5 "Watchdogs"; their policy content is kept.

**Status.** Not concurred, not proposed for a device. Nothing here changes
the bounded, attended trial (iii-b) or the stage-3c image: FS-R-011 §6 says
this is **not an added gate** on (iii-b), and that it **must inform the
Quest 2 trial and sustained Valve-userspace operation**. Every new policy
value (P12–P18, §4.4) was approved by the PM for design and harness work
(J-122); every new device action class is listed for the Chair (§7.3).

**Binding wording (FS-R-011 §6, J-104), verbatim.**
- FS-R-011 (private review record): "The successful-no-op helper path supplies
  no dependable forced shutdown through the generic thermal core on this
  configuration." (Quest 2, v2.7 config.)
- FS-R-011 (private review record): "A forced, unsynchronised kernel power-off
  is a last-resort path, not graceful shutdown."
- On the Quest 3 the 100 ms delay schedules an emergency power-off
  **attempt**, not a guaranteed power-off (`FS-R-011.md:301-303`). Vendor
  notify paths and hardware over-temperature protection remain unassessed
  [O].

Tags: [M] hardware output · [M-static] artifact, cited by path:line ·
[D] derivation · [C] hypothesis or outside claim · [O] open.

**Sources** (read-only): Quest 3 v66 `~/work/fs006-kernel/src`
(`23c97b254`) and config
`firmware/quest3/extracted/v66_unit1_slotA/kernel.config`;
Quest 3 v2.7 `~/work/kgate27/stock.config`; Quest 2 / Quest Pro
`~/work/kgateq2/src` (`6bde5fc06`), `~/work/kgateq2/stock.config`,
`~/work/kgateqpro/stock.config`; Quest 3S `~/work/kgateq3s/stock.config`;
compiled DTs `~/work/dtdiff/{v66,v27}.dts` (Quest 3) and
`devices/quest2/analysis/v27-dt/{v27-dtb1,v27-dtbo0}.dts` (Quest 2 v2.7,
dtbo0 = "Hollywood (DVT)", the PM's unit's board label, J-36); Quest 2 v2.7
`thermal_info_config.json` (`scratchpad/agents/oc-q12/vendor/`, sha256
prefix `cc3e513784a468d2`, as cited by `perf-envelope-quest1-2.md`); the
stage PID 1 reboot path `devices/quest3/common/DEADLINE.md` (revision 5).
**Revision 4 (Meta configuration, §4.5):** the vendor and odm images,
read only with `debugfs` (no `-w`), `dumpe2fs -h` and `sha256sum`:
Quest 3 v66 `firmware/quest3/v66_unit1_super/{vendor_a,odm_a}.img`
(Unit 1's own super dump, `firmware/quest3/PROVENANCE.txt:70`); Quest 3 v2.7 `~/work/fs006-kernel/v27/vendor.img`
(from the OTA); Quest 2 v2.7 `firmware/quest2/v2.7-user_ota/vendor.img`
(from the OTA); the v66 `perf_service` binary `~/work/fs006-power/perf_service.bin`
(`strings` only). The Quest 2 hash `cc3e5137…` cited above was re-derived
from that vendor image.
**Revision 5:** the Unit 2 v2.7 read-only baseline
`devices/quest3/evidence/unit2-v27-baseline-20261012/` (`getprop-all.txt`,
`proc-cmdline.txt`, `proc-partitions.txt`, `partitions-by-name.txt`;
`SHA256SUMS` there; J-115); the vendor `build.prop` and the JSON files of
the images above, re-read the same way (counts and key names only); the
odm image's `/etc` listed with `debugfs rdump` into a temporary directory,
deleted afterwards. No local `liblp` or `libsnapshot` source exists, so
every LP-format and Virtual A/B detail below is [C, AOSP].
Unless marked, `drivers/…`, `kernel/…`, `arch/…` paths below are **v66**
(Quest 3) or, where marked **(Q2)**, the Quest 2 tree.

### Revision 5 changes

| item (review 4) | change | sections |
|---|---|---|
| **M1** Virtual A/B not handled | Verified on Unit 2 (`ro.virtual_ab.enabled`/`retrofit` true, baseline taken on the boot after its OTA) and in the v2.7 and Quest 2 vendor `build.prop`: new fact **F38**. A `-cow` partition in the active slot's LP metadata → fallback, `reason=vab-merge`; the `build.prop` vendor incremental must equal the matched row's (catches mixed reads). Added beyond the review: the `-cow` test is necessary, not sufficient (COW can lie wholly on `userdata` [C]): declared **R25**, with **O27** for a reliable merge marker; the LP header flag and `UPDATED` attribute are logged only. O22 and the §7.2 probes extended (`ro.virtual_ab.*`, `snapshotctl dump`, `dmctl list devices`) | §0 item 10, F38, §4.5.2, §4.5.3 steps 1 and 3, §4.5.5, §7.1, §7.2, §8, O22, O26, O27, R25, §9.3 |
| **M2** "killed at 2 s" did not bound the boot | Verified (F39): RT policy and affinity are inherited unless reset (`SCHED_RESET_ON_FORK` resets the policy only); a `D`-state read ignores SIGKILL. `fs-metacfg` is now spawned first, while `fs-thermald` is still `SCHED_OTHER` and unpinned, with `SCHED_RESET_ON_FORK` as a second barrier; the child resets affinity and signal mask, closes descriptors and gets `RLIMIT_AS`, `RLIMIT_CPU` (and FSIZE, NOFILE, NPROC). The parent waits with `ppoll` on the pipe and a pidfd against one 2 s deadline, never a blocking `waitpid`; at the deadline it kills, closes the pipe, falls back and continues even if the child is stuck; reaps later with `WNOHANG`. Fixed record framing with length caps, so the parent's own parse is bounded | §4.5.2, §5.1, §6.2, §7.1, R23 |
| **m1** LP parser limits | Listed: primary geometry at 4096 with checksum, primary metadata at 12288 + slot × `metadata_max_size`, **backup copies not tried** (failure → fallback); 512-byte LP sectors whatever `BLKSSZGET` says (so `BLKSSZGET` is dropped: one ioctl left); version 10.≤2, header 128/256; entry sizes ≥ known structures; tables inside `tables_size` ≤ `metadata_max_size` ≤ 64 KiB; ≤ 3 slots; exactly one block device of `BLKGETSIZE64` size; `target_source` 0; overflow-safe extent end; NUL-terminated 36-byte names; `DISABLED` rejected [C, liblp] | §4.5.2, §7.1, §7.3 |
| **m2** ext4 reader unauthenticated | F34 now gives the exact feature set (verified with `dumpe2fs -h` on all three images): no `64bit` (32-byte descriptors), no `metadata_csum`, no `inline_data`. Checks listed: log block size 2, inode range, extent magic `0xF30A` and `eh_entries` ≤ `eh_max`, uninitialised extents and holes rejected, blocks inside `s_blocks_count` and the partition, `i_size_high` 0, inline data rejected, `rec_len`/`name_len` rules, caps on directory size (`/` and `/etc` are one block each today, verified) and on total bytes read | F34, §4.5.2, §7.1 |
| **m3** seccomp list incomplete | Filter installed after locate, slot read, open and `BLKGETSIZE64`; pre-filter syscalls listed; post-filter allow-list adds `close`, `fstat`, `brk`, non-executable `mmap`/`munmap`, `clock_gettime`, `rt_sigreturn`; descriptor arguments compared; `ioctl` by command number | §4.5.2, §7.1 |
| **m4** `super` may not be probed yet | Scan, then a `NETLINK_KOBJECT_UEVENT` wait for `PARTNAME=super` inside the 2 s budget; not found → `no-super` | §4.5.2, §7.1, §7.3 |
| **m5** hashes computed by the helper | `fs-thermald` hashes the raw JSON (≤ 64 KiB, shipped in the record) and the canonical record itself; each row gains the VR-runtime list's sha256, and the list is exported only when it matches | §4.5.2, §4.5.3 step 3 |
| **m6** schema details | Class from our class map, never from `Type` (verified: Quest 3 `soc-usr`, typed `SKIN`, reaches SHUTDOWN 115); CRITICAL/EMERGENCY must be unset (step 5's "between SEVERE and SHUTDOWN" removed, it contradicted step 6); `VrThreshold` must be the scalar `"NAN"`; `Monitor: true` required on every sensor with a set slot (verified: 36/37/19, BCL included) | F33, §4.5.3 steps 4–5, §4.5.4 row 4, §7.1, O25 |
| **m7** Unit 2 still listed as v71 | Unit 2 moved to the v2.7 bullet (build and vendor incremental `52433670036000520`, user, slot `_a`, `eureka`; new **F40**), row `c9301ff5…` expected pending the `sha256sum` probe; removed from the v71/v72/v76/v84 list | F40, §4.5.5, §8 |
| **m8** Unit 2 probes | lpdump and `/proc/bootconfig` planned on Unit 1 (v66 (Unit 1)); F37 partly measured on Unit 2 (slot `_a`; cmdline has `bootconfig` and no `androidboot.*`); probes already measured by the baseline not repeated. **Verified correction:** the privileged probes on Unit 2: [removed for publication] | F37, F40, §7.2 item 6, O22 |
| **m9** decision box stale | P12–P18, option B, the `pid1-hold.sh` change and the S1 softdog marked decided (J-122); tsens/ADC loads deferred; no open decision left | box, §4.4, §4.5.6 |
| **m10** §4.5.4 Quest 3 only | Quest 2 rows added (first fan trips CPU/GPU 70, battery 45, front panel 40 °C; kernel maps 90/95/110 °C; USB-C charging 53/55 °C) and a layer **2a** for the `user_space` zones Meta's userspace drives, declared unmapped [O] (**O29**), a departure for the PM only if O29 finds an uncovered action | §4.5.4, §4.5.5, O29 |
| nit: F31 "only" | Reworded: odm's thermal-related entries are the perf_service manifest and init file; it also has the power-statistics HAL's files, which set no threshold (verified, `debugfs rdump`) | F31 |
| nit: odm checks | Marked **v66 only** (no other odm image is held) | F31, F32, §4.5.1 |
| nit: ext4 only | A future non-ext4 vendor (for example EROFS) falls back (`fs-type`) | §4.5.2, §4.5.5, §7.1 |
| PM question pending | Left as an **[O] note** (O28, and in the box): may the public document name Meta's interface identifiers? The Arbiter asks the PM | box, O28 |
| added beyond the review | The Quest 2 4.19 tree also has a pollable pidfd (`pidfd_open`, `pidfd_poll` backported, F39): §5.2's A2 watch uses a pidfd on both kernels. P16's citation corrected to `perf-envelope-quest1-2.md:29-32` (was `:28-31`, one line off). F35 gains Unit 2's measured `super` (`sda7`, 8 GiB) and a dm device of exactly the v2.7 vendor image size | F35, F39, §4.4, §5.2 |

### Revision 4 changes

| item | change | sections |
|---|---|---|
| **PM decision J-118** | Follow Meta literally where hardware-specific: `fs-thermald` reads Meta's thermal configuration from the user's own headset at runtime and applies Meta's thresholds and mitigation order. Nothing of Meta's is in the repo; the built-in values are only a fallback. Decision box updated (item decided; P18 and the reader method added) | box, §0 item 10, §4.5 |
| new facts | F31 file names and paths (`/vendor/etc/…`; odm holds none); F32 how Meta's HAL finds the file; F33 the JSON structure at a high level; F34 the vendor ext4 features (no journal, `shared_blocks`); F35 `vendor` is a logical partition in `super` on both devices; F36 the VR-runtime list and `powerhint.cfg` (Meta's other mitigation layers); F37 where the slot suffix is found | §1 |
| thresholds | §4.1's table is now the **built-in fallback**, and the reference that the known-firmware table is reviewed against; the v66 hash `e49b49fe…` was added | §4.1 |
| new §4.5 | What is read, per device and firmware; the read-only reader `fs-metacfg` (option B, raw `O_RDONLY` read of `super`; option A, dm-linear plus a read-only mount); validation (source identity, ext4 checks, known-firmware hash table plus a parse digest, strict schema, sanity bounds, coverage against sysfs; **any doubt → fallback, and the user is told**); Meta's mitigation order mapped onto our tiers and actuators; behaviour across firmware versions; what remains ours; what the repo holds | §4.5 |
| P18 | Unknown Meta file (hash not in the reviewed table) → fallback (recommended) | §4.4, box |
| integration | Start-up loads the record or the fallback; the initramfs gate and the P12/P13 references use the active set; S1 stays unchanged (fixed stage values, no vendor read) | §5.1, §6.1, §6.2 |
| tests and probes | Reader fixtures (synthetic, ours), fault injection, fuzzing, a differential check against the local extracts (local only, never committed); read-only probes listed for the PM's approval, **not run** | §7.1, §7.2 |
| Chair | New read-only action class: our initramfs reads Meta's `vendor` partition (option B; option A also creates a dm device and a mount) | box, §7.3 |
| opens and risks | O22–O26; R23, R24 | §9 |

### Revision 3 changes

| item (re-review 2) | change | sections |
|---|---|---|
| **F18 caveat** | Verified: `ping_other_cpus` sets a pending ping only for online CPUs that are neither flagged in idle power collapse nor `cpu_isolated()` and are not the caller (`(Q2) drivers/soc/qcom/watchdog_v2.c:428-430`); the idle flag is set on `CPU_PM_ENTER` and cleared on `CPU_PM_EXIT` (`:690-697`); `cpu_isolated()` tests `cpu_isolated_mask` (`(Q2) include/linux/cpumask.h:118`); core_ctl is built (`SCHED_CORE_CTL=y`, `CPU_ISOLATION=y`, `kgateq2/stock.config:158`, `:98`). F18 now **requires at least one stopped CPU that is not core_ctl-isolated** at power-off; a CPU stopped out of idle has its flag cleared by the exit path [D]. Whether core_ctl leaves such a CPU at shutdown is O21 | F18, §5.2, §5.4, R14, O21 |
| nit: Q2 `watchdog_core` test at `:146` | **Not applied, verified:** in `~/work/kgateq2/src` at `6bde5fc06` the test `if (code == SYS_DOWN \|\| code == SYS_HALT)` is on **line 147** (`:141` is the function head); `:147` stays | F7 |
| **1** `fs-thermald-shutdown.service` never stopped | Unit now has `Conflicts=shutdown.target` and `Before=shutdown.target` and no other ordering (so it is stopped at the start of every shutdown transaction), `Type=oneshot`, `RemainAfterExit=yes`, `IgnoreOnIsolate=yes`, `RefuseManualStop=yes` [C, systemd.unit/systemd.special]; QEMU test for each shutdown verb | §6.2, §7.1 |
| **2** direct `reboot()` by any root process bypasses the detectors | `CapabilityBoundingSet=~CAP_SYS_BOOT` in the top-level `service.d` drop-in (every service, transient ones included [C]); the kernel checks `CAP_SYS_BOOT` before the lock (`kernel/reboot.c:320`; `(Q2) :316`, F27); our units set their own set. `fs-thermald` is not a unit (initramfs-started) and is unaffected. Remainder recorded in R21 | §5.1, §5.4, §6.2, R21 |
| **3** pet deadline opens a route into R11 | `JobTimeoutSec=35s` drop-ins on **every** shutdown target (`poweroff`, `reboot`, `kexec`: force action of the target; `halt` masked, below); `soft-reboot.target` and `systemd-soft-reboot.service` masked; **on any detected shutdown** (any verb) the supervisor runs A1 at + 45 s and the final pet + A2 at + 55 s, so the softdog fires only after a power-off began (F20) or not at all (a `RESTART` stops it, F7). Added beyond the review: `halt.target`/`systemd-halt.service` masked, because `SYS_HALT` stops the softdog and `machine_halt` spins (F4, F7). Declared residual R22 | §5.1, §5.3, §5.4, §6.2, §7.1, R22 |
| **4** `DefaultLimitRTPRIO=49` bypass is certain | Verified: the `RLIMIT_RTPRIO` check runs only `if (user && !capable(CAP_SYS_NICE))` (`kernel/sched/core.c:5513-5522`; `(Q2) :5069`), F25. Every service now gets `RestrictRealtime=yes` (top-level drop-in); explicit exceptions (named units that need RT) get `RestrictRealtime=no`, `CapabilityBoundingSet=~CAP_SYS_NICE` and `LimitRTPRIO=` ≤ 49; an RT broker that keeps `CAP_SYS_NICE` (rtkit) is capped by its own maximum ≤ 49 [C]. O18 retagged | §5.1, §5.4, §6.2, O18 |
| **5** initramfs gate at ≥ WARN allows a T4 loop just below SEVERE | Gate passes only with every class **below SEVERE − hysteresis** (T3's exit rule) and, if pstore holds a T4/T5 marker of the previous boot, **below LIGHT**. pstore is RAM-backed (`ramoops`, F29): the marker survives a warm restart, not a real power-off [D]. O19 must be settled before any flashed image | §6.2, §7.1, O19, R20 |
| **6** stage guard: TRIP vs staleness/DEADLINE order; exec failure | PID 1 checks `TRIP` **first** in each iteration, before the guard-alive and staleness checks and before DEADLINE (a change to `DEADLINE.md` property 2's "deadline first"; `TRIP` only shortens). A DEADLINE or backstop reboot that wins a race with a trip takes `RESTART2 "bootloader"` (softdog stopped, ABL [O3]): declared. On a trip there is **no forking fallback**: if the helper check or the `exec` fails, PID 1 exits (ash exits 127 on a failed `exec`, `DEADLINE.md` property 3a) → panic → lock-free `emergency_restart` (F19); harness cases added | §6.1, §7.1 |
| **7** forged READY hides a dead guard | PID 1 also reads the guard's `/proc/<pid>/stat` with the `read` builtin each iteration: comm `(fs-tguard)`, state `R`/`S`/`D`, start time (field 22) equal to the value at READY; anything else, or a missing file → guard dead (F28) | §6.1, §7.1 |
| **8** S1 softdog on the Quest 3 → `emergency_restart` on a guard hang | T0's `download_mode` read = 0 is an **explicit precondition** for opening the softdog in S1 on the Quest 3 | §6.1, §7.2, §7.3 |
| nit: gate final pet | On a gate refusal the supervisor gives the final pet (`M_final`) at the moment PID 1 `exec`s `fs-poweroff-final`; bound = gate decision + ≤ 1 s + `M_final` (not the T4 + 55 s + `M_final` bound that applied by default) | §6.2 |
| nit: A1/A2 | A1/A2 never `exec` (they keep the `@` `argv[0]` inherited from the fork), close `/dev/watchdog` and every other unneeded descriptor right after the fork; QEMU check under O7 | §5.1, §7.1 |
| nit: rise anomaly on a no-sibling sensor | A rise-rate anomaly while the value is still **below SEVERE** on a sensor with no independent sibling → P9 sensor fault (SEVERE now, T4 after 120 s), not T4; > 125 °C still latches T4 | §3.3, §7.1 |
| nit: `RLIMIT_RTTIME` soft limit | Verified: the soft limit only sends SIGXCPU (`kernel/time/posix-cpu-timers.c:863-867`), which the supervisor blocks; only the hard limit's SIGKILL acts (`:859-861`), F26. Now soft = hard = 500 ms | §5.1, §5.4 |
| residuals | Findings 2 and 3 declared as residuals R21 (remainder) and R22, listed with R11/K5, R12, R13 and O6 in §9.3 | §9.2, §9.3 |

### Revision 2 changes

| finding (review 1) | change | sections |
|---|---|---|
| **B1** the "restart after a failed `POWER_OFF`" fallback cannot work | Verified: `reboot()` takes `system_transition_mutex` (`kernel/reboot.c:346`; Q2 `:342`), `do_exit(0)`s after a returned power-off (`:366-367`; Q2 `:362-363`) and never unlocks (`:397`; Q2 `:393`); `machine_power_off` has already stopped the other CPUs (`arch/arm64/kernel/process.c:170-176`); Q2 `do_msm_poweroff` returns only after `msleep(10000)` (`(Q2) msm-poweroff.c:619-631`); arm64 `machine_restart` never returns (`process.c:187-207`). **The userspace post-`POWER_OFF` fallback is removed** (no `RESTART`, no second `reboot()` anywhere). Stage: **PID 1 is the only reboot caller**; the guard signals it; a returned power-off panics PID 1 → `emergency_restart`, which takes no lock (F19). Valve: A2 is the last `reboot()` caller; after it only **timers that survive the kernel path** act: the softdog, pinned with the supervisor and A2 to CPU0 (F21), last petted just before A2; the Quest 2 msm watchdog (F18); optionally a deliberate panic (P15). The harness models the lock and the CPU stop | F4, F18–F21, F24, §0, §4.1, §5.1–§5.5, §6.1, §7.1, R14 |
| **M1** softdog is not stopped on power-off | Verified: the watchdog core stops a watchdog only on `SYS_DOWN`/`SYS_HALT` (`drivers/watchdog/watchdog_core.c:160`; Q2 `:147`); `kernel_power_off` notifies `SYS_POWER_OFF` (`kernel/reboot.c:260-263`). **F7 corrected**: the softdog stays armed through `reboot(POWER_OFF)` and covers a `device_shutdown()` hang; it is stopped on `RESTART`. Q2 `watchdog_v2` has no reboot notifier or shutdown callback (F18). Supervisor gets a **pet deadline** for every shutdown; final margin ≥ kernel power-off time + Q2's 10 s (P17) | F7, F18, §5.1, §5.3, §5.4, §5.5, R13 |
| **M2** hot anomalies were dropped from the max | Hot-side anomaly (> 125 °C, or > 10 °C/s rise) **counts toward T4** unless an independent sibling contradicts it within 2 cycles; low/EIO/frozen keep P9 | §3.3, §7.1 |
| **M3** "RESTART lands in stock Android" was too broad | Restart landing claims restricted to `fastboot boot` images and tagged [C] (Android boot is heavy before Meta's thermal HAL; ABL [O3]); **initramfs thermal gate** before `switch_root`; flashed-image hot reboot loop listed (R20). Partial disagreement on the gate's battery trigger (below) | §0, §4.2, §5.4, §6.2, O3, R20 |
| m1 quote | FS-R-011 quoted verbatim with path:line | Binding wording |
| m2 P12 vs §5.3 | Stage budget ≤ 3 s in both | §4.4, §5.3 |
| m3 "10 s later A2 is gone" | A2's exit observed by pidfd (v66) / `waitpid` (Q2); no fixed wait (Q2 returns only after ≥ 10 s); `JobTimeoutSec=35s` staggered before T5 at 45 s | §5.2, §5.3, §6.2 |
| m4 heartbeat age | Named clock: `CLOCK_BOOTTIME` counter in the record, never mtime; PID 1 compares with `/proc/uptime` (also BOOTTIME, F23) **and** a loop-iteration count | §5.4, §6.1, §6.2 |
| m5 | `RebootWatchdogSec=off`, `KExecWatchdogSec=off` added | §6.2, O7 |
| m6 | `SCHED_FIFO` 60 (> threaded-IRQ default 50, F22); `DefaultLimitRTPRIO=49` for others; SIGSTOP unblockable and covered; actuators exit on pipe EOF without acting | §5.1, §5.4, §6.2 |
| m7 | Quest 2 S1 zones and thresholds defined (P16) | §6.1 |
| m8 | §7.3 rows for `sync()`, `/dev/pmsg0`, sysrq; ADSP start → `thermal-control-design.md` §6.7 T3b | §3.1, §7.3 |
| nit 1 | T2 = MODERATE only; SEVERE is T3 | §4.1 |
| nit 2 | SIGSTOP'd supervisor row; PID 1 hung rows split | §5.4 |

**Disagreement (partial, M3).** The gate powers off on any **thermal or
fault** WARN trigger, but **not** on the low-battery-only WARN (≤ 10 %,
P13): that would make a 9 % device unbootable. P6 (≤ 3 % discharging)
still powers off. The fan class cannot be checked before `switch_root` on
the Quest 2 (no fan driver before a DRM panel, §4.3); it is checked before
load-producing units start (`fs-thermald-ready.target`).

---

## 0. Headline decisions

1. **FrameShift owns thermal safety in software, end to end.** One
   independent supervisor, `fs-thermald` (the daemon of
   `thermal-control-design.md` §6, with this document's mechanism), is the
   **only** writer of fan targets, CPU/GPU caps and the governor, and the
   **only** software component that decides an emergency shutdown. The
   kernel's thermal shutdown paths are **not counted** as protection on any
   device (§1, F1–F3).
2. **Tiers:** NORMAL → NOTICE → THROTTLE → WARN (user-visible) →
   GRACEFUL SHUTDOWN (Meta's SHUTDOWN thresholds, latching) → IN-BAND LAST
   RESORT (our own bounded sync + **one** `reboot(POWER_OFF)`; if that
   fails, only kernel timers and hardware act) → OUT-OF-BAND
   (kernel/PMIC/hardware/manual, not ours). §4.
3. **Graceful shutdown is bounded:** Valve userspace ≤ 55 s from decision
   to our last `reboot()` call, plus the softdog's final margin (P17) as
   the timer fallback, and the same bound for **any** shutdown we detect,
   whoever started it (revision 3); stage images ≤ 3 s to PID 1's
   power-off. The device
   is **pre-cooled first** (fan to top level, minimum caps) so that any
   later hang happens in the coolest reachable state (§5.3).
4. **One `reboot(POWER_OFF)`, no userspace fallback after it.** A
   power-off that returns leaves the kernel's reboot lock held for ever,
   the other CPUs stopped and devices shut down (F4): **no later
   `reboot()` from any process can run**. So: in stage images **PID 1 is
   the only reboot caller** (a returned power-off panics it, and the panic
   restarts without the lock, F19); in Valve userspace systemd's PID 1
   powers off normally and our pre-forked actuator A2 is the last resort;
   after A2 only the softdog (pinned to CPU0, F21), the Quest 2 msm
   watchdog (F18) and, if ruled, a deliberate panic (P15) act (§5.2).
   Where a restart lands is [C]: for a `fastboot boot` image, the stock
   boot chain (Android, whose boot is heavy before Meta's thermal HAL
   runs [C]); for a flashed image, our own initramfs, which runs a
   **thermal gate** before any load (§6.2).
5. **Independence from Valve's systemd:** the supervisor is started by
   **our initramfs** before any load, survives switch-root and systemd's
   final killing spree, owns the softdog, and requests shutdown from systemd
   by **signal** (`SIGRTMIN+4`), not D-Bus. It never depends on PID 1 to
   reach power-off (§5.1, §6.2). No service may call `reboot()` itself
   or take a realtime priority above 49 (bounding set and
   `RestrictRealtime=`, revision 3, §6.2).
6. **Production supervisor in static C, Python as the reference model**
   (differential testing on shared fixtures), because it must run before
   switch-root and without Valve's libraries (§5.1). This changes
   `thermal-control-design.md` §6.1's "Python 3 stdlib" shape.
7. **Stage images now: no change.** The bounded hold, the PM's presence and
   the after-trial temperature procedure stay the protection. A minimal
   read-only **stage thermal guard** (§6.1) is designed for (a) any Quest 3
   stage hold longer than today's bounds and (b) **the first Quest 2
   trial**, where the zones are built in and no new module is needed. The
   guard never calls `reboot()`; it asks PID 1.
8. **No kernel, DT or config change now** (FS-R-001/002). The deferred
   options are listed with their constraints (§5.6). One boot-image
   **cmdline** question (Quest 3 crash-dump arming) must be settled before
   sustained Valve operation (R11).
9. **Never Valve's hooks:** no Valve fan, power, charger or shutdown hook
   runs on a Quest; our shutdown uses only systemd's `poweroff.target` and
   the kernel `reboot()` syscall (§6.2).
10. **Meta's thresholds come from the user's own headset (revision 4, PM
    J-118).** At boot, before any load, our initramfs reads Meta's
    `/vendor/etc/thermal_info_config.json` (and the VR-runtime mitigation
    list) read-only from the active slot's `vendor` partition. It accepts
    the file only if its hash is in our reviewed known-firmware table and
    it passes the schema, bounds and coverage checks; `fs-thermald` then
    applies Meta's thresholds, hysteresis and mitigation order. On **any**
    doubt (revision 5 adds a pending Virtual A/B merge, F38, and a reader
    that does not answer in 2 s, which never holds up the boot) it uses
    the built-in values (§4.1) and tells the user. The
    mechanism, the departures P1–P18 and the last-resort path stay ours.
    Nothing of Meta's is committed: the repo holds hashes, parse digests
    and the fallback numbers (§4.5).

---

## 1. New source facts (this pass)

| # | fact | tag, source |
|---|---|---|
| F1 | **Quest 2: no thermal trip is typed `critical` anywhere.** The compiled v2.7 `v27-dtb1.dts` and `v27-dtbo0.dts` contain **0** `type = "critical"` (81 and 59 `passive` trips). Even the PMIC temp-alarm zone's 145 °C trip is `passive` (`(Q2) arch/arm64/boot/dts/vendor/qcom/pm8150.dtsi:145-168`). So the generic core's `handle_critical_trips` → `orderly_poweroff` path is **never entered** by Meta's DT on the Quest 2, independently of the helper path and the 0 ms delay. This adds to FS-R-011 §6; it does not change its wording | [M-static] compiled DT grep; source |
| F2 | **No userspace fix for the helper path exists.** With `STATIC_USERMODEHELPER=y`, `call_usermodehelper_setup` replaces the path with `CONFIG_STATIC_USERMODEHELPER_PATH` (`kernel/umh.c:369-372`; `(Q2) :396-399`), so writing `/proc/sys/kernel/poweroff_cmd` changes nothing | [M-static] |
| F3 | **Quest 3 critical handling:** `tz->ops->notify` first, then (once) `thermal_emergency_poweroff()` + `orderly_poweroff(true)` (`drivers/thermal/thermal_core.c:388-420`). The emergency work calls `kernel_power_off()` then `emergency_restart()`, with **no** `emergency_sync()` (`:347-364`). Reachable only if a critical trip exists, i.e. PMIC temp-alarm loaded (option B, `thermal-control-design.md` §5) | [M-static] |
| F4 | **`reboot(POWER_OFF)` semantics (revised).** Error returns (`EPERM`, `EINVAL`, pid namespace) happen only **before** the lock (`kernel/reboot.c:311-338`). Then `mutex_lock(&system_transition_mutex)` (`:346`; `(Q2) :342`); `kernel_power_off()` runs the reboot notifiers with `SYS_POWER_OFF` and `device_shutdown()` (`:260-266`, `:289-299`), moves the caller to `reboot_cpu` (0 unless `reboot=` says otherwise, `:47`, `:220-236`; neither device's cmdline sets it), then `machine_power_off()` disables IRQs and **stops every other CPU** before `pm_power_off` (`arch/arm64/kernel/process.c:170-176`; `(Q2) :144-150`). **If that returns, the syscall `do_exit(0)`s the caller while still holding the lock** (`kernel/reboot.c:366-367`, unlock only at `:397`; `(Q2) :362-363`, `:393`). Every later `reboot()` (any process, any command) then blocks for ever, uninterruptibly, in `mutex_lock`. Quest 2's `do_msm_poweroff` returns only after `msleep(10000)` (`(Q2) drivers/power/reset/msm-poweroff.c:619-631`). arm64 `machine_restart` never returns (`process.c:187-207`) and `machine_halt` spins (`:157-162`). **Consequence:** after a returned power-off, nothing in userspace can reboot; only a panic or `emergency_restart` (no lock, `kernel/reboot.c:66-70`) can | [M-static; D] |
| F5 | **Power-off providers.** Quest 3: `pm_power_off = psci_sys_poweroff` → PSCI `SYSTEM_OFF` (`drivers/firmware/psci/psci.c:323,481`); what TZ does with the PMIC is [C]. Quest 2: `do_msm_poweroff` clears download mode, disables SDI, sets PON to SHUTDOWN, halts the SPMI PMIC arbiter and deasserts PS_HOLD (`(Q2) drivers/power/reset/msm-poweroff.c:619-631,666`; built by `POWER_RESET_QCOM=y`, `kgateq2/stock.config:2326`) | [M-static] |
| F6 | **Quest 3 crash-dump arming.** `qcom-dload-mode.ko` is in Meta's recovery set that our stage images load (`firmware/quest3/extracted/v66_unit1_slotA/vendor_ramdisk/lib/modules/modules.load.recovery:44`). Its reboot notifier clears dump mode on any clean restart/power-off (`drivers/power/reset/qcom-dload-mode.c:260-282`); its panic notifier keeps it (`:247-258`). `emergency_restart()` runs **no** reboot notifiers (`kernel/reboot.c:66-70` vs `:73-79`). So with dump mode armed, a softdog expiry, a thermal emergency restart or a panic **before any clean reboot/power-off began** lands in crash-dump mode (dark, USB `05c6:900e`) rather than a normal boot [D; XBL behaviour C]. Probe arms dump mode only if `enable_dump` (`:326-328`); the stock cmdline sets `qcom_dload_mode.download_mode=1 dump_mode=32 emmc_dload=1` [M, FS-A-004 (private review record)]. **Nuance:** our stage inits load it with busybox `insmod` and no arguments; command-line options for *loadable* modules are applied by modprobe/libkmod, not by the kernel [C, upstream semantics], so dump mode is probably **not** armed in our stage images, and **would** be armed under a libkmod userspace (Valve's systemd/udev) [D]. A read-only `cat /sys/module/qcom_dload_mode/parameters/download_mode` would settle it [O] | [M-static; M; D; C] |
| F7 | **softdog (corrected in revision 2).** On expiry it calls `emergency_restart()`, or panics with `soft_panic`, or with `soft_reboot_cmd` first tries `kernel_restart` from a kthread and re-arms for `TIMER_MARGIN` (60 s) before `emergency_restart` (`drivers/watchdog/softdog.c:31,66-120`). Both trees register `watchdog_stop_on_reboot()` (`:188`; `(Q2) :150`), but the core's notifier stops the watchdog **only on `SYS_DOWN` (= `SYS_RESTART`) or `SYS_HALT`** (`drivers/watchdog/watchdog_core.c:154-170`, test at `:160`; `(Q2) :141-157`, `:147`; codes `include/linux/reboot.h:11-14`). `kernel_power_off` notifies `SYS_POWER_OFF` (`kernel/reboot.c:260-263`). **So the softdog stays armed through `reboot(POWER_OFF)`** and fires if `device_shutdown()` hangs or `pm_power_off` returns; it **is** stopped by `RESTART`/`RESTART2`. Its timer is an hrtimer (`softdog.c:137,190`), so it fires only on a CPU that still runs (F21). The Quest 2 boot header carries `softdog.soft_panic=1` [M-static, `devices/quest2/analysis/v27-dt/boot-header.txt`] and its config has `WATCHDOG_NOWAYOUT=y` (`kgateq2/stock.config:2573`): once opened it can never be stopped. Quest 3: `SOFT_WATCHDOG=y`, `NOWAYOUT` unset (v66 `kernel.config:3229`, `:3216`); v66 also offers `soft_reboot_cmd` and `soft_active_on_boot` (`softdog.c:54-61`) | [M-static] |
| F8 | **Quest 3: no SoC watchdog node.** The compiled v66 and v2.7 DTBs contain no `qcom,msm-watchdog` or `qcom,gh-watchdog` node (no "watchdog" string at all), although the drivers are built as modules (`QCOM_SOC_WATCHDOG=m`, `QCOM_WDT_CORE=m`, `GH_VIRT_WATCHDOG=m`; v66 `kernel.config:5673-5682`, `:5023`). So **no Linux-petted SoC watchdog exists on the Quest 3** even if `qcom_soc_wdt` were loaded. This **corrects** `thermal-control-design.md` §6.5 ("kernel ← `qcom_soc_wdt` if loaded"). Overlays (dtbo) not checked for it; a firmware or hypervisor watchdog is [O] | [M-static] |
| F9 | **Quest 2 watchdog:** `QCOM_WATCHDOG_V2=y` (`kgateq2/stock.config:4442`), kernel-petted, bark 11 s in `v27-dtb1.dts:1812-1821` (`0x2af8` ms), **12 s on DVT** (`v27-dtbo0.dts:2741`, `0x2ee0`), bite at bark + 3 s (`(Q2) drivers/soc/qcom/watchdog_v2.c:929-930`); a kernel hang → bark → panic → restart → `download_mode` 0 → Android (`devices/quest2/PORT-PLAN.md` §1.4 item 3). Userspace petting needs DT `qcom,userspace-watchdog`: **0** occurrences in `v27-dtb1.dts`/`v27-dtbo0.dts` [M-static] | [M-static] |
| F10 | **"shutdown,thermal" restart reasons exist but write persistent state.** Quest 2: `RESTART2 "shutdown,thermal"` → warm reset + PON reason SHUTDOWN_THERMAL + IMEM cookie (`(Q2) msm-poweroff.c:494-500,543-546`). Quest 3: `qcom-reboot-reason` writes PON reason `0x9` to the nvmem cell `restart_reason` (`drivers/power/reset/qcom-reboot-reason.c:29-60`), a PMIC SDAM write that survives a reset [D]. What the bootloader then does is [O]. **Not used** (§7.3) | [M-static; D] |
| F11 | **No lockup detection in the kernel:** `SOFTLOCKUP_DETECTOR` and `DETECT_HUNG_TASK` unset in every config checked (v66 `:7106-7107`; Q2 `:5603-5604`); `PANIC_TIMEOUT=-1` (v66 `:7105`, Q2 `:5608`: immediate `emergency_restart`, `kernel/panic.c:404-412`; `(Q2) :343-351`); v66 `PANIC_ON_OOPS=y` (`:7103`) | [M-static] |
| F12 | **Quest 2 Meta thresholds** (JSON severities LIGHT/MODERATE/SEVERE/…/SHUTDOWN): `batt-virt` 53 / – / 58 / **59** (hyst 1/–/3/1); `vrapi-front-panel` (skin) 47 / 51 / 52 / **60** (hyst 1/1/5/5); `cpu-*-usr`, `cpuss-*`, `gpuss-*` SEVERE 95, SHUTDOWN **115** (hyst 5); `cpu-1-*-usr` LIGHT 90; `vrapi-pmem` SEVERE 95 | [M-static] JSON `cc3e5137…` |
| F13 | **Quest 2 battery is in-kernel:** `QPNP_SMB5=y`, `QPNP_FG_GEN4=y` (`kgateq2/stock.config:2372,2380`), DT JEITA bands in the battery profiles (`(Q2) arch/arm64/boot/dts/oculus/hollywood/*Goertek*.dtsi`). No ADSP staleness class as on the Quest 3 | [M-static] |
| F14 | **Quest 2 PMIC temp-alarm:** the 4.19 driver clears both override bits (`(Q2) drivers/thermal/qcom-spmi-temp-alarm.c:251-258`); pm8150 uses threshold set 1 (`pm8150.dtsi:51`) = 95/115/145 °C for GEN2 or 110/130/150 °C for GEN1 (`qcom-spmi-temp-alarm.c:50-62`); subtype per PMIC, and pm8150b/pm8150l's sets, [O]. Hardware stage 2/3 shutdown therefore stays enabled [D] | [M-static; D] |
| F15 | **Event fast path:** v66 sends a thermal-netlink `TZ_TRIP_UP` (`thermal_core.c:440`); 4.19 has only the legacy `thermal_generate_netlink_event` (`(Q2) thermal_core.c:1604-1668`). Polling stays the primary input | [M-static] |
| F16 | **tsens critical interrupts are not a shutdown path:** v66 masks them as "unused on Linux" (`drivers/thermal/qcom/tsens.c:466-468`); 4.19 handles and masks them (`(Q2) drivers/thermal/tsens2xxx.c:573-660`). Any hardware reset-on-critical is firmware-configured [O] | [M-static] |
| F17 | **Valve userspace systemd is 257.7** [M-static, `valve-image-slot-in.md:386`]; `SurviveFinalKillSignal=` exists from systemd 255 [C] | [M-static; C] |
| F18 | **Quest 2 msm watchdog across power-off (new).** `watchdog_v2` registers no reboot notifier and no `.shutdown` callback (`(Q2) drivers/soc/qcom/watchdog_v2.c:1103-1111`; it is disabled only by `remove` `:718-741` or the sysfs `disable` `:276-318`), so it **stays enabled through `reboot(POWER_OFF)`**. Its pet kthread pings the other online CPUs first when `qcom,ipi-ping` is set (`:640-680`, `:421-450`; set in `v27-dtb1.dts:1820`, not overridden by dtbo0) and retries for ever while a ping is pending. Meta's 4.19 `ipi_cpu_stop` clears only `cpu_active`, **not** `cpu_online` (`(Q2) arch/arm64/kernel/smp.c:847-868`), so after `machine_power_off`'s `smp_send_stop` the ping never completes and petting stops [D] → bark (12 s) → `panic` (`:780-795`) or, if the bark is not serviced, bite at bark + 3 s. On panic its notifier rewrites bark **and bite** to `(panic_timeout + 10)` s = **9 s** with `PANIC_TIMEOUT=-1` (`:221-238`). So on the Quest 2 a returned or hung `pm_power_off` is followed by a **hardware** reset within about 12–21 s [D]. It does **not** cover a `device_shutdown()` hang (the kernel is alive and keeps petting). **Caveat (revision 3):** `ping_other_cpus` pings only online CPUs that are not flagged in idle power collapse, not `cpu_isolated()` and not the caller (`:428-430`; flag set on `CPU_PM_ENTER`, cleared on `CPU_PM_EXIT`, `:690-697`; `cpu_isolated()` = `cpu_isolated_mask`, `(Q2) include/linux/cpumask.h:118`; core_ctl built, `SCHED_CORE_CTL=y`, `CPU_ISOLATION=y`, `kgateq2/stock.config:158,98`). So F18 holds only if **at least one stopped CPU is not core_ctl-isolated** at power-off; a CPU that leaves idle to take the stop IPI clears its flag on the way out and then spins with interrupts masked, never re-entering idle [D]. If every other CPU is isolated, the ping set is empty, petting continues, and only the softdog covers (O21) | [M-static; D] |
| F19 | **Only global init's exit panics** (`kernel/exit.c:823-831`; `(Q2) :894-895`): "Attempted to kill init!", then with `PANIC_TIMEOUT=-1` `emergency_restart()` (F11), which takes no lock and runs no reboot notifier. A `reboot(POWER_OFF)` issued **by PID 1** that returns therefore ends in an immediate restart; issued by any other process it ends silently with the lock held (F4) | [M-static; D] |
| F20 | **Dump mode after a started power-off (new).** The `qcom-dload-mode` reboot notifier clears dump mode for **every** event code unless already in panic (`qcom-dload-mode.c:268-269`), and runs at the start of `kernel_power_off` (F4). So a panic or softdog `emergency_restart` **after** a power-off began lands in a normal boot even if dump mode had been armed [D; XBL behaviour C] | [M-static; D] |
| F21 | **CPU0 survives a returned power-off; pin to it (new).** The power-off caller is moved to `reboot_cpu` 0 (F4) and the others are stopped. An hrtimer is queued on the CPU that starts it when that CPU is busy (`kernel/time/hrtimer.c:202-210`; `kernel/sched/core.c:674-683`; no `nohz_full`/`isolcpus` on either cmdline). The softdog is re-armed (`softdog.c:137`) in the context of the process that pets it, so **a supervisor pinned to CPU0 keeps the softdog's hrtimer on CPU0**, the one CPU still running [D]. IRQs are disabled in `machine_power_off`; they are re-enabled at the next context switch after `do_exit`/`msleep` [D] | [M-static; D] |
| F22 | **Threaded IRQs run at `SCHED_FIFO` 50** (v66 `kernel/irq/manage.c:1370` → `sched_set_fifo`, `kernel/sched/core.c:5837-5841`; `(Q2) kernel/irq/manage.c:1226`, `MAX_USER_RT_PRIO/2`). `RT_GROUP_SCHED` is unset on both | [M-static] |
| F23 | **`/proc/uptime` is `CLOCK_BOOTTIME`** (`fs/proc/uptime.c:27`; `(Q2) :22`) | [M-static] |
| F24 | **sysrq `c` panics directly** on both trees (`drivers/tty/sysrq.c:149-155`; `(Q2) :135-141`), `MAGIC_SYSRQ=y` (v66 `:7021`, Q2 `:5565`); writes to `/proc/sysrq-trigger` bypass the sysrq mask (`sysrq.c:1154-1162`, `check_mask=false`) | [M-static] |
| F25 | **`CAP_SYS_NICE` bypasses `RLIMIT_RTPRIO` (revision 3).** `__sched_setscheduler` applies the `RLIMIT_RTPRIO` check only `if (user && !capable(CAP_SYS_NICE))` (`kernel/sched/core.c:5513-5522`; `(Q2) :5069`). A root unit with the default capability set can therefore take any `SCHED_FIFO` priority, including above the supervisor's 60, whatever `LimitRTPRIO=` says | [M-static] |
| F26 | **`RLIMIT_RTTIME`: only the hard limit acts on a task that blocks SIGXCPU.** At the hard limit SIGKILL (`kernel/time/posix-cpu-timers.c:859-861`); at the soft limit only a SIGXCPU per second (`:863-867`; `(Q2) :845-856`, `:858-872`). A blocked SIGXCPU stays pending and does nothing | [M-static] |
| F27 | **`reboot()` requires `CAP_SYS_BOOT`** in the caller's pid namespace, checked before the lock (`kernel/reboot.c:320-321`; `(Q2) :316`). A process whose capability bounding set lacks it cannot regain it (setuid and file capabilities are limited by the bounding set [C, capabilities(7)]) and gets `EPERM` | [M-static; C] |
| F28 | **`/proc/<pid>/stat`** prints `pid (comm) state …` with `state` the first letter of `task_state_array` (`R S D T t X Z P I`; `fs/proc/array.c:129-143`, printed at `:541-545`; `(Q2) :136-139`, `:532`) and the start time (boottime clock ticks) as field 22 (`:539`, `:564`) | [M-static] |
| F29 | **pstore is RAM-backed on both devices:** `PSTORE_RAM=y`, `PSTORE_PMSG=y` (v66 `kernel.config:6506,6508`; Q2 `stock.config:5135-5136`); `ramoops` regions in `~/work/dtdiff/v66.dts:2551-2552` and `v27-dtbo0.dts:2642-2643`. Records survive a warm reset, **not** a real power-off (DRAM loses power) [D] | [M-static; D] |
| F30 | **`KEXEC` is unset** on both kernels (v66 `kernel.config:439-440`; Q2 `stock.config:443`); a kexec request cannot load a kernel | [M-static] |
| F31 | **Where Meta's thermal configuration lives (revision 4).** On the vendor partition, under `/vendor/etc/`: `thermal_info_config.json` (thermal HAL thresholds), `vr_runtime_power_mitigation.json` (VR-runtime mitigation list), `powerhint.cfg` and `powerhint_holdout.cfg` (power-HAL hints). Sizes of `thermal_info_config.json`: Quest 3 v66 27,284 bytes, Quest 3 v2.7 27,505, Quest 2 v2.7 16,015. The odm partition's `/etc` (Quest 3 v66 only: no odm image of v2.7 or of the Quest 2 is held locally; 46 files, searched recursively) holds no thermal configuration. Its thermal-related entries are the HAL's VINTF manifest `/odm/etc/vintf/manifest/perfservice.xml` and init file `/odm/etc/init/perfservice.rc`, which starts `/odm/bin/hw/perf_service` serving `IThermal` 1.0/2.0; it also carries the power-statistics HAL's init file and manifest (`android.hardware.power.stats@1.0-service.anorak.{rc,xml}`), which configure no threshold (revision 5 wording). sha256 prefixes: thermal JSON v66 `e49b49fe2920cd83`, v2.7 `c9301ff553f65255`, Quest 2 `cc3e513784a468d2`; VR-runtime list v66 `674af9d5d27acf7b`, v2.7 `d3a2ffa41e057cfa`, Quest 2 `f525cc6a6cb50f4d`. The WSL copies `~/work/fs006-power/thermal_info_config.json` and `~/work/thermal-design/v27vendor/thermal_info_config.json` equal the v66 and v2.7 files | [M-static] `debugfs ls`/`cat` on the images in Sources |
| F32 | **How Meta's HAL finds the file.** The v66 `perf_service` contains the strings `/vendor/etc/`, `thermal_info_config.json` and `vendor.thermal.config`. That is the AOSP thermal-HAL pattern: the property names the file, and `thermal_info_config.json` is the default [C]. The property is not set in `/build.prop`, `/default.prop` or `/etc/build.prop` of any of the three vendor images, nor in odm's `/etc/build.prop` (**Quest 3 v66 only**; no other odm image is held), so the default applies [M-static; system-partition properties and the v2.7/Quest 2 odm not checked, O24] | [M-static; C] |
| F33 | **Structure (high level only).** One JSON object with a `Sensors` array (Quest 3 53 entries, Quest 2 32) and a `CoolingDevices` array (6 and 9 name/type pairs, **no bindings**: no `BindedCdevInfo` anywhere). Each sensor has `Name`, `Type`, `HotThreshold` (7 slots, in AOSP severity order NONE, LIGHT, MODERATE, SEVERE, CRITICAL, EMERGENCY, SHUTDOWN [C]), `VrThreshold` (a **scalar**, the string `"NAN"` in every sensor of all three files; purpose O25), `Multiplier`, and optionally `HotHysteresis` (7 slots) and `Monitor`. Values are **numeric strings or `"NAN"`** (Quest 3: all strings; Quest 2: numbers and strings mixed). CRITICAL and EMERGENCY are unset in all three files. **`Monitor` is `true` on exactly the sensors with any set slot (temperature or BCL; the Quest 3's 8 BCL entries included) and absent elsewhere** (Quest 3 v66 36 of 53, v2.7 37 of 53, Quest 2 19 of 32; revision 5). `Type` is not a reliable class: Quest 3 `soc-usr` is typed `SKIN` and sets SoC values up to SHUTDOWN 115 °C (both Quest 3 files). `Multiplier` is 0.001 or 1, except Quest 2 `batt-usr` at 0.1 | [M-static; C] |
| F34 | **The vendor images are ext4 without a journal**, with `shared_blocks` (a read-only compat feature: read-only use only), 4 KiB blocks, `dir_index` and extents; the configuration files are extent-mapped (inode flag `0x80000`). Same on all three images. **Exact feature set (revision 5):** `ext_attr dir_index filetype extent sparse_super large_file huge_file uninit_bg dir_nlink extra_isize shared_blocks`, nothing else: no `64bit` (so 32-byte group descriptors), no `metadata_csum` (so **no checksum authenticates any ext4 structure**: the reader's bounds checks and the file hash are the only protection), no `inline_data`, no `has_journal`. Inode size 256, flags `signed_directory_hash`. Block counts 164,943 (v66), 130,812 (v2.7), 72,239 (Quest 2), each smaller than its image (the rest is the verity hash tree and footer) | [M-static] `dumpe2fs -h`, `debugfs stat` |
| F35 | **`vendor` is a logical partition in `super` on both devices.** Bootloader `getvar all` lists `super` (Quest 3 8 GiB, FS-A-004 (private review record); Quest 2 6 GiB, FS-A-006 (private review record)) and no physical `vendor` or `system` partition. Unit 1's `vendor_a.img` comes from the PM's super dump of that unit (`firmware/quest3/PROVENANCE.txt:70`). **Unit 2 (v2.7, revision 5):** `super` → `/dev/block/sda7` (`partitions-by-name.txt:72`), 8,388,608 KiB = 8 GiB (`proc-partitions.txt:45`); `ro.boot.dynamic_partitions` true (`getprop-all.txt:1762`); a device-mapper device of exactly the v2.7 OTA `vendor.img` size (531,724 KiB = 544,485,376 B, `dm-11`, `proc-partitions.txt:134`) [M; identity by size only]. The LP-metadata layout we parse is AOSP's public `liblp` format [C]: no raw super image is held locally (O22) | [M; M-static; C] |
| F36 | **Meta's other mitigation layers (revision 4).** `vr_runtime_power_mitigation.json` holds one compact string that lists named VR-runtime mitigations, each tagged with level tokens (`T1`–`T3`, `B1`, `M1`). It differs between v66, v2.7 and the Quest 2; the meaning of each token is O23. `powerhint.cfg` is TOML. Its hints write `cdevN_upper_limit` of the DT limit zones under `/sys/devices/virtual/thermal/tz-by-name/` (v66 115 such lines in 53 sections, v2.7 282 in 175, Quest 2 114 in 81), so Meta deepens the kernel's one-step CPU maps (`thermal-control-design.md` §0.1) through power hints. Which hint `perf_service` selects at which severity is in its code (`thermal-control-design.md` §7.1 item 2) | [M-static; O] |
| F37 | **Slot suffix.** The Quest 3 cmdline carries `bootconfig` (FS-A-004 (private review record)), so `androidboot.slot_suffix` is expected in `/proc/bootconfig` [C]. The Quest 2 (4.19, no bootconfig) is expected to carry it in `/proc/cmdline` [C]. **Partly measured on Unit 2 (revision 5):** `ro.boot.slot_suffix` = `_a` (`getprop-all.txt:1773`); its `/proc/cmdline` carries `bootconfig` and **no** `androidboot.*` parameter (`proc-cmdline.txt:3`), so on the Quest 3 the slot can only come from `/proc/bootconfig` [M; D]. `/proc/bootconfig` itself was not read (§7.2), and the Quest 2 is unmeasured | [M; C] |
| F38 | **Virtual A/B (revision 5).** Unit 2 (v2.7) reports `ro.virtual_ab.enabled` = true and `ro.virtual_ab.retrofit` = true (`getprop-all.txt:2236-2237`); the v2.7 vendor `build.prop` sets both (`~/work/fs006-kernel/v27/vendor.img` `/build.prop:152-153`), the Quest 2 v2.7 vendor `build.prop` sets `ro.virtual_ab.enabled=true` (`:182`), and the v66 vendor `build.prop` sets neither (system properties not checked). Unit 2's baseline was taken on the boot after its OTA (`ro.boot.bootreason` `reboot,ota`, `:1758`). Under Virtual A/B an update is written as a **snapshot**: until the background merge after the next Android boot has finished, the booted filesystem is the dm-snapshot of the raw extents plus copy-on-write (COW) data, so **the raw `vendor<suffix>` extents are not the booted filesystem**: they hold the old version, or a mix while a merge runs [C, AOSP Virtual A/B]. COW data lives in `<name>-cow` partitions inside `super` and/or in image files on `userdata` [C, libsnapshot]; only the first is visible in the LP metadata. The snapshot state itself is kept on the `metadata` partition (`/dev/block/sda10` on Unit 2, `partitions-by-name.txt:43`) [C], which our reader does not read | [M; M-static; C] |
| F39 | **Child processes inherit the supervisor's scheduling (revision 5).** A forked child keeps the parent's RT policy and CPU affinity unless `SCHED_RESET_ON_FORK` is set, which resets only the policy, to `SCHED_NORMAL` nice 0 (`kernel/sched/core.c:3488-3503`; `(Q2) :3119-3134`), not the affinity [M-static]; the blocked-signal mask survives fork and `execve` [C, signal(7)]. A task in uninterruptible sleep (`D`, for example a block read) does not act on SIGKILL until the read returns [C]. **Both kernels have a pollable pidfd:** `pidfd_open` (`kernel/pid.c:585`; `(Q2) :499`, syscall 434 in `include/uapi/asm-generic/unistd.h:741`) and `pidfd_poll` (`kernel/fork.c:1845`; `(Q2) :1723`), so the Quest 2's 4.19 tree has it backported (this corrects §5.2's "`waitpid` on 4.19", which stays valid but is no longer needed) | [M-static; C] |
| F40 | **Unit 2 identity (revision 5, J-115).** Build `52433670036000520` = v2.7, `ro.build.type` user (`getprop-all.txt:1970`, `:1975`), `ro.vendor.build.version.incremental` `52433670036000520` (`:2215`), `ro.product.vendor.device` `eureka` (`:2149`): equal to the v2.7 OTA vendor `build.prop` (`/build.prop:6`, `:22`) [M; M-static]. [removed for publication] | [M; M-static] |

---

## 2. Thermal ownership model

| resource | owner | everyone else |
|---|---|---|
| Shutdown **decision** for thermal, battery, sensor or fan faults | `fs-thermald` | systemd only executes it; Valve units never decide it |
| Fan target (hwmon `rpm`) | `fs-thermald` (`thermal-control-design.md` §3.3) | Meta's kernel step_wise also drives the cdev; our 1 s re-assert wins (§3.3 there). Valve's `deckard-fan-control` never runs |
| CPU governor and `scaling_max_freq`; GPU `max_pwrlevel` | `fs-thermald` | read-only for every other unit (§6.2) |
| Suspend | nobody (P10: sleep targets masked) | logind suspend keys ignored |
| Charging, JEITA | **hardware/firmware**: Quest 3 ADSP battmgr; Quest 2 in-kernel SMB5 | **no software writes**, ours included (`thermal-control-design.md` §0.8; Quest 2 the same until its own ruling) |
| Kernel trip points | Meta's DT, unchanged | **nobody writes a trip** (keeps PMIC stage-2 rules, §5 there) |
| PMIC temp-alarm | Quest 3: not loaded (option A); Quest 2: built in, S2/S3 kept (F14) | — |
| User-visible thermal/battery warnings | `fs-thermald` (state file + LED; UI route [O]) | — |

**Technical prevention, not just masks** (FS-R-011 §7 D3: a unit mask does
not stop a direct invocation). In the Valve layer (§6.2):
- a top-level service drop-in (`/etc/systemd/system/service.d/`) sets
  `ReadOnlyPaths=` on the owned sysfs nodes for **every** service, and our
  own units reset it;
- Valve's Frame-hardware, power and charger units are masked **and** their
  executables are shadowed by a fail-closed stub (option D of
  `valve-image-slot-in.md` §3);
- the remaining hole is root processes outside any unit (pkexec helpers):
  they belong to the writer inventory [O].

---

## 3. Inputs

### 3.1 Quest 3 (eureka), first

| class | source (sysfs) | modules (v66) | rate | stale / fault rule |
|---|---|---|---|---|
| SoC | `thermal_zone*` types `cpu-*`, `cpuss-*`, `gpuss-*`, `nspss-*`, `ddr`; `soc-usr` | `qcom_tsens`; ADC for `soc_therm` | 1 s (+ netlink wake, F15) | per `thermal-control-design.md` §6.4; ≥ 1 per cluster, ≥ 2 GPU |
| skin | `surf-virt-usr`, and the same value recomputed from `pcb1`, `pcb3`, `pogo`, `soc`, `battery` with Meta's coefficients | `qcom-vadc-common`, `qcom-spmi-adc5-gen3`, `virtual_sensor` | 1 s | kernel vs recomputed > 5 °C for 30 s → use recomputed, flag |
| battery | `power_supply/battery/{temp,voltage_now,current_now,capacity,status}`; `batt-virt-usr`; remoteproc `adsp` `state` | ADSP start, `qti_battery_charger_main` (validated in `thermal-control-design.md` §6.7 trial **T3b**) | **5 s** (each read is a pmic_glink round trip) | ADSP not `running`; all three values frozen 60 s → battery-class fault (§6.4 there) |
| USB connector | `usb-conn` | ADC | 1 s | as SoC |
| PMIC die | six ADC die channels (iio) | ADC | 2 s | under option A only |
| fan | hwmon `rpm`, `pwm`; cdev `cur_state`; kmsg | `pwm-qti-lpg`, `panel_event_notifier`, `pwm-tach-fan` | 1 s | F1–F7 (§3.3 there) |
| LMh | `cpuN/dcvsh_freq_limit` | `qcom-cpufreq-hw` (already in the stage set) | 1 s | log only; a clamp below the cap with all zones "cool" is a sensor-plausibility flag |

### 3.2 Quest 2 (hollywood), second

| class | source | availability | rate | notes |
|---|---|---|---|---|
| SoC | tsens `cpu-0-{0..3}-usr`, `cpu-1-{0..7}-usr`, `cpuss-{0,1}-usr`, `gpuss-{0,1}-usr`, `vrapi-pmem` (zone names `v27-dtbo0.dts`) | **built in**; exist in a stage image (PORT-PLAN §1.4 item 5) | 1 s | many zones are `user_space` and do nothing without us (F1) |
| skin | `vrapi-front-panel` (virtual) | built in (`VIRTUAL_SENSOR=y`) | 1 s | its inputs and fault behaviour [O]; a recomputed cross-check needs them |
| battery | `power_supply/battery/*` (SMB5 + FG gen4), `batt-virt`, `batt-usr` | built in (F13) | 2 s | in-kernel: no ADSP staleness class, but frozen-value detection stays |
| board | `pcb1-usr`, `pcb2-usr`, `pcb3-usr`, `xo-therm-adc`, `imu-usr`, `rfpa-usr` | built in | 2 s | log; plausibility cross-check |
| fan | hwmon of `pwm-tach-fan` | **only after a DRM panel registers** (probe defers, `thermal-control-design.md` §0.9) | 1 s | headless phases have **no** fan control (§4.3) |
| BCL | `pm8150b-bcl-lvl*` | built in | 2 s | log |

### 3.3 Sensor-failure handling (both devices)

Unchanged from `thermal-control-design.md` §6.4 (P9), plus (revision 2
splits the low/broken side from the hot side, review 1 M2):
- **all reads use descriptors opened at start-up** (no path lookups later);
- **low or broken side → sensor fault (P9):** a read error (EIO, short
  read), a value below −20 °C, or a frozen value (stale rules of §6.4
  there). A faulted sensor is excluded from the max;
- **hot side → counted, not dropped:** a value above 125 °C, or a rise
  faster than 10 °C/s on a slow class (battery, skin, board), is an
  **anomaly that counts toward T4**. It immediately sets at least T3
  (SEVERE). If within **2 cycles** no **independent sibling** of the same
  class contradicts it, T4 latches. "Contradicts" means: at least one
  healthy independent sibling reads below that class's SEVERE threshold
  and none reads at or above it. A contradicted anomaly becomes a sensor
  fault (P9: SEVERE now, T4 after 120 s). A class with **no independent
  sibling** (Quest 3 `usb-conn`, the physical battery sensor on either
  device; virtual sensors derived from the same input are not independent
  [O20]) has nothing to contradict it: its hot anomaly above 125 °C, or a
  rise anomaly whose value has reached that class's SEVERE threshold,
  latches T4 after the 2 cycles. **A rise anomaly whose value is still
  below SEVERE on a no-sibling sensor is a P9 sensor fault** (SEVERE now,
  T4 after 120 s), not T4 (revision 3). A false latch costs availability,
  not safety (R19);
- a **class** is faulted when fewer than its minimum count of sensors are
  healthy; a class fault is SEVERE at once and GRACEFUL SHUTDOWN after
  120 s (P9); **two faulted classes → GRACEFUL SHUTDOWN at once**;
- the **start-up self-test** gates readiness: no READY → the image keeps
  its short bound (stage) or never starts load-producing units (Valve);
- a fault never lowers a level; the max over healthy sensors and
  uncontradicted hot anomalies is used.

---

## 4. Policy

### 4.1 Tiers

| tier | trigger (any) | actions | leaves when |
|---|---|---|---|
| **T0 NORMAL** | — | NORMAL caps (P11 ruling: L4), fan per §3.3 there (P1 floor) | — |
| **T1 NOTICE** | Meta LIGHT | log 1 s; LIGHT caps/fan floor (P3/P4) | below LIGHT − hyst for 30 s |
| **T2 THROTTLE** | Meta MODERATE | MODERATE caps and fan floor | below threshold − hyst for 30 s |
| **T3 WARN** (user-visible) | Meta SEVERE; any sensor/fan fault (P8/P9); a hot anomaly awaiting confirmation (§3.3); battery ≤ 10 % discharging (P13) | SEVERE caps and fan floor + LED pattern + state file + UI notice [O] | below SEVERE − hyst for 30 s, and shown ≥ 30 s |
| **T4 GRACEFUL SHUTDOWN** | Meta SHUTDOWN; P5–P9 escalations; two faulted classes; uncontradicted hot anomaly (§3.3); supervisor-loss (§5.4) | §5.3 sequence | **latching**: never cancelled |
| **T5 IN-BAND LAST RESORT** | T4 budget expired; or during T4 any SoC ≥ SHUTDOWN + 5 °C, battery ≥ SHUTDOWN + 2 °C or skin ≥ SHUTDOWN + 3 °C (P12) | bounded `sync` (A1); final softdog pet; **one** `reboot(POWER_OFF)` (A2); no further `reboot()` by anyone of ours; fallback = kernel timers (§5.2) | — |
| **T6 OUT-OF-BAND** (not ours) | — | Quest 3: critical trip + 100 ms attempt **only if temp-alarm is loaded**; Quest 2: msm watchdog bite after a stopped kernel (F18); PMIC stage 2/3 hardware; LMh; battery UVLO; the PM's manual route | — |

Thresholds are **Meta's, read from the user's own headset at runtime**
(revision 4, §4.5), each device's own (never a sibling's). The table
below is the **built-in fallback**, used on any doubt. It is also the
reference against which each entry of the known-firmware table is
reviewed. "Meta SHUTDOWN/SEVERE/LIGHT" in this document (P12, P13, the
gate) means the **active set**: the runtime values once accepted, else
these.

| device | skin L/M/S/**SHUT** | battery L/M/S/**SHUT** | SoC L/M/S/**SHUT** | source |
|---|---|---|---|---|
| Quest 3 | 48/50/52/**60** | 58/61/63/**65** | 89/92/95/**115** | `thermal-control-design.md` §2.2 (v2.7 JSON `c9301ff5…`; v66 JSON `e49b49fe…` identical except `usb-conn`, F31) |
| Quest 2 | 47/51/52/**60** | 53/–/58/**59** | 90 (cpu-1-*)/–/95/**115** | F12 (JSON `cc3e5137…`) |
| Quest Pro, Quest 3S | **[O]** (JSONs not extracted) | | | `thermal-control-design.md` §7.1 item 8 |

Plus the accepted departures (PM ruling 2026-10-09): usb-conn ≥ 70 °C (P5,
Quest 3), battery ≤ 3 % discharging (P6), PMIC die 95/115 (P7, Quest 3
option A), fan fault (P8), sensor fault (P9). Hysteresis is Meta's per
sensor for each step down, with a 30 s minimum dwell; every step up is
immediate. Where a device has no MODERATE value (Quest 2 battery and SoC),
that class goes from T1 straight to T3.

### 4.2 Battery and charger

- **Temperature** is the binding constraint (§6A.6): the battery row above;
  on the Quest 3 the battery class also needs ADSP liveness (§3.1).
- **Critical level:** P6 (≤ 3 % and discharging → T4). Meta's own value and
  any voltage cut-off are [O] (`thermal-control-design.md` §7.1 item 11);
  no voltage floor is invented here.
- **Charger:** no software writes (§2). The charger stays protected by
  ADSP JEITA (Quest 3) or SMB5 hardware/software JEITA with Meta's DT bands
  (Quest 2, F13); the Quest 3 kernel also cuts USB CC at `usb-conn` 60 °C
  (`thermal-control-design.md` §0.7).
- **Shutdown while a charger is attached:** the sequence is the same. For a
  `fastboot boot` image the device may then boot into Meta's off-mode
  charging (stock boot image, Meta's charger-mode module set including the
  thermal drivers, `init.insmod.charger.cfg`) [C]; our image does not
  persist. The T4 notice tells the user to **unplug** (P14). A **flashed**
  image (Unit 2 only, later) boots into **our** initramfs instead, whose
  thermal gate (§6.2) runs before anything else; its charger-mode boot
  behaviour is [O].

### 4.3 Fan (B-series rules)

Unchanged from `thermal-control-design.md` §3.3: temperature-driven from
the device's own Meta zones; **display state is not a cooling control**;
tach failure (F1–F7) → SEVERE now → T4 after 120 s (P8). Additions:
- **T4 and T5 set the fan to the top level first** and leave it there; the
  LPG is expected to hold that duty while the kernel finishes [C, O6].
- **Quest 2 headless phases:** the fan driver does not exist until a DRM
  panel registers. Any phase without a fan driver is **idle-only** and time-
  bounded; the supervisor treats "fan absent" as a fan fault unless the
  image declares a headless idle stage.

### 4.4 New proposals (continue §0.1's numbering): all approved by the PM (J-122)

Revision 5: P12–P18 are **approved as recommended** for design and harness
work (J-122); P18 is approved as (a), fall back. The "if rejected" column
is kept as the record of the alternative.

| # | proposal | why | if rejected |
|---|---|---|---|
| P12 | T4 budgets (Valve: T5 at 45 s; stage: ≤ 3 s = step stop 2 s + PID 1 poll ≤ 1 s, §5.3) and the T5 fast-escalation deltas (+5 SoC, +2 battery, +3 skin) | bounds the time spent above Meta's SHUTDOWN line | wait the full budget |
| P13 | User-visible WARN at Meta SEVERE, at any fault, and at 10 % battery (notice only; no device action) | the PM's "user-visible warning" tier; Android warns at low battery [C] | log only |
| P14 | "Unplug" notice on a T4 with a charger attached | off-mode charging may resume heating [C] | silent |
| P15 | **Valve only:** if A2's exit is observed (its power-off returned, F4), the supervisor writes `c` to a pre-opened `/proc/sysrq-trigger` → panic → `emergency_restart` (F24, F11), without the lock; dump mode already cleared (F20) | restarts at once instead of waiting for the softdog margin; the restart lands where §0 item 4 says [C] | the softdog alone (≤ P17's final margin later) |
| P16 | **Quest 2 stage-guard (S1) abort values** (§6.1): any SoC zone ≥ 60 °C; any board zone ≥ 40 °C; battery ≥ 45 °C; `vrapi-front-panel` ≥ 40 °C | Quest 3 T1 equivalents; battery and skin at Meta's **first fan trip** (`perf-envelope-quest1-2.md:29-32`), because a headless stage has no fan; far below Meta's LIGHT (47/53/90) | Quest 3 T1 values only (SoC, board) |
| P17 | **softdog margins:** running margin 30 s; at T5/TRIP a final pet with margin `M_final` = 30 s, no pet afterwards; `M_final` must be ≥ 2 × the measured kernel power-off time (T5 trial, §7.2) + 10 s (Quest 2 `msleep`, F4) | a stuck supervisor and a hung kernel power-off path both end in a restart within a bound | 60 s (softdog default) |
| P18 | **Unknown Meta configuration (revision 4):** a `thermal_info_config.json` whose sha256 is not in the reviewed known-firmware table (§4.5.3) is **not applied**. The built-in values are used, the user is told, and the hash is logged so that the file can be reviewed and added | "fall back on any doubt" (the PM's J-118 decision). An unreviewed file is doubt, and only review can tell a new Meta policy from a corrupt or altered file | **(b)** apply an unknown file if it passes the schema, coverage and bounds checks **and** no threshold is looser than the fallback, with a NOTICE that it is unreviewed |

### 4.5 Meta's configuration at runtime (revision 4, PM decision J-118)

**The PM's rule:** follow Meta literally where hardware-specific. Our
supervisor reads Meta's thermal configuration from the user's own headset
at runtime and applies Meta's thresholds and mitigation order. Nothing of
Meta's is copied into the repo, and fixed values are used only as a
fallback.

#### 4.5.1 What is read

| file (on `vendor`, active slot) | what we take | Quest 3 v66 (Unit 1) | Quest 3 v2.7 | Quest 2 v2.7 |
|---|---|---|---|---|
| `/vendor/etc/thermal_info_config.json` | per-sensor LIGHT/MODERATE/SEVERE/SHUTDOWN, hysteresis, `Multiplier` (F33) | 27,284 B, `e49b49fe…` | 27,505 B, `c9301ff5…` | 16,015 B, `cc3e5137…` |
| `/vendor/etc/vr_runtime_power_mitigation.json` | the ordered list of VR-runtime mitigations and their level tokens (F36); exported, not actuated | 178 B, `674af9d5…` | 189 B, `d3a2ffa4…` | 183 B, `f525cc6a…` |
| `/vendor/build.prop` | `ro.product.vendor.device` (`eureka` / `hollywood`), `ro.vendor.build.version.incremental` (`50105190000000511` / `52433670036000520` / `52242990024200150`); our reader caps each value at 92 bytes (both are far shorter) and the file at 64 KiB | identity | identity (equals Unit 2's, F40) | identity |
| `powerhint.cfg`, `powerhint_holdout.cfg` | **not read** in revision 4: their hint-to-severity binding is in `perf_service` code (F36; `thermal-control-design.md` §7.1 item 2) | — | — | — |

Hashes and sizes are [M-static] from the images in Sources (F31). The
odm partition holds no thermal configuration (F31). The property
`vendor.thermal.config` could rename the file (F32). It is unset in every
vendor property file checked and in the v66 odm's (the only odm image
held), so the reader uses the default name;
a §7.2 probe confirms the property is empty on each unit (O24).

**Kernel-side Meta policy is already read at runtime.** The DT trips,
hysteresis and cooling maps (fan steps, the one-step CPU maps, the USB CC
cut) come from the DTB the image boots. The kernel exposes them in sysfs
(`thermal_zone*/trip_point_N_{temp,hyst}`, `cdevK`, `cdevK_trip_point`).
`thermal-control-design.md` §3.3 already reads them at start-up; in
revision 4 they are no longer "asserted equal to the device config",
because they are the source.

#### 4.5.2 How the files are reached (`fs-metacfg`, our initramfs)

A one-shot static helper, `fs-metacfg`, started by `fs-thermald` as the
**first step of its start-up**, before `mlockall`, before the CPU0
pinning and the `SCHED_FIFO` elevation, before the actuators are
pre-forked, and before the self-test and the thermal gate (§5.1, §6.2).
It is a separate process so that the supervisor never parses Meta's
JSON, LP metadata or ext4 structures. It runs once per boot. The vendor
partition is never written by anyone of ours, so it is not re-read.

**The boot never waits on the helper (revision 5, review 4 M2).** A
block read in uninterruptible sleep ignores SIGKILL until it returns, and
a child that inherited `SCHED_FIFO` 60 and the CPU0 pinning could not be
pre-empted by the parent that is meant to kill it (F39). So:
- **spawn rules:** the child is forked while `fs-thermald` is still
  `SCHED_OTHER` and unpinned; as a second barrier the parent sets
  `SCHED_RESET_ON_FORK` before the fork (F39) and drops the flag again
  when it elevates itself to `SCHED_FIFO` 60, so the actuators A1/A2,
  pre-forked later, keep their RT policy (§5.1); the child, before
  `execve`, sets its affinity to all CPUs, empties its signal mask, closes
  every descriptor except the record pipe's write end, and sets
  `RLIMIT_AS` 32 MiB, `RLIMIT_CPU` soft 1 s / hard 2 s, `RLIMIT_FSIZE` 0,
  `RLIMIT_NOFILE` 16 and `RLIMIT_NPROC` 0 (no further fork);
- **bounded wait:** the parent never calls a blocking `waitpid`. It waits
  with `ppoll` on the record pipe and a pidfd (both kernels, F39) against
  one **2 s** deadline on `CLOCK_BOOTTIME`, reading at most the framed
  maximum below. At the deadline, or on any framing error, it sends
  SIGKILL, **closes the pipe**, selects the fallback (`reason=reader-timeout`
  or `reader-bad-record`) and continues the boot at once, even if the
  child is stuck in `D` state. The child is reaped later with
  `waitid(…, WNOHANG)` on each supervisor tick, and a child still unreaped
  after 60 s is logged once (`/dev/pmsg0`); it holds only a read-only
  descriptor of `super`;
- **fixed framing, so the parent's own parse is bounded:** one header of
  fixed size (magic, version, status code, three lengths), then the raw
  `thermal_info_config.json` bytes (≤ 65,536), the raw VR-runtime list
  (≤ 4,096), the two `build.prop` values (≤ 92 bytes each), and the
  canonical record as fixed-size entries (≤ 128 sensors × a fixed entry
  size: name ≤ 32 bytes, seven slots and seven hysteresis values as
  signed m°C integers with an "unset" code, the multiplier as an
  integer ratio). Any length over its cap, a count over 128 or a short
  read → fallback. The parent reads nothing else from the child.

`fs-thermald` makes the final acceptance decision (§4.5.3) from those
bytes: it computes the file hashes and the parse digest **itself** (m5).

| | **option B (approved, J-122): read-only block reads, no mount** | option A: dm-linear plus a read-only mount |
|---|---|---|
| locate | the one block device whose sysfs `uevent` has `PARTNAME=super`, with size equal to `getvar`'s (Quest 3 `0x200000000`, Quest 2 `0x180000000`, F35; Unit 2 measured, F35); anything else → fallback. **Revision 5 (m4):** the storage driver (UFS on the Quest 3: `sda7` on Unit 2) may still be probing when the initramfs starts, so the helper first scans `/sys/class/block`, and if `super` is not yet there, listens on a `NETLINK_KOBJECT_UEVENT` socket for an `add` event with `PARTNAME=super`, inside the same 2 s budget (event-driven, no sleep loop); not found in time → fallback (`reason=no-super`) | same |
| open | `O_RDONLY \| O_CLOEXEC` only; `pread` and **one** ioctl, `BLKGETSIZE64` (revision 5: `BLKSSZGET` dropped, because LP sectors are 512 bytes whatever the device's logical block size, which is 4096 on UFS [C, liblp]); seccomp filter after the open (below); never `O_RDWR`, no other ioctl, no `BLKRRPART` | `O_RDONLY` for the LP read, then device-mapper ioctls |
| logical partition | parse the LP geometry and the metadata for the active slot (F37) [C, liblp format], within the **limits** below: magic, header and table SHA-256 checksums, partition `vendor<suffix>`, every extent `LINEAR` and inside `super`; **no `*-cow` partition** (Virtual A/B, below) | same parse, then a transient dm-linear device `fs-vendor-ro` created with the read-only flag (`BLK_DEV_DM=y` on both kernels: v66 `kernel.config:1997`, Quest 2 `kernel.config:1694`) |
| filesystem | our own bounded ext4 reader, within the **checks** below: superblock magic, block size 4096, **feature set exactly as F34** (a journal or any other feature → fallback); path walk `/` → `etc` → name by a linear scan of directory blocks (valid with `dir_index` [C]); regular file, not a symlink; extent depth ≤ 2; size ≤ 64 KiB. **ext4 only:** a future vendor image in another format (for example EROFS) fails the superblock check and falls back (`reason=fs-type`) until a reader for it is designed and reviewed | kernel ext4 (`EXT4_FS=y`, v66 `:6375`, Quest 2 `:4998`), `mount -o ro,noload,nosuid,nodev,noexec`; read the three files; `umount`; remove the dm device |
| kernel state changed | **none** | a transient dm device and a mount (volatile) |
| integrity | no dm-verity in either option: integrity comes from the hash table (§4.5.3); verifying through Meta's vbmeta hashtree is a later option (O26) | same |
| cost | a small extra parser to test and fuzz (§7.1) | the kernel's mature ext4 code; more steps, and a cleanup that must happen on every path |

**LP parser limits (revision 5, m1; all [C, liblp], checked by our own
LP writer's fixtures, §7.1).** Only the **primary** geometry (offset
4096, `LP_METADATA_GEOMETRY_SIZE` 4096, with its SHA-256 checksum) and
the **primary** metadata copy of the active slot (offset 12288 + slot ×
`metadata_max_size`) are read. The backup geometry (8192) and the backup
metadata copies are **not** tried: a primary that fails any check is
doubt, so the result is the fallback (`reason=lp-primary`), never a
repair. Accepted values: geometry `metadata_slot_count` ≤ 3 and the slot
index below it; `logical_block_size` a multiple of 512 (logged, not used:
every LP offset and extent is in 512-byte sectors, whatever `BLKSSZGET`
would say); header `major_version` 10, `minor_version` ≤ 2,
`header_size` 128 (minor 0–1) or 256 (minor 2); each table's
`entry_size` ≥ the size of the structure we know (partition 52, extent
24, group 48, block device 64 bytes) and each table inside `tables_size`,
which is ≤ `metadata_max_size` ≤ 64 KiB; overflow-checked
`num_entries × entry_size`; **exactly one** block-device entry, whose
size equals `BLKGETSIZE64`; partition names NUL-terminated within their
36 bytes; the `vendor<suffix>` partition unique and without the
`DISABLED` attribute; every extent `target_type` LINEAR (0) with
`target_source` 0, and `(target_data + num_sectors) × 512` computed
without overflow and ≤ the device size; extents of `vendor<suffix>` sum to
at least the ext4 size (`s_blocks_count` × 4096).

**Virtual A/B: a pending merge → fallback (revision 5, review 4 M1;
F38).** If the active slot's metadata lists **any** partition whose name
ends in `-cow`, a snapshot merge is pending and the raw extents are not
the booted filesystem: fallback, `reason=vab-merge`, logged with the
names of the `-cow` partitions. This test is necessary but not
sufficient, because COW data may lie wholly in image files on `userdata`
with no `-cow` entry in `super` (F38) [C]; the vendor-incremental
requirement of §4.5.3 step 3 then catches a **mixed** read (files from
two versions), but a read that is consistently the **older** version
can still match the older version's reviewed row. That remainder is
declared (R25, O27). Two further LP signals, the header flag
`LP_HEADER_FLAG_VIRTUAL_AB_DEVICE` and the partition attribute `UPDATED`,
are **logged only** until their meaning after a finished merge is
settled (O27) [C, liblp].

**ext4 reader checks (revision 5, m2).** There is no `metadata_csum`
(F34), so nothing in the filesystem is authenticated and every field is
bounded before use: superblock magic `0xEF53`; `s_log_block_size` = 2
(4096 bytes); feature words exactly F34's set; `s_inodes_per_group`,
`s_blocks_per_group` non-zero and the group count consistent with
`s_blocks_count`; 32-byte group descriptors (no `64bit`); inode numbers
in 1…`s_inodes_count`; inode size 256 as in the superblock; the inode
must have the extent flag and **not** the inline-data flag;
`i_size_high` = 0 and `i_size` ≤ 64 KiB, for the three files and for
the two directories `/` and `/etc` (each is one 4096-byte block today,
flags `0x80000` only, i.e. not hash-indexed, on all three images
[M-static, `debugfs stat`]); extent header magic `0xF30A`,
`eh_entries` ≤ `eh_max`, `eh_max` ≤ what fits in its block or in the
inode's 60 bytes, depth ≤ 2; an extent with `ee_len` > 32,768 (an
uninitialised extent) or a gap between extents (a hole) → fallback;
every physical block < `s_blocks_count` **and** inside the `vendor`
partition's length; directory entries with `rec_len` ≥ 12, a multiple of
4, ≤ the rest of the block, and `name_len` + 8 ≤ `rec_len`; at most
16 directory blocks scanned and at most 1 MiB read from `super` in total.
Any failure → fallback (`reason=ext4-<check>`).

**seccomp (revision 5, m3).** The filter is installed **after** the
locate (sysfs scan, uevent socket), the slot read (`/proc/bootconfig` or
`/proc/cmdline`), the `O_RDONLY` open of `super` and the `BLKGETSIZE64`
call; those steps use only `openat` with `O_RDONLY`, `getdents64`,
`read`, `close`, `fstat`, `socket`/`bind`/`recvmsg` on the uevent socket,
`ppoll`, `ioctl(BLKGETSIZE64)`, `brk`, `mmap`/`munmap` and `clock_gettime`
(checked under qemu `-strace`, §7.1). After `PR_SET_NO_NEW_PRIVS` the
filter allows only: `pread64` on the `super` descriptor, `write` on the
pipe descriptor (descriptor arguments compared), `close`, `fstat`, `brk`,
`mmap` without `PROT_EXEC` and `munmap`, `ioctl` with the command number
`BLKGETSIZE64` only, `clock_gettime`, `rt_sigreturn` and `exit_group`;
anything else kills the process (`SECCOMP_RET_KILL_PROCESS`), which the
parent sees as a bad record → fallback.

Option B was recommended and approved (J-122). It changes no kernel state, behaves the same on
4.19 and 5.10, needs no cleanup, and leaves nothing mounted that a later
Valve unit could find. **Stage images (S0/S1) do not run `fs-metacfg`**:
their thresholds are fixed stage values far below Meta's LIGHT (§6.1,
P16, T1), so they need no Meta file and gain no new action.

#### 4.5.3 Validation: any doubt → fallback, and the user is told

Each step must pass. The first failure selects the **built-in fallback**
(§4.1 values, with Meta's hysteresis as recorded there), with a reason
code.

1. **Source identity.** `super` found as in §4.5.2; the LP checksums are
   valid and every LP limit holds (§4.5.2); a `vendor<suffix>` partition
   exists for the slot read from `/proc/bootconfig` (Quest 3; its
   cmdline has no `androidboot.*`, F37) or `/proc/cmdline` (Quest 2);
   **no `-cow` partition is listed (Virtual A/B, F38, `reason=vab-merge`)**.
   `ro.product.vendor.device` must equal the running device (Quest 3
   `eureka`, Quest 2 `hollywood`), which is checked against the DT
   `model` our image reads at start-up.
2. **File checks** (§4.5.2 B, or the mount in A): a regular file, at most
   64 KiB, read completely.
3. **Known-firmware table** (in the repo: **hashes only**). Each row holds
   device, vendor incremental, file, size, sha256, the **parse digest**
   (the sha256 of *our* canonical record of the values we extracted:
   sensor name; the seven slots in m°C or unset; hysteresis; multiplier,
   sorted by name) and, **new in revision 5, the sha256 of the VR-runtime
   list** of the same firmware. **`fs-thermald` computes all three
   itself** (review 4 m5): the sha256 of the raw JSON bytes the helper
   shipped (≤ 64 KiB, §4.5.2 framing), the sha256 of the canonical record
   as received, and the sha256 of the raw VR-runtime list; the helper
   never supplies a hash. The file's sha256 **and** the parse digest must
   both match a row for this device, **and the vendor incremental read
   from `build.prop` must equal that row's** (revision 5, M1: a read that
   mixes two versions fails here). A matching file hash with a different
   digest means a parser defect → fallback plus a fault record. An
   unknown file hash → fallback (**P18**). The VR-runtime list is
   exported (§4.5.4 layer 5) **only if** its hash equals the row's;
   otherwise it is not exported and a NOTICE says so (the thresholds are
   unaffected, since the list has no actuator). Rows today: the three
   files of F31, Quest 3 v66 and v2.7 and Quest 2 v2.7, reviewed against
   §4.1. A new row is a reviewed, hash-only change, made offline from an
   extract the PM owns.
4. **Strict schema.** RFC 8259 JSON, depth ≤ 4, duplicate keys rejected,
   only the keys of F33 (an unknown key, for example `BindedCdevInfo`,
   could change the meaning → fallback). `HotThreshold` and
   `HotHysteresis` have exactly 7 slots, each a number, a numeric string or
   `"NAN"`. **Revision 5 (m6):** `VrThreshold` must be the scalar string
   `"NAN"` (its meaning is unknown, O25, so any other value is doubt);
   `Monitor` must be `true` on **every** sensor with a set slot
   (temperature or BCL) and absent or `true` elsewhere (today 36, 37 and 19 sensors,
   F33): a set sensor that Meta does not monitor would change the
   meaning. `Multiplier` must equal the value our class map expects for
   that sensor (0.001 for m°C zones, 0.1 for Quest 2 `batt-usr`, 1 for BCL
   levels).
5. **Sanity bounds (ours).** The **class of a sensor comes from our class
   map, never from Meta's `Type`** (revision 5, m6): Quest 3 `soc-usr` is
   typed `SKIN` but sets SoC values up to SHUTDOWN 115 °C (F33), so it is
   in our SoC class and bounded at 115, not at skin 60. For temperature
   sensors, every set slot is 35–125 °C; set slots strictly increase from
   LIGHT to SHUTDOWN; **CRITICAL and EMERGENCY must be unset** (revision
   5: our class map records them unset for every sensor, so step 6 would
   reject a set one anyway; the former "or between SEVERE and SHUTDOWN"
   contradicted step 6 and is removed: a file that sets them falls back);
   every hysteresis is ≥ 0 and keeps its release point (threshold −
   hysteresis) at or above 20 °C (the largest reviewed value is Meta's
   v2.7 `usb-conn` 45 °C at 70 °C; SoC, battery and skin are ≤ 5 °C); no
   SHUTDOWN is above the highest SHUTDOWN that a
   reviewed Meta file sets for that class (SoC/GPU/NPU 115, battery 65,
   skin 60 °C; `PROJECT_SETUP` §6A item 1). BCL entries are not
   temperatures: they are logged and not bounded.
6. **Coverage against the running kernel.** Every sensor of our class map
   that is required on this device (§3.1, §3.2) is in the file, with
   exactly the set slots that our class map records for that sensor (for
   example, on the Quest 2 no battery or SoC sensor sets MODERATE, and only
   `cpu-1-*` sets LIGHT). Every sensor in the file that has a set temperature slot is
   in our class map, so no Meta threshold is silently dropped. Each one
   exists as a `thermal_zone*/type` of the same name in sysfs; a sensor
   missing at runtime is a sensor fault (P9), not a reason to drop it.

**Telling the user.** A fallback sets `limits=builtin reason=<code>` in
`/run/fs-thermald/state`, writes a line to the console, the journal and
`/dev/pmsg0`, and raises a one-time NOTICE through the UI route (O11). In
trials, the PC console checklist (J-118) shows it. It is **not** a WARN
and does not light the WARN LED, because the fallback values are Meta's
reviewed numbers. Accepted runtime values set `limits=meta-runtime`, with
the file hash and vendor incremental. Both cases log the active threshold
vector (numbers only) at start-up (§6.6 of `thermal-control-design.md`).

**No set means no load.** A device without fallback values (Quest Pro,
Quest 3S: §4.1 [O]) cannot fall back, so `fs-thermald` never reports
READY there and no load-producing unit starts.

#### 4.5.4 Meta's mitigation order mapped onto our tiers and actuators

Meta acts in this order as temperature rises (lowest trigger first). The
configuration for each layer is on the device.

| # | Meta layer (where configured) | Meta's trigger | our tier | our actuator / behaviour |
|---|---|---|---|---|
| 1 | Kernel DT fan steps (DTB; sysfs trips) | first fan trips: **Quest 3** SoC 60, battery 45, skin 42 °C; **Quest 2** CPU/GPU 70, battery 45, front panel (`vrapi-front-panel`) 40 °C (`perf-envelope-quest1-2.md:29-32`; revision 5) | T0 | fan demand = Meta's demand computed from the **runtime** trips (`thermal-control-design.md` §3.3), raised by our P1/P4 floors, never lowered. Quest 2: only while a fan driver exists (after a DRM panel, §4.3) |
| 2 | Kernel DT CPU/GPU maps; USB CC or charging cut (DTB) | **Quest 3** battery 45/58, skin 48, SoC 89 °C; `usb-conn` 60 °C. **Quest 2** (revision 5): `cpu-1-x-limit` 90 °C (hyst 5), `gpuss-max-step` 95, `cpu-0-x-step` 110 (isolates the core), USB-C charging reduced at 53 and suspended at 55 °C (`perf-envelope-quest1-2.md:24-27`, `:35`) | T0–T1 | **executed by the kernel itself**, not duplicated. Our caps are combined with it by minimum (effective limit = min, `thermal-control-design.md` §4.1), so we never relax it. We make no `battery_charger` (Quest 3) or SMB5 (Quest 2) write (§2) |
| 2a | **Quest 2 only (revision 5):** `user_space`-governed DT zones (25 zone nodes in `v27-dtb1.dts`, 19 in `v27-dtbo0.dts`; the merged count is not computed), whose cooling Meta's **userspace** drives | Meta's userspace action and trigger for them: **[O] (O29)** | T1–T3 | **not replicated: an unmapped layer, declared [O]**. Our tiers cover those sensors through the JSON severities (layer 4) and our P3 caps and P4 fan floors; nothing of ours writes their `cdev` or trip nodes. If O29 finds a Meta action our tiers do not cover, it becomes a departure for the PM to rule on |
| 3 | Power-HAL hints that deepen those maps (`powerhint.cfg`, `cdevN_upper_limit`, F36) | chosen by `perf_service` code [O] (`thermal-control-design.md` §7.1 item 2) | T1–T3 | **not applied** (binding unknown, and a new write class). Our P3 graded caps stand in (accepted departure) |
| 4 | HAL severities (`thermal_info_config.json`) | per-sensor LIGHT / MODERATE / SEVERE (runtime values) | T1 / T2 / T3 | P3 caps, P4 fan floors; WARN (P13) at SEVERE. CRITICAL / EMERGENCY are unset in every reviewed file; a file that sets them falls back (§4.5.3 step 5, revision 5). If a future reviewed row needs them, the class map and this row are changed with it (they would map to T3) |
| 5 | VR-runtime mitigations (`vr_runtime_power_mitigation.json`) | level tokens `T1`–`T3`, `B1`, `M1` [O23] | — | **no actuator in our stack**: the ordered list is exported in `/run/fs-thermald/state` for a future compositor shim (frame-rate or resolution limits, O11). Its order is kept as Meta wrote it |
| 6 | HAL SHUTDOWN (`thermal_info_config.json`); Android's ThermalManagerService [C] | per-sensor SHUTDOWN | T4 | graceful shutdown (§5.3), latching |
| — | none (Meta has no userspace layer here) | — | T5 | ours: one `reboot(POWER_OFF)`, kernel timers (§5.2) |

**Order invariant** (tested, §7.1): no step is ever applied while an
earlier step that its temperature implies is not, and no runtime value
ever lowers a level below what our own rules require. The fan is always
at least at Meta's DT demand before any cap of ours. A cap is never
looser than the kernel's own map, and T4 never waits on a layer we do
not actuate.

#### 4.5.5 Across firmware versions

- **Quest 3 v66 (Unit 1, `fastboot boot`):** file `e49b49fe…` (a known
  row). The values are those of §2.2 in `thermal-control-design.md`,
  without `usb-conn`; the VR-runtime list is the v66 variant. Our P5
  (`usb-conn` ≥ 70 °C → T4) stays ours.
- **Quest 3 v2.7 (the OTA; Unit 2 since its update, J-94, J-115):** file
  `c9301ff5…` (a known row). It adds Meta's `usb-conn` LIGHT 70 °C
  (hysteresis 45), which maps to T1, while P5 at the same temperature
  still takes T4, so P5 dominates. The VR-runtime list differs from v66
  (F36), which is exported only. **Unit 2 (revision 5):** build
  `52433670036000520` (user), slot `_a`, vendor incremental
  `52433670036000520`, device `eureka` (F40), all equal to the OTA's, so
  row `c9301ff5…` is **expected** to match; that is confirmed only by the
  read-only `sha256sum` probe (§7.2). Virtual A/B is enabled on it
  (F38): if a merge is still pending when FrameShift boots, the reader
  falls back (`vab-merge`).
- **Mixed versions:** a `fastboot boot` image carries its own kernel and
  DTB, while `vendor` is whatever the slot holds (for example a v66 image
  on a v2.7 slot). Thresholds follow `vendor` (hardware policy); trips
  follow the running DT. The v66 and v2.7 DTs have identical thermal
  trips and maps (`thermal-control-design.md` Sources), so the coverage
  check (§4.5.3 step 6) passes. The record logs both versions. That route
  is named, not proposed (J-34).
- **Quest 3 v71, v72, v76, v84:** no vendor extract is held locally
  (`firmware/quest3/v72-user_ota/` and `v84-user_ota/` hold boot-chain
  images only), so there is no row and they use the **fallback** under
  P18 until a reviewed row is added. (Revision 5: Unit 2 is no longer on
  v71, see the v2.7 bullet.)
- **A future vendor image that is not ext4** (for example EROFS) falls
  back (`reason=fs-type`, §4.5.2) until a reviewed reader for it exists,
  even if its JSON is unchanged (revision 5 nit).
- **Quest 2 v2.7:** file `cc3e5137…` (a known row; F12 values). The unit's
  own build must still be confirmed equal to the OTA's (§7.2 probe); if
  it differs, the unit uses the fallback. Virtual A/B is enabled in its
  vendor `build.prop` (F38), so the `vab-merge` rule applies. Many
  Quest 2 zones use the `user_space` governor (`thermal-control-design.md`
  §8), and Meta's userspace action for them is [O] (O29; §4.5.4 layer
  2a). Our tiers cover them through the JSON severities; the
  `single_step` kernel zones act on their own.

#### 4.5.6 What remains ours

The mechanism: `fs-metacfg`, the validation rules, bounds and class map
(sensor name → class, required counts, independent siblings [O20]), the
decision core, the tiers, the 30 s minimum dwell, the fault and
hot-anomaly rules (§3.3, P8, P9), the known-firmware table, the fallback
values and the user notices. The accepted departures P1–P11
(PM 2026-10-09) and P12–P18 (approved, J-122). P12's deltas and P13's
trigger now apply to the **active** SHUTDOWN and SEVERE values. The
stage guard's fixed values (P16, T1). The **last-resort path** (T5, A1/A2,
`fs-poweroff-final`, the softdog, the pet deadline) and the initramfs
gate's logic, whose values now come from the active set.

#### 4.5.7 What the repo holds

The file hashes, sizes, vendor incrementals and parse digests of the
known-firmware table; the fallback numbers already in this document; the
class map; and **synthetic** test fixtures that we write in the same
schema, with invented values (§7.1). The differential test against the
real files runs only on the PM's machine, reading the gitignored
`firmware/` tree and the WSL extracts, and is skipped when they are
absent. It never writes a Meta file, or any excerpt of one, into the
repo or into an evidence bundle. On the device, the record lives in RAM
(`/run`) and in the user's own logs.

---

## 5. Mechanism

### 5.1 The supervisor (`fs-thermald`)

- **Static aarch64 C**, built like `fs-supervise` (`devices/quest3/common`),
  no dependency on the Valve rootfs; a **pure decision core**
  `decide(state, readings, now) → (actions, state)` driven by a per-device
  table. The **Python reference model** of the same core is the test oracle
  (differential testing, §7.1), as FSB1 has two independent decoders.
- **Start-up, once:** load the built-in per-device table; **first**, still
  `SCHED_OTHER` and unpinned, spawn `fs-metacfg` and wait for its record
  with the bounded, non-blocking wait of §4.5.2 (2 s; revision 5: a stuck
  helper never holds up the boot); accept Meta's runtime
  values only if every check of §4.5.3 passes, otherwise use the fallback
  and say so; log the source, the hashes and the active threshold vector;
  only then open every sysfs node,
  `/dev/pmsg0`, `/dev/kmsg`, `/proc/1/comm`, `/proc/sysrq-trigger` (only
  if P15 is ruled) and `/dev/watchdog` (§5.4); `mlockall`;
  `OOMScoreAdjust`/`oom_score_adj` −1000; **`sched_setaffinity` to CPU0**
  (F21); `SCHED_FIFO` priority **60**, above the threaded-IRQ default 50
  (F22), with `RLIMIT_RTTIME` soft = hard = 500 ms (revision 3: the soft
  limit only sends SIGXCPU, which is blocked, F26; the hard SIGKILL kills a
  spinning loop, which then never starves the system); every other service
  gets `RestrictRealtime=yes`, and the few that need RT get
  `CAP_SYS_NICE` removed and `LimitRTPRIO=` ≤ 49 (§6.2; `CAP_SYS_NICE`
  bypasses `LimitRTPRIO`, F25); **pre-fork two actuators** (A1
  `sync`, A2 power-off), also pinned to CPU0, blocked on pipes, so no fork
  is needed in an emergency; then the self-test; READY. `fs-thermald` is
  not a systemd unit, so the services' `CapabilityBoundingSet=` and
  `RestrictRealtime=` (§6.2) do not apply to it.
- **Actuators act only on an exact command byte.** A pipe EOF (supervisor
  dead) or any other byte → the actuator `_exit`s **without acting**. A2's
  body is the freestanding `fs-poweroff-final` code (§5.2), **linked in,
  never `exec`'d**: A1 and A2 never `exec`, so they keep the `@` `argv[0]`
  copied at the fork (O7). Right after the fork each closes
  `/dev/watchdog` and every descriptor it does not use (revision 3), so
  only the supervisor holds the softdog.
- **Loop:** 1 s tick (`timerfd`), poll-wake on thermal netlink (Quest 3),
  read, `decide`, apply, read back, pet the softdog **only after a complete
  cycle** (a stuck read stops the petting).
- **Pet deadline (revision 2, M1).** The softdog survives a kernel
  power-off (F7). If the supervisor kept petting while the kernel hangs in
  `device_shutdown()`, the softdog would never fire. So once **any**
  shutdown is under way, petting ends at a fixed time: at the latest at
  T5's A2 call (T4 + 55 s, final pet with `M_final`, P17), never later.
  "Shutdown under way" is any of: our own T4; a `SHUTDOWN` byte from
  `fs-thermald-shutdown.service` (stopped early in every systemd shutdown,
  §6.2); PID 1's `comm` read through the pre-opened `/proc/1/comm` becoming
  `systemd-shutdow` (the descriptor follows the task across `exec`) [D].
  A user-requested shutdown gets the same 55 s + `M_final` bound.
- **Any detected shutdown ends in our power-off (revision 3, review 2
  item 3).** Whatever the verb (power-off, reboot, kexec; halt and
  soft-reboot are masked, §6.2), from the moment a shutdown is detected
  the supervisor runs A1 at + 45 s and the final pet + A2 at + 55 s,
  exactly as T5. So the softdog can only fire **after a power-off
  began** (its notifier has cleared dump mode, F20), or not at all
  (a `RESTART` already under way stopped it, F7, and A2 then blocks
  harmlessly on the lock). A user reboot that takes longer than 55 s
  therefore becomes a power-off. The softdog firing on a **running**
  system is left only to the supervisor's own death or stall (running
  margin, R11).
- **Direct `reboot()` by other processes is blocked (revision 3, review 2
  item 2).** Every service runs without `CAP_SYS_BOOT` in its bounding set
  (§6.2), so `systemctl poweroff -ff`, busybox `poweroff -f` or a Valve
  script inside any service gets `EPERM` before the lock (F27) and must go
  through PID 1, where the detectors see it. The remainder is R21.
- **No path lookups after start-up.** After a busybox `switch_root` the
  initramfs is emptied; pre-opened descriptors stay valid, and anything new
  is reached through `/proc/1/root/` [D].
- **Signals:** every blockable signal is blocked. SIGKILL and SIGSTOP
  cannot be blocked: SIGKILL is the "crashed" row of §5.4, SIGSTOP the
  "stopped" row (both end the petting, so the softdog and the heartbeat
  watcher cover them). `argv[0]` begins with `@` (systemd's
  root-storage-daemon convention: excluded from the final killing spree)
  [C, systemd.io; verify on 257.7, O7].

### 5.2 Who calls `reboot(POWER_OFF)`, and what happens if it returns

F4 makes a returned power-off a dead end for userspace: the reboot lock
stays held, the other CPUs are stopped and the devices are shut down.
**Revision 2 therefore has no userspace fallback after a `POWER_OFF`**
(revision 1's "supervisor calls `RESTART` 10 s later" would have blocked
for ever in `mutex_lock`, review 1 B1). The design instead chooses the
caller so that its failure ends in a lock-free restart, and leaves the
rest to timers that survive the kernel path.

| image | caller | if `pm_power_off` returns | if `device_shutdown()` hangs |
|---|---|---|---|
| stage (S1) | **PID 1 only**, by `exec` of `fs-poweroff-final` (§6.1). The guard never calls `reboot()` | PID 1 `do_exit`s → panic → `emergency_restart` at once (F19), no lock; dump mode already cleared (F20) | softdog, **if** the guard opened it (§6.1; Chair), fires `M_final` after TRIP (F7); otherwise Quest 3: nothing (R13); Quest 2: msm watchdog keeps being petted (F18), so nothing |
| Valve, normal | systemd-shutdown as PID 1 (`poweroff.target`, or `poweroff-force` at 35 s; any other user shutdown verb likewise with its own target, all bounded at 35 s, §6.2) | PID 1 panics → restart (F19) | softdog (pet deadline, §5.1), ≤ 55 s + `M_final` after T4 or after a detected user shutdown (§5.1) |
| Valve, T5 | A2 (pre-forked, pinned to CPU0). If PID 1 already holds the lock, A2 simply blocks in `mutex_lock` — harmless | A2 ends silently with the lock held. The supervisor sees A2's exit (a pidfd on both kernels, F39; revision 4 said `waitpid` on 4.19), logs to `/dev/pmsg0`, keeps fan top and caps minimum where writes still work, and then: P15 sysrq `c` (if ruled) or waits for the softdog (`M_final` after the final pet, CPU0, F21). Quest 2 additionally: msm watchdog hardware reset within about 12–21 s (F18), **if** at least one stopped CPU was not core_ctl-isolated (F18 caveat, O21) | softdog, `M_final` after the final pet |

`fs-poweroff-final` is freestanding like `fs-reboot-final`
(`DEADLINE.md` §2 property 3a): (1) `reboot(POWER_OFF)`; (2) only if that
returns an **error** (the lock was never taken, `kernel/reboot.c:311-338`):
`reboot(RESTART)`; (3) `nanosleep` for ever; it never exits. A returned
power-off never comes back to user space (the kernel `do_exit`s the
caller), so (2) runs only on `EPERM`/`EINVAL`. Fixed arguments, checked by
disassembly and a qemu `-strace` fixture (§7.1). `pm_power_off` is set on
both devices (F5), so the kernel's `POWER_OFF` → `HALT` substitution
(`kernel/reboot.c:343-344`; `machine_halt` spins, F4) does not apply [D].

**Where a restart lands** (all [C]): a `fastboot boot` image is gone after
any reset, so the stock boot chain runs. Meta's Android then brings its
own thermal stack, but its boot is heavy load **before** Meta's thermal HAL
is up [C], and ABL's behaviour when hot is [O3]. A **flashed** image
re-enters FrameShift: our initramfs gate (§6.2) must refuse load and power
off, otherwise a hot reboot loop follows (R20). Not `RESTART2
"bootloader"`: fastboot mode's thermal behaviour is [O3].

### 5.3 Graceful shutdown sequence (T4)

| t | Valve userspace | stage image (S1) |
|---|---|---|
| 0 | latch T4; reason to `/dev/pmsg0` and kmsg; **fan → top level; CPU caps → `cpuinfo_min_freq`; GPU `max_pwrlevel` → lowest** (pre-cool); LED pattern; state file; UI notice [O]; pet deadline armed (§5.1) | guard: latch; reason to `/dev/pmsg0`; LED; SIGTERM to the step's process group (no fan or cap writes in S1) |
| 0 | `kill(1, SIGRTMIN+4)`: systemd starts `poweroff.target` [C, systemd(1)]; our drop-ins bound it (§6.2): `DefaultTimeoutStopSec=10s`, `poweroff.target` `JobTimeoutSec=35s`, `JobTimeoutAction=poweroff-force` | — (nothing persistent is mounted) |
| 2 s | — | guard: SIGKILL to the step's group; final softdog pet (if open, `M_final`); `TRIP` written into the heartbeat record |
| ≤ 3 s | — | PID 1's loop reads `TRIP` (≤ 1 s) → `exec fs-poweroff-final` (§6.1). **Last software action.** |
| 35 s | systemd's job timeout: `poweroff-force` (systemd-shutdown as PID 1 calls `reboot(POWER_OFF)`; if it returns, PID 1 panics → restart) | |
| 45 s | still alive → **T5**: A1 `sync()`; wait ≤ 10 s | |
| 55 s | final softdog pet with `M_final` (P17), then A2 `reboot(POWER_OFF)` (A1 finished or not). **Last `reboot()` call; no further pets** | |
| A2 exits | power-off returned (§5.2): P15 sysrq `c` if ruled | |
| 55 s + `M_final` | softdog expiry (Quest 3 `emergency_restart`; Quest 2 panic → restart, msm bite 9 s later if that fails, F18) | (stage: TRIP + `M_final` if the guard opened the softdog) |

During T4, a further rise past the P12 deltas jumps straight to T5. Bounds:
Valve ≤ 55 s to our last `reboot()` call, ≤ 55 s + `M_final` to a kernel
timer restart; stage ≤ 3 s to PID 1's power-off, then a lock-free panic
restart if it returns. systemd's own shutdown normally finishes first; our
timers only matter when it does not. A shutdown we did not start (user,
Valve, any verb) is handled from its detection with the same 35/45/55 s
column (revision 3, §5.1).

### 5.4 Hangs and failures

| failure | detected by | action | landing state |
|---|---|---|---|
| supervisor loop stuck (blocking read, D state) | softdog not petted (running margin 30 s, P17) | Quest 3: `emergency_restart` (dump mode if armed, F6/R11); Quest 2: panic (`soft_panic=1`) → restart | restart; landing per §5.2 [C] |
| supervisor spins | `RLIMIT_RTTIME` hard-limit SIGKILL at 500 ms (the soft limit's SIGXCPU is blocked, F26) | as "crashed" | — |
| supervisor crashed or killed | `fs-thermald-watch` (heartbeat age > 5 s, §5.5) → `systemctl poweroff`; stage: PID 1 heartbeat check (§6.1) | graceful T4 by systemd; softdog still armed (closed without magic close) as backstop | off, or restart |
| supervisor stopped (SIGSTOP from a root process) | the same heartbeat watcher (the record stops advancing); the softdog is held open but not petted | as "crashed"; the softdog fires 30 s after the last pet | off, or restart |
| PID 1 (systemd) hung, supervisor alive, device cool | nothing urgent: thermal control continues without PID 1 | none; user power-key hold | — |
| PID 1 hung **and** T4 needed | T4 budget expiry | T5: A2 does not need PID 1 | off, or timer restart |
| PID 1 hung **and** supervisor dead | the watcher's `systemctl poweroff` needs PID 1, so only the softdog | restart 30 s after the last pet | restart |
| a Valve unit stuck in stop | `DefaultTimeoutStopSec`, then `JobTimeoutSec=35s` → `poweroff-force`, then T5 | — | off |
| a root process calls `reboot()` directly (`systemctl poweroff -ff`, busybox `poweroff -f`, a Valve script) | inside any service: `EPERM`, no `CAP_SYS_BOOT` in the bounding set (F27, §6.2), so it must go through PID 1 and the detectors (§5.1) | — | as a normal shutdown |
| the same, from outside any service (R21 remainder) | none of the three detectors; the supervisor keeps petting | if `device_shutdown()` then hangs, nothing fires until the supervisor's own death | R21 |
| a slow user reboot (or kexec, F30) | detection (§5.1); `JobTimeoutSec=35s` on its target (§6.2) | A1 at + 45 s, final pet + A2 at + 55 s: the reboot becomes a power-off; softdog only after that power-off began (F20), or stopped if a `RESTART` already runs (F7) | off, or restart |
| a RT task above the supervisor's priority hogs CPU0 | prevented: `RestrictRealtime=yes`, no `CAP_SYS_NICE` for RT exceptions, `LimitRTPRIO` ≤ 49 (F25, §6.2); otherwise the softdog's running margin | restart | R11 if it happens |
| storage hung (`sync` blocks) | A1 timeout | skip, A2 power-off unsynced (read-only verity root; only the writable layer is at risk) | off |
| **kernel power-off path hangs** (`device_shutdown`) | **softdog** (it survives `POWER_OFF`, F7), no pet after the deadline (§5.1) | Quest 3 `emergency_restart`, Quest 2 panic → restart; dump mode already cleared (F20) | restart (§5.2 [C]) |
| `pm_power_off` returns | caller PID 1 → panic → restart (F19); caller A2 → lock held, softdog on CPU0 (F21) or P15; Quest 2 also msm watchdog (F18, if a non-isolated CPU was stopped, O21) | — | restart |
| `pm_power_off` hangs with IRQs masked on CPU0 | Quest 2: msm watchdog bite (F18). **Quest 3: nothing** [O4, O5] | hardware only | Quest 3: R12 |
| kernel hang | Quest 2: msm watchdog → panic → Android (F9). **Quest 3: nothing** (F8) | hardware protection only | Quest 3: R12 |
| panic | `PANIC_TIMEOUT=-1` | restart | Quest 2: Android [C]; Quest 3: crash-dump mode if armed **and** no power-off had begun (R11, F20) |

**Heartbeat clock (m4).** The supervisor writes a fixed-size record
`seq boottime_ns state` with `pwrite` each complete cycle; `boottime_ns`
is `clock_gettime(CLOCK_BOOTTIME)`. The watcher compares it with its own
`CLOCK_BOOTTIME`; file mtime is never used. A frozen `seq` for 5 of the
watcher's own 1 s ticks also counts as stale (a clock-independent test).

**Why the supervisor owns the softdog** (and systemd's
`RuntimeWatchdogSec` is off): the softdog is a single-open device; the
component whose death is unsafe is the supervisor, not PID 1 (the
supervisor reaches power-off without PID 1, §5.2). On the Quest 2,
`NOWAYOUT` makes the open irreversible until reboot, and expiry is a panic
(F7); that is acceptable only where the restart landing is acceptable: a
`fastboot boot` image (stock boot chain [C]) or a flashed image with the
initramfs gate (§6.2).

### 5.5 Supervision chain, summarised

`fs-thermald` ← softdog (kernel hrtimer on CPU0, survives `POWER_OFF`) and
← `fs-thermald-watch` (heartbeat on `CLOCK_BOOTTIME`, graceful); load ←
`fs-thermald` (caps, independent of the loads' cooperation); shutdown ←
`fs-thermald` (signal to PID 1, then its own T5: one `reboot(POWER_OFF)`);
kernel power-off path ← softdog (pet deadline) on both devices, plus the
msm watchdog on the Quest 2 once the CPUs are stopped, if one of them was not core_ctl-isolated (F18); kernel ←
nothing on the Quest 3, msm watchdog on the Quest 2. Stage: PID 1 is the
only reboot caller; the guard signals it.

### 5.6 Kernel configuration: what we rely on and what is deferred

- **Relied on:** nothing in the kernel's thermal shutdown (F1–F3). The
  stock kernels stay unchanged (FS-R-001/002). Relied on in the reboot
  path: the facts F4, F7, F18–F21 (stock behaviour, no change).
- **Writes we never make:** trip points; `poweroff_cmd` (useless, F2); any
  PMIC temp-alarm register; `RESTART2` reason strings (F10); `kernel.panic`
  (must stay −1 for F18/F19).

| deferred option | effect | constraint |
|---|---|---|
| K1 `STATIC_USERMODEHELPER_PATH="/sbin/fs-umh"` (a helper that forwards only "poweroff" to `fs-thermald`) | makes `orderly_poweroff` reach us | kernel rebuild: kgate ABI review, FS-R-001/002; only if FrameShift ever ships a kernel |
| K2 Quest 2 `THERMAL_EMERGENCY_POWEROFF_DELAY_MS > 0` | forced unsynced attempt | useless without K3 (F1); rebuild |
| K3 DT critical trips (ArmadaVR's `0002-eureka-critical-thermal.patch` idea) | kernel last resort at Meta's SHUTDOWN values | boot-chain artifact change; on the Quest 3 it races our graceful path (100 ms) unless set above it |
| K4 cmdline `softdog.soft_reboot_cmd=<word>` (Quest 3) | softdog expiry → `kernel_restart` (notifiers run, dump mode cleared) before the emergency restart | boot-image header change: review; no rebuild. **Adds up to 60 s** (`TIMER_MARGIN`, `softdog.c:31,89-110`) when the kernel path is hung, because its `kernel_restart` re-runs `device_shutdown()`; F20 already clears dump mode after a started power-off, so K5 is preferred |
| K5 Quest 3 dump-mode disarm for sustained images (load `qcom-dload-mode` with `download_mode=0` explicitly, or not at all) | normal boot after an unclean reset (R11) | module-parameter / module-set change: Chair (SCM state) |

**Recommendation:** none now. K5 (or K4) is decided before any sustained
Valve-userspace operation on a Quest 3; K1–K3 only if FrameShift ever
builds kernels.

---

## 6. Integration

### 6.1 Stage images

**S0 (today, unchanged).** The protection of every stage image remains the
time bound (DEADLINE, backstop), idle load, the PM's presence and the
after-trial temperature procedure (`devices/quest3/SIGNOFF.md` §F). The
current Quest 3 stage images load no thermal-zone driver (the v66 recovery
module set has none) [M-static], so nothing here applies to them.

**S1 stage thermal guard (`fs-tguard`, designed, not built).** For (a) any
Quest 3 stage hold beyond today's bounds and (b) the first Quest 2 trial:
- **Inputs:** read-only zones. Quest 2: built in, **no new module**.
  Quest 3: `qcom_tsens`, `qcom-vadc-common`, `qcom-spmi-adc5-gen3` from
  v66 vendor_dlkm (T1 of `thermal-control-design.md` §6.7): a new module
  set, so a review item.
- **No Meta file is read in S1 (revision 4):** the guard's values are
  fixed stage bounds far below Meta's LIGHT, not a substitute for Meta's
  thresholds, so S1 gains no vendor read (§4.5.2).
- **Thresholds**, deliberately below Meta's SHUTDOWN because the stage has
  no fan control and no caps beyond idle:
  - **Quest 3:** the idle-hold abort values of T1: any SoC zone ≥ 60 °C,
    board ≥ 40 °C.
  - **Quest 2 (P16):** SoC — `cpu-0-{0..3}-usr`, `cpu-1-{0..7}-usr`,
    `cpuss-{0,1}-usr`, `gpuss-{0,1}-usr` — any ≥ 60 °C; board — `pcb1-usr`,
    `pcb2-usr`, `pcb3-usr`, `xo-therm-adc` — any ≥ 40 °C; battery —
    `power_supply/battery/temp`, `batt-virt` — ≥ 45 °C; skin —
    `vrapi-front-panel` — ≥ 40 °C. Minimum healthy counts (READY and
    class fault): SoC ≥ 1 per CPU cluster and ≥ 1 GPU; board ≥ 1; battery
    ≥ 1; skin optional (its inputs are [O12]). No Quest 2 idle baseline is
    measured yet: Q2-P1 (§7.2) must show idle values well below these
    before the guard is used.
- **Action (revision 2, B1): the guard never calls `reboot()`.** It stops
  the step (SIGTERM to its process group, SIGKILL at + 2 s), gives the
  softdog its final pet (if opened), then writes `TRIP` into its heartbeat
  record. **PID 1 is the only reboot caller:** its loop reads `TRIP` and
  takes a new branch of `fs_reboot_pid1` that `exec`s `fs-poweroff-final`
  (§5.2) instead of `fs-reboot-final`. If the power-off returns, PID 1
  panics and the kernel restarts without the lock (F19). The PM's
  procedure then confirms "off" physically.
- **Loop order (revision 3, review 2 item 6).** In each iteration PID 1
  checks **`TRIP` first**, then the guard-alive check and staleness, then
  DEADLINE, the collected file and the ack window. This changes
  `DEADLINE.md` property 2's "the deadline is checked first"; it is safe
  because `TRIP` only shortens, and the heartbeat read is bounded
  (`read -r -t 1 <>`, property 4), so the deadline check is delayed by at
  most 1 s and the backstop stays the tight bound. Otherwise a guard that
  wrote `TRIP` and then stalled would make PID 1 see "stale" first and take
  `RESTART2 "bootloader"`: that **stops the softdog** (F7) and lands a hot
  device in ABL [O3]. **Declared:** a DEADLINE or backstop reboot that
  wins a race with a trip (the trip lands in the same second, or PID 1 is
  stuck and only the backstop runs) has the same effect; the guard's
  thresholds are far below SHUTDOWN (P16, T1 values), which bounds it.
- **No forking fallback on a trip (revision 3).** `fs_reboot_pid1`'s
  existing guard (`DEADLINE.md` property 3a: exec only a regular,
  executable, non-symlink helper, else the forking `fs_reboot`) is **not**
  used on the `TRIP` branch, because its fallback is `RESTART2
  "bootloader"`. On `TRIP`: if `fs-poweroff-final` fails the type check,
  PID 1 runs `exit 1`; if the `exec` itself fails (ENOEXEC, ENOMEM), ash
  exits with 127 (property 3a, checked under qemu). Either way PID 1 exits
  → "Attempted to kill init!" panic → `emergency_restart`, which takes no
  lock (F19). No power-off has begun, so on the Quest 3 dump mode applies
  if armed (R11): one more reason for the T0 precondition below. The
  READY check also requires the helper to pass the type check (a guard is
  never accepted as READY while its power-off helper is missing).
- **It can only shorten the hold.** PID 1's DEADLINE stays as fixed by
  `pid1-hold.sh`; the guard never extends it, and since it never takes the
  reboot lock it can no longer block PID 1's or the backstop's reboot
  (revision 1 could, review 1 B1). A forged `TRIP` (the host shell is
  root) only powers off earlier: host input only shortens
  (`DEADLINE.md` §2 property 6). A longer hold is permitted only by a
  reviewed image whose guard is READY; if the guard is not READY by
  T0 + 30 s, or its heartbeat is stale, or it is not alive (below), PID 1
  takes its existing reviewed reboot path at once.
- **Guard alive, independent of the record (revision 3, review 2 item 7).**
  The host shell is root and can forge an advancing `READY` record, which
  on a longer-hold image would hide a dead guard (the spirit of
  `DEADLINE.md` property 6: host input must only shorten). So PID 1 also
  reads `/proc/<guard pid>/stat` each iteration with the `read` builtin
  (`read -r -t 1 _p _c _s … _st _r <`; `[ -f ]` first, `O_RDONLY` like the
  clock, property 8). The guard is alive only if field 2 is
  `(fs-tguard)`, the state (field 3) is `R`, `S` or `D`, and the start
  time (field 22) equals the value PID 1 recorded when it first accepted
  READY (F28). A missing or unreadable file, `Z`, `X`, `T`, `t`, another
  comm or another start time (a reused PID) → dead → the reviewed reboot
  path. A `D`-state hang is left to staleness and to the softdog.
- **Heartbeat in PID 1, fork-free (m4).** The record is one line
  `seq boottime_s state` (`state` ∈ `READY`, `TRIP`), `boottime_s` from
  `CLOCK_BOOTTIME`. PID 1 reads it with `read -r -t 1 <>` under
  `DEADLINE.md` property 4 rules, and its clock with the `read` builtin on
  `/proc/uptime` (also `CLOCK_BOOTTIME`, F23). Stale = integer uptime −
  `boottime_s` > 5, **or** `seq` unchanged for 6 loop iterations (the
  file-independent clock of property 9, because `/proc/uptime` can lie,
  property 2). Builtins and shell arithmetic only.
- **Fork-free and FIFO-safe** in PID 1 (`DEADLINE.md` §2 properties 4–5);
  the guard is a separate static binary started once, like `fs-idle`.
  The `pid1-hold.sh` change (`TRIP` branch first in the loop, the
  guard-alive check, the no-fallback exit, second helper) is a change to a
  reviewed file and reruns its harness and review.
- **softdog in S1** (recommended; Chair, §7.3): opened by the guard, CPU0,
  running margin 30 s, final pet at `TRIP`. It covers a guard hang and a
  hung kernel power-off path. Without it, a `device_shutdown()` hang after
  `TRIP` is uncovered on both devices (R13). It is stopped by every normal
  stage `RESTART`/`RESTART2` (F7), so the existing reboot paths are
  unaffected. **Precondition on the Quest 3 (revision 3, review 2 item
  8):** a guard hang ends in the softdog's `emergency_restart` **before**
  any power-off began, i.e. in crash-dump mode if dump mode is armed
  (F6, R11). The softdog is opened in S1 on a Quest 3 only after the T0
  read of `/sys/module/qcom_dload_mode/parameters/download_mode` has
  returned `0` for that image's module set (§7.2); otherwise the guard
  runs without it. On the Quest 2 `download_mode` is 0 after a panic
  restart (F9).
- **No fan writes, no cap writes** in S1: those are T2/T3a write classes.

### 6.2 Valve userspace (later)

| piece | where | content |
|---|---|---|
| thermal modules, early caps, `fs-thermald` start | **our initramfs**, before any load | Quest 3 module list `thermal-control-design.md` §1.4 (ADSP for the battery class); Quest 2 built in; governor/caps first (that doc's §4.1 `fs-cpufreq-safe` becomes the supervisor's init step) |
| **`fs-metacfg`** (revision 4) | our initramfs, before `fs-thermald`'s self-test and the gate | reads Meta's `thermal_info_config.json`, the VR-runtime list and `build.prop` read-only from the active slot's `vendor` in `super` (§4.5.2, option B); spawned by `fs-thermald` before its RT elevation and pinning, under rlimits and seccomp; `fs-thermald` waits at most 2 s with `ppoll` (never a blocking `waitpid`), then kills it, closes the pipe and continues with the fallback even if the helper is stuck in `D` state (revision 5, M2); its framed record goes to `fs-thermald`, which hashes it itself and accepts it or uses the fallback (§4.5.3). New read-only action class (§7.3) |
| **initramfs thermal gate** (revision 2, M3) | our initramfs, before `switch_root` | `fs-thermald` reads **every temperature class** (and battery capacity). **Pass rule (revision 3, review 2 item 5):** every class **below its SEVERE threshold − Meta's hysteresis**, taken from the **active** set (runtime values if accepted, else the fallback, §4.5; revision 4) (T3's exit rule; Quest 2 battery: below 58 − 3 = 55 °C), no sensor or class fault, self-test passed; and if pstore holds a T4/T5 marker written by the previous boot, every class **below LIGHT**. A gate at "≥ WARN" alone would let a device shut down at Quest 2 battery SHUTDOWN 59 °C reboot at 57.9 °C and loop between 58 and 59 °C. pstore is RAM-backed (F29): the marker survives a timer or panic restart, not a real power-off, so after a power-off only the SEVERE − hysteresis rule applies [D]. Fail → **no `switch_root`, no load**: fan top where present, minimum caps, the supervisor's **final softdog pet** (`M_final`) and then the init (PID 1) `exec`s `fs-poweroff-final` at once (bound: gate decision + ≤ 1 s + `M_final`, revision 3 nit). Low battery alone (P13, ≤ 10 %) only warns; P6 (≤ 3 %) powers off. The fan class is checked later, before `fs-thermald-ready.target` (Quest 2 has no fan driver before a DRM panel, §4.3). O19 (limit on consecutive hot boots, marker format) is settled **before any flashed image** |
| `fs-thermald-watch.service` | our layer | `DefaultDependencies=no`, `Before=sysinit.target`, `Restart=always`; heartbeat (§5.4, `CLOCK_BOOTTIME` record) stale > 5 s → `systemctl poweroff` |
| `fs-thermald-shutdown.service` | our layer | `DefaultDependencies=no`, **`Conflicts=shutdown.target`, `Before=shutdown.target`** and no other ordering (revision 3, review 2 item 1: without the conflict a `DefaultDependencies=no` unit is never stopped and its `ExecStop=` never runs [C]); `Type=oneshot`, `RemainAfterExit=yes`, `IgnoreOnIsolate=yes` (an isolate is not a shutdown), `RefuseManualStop=yes`; started at boot; `ExecStop=` writes `SHUTDOWN` to the supervisor's control pipe: starts the pet deadline and the + 45/55 s actuators (§5.1) on any shutdown. QEMU test per verb (§7.1) |
| `system.conf.d/50-frameshift.conf` | our layer | `RuntimeWatchdogSec=off` (the supervisor owns the softdog), **`RebootWatchdogSec=off`, `KExecWatchdogSec=off`** (systemd-shutdown must not open or re-arm the softdog, O7), `DefaultTimeoutStopSec=10s`, `DefaultLimitRTPRIO=49` (below the supervisor's 60 and the IRQ threads' 50). It does **not** bind a holder of `CAP_SYS_NICE` (F25, [M-static]); the binding controls are in `service.d/50-frameshift-caps.conf` below |
| `poweroff.target.d/50-frameshift.conf` | our layer | `JobTimeoutSec=35s`, `JobTimeoutAction=poweroff-force` (staggered 10 s before T5 at 45 s) |
| `reboot.target.d/`, `kexec.target.d/50-frameshift.conf` (revision 3, review 2 item 3) | our layer | `JobTimeoutSec=35s` (upstream default 30 min [C]), each keeping its own force action (`reboot-force`; kexec has no kernel support, F30, and falls back to a reboot [C]). The supervisor's + 45/55 s actuators then turn any still-running shutdown into our power-off (§5.1) |
| masks (revision 3) | our layer | **`soft-reboot.target`, `systemd-soft-reboot.service`**: a soft reboot sends the shutdown signal but never reaches the kernel, so the pet deadline would let the softdog fire on a running system [C, systemd ≥ 254]. **`halt.target`, `systemd-halt.service`**: `reboot(HALT)` notifies `SYS_HALT`, which stops the softdog (F7), and `machine_halt` spins with the device on (F4) |
| `service.d/50-frameshift-caps.conf` (revision 3, review 2 items 2 and 4) | our layer, top-level drop-in for **every** service (transient ones included [C]) | `CapabilityBoundingSet=~CAP_SYS_BOOT` (no service can call `reboot()`, F27: every shutdown goes through PID 1 and the detectors); `RestrictRealtime=yes` (no service can take an RT policy, whatever its capabilities, F25). **Exceptions**, each named and reviewed: a unit that needs RT (for example the gamescope session [O18]) gets `RestrictRealtime=no` plus `CapabilityBoundingSet=~CAP_SYS_NICE` and `LimitRTPRIO=` ≤ 49, so `RLIMIT_RTPRIO` binds it; an RT broker that must keep `CAP_SYS_NICE` (rtkit) is limited by its own `--max-realtime-priority` ≤ 49 [C]. Our own units set their own sets explicitly. Whether a later Valve drop-in can widen these is checked in QEMU (O7) |
| `logind.conf.d` + masks | our layer | P10: sleep targets masked, suspend keys ignored; power key → poweroff |
| `service.d/50-frameshift-ro.conf` | our layer | `ReadOnlyPaths=` for the owned sysfs nodes (§2) |
| load-producing units (gamescope session, Steam) | drop-ins | `Requires=`/`After=fs-thermald-ready.target` (reached when the supervisor reports READY through its state file, fan class included) |
| masked + stubbed | — | `deckard-fan-control`, `deckard-power-monitor`, `deckard-charger`, `deckard-led-control`, the post-update shutdown hooks (`holo-post-update-shutdown`, `steamos-post-update`) and every Frame-hardware unit of `valve-image-slot-in.md` §2.3 |
| exported state | `/run/fs-thermald/state` | level, reason, temperatures; a future UI shim (Steam notification, battery percent interface) reads it [O11] |

**Never:** Valve's fan control, Valve's charger/NVM writer, any Valve
shutdown or firmware hook, Valve scripts on the shutdown path.

### 6.3 User-visible warning

Stage images: LED pattern (an existing write class) and the host console.
Valve userspace: LED (bystanders), state file, and a UI notice whose route
into Steam is [O11]; display dimming is a further mitigation Meta may use
[O] and a new write class.

---

## 7. Testing and evidence

### 7.1 Offline

- **Decision core:** C vs Python reference on shared fixtures
  (differential); properties: a fault never lowers a level; T4 latches;
  hysteresis and dwell; every threshold at ±0.1 °C; T2 is MODERATE only;
  hot anomalies (§3.3): confirmed, contradicted within 2 cycles, and
  single-sensor classes (> 125 °C or at SEVERE → T4; a rise anomaly below
  SEVERE → P9 fault, revision 3); the fallback values asserted equal to
  the values parsed from the known files (`e49b49fe…`, `c9301ff5…`,
  `cc3e5137…`; local-only test, §4.5.7) and to the DT lines; **revision
  4:** the same decisions with the runtime set and with the fallback on
  the known files; the order invariant of §4.5.4 as a property.
- **Meta configuration reader (revision 4, §4.5).** `fs-metacfg` in C
  against a Python reference reader (differential), on **synthetic**
  fixtures that we write: `super` images from our own LP writer (written
  independently of the reader) holding ext4 images built with
  `mke2fs -d` from fixture trees, with JSON in Meta's schema and invented
  values. Fault injection, each → fallback with the right reason code and
  never a crash: bad LP magic or checksum, an extent outside `super`, no
  partition for the slot, a wrong device in `build.prop`, a journal or an
  unknown incompat feature, the file missing, oversized, a symlink or
  truncated, duplicate keys, an unknown key, a 6- or 8-slot array, `NAN`
  in a required slot, non-increasing slots, a value out of bounds, a
  release point below 20 °C, a multiplier mismatch, a required sensor
  missing, an unmapped sensor with a set slot, an unknown hash, a known
  hash with a wrong parse digest, and a reader that hangs (killed at 2 s).
  **Revision 5 additions:** a `-cow` partition in the slot's metadata
  (`vab-merge`); a vendor incremental that differs from the matched row;
  a VR-runtime list with a wrong hash (thresholds accepted, list not
  exported); `VrThreshold` other than `"NAN"`; a set sensor without
  `Monitor: true`; CRITICAL or EMERGENCY set; a `SKIN`-typed SoC sensor
  at 115 °C (accepted, SoC class); each LP limit of §4.5.2 broken once
  (primary geometry checksum with a valid backup → still fallback; minor
  3; header size 200; a short `entry_size`; tables beyond `tables_size`;
  4 slots; two block devices; a block-device size ≠ the device;
  `target_source` 1; an extent end that overflows 64 bits; an
  unterminated 36-byte name; a `DISABLED` vendor partition); each ext4
  check of §4.5.2 broken once (log block size 3, `64bit` or
  `metadata_csum` set, inode 0 or beyond `s_inodes_count`, bad extent
  magic, `eh_entries` > `eh_max`, an uninitialised extent, a hole, a
  block beyond `s_blocks_count` or beyond the partition, `i_size_high`
  set, inline data, `rec_len` 8, unaligned or past the block, `name_len`
  too long, a directory over the cap); an EROFS image (`fs-type`); a
  `super` that appears 1.5 s late (uevent path, accepted) and one that
  never appears (`no-super`); a record over a length cap, a count of 129
  and a short record; **a helper stuck in `D` state** (qemu: an `nbd`
  device whose server stops answering) → the parent continues with the
  fallback at 2 s, the child is reaped later, and the boot is not
  delayed; a helper that spins (killed by `RLIMIT_CPU`); a helper that
  calls a forbidden syscall (killed by seccomp). The parent's priority,
  affinity and signal mask are asserted **not** inherited by the helper.
  The JSON, LP and ext4 walkers are fuzzed. The syscalls are checked
  under qemu `-strace`: before the filter only the set listed in §4.5.2;
  after it only `pread64` on `super`, the pipe write, `close`, `fstat`,
  `brk`, non-executable `mmap`/`munmap`, `ioctl(BLKGETSIZE64)`,
  `clock_gettime`, `rt_sigreturn` and `exit_group`. **Local-only differential** (skipped
  when the extracts are absent; nothing written to the repo): the C reader,
  the Python reader and `debugfs cat` agree on the three real images
  (F31), the hashes and parse digests equal the table, and the parsed
  thresholds equal §4.1.
- **Fixture sysfs trees** for Quest 3 v66 and v2.7 drivers and the Quest 2
  4.19 built-in stack (user_space zones, FG gen4 battery, fan absent until a
  panel), with fault injection: missing, EIO, frozen, jumping and
  out-of-range sensors (low and high separately); ADSP down; a **blocking
  read** (a FIFO standing in for a sysfs node) to prove the softdog stops
  being petted; write failures; fan F1–F7.
- **Actuator and PID 1 safety (revision 2, B1):** the deadline-harness
  approach (only the syscall faked), with a fake `reboot` that **models the
  kernel**: a `POWER_OFF` that "returns" leaves a transition lock held, so
  every later fake `reboot` call blocks for ever; it stops every
  harness process not pinned to CPU0; issued by the simulated PID 1 it ends
  in a simulated panic → restart; on the Quest 2 profile it returns only
  after 10 s. Assertions: in S1 only PID 1 ever calls `reboot`; in Valve no
  component of ours calls `reboot` after A2; the supervisor's last softdog
  pet precedes A2 and none follows; after A2's exit only P15's sysrq write
  (if enabled) or the softdog acts; the pet deadline also ends petting on a
  `SHUTDOWN` byte and on a `systemd-shutdow` comm; actuators exit without
  acting on EOF; A1/A2 hold no `/dev/watchdog` descriptor and never call
  `execve` (revision 3); on any detected shutdown (each verb) A1 runs at
  + 45 s and the final pet + A2 at + 55 s. qemu `-strace` fixture for `fs-poweroff-final`: exactly
  `reboot(POWER_OFF)`, then (error injected only) `reboot(RESTART)`, then a
  `nanosleep` loop; no exit; no `RESTART2` string; static check that no
  trip-point or `poweroff_cmd` path is in the binary.
- **systemd and kernel integration in QEMU** (aarch64, systemd 257.7,
  generic kernel with softdog): `@` survival across busybox `switch_root`
  and the final killing spree (O7); `SIGRTMIN+4` → `poweroff.target` (O14);
  `RebootWatchdogSec=off` leaves `/dev/watchdog` alone in systemd-shutdown
  (O7); a Valve-like unit with a hung `ExecStop` → 35 s / 45 s budgets
  hold; `fs-thermald` killed or SIGSTOPped → watch unit powers off within
  5 s; softdog expiry; `RLIMIT_RTTIME` kill at the hard limit with SIGXCPU
  blocked (F26); **revision 3:** `fs-thermald-shutdown.service`'s
  `ExecStop=` runs on `poweroff`, `reboot` and `kexec` and not on an
  isolate; `systemctl poweroff -f` and a `JobTimeoutAction=` force (no unit
  is stopped) are caught by the `systemd-shutdow` comm detector;
  `systemctl poweroff -ff` and busybox `poweroff -f` from a service fail
  with `EPERM` (bounding set), including from a transient `systemd-run`
  unit and after a Valve-style unit drop-in; `systemctl soft-reboot` and
  `systemctl halt` refused (masked); a reboot with a hung `ExecStop` →
  35 s job timeout, then our A2 power-off at + 55 s; a service with the
  default capability set cannot take `SCHED_FIFO` (`RestrictRealtime`),
  and an exception unit cannot exceed 49; A1/A2 keep `@` and survive the
  final killing spree (O7); **a test module whose
  `.shutdown` callback sleeps longer than `M_final` → the softdog fires
  during `reboot(POWER_OFF)`** (M1); a `pm_power_off` stub that returns →
  only CPU0 runs, the pinned softdog fires, a second `reboot()` blocks.
- **Stage guard (S1):** the `fixtures-deadline.sh` harness extended: the
  guard trips → `TRIP` → PID 1 execs `fs-poweroff-final`; guard never
  READY → PID 1's reboot; stale heartbeat by uptime and by loop count;
  forged `TRIP` only shortens; FIFO in place of the heartbeat file; fork
  count unchanged in the loop. **Revision 3:** `TRIP` written and the guard
  then stalled (stale record) → power-off, not `RESTART2`; `TRIP` and
  DEADLINE in the same iteration → power-off; `fs-poweroff-final` missing,
  a symlink or not executable at `TRIP` → PID 1 exits (simulated panic →
  restart), never `fs_reboot`; an `exec` that fails (ENOEXEC) → ash exits
  127 → the same; a forged advancing `READY` record with the guard killed,
  stopped (`T`), a zombie, or its PID reused by another comm or start time
  → PID 1's reviewed reboot path; a helper missing at READY time → READY
  refused.
- **Initramfs gate:** fixture trees hot at boot (each class), self-test
  failure, 9 % battery (boots, warns) and 3 % (powers off). **Revision 3:**
  each class just below SEVERE but above SEVERE − hysteresis (Quest 2
  battery 56 °C) → powers off; below SEVERE − hysteresis → boots; a pstore
  T4 marker present and a class between LIGHT and SEVERE − hysteresis →
  powers off; the final softdog pet precedes the `exec` and none follows.

### 7.2 Evidence before any device use

1. All suites above pass; adversarial review GO.
2. Read-only baselines: Quest 3 T0 (`thermal-control-design.md` §7.3 Phase 1,
   plus `cat /sys/module/qcom_dload_mode/parameters/download_mode`; a
   reading of `0` for the image's module set is a **precondition** for
   opening the softdog in S1 on a Quest 3, revision 3); Quest 2
   Q2-P1 extended with zones, cooling devices, hwmon and battery reads (its
   idle values set or confirm P16).
3. Attended trials T1–T5 in that doc's order; **T5 measures** the T4 wall
   time, the **kernel power-off time** (from the `reboot(POWER_OFF)` call
   to power loss; sets `M_final`, P17) and the landing state (off,
   off-mode charging, Android). A failed power-off is not provoked on a
   device; its handling is proven offline (§7.1).
4. After every T5: the PMIC power-off/reset reason read-only
   (`PROJECT_SETUP` §6A item 8b) to separate our power-off from a PMIC,
   thermal or watchdog event.
5. **No Quest 2 hold beyond a short bound and no sustained Valve operation
   on any device before T5 passes on that device** (R10 of that doc).
6. **Meta configuration (revisions 4 and 5), read-only probes for the
   PM's approval, not run.** They extend T0 (Quest 3, Android) and Q2-P1
   (Quest 2). **Already measured on Unit 2** by the J-115 baseline, so not
   repeated there: `ro.vendor.build.version.incremental`,
   `ro.boot.slot_suffix`, `/proc/cmdline`, the by-name link of `super`,
   and `ro.virtual_ab.enabled`/`retrofit` (F37, F38, F40).
   - `adb shell sha256sum /vendor/etc/thermal_info_config.json /vendor/etc/vr_runtime_power_mitigation.json`
     (the unit's own files equal a known row; on Unit 2, row `c9301ff5…`
     is expected);
   - `adb shell getprop ro.vendor.build.version.incremental` (Unit 1,
     Quest 2);
   - `adb shell getprop vendor.thermal.config` (O24: expected empty; all
     units);
   - `adb shell getprop ro.boot.slot_suffix` and `adb shell cat /proc/cmdline`
     (Unit 1, Quest 2; F37);
   - **Virtual A/B (revision 5, M1; O27):** `adb shell getprop ro.virtual_ab.enabled`,
     `adb shell getprop ro.virtual_ab.retrofit` and
     `adb shell getprop ro.virtual_ab.compression.enabled` (Unit 1,
     Quest 2); the snapshot state: [removed for publication];
   - [removed for publication]
   None of these writes anything.

### 7.3 New action or write classes (Chair before use)

| class | where | note |
|---|---|---|
| `reboot(POWER_OFF)` from our images | S1 (PID 1 only), initramfs gate (PID 1), Valve (A2 at T5 and at + 55 s after any detected shutdown) | new syscall path (today only `RESTART2 "bootloader"`/`RESTART`); new freestanding helper `fs-poweroff-final`; `pid1-hold.sh` change (§6.1: `TRIP` first, guard-alive check via `/proc/<pid>/stat`, PID 1 exit instead of a forking fallback on a trip) |
| Quest 3 tsens/ADC module load in a stage image | S1 | probe programs TSENS/ADC thresholds (volatile) [D] |
| opening the softdog | Valve; S1 (recommended, §6.1) | Quest 2: irreversible until reboot (`NOWAYOUT`), expiry = panic; Quest 3 S1: only after T0 reads `download_mode` = 0 (revision 3) |
| `sync()` of the writable layer (A1) | Valve | bounded 10 s; skipped if it blocks |
| `/dev/pmsg0` writes (pstore) | S1, Valve, initramfs | reasons before shutdown; FS-R-007 §5 Ask 4 rule (`thermal-control-design.md` §6.6) |
| sysrq `c` write (deliberate panic), P15 | Valve, only after A2's exit | lock-free restart; dump mode already cleared (F20) |
| fan hwmon writes; cpufreq/kgsl cap writes | T3a; T2 | already listed in `thermal-control-design.md` §6.7 |
| ADSP start (battery class, Quest 3) | Valve; trials | `thermal-control-design.md` §6.7 **T3b** |
| cmdline changes (K4), dump-mode module parameter (K5) | Valve, Quest 3 | K5 changes secure-world dump state |
| systemd hardening (revision 3): `CapabilityBoundingSet=~CAP_SYS_BOOT`, `RestrictRealtime=yes` / `~CAP_SYS_NICE` + `LimitRTPRIO` ≤ 49 for every service; `JobTimeoutSec=35s` on every shutdown target; masks of `soft-reboot.target`, `systemd-soft-reboot.service`, `halt.target`, `systemd-halt.service` | Valve layer | no device write by itself; changes what Valve's units may do (direct reboot, RT), so it is reviewed with the Valve integration; exceptions listed by name |
| pstore read in the initramfs gate | flashed images | read-only; entries are never deleted by the gate (O19) |
| **read of Meta's `vendor` partition** (revision 4, §4.5.2) | initramfs of Valve-userspace images (not stage images) | **new action class, read-only.** Option B (approved by the PM, J-122): `O_RDONLY` open of `super`, located by `PARTNAME` and size (a uevent socket while waiting for it, revision 5); `pread` and one size ioctl (`BLKGETSIZE64`) only, under seccomp; a helper bounded to 2 s that never delays the boot; no mount, no dm device, no write. Option A: as B for the LP read, plus a transient read-only dm-linear device and an `ro,noload` ext4 mount, both removed afterwards (volatile kernel state). Neither writes storage or touches a boot-chain partition |
| `RESTART2 "shutdown,thermal"` | — | **not proposed**: PON/SDAM persistent write (F10) |
| PMIC temp-alarm load (Quest 3 option B), backlight dimming | — | existing rules |

---

## 8. Per-device summary

| item | Quest 3 (v66 Unit 1; v2.7) | Quest 2 (v2.7) | Quest Pro | Quest 3S |
|---|---|---|---|---|
| kernel critical path | only with temp-alarm loaded; 100 ms emergency **attempt** (F3) | **none**: no critical trips (F1); delay 0 | as Quest 2 (delay 0, `kgateqpro/stock.config:2546`); its DT [O] | as Quest 3 (`kgateq3s/stock.config:3215`) |
| helper path | empty static path (F2) | same | same | same |
| SoC watchdog | **none** (no DT node, F8) | msm watchdog, kernel-petted; not stopped by power-off; stops being petted once the CPUs are stopped → reset (F18) | built in (`:4438`); DT [O] | drivers `=m`; DT [O] |
| softdog | `emergency_restart`; not `NOWAYOUT`; survives `POWER_OFF`, stopped by `RESTART` (F7) | `soft_panic=1`, `NOWAYOUT`; same reboot behaviour (F7) | `NOWAYOUT` (`:2597`); cmdline [O] | as Quest 3 |
| failed power-off | PID 1 caller: panic → restart; A2: softdog on CPU0 / P15 | as Quest 3, plus msm watchdog (F18); returns only after 10 s | [O] (4.19, presumably as Quest 2) | [O] |
| unclean reset lands in | crash-dump mode if armed and no power-off had begun (F6, F20, R11) | Android (`download_mode` 0) [C] | [O] | [O] |
| power-off provider | PSCI `SYSTEM_OFF` | `do_msm_poweroff` | `POWER_RESET_QCOM` (`:2346`) | as Quest 3 |
| battery path | ADSP (staleness class) | in-kernel SMB5 + FG gen4 | SMB5 + FG gen4 (`:2392,2403`) | [O] |
| fan in a headless stage | driver loads; not commanded | absent until a DRM panel | 2 fans; same probe rule | own levels (`thermal-control-design.md` §8) |
| thresholds | §4.1 | §4.1 (F12); S1: P16 | [O] | [O] |
| Meta config at runtime (revision 4) | `vendor_<slot>` in `super` (8 GiB); known rows v66 `e49b49fe…` (Unit 1), v2.7 `c9301ff5…` (Unit 2 expected, F40); v71/v72/v76/v84 → fallback (P18); Virtual A/B merge pending → fallback (F38) | `vendor_<slot>` in `super` (6 GiB); known row v2.7 `cc3e5137…`; Virtual A/B enabled (F38) | no row, **no fallback** → no READY (§4.5.3) | no row, **no fallback** → no READY |

Lockstep rule: the Quest Pro follows the Quest 2's **mechanism** (4.19,
delay 0, `NOWAYOUT`) and the Quest 3S the Quest 3's, but each copies **its
own** thresholds, fans and sensors (§6A.3); nothing is inherited.

---

## 9. Open questions and risks

### 9.1 Open [O]

1. XBL behaviour after an unclean reset with dump mode armed (Quest 3):
   crash-dump entry, `emmc_dload=1` minidump write; whether our stage
   images arm it at all (F6 nuance).
2. Off-mode charging after a power-off with a charger attached: what boots,
   with which thermal stack, per device.
3. Fastboot-mode (ABL) thermal behaviour if a reboot lands there hot; how
   much load Meta's Android boot puts on a hot device before its thermal
   HAL runs [C].
4. Whether PSCI `SYSTEM_OFF` can return or hang on the Quest 3; PS_HOLD
   set-up. A hang with IRQs masked on CPU0 is uncovered there.
5. A firmware or hypervisor watchdog on the Quest 3 (F8); dtbo overlays.
6. Fan duty after the kernel stops or while `device_shutdown` hangs.
7. systemd 257.7: the `@` convention after a busybox `switch_root`;
   `SurviveFinalKillSignal=` as the alternative (F17); whether
   systemd-shutdown with `RebootWatchdogSec=off` neither opens nor
   magic-closes `/dev/watchdog` (a magic close after the supervisor's death
   would disarm the Quest 3 softdog).
8. Meta's low-battery level and any voltage cut-off (both devices).
9. Vendor notify paths (`tz->ops->notify`) per sensor driver (FS-R-011 §6).
10. PMIC stage-2/3 thresholds per instance (Quest 3 path per instance;
    Quest 2 GEN1 vs GEN2, F14) and any tsens hardware reset monitor.
11. The route for a user-visible notice into Steam's UI.
12. Quest 2 `vrapi-front-panel` inputs and fault behaviour; whether a panel
    registers in a headless boot.
13. Quest Pro and Quest 3S thermal JSONs, DTs and cmdlines.
14. `SIGRTMIN+4` handling in Valve's systemd 257.7 (documented [C]).
15. Load shedding by cgroup v2 freeze (5.10 has it; 4.19 does not): not
    used.
16. Kernel power-off time per device (T5 measurement) → `M_final` (P17).
17. Quest 2: whether the msm watchdog's bite still resets the SoC after
    `do_msm_poweroff` has disabled SDI and halted the SPMI arbiter (F18
    relies on it) [C].
18. **Retagged (revision 3).** That `CAP_SYS_NICE` bypasses
    `RLIMIT_RTPRIO` is now [M-static] (F25), and `RestrictRealtime=yes`
    plus the exception rule (§6.2) closes it. Open: which Valve units
    need RT (gamescope's realtime threads, audio via rtkit) and at what
    priority, so the exception list can be written [O].
19. A flashed image's limit on consecutive hot boots and the pstore marker
    format read by the initramfs gate (R20). The marker survives only
    warm restarts (F29). **Must be settled before any flashed image**
    (revision 3).
20. Which sensors count as **independent siblings** per class (§3.3);
    virtual sensors share inputs.
21. **(new, revision 3)** Quest 2: whether core_ctl leaves at least one
    stopped CPU un-isolated at power-off (F18 caveat); with every other CPU
    isolated, the msm watchdog keeps being petted after a returned or hung
    `pm_power_off`, and only the softdog covers. A read-only
    `/sys/devices/system/cpu/cpu*/core_ctl/` and isolation read during
    Q2-P1 would show the idle state [C].
22. **(new, revision 4)** The LP-metadata layout of `super` on each device
    (geometry, metadata slots, extent types), parsed by `fs-metacfg` from
    AOSP's public `liblp` format [C]; no raw `super` image is held locally
    (F35). Settled by the read-only `lpdump` probe (§7.2) and the synthetic
    fixtures (§7.1). **Extended in revision 5:** the header version and
    flags (`LP_HEADER_FLAG_VIRTUAL_AB_DEVICE`), any `-cow` partitions and
    the `cow` group, the `UPDATED` attribute on the active slot's
    partitions, and whether the backup metadata ever differs from the
    primary. [removed for publication].
23. Meaning of the VR-runtime mitigation tokens (`T1`–`T3`, `B1`, `M1`) and
    names, and which compositor controls they map to (F36); needed before
    any actuator is attached to them (with O11).
24. Whether any system-partition property or init script sets
    `vendor.thermal.config` (F32); the reader assumes the default name
    until the §7.2 probe shows the property empty.
25. Purpose of `VrThreshold` in Meta's JSON (F33): its value must be the
    scalar `"NAN"` (revision 5, §4.5.3 step 4); any other value falls
    back until its meaning is known.
26. Verifying the vendor file through Meta's vbmeta hashtree (dm-verity
    root hash) instead of, or in addition to, our hash table (§4.5.2); it
    would make P18 option (b) safer to consider. **Revision 5:** it would
    also detect a stale raw read during a Virtual A/B merge (R25), since
    the old blocks would not match the new root hash [D].
27. **(new, revision 5)** Virtual A/B on each unit (F38): where the COW
    data of an update lives (`-cow` partitions in `super` or images on
    `userdata`), how long the merge takes after the first Android boot,
    and whether the LP header flag or the `UPDATED` attribute
    (logged only, §4.5.2) reliably marks a pending merge. The probes: [removed for publication]. Reading the merge state on the `metadata` partition from
    our initramfs would be a further read-only action class, **not
    proposed**.
28. **(new, revision 5) PM question pending (the Arbiter asks the PM):**
    whether naming Meta's interface identifiers (JSON keys, sensor names,
    mitigation token names) in the public version of this document is
    allowed. Until answered, the document keeps them and the public-scope
    pass holds them.
29. **(new, revision 5)** Quest 2: what Meta's userspace does with the
    `user_space`-governed DT zones (which zones, which cooling devices,
    at which temperatures) (§4.5.4 layer 2a). Until known, that layer is
    unmapped; our tiers cover the sensors through the JSON severities.

### 9.2 Risks

- **R11 (high, Quest 3):** an unclean reset (softdog, thermal
  `emergency_restart`, panic) **before any power-off began** may land in
  crash-dump mode, powered without OS thermal control, possibly writing a
  minidump to flash (F6; after a started power-off dump mode is cleared,
  F20) → K5/K4 decision before sustained operation; the supervisor never
  panics on purpose except P15, which runs only after a started power-off.
- **R12 (high, Quest 3):** no kernel-hang watchdog (F8) → a hard kernel
  hang, or a `pm_power_off` hang with IRQs masked, while hot relies on
  PMIC/LMh hardware and the PM; sustained unattended use needs [O4, O5]
  answered.
- **R13 (revised):** a hang inside `device_shutdown()` is covered by the
  softdog on both devices (it survives `POWER_OFF`, F7) **only if** the
  softdog is open and its petting has ended (pet deadline, §5.1); in a
  stage image without the S1 softdog it is uncovered → pre-cooling before
  the call, S1 softdog recommended. A hang during a normal `RESTART` stays
  uncovered (the softdog is stopped there).
- **R14 (revised):** a returned `reboot(POWER_OFF)` leaves the reboot lock
  held and only CPU0 running (F4) → no userspace fallback by design; PID 1
  as the caller where possible (F19); otherwise CPU0-pinned softdog, msm
  watchdog (Quest 2, only if a stopped CPU was not core_ctl-isolated, F18
  caveat, O21), P15.
- **R15 (Quest 2):** opening the softdog is irreversible and its expiry is
  a panic (F7) → open it only in images whose restart landing is
  acceptable (§5.4), and only with the Chair's concurrence.
- **R16 (high, Quest 2):** with no critical trips (F1) and no forced path,
  `fs-thermald` is the **only** software shutdown → differential testing,
  T5 on that device before any longer hold.
- **R17:** off-mode charging may resume heating after a thermal power-off
  [C] → P14 notice; the PM's procedure (power off, confirm, unplug).
- **R18:** Valve units or scripts write owned nodes or block shutdown →
  `ReadOnlyPaths`, stubs, budgets (§2, §6.2).
- **R19:** a supervisor bug or a hot-side sensor glitch (§3.3) causes
  spurious shutdowns: availability, not safety; every reason is logged to
  pstore.
- **R20 (new, flashed images):** a timer restart of a still-hot flashed
  image re-enters FrameShift → hot reboot loop; each boot is short and
  idle, but the loop is unbounded → initramfs gate (§6.2), O19. Revision
  3: the gate passes only below SEVERE − hysteresis (below LIGHT after a
  pstore T4/T5 marker), so a device cannot oscillate just under SEVERE.
- **R21 (revised in revision 3):** a missed "shutdown under way" signal
  lets the supervisor keep petting through a hung `device_shutdown()` →
  three independent detectors (§5.1, the `fs-thermald-shutdown.service`
  one now actually stopped, §6.2), no `CAP_SYS_BOOT` in any service's
  bounding set, so a direct `reboot()` from a service fails (F27), and the
  QEMU tests (§7.1). **Declared remainder:** a root process **outside any
  service** that calls `reboot()` directly is still unseen (processes
  started before systemd from our initramfs, which are ours; a unit whose
  own drop-in re-adds `CAP_SYS_BOOT`, ruled out by review of the exception
  list and the QEMU check; an interactive root shell reached through a
  unit that keeps the capability). Its consequence is the R13 class: a
  `device_shutdown()` hang that only the supervisor's death would end.
- **R22 (new, revision 3):** shutdown verbs other than power-off. A slow
  reboot or kexec could outlast the pet deadline, and a soft reboot sends
  the shutdown signal without ever reaching the kernel, so the softdog
  could fire on a running system or before any power-off began (crash-dump
  on a Quest 3 if armed, R11) → `JobTimeoutSec=35s` on every shutdown
  target, soft-reboot and halt masked (§6.2), and on any detected shutdown
  our own A1/A2 at + 45/55 s (§5.1), so the softdog fires only after a
  power-off began (F20). **Declared remainder:** a user reboot slower than
  55 s becomes a power-off (availability); a `device_shutdown()` hang
  during a **reboot** stays uncovered, because `SYS_RESTART` stops the
  softdog before `device_shutdown()` and A2 then blocks on the lock (R13);
  a soft reboot or halt requested from outside any service (R21 remainder)
  [C].

- **R23 (new, revision 4):** a reader or parser defect, or an altered
  file, could feed wrong thresholds → known-firmware hash **and** parse
  digest, strict schema, bounds no looser than any reviewed Meta file,
  coverage against sysfs, a separate 2 s-bounded process under seccomp
  and rlimits, spawned before the supervisor's RT elevation and never
  waited on beyond 2 s (revision 5), explicit LP and ext4 limits,
  fuzzing; any failure → fallback, never "no thresholds" on the Quest 3 or
  Quest 2.
- **R24 (new, revision 4):** under P18 (a), firmware we have not reviewed
  runs on our fallback values even if Meta has made them **stricter** there
  → the user is told; the hash is logged for review; adding a row is a
  small offline change. P18 (b) would close it for stricter files only.
- **R25 (new, revision 5):** a Virtual A/B update whose merge has not
  finished, with its COW data wholly on `userdata` (no `-cow` entry in
  `super`, F38), leaves the raw `vendor` extents consistently at the
  **older** version; the reader can then match the older version's
  reviewed row and apply its thresholds while Meta's own Android would
  use the newer ones → the `-cow` rule, the vendor-incremental match
  (catches mixed reads), and the fact that every applied set is a
  reviewed Meta set of the same device, bounded by §4.5.3 step 5;
  declared. Closes with O27 (a reliable merge marker) or O26 (verity
  root-hash check).

### 9.3 Declared residuals (revision 3)

Accepted for presentation, each with its mitigation and the decision that
would close it:

| residual | where | mitigation now | closes it |
|---|---|---|---|
| **R11 / K5** unclean reset before any power-off began → Quest 3 crash-dump mode if armed | Quest 3, Valve and S1 | power-off as the only deliberate path; dump mode cleared once a power-off began (F20); S1 softdog only with `download_mode` = 0 (T0) | K5 (or K4) before sustained Valve operation |
| **R12** no kernel-hang watchdog on the Quest 3 | Quest 3 | hardware PMIC/LMh protection; the PM's presence; bounded holds | O4, O5 answered |
| **R13** `device_shutdown()` hang uncovered without an open softdog, and during any `RESTART` | both | pre-cooling before the call; S1 softdog recommended | none planned (kernel behaviour) |
| **O6** fan duty after the kernel stops or while `device_shutdown()` hangs | both | fan set to top level first (§4.3) | measurement in T5 |
| **R21 remainder** direct `reboot()` from a root process outside any service | Valve | bounding set on every service; three detectors | none planned; review of exception units |
| **R22 remainder** reboot-path `device_shutdown()` hang; slow reboot becomes a power-off | Valve | 35 s job timeouts; A1/A2 at + 45/55 s | none planned (kernel behaviour) |
| **R25** (revision 5) stale raw `vendor` read during a Virtual A/B merge with COW on `userdata` → an older reviewed row applied | Valve (Quest 3, Quest 2) | `-cow` rule; vendor-incremental match; reviewed sets only, bounded | O27 or O26 |
