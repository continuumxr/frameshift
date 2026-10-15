# ArmadaVR (Producdevity) and the Armada family

*Edited for publication: names and links removed or paraphrased.*

Agent report, 2026-10-10. An offline review of
https://github.com/Producdevity/ArmadaVR, plus a short look at how it relates
to armada-os/armada and seilent/armada. Read through the GitHub API and web
page, then from a shallow source clone. Nothing was built or run. No device
was touched. No firmware or binaries were downloaded.

Tags: [M-static] read in their repo (path or commit cited) · [C] their claim,
not checked by us · [D] our inference · [O] open.

## Sources

| Short | Repo | Read at | Notes |
|---|---|---|---|
| **AVR** | Producdevity/ArmadaVR, `master` | `272b607` (2026-10-10 11:44 +0200) | 89 commits. History runs from `d3b6723` (2026-09-11). The GitHub repo was created 2026-10-07. 0 releases, 0 open issues, 4 stars, 1 fork (GitHub API, 2026-10-10) |
| **ARM** | armada-os/armada | API metadata + README + LICENSE.md only | "SteamOS-like ARM handheld distro". Org-owned, about 1.9k stars, pushed 2026-10-10 |
| **SEI** | seilent/armada | API metadata only | A plain **fork of armada-os/armada** (created 2026-10-03). Not VR-related |

Clone (source only, untrusted, nothing executed):
`%TEMP%\claude\...\scratchpad\dl\armadavr-src`. The tree has 283 files:
Python tools, Containerfiles, patches, docs and tests. A scan found no
`.bin`, `.so`, `.mbn` or `.fw` files. `.gitignore` excludes `output/`,
`.agents/` and `docs/validation.md` [M-static].

## 1. What ArmadaVR is

- **Goal [M-static README.md]:** "An experimental ARM64 Linux VR environment
  and headset board-support project." It **has no validated headset
  installation image** and states this plainly.
- **Targets [M-static README.md, docs/research.md]:** Quest 3 (primary) and
  Pico Neo3 Pro Eye. Neo3 Pro is a separate target. **No Quest 2, Quest Pro,
  Quest 3S or Quest 1 content exists in the tree.** The only "Quest 2" mention
  is a third-party shim (docs/steam-frame.md:335). No Quest 2 port can be
  checked from this repo [O].
- **Base distro:** a Fedora development environment (Fedora 44 container:
  systemd 259.8, glibc 2.43, from docs/headset-bringup.md), using Armada's FEX
  packaging, native Monado and OpenXR, and Proton. Steam Frame components
  (native ARM64 SteamVR, the Lepton Android container) are taken from Valve's
  recovery image and package repository into a **QEMU** lab [M-static
  README.md, docs/steam-frame.md, docs/steamvr-arm64.md]. Holo Core is listed
  as optional later [M-static].
- **Kernel strategy:** keep **Meta's vendor kernel**, built from
  facebookincubator/oculus-linux-kernel `dbc2bc83` (5.10.246, the same tree
  as our v2.7 `kgate27`). It merges `oculus_anorak_defconfig` +
  `oculus_eureka_defconfig` + a "Linux userspace" fragment (DEVTMPFS,
  namespaces, cgroup PIDs, SYSVIPC and similar), uses **ThinLTO** instead of
  full LTO (full LTO ran out of memory), and keeps CFI and PGO
  [M-static docs/headset-bringup.md, profiles/kernel/linux-userspace.config].
  Build results: 272 modules and 14 DTBs. The 272 names match the stock
  module set [C].
- **Boot method: none proven.** Their Quest 3 is a retail unit on build
  `52083180032000520`, kernel 5.10.237 (docs/device-installation.md:9-22).
  *[removed for publication]* Unsigned v4 boot containers
  are assembled **offline only** (docs/quest-boot-assembly.md). **Nothing
  has booted on a headset.** On hardware, the only result is Turnip
  offscreen rendering under **stock Android** (docs/turnip.md:169-201).
- **Activity:** very high. 89 commits, around the clock, between 2026-09-11 and
  2026-10-10 (`git log`). One author: Producdevity (GitHub handle). There is a
  `.agents/` ignore entry, and "local investigation journals" are excluded.
  The style suggests an agent-driven workflow, like ours [D].
- **Licence: none.** The GitHub API reports `license: null`. The repo has no
  LICENSE or COPYING file [M-static]. That means all rights are reserved by
  default. The only licence file is `patches/lepton/LICENSE` (Valve's
  BSD-style Lepton licence; it covers patches to Valve's Lepton 2.8.14
  launcher). Mesa, Monado and kernel patches carry no SPDX lines of their own.
  They modify MIT, BSL-1.0 and GPL-2.0 code, but the repo does not license our
  reuse of them [D]. **Bundled third-party binaries: none.** The tools fetch
  pinned upstream sources (AOSP mkbootimg/avbtool, Steam client, OpenVR,
  xpresent, qcom pd-mapper/qrtr) into `output/` [M-static tools/fetch-*.py].

**Relation to Armada [M-static docs/headset-bringup.md:140-172; ARM/SEI API]:**
armada-os/armada is a Fedora-bootc handheld distro. Device support comes from
ROCKNIX: kernel 7.2.3, a v0 boot image at `/KERNEL` on FAT, and 22 handheld
DTBs. It has **no Quest or Pico support**. LICENSE.md:
GPL-2.0-or-later for Armada's own code; bundled parts keep upstream terms
(Apache-2.0 Universal Blue tooling, ROCKNIX terms) [C]. ArmadaVR is a
**separate, non-fork** sibling. It reuses Armada's FEX packaging and Fedora
workflow, and explicitly rejects Armada's handheld boot setup and `/KERNEL`
updater for headsets. seilent/armada is just a fork of armada-os/armada. Its SM8250
kernel is what seilent's `pocket-micro-2` branch (already in our index) draws
on. Neither is VR work.

## 2. What is reusable or instructive, by area

ArmadaVR has no licence, so treat everything below as **ideas and facts to
reimplement**, never code to copy. Ask the author for a licence (same stance
as Quest1-SteamOS).

**Boot/init**
- ADSP → PMIC-GLINK → UCSI → DWC3 host-role chain, needed before **USB
  storage** appears (docs/quest-early-boot.md:13-41; script
  `system/quest/armada-quest-boot`). We already knew about the `boot_adsp`
  trigger (FS-A-006 (private review record):155). **New details [C, QEMU-modelled only]:**
  - wait for QRTR service-locator (service 64, v1, instance 1) *before*
    writing `boot_adsp`;
  - `ucsi_glink` has no module alias in the vendor build, so it must be loaded
    explicitly;
  - readiness = ADSP `running` + `PMIC_RTR_ADSP_APPS` rpmsg bound + UCSI port +
    DWC3 role `host`, each capped at 12 s;
  - never force host role.
- The pd-mapper must survive switch-root: `SurviveFinalKillSignal=yes`
  (`IgnoreOnIsolate` alone failed). Use `FailureAction=poweroff`, not an
  emergency shell, on a headset with no console (docs/quest-early-boot.md:125-147).
  These systemd lessons apply directly to our initramfs design [D].
- **Kernel Image size:** with CFI under LLD, an orphan `.eh_frame` lands after
  `_end`, so the raw Image is 2,404 bytes longer than its header's
  `image_size`. Loaders that check extents (quest-kexec) reject it.
  Fix: `patches/kernel/linux-userspace/0003-arm64-place-cfi-unwind-data.patch`
  (docs/device-installation.md:121-149) [C]. This matters to us only if we
  rebuild the kernel or use kexec [D].
> **Correction (J-96):** with an empty path, usermode helpers are a *successful no-op*
> (`kernel/umh.c:397-423`), so the kernel's forced fallback in `orderly_poweroff` never
> fires. A forced, unsynced power-off happens only via `thermal_emergency_poweroff`
> when `THERMAL_EMERGENCY_POWEROFF_DELAY_MS > 0`: 100 on Quest 3 v66, **0 on Quest 2
> v2.7: no software-forced power-off via the kernel thermal core; vendor notify hooks and the PMIC/TSENS hardware over-temperature protection were not assessed [O]**. Text below kept as written.
>
> **Narrowed (FS-R-011 §6, J-104):** "never fires" is too absolute: allocation failure
> or a disabled helper can still return nonzero and reach `__orderly_poweroff`'s forced
> fallback. Required wording: "The successful-no-op helper path supplies no dependable
> forced shutdown through the generic thermal core on this configuration." On the
> Quest 3 the positive delay schedules an emergency power-off *attempt*, not a
> guaranteed physical power-off 100 ms later.

- **`CONFIG_STATIC_USERMODEHELPER=y` with an empty path** blocks every kernel
  usermode helper. In their QEMU test, the thermal `orderly_poweroff` never ran
  and only the emergency fallback powered off the machine
  (docs/headset-bringup.md:126-137) [C]. **All our stock configs
  have it** (v2.7, v66, v71, v72, v76, v84 for Quest 3; v2.7 for Quest 2, 3S
  and Pro: `firmware/*/…/kernel.config`) [M-static, ours]. Consequences on a
  stock kernel [D]: no `/sbin/poweroff` from thermal criticals, no
  `request_module` autoloading, no core-dump pipe helper. Our userspace must
  load modules itself and must own thermal shutdown. This **is new to us**.

**Rootfs** (docs/headset-root.md): an offline-built root with matching modules
and firmware, and a QEMU handoff test that checks the image hash is unchanged.
It confirms what our notes already say: userdata and `vision` use wrapped-key
metadata encryption + FBE, and `persist` holds calibration
(docs/headset-bringup.md:291-298). Nothing new for us.

**Graphics: the most valuable part.**
- Mesa `freedreno_devices.py` lists chip `0x43050b00` as **FD740v3 / Quest 3**.
  KGSL firmware names: `a740v3_sqe.fw`, `gmu_gen70200.bin`, `a740v3_zap`
  (docs/headset-bringup.md:217-235). This answers our open point
  community-quest-repos-2.md:373 (does Turnip-KGSL support A740?): **yes,
  upstream** [C].
- **Physical result [C, docs/turnip.md:169-201]:** on stock Quest 3 Android,
  source-built Turnip first failed `vkCreateDevice` with
  `VK_ERROR_OUT_OF_DEVICE_MEMORY`. It worked after switching to **KGSL GPUOBJ
  allocation ioctls**, because the legacy alloc ioctl is unavailable under stock
  policy. Patch `patches/mesa/turnip/0006-kgsl-gpuobj-allocation.patch`
  is based on **Jbbrack03/Quest-3-Turnip-Driver** commit `b09a4535`, a repo new
  to us. Results: 32 buffer/fence checks and 16 shader-rendered frames. Stock
  drivers lack opaque-FD semaphores and direct-display support. The SDE DRM node
  returns `EACCES` from the shell.
- Patch series to study (Mesa 26.1.8 base): KGSL fence ownership, wait-any,
  **KGSL↔DRM-syncobj bridge** (`TU_KGSL_DRM_SYNC`), and a **KGSL display**
  helper (`TU_KGSL_DISPLAY`) that opens the SDE primary node for
  `VK_KHR_display` (docs/turnip.md:74-93). Kernel side: `DRIVER_SYNCOBJ |
  DRIVER_SYNCOBJ_TIMELINE` on the SDE `msm_drv` (13-line patch 0001) and a
  dma-buf sync-file import/export backport (0002). Compare these with
  YusufOzmen01's `9b68500d48` sync bridges (oculus-linux-kernel-yusuf.md:90).
  Two independent routes reach the same design [D].
- Monado `0001-direct-display-selection.patch`: explicit display, mode and plane
  selection for `vk_display`, keeping fake display timing (docs/monado.md:54-80).

**VR runtime:** a native ARM64 SteamVR (from Frame recovery
`20260922.5153644-0.3.0` and hotfix packages) in QEMU with software Vulkan.
Dashboard and Library work with virtual controllers, and Windows OpenXR runs
via Proton [C, docs/steamvr-arm64.md]. Useful pointers: the Frame stable
metadata URL, the RAUC bundle check against
`/etc/rauc/trusted_keys/`, and `steamwebhelper.sh` hard-coding `taskset 0x7c`
(docs/steam-frame.md:22-40, docs/research.md). This overlaps our Frame stack
map. Nothing has run on hardware.

**Tracking/controllers** (docs/quest3-tracking-protocol.md): it confirms
packet 80 = IMU (direct channel), the 104-byte UAPI record, an 800 Hz IMU rate,
and stock library names (`libsensordatatransforms.so` `transformImuData`,
`libcalibrationmanager` paths `imu_calibration.json` /
`camera_calibration.json`). It is **behind** quest-kexec-q2, which already
drives SyncBoss without libraries (cmds 110 and 133). Nothing new to reuse.

**Audio:** silent apart from "remaining". **Wi-Fi:** silent for Quest.

**Power/thermal/fan:** `patches/kernel/linux-userspace/0002-eureka-critical-thermal.patch`
adds Meta's 28 Android shutdown limits as kernel DT critical trips: battery
65 °C, skin 60 °C, 26 zones at 115 °C, with stock hysteresis
(docs/headset-bringup.md:98-124). Their source file has the same sha256 prefix
`c9301ff553f65255` as our v2.7 `thermal_info_config.json`, so the values match
[M-static, both]. This is an alternative or backstop to our userspace watchdog
(thermal-control-design.md). The usermode-helper caveat above applies. No fan
or battery-charging work.

**Packaging/installer/UX:** none for headsets. The installer is "last"
(docs/device-installation.md:337-340).

**Docs/process:** strong evidence discipline. Every claim is bounded ("this
does not establish…"), outputs are versioned and never overwritten, all
inputs are hash-pinned, tools refuse physical targets in VM tests, and there
is a read-only `tools/probe-device.py`. This is close to our own FS-R rules,
and a reasonable model for a "QEMU first" gate for userspace [D].

## 3. Safety and licensing red flags

1. **No licence on the repo.** We cannot copy code, patches or docs.
2. **Firmware sources.** A reference OTA came from an unofficial
   third-party mirror (docs/headset-bringup.md:241) and was not authenticated.
   Later, an exact OTA was "authenticated" against a certificate copied from the
   device. Their Meta firmware (ADSP, GPU, SyncBoss, controllers) and Valve
   images stay local in `output/`; **none is committed** [M-static scan].
3. **Steam sign-in.** `just desktop-online` signs in to Steam in the VM.
   Lepton and SteamVR payloads come from an authenticated Steam install. That is
   fine for personal use, but nothing of it may be redistributed [D].
4. **No forbidden boot-chain actions.** There is no boot-chain,
   protected-partition or MCU firmware write. They explicitly
   refuse such commands (docs/quest3-boot-route.md:88-91) and do not run
   Meta's firmware updaters (docs/headset-bringup.md:283-287). The Android
   container uses **"private Android Mesa builds"** that are not published [C].

## 4. Quest 3 panel/display findings for our dark-panel problem

**Nothing directly useful.** ArmadaVR has never driven a Quest panel. It
has no fastboot boot, no splash or handoff analysis, no DSC, BLU or
second-enable findings, and no "run twice" evidence. It lists panel variants
(BOE/JDI/Sharp `eureka-panel*.dtsi`) only as remaining work
(docs/headset-bringup.md:199). The only display-adjacent items come after
first light:
- the SDE syncobj patch, the KGSL display helper and the Monado plane/mode
  selection (§2);
- their note that DTBO index **8** = PVT1.1 on build `52083180032000520`
  versus index 11 at commit `063d9fb8` (docs/device-installation.md:29;
  docs/headset-bringup.md:67-70) [C]. Overlay index can move between builds,
  so we should read ours from the running unit [D].

The run-twice plan still rests on quest-kexec `4554025` and our own
display-handoff-dark.md analysis.

## 5. Proposed community-work-index paragraph

> **Examined 2026-10-10 (docs/research/armadavr.md):** Producdevity/ArmadaVR
> (`272b607`, **no licence**: ideas only, ask the author) is a Fedora + FEX +
> native Monado/SteamVR lab in QEMU for Quest 3 and Pico Neo3 Pro Eye. It uses
> Meta's 5.10.246 kernel (ThinLTO, CFI kept). Its Quest 3 is retail, and
> **nothing has booted on a headset**. There is no Quest 2 code. Reuse
> (reimplement):
> - Turnip-KGSL on A740 needs **GPUOBJ alloc** (from
>   Jbbrack03/Quest-3-Turnip-Driver `b09a4535`), proven offscreen on stock
>   Android; also its KGSL↔DRM-syncobj, `TU_KGSL_DISPLAY` and SDE
>   `DRIVER_SYNCOBJ` patches;
> - the ADSP→PMIC-GLINK→UCSI→DWC3 wait order (QRTR svc 64 first; load
>   `ucsi_glink` explicitly);
> - pd-mapper `SurviveFinalKillSignal` and `FailureAction=poweroff`;
> - Meta's 28 shutdown limits as DT critical trips;
> - the CFI `.eh_frame` Image-size fix.
>
> **Stock `STATIC_USERMODEHELPER=y` with an empty path** (in all our
> configs) blocks orderly_poweroff and module autoload. Avoid its
> unauthenticated third-party OTA. armada-os/armada (GPL-2.0+, ROCKNIX
> `/KERNEL`, handhelds) and seilent/armada (a plain fork) have no VR
> content.
