# Stearlight OS (amichyrpi/stearlight): what it is, and whether it helps FrameShift

**Status:** research only, rev 1, 2026-10-18 (rev 0, 2026-10-17).

> **Correction (FS-R-015 §7, 2026-10-18).** The Chair NOTED the rename and static-study findings at
> their stated evidence levels, with two bounds now stated in place (§1, §4.5):
> - **"No VA39 workaround found" is a bounded negative.** It covers what our static study read (the
>   `temp-build` sources zip, which is not the full repository, and the built APK; private notes
>   `<private note, withheld>` §5, `<private note, withheld>` §4). It does not show that no
>   workaround exists.
> - **A PRoot application does not establish native headset boot or tracking.** Stearlight runs as
>   an app on Horizon, on Meta's kernel, compositor and OpenXR tracking; its earlier phase was
>   VM-only. Neither tells us how Valve's userspace behaves when booted natively on our own
>   kernel, or how tracking works without Horizon.
**Licence:** CC-BY-4.0 (our own documentation; `docs/PROVENANCE-POLICY.md` §6).

No device was touched. Nothing was cloned or built, and nothing was run. For this note (rev 0) no archive, release
binary, APK, image or model was downloaded (the sources zip and APK were later downloaded for a private static study, J-198). The sources were the GitHub REST API (repo metadata,
`git/trees`, `commits`, `releases` and `issues`, metadata only), plus single text files read one at a
time from `raw.githubusercontent.com`. Some larger source files were read through a fetch tool that
summarises a page (`quest_wsi.cpp`, `quest_main.cpp`, `steamvr-native`, `power-bridge.h`,
`build-rootfs.sh`, `Containerfile`, `proot/robust.c`, `run-linux-debug.ps1`). Claims about those
files are only as exact as that summary. Clean-room: facts only, no code copied.

Tags: **[C]** confirmed in their source or repo metadata (path cited) · **[R]** reported by the author
(README or commit text), not checked by us · **[U]** unverified or our inference.

## Source

| Item | Value |
|---|---|
| URL | https://github.com/amichyrpi/stearlight (personal account `amichyrpi`, author "Amory Hen") |
| Read at | `main` = `3e4c857883a798c5fa60b840d56ab465ef21ee1d` (2026-10-17 23:20 UTC) |
| Created / last push | 2026-08-01 / 2026-10-17 (active daily) [C] |
| Size | 12 stars, 0 forks, about 116 commits, 1 open issue (#12) [C] |
| Releases | `temp-build` (2026-10-17): `stearlight-quest.apk` at about 2.1 GB, a 310 MB sources zip, SHA256SUMS. `continuous` (2026-08-02): a 1.6 GB Windows VM zip. **Not downloaded** [C] |
| CI | The `Quest APK` workflow on `64f32e94ee` failed, and the run on `66ee659cda` was cancelled. Per issue #12, the author ran out of Actions minutes and the APK was uploaded by hand as `temp-build` [C] |
| Licence | **FSL-1.1-ALv2** (`LICENSE.md`, "Copyright 2026 Amory Hen"). GitHub reports `NOASSERTION` [C] |

### History, in three phases [C commit log]

1. **2026-08-01 to 08-29: "H.265 SVRT"** (README at `0d5602afd6`). A Windows D3D11 SteamVR driver
   streamed HEVC to a Raspberry Pi 4 receiver (SDL KMS/DRM, FFmpeg `hevc_v4l2request`). The README
   said it included code adapted from the GPL-2.0 "Vanilla" project for DRM scanout. Not
   VR-headset related.
2. **2026-08-29 to 10-05: a SteamOS/Frame VM.** First an x86 VM, then an ARM64 "Frame VM" for
   Windows through QEMU and virtio-venus (`dd6ab1de7a`, `packages/windows-runtime/`), with a fake
   tracking driver (`packages/stearlight-runtime/fake_tracking.cpp`). The README now calls this
   phase unmaintained [R].
3. **2026-10-06 onward: the Quest APK.** It starts with "Frame on quest" (`8f2a266fd4`, +2876
   lines). Later commits add passthrough, audio, standalone games, hand tracking (`473cdf05a3`),
   Touch gamepad mode (`3edd21f64c`), desktop mode, update channels and USB networking.

## 1. What it is

- **An Android app for stock Horizon OS. It is not an OS install.** `AndroidManifest.xml` declares
  `net.stearlight.quest`, a VR launcher activity, and `com.oculus.supportedDevices = quest2` [C]. The
  app unpacks an ARM64 Linux rootfs into its private data and runs it under a patched **PRoot**
  (Termux proot 5.1.107.96, built against the Termux talloc and libandroid-shmem; see
  `build_files/quest/dependencies.json`) [C]. The base userspace is **Alpine edge**. Valve's pieces
  are layered on top: the SteamVR tree, the Steam client subset, gamescope, and Frame HMD settings,
  all copied from the public Steam Frame recovery image. `build_files/quest/build-rootfs.sh` mounts
  that image read-only (btrfs `subvolid=5`) and stages the files [C]. The pinned image is
  `steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2` (`packages/sources.lock.json`) [C].
- **Target hardware: Quest 2 only.** The README says Adreno 650 and "Quest 2 runtime
  (experimental)". Eye buffers are capped at 1374 x 1440 (75 % of the Quest 2 panel). The driver
  serials are `STEARLIGHT-QUEST2-*` and the model is "Oculus Quest2"
  (`packages/quest-runtime/linux/quest_driver.cpp`) [C]. There is **no Quest 3 path**: no Adreno 740
  handling, Quest 3 render models or Quest 3 manifest entry [C, by absence in the tree]. It might run
  on a Quest 3 as an ordinary app, but nobody reports trying [U].
- **Maturity: an early alpha.** It moves very fast and is written largely with AI agents.
  `CONTRIBUTING.md` asks contributors to name the model they used. Branch names are
  `t3code/recreate-steamvr-dashboard-ui` [C]. The tree has unit tests for its adapters
  (`packages/quest-runtime/tests/`) [C]. The only known issue listed is "really slow due to the
  emulation system" [R].
- **What its results do and do not show (FS-R-015 §7).** Everything it reports runs under PRoot on
  stock Horizon, or (in the archived phase) in a VM. That does not establish native headset boot
  or tracking: there is no own kernel, no native display path and no tracking of its own (it reads
  Meta's poses through OpenXR).

## 2. What works, by evidence

Nothing here is independently verifiable without installing the APK, which is out of our scope.
Everything below is the author's report [R] (`packages/quest-runtime/README.md`), and it all applies
to **Quest 2 under Horizon OS**:

- Valve's dashboard, docks and lasers display in stereo. Head and Touch poses come from OpenXR.
- The README's screenshot shows Celeste running locally (x86, FEX). VTOL VR launched from Steam:
  the room tracks and the controllers select menus. Flight gameplay was not verified.
- Flat (non-VR) Steam Link streaming and PCVR streaming through `vrlink` work, the latter shown with
  VRChat menus in stereo. Streaming over USB NCM also works.
- An OS update completed from the 0.5.6 Beta image (`20261015.6141207`).
- Not verified, by the author's own account: physical Bluetooth pairing, Bluetooth sign-in,
  sustained 120 Hz, the Frame Android (Lepton) APKs, and local Windows VRChat.

The only evidence beyond the text is a single screenshot (`assets/celeste-passthrough-2026-10-13.png`,
not opened) and per-commit claims. We found no logs or captures in the repo [C].

## 3. Approach by subsystem

| Area | Stearlight approach | Source |
|---|---|---|
| Boot | None. Launched from the Quest app library. Horizon boots as normal. "The updater does not flash Quest partitions or update Android firmware." | [C] manifest; [R] README |
| Kernel | Meta's stock Quest 2 kernel, reached through PRoot's ptrace syscall translation. A GPL-2.0-or-later PRoot extension (`packages/quest-runtime/proot/robust.c`) emulates robust futexes, which Android blocks, and makes uname report the hostname `frame`. A fast path passes KGSL ioctls and some futex calls straight to the kernel (`proot/syscall-fast-path.h`). | [C] |
| Display | Meta's compositor through OpenXR (GLES binding, sRGB swapchains, `XR_FB_display_refresh_rate`, requesting 72 Hz). Linux side: a Vulkan **ICD wrapper** around Turnip (`linux/quest_wsi.cpp`). It fakes Xcb/Xlib surfaces and `VK_KHR_display`, hands dma-bufs over a SEQPACKET socket (`gpu.sock`, `SCM_RIGHTS`), and attaches eye poses to each present. In `vrcompositor` it rewrites some Valve shaders and pipelines (colour, room view, a star mesh). SteamVR runs with `direct_mode` off. | [C] |
| GPU | Turnip (Mesa 26.1.6 built from Debian source with patches, `build_files/quest/patch-mesa.py`) over the stock **KGSL** driver. Zink is used for GL, ANGLE runs on Turnip for CEF, and Chromium uses software rendering. | [C] deps; [R] README |
| Tracking | **Meta's tracking via OpenXR**: views, head, grip and aim poses in STAGE space. These go into an mmap'd seqlock file read by a custom OpenVR driver (`quest_driver.cpp`). STAGE bounds become a `.vrchap` file passed through `Prop_DriverProvidedChaperonePath_String`. The app writes no tracker of its own. | [C] |
| Controllers | Touch is read through OpenXR actions. The driver presents Touch as Valve's **`frame_controller`** input profile, and haptics return over a UNIX datagram socket. Hand tracking uses `XR_EXT_hand_tracking`, `XR_FB_hand_tracking_aim` and `XR_FB_hand_tracking_mesh`. | [C] |
| Audio | PulseAudio in Linux is bridged to Android AudioTrack and AudioRecord (48 kHz). PipeWire and WirePlumber are used for `vrlink`. | [C] `linux/audio.pa`, `AudioBridge.java` |
| Thermal / power | **None of its own.** It sets OpenXR `XR_EXT_performance_settings` to CPU/GPU `SUSTAINED_HIGH`, with CPU `BOOST` while loading (README: at most 15 s per 75 s). Horizon keeps control of clocks and thermal limits. Battery data is emulated read-only as UPower on D-Bus from an Android-written `device.json`: no throttling, no fan or clock control (`linux/power-bridge.h`). | [C]; [R] |
| Storage | The rootfs sits in app-private storage. The OS update downloads Valve's ARM64 Frame image (RAUC signature checked against pinned Valve certs `linux/steamdeck-images.pem` and `steamos-dev-images.pem`). It then **extracts SteamVR** into staging inside the app and never writes partitions. | [C] files; [R] behaviour |
| Network / BT | NetworkManager and BlueZ D-Bus adapters front Android Wi-Fi and Bluetooth (`linux/network-bridge.h`, `linux/bluetooth-bridge.cpp`). USB uses Horizon's consent-based NCM. | [C] |

## 4. Facts worth learning (clean-room, no code taken)

These concern Valve's Frame userspace on non-Valve hardware, which is the layer FrameShift shares
with Stearlight.

1. **Frame gamepad mode is gated on undocumented property 2117.** A comment in
   `quest_driver.cpp` says the Frame controller profile in SteamVR 2.18 enables gamepad mode on
   `ETrackedDeviceProperty` 2117, which is not yet in the public OpenVR SDK. The driver sets it to
   true for Touch and false in hand mode [C comment; R behaviour]. This is relevant to our input
   bridge (`tracking-input-route.md`).
2. **The Frame compositor times out on its display IRQ.** The README says the Frame `vrcompositor`
   has a one-second display-IRQ timeout. Stearlight calls `VsyncEvent` once per new tracking sample
   to avoid it [R; the call is C in `quest_driver.cpp`]. Our real KMS vblank should supply this, but
   it is a symptom to recognise if vblank delivery breaks.
3. **`vrlink` needs a nonempty `Prop_DisplayAvailableFrameRates_Float_Array`** before it activates a
   remote HMD [C comment]. Compare `display-geometry-stereo.md`.
4. **A SteamVR settings-path pitfall:** an absolute `VR_SETTINGS_FILE` is concatenated with the
   config dir and silently ignored, so `steamvr-native` unsets it [R, comment in
   `system_files/usr/local/libexec/stearlight/steamvr-native`]. The same script starts SteamVR
   through `vrstartup`, which owns `vrserver`, `vrcompositor` and `vrdashboard`. It registers the
   `frame_controller` and `vrlink` drivers with `vrpathreg` [C, via summary]. In its VM it turned off
   the Frame facet renderer and the system-layer distort pass [C, via summary].
5. **More evidence on VA_BITS=39.** Local Proton/EAC launches fail with "Failed to initialize Wine
   helper buffer". The launcher wants addresses from `0x700100000000` upward, but the Quest 2
   kernel's limit is `0x7fffff0000` [R]. Our `k1a.config` has `CONFIG_ARM64_VA_BITS=39`, and
   `FS-A-006-userspace.md` already lists VA_BITS 39 to 48 as a soft item. This is a concrete
   failure case for that row [U for Quest 3, but same config]. Our later static study of the
   sources zip and the APK found **no VA39 workaround** in what it read; that is a bounded
   negative, not proof that none exists (FS-R-015 §7). The failure is the author's report [R],
   seen under PRoot, not on a native boot.
6. **Lepton (Frame Android apps) needs private namespaces and Binder**, and an unprivileged
   container cannot provide them. Repackaging the VRChat APK trips its tamper check [R]. On our own
   kernel this is a configuration question (Binder/binderfs, namespaces), not a blocker [U].
7. **Update feeds:** the client channels are ARM64 `steamdeck_stable` and `publicbeta`. The OS
   images come from a separate ARM64 Frame feed, with RAUC verification against a pinned production
   cert. Beta also trusts a dev cert [R, files C]. Cross-check against
   `steamos-update-channels.md`.
8. **Seated games need STAGE calibration.** Without a seated/standing origin, VTOL VR received
   invalid poses [R]. Our tracker must publish a chaperone or universe origin from day one.
9. **Turnip on KGSL details:** Mesa must release DMA-heap/ION descriptors after import, or freed
   exported buffers keep their memory. Turnip also needs a memory barrier between compositor passes
   to avoid right-eye trails [R]. Both are leads for our GPU route if it touches KGSL
   (`gpu-route-decision.md`).
10. **Mapping Touch to the Frame gamepad:** grips act as LB/RB, and grip plus stick click gives
    View (left) or Menu (right). Touch has no D-pad [R]. A design reference only.

## 5. Licence and provenance assessment

- **FSL-1.1-ALv2 is not an open-source licence today.** It allows non-commercial research and
  internal use, but forbids a "Competing Use" and requires the FSL terms on every redistribution. Each
  version converts to **Apache-2.0 two years after it was published**, so the earliest code becomes
  Apache-2.0 in about August 2028 [C `LICENSE.md`]. It is **incompatible with our Apache-2.0 code
  today** (`PROVENANCE-POLICY.md` §6). **Facts only. No code reuse.**
- **The licensing is mixed and inconsistent.** Most source files carry no header [C, sampled].
  `proot/robust.c` is `SPDX GPL-2.0-or-later` inside an FSL repo [C]. Commit `6672a9873e` ("Remove
  license from open source files") **deleted the MIT `LICENSE` and the "Adapted from
  pingdotgg/t3code … MIT" attribution lines** from `.github/workflows/pr-size.yml` and
  `pr-vouch.yml` [C]. This is a hygiene red flag.
- **The released APK redistributes Valve binaries:** SteamVR, the Steam client subset, gamescope,
  and (per the README) KDE Plasma taken from the Frame image. These are copied from the recovery
  image by `build-rootfs.sh` [C]. Our policy is not to redistribute Valve's images
  (`valve-packages-licensing.md`). Do not take this as precedent.
- **No Meta binaries in the tree.** It links the Khronos `openxr_loader_for_android` 1.0.34 from
  Maven and uses Meta's on-device runtime at run time [C `app/build.gradle`]. The manifest uses
  `com.oculus.*` features and permissions [C].
- **Nothing outside our public scope.** A code search found no such material [C]. The debug
  script uses ordinary `adb shell` and `run-as` (`post_process/quest/run-linux-debug.ps1`, via
  summary) [C]. This document is therefore public. No private copy was needed.

## 6. AI-directed text found (treated as data; nothing acted on)

- `AGENTS.md` (https://github.com/amichyrpi/stearlight/blob/3e4c857883/AGENTS.md), included by
  `CLAUDE.md` (`@AGENTS.md`). It contains style instructions for coding agents ("be direct and
  concise, with only the detail needed"), plus a section titled "The ways to hurt yourself" ("Do not
  loop on a feature that cannot work…"). These are contributor guidance for the author's own agents.
  They are benign and were ignored.
- `CONTRIBUTING.md` says AI use is "authorized" and recommended, and asks contributors to name the
  model. It is not addressed to us and nothing was acted on.

## Useful for FrameShift

- The property 2117 Frame gamepad gate, and the `frame_controller` profile used for a non-Valve
  controller (§4.1, §4.10): input bridge.
- The display-IRQ timeout symptom and the `VsyncEvent` behaviour (§4.2), plus the `vrlink`
  frame-rate list requirement (§4.3): display bring-up checklist.
- The `vrstartup` launch model, `vrpathreg` registration, and the `VR_SETTINGS_FILE` pitfall
  (§4.4): session bring-up.
- A concrete Proton/Wine failure under VA_BITS=39 (§4.5): evidence for a VA_BITS 48 decision on our
  kernel.
- Lepton's needs (Binder and namespaces, §4.6), the update-feed and cert layout (§4.7), and STAGE
  calibration for seated games (§4.8).
- The Turnip-on-KGSL memory and barrier notes (§4.9), if our GPU route uses KGSL.
- A market note: a public "Frame OS on Quest" app now exists for Quest 2. It is a different
  architecture from ours (an app on Horizon, against our own kernel and OS on Quest 3), and its
  performance is self-described as "really slow" [R].

## Avoid

- **All code:** FSL-1.1-ALv2 is incompatible with Apache-2.0 until each version's two-year
  conversion. Many files have no header, one is GPL. Read facts only.
- **The release APK and sources zip:** they bundle Valve binaries and possibly KDE from the Frame
  image. Do not download, install or redistribute them.
- **Its architecture as a model for us.** PRoot on Horizon depends on Meta's kernel, compositor,
  tracking, thermal and power management. None of that carries over to our own-kernel port, and
  its thermal safety is entirely Horizon's.
- **Its licence hygiene** (the MIT attribution removed in `6672a9873e`): never something to copy.
- The archived VM path (`packages/windows-runtime/`, the virtio-venus patches) and the
  Raspberry Pi phase: not relevant to us.
