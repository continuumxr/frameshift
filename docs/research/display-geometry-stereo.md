# Quest 3 display geometry for correct stereo, and the boot splash

Question (2026-10-13, after J-125..J-127): stage 3c lit both panels, but
the eyes came out swapped and each image was rolled ("canted inward": the
left eye clockwise, the right eye counter-clockwise). Questions:
- What is the exact panel roll, per eye and per device?
- What must a SteamVR or Frame runtime driver be given to render correct
  stereo, and how does the Steam Frame supply it?
- Where does Meta keep per-unit display calibration, and can we read it
  at runtime?
- How do we validate this, and how should the boot splash be drawn?

This builds on `display-pipeline-and-geometry.md` §C, which it extends and
in places corrects.

Offline and read-only. No device was touched and nothing was committed.

**Tags:**
- **[M]** hardware output, including PM reports of what was seen.
- **[M-static]** read from a named artifact.
- **[D]** derived.
- **[C]** inferred, or an external claim we have not verified.
- **[O]** open.

Web claims come from a focused web survey run alongside this note. They are
tagged [C] unless re-checked here.

**Public-scope note:** Meta property values and file names quoted below
are for private research. The public export follows J-90: names and our
own derivations only, after audit.

## Sources

- **Meta v2.7 OTA** `firmware/quest3/ota/q3_52433670036000520.zip`. We
  extracted the `odm`, `product`, `system` and `system_ext` partitions
  locally with the stdlib payload reader, into WSL `~/work/geom-x/` (not in
  the repo). sha256 prefixes: odm `a107220e…`, product `b0830d33…`, system
  `a43502bc…`, system_ext `1398d3cc…`.
  - We also opened the APEX payloads `com.meta.xr` and `com.meta.hzos`
    from `odm`.
  - `com.meta.quest.apex` is listed in `odm` but could not be dumped.
    Not investigated [O].
  - File trees were listed with `debugfs -c` (catastrophic mode,
    read-only). Only `build.prop`/`.rc` text and file names were read.
    No Meta executable was disassembled.
- **v2.7 vendor** `~/work/fs006-kernel/v27/vendor.img`; **v66 super
  extracts** `firmware/quest3/v66_unit1_super/`.
- **DTs** `~/work/dtdiff/{v66,v27}.dts`; **Meta kernel source**
  `~/work/fs006-kernel/src` (`23c97b254`, v66 build).
- **Unit 2 (v2.7) getprop**
  `devices/quest3/evidence/unit2-v27-baseline-20261012/getprop-all.txt`.
- **Unit 1 stock display capture**
  `devices/quest3/evidence/stock-display-20261010/`.
- **Steam Frame rootfs** (read-only) WSL `~/sfroot-full`, build
  `20260922.6152327`. Also
  `firmware/SteamOS/extracted/{config-6.18.0-gfbdbca41fd45,sm8650-deckard.dtb}`.
- **OpenVR driver header** as shipped in the Frame rootfs
  (`/opt/steamvr/tools/hellovr_vulkan_linux/src/openvr/headers/openvr_driver.h`,
  BSD-3, SteamVR API 2.1).
- **Our code:** `devices/quest3/stage3c/src/fs-pattern.c` and
  `devices/quest3/stage3d/src/fs-pattern.c` (v0.7, uncommitted).

---

## 0. Answers in brief

1. **Roll angle.** Meta's own value is **21° of in-plane roll per eye**,
   mirrored between the eyes, on top of a 180° mount.
   - Source [M-static]: in the v2.7 odm `/etc/build.prop:49-50`, the comment
     directly above `ro.minui.rotation_degrees=201` explains the value as 21°
     plus 180° for the upside-down screen (paraphrased; no Meta file text
     reproduced). Unit 2's live props carry the same
     value (`getprop-all.txt:2054`).
   - Community levelling of Quest 3 mirror streams uses about 22°
     (scrcpy `--angle=22`) [C].
   - Quest Pro: "21° toward each other" from a pre-launch CAD leak [C].
   - **Confidence:** high that the design value is 21°, because it is a
     Meta constant. That it is *exactly* 21.0° optically is medium: it is
     an integer setting, and community estimates are 20–22°.
   - **It is a per-model constant** (one odm file for every unit).
     Per-unit residual roll and decenter are probably factory-calibrated
     in `/persist/calibration` [C, Quest 1 precedent]. Magnitude [O].
2. **Direction [M, PM report J-125].** Upright content appears rotated
   clockwise in the left eye and counter-clockwise in the right: the tops
   lean toward the nose.
   - Compensation: pre-rotate the left eye's content counter-clockwise
     and the right eye's clockwise, by 21° [D]. This is what stage 3d v0.7
     does (`roll=21`).
   - The scrcpy practice agrees: the left half of Meta's composited
     buffer needs +22° (clockwise) to look level, so Meta pre-rotates the
     left eye counter-clockwise [C].
3. **The "swap" is the 180° mount applied to the whole frame [D, strong].**
   - Stage 3c rotated each 2064-px half by 180° *in place*
     (`stage3c/src/fs-pattern.c:493-560`).
   - The DT orientation (`qcom,mdss-dsi-panel-orientation = "180"`,
     `v27.dts:16973`) and Meta's composer (`ro.vros.composer.orientation=ROTATION_180`,
     v66 `prop.default:558`) both rotate the **entire 4128-wide frame**.
     That maps buffer half 0 to the *right* eye.
   - "Per-half 180° + swap" and "whole-frame 180°" are the same mapping.
     The driver should express it as one whole-frame 180° rotation, then
     apply the per-eye roll in viewer coordinates.
   - Stock scan-out uses `rotation=1` (DRM_MODE_ROTATE_0) on every plane
     (`capture-lit.txt:144`, `:168`). Meta renders the rotation into
     the buffer and uses no hardware rotation [M-static].
4. **IPD is read from two magnetic sensors, raw [M-static].** The odm
   `build.prop:56` (also `getprop-all.txt:2029`) names:
   - `ro.iad.sysfs_nodes` = the AS5510 Hall sensor's `adc_raw_value`
     (`/sys/bus/i2c/drivers/as5510/0-0056/`);
   - and the AK09973 magnetometer's `in_magn_z_raw` (`…/ak09973/0-0010/iio:device1/`).
   - Both drivers are GPL and in Meta's public tree
     (`drivers/staging/oculus/as5510.c`, `drivers/iio/magnetometer/ak09973.c`).
     Both ship in v2.7 `odm_dlkm` and `vendor_ramdisk`.
   - The raw-to-millimetres conversion is [O]. It is probably per-unit
     calibration [C].
5. **The Steam Frame keeps per-unit HMD geometry in `/persist/device_config.json`
   [M-static].**
   - The file is restored from an on-board EEPROM (`restore-calibration`).
   - SteamVR's `vrcalib` uses it to predistort the boot logos and to build
     a lens-warped kernel console. The Frame's boot splash is therefore
     per-unit and lens-aware (§5).
   - The JSON schema is not public [O]. The Frame's controller configs use
     the lighthouse device-config schema (`device_class`, `imu`,
     `lighthouse_config`, …), so the HMD file is probably the same family
     as the Index's [C].
6. **Meta's per-unit calibration** lives under `/persist/calibration/`.
   - `calibrationserver.rc` (system_ext) creates `/persist/calibration`
     and `/persist/calibration/online` [M-static].
   - The display files' names and format are [O].
   - Reading them would be a **new action class**: Meta `persist`, never
     yet read by us, needs the Chair (§3).

---

## 1. Panel roll and layout per device

| device | in-plane roll | mount / scan-out | per eye | evidence |
|---|---|---|---|---|
| **Quest 3** | **21°**, mirrored per eye (tops nasal) | 180° whole frame; one 4128×2208 mode over 2 DSI links | 2064×2208 | odm `build.prop:49-50` [M-static]; Unit 2 `:2054` [M-static]; PM J-125 [M]; scrcpy ≈22° [C] |
| **Quest Pro** | 21° "toward each other" [C, leak]; 30° claimed in one issue [C, weak] | [O] (no Pro firmware held) | 1800×1920 [C] | survey |
| **Quest 2** | none known [C] | SurfaceFlinger `ORIENTATION_270` (v2.7 vendor `build.prop:133`) [M-static]; portrait panel, eyes stacked | 1832×1920 | survey; QK2 notes |
| **Quest 3S** | as Quest 2 [C] | Quest 2 LCD and Fresnel lenses [C, heise] | 1832×1920 | survey |
| **Steam Frame** | none: Link dump shows 0° view rotation [C] | 2 DSI links, two `deckard_panel` nodes with `dual-panel` (`sm8650-deckard.dtb`) [M-static]; no rotation property in the DT [M-static] | 2160×2160 | DT; survey |

**Notes:**
- **Roll vs yaw.** On Link, every Meta headset reports identity eye-to-head
  rotation. So the roll never reaches apps: Meta's compositor absorbs it
  [C, survey; risa2000 `hmdgdb`]. It is in-plane (about the optical axis),
  not a yaw cant. Our driver must also keep it out of the eye-to-head
  transform (§2).
- **Version history.** v66 put the same 21° + 180° comment and 201 on
  `ro.boot.bootloader_screen_rotation` (recovery `prop.default:482-483`,
  §C.1 of the pipeline note). v2.7 puts them on `ro.minui.rotation_degrees`
  in odm `build.prop` [M-static]. The value and meaning are unchanged.
- **What 201 implies [D].** A single value cannot express mirrored
  per-eye rolls. Meta's minui runs `ro.iad.split_panel=true` (odm
  `:55`), which is presumably per-eye drawing that mirrors the roll. How
  minui applies the 21° per eye is [O].
- **Other IAD properties** (odm `:57-58`): `ro.iad.peripheral_warp_factor=0.5706`
  and `ro.iad.display_width_pixels=4128`. Their meaning is [O]; a minui
  layout parameter is a guess [C].
- **`ro.boot.bootloader_ipd_offset=886`** is a static value in v2.7
  `product/etc/build.prop:46` [M-static]. It is a per-model constant, not a
  per-unit one [D]. Its unit is [O].
- **Panel sources vary per unit.** The DT carries `eureka_panel_{boe,jdi,sharp,…}`
  variants (`v27.dts:685-690`), and the bootloader picks one
  (`msm_drm.dsi_display0=meta,eureka_panel_sharp` on Unit 1). Whether the
  roll or the optics differ by panel vendor is [O]. The 21° is not keyed by
  panel [M-static: a single property].

**FOV and resolution (public reference only):**
- Quest 3 per-eye panel 2064×2208 [C, Meta compare-devices page].
- Recommended render target on Link is 2064×2240 [C, hmdgdb].
- Left-eye tangents on Link: L −1.376, R +0.839, B −1.428, T +0.966
  (54°/40°/54.3°/44°) [C, hmdgdb]. The right eye mirrors them.
- Native OpenXR is wider: −56.7°/+42.0°/+46.2°/−57.8° (L/R/U/D) [C, NVIDIA
  forum, §C.3 of the pipeline note].
- Meta's own Link descriptor `/system/etc/xrs-hmdconfig.capnp.bin`
  (760 B, `b68485f7…`) [M-static, read as data only]:
  - it holds 4128×2208, refresh 72/90/120 and per-eye FOV degrees equal to
    the hmdgdb Link values;
  - no roll value was recognisable [D, schema unknown].
- Stock modes: 4128×2208 and 3104×1664 at 72–120 Hz (13 rates each,
  `capture-asleep.txt:8-9`) [M-static].

---

## 2. What a SteamVR / Frame runtime driver needs

### 2.1 The OpenVR driver interface

From `openvr_driver.h` as shipped [M-static].

**`IVRDisplayComponent_003`:**
- `GetRecommendedRenderTargetSize`.
- `GetEyeOutputViewport`: where each eye lands in the output.
  - It carries the **swap**, or the whole-frame 180° is folded into
    distortion (§2.2).
- `GetProjectionRaw`: tangents per eye.
- `ComputeDistortion`: per-channel UV.
  - It carries the **roll**, the **180°** and the lens model.
  - OpenVR has no panel-rotation property.
  - Monado's SteamVR driver does the same thing (pipeline note §C.4).
- `ComputeInverseDistortion`.

**`IVRServerDriverHost`:**
- `SetDisplayEyeToHead` carries the IPD translation. Its rotation stays
  identity (the roll is in-plane).
- `SetDisplayProjectionRaw` and `SetRecommendedRenderTargetSize` allow
  live updates.

**Hidden-area mesh:** `CVRHiddenAreaHelpers::SetHiddenArea`.

**Display properties:**
- `Prop_DisplayFrequency_Float`;
- `Prop_DisplayAvailableFrameRates_Float_Array` and
  `Prop_DisplaySupportsMultipleFramerates_Bool`;
- `Prop_SecondsFromVsyncToPhotons_Float`;
- `Prop_UserIpdMeters_Float`;
- `Prop_DisplayMCImageLeft/Right_String` (mura, optional);
- `Prop_LensCenterLeftU…`.

**Present path.** Two documented choices:
- `IVRVirtualDisplay_002`: the compositor does the distortion and hands
  the driver the finished frame, which we scan out.
- `IVRDriverDirectModeComponent_008`: the driver composites the layers
  itself.

**Either way, our code must make the KMS commit.** SteamVR's own DRM
direct mode would commit one full-width plane, which this SDE driver
garbles above about 1128 px per rect. Stock and stage 3c use 4×1032 rects
(pipeline note §A.4) [D].

**How the Frame does it [M-static, names only]:**
- `/opt/steamvr/drivers/prism` has `"redirectsDisplay": true`, plus
  `bin/linuxarm64/{libprism.so,vrprismhost}`. The Frame redirects
  compositor output through its own path.
- `drivers/frame_hmd` is resource-only.
- The HMD device itself is said to live in `drivers/cv/bin/linuxarm64/driver_cv.so`
  [C, Quest1-SteamOS `docs/steamframe-stack.md`].
- Under J-120 tier 3 we build our own display driver. Reusing prism or
  `driver_cv` on Quest hardware is [O] and unlikely: they expect the
  Frame's display FPGA and EEPROM [C].

### 2.2 Values the FrameShift driver must supply, with sources

Source priority, following the emergency-shutdown §4.5 pattern:
1. Read at runtime from the user's own headset.
2. Measured by us, with the PM.
3. Public reference as the fallback.

Values read from a Meta partition go through the same validated reader as
`fs-metacfg`. Today that reader covers `vendor`; `odm` and `product` would
be an extension of the same read class, which still needs review.

| value | runtime source (preferred) | fallback |
|---|---|---|
| output layout: 4128×2208, two eyes side by side, whole-frame 180° | running DT `qcom,mdss-dsi-panel-orientation`; KMS mode list | constants above |
| eye-to-half mapping (left eye = buffer half 1) | derived from the 180° [D]; confirmed by stage 3d [M pending] | — |
| per-eye roll ±21° (left CCW, right CW in viewer space) | odm `ro.minui.rotation_degrees` − 180 (sign per eye ours) | 21; PM fan test §4 |
| per-unit roll/decenter residual | `/persist/calibration/…` [O; new action class] | 0; PM fan and nonius tests |
| projection tangents per eye | none on-device known; `/persist` [O] | native OpenXR values (§1), then trimmed by PM ring test |
| lens distortion, per channel | `/persist` [O]; else unknown: no public Quest 3 model | measured: grid plus phone camera at the eye box, fitted offline (§4) |
| CAC | see note below | do CAC in `ComputeDistortion` |
| IPD (eye-to-head x = ±IPD/2) | `ro.iad.sysfs_nodes` raw values, via a conversion [O] | 63–64 mm default; user slider |
| refresh | DT/KMS modes 72–120 Hz | 90 Hz (PM default rule) |
| vsync-to-photons | [O]: LCD with pulsed BLU (`meta,max-blu-pulse-overlap-us`, `response-time-curve` in DT) | ≈ 1 frame, measured later |
| render target | from the distortion's centre magnification | 2064×2208 (≈2064×2240 on Link) |
| hidden-area mesh | from the lens-visible region | circle from the PM ring test |

**CAC.** Two signals that Meta does CAC in the display hardware:
- Unit 2 carries `display.enable_ddic_cac=1` and `persist.ovr.global_cac=1`
  (`getprop-all.txt:172`, `:1646`) [M-static].
- The SDE catalog has an SSPP CAC block (`sde_hw_catalog.h:312`)
  [M-static].
So Meta may correct chromatic aberration in the DDIC or the pipe rather
than in the GPU [C]. If the DT on-commands we send leave the DDIC's CAC
enabled, a GPU CAC pass would double-correct [O]. Check: colour fringing
on a white grid, §4.

**Panel and lens move together on Quest 3** (pipeline note §C.2–C.3). So
only the eye translation changes with IPD; FOV, distortion and roll do
not [D].

---

## 3. Meta's per-unit calibration: where, what format, runtime read

**What we know:**
- `persist` is ext4 and mounted at `/persist` (v2.7 vendor
  `/etc/fstab.persist`) [M-static].
- `calibrationserver` (`/system_ext/bin/calibrationserver`, service
  `calibration_svr`, running on Unit 2: `getprop`) owns
  `/persist/calibration` and `/persist/calibration/online`.
  - It wipes `online.tmp` on every boot (`calibrationserver.rc`)
    [M-static].
  - Libraries: `libcalibrationmanager.oculus.so`,
    `libcalibrationstore.so` (also in odm),
    `calibration_manager_ctl` [M-static].
- Other names found:
  - `/persist/calibration/Status_LED_RGB` (light HAL rc);
  - `/persist/calibration/audio/` (`ueventd.rc` firmware path)
    [M-static].
- Meta's runtime APK `VrDriver.apk` (in `com.meta.xr` APEX) ships a
  thrift "sensor calibration IO" library. So calibration files may be
  Thrift-serialised rather than JSON [C].
  - No distortion-mesh asset appears in the APK, `system` or `vendor`.
  - The Quest 1's `system/etc/calibration/distortion-mesh.bin` has no
    Quest 3 counterpart in these partitions [M-static, by name].
  - So the Quest 3 lens model is either compiled in or stored per unit
    [O].
- **Precedent, Quest 1** [C]: `/persist/calibration/display/{left,right}/…_screen_offset.json`
  with `decenter` and `roll` keys; `/persist/IPD_MIN`/`IPD_MAX`. ArmadaVR
  reports "left/right display offset" JSON paths referenced by Meta's
  calibration manager on Quest 3 (pipeline note §C.5).

**Not held:** a Quest 3 persist image exists only on the PM's offline backup drive (the
inventory lists four persist images, the dump inventory (private)),
which this note did not touch. So the Quest 3 display-calibration file
names are [O].

**Feasibility:**
- *Names only, under stock Android.* [removed for publication]
- *Contents, under Android.* Reading per-unit calibration bytes is a new
  data class. Treat it as Chair-level, even though it is a read.
- *At runtime under FrameShift.* Mounting Meta `persist` (ro, `noload`)
  from our image, or parsing it with an `fs-metacfg`-style ext4 reader, is
  a **new action class for the Chair**:
  - `persist` has so far been "never mounted from Linux" (RESEARCH_NOTES
    rule; JOURNAL "Do not go here" item 16).
  - If approved, use the §4.5 pattern: parser-only and read-only, the
    block device opened `O_RDONLY`, a known-format table, fallback on any
    doubt, and nothing copied into the repo.
- **FS-R-001 / writer inventory reminder.** Valve's `restore-calibration`
  (`valve-writer-inventory.md` P2) runs `mke2fs` on whatever is mounted at
  `/persist`. FrameShift must never mount Meta's persist at `/persist` in
  a Valve userspace.
  - Any Frame-format `device_config.json` we provide must live on a
    FrameShift-owned store.
  - The path is the Frame fstab's `PARTLABEL=syspersist` →
    `/persist`, ro. No Quest partition carries that label [D].

---

## 4. Plan

### 4a. Measure and validate the angle and the swap with our test pattern

Each step fits the existing stage 3d run discipline: reviewed brightness
bounds, single readings, and one image per run. Steps 2–4 are pattern
variants that need review first.

1. **Stage 3d as built** (v0.7, `eyes=swap roll=21`). Expected result:
   - every character reads upright in the correct eye;
   - centre lines look level;
   - the eye markers match.

   Record "level / tilted CW / tilted CCW" per eye, one eye closed at a
   time.
2. **Protractor fan, per eye (angle to about 1°).**
   - Around each eye's optical-centre estimate, draw 9 short horizontal
     strokes.
   - Each stroke is pre-rotated by roll + k°, for k = −4…+4.
   - Each stroke carries a chiral label (bar count 1–9) and keeps
     |roll + k| ≤ 25, the current mixer bound.
   - The PM, head upright and one eye closed, names the stroke that looks
     level.
   - Answer = 21 + k per eye. A second run at half-degree offsets gives
     about 0.5° if needed.
3. **Binocular nonius (relative roll between the eyes).**
   - The left eye sees the left half of a long horizontal line and the
     top half of a vertical line.
   - The right eye sees the complementary halves.
   - A residual opposite roll shows up as a kink or vertical offset at the
     line ends. Ticks let the PM read the offset; vertical misalignment
     (dipvergence) is checked too.
4. **Lens centre and FOV rings.** Concentric numbered rings about the
   estimated optical centre in each eye. The PM reports the last fully
   visible ring at left, right, top and bottom. This gives per-side FOV in
   panel pixels, so first tangents via the model.
5. **Distortion and CAC.** Show a straight-line white grid.
   - The PM reports curvature and colour fringes. Fringes with no GPU CAC
     would mean the DDIC/SDE CAC is not active; their absence leaves it
     open.
   - The robust step comes later: a phone camera at the eye box photographs
     the grid through each lens (PM-run). We then fit a per-channel radial
     model offline.
6. **Stability.** Repeat step 2 on Unit 2 (v2.7). Per-unit variation then
   shows directly: same model, two units.

### 4b. Driver data and sources

See §2.2. In short:
- **Runtime first:**
  - DT and KMS: modes, refresh, 180°;
  - odm/product props: roll 201−180, IAD nodes;
  - IAD raw sensors: IPD;
  - `/persist` calibration: per-unit, only after a Chair ruling.
- **Then PM-measured values:** roll residual, FOV rings, distortion fit.
- **Public fallback:** hmdgdb and NVIDIA-forum tangents, 21°, 2064×2208.
- **The driver plumbing:**
  - the eye swap and whole-frame 180° go into the output mapping;
  - the roll, 180° and lens model go into `ComputeDistortion`;
  - the IPD goes into `SetDisplayEyeToHead`, translation only;
  - our KMS 4×1032 commit does the scan-out.

### 4c. Open questions [O]

1. Exact optical roll per unit, and whether Meta stores a per-unit roll
   (fan test; `/persist` names).
2. How minui and the bootloader mirror 201 per eye under `split_panel`.
   Can a recovery screenshot settle it? Read-only.
3. The Quest 3 lens distortion model and coefficients. No public source;
   possibly in `/persist` or compiled into `libvrruntimeservice.so`
   (which we do not disassemble).
4. The IAD raw-to-millimetres conversion: which calibration, and its
   units. The meaning of `bootloader_ipd_offset=886` and
   `peripheral_warp_factor=0.5706`.
5. Whether DDIC CAC is on after our DT-driven panel enable.
6. Whether the per-panel-vendor variants (BOE/JDI/Sharp) differ in
   optics or roll.
7. The Frame `device_config.json` schema. It can be learned only by
   observing Valve's software on our side (J-120: no disassembly).
8. Quest Pro roll from its own firmware (no Pro OTA held).
9. `com.meta.quest.apex` could not be dumped from odm. Not needed here.

---

## 5. Boot splash

**How the Steam Frame draws it [M-static, names and structure only]:**
- **No Plymouth.** Nothing in the rootfs; KDE's KSplash is the desktop
  session's.
- **Stage 1, U-Boot.**
  - Valve's U-Boot (`/boot/uboot_{ev3,dv1,dv2,mp}.img`) has a
    `deckard_logo` command ("Show Deckard logo").
  - It loads pre-warped images from the ESP: `logo.bmp.gz`,
    `logo_battery_low.bmp.gz`, `logo_console.bmp.gz`,
    `logo_error.bmp.gz`, `logo_usb.bmp.gz`, plus `splashpos`.
  - It also loads `default.vrfont` / `default.vrterminal` for lens-correct
    text (strings in the GPL U-Boot image).
- **Generation.** `deckard-boot-images.service` (multi-user) runs
  `/usr/lib/deckard-boot-images/predistort_images.sh`, which:
  - composes each logo over a background;
  - runs SteamVR's `vrcalib` with built-in Frame defaults, the per-unit
    `/persist/device_config.json` and a fixed virtual image pose (a quad
    about 2 m ahead);
  - writes the predistorted per-eye BMPs to `/esp/efi/SteamOS`;
  - also builds a pre-warped terminal mesh and font, packed as a
    `vrfonts.img` initrd fragment and by the `deckard_fw` initcpio hook;
  - regenerates only when the hashes of its inputs change: images,
    `device_config.json`, `vrcalib`.
- **Stage 2, kernel.** `CONFIG_DRM_CLIENT_VRCONSOLE=y`, default DRM client
  `vrconsole` (Frame kernel config). Valve's in-kernel DRM client draws a
  lens-correct console from those two firmware files (`drm_vrconsole`,
  `VRTerminalPoint_t` in the kernel strings). The Frame kernel's source is
  not public [O].
- **Then the SteamVR session.**

The layout is therefore lens-aware and per-unit. The panel geometry
(two 2160×2160 panels, no rotation in the DT) is applied by `vrcalib` at
generation time, not by the bootloader [D].

**What Meta's bootloader does on the Quest 3:**
- ABL/UEFI draws the Meta logo itself.
  - The `splash` partition on Unit 1 is all zeros (34 MiB,
    `firmware/quest3/unit1_nonslotted/splash.img`) [M-static].
  - So the logo is built into the firmware [D].
  - ABL bootloader UI uses the 201 rotation, i.e. 180° plus 21° roll
    (v66 `bootloader_screen_rotation`) [M-static].
- **Installed boots.** ABL leaves the logo lit, and the kernel's
  continuous-splash handoff keeps that frame until the first commit (J-126;
  `display-handoff-dark.md` §3). How long it stays lit (ABL → kernel →
  our first commit) is **unmeasured [O]**. Measure it on the first installed
  boot from boot-log timestamps plus the PM's stopwatch.
- **`fastboot boot`.** The screen goes dark at the boot command (J-126).

**What FrameShift needs for a correct splash on the Quest 3 [D]:**
1. **No U-Boot stage** (deferred, FS-R-001) and no Valve `vrconsole` in
   Meta's 5.10 kernel. The Frame's stages 1–2 have no Quest equivalent.
   - Meta's logo shows first and cannot be replaced (ABL stays Meta's).
2. **Our own early splash.** A small initramfs KMS client from the
   fs-pattern lineage, which:
   - takes over the ABL frame **without a modeset** (no-modeset plane
     swap, J-127) using the 4×1032 rect layout;
   - draws per-eye images with the whole-frame 180°, the eye mapping
     (left eye = buffer half 1) and the ±21° roll;
   - adds lens predistortion once a model exists (§4.5). Until then it
     draws an undistorted small logo near each optical centre, which is
     acceptable at small angles.
3. **Predistort offline, like Valve.** Generate the per-eye splash images
   at install/update time from our geometry record (§2.2). Use our own
   tool: we neither ship nor call `vrcalib`. Store them on a
   FrameShift-owned partition and regenerate on a hash change, the same
   pattern as `predistort_images.sh`.
   - A per-unit residual applies only if a Chair-approved `/persist` read
     exists.
4. **IPD for disparity.** The splash is a quad at finite depth, so each
   eye's offset depends on IPD (as `vrcalib` uses the device config).
   - Read the IAD raw value at boot.
   - Or draw at optical infinity: per-eye images centred on each optical
     axis, which needs no IPD [D].
5. **In a Valve userspace.** `deckard-boot-images.service` writes to the
   ESP, which the Quest lacks; it is already blocked (writer inventory
   B14). Our splash generator replaces it.
