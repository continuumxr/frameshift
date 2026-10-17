# fs-thermald executor and integration (normative spec, part 2, rev 2, 2026-10-16)

> **Rev 2:** the internal adversarial review (§12) fixes applied: TRIP written to the heartbeat at
> once (E-19), PID 1 double-reads the record and never reboots on an unknown state (P-1), no `/run`
> write on the TRIP path (P-2), the log-only build never publishes READY (E-31), the gate waits for
> the asynchronous probes (E-28), the watcher is installed and signals PID 1 directly (§9), and the
> disclosures of E-6/E-28 corrected.

Part 2 of the thermal and battery shutdown service (PD-7). Part 1 built
the pure decision core (`CORE-SPEC.md`), the reader (`METACFG-SPEC.md`)
and a simulation build in which every safety action was printed. This
file specifies the code that **executes** those actions on a device, the
stage-image and Valve-layer integration, and the user-visible notice
consumers. Binding design: `docs/research/emergency-shutdown-design.md`
rev 5 ("ESD") and `docs/research/thermal-control-design.md` rev 2 ("TCD");
Chair ruling FS-R-013 (private review record) §7, §3 and §10 H-1/H-2. Rule ids `E-n`
(executor), `P-n` (PID 1), `V-n` (Valve layer); CORE-SPEC rev 7 adds K-50
… K-55 (PMIC, P7).

**Nothing here has run on a device.** Every result below is offline: the
native test build under a fake root, the static aarch64 builds checked
statically, and the PID 1 shell logic under qemu-user with the reviewed
busybox. Tags: [M] hardware output · [M-static] artifact or source ·
[D] derived · [C] inferred · [O] open.

---

## 1. Build kinds (src/fs-thermald.c header, tools/build.sh)

| binary | defines | modes | what it can do |
|---|---|---|---|
| `fs-thermald` (native test) | `FS_TEST` | `--sim` (part 1), `--exec-sim`, `--exec-gate`, `--gate`, `--fst-scan` | everything under a fake root; kernel-facing calls replaced by logged stand-ins (§6) |
| `fs-thermald-logonly-test` (native) | `FS_TEST FS_LOGONLY` | `--exec-sim` | the T1 log-only rules under a fake root |
| `fs-thermald.a64` (product) | `FS_DEVICE` | `--run`, `--gate`, `--dump-config`, `--accept-only` | the real executor; **no** `--trial-override`, `--batt-absent`, `--sim`, `--root`, stdin ticks or fixture markers (checked on the binary's strings) |
| `fs-thermald-trial.a64` | `FS_DEVICE FS_TRIAL` | as product, plus the two trial flags | TS trial images only |
| `fs-thermald-logonly-trial.a64` (T1) | `FS_DEVICE FS_LOGONLY FS_TRIAL` | `--run --stage --trial-override --batt-absent` | the T1 invocation (log-only rules plus the trial flags) |
| `fs-thermald-logonly.a64` | `FS_DEVICE FS_LOGONLY` | `--run`, `--gate` | reads and logs; **no** device write, no softdog, no actuator, no signal, no pmsg, no sysrq: the code paths are compiled out (E-31) and the strings `/dev/watchdog`, `/proc/sysrq-trigger`, `/dev/pmsg0` are absent from the binary (build check) |
| `fs-poweroff-final.a64` | freestanding | — | `reboot(POWER_OFF)`, `reboot(RESTART)`, `nanosleep` loop; exactly 3 `svc`, proven from the disassembly (`tools/check_poweroff.py`) |
| `fs-noticed`, `fs-warnscreen`, `fs-thermald-watch` | — | §8, §9 | consumers and the Valve watcher |

All aarch64 binaries: pinned clang r450784e, static, ET_EXEC, no INTERP,
no NEEDED, bit-identical rebuild; hashes in `fixtures/build-record/BUILD.txt`.

## 2. Start-up order (E-12)

1. Parse; block every blockable signal (`--run`, `--gate`, `--exec-*`).
   A write to a dead actuator's pipe then returns `EPIPE` instead of
   killing the supervisor (found by `x_actuator_a2_died_early`).
2. stdout/stderr: on a device they must be a regular file **on tmpfs**
   (`fstatfs` TMPFS_MAGIC) or `/dev/null`, else they are re-opened to
   `/dev/null` (E-29: a console, a pipe or a disk file in writeback must
   never stall the loop). The init starts the supervisor with
   `>/run/fs-thermald.log 2>&1`.
3. The record (fs-metacfg spawn with the 2 s bound, part 1); on every
   v2.7 Quest 3 the built-in table (`vab-policy`).
4. `--run` and `--gate`: wait up to `--wait-zones` ms (default 10000) for every counted
   zone and IIO channel (asynchronous probes, FS-R-013 H-1: an `insmod`
   return is not readiness); the self-test then names any that never
   appeared (never READY). No module is loaded by the supervisor.
5. Open every node once (part 1 `io_open`), the PMIC IIO channels (E-33).
6. Executor (`exec_start`): `/run/fs-thermald/{notice,hb}`, the control
   FIFO (`ctl`, `mkfifo` 0600, opened `O_RDWR|O_NONBLOCK`, must be a FIFO),
   the pre-opened `/proc/1/comm`, `/dev/pmsg0`, `/proc/sysrq-trigger`
   (only with `--p15`, never in stage mode), `/dev/kmsg`; then the softdog
   (E-2); then the actuators (E-7); then the RT hardening (E-12 below).
7. Governor and the not-READY caps (part 1), then the loop.

**RT hardening (device builds):** `mlockall(MCL_CURRENT|MCL_FUTURE)`,
`oom_score_adj` −1000, affinity CPU0, `SCHED_FIFO` 60 with
`SCHED_RESET_ON_FORK`, `RLIMIT_RTTIME` soft = hard = 500 ms. A failure of
the affinity, the policy or the limit withholds READY (E-25). It is done
**after** the actuator forks, so the actuators never inherit
`RLIMIT_RTTIME` (a power-off that runs for more than 500 ms of CPU in
A2's context must not get a SIGKILL pending inside `device_shutdown()`).

## 3. Executor rules (src/thermald_exec.c)

### 3.1 Softdog (E-1 … E-6)

- **E-1** The supervisor is the only opener of `/dev/watchdog` (softdog is
  id 0 and owns both `/dev/watchdog` and `/dev/watchdog0`; the open is
  exclusive, `watchdog_dev.c:840-841` [M-static]). `RuntimeWatchdogSec`,
  `RebootWatchdogSec`, `KExecWatchdogSec` are off (V-3).
- **E-2** It opens the softdog only if `--softdog` is given (a separate
  action class, FS-R-013 §7) **and**
  `/sys/module/qcom_dload_mode/parameters/download_mode` reads exactly
  `0` (one optional newline). Missing, unreadable, `1`, or anything else
  → not opened, logged (`download_mode-unreadable`, `download_mode-not-0`).
  The parameter's getter is `param_get_int` over `static bool enable_dump`
  (`qcom-dload-mode.c:38, 109` [M-static]): it prints the 4 bytes at the
  bool's address, so a printed `0` means the bool is false; a nonzero
  print can be a false refusal (padding), never a false acceptance.
  FS-R-013 §7: a readable 0 does not prove every secure-world condition;
  it is the precondition the design asks for, not a proof (§10).
- **E-3** Opening starts the timer with the kernel's margin (60 s,
  `softdog.c:31-36`); `WDIOC_SETTIMEOUT(30)` (P17 running margin) follows
  at once and is read back with `WDIOC_GETTIMEOUT`. A failure leaves the
  open timer running: it is still petted, and READY is withheld.
- **E-4** Final pet = `WDIOC_SETTIMEOUT(M_final)` (which re-arms an active
  timer with the new timeout, `watchdog_dev.c:375-399, 766-779`
  [M-static]) then `WDIOC_KEEPALIVE`. `M_final` = 30 s (P17, provisional;
  re-sized from the T5 power-off measurement).
- **E-5** After the final pet: never another pet **by the supervisor**,
  whatever the core says. Kernel fact (review m1): any close of the softdog
  without the magic `V` pings it once (`watchdog_dev.c:917-930` [M-static]),
  so a supervisor that dies after the final pet re-arms `M_final` from its
  death: the bound is the death time + `M_final`, at most final pet +
  2 × `M_final` if it dies just before expiry.
- **E-6** `pet` (`WDIOC_KEEPALIVE`) only at the **end of a complete
  cycle** (after the reads, the decision, the timeline actions, the writes
  and the records): a read stuck in the kernel stops the petting
  (`x_hung_read_stops_petting`). The magic close `V` is never written; a
  supervisor that dies leaves the softdog armed (it fires after the
  margin).
- `--require-softdog`: no published READY without an open softdog (the
  Valve product and any hold that relies on it).

### 3.2 Actuators A1/A2 (E-7 … E-10)

- **Install name (review m5):** every image installs the supervisor
  binary (product, trial or log-only-trial) as `/bin/fs-thermald`, so its
  comm is `fs-thermald` (P-5 checks it; comm is cut to 15 characters).
- **E-7** A1 (`sync`) and A2 (power-off) are forked at start-up, before
  any emergency, never later. Right after the fork each closes the
  softdog descriptor and every descriptor except its command pipe (and
  A1's status pipe): `x_actuators_drop_watchdog` checks `/proc/<pid>/fd`.
  Neither ever `exec`s: they keep the supervisor's `argv[0]` (the launcher
  starts the supervisor as `@fs-thermald`, systemd's root-storage-daemon
  convention, O7 [C, to verify on 257.7]).
- **E-8** Each acts only on its exact command byte (A1 `0xA1`, A2 `0xA2`);
  EOF (supervisor gone) or any other byte → `_exit(0)` without acting
  (`x_actuators_exit_on_eof`, `x_actuator_wrong_byte`). The supervisor's
  pipe ends are non-blocking: a command write never blocks.
- **E-9** Device builds: each actuator pins itself to CPU0, takes
  `SCHED_FIFO` 59 (below the supervisor's 60, above the threaded IRQs'
  50) and `mlockall`s. No `RLIMIT_RTTIME` (E-12).
- **E-10** A1: `sync()`, then one byte `D` on its status pipe → the
  core's `a1_done` input on a following tick. A2: `fs_poweroff_final()`
  (the same three-syscall sequence as `fs-poweroff-final`, linked in).
  `a2_exited` is reported only for an A2 that exited normally (`CLD_EXITED`)
  **after** its byte was delivered (a returned power-off, F4; review m2); an earlier death is "A2 died",
  withholds READY, and is never reported as a returned power-off
  (`x_actuator_a2_died_early`: the final pet is still given at + 55 s,
  so the softdog covers the missing actuator).

### 3.3 Signal, timeline and inputs (E-11 … E-19)

- **E-11** `signal-pid1` = `kill(1, 38)`, the **literal 38** (glibc
  `SIGRTMIN+4`, systemd's `poweroff.target` request; under musl
  `SIGRTMIN+4` is 39 = `reboot.target`, so the macro is never used).
  `x_valve_t4_timeline` checks that the fake PID 1 received exactly one
  signal 38. That systemd 257.7 on SteamOS maps 38 to `poweroff.target`
  is [C] (systemd(1); glibc build) and is a QEMU item (§11).
- **E-13** Per tick, before the core: `a1_done` (status pipe, latched),
  `a2_exited` (`waitid(WNOHANG)` on A2, E-10), `shutdown_byte` (any `S`
  byte read from the control FIFO, latched; E-14), `pid1_shutdown`
  (`pread` of the pre-opened `/proc/1/comm` = `systemd-shutdow`).
- **E-14** The control FIFO accepts only the byte `S`; anything else is
  ignored (`x_ctl_other_bytes`).
- **E-15 Order within one cycle:** read → executor inputs → core →
  FST1 records (E-20) → timeline actions (`signal-pid1`, `a1`,
  `final-pet` then `a2`, `sysrq-c`; stage: `term-step`, `kill-step`,
  `final-pet`, `trip`) → the part-1 writes (fan, caps, read-back) →
  state, notice and heartbeat records → `pet`. The timeline actions are
  pipe writes, a `kill` and an ioctl; they never wait behind a sysfs
  write that could block.
- **E-16** On a tick with both, the final pet precedes A2's byte.
- **E-17** Stage mode (S1 guard timeline, C-39): `term-step` = SIGTERM to
  the process group named in `--step-pgid-file` (a regular file, read
  with `O_NONBLOCK|O_NOFOLLOW`; pgid ≤ 1, our own group or a non-number
  is refused); `kill-step` = SIGKILL to it 2 s later; then the final
  pet; then TRIP. No actuators, no PID 1 signal, no sysrq (PID 1 is the
  only reboot caller, ESD §6.1).
- **E-18** `sysrq-c` writes `c` to the pre-opened `/proc/sysrq-trigger`
  (only with `--p15`; the core emits it only after an A2 exit, K-12).
- **E-19** TRIP is written into the heartbeat record (E-26) **at once,
  inside the timeline step**, before the tick's sysfs writes (review M1:
  a stuck fan or KGSL write must not hide TRIP from PID 1;
  `x_stage_trip_before_stuck_write`), and stays.

### 3.4 Records (E-20 … E-28; src/fst_record.c, tools/ref/fst_ref.py)

- **E-20 FST1 (pstore).** One line per event, one `write()` to
  `/dev/pmsg0`: `FST1 ev=<start|t4|t5|a2|a2-returned|gate> t=<ms>
  reason=<notice reason> sensor=<cause|-> value=<m°C|-> hot=<name:m°C|->
  why=<t4/t5 events|-> cd=<s|-> crc=<crc32>`, ≤ 240 bytes, canonical form
  only (a parser re-encodes and compares). Written on the T4 latch tick,
  the T5 tick, the A2 tick, the tick A2's exit is seen, and on a gate
  refusal. The pmsg zone is an append-only ring (128 KiB − 12 B; records
  are not delimited by the kernel, so the newline delimits them; a write
  larger than the zone keeps only its tail, `ram_core.c:345-373`
  [M-static]).
- **E-21** No `/dev/pmsg0` (no pstore) → logged, no record; never fatal.
- **E-22** The next boot's gate (`--pstore DIR`, `DIR/pmsg-ramoops-0`,
  the previous boot's bytes, `ram.c:588-589` [M-static], read in full up to
  256 KiB, review m6) scans for valid
  records: any `t4/t5/a2/a2-returned/gate` record is the O19 marker (the
  gate then requires every class below LIGHT, C-42) and gives
  `last=<reason>:<m°C>` for the notice consumers ("Last shutdown: fan
  failure at 52 °C"). A corrupt record is ignored (`x_gate_pstore_bad_crc`).
  pstore is RAM: the marker survives a warm reset (softdog, panic), not a
  real power-off (ESD F29). **O19 (a limit on consecutive hot boots) is
  not settled** (§11).
- **E-24 FSN1 notice record.** `/run/fs-thermald/notice`, exactly 256
  bytes, overwritten in place by one `pwrite` per tick: `FSN1 seq= t=
  ready=<published READY> tier= n=<CORE-SPEC §15 notice> last=<E-22>
  crc=…`, space-padded, `\n`. It is the **only** channel to the consumers
  (the PLAN's notice socket was dropped: a pull record cannot block the
  writer and 1 s granularity needs no push). The supervisor never reads
  it, never waits, never signals a consumer.
- **E-25 Published READY** = core READY ∧ the executor's preconditions
  (run records available, control FIFO, actuators alive, RT hardening,
  softdog when required). The core is not changed (K-22): a withheld
  READY only stops downstream gates (`fs-thermald-ready.target`, PID 1's
  longer hold); the core's own caps and fan follow its own READY.
- **E-26 Heartbeat record** `/run/fs-thermald/hb`: one fixed-width
  40-byte line `%20llu %12lld %-5s\n` (seq, CLOCK_BOOTTIME seconds,
  `INIT|HOLD|READY|TRIP`), overwritten in place, **never truncated** (a
  reader must never see an empty file), no leading zeros (PID 1's strict
  number parsing). `HOLD` = core READY but READY withheld (E-25). A
  one-shot `--gate` creates neither record. A concurrent reader can still
  see a torn record (busybox `read` reads byte by byte); PID 1 therefore
  reads it twice and acts only on two equal reads (P-1).
- **E-28 Gate refusal** (`--gate`, design §6.2): the gate first waits for
  the asynchronous probes like `--run` (review M5: a refusal powers off);
  then an FST1 `ev=gate` record; with `--softdog` and `download_mode` 0:
  the softdog is opened and given the final pet (`M_final`); then fan to
  top and CPU/GPU to their minimum (review m3; after the pet, so a stuck
  sysfs write cannot delay the softdog). The gate process then exits,
  which closes the softdog without `V`: the kernel pings it once more and
  it keeps running (`watchdog_dev.c:917-930`), so the bound is the gate's
  exit + `M_final` (review m1: it is not "left open"; while closed another
  root process could re-open it and stop it with `V`, which no FrameShift
  code does). PID 1 then execs `fs-poweroff-final`. A pass never opens it
  (a single-open device left running unpetted would fire).

### 3.5 Other rules

- **E-29** Device stdout/stderr: regular file or `/dev/null` only (§2);
  the tick line is printed on change, above tier 0, or every 5 s.
- **E-31 Log-only build (T1):** no pmsg/sysrq open, no actuator, no
  softdog, no governor/cap/fan write, no signal: compiled out, and every
  non-`pet` action is logged `log-only: not executed`; it **never
  publishes READY** (heartbeat `HOLD`, review M4)
  (`x_logonly_writes_nothing`).
- **E-32 ADSP name.** The remoteproc is named after its platform device:
  `3000000.remoteproc-adsp` on v2.7 (`qcom_q6v5_pas.c:747`,
  `remoteproc_sysfs.c:222` [M-static]; `remoteproc1: 3000000.remoteproc-adsp`
  in two raw Android probes, FS-A-006/FS-A-004 [M]). **Part 1 matched the
  exact name `adsp` and would have raised `b:adsp` (battery class fault →
  T4 after 120 s) on the device.** The I/O layer now accepts `adsp` or a
  name ending in `.remoteproc-adsp` (`p2_adsp_name_*` scenarios, with the
  negative controls `2000000.remoteproc-cdsp` and `xremoteproc-adsp`).
- **E-33 PMIC channels (CORE-SPEC K-50).** Each PMIC die sensor is the
  IIO attribute `in_temp_<label>_input` (milli-°C; a processed read starts
  one ADC conversion and may wait up to 10 × 50 ms,
  `qcom-spmi-adc5-gen3.c:472-540, 797-822` [M-static]) of exactly one
  `/sys/bus/iio/devices/iio:deviceN` (N is not fixed; the label is). More
  than one match → not used (logged), which fails the self-test.
  **Declared (review m8):** with a hung ADC each of the 7 reads can sleep
  about 0.5 s under the driver's lock, so one cycle can exceed 5 s; the
  watcher and PID 1 then call the guard stale (fail-safe), and a T5 action
  due in that cycle is late by as much (the softdog margin still bounds a
  stuck cycle).

## 4. FST1/FSN1 formats

See E-20 and E-24. Both implementations: `src/fst_record.c` (C) and
`tools/ref/fst_ref.py` (independent Python). `x_fst_differential` runs
the C scanner and the Python scanner on 188 generated and mutated dumps.

## 5. PID 1 TRIP branch (stage/pid1-hold-ts.sh; P-1 … P-8)

`pid1-hold-ts.sh` = the K1a-pinned `common/target/pid1-hold.sh` rev 5
(`4294c9d5…`) with every rev-5 line unchanged plus revision 6:

- **P-1 TRIP first.** Each iteration first reads the guard's heartbeat
  twice (`[ -f ]`, not a symlink, `read -r -t 1 <>`); TRIP in either read
  → P-2. Otherwise a record counts only if both reads agree and the state
  is `INIT|HOLD|READY|TRIP`; a torn or unknown record is **never** a reason
  to reboot by itself: it counts toward P-4's staleness only, and every
  guard-triggered reboot re-reads the record and powers off instead if it
  now shows TRIP (review M2). A FIFO or a missing file is ignored.
- **P-2** On TRIP PID 1 `exec`s `fs-poweroff-final` if it is a regular,
  executable, non-symlink file; otherwise `exit 1` → "Attempted to kill
  init" panic → `emergency_restart` without the reboot lock (F19).
  Nothing under `/run` or `/dev` is written on this path (the rev-5
  "reboot first" rule; review M3). **No forking fallback** (its fallback is `RESTART2 "bootloader"`, which stops
  the softdog and lands a hot device in ABL).
- **P-3** `FS_GUARD_REQUIRED=1` (a hold that depends on the guard): not
  READY by T0 + `FS_GUARD_READY_S` (30) → the reviewed reboot path.
- **P-4** Stale: heartbeat boottime more than 5 s behind `/proc/uptime`,
  or seq unchanged for 6 iterations → the reviewed reboot path.
- **P-5** Alive: `/proc/<guard pid>/stat` comm `(fs-thermald)`, state
  R/S/D, start time equal to the value first accepted (a forged READY
  record without the guard process fails, `req_forged_ready`).
- **P-6** Without `FS_GUARD_REQUIRED` the guard can only shorten the hold.
- **P-7** The deadline and backstop keep their rev-5 order after P-1; the
  two TRIP reads delay them by at most 2 s per iteration. Declared (ESD §6.1):
  a deadline or backstop reboot that wins a race with a trip lands in ABL.
- **P-8** Test: `tools/stage/test_pid1_trip.sh` (15 scenarios, reviewed
  stage-1 busybox `c2f279d1…` under qemu-aarch64, scaled deadline 16 s).

## 6. Test stand-ins (FS_TEST only)

| real call | stand-in |
|---|---|
| `open("/dev/watchdog")`, `WDIOC_SETTIMEOUT`, `WDIOC_KEEPALIVE` | `<root>/dev/watchdog` regular file; lines `settimeout N`, `keepalive` |
| `kill(1, 38)` | `kill(<fake PID 1>, 38)`; the fake PID 1 (`tools/testprogs/fakepid1.c`) logs every signal; `--test-pid1` must be > 1 |
| A1 `sync()` | 20 ms sleep (`sim/a1-hang`: never returns) |
| A2 `fs_poweroff_final()` | log `a2 poweroff-called`; `sim/a2-returns`: `_exit(0)` (a returned power-off), else `pause()` |
| RT hardening | skipped, logged |
| every other path | under `--root` |

Everything else is the production code: the forks, pipes, `waitid`, the
FIFO, the records, the stage step signals (a real process group,
`tools/testprogs/stepgroup.c`). In `--exec-sim` the supervisor prints an
`in …` line with the executor's inputs of each tick, so the Python
reference replays exactly those inputs (differential).

## 7. Build-time exclusions (tools/build.sh)

Product `fs-thermald.a64`: no `--trial-override`, `--batt-absent`,
`--sim`, `--test-pid1`, `--root `, `--test-row`, `--fst-scan`, `!HANG`,
`!EIO`. Trial build: has `--trial-override`. Log-only: no
`/dev/watchdog`, `/proc/sysrq-trigger`, `/dev/pmsg0`, `--trial-override`.
`test_tables.py`: `poweroff_cmd`, `restrict_cur`, `restrict_chg`,
`charge_control_limit`, `shutdown,thermal`, `RESTART2`, `force_failure`
in no binary; `sysrq-trigger`/`/dev/watchdog` only in executor builds.

## 8. Notice consumers (src/fs-noticed.c, src/warnscreen/)

- **fs-noticed (LED, R47):** polls the FSN1 record every 250 ms and
  updates the tri-LED every 50 ms through the existing LED write class
  (`/sys/class/leds/{red,green,blue}/brightness`; `leds-qti-tri-led`
  labels on pmxr2230, `v27.dts:21197-21226` [M-static]; no `pattern`
  trigger in the config, so the blink is written from userspace).
  Patterns (E-34): shutdown red 4 Hz (also when stale); warn amber 1 Hz;
  record stale > 5 s slow white; normal: unchanged. Idle priority.
- **fs-warnscreen (KMS, R46):** `fs-pattern` v0.7.1 (`99fc131b…`, the
  stage-3d display path) + `warn.patch` (46 lines: `main` → `fsp_main`,
  the picture → `warn_frame.h`, a new `main` in `warn_main.h`); the patched
  source must hash `300b035d…`. Every DRM step, bound and log record is
  fs-pattern's: `reset` once (stage 3d's r1), then `show-off-quad` per
  display, each in a child, held ≤ 10 s, then the fd is closed. **Static
  frame** (no animation, no re-commit): "SHUTTING DOWN / <REASON> / IN
  55 S / REMOVE HEADSET", "THERMAL WARNING / <REASON> / OFF IN 90 S", or
  "LAST SHUTDOWN / <REASON> / AT 52 C"; at most three displays (last
  shutdown, first warn, first shutdown), none after a shutdown display.
  Same levels as stage 3d (0x80 field, 0xFF text), per-eye roll 21° and
  eye swap. Offline: a frame fixture per reason (`test_consumers.py`).
  On a device: a new display operation in that composition (T5 package).
- **(b) SteamVR overlay:** not built (needs the SteamVR driver; §11).

## 9. Valve layer (valve/; V-1 … V-8)

Unit files and drop-ins as ESD §6.2: `fs-thermald-watch.service`
(installed into `sysinit.target`; heartbeat stale → one `kill(1, 38)`,
the supervisor's own request, so no logind/polkit or inhibitor path is
involved; review M6/m4), `fs-thermald-shutdown.service`
(`Conflicts=`/`Before=shutdown.target`, `ExecStop=` sends the `S` byte,
never blocks), `fs-thermald-ready.{service,target}`, `system.conf.d`
(watchdogs off, `DefaultTimeoutStopSec=10s`, `DefaultLimitRTPRIO=49`),
`poweroff/reboot/kexec.target.d` (`JobTimeoutSec=35s`),
`service.d/50-frameshift-caps.conf` (`~CAP_SYS_BOOT`,
`RestrictRealtime=yes`), `ReadOnlyPaths`, logind (no suspend), masks.
Checked statically and `fs-thermald-watch` is tested
(`tools/test_valve_units.py`). **The systemd 257.7 QEMU suite of ESD §7.1
is not done** (§11).

## 10. Disclosures required by FS-R-013 §7

**A software watchdog is not an independent hardware shutdown
guarantee.** The softdog is a kernel hrtimer (`softdog.c:137-138`, not
pinned to a CPU [M-static]). It does not fire if the kernel itself is
hung, if interrupts are masked on the CPU its timer is queued on, or if
that CPU was stopped by `smp_send_stop` during a power-off [C]; the
Quest 3 has no Linux-petted SoC watchdog (no `qcom,msm-watchdog` node,
F8 [M-static]; `qcom_wdt_core.ko` alone binds nothing). Its purpose is
narrower: to turn a dead or stuck **supervisor**, or a power-off path
that hangs in `device_shutdown()` with the timer still able to run, into
a restart within a bound (30 s running margin; `M_final` 30 s after the
final pet).

**Where resets land** (all [C] unless tagged):

| path | kernel effect [M-static] | landing |
|---|---|---|
| softdog expiry (default config) | `emergency_restart()`: no notifiers, no reboot lock; `reboot_mode` stays COLD (no panic notifier ran), so SCM's restart handler does not act and PSCI issues a cold `SYSTEM_RESET` (`softdog.c:117`, `reboot.c:66-71`, `qcom_scm.c:2656-2665`, `psci.c:298-312`) | the stock boot chain (a `fastboot boot` image is gone): Meta's Android. With dump mode armed, whether firmware enters crash-dump mode on this cold reset is **[O]** |
| `reboot(POWER_OFF)` by A2 or PID 1 (`fs-poweroff-final`) | reboot notifiers with a NULL command: `qcom-dload-mode` clears dump mode (`qcom-dload-mode.c:266-272`); softdog not stopped (only on `SYS_RESTART`/`SYS_HALT`, `watchdog_core.c:154-170`); `pm_power_off` = PSCI `SYSTEM_OFF` | off. If `pm_power_off` returns: caller ends with the reboot lock held (`reboot.c:347, 368`); A2 → the softdog (`M_final`) or P15; PID 1 → panic → `emergency_restart`. Note (review n3): `machine_power_off` has already masked IRQs on CPU0 and stopped the other CPUs (`process.c:147-153`), so whether the softdog timer can still fire after a returned power-off is [C] |
| sysrq `c` (P15, only after A2's return) | `panic()`; `PANIC_TIMEOUT=-1` → immediate `emergency_restart`; a dump-mode panic notifier sets WARM only if dump mode is armed (it was cleared by the power-off attempt) | normal boot [C] |
| PID 1 exits (P-2, missing helper) | panic → `emergency_restart` | normal boot, or crash-dump mode if dump mode is armed (no power-off began) |
| gate refusal | as `reboot(POWER_OFF)` | off |

**Crash-record and minidump effects.** Every path above writes nothing to
UFS by our code. Kernel-side: a panic (`sysrq c`, PID 1 exit) is recorded
by ramoops (`max_reason` = OOPS: PANIC and OOPS dumps; one 128 KiB dmesg
record; the console zone records continuously; `v27.dts:2573-2581`,
`ram.c:667-690, 781-785` [M-static]) in RAM only; our FST1 records are in
the same RAM (pmsg zone). `QCOM_MINIDUMP`, `_PANIC_DUMP` and `_PSTORE` are
enabled (stock and K1a): the minidump panic notifier registers the ramoops
regions (KCONSOLE/KDMESG/KPMSG) into the minidump table
(`minidump_log.c:1211-1240, 1333-1335`), so **if dump mode is armed** a
panic's minidump includes the pstore contents, our FST1 records included.
In the K1a composition `qcom-dload-mode.ko` is loaded by `insmod` without
arguments, so the stock cmdline's `qcom_dload_mode.download_mode=1` does
not apply and dump mode is disarmed at probe (`qcom-dload-mode.c:332-334`;
`kernel/module.c:4145` [M-static]) [C until read on the unit: the T0-K
row `download_mode`]. `emergency_restart` from the softdog does not dump
EMERG to ramoops (only PANIC/OOPS). The FST1 records contain a reason
code, a sensor name and temperatures: no identifier.

## 11. Open items and declared limits

| item | state |
|---|---|
| systemd 257.7 QEMU suite (ESD §7.1: softdog expiry, `RLIMIT_RTTIME`, `@` survival, `CAP_SYS_BOOT`, `JobTimeoutSec`, signal 38 → `poweroff.target`) | **not done** (no systemd VM here); the unit files are checked statically |
| qemu `-strace` fixtures of fs-metacfg and `fs-poweroff-final` | not done; `fs-poweroff-final` is proven from the disassembly |
| D-state helper test (nbd), C-side fuzzing of the JSON/LP/ext4 walkers, order-invariant property test, F7 (kmsg fan), recomputed skin cross-check | not done (PLAN §6 list) |
| suspend/resume (P10), BOOTTIME jumps, v2.7 fan resume inversion | not done; suspend is masked (V) and stage images do not suspend |
| thermal netlink poll-wake | not built; 1 s tick only |
| (b) SteamVR in-headset notification | not built (needs the SteamVR driver) |
| O19 limit on consecutive hot boots | open (the marker exists; the limit does not) |
| K5/K4 (R11) | open (FS-R-013 §7: K5 preferred) |
| the S1 guard with P16's fixed thresholds (`fs-tguard`) | not built; TS stage images run `fs-thermald --stage` with the full table as the guard |
| dump mode on a cold PSCI reset | [O] |

## 12. Internal adversarial review (2026-10-16)

Reviewer A (code, read-only, own WSL build): **GO-with-fixes**, no
BLOCKER, 6 MAJOR, 9 MINOR, 6 NIT. Applied: M1 (E-19), M2 (P-1), M3
(P-2), M4 (E-31), M5 (E-28), M6 (§9); m1 (E-5, E-28 text), m2 (E-10),
m3 (E-28), m4 (§9), m5 (install name), m6 (pmsg read in full), m7 (E-29
tmpfs), m8 (E-33 declared), m9 (assertions tightened: A2 death, the
heartbeat state, the LED stale blink); n1 (E-2), n2 (rev-5 line kept),
n3 (§10), n4, n5 (an LED is cleared when its pattern ends), n6 (the gate
creates no record). Declared, not changed: `x_stalled_consumers` checks a
design property (a pull record on tmpfs) and cannot fail on tmpfs by
construction; it stays as the regression guard of that property.

Delta check after the fixes (reviewer C, read-only, own build; all 11
aarch64 hashes reproduced): part 2 **GO**; every MAJOR/MINOR confirmed
fixed; its nits (the second PID 1 read cleared, P-7's 2 s bound, the E-28
order, the watcher refusing a PID ≤ 0) applied.
