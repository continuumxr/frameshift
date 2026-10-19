# Quest 3 K1g: recovery procedure (our kernel with the boot-chain write guard; Unit 2 first, then Unit 1)

**Scope.** One temporary `fastboot boot` of a reviewed `boot-k1g.img` (`k1g/README.md`) on one Quest 3 unit on v2.7
(user build, slot A; never flashed). This file is the K1g counterpart of `RECOVERY.md` §4b (K1a). `RECOVERY.md` itself
is pinned in the Chair-concurred K1a sign-off and is **not edited**; where this file says "as `RECOVERY.md` §n", that
section applies unchanged with the K1g scripts (`host/*-k1g.ps1`) and the run's unit.

**Status.** Offline document (2026-10-16). Nothing here authorises a device action: that needs the Chair's ruling on
the concrete K1g package, both K1a attempts done, and the PM's live sign-off. Every outcome is **expected, not
guaranteed**; tags as in `RECOVERY.md` ([D] derivation, [C] hypothesis).

> **Never select "Switch Boot Slot" in the bootloader menu** (PM report: can brick; J-75). Use only the routes below.
> **Never use any flashing, EDL or crash-dump collection tool.**

## 1. Before the attempt

As `RECOVERY.md` §1 with the K1g checklist (the K1g sign-off tooling (private) phases A, B, E; the K1g sign-off sheet (private)): the named unit
only, Android up on slot A, the single-reading admission rule (battery above 50 %, status 3/4/5 below 35 °C or status
2 below 30 °C, at most 900 s old and before BA, this unit), BA/BF, presence, the typed nonce, the BA-to-boot dwell
≤ 300 s, and this unit's readback precondition (the K1a walkthrough (private) step 0b).

## 2. The normal path

1. **Boot:** `fs-observe-k1g.ps1 … -ThenCollect` runs one `fastboot boot`, records **BootStartUtc** (just before the
   call) and **Th** (when it returned; printed as `Th=`), and waits for the gadget `FS-<nonce>`.
2. **PID 1** (our `init.sh`): the deadline file first (T0 + 200 s), the 95 stock modules, then **the guard proof once**
   (at most 25 s, stopped by fs-supervise at 25 s, killed 2 s later), then the ACM gadget and the host shell.
3. **Collect:** `fs-collect-k1g.ps1`: fs-verify, fs-ack, fs-status, `fs-k1g <challenge>` once (only before
   BootStartUtc + 53 s), then **fs-done**. PID 1 reboots about 1 s later into **fastboot** (`RECOVERY.md` §2 step 3).
4. **After:** AF immediately, `fastboot -s <serial> reboot`, AA promptly, the follow-ups at about +5 and +10 minutes
   after the end of AA (continuing while rising or concerning), phase F, then `fs-classify-k1g.ps1`.

## 3. The timers (unchanged from K1a)

| timer | when | what happens |
|---|---|---|
| deadline (PID 1 loop) | **T0 + 200 s** | exec of fs-reboot-final: fastboot, else a plain restart into Android |
| backstop (child) | T0 + 201 s | fs-reboot "bootloader", then `reboot -f` |
| no host ack | SHELL_READY + 150 s | as the deadline |
| init error (`fail()`) | T0 + 60 s | as the deadline (red LED) |
| the guard proof | at most 25 s + 2 s inside PID 1 (before the gadget) | the proof stops; PID 1 goes on to the gadget either way |

T0 is PID 1's start; it cannot come before BootStartUtc, so the earliest timer reboot is no earlier than
BootStartUtc + 200 s. The host gives up at BootStartUtc + 185 s. **These timers are userspace: they do not cover a
kernel hang** (§5). A proof that stops on time (its `ABORT: time:` line, or fs-supervise's timer) does not hang PID 1:
the gadget, the session and the reboot follow as on the normal path. The host classifies a time stop **before arming**
INCONCLUSIVE (no armed guard test case attempted; decoy set-up and the before-pass reads had run) and one **after
arming** K1G REVIEW (`k1g/README.md` §5).

## 4. Where the unit lands, and what the PM does

**Before PID 1 runs nothing brings the unit back** (as K1a): our kernel can hang or panic early (before or while
loading the stock modules). The K1g kernel's config is K1a's: `PANIC_ON_OOPS` **off** (an oops is logged, the task
killed, the kernel goes on; the oops line makes the record K1G REVIEW) and `PANIC_TIMEOUT=-1` (a panic **reboots at
once**, normally **straight into Android** on slot A, with no fastboot visit) [C]. The stock `qcom-dload-mode.ko`
loads with download mode off by default, but the Qualcomm crash-dump mode stays **possible** (for example after a
panic before that module loads) [C]. Every command names the run's unit (`-Serial <serial>`, `fastboot -s <serial>`).

| state the PM sees | action | expected outcome |
|---|---|---|
| `fastboot boot` failed (`FAILED (remote: …)`) or still in fastboot | `fastboot -s <serial> reboot` | Android on slot A; nothing ran |
| **fastboot** again after the attempt | the normal path: AF, `fastboot -s <serial> reboot`, AA | Android on slot A [D] |
| **Android directly**, no fastboot visit (a panic rebooted the unit; or another unexpected path) | **AA first** (AA02 `ro.boot.bootreason` records why). AF is recorded as **not taken**; no extra reboot is made for it. Then the follow-ups and phase F (F1 = n): the record is not clean | Android on slot A [C]; Unit 1 stays refused (a new package review first) |
| no `FS-<nonce>` gadget, LED dark or unchanged, no fastboot | the kernel or PID 1 did not start, or hung during the modules or the guard proof. **Wait until Th + 260 s** (the 200 s deadline + 60 s, as K1a; the proof's 27 s are inside the deadline), still nothing: **hold the power button about 15–20 s** until the unit is off [C], power on; if needed volume-down + power → fastboot → `fastboot -s <serial> reboot` | [C] slot A boots as before |
| dark; USB `05c6:900e` (Qualcomm crash-dump / download mode after a panic). Spot it read-only: Device Manager "QUSB_BULK"/"Qualcomm HS-USB", or `Get-PnpDevice -PresentOnly \| Where-Object InstanceId -match 'VID_05C6&PID_900E'` | **at once** (do not wait for Th + 260 s): **never use any flashing, EDL or crash-dump collection tool.** Hold power until off, then power on | [C] slot A boots. The bootloader may have written a crash minidump [C] |
| hung later (PID 1 ran, then nothing) | as the "no `FS-<nonce>` gadget" row: Th + 260 s, then hold power | [C] |

The Th + 260 s schedule is a **fallback schedule, not an instruction to wait** through heat or another concerning
physical condition: at **≥ 40 °C** (or any concerning sign) shut down and cool at once (power-menu power-off while
connected, physical observation that the unit is off, then unplug; physical shutdown and unplugging take precedence),
and never restart merely to obtain a reading (`RECOVERY.md` "Battery after the attempt"; FS-R-013 §3).

## 4a. The guard during recovery (K1g-specific)

- **What is armed when.** The guard is part of our kernel. From the kernel's first instruction it is in **protect**
  (the boot default): writes to the Quest's boot-chain and unit-unique partitions are refused from the start, before
  and during the modules. The proof then latches `kernel.modules_disabled`, **arms strict and seals** it: from then
  until the kernel stops, every block write and SCSI/UFS pass-through to any disk other than the probe's RAM decoys is
  refused, and no process can disarm it (the seal is one-way).
- **Across a hang.** If the unit hangs after arming, the guard **stays armed and sealed** until the power is removed or
  the kernel reboots; nothing in userspace can lower it. If it hangs before arming, protect mode stays in force. In
  both cases the recovery is the manual route above (Th + 260 s, then hold power); the guard does not delay it.
- **It does not block the way back.** The guard refuses block writes and pass-through only. The reboot paths
  (`reboot(RESTART2, "bootloader")`, a plain restart, `reboot -f`, a panic reboot, holding power) need no block write
  from our kernel [D: the reboot cookie is not a partition write]; a power-off clears all guard state (it lives in
  RAM). Nothing of the guard persists: after the attempt the unit boots Meta's stock kernel, which has no guard.
- **What a refused write looks like.** Nothing is visible on the headset (no display, no LED change, no reboot): a
  refused call fails with **EPERM** (a write-class block request refused in the block layer reaches the writer as
  **EIO**), the guard's counter for that path moves, a rate-limited kernel-log line `fs_blkguard: denied <path> on
  <node> (<partition name>) [<reason>] by <command>[<pid>]` is written (RAM only), and `/proc/fs_blkguard` lists the
  last refusals. During K1g the proof makes such refusals on purpose; the record carries the counters (the runner's
  `blkguard` step) and the kernel log lines (`kmsg` step). A refusal is the guard working; it is never a reason to
  touch the unit, and it needs no recovery action.
- **The proof's own stops.** A proof that stops before arming (`ABORT`, including `ABORT: time:`) has written nothing
  and armed nothing (protect stays); one that stops after arming leaves the guard armed until the reboot. Neither
  changes the procedure: the session continues and the unit returns by itself (§3).

## 4b. Storage writes during a K1g cycle

None by FrameShift's own tools: they read and boot, and the proof writes only its RAM/tmpfs decoys (`/run` and
`/dev` are tmpfs; `ram0`/`ram1` are RAM disks); with the guard armed a write to the unit's storage is refused anyway.
The cycle's `adb reboot bootloader` (BA → BF) makes **Android** write the bootloader message to **misc**, as in every
stage (`common/MISC-RULE.md` §3); after a **panic or oops** our kernel, like stock, may write **pstore records** (EFI
variables) [C] (not a block path the guard sees); after a panic in download mode the bootloader may write a **crash
minidump** [C]. None of these is a FrameShift write. Within the K1g boot the proof's fail-closed read rows measure the
listed ranges before and after the guard cases; across the session, misc, devinfo and partition-content invariance
were not measured (FS-R-013 §3).

**Every manual step is recorded:** checklist phase F asks whether the unit came back by itself and whether dump mode
was seen. A manual power-off, a §4 manual step or dump mode makes the attempt's after-session record **not clean**, and
Unit 1 then stays refused (a new package review first).

## 5. What is not covered

- **A kernel hang or panic of our kernel** (§4): no userspace timer covers a hang and there is no watchdog (J-49); the
  manual route is the only recovery. Every outcome is [C].
- **Persistent effects outside the guarded block and pass-through paths:** RPMB and UFS device attributes reached by
  other means, an XBL minidump, pstore records in EFI variables, the misc bootloader message, and the residuals of the
  guard itself (`docs/research/fs-blkguard-design.md` §6: sysfs device settings, GPIO/I2C/firmware/NVM writers, EFI
  variables, PCI/DMA).
- **Thermal protection** beyond the kernel's own CPU mitigation maps (FS-R-006 §4); K1g drives no fan and runs no
  thermal engine.
