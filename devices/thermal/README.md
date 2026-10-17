# devices/thermal: thermal and battery shutdown service (parts 1 and 2, offline)

FrameShift's `fs-thermald` (the single owner of fan, caps and the shutdown
decision) and `fs-metacfg` (the read-only reader of Meta's thermal
configuration from the user's own headset), per
`docs/research/emergency-shutdown-design.md` rev 5 and
`docs/research/thermal-control-design.md` rev 2 (PD-7, J-149).

**Status (2026-10-16):** part 1 merged (round-5 GO-with-fixes); **part 2
built on `feat/thermal-part2`, offline only**: the device executor
(softdog, A1/A2, `kill(1, 38)`, pmsg, sysrq; product, trial and log-only
builds), the PID 1 TRIP branch, the Valve layer, the notice consumers
(LED, static KMS warning frame, next-boot record), the PMIC class P7
(CORE-SPEC rev 7) and the v2.7 ADSP-name fix. Normative text:
[`EXEC-SPEC.md`](EXEC-SPEC.md) (with the FS-R-013 §7 disclosures: where
resets land, crash-record/minidump effects, the softdog is not an
independent hardware guarantee). Nothing has run on a device. The TS T0
package: `devices/quest3/ts/`.

| path | what |
|---|---|
| `PLAN.md` | design-to-code plan and requirement coverage |
| `EXEC-SPEC.md` | part 2: executor, PID 1 TRIP branch, Valve layer, consumers, disclosures (E-, P-, V- rules) |
| `src/thermald_exec.c`, `fst_record.c`, `fs-poweroff-final.c`, `fs-noticed.c`, `fs-thermald-watch.c`, `warnscreen/` | part 2 sources |
| `stage/pid1-hold-ts.sh`, `valve/` | the TS PID 1 hold with the TRIP branch; the Valve-layer units and drop-ins |
| `tools/sim/exec_scenarios.py`, `tools/stage/`, `tools/test_valve_units.py`, `tools/test_consumers.py`, `tools/ref/fst_ref.py`, `tools/check_poweroff.py` | part 2 suites and checkers |
| `METACFG-SPEC.md`, `CORE-SPEC.md` | normative specs (M-, A-, C-, K- rules) |
| `src/fs-metacfg.c` | the reader (production and `-DFS_TEST` variants) |
| `src/fs-thermald.c`, `thermald_core.c`, `thermald_accept.c`, `thermald_tables.c` | start-up, I/O, decision core, acceptance, tables |
| `tools/ref/` | independent Python references (core, reader) and their tests |
| `tools/fix/mkfix.py` | independent fixture writer (synthetic `super` images, invented values) |
| `tools/fix/wrap_super.py`, `tools/test_real_local.sh` | local-only differential on the real vendor images |
| `tools/sim/` | fake-sysfs harness, the 111 scenarios, the simulated fan (`fanmodel.py`) and the fan sweep (`sweep.py`) |
| `tools/test_metacfg.py`, `test_accept.py`, `test_tables.py` | reader, acceptance/spawn, table suites |
| `tools/build.sh`, `tools/run_all.sh` | build (native + pinned-clang static aarch64) and run everything |
| `tables/` | known-firmware rows (hashes) and derived tables (identifiers and thresholds only, J-123) |
| `fixtures/*/RESULTS.txt` | suite results of the committed revision |

Run (WSL): `bash devices/thermal/tools/run_all.sh [--local]`.

## Round-4 review fixes (rev 6, 2026-10-15)

- **Healthy fan, no false shutdown** (BLOCKER): the ramp credit on a
  target change uses the median of the last three tach readings (K-46);
  an F3 episode inside the allowance ends when the fan reads the level it
  missed (K-47), so noise or a slow spin-up cannot keep a timer alive
  through back-to-back allowances, while a stuck fan never ends it.
- **Failed fan reads** (MAJOR): F6 is a rate, 5 of the last 20 ticks
  (K-44); checks are held, not reset, on a tick without their readings
  (K-45), so a dead fan with flaky reads still trips at 36 s; the
  start-up self-test retries a failed fan read twice (K-48); F9's noise
  floor is 25 % (K-49).
- **Meta's values only from an established active view** (MAJOR,
  FS-R-012 §8): the reader refuses the Virtual A/B header flag, unknown
  header flags, a `cow` group, a `scratch` overlay, and `UPDATED` or
  unknown attributes on the active vendor partition (METACFG-SPEC M-11,
  M-12 rev 2); the supervisor then runs on the built-in table with the
  reason logged. **This is a deny-list of the signals visible in `super`,
  not a reading of the snapshot state:** the merge state on `metadata` and
  any COW files on `userdata` are not read, so an update whose LP metadata
  shows none of the signals would still be accepted (ESD R25, O27), but
  see the next bullet. The real-image test
  (`tools/test_real_local.sh`) wraps the OTA vendor images in a synthetic
  `super` (`tools/fix/wrap_super.py`); a real v2.7 `super` has not been
  exercised; the T0 `lpdump` probe settles its layout.
- **Virtual A/B devices always use the built-in table** (PM decision
  2026-10-15, METACFG-SPEC M-21a): a vendor `build.prop` with any
  `ro.virtual_ab.*` property not equal to `false` is refused
  (`reason=reader:vab-policy`); an unreadable `build.prop` is refused too.
  So every Quest 3 (and Quest 2) on v2.7 runs on the built-in table; the
  real-image test now expects the two v2.7 rows refused (C = Python) and
  v66 accepted. J-118's runtime path stays implemented for non-Virtual-A/B
  firmware (v66). Proving the update state from `metadata` is a possible
  later step, not planned. The built-in Quest 3 set equals the reviewed
  v66 file; v2.7 differs only in `usb-conn` LIGHT 70 °C, which P5 (T4 at
  70 °C, ours) already covers.
- **Declared limit (widened):** while demand alternates faster than the
  ramp, a fan stuck at any speed between the alternating targets is not
  an F3: half-periods up to about 7 s without tach noise, up to about
  8-10 s with +-2-5 % noise (a noisy high reading can end an early F3
  episode, K-47; scenario `rev6_noisy_stuck_limit_8s`). The tier floors
  end the alternation at LIGHT (SoC 89 °C) and the fan is caught there
  (sustained full load: F3 and trip 2 about 53 s after the load starts).
- **Healthy envelope:** rotor lag at most 1 s behind the driver ramp
  (a 2 s lag gave one false trip-2 shutdown in the round-5 review); T3a
  measures the lag on both units, and a lag above 1 s means the fan rules
  are revisited before TS.
- **Sweep** (`tools/sim/sweep.py`, `fixtures/sweep/RESULTS.txt`): 320
  healthy runs (ramps 100/500/2000 rpm/s and v66, noise ±0.5/±10 %,
  failed reads 0/2 %, 20 seeds each, demand alternating every 3–6 s,
  rotor lag up to 1 s and spin-up up to 2 s): no shutdown, no fan fault;
  120 dead/stuck/frozen/unreadable runs: every one shut down within its
  bound; all 440 runs C = Python.
