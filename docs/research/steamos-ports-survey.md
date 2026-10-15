# How others booted SteamOS on Quest headsets: boot, display, GPU, desktop

Agent report, 2026-10-14. Research only. Public web and public repos only;
repos were cloned read-only into WSL `~/work/steamos-ports/` and read, never
built or run. No disassembly or decompilation, no binary or model downloads,
no device commands. Tracking and controllers are covered by the parallel
survey `quest-ports-tracking.md`; this note covers **boot, display, GPU and
desktop** only.

**Why:** the PM wants the next big milestone to be "SteamOS desktop or virtual
environment on the Quest 3", and reports that community members reached a
SteamOS boot on Quests within weeks of Valve's image. This note finds out
exactly what they booted and how, to calibrate our path.

**Tags** (FS-R-001): **[M-static]** read from a named file at a named commit ·
**[C]** a community claim (their hardware result, which we cannot check) ·
**[D]** derived by us · **[O]** open. No [M]: nothing here was measured by us.

**Scope rule:** where a project used a bootloader unlock, root or kexec, this
note records only *that* it did, never how.

---

## 0. Answers in brief

1. **Nobody has publicly booted SteamOS on a Quest 3.** The public results are
   on the Quest 1, the Quest 2 and (unpublished) the Quest Pro. On the Quest 3
   the community has Turnip-on-KGSL running *inside Horizon OS* (an emulator
   project) and QEMU-only work; nothing on hardware.
2. **None of them booted Valve's Frame image unchanged.** Each one:
   - used a **different root filesystem**: Valve's *public package-repo* base
     rootfs plus packages as a **chroot from Alpine, without systemd** (Quest 2),
     or Valve's generic **Holo Core preview** rootfs with Frame binaries copied in
     (Quest 1);
   - **replaced Valve's graphics stack**: their own upstream Turnip on KGSL plus
     Zink in `/usr/local` and their own patched gamescope (Quest 2), or Meta's
     proprietary Adreno blob through libhybris plus ANGLE (Quest 1);
   - had **no thermal service**: clock caps only (Quest 2) or nothing beyond
     keeping the fan running (Quest 1); no battery protection anywhere.
3. **How far they got:** Quest 2 = Steam client gamepad UI flat in both eyes
   (sign-in screen), then a 3DoF Monado scene; Quest 1 = Big Picture on a
   virtual screen inside VR plus Valve's SteamVR 2.17 with the Aurora
   environment at about 40 fps, 3DoF; Quest Pro = a news report of Big Picture
   with lens distortion, no code. **Nobody reached a Plasma desktop on a Quest**.
4. **How fast:** about one day from a working Linux shell to the Steam UI
   (Quest 2), about two days for the Quest 1 stack, both AI-assisted and with
   no review or safety gates. The time went into the kernel hand-off, not into
   SteamOS.
5. **What this means for FrameShift [D]:**
   - Their speed came from dropping exactly what FrameShift keeps: Valve's own
     systemd and session, Valve's Mesa and gamescope, thermal and battery
     protection, and the Chair process. It is not a like-for-like benchmark.
   - **No community GPU approach is faster than (e′) for a *pure* first
     desktop.** The QK2-style overlay (our own Turnip-KGSL + Zink + a patched
     gamescope) is faster to a *non-pure* first Steam UI, but it is route (a) as
     a stop-gap, which the PM declined in J-154; software rendering is not an
     option (Valve's image has no llvmpipe or lavapipe, and Valve's compositors
     need Vulkan plus DRM syncobj).
   - **Calibration point:** on the Frame, the Steam UI and Plasma run *inside*
     SteamVR (gamescope with the OpenVR backend, Plasma nested; vrcompositor is
     the only KMS client). So on a Quest 3 with its eye swap and 21° roll, a
     *viewable* pure SteamOS desktop **is** the virtual environment: Valve's
     vrcompositor plus our HMD driver. A flat gamescope session on the panels is
     a bench check, not something a user can comfortably look at.
   - **Fastest safe path:** keep (e′), and give the PM two demo milestones on the
     way: **R-1 "SteamOS boots on Quest 3"** (Valve's own systemd on the
     unmodified 0.4.5 image, no GPU needed; after PD-10 and PD-7) and **V0
     "SteamOS desktop in the headset"** (Valve's vrcompositor and gamescope
     overlay through the (e′) device, with a fixed-pose FrameShift HMD driver),
     then V1 with 3DoF. §6 and §7.

---

## 1. Projects found and what they are

| Short | Project | Device | Read at | Licence | Booted on hardware? |
|---|---|---|---|---|---|
| **QK2** | machachu56/quest-kexec-q2, branch `quest2-port` | Quest 2 | `9c96c19` (2026-10-07) | GPL-2.0 (`LICENSE`); Monado driver files SPDX BSL-1.0 | **yes [C]**: Steam UI, 3DoF VR |
| **Q1** | nicolas-riera/Quest1-SteamOS | Quest 1 | `b7467ff` (2026-10-07) | **no licence file** (README: kernel changes GPL-2.0, Monado patch BSL-1.0) | **yes [C]**: Big Picture in VR, SteamVR Aurora |
| **QPro-S** | unpublished Quest Pro SteamOS boot | Quest Pro | public: one news video (2026-10-05) | no code | **reported [C]**: Big Picture with distortion |
| **QK** | YusufOzmen01/quest-kexec | Quest Pro | `e61edbd` (2026-10-04) | GPL-2.0, but ships closed binaries and a modified-ROM release | yes [C], but **Android only**, not SteamOS |
| **OLK** | YusufOzmen01/oculus-linux-kernel, branch `oculus-quest-pro-kernel-master` | Quest Pro | `9b68500d48` (2026-10-10) | GPL-2.0 (Linux; GitHub API says NOASSERTION) | kernel for QK; no SteamOS |
| **QK-M** | Mac898/quest-kexec, branch `quest2-support` | Quest 2/Pro | `2d42980` (2026-10-11) | GPL-2.0 | loader multi-board refactor only (upstream PR #1); no SteamOS |
| **RVR** | Producdevity/reframed-vr | Quest 3, Pico Neo3 | `c704df7` (2026-10-14 UTC) | **no licence** | **no**: QEMU only ("Exact-device boot" open) |
| **Q3T** | Jbbrack03/Quest-3-Turnip-Driver | Quest 3 (Horizon OS) | `83cd874` (2026-07-17) | **no licence** | Turnip on KGSL inside Horizon OS (emulator use); no Linux boot |
| **NF** | HttpAnimations/neoframe (GitLab) | Pico Neo 2 (SDM845) | `b885ec4` (2026-10-05) | AGPL-3.0 | **no**: early bring-up; a soft-brick and recovery documented |
| **SAP** | hashtagbasit/SteamOS-ARM-Port | SM8250/8550/8650/8750 handhelds | README via GitHub API, 2026-10-14 | GPL-2.0 (README badge; API NOASSERTION) | yes [C]: Game Mode and KDE desktop, mainline kernels (not a Quest) |
| — | leo-n64/linux-vr-pro | (PC streaming idea) | `4f0d693` ("Deleted") | none | not a port; irrelevant |

Search coverage: GitHub repository, user, fork and issue searches; GitLab and
Codeberg project searches; YouTube search and video metadata; Steam Community
thread `573795849686077848`; general web search. Reddit's API refused
unauthenticated requests, and X/Twitter could not be searched, so posts that
exist only there are not covered **[O]**. The FXR/FreeXR community's own
channels are not public web and were not searched.

Already examined earlier and not repeated here: `community-quest-repos-2.md`
(QK, QK2, Q1 outside the display path), `display-clues-kexec-quest1.md`,
`oculus-linux-kernel-yusuf.md`, `armadavr.md` (the same author's earlier
ArmadaVR repo; RVR documents a rename but does not name the old project),
`FS-A-006-quest-projects.md`. This note adds the
boot/GPU/desktop comparison, the timelines, NF, Q3T's status, QK-M, the
QPro-S public trace, and the milestone calibration.

---

## 2. Per project: what boots, display, GPU, changes, safety, time

### 2.1 QK2: Quest 2, kexec, SteamOS userspace as a chroot

**What boots** [M-static, `docs/QUEST2_PORT.md`, `README.md` at `9c96c19`; results C]:
- Kernel: **Meta's Quest 2 4.19** (`oculus-quest2-kernel-master` `6e4286073`,
  the closest public build) with the QK kexec-target patches plus Quest 2
  patches (USB, UFS, GPU wake-up, watchdog). Entered by **kexec from modified
  Android** (root and kexec used; method not recorded here). Nothing flashed.
- Init: a BusyBox initramfs, then **Alpine 3.22 with OpenRC** from a pinned
  image file on `userdata`.
- SteamOS: **not Valve's image.** `tools/steamos-rootfs.sh` imports Valve's
  public package-repo base rootfs (`steamdeck-packages.steamos.cloud/
  archlinux-deckard/.../system.rootfs.zst`) and pacman-installs
  `deckard-steam-rel`, `fex-wtf`, `mesa`, `xorg-xwayland`, PipeWire and helpers
  into a 24 GiB ext4 image. It runs as a **chroot from Alpine**: "The 4.19
  vendor kernel cannot run this systemd", so `qkx-steamos` mirrors
  `steam.service` in a shell script.
- How far: **Steam client gamepad UI full-screen in both eyes**, signed in by
  the phone QR code; Touch controllers as a uinput gamepad; then **first VR**:
  Monado with a 3DoF SyncBoss-IMU driver, side-by-side through gamescope, no
  lens distortion. Evidence: "user-confirmed" status notes; no video or log in
  the repo [C].

**Display path** [M-static, `QUEST2_PORT.md` §§"display", "GPU frames on the panel", "correct per-eye image"]:
- **Meta's stock SDE `msm_drm` KMS** (DSI-1 1920×3664@120, DSC, 2 LM / 2 DSC /
  2 DSI). Not fbdev, not upstream DPU.
- One full-width plane gave "rows of small purple blocks"; **one half-width
  plane per mixer** was correct (same root cause as our J-109/J-125 per-pipe
  finding).
- gamescope **DRM backend**, patched: `0001` LINEAR when planes lack
  `IN_FORMATS`; `0002` libliftoff tolerates SDE plane properties (`input_fence`,
  8-bit `alpha`); `0003` split every layer into left/right planes; `0004`-`0006`
  a composite shader that maps each panel pixel to its eye and rotates it (the
  Quest 2 panel is one portrait panel, eyes stacked and rotated 90°; **SDE
  cannot rotate linear RGB planes**), plus side-by-side stereo for Monado.

**GPU** [M-static, same doc, `patches/mesa/0001`, `rootfs/usr/local/bin/qkx-steamos`]:
- **Meta KGSL** (`/dev/kgsl-3d0`) + **upstream Mesa 25.1.9 Turnip built with
  the KGSL backend** + **Zink** for GL 4.6/EGL/GBM; Vulkan 1.3 on Adreno 650.
- A Mesa patch makes Turnip-KGSL report the SDE `msm_drm` nodes through
  `VK_EXT_physical_device_drm` (env-overridable) so gamescope can pair GPU and
  KMS.
- **Valve's Mesa was not used**: their Mesa goes into `/usr/local` with
  `ld.so.conf.d/00-qkx-mesa.conf` first, and `MESA_LOADER_DRIVER_OVERRIDE=zink`
  plus `VK_ICD_FILENAMES` point at it. gamescope runs from the **Alpine** side,
  not Valve's.
- A kernel patch was needed for the GPU RSC wake sequence after the kexec
  hand-off (kexec-specific [D]).

**Changes to the SteamOS side** [M-static, `tools/steamos-rootfs.sh`, `qkx-steamos`, `qkx-gpu.start`]:
- added GTK 2 (self-built; `steamui.so` links it), `lsof`, `xhost`, debug tools;
- `steam` user with **passwordless sudo**; Android paranoid-network groups
  3003/3004 (needed on Q2, **not on Q3**: Q3 v2.7 lacks
  `ANDROID_PARANOID_NETWORK`, `community-quest-repos-2.md` §1.5);
- `nsswitch` edited (no resolved), machine id created, `resolv.conf` replaced;
- device nodes `chmod 0666` (kgsl, ion, DRI);
- `pacman.conf` with optional signatures (anti-pattern S12 in the earlier note);
- systemd, udev and Valve's session never run.

**Safety** [M-static, `rootfs/etc/local.d/qkx-thermal.start`; C]:
- CPU thermal zones are `user_space` (Android's thermal-engine absent), "so
  nothing throttles"; mitigation = schedutil plus `scaling_max_freq` caps;
  3 min full CPU load reached 75.6 °C [C]. No fan control, no GPU cap, no
  battery or skin protection, no shutdown path.
- "Do not mount `persist` from Linux" (it reset the headset).

**Timeline** [M-static, git author dates]:
| date | milestone |
|---|---|
| 2026-09-26 | QK (the Quest Pro loader it builds on) first release |
| 2026-10-06 | Quest 2 port: kexec to a BusyBox shell; Alpine on UFS; KMS and `vulkaninfo` (Turnip-KGSL); gamescope + vkcube |
| 2026-10-06/07 | GPU frames on the panel (split planes); correct per-eye image; **Steam client UI in the headset** |
| 2026-10-07 | controllers and IMU via SyncBoss; tracking cameras streaming; **first 3DoF VR** (Monado) |

**Reuse** [D]: GPL-2.0 tools and BSL-1.0 Monado driver, with attribution. For
FrameShift's pure route the reusable parts are *knowledge*: the SDE plane-split
and property quirks (already ours, J-109), the Turnip-KGSL ↔ KMS pairing idea,
the RSC-wake symptom (to watch for if G1 stalls on GMU votes), and the
"Steam needs GTK 2/lsof/machine-id" list as a checklist (Valve's full Frame
image already contains GTK 2 [C, Q1 copied it from there]). Their gamescope
and Mesa patches are exactly what (e′) exists to avoid.

### 2.2 Q1: Quest 1, `fastboot boot`, Holo with systemd as PID 1

**What boots** [M-static, `README.md`, `docs/rootfs-build.md`, commit `21a997e` message; results C]:
- Kernel: **Meta's Quest 1 4.4** with a patch adding syscall back-ports for
  systemd 258 and LSE/LDAPR emulation for the arm64 Steam client (Kryo 280 is
  ARMv8.0). Booted by **`fastboot boot` on a bootloader-unlocked Quest 1**
  (unlock used; method not recorded). Nothing flashed.
- Init: a BusyBox initramfs that loop-mounts `/data/steamos/holo.img` and
  `switch_root`s to **systemd as PID 1**.
- Rootfs: **Valve's generic Holo Core aarch64 preview** (`holo-packages.steamos.cloud/
  holo-core-aarch64-preview/mash-20251118.3/system.rootfs.zst`), not the Frame
  image, plus pacman packages, **plus the Frame's Steam client, GTK 2 and
  SteamVR 2.17 copied from a Frame rootfs** ("with local edits" to SteamVR).
  Assembled by hand on the headset, 2026-10-05 to 10-07; not published.
- How far: **Big Picture on an Xvfb virtual screen shown as a quad in VR**
  (also over VNC), and **Valve's SteamVR with the Aurora environment at about
  40 fps**, 3DoF head, Touch controllers [C].

**Display path** [M-static, `src/monado/quest1-monado.patch`]:
- **MSM MDSS fbdev atomic commit** (`msm_mdp_ext.h`) from a new Monado
  compositor target (`comp_window_mdp.c`), 2880×1600 at 72 Hz, zero-copy from
  AHardwareBuffers, Meta's lens distortion in Monado. No KMS.
- SteamVR's vrcompositor is **not** on the display: a custom SteamVR driver
  simulates direct mode and forwards frames over OpenXR to Monado.

**GPU** [M-static, `docs/steam-gpu.md`, `docs/rootfs-build.md`]:
- **Meta's proprietary Adreno 540 Vulkan blob through libhybris** (from the
  headset's own Android partitions, mounted read-only), plus a Vulkan shim with
  X11 WSI and a layer that emulates timeline semaphores for SteamVR.
- Steam's CEF first fell back to **llvmpipe** (the Holo Core preview Mesa has
  it; the Frame image does not) and burned 1.4-3 cores at 1280×800 [C]; it now
  runs ANGLE-Vulkan on the blob.
- Valve's Mesa/Turnip is **not** used (no freedreno KMD for A540 on 4.4).

**Changes**: libhybris, Android HALs and the modem stack run under Holo; Monado
built on the headset; SteamVR edited; zram and sshd priority tweaks
(`device/holo-perf.sh`).

**Safety** [M-static; earlier note §6]: the fan is kept running when the panels
blank (the Quest 1 fan driver stops it on POWERDOWN); GPU forced to
`performance` while presenting; no thermal daemon, no battery handling.

**Timeline**: repo first commit 2026-10-06 already states "native Holo boot"
(work began on or before 2026-10-05); SteamVR running 2026-10-06; boot-image CI
prereleases 2026-10-07. The README says the whole project was written by an AI
and tested by a human.

**Reuse** [D]: no licence file → **pointers only**, except the GPL-2.0 kernel
patch and the BSL-1.0 Monado patch (PM stance, 2026-10-10: ask the author to
add a licence). Its route (Meta's blob via libhybris) conflicts with the PM's
no-Meta-software rule (J-155, J-162) and does not apply to (e′).

### 2.3 QPro-S: Quest Pro, unpublished

- **Public trace only** [M-static, YouTube video `AqrF37lu0Ys`, channel
  UntitledGameShow, uploaded 2026-10-05, description]: a news round-up states
  that a developer (named after a TV character, likely a pseudonym) bypassed
  bootloader hurdles and booted ARM64 SteamOS on a **Quest Pro** "with optical
  distortion and Big Picture rendering". No repo, log or method is linked.
- A Steam Community thread (2026-10-09) only says "someone got SteamOS booting
  on a quest", without details.
- A later private report to the PM (paraphrased, see the private notes; not
  reproduced here) says the work is kexec-based and back-ports a recent
  upstream `drm/msm` into the Quest Pro's 4.19 kernel, and is not yet
  publishable. **No code, licence or evidence is public; treat as [C],
  pointer only.**
- Calibration value [D]: if true, it is the only Quest effort on route (b)
  (upstream drm/msm on a downstream kernel), the fallback back-end of (e′)
  (PD-2). Worth a follow-up when it is published, especially its GPU power and
  thermal handling, which (b) has to re-derive (gpu-route-decision §2b).

### 2.4 QK and OLK: Quest Pro, kexec, Android only

[M-static, `README.md`, `docs/KEXEC_ANDROID_WORKING_SETUP.md`; OLK log] QK
kexecs from modified Android into a second Meta Android, not SteamOS. OLK's
latest commit (2026-10-10, "KGSL/Turnip sync bridges, display slot") adds
kernel hooks for Turnip-on-KGSL synchronisation and a GPU slot for a VR
compositor, but no SteamOS userspace is published. Display: Meta's SDE with a
closed splash binary (two planes). Thermal: the alternate Android runs Meta's
own stack. Already analysed in `oculus-linux-kernel-yusuf.md`; nothing new for
boot or desktop. QK-M (2026-10-10/11) only generalises the loader to board
descriptors (Quest 2 and Quest Pro); no SteamOS.

### 2.5 RVR and Q3T: Quest 3, no Linux boot

- **RVR** [M-static, `README.md` at `c704df7`]: Fedora + FEX + Monado; "Quest
  work retains Meta's vendor kernel and board drivers, with Mesa Turnip for
  KGSL"; all results are QEMU ("VM results do not establish hardware
  compatibility"); the Quest kernel only compiles. No licence → pointers only.
- **Q3T** [M-static, `README.md` at `83cd874`; C]: upstream Turnip with three
  patches runs games **inside Horizon OS without root** on the Quest 3's Adreno
  740v3: KGSL allocations rerouted to the `GPUOBJ_ALLOC` family (Horizon's
  SELinux blocks `GPUMEM_ALLOC_ID`), tolerant SPIR-V, a linear fallback for
  Meta's gralloc. Evidence that **Turnip's KGSL backend works on the Q3 GPU**,
  which lowers G1's risk [C → D]. Under our own init (no Horizon SELinux) the
  allocator patch may not be needed [O]. No licence → pointer only; its
  handoff notes mention a disassembly of a stock driver, which we do not use.

### 2.6 NF and SAP: Frame-image ports on other hardware

- **NF** (Pico Neo 2, SDM845) [M-static, `notes/01`-`05`, 2026-10-05]: no kexec
  in the stock kernel, so a repacked stock `boot.img` with a custom initramfs;
  the stock 4.9 kernel cannot run systemd 257, so a mainline sdm845 kernel was
  planned; display via the stock DRM was partial ("grey + edge slivers").
  Used a community handheld image, not Valve's. **Safety lesson**: writing a
  recovery command to `misc` soft-bricked the unit because that ABL never
  clears it (cf. our `misc` rules, FS-R-005). AGPL-3.0; nothing to reuse.
- **SAP** (handhelds) [C, README]: Valve's Frame image on **mainline**
  `drm/msm` kernels reaches **Game Mode and the KDE desktop** on SM8550/8650/8750
  and, in beta, **SM8250 (the Quest 2/Pro SoC family)**; repo created
  2026-09-24, two days after Valve's 0.3.0 recovery build. It masks and fixes
  Valve services and flashes a third-party ABL (not applicable to a Quest).
  Calibration [D]: with an upstream `msm` device, Valve's graphics stack runs
  unpatched, which is the premise of (e′) and of horizon (c).

---

## 3. Side-by-side

| | QK2 (Quest 2) | Q1 (Quest 1) | QPro-S (Quest Pro) | FrameShift plan (Quest 3) |
|---|---|---|---|---|
| entry | kexec from modified Android | `fastboot boot`, unlocked | kexec [C, private] | `fastboot boot`, unlocked (PD-5) |
| kernel | Meta 4.19 + patches | Meta 4.4 + back-ports | Meta 4.19 + drm/msm back-port [C] | Meta 5.10 v2.7, our build (K1) |
| PID 1 | BusyBox → Alpine OpenRC | BusyBox → **systemd 258** | ? | BusyBox → **Valve's systemd** |
| rootfs | Valve repo base + packages, **chroot** | **Holo Core preview** + Frame binaries | ? | **Valve 0.4.5 stable, unmodified** + our layer |
| display | SDE KMS, gamescope DRM backend (patched: split, per-eye shader) | MDSS **fbdev** from Monado | ? (distortion shown) | SDE KMS; today our own client (4×1032 planes, swap, roll); (e′): one `msm` device with in-kernel split |
| GPU | KGSL + **own** Turnip-KGSL + Zink | **Meta blob** via libhybris + ANGLE | upstream drm/msm GPU [C] | (e′): KGSL behind a drm/msm uAPI; **Valve's** Turnip and Zink |
| Valve's Mesa / gamescope | replaced / replaced | unused / unused | ? | **unchanged** |
| furthest | Steam UI flat per eye; 3DoF Monado | Big Picture in VR; SteamVR Aurora ~40 fps | Big Picture + distortion | stage 3d PASS (our pattern, both units) |
| thermal / battery | clock caps / none | fan kept on / none | ? | full `fs-thermald` first (PD-7) |
| write safety | files on `/data`; "never mount persist" | file on `/data`; Android parts ro | ? | `fs-blkguard` first (PD-10); RAM root (PD-3) |

---

## 4. Lessons that change or confirm our plan [D]

1. **The kernel is the gate, not SteamOS.** Every project spent its effort
   getting Linux running on Meta's hardware; SteamOS userspace then came up in
   hours. FrameShift has already passed the equivalent gate on the display side
   (stage 3d on v2.7). Our remaining gates are the ones the community skipped:
   guard, thermal, our own kernel build, and the GPU contract.
2. **5.10 is an advantage.** QK2 could not run Valve's systemd on 4.19 and fell
   back to a chroot; Q1 had to back-port syscalls into 4.4. Meta's Quest 3
   kernel is 5.10, which meets systemd's floor, so R-1 can run Valve's own
   systemd as PID 1 with the config work already planned (K1 groups,
   SysV IPC at K1i) [D; runtime O].
3. **The per-pipe plane split is universal on Meta's SDE.** QK2 hit it on the
   Quest 2, OLK/QK on the Quest Pro, we on the Quest 3. In (e′) it moves into
   the kernel (the wide-plane split), so no compositor patch is needed.
4. **Geometry belongs to the VR compositor.** QK2 had to patch gamescope with a
   per-eye shader because a flat session cannot be viewed through the lenses
   otherwise; SDE cannot rotate linear planes. On the Quest 3 (eye swap, 21°
   roll) the same holds. In Valve's design the flat UI is an overlay inside
   SteamVR (F1/F2 in `gpu-route-decision.md`), so the pure way to a viewable
   desktop is vrcompositor plus our HMD driver's geometry, not a flat session.
5. **Turnip-on-KGSL works on both GPUs** (A650 under Linux, A740v3 under
   Horizon) [C]. That supports keeping G1 as planned and makes CP-1 less risky.
6. **Nobody has thermal or battery handling.** 75.6 °C after 3 min of capped CPU
   load on a Quest 2 [C] is a warning for anyone reproducing these demos; PD-7
   stays first. Nothing in these projects changes `thermal-control-design.md`.
7. **Do not copy:** passwordless sudo, `0666` device nodes, unsigned pacman,
   `/usr/local` Mesa that shadows Valve's, closed splash binaries, modified-ROM
   releases, Meta blobs via libhybris.

---

## 5. Licence summary and clean reuse

| Project | Licence | What we may reuse | Pointer only |
|---|---|---|---|
| QK2 | GPL-2.0; BSL-1.0 Monado driver | GPL tools/patches with GPL obligations; BSL code with attribution. Useful mostly as knowledge (§2.1) | — |
| QK / OLK / QK-M | GPL-2.0 | GPL kernel patches and scripts (with obligations) | closed `qkx-splash`, the overlay APK and the ROM release: **never** |
| Q1 | none (README: kernel GPL-2.0, Monado BSL-1.0) | the kernel patch (GPL-2.0), the Monado patch (BSL-1.0) | everything else |
| RVR, Q3T, linux-vr-pro | none | — | all |
| NF | AGPL-3.0 | nothing relevant | — |
| SAP | GPL-2.0 | as already indexed (initramfs, rootfs ingest, mask lists) | its ABL route |
| QPro-S | no code | — | all |

---

## 6. (a) The fastest SAFE path to "SteamOS desktop on Quest 3"

### 6.1 What the milestone can honestly mean under our rules [D]

- **"SteamOS boots"**: Valve's unmodified image, Valve's systemd as PID 1, on
  the Quest 3, with our guard and thermal service live. No GPU needed. This is
  further than QK2 got on purity (they never ran Valve's systemd) and is
  reachable first.
- **"SteamOS desktop / virtual environment"**: Valve's own vrcompositor drives
  the panels through the (e′) `msm` device; Valve's gamescope runs as its
  OpenVR overlay with the Steam UI (and Plasma nested, as on the Frame); our
  HMD driver supplies the per-eye geometry. A fixed (head-locked) pose is
  enough for a first desktop; 3DoF follows from the tracking plan.

### 6.2 Is any community GPU approach faster than (e′) for a first desktop?

| approach | faster to first Steam UI? | cost to purity | other cost | verdict |
|---|---|---|---|---|
| **QK2-style overlay**: our upstream Turnip-KGSL (the G1 tool) + Zink in a separate layer, our patched gamescope (DRM backend, plane split, per-eye shader), Valve's Steam client | **yes**, it reuses G1's build | replaces Valve's Mesa and gamescope at runtime (Valve's files stay on disk but are shadowed); not the Frame's session; throwaway except lessons | it is route (a) as a stop-gap, which the PM declined (J-154); needs PD-7 and the guard anyway; a Chair class for running a non-Valve graphics stack | **not recommended**; only if the PM explicitly wants an early, internal, never-shipped visual |
| **Q1-style Meta blob via libhybris** | no on the Q3 (Android 14 HALs, much glue) | Meta proprietary software at runtime | against J-155/J-162 (no Meta software) and legal review | **reject** |
| **software rendering** (llvmpipe/lavapipe) | no | adds packages Valve's image lacks (no llvmpipe, no lavapipe: stage3-4-plan §1) | gamescope and vrcompositor still need Vulkan + DRM syncobj + a render node; CPU-bound at 4128×2208 and hot (Q1: 1.4-3 cores at 1280×800 [C]) | **reject** |
| **upstream drm/msm back-port** (QPro-S style, route (b)) | not shown; unpublished | none on the SteamOS side | re-derives GPU power/thermal, loses BCL on Q3 (gpu-route-decision §2b) | stays the (e′) fallback (PD-2) |

**Answer:** no community GPU approach is faster than (e′) to a *pure* first
desktop [D]. The only faster route to *any* Steam UI is the QK2-style overlay,
whose purity cost is total for graphics and whose work is mostly discarded.

### 6.3 The recommended fastest safe path [D]

Keep (e′) and the existing gates, and re-cut the plan's end so the PM gets
visible SteamOS milestones as early as the gates allow:

1. **Prerequisites, unchanged:** K1a → K1g (PD-10, `fs-blkguard` proven) → T1
   and the full `fs-thermald` (PD-7) → K1i (SysV IPC with rebuilt modules).
2. **R-1 = "SteamOS boots on Quest 3"** (first public-facing milestone): the
   unmodified 0.4.5 image in RAM (PD-3), Valve's systemd to `fs-console.target`,
   guard armed, our splash on the panels showing live boot status from Valve's
   journal and the reached target. No GPU. Evidence: unit list, journal,
   optical splash check, ssh session into Valve's userspace.
3. **G1 in parallel with S0/CP-0**, as planned (upstream Turnip-KGSL offscreen,
   test tool only).
4. **(e′) G1c → G2**: Valve's unmodified Turnip on the rebuilt modules; then one
   GPU frame on the panels through Valve's display WSI with the in-kernel plane
   split and the fence path.
5. **New V0 = "SteamOS desktop in the headset"**: Valve's vrcompositor on the
   `msm` device with a **fixed-pose** FrameShift OpenVR HMD driver (display
   component with our eye-swap/roll geometry and distortion), Valve's gamescope
   as the OpenVR overlay showing the Steam UI, under a thermal soak. Needs
   persistent storage for Steam (PD-13; R0's RAM root is too small for G3/V0).
   This replaces the plan's flat G3 as the PM demo; a flat gamescope session can
   remain a bench check.
6. **V1 = "SteamOS virtual environment"**: the same with 3DoF head tracking from
   the SyncBoss IMU (tracking plan, early stage), SteamVR Home or Aurora.

Open points for V0 [O]: whether Valve's vrcompositor accepts a third-party
driver's direct-mode display on KHR_display (Q1 had to simulate direct mode and
bypass vrcompositor's display; on the Frame, vrcompositor owns KMS itself);
the distortion-mesh source for the Quest 3 lenses (values only, never Meta
code); and how gamescope's OpenVR backend behaves without Valve's Frame
driver.

---

## 7. (b) Milestones (no time estimates; device steps need the PM present and the Chair's concurrence per class)

| # | milestone | kind | needs (decisions / Chair) |
|---|---|---|---|
| M0 | Offline: O-0 slot-in phase 0, `fs-blkguard` in QEMU, full `fs-thermald` build, R0 RAM-root builder, S0 contract spec (CP-0) | offline | PD-11, PD-12; reviews |
| M1 | **K1a**: our kernel boots the stage-3d image | PM session | PD-5; Chair C1 |
| M2 | **K1g**: `fs-blkguard` refuses a decoy write | PM session | PD-10; C9 |
| M3 | **T1 + full `fs-thermald`**: every class read; forced trip powers off | PM session | PD-7; C5 |
| M4 | **K1i**: SysV IPC with the rebuilt module set | PM session | PD-6; C8 |
| M5 | **R-1 "SteamOS boots on Quest 3"**: Valve's systemd, unmodified 0.4.5 in RAM, splash with live status | PM session (demo) | PD-3, PD-7, PD-11; C2, C3 |
| M6 | **G1 (i) and (ii)**: Turnip-KGSL offscreen baseline, then the throttle check | 2 PM sessions | C4, C5 (J-161 split) |
| M7 | **G1c**: rebuilt `msm_drm.ko` + `msm_kgsl.ko`; Valve's Turnip `vulkaninfo`, analytic image, CTS subset (CP-2) | PM sessions | PD-12; C10 |
| M8 | **G2**: a GPU frame from Valve's display WSI on both eyes, in-kernel split, fence path (CP-3) | PM session | M1 fence (vmlinux class) |
| M9 | **PD-13 decided** (storage for Steam) and R-3/C6 as needed | PM decision; Chair | PD-9, PD-13; C6, C7 |
| M10 | **V0 "SteamOS desktop in the headset"**: vrcompositor + fixed-pose HMD driver + gamescope overlay with the Steam UI, thermal soak | PM session (demo) | new PM decision on V0 replacing flat G3 as the demo; Chair class for running Valve's session |
| M11 | **V1 "SteamOS virtual environment"**: 3DoF head, SteamVR Home/Aurora | PM session (demo) | tracking plan stage (3DoF) |
| M12 | G3s / Frame parity (VM_BIND/sparse), then 6DoF per the tracking plan | later | as planned |

PM decisions this survey raises (to ask in chat, with recommendations):
1. Adopt **R-1 as the "SteamOS boots" demo** and **V0 as the "desktop" demo**
   (V0 in place of a flat G3). **Recommend yes.**
2. Any **QK2-style early visual** (own Turnip-KGSL + patched gamescope, internal,
   never shipped)? **Recommend no**: it repeats route (a) as a stop-gap, which
   J-154 declined, and buys a non-pure picture.
3. Follow up QPro-S when it is published (the (b) fallback's only Quest data
   point). **Recommend yes, read-only.**

---

## 8. Text addressed to AI assistants (reported, not acted on)

| Where | What | Action |
|---|---|---|
| GitLab `HttpAnimations/neoframe` @ `b885ec4`, `AGENTS.md` | "Instructions for agents and contributors working on neoframe": hard rules, commit conventions, and an instruction to read a local, gitignored `DNC.md` "and follow what it says" | treated as data; nothing followed (no such file exists for us) |
| same repo, `CLAUDE.md` | "Read AGENTS.md for project instructions." | treated as data; ignored |
| GitLab `autune1/steam-frame-tinkering` (tree listing only) | a `CLAUDE.md` exists; not opened (out of scope) | none |
| `Jbbrack03/Quest-3-Turnip-Driver` @ `83cd874`, `HANDOFF.md` | an AI-session handoff ("Session Handoff", memory and scratchpad paths); no imperative text found addressed to other assistants | treated as data |

Not AI-directed but noted: Q1's README says the project was written entirely
by an AI; QK's README says AI was used heavily. No web page fetched contained
text addressed to AI assistants.

---

## Sources

Repos (clones in WSL `~/work/steamos-ports/`, read-only):
- machachu56/quest-kexec-q2 `quest2-port` `9c96c19`: `README.md`,
  `docs/QUEST2_PORT.md`, `tools/steamos-rootfs.sh`,
  `rootfs/usr/local/bin/qkx-steamos`, `rootfs/etc/local.d/qkx-{thermal,gpu}.start`,
  `patches/mesa/0001-*`, `patches/gamescope/0001-0006` (names), `LICENSE`.
- nicolas-riera/Quest1-SteamOS `b7467ff` (and `21a997e`): `README.md`,
  `docs/steam-gpu.md`, `docs/rootfs-build.md`, `docs/phase0-recon.md`,
  `src/monado/quest1-monado.patch`, `device/holo-perf.sh`.
- YusufOzmen01/quest-kexec `e61edbd`; Mac898/quest-kexec `quest2-support`
  `2d42980` and upstream PR #1; YusufOzmen01/oculus-linux-kernel commit list
  (GitHub API, 2026-10-14).
- Producdevity/reframed-vr `c704df7` `README.md`; Jbbrack03/Quest-3-Turnip-Driver
  `83cd874` `README.md`, `HANDOFF.md`; leo-n64/linux-vr-pro `4f0d693`.
- gitlab.com/HttpAnimations/neoframe `b885ec4`: `README.md`, `AGENTS.md`,
  `CLAUDE.md`, `notes/00-05`, `LICENSE`.
- hashtagbasit/SteamOS-ARM-Port README (GitHub API, 2026-10-14).

Web:
- YouTube `AqrF37lu0Ys` (UntitledGameShow, 2026-10-05), metadata and
  description via oEmbed and the watch page.
- Steam Community thread https://steamcommunity.com/discussions/forum/11/573795849686077848/
  (read 2026-10-14).
- GitHub, GitLab and Codeberg search APIs (2026-10-14).

FrameShift context: `stage3-4-plan.md` (§§1, 4.4, 4.5, 5), `gpu-route-decision.md`
rev 1 (§§0, 1, 3), `community-quest-repos-2.md` (§§1.5, 6, 7, 8),
`JOURNAL.md` J-149..J-165; the private community notes were read and are only
paraphrased in §2.3.
