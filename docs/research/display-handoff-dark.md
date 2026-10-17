# Quest 3 trial (iii): why the panels stayed dark

Question (2026-10-10): trial (iii) committed and held a frame, so why did
no light reach the PM's eyes? What does the next image have to do
differently?

This is an offline, read-only investigation. No device was touched. Nothing
was downloaded and nothing was committed. Python was run with `-I -B`, and
the scripts and unpacked copies are in the session scratchpad, not in the
repo.

Tags: [M] hardware output or log · [M-static] artifact, cited by path:line
or address · [D] derivation · [C] hypothesis or external claim · [O] open.

## Sources and versions

**Kernel source: v66 (the nearest available), not v72 or v2.7.**
- Tree: WSL `~/work/fs006-kernel/src`, Meta commit `23c97b254` "build:
  5010519.0.510". Unit 1 runs `.511`,
  `5.10.198-01402-g1c5986fe21ee`. That this tree matches the
  running binary exactly is [C].
- Paths below are relative to `techpack/display/msm/` unless shown in full.
- v2.7 (`~/work/kgate27/src`, `dbc2bc83`) is used **only** for comparison.

**Binary checks (v66, the module that actually ran):**
`firmware/quest3/extracted/v66_unit1_slotA/vendor_ramdisk/lib/modules/msm_drm.ko`.
- sha256 `17c187ec…`; vermagic `5.10.198-01402-g1c5986fe21ee`.
- It comes from vendor_boot `1e3b3762…`, the hash in
  `devices/quest3/stage3a/IMAGE.md:43`.

**Device tree:** v66 base DTB decompiled, `~/work/dtdiff/v66.dts`. The
PVT1.1 dtbo (`~/work/fs006-power/dtbo/dtbo10.dts`) does not touch the
display.

**ABL:** Meta's v66 bootloader; its boot-path behaviour is summarised as
findings in §1 *[removed for publication]*.

**Recovery:** `…/recovery.img` (sha256 `9dabc752…`), ramdisk unpacked
read-only into the scratchpad.

**Trial evidence:**
- FS-A-010 (private review record) (FSP1 record, attempt log, capture);
- stage-1 dmesg in FS-A-005 (private review record).

Both are `fastboot boot`s through the same v66 ABL.

**Trial (iii) captured no dmesg.** This is the biggest gap in the evidence.

---

## 0. Verdict

**Most likely mechanism [D, from v66 source and the boot-path findings of
§1; the root cause itself is still open]:**

1. On `fastboot boot`, ABL clears the screen to black just before it starts
   the kernel. It does not call its own display power-off routine (§1).
   The MDSS pipeline stays running into the kernel. Stage 1 proves this
   for the same path (`cont_splash enabled in 1 of 1`).
2. The kernel therefore takes over in **continuous-splash mode**. On v66,
   our first full-modeset commit goes through Meta's *splash-handoff* path
   (§3). That path:
   - never resets the panel;
   - never sends the panel "on" commands (sleep-out `0x11`, display-on
     `0x29`);
   - only re-sends the "pre-on" register set and reprograms the strobed
     backlight unit (BLU) timing.

   The commit therefore inherits whatever physical state the panel and BLU
   were in at handoff. **If that state was "not emitting", nothing we did
   could turn it on.**
3. Two hypotheses remain, and static analysis cannot tell them apart:
   - **H1:** at handoff the panel or BLU was physically off. The UEFI
     display driver, which sits below ABL and is not available locally, is
     the prime suspect.
   - **H2:** the handoff modeset's link-down/link-up without panel re-init
     left the panel's display driver IC (DDIC) without a usable image.

   **Both point to the same fix:** make the second enable a *full*,
   non-splash enable (option R3, §6). It uses Meta's normal screen
   off/on sequence and needs no forbidden write and no flashing.
4. **The "backlight changes blocked" premise does not apply to v66**
   [M-static]. `backlight_changes_blocked` exists only in the v2.7
   source. It is absent from the v66 source and from the v66
   `msm_drm.ko` binary.
   - On v66 the kernel reprograms the BLU at enable, at the default level
     1000/1000 (≤ 8.2 % duty).
   - Recovery's `panel0-backlight` = 127 write is effective on v66.
   - Candidate 2 in FS-A-010 (private review record) is
     therefore ruled out for v66.

---

## 1. Does ABL tear the display down on `fastboot boot`? (Q1)

**Findings on the boot handoff [D; removed for publication]:**
- On `fastboot boot`, ABL loads and authenticates the image, clears the
  screen to black (`ClearScreen`), and then starts the kernel.
- ABL has a display power-off routine (clear screen, then set the display
  power state off). It is used on its reset/shutdown and ship-mode paths.
  **No call to it was found on the direct `fastboot boot` → kernel path.**
  Indirect call chains were not traced exhaustively [D].
- "Blanking display due to inactivity" is also just `ClearScreen`. To ABL,
  "blank" means "draw black".
- ABL rewrites `/reserved-memory/splash_region` from the UEFI variable
  `DisplaySplashBufferInfo`, and powers the display down only if that DT
  node is missing. v66 has the node (`v66.dts:2597`, `reg 0xbfc00000
  +0x6f00000`).

**The kernel side, stage 1, same ABL path [M]:**
- `serial-session3…:462`: "mdss_0_disp_cc_pll0 PLL is already enabled".
- `:655`: "cont_splash enabled in 1 of 1 display(s)".
- That count is a **register readback**: a CTL block with an interface
  selected (`sde/sde_rm.c:2204-2212`). So ABL left the MDSS
  CTL → INTF path configured.
- The kernel cmdline carries ABL's `msm_drm.dsi_display0=meta,eureka_panel_sharp:`
  (`:12`).

**Conclusion [D]:**
- On `fastboot boot`, ABL draws black and hands over a *running* MDSS
  pipeline. It does not run its power-off routine.
- The PM's "went dark the instant the boot command ran" is fully explained
  by `ClearScreen`. "Dark" does not tell a lit black LCD apart from a dark
  backlight.
- What the UEFI display driver (DisplayDxe, in the xbl/uefi image, not in
  `firmware/quest3/`) does to the panel or BLU at ExitBootServices is
  **[O]**.

---

## 2. What state was the panel in, given `active=1`? (Q2)

**What FSP1 seq 34–40 show [M]:**
- CRTC 155 is `active=1` with mode 4128×2208@90, `fb=0`.
- Planes 71, 97, 100 and 103 are on CRTC 155 with `fb=0`.

**Where that state comes from [M-static, v66]:**
- It is exactly the state `sde_kms_cont_splash_config` fabricates at
  probe. `sde/sde_kms.c:3466-3640` sets `crtc->state->active = true`
  (`:3609`), the mode, `connector->state->crtc`, and the splash pipes
  staged on the CTL. The encoder side also sets `best_encoder`
  (`sde/sde_encoder.c:6270`).
- The four planes match a quad-pipe splash (4 mixers / 4 DSC).

**What the kernel knows and does not know [M-static]:**
- It builds this "active" state from **MDSS registers + DT only**. It
  never reads the DDIC power mode or the BLU.
- Its brightness is assumed, not read: `dsi_panel_bl_handoff` sets
  `bl_level` = max (`dsi/dsi_panel.c:1321`). Line `:1311` says "Ideally,
  we should read the backlight level from the panel".

**Answer [D]:**
- Yes, the kernel can believe the display is active while the panels are
  physically dark.
- `active=1` and `shown=1` say nothing about photons.
- The four staged pipes do show that MDSS was still scanning out ABL's
  buffer at handoff. After `ClearScreen`, that buffer is black.

---

## 3. The full-modeset path and the BLU on v66 (Q3)

### 3.1 No changes-blocked gate on v66 [M-static]

- `backlight_changes_blocked` appears in v2.7 (`sde/sde_crtc.c:973-1083`,
  `dsi/dsi_panel.h:182`).
- It appears **nowhere** in the v66 tree (`grep -rn`).
- It is also absent from the strings of the v66 `msm_drm.ko`. That
  binary does contain `blu_default_duty`, `fifo_trim`, `tokki_a` and
  `meta,cont-splash-handoff`.
- **Consequence:** `display-bringup-quest3.md` §1 ("changes start
  blocked") and §3 ("lowering brightness means unblocking") are v2.7
  facts. They do not apply to the kernel we run.

### 3.2 Why our commit was a full modeset [M] / [D]

- The TEST_ONLY attempts without `ALLOW_MODESET` returned −22. The split
  layout with `ALLOW_MODESET` was accepted.
- The no-modeset attempts touched only planes (objs=4). The accepted one
  added the CRTC and connector (objs=6).
- Why the plane-only swap was rejected is **[O]**.
- Whether Android's own first commit is a modeset, and so exercises the
  path below, is also **[O]**.

### 3.3 The first full modeset while splash is active (v66)

`is_skip_op_required()` is true while `is_cont_splash_enabled` is set
(`dsi/dsi_display.c:62`).

**Disable half (`msm_atomic.c:185-276`).** It runs because the old CRTC
is active and `best_encoder` is set:
- bridge disable → `dsi_display_pre_disable` → `dsi_panel_pre_disable`
  (`dsi/dsi_panel.c:5995`):
  - sets the Tokki-A BLU to level 0 (`:6010`). Level 0 is the minimum
    pulse, not zero (`:794-800`: at least guardband+2 internal lines,
    about 1 % duty) [D];
  - sends `PRE_OFF`, which the Sharp DT does not define;
- video engine off;
- `dsi_panel_disable` is **skipped** (`dsi/dsi_display.c:9100`), so no
  display-off or sleep-in;
- `dsi_display_unprepare`: panel unprepare and post-unprepare are
  **skipped** (`:9242`, `:9281`), but the host, link clock, controller,
  PHY and core clock are all turned off. The DSI link stops.

**Enable half (`dsi/dsi_drm.c:200-257`):**
- `dsi_display_prepare`:
  - powers the PHY and controller up again;
  - **skips** the soft reset and `dsi_panel_prepare` (no panel reset, no
    supply sequence);
  - because of `meta,cont-splash-handoff` (DT `v66.dts:16734`), re-sends
    the **pre-on** set via `dsi_panel_pre_enable`
    (`dsi/dsi_display.c:8542`, `dsi/dsi_panel.c:5616`). That set includes
    the "Backlight – set to 100%" BLU registers, page `0x23`,
    `B8`–`BF`.
- `dsi_display_enable` takes the splash branch (`:8862-8878`):
  - video engine on;
  - splash cleanup, which clears `is_cont_splash_enabled`;
  - **no `dsi_panel_enable`**, so the on-command set (sleep-out `0x11`
    + 120 ms, display-on `0x29` + 120 ms, `v66.dts:16807`) is **not
    sent**.
- bridge enable → `sde_connector_helper_bridge_enable` →
  `backlight_update_status` (`sde/sde_connector.c:1151-1183`):
  - brightness defaults to max (`:261`), so `bl_lvl` = 1000;
  - this leads to `dsi_panel_set_backlight` → Tokki-A, via the
    temperature work when `meta,temperature-dependent-backlight` is set.

**Answer [D]:**
- On v66 the BLU **is reprogrammed** by DCS at level 1000: pulse =
  internal vtotal × 82/1000, i.e. ≤ 8.2 % duty.
- It is not left at zero or blocked.
- The panel itself is never told to wake up. The kernel assumes ABL left
  it awake.

**The close path on v66 [M-static]:**
- `msm_lastclose` → `drm_client_modeset_commit_locked`
  (`msm_drv.c:1128`) disables the CRTC.
- By then the splash flag is clear, so this is a **full** panel off:
  display-off + 120 ms, sleep-in + 250 ms (`v66.dts:16805`), plus
  unprepare.
- The measured `close_ms=534` fits that (≈ 370 ms of DT waits plus supply
  sleeps) [D]. This turns `IMAGE.md` §4's "[O] on v66" into [D]. It is
  not optically confirmed, because the panels were never seen lit.

---

## 4. How Meta's recovery gets light (Q4)

**Recovery's path [M-static, recovery ramdisk]:**
- Recovery is entered by a normal ABL boot. It loads the same module set
  and uses the same `msm_drm.ko`.
- minui is a plain atomic DRM client (`display-bringup-quest3.md` §2.1).
- `init.recovery.eureka.rc:28` writes `panel0-backlight/brightness` = 127
  `on init`. On v66 this is **not** blocked. It is stored as
  `unset_bl_level` until the first enable (`sde/sde_connector.c:175-177`,
  `:837-852`, `:993`). The BLU then runs at about 500/1000, ≈ 4.1 % duty.
  [D]

**The difference [D] / [C]:**
- Recovery's kernel side is the same splash-handoff path as ours. Its
  backlight write is not what makes it lit: our path also reprograms the
  BLU, and at a higher level.
- **The likely difference is the ABL handoff state.**
  - A normal boot draws the Meta logo. The panel is visibly emitting when
    the kernel takes over, and the handoff path keeps it so.
  - A `fastboot boot` clears to black, and whatever the firmware leaves
    behind is inherited.
- So yes: our `fastboot boot` path is fundamentally different from
  recovery's **before** the kernel starts. It is the same afterwards.
- Whether a normal boot also clears or re-blits the logo, and what UEFI
  does at ExitBootServices, are [O].

---

## 5. What fs-pattern draws (Q5)

Previews are in `docs/research/pattern-preview/`. They were rendered by a
stdlib-only Python port of `fs-pattern.c:303-417` (v0.4) with its own
zlib PNG encoder.

**Validation:** for nonces `3f9c07ab` and `01234567`, the port reproduces
the C renderer's fixture statistics exactly:
- `lit_ppm=36070 / 35102`;
- `max=0x90`;
- `mean_x1000=19633 / 19509`.

The fixtures are `devices/quest3/stage3a/fixtures/render-*.txt`.

**Files (nonce `4e0addd8`, the trial-(iii) challenge):**

| file | what | sha256 |
|---|---|---|
| `pattern-4e0addd8-scanout-4128x2208.png` | the exact buffer: 8-bit grey, each half rotated 180° | `c135a402…` |
| `pattern-4e0addd8-viewer-1032x552.png` | what each eye should see (rotation undone), true levels, ¼ scale | `407ab203…` |
| `pattern-4e0addd8-viewer-1032x552-brightened.png` | the same, levels ×255/0x90 **for monitor viewing only** | `f70cad01…` |

**What to look for, per eye.** Each eye is 2064×2208 and sees one half of
the buffer.
- an almost-black field (0x10);
- a thin grey frame (8 px, 24 px inside the edge);
- a filled grey square of 126 px in the top-left corner;
- a thin cross at the centre (±184 px);
- above the cross, the **8 hex characters of that run's challenge**
  (trial (iii): `4E0ADDD8`), underlined. Glyphs are 105×147 px at level
  0x90. **They change every run;**
- below the cross: **one bar** on the link-1 half, **two bars** on the
  link-2 half (42×168 px).

**Limits:**
- Which eye shows which half is [O].
- The viewer render assumes the panel's 180° mounting undoes the in-half
  rotation, as fs-pattern intends [D]. If not, the image is upside down
  but still visible.
- The real image is **much darker** than the brightened preview.
- A lit black LCD shows a faint grey glow in a dark room [C]. Report "glow"
  versus "pitch dark" separately.

---

## 6. Options for a next image, ranked by safety (Q6)

All of these respect `display-bringup-quest3.md` §3. None writes
`blu_default_duty`, `blu_max_overlap_us`, `fifo_trim`,
`backlight_changes_blocked`, debugfs `override_default_duty`, or
`oculus,blu` `bootload`/`reset`, and none injects raw DCS. All stay
temporary (`fastboot boot` or no boot at all).

**R0: no boot, read-only, time-sensitive [C].**
- Idea: Android's `/sys/fs/pstore` may still hold the **trial-(iii)
  kernel console**: ramoops is active (`serial-session3…:214-216`).
- Read-only commands, for the Arbiter and PM to decide on: *[removed for
  publication]*.
- Identify the record by its `FS[<attempt nonce withheld>]` lines.
- The headset was cold-booted since the trial, so survival is uncertain.
- Every further reboot lowers the odds.

**R1: no boot, read-only.** Record a "lit" signature in Android and in
stock recovery, to compare against later:
- the `te-edge-isr` and `blu-pwm-isr` counts in `/proc/interrupts`,
  sampled 2 s apart. These are panel TE and BLU-PWM monitor IRQs on
  `tlmm 110/109` (`dsi/dsi_panel.c:3555-3586`, DT `v66.dts:16733`, `:16738`);
- `/sys/class/drm/card0-sde-crtc-0/{backlight_event,backlight_timing,active_event,measured_fps}`;
- `/sys/class/backlight/panel0-backlight/{brightness,actual_brightness}`.

**R2: same risk as trial (iii).** Stage 3a unchanged, plus read-only
probes from our own init:
- a short filtered `dmesg` (`dsi|sde|drm|blu|WARN`);
- the TE and BLU IRQ counts **after modules (handoff), before the commit,
  mid-hold and after close**.

How the results separate the hypotheses:

| observation | reading |
|---|---|
| no BLU edges at handoff | H1 (BLU off) |
| no TE edges at handoff | H1 (panel not scanning) |
| TE and BLU edges at handoff that stop after the commit | H2 |

Caveats:
- Pulses on the monitor GPIO do not by themselves prove the LEDs are
  powered [C].
- Keep the record small, because the serial line lost bytes (FSB1
  line-count).

**R3: adds one standard panel power cycle; the most plausible way to get
light.** Run `fs-pattern show` **twice**. The binary is unchanged; only
`fs-display` and the timing change.

How it works:
- Run 1 consumes the splash handoff, exactly as trial (iii) did.
- Its close performs the v66 lastclose full panel off (§3).
- After a pause (≥ 2 s suggested [C]), run 2 finds the CRTC inactive.
  fs-pattern then picks the expected 4128×2208@90 mode with
  `ALLOW_MODESET` (`fs-pattern.c:710-722`).
- The driver then takes the **non-splash** path: supplies, reset
  (`v66.dts`: reset `<0 20>, <1 20>`), pre-on set, on set (sleep-out,
  display-on), video engine, then BLU timing at the kernel default.

Why it is acceptable:
- This is Meta's ordinary screen-off/screen-on sequence. Android runs it on
  every sleep and wake [D].
- It is one off→on transition, not a repeated flash.

Caveats:
- BLU at level 1000 = 8.2 % duty, Meta's normal maximum.
- Optional: write `127` to `/sys/class/backlight/panel0-backlight/brightness`
  before run 2. That is exactly Meta's recovery value
  (`init.recovery.eureka.rc:28`) and gives ≈ 4.1 % duty. This write is
  not on the §3 list, but it is a new write: Chair/PM decision.
- Not exercised offline.
- R2's probes can ride along.
- Time-box the run as before: no fan, no tsens (§3 of the bring-up
  research).

**R4: different environment; Chair decision.**
- Run the client inside stock recovery, booted normally (lit). This means
  pushing fs-pattern to the RAM-backed `/tmp` and stopping recovery's UI
  so we can become DRM master.
- No flashing, but it is a state change on a Meta environment.
- It tests our client on a lit pipeline, not our boot path.

**Routes that need a Chair decision (stated plainly):**
- If R3 is still dark and R2 shows no BLU or TE activity, the remaining
  levers are all outside the rules:
  - raw DCS (sleep-out, display-on, BLU registers);
  - `oculus,blu` reset or bootload;
  - `blu_default_duty`, `fifo_trim` or overlap writes;
  - a non-temporary boot (anything that keeps ABL's logo splash alive
    needs a flashed recovery or boot image).
- These are forbidden under §3, or need flashing. Each needs a Chair
  decision.
- There is no temporary boot path in which the ABL logo survives:
  `fastboot boot` is the only one. A v4 boot image cannot carry a DTB,
  because the DTB lives in vendor_boot [M-static, header v4].

---

## 7. Corrections and open items

**Corrections:**
- `display-bringup-quest3.md` §1/§3: on v66 the backlight is **not**
  blocked, and BLU writes from the stock driver are live (§3.1 here). The
  "changes blocked" citations are v2.7 only.
- `display-bringup-quest3.md` §1 item 2: "the panels keep scanning whatever ABL
  left" holds for MDSS. But on `fastboot boot`, what ABL leaves is a
  cleared, black screen (§1).
- `display-bringup-quest3.md` §5 [O3] (and the §2.3 "splash handoff" note): answered for v66. The first
  commit was a full modeset through the splash-handoff path (§3.3).

**Open:**
- [O] What UEFI DisplayDxe does at ExitBootServices (image not
  available).
- [O] Why the plane-only TEST_ONLY attempts returned −22.
- [O] Whether Android's first commit is a modeset.
- [O] Which eye shows which link.
- [O] The cause of the 30 → 45 °C battery rise. The lit ABL fastboot screen
  during the roughly 14 + 9 min dwells is a candidate, not established.
- [O] Whether `disp-virt` exists in our environment. No "thermal zone"
  error appears in the stage-1 dmesg, so the Tokki-A temperature-work
  path is presumably active [D, weak].
