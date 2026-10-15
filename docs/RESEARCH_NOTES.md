# FrameShift — research notes

*Edited for publication: names and links removed or paraphrased.*

Working notes on questions that are open but **deliberately deferred** — not
plans, and not relayed. Tags per FS-R-001: **[M]**, **[M-static]**, **[D]**,
**[C]**, **[O]**.

---

## 1. Boot-chain alignment with Steam Frame (PM goal, 2026-10-07)

**Goal:** a boot chain as close to Steam Frame's as possible, so the port
tracks Valve's OS with the least divergence.

What Valve's OS actually touches in the chain, from `FS-A-001`/`FS-A-002`:

- **U-Boot** reads the btrfs rootfs, loads `/boot/Image` and
  `/boot/initrd.uImage`, and passes `rauc.slot=`. **[D]** at strings level.
- **`splctl`** keeps slot state in a U-Boot-style environment on a `bootenv`
  partition. **[M-static]** strings only.
- **`kernelsetup.sh`** writes U-Boot and the SoC boot firmware. Isolated by
  FS-R-001 — never run on a Quest.

**[C]** Below U-Boot, the OS never interacts with the chain except through
`kernelsetup.sh`, which we isolate. So "close to Steam Frame" means **Meta's
`xbl`/`abl` → U-Boot → Valve-style boot of the rootfs**. That is achievable by
packaging U-Boot as an Android boot image for `abl` to start. **[O]** Mainline
U-Boot's support for that route on SM8550 is unverified. FS-R-001 §4 defers it
past the first shell; it remains the long-term target.

## 2. Updates (PM preference: Valve's updates directly)

FS-R-001 R3 rules out installing unmodified Valve bundles on a Quest. The
closest compliant form is in `FS-A-002` §3:

- fetch Valve's bundle on-device from `steamdeck-images.steamos.cloud/vr/`;
- verify Valve's signature;
- diff the writer inventory and halt on change;
- transform;
- install.

Valve's userspace flows through unchanged and nothing of Valve's is
redistributed. "Our own update channel" shrinks to that transformation step.

## 3. Head tracking — deferred past the boot PoC (FS-R-001 §5), not dropped

PM, 2026-10-07: tracking is what makes VR functional. Order of work stays
boot → display → GPU → rootfs → tracking, but tracking findings are recorded
here as they turn up.

- **Precedent:** `nicolas-riera/Quest1-SteamOS` reports SteamOS on a Quest 1 via
  `fastboot boot` of Meta's own kernel. It uses Monado, a custom SteamVR driver
  (`src/steamvr-quest1`) and 3DoF via SyncBoss, plus a static map of the Frame
  stack in `docs/steamframe-stack.md`. **[M-static]** from a research pass;
  not yet read by me.

PM leaning, 2026-10-07: route 2, because it's more native to the OS.

| route | what runs Meta's tracking | notes |
|---|---|---|
| 1. Android container + pose bridge | Meta's own services, in an Android container beside SteamOS; a SteamVR driver receives poses | **No translation layer** — same CPU, same kernel, native ARM64 code; the cost is one IPC hop. Valve's **Lepton** is precedent |
| 2. libhybris | individual Android HAL libraries loaded into glibc processes | most "native"; hardest if the stack is a web of services rather than a library |
| 3. open source (Monado + Basalt) | nothing of Meta's | blob-free and portable to every target; lower quality; controllers hard; Quest 3 camera support in mainline **[O]** |

- **Routes 1 and 2 run the same binaries.** The choice turns on the shape of
  Meta's tracking stack — a library with an API, or a set of services —
  which is **[O]**. Community knowledge would settle it quickly.
- **Recompiling is not available.** Meta's tracking is closed-source.
- **Valve Lepton** — **[M-static]** README at
  `gitlab.steamos.cloud/frame-public/lepton`. A non-root Android container for
  Android VR games on Steam Frame. It is built from Waydroid, Anbox, Halium and
  Hybris — libhybris is in it, so routes 1 and 2 meet there. MIT for the tool,
  GPL-3.0 for the Android image. **[M-static]** It is not in the OS image;
  **[C]** the Steam client delivers it.
- **Valve's own tracking** is the SteamVR `cv` driver plus SM8650 DSP images
  (`FS-A-001` §6). FS-R-001: an SM8650 dependency is a hypothesis.

## 4. Stage 1 kernel, long term (PM question: best long-term support)

- **Stage 1 (FS-R-001 §2):** the stock Quest 3 kernel from the selected
  baseline plus a minimal initramfs — fewest simultaneous changes.
- **Long term, [C]:** a mainline-based kernel tracking Valve's line (6.18 today)
  with a Quest 3 DT. That is what Valve's userspace is built against — upstream
  `drm/msm`, Mesa/Turnip expectations, btrfs. Downstream vendor kernels stall
  on their own version. Developed offline in parallel, per the ruling.
- Valve's Frame kernel source is not located (`FS-A-002` §6). Mainline 6.18
  plus Valve's extracted config is the substitute.

## 5. Community work index — by device (don't reinvent the wheel)

PM principle, 2026-10-07: build on what others have done; perfect what they
haven't. Summarised in `JOURNAL.md` → *Building on others*. The detail here
comes from research passes of 2026-10-07, **[M-static]** unless noted.

### Quest 3 — useful now

- **`hashtagbasit/SteamOS-ARM-Port`** (GPL-2.0; HEAD `5825382`).
  - **Initramfs:** `external-and-mods/kernel-common/initramfs/init`. Busybox;
    `steamos.root=` overrides root, so a stock ABL's appended args can't
    redirect it; `steamos.usbshell=1` brings up a configfs ACM+NCM gadget with
    telnetd on 172.16.42.1; `bootlog.txt` is written to FAT. **Template for
    our E v0 initramfs.**
  - **Valve rootfs ingest:** `make-steamos-sm8650.sh:111-147` and
    `scripts/extract_rootfs.py`. It flattens btrfs to ext4 and drops Valve's
    `/boot` and modules. It pins Valve build `20261002.6232440` (0.5.3, a
    *dev* build — we differ: stable only).
  - **Service masks:** `scripts/apply-overlays.sh:266-291`.
  - **Signed A/B updater with fallback:** `external-and-mods/konkr-update/`
    (Ed25519, staged, state machine, recovery in the initramfs). A model for
    our own update channel.
  - **Stock-ABL recipes** — the right templates for a Quest:
    - REDMAGIC 6, `kernel-sm8350/`: v3 boot plus vendor_boot, dtbo erased,
      one DTB copy per board-id. Nubia's ABL ignored `fastboot boot`.
    - Lenovo elden: v4 image with built-in DTB and cmdline.
  - **Don't take:** its handheld stripping of VR components.
- **`MaSieS4Fun/SteamOS-ARM-SM8550`** — Armbian `sm8550` kernel patches for
  7.0.x, plus ROCKNIX deep-suspend patches. Bring-up material for a future
  mainline Quest 3 kernel; its DTBs and ABL dependency don't apply.
- **`iddqdExe` fork** (`d08846a5`, `971ecc56`) — stock Qualcomm ABL skips
  only the gzip header plus FNAME, so appended DTBs must be 8-byte aligned.
  Pad FNAME. Relevant if we ever ship gzip v0 images.
- **`justjoseorg` fork** (`5557ac0d`) — enumerates the Frame's VR components
  by deleting them: `vrserver`, `vrcompositor`, `dsp_service`, `deckard-*`,
  `steamos-headset-*` and others. For us that is the **keep** list.
- **`gryoza/reverie`** — `build/extract_rootfs.py` rebuilds the rootfs from
  Valve's casync store. It does **not** verify RAUC signatures; ours must.
- **`Chazmus` fork, `AGENTS.md`** — WirePlumber VR configs (spatial audio,
  mic tracker, `wireplumber-steamvr.conf`). Contains at least one wrong claim
  (a "proprietary Adreno driver"); verify before use.

### Quest 2 (secondary target) and Vive XR Elite (SM8250, after the Quest 3S)

- **`seilent` fork, branch `pocket-micro-2`** (19 commits ahead; AYANEO Pocket
  Micro 2). SM8250 kernel 7.2.6 on arm64 `defconfig` with patches, DTS and
  config from `seilent/armada` at `984532ff…`. Built-in Adreno 650 firmware
  (a650 sqe, gmu, zap), sm8250 adsp, ath11k QCA6390. GPU OPP above 625 MHz
  removed.

### Quest 1 (MSM8998) — later

- **`nicolas-riera/Quest1-SteamOS`** (HEAD `b7467ff`). SteamOS Holo on a
  Quest 1 with no Android:
  - boots by `fastboot boot` of Meta's 4.4 kernel
    (`oculus-linux-kernel@6929f734` plus a patch), as a v0 Image.gz-dtb;
  - loop-mounts `/data/steamos/holo.img`;
  - Adreno 540 Vulkan through libhybris;
  - Monado with an MDP display path, a custom SteamVR driver
    (`src/steamvr-quest1`), 3DoF via SyncBoss, Touch controllers;
  - `docs/steamframe-stack.md` maps the Frame stack.

  Requires an unlocked headset (assumed).

### Other Quest projects (examined 2026-10-08)

- **`YusufOzmen01/quest-kexec`** (`e61edbd`) **boots a second copy of Meta's
  Android** on a Quest Pro, through kexec. It contains **no SteamOS**. We do
  not use kexec. Its lessons still apply:
  - start the ADSP explicitly;
  - a declared but absent HAL blocks Meta's power services;
  - its rebuilt kernel failed `module_layout`, so 12 modules had to be
    rebuilt.

  Detail: `docs/research/FS-A-006-quest-projects.md`.
- **`project-barry/pb-os`** (`f2ffd9f8`): a basit derivative using the same
  approach.
- **SteamOS-ARM-Port** upstream HEAD `aab5fea4` (was `58253820`): adds only
  UI, update and SM8750 changes.

Cross-reference of all ports: `docs/research/FS-A-006-ports.md`.

### Not yet examined

`aeongdesu/holo-deckard-docker`, `lhns/steam-frame-nix`, `seilent/armada`,
`armada-os/armada`, `xXJSONDeruloXx/lepton` (a Lepton mirror).

## 6. Valve build 0.5.5 — what a diff would and wouldn't tell us

0.5.5 is a `main` (dev) build. A full diff against 0.3.0 or 0.4.4 would show
how Valve's update and firmware scripts change across versions — a direct test
of FS-R-001's point that future builds may change the writer logic. It costs
about 2.0–3.7 GiB of chunk downloads per build, and the `.raucb` bundles
themselves contain no scripts. **Nothing in our plan needs 0.5.5.** The diff
that matters is **stable to the next stable** — the input our update
pipeline's writer-inventory gate will see.

## 7. Kernel strategy after the `anorak` finding (2026-10-07)

Research passes, **[M-static]**, not yet re-checked by the Arbiter.

- **Mainline has nothing for Quest 3's platform.**
  - No SoC ID 549 in `qcom,ids.h` / `socinfo.c`.
  - No `anorak` clock, pin or interconnect drivers.
  - GPU chip ID `0x43050b00` is not in `a6xx_catalog.c`.
  - Zero patchwork hits for anorak / SXR2230P.
- **The closest mainline code isn't SM8550:**
  - GCC register offsets match **sm8450** (95/119) far better than sm8550
    (0/97);
  - the UFS PHY address matches sm8450;
  - the GIC address matches Qualcomm's AR SoC **SAR2130P**, upstreamed by
    Linaro.
- **What else is anorak-specific:** two display clock controllers; 225 pins;
  6 CPU cores reported as `qcom,kryo` (**[O]**, to confirm from MIDR on the
  device).
- **What this means:**
  - **Near term:** Meta's published downstream 5.10 kernel is the base. It is
    exact for v72, v76, v84 and v2.7. Stage 1 reuses it unmodified.
  - **Stage 2 (headless SteamOS userspace):** check what Valve's userspace
    needs from the kernel — systemd version, cgroup v2, btrfs (or an ext4
    copy, FS-R-003 §2), etc. — against 5.10.
  - **Stages 3–5:** **[O]** whether gamescope runs on the downstream
    `msm_drm` (SDE) KMS, and whether Valve's Mesa includes Turnip's **KGSL**
    backend (the downstream GPU driver). If both hold, a downstream-kernel
    SteamOS is viable long before any mainline work.
  - **Long term:** a mainline `anorak` port, modelled on the sm8450 and
    sar2130p drivers with Meta's GPL downstream sources as the register
    reference. It is a large project and a natural one to open to
    collaborators.
- **Display, either way:** the panel is Sharp/Novatek, dual-DSI video mode
  with DSC, C-PHY, 2064×2208 per eye, 72–240 Hz. The postmarketOS panel
  generator produces only a skeleton (no dual-DSI; ignores Meta's pre-on and
  post-on sequences). The Lynx R1's stuck dual-DSC bring-up is the warning
  sign.

### 7.1 Update, 2026-10-08 (FS-A-006 research)

- **Valve userspace needs a rebuilt kernel.** The stock Quest kernels
  (v66, v2.7, and Quest 2 v2.7) lack DEVTMPFS and FHANDLE (systemd 257
  "required"), USER_NS, PID_NS, SYSVIPC, POSIX_MQUEUE, AUTOFS and BTRFS
  [M-static]. Every community port rebuilt its kernel [D].
- **Meta's public source:**
  - `23c97b2` = v66 build `.510` (user; our unit is `.511`);
  - `752916b0bd` = v72 (exact);
  - `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f` = v2.7 (the build target).

  Build with `README.meta.md`'s environment (`REAL_CC`, LLVM tools) and the
  matching AOSP clang.
- **Module compatibility:** `MODVERSIONS=y`, no module signing. Rebuilt
  kernels must reproduce the stock CRCs. **Layout-changing options**
  (SYSVIPC, POSIX_MQUEUE) **change CRCs**, so vendor modules would need
  rebuilding. DEVTMPFS, FHANDLE, AUTOFS and BTRFS=m are expected to be
  neutral (FS-A-006 §3).
- **The official GKI kernel cannot be used:** only 785 of 2487 CRCs match.
- Details: `docs/research/FS-A-006-kernel.md`, `FS-A-006-userspace.md`.

## 8. Persistent diagnostic logs (PM question, 2026-10-07)

PM: some directories persist across reboots — could crash logs go there?

| location | persists? | usable by a test initramfs? |
|---|---|---|
| ramoops (RAM) | **no** — not retained across any reboot tested [M] | — |
| `pstore` partition (2 MiB, `sde49`) | yes | it is all zeros [M-static], and the stock kernel lacks `PSTORE_BLK`, so our init would have to write it raw. A persistent partition write — outside E v0 per FS-R-003; possible later as its own reviewed experiment |
| `/data` (`userdata`) | yes | **no** — encrypted; keys come through Android's vold/keystore |
| `persist`, `metadata`, `misc`, `devinfo` | yes | **never** — calibration, encryption metadata and boot-control state |

The persistent places Android uses all sit behind encryption or hold critical
state. **[C]** The best substitute is to keep evidence *out of* storage:

- live USB serial;
- LED stage colours, seen by the PM;
- timed reboot-to-bootloader, observed by the host;
- Android's recorded boot reason afterwards.

If those prove insufficient, a **raw write of a small log record into the
unused `pstore` partition** is the least risky persistent channel. It would
need the PM's approval and its own relay.

## 9. Coexisting boot chains (PM questions, 2026-10-07)

"Valve's boot chain" is really two layers.

1. **SoC firmware** — `xbl`, `tz`, `hyp`, `aop`, `uefi` and friends; Valve's
   `bootfw.tar.xz`.
   - These run before any OS. The chip's ROM only accepts Meta-signed `xbl`.
   - TrustZone and the hypervisor stay **resident** while the OS runs.
   - There is exactly one such chain per power-on, so Meta's and Valve's
     cannot coexist.
   - Valve's are built for SM8650 and signed for the Steam Frame anyway.
2. **The OS-level loader** — U-Boot, its environment, slot state and the
   rootfs. These **can** coexist:

   ```
   Meta xbl → Meta abl → (our) U-Boot, packaged as a boot image → SteamOS on userdata
   ```

   Meta's partitions are never touched. U-Boot would be our own build for
   `anorak` — Valve's binary is built for SM8650 — and would live in a boot
   slot. Its environment and the SteamOS partitions would live inside
   `userdata`. This is FS-R-001 §8.4's deferred route, and it fits the PM's
   slot policy: slot B is the test slot.

## 10. Stage-2 research index (2026-10-08)

| topic | file |
|---|---|
| community ports cross-reference | `docs/research/FS-A-006-ports.md` |
| Quest-specific projects (Quest1-SteamOS, quest-kexec) | `docs/research/FS-A-006-quest-projects.md` |
| Valve userspace vs the Quest kernel; the smallest Valve test | `docs/research/FS-A-006-userspace.md` |
| Quest 3 power, fuel gauge, thermal, fan | `docs/research/FS-A-006-power-thermal.md` |
| kernel rebuild feasibility; subsystem module map | `docs/research/FS-A-006-kernel.md` |
| Quest 2 v2.7 first look | `docs/research/quest2-v2.7-first-look.md` |
| Quest 3 display bring-up (stock kernel, static pattern) | `docs/research/display-bringup-quest3.md` |
| performance envelopes | `docs/research/perf-envelope-quest3.md`, `-quest1-2.md`, `-xr-elite.md` |
| mandatory per-device checks | `docs/DEVICE_PORT_CHECKLIST.md` |
| *added to the index 2026-10-10:* thermal and fan control design | `docs/research/thermal-control-design.md` |
| trial (iii): why the panels stayed dark (H1/H2) | `docs/research/display-handoff-dark.md` |
| Quest 3 panel and backlight (public web) | `docs/research/quest3-panel-online.md` |
| display clues from quest-kexec and Quest1-SteamOS | `docs/research/display-clues-kexec-quest1.md` |
| YusufOzmen01 oculus-linux-kernel fork | `docs/research/oculus-linux-kernel-yusuf.md` |
| trial (iii) serial loss and pacing | `docs/research/serial-loss-trial3.md` |
| *added 2026-10-11:* trial (iii-b) garble cause, how Meta drives the Quest 3 panels, community display precedents, panel geometry (cant/roll) | `docs/research/display-pipeline-and-geometry.md` (J-109) |
| stage-3c rerun design (interactive per-phase flow, 4-plane layout, run 3) | `devices/quest3/stage3c/DESIGN.md` (J-109) |
| community Quest repos, pass 2 | `docs/research/community-quest-repos-2.md` |
| ArmadaVR | `docs/research/armadavr.md` |
| Valve packages, Holo Core and redistribution | `docs/research/valve-packages-licensing.md` |
| pattern previews | `docs/research/pattern-preview/` |
| panel geometry, stereo, cant and roll | `docs/research/display-geometry-stereo.md` |
| emergency shutdown design | `docs/research/emergency-shutdown-design.md` |
| GPU route decision (route e′, J-154) | `docs/research/gpu-route-decision.md` |
| open-source tracking survey | `docs/research/oss-tracking-survey.md` |
| performance envelope, Quest 1 and Quest 2 | `docs/research/perf-envelope-quest1-2.md` |
| performance envelope, XR Elite (shelved) | `docs/research/perf-envelope-xr-elite.md` |
| community Quest ports: tracking | `docs/research/quest-ports-tracking.md` |
| stage 3 (GPU) and stage 4 (SteamOS rootfs) plan | `docs/research/stage3-4-plan.md` |
| SteamOS ports survey | `docs/research/steamos-ports-survey.md` |
| SteamOS update channels (D7) | `docs/research/steamos-update-channels.md` |
| tracking and input route | `docs/research/tracking-input-route.md` |
| USB link design (PD-8) | `docs/research/usb-link-design.md` |
| slotting Valve's image in (distribution architecture) | `docs/research/valve-image-slot-in.md` |
| Valve's hardware writers and protections | `docs/research/valve-writer-inventory.md` |
