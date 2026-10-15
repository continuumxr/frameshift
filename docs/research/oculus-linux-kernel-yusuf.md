# YusufOzmen01/oculus-linux-kernel: what the recent changes say about the dark panel

*Edited for publication: names and links removed or paraphrased.*

Question (2026-10-10): this kernel fork was recently updated. Community
advice suggests that a modified Mesa driver and a custom compositor are
needed, that the panels use DSC with a quad-view layout, that the stock OS's
CRTC parameters should be reused, and that garbage output with many coloured
lines indicates a DSC mistake. Does the
repo explain why our trial (iii) commit left the Quest 3 panels dark, and
what should change?

This is an offline, read-only investigation. No device was touched and
nothing was committed. The repo was read through the GitHub REST API and
raw.githubusercontent.com; no clone was made. Untrusted copies of five
source files are in the session scratchpad
(`scratchpad/dl/yz-oculus-linux-kernel/`). Nothing from them was built or
run.

Tags: [M-static] read in the repo, cited by commit/path:line · [C] a
claim (repo author's commit text, or the community advice above) · [D] our inference · [O] open.

Related: `display-handoff-dark.md` (v66 handoff analysis, R0–R4),
`display-clues-kexec-quest1.md` (quest-kexec "second bring-up"),
`quest3-panel-online.md`, FS-A-010 (private review record) §5–§6.

---

## 0. Answers in brief

1. **Device and kernel:** the author's work is on **Quest Pro (seacliff),
   kona, Linux 4.19.325**, branch `oculus-quest-pro-kernel-master` only.
   The Quest 3 branch (5.10.246) is an untouched mirror of Meta's tree
   [M-static]. Seven author commits, 2026-09-26 → 2026-10-10 (§1).
2. **Panel lighting:** the repo **does not explain** the "second bring-up".
   No commit touches panel power-on, DCS on-commands, DSC, topology, CRTC,
   or plane setup. The only new display item is a **Quest Pro backlight
   timing fix**: after kexec the driver could skip re-sending the BLU
   stride timing because it believed the level was unchanged. The symptom
   he describes is stale timing and ghosting, **not** a dark panel (§2.2).
   That skip **does not exist** in the Quest 3 Tokki-A path (§2.3).
3. **Compositor and Mesa:** the kernel side of his SteamOS work is DRM
   **timeline syncobj** support, **KGSL timeline fd export**, KGSL↔DRM
   sync bridges for **Turnip on KGSL**, and an experimental GPU
   "display slot" reservation for SteamVR's `vrcompositor`. That slot is
   off by default because it ghosted frames. No Mesa or compositor code is
   in this repo. What exactly "gets in the way" is **not stated** (§3).
4. **Stock CRTC parameters:** the SDE driver exposes the topology per mode
   (`topology_name`, the `mode_properties` blob) and per-CRTC mixer/plane
   layout (debugfs `crtc<id>/status`). There is a list of read-only
   captures in §4.1. **Nothing indicates that our split commit caused a
   DSC/topology mismatch.** We reused the kernel's own mode, so the DSC and
   topology come from the DT, not from userspace. Per the community advice, a DSC
   error shows garbage, which needs a lit backlight. Our failure was "no
   light at all" (§4.2).
5. **Forbidden items:** the repo's BLU timing change is a kernel patch that
   makes the stock driver write BLU registers by DCS. It is **not usable
   by us without a custom kernel**, and copying its effect from userspace
   would mean BLU/DCS writes. Both go to the Chair, not recommended (§5).

---

## 1. Device, branch and recent commits [M-static]

**Repo:** `github.com/YusufOzmen01/oculus-linux-kernel`, a fork of
`facebookincubator/oculus-linux-kernel`, created 2026-09-26, last push
2026-10-10T08:06Z. There are no issues. There are no docs: no `.md`,
`.txt` or `.rst` file is added or changed in any author commit
(compare `42dc87a978...9b68500d48`: 7 commits, 132 files, none of them
docs). The root `README.meta.md` is Meta's build note ("Quest 2/hollywood,
Quest Pro/seacliff").

**Branches:** `oculus-quest-pro-kernel-master` (default),
`oculus-quest2-kernel-master`, `oculus-quest3-kernel-master`,
`oculus-quest3s-kernel-master`.
- The Quest 2, 3 and 3S heads are AOSPBuildBot commits from 2026-09-25.
  Quest 3: `bcbad93099` "build: 5243367.4880.520", `Makefile` 5.10.246.
  There are **no author commits** on them.
- The Quest Pro branch is `Makefile` 4.19.325, on top of Meta's
  `42dc87a978` (5150387.3580.340, 2026-09-25).

**Author commits (Quest Pro branch, oldest first):**

| commit | date (UTC) | subject | display-relevant content |
|---|---|---|---|
| `db0d5b2b82` | 2026-09-26 | qkx: kexec target patches (rebased from fa2e480a85) | dispcc-kona to `fs_initcall`; gdsc, sde_power_handle, dispcc tolerate a missing msm_bus client; `dsi_ctrl.c` clock-deinit `IS_ERR_OR_NULL` guards; `sde_rsc.c` error log. Probe-survival only. |
| `5d4273bfeb` | 2026-09-26 | qkx: disable stale SPMI IRQs, SMB5 skip initial-status handlers … | none (charger/PMIC) |
| `3f87f8ba54` | 2026-09-26 | qkx: nothing parked by default; SMB5 … | none |
| `a8c21437c3` | 2026-09-30 | booting android | GPU/GMU kexec fixes, `qkx_stall` diagnostics, gdsc tracing wrapper. No display. |
| `095de251d8` | 2026-09-30 | Export qkx diagnostic hooks for modules | none |
| `b0922e4bde` | 2026-10-03 | Fix Quest Pro kexec Bluetooth, Venus and splash memory handoff | `sde_kms.c` +12: do not free a splash carveout whose pages are not `pfn_valid` |
| `9b68500d48` | **2026-10-10** | **QKX: KGSL/Turnip sync bridges, display slot, Venus V4L2 fixes** | `dsi_panel.c` +42/−2, `dsi_panel.h` +4 (BLU timing); `msm_drv.c` adds `DRIVER_SYNCOBJ`/`DRIVER_SYNCOBJ_TIMELINE`; sde_fence/rotator 64-bit seqno; `sde_kms.c` double-put fix; KGSL timeline export + display slot; DRM timeline syncobj backport |

- Commits 1–6 match the patch already summarised in
  `display-clues-kexec-quest1.md` §1.3. **`9b68500d48` is the new one.**
- Its message says this is "Work running in SteamOS kernel #18 plus later
  source-only changes". So he runs **SteamOS on a kexec'd Quest Pro** with
  this kernel [C].
- The commit's own summary of the display part is just "SDE/DSI: Quest Pro
  display bring-up changes".

---

## 2. The panel lighting problem

### 2.1 What the repo does not contain [M-static]

I searched every added or removed line of all seven commits for
`dsc|topolog|quad|mixer|crtc|backlight|bl_|dcs|splash|panel_on`.
- **No DSC or topology change.** No `sde_rm`, `sde_encoder`, DSC, or
  `dsi_display` timing change.
- **No CRTC or plane change.** `sde_crtc.c` and `sde_plane.c` are untouched.
- **No panel power, reset, or on-command change.** No `dsi_panel_enable`,
  no `prepare`, no DCS on-set.
- **No continuous-splash logic change** beyond the `pfn_valid` guard on
  freeing splash memory (`b0922e4bde`, `sde_kms.c:752-765`).
- **No note on why the panel lights only on the second bring-up.** The
  repo is silent. That quote is still only in quest-kexec
  (`initramfs/os/qkx-launch-android:68`).
- **No text on quad views, DSC garbage output, or reusing stock CRTC
  parameters.** Those come only from the community advice above [C].

### 2.2 The one new panel item: Quest Pro BLU stride timing after handoff (`9b68500d48`)

**What it changes** [M-static, `techpack/display/msm/dsi/dsi_panel.c` on the
Quest Pro branch head]:
- `dsi_panel_bl_handoff()` (`:1298-1315`) now sets `bl->bl_level = U32_MAX`
  and `bl->qkx_force_timing = true` after the stock
  `dsi_panel_get_brightness()`.
  - The author's comment: get_brightness "reports a default, not the level
    the panel is actually at". After kexec, the panel still runs the
    previous session's settings. The stride write "is skipped whenever the
    requested level matches that invented default". So the panel "keeps
    stale backlight/flash stride timing".
- `dsi_panel_handle_dfps_pwm_fifo_local_dimming()` (`:1033-1042`) used to
  return early when `bl_level != panel->bl_config.bl_level`. It now
  proceeds once while `qkx_force_timing` is set. This function writes the
  Quest Pro PWM register `0xB9` and the FIFO register `0xEC` (`:1022-1023`).
- A new module parameter, `qkx_bl_settle_min_us` (`:1145-1170`, default 0,
  0644), floors the LC settling time before the backlight flash. The
  author's reason: the curve is indexed by `pcb1_therm`, which reads high
  under SteamOS load, so "the backlight can flash before the liquid
  crystal settles (faint trailing copies)".

**Reading** [D]:
- The symptoms named are stale stride timing and ghosting. **Neither is
  "no light".** The patch is about a lit panel strobing at the wrong time.
- The comment and the code disagree slightly. The comment says the write is
  skipped when the levels *match*, but the code returns when they *differ*.
  The fix (force one pass) works either way. It shows that the stock
  handoff level is invented. Our `display-handoff-dark.md` §2 reached the
  same conclusion for v66.
- **It confirms one thing we assumed:** after a non-ABL handoff, Meta's
  driver does not know the BLU state, and a stock driver path can leave the
  BLU programming stale.

### 2.3 Does that bug class exist on the Quest 3? [M-static on the Quest 3 branch head, v2.7-era; D for v66]

- The Quest 3 BLU is `DSI_BACKLIGHT_TOKKI_A`, handled by
  `dsi_panel_handle_dfps_pwm_fifo_tokki_a()` (Quest 3 branch
  `dsi_panel.c:802`).
- That function has **no** "level unchanged" early return. It returns early
  only on bad input or `backlight_changes_blocked` (`:823-829`).
- `dsi_panel_set_backlight()` → `dsi_panel_tokki_a_update_backlight()`
  (`:1530-1540`, `:1565-1608`) either calls it directly or kicks the
  temperature work. The temperature work "Unconditionally update[s] the
  backlight timing" (`:1450-1455`).
- `dsi_panel_bl_handoff()` (`:1650-1655`) is the plain stock version, with
  `bl_level` = `bl_max_level` (`:1622`).
- `backlight_changes_blocked = 1` at parse, "will unblock when bootanim is
  done" (`:3918-3919`). This is the **v2.7** gate. `display-handoff-dark.md`
  §3.1 already established it is **absent on v66**.
- **Conclusion [D]:** the Quest Pro skip-on-same-level bug has no
  counterpart in the Quest 3 Tokki-A path. On v66, our modeset already
  reprograms the BLU at enable (`display-handoff-dark.md` §3.3). The new
  commit therefore gives **no new cause** for our dark panels. It also
  gives no reason to change R3. Running twice still means Meta's normal
  full panel off→on.

### 2.4 Why a second bring-up might be needed

The repo is silent [O]. The best available reading is still ours
(`display-handoff-dark.md` §3.3, `display-clues-kexec-quest1.md` §1.1):
- the first commit after a splash-style handoff takes the
  `is_cont_splash_enabled` skip path. It sends no panel reset and no
  sleep-out/display-on.
- the second run starts from a CRTC that lastclose turned off, so it goes
  through the full panel-on path [D].

Nothing in `9b68500d48` contradicts this. The BLU-timing fix is consistent
with it: after a handoff, the first enable runs on inherited panel state.

---

## 3. Compositor and Mesa work [M-static unless tagged]

**What is in the kernel:**
- **DRM timeline syncobj backport.** New files
  `drivers/dma-buf/dma-fence-chain.c` and `dma-fence-unwrap.c`.
  `drm_syncobj.c` +600/−195. New ioctls `SYNCOBJ_TIMELINE_WAIT`, `QUERY`,
  `TRANSFER` and `TIMELINE_SIGNAL` (`drm_ioctl.c`, `uapi/drm/drm.h`), and
  `DRM_CAP_SYNCOBJ_TIMELINE`.
  - `msm_drv.c` now advertises `DRIVER_SYNCOBJ | DRIVER_SYNCOBJ_TIMELINE`
    on the **display** (msm_drm/SDE) device.
  - The `dma_fence` seqno becomes 64-bit, hence the `%llu` and
    `lower_32_bits` edits in `sde_fence.c` and `sde_rotator_sync.c`.
- **KGSL side.** `IOCTL_KGSL_QKX_TIMELINE_EXPORT` (0x5e) returns an fd for a
  KGSL timeline, and `IOCTL_KGSL_QKX_TIMELINE_ID` (0x5f) reads it back
  (`uapi/linux/msm_kgsl.h`, new `drivers/gpu/msm/qkx_timeline_fd.h`).
  The commit message calls these "KGSL<->DRM sync bridges for Turnip on
  KGSL".
- **GPU display slot.** `IOCTL_KGSL_QKX_DISPLAY_SLOT` (0xC2) lives in
  `adreno_dispatch.c:55-220`.
  - The display process names a deadline for its next max-priority
    ("timewarp") pass. Other contexts may start only if their estimated
    run fits before that deadline.
  - Jobs from a process whose comm is `vrcompositor` are favoured.
  - It is **off by default**: `_qkx_slot_enable = 0`, with the comment
    "off: reprojected frames ghosted (2026-10-07)".
  - Why: "Without usable preemption a long job from any context delays the
    display (timewarp) pass past scanout". An earlier commit disabled A6xx
    preemption for the kexec handoff (`a8c21437c3`,
    `adreno_a6xx_preempt.c`).

**What this implies** [D]:
- The "modified mesa driver" is most likely **Turnip (Mesa's Adreno
  Vulkan driver) on the KGSL backend**. It is not mainline msm/freedreno.
- On Qualcomm the GPU (KGSL, `/dev/kgsl-3d0`) and the display (msm_drm,
  `/dev/dri/card0`) are separate drivers. SteamVR's `vrcompositor` presents
  through DRM/KMS ("using libdrm") and expects Vulkan↔DRM fence and
  timeline-syncobj interop. So he had to add timeline syncobj to msm_drm
  and bridge KGSL timelines to it. This is a plausible reading of "gets in
  the way". The repo does not say it.
- **Not in this repo:** the Mesa patches, the custom compositor, how
  SteamVR's direct mode is bypassed or replaced, and any statement that
  this compositor work relates to panel *lighting* [O]. In the commit,
  the compositor work is about timing, ghosting and fences, not about
  first light.
- **Relevance to us:** this is a later-stage problem (stage 4+ GPU/VR
  compositor), separate from stage 3a. Our Quest 3 is 5.10, so whether
  KGSL/msm_drm already have timeline syncobj there must be checked
  separately [O]. Log this for the userspace plan, not for trial (iii-b).

---

## 4. "Stock CRTC parameters": what to capture and what it means for fs-pattern

### 4.1 Read-only captures on Quest 3 in Android

Source for names: the Quest 3 branch head (v2.7-era). v66 names are
probably the same but **not verified** [D]. Nothing here writes.
*[removed for publication]* Each command is listed for the PM to approve. Target device (Quest 3 Unit 1) as in `display-handoff-dark.md` §6.

| # | what | command | why |
|---|---|---|---|
| A7 | cmdline display string | `adb -s QUEST3UNIT1 shell cat /proc/cmdline` | ABL's `msm_drm.dsi_display0=` on a normal boot, compared with stage 1 |

**Properties that need DRM ioctls** (no master needed for GET ioctls)
[M-static, Quest 3 branch `sde/sde_connector.c`]:
- connector `topology_name`: immutable enum (`:3481`). Possible values
  include `sde_quadpipe_dscmerge`, `sde_quadpipe_3dmerge_dsc`,
  `sde_quadpipe_dsc4hsmerge` (`:40-53`).
- connector `mode_properties` blob: per mode `mode_name`, `bit_clk_rate`,
  `topology=` (`:3165-3216`).
- connector `capabilities` blob (`:3315`), `dsc_mode` (enum
  none/dsc_enabled/dsc_disabled, default 0, `:72-76`, `:3432`),
  `topology_control` (bitmask, default 0, `:3485`), `LP` (default 0 = ON,
  `:3489`, `:3546`).
- plane `capabilities` blob, including `max_linewidth`
  (`sde_plane.c:4016`).

We have **no read-only tool** on Android that dumps these. Adding a
"probe" mode to fs-pattern (GETPROPERTY/GETPROPBLOB only) and running it
in Android would be new code on the device. That is a PM/Chair decision.
Doing it offline from DT (`qcom,mdss-dsi-topology`, `qcom,compression-mode`
in the v66 DTB) is free and should come first.

### 4.2 Could our split-plane commit have caused a DSC/topology mismatch that leaves the panel dark?

**Evidence against** [D]:
- **DSC and topology are kernel-side.** The SDE RM derives the topology
  from the DT timing node of the matched mode. A plain atomic commit sets
  only `MODE_ID`, `ACTIVE`, `CRTC_ID` and plane geometry. fs-pattern sends
  no `topology_control` and no `dsc_mode`, so both stay at their defaults
  of 0.
- **We reused the kernel's current mode.** GETCRTC on an active CRTC
  returned 4128×2208@90, so the mode matched a DT mode with its own
  topology and DSC configuration. An unmatched mode would have failed
  atomic check.
- **The layout errors were rejected, not accepted.** The single
  full-width plane got `−7` (E2BIG) with modeset (FS-A-010 §2, attempt 2).
  That fits a 4128-px source exceeding the SSPP `max_linewidth`
  (`sde_plane.c:2484-2556`) [D]. The split (2 × 2064) passed atomic check
  and committed rc=0. SDE validates layout against mixers at check time.
- **Per the community advice**, a DSC mistake gives garbage, colourful
  lines [C]. That is visible light, so it needs a lit backlight. Trial
  (iii) had **no light at all**. That points to panel or BLU state (H1/H2
  in `display-handoff-dark.md` §0), not DSC.

**Residual uncertainty** [O]:
- The splash state had **4 planes** on CRTC 155 (`display-handoff-dark.md`
  §2); we staged 2. Android's composer may use 2 eye planes (QK logs
  "eye planes 57/79") or 4 [O].
- If Android uses 4 planes of 1032 px, one per LM, a 4-plane layout
  would be the most faithful copy of "stock CRTC parameters". It would
  not be expected to change whether the panel emits light [D].
- Why plane-only TEST_ONLY attempts returned −22 is still open.

**Suggested fs-pattern changes** (offline, no new device action) [D]:
1. **Log, don't guess.** Before the commit, record the connector's
   `topology_name` and the mode's `topology=` from `mode_properties`, plus
   each plane's `max_linewidth`. These are read-only GET ioctls on our own
   fd and add no write.
2. **Optional "stock layout" attempt.** If Android is shown to use N
   planes of width W/N, add that layout to the TEST_ONLY plan ahead of the
   2-plane split. Keep `MODE_ID` = the CRTC's current mode. Never set
   `topology_control` or `dsc_mode`.
3. **No change to the run-twice plan (R3).** Nothing here argues against
   it, and quest-kexec remains the only prior art for it.
4. If run 2 shows **garbage**, treat it per the community advice as a
   DSC/topology mismatch. Compare the logged topology with the stock
   layout before trying anything else.

---

## 5. Forbidden-list check and Chair items

- **The repo itself:** its BLU change (`9b68500d48`) makes the **stock
  kernel driver** write the Quest Pro BLU stride/FIFO registers (`0xB9`,
  `0xEC`) by DCS once after handoff. Its settle floor is a writable module
  parameter (0644).
  - For us, any equivalent would be either a **custom kernel** (not our
    stage 3a path) or **userspace BLU/DCS writes**. Both are on the
    forbidden list. **Chair decision; not recommended.**
- **The Quest 3 branch exposes, but we must not use:**
  - debugfs `dcs_cmd_tx`, `dcs_cmd_tx_unicast`, `tx_cmd`
    (`sde_connector.c:2755-2784`): raw DCS;
  - `temperature_response_time_curve`;
  - `settling_time_override_us` (`sde_crtc.c:7872`).
  All of these are writes, so they are forbidden or need a Chair
  decision.
- **GPU display slot sysfs** (`qkx_slot*` dispatcher attributes) exists
  only in his Quest Pro kernel. It is not relevant to stage 3a.
- **Not found anywhere in the repo:** `blu_default_duty`, overlap or
  `fifo_trim` writes from userspace, `backlight_changes_blocked`
  manipulation, BLU bootload/reset, or flashing.

---

## 6. Where the repo is silent [O]

- Why the panel lights only on the second bring-up.
- Anything on DSC, quad-pipe topology, quad views, or how to copy the
  stock CRTC parameters. Those come only from the community advice [C].
- Quest 3 anything: no author commit on the Quest 3 branch.
- The Mesa/Turnip patches and the custom compositor (not in this repo).
- What exactly in SteamVR's libdrm path "gets in the way".
- Any dmesg, photos or measurements.

## Source notes

- API reads: `/repos/…`, `/branches`, `/commits?sha=<branch>`,
  `/commits/<sha>` (full patches) for the seven commits, and
  `/compare/42dc87a978...9b68500d48`.
- Raw files read (scratchpad copies): Quest Pro `dsi_panel.c` (head);
  Quest 3 `dsi_panel.c`, `sde_connector.c`, `sde_crtc.c`, `sde_plane.c`,
  `sde_rm.c` (branch head `bcbad93099`). Line numbers above refer to these
  heads.
- The Quest 3 branch head is newer than our v66 source (v2.7-era,
  5243367.4880). Facts specific to v66 are taken from
  `display-handoff-dark.md`.
