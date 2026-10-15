# Quest 3 Unit 1: recovery procedure for the stage-2a, stage-3a and stage-3b images

**Scope.** This is the recovery procedure for one temporary `fastboot boot`
of `boot-stage2a.img` (experiment (i)), `boot-stage3a.img` (the display
test, trial (iii), spent) or `boot-stage3b.img` (trial (iii-b), FS-R-010) on
**Unit 1 only** (Quest 3, v66, slot A; never flashed).
It restates and completes FS-A-006 §5.4 for these images (fix round 6;
stage 3b added 2026-10-10: DEADLINE 200 s, the dwell gate, the temperature
procedure of FS-R-010 §6).

**Status.** Offline document. Nothing here authorises a device action; that
needs FS-A-007, the Chair, then the PM's live sign-off. *(Status 2026-10-10:
stages 2a and 3a are spent, in trials (i) and (iii).)* *(Status 2026-10-11:
stage 3b (trial (iii-b)) is concurred to execute by FS-R-011 §1 (J-104), once,
attended, on Unit 1; ~~not yet run~~ **run 2026-10-11 (J-107)**. FS-R-011 §1: AF stays immediate, followed by
Android recovery and a prompt AA; keep the scheduled follow-up even after a
below-40 °C first AA; at 40 °C or above act immediately under this procedure;
the manual fallback schedule is never a reason to wait while hot; physical
shutdown and unplugging are separate observations.)* Every outcome below
is **expected, not guaranteed**. Where an outcome rests on a derivation or
on a hypothesis, the table says so ([D], [C]).

**Captures.** BA and BF are the before-state captures (in Android and in
fastboot), AF and AA the after-state captures (fastboot, then Android). The
capture tooling is withheld from this copy; the method is private. Requires
an unlocked headset (assumed).

## 1. Before the attempt (the PM)

> **Never select "Switch Boot Slot" in the bootloader menu** (PM report: can brick; J-75). Use only the routes in §4.

| check | how | required |
|---|---|---|
| only Unit 1 is attached | `adb devices -l` (BA) | exactly one device, `QUEST3UNIT1` |
| Android up on slot A | `getprop ro.boot.slot_suffix` (BA) | `_a` |
| **battery** | `dumpsys battery` (BA) | level **> 50**, temperature **< 350** (tenths of °C, so < 35 °C). Otherwise do not start |
| before-captures complete | before/after state captures (tooling withheld; method private): BA, then BF in fastboot | BA complete **before** `adb reboot bootloader` |
| image and nonce fresh | `host/fs-observe.ps1 -Stage 2a|3a|3b -Image … -Preflight` | `preflight OK` |
| temperature, dwell (stage 3c and later: **one reading**, PM J-125; it replaced stage 3b's settled pair of `SIGNOFF.md` trial (iii-b) B) | `fs-checklist3c.ps1 -Phase B`, `SIGNOFF-3c.md` B | **one** `dumpsys battery` reading on **this unit** (`-R1Serial`), typed as read: three digits from 100 to 349 (below 35.0 °C), the battery **not charging** (status 3, 4 or 5; 2 charging and 1 unknown fail), its time the PC's UTC at the reading, **at most 900 s before BA**; BA10 itself below 350 with status 3, 4 or 5; the boot ≤ 300 s after BA started. All **enforced by the observer** (`fs-observe3c.ps1`) before any device action (else no boot; after the dwell cap an abandoned-cycle record, a new reading and new BA/BF) |
| the PM is present | watching the LEDs (and, for stage 3a, the lenses) | — |

## 2. The normal path (all three images: stages 2a, 3a and 3b)

1. **Boot.** `fs-observe.ps1 -Stage … -Image … -ConfirmNonce <nonce>
   -ThenCollect` (the PM's sign-off).
   - The image must be in `<repo>\build\stage<2a|3a|3b>\<stamp>-<nonce>\`.
     The one-attempt ledger is `<repo>\build\stage<2a|3a|3b>\attempted`.
   - Stage 3a: the collector prints "=== LOOK INTO THE LENSES NOW … ==="
     3 s before the pattern.
   - Stage 3b: `-BaSummary` and `-BfSummary` are required and the dwell gate
     applies (§1). The collector prints the two-period cue ("=== LOOK INTO
     THE LENSES NOW: a FIRST lit period … then a SECOND lit period … ===")
     3 s before `fs-display`; keep looking until the second (low) beep
     (`stage3b/IMAGE.md` §3, `host/COLLECTOR.md`).
   - It runs one `fastboot boot`, records Th, and waits for the gadget
     `FS-<nonce>`.
   - With `-ThenCollect` it then starts the collector.
2. **Collect.** `fs-collect.ps1` runs fs-verify, fs-ack, fs-status, the
   runner (`fs-valve` / `fs-display`) once, and then **`fs-done`**.
   - Stage 3a: after the record the host beeps (high), pauses 10 s
     read-only while the PM, still looking into the lenses, checks that the
     panels are dark (PM-OBS2), then beeps again
     (low) and sends `fs-done` (`host/COLLECTOR.md` §11).
   - Stage 3b: beep 1 (high) after both runs and the record, a 10 s
     read-only dark check, beep 2 (low), the per-eye/per-period report
     prompt (FSR1 lines), then `fs-done` (`stage3b/IMAGE.md` §3 step 6; `SIGNOFF.md` trial (iii-b) F).
3. **PID 1 reboots about 1 s after `fs-done`.** It execs
   `/bin/fs-reboot-final`, which does three things in order:
   1. `reboot(RESTART2, "bootloader")`: the device should come back in
      **fastboot** [D: the same cookie path as `adb reboot bootloader`;
      stage 1 returned to fastboot this way, M];
   2. only if that returns: `reboot(RESTART)`, a plain restart, so the
      device lands in **Android**;
   3. only if that returns too: sleep forever. PID 1 never exits, because a
      PID 1 exit is a kernel panic.
4. **After-captures.** In fastboot: AF, then
   `fastboot -s QUEST3UNIT1 reboot`. In Android: AA.
5. **Classify.** `fs-classify.ps1 -Stage … -CollectDir … -ObserveDir …`.
   The separate gates are the misc rule and the before/after state
   comparison (method private).

## 3. When the host does not finish: the PID 1 deadline

| image | deadline (PID 1 loop, exec of fs-reboot-final) | backstop (child: `sleep`, then fork-exec `fs-reboot` "bootloader", then `reboot -f`) | no ack | init error (`fail()`) |
|---|---|---|---|---|
| stage 2a | **T0 + 260 s** | T0 + 261 s | SHELL_READY + 150 s (magenta LED) | T0 + 60 s (red LED) |
| stage 3a | **T0 + 170 s** | T0 + 171 s | SHELL_READY + 150 s (magenta LED) | T0 + 60 s (red LED) |
| stage 3b | **T0 + 200 s** | T0 + 201 s | SHELL_READY + 150 s (magenta LED) | T0 + 60 s (red LED) |
| stages 3c, 3d | **T0 + 200 s** | T0 + 201 s | SHELL_READY + 150 s (magenta LED) | T0 + 60 s (red LED); stage 3d also refuses every module when the device's module index is not the pinned v2.7 one: no gadget, no LED, back in fastboot at T0 + 60 s |

- T0 is PID 1's start. It cannot come before `fs-observe.ps1` invokes
  `fastboot boot`; the observer records that moment as **BootStartUtc**
  (just before the call). So the device's earliest timer reboot is no
  earlier than BootStartUtc + DEADLINE. (Th, when `fastboot boot` returned,
  is not a safe lower bound on T0 and is kept as evidence only: FS-R-007 B1.)
- The host gives up 15 s before that, at BootStartUtc + DEADLINE − 15 s,
  counting the time it spent preparing (`host/COLLECTOR.md` §4).
- The ack window ends earlier. The host stops its pre-runner phases by
  BootStartUtc + 135 s, and refuses to start with less than 30 s of the window left.
- These timers are userspace. They **do not cover a kernel hang** (§5).
- Expected result of every timer path: the device comes back in
  **fastboot**, then the PM continues at §2 step 4.

## 4. Where the device lands, and what the PM does

| state the PM sees | action | expected outcome |
|---|---|---|
| `fastboot boot` failed (`FAILED (remote: …)`; DEVICE_REJECTED) or still in fastboot | `fastboot -s QUEST3UNIT1 reboot` | Android on slot A |
| **fastboot** after the attempt (the normal path, any timer path) | AF, then `fastboot -s … reboot`, then AA | Android on slot A [D] |
| **Android** directly, with no fastboot visit (the RESTART fallback ran, or an unexpected path was taken) | **AA first, including the misc capture** (before any further reboot writes misc). Then either record AF as INCONCLUSIVE, or make **one** documented extra `adb reboot bootloader` cycle for AF, whose own misc write is outside the attempt's comparison | the attempt's comparison is complete except AF, or AF is taken with the extra cycle on record |
| gadget never appears, LEDs stuck, no fastboot | the PM cannot see T0. Wait from **Th, the time `fs-observe.ps1` prints** ("fastboot boot returned … Th=…"): until **Th + DEADLINE + 60 s**. That is **Th + 320 s** for stage 2a, **Th + 230 s** for stage 3a and **Th + 260 s** for stage 3b. The 60 s covers however much later than Th PID 1 starts (T0 may also come before Th), plus the backstop. Still nothing: hold the power button about 15–20 s until the device is off [C, typical for Quest; release when the LED goes out], power on; if needed volume-down + power → fastboot → `fastboot -s … reboot` | [C] slot A boots as before |
| **dark or hung, including a kernel hang** (no SoC watchdog module is loaded; **no software watchdog** by decision J-49) | hold power until off, then power on; if needed volume-down + power → fastboot → reboot | [C] slot A boots as before |
| dark; USB `05c6:900e` (Qualcomm crash-dump / download mode: a panic with `download_mode=1`, `PANIC_ON_OOPS=y`). To spot it: Windows Device Manager shows a "QUSB_BULK"/"Qualcomm HS-USB" device, or `Get-PnpDevice -PresentOnly | Where-Object InstanceId -match 'VID_05C6&PID_900E'` returns it (read-only) | **do not use any flashing tool.** Hold power until off, then power on | [C] slot A boots. XBL may have written a minidump. That is **not** covered by the after-checks (RPMB/UFS attributes are not partition-visible either) |
| stage 3a: panels still lit after the record, at PM-OBS2 | note it; the collector still sends `fs-done` | the reboot ends it, about 1 s later. Without `fs-done`, the pattern may stay displayed until recovery; T0 + 170/171 s are intended reboot times, not guaranteed panel-off times; a hang, suspend or failed reboot leaves it to the manual route [O on v66; FS-R-007 §4]. A lit panel after fs-pattern closed the fd contradicts the source-derived close path [D] (`stage3a/IMAGE.md` §4) and is a finding |
| stage 3b: panels still lit after the record, at the dark check | note it (which run's pattern, which eye); the collector still sends `fs-done` | as stage 3a: the reboot ends it about 1 s later; without `fs-done` the bright pattern may stay displayed until recovery (T0 + 200/201 s are intended reboot times, not guaranteed panel-off times); a finding (`stage3b/README.md` §5) |
| back in Android, any route | AA, including `getprop ro.boot.bootreason` | recorded |

**Battery after the attempt (stage 3b: `SIGNOFF.md` trial (iii-b) F binds).**
- Stage 3b: AF **immediately** on return to fastboot, then `fastboot reboot`,
  then AA promptly. At **≥ 400 (40 °C)** start the shutdown/cooling procedure at
  once: power-menu power-off while connected, **physical observation** that the
  device is off (not standby; adb disappearing is not enough), then unplug. Take
  **at least one scheduled follow-up reading** even below 400, and record the
  **highest observed** reading. Do not restart only to read the temperature.
  The manual-route times above are an intended fallback schedule, not an
  instruction to wait while the headset heats.
- The AA battery reading records level, temperature and status.
- If the temperature is ≥ 400 (40 °C), or above the before-value by more
  than 50 (5 °C), the PM lets the device cool before any further step and
  records it.
- None of the three images drives the fan or runs a thermal engine (stage 2a
  §6A, stage 3a §4; stage 3b only reads the fan state, `stage3b/README.md` §5).

## 4a. Stage 3d (v2.7, both Quest 3 units)

Stage 3d runs on **either unit**, each on the same v2.7 build (J-131, J-133): every command names the unit
(`-Serial <serial>`, `adb -s <serial>`, `fastboot -s <serial>`); where §4 says `QUEST3UNIT1`, use the run's unit.
The deadline and backstop are stage 3c's (T0 + 200 s / 201 s). If no `FS-<nonce>` gadget appears and the unit is back
in fastboot about a minute after the boot, the image refused the device's module index (wrong build?) or init failed:
nothing ran; `fastboot -s <serial> reboot` and report (`stage3d/HOST.md` §2 item 11). The after-captures use the withheld after-capture tooling (identity and slot; no partition hashes on a user build).

## 5. What is not covered

- **A kernel hang or panic.** No userspace timer covers it, and there is no
  watchdog. The PM's manual route above is the only recovery. Its outcome
  is [C], expected, not guaranteed.
- **Persistent effects outside the captured partitions:** RPMB, UFS device
  attributes, an XBL minidump.
- **Thermal protection** beyond the kernel's own CPU mitigation maps (which
  do not prove adequate protection, FS-R-006 §4).
