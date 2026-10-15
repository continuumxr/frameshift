# Open-source tracking survey: head, controllers, hands (Quest family)

**Status:** research only, 2026-10-14. No device was touched; nothing was built, run, downloaded
(binaries or models) or disassembled. Companion to `tracking-input-route.md` rev 1 (`ed0f28d`;
not edited here) and J-160/J-161. **Rev 1** applies the adversarial review (GO-with-fixes, 6 MAJOR).
**Rev 1.1** (2026-10-14, J-170) applies `quest-ports-tracking.md` rev 0 (dbeda68) §3:
- Quest prior art is corrected: cstahly's Quest 1 Basalt 6DoF experiment is added, and so is
  quest-kexec's Meta 6DoF (§6).
- The ground-truth gap now uses the no-external-hardware validation (§8 item 9).
- The D-T11 numbers are now **goals**, revisited once Horizon is measured (§7.1).

**Method:**
- Public web pages, papers and repo metadata (GitHub/GitLab APIs). gitlab.freedesktop.org pages
  were often blocked by a bot check, so some Monado MR states are [C] from mirrors or snippets.
- Public source read in the existing WSL clones `~/work/tracking-research/` (monado `ddeba9f6`,
  2026-10-14; thaytan/monado `dev-constellation-controller-tracking` `b1c850a0`; mateosss/basalt
  `df6e970c`).
- Four narrow research agents (VIO, constellation, hands, plumbing/runtimes). I re-checked their
  load-bearing claims in source where a clone existed (Monado constellation tree, Rift S LED
  model, licences) or by a second fetch (OKVIS2 licence, Lynx open-sourcing, Steam Frame LED
  counts). Anything not re-checked keeps [C].
- Rev 1 checks: Basalt CMake and `thirdparty/` in the clone; OKVIS2 tree and `CMakeLists.txt`,
  DBoW2 `LICENSE.txt`, Kimera-VIO `CMakeLists.txt` (GitHub API/raw text, no clone, so OKVIS2's
  bundled model file was never fetched); Valve `XRService` and `libArcturusPerception.so` read with
  `strings` only, plus the third-party notice; the Mercury models issue tracker (GitLab API).
- **Disclosure: Basalt issue #117 on gitlab.com contains AI-directed text** asking the reader to
  take repository and CLI actions. It was treated as data and ignored; nothing was done.

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read in a named file or
source · **[D]** derived · **[C]** unconfirmed (web, repo or paper claim) · **[O]** open.

---

## 0. The answer in brief

| Area | Pick | Runner-up | Why |
|---|---|---|---|
| Head 6DoF | **Basalt** (mateosss fork, BSD-3) via Monado VIT, built as the shared library only | **OKVIS2** (BSD-3) with `USE_NN=OFF`, as accuracy reference/second provider | Only open VIO proven in headsets (WMR, Rift S, Index); fastest in the Monado SLAM benchmark; multi-camera; permissive. **No open relocalisation/map layer** comparable to Valve's or Meta's |
| Early 3DoF | **x-io Fusion** (MIT) or Monado `m_imu_3dof` (BSL-1.0), plus Monado prediction | — | Fusion has runtime gyro-bias and accel rejection; Monado's never corrects yaw |
| Controllers | **Monado mainline constellation tracker** (BSL-1.0, 2026) + inside-out glue from **thaytan's Rift S branch** | OpenHMD `rift-kalman-filter` UKF (reference) | The only permissive, maintained LED tracker; the Rift S controllers are the Quest 1 Touch generation |
| Hands | **Mercury code (BSL-1.0) retrained by us** with `mercury_train` (BSL) on clean data | **MediaPipe Hands** (Apache-2.0 code *and* models) | Mercury fits stereo IR but its shipped models are unlicensed and trained partly on non-commercial data (FreiHAND, EPIC-KITCHENS); MediaPipe is clean but RGB/mono |
| SteamVR seam | **Our own OpenVR driver** (OpenVR headers BSD-3), borrowing patterns from Monado `steamvr_drv` (BSL) and ALVR (MIT) | Monado as a full runtime | Matches the current route; no GPL needed |

- **Quality, honestly [D]:** open head tracking is usable but not at Insight level (MSD paper:
  median errors of several cm on hard XR sequences; Collabora 2026: not at commercial quality).
  **No open project has published any accuracy, jitter or latency figure for inside-out LED
  controller tracking.** The best public numbers are thaytan's 2021 outside-in CV1 figures
  (about 1 cm, at least about 20 ms). "Polished" controllers would be **new work**, not
  integration.
- **Against D-T11 (`tracking-input-route.md` §6.3) [D]:** no open component has evidence of
  meeting any D-T11 target; the head comes closest; Touch Plus is **unknown, plausible only when
  the faceplate faces the cameras** (§7.1).
- **CPU [D]:** the summed estimate (§7.2) is 4.7–9.1 of 6 cores at the sustained 1.92 GHz,
  unmeasured. An ARM replay measurement must precede T2b.
- **Biggest gaps (§8):** camera capture on Q3 (unchanged R1); an open relocalisation/mapping
  layer; Touch LED models and LED/exposure sync; a controller fusion filter tuned for headset-relative tracking; Touch Plus (8 LEDs) needs a
  hand-pose prior that no open project has; hand models must be retrained (Mercury's shipped
  models are unlicensed and partly trained on non-commercial data); a way to measure every target
  without external tracking hardware (§8 item 9).
- **Quest prior art (rev 1.1) [C]:** **no Quest has reliable open 6DoF** (head or controllers).
  The only live attempt is the following:
  - who: cstahly/quest1-bootloader-to-VR (MIT), Quest 1 running Nura;
  - what: Basalt fed into Monado;
  - result: wearer trials, rejected for lock loss, lag and low-light failure; never the default.
  Every other port is 3DoF (§6).

---

## 1. Head 6DoF (VIO/SLAM)

### 1.1 Candidates

| System | Licence | Activity (to Oct 2026) | Fit for Quest (stereo/4-cam mono GS + IMU) | Evidence |
|---|---|---|---|---|
| **Basalt** (Usenko/Demmel, TUM) and **mateosss/basalt** (Monado fork) | BSD-3 [M-static `LICENSE`] | Upstream tag 0.1.7, 2026-03-21; fork tag 2026-07-22, commit 2026-07-24 [C, APIs] | Stereo VIO, KB4/DS/EUCM/fisheye624 models [M-static basalt-headers]; fork handles >2 cameras (4-cam Reverb G2) [C] | Used by Monado for WMR, Rift S, Index, North Star, RealSense [C, README]; fork ships Raspberry Pi/Radxa .debs (ARM builds) [C]; about 8 ms/frame with 2 cams, 12 ms with 4 on a Ryzen 7 5800X [C, Monado MR snippet] |
| **OKVIS2** (ETH/Imperial/TUM) | BSD-3 [M-static `LICENSE`, re-fetched]; **bundles `resources/fast-scnn.pt` (4,958,078 B, provenance unstated) and `resources/small_voc.yml.gz`; DBoW2 submodule** (§9) [M-static tree] | Commit 2025-08-27; **OKVIS2-X** (BSD-3) 2026-03-17 [C] | Multi-camera + IMU; `USE_NN` (Torch keypoint classification) **defaults ON** [M-static `CMakeLists.txt:19`] | Best median ATE in the MSD benchmark, but struggled to stay under 33 ms on a laptop CPU [C, arXiv 2508.00088]; OKVIS2-X claims best EuRoC accuracy [C, arXiv 2510.04612] |
| **Kimera-VIO** (MIT SPARK) | BSD-2 [C]; requires **DBoW2** (`find_package(DBoW2 REQUIRED)`) [M-static `CMakeLists.txt:32`] | Commit 2025-02 [C] | Stereo, equidistant model | No XR use found; GTSAM-heavy |
| **XRSLAM** (OpenXRLab) | Apache-2.0 [C, GitHub API] | Pushed 2026-02 [C] | **Monocular** VIO (mobile/AR oriented) | No stereo/multi-cam; benchmark toolbox [C] |
| **maplab** (ETH ASL) | Apache-2.0 [C, GitHub API] | Pushed 2024-05 [C] | Mapping/relocalisation framework around ROVIO(LI) | **Candidate open map/relocalisation layer** (§8) [D]; ROS-centric |
| **ROVIO** (ETH ASL) | BSD-3 text [C] | Commit 2024-01 [C] | Multi-cam at compile time, EKF, direct photometric | Lowest CPU on every Jetson in a 2021 study [C, arXiv 2103.01655]; old, weaker accuracy |
| OpenVINS (RPNG) | **GPL-3.0** | Release 2023, commit 2025-11 [C] | Arbitrary cameras, fisheye | Failed/inaccurate on easy MSD sequences [C] |
| ORB-SLAM3 | **GPL-3.0** | Last commit 2022 [C] | Stereo-inertial, KB fisheye, no >2 cams | 3.6 cm EuRoC stereo-inertial ATE [C]; **Lynx R1 port runs 90 fps on XR2 Gen 1 without IMU** (GPL-3, uses proprietary Qualcomm acceleration) [C, Lynx blog 2025-08-22] |
| VINS-Fusion / VINS-Mono | **GPL-3.0** | 2021 / 2024 [C] | ≤2 cams | Did not run on Jetson TX2 in the 2021 study [C] |
| SVO Pro | **GPL-3.0**, commercial by contacting UZH [C] | 2022 | Mono/stereo fisheye | — |
| DM-VIO | **GPL-3.0** | 2024 | Mono only | Failed many MSD runs [C] |
| xivo | **Non-commercial** [M-static per agent] | 2023 | — | Excluded |
| DPVO, DROID-SLAM, MAC-VO (learned) | MIT / BSD-3 / MIT [C] | Active | **No IMU, desktop GPU** | Not suitable for a 1 kHz-predicted headset pose [D] |

### 1.2 Benchmark evidence (Monado SLAM Dataset, IROS 2025) [C, arXiv 2508.00088]
- Data CC BY 4.0: Valve Index, Reverb G2 (4 cams), Odyssey+; more than 5 h.
- Benchmarked Basalt, OKVIS2, ORB-SLAM3, DM-VIO, SnakeSLAM. OpenVINS, HybVIO and DPVO were
  dropped after failing easy sequences.
- **OKVIS2 most accurate, Basalt second; Basalt fastest.** On these hard XR sequences more than
  half of the runs had ATE above 10 cm. Timing on an Intel laptop, **never on ARM**.
- No Quest was recorded; no public open-vs-Insight comparison exists [O].

### 1.3 Ranked shortlist and recommendation
1. **Basalt (mateosss fork) through Monado VIT** — keep the current route. Permissive, the only
   one with headset deployments, fastest. Needs global shutter (Quest tracking cameras are) [C].
   **Ship only with `BASALT_BUILD_SHARED_LIBRARY_ONLY=ON`** (`CMakeLists.txt:255`): that drops
   `ros` and `apriltag` (`thirdparty/CMakeLists.txt:8-13`) and the `rosbag`/`apriltag`/`opengv`
   link of `basalt_internal` (`CMakeLists.txt:453-476`) [M-static]; visualisation (Pangolin) off.
   Reason: `thirdparty/apriltag/ethz_apriltag2` is **4-clause BSD with an advertising clause**
   [M-static `LICENSE`] and, per the review, matches Kaess's LGPL-2.1 AprilTags [C].
   `basalt_calibrate` stays a developer tool, never shipped. **D6 audit item:** confirm the built
   `.so` links none of these.
2. **OKVIS2** — second provider behind the same VIT-like interface, and the accuracy reference
   in our replay tests. Build with **`USE_NN=OFF`**; `fast-scnn.pt` and `small_voc.yml.gz` are
   **[O]** (provenance) and not shipped; the DBoW2 notification duty applies if DBoW2 is linked
   (§9). Its CPU cost on XR2 Gen 2 is the question [O].
3. **Kimera-VIO / ROVIO** — fallbacks only (ROVIO if CPU is the binding limit).
- GPL-3 systems are **not banned** (a separate GPL daemon is lawful), but they would force the
  tracker process to GPL-3 and give no accuracy gain over the two BSD picks [D]. Reference only.
- **XR2 Gen 2 fit [D/O]:** six aarch64 cores, **sustained 1.92 GHz** (Meta L4;
  `perf-envelope-quest3.md:32`). A 2–3× slowdown from the 5800X is **optimistic** at that clock;
  3–5× gives about 36–60 ms of CPU per 4-camera frame, i.e. 1.1–1.8 cores at 30 Hz (§7.2). Not
  measured: risk R3 stays, and **an ARM replay measurement (MSD/EuRoC on an aarch64 core at about
  1.9 GHz) is required before T2b**.
- **Valve does not run this on the CPU alone:** the Frame offloads to its own CDSP program
  (`dsp_service`: IMU and NN) and to Qualcomm EVA/CVP (`evass.mbn`, `/dev/cvp`) for undistort
  and rectify (`tracking-input-route.md` §1.1) [M-static]. We have no open equivalent [O].

### 1.4 IMU-only 3DoF for an early release
- **Monado `m_imu_3dof.c`** (BSL-1.0) [M-static]: gyro integration plus *optional* tilt correction
  after 20 or 300 ms "level" windows; **yaw never corrected**; gyro bias only when triggered.
  Prediction via `m_relation_history` (4096 entries, lerp/slerp) and `m_predict` [M-static].
- **x-io Fusion** (MIT) [M-static `LICENSE.md`]: revised Madgwick (thesis ch. 7) complementary
  filter, **runtime gyro-offset estimation at rest**, accel and magnetic rejection [C, README].
- The Q3 SyncBoss has a `mag` supply (`tracking-input-route.md` §2.2) [M-static]; whether a
  magnetometer is streamed is [O]. Without it, yaw drifts in any 3DoF mode.
- **Recommendation:** Fusion for orientation (or port its at-rest bias logic into ours) +
  Monado's relation history for prediction. Both permissive.

---

## 2. Controller tracking (IR LED constellations)

### 2.1 What exists

| Work | What it does | Status | Licence |
|---|---|---|---|
| **Monado mainline `src/xrt/tracking/constellation/`** | Blob detection (`t_rift_blobwatch`), correspondence search, LambdaTwist P3P, RANSAC + Ceres PnP refinement, LED-sync refinement, dataset recording, Rerun debug | **New in 2026** (Beyley Cardellio, ported from Schmidt/Zabel work) [M-static headers]. Generic "camera mosaic" whose origin may be a **moving tracking source** with no fixed pose (headset-relative use is designed in) [M-static `t_constellation_tracker.h`]. Wired only to the CV1 sensors tracking the CV1 HMD and **PS VR2 Sense** controllers, behind `RIFT_PROBER_CONSTELLATION_TRACKING` (default off) [M-static `target_builder_rift.c`] | BSL-1.0 throughout [M-static]; its LambdaTwist is a BSL rewrite, not the GPL-3 reference [M-static] |
| **thaytan/monado `dev-constellation-controller-tracking`** | **Inside-out** controller tracking for **Rift S** and **WMR** (Reverb G2) | WIP, not merged; its own status line: "works, not very good yet" [C]; first Rift S video 2024-03 [C]; FOSDEM 2026: the advanced port "exists in various branches but is not merged" [C] | BSL-1.0, some files dual LGPL/GPL **or** BSL [M-static] |
| thaytan/OpenHMD `rift-kalman-filter` | CV1 outside-in: UKF with delay slots, two-phase LED matching | Never merged; OpenHMD unmaintained [C]. 2021: headset about 1 cm, controllers "really good most of the time" with fly-aways and hand swaps; latency at least about 20 ms [C, noraisin.net] | BSL-1.0 |
| Monado WMR mainline | Controllers 3DoF only [C] | — | BSL-1.0 |
| Monado PS VR2 | 6DoF HMD (on-device SLAM pose over USB) merged after 25.1.0 [M-static `doc/changes`]; Sense 6DoF via the tracker is unproven; users still report Sense 3DoF [C, vronlinux wiki 2026-09] | — | BSL-1.0 |
| Faessler et al. (ICRA 2014) monocular IR-LED pose | Combinatorial matching + tracking | Research code | GPL, commercial by contact [C] — reference only |
| Quest-specific | **None open.** Q1/Q2 community work is 3DoF only; a Touch-Plus-on-Quest-2 community module uses Meta's stack [C]; a Reddit modder plans Quest 3 controllers on Steam Frame, no repo [C] | — | — |

### 2.2 Key facts for the Quest
- **Rift S controllers are the Quest 1 Touch generation** (same second-generation Touch) [C,
  iFixit/RoadtoVR]. Quest 2 Touch is a different generation (still a ring) [C].
- **Rift S controllers report their own LED model.** thaytan's driver reads a calibration JSON
  from the controller over the radio and builds the LED model (positions and normals) from it
  (`rift_s_controller.c` `ctrl_json_cb`, `rift_s_controller_get_led_model`) [M-static]. If the
  Quest Touch family does the same through SyncBoss, **we would get LED models from the user's
  own controller, not from Meta software** [D; Quest behaviour O].
- **Exposure interleaving:** Rift S alternates SLAM and controller exposures ("SLAM frames are
  every 2nd frame of 60Hz camera feed", `rift_s_tracker.c:160`) [M-static]; Q1 reportedly does
  the same at 2×30 Hz [C]. The Q3 scheme is [O].
- **Touch Plus: 8 IR LEDs per controller, 7 under the faceplate and 1 at the handle base**
  (Steam Frame controllers: 18) [C, UploadVR]; Meta fuses it with always-on hand tracking and the
  IMU and gives no numbers [C, UploadVR]. **No open tracker has ever tracked a Touch Plus.**
- **Touch Pro** tracks itself with its own cameras [C]; an open route would need its pose
  protocol, not an LED tracker [O]. Pairing may trigger updates (H7; deferred, D-T9).
- **Ring Touch on Q3:** no official support; a Meta feedback item is still "investigating" [C].
- Meta's own public blog series (Constellation, LED matching, holiday lights) describes the same
  pipeline (blobs → match → PnP → IMU fusion) and warns that ambient lights create hundreds of
  false blobs [C, developers.meta.com 2019].

### 2.3 Ranked shortlist and recommendation
1. **Monado mainline constellation tracker as the engine** (BSL, maintained, generic) **+ port
   the inside-out glue from thaytan's Rift S branch** (exposure handling, controller IMU fusion,
   LED model from the controller). Engage Jan Schmidt and Beyley Cardellio upstream; our Quest
   work should land upstream, which also earns review [D].
2. thaytan's branch as-is — a quicker spike for ring Touch, but WIP and diverged.
3. OpenHMD UKF and Faessler — design references only.
- PnP libraries if needed: OpenCV (Apache-2.0) [M-static], PoseLib (BSD-3) [C].

---

## 3. Hand tracking

### 3.1 Candidates

| Option | Code licence | Model / data licence | Fit and evidence |
|---|---|---|---|
| **Monado Mercury** | BSL-1.0 (`hg_model.cpp`, `hg_sync.cpp`) [M-static]; last commit 2026-09-30 [C] | **Models repo has no LICENSE** (README is one line; last model commit 2023-01-23) [C, GitLab API]. **Issue #1, "What licence applies to the hand-tracking models?", opened 2026-10-10, is open** [M-static, GitLab API]. A third-party README (julianjc84/OpenLeap) calls them "openly-licensed (CC-BY-SA 4.0)" **with no source** [M-static README]: not evidence. Its training code `mercury_train` is BSL-1.0, but its datasets include **FreiHAND ("commercial use is prohibited")**, **EPIC-KITCHENS (CC BY-NC 4.0)** and **CMU Panoptic (research-only)**, plus Blender synthetic data (**hand asset licence [O]**) and in-house sets [C, `CombinedDataset.py`] | **Best architectural fit:** grayscale, stereo, fisheye-capable, ONNX Runtime on CPU (`grayscale_detection_160x160.onnx`, `grayscale_keypoint_jan18.onnx`) [M-static]; each ONNX session is single-threaded (`onnx_wrapper.cpp:28`) inside a **4-thread worker pool** (`hg_sync.cpp:1147-1148`) [M-static]. OpenLeap runs it on Leap Motion IR stereo [C]. Proven on Index and Luxonis; degraded on WMR and Rift S [C, monado.freedesktop.org]. **No published latency or accuracy** [C] |
| **MediaPipe Hands / Hand Landmarker** | Apache-2.0 (v1.1.1, 2026-10-14) [C] | **Model card: Apache-2.0**; Google's own consented data; "experimental usage" [C, model card PDF] | Monocular **RGB** model (192² detector, 224² landmarks): domain gap on IR mono; stereo triangulation is ours (Monado's removed `old_rgb` pipeline did exactly this, 2022–2023) [C]. Pixel 6: 17 ms CPU / 12 ms GPU [C]. **Qualcomm AI Hub, XR2 Gen 2 NPU: detector 1.24–1.39 ms, landmarks 1.78–1.89 ms** [M-static `perf.yaml`]; stereo with two hands ≈ 2 × (detector + 2 × landmarks) ≈ **10 ms per frame** [D]. **That route is proprietary** (Qualcomm QNN/TFLite-delegate libraries) |
| MMPose / RTMPose | Apache-2.0 [C] | Hand weights trained on "Hand5" incl. FreiHAND: **not clean** [C] | Good training framework for our own model |
| UmeTrack (Meta) | CC BY-NC 4.0, archived [C] | Same | Closest domain (headset mono fisheye), **evaluation only** |
| HaMeR, WiLoR, Hamba, FrankMocap, InterHand2.6M | MIT / CC BY-NC(-ND) [C] | All need **MANO** (non-commercial; forbids training commercial networks) or NC data [C, mano.is.tue.mpg.de] | Excluded from shipping |
| HOT3D + `hand_tracking_toolkit` | Apache-2.0 toolkit [C] | Hand annotations CC BY-NC-SA [C] | Evaluation metrics only |
| HaGRID (gesture images) | — | README: "a variant of" CC BY-SA 4.0 with its own PDF licence [M-static README]; **terms unread [O]** | RGB gesture/box data; detector training at most; check before use |

### 3.2 Ranked shortlist and recommendation
1. **Mercury code (BSL) retrained by us with `mercury_train` (BSL) on clean data:** Blender
   synthetic hands (asset licence [O]) + our own consented IR captures (+ any permissively
   licensed set we verify).
   Best fit for stereo IR; the retraining is the cost. Meanwhile, **ask Collabora** for the
   shipped models' licence and data provenance (D-T6; issue #1 is open); given
   FreiHAND/EPIC/Panoptic in the training mix,
   **do not ship the current models** even if a licence file appears, without that provenance [D].
2. **MediaPipe models (Apache-2.0)** as the fallback and the quickest legal prototype: grey →
   3-channel input, per-view landmarks, our triangulation; expect reduced robustness on IR [D].
3. **Our own model** trained with MMPose (Apache-2.0) if both fall short.
- **Compute on XR2 Gen 2 [D/O]:** AI Hub's ~3 ms per hand (≈ 10 ms per stereo frame with two
  hands) uses Qualcomm's NPU stack (QNN/TFLite delegate): a **proprietary** route that needs
  Qualcomm user libraries and a working CDSP/fastrpc path on our Linux. Not established, and a
  licence item. Plan for CPU (ONNX Runtime/XNNPACK) or GPU (Vulkan/OpenCL on
  Adreno 740) first; Mercury's 160² detector suits CPU at a reduced rate (e.g. 30 Hz) [D].
- **Steam Frame ships no controller-free hand tracking at launch** [C, UploadVR], so hands are
  not needed for parity with Valve; they matter for Touch Plus fusion (§2) and later features.

---

## 4. Runtimes and integration

| Option | Licence | What it gives us | Verdict |
|---|---|---|---|
| **OpenVR driver API** (`IServerTrackedDeviceProvider_004`, `IVRServerDriverHost_006::TrackedDevicePoseUpdated`, `IVRDriverInput_004::Create/UpdateSkeletonComponent`) | BSD-3; v2.15.6, 2026-03-27; ships linuxarm64 libs [M-static per agent] | The documented seam into Valve's SteamVR | **Use** (as now) |
| **Monado `steamvr_drv`** (`ovrd_driver.cpp`, driver_monado) | BSL-1.0 [M-static] | Whole Monado inside vrserver; controller and skeleton code to copy | **Borrow code patterns**; do not run the whole thing (it brings its own prober and display) |
| **Monado as the runtime** (OpenXR) + driver | BSL-1.0; 25.1.0 (2025-12-09), commits daily [M-static] | VIT, constellation, Mercury, prediction all in one tree | Library source, not our runtime: SteamVR stays the runtime |
| **ALVR** | MIT [M-static per agent] | `Controller.cpp` skeleton components; `tracking.rs` `to_openvr_ffi_hand_skeleton` (26 OpenXR joints → 31 SteamVR bones); pose history and prediction; hand-gesture → button emulation | **Reusable** (MIT) for skeletal input and prediction |
| **WiVRn** | GPL-3.0 [M-static per agent] | Patched Monado; pose lists, clock offset, polynomial interpolation; a Frame controller-interaction patch | Reference only (GPL-3) |
| xrizer / OpenComposite | GPL-3.0 [M-static per agent] | OpenVR apps on OpenXR (the other direction) | Not needed |
| VRto3D | LGPL-3.0 [C] | Example of a minimal OpenVR HMD driver | Reference |

- **How others feed SteamVR [C/D]:** ALVR is an OpenVR driver fed by poses from the headset
  (Meta tracks); WiVRn is an OpenXR runtime fed the same way. Neither tracks anything itself, so
  only their **driver plumbing** (prediction, skeleton mapping, device profiles) is reusable.

---

## 5. Sensor plumbing

| Piece | Mainline status | Relevance |
|---|---|---|
| `ov7251` | Since 4.18; 640×480 Y10 at 30/60/90 fps; **no trigger/strobe/FSIN control** [M-static per agent] | Our Q3 OV7251 pair, if we ever drive sensors ourselves |
| `og01a1b` | Since 5.18 (Intel); 1280×1024 Y8/Y10 about 120 fps; no trigger [M-static per agent] | Possibly the Q3 "OG" pair (part number [O]); Valve ships an `og01a1b-a` variant (`tracking-input-route.md` §1.1) |
| `og0ve1b` | Since 6.18 (Linaro); `og0va1b` folded in, v5 on the list 2026-07 [M-static/C] | Valve ships `og0ve1b` |
| Qualcomm CAMSS | **SM8550 merged 6.15; X1E80100 6.17; SM8650 6.19; SM8450 none; SM8750 on the list** [M-static per agent] | The Quest 3 runs Meta's downstream kernel and **Spectra**, not CAMSS; the sensors are `hw_no_io_ops` and camera power is **TZ-owned** (`tracking-input-route.md` §2.1) [M-static]. CAMSS matters only for a future mainline-kernel Quest port; whether XR2 Gen 2 matches SM8550 CAMSS is [O] |
| CCI (`i2c-qcom-cci`) | Binding lists sm8450/8550/8650/8750 [M-static per agent] | Same caveat |
| libcamera | No Qualcomm handler; "simple" pipeline + software ISP on CAMSS (sdm845, sm8250, sc8280xp, x1e80100) [C]; LGPL-2.1+ | **Not needed:** trackers want raw Y8/Y10 with timestamps, which V4L2 or Spectra give directly [D] |
| IMU | IIO `inv_icm42600` covers ICM-42688 [M-static per agent] | Not used on Quest: the IMU is behind SyncBoss |

- **Gap [D]:** no mainline sensor driver exposes strobe/trigger control. LED-synchronised
  controller exposures need sensor programming that, on Q3, nothing in the kernel does today.

---

## 6. Prior art: standalone Linux headsets with tracking

| Project | Tracking | What it teaches |
|---|---|---|
| **Steam Frame** (Valve) | Four greyscale fisheye cameras + IR illuminators; controllers with 18 IR LEDs; no controller-free hand tracking at launch [C, UploadVR]. Internally **a Basalt-derived estimator inside a proprietary SLAM/relocalisation layer**: `XRService` strings name `arcturus-xr/basalt/src/{vi_estimator/keyframe_processor,vi_estimator/landmark_creator,map/frame}.cpp`, paths that exist in neither upstream Basalt nor the mateosss fork (whose `src/` has no `map/` or `frontend/`), beside "Perception Engine" and "bridge engine" [M-static `strings`, clone]; the review also cites `basalt::VioEstimator<float>`, `rnd::Mapper`, `oc::sparse::PersistentWorld` and `ST::` [C, review]. `libArcturusPerception.so` has **0** "basalt" strings, and the notice credits "basalt" at github.com/basalt/basalt under **MIT** [M-static]. NN controller models run on Valve's CDSP (`tracking-input-route.md` §1). No public Valve talk or paper on Frame tracking found [C] | Valve started from Basalt's estimator (supports §1.3 pick 1), but the **mapping and relocalisation that make it product-grade are Valve's own and closed** [D] |
| **Lynx R1** | 2025-08-22: Lynx open-sourced its experimental 6DoF, **ORB-SLAM3 for Android, GPLv3**, 90 fps on XR2 Gen 1 **without IMU**, some proprietary Qualcomm acceleration; Qualcomm's 6DoF stays the default [C, Lynx blog] | Open VO can run on XR2-class CPUs; GPL and no IMU make it a poor base for us |
| **postmarketOS** | Sept 2026 conference talk: "initial support" for Oculus Go, Lynx R1, **Quest 3S** and Steam Frame [C] | Possible allies on mainline-kernel Quest bring-up; tracking not claimed |
| Quest1-SteamOS (no licence), quest-kexec-q2 (GPL-2.0; Monado driver BSL-1.0), Block-Flock pmaports (no licence; Monado fork BSL-1.0) | 3DoF head and Touch; camera capture through Meta's HAL or replayed traces; no 6DoF [C/M-static] | See `tracking-input-route.md` §5 and `quest-ports-tracking.md` §1 |
| **cstahly/quest1-bootloader-to-VR** (Quest 1, Nura; MIT, patches keep upstream licences) | **Experimental live Basalt 6DoF** (mateosss `df6e970`, VIT) in a separate process, fed to Monado through an opt-in pose mailbox. Wearer trials walked "in full light", but the owner **rejected** it: frequent lock loss, about 90–108 ms pose age, stutter, failure in low light. Never the default; the installed scene stays 3DoF. Cameras come through Meta's stock HAL (pointer only, D-T10) [C, `quest-ports-tracking.md` §1.1] | **No reliable 6DoF on any Quest.** Reusable: two BSD-3 Basalt patches, MIT diagnostic scripts, the pose-adapter and quality-gate design (`tracking-input-route.md` §5.4) |
| YusufOzmen01/quest-kexec (Quest Pro; GPL-2.0) | "6DoF" log line from **Meta's own `trackingservice`, in a second kexec'd Android** [C] | Not an open tracker; not a precedent (no Meta provider) |
| Simula One | Linux, Ultraleap (proprietary) hands; status stale since about 2022 [C] | — |
| ALVR / WiVRn on Quest | Meta tracks on the headset; Linux PC only renders [C] | Driver plumbing only |

---

## 7. Best open stack for the Quest 3

```
 fs-trackd (our daemon)
   capture: SyncBoss IMU 1 kHz + controller packets; tracking cameras (R1)
   head:    Basalt (BSD-3) via VIT  ──►  pose @ 30 Hz  ─┐
            [OKVIS2 alt provider]                      ├─► IMU-propagated pose @ 1 kHz
   3DoF:    Fusion (MIT) until 6DoF is live            ─┘    (Monado relation history, BSL)
   ctrls:   Monado constellation (BSL): blobs → LED match → P3P/RANSAC/Ceres
            + controller-IMU filter (UKF, OpenHMD design) + LED models read from the controller
            + Touch Plus: hand-pose prior from the hand tracker (new work)
   hands:   Mercury pipeline (BSL) with our retrained models; MediaPipe (Apache-2.0) fallback
 driver_frameshift.so (OpenVR, our code; skeleton mapping after ALVR, MIT)
```

### 7.1 Expected quality against D-T11 (`tracking-input-route.md` §6.3, rev 1)

D-T11 measures against Horizon on the same unit. **Head:** static jitter ≤ 0.2 mm / 0.02° RMS;
loop drift ≤ 1 cm over 5 min in 3×3 m; relocalisation < 1 s; IMU-to-pose ≤ 2 ms; < 1 tracking
loss per 10 min. **Controllers:** jitter ≤ 0.5 mm / 0.1°; dynamic error ≤ 5 mm RMS up to 2 m/s;
≤ 3 cm after 300 ms on IMU only; reacquire ≤ 100 ms (ring) / ≤ 250 ms (Touch Plus); no jumps
> 2 cm; ≥ 95 % tracked on a scripted motion set.

**Rev 1.1 (J-170):**
- **PASS = match Horizon measured on the same unit.** The numbers above are **goals to beat**,
  revisited once Horizon is measured.
- Context [C]: Duke (MobiCom 2024, DOI 10.1145/3636534.3696215) found Quest 3 Horizon errors of
  about 1 cm typically and above 10 cm in hard scenes. Some goals may be stricter than Horizon.

| Device | Open-stack prospect [D] | Against D-T11 [D] |
|---|---|---|
| **Head** (Basalt + IMU) | Usable room-scale 6DoF with 1 kHz IMU prediction; worse than Insight in fast motion, low texture and darkness | IMU-to-pose ≤ 2 ms: **likely** (the prediction is ours). Jitter and loop drift: **unknown** (MSD median ATEs are cm-scale on hard sequences [C]). Relocalisation < 1 s and < 1 loss per 10 min: **unlikely without a map/relocalisation layer** (§8 item 2) |
| **Ring Touch, Q1 generation** (= Rift S Touch) | Same hardware thaytan tracks: "works, not very good yet" [C]; LED model readable from the controller (Rift S) [M-static] | **No target evidenced.** Jitter and reacquire ≤ 100 ms: unknown. No jumps > 2 cm: contradicted by the fly-aways and hand swaps reported in 2021 (outside-in) [C] |
| **Ring Touch, Q2 generation** | Same method after its LED model and blink scheme; Q2 only (ring Touch on Q3 is not supported [C]) | As above, after the model work |
| **Touch Plus** (Q3/Q3S) | 8 LEDs (7 face, 1 handle), no ring; no open tracker has ever tracked one; Meta relies on hand fusion | **Unknown; plausible only when the faceplate faces the cameras.** ≥ 95 % tracked, and ≤ 3 cm after 300 ms IMU-only, through face-away poses need the hand prior (§8) and may not converge (40–90 pw) |
| **Touch Pro** | Self-tracked; needs its pose protocol, not LEDs | Unknown [O]; deferred (D-T9) |

### 7.2 CPU budget on six cores at the sustained 1.92 GHz [D estimates, unmeasured]

| Load | Cores | Basis |
|---|---|---|
| Basalt, 4 cameras at 30 Hz | 1.1–1.8 | 12 ms/frame on a 5800X [C] × 3–5 for a 1.92 GHz mobile core |
| Mercury hands, stereo at 30 Hz | 1.0–2.0 | 4-thread pool of single-thread ONNX sessions [M-static]; no published latency [C] |
| Constellation tracker (blobwatch on 4 cameras, search, Ceres) | 0.5–1.0 | Ceres single-threaded (`pose_optimize.cpp:417`) [M-static]; cost [O] |
| fs-trackd IMU, fusion, prediction; OpenVR driver | 0.1–0.3 | 1 kHz filters |
| vrserver + vrcompositor | 0.5–1.0 | [O] |
| The game (main + render threads) | 1.5–3.0 | Typical VR title [C] |
| **Sum** | **4.7–9.1 of 6** | Over budget at the upper end, before thermal headroom (§6A) |

- Consequences [D]: lower SLAM and hand rates, share frames, move image work to the GPU (Vulkan
  compute on Adreno 740), or find an open DSP path (none known; Valve uses CDSP and EVA/CVP).
  **Measure on ARM replay before T2b**, and only then fix rates.

---

## 8. Gaps that need our own work

1. **Q3 tracking-camera capture** outside Horizon (Spectra uAPI, TZ camera power): the gate
   for everything optical (R1, C1).
2. **Open relocalisation and mapping layer:** Basalt is odometry; Valve wraps its derivative in
   a proprietary mapper and relocaliser (§6), and Meta has its own. We need map persistence,
   relocalisation after loss and a stable origin for the chaperone. Candidates: Basalt's
   `nfr_mapper` (offline today), maplab (Apache-2.0), DBoW2-style place recognition (mind its
   notification clause) [D/O].
3. **LED models and timing** for each Touch generation: read from the controller if it exposes
   them (as Rift S does), else measure our own (photogrammetry rig). Never from Meta software.
4. **Exposure scheduling and LED sync:** interleaved SLAM and controller exposures; sensor
   programming that no mainline driver offers (§5).
5. **Controller fusion filter** for headset-relative tracking (moving camera origin), tuned per
   generation. The Monado tracker's moving-origin design helps, but the inside-out filter is
   unmerged WIP.
6. **Touch Plus hand prior:** fuse the hand skeleton with sparse LED fixes. No open precedent.
7. **Calibration converter** (8-coefficient Fisheye62 → fisheye624/KB4) and online refinement.
8. **CPU/thermal budget on XR2 Gen 2** (§7.2: 4.7–9.1 of 6 cores estimated; R3): ARM replay
   measurement before T2b; GPU offload; any NPU route is proprietary (§3) [O].
9. **Measurement without external tracking hardware** (D-T16, J-170).
   - PM ruling: **no Lighthouse or mocap**.
   - Both OSes are measured against the same physical references, on the same unit, with the
     same scripts. Ranked methods (detail in `tracking-input-route.md` §7.3 and
     `quest-ports-tracking.md` §5):
     1. fixture stations and a cradle;
     2. Horizon pose logs, via the Quest Link setting or our own logging app (each a device
        change needing PM approval);
     3. printed AprilTag/ArUco boards seen by our own cameras;
     4. self-consistency checks;
     5. protractor yaw steps;
     6. optional slow-motion latency video.
10. **Hand models:** retrain Mercury on clean data (synthetic + our own consented captures) and
   validate on IR; or adapt MediaPipe. Open NPU use on our Linux is [O].
11. **OpenVR driver** with prediction and skeletal input (ALVR/Monado patterns).
12. **Upstreaming:** Quest drivers and Touch models into Monado, so the work is reviewed and
    maintained beyond us.

---

## 9. Licence summary

| Component | Code | Models / data | Use |
|---|---|---|---|
| Basalt (+ mateosss fork) | BSD-3; `thirdparty/apriltag/ethz_apriltag2` is 4-clause BSD (advertising clause; per the review it matches LGPL-2.1 AprilTags) | — | Ship **only** the shared library (`BASALT_BUILD_SHARED_LIBRARY_ONLY=ON`, no visualisation); `basalt_calibrate` dev-only; D6 audit of the linked `.so` |
| OKVIS2 / OKVIS2-X | BSD-3; submodules ceres, brisk, opengv, DBoW2 [M-static `.gitmodules`; brisk licence O] | `resources/fast-scnn.pt`, `resources/small_voc.yml.gz`: **provenance [O]** | Ship with `USE_NN=OFF`, without the CNN; vocabulary [O]; **DBoW2 clause 3: "The original author of the work must be notified of any redistribution"** [M-static DBoW2 `LICENSE.txt`] |
| Kimera-VIO | BSD-2; requires DBoW2 (same clause 3), GTSAM, opengv | Vocabulary [O] | Ship (fallback) with the DBoW2 notice duty |
| XRSLAM / maplab | Apache-2.0 / Apache-2.0 [C] | — | Candidates (mono VIO / map layer) |
| ROVIO | BSD-3 | — | Ship (fallback) |
| OpenVINS, ORB-SLAM3 (and Lynx port), VINS, SVO Pro, DM-VIO | GPL-3.0 | — | Reference only |
| xivo | Non-commercial | — | Excluded |
| Monado (VIT, constellation, Mercury code, math, steamvr_drv) | BSL-1.0 (1,534 files; no GPL in `src/`) [M-static] | Mercury models: **no licence** (issue #1 open since 2026-10-10); trained partly on FreiHAND (no commercial use), EPIC-KITCHENS (CC BY-NC) and CMU Panoptic (research-only) [C] | Ship code; **do not ship the models** |
| mercury_train | BSL-1.0 [C] | Blender synthetic generator in-tree (hand asset licence [O]); external datasets carry their own (NC) terms | Retrain on clean data |
| MediaPipe Hands | Apache-2.0 | Model card Apache-2.0 [C] | Ship (fallback) on CPU/GPU; the NPU route needs **proprietary** QNN libraries |
| HaGRID | — | "Variant of" CC BY-SA 4.0; PDF terms unread [O] | Check before use |
| MMPose / RTMPose | Apache-2.0 | Published hand weights not clean (FreiHAND) | Train our own |
| MANO-based models (HaMeR, WiLoR, Hamba, FrankMocap), UmeTrack, InterHand2.6M, HOT3D hands | MIT / CC BY-NC | MANO non-commercial; NC data | Evaluation only |
| thaytan branch | BSL-1.0 or dual (LGPL/GPL **or** BSL) | — | Ship under BSL |
| OpenHMD | BSL-1.0 | — | Reference |
| x-io Fusion | MIT | — | Ship |
| OpenVR headers | BSD-3 | — | Ship |
| ALVR | MIT | — | Copy with notice |
| WiVRn, xrizer, OpenComposite | GPL-3.0 | — | Not needed |
| OpenCV / PoseLib / Ceres | Apache-2.0 / BSD-3 / BSD-3 [C for the last two] | — | Ship |
| Monado SLAM Dataset | — | CC BY 4.0 | Test data |

---

## 10. Sources

- Monado source (clone `ddeba9f6`): `src/xrt/tracking/constellation/`, `targets/common/target_builder_rift.c`,
  `drivers/pssense/`, `drivers/psvr2/`, `auxiliary/math/m_imu_3dof.c`, `doc/CHANGELOG.md`, `doc/changes/`.
- thaytan/monado (clone `b1c850a0`): `drivers/rift_s/rift_s_controller.c`, `rift_s_tracker.c`, `rift_s_camera.c`.
- Basalt: https://gitlab.com/VladyslavUsenko/basalt ; https://gitlab.freedesktop.org/mateosss/basalt
- OKVIS2 licence: https://raw.githubusercontent.com/ethz-mrl/okvis2/main/LICENSE ; OKVIS2-X: https://arxiv.org/abs/2510.04612
- Monado SLAM Dataset: https://arxiv.org/abs/2508.00088 ; https://huggingface.co/datasets/collabora/monado-slam-datasets
- Jetson VIO study: https://arxiv.org/abs/2103.01655 ; ORB-SLAM3: https://arxiv.org/abs/2007.11898
- Collabora 2022: https://www.collabora.com/news-and-blog/blog/2022/12/20/state-of-monado-visual-inertial-tracking/
- FOSDEM 2026 "Monado and beyond" transcript: https://ftp.fau.de/fosdem/2026/h1302/T38AKM-monado-and-beyond.vtt
- x-io Fusion: https://github.com/xioTechnologies/Fusion
- thaytan blog: https://www.noraisin.net/diary/ ; OpenHMD fork: https://github.com/thaytan/OpenHMD
- Monado docs: https://monado.pages.freedesktop.org/monado/ ; PS VR2 wiki: https://vronlinux.org/docs/hardware/psvr2/
- Meta constellation blogs: https://developers.meta.com/horizon/blog/increasing-fidelity-with-constellation-tracked-controllers/ ;
  https://developers.meta.com/horizon/blog/tracking-technology-explained-led-matching/
- Touch Plus tracking: https://www.uploadvr.com/meta-explains-quest-3-controller-tracking/
- Steam Frame: https://www.uploadvr.com/valve-steam-frame-official-announcement-features-details/
- Lynx 6DoF: https://portal.lynx-r.com/blog/view/open-sourcing-lynx-6dof/
- postmarketOS 2026 talk: https://pretalx.postmarketos.org/postmarketos-conference-2026/talk/8UMTPU/
- Kernel: https://github.com/torvalds/linux (`drivers/media/i2c/{ov7251,og01a1b,og0ve1b}.c`, `drivers/media/platform/qcom/camss/camss.c`)
- libcamera: https://patchwork.libcamera.org/patch/19882/
- OpenVR: https://github.com/ValveSoftware/openvr ; ALVR: https://github.com/alvr-org/ALVR ; WiVRn: https://github.com/WiVRn/WiVRn ; xrizer: https://github.com/Supreeeme/xrizer
- Hands: https://monado.freedesktop.org/handtracking.html ; https://gitlab.freedesktop.org/monado/utilities/hand-tracking-models ;
  https://gitlab.freedesktop.org/monado/utilities/hand-tracking-playground/mercury_train ; https://github.com/lmb-freiburg/freihand ;
  MediaPipe model card https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Hand%20Tracking%20(Lite_Full)%20with%20Fairness%20Oct%202021.pdf ;
  https://github.com/qualcomm/ai-hub-models/blob/main/src/qai_hub_models/models/mediapipe_hand/perf.yaml ; https://mano.is.tue.mpg.de/license.html ;
  https://github.com/facebookresearch/UmeTrack ; https://github.com/geopavlakos/hamer ; https://github.com/open-mmlab/mmpose
- Rev 1: DBoW2 licence https://github.com/dorian3d/DBoW2/blob/master/LICENSE.txt ; OKVIS2 https://github.com/ethz-mrl/okvis2 ;
  Kimera-VIO https://github.com/MIT-SPARK/Kimera-VIO ; XRSLAM https://github.com/openxrlab/xrslam ; maplab https://github.com/ethz-asl/maplab ;
  HaGRID https://github.com/hukenovs/hagrid ; OpenLeap https://github.com/julianjc84/OpenLeap ; Mercury models issue #1 (GitLab API).
- Rift S = Quest 1 Touch: https://www.ifixit.com/Device/Oculus_Rift_S ; ring Touch on Q3: https://developers.meta.com/horizon/feedback/vr/investigations/5180917188794843/

---

## 11. Differences from `tracking-input-route.md` (for its revision)

- Mercury models: "licence [O]" → **no licence file, and training data includes FreiHAND and
  EPIC-KITCHENS (non-commercial)**; D-T6 should become "retrain with `mercury_train` on clean
  data; ask Collabora; MediaPipe fallback" [C].
- Constellation: mainline now has a **generic, BSL, 2026 constellation tracker** with a
  moving-origin camera mosaic (still outside-in in use) [M-static]; the Rift S controller LED
  model is **read from the controller** in thaytan's branch [M-static].
- Touch Plus has **8 LEDs** per controller (Steam Frame: 18) [C].
- Valve's Frame head tracking: "Basalt-derived VIO" → **a Basalt-derived estimator inside a
  proprietary SLAM/relocalisation layer**; its notice credits "basalt" under MIT, not Basalt's
  BSD-3 [M-static]. The open map/relocalisation layer is a gap.
- Mercury: ONNX sessions are single-threaded but run in a 4-thread pool (R3 budget).
