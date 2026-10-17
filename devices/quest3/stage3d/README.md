# Quest 3 stage 3d: the stage-3c display test on Unit 2's own v2.7 (device side)

**Status (2026-10-14, J-144/J-146): `fcca5ee7…4fb5` ran on Unit 1 and its nonce-only rebuild `46b28f01…c06b` on Unit 2;
both registered STAGE PASS; both nonces are spent. The status text below is earlier and kept as written.**

**Status (2026-10-14, J-141): fs-pattern v0.7.1 (the mode limit, §3a) and a NEW CANDIDATE image for Unit 1
(`IMAGE.md` §0: `fcca5ee7…4fb5`, nonce `<attempt nonce withheld>`; the v0.7 candidate `3d730337…` refused safely on Unit 2 and its nonce is spent; the first v0.7.1 build `96cc15aa…` was superseded before any boot). Earlier status
(2026-10-13): built and fixture-tested offline; CANDIDATE image only. Reviews A (fs-pattern)
and B (image) of the first candidate (6c7f726) were GO-with-fixes; this rebuild folds in their fixes and
the PM decisions J-129 (modules, backlight). Nothing was booted; no adb, fastboot or COM port was used.** The image and its
evidence: `IMAGE.md`. The host side (Unit 2 serial, user-build capture rows, the new r1 semantics) is
adapted separately; §6 lists exactly what it must change. *(2026-10-13: the host side is implemented for BOTH units in
`HOST.md` (branch `feat/stage3d-host`); the PM's steps are `WALKTHROUGH.md`, the checklist reference `../SIGNOFF-3d.md`.)*

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C] hypothesis · [O] open.
Fixture runs are [D] evidence (qemu-user, bwrap, WSL), not [M].

## 1. What stage 3d is

The stage-3c run (`../stage3c/`, DESIGN.md rev 3; STAGE PASS on Unit 1, J-125), rebuilt for **Quest 3
Unit 2 on Horizon OS v2.7** (build `52433670036000520`, kernel `5.10.246-gd7102a837402`, user build,
slot a), with these PM changes (2026-10-13; J-129):

1. **Run 1 is a non-lit DISPLAY RESET** instead of the lit run 1 of stage 3c.
2. **The run-2 picture is drawn per EYE**: the eyes are swapped and each panel is pre-rotated against
   its inward cant (J-125: bars 3,4 were seen in the left eye; left content turned clockwise, right
   counter-clockwise).
3. **Modules: the proven v66 set only** (J-129): stage 3c's 97 minus `debug-regulator` and
   `qti-regmap-debugfs` = **95**, loaded from our own list `/lib/fs/modules.load`
   (`modules.load.v66`); none of the 36 v2.7-only modules loads (§5).
4. **Backlight:** `backlight_changes_blocked` is left as the driver sets it; nothing writes it (§7).

**init.sh differs from stage 3c in three places:** the product string `FrameShift stage3d`; the module
loop reads `/lib/fs/modules.load` instead of the vendor's `modules.load.recovery`; and before any
module loads it checks the SHA-256 of the device's `/lib/modules/modules.dep` and `modules.softdep`
against pins (image review B): on a mismatch it fails closed (no module at all, stages
`MODULES_REFUSED` + `ERROR_modules`, reboot `error-modules` at T0 + 60 s). What the PM would see then:
no `FS-<nonce>` gadget (the USB controller driver is a module) and no LED (also a module); the
collector times out and the unit is back in fastboot about 60 s after the boot.

Everything else is stage 3c: the PID 1 deadline 200 s / backstop 201 s, the ACM gadget, fs-verify /
fs-ack / fs-status, the one backlight write 127 (p0), the probes (`fs-probe.sh` as stage 3c's except one dmesg filter, §3a), the
idle limit (`fs-idle.sh` byte-identical), the per-phase protocol and its timing (PHASE_WORST
23/38/47/39, MAXLINES 360/1545/1545/945, guards 34/68/82/64), run 2's 4 planes x 1032 with zpos
{0,0,1,1}, run 3's red field, the paced FSB1 emission, the common helpers.

| phase | stage 3d | lit |
|---|---|---|
| p0 | as stage 3c (hash of `/bin/fs-pattern`, probe0, THE backlight write 127) | no |
| r1 | probe1, then `fs-pattern reset <c1[0:8]>`: the display reset (§3) | **no** (black only) |
| r2 | after the 2 s pause: `fs-pattern show-off-quad <c2[0:8]> 10 /dev/dri/card0 roll=21 eyes=swap`; inactive CRTC required (exit 31), split probe (TEST_ONLY only), quad_vig, quad_dma | 10 s |
| r3 | only if the host's run-3 rule holds: `show-off-solid <c3[0:8]> 5` (red field) | 5 s |

## 2. Inputs: Unit 2's own stock v2.7 files (IMAGE.md "Inputs")

- `firmware/quest3/v2.7-user_ota/{boot,vendor_boot,vbmeta,vbmeta_system,dtbo}.img`, extracted from the
  official full OTA `q3_52433670036000520.zip` (sha256 `e4c57710…2e04`): each equals the payload
  manifest's `new_partition_info` (size and SHA-256) [M-static, `provenance/ota.txt`].
- **Match with Unit 2's running build:** the vbmeta digest computed from the OTA's `vbmeta.img` +
  `vbmeta_system.img` (2 structs, 8768 bytes) is `66b76196…9f12a`, exactly Unit 2's runtime
  `ro.boot.vbmeta.digest` and `ro.boot.vbmeta.size` = 8768; `boot.img`, `vendor_boot.img` and
  `dtbo.img` match their hash descriptors in that vbmeta [M-static vs M, `provenance/avb.txt`,
  `provenance/runtime.txt`]. Corroborating runtime facts [M]: the kernel release string, the
  vendor command line in `/proc/cmdline`, `ro.boot.load_modules_parallel=true` (only in v2.7's
  bootconfig), `ro.bootimage.build.date.utc` = the OTA timestamp.
- Caveat [D]: AVB's hash descriptors are not enforced at boot on these units, so
  "the slot holds exactly these boot/vendor_boot bytes" is derived from the digest plus the runtime
  facts, not read back. The OTA payload's own signature was not verified (no Meta OTA key here).
- `build-image.sh` pins all five hashes, the kernel (`db61c073…`, release string checked), the module
  list and the vendor file list, and runs `tools/avb-check.py` on every build (refusal if the digest is
  not Unit 2's).

## 3. Run 1: the display reset (fs-pattern v0.7 `reset`)

**Source finding [M-static, kernel `dbc2bc83a`, the v66 tree identical here; research 2026-10-13]:** a
first commit with ACTIVE=0 on the handed-over splash CRTC disables it, but it is **not** a reset: the
DSI side keeps `is_cont_splash_enabled` (cleared only on the enable path, `dsi_display.c:9225`,
`dsi_drm.c:253`), so the disable skips the panel off-commands, `dsi_panel_unprepare` and the power-off
(`dsi_display.c:9458/9603/9642`), the SDE splash resources are not released while the CRTC is
inactive (`sde_kms.c:1313`), and the next enable would again take the splash skip path (no panel-on:
dark, as run 1 of stage 3c). lastclose does nothing either while a splash display is still counted
(`msm_drv.c:1112-1121`). ACTIVE=0 + MODE_ID=0 without detaching the connector is refused by the DRM
core (`drm_atomic_helper.c:674`); FB_ID=0 needs CRTC_ID=0 (`drm_atomic.c:561`).

So the reset is three steps in one process (only the commit class of stage 3c: atomic properties
ACTIVE, MODE_ID, CRTC_ID, FB_ID and plane geometry; no new property id, no new ioctl):

| step | request | effect [D] |
|---|---|---|
| A `reset_off` | connector CRTC_ID 0, CRTC MODE_ID 0 + ACTIVE 0, every plane bound to the CRTC FB_ID 0 + CRTC_ID 0 (only the value 0); TEST_ONLY, then one commit (ALLOW_MODESET) | the CRTC inactive without a mode |
| B `reset_on` | the v0.5 modeset attempts (single, then split, `plan_attempts(0, …)`) on an **all-black** buffer, MODE_ID = the handed-over 4128x2208@90 mode, ACTIVE 1; TEST_ONLY, the first accepted committed once | the enable path on the splash flags: no panel-on (the panel stays asleep, as stage-3c run 1), and it clears the DSI splash flag and releases the SDE splash |
| close | `close(fd)` at once, no hold | lastclose (no splash left) disables everything through the full off path, so run 2 gets the complete power-on |

B is planned before A is sent (a modeset attempt and the mode must exist; else nothing is committed).
Only black is ever scanned out by `reset`; a CRTC that is already provably inactive is left alone
(exit 0, `already_inactive`). Run 2 keeps its own precondition (exit 31 on an active CRTC) and the
bounded 2 s pause after r1. Exit codes are v0.6's (0, 31 state unreadable, 30, 40, 50, 60).

**Observed on v2.7 (J-144, J-146; FS-A-012 §5.3 item 1) [M + D]:** step A logs two kernel `WARNING … drm_atomic_helper.c:229
set_best_encoder` traces (its TEST_ONLY check and its commit): Meta's `sde_connector_atomic_duplicate_state` clears the
continuous-splash connector state's crtc but keeps `best_encoder`, and detaching the connector then trips the WARN_ON. Step A
disables the CRTC (`sde_crtc_disable`) but not the DSI encoder, and the stale encoder mask keeps the clock votes up. B's first
(single-plane) TEST_ONLY is rejected with -7 as planned. TE stayed 0 through r1; run 2 lit on both units. The classifier
does not flag dmesg in r1. Whether to drop step A is open (FS-A-012 ask (h) 4).

## 3a. fs-pattern v0.7.1: the mode limit (J-141)

**What happened [M]** (Unit 2, v2.7, nonce `<attempt nonce withheld>`, 2026-10-14 00:51Z): r1's `fs-pattern reset` logged the
connectors 33 (Virtual, type 15, 37 modes), **55 (DSI, type 16, 305 modes)** and 65 (DP, disconnected, 0 modes), then
`chosen_connector rc=-7 id=55` and `exit code=30 reason=too_many_modes`: v0.7's `MAXMODES` was 128. Nothing was set or
committed (a safe refusal); r2 was skipped (`run1-supervisor`).

**Cause [M-static + D]:** v2.7's panel node (`meta,eureka_panel_sharp`) has max refresh 240 (v66: 120) and **no step
sizes** (v66: 5, 24), so `dsi_panel_parse_dfps_range` lists every rate 240..72 (169; v66: 12). The driver builds one mode
per rate and timing node (2 nodes, dms-vid-seamless): **338**. For timing@0 at 208..240 Hz the VFP recomputation goes
negative (refused, the mode keeps VFP 2918) and `htotal * vtotal * rate` overflows 32 bits, so those 33 modes get a
vrefresh of 17..49, are not found by `dsi_conn_mode_valid` and are pruned (Unit 2's dmesg: "could not find mode
4128x2208x17..49vid", informational): **305** listed = 136 at 4128x2208 + 169 at 3104x1664. `tools/v27-modes.py` computes
this list from the DT the way the driver does; with v66's DT values the same model gives exactly the 24 mode records
logged in stage 3c's run (validation). v66 listed 24, so stage 3c passed. The mock model never had more than 24, and no
review compared the limit with v2.7's real count (J-141 lesson).

**v0.7.1 (the only changes; `tools/check_delta071.py`: the device build is v0.7 plus exactly these):**
- `MAXMODES` 128 → **512** (a static array; also holds 2 nodes x 240 rates = 480; a compile-time guard requires >= 480).
  More than 512 is still refused with exit 30 `too_many_modes` (mock scenario `reset-toomany`).
- Mode records: essential below 24 (as before), optional below `FSP_LOG_MODES` 48 or for an expected 4128x2208@90 mode;
  every other mode is not logged and is counted in `eos opt_skipped` (v2.7: 257). `opt_skipped` therefore counts two
  kinds of record: mode records **left out by design** (here) and optional records **dropped by the budget** (only after
  one `step=opt_budget` record). On v2.7 there is no `opt_budget` record and `opt_skipped` = modes - mode records (305 -
  48 = 257); a non-zero `opt_skipped` alone is not a lost record (`HOST.md` §2 item 12, test-host3d E3). Without this, 281 optional mode records
  would use up the 38912-byte optional budget before the property logging. The essential bytes and the stream bounds are
  unchanged (PHASE_WORST, MAXLINES, guards unchanged).
- The mode policy is unchanged. On v2.7 exactly ONE mode is 4128x2208 @ 90 Hz (index 0, PREFERRED, the v66 timing: clock
  2020285 kHz, htotal 4352, vtotal 5158); the near-duplicates (4128x2208 @ 89/91, 3104x1664 @ 90) are not expected modes.
  r1 (reset, the splash CRTC active) uses the handed-over mode when it is that mode and in the list
  (`crtc_current_expected`), else the first expected mode in the list; r2/r3 (CRTC inactive) take the first expected mode.
  Both resolve to the same timing (mock scenarios `reset-v27`, `quad-v27`; with the expected mode at index 250 behind
  near-duplicates: `reset-v27-late`, `quad-v27-late`). If a list ever held two different 4128x2208@90 timings, the first
  in list order would win (not the case on v66 or v2.7).

**Every fixed limit, audited against v2.7** (v2.7 kernel source 5243367.3600.520, the merged v2.7 DT, the stage-3c v66
records in FS-A-012 (private review record)):

| limit (fs-pattern) | v66 observed | v2.7 expected max | v0.7.1 |
|---|---|---|---|
| `MAXMODES` (chosen connector's modes) | 24 | **305** listed (338 built) | **512** (was 128) |
| `FSP_ESS_MODES` (essential mode records) | 24 | 305 modes → 24 essential | 24; + `FSP_LOG_MODES` 48 (new) |
| `MAXOBJ` (CRTCs, connectors, encoders, fbs, planes, connector encoders) | 3, 3, 3, 0, 20, 1 | the same (same SSPP DT: 4 VIG + 6 DMA, 20 planes) | 64 |
| `FSP_ESS_CONNECTORS` / `FSP_ESS_PLANES` | 3 / 20 | 3 / 20 | 3 / 20 |
| `MAXPROPS` (properties per object) | connector 24, CRTC 38, plane 32-36 | driver enums 33 / 29 / 45 plus DRM core and colour properties; CRTC +1 (`freerun_histogram`) ≈ 39 | 128 |
| `MAXFMTS` (plane formats) | ≤ 61 tokens in the VIG caps blob | the same catalogue | 512 |
| enum names read (`en[64]`) | topology 15 | 15 | 64 |
| `FSP_BLOB_MAX` (blob read) | plane caps ≤ 870, connector caps 366, mode_properties 5473 | caps the same; mode_properties ≈ 305 x 228 ≈ 70 KB → one length-only record (logging only) | 8192 (bounded by the stream review) |
| `MAXAOBJ` / `MAXAPROP` (request) | quad ≤ 26 objects / ≤ 79 properties | the same | 64 / 320 |
| `FSP_OPT_MAX` (optional bytes) | 27012-30479 used | v0.7: spent on mode records; v0.7.1 mock 19771-23805 | 38912 |
| CRTC index (`possible_crtcs` bits) | 3 CRTCs | 3 | 32 |
| `LINE_MAX_B` (record) | ≤ 260 B | the same | 1024 |

**fs-probe.sh (the one change vs stage 3c, J-141):** every connector probe on v2.7 writes 66 informational lines
(`dsi_conn_mode_valid` "could not find mode 4128x2208x17..49vid" and `dsi_display_find_mode` "failed to find mode for
v_active ..."; Unit 2's probe1 post showed 29 of them and nothing else). The probe's dmesg section no longer keeps
them: one line per point gives their count (`-- dmesg: N mode-validation line(s) not kept (...)`), so the panel/DSI/
backlight lines stay within the 80-line / 4096-byte budget. Everything else in fs-probe.sh is unchanged. Fixture
`tools/probe-dmesg-check.sh`: 66 such lines around 5 real display lines: the 5 are kept in order, the count is 66, a
later point counts 0; stage 3c's probe (negative control) loses 3 of the 5 to the byte budget.

The 4 x 1032 layout, the reset and the picture are untouched. Fixtures: `fixtures/RESULTS.txt` section (j) and the six
`sim-*-v27`/`-toomany` scenarios; the negative control `build/fs-pattern-unittest-maxmodes128` (v0.7's limit with the
v2.7 mock) fails exactly as Unit 2's r1 did (records 4-9 equal).

## 4. The per-eye picture (fs-pattern v0.7)

- Each eye is drawn in its own viewer coordinates into an eye canvas, pre-rotated, rotated 180° (as
  v0.6) and blitted into the buffer half that reaches that eye. Integer only (a Q16 sine table, floor
  division), nearest neighbour: the levels stay exactly 0x80 / 0xFF.
- **`eyes=swap`** (default): the LEFT eye is buffer half 1 (x 2064..4127) [PM report, J-125];
  `eyes=direct`: half 0, as v0.6.
- **Formulation (geometry research, `docs/research/display-geometry-stereo.md`):** the "eye swap" is the
  180° mount applied to the WHOLE 4128-wide frame. The code uses the per-half formulation (each eye's
  half rotated 180° in place, as v0.6, with the halves swapped); that is the same mapping as one
  180° rotation of the whole frame [left-eye design | right-eye design]: buffer (x, y) ↔ viewer
  (4127 − x, 2207 − y). Fixture `whole-frame-180-equivalence`: at roll 0 the C render equals the
  whole-frame 180° of the two designs placed side by side, byte for byte. The roll is applied before
  it, in each eye's viewer frame, about the eye centre (in-plane, about the viewing axis).
- **`roll=<deg>`** (default **21**, -25..25): the left eye's content is pre-rotated counter-clockwise,
  the right eye's clockwise (as the viewer sees it), as briefed. 21° is Meta's design value: in the
  v2.7 odm build.prop the comment above `ro.minui.rotation_degrees=201` explains it as 21 + 180
  (research note above; also `ro.boot.bootloader_screen_rotation=201`). The direction is the PM's
  J-125 report. Both are arguments (fs-phase.sh constants `ROLL`, `EYES`); a negative roll reverses the
  direction. (The fs-pattern.c comment still tags 21 as [C]; the source was not changed after the
  research so the candidate stays the built one.) Rotation centre = the eye canvas centre; the lens
  axis is nasal/high of it [C], which does not change the angle.
- **Not added (later practice-run pattern):** per-eye angle reference strokes (a short fan at
  17/21/25° or a horizontal reference line) to judge "level"; they would change the reviewed picture
  and its white budget, so they are left for a later practice-run pattern.
- **Bars per EYE**: left eye "1 | 2", right eye "3 | 4" (F above each group). Mixer map: swap LM0 4,
  LM1 3, LM2 2, LM3 1 (direct: 2, 1, 4, 3 as v0.6). In the v0.7 layout the quadrant groups sit at
  q = (ew − 2·M_X)/3 and 3u below the centre line, so each group stays inside its own mixer for
  |roll| ≤ 25 (≥ 22 px clearance; checked on renders).
- **`roll=0 eyes=direct` reproduces the v0.6 picture byte for byte** (fixture: equal to the stage-3c
  binary's own render for three nonces). White 2.64–3.09 % for the fixture nonces (worst `bbbbbbbb` 30884 ppm),
  mean ≤ 131.92/255: inside the reviewed v0.5/v0.6 envelope (37618 ppm, 132.777).
- Previews (`fixtures/preview/`): `pattern-v0.7-3f9c07ab-scanout-4128x2208.png` (the buffer),
  `-panels-1032x552.png` (each panel, 180° undone, left eye | right eye: the pre-rotation visible),
  `-asseen-1032x552.png` (the expected view if the cant is as reported: upright and level),
  `-mixermap-…`, `-digits-left.png`; `F-reference-u-i-m-v.png`; `solid-red-v0.7-viewer-…`.

## 5. v2.7 differences found (IMAGE.md "Display assumptions", "Modules")

- **Display DT: unchanged where the layout depends on it** [M-static, `provenance/dt.txt`]: Unit 2
  uses dtb 0 + dtbo 11 (PVT1.1); that overlay is byte-identical to Unit 1's dtbo 10. Panel
  `meta,eureka_panel_sharp` (chosen at run time, `/proc/cmdline`), timing@0 2064x2208 per link,
  HFP 38, HBP 54, HPW 20, VFP 2918, VBP 30, VPW 2, 90 Hz → mode 4128x2208@90; topology <4 4 2>, DSC
  8 bpc/8 bpp, slice 1032x32, 2 per packet, `disable-default-pps`; MDP `clock-max-rate` 550 MHz;
  4 VIG + 6 DMA, smart-DMA priority as v66, blendstages 11 (zpos max 10), pipe-order v1, no
  `meta,swap-mixers`. So 4 x 1032 with zpos {0,0,1,1} still holds; the SDE plane/caps/zpos/layout code
  is unchanged v66 → v2.7 (research). fs-pattern discovers the planes at run time anyway.
- **Changed in the DT** (none affects the commit): `qcom,mdss-dsi-panel-orientation = "180"` (only
  reported in the connector capabilities blob, never applied in hardware: `dsi_drm.c:838-854` is
  its only user); panel on/off command delays (sleep-out wait 120 → 84 ms, display-on 120 → 0 ms, off
  120/250 → 0/56 ms) and batch flags; max refresh 120 → 240, no step sizes; `meta,ddic-family`;
  `meta,freerun-histogram` (a read-only CRTC histogram blob).
- **New in the v2.7 driver (PM: leave it, §7):** Tokki-A panels start with
  `backlight_changes_blocked = 1` (`dsi_panel.c:3919`); the BLU pulse/temperature programming returns
  early until `/sys/class/drm/card0-sde-crtc-0/backlight_changes_blocked` is written (Android does it
  "when bootanim is done"). Nothing in our image writes it.
- **Modules:** v2.7's `modules.load.recovery` (= `modules.load`) has **131** modules (v66: 97): +36,
  −2 (`debug-regulator`, `qti-regmap-debugfs`). The display/USB/backlight/LED/fan closure is the same
  44 modules (v66: 45 incl. debug-regulator). The additions are ADSP remoteproc/audio (adsp_loader,
  qcom_q6v5_pas, q6_*, spf_core, gpr, snd_event, frpc-adsprpc, smp2p), charger (qti_battery_charger,
  external_battery, charging_dock), thermal (qcom_tsens, qcom-spmi-temp-alarm, qcom-spmi-adc5-gen3,
  bcl_pmic5, bcl_soc, qti_qmi_sensor_v2, qti-ocp-notifier), sensors (ak09973, as5510), usbvdm, qcom_lpm,
  userspace-consumer (all vermagic `5.10.246-gd7102a837402`).
  **PM decision J-129: stage 3d loads the proven v66 set only.** `modules.load.v66` = stage 3c's v66
  `modules.load.recovery` minus the two debug modules, in v66 order: **95** modules
  (`1b93d77d…463f`), resolved against the v2.7 module files. The builder pins it and runs
  `tools/module-list-check.py` on the v2.7 vendor modules: every entry is present; the list is closed
  under `modules.dep` and `modules.softdep` (as init.sh resolves them), so init.sh can never pull in a
  module outside it; the display/USB/backlight/LED/fan closure (44) is inside it; and (check 5,
  independent of the list) none of a fixed forbidden set of 38 (the 36 v2.7-only modules plus the two
  v66 debug modules) is in the list or reachable from it. A later addition fails even if the list is
  re-pinned. Check 4, "no excluded vendor module reachable", is relative to the list and is not an
  independent guarantee (review C MINOR-1). The comment in init.sh's module block still says
  "Meta's recovery set". It is left unchanged so that the image stays byte-identical for this
  candidate (review C MINOR-2). Versus the first candidate (6c7f726, 131 = the vendor list): −36 (the list
  above), nothing added. `modules.dep` / `modules.softdep` stay the vendor's, pinned in init.sh.
- **Boot image:** v2.7 stock `boot.img` is header v4 with signature size 0 already, so the only header
  difference is `ramdisk size`; os_version 14.0.0 and patch level 2026-06 are copied from it.

## 6. What the host side must change (interface; the host agent implements it)

1. **Image and MANIFEST:** `boot-stage3d.img`; title `FrameShift Quest 3 stage-3d image (`; build root
   `build\stage3d\`; sources `init.sh source`, `fs-phase.sh`, `fs-probe.sh`, `fs-idle.sh` of
   `stage3d\`; stock baseline (Unit 2 slot a): boot `e32f98c7…c024`, vendor_boot `bc0dd14d…2f5b`;
   new MANIFEST lines `vbmeta`, `vbmeta_system`, `vbmeta digest`.
2. **Gadget:** serial `FS-<nonce>` (unchanged), product `FrameShift stage3d`. Unit 2's fastboot serial
   instead of Unit 1's default.
3. **Verb table unchanged** (`^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z`); FSPM1, FSXE1, FSK1, FSB1
   grammars unchanged; step names unchanged (hash, probe0, probe1, pattern1, …).
4. **FSB1 record type `exp=s3d_<ph>`** (was `s3c_<ph>`).
5. **r1 is not lit:** markers begin, go, end, rec as before, but no "lit" banner/sound semantics, no
   per-eye readings, no dark check after r1 (the host may show "display reset (dark)"). **Keep ONE r1
   observation question** (fs-pattern review A, PM): "Anything visible during the reset (r1)? y/n";
   the answer is recorded, never gated. The r1 record
   (`pattern1`, `mode=reset`): `reset_precondition` (state active|already_inactive|unknown),
   `chosen_mode`, `buffer … black=1`, `reset_plan`, `test_commit` with `layout=reset_off`, then
   `reset_on_single` / `reset_on_split`, two `commit` records (attempt 0 `reset_off`; attempt 1|2
   `reset_on_*`), two `post_state` (active 0 then 1), `post_plane` (≤ 4 after A, 1–2 after B),
   `reset_close close_rc=… close_ms=…`, `exit code=0 reason=reset_done|already_inactive shown=0`;
   failures `code=50 reason=reset_off_rejected|reset_on_rejected|no_reenable_attempt`, `code=60
   reason=reset_off_failed|reset_on_failed`, `code=31 reason=crtc_state_unknown`. Suggested classes:
   R1 RESET-DONE / ALREADY-INACTIVE / RESET-NOT-DONE (never "SHOWN").
6. **r2 skip reasons now:** `p0-write-missing` (r1), `probe-late`, `brightness-not-verified`,
   `run1-not-run`, `run1-supervisor` (any nonzero reset exit lands here), `run1-not-reset`,
   `run1-stream`, `pause-fault`. No longer produced: `run1-no-accepted-commit`, `run1-close-not-clean`,
   `run1-exit`. r3's run-2 reasons are unchanged.
7. **r2 readings per EYE:** the start record carries `roll=21 eyes=swap`; expected left eye "1 | 2",
   right eye "3 | 4", F upright, text and centre line level. Seeing 3|4 in the left eye means the swap
   assumption is wrong; a remaining tilt (and its direction) means the roll is wrong. The classifier's
   mixer map for eyes=swap: LM0 4, LM1 3, LM2 2, LM3 1.
8. **Integrity pin** (collector p0 check, classifier): `/bin/fs-pattern` = `bfafad97…9a9a` (v0.7.1, J-141; v0.7 was
   `7c9fa98c…0674`).
9. **Timing unchanged:** PHASE_WORST 23/38/47/39 and the guards G 34/68/82/64 still hold
   (`tools/check-timing-3d.py` CONSISTENT, cross-checked against the 3c host constants). If the host
   drops the r1 human window (H_r1 20 s, no readings now), G_r1 and the per-phase limits must be
   recomputed and `DESIGN_G`/`DESIGN_LIM` in `check-timing-3d.py` updated with them.
10. **Replay fixtures:** `fixtures/image/<scenario>/capture.raw` + `.idx` for the host replay tests
    (27 scenarios; `c-sim-reset-fail` replaces `c-sim-unclean`; `c-modules-real` and
    `c-modules-refused` are new; `c-modules-refused` has no shell: the host sees no gadget).
11. **Fail-closed module refusal** (no gadget, no LED, back in fastboot ~60 s after the boot): the
    collector should classify a missing gadget followed by fastboot at ~T0+60 s as "module index
    refused (wrong build?)" in its notes; the distinct reason is only in the device's RAM log.

## 7. Open items (for the review and the PM)

1. **backlight_changes_blocked** (§5; PM decision J-129: leave it alone): the image never writes it
   (the builder refuses any script that names it outside a comment). With it set, the BLU timing stays
   as the DDIC/pre-on set leaves it [C], so **run 2 may be dim or dark** (or differently timed). Expected
   handling: a dim or dark run 2 leads to a follow-up build (then the unblock write would be proposed as
   a new write class).
2. **The reset's step B** relies on the source reading that an enable from the splash flags sends no
   panel-on and clears them [D]; it reuses stage 3c's run-1 commit structure (v66: dark, then the full
   power-on in run 2 [M]), but on v2.7 it is untested [O].
3. **Modules:** resolved (J-129): the 95-module v66 set; the 36 v2.7-only modules never load. Whether the
   v66 set is sufficient on v2.7 (no new display/USB dependency outside it) is checked statically
   (closure) but untested on the device [O].
4. **ABL**: that Unit 2's v2.7 ABL accepts `fastboot boot` of an unsigned header-v4 image as Unit 1's v66
   ABL did is untested [O].
5. **Unit 2 is a user build**: the privileged capture rows (BA/AA partition hashes)
   do not apply; the host side handles it (§6). *(Correction J-131/J-133: both units are user builds; the host tools record the privileged rows as "not captured" [removed for publication]<withheld document>`.)*
6. The eye swap and the roll direction come from the PM's J-125 report (the 21° value is Meta's design
   value, §4); they are parameters.
7. If Unit 1 is moved to v2.7 (J-127), this image applies to it only if its runtime
   `ro.boot.vbmeta.digest` is the same `66b76196…9f12a` (the same build); otherwise rebuild with its own
   pinned inputs.

## 8. Files

| path | what |
|---|---|
| `build-image.sh` | the builder (pins, AVB check, ramdisk, repack, MANIFEST) |
| `test-builder.sh`, `test-image.sh` | builder negatives + reproducibility + candidate rebuild; the whole-image harness driver |
| `init.sh` | = stage-3c init + product string `FrameShift stage3d`, the module list `/lib/fs/modules.load`, the pinned vendor index check (fail closed) |
| `modules.load.v66` | the 95 modules stage 3d loads (J-129), installed as `/lib/fs/modules.load` |
| `fs-phase.sh` | the per-phase runner: r1 reset, `gate_reset`, r2 options, `exp=s3d_` |
| `fs-probe.sh` | stage 3c's, plus ONE change (J-141, §3a): the v2.7 mode-validation dmesg lines are counted, not kept (`tools/probe-dmesg-check.sh`) |
| `fs-idle.sh` | byte-identical to stage 3c |
| `src/fs-pattern.c` | fs-pattern **v0.7.1** (reset mode, per-eye picture; v0.7.1: MAXMODES 512 and the mode-record cap, §3a; the mock DRM model in the unit-test build, incl. the v2.7 connector set) |
| `tools/v27-modes.py`, `tools/check_delta071.py` | v0.7.1: the v2.7 mode list from the DT (validated on v66's record; = the C mock's list); the device build v0.7.1 vs v0.7 |
| `tools/build.sh`, `tools/fixtures.sh` | the fs-pattern build (bit-identical rebuild) and its suite |
| `tools/check_render.py`, `tools/preview.py`, `tools/check_static.py`, `tools/check_propsim.py` | v0.7 render checker (independent, float), the byte-identical Python port + previews, static checks vs v0.6, the mock-model checks incl. reset |
| `tools/image-harness-3d.py`, `tools/check-timing-3d.py`, `tools/pace_evidence.py`, `tools/encode-timing.sh`, `tools/dmesg-timing.sh`, `tools/check_stream.py` | as stage 3c, retargeted |
| `tools/avb-check.py`, `tools/ota-payload-check.py`, `tools/dt-props-compare.py`, `tools/module-closure.py`, `tools/v27-inputs.sh` | the v2.7 provenance and re-check tools → `provenance/` |
| `tools/module-list-check.py` | the module-list check the builder runs (present, closed, roots inside, excluded unreachable) |
| `tools/ramdisk-scan-3d.sh` | `stage2a/tools/t1-ramdisk-scan.sh` with the v2.7 vendor_boot |
| `provenance/` | ota, avb, runtime, images, modules, dt reports + SHA256SUMS |
| `fixtures/` | every suite's outputs (RESULTS files) |
| `BUILD-RECORD.txt` | the fs-pattern v0.7.1 build record (`bfafad97…`; v0.7 was `7c9fa98c…`) |
