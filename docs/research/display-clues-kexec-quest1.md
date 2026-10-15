# Display bring-up clues from quest-kexec (Quest Pro) and Quest1-SteamOS (Quest 1)

Question (2026-10-10): do these two community projects hold any evidence on
how a Meta panel gets lit after a non-normal boot handoff? And does that
evidence support, refine or contradict the trial (iii-b) "two runs in one
boot" design (FS-A-010 (private review record) §6.2, option R3 in
`display-handoff-dark.md` §6)?

This is an offline, read-only investigation. No device was touched. Both
repos were cloned (source only) into new, empty directories under the
session scratchpad. Nothing from them was run or built. Nothing was
committed. The only repo file written is this one.

Tags: [M-static] read in the repo, cited by path:line, commit or byte
offset · [C] the repo author's claim · [D] my inference · [O] open.

## Sources

| short | repo | commit read | notes |
|---|---|---|---|
| **QK** | YusufOzmen01/quest-kexec | `e61edbd7fbdf6dc4976a979c61cc545e04738422` (2026-10-04), 9 commits | Quest Pro (seacliff, XR2+ Gen 1, kona techpack, 4.19). It kexecs a patched Meta kernel from running stock Android, then switch_roots into a second Android. |
| **Q1** | nicolas-riera/Quest1-SteamOS | `b7467ff15817f05bfab60d762c1109b9116a2608` (2026-10-07), 32 commits | Quest 1 (monterey, MSM8998, Meta 4.4). `fastboot boot`, SteamOS Holo, Monado on MDSS fbdev. OLED panels. |

- GitHub issues and PRs: **none in either repo** (API listing returned
  `[]` for both, 2026-10-10).
- Neither repo has dmesg from a display bring-up. Q1's `recon/dmesg.txt`
  is just "klogctl: Permission denied". QK quotes only isolated log lines
  in its docs.
- QK's display client `initramfs/os/qkx-splash` is a **binary only**
  (static bionic AArch64 ELF, Android clang 18; sha256 `33e9dc49…16e9`;
  added in `b7c1422`, unchanged since). No source is in the repo
  (`grep -rn splash` finds only the launch script, the docs and the DT
  edits). What it does is read from its printable strings, and those
  readings are marked [M-static, strings] or [D].

---

## 0. Answers in brief

- **(a) Second modeset needed?**
  - **QK: yes, as an empirical finding, not explained.** The panel lit
    only after the same userspace atomic-KMS client ran **twice**: one
    1 s instance that exits, a 1 s sleep, then a long-lived instance
    (`qkx-launch-android:68-72`; `docs/KEXEC_ANDROID_WORKING_SETUP.md:75`)
    [M-static + C].
  - This is the closest prior art to our R3 found so far. The handoff
    type, SoC generation, kernel and panel all differ (§1.5).
  - **Q1: silent.** It shows one `FBIOBLANK` unblank lighting OLED panels
    after `fastboot boot`, with no record of an initial dark screen. It
    neither shows nor rules out a needed cycle.
- **(b) Userspace service needed for the backlight?**
  - **QK: no evidence that one is.** Its `VrPowerManagerService` "black
    screen" was a **content** problem: TimeWarp blanked the frame while
    the panel pipeline was working. It was a separate problem from
    getting the panel lit (§1.4).
  - The repo shows only the binder level of VrPowerManager. **Nothing
    about its kernel interface** (no sysfs node, ioctl or property).
  - **Q1: no Android service.** Its own compositor does `FBIOBLANK` plus a
    LED-class brightness write (§2.2).
- **(c) Forbidden-list writes:** **none in either repo.** No BLU duty,
  overlap or fifo writes, no `backlight_changes_blocked`, no BLU
  bootload/reset, no raw DCS. Two adjacent items are listed for the
  Chair in §3.
- **(d)** Seven safe, read-only or timing-only refinements for (iii-b)
  are in §4.

---

## 1. quest-kexec (Quest Pro)

### 1.1 What "brought up twice" means exactly [M-static]

`initramfs/os/qkx-launch-android` (switch mode, before `switch_root`):

| line | action |
|---|---|
| 63-66 | Comment: "Stand in for the bootloader's continuous splash: bind the panel pipeline and drop DRM master before Android's composer opens the card, so the composer becomes master and Oculus's runtime finds the panel bound, as on a normal boot." |
| 67 | Runs only if `/bin/qkx-splash` and `/dev/dri/card0` exist. |
| 68 | Comment: **"The panel only lights on the second bring-up: run once for a second, then again."** |
| 69 | `/bin/qkx-splash 1` runs **in the foreground** (synchronous). It must exit before the script continues. |
| 70 | `sleep 1` |
| 71 | `setsid /bin/qkx-splash 180 … &` runs a second instance in the background, for up to 180 s. |
| 72 | `sleep 2`. Then `switch_root` into Android (75-77). |

- So it is **two separate processes of the same client**. It is not two
  commits in one process, and there are no sysfs writes, no blank ioctl
  and no modetest.
- **History** [M-static]:
  - `b7c1422` "booting android" (2026-09-30) had **one** run:
    `qkx-splash 180 &` then `sleep 2`.
  - `4554025` (2026-10-03) added lines 68-70 and the detach wrapper
    (19-24). Both commit messages have empty bodies.
- **The author's explanation** [C], `KEXEC_ANDROID_WORKING_SETUP.md:75`:
  - "Panel only lights if `qkx-splash` runs twice (once for 1 s, then for
    real)."
  - It was running inline that got the run cut by the telnet timeout,
    hence the detach wrapper.
  - The note ends "(verify the panel lights **without a manual
    sleep/wake**)".
- **Reading of that last phrase** [D]: before the two-run fix, the panel
  was lit by a manual Android sleep/wake, which is a display off→on
  cycle. The two-run splash automates the same cycle earlier. This is
  inference from one parenthesis. The repo never states it outright.
- **The "why":** nowhere. No mechanism is given in comments, docs or
  commit messages, and there are no issues [O].

### 1.2 What qkx-splash does, from its strings [M-static, strings; byte offsets in the binary]

- Opens `/dev/dri/card0` (1828).
- `qkx-splash: drmSetMaster` (1843).
- `connector %u on crtc %u, %ux%u@%u, planes %u %u` (18888): it logs two
  plane IDs. QK's doc mentions "eye planes 57/79" (`WORKING_SETUP.md:66`).
- `no 90 Hz mode` (13575): it requires a 90 Hz mode.
- `no primary plane` (21140), `mode blob` (21170), `framebuffer` (5429),
  `atomic commit` (15494).
- Atomic property names present: `MODE_ID`, `ACTIVE`, `CRTC_ID`, `FB_ID`,
  `SRC_X/Y/W/H`, `CRTC_X/Y/W/H`, `alpha`.
  - This is a plain full-modeset atomic commit, the same family as our
    fs-pattern.
  - No sysfs paths, no backlight or brightness strings, no
    vendor-property names.
- Exit message `%s after %d s; exiting` (22002), with the reason string
  `display taken over` (15520) [D]. So the long instance holds its frame
  until either the timeout or Android's composer takes the display, and
  then exits.
- **No drmDropMaster string.** In a static binary that is not evidence
  either way. The comment claims it drops master [C].
- **Framebuffer contents: unknown.** Probably a zeroed (black) dumb buffer
  [D].

**Inferred sequence [D]** (applying our v66 analysis,
`display-handoff-dark.md` §3.3, to kona 4.19, which is unverified):
1. Run 1's commit is the first modeset after the handoff.
2. Run 1's exit closes the last `card0` fd, and lastclose turns the CRTC
   off. If splash state was cleared by run 1, that is a full panel off.
3. Run 2's commit then enables from off, through the normal panel-on path.
4. Run 2 **keeps its fd open** until the composer takes over, so no second
   lastclose turns the panel off before Android's composer opens the card.

Whether the 4.19 kona `msm_lastclose` behaves as v66's does was not
checked. QK records no dmesg from either run [O].

### 1.3 The panel across kexec, cont_splash and cmdline [M-static unless tagged]

- **Cmdline:** the target kernel boots with **stock Android's own
  `/proc/cmdline`**, minus `softdog.soft_panic=1`, plus QK options
  (`tools/prep.sh:7-11`; captured by `tools/capture.sh:15`).
  - That cmdline carries whatever display string ABL passed to stock
    (`msm_drm.dsi_display0=…`) [D; the captured cmdline itself is not in
    the repo].
  - No cmdline edit touches the display, and no splash-disable option is
    used (`grep msm_drm|dsi_display|splash` in the tools finds nothing).
- **DT:** the target DTB is the stock **live** DT
  (`prepare.py --live-dtb runtime.dtb`). It keeps
  `/reserved-memory/cont_splash_region@9c000000`, marked `no-map`
  (`qkx-install-package.sh:93`; `docs/KEXEC_RAM_12GB_RESCUE.md:118-120`).
  `secure_display_region` is also made `no-map` (`qkx-install-package.sh:94-97`).
- **Kernel patch:** `_sde_kms_release_splash_buffer()` is guarded with
  `pfn_valid()`. The kernel logs "preserving unmapped splash memory
  0x9c000000+0x2300000" (`KEXEC_RAM_12GB_RESCUE.md:121-125`).
  - That release only happens on the SDE splash-handling path. So the
    target SDE driver did run its splash-memory logic [D].
  - Whether it detected an **active** splash display (the "cont_splash
    enabled in N of M" count) is not recorded [O].
- **The stock panel at kexec time:**
  - By default stock Android is left running ("Preserve Android's live
    hardware state by default", `tools/run.sh:32-39`). Composer services
    are stopped only with `QKX_STOP_ANDROID=1`.
  - The loader then calls `kernel_restart_prepare` (device shutdown) and
    `machine_shutdown` (`module/loader.c:823-839`).
  - Whether the stock msm_drm shutdown hook powered the panel off is
    **not shown**. [D, unverified]: a typical Qualcomm `msm_pdev_shutdown`
    runs lastclose, so the panel was probably handed over off or
    half-off.
  - The comment "Stand in for the bootloader's continuous splash"
    (`qkx-launch-android:63`) shows that the author did not treat the
    pipeline as live after kexec [C].
- **Kernel patches touching display**
  (`kernel/patches/0001-…patch`, stat lines 26-28, hunks around lines
  1950-2100):
  - `dsi_ctrl.c`: `IS_ERR_OR_NULL` guards in clock deinit, and `pdev` set
    early.
  - `sde_power_handle.c`: tolerate a missing `msm_bus` client instead of
    failing probe; init order.
  - `sde_rsc.c`: log the error code.
  - `dispcc-kona.c` and `gdsc-regulator.c`: continue without bus voting,
    and dispcc moved to `fs_initcall` (around lines 280-345).
  - All of these are **probe-survival** fixes for kexec (msm_bus not
    reprobing). **None touches `dsi_panel`, panel power sequencing,
    backlight or DCS.**

### 1.4 VrPowerManager and the "black screen" [M-static doc + C]

- **Root cause as QK states it** (`WORKING_SETUP.md:32-48`):
  - `VrPowerManagerService.prepareService()` blocks in
    `waitForDeclaredService("vendor.meta.hardware.dock.IDock/default")`.
  - So the headset stays `HEADSET_UNMOUNTED` and tracking stays in
    Standby.
  - The fix was to delete the odm VINTF fragment
    `charging_accessory_service.xml`.
- **What that black screen actually was** (`WORKING_SETUP.md:226-231`):
  - "tracking stays Standby, no active pose, and **TimeWarp blanks the
    final frame even though the panel pipeline is perfect (MISR
    constant, capture all-zero)**";
  - and "only the compositor's own IPD overlay showed" (`:46`).
  - **So it was a content problem.** The panel was already showing
    compositor output (the IPD overlay was visible). It is a different
    issue from the panel-lighting fix in §1.1 [D].
- **Interfaces shown:** binder only.
  - AIDL `oculus.internal.power.IVrPowerManager/default`, transaction 3
    `acquirePowerStateLock`, lock type 1 = MOUNTED (`:232-240`);
  - the `IPowerstate` HIDL callback (`:226-228`);
  - the `IDock` AIDL HAL.
  - **No kernel interface for VrPowerManager appears anywhere in the
    repo**: no sysfs node, ioctl or DRM property. Whether VrPowerManager
    drives panel power or backlight at all is **not shown** [O].
- **Correction to our notes:** `FS-A-006-quest-projects.md:50-51` calls
  the dock HAL "the black-screen root cause". That is accurate as QK uses
  the phrase, but it should not be read as a panel-light or backlight
  cause.

### 1.5 Quest Pro panel and how it transfers

- **Mini-LED and local dimming:** the repo is **silent**. A grep for
  `dimm|mini.?led|backlight|brightness|blu|lcd` finds nothing relevant.
- **Transfer to the Quest 3 [D]:**
  - **Same family:** Meta techpack SDE/DSI driven by a plain atomic
    client, and Meta panels needing a normal panel-on after a non-ABL
    handoff.
  - **Differences:**
    - kexec from a running OS instead of ABL `fastboot boot`;
    - kona 4.19 instead of the Quest 3's 5.10 tree;
    - mini-LED LCD instead of the Tokki-A strobed edge-lit BLU;
    - the panel was probably shut down by stock before the handoff,
      where ours was probably inherited "on" from ABL with the screen
      cleared.
  - **Net:** QK is consistent with R3 (run 1 consumes the handoff, run 2
    does a real enable). It does not tell H1 from H2. Under H1, if the
    Quest 3 BLU MCU or supply is off for reasons outside the DRM enable
    path, QK says nothing about whether an enable restores it.

---

## 2. Quest1-SteamOS (Quest 1)

### 2.1 Boot and handoff [M-static]

- Every boot is a `fastboot boot` (`README.md:13,71,146`;
  `release/boot-quest1.sh:2-3`).
- The boot-image cmdline (`tools/build-boot.sh:24`) has **no display
  options**.
- The stock cmdline (`recon/cmdline.txt`) shows that ABL appends
  `mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_sdc_lightman_video:…:split_dsi…`.
  Under `fastboot boot` ABL presumably appends it too [D].
- `kernel/quest1-kernel.patch` touches **no display file**: only syscall
  backports, NCM and similar (file list at its lines 1-780).
  `kernel/steamos.config` has no display-related deltas found.
- **cont_splash:** no handling anywhere. The repo has no dmesg.
  **Silent.**

### 2.2 How the display gets lit [M-static]

- **initramfs smoke test:**
  - `initrd/init:58-59` starts `fbtest` in shell mode only.
  - `initrd/fbtest.c:45-46` opens `/dev/fb0` and calls
    `ioctl(FBIOBLANK, FB_BLANK_UNBLANK)` **once**, then mmaps and pans
    (`FBIOPAN_DISPLAY`, `:70-73`).
  - No blank→unblank cycle, no backlight write, no sleep before the
    unblank.
- **mdptest** (`src/mdptest/mdptest.c:119-120,198-199`): unblank once at
  start and `FB_BLANK_POWERDOWN` at the end "(OLED burn-in)".
- **Monado target** (`src/monado/src/xrt/compositor/main/comp_window_mdp.c`):
  - opens `/dev/fb0` and `fb0/vsync_event` (`:719-720`), and
    `MSMFB_OVERLAY_VSYNC_CTRL` on (`:745-748`);
  - `unblanked` starts false (calloc), so the **first present** calls
    `set_panels_locked(true)` (`:551-556`);
  - that function (`:179-206`) does `FBIOBLANK UNBLANK` (`:196`), vsync
    on, and `set_brightness()` (`:200-202`);
  - frames go out with `MSMFB_ATOMIC_COMMIT`, one DMA pipe per panel
    (`:562-592`);
  - panels go off with `FB_BLANK_HSYNC_SUSPEND` when there are no frames
    for 1 s (`:268-269`) or the proximity sensor reports "removed"
    (`:226-233`);
  - `target_destroy` forces a blank "also blank what an earlier process
    left on" (`:684-687`);
  - systemd `ExecStopPost` writes `4` (POWERDOWN) to
    `/sys/class/graphics/fb0/blank` (`device/holo-monado.sh:36-37`).
- **Backlight / brightness**, commit `a8869a5` (`:154-177`):
  - the claim [C]: "mdss brings the panels back at its default backlight
    (127/255) after each unblank … while the LED class keeps reporting the
    last value written, so rewriting it is a no-op";
  - the fix: write `level-1`, then `QUEST1_BRIGHTNESS` (default **255**)
    to `/sys/class/leds/lcd-backlight/brightness` after every unblank;
  - the motivation was "everything looked much darker", not "dark".
- **Was the screen dark at first?** No doc, commit or issue reports an
  initially dark screen after `fastboot boot`, or a fix for one. The
  README claims "Both panels at 72 Hz" (`:26`) [C]. **Silent** on any
  first-light difficulty.

### 2.3 The fan/blank coupling [M-static code comment + C]

- Commit `0835027` and `comp_window_mdp.c:193-195` say: "The Oculus fan
  driver (vs1-board.c) stops the fan on FB_BLANK_POWERDOWN [or
  VSYNC_SUSPEND] and only runs it while the screen is on … mdss powers
  the panels off for FB_BLANK_HSYNC_SUSPEND too, which the fan driver
  ignores: blank with that instead."
- `vs1-board.c` is in Meta's kernel, not in the repo [C].
- Commit `701a874` ("Prox events after boot"): a proximity-stream open
  order bug meant the "panels never turned off" for a whole boot. It is
  a power-policy bug, not a lighting one.
- **Transfer [D]:**
  - It confirms that Meta's kernels have coupled **fan control to display
    blank state** (Quest 1, fbdev notifier). That supports the fan caveat
    in FS-A-010 §6.6 for our two blank events.
  - The HSYNC_SUSPEND trick does not exist on DRM. The Quest 3 coupling,
    if any, would be through a DRM or panel notifier [O].

### 2.4 How Q1 transfers

**Does not transfer [D]:**
- the MDSS fbdev ioctls (`FBIOBLANK`, `MSMFB_*`);
- the LED-class `lcd-backlight`;
- OLED DCS brightness (no separate BLU).

The Quest 3 has FB off. It uses SDE DRM, the backlight class
`panel0-backlight`, and a Tokki-A strobed BLU.

**Transfers, at most [D]:**
- **Meta's display driver re-applies its own default brightness at each
  unblank**, rather than what the userspace node reports. This matches
  v66 (`sde_connector.c:261`: brightness defaults to max at enable unless
  an `unset_bl_level` is pending). So a read-back of
  `brightness`/`actual_brightness` is weak evidence of the real level.
- The **double-write trick is not needed** on the Quest 3. The
  backlight-class `brightness` store calls `update_status` on every write
  (generic backlight core), unlike the LED class [D, generic kernel
  knowledge; not re-checked in v66].

---

## 3. Forbidden-list check and Chair items

- **Neither repo writes** `blu_default_duty`, `blu_max_overlap_us`,
  `fifo_trim`, `backlight_changes_blocked`, debugfs
  `override_default_duty`, or `oculus,blu` bootload/reset, and **neither
  injects raw DCS** [M-static, grep for
  `blu|duty|fifo|overlap|dcs|mipi` over both trees; Q1's only DCS-ish
  hits are UAPI header definitions].
- **Adjacent items, listed so they are not copied without a decision:**
  1. **Q1 drives the backlight to maximum (255/255) after every unblank**
     (`comp_window_mdp.c:154-177`). That is a userspace override of the
     driver default on a different panel type.
     - The Quest 3 analogue would be a `panel0-backlight` write. That node
       is not forbidden, but it is a new write, and anything above
       recovery's 127 needs a Chair/PM decision.
     - **Not recommended.** The Quest 3 already defaults to its maximum
       (bl 1000, about 8.2 % duty) at enable.
  2. **QK's closed binary `qkx-splash`** must not be run on our hardware.
     It is untrusted, has no source, and was built for the Quest Pro's
     90 Hz mode.
  3. **QK's kernel and DT changes** (bus-vote tolerance, splash-memory
     guard, `no-map` edits) are kexec-only. We run the stock v66 kernel
     under `fastboot boot`, so they are not applicable. Listed only for
     completeness.

---

## 4. Concrete safe additions to trial (iii-b)

All of these are timing changes or read-only probes. None writes a node,
and none adds a new panel transition beyond the one FS-A-010 §6.2 already
names.

1. **Make run 1 synchronous and gate run 2 on run 1's exit, not on a
   fixed sleep from launch.**
   - QK runs instance 1 in the foreground and only then sleeps
     (`qkx-launch-android:69-70`).
   - Our init should `wait` on run 1's PID, then pause at least 2 s, then
     start run 2.
   - QK's 1 s pause worked on the Quest Pro. Our ≥ 2 s is more
     conservative, given v66's measured `close_ms=534` and the
     120 + 250 ms DT waits.
2. **Make sure no other process holds `/dev/dri/card0` open between the
   runs.** Run 1's close must be the *last* close for lastclose to power
   the panel off. QK depends on the same thing implicitly.
   - This includes any probe helper. Probes should use sysfs or
     `/proc`, not a second DRM fd.
   - The existing in-trial check that run 2 reads `crtc_state active=0`
     stays the arbiter.
3. **Optional (Chair/PM): shorten run 1's hold.**
   - QK's first instance holds only 1 s. Run 1's only job is to consume
     the handoff. In trial (iii) it gave no light.
   - Cutting run 1 from 10 s to about 3 s would cut W by about 7 s and
     shorten the retained-frame worst case. The cost is a shorter run-1
     viewing window.
   - Not recommended below about 3 s, so the PM can still report run 1.
4. **Add read-only DRM-core connector sysfs to the probe set:**
   `/sys/class/drm/card0-*/status`, `enabled` and `dpms` for the DSI
   connector. Read them after modules load, after each commit and after
   each close.
   - The node names are discovered with `ls` in our init.
   - These are standard DRM attributes, read-only. They show the close →
     off → on sequence without opening `card0`.
5. **Widen the bounded dmesg filter** from `dsi|sde|drm|blu|WARN` to also
   match `splash|panel|backlight|bl_`.
   - This catches the splash-cleanup and panel on/off messages at run 1's
     close and run 2's enable.
   - QK's only display evidence is exactly such a line ("preserving
     unmapped splash memory").
6. **Read `panel0-backlight/{brightness,actual_brightness}` after each
   enable, but label it weak evidence.** Q1 shows that Meta's driver
   re-applies its own default at unblank regardless of the userspace
   value (§2.4). The TE and BLU-PWM IRQ deltas stay the primary signal.
7. **Fan:** if a read-only fan or cooling-device node exists in our
   environment, read it before and after each run. Q1 confirms that
   Meta couples the fan to blank state (§2.3), and (iii-b) has two blank
   events. Discovering the node is read-only. No fan write.

**Registered-outcome note [D]:** QK's history predicts the FS-A-010 §6.6
outcome "run 1 dark, run 2 lit". If that is what happens, it supports
"the handoff path never wakes the panel" (H2, or a recoverable H1). It
does not identify which component was off.

---

## 5. Where the repos are silent [O]

- Why a second bring-up is needed (QK gives no mechanism), and any dmesg
  from either QK run.
- Whether QK's target kernel detected an active cont-splash display after
  kexec, and what stock shutdown did to the panel before kexec.
- QK: anything on the Quest Pro mini-LED / local-dimming controller,
  backlight nodes, or VrPowerManager's kernel-level actions.
- Q1: any initially dark screen after `fastboot boot`, any cont_splash
  handling, and dmesg of any kind.
- The source of `qkx-splash`, so its framebuffer contents and its
  master-drop logic are not verifiable.
