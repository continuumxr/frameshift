# FrameShift

> **Status: early development; nothing to install yet.** FrameShift has no
> release, no installer and no bootable SteamOS image. What is here is the
> engineering record: research, offline tools, test fixtures, and the small
> test images used for attended trials on the project's own headsets.

**Start here.** This file is the single entry point. If you are picking the
project up cold, read it top to bottom, then follow [How to resume](#how-to-resume).
Everything else in the repository is linked from here.

*Status as of 2026-10-14 UTC (JOURNAL up to J-172, latest ruling FS-R-011). **Display milestone (M2):** stage 3c showed the first correct image on Quest 3 Unit 1 (v66, J-125), and **stage 3d PASSED on both Quest 3 units on Horizon OS v2.7** (J-144, J-146), with the eye swap and the 21° roll corrected. The report on these runs (FS-A-012) is ready for the Chair (J-159). **Next milestone: K1a**, a FrameShift-built kernel booting by temporary boot on Unit 2 (package FS-A-013, in review); then the boot-chain guard, the full thermal service and **R-1 "SteamOS boots"**, the first big milestone (J-172). Decided since: the GPU route (J-154), a bridge architecture that never alters Meta's firmware or Valve's image (J-156), licences (J-157: code Apache-2.0, kernel parts GPL-2.0-only, documentation CC-BY-4.0), our own splash later (J-168, J-172), and tracking that starts with each device's own Meta controllers (J-160 to J-170). Nothing to install yet.*

*This status line is the project's single current-status source. Status lines
in other documents (`docs/PROJECT_SETUP.md` §7, `docs/JOURNAL.md` "Where we are
now", device and stage READMEs, `IMAGE.md` files) defer to it: where they
differ, this one wins.*

### Status in plain language

- **Works:** on a Quest 3, our own small init boots with the stock kernel by
  temporary boot, proves it is running over USB serial, and returns the
  headset to Android (Stage 1). Four genuine Valve files ran on it (trial (i); registered COMPATIBILITY FAIL at step 4, a listing-rule defect, FS-R-009).
- **Display:** our test images now show correct images on both Quest 3 units on
  Horizon OS v2.7 (stage 3d, J-144/J-146).
- **Not yet:** SteamOS itself. No Valve rootfs, systemd or rebuilt kernel has
  run on a headset, and there is nothing to install.
- **Next:** K1a, our own kernel by temporary boot on Unit 2 (FS-A-013); then the
  boot-chain guard, the full thermal service and R-1 "SteamOS boots" (J-172). The
  Quest 2 channel continues offline.

New here and not on the team? [Outsider quickstart](#outsider-quickstart)
says what you need, what builds and which tests run offline.

### Licence and notice (summary)

- Code (tools, host scripts, on-device services, fixtures and records): **Apache License 2.0**
  (`LICENSE`). Kernel patches in `kernel-patches/` and FrameShift's own kernel modules:
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
published as a single initial commit:
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
  device-state capture tooling, its firmware-update risk research and the
  documents of an earlier, shelved device programme. Each withheld folder has a short README;
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
| 1 | **Quest 3** | XR2 Gen 2 (`anorak`) | Horizon OS **v2.7** (kernel `5.10.246-gd7102a837402`) | **active**, primary. Both units on v2.7; stage 3d displayed correctly on both (J-144, J-146) |
| 2 | **Quest 2** | XR2 Gen 1 (SM8250-class) | **v2.7** (kernel `4.19.325-cip128-st12-g49638c7a8637`) | secondary. Unit on v2.7; offline channel built |
| 3 | Quest Pro | XR2+ Gen 1 (`kona`) | v2.7 (Quest 2 kernel tree) | offline/build only, in lockstep; no PM unit |
| 4 | Quest 3S | XR2 Gen 2 (`panther`) | v2.7 (Quest 3 kernel tree) | offline/build only, in lockstep; no PM unit |
| 5 | Quest 1 | MSM8998 | **v50** (final firmware; end of life, J-75) | queued |
| 6 | Vive XR Elite | XR2 Gen 1 (SM8250) | its own (HTC firmware) | shelved |

The build target is the **v2.7** release for Quest 3/2/Pro/3S. Trials are
meant to run on units that are themselves on v2.7. Booting a v2.7 kernel on
older firmware would be a hybrid (J-66). The firmware ceiling is v2.7: never
newer (PM, J-69). **Today both Quest 3 units are on v2.7:** the stage-3d image (the stock v2.7
kernel with our initramfs) displayed correctly on both (J-144, J-146). The next
device milestone is K1a, a FrameShift-built kernel booting by temporary boot on
Unit 2 (FS-A-013).

**Which unit runs what, today.** Both Quest 3 units are on v2.7 and are booted
only by temporary boot. Unit 1 ran every trial up to stage 3c (then on v66) and
stage 3d on v2.7; Unit 2 ran stage 3d and is the unit for K1a (our own kernel).

### Architecture at a glance

```
 Quest headset: requires an unlocked headset (assumed)
 +-------------------------------------------------------------+
 | Qualcomm boot chain + Meta ABL: kept as shipped, never      |
 | written by us (FS-R-001, Do-not 3)                          |
 |        | fastboot boot (temporary; no partition written)    |
 |        v                                                    |
 | kernel: Meta's stock kernel today; later our own v2.7 build |
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
- **What we boot:** Meta's stock kernel plus our initramfs today (stages 1,
  2a, 3a, 3b); later our own kernel built from Meta's published v2.7 source.
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
   its own baseline; its stock firmware was updated by the PM (official
   firmware; a new baseline is needed before any FrameShift action, FS-R-011
   §8). Every live trial concurred so far has been on Unit 1 only.
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

## Current state (2026-10-14)

### Milestones on hardware (Quest 3, by temporary boot)

| when | what | result | ruling |
|---|---|---|---|
| 2026-10-08 | **Stage 1**: stock kernel + our initramfs, USB ACM shell, nonce challenge | **ACHIEVED**: interactive shell, HOST_ACK, recovery to Android [M] (image `efefe10d…7250`) | FS-R-005 |
| 2026-10-09 | **Trial (i)**, stage 2a: four genuine Valve files (loader, libc, `uname`, `b2sum`) on the stock kernel, nonce `93a1501f0b1fb692` | stage-1 class PASS. Registered outcome **COMPATIBILITY FAIL, step 4**, which is a defect in the listing rule, not in Valve's code. Valve's `uname` and `b2sum` ran correctly [M]. Run remotely (a deviation): admissible with the deviation recorded | FS-R-009 |
| 2026-10-10 | **Trial (iii)**, stage 3a: first display test (static pattern, 10 s), nonce `17449af173f0633a`, PM present | stage-1 class PASS. Registered outcome **INCONCLUSIVE** (FSB1 line count: 1,024 bytes lost on the serial link). Inner records show the modeset commit accepted and the hold completed. **The PM saw no light in either eye** (backlight off). Battery 30 → 44 °C (cause [O]) | FS-R-010 |
| 2026-10-11 | **Trial (iii-b)**, stage 3b: revised display test (backlight 127, run 1 3 s, pause, run 2 10 s), nonce `6cf0f15867f14edc`, PM present | stage-1 class PASS; FSB1 VALID; **machine side PASS** (both commits accepted; run 2 from an inactive CRTC). **Optical [PM report]: run 1 dark, run 2 lit but garbled, both eyes**: the first light on a Quest 3 panel from our boot, but not a stage PASS (the characters were not readable). Battery highest observed 30.0 °C. Only `misc` changed (RECORDED) (J-107) | FS-A-012 to come |
| 2026-10-12 | **Stage 3c** (Unit 1, v66): 4 × 1032 planes, interactive per-phase flow | **STAGE PASS**: the first correct image (J-125) | PM executive decision (J-107); reported in FS-A-012 |
| 2026-10-13/14 | **Stage 3d** (Unit 2, v2.7): eye swap and 21° roll corrected | **STAGE PASS** (J-146) | PM executive decision; reported in FS-A-012 |
| 2026-10-14 | **Stage 3d** (Unit 1, v2.7) | **STAGE PASS** (J-144) | PM executive decision; reported in FS-A-012 |

No rebuilt kernel and no Valve rootfs/systemd has run on a headset yet
(Stage 2 proper is still ahead; see `docs/PROJECT_SETUP.md` §3 for the stage
definitions).

### In progress

- **Trial (iii-b)**, the revised display test. **Ran 2026-10-11 (J-107;
  milestone row above).** Next: analyse the captured probes (the garble
  suggests a frame-format mismatch: compression, pixel format or stride
  [C]), then a rerun with live phase markers (PM decisions, J-107;
  subsequent Unit 1 temporary-boot runs authorised as a PM executive
  decision, each still adversarially reviewed and signed off), and the
  FS-A-012 report to the Chair. History: **FS-R-010 concurred with
  *preparing* it** (not executing it), with binding design decisions: a
  mid-grey/white pattern with a preview, `panel0-backlight` = 127 before run 1,
  a 3 s hold then a 10 s hold at least 2 s apart, the plane layout unchanged,
  run 2 only after an accepted commit and a clean close, paced FSB1, and
  DEADLINE ≤ 200 s.
  - **Stage 3b package built offline (J-82):** `devices/quest3/stage3b/`.
    **Candidate image `ea60d6cd…5841`, nonce `6cf0f15867f14edc`**, DEADLINE
    200 s / backstop 201 s, runner guard 91 s (5 s spare), MAXLINES 2070,
    20-line pacing. Booted once, in trial (iii-b) (J-107); the nonce is
    spent. Fixtures: fs-pattern 109/109, pacing
    27/27, builder 10/10, image 12/12, host3b 116/116, host2 459/459.
  - **Reviews (J-82, J-96):** the first package's review found 2 MAJOR (record
    cap vs step caps; SIGNOFF thermal step), fixed and verified; the final
    margin round (`bb96b7a`) was covered by the FS-A-011 review. Withdrawn
    unbooted: `a09ff582…`, `00aca656…`, `c620c1b8…`.
  - **Host-side fix after review (J-97):** the stage-3b cue now says keep
    looking "until the SECOND (LOW) BEEP", matching SIGNOFF E
    (`host/fs-collect.ps1`); the image is unchanged.
- **Quest 2 USB channel (J-72):** `devices/quest2/channel/` rev 6, an NCM
  gadget with an IPv6 link-local address and a static fixed-verb responder
  `fs-rpcd`. Built and fixture-tested offline only, **never run on a
  headset**. FS-R-010 §7: the Chair needs the **complete channel folder**
  (source, gates, allowlists, harnesses, exact binary); it was supplied in
  the consolidated FS-A-011, and FS-R-011 §4 accepted continued offline work.
- **Quest 2 on v2.7** (build `52242990024200150`, slot b; J-74/J-75).
- **Kernel route (offline):** the v2.7 kernel gates passed for all four v2.7
  targets (J-31, J-32, J-36). The required wording is: "matches the checked
  symbol-version interfaces; complete module compatibility and runtime
  behaviour remain open" (FS-R-006 §2). The gate tool is `tools/kgate`
  (v2.3). Quest 3 builds are bit-reproducible only with the same path, four
  KBUILD pins and `setarch -R` (J-65).
- **Distribution and licensing:** research in
  `docs/research/valve-packages-licensing.md` (J-80; not legal advice). **The
  PM chose option 1** (J-83): our code plus an installer that fetches from
  Valve on the user's device. The PM's idea is to build everything around an
  **unmodified Valve image** that the user downloads and slots in. How that
  fits FS-R-001 (no unmodified Valve RAUC bundles; Valve's firmware and update
  hooks must never run; FS-R-001 R3 requires "a port-controlled
  transformation and review") goes to the Chair in the consolidated
  FS-A-011 (questions D1–D7; the revised FS-R-002 §6 defers kernel-side
  protection; the superseded original §4/§7 — guard requirements, build
  pinned during bring-up — are put to the Chair as guidance only).
  Architecture: `docs/research/valve-image-slot-in.md`; summary and Chair
  questions: `docs/PROJECT_SETUP.md` §0.0 (J-85).
- **New PM requirement (J-83): graceful emergency shutdown** for critical
  failures (thermal, battery, hang). Not yet designed. **Corrected (J-96):**
  the empty static usermode-helper path makes `/sbin/poweroff` a successful
  no-op. On the Quest 3 (v66, `THERMAL_EMERGENCY_POWEROFF_DELAY_MS=100`) a
  handled critical trip schedules an emergency (unsynced) power-off
  *attempt*; **on the Quest 2 (v2.7, delay 0) the successful-no-op helper path supplies no dependable forced shutdown through the generic thermal core on this configuration**
  (FS-R-011 §6 wording) [M-static config; D; vendor notify paths and
  hardware over-temperature protection not assessed, [O]]. This raises the priority of our
  own thermal ownership, especially for the Quest 2.
- **Firmware sourcing (J-83):** record every package's hash. The Arbiter
  downloads nothing without the PM's say-so.

### Hardware units

All units are unlocked headsets (assumed by the project).

| unit | firmware / slot | role and notes |
|---|---|---|
| Quest 3 **Unit 1** (`QUEST3UNIT1`) | **v2.7** `52433670036000520` (moved from v66 by the PM, J-131) | the `fastboot boot` test unit, never flashed by FrameShift. Stage 3c (on v66) and stage 3d (on v2.7) passed here (J-125, J-144). Faulty proximity sensor (J-133) |
| Quest 3 **Unit 2** (`QUEST3UNIT2`) | **v2.7** `52433670036000520`, slot `_a` (J-115) | stage 3d passed here (J-146); the unit for K1a, our own kernel by temporary boot (FS-A-013). Faulty IPD slider and proximity sensor (J-133) |
| Quest 2 (`QUEST2UNIT`) | **v2.7** `52242990024200150`, kernel `4.19.325-cip128-st12-g49638c7a8637`, **slot b** | secondary target. `fastboot boot` only; never flashed by FrameShift (its stock firmware was moved to Meta's official v2.7 by the PM, a PM executive decision). The unit is bound by `ro.boot.vbmeta.digest` `91b7f93d…` [M]. Shut down and unplugged at the end of J-75 |

No Quest Pro, Quest 3S or Quest 1 unit is used. The XR Elite is shelved.

---

## Next steps and open items (in order)

1. **Stage 3b review fixes: done** (J-82; final candidate `ea60d6cd…`,
   nonce `6cf0f15867f14edc`).
2. **Consolidated FS-A-011:** finalised as FS-A-011 (private review record) (J-101)
   after the review, fixes and verification (J-96–J-101). The sent draft is
   kept as FS-A-011 (private review record) (J-94/J-95). Bundles built and
   checked (J-102): `FS-A-011-r2-raw.zip` `0055df6d…25df0`,
   `FS-A-011-r2-image.zip` `84b96292…781d`. Sent 2026-10-11 (J-103).
   Ruled **FS-R-011** (J-104): trial (iii-b) concurred to execute.
3. **Trial (iii-b): RUN 2026-10-11 (J-107)** under FS-R-011 §1: machine
   side PASS; run 1 dark, run 2 lit but garbled. **Analysis done
   (J-108/J-109):** the panel was handed over asleep (run 1 is the wake
   step), and run 2's 2 × 2064 planes exceed per-pipe throughput (550 MHz
   MDP max); see `docs/research/display-pipeline-and-geometry.md`. Next: the
   **stage-3c rerun** (`devices/quest3/stage3c/DESIGN.md`: interactive
   per-phase flow with live markers, banners and sounds; run 2 as 4 × 1032
   planes with explicit zpos; an optional solid-colour run 3; no debugfs
   this run), designed → adversarially reviewed → built and tested →
   reviewed, run attended on Unit 1 with a fresh nonce, the
   `devices/quest3/SIGNOFF.md` sign-off, `devices/quest3/RECOVERY.md` and
   the FS-R-010 §6 temperature procedure, one step at a time; then report
   the trial and any reruns in **FS-A-012** (the next relay), disclosing
   the PM's executive decision.
4. **Quest 3 Unit 2:**
   - add the IPD fault to its baseline and to `docs/DEVICE_PORT_CHECKLIST.md`
     (J-69; check);
   - record a new baseline before any FrameShift action (FS-R-011 §8).
5. **Design the graceful emergency shutdown** (J-83) and fold it into
   `docs/research/thermal-control-design.md`. Priority raised by J-96 and
   accepted by FS-R-011 §6 (no dependable forced shutdown through the
   generic thermal core on the Quest 2 v2.7 config); it must inform the
   Quest 2 trial and sustained Valve-userspace operation.
6. **Installer and distribution architecture** around option 1 and the PM's
   unmodified-Valve-image idea, reconciled with FS-R-001. This is a question
   for the Chair.
7. **Later and parked:**
   - the Quest 2 thermal and recovery assessment (FS-R-010 §7), and the
     channel's open hardware questions (Windows `usbncm` binding, the UDC
     under our own init, timing);
   - Stage 2 proper: the Valve rootfs reaching a controlled systemd target;
   - the rebuilt-kernel route (SYSVIPC/POSIX_MQUEUE still excluded);
   - obtaining and diffing the SteamOS 0.4 stable image (J-47). Whether it
     has been obtained is [O];
   - checklist H items;
   - head tracking (parked, not dropped);
   - licence requests to the Quest1-SteamOS and ArmadaVR authors (PM, J-77,
     J-83).

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
3. **The latest ruling, FS-R-011 (private review record)**, plus FS-R-001 (private review record) for
   the safety boundary. Every `FS-R-*` is binding until superseded. The index
   is the relay index (private).
4. **The last relay:** the consolidated FS-A-011 (FS-A-011 (private review record),
   sent 2026-10-11, ruled by FS-R-011). The next relay is **FS-A-012**,
   the trial (iii-b) report: not yet written; its raw evidence is in
   FS-A-012 (private review record) (attempt log in `captures/attempt-log.md`). Trial
   (iii-b) (run 2026-10-11, J-107) used `devices/quest3/stage3b/README.md` and `IMAGE.md`,
   the trial (iii-b) sheet in `devices/quest3/SIGNOFF.md`,
   `devices/quest3/RECOVERY.md` and `devices/quest3/common/OUTCOMES.md` §9.
   The relay's other inputs included `devices/quest2/channel/README.md`.
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
| `devices/quest3/` | README; `RECOVERY.md`; `SIGNOFF.md`, `SIGNOFF-3c.md`, `SIGNOFF-3d.md` (sign-off sheets); `stage1/` (first shell); `stage2a/` (Valve files, trial i); `stage3a/` (display, trial iii, spent); `stage3b/` (trial iii-b, run 2026-10-11, J-107); **`stage3c/` (4-plane rerun on v66, STAGE PASS, J-125)**; **`stage3d/` (v2.7, both units, STAGE PASS, J-144/J-146)**; `common/` (PID 1 infrastructure: FSB1, DEADLINE, OUTCOMES, MISC-RULE, fs-supervise); `host/` (observer, collector, classifiers, captures); `evidence/` (withheld) |
| `devices/quest2/` | README; `PORT-PLAN.md`; `channel/` (NCM channel); `analysis/` (v2.7 DT extraction and stage 1); `evidence/` (withheld) |
| `devices/questpro/`, `quest3s/`, `quest1/`, `xre/` | per-device READMEs |
| `tools/kgate/` | offline kernel symbol-version gate (FS-R-006 §3) |
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
