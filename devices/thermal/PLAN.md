# Thermal and battery shutdown service: design-to-code plan, parts 1 and 2 (offline)

> **Part 2 (2026-10-16, branch `feat/thermal-part2`):** the device executor (softdog, A1/A2,
> `kill(1, 38)`, pmsg, sysrq), the PID 1 TRIP branch, the Valve layer, the notice consumers (LED,
> static KMS warning, the next-boot record), the PMIC class P7 (CORE-SPEC rev 7 §20) and the v2.7
> ADSP-name fix are built and tested offline: normative text in [`EXEC-SPEC.md`](EXEC-SPEC.md),
> status in §1 and §2 below (rows marked *part 2*). Still nothing has run on a device. The TS T0
> package is in `devices/quest3/ts/`.

2026-10-14, branch `feat/thermal-service`. PM decision PD-7 (J-149, J-150):
the **full** thermal and battery shutdown service is built and proven
before the first GPU workload and the first SteamOS boot. This is part 1:
**offline only**. No device was touched, no adb or fastboot was run,
nothing was downloaded, the archive drive and `/persist` were not touched, no boot image
was built, and nothing in this directory can act on a device (§7).

Binding design: `docs/research/emergency-shutdown-design.md` rev 5
("ESD") and `docs/research/thermal-control-design.md` rev 2 ("TCD"), with
the PM's rulings P1–P18 (P11 rejected), J-118, J-122, J-123, J-145, J-149,
J-158 and J-161. Normative specs written for this work:
[`METACFG-SPEC.md`](METACFG-SPEC.md) (reader, record, acceptance; rules
M-n, A-n) and [`CORE-SPEC.md`](CORE-SPEC.md) (decision core; rules C-n,
clarifications K-n).

Tags: [M] hardware output · [M-static] artifact · [D] derivation ·
[C] hypothesis · [O] open.

---

## 1. Components

| component | what | where | state |
|---|---|---|---|
| **fs-metacfg** | one-shot read-only reader of Meta's thermal configuration from the active slot's `vendor` in `super` (option B, J-122): locate, slot, `O_RDONLY` open, one `BLKGETSIZE64`, seccomp, LP metadata, our bounded ext4 reader, strict JSON → framed record | `src/fs-metacfg.c` (static C, no allocation after the filter) | **built, tested** |
| **fs-thermald start-up** | spawns fs-metacfg before any RT elevation (SCHED_RESET_ON_FORK, affinity reset, empty mask, fd 3 only, rlimits), waits ≤ 2 s with `ppoll` on pipe + pidfd, kills and continues on a stuck helper, reaps later; computes the hashes itself; acceptance A-1…A-9 or the built-in fallback, with the user notice | `src/fs-thermald.c` `run_helper`, `src/thermald_accept.c` | **built, tested** |
| **decision core** | pure `core_tick(state, readings, now)`: tiers T0–T5, Meta levels with hysteresis and 30 s dwell, sensor/class/battery/fan faults, hot anomalies, P5–P15, fan demand and floors, caps, the shutdown timeline (signal PID 1, A1 at + 45 s, final pet + A2 at + 55 s, P12 fast T5, P15), stage-mode timeline (TERM, + 2 s KILL, final pet, TRIP), the initramfs gate | `src/thermald_core.c` | **built, tested** |
| **device tables** | class maps, groups and minimum counts, built-in fallback (= the reviewed files), fan levels and rules, caps, P5, known-firmware rows (hashes only) | `src/thermald_tables.c`, `tables/` | **built, tested** |
| **I/O layer** | opens every node once at start-up (zones by `type`, psy, usb, ADSP remoteproc, hwmon `pwmfan`, cdev `pwm-tach-fan0`, cpufreq policy0/2, `kgsl-3d0/max_pwrlevel`, state file), reads fan-zone trips from sysfs, writes owned nodes with read-back and the `cpuinfo_min_freq` fallback, detects other writers | `src/fs-thermald.c` `io_*` | **built, tested against fake sysfs trees** |
| **Python references** | independent oracles written from the specs only (no access to the C): `core_ref.py`, `metacfg_ref.py`; independent fixture writer `mkfix.py` (LP writer + `mke2fs -d` + exact F34 feature words) | `tools/ref/`, `tools/fix/` | **built, tested** |
| **device executor** (part 2) | softdog open/pet/final pet (E-1…E-6), pre-forked A1/A2 pinned to CPU0 (E-7…E-10), `fs-poweroff-final`, sysrq `c`, `kill(1, 38)`, `/dev/pmsg0` FST1 records, the FSN1 notice and heartbeat records, `mlockall`, SCHED_FIFO 60, RLIMIT_RTTIME; product/trial/log-only builds | `src/thermald_exec.c`, `src/fst_record.c`, `src/fs-poweroff-final.c`, `src/poweroff_final.h` | **built, tested offline** (EX 28, build checks); device execution: Chair classes (FS-R-013 §7) |
| **stage guard S1 and `pid1-hold.sh` TRIP branch** (part 2) | `fs-thermald --stage` as the guard (C-39, E-17); PID 1 TRIP-first loop, guard-alive, no-fallback exit (P-1…P-8) | `stage/pid1-hold-ts.sh` | **built, tested** (15 scenarios, reviewed busybox under qemu); `fs-tguard` with P16 values not built |
| **Valve layer** (part 2) | `fs-thermald-watch`, `fs-thermald-shutdown.service`, ready target, drop-ins (`CAP_SYS_BOOT`, `RestrictRealtime`, `JobTimeoutSec`, watchdogs off), masks, logind, `ReadOnlyPaths` | `valve/`, `src/fs-thermald-watch.c` | **built, checked statically** (59); the systemd 257.7 QEMU suite **not done** |
| **notice consumers** (part 2) | LED pattern per severity (`fs-noticed`); static per-eye KMS warning frame from the stage-3d display path (`fs-warnscreen` = fs-pattern v0.7.1 + `warn.patch`); next-boot record (FST1) read by the gate | `src/fs-noticed.c`, `src/warnscreen/` | **built, tested offline** (29: patterns, live LED run, a frame per reason, the watch sequence); SteamVR overlay (b) not built |

### 1.1 Interfaces (all read at start-up by name, never by number)

| interface | read | written (owner: fs-thermald only) | source |
|---|---|---|---|
| thermal zones `/sys/class/thermal/thermal_zone*/{type,temp}` | every class-map zone and AUX input | never (no trip, no `poweroff_cmd`, ESD §5.6) | ESD §3.1/§3.2 |
| fan zones `trip_point_N_{temp,hyst}` | at start-up: the runtime source of the fan curve (ESD §4.5.1) | never | TCD §1.3 |
| `power_supply/battery/{temp,voltage_now,current_now,capacity,status}`, `usb/online` | every psy period (Quest 3 5 s, Quest 2 2 s) | **never** (no charger write, §2 of ESD; TCD §0.8) | ESD §3.1 |
| `remoteproc/*/{name=adsp,state}` | every tick (Quest 3) | never (ADSP never stopped) | TCD §6.4 |
| hwmon `pwmfan` `{rpm,pwm,rpm_per_sec,silent_rpm}`, cdev `pwm-tach-fan0` `{cur_state,max_state}` | every tick | `rpm` (target, every tick) | TCD §3.3 |
| cpufreq `policy{0,2}/{scaling_max_freq,scaling_governor,cpuinfo_min_freq}` | every tick (read-back, other-writer check) | `scaling_governor` once (schedutil), `scaling_max_freq` every tick | TCD §4.1 |
| KGSL `kgsl-3d0/max_pwrlevel` (needs the probe-only load C4a) | read-back | every tick; absent → GPU caps skipped and logged | TCD §4.2, FS-A-013 §3.4 |
| backlight `panel0-backlight` | not used | **never** (dimming is a new write class, ESD §6.3) | — |
| `super` (block device) | fs-metacfg only, `O_RDONLY`, `pread` + `BLKGETSIZE64` | never | ESD §4.5.2 |
| `/run/fs-thermald/state` | — | every tick (limits, reason, JSON hash, VR export, the tick line) | ESD §4.5.3 |

---

## 2. Requirement coverage (design → code → test)

Test suites (all under `tools/`, results in `fixtures/<suite>/RESULTS.txt`):
**SC** `sim/scenarios.py` (111 scenarios, C binary on fake sysfs trees, each
with negative controls, then the Python reference on the same ticks:
111/111 identical natively **and** for the static aarch64 build under
qemu-user) · **SW** `sim/sweep.py` (rev 6: 440 fan runs with the
simulated fan of `sim/fanmodel.py`: 320 healthy runs over the envelope of
CORE-SPEC §19 with no shutdown and no fan fault allowed, 120 dead, stuck,
frozen and unreadable fans that must shut down within the stated bounds;
every run C = Python) · **REF** `ref/test_core_ref.py` (197 unit tests of the
reference) · **MC** `test_metacfg.py` (209 fixture images compared byte
for byte between the C reader, the fixture writer's expected record and
the Python reader, plus 19 C-only cases) · **ACC** `test_accept.py` (43
acceptance and spawn cases) · **TAB** `test_tables.py` (25 table and static
checks) · **REAL** `test_real_local.sh` (local only: the three real vendor
images wrapped in a synthetic `super`: v66 C = Python = debugfs, hashes
and digests = table, accepted; the two v2.7 rows refused `vab-policy` by both
readers (M-21a), JSON hash = table row, built-in table).

| # | requirement (source) | code | test | status |
|---|---|---|---|---|
| R1 | single owner of fan, caps, governor and the shutdown decision (ESD §0.1, §2) | I/O writes only the owned nodes; read-back each tick, other writer logged and re-asserted | SC `owner_conflict`; TAB forbidden write targets absent from all binaries | done (Valve-layer `ReadOnlyPaths` part 2) |
| R2 | tiers T0 NORMAL … T3 WARN at Meta LIGHT/MODERATE/SEVERE, every step up immediate (ESD §4.1) | C-10, C-15, C-17 | SC `soc_levels_pm1` (every threshold at ±1 m°C), `battery_levels`, `skin_levels`, `quest2_battery_59` | done |
| R3 | step down below threshold − Meta hysteresis for 30 s; WARN shown ≥ 30 s (ESD §4.1) | C-10, C-17 | SC `hysteresis_dwell` (at the release point holds; 29 s holds; 30 s drops), `t3_shown_30s` | done |
| R4 | T2 is MODERATE only; no MODERATE → T1 straight to T3 (ESD §4.1) | C-10 set slots | SC `quest2_battery_59` | done |
| R5 | T4 at Meta SHUTDOWN, latching (ESD §4.1) | C-16, C-17 | SC `soc_levels_pm1`, `battery_levels`, `skin_levels`, `psy_battery_shutdown` | done |
| R6 | T4 pre-cool: fan top, CPU `cpuinfo_min_freq`, GPU lowest; signal PID 1 (ESD §5.3) | C-21, C-27, C-35 | SC `soc_levels_pm1` | done (signal executor part 2) |
| R7 | T5: budget + 45 s A1, + 55 s final pet + A2; one `reboot(POWER_OFF)`; no pet after the final pet (ESD §5.3, P12, P17) | C-35, C-37 | SC `budget_t5_and_a2`, `t5_fast_p12` | done (executor part 2) |
| R8 | P12 fast escalation +5 SoC / +2 battery / +3 skin over SHUTDOWN (ESD §4.4) | C-18, C-36 | SC `t5_fast_p12` (+4.999 negative control), `t5_fast_a1_done` | done |
| R9 | any detected shutdown (byte, `systemd-shutdow` comm) gets the same 45/55 s bound (ESD §5.1) | C-34, C-35 | SC `external_shutdown_byte`, `external_shutdown_comm` | done |
| R10 | P15 sysrq `c` only after A2's exit (ESD §4.4) | C-38, K-12 | SC `p15_sysrq_after_a2` (before A2 never), `budget_t5_and_a2` (no P15 → none) | done |
| R11 | stage images: PID 1 the only reboot caller; guard TERM, + 2 s KILL, final pet, TRIP (ESD §6.1) | C-39, K-11 | SC `stage_mode_trip` | core done; guard and `pid1-hold.sh` part 2 |
| R12 | sensor fault P9: read error, < −20 °C, frozen virtual; SEVERE now, T4 after 120 s; clears after 30 s healthy (ESD §3.3, TCD §6.4) | C-1…C-3, C-9 | SC `sensor_read_error_t4`, `sensor_read_error_recovers`, `sensor_low`, `frozen_virtual`, `frozen_virtual_negative` | done |
| R13 | hot anomaly > 125 °C / rise > 10 °C/s counts toward T4 unless an independent sibling contradicts within 2 cycles; no-sibling rules (ESD §3.3 rev 2/3) | C-4…C-8 | SC `hot_anomaly_confirmed`, `hot_anomaly_contradicted`, `no_sibling_hot`, `no_sibling_rise_below_severe` (10 °C/s negative), `no_sibling_rise_at_severe` | done |
| R14 | class fault (minimum healthy counts): SEVERE, T4 after 120 s; two classes → T4 at once (ESD §3.3) | C-11 | SC `class_fault_two_classes`, `class_fault_120s` | done |
| R15 | battery class: ADSP not running, psy error, all three values frozen > 60 s (TCD §6.4, ESD §3.1) | C-12, K-8 | SC `class_fault_120s`, `psy_error`, `psy_stale`, `psy_not_stale` | done |
| R16 | P5 usb-conn ≥ 70 °C → T4 (Quest 3) | C-13 | SC `p5_usb_conn` (69.999 negative) | done |
| R17 | P6 ≤ 3 % discharging → T4; P13 ≤ 10 % → WARN, never a shutdown | C-14, C-33 | SC `p6_p13_low_battery`, `p6_charging_no_t4` | done |
| R18 | P14 "unplug" on T4 with a charger attached | C-31 | SC `p14_unplug`, `p14_no_unplug_on_battery` | done |
| R19 | **J-145**: charging accepted only below 30.0 °C; mid-run = **WARN only**, the battery tiers decide any shutdown (PM J-171) | C-32/K-17 (WARN while charging ≥ 30.0 °C), C-44 (gate refusal with `--j145`) | SC `j145_notice` (29.9 negative; one event; WARN `charging-too-warm`; no T4; WARN ends after charging stops), `gate_j145`, `gate_j145_pass` | done |
| R20 | no software charger write (TCD §0.8, ESD §2) | no charger node is opened for writing | TAB forbidden strings (`restrict_cur`, `restrict_chg`, `charge_control_limit`) | done |
| R21 | fan: temperature-driven from the device's own Meta zones; runtime trips; P1 3700 floor; P4 4500/5000/5500; top at T4/T5, while not READY and on a fan fault; display state never a control (TCD §3.3, ESD §4.3) | C-20, C-21 | SC `idle_normal`, `fan_demand_follows_meta` (75 °C → 4500, hysteresis 10), `soc_levels_pm1`; TAB fan table | done |
| R22 | tach checks F1–F6 (TCD §3.3), not starved by the allowance (K-24); rev 6: F6 a rate (5 of 20), checks held on a tick without their readings (K-44, K-45) | C-22…C-25, K-24, K-44, K-45 | SC `fan_f1`, `fan_cur_eq_max_ok`, `fan_f2_and_p8`, `fan_f3`, `fan_f3_negative`, `fan_f4_max_rpm`, `fan_pwm_254_ok`, `fan_f5_frozen`, `fan_absent`, `fan_write_error` | done; F7 (kmsg) **not built**; F4 final at T3a |
| R23 | P8 fan fault → SEVERE, T4 after 120 s or at the 2nd fan trip | C-16, **K-15/K-16** | SC `fan_f2_and_p8`, `fan_trip2` (74.999 negative); REF `test_k16_*` | done; K-15/K-16 found here (Q5) |
| R24 | headless phases: fan absent is a fault unless the image declares a headless idle stage (ESD §4.3) | C-26, K-14(c) | SC `fan_absent`, `fan_absent_headless`, `quest2_headless_idle`, `quest2_no_fan_rules` | done |
| R25 | caps per tier (P3, P11 rejected → NORMAL = L4), effective = min with the kernel; cap failure → `cpuinfo_min_freq`, then power off (TCD §4.1, §6.3) | C-27, C-28, I/O | SC `idle_normal`, `caps_write_fail`, `caps_fail_at_start`; TAB caps | done (Quest 2 caps **[O]**, Q2) |
| R26 | self-test gates READY; failure → fan top, SEVERE caps, T4 after 60 s unless the trial override (TCD §6.4); rev 6: a failed fan read alone is retried on the next two ticks (K-48) | C-29, C-16, K-48 | SC `selftest_missing_zone`, `selftest_trial_override`, `fan_absent`, `rev6_first_read_fails`; REF `test_k48_fan_item_retried` | done |
| R27 | petting only after a complete cycle (a stuck read stops the petting) (ESD §5.1) | loop structure; `!HANG` fixture; E-6 | SC `hung_read_stops_petting`; EX `x_hung_read_stops_petting` (no keepalive after the stuck read) | done (part 2: the real softdog wrapper) |
| R28 | initramfs gate: every class below SEVERE − hysteresis; after a pstore T4/T5 marker below LIGHT; P6 refuses, ≤ 10 % warns (ESD §6.2 rev 3) | `core_gate`, C-41…C-44 | SC `gate_*` (10 cases incl. 55.000/54.999 and 53.000/52.999 with the marker) | done (pstore read part 2, O19) |
| R29 | trial "battery absent by design" only with the override (TCD §6.4) | `--batt-absent` needs `--trial-override`; BATT dropped; P6 stays | SC `batt_absent_trial` | done; build-time exclusion of the override in product builds **part 2** |
| R30 | Meta's thresholds from the user's own headset; fallback on any doubt; user told; never "no thresholds" (J-118, ESD §0.10, §4.5) | fs-metacfg + A-1…A-9 | MC, ACC, REAL | done |
| R31 | LP: primary only, checksums, limits m1, `-cow` → `vab-merge` (F38), vendor DISABLED, extents (ESD §4.5.2); rev 2 (FS-R-012 §8): a deny-list of signals visible in super, plus the M-21a Virtual A/B policy (`vab-device`, `lp-flags`, `vab-cow-group`, `overlay`, `vab-updated`, `lp-attr`) | M-6…M-12 | MC (≈ 50 LP fixtures incl. backup-geometry-valid → still fallback; rev 2: `vab-device-flag`, `vab-device-and-cow`, `lp-flags-unknown`, `lp-flags-high`, `vab-cow-group`, `ok-group-cowx`, `overlay-scratch`, `vab-updated-attr`, `vab-updated-other-slot`, `lp-attr-unknown`, `ok-slot-suffixed-attr`) | done |
| R58 | **PM decision 2026-10-15: Virtual A/B devices always use the built-in table** (supersedes J-118's runtime values for them): any `ro.virtual_ab.*` property not `false` → `vab-policy`; unreadable `build.prop` → refused; absent → accepted (non-VAB firmware, reviewed rows only) | M-21a (key and value trimmed of `isspace` as Android's property loader) | MC `vab-prop-enabled`, `-retrofit`, `-compression`, `-empty`, `-garbage`, `-spaced`, `-false-then-true`, `-crlf`, `-lead-ff`, `-lead-vt`, `-lead-cr`, `ok-vab-prop-isspace-false`, `vab-prop-and-no-device` (order), `ok-vab-prop-false`, `ok-vab-prop-commented`, `ok-vab-prop-other-prefix`, `buildprop-missing`; REAL (v2.7 rows refused, v66 accepted) | done |
| R32 | ext4: exact F34 features, bounded walk m2, EROFS → `fs-type` | M-13…M-20 | MC (≈ 45 ext4 fixtures) | done |
| R33 | strict JSON schema (dup keys, unknown keys, 7 slots, `VrThreshold` NAN, `Monitor`, names, counts) (ESD §4.5.3 step 4) | M-22…M-25 | MC (≈ 55 content fixtures) | done |
| R34 | locate by `PARTNAME=super` and size; uevent wait inside 2 s (m4); slot from bootconfig (Quest 3) or cmdline (Quest 2) (F37) | M-1…M-4 | MC C-only: `locate-*`, `slot-*`, `uevent-late-1.5s` (accepted), `uevent-never` (no-super < 2 s), `super-size-mismatch`, `super-not-a-file` | done |
| R35 | seccomp after the open; only pread/write/… (m3) | `install_seccomp` | MC `seccomp-active-ok`, `seccomp-forbidden-syscall` (killed → no record) | done; qemu `-strace` syscall list part 2 |
| R36 | helper never delays the boot: spawn rules, 2 s ppoll, kill, continue, reap later; RLIMIT_CPU kills a spinner (m2/M2, F39) | `run_helper`, `reap_helper` | ACC `spawn: *` (hang 2.00 s, partial header, spin killed at 1.00 s, garbage, caps, short, missing helper, reaped later) and the probe of the spawn rules (empty mask, all CPUs although the parent was pinned, SCHED_OTHER, the five rlimits, only fd 3) with its negative control | done; true D-state (nbd) **part 2** |
| R37 | fs-thermald hashes itself (m5): file hash + parse digest + incremental must match a reviewed row; P18 unknown → fallback; VR list exported only if its hash matches | A-1…A-4 | ACC (12 cases), REAL | done |
| R38 | bounds (class from our map, never `Type`; CRITICAL/EMERGENCY unset; 35–125; increasing; hysteresis release ≥ 20; SHUTDOWN caps) and coverage (step 5/6) | A-5…A-7 | ACC (17 cases incl. 20 °C release negative control, SKIN-typed `soc-usr` at 115 accepted) | done |
| R39 | fallback = §4.1 numbers = the reviewed files; v2.7 differs only in `usb-conn` | tables | TAB | done |
| R40 | repo holds hashes, digests and derived thresholds only; never a Meta file (J-123, ESD §4.5.7) | `tables/derived/*.tsv` (identifiers + thresholds), `tables/known-firmware.tsv` | TAB recomputes each digest from the derived table | done |
| R41 | static C, Python reference, differential on shared fixtures (ESD §0.6, §5.1, §7.1) | all | SC 68/68 identical natively and as aarch64 under qemu; MC byte-identical records | done |
| R42 | order invariant (ESD §4.5.4): fan ≥ Meta demand before any cap; no cap looser than the kernel | C-21 (max with demand); caps are maxima, the kernel takes the minimum | SC `fan_demand_follows_meta` | partly: a property test over random traces is **part 2** |
| R43 | **user-visible fault feedback (PM J-171) (a): notice channel** — reason code, severity, countdown on every tick | core §15 K-18…K-21 (`n=` field), `/run/fs-thermald/state` | SC: the notice is asserted in the scenarios of R44 (each reason, every countdown: 55 s at T4, 10 s at fast T5, 2 s in stage mode, 120 s … 1 s on a running fault timer, 0 at A2/TRIP) and compared tick by tick with the Python reference | **core done**; the transport to (b)–(e) is part 2 (§2.1) |
| R44 | (a) reasons: fan failure, battery overheating, battery sensor lost, skin/SoC temperature high, USB connector hot, sensor fault/anomaly, battery empty/low, charging too warm, cap write failed, self-test failed, shutdown requested; **PMIC hot** | K-19/K-20 mapping and priority | SC `fan_f2_and_p8`, `fan_trip2`, `battery_levels`, `class_fault_120s`, `skin_levels`, `soc_levels_pm1`, `p5_usb_conn`, `sensor_read_error_t4`, `hot_anomaly_*`, `p6_p13_low_battery`, `j145_notice`, `caps_write_fail`, `selftest_missing_zone`, `external_shutdown_byte` | done except `pmic-hot` (with the P7 class, Q3 → part 2) |
| R45 | (b) in-headset notification/overlay under SteamOS/SteamVR through our SteamVR driver (IVROverlay / notifications) | consumer of the FSN1 record (E-24) | — | **not built** (needs the SteamVR driver; EXEC-SPEC §11) |
| R46 | (c) per-eye KMS warning screen when nothing else drives the panels (stage images, early boot, the initramfs gate), through the proven stage-3d display path (rotation, swap), plus a sound if audio is up | `fs-warnscreen` = fs-pattern v0.7.1 + `warn.patch` (static frame, reset once then show-off-quad per display, ≤ 3 displays) | CONS: a frame per reason (levels, both eyes, rolled apart, reproducible, distinct), the watch sequence on a non-DRM path | **built offline**; no sound; on a device: T5 (new display operation) |
| R47 | (d) status LED pattern as a last resort | `fs-noticed` (the existing LED write class; E-34) | CONS: pattern per severity, live run on a fake LED tree | **built offline** |
| R48 | (e) reason saved to pstore and shown on the next boot ("Last shutdown: fan failure at 52 °C") | FST1 records (E-20) at T4, T5, A2, A2's return and a gate refusal; the gate reads `pmsg-ramoops-0` (E-22): marker + `last=` for the consumers | EX `x_valve_t4_timeline`, `x_gate_pstore_marker`, `x_gate_pstore_bad_crc`, `x_notice_last_shutdown`, `x_fst_differential` (C = Python on 188 dumps) | **built offline**; O19's hot-boot limit open |
| R49 | (f) the notice never delays the deadline; the A1/A2 timeline stays authoritative | K-22; E-24 (a pull record, `pwrite` only; the supervisor never reads, waits or signals) | SC `budget_t5_and_a2`, `t5_fast_p12`; EX `x_stalled_consumers` (a reader SIGSTOPped on the record, a reader blocked on a swapped-in FIFO, a CPU hog: A1/A2 on their exact ticks, tick latency < 1 s) | done |
| R51 | **review MAJOR-1: fan checks never starved** — F2/F5 through the ramp allowance after a 15 s spin-up grace; F3 low side inside the allowance; allowance ramp capped at 60 s; hwmon `rpm_per_sec` accepted only in 50…2000 | K-24; I/O bound | SC `review_osc_frozen_tach_reaches_p8`, `review_osc_stall_reaches_p8`, `review_osc_stuck_low_reaches_p8` (SoC 81↔85 °C every 8 s: each reaches P8), `review_osc_healthy_no_fault` (negative), `review_rpm_per_sec_1` | done |
| R52 | **review MAJOR-2: a missing fan zone never disables fan control** — zone fault F8 (missing, short, unreadable, or trips ≠ table), demand from the table trips, fan written, tach checks on, P8 | K-25; I/O asserts sysfs trips = table (TCD §3.3) | SC `review_fan_zone_missing` (also with the trial override), `review_fan_trip_mismatch` | done |
| R53 | review MINORs: exact 64-bit arithmetic, out-of-int32 → ERR; frozen non-virtual sensors (tsens, usb-conn, psy, board); CRITICAL/EMERGENCY fail closed; BOARD in A-6; `ddr` in the class map; cap read-back ≤ requested; cpufreq policies from the table; TCD §3.3 cdev cross-check; S-1 sysfs parsing compared on real-format text | K-26…K-28, K-30, K-31, S-1; harness reads every tick back from the tree | SC `review_psy_overflow` (42949700), `review_frozen_tsens` (+ negative), `review_cap_clamped_ok`, `review_cdev_mismatch` (+ negative), `review_quest2_min_caps`, `review_sysfs_formats`; ACC BOARD case; TAB label→hash (circular check dropped) | done |
| R54 | Arbiter J-172: Quest 2 READY only headless idle, CPU `min` at T3–T5, policies 0/4/7; F4 against DT max-rpm at full PWM; O20 with `soc-usr` weak and a common-mode tsens fault vetoing contradiction | tables; K-24 (c), K-29 | SC `review_quest2_min_caps`, `fan_f4_max_rpm`, `fan_pwm_254_ok`, `review_weak_soc_usr`, `review_common_mode_veto`; TAB | done |
| R55 | **delta review (rev 4):** the stuck-sensor rule only for SoC tsens (`stuck`), never the battery temperature or slow 0.1 °C zones, and never through the two-class instant shutdown; `fan-trip2` needs a non-F6 fan condition or an F6 streak ≥ 5 s; tach plausibility F9; F3 inside the allowance against the ramp-progress bound with a held timer; cap read-back parsed with S-1 | K-33…K-36, S-2 | SC `review2_flat_slow_zones_no_shutdown` (battery 31.2 °C and USB flat 460 s, SoC stepping 3.5 °C: nothing), `review2_one_tsens_flat_steady_load`, `review_frozen_tsens` (stuck → T4 at + 120 s, no `classes`), `review2_f6_transient_no_trip2`, `review2_f6_persistent_trip2` (T4 at + 5 s), `review2_tach_noise_f9`, `review2_tach_ramp_plausible`, `review2_stuck_lower_of_alternating` (F3 < 90 s) | done |
| R57 | **round-4 review (rev 6, NO-GO fixed):** no false F3/trip-2 shutdown of a healthy fan under tach noise, slow spin-up or demand alternating every 3–6 s (median ramp credit K-46; F3 episodes end when the fan shows the missing speed, K-47); no false P8 from 0.5–2 % failed reads (F6 rate K-44; checks held, not reset, on a failed read K-45, so a dead fan with flaky reads still trips at once); C = Python on F5 after an `rpm`-only tick (K-45); F9 floor 25 % (K-49); widened declared limit | K-44…K-49 | SC `rev6_blocker_noise10_ramp100`, `rev6_blocker_slow_spinup`, `rev6_read_failures_2pct`, `rev6_first_read_fails`, `rev6_dead_fan_flaky_reads` (trip 2 at 36 s), `rev6_f5_after_pwm_error`, `rev6_unreadable_fan_trip2`, `rev6_unreadable_fan_p8`, `rev6_noisy_stuck_limit_8s` (noise-widened declared limit, round 5), `rev5_fast_alternation_stuck_3700` and `rev5_stuck_class_plus_skin` (rewritten so a broken build fails them: checked by mutation); SW (all); REF | done; the envelope is checked at T3a |
| R56 | **final delta review (rev 5):** no false F3 for a healthy fan through a spike and a 6 s wobble (continuous ramp expectation from the measured rpm, K-37/K-43); F9 with a noise floor and 3-of-5 persistence; per-episode two-class flag; stuck = tsens only, latched; failed reads count toward fan liveness (6 of 10) | K-37…K-43 | SC `rev5_spike_wobble_healthy_100`, `rev5_spike_wobble_healthy_50`, `rev5_spike_wobble_stuck_caught`, `rev5_wobble_stuck_4500`, `rev5_tach_noise_3pct`/`5pct` (no shutdown), `review2_tach_noise_f9` (random → F9), `rev5_dead_fan_flaky_reads` (fan-trip2 ≤ 10 s), `rev5_stuck_latched`, `rev5_stuck_class_plus_skin`, `rev5_fast_alternation_stuck_3700` (declared limit, no false T4) | done; F9 floor and F3 tolerance final at T3a |
| R50 | **PMIC die temperatures required before READY** (PM J-171, Q3) | CORE-SPEC rev 7 §20 (K-50…K-55): class PMIC, P7 SEVERE 95 / SHUTDOWN 115, 7 IIO channels by DT label, all required (min 7), self-test items, `pmic-hot`; I/O E-33 | SC `p2_pmic_*` (6, C = Python); REF 18 new tests; T0 row T0-10 names them on each unit | **built**; the channels are named from the DT (`devices/quest3/ts/SENSORS.md`), confirmed at T0 |
| R59 | **v2.7 ADSP remoteproc name** (part 2 finding): `3000000.remoteproc-adsp`, not `adsp` | E-32 suffix match | SC `p2_adsp_name_v27`, `_legacy`, `_other_rproc`, `_no_dot` | **fixed** (part 1 would have raised `b:adsp` → T4 at 120 s on a device) |

### 2.1 User-visible fault feedback (PM requirement J-171): design

The user is always told **what** is wrong and **what will happen**
before any thermal or battery shutdown, and never at the cost of the
deadline.

- **(a) One notice source: fs-thermald.** Every tick the core computes one
  notice `<severity>:<reason>[:<seconds>]` (CORE-SPEC §15): `warn` while
  WARN holds (with the time left on a running 120 s/60 s fault timer, for
  example "Fan failure — shutting down in 90 s unless it recovers"),
  `shutdown` from the decision on (with the seconds to the planned A2:
  55 at T4, 10 after a P12 fast T5, 2 in a stage image). The reason is a
  stable code with a fixed priority (battery overheating first). The
  supervisor publishes it, with the sensor name and value, in
  `/run/fs-thermald/state` (one fixed-size record, `pwrite`, sequence
  number) and on a non-blocking notice socket; it never waits for a
  reader. Display strings ("Fan failure", "Battery overheating", "Battery
  sensor lost", "PMIC hot", "Skin temperature high", "Shutting down in N
  s") are mapped from the code by each consumer, so wording can change
  without touching the supervisor.
- **(b) SteamOS / SteamVR running:** our SteamVR driver (the bridge of
  FS-A-013 §1.3) reads the notice record and raises an in-headset
  notification through IVROverlay/notifications; at `shutdown` it shows a
  persistent overlay with the countdown. Fire-and-forget: if the driver is
  absent or stuck, nothing waits.
- **(c) Nothing else drives the panels** (stage images, early boot, the
  initramfs gate before `switch_root`): `fs-warnscreen`, a small static
  program built from the stage-3d display path (the proven per-eye
  rotation and eye swap), draws a fixed warning frame per reason with the
  countdown, started by PID 1 / the gate on a `warn` or `shutdown` notice;
  a short tone if an audio path is up. It runs at idle priority, bounded,
  and is never waited on.
- **(d) LED pattern** as the last resort (and in every case): one pattern
  per severity.
- **(e) Next boot:** at the T4 latch the supervisor writes one record to
  `/dev/pmsg0` (reason code, sensor, value, time, countdown). The next
  boot's gate reads it (with the O19 marker) and shows "Last shutdown: fan
  failure at 52 °C" through (b) or (c).
- **(f) Deadline first:** the notice is computed after the decision and
  never changes or delays an action (K-22); every consumer is a separate,
  lower-priority process fed by a non-blocking write; the A1/A2 timeline
  and the softdog stay authoritative. Part 2 adds a test with a stalled
  consumer.

---

## 3. Device tables

### 3.1 Quest 3 (eureka)
- SoC: `cpu-0-*` (≥ 1 healthy), `cpu-1-*` (≥ 1), `cpuss-*`, `gpuss-0…7`
  (≥ 2), `nspss-*`, `soc-usr` (required; Meta types it `SKIN`, our class
  map makes it SoC, F33). All independent siblings (O20 reading, Q8).
- Skin `surf-virt-usr` (virtual; frozen rule inputs `pcb1-usr`,
  `pcb3-usr`, `pogo-usr`, `soc-usr`); battery `batt-virt-usr` and the psy
  battery temperature (thresholds of `batt-virt-usr`), ADSP liveness;
  USB `usb-conn` (P5); BCL entries are coverage-only.
- Fan: levels 0/3700/4500/5000/5500, 28 rules (zones and level per trip
  from `eureka-thermal.dtsi`, trips re-read from sysfs); `rpm_per_sec`
  and `silent_rpm` from hwmon when present (v2.7), else no ramp (v66).
- Caps: CPU 1920000 / 1651200 / 1382400 / 1094400 / min; GPU levels
  3 / 4 / 6 / 8 / 9.
- **Built-in set for TS (PM decision 2026-10-15: every v2.7 unit runs on
  it).** It equals the reviewed v66 file sensor by sensor (TAB); the
  reviewed v2.7 file differs only in `usb-conn` LIGHT 70 °C (hyst 45),
  which P5 (T4 at `usb-conn` ≥ 70 °C) covers, so no threshold is lost.
  Gaps before TS, none caused by the table source: the PMIC die
  temperatures (R50, J-171: channels named at T0, P7 class, part 2; no
  READY on a device until then); the T0 confirmation of the zone `type`
  names, class map and counts, ADSP staleness timing and the DT model
  mapping on both units; the T3a fan measurements (tolerances, tach noise,
  failed-read rate, rotor lag ≤ 1 s, CORE-SPEC §19); BCL zones stay
  coverage-only (no threshold, as in Meta's files).
- **Adding a known-firmware row** requires the firmware's Virtual A/B
  status from every partition's properties (`vendor`, `odm`, `system`) and
  the unit's `lpdump` output; only a non-Virtual-A/B firmware gets a row
  (METACFG-SPEC M-21a). Open for the v66 row: F38 checked only v66's vendor
  `build.prop`; its `system`/`odm` properties and an `lpdump` are T0 items.

### 3.2 Quest 2 (hollywood)
- SoC `cpu-0-*-usr` (≥ 1), `cpu-1-*-usr` (≥ 1), `cpuss-*-usr`,
  `gpuss-*-usr` (≥ 1), `vrapi-pmem`; skin `vrapi-front-panel`; battery
  `batt-virt` + psy; board `pcb1/2/3-usr`, `xo-therm-adc` (≥ 1);
  `batt-usr` coverage-only (multiplier 0.1).
- **Fan rules, fan floors and caps are not in the design documents [O]**:
  the table carries none, so a Quest 2 image is READY only as a declared
  headless idle stage (Q2).

### 3.3 Quest Pro, Quest 3S
No built-in set: refused, never READY (A-9, TAB).

---

## 4. Failure modes and what the service does

| failure | detection | action | proof |
|---|---|---|---|
| Meta file unknown (newer firmware) | hash not in the table | fallback, `limits=builtin reason=unknown-hash`, notice (P18) | ACC, SC (every SC run starts on the fallback) |
| parser defect | file hash known, digest differs | fallback + fault record | ACC |
| Virtual A/B merge pending, or the active view not established | `-cow` in the slot's LP metadata; rev 2: the Virtual A/B header flag, another header flag, a `cow` group, a `scratch` partition, `UPDATED` or an unknown attribute on the active vendor; vendor incremental ≠ row | fallback `vab-merge` / `vab-device` / `lp-flags` / `vab-cow-group` / `overlay` / `vab-updated` / `lp-attr` / `incremental-mismatch` | MC, ACC |
| Virtual A/B device (PM 2026-10-15) | vendor `build.prop` `ro.virtual_ab.*` not `false`, or `build.prop` unreadable | fallback `vab-policy` (or the read failure's code): built-in table, every v2.7 unit | MC, REAL |
| reader hangs (D state), spins, crashes, lies about lengths | 2 s deadline, RLIMIT_CPU, EOF, framing caps | kill, close, fallback, continue; reap later | ACC |
| sensor lost, erroring, out of range, frozen | C-1…C-3 | WARN now, T4 at 120 s | SC |
| hot glitch vs real heat | C-4…C-8 | WARN, then T4 unless contradicted | SC |
| ADSP down, battery values stale | C-12 | battery class fault → T4 at 120 s | SC |
| fan stalled, wrong speed, frozen tach, missing, write error | C-23…C-25, K-15, K-16, K-44…K-47 (an isolated failed read is not a fault) | fan top, WARN, T4 at 120 s or at the 2nd fan trip | SC, SW, REF |
| caps not writable | read-back, `cpuinfo_min_freq` fallback | T4 `cap` | SC |
| another writer changes our cap | read-back mismatch | logged, re-asserted | SC |
| supervisor read hangs | the cycle never completes | no pet → softdog (part 2) | SC |
| T4 does not finish in time | timeline | A1 + 45 s, final pet + A2 + 55 s; fast at P12 | SC |
| A2's power-off returns | `a2_exited` | P15 sysrq `c` (if ruled), else the softdog | SC |
| hot reboot loop (flashed image) | gate | refuse below SEVERE − hysteresis, below LIGHT after a marker | SC gate |
| unsupported device | no table | never READY | TAB |

---

## 5. Spec findings from the independent implementations (for review)

- **Round-4 review of rev 5 (NO-GO, J-179; fixed in rev 6, CORE-SPEC
  §19, METACFG-SPEC rev 2):** BLOCKER: a healthy fan with ±10 % tach noise
  or a 2 s spin-up under demand alternating every 3–6 s got F3 and a
  `fan-trip2` shutdown (one high reading on a change tick raised the
  expectation; the K-36 hold kept the timer through back-to-back
  allowances). MAJOR: 0.5–2 % failed fan reads → `t4:fan`. MAJOR
  (FS-R-012 §8): the reader logged the Virtual A/B flag and `UPDATED`
  instead of refusing. MINORs: C ≠ Python on F5 after an `rpm`-only
  tick; a dead fan with flaky reads lost its timers; two scenarios that
  passed on any build; the declared limit too narrow. All fixed, with the
  sweep (SW) as the regression for the blocker and the fan MAJOR.
- **K-15/K-16 (safety, fixed):** raising the fan target to `top` after a
  fault starts a new ramp allowance; with a 30 s clear, a fan stuck at a
  wrong speed (F3) or with a frozen tach (F5) cleared between windows and
  **never reached P8's 120 s T4**. Fixed: no clear inside the allowance,
  and a 60 s fan clear window. Found by the Python reference's author from
  the spec alone.
- **F4 was subsumed by F3** with the TCD §3.3 tolerances; redefined against
  DT max-rpm at full PWM (J-172), final at T3a.
- **Delta review of rev 3 (GO-with-fixes):** K-27 falsely shut down a
  device whose battery and USB readings stayed flat at 0.1 °C resolution
  while the SoC moved; a single fan read error at the 2nd fan trip shut
  down at once. Fixed as K-33/K-34 with the reviewer's cases as scenarios;
  MINORs as K-35/K-36/S-2.
- **Adversarial review (GO-with-fixes):** MAJOR-1 (fan checks starved by
  re-started allowances) and MAJOR-2 (one missing fan zone disabled all fan
  control) fixed as K-24/K-25, with the reviewer's cases as regression
  scenarios; every MINOR applied (K-26…K-31, S-1). The reference author's
  readings of rev 3 are K-32.
- **M-20 was too weak** (inode/descriptor ranges inside the partition but
  past the filesystem): strengthened.
- **The 16-block directory cap** is reachable only for `/` plus `/etc`
  together (one directory over 16 blocks already fails `ext4-isize`).
- **`build.prop` `import` lines** would have caused a fallback under the
  first reading; now ignored (rev 1a).
- Eight further readings were aligned (status codes for wrong JSON types,
  log fields zeroed on failure, sysrq `c` only after an earlier A2, T5
  budget shown on its own tick, …): METACFG-SPEC rev 1a, CORE-SPEC K-1…K-16.
- **Declared divergence:** read-budget accounting at the 1 MiB edge
  (METACFG-SPEC §8; fixture `budget-edge-over`).

---

## 6. What the T0–T6 hardware stages will need

Per TCD §6.7, re-targeted to v2.7 on both units (FS-A-013 TS row); each
step its own package, reviews and the PM's sign-off; bounded attended hold
until T5 passes **and** the full v2.7 checklist is complete (J-158).

| stage | needs from part 1 / part 2 | read or measure | sets / confirms |
|---|---|---|---|
| **T0** (Android, read-only, PM's device gate) | nothing built; **the PMIC die-temperature iio channels must be named here (J-171: required before READY)** | zone `type` list and idle values; cooling devices; hwmon names and `rpm`/`pwm`/`rpm_per_sec`/`silent_rpm`; psy fields and how often they change; `remoteproc` names; cpufreq `cpuinfo_min_freq` and OPPs per policy; KGSL `num_pwrlevels`/`max_pwrlevel`; **`/sys/module/qcom_dload_mode/parameters/download_mode`**; DT `model` string; `/proc/bootconfig` (slot); `sha256sum` of the two vendor files; `getprop vendor.thermal.config`; Virtual A/B state (`snapshotctl dump`, `dmctl`), `lpdump` (privileged; [removed for publication]); PMIC registers (TCD §5.2 E); iio die-temperature channel names | class map names and counts; frozen-rule thresholds; ADSP staleness timing; the DT model → device mapping; row `c9301ff5…` on both units; softdog precondition (`download_mode` = 0); P7 channels (Q3) |
| **T1** monitor only | fs-metacfg (production build) + fs-thermald **log-only** mode (part 2: a mode that reads and logs but writes nothing) in a stage image with the tsens/ADC modules | fs-metacfg on the real `super` (first device read of a Meta partition, Chair class); every zone present; idle values vs Android ±3 °C | `limits=meta-runtime` on both units; uevent timing of `super` |
| **T2** caps at idle + **probe-only KGSL load** (C4a) | part 2 writes enabled for cpufreq and KGSL only | governor/caps read-back; firmware requests logged | caps path; KGSL nodes exist without a workload |
| **T3a** fan | fan writes enabled | tach vs target at 3700/4500/5500; ramp; blank re-assert; `force_failure` → F1/F2/F5 within ≤ 25 s; rev 6: tach noise, failed-read rate and the rotor's lag behind the driver ramp (the healthy envelope of CORE-SPEC §19); **measure the real rotor lag on both units: above 1 s, K-43/K-47 are revisited before TS** (round 5: a 2 s lag gave a false trip 2) | F3/F4/F5 tolerances (Q4), K-16 window, the K-44 rate and the K-49 floor |
| **T3b** battery (ADSP from the OTA, J-158; J-145 for charging) | ADSP start in the image | psy vs Android ±2 °C; how voltage/current move (staleness thresholds); `batt-virt`/`surf-virt` vs Android | C-12 timing; J-145 behaviour (Q1) |
| **T4** throttle, **CPU-only** load (GPU part = G1(ii), J-161) | test thresholds at idle + 3 °C (a test row) | each tier's caps read back; hysteresis; dwell | P3 caps effective |
| **T5** shutdown path | the notice consumers (b)–(e), shown and timed against the countdown; **part 2 executor**: softdog (after `download_mode` = 0), A1/A2, `fs-poweroff-final`, `/dev/pmsg0`; S1 guard + `pid1-hold.sh` TRIP branch for stage images | orderly power-off time; **kernel power-off time → `M_final` (P17)**; landing state; PMIC power-off reason afterwards; simulated sensor loss and ADSP stop (inputs only, ADSP never stopped) | P17 margin; ESD O16 |
| **T6** soak | full checklist complete (J-158) | 10 → 30 → 60 min, discharging then charging | sustained operation |

Before T1, part 2 must also bring: the production executor and its QEMU
suite (ESD §7.1: systemd 257.7, softdog expiry, `RLIMIT_RTTIME`, `@`
survival, `CAP_SYS_BOOT`, `JobTimeoutSec`), the qemu `-strace` checks of
fs-metacfg and `fs-poweroff-final`, a D-state helper test (nbd), C-side
fuzzing of the JSON/LP/ext4 walkers (the Python reader was fuzzed with
3000 flips), the order-invariant property test, F7 (kmsg), the recomputed
skin cross-check (TCD §6.4), the pstore marker (O19), and the product-build
exclusion of the trial override.

---

## 7. What part 1 deliberately does not do

- No device mode: the binary is a **simulation build**; every safety
  action (`pet`, `final-pet`, `a1`, `a2`, `signal-pid1`, `sysrq-c`,
  `term-step`, `kill-step`, `trip`) is printed, never executed. The
  aarch64 builds exist only to run the suites under qemu-user; no image
  includes them, and no binary is committed (`fixtures/build-record/BUILD.txt`
  holds their hashes).
- No Meta file and no excerpt is committed: `tables/derived/` holds sensor
  names, multipliers and threshold numbers (J-123), `tables/` hashes.
- The local-only differential (`tools/test_real_local.sh`) reads the three
  vendor images read-only and deletes its scratch copies.

---

## 8. Open questions for the PM and the Arbiter

**Arbiter decisions J-172:** Q2 Quest 2 READY only headless idle, CPU
`min` at T3–T5, policies from the table (done); Q3 the PM's decision
stands (PMIC required before READY); Q4 F4 kept, redefined against DT
max-rpm (done, final at T3a); Q5 O20 agreed with `soc-usr` weak and a
common-mode tsens fault vetoing contradiction (done, K-29); raw base zone
for fan demand accepted; K-23 confirmed; Q6 part 2 scope below.

**Part 2 scope (Q6, J-172), in addition to §1 and §6:** suspend/resume
(P10 masking, BOOTTIME jumps, the v2.7 fan resume inversion); the PID 1
signal as the literal 38 (glibc SIGRTMIN+4; under musl SIGRTMIN+4 = 39 =
reboot.target), tested on systemd 257.7; softdog only after
`download_mode` = 0; wait for zones at start-up; a log-only mode as a
separate build; a product build without FS_TEST and the override flags;
ExecStopPost (fan top, minimum caps); the GPU cap mandatory before any GPU
load; the fault-feedback parts (b)–(e).

**Decided by the PM (J-171):** Q1 J-145 mid-run = WARN only (implemented,
K-17); Q3 PMIC die-temperature channels required before READY (R50,
named at T0); Q4 K-15/K-16 approved, F4 kept and retuned at T3a
(Arbiter); new requirement: user-visible fault feedback (§2.1, R43–R49).
Pending (the Arbiter, after the adversarial review): Q2, Q5, Q6, and the
remaining items below.

1. *(decided, J-171)* J-145 mid-run: WARN only.
2. **Quest 2 caps, fan rules and fan floors (PM/Arbiter):** Meta's L4
   values, the hollywood fan zones and Quest 2 P1/P4 floors are not in the
   design; until supplied (from the Quest 2 DT and T0-equivalent probes)
   a Quest 2 image is READY only as a headless idle stage.
3. *(decided, J-171)* PMIC die temperatures: required before READY (R50).
4. *(decided, J-171)* F4 kept, retuned at T3a.
5. *(decided, J-171)* K-15/K-16 approved.
6. **Independent siblings (O20):** part 1 treats every SoC sensor (tsens
   and the `soc-usr` ADC) as independent and skin/battery/USB as having
   none; AUX inputs never fault. Confirm.
7. **Fan demand from the base sensor:** part 1 drives Meta's fan curve from
   the instantaneous base zone, not v2.7's 5 s-averaged fan zone (reacts
   sooner, more fan). Accept?
8. **Part 2 scope (Chair classes):** the device executor, S1 guard and
   `pid1-hold.sh` change, the Valve layer, and fs-metacfg's first read of
   `super` on a device (FS-A-012 ask (g)).
