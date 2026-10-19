# GPU route decision for the Quest 3 (PD-1 reopened)

**Status:** research and recommendation only, 2026-10-14 (J-150 brief). No device was touched.
**Revision 1:** the adversarial review (GO-with-fixes; (e′) stays the recommendation) has been
applied; see §6. **Revision 1.1 (2026-10-18):** the FS-R-015 §7 correction to F2a below.

> **Correction (FS-R-015 §7, 2026-10-18).** F2a (added J-199) said Turnip's display WSI "must
> implement" `VK_EXT_display_control` and `VK_EXT_display_surface_counter` "for real", and stated
> the V4L2 decoder as a need. The Chair ruled that F2a is a **concrete compatibility lead**:
> imported or referenced extension names do not establish mandatory use, the absence of a fallback,
> or a working Quest display path. The decoder claim likewise remains a lead until confirmed. F2a
> is reworded in place; the route recommendation is unchanged.

**Method:**
- No Valve, Meta or Qualcomm binary was disassembled or decompiled.
- Binaries were read only for string presence, symbol tables (dynamic imports) and package
  metadata.
- Kernel and DT facts come from Meta's published GPL source and from public upstream source.
- Disclosure: while drafting, Valve's Frame DTBs were converted to text with `dtc`. That is a
  format conversion of a data blob, not code. The outputs were deleted, and nothing from them is
  cited; the GPU-thermal points come from upstream `sm8550.dtsi`.

**Question:** which GPU route is the best long-term one, the most stable, the most polished and the
most feasible? It must keep safety first and reach users reasonably soon, under the PM's
principle: *"a 100% pure SteamOS image, and just modify the Meta parts that hook into it"*
(J-150).

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named file or
source · **[D]** derived · **[C]** unconfirmed, web or community · **[O]** open.

Effort is given in **person-weeks (pw) of focused agent work**. Hardware-trial time, reviews and
Chair turnaround are not included.

---

## 0. The answer in brief

1. **What Valve's userspace really needs** (§1): **one** DRM device named `msm` that provides both
   the GPU uAPI and KMS on the same node and accepts one full-width plane.
   - On the Frame, upstream drm/msm is that device.
   - On the Quest 3, the "Meta parts that hook into it" are two kernel modules: Meta's SDE display
     driver (`msm_drm.ko`) and KGSL (`msm_kgsl.ko`).
   - If those two present that device, **every Valve file stays byte-for-byte unchanged**: all
     four Turnip builds, Zink, gamescope and vrcompositor.
   - A few Valve scripts hard-code Frame specifics and get Quest-side drop-ins in our layer
     (§3.1).
2. **Recommendation: route (e′), the "Frame-compatible `msm` device".**
   - Rebuild Meta's two modules from Meta's GPL source so that together they register one DRM
     device named `msm`:
     - Meta's SDE KMS;
     - an in-kernel drm/msm GPU uAPI implemented on a **refactored** Meta production KGSL;
     - syncobj with a working fence path (§2e, M1);
     - a kernel-side split of one wide plane into the four ≤1032-px pipes.
   - Nothing changes on the SteamOS side.
   - Meta's GPU power, DCVS and thermal management stay in charge, as in today's safety design.
3. **Staged path.** All stages hide behind the same userspace contract, so SteamOS never notices
   when the GPU back-end changes.
   - **Fastest first pixels:** keep G1, the upstream Turnip-KGSL offscreen test on the stock
     kernel (2–4 pw). It is a test tool only and is never shipped.
   - **Then:** **18–32 pw** to Valve's vrcompositor on the panels, plus **3–6 pw** for
     VM_BIND/sparse: **about 21–38 pw to Frame parity** (§3).
   - **Fallback back-end:** the upstream drm/msm GPU back-port (b).
   - **Long-term horizon:** mainline (c), re-checked at fixed checkpoints (§3).
4. **Rejected:**
   - (a), KGSL plus our own Turnip fork, as the product route: it forks Valve's Mesa (×4) and
     gamescope, permanently.
   - (b2), a newer downstream kernel: it is still KGSL plus SDE, at 12–20+ pw.
   - (c), mainline, as a near-term route: 20–35 pw to first light, and it is blocked on upstream
     work.

---

## 1. The decisive facts: what Valve's image talks to

| # | finding | source |
|---|---|---|
| F1 | **gamescope on the Frame does not drive KMS.** `gamescope-session` runs it with `--backend openvr --allow-deferred-backend`, as a SteamVR overlay | `~/sfroot-full/usr/lib/steamos/gamescope-session` L59–60 [M-static] |
| F2 | **The KMS client is vrcompositor, through Turnip's display WSI.** Its strings include `VK_KHR_display`, `VK_EXT_acquire_drm_display`, `vkAcquireDrmDisplayEXT` and `VK_EXT_direct_mode_display`. It also uses libdrm at runtime (imports `drmModeGetResources`/`GetConnector`) and has a **DRM-lease path** (review). vrcompositor and `modetest` are the only KMS masters; Plasma runs nested (review-verified) | `/opt/steamvr/bin/linuxarm64/vrcompositor` (strings, symbol table) [M-static → D] |
| F2a | **Compatibility lead (corrected rev 1.1, FS-R-015 §7): vrcompositor references Vulkan display-event and present-timing entry points:** `vkRegisterDisplayEventEXT` (alongside a "VulkanVblankThread" string), `vkGetSwapchainCounterEXT`, `VK_KHR_present_id` and `present_wait`. That suggests it can pace frames from display events [C]. The names alone do not establish that the paths are mandatory, that no fallback exists when `VK_EXT_display_control` / `VK_EXT_display_surface_counter` are absent, or that any Quest display path works [O]. So implementing them in Turnip's display WSI on our KMS route, with vblank events from the Quest 3 DRM driver, is a **candidate requirement to confirm** (by tracing which paths run, on a host or the device), not an established one (added J-199). Likewise, the Steam Link player's need for a V4L2 stateful decoder (NV12) is a **lead** from the stearlight study, until confirmed on our side | names confirmed present in our 0.4.5 `vrcompositor` [M-static]; their use and necessity [O]; the pacing reading and the decoder need come from the stearlight source study (`<private note, withheld>`) [C, lead] |
| F3 | Valve's helper scripts address the display **by driver name** (`modetest -M msm`) and hard-code Frame specifics: DSI-1, one 4320×2160 plane on one CRTC. `set_kernel_thread_priorities.sh` names drm/msm threads (`msm`, `ring0..3`, `dsi_drm_work_*`); without matches it skips silently and loses those RT priorities | `/usr/bin/displays_turn_off_drm_master`; `/usr/share/deckard/set_kernel_thread_priorities.sh` L71 [M-static] |
| F4 | **Turnip opens a DRM device only if its driver name is exactly `msm`, at version 1.x with x ≥ 6** (syncobj). With `VK_KHR_display` it opens **the same device's** primary node as the display (`master_fd`) | Mesa main `5419740b` `tu_knl.cc` L417–440, `tu_knl_drm_msm.cc` L1341–1352 [M-static] |
| F5 | **Display WSI must be on the GPU's own device.** `can_present_on_device` uses `drmDevicesEqual`, and Acquire checks `st_rdev`; a different (SDE) fd returns `VK_ERROR_UNKNOWN`. The display WSI commits **one plane covering the full mode** | `tu_wsi.cc` L26–33; `wsi_common_display.c` L4597–4622, L2931–3016 [M-static] |
| F6 | Valve's Turnip builds have **no KGSL backend** (no `/dev/kgsl-3d0` string). Upstream Turnip's KGSL backend **refuses `VK_KHR_display`** ("I can't KHR_display"), disables `VK_EXT_physical_device_drm` and has **no syncobj** (sync_file only, emulated timelines) | `libvulkan_freedreno.so` strings [M-static → D]; `tu_knl_kgsl.cc` L1901–1904 [M-static] |
| F7 | gamescope (OpenVR backend) needs a **render node** (`hasRender`) and **DRM syncobj** for explicit sync (OPAQUE_FD timeline export). wlroots offers linux-dmabuf/wl_drm only with a renderer DRM fd. GL is Zink; GBM falls back to kmsro→Zink | gamescope 3.16.28 (`fa0b4d33`) `rendervulkan.cpp` L461–507, `Timeline.cpp` L17–60; wlroots `d7835334`; Mesa `gbm_dri.c` L274–290 [M-static] |
| F8 | **Meta's SDE driver already speaks the drm/msm GEM uAPI.** It registers DRM driver `msm_drm` with `DRIVER_GEM \| DRIVER_RENDER \| DRIVER_ATOMIC \| DRIVER_MODESET`. Its ioctl numbers 0x00–0x0C match upstream; 0x0D–0x13 are Meta/QC private and **clash** with upstream 0x0D `VM_BIND` and 0x0E `PERFCNTR_CONFIG` | `techpack/display/msm/msm_drv.c` L2215–2294; `include/uapi/drm/msm_drm.h` L390–413 (Meta 5.10) vs upstream v7.2 L540–556 [M-static] |
| F9 | The SDE takes **one pipe per plane** (`maxlinewidth`); userspace must split wide layers. One plane wider than a pipe garbles the panels | `sde_plane.c` L2484–2556 [M-static]; J-108/J-109, E6 [M] |
| F10 | Quest 3 SoC (`anorak`, msm-id 549): the **fabric is SM8450-derived** (GCC 105/168, GPUCC 19/19 and icc 123/141 offsets match sm8450; DSI PHY v4.3); the display is **DPU 9.3** with two MDSS. The GPU is `gen7_6_0` "Adreno740v3", chip 0x43050b00, with firmware `a740v3_sqe.fw`, `gmu_gen70200.bin` and `a740v3_zap` | Meta 5.10 `anorak.dtsi`, `anorak-gpu.dtsi`, `drivers/gpu/msm/adreno-gpulist.h` L2175–2207, `sde_hw_catalog.c` [M-static]; offset comparison [D] |
| F11 | Meta's DT wires the GPU into the kernel thermal framework **through KGSL's node**: `&msm_gpu { #cooling-cells = <2>; }` and 9 cooling maps to `&msm_gpu` | `anorak-thermal.dtsi` L3–5, L954; `anorak-thermal-overlay.dtsi` [M-static] |

**What follows [D]:**
- The cheapest point at which to adapt the Quest 3 to Valve's image is **below** Vulkan, at the
  device contract (F4, F5, F7).
- Above that line, every route that leaves two devices or a KGSL node must patch Turnip, and
  usually gamescope too.
- Valve's image addresses the display by the name `msm` (F3, F4). An `msm_drm` display beside
  an `msm` GPU therefore cannot satisfy it unchanged.

---

## 2. The options

### (a) KGSL plus our own Turnip build, as an add-on layer

- **SteamOS-side changes:**
  - Turnip rebuilt for all four of Valve's builds (native, x86_64 and i386 FEX guests, Android
    guest) with `-Dfreedreno-kmds=msm,kgsl`. Runtime selection works, and KGSL wins (Mesa
    `vk_instance.c` L444–462 [M-static]).
  - **Patches:**
    - allow `VK_KHR_display` on KGSL with `master_fd` = the SDE card;
    - relax both device-equality checks (F5);
    - fake `VK_EXT_physical_device_drm`;
    - a 4-plane split in the display WSI (F5, F9).
  - **gamescope:** explicit sync breaks, because there is no syncobj on KGSL (F6, F7). Either a
    gamescope patch or a kernel syncobj bridge is needed. The community bridge pattern is KGSL
    timeline export plus `DRIVER_SYNCOBJ` on the SDE [C, `oculus-linux-kernel-yusuf.md`].
  - **Xwayland/glamor and wlroots dmabuf** need a render node that KGSL does not provide (F7)
    [D].
  - Valve's Mesa commit `8aa73b4b` is not public ("404 Commit Not Found") [C]. Our Turnip would
    lack Valve's own patches [O].
- **Stability across Valve updates: poor [D].** Every Valve Mesa update needs a rebased fork ×4,
  and our fork lags Valve's fixes. FEX's handling of KGSL ioctls from 32-bit guests is [O].
- **Power/safety: best** (Meta's KGSL unchanged).
- **Time:**
  - G1 offscreen: 2–4 pw.
  - Panels: +3–6 pw.
  - gamescope/vrcompositor: +6–12 pw (WSI split, sync bridge, gamescope patches).
  - Then permanent maintenance.
- **Chair classes:** C4, C5, plus C10 for the sync bridge.
- **Purity: low.** It modifies Valve's Mesa and probably gamescope.

### (b) Upstream drm/msm GPU back-ported into Meta's 5.10

**Size** [M-static line counts on `snap-<tag>`; D for the estimate]:
- **v6.18 base:** about 39k lines (a6xx/a7xx and adreno 17.2k, msm core GPU 12.4k, register XML
  9.3k), plus private copies of drm_gpuvm, drm_exec and the new scheduler (about 6.6k).
- **v6.14 base (no VM_BIND/gpuvm):** about 35k plus about 3k.
- **API gaps:** 73 symbols missing from 5.10 at v6.18, 44 at v6.14, across about 10 subsystems.
- **Hard ones:**
  - dma-resv usage semantics (5.10 still has the excl/shared model) → an implicit-sync
    translation against Meta's SDE;
  - the io-pgtable path through Meta's `qcom_iommu_util`;
  - Meta's `adreno_smmu_priv` lacks `get_fault_info`/`set_stall`/`resume_translation`/PRR
    (no stall-on-fault, no sparse/MAP_NULL);
  - GX/CX GDSCs are **regulators** on anorak, where upstream expects genpd;
  - the OPP API.
- **vmlinux:** need not change if everything is a private copy or a shim. A clean fix to
  dma-resv or `drm_gem_object` would break the KMI/CRCs.
- **A740v3 is in no mainline tag** (v6.6–v7.2). Mainline has 0x43050a01 only.
  - The 54 hwcg values match KGSL's `gen7_6_0`.
  - **The GMU chipid differs:** KGSL writes 0x07060000, mainline 0x7020100.
  - KGSL has gen7_6_0-only RSCC/BCL paths (`adreno_gen7_gmu.c` L76, 211, 640, 847).
  - **The real risk is hwsched versus non-hwsched [O].** KGSL runs `gen7_6_0` hardware-scheduled
    through the GMU. Mainline drives the a740 without hwsched. Whether `gmu_gen70200.bin` behaves
    on 740v3 in mainline's mode, with the 740v3 chipid, is untested. It is a serious bring-up
    risk, not a proven blocker.
- **Power/thermal compared with KGSL:**
  - Mainline has GMU DCVS over HFI, devfreq with simple_ondemand, GMU bandwidth voting (6.14),
    ACD (6.16), preemption (6.13) and `of_devfreq_cooling_register`.
  - Mainline has **no BCL/limits management for a7xx**, and its sm8550 OPPs stop at 680 MHz.
  - KGSL `gen7_6_0` has DCVS, bus DCVS, ACD, **BCL**, LPAC and preemption.
  - IFPC is off on both.
  - Every GPU safety row (A5, A6, D2; `emergency-shutdown-design.md`) would be re-derived
    [M-static, snap trees and `drivers/gpu/msm`; D].
- **Split devices:** upstream has had `separate_gpu_kms` since v6.17 (a render-only `msm`
  device). A GPU-only `msm` beside the SDE's `msm_drm` **still fails F4/F5**, so Turnip needs a
  patch. A combined device needs the GPU merged into the SDE driver, unifying two GEM
  implementations (+4–8 pw) [D].
- **Community evidence:**
  - A private community report describes a drm/msm 6.14 back-port running on a 4.19 Quest Pro
    (A650), together with a custom WSI [C, private note, paraphrased].
  - A public 5.19 → 4.19 back-port exists for SDM845/A630 (github.com/notfound8852/msm-drm-5.19-backport)
    [C].
  - Both are a6xx, which is long upstream. No a7xx or 5.10 back-port is public [C].
- **Time:**
  - compile-clean: 3–6 pw;
  - hardware bring-up (DT adapter, GDSC, GMU chipid, zap, SMMU): 3–8+ pw;
  - combined device and plane split: +6–12 pw;
  - **12–26 pw** to panels, with a serious GMU bring-up risk (hwsched versus non-hwsched).
- **Chair classes:** C1, C4, C10, C11 (DT adapter or overlay), plus a new GPU driver.
- **Purity: high** (with the combined device).

### (b2) A newer downstream kernel for anorak

- **No anorak BSP newer than 5.10 is public** [C]. The Samsung Galaxy XR (XR2+ Gen 2) still
  ships 5.10 [C, github.com/4uva4ek/KernelSU-GXR].
- CodeLinaro's msm-5.15 is the kalama (SM8550) line [C]. The anorak fabric is closer to waipio
  (F10).
- (b2) therefore means transplanting the SoC (clk, pinctrl, icc, DT, msm-id 549) plus
  forward-porting:
  - SDE 9.3 and its features;
  - KGSL `gen7_6_0`;
  - Meta's 49.8k lines (`drivers/staging/oculus`: SyncBoss 7.5k, MCU flasher 6.9k, STP 4.6k,
    CYPD/PD, fan tach, BLU, …);
  - per-target camera, audio and video [M-static LOC; D].
- **Payoff: none for this question.** It is still KGSL plus SDE, and it still needs (a) or the
  contract device.
- **Effort:** 12–20 pw to first light; 25+ pw to parity.
- **Risk: high.** Firmware and hypervisor (Gunyah) ABI coupling is untested. **Dominated.**

### (c) Mainline display and GPU (upstream DPU), the Frame-like end state

- **Missing upstream** [M-static linux-next 20261014 `d419d6822`; C for mailing-list status]:
  - anorak SoC support (ids, gcc, gpucc, dispcc0, tcsr, pinctrl, icc, rpmhpd, PAS, pmic-glink);
  - the **DPU 9.3 catalog**;
  - **quad-pipe** (4 LM → 2 INTF, 2 DSC per INTF). Jun Nie's enabling patch is **not merged**:
    v20 was applied, then dropped in May 2026 after an SDM845 4K regression; v21 has been
    pending since 2026-07-27;
  - C-PHY + DSC 1.2 Novatek panel drivers for **three panel vendors** (Sharp, JDI, BOE), plus the
    MP3314 BLU;
  - the A740v3 catalog entry;
  - Meta's devices re-hosted (SyncBoss, fan, CYPD).
- **Quad-pipe is mandatory, not optional [D].** Sharp timing at 90 Hz is about 1.01 Gpix/s per
  DSI, about 505 Mpix/s per LM with 4 LMs, against a 550 MHz MDP clock (`eureka-panel-sharp.dtsi`,
  `anorak-sde.dtsi` L399).
- **Prior art is weak:** Lynx R1 (XR2 Gen 1) on 6.13 still cannot light its dual-DSC panels [C].
- **Effort:** 20–35 pw to first light and GPU; 50+ pw to headset parity. **Risk: very high.**
- **Payoff: maximal.** One upstream `msm` device, exactly as on the Frame; Valve's userspace and
  gamescope unchanged; the community and Valve maintain the GPU and display drivers.

### (e) A uAPI translation shim — two forms

**(e-user) LD_PRELOAD or ioctl interception in userspace: rejected [D].**
- It cannot give syncobj fds or a real `drmGetDevice` identity (F7).
- It would have to be injected into Valve's processes and the FEX/Android guests.
- That is fragile, and not pure.

**(e′) The recommended form: a Frame-compatible `msm` device built from Meta's two modules.**
- **In Meta's `msm_drm.ko`** (rebuilt from GPL source):
  - the driver name becomes `msm` and the version 1.12 (pre-VM_BIND, so Turnip takes its legacy
    path);
  - Meta's private ioctls 0x0D+ move out of the upstream range (F8);
  - `DRIVER_SYNCOBJ | DRIVER_SYNCOBJ_TIMELINE` are advertised (core 5.10 already has timeline
    syncobj [M-static, `drm_syncobj.c`]);
  - the GPU ioctls Turnip uses are implemented by calling into KGSL;
  - one wide plane is split into ≤1032-px pipes inside the SDE (F9).
- **In Meta's `msm_kgsl.ko`** (rebuilt): a small in-kernel API for per-file contexts, dma-buf
  import, command submission and fences. KGSL exports only 6 symbols today [M-static].

**uAPI surface** [M-static, `tu_knl_drm_msm.cc`, `msm_common.h`]:
- `GET_PARAM`: chip id, GMEM, VA range, UBWC, highest bank bit, timestamp, faults, priorities
  (values from `KGSL_PROP_*`).
- `SET_PARAM`: COMM/CMDLINE as no-ops.
- `GEM_NEW`/`GEM_INFO`: SDE GEM objects (scanout-capable) imported into the client's KGSL
  pagetable, as KGSL already does for dma-bufs (`GPUOBJ_IMPORT`).
- `GEM_SUBMIT`: maps to KGSL `GPU_COMMAND`, with fence-fd in and syncobj in/out from KGSL
  timestamp fences.
- `SUBMITQUEUE_NEW`/`CLOSE`: map to `DRAWCTXT_CREATE`/`DESTROY` with priority.
- `WAIT_FENCE`: maps to `WAITTIMESTAMP`.
- PRIME, mmap and syncobj come from the DRM core.
- VM_BIND: Turnip falls back without it, **but sparse needs it** (`has_sparse = has_vm_bind`).
  It is planned onto KGSL `GPUMEM_BIND_RANGES` before G3 sign-off (M4 below).
- **Size proxy [D]:** upstream Turnip implements this whole mapping **in userspace** in 2,074
  lines (`tu_knl_kgsl.cc`), including sparse, so the semantic mapping is tractable.
  - The kernel side is **not** a thin wrapper (M5): estimate 6–10k lines, including the KGSL
    refactor.

**Review findings that shape (e′)** (rev 1). Each is a planned work item, not an open question.

- **M1 — the fence path (+1–2 pw).**
  - The problem: advertising `DRIVER_SYNCOBJ_TIMELINE` on 5.10 would make gamescope show
    unfinished frames.
  - gamescope's OpenVR backend always offers explicit sync and then waits with
    `DRM_IOCTL_SYNCOBJ_EVENTFD` (gamescope `Timeline.cpp` L151 [M-static]).
  - That ioctl is **absent from Meta's 5.10 core drm**, which is built in (`CONFIG_DRM=y`; not in
    `include/uapi/drm/drm.h` [M-static]).
  - gamescope then falls back to polling the dma-buf, and KGSL never attaches fences to dma-bufs.
  - Two fixes:
    - **(i)** back-port the syncobj eventfd ioctl into vmlinux. This is a Chair-class vmlinux
      change on our own kernel (K1 lineage) and needs a KMI/CRC check of `struct drm_syncobj`
      users.
    - **(ii)** leave the timeline flag off and implement `dma_resv` implicit fencing in the shim.
      Turnip then emulates timelines, Mesa WSI uses implicit sync, and the SDE waits on the
      exclusive fence.
  - **Recommend (i)**, because it gives gamescope the same explicit-sync path it runs on the
    Frame. The shim attaches `dma_resv` fences to written BOs **in either case**, since the SDE's
    scanout wait and any implicit consumer need them.
- **M2 — register protection (S0 item).**
  - KGSL's gen7 table write-protects 0x8d0–0xa40 (`adreno-gpulist.h` L2008 [M-static]). Mainline
    leaves the perf-counter selects writable.
  - Turnip-on-msm selects perf counters, and Valve's build contains the autotune and preemption
    paths. Those writes would fault and hang the GPU.
  - Fix at S0: align KGSL's protect table with mainline's for the counter selects, or keep those
    paths off. Share counters with KGSL's own reservations.
- **M3 — GPU address collisions (S0 item).**
  - KGSL has one pagetable per process, but Turnip opens an fd per `VkDevice` and allocates over
    the whole reported VA range.
  - Fix: give each fd its own VA window within the process pagetable, or use kernel-assigned
    addresses and do not report a VA range.
- **M4 — sparse and D3D12 (3–6 pw, before G3 sign-off).**
  - Without VM_BIND there is no sparse. vkd3d-proton then cannot reach D3D12 feature level 12_0
    [C], so titles that run on the Frame would fail.
  - Plan: map VM_BIND (MAP, UNMAP, MAP_NULL) onto KGSL bind-ranges. Advertise the VM_BIND
    version only once that mapping passes its CTS subset.
- **M5 — KGSL needs a real refactor, not six new exports.**
  - Its command and sync paths take user pointers and sync_file fds.
  - `gen7_6_0` runs hardware-scheduled through the GMU, so submission goes through the hwsched
    path.
  - Buffer frees must be deferred until the GPU retires.
  - GPU faults must map to device-lost.
  - Prior art is thin: the old kgsl-drm GEM shim was reportedly "usually in disrepair" [C].

**Honest polish and stability judgement [D]:**
- (+) Everything that touches the hardware stays Meta's production code: GMU, hwsched, DCVS, BCL,
  ACD, preemption, hang recovery, firmware and the thermal maps (F11).
- (+) The kernel underneath is frozen with Meta's v2.7, so it does not move.
- (+) Valve's 32-bit and Android guests use the msm uAPI exactly as on the Frame.
- (−) The translation layer is **novel**. Nobody else maintains it, Mesa's CI never runs it, and
  fault/hang reporting approximates upstream semantics.
- (−) The KGSL refactor (M5) touches Meta's submission path. That path is safety-relevant code,
  so it is reviewed as such.
- (−) The shim must follow Valve's Turnip whenever Turnip starts **requiring** newer msm uAPI
  (per-build check).
- (−) Two Meta modules become ours to maintain, and their source is published (GPL).
- **Mitigation:** an objective conformance gate. A Vulkan CTS subset on Valve's Turnip over (e′)
  must match the upstream Turnip-KGSL baseline on the same unit.
- **Overall:** stability medium-high once the gate passes; polish high to the user (nothing
  visible); kernel-side polish medium.
- **Time (rev 1):**
  - S0 design, including M2 and M3: 2–3 pw;
  - KGSL refactor and shim, offscreen with Valve's Turnip (M5): 9–15 pw;
  - fence path (M1): 1–2 pw;
  - panels (plane split): 3–5 pw;
  - gamescope/vrcompositor: 3–7 pw;
  - **18–32 pw to Valve's vrcompositor on the panels**;
  - **+3–6 pw for VM_BIND/sparse (M4): about 21–38 pw to Frame parity**, with **no** permanent
    fork.
- **Chair classes:**
  - C4 and C5;
  - C10 widened to "rebuilt Meta `msm_drm.ko` and `msm_kgsl.ko` presenting the `msm` contract";
  - a **vmlinux class** for the syncobj-eventfd back-port if M1 (i) is chosen.
  - No DT change: KGSL keeps its node and cooling maps.

**Plane split [review-verified, D].** It is feasible inside the SDE by driving hidden planes, one
per mixer, with matching UBWC settings.

**Not applicable:** virtio native context (a Turnip backend for VMs) does not fit this case
(review-verified).

**Later relief [O]:** SteamVR driver-direct-mode could relax the same-device requirement for
vrcompositor.

### Comparison

| | (a) KGSL + Turnip fork | (b) drm/msm back-port | (b2) newer downstream | (c) mainline | **(e′) `msm` contract on KGSL** |
|---|---|---|---|---|---|
| SteamOS side changed | Mesa ×4, gamescope, maybe wlroots | nothing (combined device) or Turnip | as (a) or (e′) | **nothing** | **nothing** |
| Stability across Valve updates | poor (fork rebases) | good; forked core helpers on 5.10 | as (a)/(e′) | best | good; uAPI watch per build |
| Performance and power | Meta's (best) | re-derived; no BCL | Meta's | upstream (Frame-grade on SM8650) | **Meta's (best)** |
| Safety (thermal/DCVS) | unchanged design | re-derive A5/A6/D2 | unchanged | re-derive everything | **unchanged design** |
| First GPU pixels | 2–4 pw | 6–14 pw | 12–20 pw | 20–35 pw | 2–4 pw (G1 tool); 11–18 pw with Valve's Turnip |
| To gamescope/vrcompositor | 11–22 pw, then a fork forever | 12–26 pw + risk | 25+ pw | 50+ pw | **18–32 pw** (+3–6 pw sparse → 21–38 pw parity) |
| Main risk | maintenance, Valve-private Mesa patches | hwsched vs non-hwsched GMU on 740v3 [O]; implicit sync | SoC transplant | upstream quad-pipe, SoC | translation fidelity; KGSL refactor (M5) |
| Quest 2/Pro carry-over (A650, 4.19, KGSL `=y`, ION) | Turnip-KGSL on A650 shown [C] | **best**: a6xx long upstream; community 4.19 precedent [C] | none | SM8250 mainline exists; DSC panels blocked [C] | contract reused; KGSL glue re-done (~50 %) [D]; or (b) behind the same contract |
| Long-term value | none beyond Quest | feeds (c) (740v3 entry) | none | end state | contract outlives back-ends |

---

## 3. Recommendation

**ONE route: (e′), the Frame-compatible `msm` device, built from Meta's own modules on Meta's
5.10 kernel, with Valve's SteamOS image unchanged.**

Why, against the PM's criteria [D]:
1. **Purity.** It is the only near-term route that changes nothing on the SteamOS side. All
   Quest-specific work sits in "the Meta parts that hook into it": `msm_drm.ko`, `msm_kgsl.ko`
   and our HMD driver.
2. **Safety first.**
   - Meta's GPU power management, BCL and DT thermal maps stay as they are.
   - `fs-thermald`'s GPU caps (KGSL `max_pwrlevel`, C5) and the emergency-shutdown design are
     unchanged.
   - (b) and (c) both re-derive GPU safety, and (b) loses BCL.
3. **Stability across Valve updates.**
   - No Mesa or gamescope fork.
   - Each Valve build is checked against a written uAPI list, the same way each build already
     gets a writer closure.
4. **Feasibility and time to users.**
   - 18–32 pw to the VR compositor. That is somewhat slower than (a)'s 11–22 pw, but without
     (a)'s permanent fork of Valve's Mesa and gamescope.
   - Comparable in time to (b), with less risk: (b) carries the hwsched/non-hwsched GMU question
     on 740v3, loses BCL, and re-derives GPU safety.
5. **Long-term.** The contract is also what (b) and (c) present. A later back-end swap
   (back-port or mainline) changes no SteamOS byte, so no work above the kernel is thrown away.

### Staged path with decision checkpoints

| stage | what | pw | checkpoint (go / switch) |
|---|---|---|---|
| **S0** offline | **Contract spec:** the exact msm uAPI used by Valve's Turnip (string presence in Valve's four builds plus upstream Mesa 26.3 source). Also: the KGSL mapping table, the ioctl renumbering, the **KGSL refactor design (M5)**, the **protect-table and counter plan (M2)**, the **per-fd VA windows (M3)**, the **M1 fence choice**, the wide-plane split design (hidden planes, UBWC), and the module-rebuild and KMI/CRC plan | 2–3 | **CP-0:** no row is "impossible on KGSL", and the M1–M3 designs are reviewed. Otherwise start the (b) spike behind the same contract |
| **G1** device (parallel with S0) | As already planned: the upstream Turnip-KGSL **test tool** on the stock kernel, offscreen, with an analytic image and the GPU at its lowest levels. It validates firmware, zap and KGSL power under our initramfs and records the power baseline | 2–4 | **CP-1:** KGSL and firmware sound on both units; baseline recorded |
| **G1c** device | Rebuilt modules (KGSL refactor plus shim): **Valve's unmodified Turnip** runs `vulkaninfo` (Adreno 740v3), the analytic image and a CTS subset that includes perf-counter and multi-`VkDevice` cases | 9–15 | **CP-2:** CTS parity with the G1 baseline; no GPU faults from protected registers. Unfixable semantic gaps → switch the back-end to (b), keeping the contract |
| **G2** device | A GPU frame on the panels through Valve's display WSI: one full-width plane split in the SDE, the M1 fence path, no kernel WARNs | 4–7 (incl. M1) | **CP-3:** both eyes correct, no tearing or partial frames, `dmesg` clean |
| **G3** device | vrcompositor and gamescope (OpenVR backend) from Valve's image, with the Quest-side drop-ins (§3.1), under full `fs-thermald` | 3–7 | Steam UI usable under a thermal soak (**18–32 pw** cumulative from S0) |
| **G3s** device | VM_BIND/sparse on KGSL bind-ranges (M4); advertise VM_BIND only after its CTS subset passes | 3–6 | **CP-G3 sign-off:** a vkd3d-proton D3D12 FL 12_0 title runs (**21–38 pw** cumulative = Frame parity) |
| **ongoing** | **Per Valve build:** diff the msm uAPI usage and the Frame-specific scripts before adopting the build. **Each quarter:** mainline readiness (quad-pipe merged, anorak or any SXR2230P support, the 740v3 entry) | — | **CP-4/CP-5:** reopen (c) only when quad-pipe is merged **and** an anorak SoC base exists |

### 3.1 Quest-side drop-ins (our layer; Valve's files untouched)

| Valve file | Frame specific | Quest-side override |
|---|---|---|
| `/usr/bin/displays_turn_off_drm_master` | DSI-1, one 4320×2160 plane | our drop-in, or a unit override pointing at ours: Quest connector, 4-pipe-aware mode |
| `/usr/share/deckard/set_kernel_thread_priorities.sh` | drm/msm thread names (`msm`, `ring0..3`, `dsi_drm_work_*`) | our drop-in mapping to the SDE/KGSL thread names, so the RT priorities are not silently lost |

Other Frame-specific scripts are listed per Valve build at S0 (the same pass as the writer
closure).

**Quest 2/Pro:** the contract is per-device; the back-end is chosen per device.
- On A650/4.19, (b) may beat a KGSL-glue port, because a6xx is mature upstream and has community
  precedent [C].
- Decide that at the Quest 2 GPU stage, not now.

---

## 4. What the PM must decide (asked in chat)

1. **PD-1 (revised):**
   - Options:
     - (e′) the `msm` contract on KGSL, with (b) as the fallback back-end and (c) as the horizon;
     - keep (a);
     - go straight to (b).
   - **Recommend (e′).**
2. **PD-12 (widened):**
   - The change: rebuild **both** Meta `msm_drm.ko` and `msm_kgsl.ko` from Meta's GPL source,
     covering the rename, the uAPI, syncobj and the wide-plane split.
   - Consequences: a Chair class (C10 widened), and published source.
   - **Recommend yes.**
3. **G1 stays as planned** (upstream Turnip-KGSL test tool, never shipped). **Recommend yes.**
4. **PD-2:** the (b) spike only at CP-0 or CP-2 failure. **Recommend yes.** This matches the PM's
   J-149 "only if (a) runs into trouble", now read against (e′).
5. **M1 fence path:**
   - Options:
     - (i) back-port the syncobj eventfd ioctl into our vmlinux (Chair-class vmlinux change);
     - (ii) no timeline flag, with implicit `dma_resv` fencing only.
   - **Recommend (i)**, with the shim's `dma_resv` fences in place either way.
6. **The effort is now 18–32 pw to the VR compositor and about 21–38 pw to Frame parity.** The PM
   accepts this or asks for (a) as a stop-gap. **Recommend accepting it.** A stop-gap (a) costs
   11–22 pw that are thrown away.

## 5. Open questions [O]

- Valve-private uAPI use in Turnip `8aa73b4b`. Resolve by string presence at S0.
- How vrcompositor obtains its DRM fd: its DRM-lease path, a Wayland lease, or opening the node
  itself. Resolve with a runtime trace at G3.
- Whether gamescope or wlroots need the dma-buf sync-file import/export ioctls, which are also
  absent in 5.10.
- SteamVR driver-direct-mode as later relief for the same-device requirement.
- KGSL governor autonomy without Android (stage3-4-plan §9).
- Sparse binding (VM_BIND via `GPUMEM_BIND_RANGES`) and when Valve's titles need it.
- For (b): 740v3 GMU chipid and non-hwsched bring-up; the SMMU stall hooks.

## Sources

- **Repo:**
  - `docs/research/stage3-4-plan.md` rev 1;
  - `docs/JOURNAL.md` J-148–J-150;
  - `emergency-shutdown-design.md` (GPU caps, A5/A6/D2);
  - `armadavr.md`, `oculus-linux-kernel-yusuf.md`, `community-quest-repos-2.md`;
  - `<private note, withheld>` (paraphrased only; not for public export).
- **Valve rootfs** `~/sfroot-full` (0.3.0; strings, dynamic imports and pacman metadata only):
  - `usr/lib/steamos/gamescope-session`;
  - `usr/bin/displays_turn_off_drm_master`;
  - `opt/steamvr/bin/linuxarm64/vrcompositor`;
  - `libvulkan_freedreno.so`;
  - versions: gamescope 3.16.28-1, deckard-mesa 26.3.0_devel+git8aa73b4b-1, libdrm 2.4.134,
    vulkan-icd-loader 1.4.309.0.
- **Frame kernel config** `firmware/SteamOS/extracted/config-6.18.0-gfbdbca41fd45`:
  `DRM_MSM=y`, `DRM_GPUVM`, `DRM_EXEC`, `DEVFREQ_THERMAL`, `SM_GPUCC_8650` [M-static].
- **Meta v2.7 kernel source** `~/work/kgate27/src`:
  - `techpack/display/msm/{msm_drv.c,sde/sde_plane.c,sde/sde_crtc.c}`;
  - `include/uapi/drm/msm_drm.h`;
  - `drivers/gpu/msm/*`;
  - `arch/arm64/boot/dts/vendor/qcom/anorak*.dtsi`, `oculus/eureka/*`;
  - `drivers/staging/oculus`;
  - `stock.config`, `modules.list.anorak`.
- **Public source (clones in WSL `~/work/gpu-research`):**
  - Linux v6.6–v7.2 and linux-next 20261014 (`d419d6822`): `drivers/gpu/drm/msm`,
    `arch/arm64/boot/dts/qcom/sm8550.dtsi` (A740 `0x43050a01`, 8 GPU cooling maps, ACD levels);
  - Mesa main `5419740b` and 26.2 `f25a43cb`;
  - gamescope 3.16.28 `fa0b4d33`;
  - mainline msm commits `1f8c29e8006` (A740, v6.7), `e7ae83da4a2` (a7xx preemption, v6.13),
    `855e9d0fbb0` (GMU BW, v6.14), `b733fe7bff8` (ACD, v6.16), `111fdd2198e` and `feb8ef4636a`
    (gpuvm and VM_BIND, v6.17), `217ed15bd39` (`separate_gpu_kms`, v6.17).
- **Web [C]:**
  - Jun Nie quad-pipe series: lkml.iu.edu 2603.1/08641, 2605.2/09128, 2607.3/04589;
  - A7xx upstreaming: lkml.iu.edu 2309.3/01419;
  - github.com/notfound8852/msm-drm-5.19-backport;
  - github.com/MaSieS4Fun/SteamOS-ARM-SM8550 (Valve's SteamOS ARM with Turnip and gamescope on
    SM8550/A740 handhelds; gamescope patched only for backlight, rotation and QAM);
  - github.com/4uva4ek/KernelSU-GXR;
  - pkgs.nura.eco (linux-lynx-r1).
- **Method note:**
  - No disassembly or decompilation.
  - DT facts come from Meta's GPL DTS source and upstream `.dtsi` files.
  - The earlier `dtc` conversion of Valve's DTBs is disclosed in the header; nothing from it is
    cited.

## 6. Revision 1: adversarial review (GO-with-fixes) and changes

**Verified by the review:**
- gamescope runs on the OpenVR backend; Plasma runs nested.
- vrcompositor and `modetest` are the only KMS masters.
- Turnip's driver-name (`msm`) and version (≥ 1.6) checks.
- The display WSI commits one primary plane.
- 0x43050b00 is absent from linux-next.
- A plane split inside the SDE is feasible with hidden planes and matching UBWC settings.
- Virtio native context is not applicable.

**Changes:**
- The effort is corrected to 18–32 pw to the VR compositor, +3–6 pw for VM_BIND/sparse (about
  21–38 pw to Frame parity), and the checkpoints are restated (§3).
- **M1** (syncobj eventfd absent in 5.10, so gamescope would show unfinished frames): two fixes,
  with (i) recommended; moved from [O] into the plan.
- **M2** (the KGSL protect table blocks the perf-counter selects): an S0 item.
- **M3** (VA collisions between per-`VkDevice` fds): an S0 item.
- **M4** (sparse needs VM_BIND for vkd3d-proton FL 12_0): stage G3s before G3 sign-off.
- **M5** (a real KGSL refactor: user pointers, hwsched, deferred frees, fault → device-lost).
- **Minor:**
  - "byte-for-byte" is now limited to Valve's files, with the Quest-side drop-ins in §3.1;
  - vrcompositor's libdrm use and DRM-lease path;
  - (b)'s GMU risk restated as hwsched versus non-hwsched;
  - driver-direct-mode noted as [O];
  - the `dtc` disclosure.
