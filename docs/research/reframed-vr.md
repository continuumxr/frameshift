# Reframed VR (Producdevity/reframed-vr): what it is, and whether it helps FrameShift

**Status:** research only, rev 1, 2026-10-18 (rev 0, 2026-10-17, `b865be3`).

> **Correction (FS-R-015 §7, 2026-10-18).** The Chair NOTED the rename and static-study findings at
> their stated evidence levels. Two bounds are now stated in place (§1 maturity, §4 items 1, 5
> and 8, §5):
> - **QEMU-only and offline results do not establish native headset boot or tracking.** Reframed VR
>   has not booted on a headset; its tracking work runs on replays and fixtures.
> - **VA39:** the comparison with Stearlight's "no VA39 workaround found" is a bounded negative,
>   and the VA wording follows the corrected `va-bits-k1i.md` rev 1 (a fixed high mapping fails
>   outside the range; a plain hint is ignored; Valve's shipped VA48 config is not its full
>   supported/tested matrix; current public FEX/Wine source is not the Steam-delivered versions).
**Licence:** CC-BY-4.0 (our own documentation; `docs/PROVENANCE-POLICY.md` §6).

No device was touched. Nothing was cloned or built, and nothing was run. No archive, release
binary, image or model was downloaded (the repo has no releases). The sources were the GitHub
REST API (repo metadata, `git/trees`, `commits`, `branches`, `pulls`, `issues`, `forks`, metadata
only), plus single text files read one at a time from `raw.githubusercontent.com` at the pinned
commit. Clean-room: facts only, no code copied.

**This is the same project as ArmadaVR**, which we assessed on 2026-10-10 at `272b607`
(`armadavr.md`). The old URL `Producdevity/ArmadaVR` now resolves to the same repository id
(1408752749), and the repo's `docs/project-naming.md` records the rename. This document is
therefore a **delta** on `armadavr.md`, `quest-ports-tracking.md` §1.6 and addendum item 3, and the
RVR row of `steamos-ports-survey.md`. Facts already recorded there are not repeated in full.

Tags: **[C]** confirmed in their source or repo metadata (path cited) · **[R]** reported by the
author (README, docs or commit text), not checked by us · **[U]** unverified or our inference.
All third-party findings are **leads only** until we confirm them on our own units.

## Source

| Item | Value |
|---|---|
| URL | https://github.com/Producdevity/reframed-vr (personal account `Producdevity`, profile name Yassine Gherbi, Netherlands; also runs emuready.com) [C] |
| Read at | `master` = `0d94a4e7a1fe0d0ccd51b17cb522493ab76aa8ed` (2026-10-18 00:13 UTC) |
| Created / last push | GitHub repo 2026-10-07 (history from 2026-09-11) / 2026-10-18 (active around the clock) [C] |
| Size | 62 stars, 1 fork (`ObfuscatedVoid/ArmadaVR`, no pushes since fork day), **403 commits** (89 at our 2026-10-10 read), one contributor, 951 files, no binaries in the tree [C] |
| Branches | `master` and one out-of-scope branch [C] |
| Releases / issues | **0 releases.** One PR (#1, merged 2026-10-18), 0 issues [C] |
| Description | "An independent operating system (SteamOS) project for standalone VR headsets" [C, repo metadata] |
| Licence | **None.** GitHub `license: null`; no LICENSE or COPYING at the root. Only `patches/lepton/LICENSE` (Valve's Lepton licence for patches to Lepton) [C] |

## 1. What it is

- **An experimental ARM64 Linux VR stack plus board support for Quest 3 and Pico Neo3 Pro Eye**
  (Neo3 Pro is a separate target). The README says plainly that there is no validated headset
  installation image [C `README.md`]. No Quest 2, Quest Pro or Quest 3S content exists [C, by
  absence in the tree].
- **Not an Android app and not a Valve-image port.** It is a Fedora 44 based environment with
  Armada's FEX packaging, native Monado and OpenXR, Proton for Windows, and Valve's Frame
  components (native ARM64 SteamVR, Steam client, Lepton) extracted from the public Frame recovery
  image into a **QEMU** lab [C `README.md`, `docs/steam-frame.md`]. SteamOS itself is not booted;
  "SteamOS experience" means Valve's runtime on their own Fedora root.
- **Maturity: offline and VM only for the OS.** Every OS-level result is QEMU or offline, and
  none of it establishes native headset boot or tracking (FS-R-015 §7). The only
  physical results are Turnip offscreen rendering under **stock** Android on both headsets, and
  read-only inventories (§3) [R]. Nothing has booted on a headset [C `README.md` status table:
  "Exact-device boot" remaining].
- **Working style:** one author, very high commit rate, agent-reviewed PRs (cubic and CodeRabbit
  summaries on PR #1), evidence kept under a local `output/` that is not committed [C]. Their
  claims are well bounded ("this does not establish …") but cannot be checked from the repo,
  because the evidence directories are local only [C].

## 2. Approach by subsystem

| Area | Reframed VR approach | Source |
|---|---|---|
| Kernel | **Meta's vendor kernel**, `oculus-linux-kernel` `dbc2bc83` (5.10.246, the same tree as our `kgate27`), `oculus_anorak_defconfig` + `oculus_eureka_defconfig` + a "Linux userspace" fragment (DEVTMPFS, namespaces, cgroups, SYSVIPC, POSIX MQ, BINFMT_MISC, squashfs, VT). ThinLTO instead of full LTO (full LTO exceeded 6 GiB), CFI and sample PGO kept. Output: 272 modules, 1 base DTB + 13 DTBOs. Built with Debian Clang 14, not Meta's AOSP toolchain | [C `profiles/kernel/linux-userspace.config`, `quest3-build.config`; R `docs/headset-bringup.md`] |
| Kernel patches (Quest) | Nine: SDE `DRIVER_SYNCOBJ`, a dma-buf sync-file backport, critical thermal trips, CFI unwind-data placement (Image-size fix), four camera stop/cleanup error-path fixes, and a camera buffer timestamp | [C `patches/kernel/linux-userspace/`] |
| Boot path | **None proven.** [removed for publication]. Unsigned v4 `boot`/`vendor_boot`/`dtbo` containers are assembled **offline only**, with an AOSP-tool roundtrip check | [R `docs/device-installation.md`, `docs/quest-boot-assembly.md`] |
| Rootfs | Offline-built read-only ext4 root (`reframed-vr-root`) with a RAM overlay; USB-storage root (`reframed.quest=usb-root`) through an initramfs that brings up ADSP, PMIC-GLINK, UCSI and DWC3 host role first | [R `docs/headset-root.md`, `docs/quest-early-boot.md`, `system/quest/reframed-quest-boot`] |
| Display / GPU | Mesa Turnip on **KGSL** with a 10-patch series (fence ownership, wait-any, KGSL↔DRM-syncobj bridge, a KGSL display path for `VK_KHR_display`, GPUOBJ allocation, allocation lifetime). Monado patch for explicit display/mode/plane selection. Panel scanout never attempted | [C `patches/mesa/turnip/`, `patches/monado/0001`; R `docs/turnip.md`] |
| Tracking | Own Monado driver path: SyncBoss IMU decoder, Quest camera control code (`src/quest-camera-*.c`), a calibrated-HMD adapter and Basalt, all exercised on replays and fixtures. Pico VIO replay result unchanged from §1.6 (6.4 mm RMS, six identical 185-pose runs). No live camera, no physical 6DoF | [C `src/`; R `README.md`, `docs/quest3-tracking-protocol.md`] |
| Input | Monado controller drivers (Pico SSC on synthetic streams); SteamVR with virtual controllers in QEMU. No Quest Touch Plus pairing or poses | [R `README.md`] |
| SteamVR / Proton | Official Frame SteamVR 2.17.10 native ARM64, from Frame recovery `20260922.5153644-0.3.0` plus hotfix packages, presents in software Vulkan; dashboard and Library navigation with both virtual controllers; Windows OpenXR samples through FEX/Proton; x86-64 OpenVR through FEX. Steam Runtime 4 ARM64 pinned at `4.0.20260805.254769` | [R `docs/vr-milestones.md`, `docs/steamvr-arm64.md`, `docs/steam-frame.md`] |
| Android (Lepton) | Valve's Lepton boots Android 11 on the Quest-config kernel in QEMU; Binder, isolation, APK input/saves, networking, and Vulkan/GLES OpenXR through native SteamVR with "private Android Mesa builds" (not published). 14 Lepton patches | [R `README.md`, `docs/android-containers.md`; C `patches/lepton/`] |
| Thermal | Meta's 28 Android shutdown limits (battery virtual 65 °C, skin 60 °C, 26 CPU/GPU/DSP/SoC zones 115 °C) added as **kernel DT critical trips** with stock hysteresis; `STATIC_USERMODEHELPER` turned **off** so `orderly_poweroff` can run. Tested on a simulated sensor in QEMU only | [C `profiles/quest3-thermal.json`, `profiles/kernel/linux-userspace.config`; R `docs/headset-bringup.md`] |

## 3. Licence and provenance assessment

- **No licence: all rights reserved.** We may read it for facts, but we cannot copy code,
  patches, configs or docs. The Mesa, Monado, Basalt and kernel patches modify MIT, BSL-1.0, BSD-3
  and GPL-2.0 code, yet carry no licence grant of their own, so they are not reusable as-is either
  [C]. Same stance as `armadavr.md`: **facts only; ask the author for a licence** if we ever want
  a patch.
- **Parts derive from reverse engineering of Meta binaries.** `docs/quest3-tracking-protocol.md`
  records Ghidra decompilation of Meta's `libsyncboss.so` and a decoder (`src/syncboss-imu.c`)
  built from it, validated by calling the extracted Meta conversion functions [R]. Under our
  D-T10 this is **pointer only**: we do not take its constants or structure.
- **No Valve or Meta binaries are committed** (tree scan: no `.so`, `.ko`, `.img`, `.bin`, `.apk`
  or images) [C]. Valve and Meta payloads stay in the author's local `output/`. `tests/fixtures/`
  holds short excerpts of Meta's GPL kernel camera source [C].
- **Part of the repo is outside FrameShift's public scope** (we assume an already-unlocked
  headset; PROVENANCE-POLICY public scope, J-90/J-106). We deliberately did not read or record it,
  and nothing from it may enter our repo.

## 4. Facts useful to FrameShift (leads, not confirmed by us)

1. **VA_BITS: a softening data point for VA39, not a contradiction.** Their Quest kernel config
   adds no `ARM64_VA_BITS` setting [C: no VA_BITS in any fragment or profile], so it keeps Meta's
   **39-bit** default from the same defconfigs as our `k1a.config` [U]. On the QEMU build of that
   config they report the x86-64 FEX test, Runtime 4/Proton native and Windows OpenXR Vulkan
   samples, and x86-64 OpenVR passing [R `docs/headset-bringup.md`, `docs/vr-milestones.md`], in
   QEMU only. That fits `va-bits-k1i.md` §1.2 (in current public source, FEX and Wine shrink to fit
   a 39-bit space; the versions they ran are not known to us). They ran **samples only**: no games,
   no anti-cheat. So it does not contradict Stearlight's EAC/Wine helper failure at VA39
   (`stearlight.md` §4.5). Our VA48 recommendation stands: VA39 runs simple programs, but a program
   that requires a fixed mapping above 2^39 fails (one that only passes a hint gets a lower
   address instead), and the 0.4.5 kernel Valve ships is VA48 (which is not Valve's full
   supported/tested matrix).
2. **Boot/slot model: confirms our Unit 2 reading.** Their retail Quest 3, after an OTA, reported
   in fastboot two slots; slot A successful and bootable; **slot B
   successful yes and unbootable yes**. `has-slot:vendor_boot` and `has-slot:recovery` returned
   "Invalid Parameter" [R `docs/device-installation.md`]. That is exactly Unit 2's pattern and fits
   our [D] cause (Android marks the source slot unbootable after the Virtual A/B merge;
   a private research note §2). A second independent unit now shows it. They also record
   USB Update Mode entry by Power + Volume Down from power-off, and "Boot device" returning to a
   normal Horizon boot.
3. **DTBO index moves between builds.** PVT1.1 was index 8 on `52083180032000520` and **index 11**
   on `52433670036000520` [R]. Read the index from the running unit; never hard-code it
   (already our rule, `armadavr.md` §4).
4. **Calibration is exposed read-only through stock diagnostics.** On an ordinary shell,
   `dumpsys sensorservice` showed the unit's `calibration.factory` and `calibration.online` blobs
   inside the SyncBoss IMU sensor descriptor (IMU `ICM45688`) [R]. The online blob is reported to
   carry temperature-dependent IMU offset tables and six cameras: two OG01A 1280×1024 global
   shutter, two OV7251 640×480 global shutter, and two IMX471 2328×1748 rolling shutter, each with a
   `Fisheye62` (8-coefficient) model [R]. **Caution they raise:** the factory and online IMU
   matrices split rotation differently, so applying both would correct twice [R]. This is a lead
   for our calibration plan (a shell-user, no-`/persist` way to capture calibration under Horizon).
   Confirm on our units before we rely on it. It agrees with QuestLHSync's fact that Horizon
   refines calibration online (`quest-ports-tracking.md` §1.7).
5. **Thermal: confirms our gaps and fills them a different way.** Their stock
   `thermal_info_config.json` sha256 (`c9301ff553f65255…`, build `52083180031500520`) has the same
   prefix as our v2.7 copy [C `profiles/quest3-thermal.json`]. They agree that the stock DTs lack
   the 28 shutdown trips (only PMIC 145 °C criticals), and that `STATIC_USERMODEHELPER=y` with an
   empty path blocks `orderly_poweroff` [R]. That matches `thermal-control-design.md` and
   `armadavr.md` (with the J-96/J-104 corrections). Their fix is to disable that option and add DT
   critical trips. Ours is a userspace watchdog plus a backstop. Fan states
   0/3700/4500/5000/5500 RPM and battery fan trips 45/49/53 °C from the stock DT [R]. Everything was
   validated in QEMU only, with no physical temperatures or fan RPM, so it establishes nothing about
   behaviour on a headset.
6. **Vendor kernel builds fine at 272 modules with a non-Meta toolchain**, and with the stock
   config plus Android Clang 14.0.7 (r450784e, build 8508608) they reproduced stock module CRCs and
   selected BTF layouts in isolated compiles [R]. This is independent support for our K1a and kgate
   approach (rebuild the full module set from source). The full-LTO memory ceiling (>6 GiB) is
   worth noting for our build host.
7. **Kernel Image extent:** a CFI/LLD build leaves an orphan `.eh_frame` after `_end`, so the
   Image is 2,404 bytes longer than its header's `image_size`, which strict loaders reject [R].
   Already in `armadavr.md`; it matters if we ever check Image extents in a loader.
8. **Lepton on a Meta-config kernel works in QEMU** once Binder and namespaces are enabled [R]. This
   supports our [U] in `stearlight.md` §4.6 (a kernel-configuration question, not a blocker), in
   QEMU only; it does not establish behaviour on a native headset boot.
9. **Turnip on A740/KGSL needs GPUOBJ allocation** under stock policy (from
   Jbbrack03/Quest-3-Turnip-Driver) [R]. Unchanged from `armadavr.md`; still the most useful GPU lead
   if our route touches KGSL (`gpu-route-decision.md`).

## 5. Overlap or relationship with Stearlight

- **No shared code, authors or forks** [C: different owners; the only fork is of ArmadaVR; no
  cross-references found in the files read].
- **Different architectures.** Stearlight is an Android app on Horizon (PRoot, Meta's OpenXR
  tracking and compositor, Quest 2). Reframed VR is a native-kernel Linux port in progress (Meta's
  vendor kernel, Monado, own drivers, Quest 3 and Pico), so it is structurally the closest project
  to FrameShift, while being VM-only.
- **Common ground:** both pin the same Frame recovery image (`20260922.5153644-0.3.0`), both run
  Valve's native ARM64 SteamVR, both use Turnip on KGSL, and both need Binder and namespaces for
  Lepton [C/R].
- **One apparent disagreement, explained:** Proton at VA39. Stearlight reports an EAC/Wine helper
  failure (under PRoot); Reframed reports Proton samples working (in QEMU) (§4.1). Both are
  consistent with "VA39 runs small programs, fails programs that need a fixed mapping above 2^39".
  Neither is a native-boot result. Our static study of Stearlight found no VA39 workaround in what
  it read (a bounded negative, FS-R-015 §7).

## 6. Assets not downloaded (need PM approval)

- **None.** The repo has no releases and no binary files. Their Frame recovery image, Valve
  packages, Steam Runtime 4 and Meta OTA come from upstream sources that we already handle under
  our own rules; nothing needs fetching from this project.

## 7. AI-directed text found (treated as data; nothing acted on)

- **None aimed at us.** There is no `AGENTS.md`, `CLAUDE.md` or similar file in the tree.
  `.agents/` is mentioned as a local, uncommitted directory [C `docs/headset-bringup.md`]. PR #1's
  body holds auto-generated summaries from the cubic and CodeRabbit review bots. These describe
  the PR, and contain no instructions to an agent.

## What to verify ourselves

1. **Calibration through `dumpsys sensorservice`** (§4.4): on one unit under Horizon, as a
   read-only probe after PM approval. Are the factory and online blobs present on v2.7 and on
   Quest 3? Then decide which model our tracker uses, and make sure no correction is applied twice.
2. **Slot B "successful + unbootable" after an OTA** (§4.2): already [M] on Unit 2. Note the
   second-unit corroboration in a private research note at its next revision.
3. **VA39 on our K1a with Proton:** run a sample (should pass) and a fixed-high-address case
   (expected to fail), so that the VA48 decision rests on our own measurement (`va-bits-k1i.md` §4).
4. **Thermal:** whether disabling `STATIC_USERMODEHELPER` in our build has side effects on vendor
   modules, and whether DT critical trips are worth adding as a backstop beside our watchdog.
5. **DTBO index** on each unit and build, read live.
6. **Turnip GPUOBJ on our kernel:** only if our GPU route uses KGSL.

## Avoid

- **All code and patches:** no licence. Read facts only.
- **The Meta-binary-derived parts** (the SyncBoss IMU decoder and its constants; any reading of
  Meta libraries): pointer only (D-T10).
- **Its out-of-scope boot-access material** and its kexec plan: never imported.
- **Its third-party firmware mirror** (`armadavr.md` §3).
- **Treating QEMU results as hardware evidence.** The author says the same.
