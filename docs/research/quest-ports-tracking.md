# Quest Linux/SteamOS ports: how far tracking got, and how to validate without a rig

**Status:** research only, rev 0.1, 2026-10-15 (rev 0: 2026-10-14, J-167; rev 0.1 adds the
Chair survey cross-check addendum at the end). No device was touched. Nothing was built,
run, downloaded (no binaries or models) or disassembled. Companion to `tracking-input-route.md`
rev 2.2 and `oss-tracking-survey.md` rev 1, which are **not** edited here (corrections are listed
in §3 for the next revision).

**Why:** the PM reports that other community ports reached 3DoF **and** 6DoF on Quest headsets,
and rules out Lighthouse and mocap as references (J-167). Our docs said no open project had
reached 6DoF on a Quest.

**Method:**
- Public web search, GitHub/GitLab/Codeberg APIs, and fresh clones in WSL `~/work/quest-ports/`
  (read only; nothing built or run). Clone heads:

  | Repo | Head | Date |
  |---|---|---|
  | cstahly/quest1-bootloader-to-VR | `18532a559` | 2026-10-05 |
  | Block-Flock/pmaports-oculus-monterey | `7ce0ccce4` | 2026-08-26 |
  | Block-Flock/monado-oculus-monterey (branch `oculus-monterey`) | `e160863ad` | 2026-08-22 |
  | nicolas-riera/Quest1-SteamOS | `b7467ff15` | 2026-10-07 |
  | machachu56/quest-kexec-q2 (branch `quest2-port`) | `9c96c192d` | 2026-10-07 |
  | YusufOzmen01/quest-kexec | `e61edbd7f` | 2026-10-04 |
  | Producdevity/reframed-vr | `c704df762` | 2026-10-15 |
  | CreoleVR/QuestLHSync | `d941d4ec9` | 2026-10-14 |
  | marcsabat/slam_tracking_comparison | `416a5a20b` | 2026-04-06 |
  | leo-n64/linux-vr-pro | `4f0d693cb` | 2026-09-25 |

- Forks checked by API: Noculus-VR/Quest1-SteamOS (CI-only changes), Mac898/quest-kexec branch
  `quest2-support` `2d42980a` (board descriptors only; no tracking).
- Monado MRs and issues, and pmaports MRs, searched with the GitLab API for quest, oculus,
  monterey, hollywood, eureka, syncboss and panther.
- **Gaps:**
  - reddit.com is not reachable by our tools, so Reddit posts were not read.
  - The Nura (postmarketOS) wiki is behind a bot check; we did not try to get around it.
  - FXR was not searched (not public).
  - XDA only through search snippets: device threads, nothing on tracking.
- Several repos record reverse engineering of Meta binaries (disassembly, symbol dumps, Frida
  injection). Those parts are named here as **pointers only** (D-T10). We did no reverse
  engineering ourselves, and nothing from them goes into our code.
- `<private note, withheld>` was not read or quoted.

**Tags** (FS-R-001): **[M-static]** read in a named file or source · **[D]** derived ·
**[C]** unconfirmed (web or repo claim, not checked on hardware) · **[O]** open.

---

## 0. The answer in brief

1. **Someone did reach 6DoF on a Quest, experimentally.**
   - Who: **cstahly/quest1-bootloader-to-VR** (MIT), on the **Quest 1** running Nura/postmarketOS.
   - What: live **Basalt** VIO (mateosss fork `df6e970`) on the headset, fed into Monado through
     an opt-in pose-mailbox patch.
   - Shown to a wearer in bounded trials: walking worked "in full light" [C].
   - Quality: the owner rejected it. It lost lock with quick movement, lagged and stuttered, and
     failed in low light.
   - It was never installed as the default; the shipped scene stays 3DoF [C, `docs/tutorial/09`].
   - **No project has reliable 6DoF on any Quest.**
   - **No project has 6DoF controllers on any Quest.**
2. **3DoF is common and works:**
   - Quest 1: Quest1-SteamOS (SteamVR) and Block-Flock/cstahly (Monado);
   - Quest 2: quest-kexec-q2 (Monado);
   - head **and** Touch controllers, rotation only.
   All of them use the SyncBoss IMU.
3. **"6DoF" in quest-kexec is Meta's own tracker:**
   - what runs: Meta's `trackingservice` under a second, kexec'd **Android** on Quest Pro;
   - its log: `Frame: v8, 6DoF, active: true` [C, `docs/KEXEC_ANDROID_WORKING_SETUP.md:240`];
   - it is not an open or Linux tracker, so it is not a usable precedent for us (PM: no Meta
     provider).
4. **Validation in the community is weak.** Nobody compared against Horizon. The best practice
   found (cstahly) was:
   - stationary-clip drift;
   - return to a marked spot;
   - "intended 50 cm" moves;
   - replay determinism;
   - IMU and gyro self-consistency;
   - wearer judgement.
   Our plan in §5 makes these quantitative and **identical under Horizon and FrameShift**, using
   physical fixtures as the shared reference.
5. **Reusable cleanly:**
   - cstahly's MIT tools and its BSD-3 Basalt patches;
   - one confirmed upstream Basalt multi-camera bug;
   - its Monado pose adapter design;
   - QK2's BSL Monado driver structure;
   - an MIT precedent for logging Horizon poses (KirvilNET/QuestSLAM).
   Details in §4.

---

## 1. Project-by-project

### 1.1 cstahly/quest1-bootloader-to-VR (Quest 1, Nura): the only open 6DoF attempt that ran live

- **Licence:** MIT for the repo; `patches/` keep upstream licences (Monado BSL-1.0, kernel
  GPL-2.0; Basalt, rmtfs, pd-mapper and tqftpserv BSD-3) [M-static `README.md`, `LICENSE`, commit
  `18532a5`]. Meta firmware, calibration and lens assets are excluded.
- **Model:** Quest 1 (`monterey`, MSM8998). It is a companion
  to Block-Flock's pmaports port.
- **Head:**
  - 3DoF is accepted and installed (Monado orientation).
  - 6DoF is experimental:
    - stack: Basalt (float build) via VIT, run as a **separate process**;
    - pose path: a 128-byte versioned mailbox read by a Monado polling thread (patch `0003`);
    - head and world alignment: a lever-arm, stale-hold and re-anchor helper
      (`patches/monado/runtime-src/monterey_vio.h`);
    - a conservative quality gate (`tools/tracking/vio-quality.h`).
    [M-static]
- **Controllers:** buttons only (uinput bridge); no controller tracking [M-static
  `packages/device-oculus-monterey/oculus-controller-uinput.c`].
- **Sensor access (pointer only):**
  - IMU: read passively from the already-running SyncBoss stream (`capture-imu.c`, "no stream
    configuration") [M-static];
  - cameras: through **Meta's own stock camera HAL and libsyncboss**, loaded from the untouched
    Android system partition by a Bionic preload (`oculus-stock-runtime`,
    `tools/camera/stock-probe.c`) [M-static];
  - preview: four 320×240 Y8 streams at about 30 Hz; IMU at about 1015 Hz [C];
  - their camera docs record disassembly of Meta's `libsyncboss.so`
    (`docs/CAMERA-ROADMAP.md:601`). **That route is not for us** (D-T10; and Q3 has a different
    camera stack).
- **Tracker settings:** Basalt with:
  - four cameras (order 0,2,1,3);
  - live images decimated to 15 Hz (30 Hz in the later r5 trials) at full IMU rate;
  - workers pinned to the four big cores, nice 10.
  [C, `tools/tracking/README.md`]
- **To OpenXR:** Monado → their own framebuffer VR renderer. No SteamVR.
- **Evidence (their own logs, not checked by us):**
  - stationary replay drift:
    - first about 10 m (accelerometer bias/convention);
    - about 10 cm with the accelerometer down-weighted;
    - **4.9 mm endpoint and 24 mm max excursion** after rectification and tuning, on one clip;
  - marked return error 0.095–0.130 m;
  - a 20 s live run spanned 34 mm while nominally still;
  - pose age from driver timestamp to poll: median 36–43 ms;
  - wearer trial "Piigko" (r5): 550/1073/129 of 966/2306/737 poses ready; ages 90–108 ms;
    owner verdict "a little better, can kinda move, loses lock frequently".
  [C, `docs/basalt-positional-tracking.md`, `docs/tutorial/07`, `09`]
- **How they validated (all ground-truth-free):**
  - stationary-clip drift ("a correct VIO should output ~zero");
  - return to a table marker;
  - intended-distance moves (50 cm, about 2 m out and back);
  - replay determinism;
  - **IMU propagation vs. future VIO** consistency (`imu-propagation-consistency.py`);
  - **visual-vs-gyro SO(3)** rotation agreement for the time offset (`audit-visual-gyro-so3.py`);
  - capture timing audit;
  - a synthetic two-camera epipolar test;
  - SIFT correspondences to check camera order;
  - a synthetic 10 cm translation pushed end to end through OpenXR;
  - bounded wearer trials (start-here reset, readiness gate, recovery guard).
- **Lessons for us [D]:**
  - Accelerometer convention and bias errors produce metres of drift. Calibration conventions
    must be proven before tuning.
  - Camera/IMU time alignment from transport timestamps was never resolved.
  - Two cores gave 181 ms median latency against 36 ms on four. Watch this against the PM's
    "no dedicated cores unless Meta does" (J-166).
  - Low light and stale exposure metadata (cache coherency) broke tracking.
  - Loosening the gates is not a fix.

### 1.2 Block-Flock/pmaports-oculus-monterey + monado-oculus-monterey (Quest 1, postmarketOS)

- **Licence:**
  - pmaports repo: **none** (pointer only);
  - Monado fork: BSL-1.0, inherited, with three commits adding a `monterey` driver
    (SyncBoss IMU parser, guarded HMD transport) [M-static `src/xrt/drivers/monterey/`].
- **Status:** 3DoF head through Monado, fed by a bridge to the stock SyncBoss userspace. Touch
  works as libinput input. README: "Not working yet: … tracking" (positional) [M-static
  `README.md`]. Validation: none recorded beyond working/not working.

### 1.3 nicolas-riera/Quest1-SteamOS (Quest 1, SteamOS Holo + SteamVR)

- **Licence:** **none** (pointer only; only its GPL kernel patch and BSL Monado patch are
  reusable, as before).
- **Status:**
  - 3DoF head with a neck model;
  - Touch rotation with an arm model;
  - in SteamVR at about 40 fps;
  - Meta's `libsyncboss` via libhybris; cameras captured natively through Meta's camera HAL
    (`src/qcam`);
  - 6DoF not started ("SLAM is next") [M-static `README.md:18,36-37`].
- **Validation:**
  - a two-static-pose IMU mounting calibration for the controllers
    (`docs/controllers-native.md:280`);
  - gyro bias at rest measured at about 0.01 rad/s (`docs/syncboss-imu.md:61`) [C].
- **Note:** its docs record disassembly and symbol dumps of Meta binaries
  (`docs/tracking-6dof.md:10`, `docs/tracking-ipc.md:5`). Pointer only.

### 1.4 machachu56/quest-kexec-q2 (Quest 2, Frame userspace in a chroot)

- **Licence:** GPL-2.0; the Monado driver files carry `SPDX: BSL-1.0` [M-static
  `monado/drivers/quest2/q2_driver.c:1-2`].
- **Status:**
  - 3DoF head and Touch rotation through SyncBoss kernel nodes (no Meta library), using
    `m_imu_3dof`;
  - fixed 1.6 m height;
  - the four OV7251 cameras stream into Monado frame sinks by **replaying a recorded Android
    ioctl sequence**; no tracker consumes them;
  - 6DoF is planned as "Basalt through Monado's VIT/SLAM interface" [M-static
    `docs/QUEST2_PORT.md:388-406`, `TODO.md:32-39`, `q2_cameras.c:5-15`].
- **Validation:** user-confirmed "smooth head rotation, controllers rotate correctly" (subjective).

### 1.5 YusufOzmen01/quest-kexec (Quest Pro, a second Android)

- **Licence:** GPL-2.0. Status: boots Meta's Android again under kexec. Meta's `trackingservice`
  reaches 6DoF after a `vrmountlock` helper and a service restart [C,
  `docs/KEXEC_ANDROID_WORKING_SETUP.md:78,240`].
- It is **Horizon's tracker**, not a port's. It may be what the PM saw reported as "6DoF" [D].

### 1.6 Producdevity/reframed-vr (Quest 3 and Pico Neo3 Pro Eye; QEMU only)

- **Licence:** **none** (pointer only). Nothing booted on hardware.
- **Tracking:**
  - Pico VIO: native Basalt on **public Collabora MIO09 replays with Valve Index calibration**;
  - result: 6.4 mm RMS / 16.6 mm max after a rigid SE(3) alignment **without scale fit**,
    identical across runs;
  - live cameras and "physical 6DoF" not done [C, `README.md:22-23`, `docs/pico-slam.md:55-70`].
- **Teaches:**
  - align without fitting scale, so scale errors stay visible;
  - check run-to-run determinism.
- **Points to** arcturus-vision/dipr: 2022 inertial-prediction research, licence NOASSERTION
  (noncommercial share-alike per reframed-vr) [C]. Pointer only.

### 1.7 Others checked

| Project | Quest | Tracking | Licence | Use to us |
|---|---|---|---|---|
| CreoleVR/QuestLHSync | Pro/3/3S; Steam Frame | None of its own. Reads Horizon camera rings by **Frida injection into Meta's sensors HAL**, aligns Lighthouse to Horizon's pose. Reads `/persist/calibration`, preferring "the newest online-refined file" [M-static the project's module source] | MIT | Pointer only (injection into Meta code, /persist, Lighthouse). Fact [C]: Horizon refines camera calibration online, which our calibration plan (D-T3) should expect |
| KirvilNET/QuestSLAM | 3/3S (Horizon) | Unity app streaming **Horizon's VIO pose** at up to 120 Hz to ROS [C, README] | MIT | **Precedent for an on-headset Horizon pose logger** (§5, R2b) |
| marcsabat/slam_tracking_comparison | 3 (Horizon) vs Pimax Crystal Light | Pose CSVs `frame,time_ns,pos,quat,position_tracked,orientation_tracked` at about 90 Hz, 180 rows each [M-static CSV headers] | none | Pointer: shows the black-box OpenXR pose-log format we want |
| Monado !2941 (open) | Rift CV1 Touch | 6DoF Touch via the constellation tracker, "stable enough" for easy Beat Saber [C, MR text] | BSL-1.0 | Relevant to Q1/Q2 Touch LED rings (survey §3); subjective validation only |
| postmarketOS conf. 2026 talk | lists Quest 3S (`panther`) among "initial support" | None claimed; the speaker's own 6DoF is a Vive tracker on a phone [C, pretalx 8UMTPU] | — | No Quest tracking |
| Lynx R1 ORB-SLAM3 | (not Quest) | Already in survey §6 | GPLv3 | — |
| leo-n64/linux-vr-pro | 3 | Streaming plan; no code | none | — |

No Quest-related Monado MR and no Quest pmaports MR exist (GitLab API search, 2026-10-14).
OpenHMD and xr-hardware have no Quest tracking [C].

---

## 2. Summary table

| Project | Quest | Head | Controllers | Sensors | Tracker | Reaches | Evidence | Licence |
|---|---|---|---|---|---|---|---|---|
| cstahly | 1 | 3DoF installed; **6DoF experimental, rejected** | buttons only | IMU passive; cameras via Meta HAL | Basalt (VIT) | Monado/OpenXR, own renderer | logs, CSV metrics, wearer trials | MIT (+ upstream) |
| Block-Flock | 1 | 3DoF | input only | stock SyncBoss bridge | `m_imu`-style 3DoF | Monado | README | none / BSL fork |
| Quest1-SteamOS | 1 | 3DoF | Touch 3DoF + arm model | libsyncboss + Meta HAL (libhybris) | own fusion | SteamVR | README, docs | none |
| quest-kexec-q2 | 2 | 3DoF | Touch 3DoF | SyncBoss kernel nodes; camera ioctl replay | `m_imu_3dof` | Monado/OpenXR | user report | GPL-2.0 / BSL |
| quest-kexec | Pro | Meta's 6DoF (Android) | Meta's | Meta stack | Meta | Horizon apps | log | GPL-2.0 |
| reframed-vr | 3, Pico | none on hardware | none | — | Basalt (replay) | Monado (QEMU) | dataset replay | none |

---

## 3. Corrections to our docs (for the next revisions; not applied here)

- `oss-tracking-survey.md` §6 row "Quest1-SteamOS, quest-kexec-q2 … no 6DoF" is correct for
  those two, but the survey's implied claim (no Quest port reached 6DoF) is **wrong**. Add
  cstahly: **experimental live Basalt 6DoF on Quest 1, reached wearer trials, rejected for lock
  loss, lag and low light; never default** [C].
- `tracking-input-route.md`:
  - §5.1: add the Basalt per-camera epipolar bug (§4 item 1) to the fork's to-do list.
  - D-T16: currently "Lighthouse or mocap loan", which the PM rejected (J-166/J-167). Replace it
    with the §5 method; **pending PM**.
  - §7.3 step 3: replace the ground-truth rig with the §5 fixtures, and say that Horizon and
    FrameShift are compared on **the same physical references**, not on simultaneous
    trajectories (both cannot run at once on one unit).
- Memory `community-work-index`: cstahly was listed for Wi-Fi, Monado and controllers only. Add
  "Basalt live VIO trial, MIT tracking tools".

---

## 4. What we can reuse cleanly

1. **Basalt bug, confirmed in our clone [M-static]:**
   - where: `include/basalt/optical_flow/optical_flow.h:210` at `df6e970` (our
     `~/work/tracking-research/basalt`);
   - what: the essential matrix for every camera `i` is built from `T_i_c[0]⁻¹·T_i_c[1]`;
   - fix: cstahly's patch `0006` uses `T_i_c[i]`.
   - It matters for any Quest with more than 2 cameras. Effect on accuracy [C]. **Fix it
     ourselves in our fork** (BSD-3; a one-line change; credit cstahly).
2. **Other Basalt patches (BSD-3):**
   - `0001`: VIT null end-of-stream pose;
   - `0005`: skip fully masked detection cells.
   Do not take `0002`, `0004` or `0007` (rejected by their author).
3. **MIT validation tools to adapt.** All are ground-truth-free diagnostics, and our harness can
   run them on our recordings:
   - `summarize-trajectory.py`;
   - `imu-propagation-consistency.py`;
   - `audit-visual-gyro-so3.py`;
   - `audit-capture-timing.py`;
   - `check-camera-correspondences.py`;
   - `analyze-prediction.py`;
   - the recording idea `QVRREC01`: interleaved camera and IMU events, keeping host-arrival and
     MCU timestamps separately.
4. **Design patterns (MIT/BSL):**
   - the separate tracker process with a bounded queue (at most 2 outstanding image groups; skip
     images, never IMU);
   - the versioned pose mailbox;
   - the quality gate (feature support per camera, freshness ≤ 150 ms, continuity and jump
     checks);
   - hold on short loss, quiet re-anchor on long loss;
   - the "start here" recentre;
   - bounded trial launcher with a recovery guard.
   These match our dedicated tracking process (§6.3 of the route). Reimplement them in our code
   and credit the source.
5. **quest-kexec-q2 Monado driver** (BSL-1.0): device and builder structure for a Quest
   SyncBoss HMD with Touch, and the Touch IMU axis and scale facts (already in
   `community-quest-repos-2.md` §4.1).
6. **KirvilNET/QuestSLAM** (MIT): a working Horizon pose-streaming app, as a reference for our
   own minimal logger (§5, R2b). Licence-clean to read; installing anything is a device write.
7. **Not reusable:**
   - camera paths through Meta's HAL, libsyncboss or Frida (D-T10);
   - all no-licence repos (pointers);
   - Meta's trackingservice under kexec.

---

## 5. Proposed validation for D-T11 "Horizon parity" with no external tracking hardware

**Principle [D]:**
- Horizon and FrameShift cannot run at the same time on one unit, so we never subtract one
  trajectory from the other.
- Instead, both are measured against the **same physical references**, with the same scripts,
  room and lighting. Metrics are computed by one script for both.
- Parity means FrameShift's metric distribution is no worse than Horizon's. Report
  N ≥ 10 repetitions with confidence intervals; our §7.3 floors stay as minimums.
- Alignment is SE(3) only, never scale (as in reframed-vr), so scale errors show.

**Ranked methods:**

| Rank | Method | Measures | Needs | Device impact |
|---|---|---|---|---|
| **R1** | **Fixture stations:** a rigid headset cradle (a stand, or a box with a moulded foam seat) and **marked stations** on a table and floor, measured with a steel tape and a printed grid (about 1 mm). Place the headset at A, B, C…, return to A; repeat 10×. Controllers sit in their own cradle at marked table stations | **Absolute scale** (estimated vs taped distances); **return-to-station repeatability**; **static jitter** (60 s holds, RMS after detrend, plus Allan deviation); **loop drift** (walk a scripted loop, re-seat in the cradle; closure error); controller-to-head relative pose error (frame-independent) | Tape, printed grid, a cradle (about €20) | None beyond running each OS |
| **R2a** | **Horizon pose log via Quest Link/Air Link** (built into Horizon): an OpenXR logger on the PC records HMD and controller `xrLocateSpace` poses plus tracked flags at about 90 Hz (the format in §1.7) during the R1 scripts | Horizon's numbers for every R1 metric, and tracking-loss counts | A Windows PC with Meta's Link app; enabling Link on the headset | **Setting change on the headset**: PM approval. Link poses are predicted for display, so latency is not measurable this way |
| **R2b** | **On-headset OpenXR logger APK** (ours, minimal; QuestSLAM shows it works) logging poses at the runtime's own time | Same as R2a, less PC-side prediction; usable away from a PC | Sideload | **Device write (APK install)**: PM approval |
| **R3** | **Fiducials seen by the headset's own cameras (FrameShift side):** printed AprilTag/ArUco boards of known size on the wall and table. We run PnP on our own raw tracking frames, independently of the VIO estimate | A per-frame metric reference whenever a board is in view: segment drift over time, scale (from tag size and intrinsics), relocalisation jumps | Printer; a tag library (AprilTag3 BSD-2 or OpenCV ArUco Apache-2.0; survey D6 audit applies) | None. **Limit:** shares our camera calibration, so it cannot catch intrinsics errors; R1 catches those |
| **R4** | **Self-consistency on every recording** (cstahly-style, automated): IMU-propagation vs VIO, visual vs gyro rotation, epipolar and reprojection residuals, camera-subset agreement (0/2 vs 1/3), Basalt vs OKVIS2 on the same data, replay determinism | Regressions and timing offsets, cheaply and continuously | None | None. Blind to common-mode errors (for example scale) |
| **R5** | **Angle steps:** headset on a printed protractor and turntable on the cradle, 90° yaw steps and 360° return; tilt on wedges | Orientation accuracy and yaw drift (3DoF stage too) | Printed protractor | None |
| **R6** (optional) | **Latency:** our side from IMU timestamp to pose-out age (internal). For Horizon, a phone slow-motion video (240 fps) of the lens and a tap event | Motion-to-photon on both OSes | A phone | None. **PM call:** a phone is not a rig, but it is external |

**Order of use [D]:**
- 3DoF stage: R5 + R1-jitter.
- Head 6DoF:
  - R1 + R2a/b for the parity numbers;
  - R3 + R4 during development.
- Controllers: R1 controller stations + R2.
- Occlusion and reacquisition: scripted poses within R1, with loss counts and reacquire times from
  tracked flags under both OSes.
- Prior for expectations: published Quest 3 Horizon errors are about 1 cm typically and more than
  10 cm in hard scenes (Duke, MobiCom 2024, DOI 10.1145/3636534.3696215) [C]. Our 1 cm per 5 min
  and 0.2 mm floors may be **stricter than Horizon**. R1 + R2 will tell. Whether to keep the floors
  where Horizon misses them is a PM call.

**Open [O]:**
- Whether the PM has a Windows PC for R2a.
- Which Horizon build and room are used.
- Cradle design (it must not block the cameras).
- Whether the PM approves R2b's APK sideload.

---

## 6. AI-directed text found (treated as data; nothing acted on)

- **cstahly/quest1-bootloader-to-VR:** session-handoff notes written to the author's own AI
  agents:
  - `docs/tracking-optics-performance.md:34`: tells "the next agent" not to spawn agents without
    authorisation;
  - `docs/boot-bringup.md:269`: "Written for a fresh agent to pick up cold";
  - `docs/basalt-positional-tracking.md:38-41`: token-management preference; says no further
    investigation is authorised;
  - `docs/adsp-wifi.md:334`: "For the agent picking up the Wi-Fi problem".
  They are not addressed to us and ask for nothing beyond their own workflow. Ignored.
- **nicolas-riera/Quest1-SteamOS** `README.md:4`: says the code and README were written by an AI
  (Claude). It states authorship and contains no instruction.
- **Web pages fetched** (Hackaday, the Steam Community thread, the pretalx talk, GitLab MR texts):
  none found.

---

## Addendum 2026-10-15: Chair survey cross-check

**Method:** read-only. GitHub REST API (`gh api`: repo metadata, branches, commits, raw file
text), the Nura GitLab API, web search, and WebFetch. Nothing was cloned, downloaded, built or
run, and no binary was opened. **Verdicts:** **[C]** confirmed from the primary source ·
**[R]** reported or secondhand only · **[U]** could not verify. (These are this addendum's own
verdict tags; the [C] of FS-R-001 in the sections above means "unconfirmed claim".)
**Blocked:**
- reddit.com refuses our fetch tool;
- the Nura wiki (`wiki.postmarketos.org` now 301-redirects to `wiki.nura.eco`) serves an Anubis
  bot check.
We did not try to get around either one (no login, no scrapers).

| # | Chair claim | Verdict | What is new against §1–§2 | Source |
|---|---|---|---|---|
| 1 | nicolas-riera/Quest1-SteamOS: native capture from all 4 tracking cameras through libsyncboss + libqcameraoculushal (libhybris); Basalt planned, not working; controllers 3DoF + arm model | **[C]** | **Nothing changed since our pin.** HEAD is still `b7467ff15` (2026-10-07), `main` is the only branch, and there is still **no licence** (API `license: null`). Detail beyond §1.3, from `docs/tracking-6dof.md` "Update 2026-10-06 evening" (author's claims, which we did not check): 4 × 640×480 Y8 at 2 × 30 Hz, alternating HEADSET (4 ms) and CONTROLLER (~38 µs) exposures; ISP timestamps on CLOCK_MONOTONIC; the cameras run only while Monado is stopped. Basalt is "next step 2" and not built (README: "There is no 6DoF yet"; `docs/controllers-native.md:275` arm model). Small correction to the Chair: `docs/syncboss-imu.md` covers the IMU and SyncBoss only; the camera claim comes from `tracking-6dof.md` and `src/qcam/qcam.c` | [repo](https://github.com/nicolas-riera/Quest1-SteamOS), [tracking-6dof.md](https://github.com/nicolas-riera/Quest1-SteamOS/blob/b7467ff15/docs/tracking-6dof.md) |
| 2 | machachu56/quest-kexec-q2 `quest2-port`: README says tracking unfinished; `docs/QUEST2_PORT.md` "Status 2026-10-07: first VR (Monado, 3DoF)" reports 3DoF head + controllers; `q2_cameras.c` replays recorded Meta HAL transactions | **[C]** | **Nothing changed since our pin.** `quest2-port` HEAD is still `9c96c192d` (2026-10-07). New: the branch's **README status table is stale**: it lists head and controller tracking (3DoF/6DoF), tracking cameras and OpenXR under "Not yet", while `QUEST2_PORT.md:388-406` reports 3DoF working, user-confirmed. The file header of `q2_cameras.c:4-15` confirms that the camera start-up done by Meta's HAL is recorded on Android (`qkx_camtrace`) and replayed. No Meta library is loaded at runtime, but the start-up sequence itself comes from Meta's HAL. `main` (`e61edbd7f`) is the Quest Pro tree from §1.5 | [QUEST2_PORT.md](https://github.com/machachu56/quest-kexec-q2/blob/quest2-port/docs/QUEST2_PORT.md), [q2_cameras.c](https://github.com/machachu56/quest-kexec-q2/blob/quest2-port/monado/drivers/quest2/q2_cameras.c) |
| 3 | Producdevity/reframed-vr: Basalt results are Pico replay only; no Quest hardware | **[C]** | **12 commits after our pin.** HEAD is `a92da3b54` (2026-10-15 00:01Z); our pin `c704df762` is in the history (compare: ahead 12, behind 0). Commit `4684ce2e5`, "run continuous stereo capture and native 6DoF", adds the Pico live-capture path (`src/pico-slam-live.c`). It is tested only on replays and simulated kernel events: `docs/pico-slam.md:138-143` says physical sensor identities, calibration and capture timing "are still required". README `:23`: physical 6DoF is not done; Quest only in QEMU. Still **no licence** | [repo](https://github.com/Producdevity/reframed-vr), [pico-slam.md](https://github.com/Producdevity/reframed-vr/blob/master/docs/pico-slam.md) |
| 4 | r/QuestPro `1wy3vxr` "SteamOS on Quest Pro" (demo, tracking does not work; original on X by marquina_osu) | **[U]** | Reddit is blocked to us. Web search finds no trace of the post or the X handle. No GitHub user `marquina_osu`. Chair-reported only | — |
| 5 | r/OculusQuest `1x44bad` "Quest 2 boots Arch Linux", Cool-gamer19393, 2026-10-12, repo promised | **[U]** | Reddit is blocked to us. No GitHub user `Cool-gamer19393` (API 404). A GitHub repo search (Quest + Arch/kexec/Basalt/SyncBoss/SLAM, pushed after 2026-10-01) finds nothing new. Treat it as an unreleased claim with no tracking stated | — |
| 6 | r/SteamFrame `1wz3bhq` "Steam Frame OS on the Quest 2 for real" = an APK on Horizon, not a native OS | **[U]** | Reddit is blocked to us; search finds nothing. If the Chair is right, it is Horizon's tracking and out of scope, as with §1.5 | — |
| 7 | FreeXR/Nura wiki, Quest 3S (`panther`): "Not booting", kernel pending | **[R]** | The wiki is behind the Anubis bot check. This agrees with the PM's earlier screenshot (J-75: status "not booting"). Supporting evidence, our own check: Nura's pmaports (GitLab API, `gitlab.postmarketos.org`) has **no** `device-meta-panther` or `linux-meta-panther` package under `device/testing` or `device/downstream`, and no MR mentions it | [wiki (blocked)](https://wiki.nura.eco/wiki/Meta_Quest_3S_(meta-panther)) |

**Overall claim (wording per FS-R-013 §12):** "No validated native 6DoF head-and-controller implementation was
found in the inspected public sources." A research result, not proof that none exists. **Supported**, with these limits:
- Items 4–6 were not readable.
- The only live native 6DoF is still cstahly's rejected experiment on Quest 1, head only (§1.1).
  Its HEAD is unchanged at `18532a5` (pushed 2026-10-05).
- No project shows 6DoF controllers on any Quest.

**AI-directed text:** none found in the pages and files read. One pointer only:
`Quest1-SteamOS/docs/tracking-6dof.md:10` cites "`%TEMP%\claude\...\scratchpad\t6\`" (a trace
that an AI wrote it, as noted in §6). It contains no instruction.

**What this means for our route** (our own Basalt fork, our own drivers, no Meta tracking
binaries, Q3 Touch Plus first) [D]:
- **No precedent to borrow.** Every Quest camera path found so far depends on Meta at some
  level:
  - Q1: Meta's HAL, loaded through libhybris;
  - Q2: replaying a recorded sequence from Meta's HAL.
  Neither fits D-T10, and neither applies to the Q3 camera stack. Our own Q3 capture driver stays
  first-of-kind work.
- **Two design inputs, both unchecked on Q3 [O]:**
  - Q1 interleaves HEADSET and CONTROLLER exposures in a single camera schedule. Expect a
    similar split for Touch Plus IR sensing.
  - Q1 clocks: camera timestamps are on CLOCK_MONOTONIC, but SyncBoss shutter records use
    SyncBoss time. Expect the same clock-domain problem (§1.1 lessons).
- **reframed-vr is the closest structural analogue** (live Basalt fed through Monado's VIT path),
  but it has no licence and has never run on hardware. Pointer only.
- **Touch Plus 6DoF has no open precedent anywhere.** The nearest is Monado !2941 (Rift CV1
  constellation, §1.7). Budget for it as research, not as a port.
