# FrameShift

> **Status: early development; nothing to install yet.** FrameShift has no
> release, no installer and no bootable SteamOS image. What is here is the
> engineering record: research, offline tools, test fixtures, and the small
> test images used for attended trials on the project's own headsets.

**Start here.** This file is the single entry point. If you are picking the
project up cold, read it top to bottom, then follow [How to resume](#how-to-resume).
Everything else in the repository is linked from here.

**New to FrameShift?** Read [How FrameShift works](docs/HOW-FRAMESHIFT-WORKS.md) first: a plain-language
guide to the design, the safety systems and what has been tested so far.

*Status as of 2026-10-23 UTC (JOURNAL up to J-244, latest ruling FS-R-018). **Milestone T0 passed on both Quest 3 units on 2026-10-18:** the first thermal-service step identified the temperature, fan and battery sensors under stock Android and read them through a short CPU load; the fan-trip table, corrected after the first run, matches on both units (FS-R-016). **Milestone K1a** passed on both units on 2026-10-17: a FrameShift-built Horizon OS v2.7 kernel, from Meta's published kernel source, booted by temporary boot with Meta's stock modules (FS-R-013). The boot-chain storage write guard (**K1g**) **passed on both Quest 3 units** (411 of 411 cases, 402 of them refusals, protected partitions unchanged): on Unit 2 after a first attempt whose probe stopped itself before arming the guard (fail-closed; nothing was written), on Unit 1 on its one attempt (2026-10-23). The USB network link (**N1**) has **not passed yet**: its second run on Unit 2 failed on a timing problem in our own PC-side tool (it took too long to find the new network adapter) before the transfer started; a faster tool is built and another run needs a new review. **Next:** a reviewed N1 re-run, the Steam-ready kernel (K1i), the full thermal service and **R-1 "SteamOS boots"**, the first big milestone. Nothing to install yet.*

*This status line is the project's single current-status source. Status lines
in other documents (`docs/PROJECT_SETUP.md` §7, `docs/JOURNAL.md` "Where we are
now", device and stage READMEs, `IMAGE.md` files) defer to it: where they
differ, this one wins.*

### Status in plain language

- **Works:** on a Quest 3, our own small init boots with the stock kernel by
  temporary boot, proves it is running over USB serial, and returns the
  headset to Android (Stage 1). Four genuine Valve files ran on it (trial (i); registered COMPATIBILITY FAIL at step 4, a listing-rule defect, FS-R-009).
- **Display:** our test images show correct images on both Quest 3 units on
  Horizon OS v2.7 (stage 3d, J-144/J-146).
- **Our own kernel:** a FrameShift-built v2.7 kernel booted on both Quest 3
  units with all 95 of Meta's stock modules loaded and no kernel warning
  (K1a, J-193).
- **Thermal sensors:** the sensors the thermal service needs are identified
  and read on both Quest 3 units (T0, J-205/J-206). This does not yet prove
  FrameShift's own thermal protection; that is the later TS stages.
- **Boot-chain guard:** our guard kernel booted on Unit 2, but the first probe
  run stopped itself before arming (K1g r2 REVIEW, J-207); the fix is built.
- **Not yet:** SteamOS itself. No Valve rootfs or systemd has run on a
  headset, and there is nothing to install.
- **Next:** the boot-chain guard (K1g r3), the USB network link (N1), then
  the Steam-ready kernel (K1i), the full thermal service and R-1 "SteamOS
  boots". The Quest 2 channel continues offline.

New here and not on the team? [Outsider quickstart](#outsider-quickstart)
says what you need, what builds and which tests run offline.

### Licence and notice (summary)

- Code (tools, host scripts, on-device services, fixtures and records): **Apache License 2.0**
  (`LICENSE`). Kernel patches (in `kernel-patches/` and the fs-blkguard patches in `tools/blkguard/`), the fs-blkguard probe, harness, test and bench C sources (`tools/blkguard/`) and FrameShift's own kernel modules:
  **GPL-2.0-only** (`kernel-patches/README.md`). Documentation: **CC-BY-4.0**
  (`LICENSES/CC-BY-4.0.txt`). See `NOTICE`.
- Meta and Quest are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and Steam Frame
  are trademarks of Valve Corporation; other names are the property of their respective owners.
  **FrameShift is not affiliated with or endorsed by them.** This repository
  contains **no Valve or Meta software, firmware or images**; users obtain
  SteamOS from Valve. See `NOTICE`.
- **The project assumes an already-unlocked headset.**

### How this project is made (AI disclosure)

- FrameShift is developed with AI assistance.
- The engineering, code, tests, documentation and relays (the **Arbiter**
  role) are produced by Anthropic's Claude Opus 5.5, working in Claude Code.
- Independent adversarial review (the **Chair** role) is done by OpenAI's
  ChatGPT Sol 6.1 in a separate session.
- A human project manager (the **PM**) directs the work, makes every
  decision, approves every device action and is required to be physically
  present for every headset boot (one recorded deviation: trial (i) was run
  remotely, FS-R-009). The PM carries relays and rulings between the two AI
  sessions.
- AI output is checked by reviews, offline test suites and hardware
  evidence, but readers should verify claims themselves. The evidence tags
  ([M], [D], [C], [O]; see [Evidence tags](#evidence-tags-fs-r-001-enforced-in-every-document))
  show how each claim is supported.

### About this public copy

This repository is a sanitised export of the private development repository,
published as sanitised snapshots (one commit per export):
- **Commit ids** quoted in documents refer to the private development
  repository and do not resolve here.
- **Device serial numbers** are replaced by placeholders: `QUEST3UNIT1`
  (Quest 3 Unit 1), `QUEST3UNIT2` (Quest 3 Unit 2), `QUEST2UNIT` (the Quest 2
  unit); third-party units are not identified. Local paths are replaced by
  `<repo>`, `$HOME` and `<build-host>`.
- **Raw evidence folders** that contain device identifiers
  (FS-A-004 (private review record), `-005-`, `-006-`, `-009-`, `-010-raw/`,
  `devices/quest2/evidence/`, `devices/quest3/evidence/`), the decompiled
  Quest 2 device tree, all built binaries, and anything extracted from or
  output by third-party binaries (Valve ld.so inspections and disassembly,
  glibc source excerpts, stock module CRC tables and inventories, stock
  init-script excerpts) are **withheld**: the public copy holds only material
  the project wrote itself. Also withheld, as outside the public scope (the
  SteamOS-port work for an already-unlocked headset): the project's
  device-state capture and partition-readback tooling (including the
  readback rows, the K1a, K1g and N1 walkthroughs, run addenda and sign-off
  tooling, and the Android-side T0 thermal probe and its run documents), its
  firmware-update risk research,
  research that depends on its private clean-room study of third-party
  binaries, security findings about third-party software that go to its
  authors first, and the documents of an earlier, shelved device
  programme. Each withheld folder has a short README;
  hashes and summaries are in the journal. Text passages that
  were removed or paraphrased in dated records are marked
  "[removed for publication]" or "[paraphrased for publication]".
- Because of this, some files no longer match the SHA-256 pins recorded in
  manifests and documents: they were edited to remove identifiers, changed after
  the record was frozen, or differ only in line endings, and some pinned files
  (build outputs, images, firmware inputs) were never in the repository.
  `docs/PUBLIC-MANIFEST-CHECK.txt` classifies every manifest entry in this copy;
  manifest entries for files outside the public scope are removed (each manifest
  says how many).
- **Offline suites affected by withheld material.** These print
  `SKIP (withheld evidence)` or `SKIP (withheld)` for the affected cases
  instead of failing:
  - `devices/quest3/host/test-host2.ps1`: section L (step-4 list rule, needs
    FS-A-009 (private review record)) and section M (misc rule, needs withheld
    FS-A-005 (private review record) evidence); section B (before/after command data),
    section P (fake-device captures) and the F3 findings cases, which test
    the withheld device-state capture tooling;
  - `devices/quest3/host/test-host3b.ps1`: section D (the trial-(iii)
    capture in FS-A-010 (private review record));
  - `devices/quest3/common/tools/test_misc_rule.py` (all cases use withheld
    evidence);
  - `devices/quest3/stage3b/tools/pace_evidence.py` case (b);
  - `tools/kgate/validation/run_validation.sh` (comparison with the FS-A-006
    evidence lists);
  - `devices/quest2/channel/tools/fixtures-build.sh` (the shipped-binary
    segment check) and `devices/quest2/channel/host/test-transport-tcp.ps1`
    (real-responder sections D/E/G/H, which also need build inputs).
- Suites that need gitignored build inputs (busybox, built tools, firmware,
  the AOSP toolchain) refuse to start without them, as in the private
  repository: the stage 2a/3a/3b builders and image tests, the fs-pattern
  fixtures and the common fixture **generators** (`common/tools/fixtures-fsb1.sh`,
  `fixtures-deadline.sh`, `fixtures-supervise.sh`,
  `fixtures-supervise-native.sh`). The FSB1 decoder suites themselves run on
  the committed fixtures: `devices/quest3/common/tools/test_fsb1.py` (38/38)
  and `devices/quest3/common/host/test-fsb1.ps1` (38/38, cross-checked against
  the Python results).

---

## What FrameShift is

FrameShift ports **Valve's SteamOS for the Steam Frame** (Valve's ARM headset,
Snapdragon 8 Gen 3 / SM8650, board `deckard`) to **Meta Quest headsets**. Valve
published the Frame's ARM image, so this is a port of real SteamOS userspace, not
something SteamOS-like built from scratch. The work goes into the kernel, device
tree, boot path, display, thermal/power control and, later, tracking. The
headsets keep Meta's bootloader. Our images start through `fastboot boot` (and,
on the designated unit only, through reviewed flashing later).

Naming rule: the project is **FrameShift** (one word). "Steam" and "SteamOS"
are used only to explain what the project does, never as part of our own names.

**PM's product goal (J-75, J-83):** a polished, professional port that builds on
community work, then improves on it. Learn from others, then independently choose
the most robust method.

### Targets and order

Order adopted by the Chair in **FS-R-006 §1** (PM decision, J-35/J-37):

| # | device | SoC | build target | status |
|---|---|---|---|---|
| 1 | **Quest 3** | XR2 Gen 2 (`anorak`) | Horizon OS **v2.7** (kernel `5.10.246-gd7102a837402`) | **active**, primary. Both units on v2.7; stage 3d (J-144, J-146) and K1a (J-193) passed on both |
| 2 | **Quest 2** | XR2 Gen 1 (SM8250-class) | **v2.7** (kernel `4.19.325-cip128-st12-g49638c7a8637`) | secondary. Unit on v2.7; offline channel built |
| 3 | Quest Pro | XR2+ Gen 1 (`kona`) | v2.7 (Quest 2 kernel tree) | offline/build only, in lockstep; no PM unit |
| 4 | Quest 3S | XR2 Gen 2 (`panther`) | v2.7 (Quest 3 kernel tree) | offline/build only, in lockstep; no PM unit |
| 5 | Quest 1 | MSM8998 | **v50** (final firmware; end of life, J-75) | queued |
| 6 | Vive XR Elite | XR2 Gen 1 (SM8250) | its own (HTC firmware) | shelved |

The build target is the **v2.7** release for Quest 3/2/Pro/3S. Trials are
meant to run on units that are themselves on v2.7. Booting a v2.7 kernel on
older firmware would be a hybrid (J-66). The firmware ceiling is v2.7: never
newer (PM, J-69). **Today both Quest 3 units are on v2.7:** stage 3d (the
stock v2.7 kernel with our initramfs) displayed correctly on both (J-144,
J-146), and K1a booted a FrameShift-built v2.7 kernel on both (J-193).

**Which unit runs what, today.** Both Quest 3 units are on v2.7 and are booted
only by temporary boot. Unit 1 ran every trial up to stage 3c (then on v66),
and stage 3d and K1a on v2.7. Unit 2 ran stage 3d and K1a (first), and is the
unit reserved for separately reviewed flashing work later.

### Architecture at a glance

```
 Quest headset: requires an unlocked headset (assumed)
 +-------------------------------------------------------------+
 | Qualcomm boot chain + Meta ABL: kept as shipped, never      |
 | written by us (FS-R-001, Do-not 3)                          |
 |        | fastboot boot (temporary; no partition written)    |
 |        v                                                    |
 | kernel: Meta's stock kernel, or our own v2.7 build (K1a)    |
 |         (gated offline by tools/kgate)                      |
 | initramfs: ours. PID 1 with an unconditional DEADLINE       |
 |         reboot, fs-supervise, the FSB1 result record        |
 |        | later (Stage 2 proper)                             |
 |        v                                                    |
 | Valve's Steam Frame rootfs, byte-unmodified and read-only,  |
 | with our layer on top; Valve's updaters and firmware        |
 | writers never run (planned: docs/PROJECT_SETUP.md 0.0)      |
 +------------------------------+------------------------------+
                                | USB: ACM serial (Quest 3) or
                                | NCM network (Quest 2, offline)
                                | FSV1 challenge, HOST_ACK, FSB1
 Host PC (Windows + WSL)        v
   fs-observe.ps1 -> fs-collect.ps1 -> fs-classify*.ps1  (devices/quest3/host/)
   image builders, fixtures, kgate                        (WSL)

 Review: Arbiter writes relay FS-A-NNN -> adversarial agent review ->
 PM sends it -> Chair rules FS-R-NNN -> PM signs off at the headset ->
 one attempt, no retry -> result reported in the next relay
```

- **Boot chain we keep:** the Qualcomm chain and Meta's ABL. We never write
  boot-chain partitions; our images arrive by `fastboot boot`.
- **What we boot:** Meta's stock kernel plus our initramfs (stages 1 to 3d);
  since K1a also our own kernel built from Meta's published v2.7 source, with
  Meta's stock modules taken from the unit's own firmware.
- **Userspace:** later, Valve's Frame rootfs, read-only, with our layer
  overlaid (`docs/research/valve-image-slot-in.md`).
- **Host side:** PowerShell observer, collector and classifiers; every result
  travels as an FSB1 record (`devices/quest3/common/FSB1-SPEC.md`), and a
  damaged record is rejected, never repaired.
- **Process:** see [How the project is run](#how-the-project-is-run).

---

## How the project is run

### Roles

| role | who | does what |
|---|---|---|
| **PM** | the project lead, owner of the devices and the decision-maker | approves every device action, sends relays to the Chair, signs off every boot attempt in person |
| **Arbiter** | the engineering assistant (Anthropic's Claude Opus 5.5, in Claude Code) | does the engineering and research, writes the journal and the relays `FS-A-NNN`, and runs read-only probes the PM has authorised |
| **Chair** | an independent adversarial reviewer: a separate AI assistant session (OpenAI's ChatGPT Sol 6.1) that the PM runs. The PM carries relays and rulings between the sessions | reviews each relay and its evidence and issues numbered rulings `FS-R-NNN`. **Rulings are binding until explicitly superseded** (`docs/CHAIR_DIRECTIVE.md` §7) |

### The relay process (the records are kept private, J-167)

1. A relay `FS-A-NNN` is written **only when something must go before the
   Chair**: a discovery, a question, a device result, or a package to review.
   Routine back-and-forth stays out of relays.
2. **Numbers are never skipped.** Unsent material rolls into the open relay.
   The ruling mirrors the number (`FS-A-010` → `FS-R-010`).
3. Before a relay is marked ready, **adversarial agent-reviewers** check it and
   its bundle (read-only, with narrow scopes). Their findings are fixed or
   disclosed in the relay.
4. **The PM sends the file** (with its `FS-A-NNN-raw.zip` evidence bundle) and
   says when it is sent. Do not paste relays into chat as code blocks.
5. **Wait for the ruling** before finalising the next relay. Record the ruling
   verbatim as the private review records, and record its effects in the journal (a
   new J-entry and Corrections rows).
6. Dated records are **superseded, not edited**. Corrections stay visible
   (`docs/JOURNAL.md` → Corrections).

### Evidence tags (FS-R-001; enforced in every document)

- **[M]**: measured on hardware, with the output shown.
- **[M-static]**: read from a named file, image or dump.
- **[D]**: derived from something measured, with the derivation stated.
- **[C]**: inferred and plausible, but unconfirmed.
- **[O]**: **open**, i.e. unresolved. It does not mean "observed" (FS-R-005 §5).

A PM report is recorded as `[PM report]`, not [M]. A fixture or emulator run is
[D] evidence, not [M]. Never turn a plausible mechanism into a measured result.
Scope each claim to what was actually shown.

---

## Safety rules (non-negotiable, in brief)

The full lists are in `docs/JOURNAL.md` → **Do not go here** (25 items),
`docs/PROJECT_SETUP.md` **§6A**, FS-R-001 (private review record), and
`docs/DEVICE_PORT_CHECKLIST.md`. In brief:

1. **Valve's update and firmware machinery never runs on a Quest** (FS-R-001
   scoped stop). Valve's `kernelsetup.sh` writes the whole Qualcomm boot
   chain, and `splctl` writes `bootenv`. Never install an unmodified Valve RAUC
   bundle (FS-R-001 R3). Never "fix" Valve's broken `steamos-firmware-update`
   (Do-not 15). Never start an unreviewed stock SteamOS service set.
2. **Never write boot-chain partitions** on any headset (`xbl*`, `tz`,
   `hyp`, `aop*`, `uefi*`, `abl`, `devcfg`, … Do-not 3). The ABL stays
   Meta's. Don't create partitions that would arm Valve's writer (Do-not 13).
3. **Unit scope (FS-R-006 §1):** Quest 3 **Unit 1 and the Quest 2 get
   temporary boot (`fastboot boot`) only and are never flashed by
   FrameShift.** The Quest 2's stock firmware was moved to Meta's official
   v2.7 by the PM (PM executive decision); that is not FrameShift flashing.
   Quest 3 **Unit 2** is reserved for separately reviewed flashing work, after
   its own baseline; its stock firmware was updated to Meta's official v2.7
   by the PM (PM executive decision). Every live trial so far has been a
   temporary boot; FrameShift has flashed nothing on any unit.
4. **Every boot attempt** needs the Chair's concurrence **to execute** (not
   just to prepare), plus a fresh nonce and the PM's **live sign-off with the
   PM physically at the headset**. The PM confirms presence explicitly in chat
   before the attempt step is given (J-60). Give steps one at a time. One
   attempt, no retry.
5. **Read-only by default.** The PM has given standing approval for read-only
   probes. **Confirm with the PM before anything that writes or changes state**:
   reboots, `adb push`, mounts, `setprop`, flashing, slot changes. Classify
   every command before running it, and list commands inline for the PM.
6. **Never use the bootloader menu's "Switch Boot Slot"** (PM: can brick, J-75).
   Think hard before any `fastboot set_active` (Do-not 9).
7. **Thermal:** our images replace Android's thermal and battery protection.
   Without our own thermal stack, holds stay short, bounded and attended
   (§6A.1–2). Cooling follows temperature, not screen state (§6A.3). Never
   leave the stock `performance` governor running unattended. No
   beyond-spec overclocking (§6A.4–5). Apply the FS-R-010 §6 temperature
   procedure (stable within tolerance, < 35 °C, ≥ 40 °C → shut down at once,
   verified power-off).
8. **Partition, MCU and package hazards (§6A.8b):** never mount `persist`,
   `private` or `metadata` read-write. Never send unknown SyncBoss commands.
   Never disable package signature checks.
9. **Never reproduce Valve credentials** (for example the service credentials
   embedded in Valve's update client config). Use no token for Valve's gated
   repos (J-80).
10. **Never write to the PM's archive drive.** It holds the original
    firmware packages and is read only.
11. **Third-party testers** get reviewed `fastboot boot`-only images, a written
    risk briefing and consent, and no Valve binaries (§6A.9).

---

## Current state (2026-10-19)

### Milestones on hardware (Quest 3, by temporary `fastboot boot`)

Nothing was flashed by FrameShift in any of these runs. Milestone definitions: `docs/PROJECT_SETUP.md` §3.

| when | milestone | result | ruling |
|---|---|---|---|
| 2026-10-08 | **M1, first shell**: the stock kernel with our initramfs, a USB serial shell and a challenge | **achieved** on Unit 1 (v66) [M] | FS-R-005 |
| 2026-10-09 to 10-11 | early trials on Unit 1 (v66): four Valve userspace files on the stock kernel; two first display tests | each reached our init and answered the challenge. Registered outcomes: a listing-rule defect (fixed), an inconclusive record, and a lit but garbled image | FS-R-009, FS-R-010, FS-R-012 |
| 2026-10-13, 2026-10-14 | **M2, correct image on the panels** | stage 3c on Unit 1 (v66); then stage 3d on **both units on v2.7**, with the eye swap and the 21° roll corrected | **FS-R-012: display milestone accepted** |
| 2026-10-17 | **K1a, our own kernel boots** | a FrameShift-built v2.7 kernel with Meta's stock modules booted on **both units** (Unit 2, then Unit 1): K1A PASS each (all 95 modules loaded, no kernel warning, memory measured), clean before/after checks, no recovery needed, highest battery reading 31.0 °C [M] | FS-R-013 concurred; **FS-R-014: accepted** |
| 2026-10-18 | **T0, thermal sensors identified** (stock Android, no FrameShift image) | on **both units** (Unit 2, then Unit 1): T0 PASS each; the sensors read through a short CPU load (SoC peak 50.4 and 52.6 °C, battery at most 27.9 °C, fan not needed); all 28 fan zones match the corrected table [M]. A first Unit 2 run (REVIEW) had found the table error and a row-timing defect, both fixed in r2 | **FS-R-016: T0 complete** (not yet a test of FrameShift's thermal protection or of the fan) |
| 2026-10-19 | **K1g r2, boot-chain guard** (Unit 2) | **REVIEW:** the guard kernel booted (95 modules, no warning) and the unit returned to fastboot by itself; the probe's third hashing row failed closed (its reads were rounded to 512 bytes on 4096-byte storage), so the guard was not armed and no guard case ran; nothing was written | **FS-R-016: REVIEW accepted**; the r3 reads concurred |

No Valve rootfs or systemd has run on a headset yet. That is R-1, after the guard (K1g) and the Steam-ready kernel (K1i).

### In progress

- **K1g r3** (`devices/quest3/k1g/`, the guard in `tools/blkguard/`): the probe now reads in whole 4096-byte blocks and
  hashes only each row's bytes; the kernel is unchanged. Tested in QEMU and UML with 4096-byte sectors, including a
  reproduction of the Unit 2 failure. Its reads are concurred (FS-R-016); the revised attempt gate (recording the r2
  attempt as superseded) goes to the Chair as its own change before the replacement Unit 2 attempt.
- **N1** (`devices/quest3/n1/`): the guard kernel with a USB network link next to the serial console and one bounded
  transfer, Unit 2 only, after a clean K1g r3 on Unit 2.
- **K1i preparation:** 48-bit virtual addresses together with SysV IPC, with a 39-bit control image
  (`docs/research/va-bits-k1i.md`, PM decision); the Wi-Fi module now rebuilds to match Meta's stock module (J-210).
- **The module loader (H-1/H-2)** (`devices/quest3/h1/`): an ordered, bounded loader for the later kernels, with the
  thermal modules first and a refusal to hand over if they are not ready. Built offline; for K1i and TS.
- **The thermal and battery service** (`devices/thermal/`): specifications, our own C sources, simulations and the
  derived threshold tables (identifiers and numbers only, J-123), with the fan-table correction found by T0. Built
  and tested offline.
- **R-1 preparation:** the review of what SteamOS 0.4.5 could write or start (masks and controls; kept private
  for now), an open-source PD mapper for the battery service (`docs/research/pd-mapper.md`), a design for how
  FrameShift answers SteamOS's shut down, restart, sleep, update and reset requests (with the PM's decisions; kept
  private for now), and the R-1 package itself, being built and tested offline in QEMU (not in this copy yet).
- **Installed boot:** a research design for a later, reviewed install-and-restore cycle on Unit 2 (kept private for
  now). No install is planned before R-1.

### Hardware units

All units are unlocked headsets (assumed by the project).

| unit | firmware | role and notes |
|---|---|---|
| Quest 3 **Unit 1** (`QUEST3UNIT1`) | Horizon OS v2.7 (build `52433670036000520`), slot A | the temporary-boot test unit; never flashed by FrameShift. Stage 3c (on v66), stage 3d, K1a and T0 (on v2.7) passed here. Its proximity sensor is faulty |
| Quest 3 **Unit 2** (`QUEST3UNIT2`) | Horizon OS v2.7 (build `52433670036000520`), slot A | stage 3d, K1a and T0 passed here; K1g r2 came out REVIEW (r3 next). Reserved for separately reviewed flashing work. Its IPD slider and proximity sensor are faulty. Backed up read-only |
| Quest 2 (`QUEST2UNIT`) | Horizon OS v2.7 (build `52242990024200150`), slot b | secondary target; temporary boot only; no Quest 2 run is concurred yet |

No Quest Pro, Quest 3S or Quest 1 unit is used. The XR Elite is shelved. Known unit faults are recorded and factored into
results, never compensated for.

---

## Next steps and open items (in order)

1. **K1a: done** (2026-10-17, both units; FS-R-013). **T0: done** (2026-10-18, both units; FS-R-016).
2. **K1g r3:** the revised attempt gate, with its tests and review, to the Chair (FS-R-016); then the replacement attempt
   on Unit 2. After a clean Unit 2 result: **N1** on Unit 2, then K1g on Unit 1.
3. **SA-C1**, the restart-argument lockdown in our kernel, as its own named kernel change with K1i (FS-R-016).
4. **K1i**, the kernel for Steam: SysV IPC plus a rebuilt, pinned module set, passing K1g again.
5. **TS**, the full thermal and battery service, stages T1–T5 on each unit and kernel that will use them.
6. **R-1, SteamOS boots**: Valve's unmodified 0.4.5 rootfs loaded into RAM over USB, verified, reaching a controlled console
   target with Valve's risky units masked and the guard and module latch armed. The first big showable milestone.
7. **Later and parked:** the GPU route (G-rows), the desktop in the headset (V0), tracking (V1–V5), the Quest 2 thermal
   and recovery assessment, the installer and distribution architecture, and licence requests to community authors.

---

## Outsider quickstart

For readers outside the project. Nothing here is a supported install path;
read the [safety rules](#safety-rules-non-negotiable-in-brief) first.

**What you need**
- A Quest 3 (the only model with live trials so far). FrameShift **requires
  an unlocked headset (assumed)**; this repository does not cover how a
  headset gets there.
- Your own stock `boot` and `vendor_boot` images, taken from the official
  firmware for your unit. Nothing from Meta or Valve is redistributed here.
  The stage builders pin the exact stock images of the project's Unit 1
  (v66 `50105190000000511`, slot A) and refuse anything else, so other
  firmware needs new pins and a new review.
- For the Valve-file stage (2a): Valve's public Steam Frame image, from
  Valve.
- The toolchain under [Environment](#environment): Windows 11 with
  PowerShell 5.1 and Android platform-tools; WSL Ubuntu with AOSP clang
  r450784e, AOSP make 4.3 and the listed packages; the pinned third-party
  inputs under [What is not in git](#what-is-not-in-git-and-where-it-is)
  (AOSP `mkbootimg`, busybox-static 1.37.0 arm64).

**What builds**
- Our static aarch64 tools (`tools/build.sh` in `devices/quest3/common/`,
  `stage3a/`, `stage3b/`).
- The stage images (`build-image.sh` in each stage folder; each build makes
  a new nonce), given the pinned inputs above.
- The Quest 2 channel (`devices/quest2/channel/README.md` §1).
- Kernels from Meta's published source; exact recorded hashes cannot be
  reproduced here (see [Environment](#environment)).

**Which suites run offline in this copy** (no device, no build inputs)
- `bash tools/kgate/test_kgate.sh` (WSL/Linux; python3, mke2fs, debugfs):
  170 cases.
- `python3 -I devices/quest3/common/tools/test_fsb1.py` (38/38) and
  `devices\quest3\common\host\test-fsb1.ps1` (38/38, cross-checked against
  the Python results). Both write their results into the fixture folder
  unless given a scratch copy (`FIXDIR` / `-FixDir`).
- `devices\quest3\host\test-host3b.ps1`: **112 passed, 1 skipped** (the
  skip is section D, cases D1–D4, reported as one SKIP line; 116 in the
  private repository).
- `devices\quest3\host\test-host2.ps1`: **333 passed, 5 skipped** (sections
  B, L, M, P and the F3 cases, one SKIP line each; 459 in the private
  repository). It needs WSL with `dash` and `bash` (it runs the
  shell fixtures under WSL dash and bash --posix; the G-sh cases). See
  [About this public copy](#about-this-public-copy).
- `devices\quest3\host\test-host3c.ps1` and `test-host3d.ps1`: the before/after
  capture section (UB in test-host3c) reports one SKIP line because that tooling is
  withheld here; checks that read withheld files fail or skip in this copy.
- `devices\quest3\stage1\test-host.ps1`: the stage-1 host protocol checks
  (74).

**Replicate on your own unit**
- **Re-pin for your own firmware.** Each stage builder
  (`devices/quest3/stage<2a|3a|3b>/build-image.sh`) pins the project's Unit 1
  stock images in its pin block: `EXPECT_STOCK_BOOT` and `EXPECT_STOCK_VBOOT`
  (SHA-256 of your stock `boot` and `vendor_boot`), plus the values derived
  from them, `EXPECT_KERNEL` (the stock kernel), `EXPECT_MODLIST` /
  `EXPECT_MODLIST_N` (`modules.load.recovery`) and `EXPECT_VLIST` /
  `EXPECT_VLIST_N` (the sorted vendor-ramdisk path list). The inputs are read
  from `firmware/quest3/v66_unit1_slotA/`. Regenerate these values from your
  own images, then review the diff as you would any other pin change; a
  module list that differs from Unit 1's means the init's module loading
  needs review too.
- **Inputs to fetch** (names and versions; nothing is redistributed here):
  AOSP `platform/system/tools/mkbootimg` at commit
  `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` (`EXPECT_AOSP`); Ubuntu
  `busybox-static` `1:1.37.0-7ubuntu1` arm64 (the extracted binary is pinned
  as `EXPECT_BUSYBOX`); AOSP clang `r450784e` (clang 14.0.7) in
  `~/toolchains/clang-r450784e`; AOSP make 4.3; your own unit's official
  stock firmware.
- **Capture interface for stage 3b.** `fs-observe.ps1 -Stage 3b` requires
  `-BaSummary` and `-BfSummary`: one text file per phase (BA, then BF) of
  the current cycle, and refuses to boot without them. It ignores empty
  lines and checks only the first and last lines (at least two lines):
  - the first line must be exactly
    `# fs-capture.ps1 phase <P> nonce <N> serial <S>  <UTC>`, where `<P>` is
    `BA` or `BF`, `<N>` the attempt nonce (16 lowercase hex), `<S>` the
    device serial passed to `fs-observe.ps1 -Serial` (its default is the
    placeholder `QUEST3UNIT1`; pass your own unit's serial), and `<UTC>` the phase
    start as ISO 8601 UTC with a `Z` suffix (for example
    `2026-10-11T09:30:00Z`; fractional seconds allowed); note the **two
    spaces** before the timestamp;
  - the last line must start `PHASE <P> OK: ` (any text may follow);
  - the lines in between are not parsed;
  - BF must start no earlier than BA, and the boot must come within 300 s
    of BA's start (the dwell gate).

  A replicator can write these files from their own before/after state
  records.
- The project's own procedure uses additional before/after state checks
  whose tooling is not published.

**Limits for a replicator**
- The project's **device-state capture tooling is not published.** A
  replicator must provide their own before/after state checks (the BA, BF,
  AF and AA phases in the [Glossary](#glossary)).
- The public `fs-observe.ps1` was edited for publication, so it no longer
  matches its pinned hash; `devices/quest3/SIGNOFF.md` step A's pin check
  applies to the project's own runs. `docs/PUBLIC-MANIFEST-CHECK.txt` gives
  the status of every pinned file in this copy.
- Images in this repository's records were reviewed for the project's own
  units only. Any other device use is at your own risk and outside the
  rulings recorded here.

---

## How to resume

1. **Read this README.**
2. **`docs/JOURNAL.md`:** read "Where we are now", then **Do not go here**
   (all of it), then the latest entries (J-78 onward) and the
   **Corrections** table. The journal is the full history. Its entries are
   never rewritten.
3. **The latest ruling is FS-R-016** (T0 complete; K1g r2 REVIEW accepted; the r3 reads concurred); FS-R-001 is the safety
   boundary. Every `FS-R-*` is binding until superseded. The relays and
   rulings are private review records (J-167); the journal records their
   effects.
4. **The last relay** was FS-A-016 (the T0 r2 results, the K1g r2 REVIEW and the
   r3 asks, ruled by FS-R-016). Next: the K1g gate revision as its own change.
   The packages are `devices/quest3/k1a/`, `k1g/` and `n1/` (their walkthroughs,
   run addenda and sign-off tooling are not in this public copy); recovery:
   `devices/quest3/RECOVERY.md` §4b and `devices/quest3/RECOVERY-K1g.md`.
5. **The device README:** `devices/quest3/README.md` (then `quest2/`, and so
   on), and `docs/PROJECT_SETUP.md` for the plan and the §6A safety
   requirements.

### Environment

- **Host:** Windows 11, Windows PowerShell 5.1 for the host tools (`adb` and
  `fastboot` from Android platform-tools), and WSL Ubuntu for builds and
  fixtures. `<repo>` below means the repository root as seen from WSL.
  **In this public copy the shell builders and fixtures derive the repository
  root from their own location** (`ROOT=` / `HERE=` in each script), instead
  of the hard-coded private path. This changes the scripts' bytes, so their
  hashes no longer match the pins recorded in the relays (a reviewable
  change). Kernel reproducibility (J-65) depends on the build path and on
  the build user/host strings embedded in the kernel banner. **The recorded
  build user/host values are withheld from the public copy, so outside
  readers cannot reproduce those exact kernel hashes.** `repro_q*.sh` reads
  them from `FS_KBUILD_USER` / `FS_KBUILD_HOST` (defaults `builder` /
  `build-host`); with the defaults it still checks run-to-run
  reproducibility, but the results will not match the recorded hashes.
- **WSL toolchains** (not in git):
  - `~/toolchains/clang-r450784e`: AOSP clang 14.0.7, matching the v2.7
    kernels; used for all our static aarch64 tools;
  - `~/toolchains/clang-r416183b`: v66-era clang, not exact;
  - `~/toolchains/build-tools`: AOSP make 4.3.
  - The kernel gate work tree is `~/work/kgate27`. Meta's build recipe is
    `README.meta.md` in the kernel source.
  - WSL packages used: `lz4`, `cpio`, `dtc`, `zstd`, `erofs-utils`,
    `simg2img`, `bwrap`, `casync`, `qemu-aarch64`, `debugfs`, python3 (J-12).
- **Kernel sources:** Meta publishes them per build at
  `github.com/facebookincubator/oculus-linux-kernel`. Quest 3 v2.7 is
  `dbc2bc83a2b6`, and Quest 2 v2.7 is `6bde5fc06b25`.
  `ValveSoftware/steamos_kernel` is **not** the Frame kernel (Do-not 7).

### Running the offline tests (no device involved)

```
# Windows (PowerShell 5.1), from the repository root
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host3b.ps1   # stage 3b host suite (116; public copy: 112 passed, 1 skipped = section D, D1-D4)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host2.ps1    # stages 2a/3a host suite (459; public copy: 333 passed, 5 skipped = B, L, M, P, F3; needs WSL dash and bash)
#   Both rewrite their committed *.output.txt unless you pass -OutFile <scratch file>.

# WSL
wsl.exe -e bash <repo>/devices/quest3/stage3b/tools/fixtures.sh   # fs-pattern v0.5 (needs the built fs-pattern)
wsl.exe -e bash <repo>/devices/quest3/stage3b/test-builder.sh     # builder negatives (needs gitignored build inputs)
wsl.exe -e bash <repo>/devices/quest3/stage3b/test-image.sh       # whole image under qemu/bwrap (needs a built image)
bash tools/kgate/test_kgate.sh                                                                    # kgate (170 cases; runs in the public copy)
```

The Quest 2 channel commands are in `devices/quest2/channel/README.md` §1.
**Building an image** (`devices/quest3/stage3b/build-image.sh` in WSL) needs
the gitignored inputs below and creates a **new nonce**. Never rebuild or reuse
an image that was proposed to the Chair. A built image is only ever booted
after a ruling and the PM's sign-off.

### What is not in git, and where it is

`.gitignore` excludes `firmware/`, `build/`, `captures/`, `*.img`, `*.bin`,
`*.zip` and similar. Exceptions: the
synthetic kgate fixtures (`tools/kgate/fixtures/data/`) and the Quest 2
channel build record (`devices/quest2/channel/build/BUILD.txt`; the binary
itself is not committed). These are on the PM's machine only:

| what | where | how to get or regenerate it |
|---|---|---|
| Steam Frame image and extracts | `firmware/SteamOS/` (the `steamframe-oobe-repair-20260922.5153644-0.3.0` image; `extracted/`) | Valve's public download. A clean rootfs copy is in WSL `~/sfroot-full`, made from a read-only kernel mount. **Never use `btrfs restore`** (Do-not 5) |
| Quest firmware: official OTA packages and extracted partitions | `firmware/quest3/`, `quest2/`, `quest3s/`, `questpro/`, each with a `PROVENANCE.txt` | the PM's archive (**read only**); official OTA packages with hashes recorded. Never redistributed |
| third-party build inputs | `build/third_party/` (AOSP `mkbootimg` at `d2bb0af5…`; busybox-static 1.37.0 arm64 `.deb` with `PROVENANCE.txt`) | re-fetch the pinned versions. The builders refuse anything else |
| built images and harness output | `build/stage1/` … `build/stage3b/<UTC>-<nonce>/` (with `attempted/` ledgers) | `build-image.sh` (a new nonce each time) |
| our static aarch64 tools | `devices/quest3/common/build/`, `stage3a/build/`, `stage3b/build/` (gitignored; `BUILD-RECORD.txt` and `build-record/` are tracked) | `tools/build.sh` in each directory. They are stated to rebuild bit-identically; on another host this is [O] |
| live trial captures | `captures/<nonce>/` | the attempt itself. What a relay needs is copied into the private review records (not in the public copy) |
| XR Elite and Quest 1 material | the PM's machine | the PM (read only) |

A newcomer obtains firmware for their own device themselves; nothing from
Meta or Valve is redistributed here.

---

## Contributing

- Issues and pull requests are welcome.
- How reviews work here: changes that affect what runs on a headset are
  summarised in a relay (`FS-A-NNN`), checked by adversarial agent-reviewers,
  and sent by the PM to the Chair, whose ruling (`FS-R-NNN`) is binding. See
  [How the project is run](#how-the-project-is-run).
- An outsider's changes are reviewed the same way before any device use. A
  merged change does not by itself authorise a device action.
- Keep to the evidence tags, the safety rules and the naming rule. Contribute
  only your own work under the licences above (code Apache-2.0, kernel parts GPL-2.0-only,
  docs CC-BY-4.0); never add Valve or Meta software, firmware, images or
  credentials.

---

## Repository map

| path | what |
|---|---|
| `README.md` | this file: the entry point and current state |
| `docs/JOURNAL.md` | full history (J-01…), **Where we are now**, **Do not go here**, Building on others, Corrections |
| `docs/PROJECT_SETUP.md` | the plan: premise, targets, stages (§3), conventions (§6), **safety requirements (§6A)**, status table (§7) |
| `docs/DEVICE_PORT_CHECKLIST.md` | per-device thermal/fan/battery/display/boot hazards that must be checked, with a status matrix |
| `docs/RESEARCH_NOTES.md` | deferred questions; community index; research index (§10) |
| `docs/research/` | research notes (thermal design, display, serial loss, licensing, community repos, performance envelopes), `pattern-preview/` |
| `docs/CHAIR_DIRECTIVE.md`, `docs/FrameShift_Chair_Continuity_Directive.md` | the Chair's role and protocol (partly superseded; see `ERRATA-002.md`) |
| `docs/ERRATA-001.md`, `docs/ERRATA-002.md` | early supersessions |
| `relays/` | a short note only: the review dialogue (relays `FS-A-NNN`, rulings `FS-R-NNN`, evidence) is kept private (J-167) |
| `devices/quest3/` | README; `RECOVERY.md`; `SIGNOFF.md`, `SIGNOFF-3c.md`, `SIGNOFF-3d.md` (sign-off sheets); `stage1/` (first shell); `stage2a/` (Valve files, trial i); `stage3a/` (display, trial iii, spent); `stage3b/` (trial iii-b, run 2026-10-11, J-107); **`stage3c/` (4-plane rerun on v66, STAGE PASS, J-125)**; **`stage3d/` (v2.7, both units, STAGE PASS, J-144/J-146)**; **`k1a/` (our own v2.7 kernel, K1A PASS on both units, J-193)**; `k1g/` (the boot-chain guard package, r3); `n1/` (the USB network link package); `h1/` (the module loader); `RECOVERY-K1g.md`; `ts/` (thermal-service inputs: sensors and firmware facts); `common/` (PID 1 infrastructure: FSB1, DEADLINE, OUTCOMES, MISC-RULE, fs-supervise); `host/` (observer, collector, classifiers, captures); `evidence/` (withheld) |
| `devices/thermal/` | the thermal and battery service: specifications, our C sources, simulations, derived threshold tables (offline) |
| `devices/quest2/` | README; `PORT-PLAN.md`; `channel/` (NCM channel); `analysis/` (v2.7 DT extraction and stage 1); `evidence/` (withheld) |
| `devices/questpro/`, `quest3s/`, `quest1/`, `xre/` | per-device READMEs |
| `tools/kgate/` | offline kernel symbol-version gate (FS-R-006 §3) |
| `tools/blkguard/` | fs-blkguard, the boot-chain write guard: the kernel patch and the probe, harness, test and bench C sources (GPL-2.0-only), the QEMU/UML harness scripts and their results |
| `kernel-patches/` | future kernel patches (GPL-2.0-only); empty for now |
| `LICENSE`, `LICENSES/`, `NOTICE` | Apache-2.0 (code), CC-BY-4.0 (docs); licences, trademark and non-affiliation notice |

---

## Glossary

| term | meaning |
|---|---|
| **ABL** | Android Bootloader: Meta's signed bootloader stage, which provides fastboot. It stays Meta's and is never replaced |
| **`fastboot boot`** | a temporary boot of a boot image from the host, with no partition written by us. Firmware and kernel code still run, so "no persistent effect" is checked, not assumed (FS-R-003 §6) |
| **slot A/B; active slot** | the A/B partition sets. Work never switches slots casually. "Switch Boot Slot" is never used |
| **v66, v71, v2.7, v50** | Horizon OS release versions. **v2.7** is the build target |
| **version numbering** | Meta's Quest firmware numbering moved from v-numbers (for example v50, v59, v66, v71, v83) to Horizon OS versions (for example v2.1, v2.7). **v2.7 is newer than v83** and the other v-number releases |
| **`anorak`, `eureka`, `hollywood`, `seacliff`, `panther`, `deckard`** | platform and codenames: the Quest 3 platform, Quest 3, Quest 2, Quest Pro, Quest 3S, and Steam Frame |
| **nonce** | 16 hex characters, fresh per image and attempt. It binds a result to one attempt. The PM types it to confirm the sign-off. Spent nonces are never reused |
| **challenge / FSV1** | the host sends a fresh challenge. The device answers with a hash of `nonce:challenge` in an FSV1 record, which proves this attempt's code is running |
| **HOST_ACK / FSA1 / FSS1 / FSD1** | the host's acknowledgement, the status record, and the `fs-done` (finish and reboot) acknowledgement |
| **FSB1** | the framed result record (line count, byte counts, SHA-256, END). Damaged or incomplete records are rejected, never salvaged (`devices/quest3/common/FSB1-SPEC.md`) |
| **FSP1** | fs-pattern's own CRC-checked event records inside FSB1 |
| **FSR1** | the PM's optical-reading records (per eye, per run) |
| **paced emission** | FSB1 sent in chunks with a 0.1 s pause after each full chunk, to lower the burst pressure on the USB serial link. Per stage: stages 2a and 3a were **unpaced**; **stage 3b uses 20 lines per 100 ms** (`FSB1_PACE_LINES=20`; the pacer's default of 10 lines is not used by any image so far). The bytes are identical to unpaced emission (FS-R-010 §5; `common/FSB1-SPEC.md` §9, `stage3b/IMAGE.md` §4) |
| **BA / BF / AF / AA** | the before/after state checks: **B**efore in **A**ndroid, **B**efore in **F**astboot, **A**fter in **F**astboot, **A**fter in **A**ndroid (method private). The BA → attempt dwell is ≤ 5 min |
| **misc rule** | how changes to the `misc` partition between BA and AA are classified (UNCHANGED / EXPECTED / RECORDED / STOP / INCONCLUSIVE) (`common/MISC-RULE.md`) |
| **DEADLINE / backstop** | PID 1's unconditional reboot time, counted from boot. HOST_ACK cannot cancel it. 200 s / 201 s for stage 3b (`common/DEADLINE.md`) |
| **BootStartUtc, Th, T0** | host time just before `fastboot boot` (the budget origin); when `fastboot boot` returned (evidence only); and kernel start |
| **runner guard** | the host-side refusal to start the device runner unless enough time is left before the host give-up: 91 s for stage 3b (75 + 5 + 11; FS-R-011 §2, `stage3b/IMAGE.md` §4) |
| **RunnerWorstSec** | the collector's figure for the runner's worst-case duration: 75 s for stage 3b (at least W); the guard adds `RunnerMarginSec` 5 s and the 11 s beep-and-pause interval (`host/COLLECTOR.md`, `stage3b/IMAGE.md` §4) |
| **W / B** | stage-3b timing-model terms (`stage3b/IMAGE.md` §4): **W** is the runner's worst case, summed from its parts (74.4 s); **B** is the record budget left for the runner after margins and the earlier phases (85 s) |
| **E1** | the clean-checkout check (`fs-gitcheck`) that builders and host tools run on pinned source trees |
| **stage-1 class / registered outcome** | the classification fixed before the attempt (`common/OUTCOMES.md`): PASS, COMPATIBILITY FAIL, DISPLAY FAIL, INCONCLUSIVE and so on. It is never re-graded afterwards (FS-R-009) |
| **kgate** | `tools/kgate`, the offline gate that checks a rebuilt kernel's exported symbol CRCs and `module_layout` against Meta's stock vendor modules |
| **BLU, TE, DSC, CRTC, TEST_ONLY** | backlight unit; panel tearing-effect interrupt; Display Stream Compression; the DRM scan-out pipeline; a DRM atomic commit that is only validated |
| **H1 / H2** | the two dark-panel hypotheses: the panel/BLU was off at takeover (H1), or restarting the link broke the panel (H2) (`docs/research/display-handoff-dark.md`) |
| **NCM / ACM** | USB network and serial gadget functions. The Quest 3 stock kernel has ACM. The Quest 2 has only NCM |
| **RAUC / `kernelsetup.sh` / `splctl`** | Valve's update framework and its boot-firmware writers. They never run on a Quest |
| **J-NN, FS-A-NNN, FS-R-NNN** | journal entry, Arbiter relay, Chair ruling |
| **Do-not N** | item N of the numbered **Do not go here** list in `docs/JOURNAL.md` |
| **review codes (M1, N1, m9, S1, S5 …)** | short local labels, defined where they are cited. In review rounds they are finding IDs from that round, defined in the cited JOURNAL entry or relay (or the review section of the document that cites them); in test suites and research notes they can be case or row IDs of that document's own tables (for example the slow-loris cases S1–S5 in `devices/quest2/channel/README.md` §5.2). The same code can mean different things in different places |
| **rule N** | with OUTCOMES: row N of a precedence table in `devices/quest3/common/OUTCOMES.md` (for example "rule 25", the stage-3b machine-side PASS row of §9.4). In `docs/PROJECT_SETUP.md` §6A, "rule 2" means item 2 there (bounded holds) or rule 2 of the fan policy |
| **checklist IDs (F7, H8, H9 …)** | rows of `docs/DEVICE_PORT_CHECKLIST.md` (letter = section, number = row) |
| **§1.1 host pins** | the host-tool SHA-256 table in FS-A-011 (private review record) §1.1 (identity and pins), concurred by FS-R-011 §1, plus the three host dependencies added by its clarification A (`devices/quest3/SIGNOFF.md` trial (iii-b)) |
| **LMh** | Qualcomm's Limits Management hardware: on-SoC CPU frequency limiting (a hardware clamp) under thermal or current stress; part of the hardware's own protection, not controlled by our images [C] |
| **walt, schedutil** | CPU frequency governors: walt is Qualcomm's Window-Assisted Load Tracking scheduler/governor used by Android; schedutil is the mainline Linux one |
| **msm-adreno-tz** | the Qualcomm Adreno GPU devfreq governor |
| **drvfs** | WSL's filesystem for Windows drives (`/mnt/c/…`); without the `metadata` mount option it cannot store Linux mode bits, so `fs-gitcheck.sh` reports mode bits as "not checkable here" |
| **cip128** | in the Quest 2 kernel version `4.19.325-cip128-…`: a Civil Infrastructure Platform (CIP, the long-term-support 4.19 kernel line) release tag |
| **FSK1** | the one-line skip record a stage-3b runner prints for a run it did not start (`FSK1 run=<n> skipped reason=<why> END`), so the step list never changes (`common/OUTCOMES.md`) |
| **FSDE1** | the display runner's refusal line (stages 3a/3b), printed instead of an FSB1 record (for example `FSDE1 error=record-too-large … END`); the host classifies it INCONCLUSIVE. Stage 2a's equivalent is `FSVE1` (`common/FSB1-SPEC.md`, `host/COLLECTOR.md`) |
| **PM-OBS2** | the PM's dark check: after the first (high) beep, the PM confirms the panels are dark during the collector's 10 s pause, before `fs-done` (`stage3a/IMAGE.md`, `RECOVERY.md`); trial (iii-b) keeps the same dark check |
| **B1 / C1** | the two FS-R-007 findings that held live concurrence for trials (i) and (iii): B1, host timing must use a conservative origin and count preparation delays; C1, correct the physical display-exposure claim. Both closed by FS-R-008 |
| **listing rule** | the acceptance rule for step 4 of trial (i) (`ld.so --list` on Valve's `b2sum`). The current version is amended rule A (`devices/quest3/stage2a/LISTING-RULE-A.md`, FS-R-009 §4) |
| **T1 pins** | the pinned hashes, ELF dependencies and provenance of the four genuine Valve files used in trial (i) (`devices/quest3/stage2a/T1-PINS.md`; FS-R-006 §5 A) |
| **SyncBoss** | Meta's on-headset microcontroller (MCU) and its command protocol (IMU and controllers). Unknown SyncBoss commands are never sent (`docs/PROJECT_SETUP.md` §6A item 8b) |
| **Holo Core** | a public aarch64 preview rootfs without Steam, SteamVR or `deckard-*` packages; it is not the Frame's shipped base (J-80; `docs/research/community-quest-repos-2.md`) |
