# Quest 3 panel and backlight: what the public web says

*Edited for publication: names and links removed or paraphrased.*

Question (2026-10-10): after trial (iii), the Quest 3 panels emitted no
light. Is there any public information that helps explain the result or
points to a fix? The trial setup was `fastboot boot` of the stock v66
kernel with our initramfs, then plain atomic DRM with a dumb buffer, a full
modeset, 4128x2208@90, and a split across two planes on one DSI connector.

This was online research only, using WebSearch and WebFetch on
documentation and discussion pages. No device was touched, nothing was
installed, and nothing was committed. Two SID papers were fetched as PDFs
(documents, not binaries). They landed in the session's tool-results
folder and were converted to text in the scratchpad with the
already-installed `pdftotext`.

Tags: [C] external claim (what a source says, with its URL) · [O] open /
unknown / nothing found · [D] my own derivation or inference from [C]
items, not stated by any source.

Companion offline analysis: `docs/research/display-handoff-dark.md`.

---

## 1. Quest 3 display hardware

### Confirmed by Meta or by teardown

- **Two fast-switch LCDs, one per eye, at 2064x2208 per eye, 1218 PPI,
  25 PPD, behind pancake lenses.** [C]
  - Meta's own SID 2025 paper on the Quest 3S has a table comparing Quest
    2, 3S and 3: "Fast-Switch (FS) LCD", Quest 3 "2064 RGB x 2208",
    "1218 PPI | 25PPD", "Pancake lens".
    https://sid.org/Portals/sid/Files/SID-Digest/docs/39-4.pdf
    (Xiang et al., *Quest 3S Immersive Display with High Visual Fidelity*,
    SID 2025 Digest pp. 523-525. High quality: primary source.)
  - iFixit: "two LCD" in the Quest 3, against a single LCD in the 3S.
    https://www.ifixit.com/News/101990/metas-quest-3s-is-just-a-revamped-quest-2-and-its-the-better-for-it
    (Oct 2024.)
  - TechRadar, reporting iFixit's microscope work: 2064x2208 per eye,
    120 Hz.
    https://www.techradar.com/computing/virtual-reality-augmented-reality/meta-quest-3-teardown-video-shows-lower-price-doesnt-mean-low-quality
    (Oct 2023.)
- **Pre-launch firmware strings described a single combined LC display of
  4128x2208 at 90 Hz for "Eureka".** A 120 Hz config appeared later, in
  v49. [C] MIXED, 2023-01-11, citing a data-miner and Brad Lynch.
  https://mixed-news.com/en/new-details-about-the-meta-quest-3-display/
  Our 4128x2208@90 mode on one connector matches this firmware-level
  description of one logical display, even though there are two physical
  panels. [D]
- **Meta's own Quest 3 display paper exists but could not be read.** [C]
  - The 3S paper cites it as: Lee A. et al. (2024), *90-1: Invited Paper:
    Quest 3 Immersive Display with High PPI and Hybrid Backplane
    Technology*, SID Digest 55:1258-1261, doi:10.1002/sdtp.17772.
  - Wiley returned 403, and no open copy was found. [O]
  - This paper is the most likely public source for Quest 3 BLU timing,
    the DDIC and the backplane. It is worth getting through a library or
    an SID membership. [O]

### Panel vendor and DDIC: not established

- **Vendor:** no teardown names the Quest 3 panel vendor. [O]
  - Brad Lynch predicted "JDI and probably BOE" (MIXED, Jan 2023, link
    above). This was a prediction. [C]
  - A Display Tech Center show summary called BOE the "main supplier" for
    Quest 3 LCDs (Patreon, low-quality and second-hand). [C]
    https://www.patreon.com/DisplayTechCenter/posts/display-week-158955563
  - iFixit and heise say Meta buys Quest 2/3S panels from several
    manufacturers, so the pixel arrangement may vary. [C]
    https://heise.de/-9987611 (2024-10-20)
  - Sharp was reported as the largest Quest **2** display supplier
    (Nikkei, via MIXED). Nothing ties Sharp to the Quest 3. [C]
- **DDIC:** no source names it. "Novatek" is unsupported online. [O]
  - For the Quest 2, Meta says only that it "customized a DDIC" and used
    MIPI D-PHY with two ports. [C] (SID 2022 paper, below.)
- **iFixit Quest 3 chip ID** (2023-10-13) lists no display IC, DDIC,
  bridge or LED driver. [C]
  https://www.ifixit.com/Teardown/Meta+Quest+3+Chip+ID/165932
  - It does list an STMicro **STM32G071EB** Cortex-M0+ MCU and an SiLabs
    **EFM8BB51** 8-bit MCU on the headset board, with no role given. [C]
  - It also lists a TI **TPS65132L** dual-output supply. This part family
    is commonly used for LCD ±5 V bias. [C] for the part. Its role here is
    [O].
  - Whether either MCU is the "Tokki-A" BLU controller is pure
    speculation. [O]

### Backlight design

- **Quest 2 (primary source):** Kim et al., *High-PPI Fast-Switch Display
  Development for Oculus Quest 2 VR Headsets*, SID 2022.
  https://research.facebook.com/file/2816674991811976/High-PPI-Fast-Switch-Display-Development-for-Oculus-Quest-2-VR-Headsets.pdf
  - One 5.46" 1920x3664 LTPS fast-switch IPS panel. [C]
  - "Split backlight" with LED bars on the left and right sides
    (edge-lit). [C]
  - "B/L illumination: Global". [C]
  - Low persistence is achieved "by controlling the duty ratio in the
    backlight timing". [C]
  - "After all of the gate lines are scanned-out ... we wait until the LC
    settles down and then the backlight is illuminated for a short
    time." [C]
  - Frame rate is set by vertical porches, with a fixed scan-out time.
    [C]
  - Typical brightness is 100 nits. [C]
- **Quest 3S (same panel as Quest 2):** one LCD with "two separate
  backlights (one for each eye)". [C] (SID 2025, link above)
  - It uses temperature-dependent BLU timing driven by a "virtual
    temperature sensor". [C]
  - It constrains a left-right "BLU offset". [C]
  - It uses content-adaptive duty control (CADC), which modulates
    backlight PWM per content. [C]
- **Quest 3:** neither of these papers states its BLU layout. [O]
  - VR.org says the backlight is "always on" in the sense that there is
    no local dimming. [C]
  - Lynch said local dimming was not expected. [C]
  - A Blur Busters forum post claims all headsets, Quest 3 included,
    strobe. Another forum post claims the Quest 3 does not. Neither gives
    a measurement. [C], low quality.
    https://forums.blurbusters.com/viewtopic.php?p=121116
  - Our own finding of a strobed BLU capped at about 8.2% duty comes from
    the kernel and DT, not from any web source. [O] online.
- **No public mention of "Tokki", "oculus,blu" or "BLU firmware"** was
  found in any search. [O]
- **Quest Pro, for contrast:** a mini-LED backlight with about 500
  locally dimmable zones, giving 75% more contrast. Local dimming is
  opt-in per app. [C]
  https://www.meta.com/blog/vr-display-optics-pancake-lenses-ppd/ and
  https://mixed-news.com/en/meta-quest-pro-local-dimming-pc-vr/
- **Quest 3S:** the same panels and lenses as the Quest 2, 1832x1920 per
  eye. [C] heise / iFixit, links above.

---

## 2. Anyone driving Quest-class displays outside Meta's Android

Honest summary: **no public report was found of anyone lighting a Quest
2, 3, 3S or Pro panel from a non-Meta kernel or userspace.** [O]

- **postmarketOS:** a talk at the postmarketOS conference (2026-09-27,
  "Virtual Reality on PostmarketOS", HaeckseAlexandra) lists "initial
  support" for Oculus Go, Lynx R1, "META Quest 3S (panther)" and the
  upcoming Steam Frame. [C]
  https://pretalx.postmarketos.org/postmarketos-conference-2026/talk/8UMTPU/
  - The abstract gives **no** display detail for the 3S. [C]
  - The speaker's own demo uses a phone, not these headsets. [C]
  - The postmarketOS wiki and GitLab now redirect to `*.nura.eco` behind
    an Anubis bot wall, so the device pages could not be read. [O]
  - It is worth a manual browser look at the "Category:Headset" page and
    any `panther` device page. A working 3S display there would be the
    single most useful data point, because it uses the same XR2 Gen 2 SoC
    and the Quest 2-style BLU. [O]
- **Lynx R1 (XR2 Gen 1, close-to-mainline 6.13 kernel), per search
  snippets of the postmarketOS wiki:**
  - Panels are two JDI/BOE LPM021M528C. The panel drivers are WIP, and
    "mdss-mdp throws an error (-22)". [C]
  - The backlight is an MPS MP3387LGRT, marked unsupported. [C]
  - So on the one XR2 headset with an active mainline port, the display
    is **not** working yet. [C] (snippet only, page not readable)
- **A public community organisation:** no display, kernel-port or panel
  work is visible. [C] [removed for publication]
- **Quest 1 press coverage (Aug 2026):** coverage says no alternative OS
  has shipped for the Quest 1 and says nothing about display bring-up. [C]
  [removed for publication]
- **Older Quest 1/2 community tooling (2021 firmware):** no display
  work. [C]
- **Pico, HTC XR Elite, Quest Pro:** no custom-kernel display
  reports were found. [O]
- **Generic downstream-port analogue (unnamed device, MoKee kernel, in a
  pmaports snapshot):** "Display does also work" but brightness defaulted
  to zero and needed a manual `echo 127 > .../lm3530-backlight/brightness`.
  [C] https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/b82df54a3ebb4fee5655b2937054d4591ed7ce61
  - This shows only that a dark panel on a working pipeline is often just
    a backlight-enable or brightness problem. It does not show that our
    BLU behaves the same way. [D]

---

## 3. Qualcomm ABL and continuous splash on `fastboot boot`

### What stock CLO ABL does on `fastboot boot` (source-level, high quality)

The source is CodeAurora/CLO `abl/tianocore/edk2` QcomModulePkg, as
mirrored at https://github.com/David112x/edk2-android. Meta's ABL may
differ. Our own analysis of the v66 ABL boot path (`display-handoff-dark.md` §1)
is the authority for Quest 3.

- `CmdBoot` (`Library/FastbootLib/FastbootCmds.c`) does the following,
  in order. [C]
  1. Checks the boot preconditions and the image header.
  2. Calls `LoadImageAndAuth`.
  3. Calls `ExitMenuKeysDetection()`.
  4. Calls `FastbootOkay`, `FastbootUsbDeviceStop` and
     `ResetBootDevImage`.
  5. Calls `BootLinux(&Info)`.
- `ExitMenuKeysDetection()` (`Library/BootLib/MenuKeysDetection.c`,
  © 2016-2019 Linux Foundation) does this, if
  `FixedPcdGetBool(EnableDisplayMenu)`: [C]
  - cancels the key timer;
  - runs `gST->ConOut->ClearScreen(gST->ConOut);`
  - runs `RestoreBootLogoBitBuffer();`
  - This is a **framebuffer clear plus logo restore through the UEFI
    console**. It is not a panel power-down. [C]
  - It matches the PM's "screen went dark the instant `fastboot boot`
    ran", if Meta's ABL restores no logo. [D]
- `BootLinux` (`Library/BootLib/BootLinux.c`) calls
  `FreeBootLogoBltBuffer()`, then `ShutdownUefiBootServices()`
  (ExitBootServices), then `PreparePlatformHardware()`. [C]
  - Any panel or BLU power-off at handoff would live in the closed
    `DisplayDxe` ExitBootServices handler, which is not public. [O]
- `UpdateCmdLine.c` reads the UEFI variable `DisplayPanelConfiguration`
  (written by the closed DisplayDxe) and appends it verbatim to the kernel
  cmdline. [C]
  - So the `msm_drm.dsi_display0=...` string and any splash flags come
    from DisplayDxe, not from logic visible in ABL. [C]
  - No fastboot-boot-specific branch exists in `UpdateCmdLine`. [C]
- ABL also has `fastboot oem select-display-panel <x>`, which writes the
  UEFI variable `DisplayPanelOverride`. [C] (FastbootCmds.c)
  - On SM8150 MTP, `oem select-display-panel none` plus `reboot
    bootloader` made a following `fastboot boot` come up without the
    bootloader driving the panel. On HDK855 it was not enough alone. [C]
    https://lkml.iu.edu/hypermail/linux/kernel/2006.0/05991.html
    (LKML, June 2020; Linaro devs; reference boards, not Quest.)
  - **This is a persistent UEFI-variable write. It is a bootloader state
    change, so it needs a Chair decision if anyone proposes it for the
    Quest.** Also, "none" would remove the cont-splash handoff entirely,
    which is the opposite of what H1 wants. [D]

### Downstream SDE continuous splash (CLO display-drivers commits)

The source is a mirror of CLO `display-drivers` on git.evolution-x.org
(medium-high quality: real CLO commit text).

- `is_skip_op_required()` returns true when continuous splash is enabled
  (or for trusted VM). `dsi_ctrl_host_init()`'s parameter was renamed
  from `is_splash_enabled` to `skip_op`, with the comment that hardware
  operations are omitted for continuous splash. [C]
  https://git.evolution-x.org/anierin/display-drivers/commit/4b27380f07f648ff96f397ecf2e2f495db109af0
- `sde_rm_cont_splash_res_init` counts a display as splash-enabled only
  when its CTL block reports an active interface. That is a
  hardware-register readback, not a cmdline flag. [C]
  https://git.evolution-x.org/anierin/display-drivers/commit/2abcfa0acdc4221d369a970f75de0984ff58c8bb
- When splash is enabled, panel regulator votes are taken at probe and
  only dropped at suspend or in `cont_splash_res_disable()`. [C]
  https://git.evolution-x.org/anierin/display-drivers/commit/35b60f62087b404ad727798286649fdbbce5fec5
- Mainline DPU discussion says the bootloader-configured splash path can
  coexist with, and fight, the kernel's own path. The kernel is expected
  to inherit it, not override it. [C]
  https://lkml.iu.edu/hypermail/linux/kernel/2202.2/01145.html
- This lines up with our offline finding: on the first commit after
  takeover, v66 skips panel reset, sleep-out and display-on because the
  splash path says "already on". [D]
  - What the splash detection keys on (hardware readback) means ABL's
    `ClearScreen` would **not** turn splash detection off. The CTL/INTF
    stays active with a black buffer. [D]
  - So the kernel would still believe the panel is lit. If DisplayDxe
    actually cut panel or BLU power at ExitBootServices while leaving
    the MDP pipe running, that is exactly H1. [D]

### Community black-screen fixes (other SoCs, for pattern only)

- **SDM845 mainline:** a random black screen at panel init since about
  v6.5. The workaround is adding `console=ttyMSM0,115200` (a timing
  change). [C]
  https://gitlab.freedesktop.org/drm/msm/-/issues/46 and the Mobian
  commit
  https://salsa.debian.org/Mobian-team/mobian-recipes/-/commit/c8534fb089a11b19b9cb2930a765d0af82210cd2
  This is mainline msm, not SDE, so it is weakly relevant. [D]
- **STM32MP1:** the screen goes black at the kernel handoff while LCD
  power and backlight stay enabled. [C]
  https://community.st.com/t5/stm32-mpus-products/splashscreen-off-between-u-boot-and-kernel-stm32mp1/td-p/634756
  This is the opposite of our symptom (our backlight is off). [D]
- **AYN Odin 2 custom LinuxLoader** exposes `DisableDisplayHW` because
  mainline dispcc fails "if the display hardware is not disabled before
  exiting boot services". [C]
  https://renegade-project.tech/en/ayn-odin2/linuxloader
  This concerns mainline kernels and does not apply to stock v66 SDE.
  [D]
- **No source** was found specifically for "backlight off after fastboot
  boot" on any Qualcomm device. [O]

---

## 4. Strobed / low-persistence VR backlights

- **How the strobe is timed (Meta patent and paper):** US10522094B1
  (Facebook Technologies, priority 2016-04-01, inventors Richards, Patel,
  Shi), "Global illumination mode LCD for VR". [C]
  https://patents.google.com/patent/US10522094
  - A single controller drives both the data driver and the BLU. [C]
  - The BLU is off during scan-out and LC settling. It is enabled at
    t_i, after all rows are scanned and settled, and stays on until the
    frame ends. [C]
  - Example figures: an 11 ms frame, 3 ms scan, 6 ms LC transition and
    2 ms illumination. This is described "each frame". [C]
  - The patent does **not** say what happens when there are no new
    frames. [C]
  - The Quest 2 paper says the same thing (global flash after
    settle), and adds that illumination timing "has been optimized for
    each frame rate". [C]
- **The Quest 3S adds** temperature-dependent BLU delay, left-right BLU
  offset limits and per-content PWM (CADC). [C] (SID 2025)
  - All three imply software or firmware that sets BLU timing and duty
    at run time. [D]
  - Default values at kernel takeover are not described publicly. [O]
- **Generic strobe controllers** (Blur Busters / Zisworks open firmware)
  set strobe phase relative to VSYNC, with flash length as a separate
  parameter. [C]
  https://forums.blurbusters.com/viewtopic.php?p=28255
- **Can a static frame be lit without a compositor?**
  - No source answers this for Meta hardware. [O]
  - From the sources above: the strobe is tied to panel scan timing and
    per-frame-rate timing, not to new content. [D]
  - A DSI **video-mode** pipeline re-scans the same buffer every vsync,
    so a static dumb buffer still produces a per-frame scan that a strobe
    controller can lock to. [D]
  - Nothing in principle needs a compositor. What is needed is (a) the
    timing source the BLU locks to (TE, vsync or a DDIC output) actually
    running, (b) the BLU armed with non-zero duty and a valid phase, and
    (c) the panel out of sleep with display on. [D]
  - In **command mode** without autorefresh, a static buffer means no
    scans after the first one. Then a strobe that keys on scans might
    fire once or not at all. [D]
  - Our offline notes know which mode v66 uses for this panel. The web
    does not. [O]
- **No public description** of a Meta BLU "enable sequence", BLU MCU
  firmware or bootload requirement was found. [O]

---

## 5. Meta's public kernel repo (facebookincubator/oculus-linux-kernel)

- There are branches per device, including `oculus-quest3-kernel-master`
  (last updated 2026-09-25) and `oculus-quest3s-kernel-master`. [C]
  https://github.com/facebookincubator/oculus-linux-kernel/branches/all
- **Commit messages carry no information.** [C]
  - Every Quest 3 commit is an "Oculus Quest 3 kernel project build:
    NNNNNNN.NNNN.5x0" source drop or a "Re-sync with internal
    repository".
  - Our v66 tree is `23c97b2` "build: 5010519.0.510", dated 2024-07-07.
  - The newest is `bcbad93` "5243367.4880.520", 2026-09-25.
  - https://github.com/facebookincubator/oculus-linux-kernel/commits/oculus-quest3-kernel-master
- **Issues:** there are 6 open, none about display, panel, backlight or
  splash. [C]
  - #233 (2026-07-01) asks for missing source for the built-in STP staging
    driver.
  - The other issues are about manifests, debug configs, binder and
    syncing.
  - https://github.com/facebookincubator/oculus-linux-kernel/issues
- PR search for "display" gives 0 results. [C]
- So for Tokki, BLU or splash behaviour, the **source itself** (already
  analysed offline) is the only public material. There is no design
  commentary. [O]

---

## 6. Implications for our next attempt

### Evidence relevant to the run-twice proposal

The proposal: run the pattern twice, so the second run does a full off→on
modeset.

**For** (ranked):

1. **CLO SDE design.** CLO's own code skips hardware and panel operations
   whenever cont-splash is active (`is_skip_op_required`). That is the
   mechanism behind H2. [C+D]
   - A full disable then enable in the same boot takes the kernel out of
     the splash state. The second enable then has to run the panel's own
     power-on path: reset, on-commands (sleep-out, display-on) and BLU
     programming. [D]
   - This is the standard downstream behaviour, but no web source
     demonstrates it on Quest. [O]
2. **ABL behaviour.** CLO ABL's `fastboot boot` path only issues a UEFI
   `ClearScreen`, then hands off with the pipe still configured. Splash
   detection is hardware readback. [C]
   - So the kernel almost certainly took the "already on" branch on the
     first commit, which is the branch where panel init is skipped.
     [D]
3. **Strobe timing.** Strobe timing is per-frame and per-frame-rate
   (Quest 2 paper, patent, 3S paper). [C]
   - A clean full modeset gives the BLU path a fresh, consistent timing
     start, instead of inheriting whatever the bootloader left. [D]

**Against, or limits** (ranked):

1. **H1 may not be fixed by a second run.** If the closed DisplayDxe cut
   panel or BLU power at ExitBootServices while the kernel's regulator
   or GPIO bookkeeping still says "on", the off→on cycle may not restore
   power. [D]
   - This happens if the driver's disable path skips "already off"
     resources, or if the BLU MCU needs a reset or bootload the kernel
     only does at probe.
   - No public source shows what DisplayDxe does at ExitBootServices.
     [O]
2. **A full off→on is a new code path on this unit.** It sends
   panel-off and on-commands and power-cycles rails through Meta's
   unmodified driver. [D]
   - That is stock driver behaviour, not raw DCS injection. But it should
     be named as a state change in the trial plan, under
     headset-permissions.
3. **Missing Meta services may still leave it dark.** If the BLU duty or
   timing is normally set by a Meta userspace service (CADC-like
   per-content duty, a temperature-driven delay), a kernel-only modeset
   might enable the BLU at zero or default duty. [D]
   - The 3S paper shows these knobs exist. [C]
   - Their defaults at boot are unknown. [O]

### Concrete new ideas (no flashing, no raw DCS, no BLU duty, overlap,
fifo, bootload or reset writes)

1. **Read-only snapshot before and after each commit, in the same
   trial.** Capture:
   - the debugfs/sysfs view of the DSI display (panel power state,
     `cont_splash` flags if exposed);
   - regulator and GPIO state for panel reset, the bias supply (the
     TPS65132-class ±5 V bias, if the DT names it) and the BLU enable
     line;
   - the BLU driver's read-only status nodes.

   This tells H1 (rails or BLU actually off) apart from H2 (rails on,
   panel asleep) without guessing. It is read-only and allowed. [D]
2. **Check the actual cmdline the kernel received** (`/proc/cmdline`)
   for the DisplayDxe-supplied `msm_drm.dsi_display0=` string and any
   splash or skip flags. ABL appends `DisplayPanelConfiguration`
   verbatim, so this shows what the bootloader told the kernel. [C+D]
3. **Make the second run a true disable.** Commit the CRTC with
   `ACTIVE=0` and the connector detached, wait at least a few frames,
   then do a fresh enable. A mode change alone might be treated as
   seamless and stay on the skip path. [D]
4. **Hold the pattern for several seconds after each enable, and log
   vblank or pageflip events.** This confirms the scan clock is running,
   which matters for a strobe that locks to frames. If the panel is in
   command mode, do one or more additional page flips of the same
   buffer, so the BLU has scans to lock to. This is normal DRM use, not
   DCS. [D]
5. **Manual follow-up (not automated):** have someone open the
   postmarketOS (nura.eco) wiki in a normal browser and read any Quest 3S
   (panther) device page. A working 3S display there would show how
   someone else got light from the same SoC family and BLU style. [O]
6. **Get the SID 2024 Quest 3 display paper** (doi:10.1002/sdtp.17772)
   through a library. It is the one public primary source likely to
   describe Quest 3 BLU timing and the DDIC. [O]

### Ideas a source suggests that need a Chair decision

- `fastboot oem select-display-panel <x>` (SM8150 LKML thread) writes a
  persistent UEFI variable (`DisplayPanelOverride`).
  - That is a bootloader state change. **Chair decision required.**
  - It is also probably counter-productive here, because it removes the
    splash handoff. [D]
- Any route that writes the BLU duty or timing directly, or resets or
  bootloads the BLU MCU, falls under the standing restriction. **Chair
  decision required.** No web source proposes this for Quest. [O]

---

## Source quality notes

- **Primary and strong:**
  - the Meta SID 2022 (Quest 2) and SID 2025 (Quest 3S) papers;
  - the Meta patent US10522094B1;
  - the CLO ABL source (GitHub mirror, generic CLO; Meta's ABL may
    differ);
  - the CLO display-drivers commits (mirror);
  - the GitHub branch and commit listings for Meta's kernel repo.
- **Secondary:** iFixit (chip ID, Oct 2023), heise / TechRadar / MIXED
  journalism (2023-2024).
- **Weak:**
  - Blur Busters forum posts;
  - the Patreon trade-show summary;
  - postmarketOS wiki content seen only in search snippets (the pages
    were blocked).
- **Searched with no result:** "Tokki", "oculus,blu", Quest panel DDIC
  vendor, any Quest custom-kernel display success or black-screen
  report, and Meta kernel commit messages about display.
