# fs-thermald decision core (normative spec, rev 1, 2026-10-14; rev 6, 2026-10-15: §19; rev 7, 2026-10-16: §20)

Implements the policy of `docs/research/emergency-shutdown-design.md`
(rev 5) §3.3, §4.1–§4.4, §5.1, §5.3 and §6.2 (gate) and of
`docs/research/thermal-control-design.md` §3.3, §4, §6.3–§6.4, with the
PM's rulings P1–P18 (P11 rejected: NORMAL caps are Meta's L4). Two
independent implementations follow this text: the C core
(`src/thermald_core.c`, production) and the Python reference
(`tools/ref/core_ref.py`, the oracle). They are compared tick by tick on
shared scenarios (`tools/sim/`). Where code and this file disagree, this
file wins.

Rule ids `C-n` are cited by the coverage table in `PLAN.md`.

## 0. Units and names

- Temperatures: integer milli-°C (m°C). Time: integer milliseconds on
  `CLOCK_BOOTTIME`. Integer arithmetic only.
- Severity slots 0…6: NONE, LIGHT, MODERATE, SEVERE, CRITICAL, EMERGENCY,
  SHUTDOWN. Tiers 0…5: NORMAL, NOTICE, THROTTLE, WARN, SHUTDOWN (graceful,
  "T4"), LASTRESORT ("T5"). Slot → tier: LIGHT 1, MODERATE 2, SEVERE 3,
  SHUTDOWN 4 (CRITICAL/EMERGENCY are never set in an accepted set).
- "For > X s": a condition true on consecutive ticks; its timer starts at
  the first tick it is true and fires on the first tick with
  `now − start > X`. Any tick where it is false resets the timer.

## 1. Configuration (`fs-thermald --dump-config`, JSON)

The core is driven by one configuration object, printed by the C binary
and read by the Python reference (so both use the same tables; the tables
themselves are tested separately against the design and Meta's files):

```
{"device","mode":"valve"|"stage","limits","reason","tick_ms":1000,
 "psy_period_ms", "adsp":bool,
 "groups":[{"name","class","min"}],
 "sensors":[{"name","class","group","kind":"zone"|"psy"|"aux",
             "slow":0|1,"indep":0|1,"th":[7 × int|null],"hy":[7 × int|null],
             "vin":[names]}],
 "fan":null | {"levels":[rpm…],"top","floor_p1","floor_tier":[6 × rpm],
             "rpm_per_sec","silent_rpm","max_pwm",
             "rules":[{"zone","base","trips":[{"t","h","lvl"}…]}]},
 "caps":{"cpu":[6 × kHz|"min"],"gpu":[6 × level]},
 "p5":{"sensor","t"} | null,
 "flags":{"trial_override","headless_fan","batt_absent","p15","j145"}}
```

Classes: `SOC`, `SKIN`, `BATT`, `USB`, `BOARD`, `AUX`. `th`/`hy` are the
**active** set (runtime Meta values if accepted, else built-in), already
resolved per sensor (the `psy` battery sensor carries its reference
sensor's values). `null` = unset.

## 2. Inputs per tick

```
t                       now (ms)
s[name]                 for every sensor of kind zone or aux: int m°C | ERR | ABSENT
psy                     {temp: int deci-°C | ERR, volt: int | ERR, curr: int | ERR,
                         cap: int % | ERR, status: Charging|Discharging|Not charging|
                         Full|Unknown|ERR}   (C-30 says on which ticks it is used)
usb_online              0 | 1 | ERR | ABSENT
adsp                    "running" | other text | ERR | ABSENT   (only if config adsp)
fan                     {rpm, pwm, cur, max: int | ERR} | ABSENT
fan_wr_err              bool: the previous tick's fan write failed
cap_fail                bool: the previous tick's cap write, read-back and the
                        cpuinfo_min fallback all failed
caps_ok_at_start        bool (first tick only): governor/caps written and read back
shutdown_byte           bool: a SHUTDOWN byte arrived (systemd shutdown detected)
pid1_comm               text: /proc/1/comm
a1_done                 bool: actuator A1 reported its sync finished
a2_exited               bool: actuator A2 exited (its power-off returned)
pstore_marker           bool (gate only): a T4/T5 marker of the previous boot
```

## 3. Sensor health (C-1 … C-9)

Evaluated for every sensor of kind `zone`, `aux` and (on psy sample ticks)
`psy`, in this order; the first match wins:

- **C-1** reading `ERR` or `ABSENT` → **fault `read`**.
- **C-2** value < −20000 → **fault `low`**.
- **C-3** frozen virtual sensor (sensor has `vin`): the value is identical
  to the one it had at `frozen_since`, `now − frozen_since ≥ 120000`, and
  any `vin` input has moved (max − min of its usable readings since
  `frozen_since`) > 1000 → **fault `frozen`**. `frozen_since` is reset to
  `now` (and the input min/max cleared) whenever the value changes.
- **C-4** value > 125000 → **anomaly `hot`**.
- **C-5** `slow` sensor, a previous numeric reading `(pv, pt)` exists, and
  `(v − pv) × 1000 > 10000 × (now − pt)` (a rise faster than 10 °C/s) →
  **anomaly `rise`**. `(pv, pt)` = the last numeric reading of this sensor
  and its time (updated on every numeric reading).
- **C-6** otherwise **healthy**.

AUX sensors are only inputs to C-3: their health is computed (C-1, C-2)
but they never fault, never count and have no thresholds.

- **C-7 Anomaly resolution.** A sensor that becomes anomalous while not
  already pending and not faulted becomes **pending** with `n = 0`. Each
  tick (including the detection tick) the sensor's class is checked
  for **contradiction**: at least one *other* sensor of the same class,
  `indep` = 1, healthy this tick, below its own SEVERE threshold, and no
  healthy `indep` sibling of that class at or above its SEVERE. (A sensor
  with no SEVERE set never contradicts.) Contradiction on any checked tick
  is remembered. At the tick where `n = 2` (two ticks after detection) the
  pending state resolves: contradicted → **fault `contra`**; else **T4
  latch `anomaly:<name>`**. `n` increases by 1 each tick after detection.
- **C-8 No independent sibling.** If the sensor is not `indep`, or no other
  `indep` sensor exists in its class: a `rise` anomaly whose value is below
  the sensor's SEVERE (or that has no SEVERE) → **fault `rise`** at once
  (not pending). Every other anomaly of such a sensor is pending as in C-7
  and can never be contradicted, so it latches T4 at `n = 2`.
- **C-9 Sensor fault lifecycle.** `fault_since` = the first faulted tick.
  The fault stays active until the sensor has been healthy (C-6) on every
  tick for **≥ 30000** ms; then it clears. While active (the recovery
  window included) the sensor counts as faulted (C-11) and its timer runs:
  `now − fault_since ≥ 120000` → **T4 latch `sensor:<name>`** (P9). A new
  fault while active keeps `fault_since`.

**Usable value:** a sensor's reading this tick is usable when it is healthy
(C-6). Pending and faulted readings are not usable (they never lower a
level, and a pending anomaly reaches T4 only through C-7).

## 4. Levels and tiers (C-10 … C-19)

- **C-10 Sensor level** (sensors with any set slot in 1…6), sticky
  `L ∈ {0} ∪ set slots`, `down_since`:
  - with a usable value `v`: `up = max{k set : v ≥ th[k]}` (0 if none).
    If `up > L`: `L = up`, `down_since = none`. Else if `L > 0` and
    `v < th[L] − hy[L]` (unset hy = 0): `down_since = now` if none; if
    `now − down_since ≥ 30000`: `L = max{k set, k < L : v ≥ th[k] − hy[k]}`
    (0 if none), then `down_since = now` if `L > 0` and
    `v < th[L] − hy[L]`, else none. Else (`v ≥ th[L] − hy[L]`):
    `down_since = none`.
  - without a usable value: `L` unchanged, `down_since = none`.
- **C-11 Groups and classes.** A sensor is *counted healthy* when its
  reading this tick is usable and it has no active fault. A group is short
  when fewer than `min` of its sensors are counted healthy. A class is
  **faulted** when any of its groups is short, or (BATT) C-12 says so.
  Class fault lifecycle as C-9 (clears after 30000 ms not faulted;
  `class_since` kept meanwhile): `now − class_since ≥ 120000` → **T4
  `class:<C>`**; **two or more classes faulted on the same tick → T4
  `classes`** at once.
- **C-12 Battery class** (config `adsp`: Quest 3) on top of C-11: `adsp` ≠
  `running` → faulted `adsp`; on psy sample ticks any psy field `ERR` →
  faulted `psy` (until the next sample tick without error); `temp`,
  `volt` and `curr` all unchanged for > 60000 ms (compared across sample
  ticks; the timer starts at the first sample where all three equal the
  previous sample) → faulted `stale` until any of the three changes.
  Without `adsp` (Quest 2) the psy rules apply, the ADSP rule does not.
  `batt_absent` (trial override only): the BATT class, its sensors and
  C-12 are skipped entirely.
- **C-13 P5:** the `p5` sensor usable and `v ≥ p5.t` → **T4 `p5`**.
- **C-14 P6/P13:** on psy sample ticks, `cap` ≤ 3 and `status` =
  `Discharging` → **T4 `p6`**; `cap` ≤ 10 and `Discharging` → `lowbatt`
  (a WARN contribution, held until a sample shows otherwise).
- **C-15 Contributions:** `want` = max over sensor levels (slot → tier),
  and at least 3 if any of: an active sensor fault, a pending anomaly, a
  faulted class, a fan fault, `lowbatt`, a failed self-test.
- **C-16 Other T4 latches:** any sensor level = SHUTDOWN (`shutdown:<name>`);
  fan fault for ≥ 120000 ms (`fan`); fan fault while any fan rule has a
  trip of index ≥ 1 active (`fan-trip2`, P8); `cap_fail` (`cap`); a failed
  self-test for ≥ 60000 ms without `trial_override` (`selftest`).
- **C-17 Tier.** If T4 is latched: tier = 4, or 5 once T5 started. Else
  `tier = want`, except that a tier of 3 is held until it has been shown
  for ≥ 30000 ms (`t3_since`, set when the tier becomes 3 from below).
  T4 latches on the first tick any trigger fires and is never cancelled.
- **C-18 T5 fast escalation (P12),** only while T4 is latched and T5 not yet
  started: a usable value with `v ≥ th[SHUTDOWN] + 5000` on a SOC sensor,
  `+ 2000` on BATT, `+ 3000` on SKIN → **T5 `p12:<name>`** now.
- **C-19 T4 reasons** are reported on the latch tick as the sorted set of
  every trigger that fired on that tick.

## 5. Fan (C-20 … C-26)

Only when the config has `fan` and `headless_fan` = 0.

- **C-20 Demand.** Per rule, trip `j` is active from the first tick the
  base sensor's usable value is ≥ `t_j` until a usable value is
  < `t_j − h_j`. Without a usable value the trip states are unchanged.
  Rule level = max `lvl` of its active trips (0 if none); demand level =
  max over rules; demand rpm = `levels[demand level]`.
- **C-21 Target.** `max(demand rpm, floor_p1, floor_tier[tier])`, clamped
  to `top`; `top` at tier ≥ 4, while not READY, and while a fan fault is
  active.
- **C-22 Allowance.** When the target differs from the previous tick's
  target (the first tick counts as a change from 0): `allow_until = now +
  15000 + ramp`, `ramp = |Δ| × 1000 / rpm_per_sec` (integer division) if
  `rpm_per_sec` > 0 and not (both old and new ≤ `silent_rpm`), else 0.
- **C-23 Immediate checks:** fan input `ABSENT`, any fan field `ERR`, or
  `fan_wr_err` → fault `F6` (**rev 6: F6 is a rate, ≥ 5 of the last 20
  ticks, K-44**); `cur > max` → fault `F1`.
- **C-24 Timed checks** compare the fan with the **previous tick's**
  target and run only while `now ≥ allow_until` (timers reset otherwise),
  never on the first tick (no target written yet): F2 `target > 0 and rpm = 0` for > 20000; F3
  `|rpm − target| > max(500, target × 15 / 100)` for > 45000; F4
  `pwm = max_pwm and rpm × 100 < 85 × target` for > 45000; F5 `rpm` equal
  to the previous tick's `rpm` and `target > 0` for > 30000 (its timer
  starts at the tick where the repeated value is first seen again).
- **C-25 Fan fault lifecycle:** as C-9 (30000 ms clear, `fan_since` kept),
  reported as the first code that raised it.
- **C-26** Fan absent with `headless_fan` = 1: no checks, no target
  (`fan=-`).

## 6. Caps (C-27, C-28)

- **C-27** CPU cap = `caps.cpu[tier]` (`min` = `cpuinfo_min_freq`), GPU
  level = `caps.gpu[tier]`; while not READY: the tier-3 values unless the
  tier is higher.
- **C-28** The I/O layer writes and reads back each tick; a mismatch or a
  write error makes it write `cpuinfo_min_freq`; if that fails too, it
  reports `cap_fail` on the next tick (C-16). A read-back that differs
  from our last write at the start of a tick is an ownership conflict:
  logged and re-asserted (I/O, not the core).

## 7. Self-test, READY, notices (C-29 … C-33)

- **C-29 Self-test** on the first tick: every zone/psy sensor of a counted
  class healthy (C-6), no class faulted, `caps_ok_at_start`, the fan
  present and readable (C-23 clean) and the config has `fan`, unless
  `headless_fan`; and an active set exists. Pass → event `ready`, READY = 1. Fail → event
  `notready:<first failed item>`, READY stays 0 for the run (C-15, C-16).
- **C-30 psy sampling:** psy is used on the first tick and on every tick
  with `now − last_sample ≥ psy_period_ms`; other ticks ignore `psy`.
- **C-31 P14:** on the T4 latch tick, `usb_online = 1` or psy status
  `Charging`/`Full` (last sample) → event `unplug`.
- **C-32 J-145:** on a psy sample tick with status `Charging` and `temp ≥
  300` (30.0 °C) → event `j145` (notice only; once per 60000 ms).
- **C-33 lowbatt notice:** event `lowbatt` when C-14's `lowbatt` starts.

## 8. Shutdown timeline (C-34 … C-40)

- **C-34 Anchor.** `tl0` = the first tick of: the T4 latch, a
  `shutdown_byte`, or `pid1_comm` = `systemd-shutdow` (each detected
  shutdown, design §5.1).
- **C-35 Valve mode:** at the T4 latch tick, action `signal-pid1` (once;
  not for a detected external shutdown, which systemd already runs). At
  `tl0 + 45000`: action `a1` (once) and, if T4 is latched, T5 starts
  (`t5:budget`). At `tl0 + 55000`: `final-pet` then `a2` (once).
- **C-36 T5 fast (C-18)** at tick `tf`: `a1` now (if not yet), and
  `final-pet` + `a2` at the first tick with `a1_done` or `now ≥ tf +
  10000`, but never later than `tl0 + 55000`.
- **C-37 Petting:** action `pet` on every tick before `final-pet`; none on
  or after it (the `final-pet` tick emits `final-pet` instead).
- **C-38 After A2:** `a2_exited` and `p15` → action `sysrq-c` (once).
  Nothing of ours calls `reboot()` again.
- **C-39 Stage mode** (S1 guard timeline, design §5.3): at the T4 latch
  `term-step`; at `tl0 + 2000` `kill-step`, `final-pet`, `trip`. No
  `signal-pid1`, `a1`, `a2`.
- **C-40** Actions fire at most once each, on the first tick at or after
  their time.

## 9. Gate (initramfs, design §6.2) (C-41 … C-44)

A pure function of the first tick's readings, the active set and
`pstore_marker`:

- **C-41** refuse `selftest` if C-29 fails; refuse `fault` if any sensor is
  faulted or anomalous.
- **C-42** refuse `hot:<name>` if any usable sensor with a SEVERE slot has
  `v ≥ th[SEVERE] − hy[SEVERE]`, or the P5 sensor has `v ≥ p5.t`; with
  `pstore_marker`: also if any usable sensor has `v ≥` its lowest set slot
  among LIGHT…SHUTDOWN.
- **C-43** refuse `p6` on `cap ≤ 3` and `Discharging`; `cap ≤ 10` and
  `Discharging` passes with a `lowbatt` warning.
- **C-44** with `j145` set: refuse `j145` if status is `Charging` and
  `temp ≥ 300`. Otherwise pass.

## 10. Output (one line per tick, both implementations)

```
t=<ms> tier=<0-5> ready=<0|1> fan=<rpm|-> cpu=<kHz|min> gpu=<lvl|-> f=<faults> e=<events> a=<actions>
```

- `faults`: sorted, comma-joined, `-` if none: `s:<name>:<read|low|frozen|contra|rise>`,
  `p:<name>` (pending anomaly), `c:<CLASS>`, `b:<adsp|psy|stale>`,
  `fan:<F1…F6>`, `selftest`.
- `events`: sorted, comma-joined, `-` if none: `ready`,
  `notready:<item>`, `t4:<reason>` (one per C-19 reason), `t5:<reason>`,
  `unplug`, `j145`, `lowbatt`.
- `actions`: sorted, comma-joined, `-` if none: `a1`, `a2`, `final-pet`,
  `kill-step`, `pet`, `signal-pid1`, `sysrq-c`, `term-step`, `trip`.
- `gpu=-` when the config has no GPU caps; `fan=-` under C-26 or without a
  fan in the config.

## 11. Evaluation order within one tick (both implementations)

1. psy sample decision (C-30).
2. Health of every sensor (C-1 … C-6), then the previous-reading and frozen
   trackers are updated with this tick's reading.
3. Anomalies: new detections, contradiction checks, resolution at `n = 2`
   (C-7, C-8); pending sensors then increment `n`.
4. Sensor fault lifecycle and timers (C-9).
5. Sensor levels (C-10).
6. Battery class (C-12), groups and classes (C-11).
7. Fan checks against the previous target (C-23 … C-25), then fan demand
   (C-20).
8. P5, P6, P13 (C-13, C-14).
9. Self-test on the first tick (C-29), or its fan item on a retry tick
   (K-48).
10. T4 triggers (C-7, C-9, C-11, C-13, C-14, C-16) → latch (C-19).
11. T5 fast escalation (C-18), also on the latch tick.
12. Tier (C-17).
13. Fan target and allowance (C-21, C-22).
14. Caps (C-27).
15. Timeline and petting (C-34 … C-40).
16. Events (C-29, C-19, C-31 … C-33) and the output line (§10).

Faults reported in `f=` are the state **after** step 10 (a fault cleared by
C-9 this tick is not shown; a pending anomaly resolved this tick is shown
as its result).

## 12. Tick file format (simulation and differential tests)

One JSON object per line (JSONL), one line per tick, ticks in time order:

```
{"t": 1000,
 "s": {"cpu-0-0-0": 41000, "pcb1-usr": "ERR", ...},   every zone/aux sensor, int or "ERR"/"ABSENT"
 "psy": {"temp": 312, "volt": 4012000, "curr": -350000, "cap": 80, "status": "Discharging"},
        any field may be "ERR"; the object is present on every tick (C-30 decides use)
 "usb_online": 0,                                      0/1/"ERR"/"ABSENT"
 "adsp": "running",                                    text/"ERR"/"ABSENT" (ignored without config adsp)
 "fan": {"rpm": 3700, "pwm": 120, "cur": 1, "max": 4} or "ABSENT"
 "fan_wr_err": false, "cap_fail": false, "caps_ok_at_start": true,
 "shutdown_byte": false, "pid1_comm": "systemd",
 "a1_done": false, "a2_exited": false}
```

Missing keys take these defaults: `fan_wr_err`, `cap_fail`,
`shutdown_byte`, `a1_done`, `a2_exited` false; `caps_ok_at_start` true;
`pid1_comm` `"init"`; `usb_online` 0; `adsp` `"running"`. The psy `temp`
is in deci-°C (×100 → m°C for the psy sensor). C-1 … C-10 run for the
psy sensor on sample ticks only; on other ticks every one of its states
(health class, usable value for C-11 counting and C-18, level, fault and
pending timers' inputs) is carried unchanged from its last sample tick,
and its C-7 `n` advances and its C-9/C-10 timers are evaluated only on
sample ticks (the C-9 T4 latch for the psy sensor fires on a sample tick).

## 13. Clarifications (rev 1a, binding for both implementations)

- **K-1 Fault and pending are independent.** A pending sensor (C-7) whose
  reading becomes `ERR`/low/frozen also gets a C-9 fault; the pending state
  still resolves at `n = 2`. A resolution to `contra` on an already faulted
  sensor keeps the existing `fault_since` and reason.
- **K-2 Fault reason** shown in `s:<name>:<reason>` is the reason that
  raised the fault (kept until it clears), like the fan code (C-25).
- **K-3 Health passes.** Step 2 runs C-1/C-2 for every sensor first, then
  C-3 for sensors with `vin` (using their inputs' health from that first
  pass: an input is usable when C-1/C-2 did not fire and, for non-AUX
  inputs, C-4/C-5 do not fire either), then C-4 … C-6.
- **K-4 Frozen tracker** (C-3) changes only on ticks where the virtual
  sensor's reading is numeric: if it equals `fz_val`, the inputs' usable
  readings of this tick are folded into their min/max and **then** the
  frozen condition is checked; otherwise `fz_val = v`, `frozen_since = now`
  and the min/max restart from this tick's usable input readings.
- **K-5 Rise tracker** (C-5): `(pv, pt)` is updated after the health
  checks with every numeric reading (anomalous ones included).
- **K-6 Contradiction** (C-7) uses this tick's health of the siblings:
  `healthy` = C-6 this tick (a sibling in a C-9 recovery window counts).
- **K-7 Class lifecycle** (C-11): the class is *active* from the first tick
  its condition holds until the condition has been false for ≥ 30000 ms;
  `c:<CLASS>` is shown while active; "two or more classes faulted" counts
  active classes. `b:<…>` tokens are shown while their condition holds.
- **K-8 C-12 details:** on a sample tick with all of `temp`, `volt`,
  `curr` numeric: if the previous numeric triple exists and equals this
  one, the stale timer starts (if not running) and `stale` holds once
  `now − start > 60000`; otherwise the timer and `stale` reset. The
  previous triple is the last all-numeric one. A sample with any field
  `ERR` sets `psy` (and leaves the stale state unchanged).
- **K-9 Self-test items** (C-29) are checked in this order and the first
  failure names the event: `sensor:<name>` (config order; zone/psy
  sensors of SOC, SKIN, BATT, USB, BOARD), `class:<CLASS>` (order SOC,
  SKIN, BATT, USB, BOARD), `caps`, `fan`.
- **K-10 Fan timers** reset on any tick with a fan input `ABSENT`/`ERR`
  (**rev 6: replaced by K-45, the checks hold instead**, §19).
  F5 compares with the previous tick's `rpm` only when that was numeric.
  The fan fault *condition* on a tick is: C-23 fires or any of F2…F5 has
  fired and its condition still holds.
- **K-11 Stage mode** ignores `shutdown_byte` and `pid1_comm` (PID 1 is
  ours); C-18 there sets tier 5 without actions; there is no `t5:budget`.
- **K-12 Valve-mode T5 events:** `t5:budget` (C-35) or `t5:p12:<name>`
  (C-18). `signal-pid1` is emitted on the T4 latch tick even when an
  external shutdown anchored `tl0` earlier. `sysrq-c` requires that `a2`
  was emitted earlier.
- **K-13 Gate** (`--gate`): the first tick is evaluated as a normal tick;
  `fault` refuses if any non-AUX sensor has an active fault or a pending
  anomaly after step 4; `hot:<name>` per offending sensor (psy included);
  reasons are sorted and de-duplicated. Output:
  `gate=<pass|refuse> reasons=<list|->` plus ` warn=lowbatt` if C-43 warns.
- **K-14** (rev 1b, after the independent implementation's report): (a) a
  fault raised on a tick never starts its 30 s recovery on that same tick;
  (b) C-8's immediate `rise` fault applies also while the sensor is pending;
  (c) `headless_fan` excuses only an **absent** fan: a present fan is
  targeted and checked as usual, and the self-test `fan` item passes only
  for a headless image whose fan is absent, or a config with `fan` and a
  clean C-23; (d) C-18 reports one `t5:p12:<name>` per sensor that crosses
  on that tick; (e) the budget T5 (C-35) starts in step 11, so that tick
  already shows tier 5 with tier-5 fan and caps; (f) C-43 warns
  `lowbatt` whenever `cap ≤ 10` and Discharging (also with `p6`);
  (g) the `j145` event (C-32) does not depend on `flags.j145`, which only
  arms the gate refusal (C-44); (h) `cpu=-` when the config has no caps
  (`caps` null), and `batt_absent` removes the BATT sensors and groups from
  the dumped configuration (P6/P13/J-145 still read psy).
- **K-15** (rev 1c, found by the simulation: raising the target to `top`
  after a fan fault starts a new allowance, which would otherwise clear the
  fault and defeat P8's 120 s escalation): a fan fault never clears on a
  tick inside the allowance (`now < allow_until`); such a tick resets the
  C-25 30 s clear timer. C-23's immediate checks still run there.
- **K-16** (rev 1d, found by the independent reference: with a 30 s clear,
  a fan stuck at a wrong speed or with a frozen tach clears between the
  F3/F5 windows and never reaches P8's 120 s): the C-25 clear window of a
  **fan** fault is **60000 ms** (longer than the longest timed check, F3/F4
  > 45 s), counted only on ticks outside the allowance (K-15).

## 14. PM decisions J-171 (rev 2, binding)

- **K-17 J-145 is a WARN (replaces C-32's "notice only").** On a psy
  sample tick with status `Charging` and `temp ≥ 300`, the condition
  `j145` starts; it holds until a sample shows otherwise (status not
  `Charging`, or `temp < 300`; an `ERR` sample keeps it). While it holds it
  is a WARN contribution (C-15, tier ≥ 3) and never a T4 trigger by
  itself. The `j145` event fires when the condition starts (replacing the
  60 s repeat). The gate refusal C-44 is unchanged.

## 15. User-visible notice (PM requirement J-171, rev 2)

Every tick the core emits one notice field, appended to the output line
as ` n=<notice|->`:

```
<severity>:<reason>[:<seconds>]      severity: warn | shutdown
```

- **K-18 When.** `shutdown` from the tick a shutdown is decided: T4 latched
  (reason from K-19) or, in valve mode, a detected external shutdown
  (`shutdown-requested`). Otherwise `warn` while the tier is ≥ 3 (reason
  from K-20). Otherwise `-`. Once `shutdown`, it never goes back.
- **K-19 Shutdown reason** = the mapping of the T4 latch reasons of the
  latch tick (C-19), the highest in the priority list below wins, and is
  kept afterwards: `shutdown:<name>` and `anomaly:<name>` → by the
  sensor's class (BATT `battery-overheating`, SKIN `skin-temperature-high`,
  SOC `soc-temperature-high`, USB `usb-connector-hot`); `sensor:<name>` →
  `battery-sensor-lost` for a BATT sensor, else `sensor-fault`;
  `class:BATT` → `battery-sensor-lost`; other `class:<C>` and `classes` →
  `sensor-fault`; `p5` → `usb-connector-hot`; `p6` → `battery-empty`;
  `fan`, `fan-trip2` → `fan-failure`; `cap` → `cap-write-failed`;
  `selftest` → `self-test-failed`.
- **K-20 Warn reason** = the highest-priority condition holding this
  tick: a BATT sensor at level ≥ SEVERE → `battery-overheating`; SKIN ≥
  SEVERE → `skin-temperature-high`; SOC ≥ SEVERE →
  `soc-temperature-high`; an active fan fault → `fan-failure`; the BATT
  class active or a BATT sensor fault → `battery-sensor-lost`; any other
  sensor fault or active class → `sensor-fault`; a pending anomaly →
  `sensor-anomaly`; a failed self-test → `self-test-failed`; `lowbatt` →
  `battery-low`; `j145` → `charging-too-warm`.
- **Priority** (highest first): `battery-overheating`,
  `skin-temperature-high`, `soc-temperature-high`, `usb-connector-hot`,
  `fan-failure`, `battery-sensor-lost`, `sensor-fault`, `sensor-anomaly`,
  `battery-empty`, `cap-write-failed`, `self-test-failed`, `battery-low`,
  `charging-too-warm`, `shutdown-requested`.
- **K-21 Countdown (seconds, integer, rounded up, never below 0).**
  `shutdown`, valve mode: until the planned A2 tick, `min(tl0 + 55000,
  tf + 10000 if T5 fast started)`; stage mode: until `tl0 + 2000`; `0`
  from that tick on, and `0` on and after the tick `a2` (stage: `trip`) is
  emitted even if earlier (A1 done, C-36). A T4 latch after a detected
  external shutdown replaces `shutdown-requested` by its K-19 reason (the
  countdown keeps the same `tl0`). `warn`: if the chosen reason has a running timer to
  T4, the time left on it (`fan-failure`: `fan_since + 120000`;
  `battery-sensor-lost` / `sensor-fault`: the earliest `fault_since +
  120000` or `class_since + 120000` among the faults that map to that
  reason; `self-test-failed` without `trial_override`: `t0 + 60000`);
  otherwise no `:<seconds>` part.
- **K-23** (rev 2a, after the reference's report): an `ERR` in any psy
  field keeps `j145` (K-17); a WARN held by C-17 after every condition has
  ended repeats the last warn reason without seconds (`sensor-fault` if
  there was none); a hot sensor of another class maps to
  `soc-temperature-high`, a USB sensor at >= SEVERE to `usb-connector-hot`.
- **K-22 The notice never changes the decision.** It is computed after
  step 16 from the state; it never delays or reorders an action (the A1/A2
  timeline stays authoritative, J-171 (f)).

## 16. Adversarial review fixes and Arbiter decisions J-172 (rev 3, binding)

- **K-24 Fan checks are not starved by the allowance (MAJOR-1).**
  (a) *Spin-up grace:* whenever the target changes from 0 to > 0 (the
  first tick counts, from 0), `spin_until = now + 15000`. **F2 and F5 run
  on every tick with `now ≥ spin_until`, inside or outside the ramp
  allowance**; inside the grace their timers reset. (b) *F3* outside the
  allowance is unchanged. Inside the allowance (and outside the grace) its
  condition is `rpm < lo − max(500, lo × 15 / 100)` with `lo = min(T,
  T_prev)`, `T` the target in force (the previous tick's) and `T_prev` the
  target in force before `T` (0 at start); false when `lo = 0`. The F3
  timer runs on as long as the condition of each tick holds, across the
  allowance boundary. (c) *F4* (Q4, J-172): `pwm = max_pwm` and
  `rpm × 100 < 85 × max_rpm` (config `fan.max_rpm`, Quest 3 DT 8500) for
  > 45000, outside the allowance only. (d) `ramp = min(60000, |Δ| × 1000 /
  rpm_per_sec)`. The I/O layer accepts a hwmon `rpm_per_sec` only within
  50…2000, else it keeps the table value (logged).
- **K-25 Fan zones (MAJOR-2).** A fan rule whose zone is missing, has
  fewer trips than the table, an unreadable trip, or trips (temperature or
  hysteresis) that differ from the table is a *zone fault*: the rule still
  drives demand with the table's trips, and C-23 raises fan fault **`F8`**
  on every tick (order F6, F8, F1, then F2…F5). The config carries
  `fan.zone_fault` (true/false). Fan control and the tach checks continue;
  the self-test `fan` item fails; P8 applies.
- **K-26 64-bit readings (MINOR).** Every arithmetic on readings is
  exact (64-bit in C). A reading outside int32 after scaling (psy `temp`
  × 100) is `ERR` (C-1).
- **K-27 Frozen non-virtual sensors (MINOR).** For zone sensors without
  `vin` and the psy sensor, classes SOC, SKIN, BATT, USB, BOARD: a tracker
  `(fv, fsince, ref0)`. `ref` = the maximum of this tick's usable (K-3
  sense) values of the **other** SOC sensors (none if there is no such
  value). On a numeric reading equal to `fv`: frozen (C-3 `frozen`) when
  `now − fsince ≥ 300000` and `ref` and `ref0` both exist and differ by
  more than 3000. Otherwise (different value, or the first reading):
  `fv = v`, `fsince = now`, `ref0 = ref`. Psy: sample ticks only.
- **K-28 Fail closed (MINOR).** A sensor level CRITICAL or EMERGENCY
  (unreachable for an accepted set) maps to tier 4, never 0. A-6 bounds
  BOARD sensors too (SHUTDOWN cap 125000).
- **K-29 Contradiction (Q5, J-172).** A sensor flagged `weak` in the
  config (Quest 3 `soc-usr`, which reads low) never counts as the
  contradicting sibling. No contradiction is recorded on a tick where any
  other `indep` sibling of the class has C-1/C-2/C-3 health or an active
  fault (tsens share one controller: a common-mode fault is a fault, not
  "cool").
- **K-30 Caps.** `caps.cpu` entries may be `null`: `cpu=-`, nothing
  written (Quest 2 T0–T2; T3–T5 `min`, J-172). The cpufreq policies come
  from the table. (I/O: a read-back at or below the requested value is
  accepted; an ownership conflict is a read-back above ours.)
- **K-31 cdev cross-check (TCD §3.3, MINOR).** With a fan in the config
  and numeric fan input: condition `cur ≠ demand level` (C-20, this tick);
  on the first tick with the condition held for > 10000 ms, event
  `cdev-mismatch` (once per episode; a tick without the condition ends it).
  Log only: no tier, no fault.
- **S-1 sysfs text (both the C I/O layer and the harness's reader):**
  trailing `\n` and spaces are stripped; a decimal integer with optional
  leading spaces and sign is numeric; anything else, an empty file, or a
  value outside int32 is `ERR`.
- **K-32** (rev 3a, the reference author's readings, confirmed): the
  int32 rule (K-26) applies to every tick integer, and a psy `temp` out of
  range is an `ERR` field everywhere (C-12 `b:psy` included); a level
  CRITICAL/EMERGENCY also latches T4 as `shutdown:<name>`; a `weak`
  sibling at or above SEVERE still blocks a contradiction, and weak
  sensors count as existing siblings for C-8; F4 falls back to the target
  when `fan.max_rpm` is absent; F3 does not run inside the spin-up grace;
  K-31's "numeric fan input" is all four fan fields; the K-27 reference
  includes any usable SOC sensor and the tracker changes only on numeric
  readings.

## 17. Delta review of rev 3 (rev 4, binding; supersedes K-27 and parts of K-24)

- **K-33 Stuck tsens (replaces K-27).** The frozen rule for non-virtual
  sensors applies **only to SOC-class zone sensors** (never the psy battery
  temperature, which C-12 covers, nor USB, BOARD, SKIN or BATT zones, whose
  0.1 °C steps legitimately stay flat for minutes). Same tracker and
  thresholds as K-27 (identical value for ≥ 300000 ms while the maximum of
  the other usable SOC sensors moved by more than 3000). Its fault reason
  is **`stuck`** (not `frozen`), shown `s:<name>:stuck`; it escalates like
  any sensor fault (C-9: WARN now, T4 after 120 s), **but a sensor whose
  active fault reason is `stuck` counts as healthy for the two-class
  instant shutdown** (C-11 "two or more classes"): a class faulted only
  through `stuck` sensors does not count there. (The class's own 120 s
  rule still applies.)
- **K-34 `fan-trip2` debounce.** The C-16 `fan-trip2` latch requires, on
  that tick, an active fan fault **and** either a current fan condition
  other than F6 (C-23 F8/F1 firing, or F2…F5/F9 fired and still holding),
  or the F6 condition held on every tick for ≥ 5000 ms (`f6_since` = the
  first tick of the current unbroken F6 streak). A transient F6 still
  raises the fan fault (WARN, fan top) and the 120 s P8 rule is unchanged.
- **K-35 Tach plausibility F9.** With numeric fan input, a tick is
  *implausible* when `rpm < 0`, or `rpm > max_rpm × 12 / 10` (if
  `max_rpm` > 0), or, with `rpm_per_sec` > 0 and a numeric previous
  reading at `pt`, `|rpm − prev_rpm| × 1000 > 2 × rpm_per_sec × (now −
  pt)` unless both `rpm` and `prev_rpm` are ≤ `silent_rpm` (the driver's
  jump). Five consecutive implausible ticks → C-23-style fault code
  **`F9`** (held while the streak continues; order F6, F8, F1, F2, F3,
  F4, F5, F9). The streak resets on a plausible tick or a fan `ERR`.
- **K-36 F3 inside the allowance (replaces K-24 (b)).** Let `t_change` be
  the tick of the last target change, `T` the target in force and
  `T_prev` the one before. Inside the allowance and outside the spin-up
  grace: rising (`T > T_prev`): `e = T` if `rpm_per_sec` = 0 or both
  `T_prev` and `T` ≤ `silent_rpm`, else `e = min(T, T_prev + rpm_per_sec
  × max(0, now − t_change − 1000) / 1000)`; condition `rpm < e − max(500,
  e × 15 / 100)`. Falling (`T < T_prev`): condition `rpm < T − max(500,
  T × 15 / 100)`. **Inside the allowance a false condition holds the F3
  timer (neither runs it on from a reset nor resets it); only a tick
  outside the allowance with `|rpm − T| ≤ tol(T)`, the spin-up grace, or a
  fan `ERR` resets it.** (**Rev 6:** a reading at or above the level the
  fan missed also resets it, K-47; a fan `ERR` holds it, K-45.) F3 fires on any tick (held ones included) once a
  running timer has passed 45000 ms (`now − f3 > 45000`), and holds while
  the timer runs. Outside the allowance F3 is unchanged.
- **S-2 cap read-back** (I/O) parses with S-1: a non-numeric read-back is a
  failure, never a success.

## 18. Final delta review (rev 5, binding; amends K-33…K-36)

- **K-37 Ramp bound from the measured rpm (BLOCKER).** In K-36 the rising
  bound starts from `base = min(T_prev, r0)`, where `r0` is the fan `rpm`
  read on the tick the target changed (if that reading was not numeric:
  the last numeric `rpm` of an earlier tick, else 0):
  `e = min(T, base + rpm_per_sec × max(0, now − t_change − 1000) / 1000)`.
  **The same bound replaces K-36's falling rule:** for a falling target
  (`T < T_prev`) too, `e = min(T, base + rpm_per_sec × max(0, now −
  t_change − 1000) / 1000)` (so a fan still ramping up from below the new,
  lower target is judged by its ramp, not by `T − tol`; a fan above `T`
  has `base ≥ T` and gets `e = T` at once). `e = T` when `rpm_per_sec` = 0
  or both `T_prev` and `T` are ≤ `silent_rpm`. Everything else in K-36
  stands (a fan stuck at the lower target still has `r0 = T_prev`).
- **K-38 F9 noise floor and persistence (replaces K-35's rate test and
  streak).** The rate test is `|rpm − prev_rpm| > 2 × rpm_per_sec ×
  (now − pt) / 1000 + max(500, prev_rpm × 15 / 100)` (integer division,
  previous reading from the **previous tick only**: after a fan `ERR`
  tick there is no previous reading); the range test and the silent jump
  exemption are unchanged. F9 holds while at least **3 of the last 5**
  ticks with numeric fan input were implausible; a fan `ERR`/`ABSENT` tick
  clears that history. The floor is provisional until T3a measures the
  tach noise.
- **K-39 Two-class rule per episode (K-33).** Each class fault episode
  (from `active` set to `active` cleared) carries a flag set on any tick
  whose condition holds with stuck-faulted sensors counted healthy; only
  active classes with that flag set count toward "two or more classes",
  the recovery window included.
- **K-40 Stuck = tsens only and latched.** K-33 applies to SOC-class zone
  sensors that are not `weak` (`soc-usr` is an ADC thermistor). Once a
  sensor is stuck, its health stays `stuck` on every reading equal to the
  stuck value, whatever the reference does, until the value changes.
- **K-41 Fan liveness counts failed reads.** K-34's F6 qualifier becomes:
  the F6 condition (C-23 F6) held on **at least 6 of the last 10 ticks**
  with a fan in the config (a success does not reset it); an unbroken 5 s
  streak (6 ticks) still qualifies on its 6th tick.
- **K-42 Edge readings confirmed (J-172 Arbiter):** the per-episode flag
  (K-39); F9's previous reading is the previous tick only (K-38); the
  K-36 hold as amended by K-37; ABSENT resets the F9 history; F4 inside
  the allowance resets its timer; a headless image with the fan absent
  has no F6 qualifier.
- **K-43 Continuous ramp expectation (replaces the bound `e` of K-36/K-37).**
  The core keeps an expected minimum fan speed `x` (initially 0):
  - *on a target change* (step 13, new target `Tn`, rpm `r0` as in K-37):
    `x = Tn` if `rpm_per_sec` = 0 or both the old target and `Tn` are ≤
    `silent_rpm` (the driver jumps); else if `Tn < x`: `x = Tn`; else
    `x = max(x, min(r0, Tn))` (a fan ahead of the expectation is credited,
    the expectation is never lowered by a slow fan);
  - *each tick in step 7 before the F3 check*, inside the allowance and
    outside the spin-up grace: if `now − t_change > 1000`,
    `x = min(T, x + rpm_per_sec × (now − t_last) / 1000)` with `t_last` the
    previous tick's time; if `T < x`: `x = T`. Outside the allowance:
    `x = T`. `x` depends only on time and the targets: it is updated this way
    on every tick with a fan in the config except the first, fan `ERR`
    ticks included; `t_last` is the previous tick's time.
  - **Declared limit (K-43, widened in rev 6):** with targets alternating
    faster than the ramp (for example 3700/5500 every 6 s at 100 rpm/s) a
    healthy fan gains less than the F3 tolerance in each half-period, so a
    fan **stuck at any speed between the alternating targets** (the lower
    target included) stays within tolerance of the expectation and is not
    an F3 while the alternation lasts. The backstop is the tier floors:
    SoC 89 / 92 / 95 °C (LIGHT / MODERATE / SEVERE) floor the target at
    4500 / 5000 / 5500, so the low target (3700) cannot recur once the SoC
    reaches LIGHT; the alternation ends and the stuck fan is caught there
    (under sustained full load: F3 and then `fan-trip2` about 53 s after
    the load starts at 100 rpm/s, scenario
    `rev5_fast_alternation_stuck_3700`, sweep `stuck3700-load` 48-56 s).
    The limit holds up to about 7 s half-periods without tach noise and
    up to about 8-10 s with +-2-5 % noise (K-47, §19;
    `rev6_noisy_stuck_limit_8s`).
    F2/F5/F9 still apply throughout. The tolerance is revisited with the
    T3a measurements.
  - Inside the allowance F3's condition is `rpm < x − max(500, x × 15 /
    100)`; the K-36 hold rule (rev 6: K-47) and firing rule stand. So a fan stuck below
    alternating targets is caught however fast the demand alternates,
    while a healthy fan ramping at `rpm_per_sec` stays above `x`.

## 19. Round-4 review fixes (rev 6, binding; amends C-23, C-29, K-10, K-36, K-37, K-38, K-41)

The round-4 adversarial review (NO-GO, J-179) found two false-shutdown
paths on a **healthy** fan: (1) tach noise or a slow spin-up under demand
alternating every 3-6 s: one high reading on a target-change tick raised
the expectation `x` (K-37/K-43), the next low reading started F3, and the
K-36 hold kept that timer alive through back-to-back allowances until F3
and `fan-trip2`; (2) 0.5-2 % failed fan reads: every failed read raised F6
at once, and a fault that is re-raised before its 60 s clear reaches P8.
And a dead fan whose reads failed now and then lost its F2/F5 timers on
every error (K-10), so trip 2 came 120 s late. The rules below fix the
mechanisms; a false shutdown on a healthy fan is a defect like a missed
one.

**Healthy-fan envelope assumed (and swept, `tools/sim/sweep.py`):** driver
ramp 0 (v66) or 100-2000 rpm/s; the rotor follows the driver's setpoint
with a lag of **at most 1.0 s** (swept 0.3-1.0 s) and at least 900 rpm/s
(an 1800 rpm step within about 2 s); tach noise up to +-10 % per reading;
up to 2 % failed reads; demand alternating 3700 <-> 5500 every 3-6 s.
**Outside the envelope the rules are not shown safe against a false
shutdown:** the round-5 review found one false `fan-trip2` at 126 s with
a 2 s rotor lag, 100 rpm/s and +-10 % noise (0 of 24 runs at a lag of
1.5 s or less). The T3a measurements check this envelope on both units,
the rotor lag first; a measured lag above 1 s means K-43/K-47 are
revisited before TS.

- **K-44 F6 is a rate (replaces C-23's immediate F6).** The C-23 *tick
  condition* (fan input `ABSENT`, any fan field `ERR`, or `fan_wr_err`) is
  kept for the last 20 ticks with a fan in the config (a headless absent
  tick counts as no failure, K-42). The F6 fault condition holds on a tick
  when the tick condition held on **at least 5 of the last 20 ticks** (this
  one included). Isolated failures are not a fault: at 2 % the chance of 5
  in 20 is about 4e-5 per tick, and such an episode clears normally
  (60 s, K-15/K-16). A persistently failing fan still escalates: F6 on its
  5th failed tick (4 s), `fan-trip2` on the 6th at the 2nd fan trip (K-41,
  now counted on the same history's last 10 ticks: unchanged 6 of 10), P8
  120 s after F6 otherwise. Order of codes unchanged (F6, F8, F1, F2, F3,
  F4, F5, F9). F1 needs only `cur` and `max` numeric.
- **K-45 A check runs on the readings it needs (replaces K-10's reset).**
  F2, F3 and F5 need a numeric `rpm`, F4 a numeric `rpm` and `pwm`. On a
  tick without them the check is **held**: its timer neither starts nor
  resets, and it fires (and still holds, K-10, K-34) once a running timer
  has passed its limit. So intermittent read errors no longer reset dead-
  or stuck-fan detection: a dead fan gets F2 and trip 2 at 36 s from boot
  (15 s grace + 20 s) however its reads fail in between. F5 compares with
  the **last numeric `rpm`** of an earlier tick, whatever the other fields
  (this settles the round-4 C != Python divergence on a tick where `rpm`
  reads and `pwm` fails: the reference's reading was right). Timers still
  reset on the first tick and inside the spin-up grace (K-24 a), F4 inside
  the allowance (K-42).
- **K-46 Robust ramp credit (amends K-37/K-43).** `r0` on a target change
  is the **median of the numeric `rpm` readings of the last three ticks**
  (this one included; with two readings the lower, with one that one; with
  none the last numeric `rpm` of an earlier tick, else 0). One noisy high
  reading no longer raises `x`. The rest of K-43 stands.
- **K-47 F3 episodes end when the fan shows the missing speed (replaces
  the K-36 hold).** With the F3 timer the core keeps `need` (0 when no
  timer runs): on a tick whose F3 condition holds on the **low** side,
  `need = max(need, level)` with `level = x − tol(x)` inside the
  allowance or `T − tol(T)` outside it (`tol(v) = max(500, v × 15 /
  100)`). On a tick whose condition is false: outside the allowance the
  timer resets (as before, the reading is within `tol(T)` of `T`); inside
  it the timer resets when `rpm ≥ need`, and is otherwise held (neither
  starts nor resets, fires once past 45000 ms). A healthy fan that dipped
  below the expectation once (noise, lag) reaches the level it missed on
  a following tick and ends the episode, so no timer survives back-to-back
  allowances on healthy behaviour. A stuck or slow fan never shows `need`
  (it is the highest level it failed, and grows with the expectation), so
  the timer runs on across allowances as K-36 intended: a fan stuck at the
  lower target under slow alternation (20 s) still gets F3 before 90 s
  (`review2_stuck_lower_of_alternating`), stuck at 4500 under the 5000/5500
  wobble too (`rev5_wobble_stuck_4500`). With tach noise `p`, a fan stuck
  at `s` may end an early episode with a high reading, but only while
  `need < s × (1 + p)`; once the expectation passes that, the episode is
  locked (sweep `stuck2500-alt`, `stuck3700-load`). **This widens the
  declared limit of K-43 with noise:** noise-free, a fan stuck between the
  targets escapes F3 for half-periods up to about 7 s at 100 rpm/s; with
  +-2-5 % noise, a fan stuck at 3700-4300 rpm can also escape at about
  8-10 s half-periods (the expectation must climb past `s × (1 + p)` plus
  the tolerance before an episode locks). The tier floors still bound it:
  at LIGHT the alternation ends and the fan is caught
  (`rev6_noisy_stuck_limit_8s`: stuck at 4000 with +-5 % noise, 8 s
  alternation, no fan fault; at 89 °C F3 and trip 2 within 60 s). The spin-up grace, the
  first tick and an outside in-tolerance reading reset `need` with the
  timer. Firing (K-36) is unchanged.
- **K-48 The self-test fan item retries a failed read (amends C-29,
  K-14 c).** On the first tick, when every earlier item passes and the fan
  item would fail only through the C-23 tick condition (no other fan code
  holds), the decision is deferred: the fan item is evaluated again on the
  next two ticks; `ready` on the first of them without the condition (and
  without a fan code), `notready:fan` when it holds on all three ticks or a
  fan code holds on a retry tick. Until then `ready = 0` (fan top, caps of
  T3, no event); `t0` stays the first tick. The gate (K-13) is evaluated on
  the first tick and so never refuses on a single failed fan read. Without
  this, a fan with 2 % failed reads would fail the self-test (and shut down
  60 s later) on 2 % of boots.
- **K-49 F9 noise floor (amends K-38).** The rate test's floor is
  `max(500, prev_rpm × 25 / 100)` (was 15 %): with +-10 % noise two
  consecutive readings of a steady fan differ by up to 20 % of its speed,
  at least 22 % of the previous reading. Random readings 0-9000
  (`review2_tach_noise_f9`) are still implausible. F9's previous reading
  and history otherwise stay as K-38 (cleared by a tick with any fan field
  `ERR`).
- **S-3 Sweep (tests).** `tools/sim/sweep.py` drives the C binary with
  the simulated fan of `tools/sim/fanmodel.py` and replays every run
  through the reference: the healthy envelope above (4 ramps x noise
  +-0.5 / +-10 % x failed reads 0 / 2 %, 20 seeds each, 200 s, drawn
  half-period and rotor dynamics) must give no shutdown and no fan fault;
  dead, stuck, frozen and unreadable fans (20 seeds each, random ramp,
  noise and failure rate) must shut down within: dead at the 2nd trip
  38 s, dead below it 158 s (P8), stuck at 2500 under alternation 69 s,
  stuck at 3700 then sustained 89 °C 62 s after the load, frozen tach 32 s
  after its first repeat, unreadable 5 s after the first failure. Results:
  `fixtures/sweep/RESULTS.txt`.

## 20. PMIC die temperatures, P7 (rev 7, binding; thermal part 2; PM J-171 Q3, PLAN R50)

The PM ruled (J-171 Q3) that the PMIC die temperatures are required before
READY. P7 (approved, J-122): a PMIC die at 95 °C is SEVERE, at 115 °C
SHUTDOWN (`thermal-control-design.md` §5.2, option A: the
`qcom-spmi-temp-alarm` driver is not loaded, so these are read through the
ADC's IIO channels instead; EXEC-SPEC.md E-33 says how).

- **K-50 Class `PMIC`.** A seventh class `PMIC` (dump-config `"class":
  "PMIC"`). Its sensors have `"kind":"iio"`. For the core, `iio` is
  exactly `zone`: one reading per tick, `int m°C | ERR | ABSENT`, in the
  tick file's `s` object under the sensor's name, with every rule that
  applies to a `zone` sensor (C-1 … C-11, C-15 … C-19, K-1 … K-49), except
  the rules that name the SOC class or `tsens` (K-33/K-40 stuck rule: SOC
  only, unchanged). `slow` = 0, `indep` = 0 (the dies are different
  chips, not siblings: the no-sibling rules of C-7/C-8 apply), no `vin`.
- **K-51 Thresholds (ours, never Meta's).** SEVERE 95000 with hysteresis
  5000; SHUTDOWN 115000 with hysteresis 5000; every other slot unset. They
  are the built-in values whether Meta's runtime set is accepted or not
  (the JSON has no PMIC sensor; A-7 coverage does not include them).
  CRITICAL/EMERGENCY stay unset (K-28 unchanged).
- **K-52 Group and counts.** One group `pmic` (class PMIC) whose minimum
  healthy count is the number of PMIC sensors in the table (every die is
  required: a die that is not read is a PMIC that is not watched). On the
  Quest 3: 7 (`pmk8550_die_temp`, `pmxr2230_die_temp`,
  `pm8550vs_c_die_temp`, `pm8550vs_d_die_temp`, `pm8550ve_die_temp`,
  `pm8550b_die_temp`, `pm8550b_lite_die_temp`; the DT channel labels of
  `vadc@9000`, `v27.dts:20777-20886` [M-static]; confirmed on each unit at
  T0). The Quest 2 table has none (its 4.19 temp-alarm driver keeps the
  PMIC's stage 2, `thermal-control-design.md` §8; P7 there is [O]).
- **K-53 Self-test (amends K-9).** The item order is `sensor:<name>`
  (config order; zone, iio and psy sensors of SOC, SKIN, BATT, USB, BOARD,
  PMIC), `class:<CLASS>` (order SOC, SKIN, BATT, USB, BOARD, PMIC),
  `caps`, `fan`. So no Quest 3 configuration is READY without every PMIC
  die readable and healthy.
- **K-54 Notice (amends K-19, K-20, K-23 and the priority list).** A new
  reason `pmic-hot`: K-19 maps `shutdown:<name>` and `anomaly:<name>` of a
  PMIC sensor to `pmic-hot`; `sensor:<name>` of a PMIC sensor and
  `class:PMIC` map to `sensor-fault` (as any non-BATT class). K-20: a PMIC
  sensor at level ≥ SEVERE → `pmic-hot`. K-23's "a hot sensor of another
  class maps to `soc-temperature-high`" no longer applies to PMIC.
  Priority: `battery-overheating`, `skin-temperature-high`,
  `soc-temperature-high`, **`pmic-hot`**, `usb-connector-hot`, then
  unchanged.
- **K-55 Unchanged:** C-18 has no P12 delta for PMIC (a PMIC sensor never
  starts a fast T5); C-42's gate applies to PMIC sensors like any sensor
  with a SEVERE slot; no fan rule uses a PMIC sensor; caps follow the tier.
