# Quest 3 display bring-up on the stock kernel (static test pattern)

Question (PM, 2026-10-08): can we put a static test pattern on the Quest 3
panels soon, with Meta's stock kernel, stock vendor modules and our own
initramfs (the stage-1 route: `fastboot boot`, no flashing)?

This is offline research only. No device was touched.

> **Correction (2026-10-10, J-75; `docs/research/display-handoff-dark.md`
> §3):** the backlight statements below were drawn from the v2.7 source
> and are **wrong for v66**.
> - `backlight_changes_blocked` does not exist in the v66 source or in the
>   v66 `msm_drm.ko` [M-static].
> - On a full-modeset commit, v66 reprograms the Tokki-A BLU at
>   bl 1000/1000, i.e. duty = vtotal × 1000/1000 × 82/1000 ≈ 8.2 %
>   [D, near-match v66 .510 source]. That is Meta's normal maximum and
>   about 2× recovery's 127 write (≈ 4.1 %). It does not stay at "the boot
>   level".
> - How the pre-on block "Backlight - set to 100%" relates to the Tokki-A
>   duty is [O].
> - Trial (iii) shows the panels emitted no light, so no frame was seen
>   at any level.


Tags: [M] hardware output · [M-static] artifact, cited by path:line · [D]
derivation · [C] hypothesis · [O] **open**.

Sources:
- v2.7 kernel source: WSL `~/work/kgate27/src`. The display driver is
  `techpack/display/msm/` (`CONFIG_DRM_MSM` is off; `msm_drm.ko` is the
  techpack driver).
- Stage-1 logs: FS-A-005 (private review record).
- Stock v66 images of Unit 1: `firmware/quest3/v66_unit1_slotA/`
  (the kernel and modules used in stage 1), plus its vendor and odm
  images. `recovery.img` was unpacked into a scratch directory and
  read only. Recovery paths below are inside that ramdisk.

The v2.7 source is used for the driver logic. Stage 1 ran the v66 kernel
(`5.10.198-01402-g1c5986fe21ee`). That the v66 display driver matches v2.7
on the points used here is [C]. The stage-1 dmesg strings match v2.7 code
paths line for line where checked.

---

## 0. Correction: the panel is not `sy103`

FS-A-006 (private review record) §2.3 (display row) says "Panel `sy103` in DT (1280p,
90 Hz, video mode)". **That is wrong.**

- `sy103` exists only in Qualcomm's reference display trees
  (`arch/arm64/boot/dts/vendor/qcom/display/anorak-sde-display-idp*.dtsi`,
  `dsi-panel-sy103-*.dtsi`) [M-static].
- Meta's tree overrides the default panel:
  `arch/arm64/boot/dts/oculus/eureka/eureka-panel.dtsi:125`
  `qcom,dsi-default-panel = <&eureka_panel_sharp>` [M-static].
- ABL passes `msm_drm.dsi_display0=meta,eureka_panel_sharp:`
  (`serial-session3-20261008T040633Z.txt:12`) and the driver binds it
  (`:633`, `:638`) [M].

**The real panel** (`eureka-panel-sharp.dtsi`) [M-static]:

| property | value | line |
|---|---|---|
| name | "Sharp novatek dual video mode dsi panel with dsc" | 6 |
| mode | video mode, one panel node driving DSI 0 and DSI 1 | 7–9 |
| refresh | min 72, max 240, default 90 Hz | 29–31 |
| orientation | 180° | 34 |
| `meta,cont-splash-handoff` | set | 36 |
| PHY | C-PHY | 41 |
| timing@0 | 2064 × 2208 per DSI link | 45–46 |
| timing@1 | 1552 × 1664 with DDIC upscaling ("1.33x") | 271–273 |
| compression | DSC, 8 bpp, slice 1032 × 32 | 254–260 |
| topology | 4 mixers, 4 DSC, 2 interfaces | 266 |

The DRM mode doubles the width across the two links
(`techpack/display/msm/dsi/dsi_display.c:7805`), so the expected preferred
mode is **4128 × 2208 @ 90 Hz** on one connector, `DSI-1` [D]. Stage 1 saw
exactly one DSI connector (`serial-session-20261008T0359Z.txt:12`) [M]. The
actual mode list is [O].

Both eyes share one connector and one CRTC, so one modeset covers both
panels [D].

---

## 1. Why nothing was displayed in stage 1

**Most likely: nobody ever committed a frame.** Taking the points in turn:

1. **No DRM client ran** [M-static]. `devices/quest3/stage1/init.sh` loads
   the 97 recovery modules (`:156-158`), then does USB and the shell. It
   never opens `/dev/dri/card0`. msm_drm probed fully: "Initialized msm_drm
   1.4.0" (`serial-session3…:654`) [M].
2. **Continuous splash was active** (`serial-session3…:655`, "cont_splash
   enabled in 1 of 1 display(s)") [M]. ABL left the MDSS pipeline and the
   panels running. The kernel took them over without reprogramming
   anything: it marks the CRTC active with the preferred mode
   (`sde/sde_kms.c:3612-3619`). The panels then keep scanning whatever ABL
   left in its splash buffer until userspace commits [D, from source]. No
   splash timeout was found in `msm_drv.c` or `sde/*.c` [D; partial
   search, not exhaustive]. So "nothing" means ABL's last image during `fastboot boot`
   was black or unlit. Which of the two it was is [O]: nobody recorded
   whether the panel was backlit black or dark.
3. **No fbdev or console** [M-static]:
   `extracted/v66_unit1_slotA/kernel.config` has
   `# CONFIG_FB is not set` (`:3966`),
   `# CONFIG_DRM_FBDEV_EMULATION is not set` (`:3792`) and
   `# CONFIG_VT is not set` (`:2583`). There is no `/dev/fb0` and no
   framebuffer console, so no kernel text could have appeared. The cmdline's
   `video=vfb:640x400` is inert.
4. **Regulators and power sequencing: not the cause** [D]. The panel
   supplies are present and loaded:
   - TPS65132 VSP/VSN bias: `eureka-panel.dtsi:46-73`, `tps65132_regulator`
     loaded (`serial-session…:73`);
   - vddio L5B and `display_panel_vsp_en`: `:118-123`, `:133-142`;
   - the BLU MCU supply L12B, held by `blu_fw_driver`
     (`eureka-panel.dtsi:412-425`; `drivers/staging/oculus/blu_fw_driver.c:163-227`).

   The "outp/outn: Operation of current configuration missing" lines
   (`serial-session3…:623-628`) are warnings, not failures [C].
5. **Firmware: not the cause** [D, from the stage-1 log]. The only display firmware request was
   `dsi_prop`, an optional DT override. It fell back to the device tree
   after the 1 s timeout (`serial-session3…:629-631`). `/vendor/firmware`
   on v66 has no display or DSI blob; listed offline from the image with
   e2fsprogs `debugfs` [M-static].
   msm_drm needs no remoteproc or co-processor.
6. **No Meta-specific compositor appears to be needed to scan out** [D].
   Meta's own recovery draws with plain DRM (minui). See §2.
7. **Two harmless-looking errors:** "unable to find domain 1/3 … nrt"
   (`serial-session3…:648-649`) concern non-realtime (writeback) SMMU
   domains, not DSI [C]. Whether Android logs the same is [O].

**Backlight is a separate, Meta-specific path** [M-static], and it explains
why brightness cannot be changed from our side by default:

- The backlight type is `bl_ctrl_tokki_a` (`eureka-panel.dtsi:265`): a
  strobed backlight unit (BLU) whose pulse timing is sent as DCS commands
  to the Novatek DDIC (`dsi/dsi_panel.c:802-1000`).
- Duty is capped by design: pulse length =
  `vtotal × bl_lvl/1000 × blu_default_duty/1000` (`dsi_panel.c:861`). With
  `meta,blu-default-duty-cycle = <82>`, that is **8.2 % at full level**
  (`eureka-panel.dtsi:266`).
- **Changes start blocked.** `backlight_changes_blocked = 1`, commented "we
  start blocked, will unblock when bootanim is done"
  (`dsi_panel.c:3918-3919`). While it is set, every Tokki-A update returns
  early (`dsi_panel.c:829`, `:1034`, `:1187`, `:1286`). Writes to
  `panel0-backlight/brightness` are therefore ignored until something
  writes 0 to `/sys/class/drm/card0-sde-crtc-0/backlight_changes_blocked`
  (`sde/sde_crtc.c:1007-1044`). Nothing in vendor, odm or recovery writes
  it (searched) [M-static]. The writer is presumably in system [C].
- **Consequence [D]:** on our boot the BLU runs at the boot default that ABL
  and the panel's pre-on commands set ("Backlight - set to 100%",
  `eureka-panel-sharp.dtsi:72-83`). Meta's boot logo and recovery UI also
  run at this level. Its actual luminance and duty are [O].

---

## 2. Minimal set for a static pattern

### 2.1 Proof that this route works: Meta's recovery [M-static]

Meta's recovery ramdisk (`v66_unit1_slotA/recovery.img`) does
exactly what we need, with the same 97-module recovery set that stage 1
loaded (`modules.load.recovery`):

- **Services:** only `ueventd`, `charger`, `recovery`, `adbd` and
  `fastbootd` (`system/etc/init/hw/init.rc:64-81`). There is no composer,
  HWC or Meta compositor.
- **Drawing:** `librecovery_ui.so` (minui) contains the QTI atomic DRM
  backend: `MinuiBackendDrm::SetupPipeline`, `AtomicPopulatePlane`,
  `DrmEnableCrtc`, `DRM_IOCTL_MODE_CREATE_DUMB`, `drmModeAddFB2`, the
  properties `FB_ID`/`CRTC_ID`/`SRC_*`/`CRTC_*`/`MODE_ID`/`ACTIVE`, and
  the SDE topology names `sde_quadpipe_dscmerge` and so on (from
  `strings`).
- **Tuning:** `prop.default:113-114` sets recovery UI margins of 480/456 px,
  so text sits inside the visible lens area. `:480-484` sets
  `ro.minui.default_rotation=ROTATION_CUSTOM`, `RGBX_8888`, and "21 + 180
  since the screen is upside down".
- **Backlight:** `init.recovery.eureka.rc:28` writes `panel0-backlight` =
  127. That write is blocked per §1.

[D] Meta built and tuned a stock-kernel, dumb-buffer, atomic-modeset path
for these panels. The PM reports that stock recovery lights the Quest 3
panels (2026-10-09; PM report, J-43). That shows recovery's minui path
works on this hardware; it does not show that our `fs-pattern` route does.

### 2.2 What we need

| item | what | status |
|---|---|---|
| kernel | stock v66 `Image`, as in stage 1 | have it |
| modules | the same 97-module `modules.load.recovery` set (ok=97 fail=0 in stage 1, `serial-session…:12`) | have it |
| firmware | none. Keep `/sys/class/firmware/timeout`=1 so `dsi_prop` does not stall 60 s (`init.sh:153-154`) | have it |
| `/dev/dri/card0` | `DEVTMPFS=n`: `mknod /dev/dri/card0 c 226 0`, checking `/sys/class/drm/card0/dev` first | 1 line |
| userspace | a static DRM client: dumb buffer + atomic commit, holding the fd open | **to write** |
| Android daemons | none (§2.1) | — |

Display-relevant modules inside the 97 [M], from `/proc/modules` in
`serial-session…:73-168` and the DT:

- `msm_drm.ko`;
- its users: `msm_ext_display`, `msm-mmrm`, `hdcp`, `altmode-glink`,
  `spmi-pmic-arb`, `pinctrl-msm`, `panel_event_notifier`,
  `msm_dma_iommu_mapping`, `llcc-qcom`, `dwc3-msm`, `qcom_rpmh`,
  `qcom_iommu_util`, `qcom-scm`;
- providers: `dispcc0-anorak`, `dispcc1-anorak`, `gcc-anorak`, `clk-rpmh`,
  `gdsc-regulator`, `rpmh-regulator`, `qti-fixed-regulator`,
  `tps65132-regulator` (LCD bias), `i2c-msm-geni` (the TPS65132 bus),
  `blu_fw_driver` (BLU MCU supply), `arm_smmu`, `qnoc-anorak`/`icc-rpmh`
  and `qcom_dma_heaps`.

`mp3314.ko` is also in the set, but its DT node exists only for `panther`
(Quest 3S, `oculus/panther/panther-panel.dtsi:210`), so it is a no-op here
[M-static]. **Keep loading all 97 rather than pruning.** Pruning adds risk
for no gain.

### 2.3 The userspace client

**Our own ~250-line static C program** using only kernel uapi ioctls
(`/usr/include/drm/drm_mode.h` is present in WSL; `aarch64-linux-gnu-gcc`
is installed, the same toolchain as `fs-reboot`). No libdrm is needed.
busybox cannot do this.

Supported by the driver [M-static]:
- `DRIVER_ATOMIC | DRIVER_MODESET`;
- `dumb_create`/`dumb_map_offset` (`msm_drv.c:2264-2278`);
- legacy `SETCRTC` via `drm_atomic_helper_set_config`
  (`sde/sde_crtc.c:7975`).

Sequence:
1. `DRM_IOCTL_VERSION`: require the name `msm_drm`.
2. Set client caps `UNIVERSAL_PLANES` and `ATOMIC`.
3. Find the connected DSI connector and its preferred mode; create a mode
   blob.
4. Make one XRGB8888 dumb buffer of 4128 × 2208 (≈ 36 MB). Fill it once.
   Call `ADDFB2`.
5. Run an atomic `TEST_ONLY` first, then the real commit
   (`ALLOW_MODESET`): plane `FB_ID`/`CRTC_ID`/`SRC`/`CRTC` rects, CRTC
   `MODE_ID` + `ACTIVE=1`, connector `CRTC_ID`.
6. **Hold the fd open for a bounded time, then close it** (corrected after
   the fs-pattern review; the earlier "never close the fd" is withdrawn).
   Closing ends the image: as DRM master, preclose null-commits our FB off
   the planes (`msm_drv.c:1624-1629` → `sde_kms.c:2577-2660`); the last
   close then runs `msm_lastclose` (`drm_file.c:497` → `msm_drv.c:1095`),
   whose kms_client commit (`msm_drv.c:1169-1170`) carries no mode and
   disables the CRTC (panels off) [D, v2.7; v66 [O]]. If no commit of ours
   happened, splash is still active and lastclose returns early
   (`sde_kms.c:3858`), leaving the panels as ABL left them. Closing is the
   intended, bounded end of the test (stage 3a `fs-pattern`). No loops and
   no re-commits.

Open details:
- **Plane splitting** is [O]. SSPP linewidth is 5120 and source split is
  available (`vendor/qcom/display/anorak-sde-common.dtsi:149,162`), so one
  full-width plane may pass. minui splits per mixer by topology name.
  Probe both with `TEST_ONLY`, which is harmless.
- **Splash handoff** is [O]. Because the splash CRTC is already "active"
  with the same mode, the first commit may be only a plane swap, not a full
  enable. Either way the backlight stays at the boot default, because
  updates are blocked.

**Pattern:**
- dark-grey field (about 0x20);
- one mid-grey frame or cross inside the central area (stay inside the
  480/456 px recovery margins);
- distinct left and right markers (one bar on the left half, two on the
  right) to prove both links;
- orientation-agnostic, because the panel is rotated 180° and canted.

No full-field white, no animation, no re-commits.

---

## 3. Safety

- **Power sequencing [D]: low risk.** We never touch regulators or GPIOs.
  The stock driver applies Meta's DT sequence (supply entries and sleeps
  `eureka-panel.dtsi:144-192`; reset `eureka-panel-sharp.dtsi:21-23`).
  Stage 1 already had the panels powered through continuous splash, and
  then rebooted through `fs-reboot` with no observed harm (J-21) [M for
  the reboot; absence of harm is not a measurement]. msm_drm's
  shutdown hook only runs lastclose (`msm_drv.c:2700-2720`). A reboot cuts
  the rails as in any Android reboot. A static pattern changes the
  content, not the power state.
- **Backlight and heat [D].** With changes blocked, the BLU stays at the
  boot default that Meta uses for its boot logo and recovery. The Tokki-A
  maths caps duty at 8.2 % even at full level (`dsi_panel.c:861`).
  "panel0-backlight 255/255" in Android is the max state of the cooling
  device, not evidence of a hot backlight. **Forbidden writes** (each can
  lengthen pulses or upset the BLU MCU):
  - `card0-sde-crtc-0/{blu_default_duty, blu_max_overlap_us, fifo_trim, backlight_changes_blocked}` (`sde_crtc.c:1075-1085`);
  - debugfs `override_default_duty` (`dsi_display.c:2639`);
  - `oculus,blu` `bootload`/`reset` (`blu_fw_driver.c:51-122`), which put
    the MCU into its bootloader;
  - any raw DCS injection.

  Lowering brightness means unblocking, which runs Android's normal
  driver path. Keep that as an explicit, separate step if the PM wants
  dimmer output.
- **Fan [M-static].** `pwm-tach-fan` starts with `is_display_on = true`
  (`drivers/staging/oculus/pwm-tach-fan.c:1186`). This resolves the [O] in
  `FS-A-006-power-thermal.md` §3: the cap applies only after a BLANK event
  (`:677-686`), and UNBLANK restores the vote (`:687-694`). Turning the
  display on does not raise the fan. **In the stage-1 environment nothing
  drives the fan at all:** `qcom_tsens.ko` is only in vendor_dlkm and was
  not in stage 1's module list, so SoC thermal zones are not expected [D,
  from the module list and DT; not inferred from missing log lines (FS-R-005
  §4)]. The cmdline also sets
  `cpufreq.default_governor=performance` (`:12`), against PROJECT_SETUP
  §6A.4. **The display adds heat with no active cooling or kernel
  monitoring, so time-box the test** (fs-pattern requests a 10 s hold; the
  stage3a image intends to reboot at T0+170 s; whether the panels go dark
  on close is [O] on v66, FS-R-007 §4), or design a
  monitored variant: load `qcom_tsens.ko` for thermal zones, and never
  load `qcom-spmi-temp-alarm` (PROJECT_SETUP §6A.3). Display state is not
  a cooling control (FS-R-006 §4).
- **Eye safety [D]/[C].** The BLU strobes at the refresh rate (90 Hz,
  ≤ 8.2 % duty), which is normal Quest operation and far above the 3–30 Hz
  photosensitive band [C]. Our test adds no flashing: one commit, static
  image, dark content, no on/off toggling (repeated blank/unblank would be
  a slow flash). The observer looks through the lenses briefly. Keep the
  lenses out of direct sunlight [C].
- **Panel wear [C].** LCD image retention from a few minutes of a static
  dark pattern is negligible.

---

## 4. Valve userspace or the rebuilt kernel?

**Neither** [D].
- Kernel: the stock v66 kernel and its 97 recovery modules, unchanged
  (§2.2).
- Userspace: one static binary of our own, plus `init.sh` additions.
- No Valve files, no v2.7 build, no Android daemons.

On a v2.7 kernel, the same client is expected to work with v2.7's own
modules [C]; the kernel gate only shows matching symbol-version interfaces
(FS-R-006 §2).

---

## 5. Feasibility and open questions

**Assessment (Arbiter's judgement, [C]):** feasible with modest work and
low risk if the safeguards hold. The work is:
- one small C tool;
- an `init.sh` stage (mknod, run the tool after `MODULES_READY` and before
  the USB setup, or from the shell);
- the usual review package and one `fastboot boot` with the PM present.

Top open questions:
- **[O1]** What the panels showed during stage 1: lit black or unlit.
  Needs the PM's eyes on the lenses at the next boot.
- **[O2] answered by PM report (2026-10-09, J-43):** stock recovery lights
  the Quest 3 panels. This shows minui's plain-DRM path works on this
  hardware; our own route remains to be shown by the display test. (The PM
  checked it independently; no reboot by us. It is a PM report, not
  hardware output we recorded.)
- **[O3]** Whether the first commit after splash handoff is a plane swap or
  a full enable, and whether a single 4128-wide plane passes `TEST_ONLY`.
- **[O4]** The boot-default BLU luminance and duty with changes blocked.
  Also which process unblocks it in Android (presumably system, not
  extracted).
- **[O5]** The thermal envelope of a held display with no tsens and the
  fan off. Bound it by time, or add monitoring.
- **[O6]** The full mode list (timing@0 / timing@1 × refresh rates).
- **[O7]** Whether the v66 driver matches the v2.7 source on the backlight
  block and splash paths cited here.
