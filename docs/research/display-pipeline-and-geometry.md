# Quest 3 display pipeline, community display work, and panel geometry

Question (2026-10-11, after trial (iii-b), J-107/J-108): run 2 lit the Quest 3
panels but the image was garbled. We committed mode `4128x2208x90vid` as
**2 VIG planes of 2064 px, XR24, linear**. Stock Android scans out with
**4 DMA rects of 1032 px** (2 SSPPs in multirect), AB24 with the UBWC
modifier, core clock 503 MHz. How does Meta drive these panels, what must our
`fs-pattern` commit match, what has the community done, what is the panel
geometry, and what are the next three changes for the stage-3c run?

Offline, read-only research. No device was touched. Nothing was downloaded
or cloned beyond reading source pages; nothing was committed.

Tags: **[M-static]** read from source or a captured artifact (cited by
path:line or URL) · **[D]** derived · **[C]** inferred or an unverified
external claim · **[O]** open. Stock captures from Unit 1 under Android are
hardware output; where cited here they are quoted from the committed capture
files, so they are tagged [M-static] with the file named.

## Sources and versions

- **Meta kernel source, v66 user build** `23c97b254` "build: 5010519.0.510"
  of `github.com/facebookincubator/oculus-linux-kernel`, branch
  `oculus-quest3-kernel-master` (the nearest public tree to Unit 1's
  `.511` v66 (Unit 1) kernel; local read-only copy, WSL `~/work/fs006-kernel/src`).
  Display driver paths below are relative to `techpack/display/msm/`.
  That this tree matches the running `msm_drm.ko` exactly is [C]; earlier
  passes matched dmesg strings and symbols (`display-handoff-dark.md`).
- **v66 DTB**, decompiled: `~/work/dtdiff/v66.dts` (panel node
  `meta,eureka_panel_sharp` at `:16731`).
- **Qualcomm SDE catalog DT** in the same tree:
  `arch/arm64/boot/dts/vendor/qcom/display/anorak-sde-common.dtsi`.
- **Stock capture, Unit 1, Android lit**:
  `devices/quest3/evidence/stock-display-20261010/capture-lit.txt`
  (debugfs `dri/0/state`, `crtc155/status`, `crtc155/state`, sysfs, IRQs),
  and `capture-asleep.txt` (cmdline, mode list).
- **Mainline DPU** (for the public pipe-clock model):
  `torvalds/linux` `drivers/gpu/drm/msm/disp/dpu1/dpu_plane.c`, master as
  read 2026-10-11 via raw.githubusercontent.com.
- Our earlier notes: `display-bringup-quest3.md`, `display-handoff-dark.md`,
  `quest3-panel-online.md`, `oculus-linux-kernel-yusuf.md`,
  `display-clues-kexec-quest1.md`, `community-quest-repos-2.md`,
  `armadavr.md`, `FS-A-006-quest-projects.md`, `FS-A-006-ports.md`.

---

## 0. Answers in brief

1. **The leading cause of the garble is pipe throughput, now with a code
   path behind it [D, strong].** In this downstream SDE driver the kernel
   does **not** compute a per-plane clock and does **not** reject a pipe
   that is too wide for the clock. Clock and bandwidth are *votes* that the
   composer passes in as CRTC properties (§A.4). With the mode's 5158-line
   vertical total, one SSPP rect must deliver its whole width in one
   2.154 µs line, so a rect may be at most **≈ 1128 px wide** at the 550 MHz
   MDP maximum. Our 2064-px rects need ≈ 1.006 GHz. The atomic check
   passed, the pipe could not keep up, and the DSC stream to the panels was
   corrupted. Mainline DPU uses the same clock model and *splits* any pipe
   that would exceed the maximum clock (§A.4). Stock stays at 1032 px per
   rect, 503 MHz.
2. **Lowering the refresh rate does not help [D].** The panel changes rate
   by stretching the vertical front porch (`dfps_immediate_porch_mode_vfp`),
   so the line time, and with it the per-rect width limit, is the same at
   72 Hz as at 90 Hz (§A.4).
3. **The kernel's own splash handoff already stages 4 planes** (71, 97,
   100, 103: VIG0–VIG3, one per mixer) [M-static, FSP1 seq 34–40 via
   `display-handoff-dark.md` §2]. **Stock Android uses 4 rects** of 1032
   (DMA3 rect 0/1 for the left half of the CRTC, DMA2 rect 0/1 for the
   right) [M-static, capture]. Both are one rect per layer mixer (LM).
4. **UBWC is not required, and neither is AB24 [D].** Linear XRGB8888 is in
   every pipe's format list. With no clock/bandwidth properties set, the
   kernel votes the **maximum** clock (550 MHz) and bandwidth (16 GB/s), so
   linear fetch is not starved by under-voting (§A.4, §A.5).
5. **DSC, the topology and the PPS are kernel- and panel-side.** The DT sets
   DSC 8 bpc / 8 bpp, slice 1032×32, 2 slices per packet, block prediction,
   topology 4 LM / 4 DSC / 2 INTF, and `qcom,disable-default-pps`, so the
   host sends **no** PPS packet to the panel [M-static]. A KMS client
   touches none of this. It must only keep every rect inside one mixer's
   throughput (§A.2).
6. **The full (non-splash) panel power-on is Meta's normal sequence**:
   supplies, reset, pre-on set, sleep-out + display-on, video engine,
   unicast post-on sets per link, then backlight-unit (BLU) timing (§A.6).
   Run 2 went through it: TE ≈ 181/s, the stock rate (J-108).
7. **Match-stock checklist** (§A.8): 4 planes × 1032 px, one per LM, zpos
   set explicitly, global coordinates (the kernel derives the left/right
   layout); leave clock and bandwidth unvoted (max) or copy stock's votes;
   keep XR24 linear. Add read-only underrun counters from the encoder's
   debugfs `status` node.
8. **Community (§B): there is a direct precedent.**
   `machachu56/quest-kexec-q2` drove a Quest 2 through Meta's stock SDE
   driver with non-Android KMS clients.
   - With one plane spanning both layer mixers, the panel showed "rows of
     small purple blocks".
   - With one half-width plane per mixer, XR24 linear with no modifier, it
     displayed correctly. gamescope was patched to split every layer the
     same way.
   - The author first blamed DSC/PPS, and was wrong.
   - Quest 1 (fbdev, one DMA pipe per mixer) and Yusuf Özmen's Quest Pro
     (`qkx-splash`, 2 planes) follow the same pattern.
   - On mainline, the Lynx R1 dual-DSC XR2 panels still do not work.
9. **Geometry (§C):**
   - The Quest 3 panels are mounted 180° and, by Meta's own recovery
     property, **rolled about 21°** in-plane: "21 + 180" is the comment on
     `ro.boot.bootloader_screen_rotation=201`, not on the minui rotation
     as our notes said.
   - The lens axis sits nasal and high of each panel's centre.
   - Cant, roll and lens offsets belong in the runtime's eye-to-head
     transforms, projection and distortion, not in the KMS commit.
   - Per-unit display calibration lives in `/persist` (names only).
   - Valve has published no Frame geometry format.

---

## A. How Meta drives the Quest 3 panels

### A.1 The path: one connector, one CRTC, two DSI links

- **Panel node** `meta,eureka_panel_sharp` [M-static, `v66.dts:16731-16860`]:
  - "Sharp novatek dual video mode dsi panel with dsc", `dsi_video_mode`,
    `burst_mode`, C-PHY (`qcom,panel-cphy-mode`);
  - `qcom,dsi-ctrl-num = <0 1>` and `qcom,dsi-phy-num = <0 1>`: one panel
    node spans both DSI controllers and both PHYs;
  - `qcom,cmd-sync-wait-broadcast`: commands are broadcast to both links,
    except the unicast post-on sets (§A.6).
- **Timing@0** per link [M-static, `v66.dts`, timing@0]: 2064 × 2208,
  HFP 38, HBP 54, HPW 20, so htotal = 2176 per link; VFP 2918, VBP 30,
  VPW 2, so **vtotal = 5158**; 90 Hz default, 72–120 Hz range.
- **The DRM mode** doubles the width over the two links: `4128x2208x90vid`,
  clock 2 020 285 kHz, htotal 4352, vtotal 5158 [M-static, capture
  `crtc[155]` mode line]. This matches the DT exactly [D].
- **Mode list** [M-static, `capture-asleep.txt`]:
  - `4128x2208` at 72, 75, 80, 85, 90, 95, 96, 100, 105, 110, 115, 120;
  - `3104x1664` at the same rates (timing@1, DDIC upscaling).
- **The huge vertical blank is deliberate** [C]. The fast-switch LCD scans
  quickly, then waits for the liquid crystal to settle before the BLU
  flashes (`quest3-panel-online.md` §1 and §4). So the active lines are
  packed into 2208/5158 ≈ 43 % of the frame time. That is what makes the
  per-line pixel rate so high (§A.4) [D].
- **Which eye is DSI0** is still [O]. Stock gives no hint, because the
  composer pre-rotates in the GPU and uses plane rotation `ROTATE_0`
  (`rotation=1` on every stock plane [M-static, capture]).

### A.2 Topology and DSC

- **Per mode** [M-static, `v66.dts` timing@0]:
  - `qcom,display-topology = <4 4 2>`: 4 LMs, 4 DSC encoders, 2 INTFs;
  - `qcom,compression-mode = "dsc"`;
  - `qcom,mdss-dsc-bit-per-component = <8>`, `bit-per-pixel = <8>`;
  - `qcom,mdss-dsc-slice-width = <0x408>` (1032),
    `slice-height = <0x20>` (32), `slice-per-pkt = <2>`;
  - `qcom,mdss-dsc-block-prediction-enable`;
  - **`qcom,disable-default-pps`**.
- **Stock dmesg agrees**: "default topology: lm: 4 comp_enc:4 intf: 2"
  [M-static, `capture-lit.txt` dmesg tail].
- **What it means [D]:**
  - Each LM is 1032 px wide and feeds one DSC encoder, one slice wide.
  - Two encoders are merged onto each INTF, i.e. each DSI link carries
    2064 px as 2 slices per packet.
  - In other words, each eye is driven by an LM pair, each LM through its
    own DSC encoder.
- **The kernel cross-checks the mixer count against the clock**
  [M-static, `sde/sde_kms.c:3689-3730`]:
  - mode clock = htotal × vtotal × fps × 1.05 = 2.121 GHz;
  - it adds LMs in pairs until clock / num_lm ≤ `max_core_clk_rate` and
    width / num_lm ≤ `max_mixer_width` (2560, `anorak-sde-common.dtsi:148`);
  - so **≈ 530 MHz per LM with 4 LMs; 2 LMs would need 1.06 GHz**
    [D, from the values].
  - In this kernel 4 mixers are a hard requirement of the mode, not a
    choice.
- **PPS.** With `disable-default-pps`, `use_default_pps` is false
  (`dsi/dsi_panel.c:3711-3712`), so `dsi_display_enable` never calls
  `dsi_panel_update_pps` (`dsi/dsi_display.c:8901-8913`) [M-static].
  - The host DSC encoders are still configured from the DT values.
  - The DDIC's decoder settings must therefore come from Meta's own
    pre-on register set [C]. A comparable panel in the same DT has
    vendor registers `C0 03` / `C1 …` with a 0x20 slice height in its on
    set (`v66.dts:16468`). The Sharp pre-on payload was not decoded.
  - Either way, **a KMS client neither can nor needs to touch the PPS.**
    It is fixed per mode by the DT plus the panel's init [D].
- **Connector properties that could change DSC or topology**
  (`topology_control`, `dsc_mode`) default to 0
  (`oculus-linux-kernel-yusuf.md` §4.1). We never set them, and we must
  not [D].

### A.3 Pipes, layouts and source-split rules

**SSPP inventory** [M-static, `anorak-sde-common.dtsi:94-113`]:
- 4 VIG + 6 DMA pipes: `"vig","vig","vig","vig","dma",…`.
- Smart-DMA v2.5. Every pipe has a second "virtual" rect, so the driver
  exposes **20 planes**. The stock `dri/0` list shows 20 [M-static,
  capture].
- **Plane order** [M-static, `sde/sde_kms.c:2166-2200`]:
  - primary rects first, in catalog order: plane-0..3 = VIG0..3,
    plane-4..9 = DMA0..5;
  - then the virtual rects in `smart-dma-priority` order `<7 8 9 10 1 2 3 4 5 6>`:
    plane-10..15 = DMA0..5 rect 1, plane-16..19 = VIG0..3 rect 1.
- **Mapping to DRM ids [D]:** 71/97/100/103 = VIG0–3;
  106/109/112/115/118/121 = DMA0–5; 124/128/131/134/137/140 = DMA0–5
  rect 1; 143–152 = VIG rect 1.
- A client can confirm this read-only from each plane's `capabilities`
  blob: `pipe_idx`, and `primary_smart_plane_id` on virtual planes
  [M-static, `sde/sde_plane.c:3972-4041`].

**Stock layout under Android** [M-static, `capture-lit.txt`
`crtc155/status`]:

| plane | pipe [D] | src_x | dst x (in its half) | stage | multirect |
|---|---|---|---|---|---|
| 115 | DMA3 rect 0 | 0 | 0 | 1 | parallel, rect 0 |
| 134 | DMA3 rect 1 | 1032 | 1032 | 1 | parallel, rect 1 |
| 112 | DMA2 rect 0 | 2064 | 0 | 2 | parallel, rect 0 |
| 131 | DMA2 rect 1 | 3096 | 1032 | 2 | parallel, rect 1 |

All four use fb 56, 4160×2208, AB24, modifier `0x0500000000000001`
(Qualcomm compressed, i.e. UBWC), pitch 16640, `rotation=1` (`ROTATE_0`).
There are 4 mixers × 1032 on CTL 0.

**Quad-pipe layouts** [M-static, `sde/sde_crtc.c:5955-6018`]:
- For a quad-pipe topology every plane belongs to the **left** or the
  **right** half (`sspp_layout` property: none/left/right,
  `sde/sde_plane.c:4118-4122`, `:4208`).
- With `none`, the default and what we use, the kernel converts global
  coordinates. A plane with `crtc_x ≥ 2064` moves to the right half, at
  `crtc_x − 2064`.
- A plane must fit inside its half (`-E2BIG`, "invalid horizontal
  destination").
- This is why stock debugfs shows destination x of 0 and 1032 for both
  eyes [D].
- LM0/LM1 form the left layout and LM2/LM3 the right, unless the catalog
  sets `swap_mixers` (`sde/sde_crtc.c:3925-3945`). It does not on v66
  (see below).

**Staging rules a client must respect** [M-static]:
- At most **2 planes per blend stage per half** ("> 2 planes @ stage",
  `sde/sde_crtc.c:5866-5890`).
- Two planes sharing a stage in the same half form a source-split pair
  (`_sde_crtc_validate_src_split_order`, `sde/sde_crtc.c:1849-1928`):
  - the lower DRM plane id must be the left one, **unless** the catalog
    sets `pipe_order_type`. Anorak sets `qcom,sde-pipe-order-version = <1>`
    (`anorak-sde-common.dtsi:163`, read at `sde/sde_hw_catalog.c:4109`),
    so this rule is waived here [M-static];
  - the two must be contiguous in x;
  - they must have the same y and height.
- `swap_mixers` comes from the Meta-only DT flag `meta,swap-mixers`
  (`sde/sde_hw_catalog.c:627`, `:4094`). It is absent from the v66 DTB
  (grep), so LM0/LM1 form the left half [M-static].
- If both rects of one SSPP are staged, they are validated as a multirect
  pair (`sde/sde_crtc.c:5741-5808`):
  - no scaling, no inline rotation, a format valid for multirect;
  - if the client leaves `multirect_mode` unset, the driver picks
    parallel or time-multiplexed itself (`sde/sde_plane.c` in
    `sde_plane_validate_multirect_v2`, near `:1824-1935`).
- **zpos:** if the driver runs as a "custom client", every plane's zpos
  defaults to 0, with a maximum of `blendstages − 1` = 10
  (`sde/sde_plane.c:4162-4178`; `qcom,sde-mixer-blendstages = <0xb>`).
  Otherwise non-primary planes default to index + 1. Twenty planes
  (virtual rects exist) imply custom-client mode, because virtual planes
  are only created when `sde_is_custom_client()` is true
  (`sde/sde_kms.c:2185-2191`) [D].
  - **So set zpos explicitly** rather than rely on defaults.
- **Why stock uses DMA2/DMA3** is [C]: these are the two DMA pipes with
  CAC (chromatic-aberration-correction) fetch mode and an LM-pair
  preference (`qcom,sde-sspp-cac-mode` = 2 and
  `qcom,sde-sspp-cac-lm-pref` = `<0 1>`, `<2 3>`,
  `anorak-sde-common.dtsi:99-104`).
  - Debugfs `status` does not print the plane's `cac_type`
    (`sde/sde_crtc.c:7097-7195`), so whether Meta's composer actually
    enables hardware CAC is [O].
  - It does not matter for a test pattern: CAC defaults to `none`.

### A.4 Clock and bandwidth: who votes, and the per-rect width limit

**Who votes [M-static]:**
- `_sde_core_perf_calc_crtc` (`sde/sde_core_perf.c:91-170`) takes
  `core_clk`, `core_ab`, `core_ib` and, when split, `llcc_ab/ib` and
  `dram_ab/ib` straight from **CRTC properties**.
- Setting any of them sets `bw_control` (`sde/sde_crtc.c:6774-6785`).
- If none is set, `bw_control` stays false:
  - reset at CRTC reset (`:5084-5088`) and state reset (`:7006-7008`);
  - the kernel then votes **`max_core_clk_rate`** and
    **`max_bw_high`** on every bus (`sde_core_perf.c:133-140`).
- The defaults are 550 MHz (DT `clock-max-rate` `0x20c85580`,
  `v66.dts:16067`/`:16254`) and 16 000 000 kbps
  (`anorak-sde-common.dtsi:167-168`, installed as property defaults at
  `sde/sde_crtc.c:6341-6382`).

**What stock votes** [M-static, `crtc155/state`]:
- `core_clk_rate: 503028768`;
- `bw_ctl` 6 231 870 464 on the data, LLCC and EBI buses;
- `ddr-rt` 7 852 156 784;
- `max_per_pipe_ib` 0.

**The composer's model [D]:** 1032 × 5158 × 90 × 1.05 = 503.03 MHz. This
is the widest rect × vtotal × fps × 1.05.

**Mainline DPU uses the same model** [M-static, torvalds/linux
`dpu_plane.c`]:
- `_dpu_plane_calc_clk` computes "dst_width * mode->vtotal * fps";
- `dpu_plane_split` breaks a plane into two pipes when the source exceeds
  `max_linewidth` **or** the computed clock exceeds `max_mdp_clk_rate`.

**The downstream SDE kernel has neither check** [M-static, by search]:
- there is no per-plane clock function in `sde/sde_plane.c` (grep `clk`);
- `sde_core_perf` only takes the votes;
- so an over-wide rect is accepted and simply underruns [D].

**Per-rect width limit [D]:**

  W_max = 550 MHz / (5158 × 90 × 1.05) ≈ **1128 px**

| layout | widest rect | required clock | fits 550 MHz? |
|---|---|---|---|
| ours, run 2: 2 × 2064 | 2064 | ≈ 1.006 GHz | **no** (1.83×) |
| splash: 4 × 1032 VIG | 1032 | 503 MHz | yes |
| stock: 4 rects × 1032 on 2 DMA | 1032 | 503 MHz | yes |
| timing@1: 3104 wide, 2 × 1552 | 1552 | ≈ 680 MHz (vtotal ≈ 4652) | no |

**The refresh rate does not move the limit [D]:**
- `dfps_immediate_porch_mode_vfp` (`v66.dts`, panel node) keeps the pixel
  clock and lengthens VFP;
- vtotal × fps, and so the line time, stays constant (≈ 2.154 µs).
  `meta,internal-1h-time-ns = <0x5dc>` (1500 ns) is the DDIC's own
  internal line, also fixed.

**Bandwidth [D]:**
- Linear XR24 at 4128 × 2208 × 4 B × 90 is about 3.3 GB/s average.
- The per-line burst is higher, because 2208 active lines are fetched in
  43 % of the frame: about 7.6 GB/s peak.
- Both are well under the 16 GB/s the kernel votes by default.
- UBWC exists to save bandwidth and power, not because the scan-out needs
  it.

**How a client stays inside the limit:** every rect ≤ 1128 px wide. In
practice that means 1032 px, exactly one rect per LM, with no scaling
(downscaling would multiply the clock by src_h/dst_h).

### A.5 Pixel format and UBWC

- Stock fb: AB24 (`DRM_FORMAT_ABGR8888`) with
  `DRM_FORMAT_MOD_QCOM_COMPRESSED` (`0x0500000000000001`), width 4160
  (UBWC-aligned), pitch 16640 [M-static, capture].
- Ours: XR24 (`XRGB8888`) linear dumb buffer, pitch 16512 (the
  `fs-pattern` source, `devices/quest3/stage3b/src/fs-pattern.c:99`,
  `:1488`).
- Both formats are in the planes' `pixel_formats` list. The test fixture
  `devices/quest3/stage3b/fixtures/` mirrors the list with AB24 first and
  XR24 present (`fs-pattern.c:1849` fixture text) [M-static fixture; the
  real list was probed on device in trial (iii-b)].
- **The difference is channel order only.** AB24 puts R in the low byte,
  XR24 puts B there. A grey pattern is identical in both [D].
- A dumb buffer cannot be UBWC. Linear is a supported fetch mode and is
  not the cause of an RGB-stripe garble [D] (J-108: "a flat grey field
  can't become RGB stripes through a format or stride error").

### A.6 Panel power-on on a non-splash enable (what run 2 executed)

Order in the v66 driver [M-static unless tagged]:

1. **Bridge pre-enable → `dsi_display_prepare`** (`dsi/dsi_drm.c:200-257`):
   - PHY, controller and link clocks up;
   - `qcom,mdss-dsi-lp11-init` is set, so the panel power-on runs inside
     `dsi_panel_prepare` (`dsi/dsi_panel.c:5584-5613`).
2. **Supplies** (`eureka-panel.dtsi:144-192` per `display-bringup-quest3.md`
   §3):
   - vddio L5B;
   - the TPS65132 VSP/VSN bias;
   - `display_panel_vsp_en`.
3. **Reset** `qcom,mdss-dsi-reset-sequence = <0 20 1 20>`: low 20 ms, then
   high 20 ms, on platform reset gpio 108 (`0x6c`). There is a second reset
   on gpio 140 (`0x8c`) with `sec-reset-off-delay` 30 [M-static, panel
   node].
4. **Pre-on set** (`DSI_CMD_SET_PRE_ON`): Meta's register pages (FF D0,
   FF E0, FF F0, FF 23 …), including the BLU "set to 100%" block
   (`display-handoff-dark.md` §3.3). The DSC/decoder setup lives here [C].
5. **`dsi_panel_enable`** sends the on set (`dsi/dsi_panel.c:5916-5950`)
   [M-static, `v66.dts` panel node, LP mode]:
   - `FF 10` (page select);
   - `11` (sleep-out), then 120 ms;
   - `29` (display-on), then 120 ms;
   - then `VID_ON` (empty for this panel [C]).
6. **No PPS packet** (§A.2). Then the **video engine is enabled**
   (`dsi/dsi_display.c:8921-8930`).
7. **`dsi_panel_post_enable`** (`dsi/dsi_panel.c:5956-5992`):
   - the post-on set;
   - Meta's **unicast** `meta,mdss-dsi-post-primary-panel-on-command` to
     link 0 and `…-secondary-…` to link 1 (pages `FF 2B`, registers
     40–48).
8. **Bridge enable → backlight update** at level 1000 (Tokki-A,
   ≤ 8.2 % duty), or 127 if written first, through the temperature work
   (`display-handoff-dark.md` §3.3).

How the splash path differs:
- On the **splash-handoff** path, steps 2, 3, 5 and 7 are skipped
  (`is_skip_op_required`); only the pre-on set is re-sent
  (`meta,cont-splash-handoff`).
- That is why run 1, a splash-handoff commit on a panel ABL had left
  asleep, stayed dark, and run 2, a full enable after lastclose, lit
  (J-107, J-108) [D].

Stock "lit" signature [M-static, capture]:
- `te-edge-isr` and `blu-pwm-isr` both rise by ≈ 182/s (33236 → 33600 and
  33255 → 33619 over 2 s);
- `measured_fps` 89.8;
- `vsync_timing=32,2208,2918@90`;
- `backlight_timing=422,5659,5659`.

Asleep, the TE and BLU counters do not advance meaningfully
(`capture-asleep.txt:109-110`; a single sample).

### A.7 What a KMS client is expected to set, and what we did not

Plane properties stock sets that we did not:
- Explicit `zpos`: stock uses stages 1 and 2.
- 4 rects instead of 2.
- DMA pipes; multirect is auto-selected by the driver.
- An AB24 UBWC buffer.

CRTC properties:
- `core_clk`, `core_ab`, `core_ib` and the LLCC/DRAM votes. Stock votes
  503 MHz and about 6.2 GB/s. We leave them unset, which means the
  **maximum** votes (§A.4).
- Not voting is the conservative choice for correctness. It costs some
  power and heat, which matters little for a ≤ 10 s hold [D].

Connector properties:
- `LP` (power mode) defaults to ON;
- `topology_control` and `dsc_mode` default to 0;
- `qsync_mode`: stock's value is [O], but not needed for a static frame.

Nothing else is required:
- input and output fences are optional for a blocking commit;
- `topology_name` and `mode_properties` are read-only and worth logging
  (`oculus-linux-kernel-yusuf.md` §4.1).

### A.8 "Match stock" checklist for the stage-3c `fs-pattern` commit

All items use only standard atomic properties in the **same commit** we
already make. There are no sysfs, debugfs, DCS or BLU writes. Items marked
"optional" are not needed to fix the garble.

| # | item | stock value | ours (run 2) | how to set via KMS (no new write class) | evidence |
|---|---|---|---|---|---|
| 1 | **rects per CRTC** | 4 rects, 1032 px each, one per LM | 2 rects × 2064 | 4 planes: `SRC_X` 0/1032/2064/3096, `SRC_W` = `CRTC_W` = 1032, `CRTC_X` = same as `SRC_X` (global coordinates; the kernel derives left/right) | §A.3 table; §A.4 limit ≈ 1128 px |
| 2 | **which pipes** | DMA3 r0+r1 (left half), DMA2 r0+r1 (right half) | VIG0 + one helper VIG | either **VIG0–3 = planes 71/97/100/103** (the kernel's own splash layout, no multirect) or the exact stock DMA2/DMA3 pairs. Select by the `capabilities` blob (`pipe_idx`, `primary_smart_plane_id`), not by hard-coded ids | §A.3; FSP1 splash state (`display-handoff-dark.md` §2) |
| 3 | **zpos / stage** | 1 (left), 2 (right) | defaults | set `zpos` explicitly: e.g. 0 for all four (pairs per half), or 1 left / 2 right like stock. If two planes share a stage in a half, they must be contiguous with the same y/h (the id-order rule is waived on anorak, but keeping lower id on the left costs nothing) | §A.3 staging rules |
| 4 | **multirect** | parallel (auto) | none | leave `multirect_mode` unset; the driver selects it. Only relevant if both rects of one SSPP are used | `sde_plane_validate_multirect_v2` |
| 5 | **layout** | left/right | derived by the kernel | leave `sspp_layout` = none (global coordinates). Never let a plane cross x = 2064 | `sde/sde_crtc.c:5988-6018` |
| 6 | **mode** | `4128x2208x90vid` | same | unchanged; do not use timing@1 (1552-px halves exceed the limit with 2 rects) | §A.1, §A.4 |
| 7 | **clock/BW votes** | core 503.03 MHz; ab 6.23 GB/s; ddr-rt 7.85 GB/s | unset, i.e. max: 550 MHz, 16 GB/s | keep unset (recommended), or optionally copy stock's `core_clk`/`core_ab`/`core_ib` values in the commit | §A.4 |
| 8 | **format** | AB24 + UBWC modifier, fb 4160 wide | XR24 linear, 4128 wide | keep XR24 linear (a dumb buffer cannot be UBWC). Note R/B order if the pattern ever uses colour | §A.5 |
| 9 | **rotation** | `ROTATE_0` (1) | not set (default 0°) | optionally set `rotation` = 1 explicitly; keep the in-buffer 180° per half as now | capture `rotation=1` |
| 10 | **DSC/topology/PPS** | from the DT | from the DT | never set `topology_control`, `dsc_mode` or any DSC property | §A.2 |
| 11 | **full enable** | normal wake | run 2 path | keep run 1 (consume splash) → lastclose → run 2 full modeset | §A.6; J-107 |
| 12 | **read-only proof** | underrun 0 [C] | not logged | log `dri/0/encoder<id>/status` ("intf / vsync / underrun") and `crtc<id>/status` + `state` before and after the run-2 commit (needs debugfs mounted inside our own initramfs; classification for review) | `sde/sde_encoder.c:5330-5352`, `:5556` |

**Headline items:** 1 (4 × 1032), 2 (pipe choice), 3 (zpos) and 12
(underrun counter). Items 1–3 are the fix. Item 12 is the proof.

---

## B. Community work that got an image on a Quest panel

Method: read through the GitHub REST API, raw.githubusercontent.com and web
search, with spot checks by the author of this note. Nothing was built,
run or cloned. Only the new or sharpened items are given in full; earlier
reads are in `display-clues-kexec-quest1.md`, `oculus-linux-kernel-yusuf.md`,
`community-quest-repos-2.md` and `armadavr.md`.

### B.1 The direct precedent: Quest 2 on Meta's SDE driver, garble → fix

**machachu56/quest-kexec-q2**, branch `quest2-port` @ `9c96c192d` (pushed
2026-10-07):
https://github.com/machachu56/quest-kexec-q2/tree/quest2-port

- **Device and kernel:** Quest 2 (hollywood, SM8250) on Meta's **stock
  downstream 4.19** kernel. The kexec patches only keep drivers alive
  across the handoff; there are no display patches [M-static, per the
  survey's file list].
- **Clients:** modetest, its own `ion2kms` tool and gamescope, all on the
  stock `msm_drm` SDE driver through atomic KMS. There is no fbdev.
- **The symptom:** the panel "only ever shows rows of small purple blocks".
  This happened for dumb, imported and CPU-drawn buffers alike, at 90 and
  120 Hz. The author first suspected DSC/PPS or panel re-init, and that
  suspicion turned out wrong. Source: `docs/QUEST2_PORT.md` (≈ `:210-216`,
  `:268-269`) [M-static, spot-checked by this author via raw fetch].
- **The cause, as the author states it:** the mode uses "a dual
  layer-mixer topology" (2 LM / 2 DSC / 2 DSI). A single plane spanning the
  full 1920 px gives the garbage; **one half-width plane per mixer displays
  correctly** (`QUEST2_PORT.md` ≈ `:273-279`) [M-static / C for the
  causal claim].
- **The working layout in `ion2kms`** (`tools/tests/ion2kms/ion2kms.c`
  ≈ `:111-173`, per the survey) [M-static]:
  - 2 planes × 960 px, src 0/960, dst 0/960, full height;
  - `XRGB8888`, pitch w×4, no modifier (linear);
  - TEST_ONLY first, then MODE_ID + ACTIVE + connector CRTC_ID with
    ALLOW_MODESET.
- **The gamescope fix:**
  `patches/gamescope/0003-drm-split-layers-across-two-planes-for-dual-LM-SDE.patch`
  puts each layer on a left plane and a right plane when
  `GAMESCOPE_DRM_SPLIT_PLANES=1`.
  - The right half uses full-CRTC coordinates (CRTC_X = half the width).
  - A user reports vkcube on the panel [C].
- **Other SDE quirks the patches handle** (patches 0001/0002/0004/0006)
  [M-static, per the survey]:
  - no `IN_FORMATS` (linear is assumed);
  - SDE's `input_fence` instead of `IN_FENCE_FD`;
  - 8-bit `alpha`;
  - no rotate-90/270 on linear RGB, so rotation is done in a shader.
- **Still open in the repo:** "the kernel-side fix for single wide planes
  (SDE source split with DSC)".
- **Licence:** the survey reports GPL-2.0 for the repo and BSL-1.0 for the
  Monado driver. The fetched doc page itself states no licence. Check the
  repo's `LICENSE` before reusing anything [O].

**Reading [D]:** this is our failure class. A plane wider than one mixer
passes the atomic check, then scans out garbage on a DSC panel, and the
cure is one plane per LM.

The author describes the cause as **straddling mixers**. §A.4 gives a
second mechanism, **the per-rect clock**. On the Quest 2 a 1920-px rect
also exceeds what one pipe delivers per line, if its mode has a similar
fast-scan vertical total [C].

Both mechanisms predict the same fix: **rects ≤ one LM wide, one per LM.**
It does not matter for the next run which of the two is "the" cause.

### B.2 Other projects

| project | device / kernel | how the display is driven | relevance | licence |
|---|---|---|---|---|
| **YusufOzmen01/quest-kexec** (`e61edbd`, no change since 2026-10-04) and **oculus-linux-kernel** fork (Quest Pro head `9b68500d48`) | Quest Pro (seacliff, kona), Meta 4.19 + probe-survival | closed `qkx-splash`: atomic full modeset, **2 planes** (ids 57/79 or 58/80), 90 Hz, run twice. SteamOS on top via Turnip-KGSL with timeline-syncobj bridges | the "two bring-ups" and "one plane per mixer" precedents; no Quest 3 commits; nothing new since 2026-10-10 [M-static, API] | GPL-2.0 |
| **Mac898/quest-kexec** `quest2-support` `2d42980a6` (2026-10-11) | Quest 2 / Pro board descriptors | no display content beyond keeping `cont_splash_region` no-map | none for display [M-static] | GPL-2.0 [C] |
| **nicolas-riera/Quest1-SteamOS** `b7467ff` | Quest 1 (MSM8998), rebuilt Meta 4.4, `fastboot boot` | MDSS **fbdev** `MSMFB_ATOMIC_COMMIT`. **2 DMA pipes, one per panel/mixer**, 1440 px each of a 2880×1600 buffer. RGBA8888, linear or UBWC per buffer. No DSC (OLED). Monado, plus a custom SteamVR driver (`src/monado/.../comp_window_mdp.c:9-10,562-576`) | an independent "one pipe per mixer" design | file SPDX BSL-1.0; rest unlicensed |
| **cstahly/quest1-bootloader-to-VR** | Quest 1, Meta 4.4 | Monado patch maps `/dev/fb0` (2880×1600×32). Pan, `FBIOBLANK` unblank, software 180° rotation, no modeset (`patches/monado/0002-…:393-468`) | fbdev; MDSS splits internally | MIT (patches keep upstream licences) |
| **Block-Flock/pmaports-oculus-monterey** | Quest 1, stock 4.4 | Xorg fbdev / labwc; KWin+Monado with Lavapipe | fbdev only | none stated |
| **Lynx R1** (pmaports `device/testing/*-lynx-r1`, mirror `0ecb7e58d2`) | XR2 Gen 1, mainline 6.13 | dual JDI/BOE DSC panels still WIP; mdss-mdp −22 per wiki snippets | mainline dual-DSC still unsolved on XR2 [C] | GPL-2.0-only (kernel) |
| **Quest 3S "panther"** (pmOS conference talk 2026-09-27) | XR2 Gen 2 | no device package, slides or repo found; GitLab/wiki behind Anubis | [O] | — |
| **Producdevity/ArmadaVR** `cfb098024` | Pico Neo 3 (VXR7200 bridge), others | rail sequencing only; "physical rendering remain open" | no Quest panel driven | none |
| **Jbbrack03/Quest-3-Turnip-Driver** | Quest 3 under Android | Turnip rendering tiled into buffers that Meta's compositor scans as linear gave full-screen band corruption | a tiling-mismatch analogue, if we ever add UBWC | Mesa MIT; repo none |

### B.3 Mainline DPU context (not Quest)

Mainline DPU is converging on the same rules [C, mailing-list reads by the
survey]:

- **Jun Nie's quad-pipe series (v17–v19, 2026)** adds the 4:4:2 topology,
  which is our DT topology:
  https://lkml.iu.edu/hypermail/linux/kernel/2601.2/08257.html
  - It clips every plane into left/right halves.
  - It splits again across two pipes when a half is too wide.
- **Mahadevan P's series (2026-10-08)** adds mixers when the mode clock
  exceeds `max_core_clk_rate`, because an LM handles one pixel per clock:
  http://www.mail-archive.com/freedreno@lists.freedesktop.org/msg47627.html
- **Upstream `dpu_plane_split`** already splits a pipe on the clock as well
  as on the linewidth (§A.4) [M-static].

### B.4 What we take from B [D]

1. Use **4 planes × 1032, one per LM**: Quest 2 (QK2), Quest 1 and stock
   Quest 3 all use one rect per mixer.
2. **Don't touch DSC first.** QK2 suspected DSC/PPS and was wrong.
3. **Linear XR24 without a modifier works on SDE** (QK2, kona 4.19). It is
   untested on the Quest 3 5.10 driver [O]. UBWC adds a tiling-mismatch
   risk (Jbbrack03).
4. **Coordinates.** QK2 and Quest 1 put the right plane at full-CRTC x.
   On the Quest 3 5.10 driver, global coordinates are converted by the
   kernel (§A.3), so full-CRTC x (0/1032/2064/3096) is correct. The stock
   per-half numbers are what the kernel *displays* after conversion [D].
5. **Use a CPU-drawn diagnostic pattern with a distinct mark per LM
   quadrant**, so that a layout fault shows which LM received which source
   [D].
6. **Late-cleanup hazard:** QK2 saw `display_panel_avdd` disabled by
   regulator late cleanup at about 32 s after boot [C]. Our run 2 started
   later than that and lit, so on our path it is probably moot [D, weak].
   A read-only regulator summary would settle it.
7. **For later stages (gamescope/SteamVR on SDE):** QK2's gamescope
   patches 0001–0003 are the known adaptations (no `IN_FORMATS`,
   `input_fence`, 8-bit alpha, split planes). Licence still to check.

## C. Panel geometry, cant and calibration

Method: web and source reads by a focused survey, plus local read-only
checks of Meta's v66 recovery `prop.default`, unpacked earlier from
`firmware/quest3/v66_unit1_slotA/recovery.img` into the session
scratchpad (`rec/out/prop.default`). Nothing was extracted from any
calibration store.

### C.1 Correction to our notes: the "21 + 180" comment

`display-bringup-quest3.md` §2.1 attaches "21 + 180 since the screen is
upside down" to `ro.minui.default_rotation`. **That is wrong.**

What `prop.default` actually says [M-static]:
- `ro.minui.default_rotation=ROTATION_CUSTOM` (`:480`) and
  `RGBX_8888`.
- The comment (`:482`) belongs to the next property,
  **`ro.boot.bootloader_screen_rotation=201`** (`:483`).
- It is followed by `ro.boot.bootloader_ipd_offset=886` (`:484`) and
  `ro.boot.bootloader_mipi_padding=0`.
- The same file sets `ro.surface_flinger.primary_display_orientation=ORIENTATION_180`
  (`:293`) and `ro.vros.composer.orientation=ROTATION_180` (`:558`).

Reading [D]:
- Bootloader-style UI is drawn rotated 201°, i.e. 180° for the upside-down
  mounting plus about **21° of in-plane roll**. That is a roll about the
  optical axis, not a yaw cant toward the face.
- Meta's composer and SurfaceFlinger use a plain 180°. The roll is
  presumably absorbed by the compositor's distortion pass [C].
- The unit and origin of `ipd_offset=886` are [O]. Read as pixels from the
  seam, it would put each eye's lens centre about 146 px (≈ 3 mm at the
  20.85 µm pitch implied by 1218 PPI) toward the nose. That is speculative.
- Whether the two eyes roll in opposite directions is [O].
- Neither property name appears in any public source found [O].

### C.2 Per-device geometry

| device | cant / roll | scan-out | per eye | panels / lenses | IPD | best source |
|---|---|---|---|---|---|---|
| **Quest 3** | in-plane roll ≈ 21° [D, `prop.default:482-483`]; yaw cant [O] | one 4128×2208 landscape mode, two DSI links, DT orientation 180° [M-static] | 2064×2208 | 2 LCD, pancake | wheel; Meta chart 58–70 mm lens spacing, 53–75 mm supported IPD [C, https://mixed-news.com/en/meta-quest-3-info/]; panel and lens move together [C] | DT; recovery `prop.default`; SID 2025 table (`quest3-panel-online.md` §1) |
| **Quest Pro** | panels "turned 21 degrees toward each other" per a pre-launch leak [C, https://www.notebookcheck.biz/Projet-Cambria-Meta-Quest-Pro-date-de-lancement-prix-specifications-et-rendus-CAO.637316.0.html] | [O] | 1800×1920 [C] | 2 mini-LED LCD, pancake | continuous 55–75 mm [C, https://roadtovr.com/quest-pro-vs-quest-2-specs-comparison/] | leak; spec sites |
| **Quest 2** | none known [O] | 1920×3664 portrait, eyes stacked, about 90° per eye [C, `machachu56/quest-kexec-q2@9c96c19` `docs/QUEST2_PORT.md` ≈ `:209-212`, `:297-307`] | 1832×1920 logical | 1 LCD, Fresnel | 3 steps 58/63/68 mm; lenses move over a fixed panel [C, https://www.meta.com/help/quest/261777072346131/] | SID 2022 paper; QK2 |
| **Quest 3S** | as Quest 2 [C] | as Quest 2 [D, unchecked] | 1832×1920 | 1 LCD (Quest 2 panel), Fresnel | 3 steps | heise/iFixit (https://www.heise.de/en/news/Teardown-Meta-Quest-3S-has-the-LCD-panels-of-the-Quest-2-9987611.html) |
| **Quest 1** | none: runtime screen "clocking 0, no tilt" [C] | 2880×1600 landscape side by side [M-static, `nicolas-riera/Quest1-SteamOS@b7467ff` `src/mdptest/mdptest.c:138-139`] | 1440×1600 | 2 OLED, Fresnel | slider ≈ 58.5–71.8 mm measured; panel and lens move together [C, `docs/quest1-lens.md`] | Quest1-SteamOS |
| **Steam Frame** | [O] | [O] | 2160×2160 | 2 LCD, pancake; lens+LCD ride the IPD rail [C, iFixit via https://www.thefpsreview.com/2026/09/25/ifixit-tears-down-the-steam-frame-batteries-and-lenses-come-out-easily-but-the-fan-is-buried/] | dial ≈ 58–70 mm [C, https://vr.org/steam-frame-specs] | spec digests (Valve wiki 403) |

### C.3 Per-eye FOV and lens centre

- **FOV values posted from a Quest 3 runtime** [C, the post does not label
  the tuple; L/R/U/D assumed]:
  - left eye ≈ −56.7°, +42.0°, +46.2°, −57.8°;
  - the right eye mirrors it.
  - Source: https://forums.developer.nvidia.com/t/cloudxr-js-6-2-0-right-eye-projection-offset-on-quest-3-and-quest-pro-while-quest-2-is-correct/381281
  - [D] The optical axis sits nasal and above each panel's centre. The
    visible image centre is therefore *not* the panel centre.
- **The same post, Quest 2 left eye** [C]: ≈ (−0.788, +0.825, +0.880,
  −0.916) rad.
- **Quest 1, reverse-engineered** [C, `Quest1-SteamOS` `docs/quest1-lens.md`]:
  - FOV up 47°, down 53°, outer 52°, inner 42°;
  - lens-to-screen offset ∓2.986 mm in x, −2.72 mm in y;
  - a per-unit decenter of a few pixels.
- **IPD-dependent offsets [D]:**
  - Where panel and lens move together (Quest 1, Quest 3, Quest Pro, Frame),
    only the eye translation changes with IPD. FOV and distortion do not.
  - On the Quest 2/3S the lenses move over a fixed panel, so the lens centre
    in panel pixels depends on the IPD step.

### C.4 Where a runtime applies the compensation

- **OpenXR.** Each `XrView` carries its own `pose` and asymmetric `fov`
  [M-static, https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrView.html].
  - Yaw cant goes in the view pose orientation (Index, Pimax) [C,
    https://docs.vulkan.org/tutorial/latest/OpenXR_Vulkan_Spatial_Computing/11_Canted_Displays/01_introduction.html].
  - In-plane roll and scan-out rotation are invisible to apps. The
    runtime's compositor or distortion pass absorbs them [D].
- **OpenVR driver API** (`ValveSoftware/openvr@09240643`,
  `headers/openvr_driver.h`) [M-static, per the survey]:
  - `IVRDisplayComponent`: `GetEyeOutputViewport` (where each eye lands in
    the output), `GetProjectionRaw` (tangent half-angles),
    `ComputeDistortion` (per-channel UV map).
  - `IVRServerDriverHost::SetDisplayEyeToHead` carries the eye-to-head
    transform, rotation included.
  - There is no scan-out rotation property, so rotation and roll have to be
    folded into `ComputeDistortion`.
  - Monado's SteamVR driver does exactly this: it multiplies the UV by
    `xrt_view.rot` before distortion (`monado@0d7970c9`
    `src/xrt/state_trackers/steamvr_drv/ovrd_driver.cpp` ≈ `:1464-1475`).
- **Monado** (`monado@0d7970c9`) [M-static, per the survey]:
  - `xrt_view.rot` is a 2×2 matrix per view (`src/xrt/include/xrt/xrt_device.h`
    ≈ `:56-104`), with helpers for identity/left/right/180.
  - The Rift S portrait panel uses `rotation_right`.
  - Index cant comes from the JSON `eye_to_head` into the view pose
    (`drivers/vive/vive_device.c`, `auxiliary/vive/vive_config.c`).
  - A 21° roll needs a non-axis-aligned `rot`, or the roll baked into the
    mesh [D].
- **ALVR / WiVRn** pass the client runtime's per-eye pose and FOV
  straight through. They have no per-headset tables
  (`alvr-org/ALVR@ebec107b` `alvr/server_openvr/cpp/alvr_server/HMD.cpp`;
  `WiVRn/WiVRn@bc3e374b` `common/wivrn_packets.h`) [M-static, per the
  survey].

### C.5 Where Meta keeps per-unit display calibration (names only)

- **Quest 1** [C, `Quest1-SteamOS@b7467ff` `docs/quest1-lens.md`]:
  - `/persist/calibration/display/{left,right}/…_screen_offset.json`
    (decenter, roll);
  - per-panel `*.mura` / `*.uniformity`;
  - `/persist/IPD_MIN` and `/persist/IPD_MAX`;
  - the lens distortion is in the runtime, not per unit.
- **Quest 2** [C, `quest-kexec-q2` `TODO.md`]:
  `/persist/calibration/camera_calibration.json` and
  `imu_calibration.json`. The repo's own rule: never mount persist from
  Linux.
- **Quest 3** [C, `Producdevity/ArmadaVR@272b6073`
  `docs/quest3-tracking-protocol.md`]: Meta's `libcalibrationmanager`
  references `HMDCalibration`, IMU/camera calibration JSONs and
  "left/right display offset" JSON paths. Exact paths are [O].
- **Our rule stands:** `persist` holds calibration and is never written or
  mounted read-write (`docs/RESEARCH_NOTES.md:260`; JOURNAL "Do not go
  here" item 16).
- **The Frame's** `vrconfig_write` writes into `/persist`
  (`valve-image-slot-in.md`). That fits a per-unit config store on the
  Frame too [C], and it is one more reason the FS-R-001 isolation must
  cover it.

### C.6 What the Steam Frame runtime expects (public information)

- **Public sources:** no Frame HMD config, driver JSON or geometry format
  has been published. The `frame-public` repos are lepton, Vulkan headers,
  developer tools and waydroid forks [M-static, per the survey's listing].
- **The only public SteamVR HMD-geometry precedent** is the lighthouse JSON
  that Monado parses for the Index [M-static, per the survey]:
  - per eye: `eye_to_head` 3×3, `intrinsics`, per-channel `distortion`
    {`center_x`, `center_y`, `coeffs`};
  - device level: `eye_target_width/height_in_pixels`,
    `lens_separation`.
- **Whether the Frame uses that format is [O].**
- **Practical consequence [D]:** a Quest 3 SteamVR path will need its own
  display component, as Quest1-SteamOS built for the Quest 1. It must
  supply:
  - eye-to-head transforms (IPD translation, rotation only if Meta's
    runtime reports any);
  - per-eye asymmetric projection;
  - a distortion function that folds in the 180° plus ≈ 21° roll and the
    per-channel lens model.
  The ground truth is Meta's own runtime (`xrLocateViews` under stock
  Horizon), which would be a PM-approved read-only capture.

### C.7 Implications for the test pattern [D]

- **Roll.** Expect each eye's image to look rolled by about 21°, possibly
  in opposite directions per eye, on top of the 180° flip. One horizontal
  line through each half's centre lets the PM report the tilt direction
  per eye.
- **Markers.** Make them chiral as well as eye-distinct (e.g. an arrow or
  "L" plus the bar counts), so flip and eye-swap can be told apart.
- **Off-centre.** Each eye's visible centre is offset nasally and
  upwards. Keep content inside the 480/456 px recovery margins, and don't
  read "off-centre" as a fault.

## D. Next three changes for the stage-3c display run (ranked)

All three stay inside the current write classes: the same atomic commit,
read-only probes, and the reviewed backlight value. The run structure is
unchanged: run 1 consumes the splash, lastclose, then run 2 does a full
modeset.

### D1. Commit 4 rects × 1032 px, one per layer mixer (the fix)

What to change in `fs-pattern`:

- **Layout.** Replace the run-2 split layout (2 × 2064) with **4 planes**:
  - `SRC_X` = `CRTC_X` = 0, 1032, 2064, 3096;
  - `SRC_W` = `CRTC_W` = 1032, full height;
  - no scaling;
  - global coordinates, `sspp_layout` left unset.
- **Planes.** First choice: **VIG0–VIG3** (DRM ids 71/97/100/103 on v66),
  confirmed read-only from each plane's `capabilities` blob (`pipe_idx`;
  no `primary_smart_plane_id`). This is the layout the kernel's own splash
  handoff staged, and it needs no multirect.
  - Fallback: the stock pairs, DMA3 rect 0+1 for x 0–2063 and DMA2
    rect 0+1 for x 2064–4127.
- **zpos.** Set it explicitly in the same commit, e.g. 0 on all four.
  That gives two contiguous planes per half at one stage, which is legal.
- **TEST_ONLY order.** The 4-plane layout goes first. Keep 2 × 2064 only as
  a TEST_ONLY probe (logged, never committed lit). It is now known to
  garble.
- **Unchanged:** XR24 linear, no clock or bandwidth properties (the kernel
  votes the 550 MHz / 16 GB/s maximum), no DSC or topology properties.

Evidence:
- §A.4: a rect is limited to ≈ 1128 px at 550 MHz, the SDE kernel does
  not check this, and mainline splits on the same criterion.
- §A.3: the stock and splash layouts are both one rect per LM.
- §B.1: QK2's purple-block garble was cured by one plane per mixer.
- J-108: the run-2 layout and the stock capture.

### D2. Read-only proof of the scan-out path, before and after the run-2 commit

Record, small and bounded (the serial line lost bytes before):

- **Underruns:** `/sys/kernel/debug/dri/0/encoder<id>/status`, which prints
  "intf / vsync / underrun" counters per physical encoder
  (`sde/sde_encoder.c:5330-5352`, `:5556`). Expected: underruns rising
  under 2 × 2064 (if probed), flat under 4 × 1032 [C].
- **Staging and votes:** `crtc<id>/status` (mixers, per-plane stage,
  src/dst, multirect) and `crtc<id>/state` (core_clk and bandwidth
  votes), to confirm the staging the kernel actually programmed.
- **TE and BLU activity:** `te-edge-isr` / `blu-pwm-isr` deltas over 2 s,
  plus `measured_fps`. These compare against the stock lit signature
  (≈ 182/s, 89.8 fps; §A.6).
- **From our own DRM fd:** connector `topology_name` and the mode's
  `topology=` from `mode_properties` (GET ioctls only).

Caveat: this needs debugfs **mounted inside our own initramfs**. That is
not a device-persistent write, but it is a new action in the image. It
goes through the normal adversarial review and the PM's classification
before the run (J-107 scope).

Evidence: §A.6, §A.8 item 12, `oculus-linux-kernel-yusuf.md` §4.1.

### D3. Make the pattern diagnose layout and eye mapping, not just "lit"

What to change:
- Give each of the 4 LM quadrants its own marker (for example 1, 2, 3 and
  4 bars) inside the existing per-half design. Keep the dark-grey field and
  the per-run challenge characters.
- Make the markers chiral (an arrow or "L") so the PM can tell a flip from
  an eye swap.
- Add one horizontal line through each half's centre so the PM can report
  the ≈ 21° roll direction per eye (§C.1, §C.7).
- Keep the 180° in-buffer rotation per half.
- Add a short, explicit PM reading question: which quadrant marker
  appears in which eye, and in which orientation.

What this gives us:
- A residual staging fault shows *which* LM got *which* source.
- The open DSI0 ↔ eye question (§A.1) and the per-panel rotation are
  answered in the same run (§C).

Geometry note: the cant, lens offset and IPD compensation are runtime
transforms (§C). They are not needed in the test pattern beyond keeping
text inside the recovery UI margins (480/456 px, `display-bringup-quest3.md`
§2.1).

Evidence: §B.4 item 5, §A.1 [O] eye mapping, §C.

### Not recommended now

- **Voting stock clocks.** It only lowers power. Max votes are safe for a
  ≤ 10 s hold.
- **UBWC.** It is impossible with a dumb buffer and needs gralloc or a
  GPU allocator.
- **Mode timing@1.** Its 1552-px halves still exceed the per-rect limit
  unless split into 4.
- **Any DSC or PPS change.** Kernel- and panel-side; QK2's DSC suspicion
  was wrong.

## Licence check (2026-10-12)

Scope: `machachu56/quest-kexec-q2`, branch `quest2-port`, head
`9c96c192d4a4a80f95ba0013294977e85c6eae11` (author "Pol", 2026-10-07; the
branch head has not moved since §B.1). Read through the GitHub web UI, the
REST API and raw file views only; nothing was cloned or downloaded [M-static].
This closes the [O] licence item in §B.1 and `stage3c/DESIGN.md` Q20.

- **Repo licence: GPL-2.0.** The only licence file in the whole tree is the
  root `LICENSE`, the standard unmodified GPLv2 text ("Version 2, June 1991",
  no program-specific copyright line, no exceptions, no "or later" applied).
  GitHub detects it as `gpl-2.0` / SPDX `GPL-2.0`. The README says
  "GPL-2.0. See `LICENSE`." and credits YusufOzmen01/quest-kexec (Quest Pro)
  and provide-salad/kexec-at-home as its base. There is no `COPYING`,
  `NOTICE` or `licenses/` directory (recursive tree, not truncated).
- **Per-component differences (file headers):**
  - `module/loader.c`: `SPDX-License-Identifier: GPL-2.0`, `MODULE_LICENSE("GPL")`,
    no copyright line.
  - `tools/tests/ion2kms/ion2kms.c` (the two-half-width-plane test client
    §B.1 cites): `SPDX-License-Identifier: GPL-2.0`, no copyright line.
  - `monado/drivers/quest2/q2_driver.c` and `monado/target_builder_quest2.c`:
    `Copyright 2026, quest-kexec contributors` +
    `SPDX-License-Identifier: BSL-1.0` (Monado's licence), so the Monado
    driver is BSL-1.0, not GPL-2.0.
  - `patches/gamescope/0003-drm-split-layers-across-two-planes-for-dual-LM-SDE.patch`
    (the split-planes fix): a bare diff of `src/Backends/DRMBackend.cpp`,
    no From/Subject header and no licence or copyright line. Like the other
    `patches/` (gamescope, mesa, monado) and `kernel/patches/` files, it
    modifies an upstream file and in practice falls under that upstream
    project's licence; the repo's GPL-2.0 `LICENSE` does not change that
    (upstream licences not re-checked here).
- **URLs:**
  - https://github.com/machachu56/quest-kexec-q2/blob/quest2-port/LICENSE
  - https://api.github.com/repos/machachu56/quest-kexec-q2/license?ref=quest2-port
  - https://raw.githubusercontent.com/machachu56/quest-kexec-q2/9c96c192d4a4a80f95ba0013294977e85c6eae11/README.md
  - https://raw.githubusercontent.com/machachu56/quest-kexec-q2/9c96c192d4a4a80f95ba0013294977e85c6eae11/tools/tests/ion2kms/ion2kms.c
  - https://raw.githubusercontent.com/machachu56/quest-kexec-q2/9c96c192d4a4a80f95ba0013294977e85c6eae11/monado/drivers/quest2/q2_driver.c
  - https://raw.githubusercontent.com/machachu56/quest-kexec-q2/9c96c192d4a4a80f95ba0013294977e85c6eae11/patches/gamescope/0003-drm-split-layers-across-two-planes-for-dual-LM-SDE.patch

**What it means for us [D]:** nothing changes. We copy no code from QK2 under
any of these licences: our `fs-pattern` one-plane-per-mixer layout is our own
implementation of a published technique, and the repo is cited as a
precedent only (stage-3c README credit, DESIGN E12). Ideas and facts
(the "one half-width plane per mixer" finding) are not covered by the GPL;
a citation with URL and commit is enough. If we ever *did* copy code, the
rule would be per file: GPL-2.0 by default (repo `LICENSE`; SPDX
`GPL-2.0` in the files checked, `loader.c` and `ion2kms.c`; other files'
headers not read), BSL-1.0 for the Monado driver files, and the
upstream project's licence for each `patches/` diff. The stale "licence to
check" notes (§B.1, `stage3c/README.md`, `stage3c/IMAGE.md`, DESIGN Q20) can
be closed by the PM pointing at this section.
