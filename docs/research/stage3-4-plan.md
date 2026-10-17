# GPU stage and SteamOS-rootfs stage: decision plan (Quest 3 first)

**Status:** research and planning only, 2026-10-14. **Revision 1:** the adversarial review
(GO-with-fixes) has been applied; see the change list at the end. Nothing here authorises a
device action, and no device was touched.

**Sources read:**
- the repo docs listed under *Sources*;
- the Valve rootfs (`~/sfroot-full`, read-only: names, package metadata and string presence
  only);
- the Frame kernel config (`firmware/SteamOS/extracted/`);
- the Quest 3 v2.7 kernel config (`firmware/quest3/extracted/v2.7-user_ota/kernel.config`).

Tags: **[M]** measured on hardware · **[M-static]** read from a named artifact · **[D]** derived ·
**[C]** plausible, unconfirmed (incl. community reports) · **[O]** open.

**Stage numbering.** This note follows the J-146 brief: "Stage 3" = **GPU** and "Stage 4" =
**SteamOS rootfs** (the private game plan §3 order). `PROJECT_SETUP.md` §3 numbers the same work differently:
GPU is its stage 4, headless userspace its stage 2 and the full session its stage 5a. Display
(stage 3 there) is complete on both Quest 3 units (J-144, J-146). The milestone IDs in §5 avoid
the clash.

---

## 0. Answers in brief

1. **GPU route: (a) Meta's KGSL driver plus our own patched Turnip fork.** A fork is needed
   because upstream Turnip's KGSL backend does not fit a KMS compositor out of the box (§2a).
   - The work:
     - patched Mesa;
     - Vulkan loader overrides;
     - a gamescope adaptation for split display and GPU devices;
     - probably a rebuilt Meta display module and a small kernel back-port for fence
       interop.
   - Only the first GPU test (G1, offscreen) needs no new kernel code.
   - **(b) a drm/msm back-port:** an offline spike, run after G1. The (a)/(b) choice is made
     again **at G2, before any WSI or compositor work**.
   - **(c) a mainline kernel:** not started for the Quest 3.
   - Reasons in §3.
2. **Early milestone: realistic.** Valve's systemd can reach a controlled console target, and
   our own KMS splash can show on the panels, without a GPU. Four preconditions:
   - **a FrameShift-built kernel:** the gate-passed groups a/a′ plus the tmpfs and btrfs ACL
     options, with the kernel gate rerun (§4.1);
   - **the boot-chain block-write guard `fs-blkguard`:** PM decision J-119;
     `valve-writer-inventory.md` marks it mandatory before Valve userspace runs;
   - **a rootfs route that writes no headset storage:** Valve's image in RAM over USB-NCM,
     behind dm-verity, in an explicitly sized RAM disk;
   - **a power/thermal envelope:** either a rule-2 bounded hold, or the battery-temperature
     class (T3b) live.

   gamescope, Steam, SteamVR, Plasma and SDDM need Vulkan or GL. Valve's Mesa has no software
   fallback at all (§1), so they stay masked until the GPU milestone.
3. **Decisions:** 13 PM questions (§6) and 11 Chair classes (§7). Ask first: the GPU route
   (PD-1), the guard before R-1 (PD-10), first-rootfs storage (PD-3) and the first
   FrameShift-built kernel (PD-5).

---

## 1. What Valve's Frame userspace expects from the GPU [M-static unless tagged]

| item | finding | source |
|---|---|---|
| Mesa packages | `deckard-mesa-linux-aarch64 26.3.0_devel+git8aa73b4b` (native); `deckard-mesa-linux-x86_64` (FEX guest tree in `usr/share/guestos/fex-mesa/`, x86_64 **and** i386: `freedreno_icd.x86_64.json`, `freedreno_icd.x86.json`); `deckard-mesa-android-aarch64` (Android guest, `usr/share/guestos/android/`). Package licence field: `custom` | pacman db `usr/lib/holo/pacmandb/local/*/{desc,files}` |
| Vulkan ICD | **four Turnip builds**: native aarch64, x86_64, i386 and Android. Native ICD `freedreno_icd.aarch64.json` → `libvulkan_freedreno.so`, API 1.4.359 | `usr/share/vulkan/icd.d/`, fex-mesa `icd.d/` |
| Turnip kernel backend | the native, x86_64 and Android builds contain the `tu_knl_drm_msm.cc` path and `DRM_MSM_*` strings (incl. `DRM_MSM_VM_BIND`); **none contains `/dev/kgsl`** → the KGSL backend is not built [M-static strings → D] (i386 not checked; same package) | `strings` presence |
| A740 on Quest 3 | chip `0x43050b00` is `FD740v3` ("Quest 3") in Mesa's `freedreno_devices.py` [M-static, upstream Mesa via `armadavr.md`]; `FD740v3` is present in Valve's Turnip | string presence |
| OpenGL | no freedreno/msm gallium DRI driver. `zink_dri.so` → GL/EGL = **Zink on Turnip**. **No software fallback:** `libgallium` has Zink but no llvmpipe/softpipe and links no libLLVM; there is no lavapipe ICD | `usr/lib/dri/`, `usr/lib/`, review check |
| libdrm | 2.4.134, no `libdrm_freedreno` | `usr/lib/` |
| Vulkan layers | explicit: `VALVE_fdm_injection`, `VALVE_rpo`; implicit: gamescope WSI, MangoHud, fossilize, `MESA_vram_report_limit` | `usr/share/vulkan/*layer.d/` |
| Frame kernel | 6.18; `DRM_MSM=y` with KMS (DPU, DSI, DP) **and** GPU in one driver; `DRM_PANEL_DECKARD`; `DRM_CLIENT_VRCONSOLE`; no KGSL | `config-6.18.0-gfbdbca41fd45` |
| session | `default.target` → `graphical.target`; SDDM; `gamescope-wayland` and `plasma` sessions; gamescope 3.16.28; `deckard-steamvr-session` | unit files, packages |
| USB gadget | Valve's own `usb-gadget-init`, `usb-gadget(.target)`, `usb-ncm-gadget@`, `adbd-pre/post` units and a FunctionFS mount; **`typec-plug-event.rules` starts `usb-gadget.target` on cable attach** (behaviour [O]) | unit and rule names |
| rootfs | btrfs, `bytes_used` 4.17 GiB, in a 5120 MiB partition | FS-A-001; review check |

- **Mesa source [M-static → C].** GitLab's API returns "404 Commit Not Found" for `8aa73b4b`
  in upstream Mesa (2026-10-14). It is probably a Valve-fork commit. Whether Valve publishes
  it is [O].
- **Topology.** On the Frame, KMS and GPU are one drm/msm device. Under (a) or (b) on the
  Quest 3 they are **two** devices: Meta's SDE `msm_drm` for KMS, and the GPU driver.

## 2. GPU options for the Quest 3 (Adreno 740v3, `anorak`)

### (a) Meta KGSL plus a patched Turnip

**Feasibility for offscreen rendering: high [D].**
- `QCOM_KGSL=m` ships in v2.7 (`msm_kgsl.ko` in `vendor_dlkm`) [M-static config; FS-A-006
  module table].
- Timeline ioctls (`kgsl_timeline.c`), `DMABUF_HEAPS=y` and `SYNC_FILE=y` are present
  [M-static, `community-quest-repos-2.md` §2].
- Offscreen Turnip-KGSL ran on stock Quest 3 Android with the GPUOBJ allocation patch
  [C, `armadavr.md`]. Turnip-KGSL plus Zink ran the Frame UI on a Quest 2 [C, QK2].

**Mesa work (state it honestly) [M-static review of upstream Mesa → D].** Building with
`-Dfreedreno-kmds=kgsl` is not enough:
- upstream `tu_knl_kgsl_load` fails when `VK_KHR_display` is enabled;
- upstream disables `VK_EXT_physical_device_drm` for KGSL;
- so gamescope gets no render node, and Xwayland/glamor and GBM-on-Zink need one.

**Needed:**
- a **Turnip fork** for all four builds (native, x86_64, i386, Android guest);
- **Vulkan loader overrides** in our layer, so that Valve's ICD files are shadowed and no Valve
  binary is changed (D3);
- the community KGSL↔syncobj, display-helper and physical-device-drm patches as references
  (licence check first) [C];
- FEX's handling of KGSL ioctls from 32-bit guests [O];
- Valve's own Mesa patches, which are missing from upstream [O].

**Kernel work.** G1 (offscreen) uses Meta's unmodified KGSL on the stock kernel. The community
display route **also** needs two changes [C, `armadavr.md`, `oculus-linux-kernel-yusuf.md`]:
- Meta's SDE `msm_drm.ko` patched for `DRIVER_SYNCOBJ`/`_TIMELINE`;
- dma-buf sync-file import/export back-ported into vmlinux.

That is a rebuilt vendor display module plus a vmlinux change: new Chair class C10, PM
decision PD-12. Whether sync_file-only explicit fencing (SDE in-fence fds) avoids both is [O];
try it first at G2.

**Display coexistence.** Android uses exactly this pairing: KGSL renders, SDE scans out, and
dma-buf/sync_file connect them [C, the Android design; not measured by us].

**Thermal and power: the best of the three.**
- Meta's GMU, DCVS, IFPC and devfreq cooling stay in charge [M-static, checklist A6].
- `fs-thermald` caps the GPU through KGSL's nodes (T2, Chair class C5).
- Governor autonomy without Android is [O]: the Quest 1 lineage forced `performance` [C].

**Firmware loading.** GPU firmware: `a740v3_sqe.fw`, `gmu_gen70200.bin`, `a740v3_zap.*`
(FS-A-006).
- `FW_LOADER_USER_HELPER_FALLBACK=y` stalls 60 s on each missing file
  [M-static config, review].
- Images must lower `/sys/class/firmware/timeout` and stage the files before KGSL opens.

**Effort [C, rough]:**
- G1: 2–4 weeks.
- G2: 3–6 weeks, including the fence path.
- Compositor integration: 2–3 months.
- After that, permanent tracking of Valve's Mesa updates across four builds.

**Licence:**
- Mesa: MIT, with notices; FOSS is allowed (D6).
- KGSL and the SDE module: GPL-2.0, and any rebuilt module's source is published.
- Firmware: proprietary; taken from the user's own device and never redistributed.

### (b) Upstream drm/msm (GPU part) back-ported into Meta's 5.10

**Feasibility: low-to-medium, high uncertainty [D].**
- **Upstream support.** A7xx arrived upstream around 6.7, and current Turnip uses uAPI from
  6.17+ (VM_BIND) with a legacy fallback [C].
- **What the back-port needs:**
  - drm_sched/fence plumbing;
  - the adreno-SMMU interface on top of Meta's downstream `arm_smmu.ko`;
  - the GMU against Meta's RPMh/AOP and gpucc drivers;
  - zap-shader loading through SCM;
  - a **new a740v3 catalog entry**, because the chip is absent from mainline [M-static research
    pass; PROJECT_SETUP §3.1];
  - a **DT/dtbo change** for the GPU and GMU nodes (Chair class C11).
- **Coexistence.** The SDE already registers as `msm_drm`, so only **symbol clashes** with the
  shared msm lineage need renaming.
- **Community report [C, unpublished; private note].** A 6.14 drm/msm back-port reportedly runs
  on a 4.19 Quest Pro (A650, an older generation). No code or licence is available.

**Valve fit: the best of (a) and (b).** Valve's four Turnip builds would run unmodified.

**Split devices are a known code change, not [O]:**
- Turnip's primary node would be the GPU-only msm card;
- gamescope's DRM init then fails with "not a KMS device" [review, from the gamescope source].
- So (b) also needs gamescope or Turnip changes.

**Thermal/power: worse than (a).** Meta's tuned DCVS is lost, and rows A5, A6 and D2 must be
re-derived.

**Effort [C]:** 3–6 months for a GPU-only back-port. Licence: GPL-2.0.

### (c) A mainline-based kernel

**Feasibility: very low near term.** `anorak` has no mainline support, so this is a new-SoC
port [M-static research pass; Do-not 14].
- **Display:** the DPU has to be redone with Meta's DSC quad-pipe panels, where the XR2
  mainline effort (lynx-r1) is stuck [C]. Stage 3 would start over.
- **Thermal and power:** Meta's protections are lost, so everything is re-derived.
- **Valve fit:** the closest of the three (one msm device, Valve's Mesa unchanged).
- **Effort [C]:** a year or more.

### Shared by (a) and (b) [D]

- **Split KMS and GPU devices.** gamescope (or Turnip) must accept a display device that is not
  the Vulkan device.
- **Per-mixer planes.** The SDE garbles any plane wider than one pipe can feed (J-108/J-109,
  E6). gamescope needs a 4-plane split. vrcompositor needs a WSI/display layer that does the
  same, and a community member reports needing a custom WSI for this [C].
- **Geometry** (180° whole-frame plus ±21° roll; J-144, J-146) belongs in our HMD driver.

## 3. Recommendation: (a), re-decided at G2 [D]

1. **Safety.** Only (a) keeps Meta's GPU thermal/power management (§6A).
2. **Speed to evidence.** G1 needs no new kernel code: Meta's stock module on the stock kernel,
   the device's firmware and our Mesa build.
3. **The compositor work is common to (a) and (b)** (split devices, 4-plane layout). (a) adds
   the Turnip fork and possibly the SDE/fence patches; (b) adds the kernel back-port.
4. **The departure from stock is below Vulkan only.** Valve's binaries are untouched (D3, D6,
   §0.0 principle). The honest cost is a maintained Mesa fork for four builds.
5. **(b) spike after G1, offline, about 2 weeks:**
   - size the diff;
   - run the CRC gate;
   - list the SMMU/GMU/DT gaps.
   **Re-decide at G2, before any WSI or compositor work** (PD-1, PD-2). If (b) is small, it
   restores Valve's Mesa byte-for-byte.

## 4. Stage 4: booting Valve's Frame userspace on the Quest 3

### 4.1 Kernel prerequisites [M-static, v2.7 `kernel.config`]

| need | stock v2.7 | fix |
|---|---|---|
| DEVTMPFS, FHANDLE (systemd hard requirements), AUTOFS | not set | group a, gate PASSED (J-31) |
| BTRFS (Valve's rootfs, mounted `ro,nologreplay`) | not set | group a (=m) **plus `BTRFS_FS_POSIX_ACL`** |
| TMPFS_XATTR, TMPFS_POSIX_ACL (overlay opaque directories on a tmpfs upper; logind `uaccess` ACLs) | per review, needed | add; **rerun the kernel gate** for the new set |
| USER_NS, PID_NS | not set | group a′, PASSED |
| `fs-blkguard` (boot-chain block-write guard; J-119) | — | kernel patch plus its kgate CRC check (slot-in 0.6); Chair class C9 |
| SYSVIPC, POSIX_MQUEUE (Steam needs SysV IPC [C, QK2]) | not set | group b **changes struct layouts**, so vendor modules would be rebuilt; not needed for R-1 |
| BLK_DEV_RAM (R0) or BLK_DEV_NBD (R1) | not set | an explicit RAM disk or NBD (=m); gate check |
| OVERLAY_FS, DM_VERITY, LOOP, SOFT_WATCHDOG, USB ACM/NCM, FUSE, USB_STORAGE/UAS | set | — |
| VT/fbcon | not set | no text console on the panels; our KMS client draws |

The gate shows symbol-version compatibility only; runtime behaviour is [O] (FS-R-006 §2).

### 4.2 Where the rootfs lives

Facts:
- The Valve image is btrfs: 4.17 GiB used in a 5120 MiB `rootfs-A` [M-static].
- Super cannot hold a second slot set [F3].
- Userdata uses wrapped-key metadata encryption plus FBE [M-static fstab].
- **Linux-visible RAM (`MemTotal`) under our kernel is unmeasured [O].** The marketing figure
  is 8 GB [C]. Measure it read-only at K1.

| option | storage writes | pros | cons / gates |
|---|---|---|---|
| **R0 RAM root over USB** (recommended for R-1) | none | the image goes from the PC over the NCM gadget into a **`brd` RAM disk or a tmpfs with an explicit `size=`** (tmpfs defaults to 50 % of RAM, too small); then dm-verity (root hash in our image) → btrfs ro, with a small tmpfs overlay; the ACM console shares the composite gadget | about 4.2 GiB of RAM plus overhead; tethered; a new transfer class (C3); **not enough for G3** (Steam, CEF and the GPU in about 3 GiB) |
| R1 NBD from the PC | none | no RAM cost; suits G3 while tethered | needs `NBD=m`; rootfs I/O hangs if the link drops (the supervisor lives in the initramfs) |
| R2 external USB SSD (Chair-suggested, D4) | none internal | untethered from the PC | one USB-C port: the headset becomes USB host, so the gadget console is lost; hub and power arrangement needed |
| **R3 Unit 2 userdata reformatted** | userdata (`sda`) | persistent and fast; the basis of a dedicated install; **suits G3** | Android data gone; recovery to Horizon by factory reset is [O] and must be shown; C6; GPT untouched |
| R4 a partition carved from userdata | GPT on the LUN with `persist` | dual-boot without touching encryption | a GPT write; Android may reject a resized userdata [O]; Chair |
| R5 dual-boot sharing Android's encrypted userdata (key handoff) | userdata through Android's keys | keeps Android data | security-sensitive. Booting from ABL means no running Android, so the hardware-wrapped keys would need Android's TEE/KeyMint stack [C]. Kept out of public material (J-134). **Not recommended** |

**Power while tethered.** Charging and JEITA on the Quest 3 are ADSP-managed (checklist C2/C3).
Our images do not start the ADSP battery class, so **"the PC supplies power" is not a
supported safety claim**. R-1 either:
- (i) runs as a rule-2 bounded, attended hold, with the PM's before/after temperature
  procedure (J-145 charging rule); or
- (ii) requires T3b (battery-temperature class) live in `fs-thermald`.

PD-7 decides between them.

**Follow-up readings after AA (FS-R-012 §5, binding; 2026-10-15).** Every stage 3/4 run keeps
**at least one scheduled temperature reading about 5 minutes after AA**, continued while the
temperature rises or is concerning, with the ≥ 40 °C procedure applied immediately; a physical
shutdown and unplug-to-cool takes precedence, and the unit is never rebooted only to obtain a
reading. This overrides J-145's "follow-ups end in Android"; only J-145's charging rule (a
reading while charging accepted below 30.0 °C) is carried. The stage-3d form is
`devices/quest3/stage3d/STANDING-REPEATS.md` §4.2.

### 4.3 Boot flow (accepted architecture: `valve-image-slot-in.md` §5.1, D1)

1. Our kernel and initramfs.
2. **`fs-blkguard` armed** with our allowlist.
3. `fs-thermald` and its gate start (rev 5 §6.2).
4. The policy check for the exact Valve build, then dm-verity.
5. The read-only overlay root is composed: our `quest` layer over Valve.
6. `var` and `/etc` in Valve's pattern (tmpfs for R0/R1).
7. `switch_root` to Valve's systemd, with:
   - `systemd.unit=fs-console.target`;
   - `systemd.gpt_auto=0`;
   - `fstab=no`;
   - the named masks.

### 4.4 What must be in place first

| item | early console milestone (R-1) | sustained / GPU load (G3, R-2) |
|---|---|---|
| **boot-chain write guard** | **`fs-blkguard` armed before `switch_root`** (J-119; writer inventory B7/P2: "K mandatory"). `deckard-charger` (battery-NVM writer `update_pack_nvm.py`), `systemd-repart` and others hang off basic/sysinit targets, which **every** target pulls in | plus the D2 effective write boundary before broad activation |
| masks (named, plus technical prevention) | `deckard-charger`, `deckard-power-monitor`, `steamos-finish-oobe-migration`, `systemd-repart`, `etc.mount`, `steamos-offload.target`, `steamos-post-update`, `steamvr-program-ble` paths, `vrconfig_write`, the updaters (RAUC, atomupd, `steamos-boot`/`splctl`), every Frame-hardware unit (slot-in §2.3); **override `typec-plug-event.rules`** (it starts `usb-gadget.target` on cable attach), not only the gadget units; cmdline `systemd.gpt_auto=0` | the same; reviewed per Valve build |
| thermal / fan / battery (`fs-thermald` rev 5) | rule-2 bounded, attended hold **plus** the stage thermal guard (T1); battery: PD-7 (bound vs T3b) | full `fs-thermald` (Meta's config at runtime, option B), fan loop with tach handling, T3b battery class |
| watchdogs | softdog opened by the guard, after T0 reads `download_mode` = 0; `qcom_wdt_core` arming [O] (F1) | softdog owned by the supervisor; P15/P17; `RuntimeWatchdogSec=off` |
| input | power key → orderly power-off (P10) | volume keys; controllers later (H5) |
| debug link | our ACM console plus `sshd` over our NCM (Valve ships `openssh`) | adopting Valve's adbd/NCM: PD-8 |

> **PD-8 reconciliation (2026-10-14):** for the USB gadget, `usb-link-design.md` supersedes the "override `typec-plug-event.rules`" mask and the debug-link row above. For R-1 (Stage A), one cmdline mask `systemd.mask=usb-gadget.target` plus our `fs` ACM; no rule override.
| display | our splash client (fs-pattern lineage: 4×1032 planes, swap, roll) as our unit | gamescope through the 4-plane path |

### 4.5 The early milestone: is it realistic?

**Yes [D]:** "Valve's systemd reaches `fs-console.target`, observed over ACM/ssh, with our splash
on the panels". It is reachable without the GPU once K1, K1b (the guard) and R0 exist.

**What breaks, or stays masked:**
- **gamescope, Steam (CEF/GL via Zink), vrcompositor, Plasma/KWin and SDDM:** no Vulkan device
  and no software fallback (§1).
- **Steam:** also SysV IPC [C].
- **Frame hardware services:** masked.
- **OOBE:** may expect an update or controller pairing [O].
- **No VT:** only `serial-getty@ttyGS0` or ssh.

**What it proves:**
- Valve's systemd, journald, udev, D-Bus and polkit run on Meta's 5.10 under our layer and
  guard.
- The first log of what Valve's units probe (the J-120 mapping table).

## 5. Milestones (each device step needs its own package, reviews and the PM's sign-off)

| id | milestone | pass condition (distinguishable from "never ran") | needs |
|---|---|---|---|
| **O-0** | offline: slot-in phase 0 (ingest, writer closure **for the chosen build**, layer builder, `fs-blkguard` design plus kgate, QEMU decoy boot; §5.2, status [O]); the Turnip-fork cross-build | decoy hashes unchanged with the masks removed; guard denies in QEMU; `.so` builds reproducible | PD-4, PD-11 |
| **G1** | GPU offscreen on the **stock v2.7 kernel** (our initramfs, as in stage 3d): `msm_kgsl` plus staged firmware plus our Turnip; GPU at its lowest levels; short bounded hold | `vulkaninfo` names Turnip Adreno 740v3; an **analytically known image** (for example a solid fill plus a computed gradient) read back with every pixel equal to its formula | Chair C4, C5 |
| **S-b** | the (b) spike, offline, after G1 | a sized diff, a CRC gate result and a gap list | PD-2 |
| **K1** | first boot of a FrameShift-built kernel (groups a/a′ plus the ACL options, rerun gate): the stage-3d image on it; read `MemTotal` | `uname -v` carries our build id and nonce; the stage-3d optical PASS repeats | PD-5, C1 |
| **K1b** | `fs-blkguard` on device | a scripted write to a decoy-class target (for example `BLKROSET` clear) is refused and logged; nothing written | PD-10, C9 |
| **T1** | Quest 3 stage thermal guard live (tsens/ADC, softdog, `reboot(POWER_OFF)`) | every class is read; a forced test trip powers off within 3 s | PD-7, C5 |
| **G2** | GPU-rendered frame on the panels: dma-buf → SDE, 4×1032 planes, fence path | a GPU-drawn code read in each eye; the pixel formula checked on readback; **(a)/(b) re-decided** | PD-1, PD-12, C10 |
| **R-1** | **early milestone**: Valve systemd to `fs-console.target`; R0 RAM root; guard armed; our splash | target reached; unit list captured; splash seen; no masked unit active; guard log clean | PD-3, PD-7, PD-11, C2, C3 |
| **K2** | SysV IPC: prove the need in QEMU, then group b plus rebuilt vendor modules if needed | Steam client in QEMU with and without SYSVIPC | PD-6, C8 |
| **G3** | gamescope session (flat Steam UI) under full `fs-thermald` | Steam UI usable for N minutes under a thermal soak | PD-13, C6 if R3 |
| **R-3** | persistent storage on Unit 2 and inactive-slot boot | boots from the installed slot; Android recovery path demonstrated | PD-9, C6, C7 |
| **V1** | SteamVR: HMD driver plus the vrcompositor display layer (Stage 5) | a VR scene in both eyes, correct geometry | later |

## 6. PM decisions (asked in chat, one at a time; recommendations [D])

- **PD-1 GPU route.**
  - Options: (a) KGSL plus a Turnip fork; (b) drm/msm back-port; (c) mainline.
  - **Recommend (a)**, re-decided at G2 before any compositor work.
- **PD-2 (b) spike.**
  - Options: about 2 weeks offline after G1; no; later.
  - **Recommend after G1.** No community contact needed (J-139).
- **PD-3 R-1 rootfs.**
  - Options: R0 RAM over USB; R1 NBD; R2 external SSD; R3 Unit 2 userdata.
  - **Recommend R0** (sized RAM disk).
- **PD-4 Mesa source.**
  - Options: upstream Mesa near 26.3; also ask Valve for its tree (held letter).
  - **Recommend both.**
- **PD-5 First FrameShift kernel (K1).**
  - Options: Unit 2 first; Unit 1 first; both.
  - **Recommend Unit 2 first** (`fastboot boot`), then Unit 1.
- **PD-6 SysV IPC.**
  - Options: prove the need in QEMU first; rebuild group b now.
  - **Recommend prove first.**
- **PD-7 Thermal and battery envelope.**
  - G1: short bounded hold, or T1 first.
  - R-1: rule-2 bounded hold, or T1 plus T3b live.
  - **Recommend:** G1 bounded with the GPU at its lowest levels; R-1 with T1 plus a rule-2
    bound; T3b required before any unbounded run.
- **PD-8 USB debug link under Valve userspace.**
  - Options: ours (mask Valve's units and the typec rule); adopt Valve's adbd/NCM.
  - **Recommend ours for now.**
- **PD-9 Product storage policy.**
  - Options: dedicated install; dual-boot via a carved partition; dual-boot via Android's
    keys.
  - **Recommend dedicated first**, research the carved partition, no key sharing.
- **PD-10 Guard before R-1.**
  - Options: `fs-blkguard` armed before any Valve userspace (K1b); masks only for R-1.
  - **Recommend the guard first** (J-119; inventory B7/P2).
- **PD-11 Valve build for R-1.**
  - Options: 0.3.0 recovery rc (already analysed; OOBE, main-branch metadata); stable 0.4.5
    (`20261007.6125817`, signature verified, J-123; D7 default).
  - **Recommend stable 0.4.5**, after rerunning the writer closure on it. 0.3.0 stays offline
    only.
- **PD-12 Modifying Meta's display module.**
  - Options: none (sync_file-only fencing first); a rebuilt `msm_drm.ko` with syncobj plus the
    vmlinux dma-buf back-port, if G2 needs it.
  - **Recommend trying none first**; accept the rebuild as a reviewed, published-source change
    if needed.
- **PD-13 G3 rootfs.**
  - Options: R1 NBD (tethered); R3 Unit 2 userdata; R2 SSD.
  - **Recommend R3 on Unit 2** if C6 is granted, else R1.

## 7. Chair rulings that will be needed (new action classes)

| # | class | note |
|---|---|---|
| C1 | boot of a **FrameShift-built kernel** (kgate route a, rerun gate) | stage 1 reused the stock kernel |
| C2 | **execution of Valve userspace on a Quest** (controlled target) | D2: helper paths addressed; writer closure for the exact build |
| C3 | **host → headset RAM transfer of the rootfs** (R0), or NBD (R1) | no storage write; verity-authenticated |
| C4 | **KGSL load and GPU firmware/zap load** (secure-world PIL via SCM), plus the **firmware read path**: staged in a private test image from the OTA, or read from the device's own partitions by the J-122 option-B reader (**no mount**) | the GPU load itself |
| C5 | thermal classes of `emergency-shutdown-design.md` §7.3, **including the GPU cap writes for G1** (kgsl/devfreq) and ADSP start (T3b) | as listed there |
| C6 | **writing Unit 2's userdata** (reformat; GPT untouched) and the recovery route | D4 accepted only scoping |
| C7 | **flashing Unit 2's inactive slot** (`boot`, and `vendor_boot`/`dtbo`/`vbmeta` consistency) plus `set_active` | S4 separate package; the active slot is never touched |
| C8 | kernel group b with **replaced vendor modules** | only if K2 shows a need |
| C9 | **`fs-blkguard` kernel patch** (vmlinux change) and its on-device test | D2 noted the guard's gaps (SG_IO/BSG, dm, open fds, module/kexec) |
| C10 | **rebuilt Meta SDE `msm_drm.ko`** (syncobj) and the **vmlinux dma-buf sync-file back-port** | only if G2 needs them (PD-12) |
| C11 | for (b): the **DT/dtbo change** (GPU/GMU nodes) plus the new GPU module | only if (b) is chosen |

R5 (key handoff) is deliberately not proposed.

## 8. Carry-over to Quest 2 and Quest Pro (XR2 Gen 1, Adreno 650)

- **Kernels: 4.19**, not 5.4.
  - Quest 2 v2.7: `4.19.325-cip128` [M-static].
  - Quest Pro: built from the Quest 2 tree [M-static, PROJECT_SETUP §1].
  - The gates passed with ACM and groups a/a′ (J-32, J-36). The ACL/tmpfs options and the guard
    need their own gate runs.
- **GPU.**
  - Turnip-KGSL on A650 has community evidence [C]. The Q2 KGSL uses ION, not dma-heaps
    [M-static]; the fork must handle that [O].
  - (b) is more plausible here: a6xx is long upstream, and there is the community 4.19 Pro
    report [C].
  - (c) is far more realistic than on the Quest 3 (SM8250 has mainline support); the dual-DSC
    panels are the blocker [C].
- **systemd 257 on 4.19:** [O]. Check in QEMU before any Q2 R-1.
- **Carries over:**
  - the layer, RAM-root and guard design;
  - `fs-thermald` (per-device tables; Pro ≠ 2);
  - the Turnip fork;
  - the compositor plane layer (per-device E6).
- **Per device:**
  - the console (no ACM in stock Q2);
  - the fan (Q2 has none before a DRM panel);
  - the Pro's eye- and face-tracking IR (H1).

## 9. Open questions [O]

- Valve's Mesa source and patches.
- Whether sync_file-only fencing avoids the SDE rebuild.
- vrcompositor's display path on the Frame.
- KGSL governor autonomy without Android.
- FEX KGSL ioctls from i386 guests.
- OOBE behaviour on 0.4.5.
- Android recovery after an R3 reformat.
- `qcom_wdt_core` arming.
- Linux-visible RAM under our kernel.

## Sources

- Repo docs:
  - the private game plan §3;
  - `docs/PROJECT_SETUP.md` §0.0, §1, §3, §6A;
  - `docs/DEVICE_PORT_CHECKLIST.md`.
- Research notes:
  - `docs/research/display-geometry-stereo.md`;
  - `emergency-shutdown-design.md` §0, §6.2, §7.3;
  - `valve-image-slot-in.md` §3–§5;
  - `valve-writer-inventory.md` (B7, P2, M1–M2);
  - `community-quest-repos-2.md` §2;
  - `armadavr.md`;
  - `oculus-linux-kernel-yusuf.md`;
  - `<private note, withheld>` (paraphrased, private).
- Relays and journal:
  - FS-A-001 (private review record), FS-A-006 (private review record);
  - `docs/JOURNAL.md` J-31, J-118–J-147.
- Static artifacts:
  - `~/sfroot-full` (pacman db, `usr/share/vulkan`, fex-mesa `icd.d`, `usr/lib/dri`, unit and
    rule names);
  - `firmware/SteamOS/extracted/config-6.18.0-gfbdbca41fd45`;
  - `firmware/quest3/extracted/v2.7-user_ota/kernel.config`.
- Web:
  - GitLab API, upstream Mesa commit `8aa73b4b` → "404 Commit Not Found" (2026-10-14).
- Adversarial review (2026-10-14): upstream Mesa (`tu_knl_kgsl`, `tu_device.cc`) and gamescope
  findings, as relayed by the coordinator.

**Rev 1 changes:**
- the guard (K1b, PD-10, C9);
- the honest Mesa and kernel work for (a) (C10, PD-12);
- split devices as a known change, with the re-decision moved to G2;
- R0 sizing and the G3 route (PD-13);
- the ACL/tmpfs options and a gate rerun;
- named masks, the typec rule and `gpt_auto`;
- the tethered-power claim withdrawn (PD-7);
- PD-11 (Valve build);
- C11;
- the four Turnip builds;
- no software GL;
- the tag and citation fixes;
- the analytic G1 check on the stock kernel;
- the firmware timeout;
- the spike moved after G1.
