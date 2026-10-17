# Tracking and input route: head 6DoF, Meta controllers and hands (stage 5b)

**Status:** research and recommendation only. No device was touched and nothing was installed or
run.
- **Rev 0:** 6256d02.
- **Rev 1:** ed0f28d (review GO-with-fixes; J-160).
- **Rev 2.4:** 2026-10-15. **J-183:** D-T3 decided (the product reads the user's own tracking calibration; self-calibration fallback; no reverse engineering of Meta's tracking).
- **Rev 2.3:** 2026-10-14. **J-170** and `quest-ports-tracking.md` rev 0 (dbeda68):
  - Quest prior art corrected: no reliable 6DoF on any Quest; cstahly's rejected Basalt experiment
    is added (§5.4).
  - Basalt epipolar bug and the reusable community items added to the fork work (§5.1, §5.4).
  - **D-T11:** PASS = match Horizon on the same unit; the numbers become goals (§7.3).
  - **D-T16:** replaced by validation without external hardware (§7.3).
- **Rev 2.2:** 2026-10-14. **J-165:** bundled controllers first (§6.2; D-T2 and D-T5 revised; stages
  T3b/T4/T5 reordered, totals unchanged); D-T3 and D-T16 marked open, pending PM.
- **Rev 2.1:** 2026-10-14. Adds **J-163** and **J-164** (a dedicated tracking process, §6.3; the DSP
  as an early checkpoint, §6.4; the CPU split). From J-163: Horizon parity as the pass mark (§7.3), Meta's limits
  adopted as values (§8.0), native Chaperone matched to Guardian by measurement (D-T17), models
  trained from scratch (D-T6).
- **Rev 2:** 2026-10-14. Applies the PM decisions and questions of **J-162** and the corrections
  in `oss-tracking-survey.md` §11 (rev 1, 44588e8). The change log is §12.

**Method:**
- No Valve, Meta or Qualcomm binary was disassembled or decompiled. Binaries were read only for
  file names, `strings` and package metadata. Valve's SteamVR resource JSON was read for **key
  structure only** (no values).
- Kernel and DT facts come from Meta's published GPL source:
  - Quest 3 v2.7: WSL `~/work/kgate27/src`, `dbc2bc83a`;
  - Quest 2 tree: `~/work/kgateq2/src`.
- Valve facts come from the 0.3.0 Frame rootfs (WSL `~/sfroot-full`) and
  `firmware/SteamOS/extracted/`. 0.4.5 is not diffed [O].
- Open source and community: clones in `~/work/tracking-research/` and the survey
  `oss-tracking-survey.md` (rev 1.1). Survey claims keep their tags. Rev 2.3 adds the Quest-port
  clones in `~/work/quest-ports/` (read only; see `quest-ports-tracking.md`).
- Disclosure (rev 0): Valve's `sm8650-deckard.dtb` was converted with `dtc`. The output was deleted
  and nothing from it is cited.
- **AI-directed text:**
  - rev 2: none found in the sources read;
  - survey: one instance (Basalt issue #117 on gitlab.com), ignored;
  - rev 2.3: cstahly's repo has handoff notes to its own agents, ignored
    (`quest-ports-tracking.md` §6).
- Per-unit calibration is described at the structure level only.

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named file or
source · **[D]** derived · **[C]** unconfirmed · **[O]** open.

**Effort** (J-162 item 6) is given in **two currencies**:
- **agent pw:** person-weeks of focused agent work (coding, research, review);
- **hardware sessions (HS):** attended sessions with the PM, each about 1–2 h under the
  reviewed-trial procedure. They cover trials, data collection, validation runs (§7.3) and tuning
  loops.

Agents compress the first currency. **Tracking quality is bounded by the second**, and by data.

---

## 0. The answer in brief

### 0.1 PM decisions and questions (J-160, J-162)

| # | PM item | Status in this revision |
|---|---|---|
| 1 | **No Meta provider** (Meta will not clear its models, training or software) | Removed entirely. The provider framework stays for our own and future providers (§6.1) |
| 2 | **Ring Touch must work on Quest 3**, built by us, legally clean | New analysis in §3: radio path, pairing, input format, LED model. Community ports of Meta binaries are pointers only (D-T10) |
| 3 | **Steam Frame controllers** with Valve's tracker, "translating the camera locations" | Needs Valve's tracker to accept Quest sensors, which needs Valve's cooperation: a held-letter question. Fallback outlined in §4 |
| 4 | **Basalt is the lead.** Is Valve's Basalt derivative open? | **No.** BSD-3 (and the MIT notice Valve ships) permit proprietary derivatives with attribution only. Plan: **our own improved Basalt fork + an open map/relocalisation layer** (§5.1) |
| 5 | **One hand model for all Quests** | Camera-agnostic training, per-device calibration, clean licensed and own-collected data under privacy rules (§5.3) |
| 6 | **Polish over effort** | Effort in agent pw **and** hardware sessions (§7.2) |
| 7 | "If the cameras are detected as peripherals, they should be usable" | Detection is not power or streaming (§2.2) |
| 8 | **How does Quest track, and does it offload?** | Horizon's pipeline and our offload options (§2.6) |

### 0.2 Summary

1. **Valve's Frame tracker is tied to Frame hardware.**
   - IMU on Valve's ADSP image; NNs on Valve's CDSP image;
   - an FPGA CSI aggregator; CAMSS; ICP/EVA;
   - models trained on Valve controllers.
   - Its `ExternalCaptureSource` and `.occ` replay are internal, not documented seams.
   - It is a Valve question, not a plan (§1).
2. **The documented seam is the OpenVR driver API.** Our driver presents the HMD and controllers,
   with our own input profile (controller type `oculus_touch`, registered with `vrpathreg`).
3. **Quest 3:**
   - SyncBoss (nRF52833) carries the IMU and the controller radio. Q2 uses an nRF52832 with the
     same driver family [M-static].
   - The six cameras are DT-declared raw MIPI sensors. Their power is TZ/sensorlock-gated, and
     their programming is outside the kernel.
4. **Recommendation: an open, own-code tracking bridge in two layers** (§6):
   - a pose API;
   - kernel-enforced sensor ownership and safety (the SyncBoss filter).

   Providers:
   - **P-open (ours)** is the default and the only one planned;
   - **P-valve** only if Valve offers an interface;
   - no Meta provider.
5. **Effort to the full Q3 set:** about **137–295 agent pw plus about 90–203 hardware sessions**,
   plus contingency (§7.2). This is a long road; polish is bounded by hardware loops and data.
6. **Safety** (§8): unchanged from rev 1, plus pairing and LED duty rules for ring Touch.
7. **Eighteen PM decisions** (§9). Tracking runs as a dedicated, isolated process on reserved
   cores (§6.3), and the DSP gets an early checkpoint (§6.4).

---

## 1. How the Steam Frame tracks (Valve rootfs, 0.3.0)

| Piece | What it is | Source |
|---|---|---|
| `drivers/cv/` | HMD and tracking driver `driver_cv.so`, `hmd_presence ["28DE.2300"]` | manifest [M-static] |
| `XRService` + `libArcturusPerception.so` | **A Basalt-derived estimator inside a proprietary SLAM/relocalisation layer** (`arcturus-xr/basalt/src/vi_estimator/...`). `ST::`/`oc::`/"Perception Engine" names suggest a licensed core [D]. The notice credits "basalt" under **MIT** (github.com/basalt/basalt), not Basalt's BSD-3 | strings, notices [M-static]; survey §11 |
| `ExternalCaptureSource` (`dispatchIMUEvent`/`Accel`/`Gyro`), `.occ` capture files | In-process capture abstraction and replay format; no documented interface | strings [M-static] |
| `adsp_sm8650.mbn` | **IMU path:** 51 `[ICM42688]` strings ("Setting up SSC GPIOs configuration for SM8650") | strings [M-static] |
| `dsp_service` + `cdsp_sm8650.mbn` | Valve's CDSP program: gaze NN, controller LED/palm feature NN | strings [M-static] |
| `evass.mbn`, `CAMERA_ICP.mbn`, `/dev/cvp`, `/dev/icp` | EVA/CVP and camera ICP | [M-static] |
| `/usr/lib/deckard-fpga/` | FPGA CSI aggregator (`passthru`/`vcint` images) | [M-static] |
| Kernel 6.18 | `qcom-camss` + Valve sensor drivers (`og0ve1b`, `og01a1b-a`, `og0ve10-a`, `arcimx616`, `ov6211`, `ov6710`), `valve-fpga`, `fastrpc`; binder devices `anbox-binder`… for Lepton (config:7090) | [M-static] |
| `vrdevice_path`, `vrconfig_path` | Name-to-path adapters; calibration in `/persist/{device_config,xrservice,eyetracking}.json` (cameras array, KB/KB-spline intrinsics, `plus_x`/`position` extrinsics, IMU bias and noise, time offset) | [M-static] |
| `drivers/frame_controller/resources/config/*_base.json` | Per-revision controller base configs. Keys: `imu {plus_x, plus_z, position}`, **`lighthouse_config {modelPoints[18], modelNormals[18]}`**, `device_class`, `model_number`, `revision`, `tracked_controller_role` | key structure [M-static]; 18 matches the public LED count [C] |

- **Could it take a Quest rig?**
  - The algorithm layer is partly generic (camera count, KB4, rolling-shutter corrector, external
    capture) [D].
  - The capture, IMU and NN layers are Frame-only.
  - **Not without Valve.** The held letter asks (D-T14).
- `driver_cv` stays dormant on a Quest (no `28DE:2300`) [C].
- **Steam Frame ships no controller-free hand tracking at launch** [C, survey §3.2].

---

## 2. Quest 3 hardware side, and how Horizon tracks

### 2.1 Sensors on the Quest 3 (GPL DT)

- **Six `qcom,cam-sensor` nodes** (`eureka-camera.dtsi`) [M-static]:
  - `CAM_OG_LEFT/RIGHT` (OmniVision "OG" mono);
  - `CAM_OV7251_LEFT/RIGHT` (640×480 global shutter [C]);
  - `CAM_RGB_LEFT/RIGHT`.

  Which serve SLAM and which serve controller frames is [O].
- **SyncBoss:** nRF52833 on SPI, 8 MHz, with consumers `swd`, `powerstate` (prox),
  `timesync` (GPIO 125), `directchannel`, `miscfifo` (`anorak-oculus-syncboss.dtsi`) [M-static].
  - Q2 (`hollywood-syncboss.dtsi:144-217`): **nRF52832**, same driver, plus `nsync`.
  - QPro (`seacliff`): nRF52840 [M-static].
- **IR emitters:**
  - flood LEDs `pmxr2230_torch2/3`: default-on, 140 mA cap, hardware strobe from PMIC GPIO 1;
  - the `nautilus` depth projector with a SAFETYBOSS MCU;
  - a SyncBoss prox-IR LED [M-static].

### 2.2 "Detected as peripherals, so usable?" (PM question, J-162 item 7)

**Detected is not usable.**
- The six sensors appear because the **DT declares them**. With `hw_no_probe_pw_ops`, the kernel
  "probes" them **without powering them or reading their ID** (`cam_sensor_core.c:1044-1075`)
  [M-static]. The node exists even if the sensor never answered.
- On a PC a USB webcam just works, because UVC is a standard class and the camera's own firmware
  programs the sensor. A Quest camera is a **raw MIPI sensor**: the host software *is* its
  firmware.

A camera becomes usable only when **all** of these are in place:

| # | Requirement | State on the Quest 3 |
|---|---|---|
| 1 | Power | Regulators and MCLK are switched by the kernel at stream start (`cam_sensor_core.c:1984-2020`). The **L8B camera supply load switch (GPIO 14) is owned by TrustZone** and gated by the **`sensorlock64` trustlet** (`eureka-base.dtsi:178-191`, `sensorlock.c:32-33, 254-370`) [M-static]. Whether it is open outside Horizon is [O] (R1) |
| 2 | Sensor programming (registers: mode, exposure, strobe) | `hw_no_io_ops`: the kernel sends no I2C (`:187-190`). Candidates, ranked: **SyncBoss** camera commands (as on Q2 [C]); **CCI** through a DT change in our image, with mainline GPL `ov7251.c`/`og01a1b.c` as clean register sources; other |
| 3 | Receive path | CSIPHY → CSID → IFE configured through Spectra command packets (`cam_req_mgr`, `cam_isp`). Buffers via `cam_smmu`, completion via `cam_sync`. GPL uAPI headers [M-static] |
| 4 | Timestamps and sync | SOF timestamps in one clock with the SyncBoss IMU (timesync/nsync) |
| 5 | Exposure and LED schedule | Interleaved SLAM and controller frames; the strobe duty follows exposure (safety, §8) |

### 2.3 SyncBoss kernel interface (summary of rev 1)

- **Nodes:** `/dev/syncboss0` (raw writes, **unfiltered**: `syncboss_write()`,
  `syncboss_spi_core.c:523`), `syncboss_stream0`, `syncboss_control0`,
  `syncboss_directchannel0`, `syncboss_powerstate0`. sysfs knobs: `syncboss_spi_sysfs.c:557-566`
  [M-static].
- **Kernel behaviour:**
  - opening the device powers and resets the MCU;
  - **type 90 (sleep) is sent on every stop of the last stream** (`:1610-1630`) [M-static].
- **Message map:**

  | Type | Meaning | Source |
  |---|---|---|
  | 80 | IMU | [M-static] |
  | 27 | nsync | [M-static] |
  | 85 | display | [M-static] |
  | 3 | SET_DATA, with sub-types 212 (prox config version) and 205 (prox calibration) | `syncboss_powerstate.c:150-175` [M-static] |
  | 203/204 | prox enable/disable | [M-static] |
  | 207 | prox state | [M-static] |
  | 244 | wake reason | [M-static] |
  | 110 | IMU enable | [C, Q1 = Q2] |
  | 133 | radio start | [C, Q1 = Q2] |
  | 143 | controller data | [C, Q1 = Q2] |
  | 47/46/44 + type-3 `a3`/`ef`/`64`/`e2`/`8f`/`a1` | Q2 camera and exposure commands | [C, QK2 `QUEST2_PORT.md:376-381`] |

- **Faulty prox on Units 1–2** (J-133) affects powerstate.

### 2.4 Meta's tracking stack (names; descriptive only, no provider)

- **Services** (Unit 1, v2.7 `getprop`) [M-static]: `trackingservice`, `trackingfidelityservice`,
  `calibration_svr`, `cam2_bridge`, `cameraserver`, `sensorproxy`, `vrdevice`, `vrfocus`,
  `xrservice`, `xrspd`; plus the `vision` partition.
- **Libraries** (v66) [M-static]: `libsyncboss.so`, `libcamerahal.so`, CAMX (`libcamx*`,
  `libxrcamerahal.so`), `libeva.so`, `libcdsprpc.so`, `libQnnHtpV69.so`.

### 2.5 Controller-related firmware on the Q3 image (never run, never pushed)

- `/odm/firmware`: `syncboss.bin`, `jedi_archive.bin`, `ruby_archive.bin`, `ruby_prq_archive.bin`,
  `santana_manager.bin` (SAFETYBOSS) [M-static names, v66].
- `/odm/bin`: `syncboss_app_updater`, `ovrfwupdatetest`, `update_blu_fw` [M-static names].
- The Q1 community decoded device types "4 Jedi, 6 Ruby" from Meta's library [C].
- **Which product each codename is, is [O].** It matters for ring Touch (§3).

### 2.6 How Horizon tracks, and what we can offload (PM question, J-162 item 8)

**Horizon's pipeline at the level of names and public facts [M-static names; C/D roles]:**

| Stage | Where | Evidence |
|---|---|---|
| IMU (about 1 kHz), camera sync, controller radio, prox | **SyncBoss MCU** (nRF52833); host side `libsyncboss.so` + kernel driver; timesync/nsync pulses | DT, GPL driver [M-static] |
| Camera capture and ISP | **Spectra**: CSIPHY/CSID/IFE (`cam_isp`), ICP firmware (`cam_icp`); userspace **CAMX** + Meta's XR camera HAL (`libxrcamerahal.so`, `liblokicamera.so`, `libmonocameracontrol.so`) | techpack + names [M-static] |
| Neural networks (hands, features, depth/scene) | **Hexagon CDSP with the HTP/NPU**, reached through **FastRPC** (`libcdsprpc.so`, `/vendor/lib/rfsa/adsp/*_skel.so`) and **QNN** (`libQnnHtpV69.so`, `libQnnBoltnnOpPackageV69.so`) | names [M-static]; Meta has said publicly that Insight uses the Snapdragon DSP [C] |
| Classic CV (optical flow, feature/descriptor kernels, warps) | **EVA/CVP** engine (`libeva.so`, `libevadsp_3_0.so`; kernel `techpack/eva`, GPL-2.0) | [M-static] |
| Fusion, mapping, relocalisation, orchestration, prediction | **CPU** (`trackingservice`, `trackingfidelityservice`) [D] | — |

**What our open stack could offload:**

| Engine | Interface | Legally clean? | Status |
|---|---|---|---|
| **CPU** (NEON) | — | yes | Baseline. The survey's estimate is **4.7–9.1 of 6 cores** for head + hands + controllers + SteamVR + game, unmeasured [D]. It is over budget at the upper end, so offload matters |
| **GPU (Vulkan compute, Adreno 740)** | Through our Turnip route (`gpu-route-decision.md`, (e′)) | **yes** (Mesa MIT) | **First choice:** image pyramids, undistortion, blob detection, NN inference (for example ncnn/Kompute-style Vulkan kernels). Shares the GPU with the compositor: budget [O] |
| **Hexagon CDSP scalar/HVX via FastRPC unsigned PD** | Meta's `adsprpc` supports unsigned PDs (`is_unsigned_pd`, `FASTRPC_MODE_UNSIGNED_MODULE`, `adsprpc.c:4130-4175`). The **CDSP channel is set non-secure with `unsigned_support = true`** (`adsprpc.c:3311-3312`); other domains are signed-only when unsigned support is on (`:4160`). The DT has `qcom,msm-fastrpc-compute` with compute context banks (`anorak.dtsi:2321-2361`) [M-static]. Toolchain: upstream LLVM Hexagon backend [C]; host library: quic/fastrpc (BSD-3) [C] or our own from the GPL downstream uAPI | Possibly | **An early checkpoint, C-DSP (§6.4)**. Open: whether Q3's Meta-signed CDSP firmware accepts unsigned PDs at runtime; whether quic/fastrpc speaks this downstream driver; whether the DSP-side headers (QuRT, HAP, remote IDL from the Hexagon SDK) can be used under the SDK's licence terms [O]. The QuRT runtime lives in the firmware: we call it, we don't ship it |
| **HTP/NPU** | QNN only | **No** (proprietary Qualcomm libraries): marked **not legally clean** | Excluded (D-T15) |
| **EVA/CVP** | GPL kernel driver, but proprietary userspace and firmware command formats | [O], probably not clean | Excluded until a documented open interface exists |

---

## 3. Ring Touch on the Quest 3 (PM requirement, J-162 item 2)

**Goal:** ring Touch (Quest 1/Rift S generation and Quest 2 generation) paired, read and tracked
on a Quest 3 by **our own** code.
- Community members reportedly made ring Touch pair by **porting Meta binaries**.
  That is a pointer only. We never port Meta binaries and never disassemble. Every fact must be
  confirmed from GPL source or our own observation (D-T10).

| Layer | What is known | What we need | Route |
|---|---|---|---|
| **Radio** | Q3 and Q2 both use a SyncBoss nRF52 (52833 vs 52832) with the same kernel driver [M-static]. The controller radio protocol is proprietary 2.4 GHz [C]; the controller-side SoC is nRF528xx [C, iFixit] | Whether the **Q3 MCU firmware** can talk to ring Touch at all | The Q3 image carries **`jedi_archive.bin` and `ruby_archive.bin`** [M-static]. If one codename is a ring Touch [O], the Q3 firmware stack knows that controller, and the barrier is userspace policy. If not, Q3 firmware may lack the radio profile, and **we never flash MCU firmware** (H7): **stop** |
| **Pairing** | The pairing list is on the MCU, ≤6 entries [C]. Pairing is a library call; Q1 mentions legacy and ECDH pairing paths [C] | The pairing command sequence, and **whether it needs key material that only Meta software holds** | Observe pairing on **our own Q2 under Horizon** at the SyncBoss transaction level (D-T8 rules: kernel-side observation, understood parameters only). Re-express it and replay it on Q3 through the allow-list. **If a secret key is needed, stop and report:** extracting it would mean disassembly. **Checkpoint C-R** |
| **Input reports** | Packet 143: `[type:5, len:7]` chunks (buttons, trigger/grip, stick, motion, capsense) [C, Q1 = Q2] | The ring-Touch layout as received on Q3, and the controller IMU scale and axes | Our own decoder from observation on our devices |
| **LED model** | The Rift S controller (= Q1 Touch generation) **reports its own LED model** over the radio (thaytan `rift_s_controller.c`) [M-static, survey §2.2]. Q2 community: Rift S-style TrackedObject JSON with 15 LEDs, stored on the Q2 data partition [C] | LED positions, normals and blink/ID scheme per generation | Read from the controller if it exposes it (as Rift S does). Otherwise measure our own with a photogrammetry rig. **Never from Meta software** |
| **Tracking** | Monado mainline constellation (BSL, 2026) + thaytan's inside-out Rift S glue: "works, not very good yet" [C] | LED sync with SLAM exposures; a controller IMU filter | Our work upstreamed to Monado (survey §2.3) |

- **Legal note [D, not legal advice]:**
  - Re-implementing a protocol observed on hardware we own, for interoperability, is the
    cleanest available position.
  - Circumventing a cryptographic pairing check could raise DMCA §1201/EU-interoperability
    questions. That goes to the lawyer list if C-R finds crypto.
- **Effort:**

  | Part | Agent pw | Hardware sessions |
  |---|---|---|
  | Pairing/protocol | 8–20 | 6–14 (Q2 observation + Q3 trials) |
  | LED models | 3–6 | 2–4 |
  | Tracking | 15–30 | 12–25 |
  | **Total** | **26–56** | **20–43** |

  Pairing **may be blocked** (crypto or firmware) [O].

---

## 4. Steam Frame controllers (PM idea, J-162 item 3)

- **"Use Valve's tracker natively, translating the camera locations":** this needs XRService to
  accept Quest cameras and IMU. That means a supported external-capture interface, Quest
  calibration in its format, and running without Valve's SM8650 DSP images.
  - Only Valve can provide that. **Held-letter question** (D-T14).
  - Also ask about the radio: Frame controllers talk to the Frame's own nRF "roy" dongle
    (`steamvr-program-ble`, `roy_dongle_fw.hex`) [M-static]. A Quest has no such radio [D], so a
    USB dongle or Valve guidance is needed [O].
- **Fallback (our own tracker):**
  - SteamVR's own resources hold nominal per-revision models (`modelPoints[18]`,
    `modelNormals[18]`) [M-static structure]. These are Valve's files: reading them at runtime from
    the user's install is a licence question [O]. Per-unit calibration, blink/ID scheme, exposure
    sync and the radio protocol are [O].
  - **Deferred** until Valve answers.

---

## 5. Open-source pieces we build on (from the survey, with our own forks)

### 5.1 Head: our own Basalt fork + open map/relocalisation layer (J-162 item 4)

- **Is Valve's derivative open? No.** BSD-3 and MIT require attribution only; Valve may keep its
  changes closed, and does [M-static notice; D].
- **Our plan:** an **own improved Basalt fork** (from mateosss, BSD-3, built with
  `BASALT_BUILD_SHARED_LIBRARY_ONLY`), via VIT. It adds:
  - Quest camera models (Fisheye62/`fisheye624`);
  - multi-camera tuning;
  - an ARM/NEON and GPU front end;
  - an **open map, relocalisation and persistence layer**. Basalt is odometry only. Candidates:
    Basalt `nfr_mapper`, maplab (Apache-2.0), a place-recognition vocabulary we train ourselves
    (mind DBoW2's notification clause) [survey §8].
- **Fork work items from the community review** (rev 2.3, `quest-ports-tracking.md` §4):
  1. **Fix the multi-camera epipolar bug** [M-static]:
     - where: `include/basalt/optical_flow/optical_flow.h:210` at `df6e970`;
     - what: the essential matrix for every camera `i` is built from `T_i_c[0]⁻¹·T_i_c[1]`, so
       each camera uses the camera 0/1 geometry;
     - fix: use `T_i_c[i]` (cstahly patch `0006`).
     It matters for every Quest with more than 2 tracking cameras. Its effect on accuracy is [C].
     We write the fix ourselves and credit cstahly.
  2. Take cstahly's two accepted **BSD-3** Basalt patches:
     - `0001`: VIT null end-of-stream pose;
     - `0005`: skip fully masked detection cells.
     Not `0002`, `0004` or `0007`: their author rejected them.
- **OKVIS2** (BSD-3, `USE_NN=OFF`) is the accuracy reference.
- **D6 audit:** `thirdparty/apriltag/ethz_apriltag2` lineage [O].
- Target: the D-T11 bar (§7.3). The upstream contribution policy is a PM call (D-T13).

### 5.2 Controllers

Monado mainline constellation tracker (BSL-1.0, generic, moving-origin camera mosaic,
2026) + thaytan's inside-out glue (BSL/dual). No open project publishes inside-out controller
accuracy. Polished controllers are **new work** [survey §0].

### 5.3 Hands: one model for every Quest (J-162 item 5)

- **Do not ship Mercury's current models.** They have no licence file, and their training data
  includes FreiHAND and EPIC-KITCHENS (non-commercial) and CMU Panoptic (research-only)
  [C, survey §3.1].
- **Plan:**
  - Our own model trained with `mercury_train` (BSL) and/or MMPose (Apache-2.0).
  - Mercury's runtime (BSL; stereographic reprojection; 4-thread pool) as the base.
  - **Camera-agnostic by design:** train on normalised (stereographic or undistorted) crops with
    randomised intrinsics, FOV, noise and IR appearance. Per-device calibration maps each Quest's
    cameras (Q1/Q2 OV7251, Q3 OG/OV7251, QPro/Q3S [O]) into that space.
- **Data:**
  - synthetic hands (asset licences audited);
  - **our own consented captures** on each Quest: written consent, purpose limitation, no faces
    or bystanders kept, local encrypted storage, retention limit, deletion on request, a GDPR-grade
    notice [D];
  - any public set only after licence verification.
- **MediaPipe** (Apache-2.0 code and model card) is the legal prototype.
- Ask Collabora about Mercury's models (issue #1 open).
- **Effort:** 25–50 agent pw; 15–30 hardware sessions, including about 20–40 h of capture across
  devices.

### 5.4 Quest-port prior art and reusable items (rev 2.3, J-170)

**Corrected prior art [C]:** **no validated native 6DoF head-and-controller implementation was found in the inspected public sources** (FS-R-013 §12 wording; a research result, not proof that none exists).
- **cstahly/quest1-bootloader-to-VR** (Quest 1, Nura; MIT, with patches keeping their upstream
  licences) ran **live Basalt 6DoF** in wearer trials:
  - Basalt in a separate process, fed to Monado through an opt-in pose mailbox;
  - wearers walked "in full light";
  - the owner **rejected** it: frequent lock loss, about 90–108 ms pose age, stutter, low-light
    failure;
  - never the default; the installed scene stays 3DoF.
- **3DoF works on several ports, head and Touch, all via the SyncBoss IMU:**
  - Quest1-SteamOS (no licence);
  - Block-Flock (no licence; Monado fork BSL);
  - quest-kexec-q2 (GPL-2.0; Monado driver BSL-1.0).
- **YusufOzmen01/quest-kexec's "6DoF"** is **Meta's own `trackingservice` in a second, kexec'd
  Android** (Quest Pro). It is not an open tracker and not a precedent (no Meta provider).
- Details: `quest-ports-tracking.md` §1–§2.

**Reusable, with licences** (reimplemented or adapted in our code, with credit):

| Item | Source | Licence | Use |
|---|---|---|---|
| Basalt epipolar fix and patches `0001`, `0005` | cstahly `patches/basalt/` | BSD-3 | Our fork (§5.1) |
| Diagnostic scripts:<br>• `summarize-trajectory.py`<br>• `imu-propagation-consistency.py`<br>• `audit-visual-gyro-so3.py`<br>• `audit-capture-timing.py`<br>• `check-camera-correspondences.py`<br>• `analyze-prediction.py` | cstahly `tools/tracking/` | MIT | Self-consistency checks (§7.3, method 4) |
| Pose-adapter design:<br>• separate tracker process;<br>• bounded queue (skip images, never IMU);<br>• versioned pose mailbox;<br>• hold on short loss, quiet re-anchor on long loss;<br>• "start here" recentre | cstahly `patches/monado/runtime-src/monterey_vio*.h` (BSL-1.0 patch), `live-vit.cpp` (MIT) | BSL-1.0 / MIT | `fs-trackd` design (§6.3) |
| Quality-gate design:<br>• per-camera feature support;<br>• freshness ≤ 150 ms;<br>• continuity and jump checks | cstahly `tools/tracking/vio-quality.h` | MIT | `fs-trackd` gating |
| Quest SyncBoss HMD + Touch Monado driver structure | quest-kexec-q2 `monado/drivers/quest2/` | BSL-1.0 | Driver and builder structure; Touch IMU axes and scale |
| Horizon pose-streaming app | KirvilNET/QuestSLAM | MIT | Reference for our own Horizon pose logger (§7.3, method 2) |

**Not reusable:**
- camera paths through Meta's HAL, libsyncboss or Frida (D-T10);
- repos with no licence (pointers only);
- Meta's trackingservice.

---

## 6. Recommendation: one architecture, two layers

### 6.1 What runs where

```
 Valve, unchanged ─────────────────────────────────────────────────────────────
  SteamOS rootfs · vrserver · vrcompositor · SteamVR input; driver_cv dormant
 Layer 2: pose API (our code) ──────────────────────────────────────────────────
  driver_frameshift.so  (OpenVR provider; Apache-2.0; registered with vrpathreg)
     HMD (display geometry, J-128) · controllers type oculus_touch, OUR input profile
     · haptics (bounded) · skeletal input
  pose API: per device {pose, timestamp, covariance, tracking state}, shared memory
 Providers (exactly one sensor owner at a time) ─────────────────────────────────
  P-open (default, only one planned): fs-trackd = SyncBoss client (IMU, controllers,
     ring-Touch pairing) + camera client + our Basalt fork + map/reloc layer
     + Monado constellation + our hand model          [our code + open source]
  P-valve (gated): only if Valve offers an interface (held letter)
  future providers: same API and same Layer-1 rules  (no Meta provider: J-162)
 Layer 1: sensor ownership and safety (kernel, minimal GPL hooks) ───────────────
  SyncBoss filter: (type, sub-type, parameter bounds) allow-list on syncboss0 writes,
     sysfs knobs locked, swd firmware path denied/removed; exposure/duty bounds; watchdog
  ownership arbitration: one owner of SyncBoss and the cameras
 Meta, unchanged ───────────────────────────────────────────────────────────────
  GPL modules as shipped + our small hook patches; MCU firmware already on the device
 Compute: CPU + GPU (Vulkan via our Turnip route); CDSP unsigned PD only if open [O];
          no QNN/NPU, no EVA userspace
```

### 6.2 Order: the controllers each user already owns come first (PM, J-165)

**PM (J-165):** "Most likely, users will own the Quest 3 and controllers, or a Quest 2 and
controllers, and will be installing FrameShift to that device alone."

**Quest 3:**
1. 3DoF head.
2. 6DoF head.
3. **Touch Plus, the bundled controllers:** inputs, 3DoF and haptics first. The pairing made under
   Horizon is reused (D-T5).
4. **Touch Plus 6DoF**, first from LEDs and IMU.
5. **Hands** (the one-model plan). Hand-prior fusion then completes Touch Plus 6DoF in occluded
   poses.
6. **Ring Touch on Q3** (cross-compatibility): our own pairing (C-R), inputs, 6DoF.
7. Frame controllers and other controllers later (Touch Pro, MX Ink, Valve's answer).

**Quest 2 port:** its **bundled ring Touch comes right after head tracking**:
1. 3DoF head.
2. 6DoF head.
3. Ring Touch inputs, then 6DoF, reusing the Horizon pairing. The ring constellation engine is
   built here.
4. Hands.
5. Others.

**Quest 1, Quest Pro and Quest 3S** follow the same rule: bundled controllers first.

### 6.3 A dedicated tracking process (PM, J-164: "offload the tracking to a dedicated process for efficiency")

`fs-trackd` is a **dedicated, isolated systemd service**, separate from vrserver, Steam and games.
All of the settings below come from our own unit files and drop-ins; no Valve file is edited.

**1. CPU isolation**
- A `fs-tracking.slice` with `AllowedCPUs=` set to **2 reserved cores**. 3 is an option (see the
  budget below).
- Drop-ins give `user.slice` (Steam, games) and vrserver `AllowedCPUs=` on the remaining cores.
- IRQ affinity puts the SyncBoss SPI IRQ and the camera IRQs on the tracking cores.
- Which cores (performance or efficiency cluster) is fixed by measurement [O].

**2. Real-time priorities**

Valve's analogue is `steamvr-set-kernel-thread-priorities.service`, which runs
`set_kernel_thread_priorities.sh` (names only) [M-static]. That script raises named kernel threads
with `chrt -r` and pins them with `taskset`: the nRF SPI thread, `gpu-worker`, `ring0/1`,
`card0-crtc`, `crtc_event`, `atomic-worker-*`, UFS IRQs, `iris`, `soundwire`.

Our order, highest first:

| Thread | Policy and priority | Reason |
|---|---|---|
| SyncBoss SPI kthread | Meta's own default, `SYNCBOSS_DEFAULT_THREAD_PRIO 51` | `syncboss_spi.h` [M-static] |
| Our IMU reader | `SCHED_FIFO` 50 | |
| Fusion/prediction | `SCHED_FIFO` 45 | |
| Camera-capture threads | `SCHED_RR` 30 | |
| VIO, constellation and hand workers | `SCHED_OTHER` with nice −5 to 0 | |

- **Bounds:**
  - RT threads stay below the display/GPU kernel threads and the thermal supervisor;
  - the global `sched_rt_runtime_us` limit is kept;
  - a **per-thread RT budget watchdog** demotes any RT thread above its CPU share over a window
    to `SCHED_OTHER`, logs it, and alerts fs-thermald.

**3. Fixed thread budgets [D]**

| Work | Threads | Notes |
|---|---|---|
| VIO | 2 (front-end optical flow + back-end) | |
| Constellation | 1 | |
| Hands | 2 | Mercury's 4-thread pool reduced and pinned |
| IMU, fusion, capture, IPC | 3–4 light threads | |

No thread pools grow at runtime.

**4. Memory**
- `mlockall(MCL_CURRENT|MCL_FUTURE)` after start-up.
- Preallocated frame and buffer pools.
- cgroup `memory.min` and `memory.max` on the slice.
- No allocation on the hot path.

**5. IPC to the OpenVR driver**
- A **lock-free single-writer shared-memory block** (memfd): per device, a seqlock- or
  triple-buffered record {pose, velocity, timestamp, covariance, state} plus the latest IMU state
  for prediction.
- A heartbeat counter. If it goes stale beyond N ms, the driver marks devices not tracking: 3DoF
  and fade for the HMD.
- No syscalls on the driver's pose path.

**6. Supervision by fs-thermald**
- systemd `WatchdogSec` plus the heartbeat.
- **The degradation order under thermal throttling is fixed:**
  1. lower the hand-tracking rate, then turn hands off while controllers are held;
  2. lower the controller-frame and constellation rate, with IMU fill between fixes;
  3. lower VIO cost (features, keyframes) down to a **head floor**: VIO never below about 15–20 Hz
     [D, to be measured], **IMU at 1 kHz always**;
  4. hand over to SteamVR/game-side reductions;
  5. orderly session stop.
- **Head tracking is never degraded below its safe floor; below it the session stops.** The
  shutdown rules of §6A are unchanged.

**CPU budget with this split** (survey §7.2 loads [D, unmeasured]; 6 cores at the sustained
1.92 GHz):

| Load | Cores | Where |
|---|---|---|
| VIO, 4 cameras at 30 Hz | 1.1–1.8 | tracking cores |
| IMU, fusion, capture, IPC | 0.1–0.3 | tracking cores |
| Constellation | 0.5–1.0 | tracking cores |
| Hands, stereo at 30 Hz | 1.0–2.0 | tracking cores |
| **Tracking subtotal** | **2.7–5.1** | **2 dedicated cores** |
| vrserver + vrcompositor | 0.5–1.0 | game cores |
| The game | 1.5–3.0 | game cores |
| **Game-side subtotal** | **2.0–4.0** | **4 game cores** |

- **What fits without the DSP [D]:**
  - **On 2 cores:**
    - head VIO plus IMU (1.2–2.1) fits, with controllers at a reduced rate when VIO runs high;
    - **hands do not fit at the same time.**
    - Hands need one of: GPU offload; DSP offload; mode switching (hands only when controllers are
      put down, as Horizon's auto-switch does [C]); or a third tracking core.
  - **On 3 cores:** head + controllers + hands at reduced rates (2.7–3.5) fits. The game side
    then gets 3 cores (2.0–4.0): tight at the upper end.
  - **Recommendation:** 2 cores plus mode switching first; GPU offload for hands and image
    front-ends after the GPU route works; the DSP if C-DSP passes.
  - **Measure on ARM replay (T0) before fixing any of this.**

### 6.4 Hardware offload: the DSP as an early checkpoint (C-DSP, before T2b)

**What the GPL source shows** [M-static]:
- Meta's v2.7 `adsprpc` driver has four channels (ADSP, MDSP, SLPI, CDSP).
- The **CDSP is non-secure with unsigned-PD support enabled** (`adsprpc.c:3311-3312`).
- Unsigned modules are requested with `FASTRPC_MODE_UNSIGNED_MODULE`.
- Signed offload to the other DSPs is restricted (`:4130-4175`).
- The DT declares the fastrpc compute node and context banks (`anorak.dtsi:2321-2361`).

**Questions for C-DSP:**
1. **Host side:** can an open host library (quic/fastrpc, BSD-3 [C], or our own from the GPL
   downstream uAPI) open `/dev/adsprpc-smd` on our image?
2. **DSP side:** can an unsigned skel be built with **open tools**? The LLVM Hexagon backend is
   upstream [C]. HVX intrinsics are in clang [C]. The QuRT/HAP/remote headers come from the
   Hexagon SDK, whose **licence terms are [O]**.
   - If the SDK terms forbid our use or redistribution of built skels, the route needs our own
     clean headers (risky) or stops.
3. **Firmware:** does the Q3's Meta-signed CDSP image, booted unchanged from the device's own
   firmware, accept an unsigned PD at runtime? Answering this needs **a state-changing trial**:
   it boots the CDSP and loads a trivial skel. That is a PM sign-off, plus the Chair for the
   first run.
4. **Value:** does a feature/optical-flow kernel on HVX beat CPU NEON by enough? Measure.

**Order:**
1. C-DSP runs in parallel with T2a, before T2b. It is offline first: licence read, host-library
   check, toolchain build. Then one trial.
2. **GPU (Vulkan compute)** is the second offload target, once the GPU route is working.
3. **The NPU (QNN) and EVA stay excluded** (D-T15).

---

## 7. Staged path, effort, targets

### 7.1 Stages and checkpoints

| Stage | Content | Checkpoint |
|---|---|---|
| T0 (offline) | Pose API, driver, `fs-trackd`; kernel filter + firmware-path removal; Basalt fork set-up; ARM replay CPU measurement; calibration converter; validation kit design (fixtures, cradle, printed boards, metric scripts; D-T16) | Chair review of the filter |
| T1 (state-changing trial) | 3DoF head (MCU power/reset, 110, packet 80, kernel 90 on stop) | **C0:** IMU at about 1 kHz, clean stop |
| T2a | Camera feasibility: SyncBoss → CCI/DT → other | **C1:** go/no-go for optics |
| T2d (parallel with T2a) | DSP feasibility (§6.4): licence read, host library, open toolchain, one unsigned-PD trial | **C-DSP:** offload plan fixed before T2b |
| T2b | 6DoF head: our Basalt fork + map/reloc, 3DoF fallback, chaperone | **C2:** head D-T11 vs Horizon |
| T3a | Touch Plus inputs, 3DoF, bounded haptics | **C3:** inputs complete |
| T3b | Touch Plus 6DoF (LEDs + IMU) | **C4p-1:** in-view Touch Plus against D-T11 |
| T4 | Hands: camera-agnostic model, data collection, skeletal input; then hand-prior fusion for Touch Plus | **C5:** licence-clean model, accuracy on all target Quests; **C4p:** Touch Plus D-T11 including occlusion, or stop |
| T5 | Ring Touch on Q3 (cross-compatibility): pairing → inputs → LED models → 6DoF | **C-R** (pairing feasible, no crypto wall) → **C4r** (ring D-T11) |

### 7.2 Effort in two currencies [D estimates]

| Stage | Agent pw | Hardware sessions (HS) | Other |
|---|---|---|---|
| T0 | 8–15 | 0–2 | Validation kit: cradle, tape, printed grid and boards (D-T16; tens of euros) |
| T1 | 3–6 | 2–4 | — |
| T2a | 6–15 | 4–10 | — |
| T2d (DSP) | 3–6 | 1–3 | SDK licence review |
| T2b (Basalt fork + map/reloc) | 20–45 | 15–35 | Validation runs under both OSes (§7.3) |
| T3a | 6–12 | 3–6 | — |
| T3b + T4 fusion: Touch Plus 6DoF | 40–90 | 30–70 | May not converge |
| T4 hands | 25–50 | 15–30 | 20–40 h of consented capture |
| T5 ring Touch on Q3 | 26–56 | 20–43 | Needs ring Touch + an own Q2 for observation |
| **Sum** | **137–295** | **90–203** | |

- **Contingency is not included.** Add about 25 %, mostly in T2a, T3b and T5.
- To 6DoF head (T0–T2b, including T2d): **40–87 agent pw, 22–54 HS.**
- **Polish is bounded by HS, not pw** [D]. Each tuning loop needs the PM, a unit and
  the §7.3 fixtures. Practical pace is perhaps 2–4 HS per week. So the full set is roughly **1–2 years
  of hardware calendar**, even with agents compressing the coding [D].

### 7.3 Pass mark: Horizon parity (D-T11, revised by J-163 and J-170)

**PM (J-163):** "Take our own model, copy Meta's limits/boundaries, and apply it to our own, so we
effectively have our own model with the same measurements."

- **PASS (PM, J-170):** **match Horizon, measured black-box on the same unit**, on every axis:
  - accuracy;
  - jitter;
  - drift;
  - latency (motion-to-pose);
  - reacquisition time;
  - tracking volume and range (distance and angles from the headset);
  - occlusion behaviour (controller behind the body, hands over controllers, face-away poses).
- **Goals (PM, J-170):** the fixed numbers below are **goals to beat, not pass conditions**.
  They are revisited once Horizon is measured. Where Horizon measures better, Horizon's number
  is the bar.
  - Context [C]: Duke (MobiCom 2024, DOI 10.1145/3636534.3696215) found Quest 3 Horizon errors
    of about 1 cm typically and above 10 cm in hard scenes.
  - So some goals (for example 1 cm per 5 min) may be stricter than Horizon itself.
- **Method (black-box, no Meta code or data inside our product):**
  1. **Same unit:** each comparison runs Horizon and FrameShift on the same headset and the same
     controllers, in the same room and lighting.
  2. **Same scripted motions:** a fixed motion script, repeated under both OSes:
     - static holds;
     - slow and fast sweeps up to 2 m/s;
     - loops in a 3×3 m room;
     - occlusion poses;
     - out-of-view throws;
     - darkness and low-texture segments.
  3. **Reference without external tracking hardware (D-T16, J-170):**
     - PM ruling: **no Lighthouse or mocap**.
     - Horizon and FrameShift cannot run at once on one unit, so trajectories are **never
       subtracted from each other**. Both are measured against the **same physical references**.
     - Alignment is SE(3) only, never scale. Report N ≥ 10 repetitions with confidence intervals.
     - Ranked methods (detail: `quest-ports-tracking.md` §5):
       1. **Fixture stations and a cradle:**
          - setup: a rigid headset cradle, controller cradles, and stations marked on the table
            and floor, measured with a steel tape and a printed grid (about 1 mm);
          - measures: absolute scale (estimated vs taped distances), return-to-station error,
            static jitter (60 s holds, RMS after detrend, plus Allan deviation), loop drift
            (re-seat in the cradle after a scripted loop), and controller-to-head relative pose
            error.
       2. **Horizon pose logs:** HMD and controller poses with tracked flags, recorded during
          the method 1 scripts, through either:
          - (a) the **Quest Link** setting, with an OpenXR logger on a PC (Link poses are
            predicted, so not for latency); or
          - (b) **our own minimal on-headset logging app**, modelled on KirvilNET/QuestSLAM
            (MIT).
          Each is a **device change needing PM approval** when the time comes.
       3. **Printed AprilTag/ArUco boards** seen by **our own** tracking cameras, with PnP
          independent of the VIO:
          - measures: segment drift, scale from tag size, relocalisation jumps;
          - limit: it shares our calibration;
          - library: AprilTag3 BSD-2 or OpenCV ArUco Apache-2.0 (D6 audit applies).
       4. **Self-consistency on every recording:**
          - IMU propagation vs VIO;
          - visual vs gyro rotation;
          - epipolar and reprojection residuals;
          - camera-subset agreement;
          - Basalt vs OKVIS2;
          - replay determinism.
          Adapted from cstahly's MIT scripts (§5.4). This method is blind to common-mode errors.
       5. **Protractor yaw steps:** 90° steps and a 360° return on the cradle; tilt wedges. This
          gives orientation accuracy and yaw drift, including at the 3DoF stage.
       6. **Optional:** a slow-motion phone video (240 fps) for motion-to-photon latency under
          both OSes. Our internal IMU-to-pose age is logged anyway. Whether to use a phone is a PM
          call.
  4. **Horizon recordings are made by the PM under Horizon**, using method 2 above. The tool must
     stay public-scope clean.
  5. **Metrics:** jitter, scale, return and loop error, ATE/RTE on fixture segments, latency,
     reacquisition and volume. They are computed by our own scripts against the method 1–3
     references, giving the same report for both OSes.
  6. **External optical checks:** IR strobe duty and frame timing are measured with a photodiode
     and oscilloscope near the emitters [D]. No software inside Horizon is touched.
- **The measurements are facts about behaviour.** Our own models and filters are tuned until
  they meet them. No Meta weights, code or configuration enter the product.

**Goals [D proposals; goals to beat, not pass conditions (J-170)]:**

- **Head:**
  - jitter ≤ 0.2 mm / 0.02° RMS;
  - loop drift ≤ 1 cm over 5 min in 3×3 m;
  - relocalisation < 1 s;
  - IMU-to-pose ≤ 2 ms;
  - < 1 loss per 10 min.
- **Controllers:**
  - jitter ≤ 0.5 mm / 0.1°;
  - ≤ 5 mm RMS up to 2 m/s;
  - ≤ 3 cm after 300 ms IMU-only;
  - reacquire ≤ 100 ms (ring) / ≤ 250 ms (Touch Plus);
  - no jumps > 2 cm;
  - ≥ 95 % tracked.

The survey's honest prior (§7.1): IMU-to-pose likely; relocalisation needs the map layer;
controllers have no open evidence yet. The only live open 6DoF attempt on a Quest (cstahly,
Quest 1) was rejected for lock loss and lag (§5.4).

### 7.4 Risks

| Risk | Description |
|---|---|
| R1 | TZ/sensorlock camera gate; sensor programming outside the kernel |
| R2 | Sequences learnable only from Meta's HAL (D-T8) |
| R3 | CPU budget 4.7–9.1/6 cores; offload limited to GPU (+ CDSP [O]) |
| R4 | Touch Plus may not converge |
| R5 | Clean hand data and models |
| R6 | MCU state; faulty prox on Units 1–2 |
| R7 | Community RE provenance |
| R8 | IR exposure safety |
| R9 | **Ring Touch pairing blocked by crypto or Q3 firmware (C-R)** |
| R10 | Valve does not answer (Frame controllers, P-valve) |

---

## 8. Safety items (H1, H3, H5, H7)

### 8.0 Meta's limits and operating points, adopted as values (J-163; J-123 allows thresholds and identifiers)

- We copy **numbers** from Meta's GPL kernel source and DT and enforce them in our Layer 1.
- We never copy weights, code or the contents of proprietary configuration files.
- Values that the GPL source does not contain are **measured black-box** (§7.3 item 6) and
  adopted as bounds.

| Quantity | Value | Source |
|---|---|---|
| IR flood LED current cap (`pmxr2230_torch2/3`) | **140 mA**, hardware strobe from PMIC GPIO 1, `default-on` trigger | `anorak-oculus-flood-led.dtsi` [M-static] |
| Flash channels | Deleted on Quest 3 (`/delete-node/ pmxr2230_flash0-3`). The SoC defaults are 1500 mA and 1280 ms and must **never** be re-enabled | `anorak-oculus-flood-led.dtsi`, `pmxr2230.dtsi:107-150` [M-static] |
| Flash thermal derating | `qcom,thermal-derate-current = <200 500>` | `pmxr2230.dtsi:116` [M-static] |
| PMIC flash safety timer | Max 1280 ms, min 10 ms, default 200 ms | `leds-qti-flash.c:47-50` [M-static] |
| IR strobe duty and pulse width | Not in GPL source. Set by camera exposure and SyncBoss scheduling | **Measure** under Horizon (photodiode); adopt the maximum observed as the hard bound [O] |
| Camera frame rates and exposure ranges (SLAM and controller frames) | Not in GPL source | **Measure** (frame timing, photodiode). Q1 at 2×30 Hz and Q2 at about 50 Hz are community claims [C] |
| IMU rate | About 1 kHz [C, Q1 and Q2 community]. No constant in the GPL driver | **Measure** under our T1 trial; compare with Horizon's documented sensor rates [O] |
| SyncBoss bus | SPI 8 MHz max; min 150 µs between transactions (DT); default 500 µs | `anorak-oculus-syncboss.dtsi`, `syncboss_spi.h` [M-static] |
| Time base | QTimer 19.2 MHz | `cam-fsync.c:41` [M-static] |
| Thermal limits | Meta's own zones, read at runtime from the user's device (PM decision J-118) | `PROJECT_SETUP.md` §6A |

1. **Kernel SyncBoss filter** in `syncboss_write()`:
   - the allow-list is keyed by (type, sub-type, parameter bounds): v1 = {110 [0], 133 [0]};
   - camera, exposure and **pairing** commands are added only after confirmation on our own
     devices, each with bounds and PM approval;
   - kernel-owned messages are denied: 90, 203, 204, type 3 with 205/212;
   - everything else is rejected and logged;
   - tuning knobs are locked.
2. **Firmware path:**
   - deny `update_firmware` (`swd_driver.c:272`) and remove `meta,fw-path`/`meta,swd-provisioning`
     from our DT;
   - never run Meta updaters or push controller archives;
   - ring-Touch work **never** involves MCU or controller firmware changes.
3. **IR (H1):**
   - flood LEDs at the 140 mA DT cap with hardware strobe; current, mode and trigger never
     written;
   - exposure, period and strobe bounded per parameter to the Horizon envelope on the same unit;
   - watchdog;
   - an IEC 62471 check [O];
   - never enable `nautilus` or touch SAFETYBOSS;
   - the controller LED duty during our pairing and tracking stays within observed Horizon
     values [D].
4. **`/persist`:** never mounted from SteamOS.
5. **Haptics** capped.
6. **Playspace (D-T17):**
   - **SteamVR's native Chaperone**, as on pure SteamOS: no Meta code and no Guardian.
   - Guardian's safety *behaviour* is matched by measurement where safety depends on it. On the
     same unit and with the same scripted approaches:
     - the boundary warning distance;
     - the warning onset time;
     - fade-to-passthrough or fade-to-grid timing;
     - behaviour on tracking loss near the boundary.
   - These are set through Chaperone's documented settings. Any gap goes into our driver or the
     overlay, never into Valve files.
   - On tracking loss: 3DoF plus fade.
7. **Thermal:** tracking yields to the §6A supervisor.
8. **Privacy:** camera data never leaves the device except consented data-collection sessions
   (§5.3).

---

## 9. PM decisions (recommendation in bold)

| ID | Decision | Recommendation |
|---|---|---|
| D-T1 | Architecture | **Decided (J-162):** two layers. P-open the default and only plan; P-valve only via Valve; **no Meta provider** |
| D-T2 | Order (revised, J-165) | **Bundled controllers first. Q3: 3DoF → 6DoF head → Touch Plus (inputs, then 6DoF) → hands → ring Touch on Q3 → Frame/other controllers later. Q2 port: head → its bundled ring Touch right after → hands → others** |
| D-T3 | Calibration source (**decided, PM 2026-10-15, J-183**) | **The product reads each user's own headset's tracking calibration (camera intrinsics/extrinsics, IMU bias and noise, time offset; plus proximity and IPD, see `device-health-design.md` fs-calread) from `/persist`: read-only, at runtime, values stay on the device, never logged or exported, `/persist` never modified or remounted; converted to Basalt's format by our converter. Needs its own Chair-reviewed package. Self-calibration is the fallback for a missing or invalid file. The format is worked out only from the PM's own offline backups (read-only); no development reads on the headsets. No reverse engineering of Meta's tracking software (J-183)** |
| D-T4 | SyncBoss safety | **The kernel filter of §8.1–8.2; each new command (camera, pairing) is a PM approval** |
| D-T5 | Pairing (revised, J-165) | **Bundled controllers (Touch Plus on Q3, ring Touch on Q2): reuse the pairing made under Horizon, which fits the owned-controllers priority. Then our own pairing for cross-compatibility (ring Touch on Q3), from observation on our own Q2; stop at C-R if crypto keys or Q3 firmware block it** |
| D-T6 | Hands (and every NN we ship) | **Trained from scratch by us on clean data (own consented + licensed/synthetic): one camera-agnostic hand model (`mercury_train`/MMPose); MediaPipe as prototype only; Mercury's current models not shipped (J-163)** |
| D-T7 | T1 | **A state-changing trial with PM sign-off** |
| D-T8 | Observation on stock Android/Horizon (Q3 cameras, Q2 pairing) | **A Chair class, own devices; re-express understood parameters only; never re-emit opaque blobs** |
| D-T9 | C1 camera plan | **SyncBoss → CCI/DT (mainline `ov7251.c`/`og01a1b.c`) → other** |
| D-T10 | Community work (Q1 RE notes, FXR ring-Touch port) | **Pointers only; never port Meta binaries** |
| D-T11 | Pass mark (**decided, J-170**) | **PASS = match Horizon, measured black-box on the same unit** (accuracy, jitter, drift, latency, reacquisition, volume and range, occlusion). **The §7.3 numbers are goals to beat**, revisited once Horizon is measured. Duke 2024 context [C]: Horizon about 1 cm typical, above 10 cm in hard scenes. Meta's safety limits and operating points are adopted as values (§8.0) |
| D-T12 | Touch Pro, MX Ink | **Defer** |
| D-T13 | Head engine | **Our own Basalt fork + open map/relocalisation layer; OKVIS2 reference; upstream where possible** |
| D-T14 | Valve letter | **Add: (1) an external-capture interface for XRService, so Frame controllers and P-valve are possible on Quests; (2) Frame-controller radio and models; (3) Basalt-derivative contributions** |
| D-T15 | Offload (revised, J-164) | **CDSP via FastRPC unsigned PD is an EARLY checkpoint (C-DSP, parallel with T2a, before T2b): open host library + LLVM Hexagon, SDK licence [O], one PM-signed trial. GPU (Vulkan, our Turnip route) is the second target once the GPU route works. No QNN/NPU (not clean), no EVA userspace** |
| D-T16 | Reference for D-T11 (**decided, J-170**: no Lighthouse or mocap) | **Validation without external tracking hardware (§7.3 step 3), ranked:**<br>1. fixture stations and a cradle;<br>2. Horizon pose logs (Quest Link setting or our own logging app; each a device change needing PM approval later);<br>3. printed AprilTag/ArUco boards seen by our own cameras;<br>4. self-consistency checks;<br>5. protractor yaw steps;<br>6. optional slow-motion latency video |
| D-T17 | Boundaries (new, J-163) | **SteamVR's native Chaperone (pure SteamOS); match Guardian's safety behaviour (warning distance, onset and fade timing, loss near the boundary) by measurement on the same unit; no Meta code** |
| D-T18 | Dedicated tracking process (new, J-164) | **`fs-trackd` as an isolated service: 2 reserved cores (3 optional) via cpuset slices; RT priorities below SyncBoss 51 and the display/GPU threads, with a budget watchdog; fixed thread budgets; mlockall; a lock-free shared-memory pose IPC; fs-thermald degradation order hands → controller rate → VIO cost to a head floor (IMU 1 kHz always) → session stop** |

## 10. Open questions [O]

1. The Q3 camera power gate (sensorlock "engaged") and the sensor-programming owner.
2. Whether Q3 SyncBoss supports the Q2 camera commands.
3. **Codename mapping (jedi/ruby) and whether Q3 firmware speaks ring Touch.**
4. **Ring Touch pairing crypto.**
5. Touch Plus layout and LED models.
6. `{oculus}` profile reuse.
7. Frame-controller radio on a Quest.
8. CDSP unsigned PD on Q3 and quic/fastrpc compatibility.
9. Basalt CPU on XR2 Gen 2.
10. The OG part number.
11. IEC 62471 emitter data.
12. 0.4.5 `drivers/cv`.

## 11. Sources (new in rev 2)

- `~/work/kgateq2/src/arch/arm64/boot/dts/oculus/hollywood/hollywood-syncboss.dtsi:144-217`
  (nRF52832); `seacliff/seacliff-syncboss.dtsi:106,136` (nRF52840).
- `~/work/kgate27/src/drivers/char/adsprpc.c:730,4130-4175` (unsigned PD);
  `techpack/eva/msm/eva/*.c` (GPL-2.0-only).
- `~/work/kgate27/src/techpack/camera/drivers/cam_sensor_module/cam_sensor/cam_sensor_core.c:1044-1075`.
- `~/sfroot-full/opt/steamvr/drivers/frame_controller/resources/config/*_base.json` (key
  structure).
- `docs/research/oss-tracking-survey.md` rev 1 (44588e8): §2, §3, §7, §8, §11; rev 1.1 (J-170).
- Rev 2.3: `docs/research/quest-ports-tracking.md` rev 0 (dbeda68).
  - Clones in `~/work/quest-ports/`: cstahly `18532a559`, quest-kexec-q2 `9c96c192d`,
    Quest1-SteamOS `b7467ff15`, quest-kexec `e61edbd7f`.
  - Basalt `~/work/tracking-research/basalt` `df6e970`, `optical_flow.h:210`.
  - Duke MobiCom 2024, DOI 10.1145/3636534.3696215 [C].

## 12. Change log

- **Rev 2.3 (J-170):**
  - Quest prior art corrected: there is no *reliable* 6DoF on any Quest. cstahly's Quest 1 Basalt
    experiment (MIT) is added: it reached wearer trials and was rejected. quest-kexec's "6DoF" is
    Meta's own tracker in a second Android (§5.4).
  - Basalt epipolar bug (`optical_flow.h:210`) and cstahly patches `0001`/`0005` added to the
    fork work (§5.1).
  - Reusable items listed with licences (§5.4).
  - D-T11 decided: PASS = match Horizon on the same unit; the numbers become goals, with Duke 2024
    context (§7.3, §9).
  - D-T16 decided: replaced by the ranked validation without external hardware (§7.3 step 3).
  - The T0 and T2b effort notes now refer to the validation kit.
- **Rev 2.2 (J-165):** order changed to bundled controllers first. Q3: Touch Plus (inputs, then
  6DoF) before hands, and ring Touch after hands. The Q2 port puts ring Touch right after head.
  D-T5 reuses the Horizon pairing for bundled controllers. D-T3 and D-T16 are pending PM.
- **Rev 2.1 (J-164):** §6.3 dedicated process: isolation, priorities (Valve's priority-script names as the
  analogue; SyncBoss prio 51), thread budgets, memory, IPC, degradation order, and the CPU split table. §6.4 C-DSP:
  CDSP unsigned-PD support (`adsprpc.c:3311-3312`), questions and order. T2d added; sums 137–295 pw / 90–203 HS.
  D-T15 revised, D-T18 added.
- **Rev 2.1 (J-163):** D-T11 is now Horizon parity, measured black-box on the same unit (§7.3,
  method included); the floors are kept. §8.0 adopts IR, flash, timer, SyncBoss-bus and time-base values from GPL
  source, and marks strobe duty, frame rates and the IMU rate as measured values. D-T17 adds
  native Chaperone matched to Guardian. D-T6 makes every shipped model trained from scratch on
  clean data.
- **Rev 2 (J-162 + survey §11):**
  - Meta provider removed.
  - New ring-Touch-on-Q3 analysis (§3) and Frame-controller section (§4).
  - Basalt answer and own-fork plan (§5.1).
  - One-model hands plan with privacy rules (§5.3).
  - Detection-vs-usable (§2.2).
  - Horizon pipeline and offload (§2.6).
  - Effort in agent pw + hardware sessions (§7.2).
  - D-T13–D-T16 added; D-T2/D-T5/D-T6/D-T8/D-T10 updated.
  - Survey corrections: Mercury models not shippable (no licence; non-commercial data);
    mainline BSL constellation tracker with moving origin; LED model read from the Rift S
    controller; Touch Plus 8 LEDs; Valve's estimator inside a proprietary SLAM/reloc layer with
    an MIT "basalt" notice.
- **Rev 1:** 12 MAJOR + 10 MINOR review fixes and J-160 (see ed0f28d §10).
