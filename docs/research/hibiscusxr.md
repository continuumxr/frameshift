# HibiscusXR (neosalsa): what it is, and whether its hand-tracking branch helps us

**Status:** research only, rev 0, 2026-10-15. No device was touched. Nothing was cloned, downloaded
(no archives, models or binaries), built, run, disassembled or decompiled. Text source and docs only,
read through the public GitLab REST API (`/repository/tree`, `/files/<path>/raw`, `/commits`,
`/compare`, `/merge_requests`).

- **URL:** https://gitlab.com/neosalsa/HibiscusXR (project id 86728484; created 2026-09-21;
  1 star, 0 forks; last activity 2026-10-09).
- **Commits inspected:**
  - `hand-tracking` head `a89e145e21ee31acecbaefaae43d0a2570a9913a` (2026-09-22). The branch is
    21 commits ahead of `main`, all from 2026-09-22, branched after `84b04dcfa167` (merge of
    `controller-input`).
  - `main` head `666b4446dd20defeaf103f5a9d1d641515d6933a` (2026-10-09). It is 299 commits ahead
    of `hand-tracking` and contains none of the branch's hand files.
  - MR !11, "Draft: Hand tracking via Mercury + shared hand state", sha `a89e145e`: opened
    2026-09-22, **closed unmerged** 2026-09-25.

**Tags:** **[C]** confirmed in source (file read at the hash above) · **[R]** reported by the
authors (README, MR text, commit messages) · **[U]** unverified.

---

## 1. What it is

- **[R]** "A custom operating system for standalone VR headsets, built on LineageOS 17.1
  (Android 10)" (`README.md`). It is **Android, not Linux/SteamOS**.
- **Target devices [R]:** Pico Neo 2 (A7B10, SDM845) is the only supported device; Oculus Quest 1
  and Pico Neo 3 are "Planned". No Quest 2/3. Nothing runs on any Quest today.
- **Maturity on `main` [R]:** per the `main` README table:
  - working: boot, display, audio, suspend, 2D Pico apps, a compositor, and head tracking
    "3DoF and 6DoF SLAM";
  - controllers partial (no positional tracking); passthrough not working.
  - The 6DoF comes from the stock Qualcomm QVR service (`qvrd`), gated by `persist.pn2.dof`
    (commit `9a1997a4f7`). It is **vendor SLAM, not an open tracker** [C, commit message + README].
- **Authors and activity:** the main committer is `HttpAnimations`, with `calico` on one branch.
  Commit messages are in Chinese. Very active from 2026-09-20 to 2026-10-09, about 400 commits on
  `main` [C, API].
- **AI-assisted:** there are `AGENTS.md` / `CLAUDE.md` files in the app and website directories
  [C]. See §5.

## 2. The `hand-tracking` branch

### 2.1 Pipeline

**It is Monado's Mercury, unmodified except for two thresholds** [C].
- `system/pn2xr/handsvc/main.c` runs a daemon (`pn2_handsvc`). It calls
  `t_hand_tracking_sync_mercury_create(calib, info, models)`, then `t_ht_sync_process` per stereo
  frame.
- Mercury's own stages do the rest: 160x160 detector, keypoint model, then its optimiser/IK. The
  branch adds no detector, keypoint model or IK of its own.
- **Patch** `system/pn2xr/monado/patches/mercury-tuneables.patch`: `max_num_outside_view` goes
  6→12 and `num_frames_before_display` 10→4, "for the pn2's narrower downward-tilted cameras" [C].

### 2.2 Models and provenance

**They are the stock Mercury ONNX files** [C].
- `system/pn2xr/monado/build.sh` (diff in compare `main...hand-tracking`) fetches them at build
  time:
  - source: `gitlab.freedesktop.org/monado/utilities/hand-tracking-models/-/archive/master/...`;
  - files: `grayscale_detection_160x160.onnx` and `grayscale_keypoint_jan18.onnx`;
  - comment: "stock files, no training involved".
- `system/tools/build/267_build_full.sh` bakes them into `/system/share/monado/hand-tracking-models`.
- **No weights are in the repository** [C, tree listing: no `.onnx`/`.pt`/`.bin` model files].
- **No training, no dataset, no new provenance.** The problem we already recorded in
  `oss-tracking-survey.md` §3 and `tracking-input-route.md` §5.3 still applies: the models have **no licence**, and
  their training data includes FreiHAND (no commercial use), EPIC-KITCHENS (CC BY-NC) and CMU
  Panoptic (research only).

### 2.3 Camera input

- Fused 1280x400 OV9282 grey frames from the Pico's tracking-camera pair. The frame is split into
  two 640x400 `XRT_FORMAT_R8` views [C, `main.c`].
- **KB4 fisheye** intrinsics and the stereo extrinsics come from the factory file
  `/persist/pvr/camera/device_calibration.xml` [C, `pn2_calib.c`, `main.c` `fill_calib`].
  - The right-in-left pose is inverted to match OpenCV `stereoCalibrate` convention ("mercury
    wants … P_right = R*p + T") [C].
  - The image boundary is a circle with radius 0.72, overridable with `PN2_BOUNDARY` [C].
- **Frame access goes through the proprietary `libqvrcamera_client.so`, called by `dlopen` on
  undocumented ops-table indices** [C, `handsvc/pn2_cam.c`, `tools/camdump.c`]. The source states
  that the table order and the frame struct layout "were recovered from libairservice.so
  (attachQvrCamera / get6DofImage)". That is reverse engineering of vendor binaries.

### 2.4 Runtime

- ONNX Runtime 1.18.0 (Android AAR from Maven) and OpenCV 4.10.0 run on the **CPU**, with Mercury's
  default thread pool [C, `build.sh`]. There is no GPU or DSP path for hands.
- **Process split [C]:**
  - one daemon owns the camera and the inference;
  - it publishes both hands (26 joints plus palm, in the left-camera frame, and the camera-in-IMU
    rig pose) to a 4 KiB **seqlock file**, `/sdcard/HandShareMem` (`hand_state.h`, version 2);
  - the Monado driver `pn2_hand.c` and the home app are pure readers. A tracking override attaches
    the hands to the head pose (`pn2_prober.c`).

### 2.5 Claims and validation

- **No latency or accuracy figures anywhere** [C].
- **MR !11 test plan [R]:**
  - checked: host tests ("2443 checks") and "runtime exposes XR_EXT_hand_tracking";
  - unchecked: "live hand detection verified on device (in progress)".
- **The last commits look like a detector that was not firing on-device [R/U]:**
  - "fix extrinsic direction and loosen detection boundary" (`954f78c936`);
  - "loosen Mercury display/out-of-view thresholds" (`0a8353ae33`);
  - an offline detection-model test tool, `det_test.cc` (`593327e999`), which dumps the raw
    `hand_exists/cx/cy/size` outputs.
- The MR was closed 3 days later, and `main` shows no hand tracking since [C].
- **Verdict on the branch:** the plumbing works; working hand tracking was never shown [U].

### 2.6 Pinch input

- `applications/vrhome/src/input/hand_pose.cpp` [C]:
  - thumb–index pinch with hysteresis (on below 24 mm, off above 34 mm) and a 60 ms debounce;
  - controllers take precedence over the pinch (commit `3b2b1b2205`).
- The tests cover the share-file round trip and the transforms only (`tests/test_hand.cpp`).

## 3. Licences

- **Repository [C]:** `LICENSE` (root, and every subdirectory) is **AGPL-3.0**.
- **The licence headers are inconsistent:**
  - `pn2_hand.c/.h` carry `Copyright 2025, PN2Lineage` and `SPDX-License-Identifier: BSL-1.0`;
  - `handsvc/*.c`, `pn2_calib.c` and `hand_pose.cpp` have no SPDX header, so they fall under the
    directory's AGPL-3.0 [C].
- **Vendor libraries [C]:** the `vendor/*` READMEs say the Pico/Qualcomm/Tobii binaries are
  gitignored, not distributed, and not redistributable.
- **Models:** not in the repo. They are Mercury's unlicensed models, as above.
- **Third-party runtimes:** ONNX Runtime (MIT) and OpenCV (Apache-2.0) are fetched as prebuilt
  binaries [C, `build.sh`].

## 4. Relevance to FrameShift

- **Nothing new for tracking.** It is Mercury plus the stock models, on a different SoC
  (SDM845), with vendor camera access. It is not validated, and it was abandoned.
- Our route already plans Mercury's runtime with **our own retrained, clean model**
  (`tracking-input-route.md` D-T6). This branch confirms only that integrating Mercury into
  Monado on an Android/Qualcomm headset is about one day of plumbing. It says nothing about
  accuracy on downward-tilted fisheye stereo, which is the open question.
- **Not relevant to head or controller tracking.** The 6DoF on `main` is Qualcomm QVR SLAM, which
  we exclude (no vendor tracking binaries).
- It does **not** run on any Quest, and its Quest 1 plan is "Planned" only [R].

## 5. AI-directed text

`AGENTS.md`, each with a `CLAUDE.md` that contains only `AGENTS.md`, appears in:
- `websites/website/`;
- `applications/library/`;
- `applications/quick-panel/`;
- `applications/settings/`.

Each file is titled "Rules for AI agents" [C]. They are the project's coding rules for its own
agents (tests must pass, no hardcoded strings, no god files, merge-request flow), not instructions
aimed at outside readers. They were read as data and not acted on. No other AI-directed text was
found in the files read.

## Use for FrameShift

- **Process split as a pattern:** one camera-owning hand daemon writes to a versioned seqlock
  shared-memory record (26 joints + palm + rig-in-IMU pose + timestamp), and many readers read it.
  The pattern is cheap and testable on the host. Re-implement it ourselves; do not copy the AGPL
  code into BSL/MIT components.
- **Mercury fisheye integration details:**
  - KB4 intrinsics;
  - the right-in-left versus OpenCV `stereoCalibrate` extrinsic inversion, a real pitfall;
  - the circular image boundary;
  - the device-clock to `CLOCK_MONOTONIC` timestamp anchoring;
  - the hint that `max_num_outside_view` and `num_frames_before_display` need loosening for
    downward-tilted narrow cameras.

  Note these for our Mercury-runtime fork. Values must be re-derived on Quest 3.
- **Offline detector probe:** dump a raw stereo frame, replicate Mercury's letterbox plus
  normalisation (std → 0.25, mean → 0.5), and print the raw detector outputs. This is a good
  debugging step for our own model. Write our own version.
- **Pinch UX defaults** as starting values: 24/34 mm hysteresis, 60 ms debounce, controller
  precedence. They are to be tuned against Horizon.

## Avoid

- **Mercury's stock ONNX models,** which this branch ships. They have no licence and NC/research
  training data, so they are excluded by D-T6.
- **The camera access method:** `dlopen` of `libqvrcamera_client.so` with ops-table indices
  "recovered from libairservice.so". It is vendor-binary reverse engineering, and on Quest it
  would mean Meta/Qualcomm tracking-stack binaries. Both are outside our rules.
- **Copying AGPL-3.0 code** (`handsvc/`, `pn2_calib.c`, `hand_pose.cpp`) into FrameShift
  components. If code is ever wanted, take only the explicitly BSL-1.0 `pn2_hand.c`, and only
  after confirming that its header is authoritative.
- **Treating "6DoF SLAM working" on HibiscusXR as open-tracking prior art.** It is the vendor QVR
  service.
- **Its unvalidated thresholds as evidence.** No on-device detection was ever reported.
