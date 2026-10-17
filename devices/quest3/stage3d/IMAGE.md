# Stage 3d boot image: the stage-3c display test on Unit 2's own v2.7

**Status (2026-10-14, J-144/J-146): `fcca5ee7…4fb5` was booted once on Unit 1 (nonce `<attempt nonce withheld>`) and its
nonce-only rebuild `46b28f01…c06b` once on Unit 2 (nonce `<attempt nonce withheld>`); both registered STAGE PASS and both nonces
are spent. The status text below is earlier and is kept as written.**

**Status (2026-10-14, J-141): NEW CANDIDATE `fcca5ee7…4fb5` (nonce `<attempt nonce withheld>`), fs-pattern v0.7.1 and the
fs-probe.sh dmesg filter, for Unit 1 first (PM: fix first, then Unit 1, then Unit 2 with a nonce-only rebuild). The
previous candidate `3d730337…c224` (nonce `<attempt nonce withheld>`, fs-pattern v0.7) ran on Unit 2: r1 refused safely with
exit 30 `too_many_modes` before any commit (v2.7's DSI connector lists 305 modes, v0.7's limit was 128; README §3a); its
nonce is spent and it is withdrawn. The first v0.7.1 build `96cc15aa…3fad` (nonce `2b2596964c0812b1`, the stage-3c
fs-probe.sh) was superseded before any boot (never booted, nonce never used) and is withdrawn too. Offline only; the new
image has not been booted.** The rest of this section is the 2026-10-13 status of the v0.7 candidate.

## 0. The image (NEW CANDIDATE, v0.7.1)

| | |
|---|---|
| file | `build/stage3d/20261014T014738Z-<attempt nonce withheld>/boot-stage3d.img` (gitignored) |
| SHA-256 | **`fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5`** (CANDIDATE) |
| size | 44,875,776 B (as before) |
| nonce | **`<attempt nonce withheld>`** (USB serial `FS-<attempt nonce withheld>`), fresh from the builder (`openssl rand -hex 8`). One attempt only |
| builder | `stage3d/build-image.sh` `b90c0fbb7e874f798f2dd56fc2f9c25c73b94f82f1b4472c5087abefd7286c34` (the fs-pattern pin; the MANIFEST title says v0.7.1 and its second line "For the Quest 3 units on Horizon OS v2.7 (…; both units, J-131)", review 2 MINOR-6 fixed; the fs-probe.sh source label); `tools/module-list-check.py` `402525cd…` (unchanged) |
| how built | from the fix branch's `devices/quest3/stage3d` bound (bwrap, WSL) over the main checkout's path, so every MANIFEST path is the main checkout's (as a later nonce-only rebuild from master will write it); output in the main checkout's `build/stage3d/` only |
| ramdisk | `ramdisk.lz4` `c67d0d8019039616283cb147122eb5cf19766113bf5a2dd78ce004399d35e236` (1,963,122 B); cpio `23a7a95fcbb34dacdadcaffec83853de697c0d551c1e6aaa9fed490649cde417` (3,414,016 B, `--reproducible`); header: only `ramdisk size` (18,697,289 → 1,963,122) |
| changed files vs the v0.7 candidate | `/bin/fs-pattern` **`bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a`** (686,776 B, v0.7.1, `BUILD-RECORD.txt`); `/lib/fs/fs-probe.sh` `f0fda86513f1f758f45086741861632f10809be0744476a7f625238246e57173` (11,358 B; README §3a: the v2.7 mode-validation dmesg lines counted, not kept); `/init` `c5558472bd2331da6503c9ece353210e0f5eb14561be3a98bfd6b08f7f43dfc1` (the nonce only; 15,973 B). Every other ramdisk file, the kernel, the stock inputs, the AVB result and the 95-module list are unchanged (§1 table) |
| reproducible | rebuilt with its own nonce and stamp: the same image `fcca5ee7…4fb5` and cpio (`fixtures/builder/candidate-rebuild.txt`). `test-builder.sh` **32/32** (the v0.6 fs-pattern binary and a tampered v0.7.1 binary refused by the pin); `test-image.sh` **27/27** on this image (`fixtures/image/RESULTS.txt`); `tools/fixtures.sh` **199/0** (incl. `probe-dmesg-v27-noise`) |

**Status: CANDIDATE, rebuilt 2026-10-13 after reviews A and B (GO-with-fixes) of the first candidate
`ec822b85…0514` (nonce `4e98edbf3fbc2d4e`, commit 6c7f726, withdrawn, never booted) and the PM decisions
J-129 (modules, backlight); b5ecfcdf… (nonce `78fcf4c6e6c3b5ba`) was an intermediate build, withdrawn
before review. Offline only.** No device, adb, fastboot or COM
port was used; the image had not been booted anywhere (as of 2026-10-13; it later ran on Unit 2, §1). Any change found by the reviews means a new
build with a new nonce; this candidate is then withdrawn. Execution needs the PM's decision with the
stage-3c conditions (J-107 decision 3 scope; Unit 2 is a different unit and a user build: see
README §7), and the host side adapted per README §6.

**What it is.** A separate `fastboot boot` image for the Quest 3 units on Horizon OS v2.7 (**both units**, J-131/J-133:
the same vbmeta digest `66b76196...f12a`; the MANIFEST's sentence "For Quest 3 Unit 2 ... only" predates J-131, see
`HOST.md` §3) (build
`52433670036000520`, kernel `5.10.246-gd7102a837402`, slot a): the stage-3c image with run 1 replaced
by a non-lit display reset and the run-2 picture drawn per eye (README §3, §4). No Valve file.

**What success means.** As stage 3c: the PM reads all 8 characters correctly in each eye in run 2;
with this picture also the bars "1 | 2" in the LEFT eye and "3 | 4" in the RIGHT eye, upright and
level (the swap and roll corrections confirmed).

## 1. The previous image (v0.7; ran on Unit 2, J-141: nonce spent, WITHDRAWN)

| | |
|---|---|
| file | `build/stage3d/20261013T065151Z-<attempt nonce withheld>/boot-stage3d.img` (gitignored) |
| SHA-256 | **`3d730337c6fa9e0b5aa6dbbe9da382770ad7b104de0399887b7bfd1c30fcc224`** (WITHDRAWN: nonce spent in the J-141 run; fs-pattern v0.7) |
| size | 44,875,776 B |
| nonce | **`<attempt nonce withheld>`** (USB serial `FS-<attempt nonce withheld>`), fresh from the builder (`openssl rand -hex 8`). One attempt only |
| builder | `stage3d/build-image.sh` `605da89e5486aadd01d93c9925ea7f852dc14a27ed94c494bf1f0fb1bf7561f7`; records in the build directory (MANIFEST.txt, avb-check.txt, module-list-check.txt, ramdisk.list, ramdisk.sha256, applets.txt, header-diff.txt, ramdisk-scan.txt, gitcheck.txt) |
| stock boot | `e32f98c74bcce5c25b098393f7804e19fbba2f0c2034c49a4fcf6aa9a8cdc024` (v2.7 OTA) |
| kernel | `db61c073962bf1df38cbb09cbb01f03e5595822754ffea1dc75166555f7d545e` (`5.10.246-gd7102a837402`), byte-identical (AOSP re-unpack) |
| header | only `ramdisk size` (18,697,289 → 1,962,577) differs from stock (stock signature size is already 0); os 14.0.0, patch 2026-06 |
| ramdisk | `ramdisk.lz4` `14c8ad33e3288d408ea5714f06c7652039695988ef5917813882f22aee911ca8` (1,962,577 B); cpio `5fc7de3914718c0f317e100d1b547ee4a907a29208987f2b4a259b4a3892aff2` (3,412,992 B, `--reproducible`) |
| vendor_boot | `bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b` (v2.7 OTA; on the device, not in the image); its modules list `0dd1deb0…66f4` (131, provenance only, NOT loaded); file list `c01d89a1…b2ce` (143); `modules.dep` `ae5edf11…29e3` and `modules.softdep` `8e49f03a…ff62` pinned in init.sh |
| loaded modules | `/lib/fs/modules.load` = `stage3d/modules.load.v66` `1b93d77d029146cf93289be87de51514c6ab7b96987f9c467a7f13f6e2a6463f`: **95** (the proven v66 set, J-129); `tools/module-list-check.py` `35261647…e8ca` PASS (present, closed, display/USB roots inside, the 36 excluded unreachable) |
| AVB | vbmeta `aae4af3a…f215` + vbmeta_system `28f5ccc9…bc50` → digest **`66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a`** = Unit 2's runtime digest; boot and vendor_boot hash descriptors MATCH (`tools/avb-check.py` `02ec464e…`) |
| E1 | AOSP mkbootimg `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` CLEAN; note: mode bits not checkable on this drvfs checkout |
| scan | `stage3d/tools/ramdisk-scan-3d.sh` `a417a122…a7d7` (t1-ramdisk-scan.sh with the v2.7 vendor_boot): no BLAKE2 hit; kernel `# CONFIG_CRYPTO_USER_API_HASH is not set` |
| reproducible | rebuilt with its own nonce and stamp: the same image and cpio (`fixtures/builder/candidate-rebuild.txt`) |

### Contents (our ramdisk; the vendor ramdisk is Unit 2's stock one)

Directories: `bin config dev lib lib/fs proc run sys tmp`.

| path | size | SHA-256 | source |
|---|---|---|---|
| `/init` | 15,973 | `5e9f5987fe7d643340604b1e4f63a0b3d73d415ba0871bceac260ae2ead84ad2` | `stage3d/init.sh` `9141cc3b9ef71dfa8163dfc776e8eb2f4b691946d97155ac910e350da0dc79a8`, nonce substituted |
| `/bin/busybox` | 1,981,032 | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | stage-1 busybox 1.37 (reviewed) |
| `/bin/fs-reboot` | 1,400 | `c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29` | stage-1 helper |
| `/bin/fs-reboot-final` | 808 | `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` | `common/build` |
| `/bin/fs-supervise` | 676,952 | `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74` | `common/build` |
| `/bin/fs-pattern` | 686,392 | **`7c9fa98c3d04d2cc43663ac85429829d204048270ddf75a62919e6185a950674`** | `stage3d/build`, **v0.7** (`BUILD-RECORD.txt`; source `354ad53d…fc42`: review A's header-comment fix changed the source hash only, the binary is bit-identical to the first candidate's, pin unchanged) |
| `/bin/fs-phase` | 16,137 | `a72d451a6b0e534035fcf8d1babe4e82cb2d2cfd56e44598cec388defe33c4ac` | `stage3d/fs-phase.sh` (header comment fixed, review B) |
| `/bin/fs-done` | 705 | `7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959` | `common/target/fs-done` |
| `/lib/fs/pid1-hold.sh` | 7,556 | `4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4` | `common/target`, rev 5 |
| `/lib/fs/fsb1-enc.sh` | 4,943 | `11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7` | `common/target`, rev 5 |
| `/lib/fs/fsb1-pace.sh` | 3,255 | `71ce176e09c21b2304b0be90543f2c0da26b0a5c0aed3c3bb23cf8a2b412404c` | `common/target` |
| `/lib/fs/fs-probe.sh` | 10,666 | `f043af6fa9a6e3bec726339c329b094ece28883e5f97cf8acb0cb9c035bb9c4f` | = stage 3c |
| `/lib/fs/fs-idle.sh` | 2,276 | `989472569328413928b5c2ab01b53060aa3a99081cf66209e45d161737ed6124` | = stage 3c |
| `/lib/fs/modules.load` | 1,487 | `1b93d77d029146cf93289be87de51514c6ab7b96987f9c467a7f13f6e2a6463f` | `stage3d/modules.load.v66` (95 modules, J-129) |

## 2. Inputs: provenance and the match with Unit 2

| file | SHA-256 | checked against |
|---|---|---|
| `firmware/quest3/ota/q3_52433670036000520.zip` | `e4c57710fbb067051698b8df4a98fd19ed7e76cb6387f8f21aca8377f49d2e04` | the held official full OTA (`firmware/quest3/PROVENANCE.txt`; `<withheld update-path research>` §1): `post-build …/52433670036000520:user/…release-keys`, `ota-type=AB`, SPL 2026-06-03, timestamp 1787794605 |
| `v2.7-user_ota/boot.img` | `e32f98c7…c024` (100,663,296 B) | payload.bin `new_partition_info` MATCH; vbmeta hash descriptor (image_size 61,607,936) MATCH |
| `v2.7-user_ota/vendor_boot.img` | `bc0dd14d…2f5b` (100,663,296 B) | payload MATCH; hash descriptor (5,058,560) MATCH |
| `v2.7-user_ota/dtbo.img` | `93bd12d2…0b` | payload MATCH; hash descriptor MATCH |
| `v2.7-user_ota/vbmeta.img` | `aae4af3a…f215` | payload MATCH; rollback 1780444800 (2026-06-03) |
| `v2.7-user_ota/vbmeta_system.img` | `28f5ccc9…bc50` | payload MATCH; chain key = the vbmeta chain descriptor key |

Unit 2 (read-only baseline 2026-10-12, `devices/quest3/evidence/unit2-v27-baseline-20261012`) [M]:
`ro.boot.vbmeta.digest` `66b76196…9f12a` and `ro.boot.vbmeta.size` 8768 = the digest and size
computed above; `Linux version 5.10.246-gd7102a837402 … #1 SMP PREEMPT Wed Aug 26 18:44:55 PDT 2026` =
the kernel string in the OTA boot.img; `/proc/cmdline` carries v2.7's vendor command line
(`… print-fatal-signals=1 … log_buf_len=256K bootconfig`; v66's differs); `ro.boot.load_modules_parallel=true`
(v2.7 bootconfig only); `ro.bootimage.build.date.utc` 1787794605 = the OTA timestamp; `ro.boot.dtb_idx` 0,
`ro.boot.dtbo_idx` 11. Reports: `provenance/{ota,avb,runtime,images}.txt` (`tools/v27-inputs.sh`).
Limits [D]: AVB does not enforce the descriptors on these units, so the slot's exact bytes are
derived (digest + runtime facts), not read back; the payload signature was not verified.

## 3. Modules (v2.7 vendor ramdisk; `provenance/modules.txt`)

- `lib/modules/modules.load.recovery` = `modules.load`: 131 entries, sha256 `0dd1deb0…66f4`, all
  vermagic `5.10.246-gd7102a837402 SMP preempt mod_unload modversions aarch64`. **Not loaded as a list
  (PM decision J-129).** init.sh loads our `/lib/fs/modules.load` (`modules.load.v66`, 95 = stage 3c's
  v66 list minus debug-regulator and qti-regmap-debugfs, v66 order), each module after its
  `modules.dep` closure and softdeps; the builder proves the list closed under both, so the 36 modules
  below never load. Versus the first candidate (6c7f726): 131 → 95, the 36 below removed, none added.
  Before any module, init.sh checks the device's `modules.dep` / `modules.softdep` SHA-256 against the
  pins (fail closed, README §1).
- Added vs v66 (36; **none of them is loaded by stage 3d**): adsp_loader_dlkm, ak09973, as5510, bcl_pmic5, bcl_soc, charging_dock,
  external_battery, frpc-adsprpc, gpr_dlkm, industrialio-triggered-buffer, kfifo_buf, mdt_loader, q6_dlkm,
  q6_notifier_dlkm, q6_pdr_dlkm, qcom-spmi-adc5-gen3, qcom-spmi-temp-alarm, qcom-vadc-common, qcom_lpm,
  qcom_pil_info, qcom_q6v5, qcom_q6v5_pas, qcom_ramdump, qcom_sysmon, qcom_tsens, qti-ocp-notifier,
  qti_battery_charger_main, qti_qmi_sensor_v2, smp2p, smp2p_sleepstate, snd_event_dlkm, spf_core_dlkm,
  usbvdm, usbvdm-cypd, usbvdm-glink, userspace-consumer. Removed (2): debug-regulator, qti-regmap-debugfs.
  New softdep: `q6_notifier_dlkm pre: qcom_q6v5_pas`.
- The display/USB/backlight/LED/fan closure (msm_drm, dwc3-msm, leds-qti-tri-led, tps65132-regulator,
  blu_fw_driver, mp3314, pwm-qti-lpg, msm_ext_display, panel_event_notifier, dispcc0/1-anorak,
  ucsi_glink, pwm-tach-fan): the same 44 modules as v66 minus debug-regulator; every member is in the
  v2.7 list. Platform probe dependencies (gcc, icc, rpmh-regulator, arm_smmu, pinctrl) are in both lists.
- vendor_dlkm is not used (as in stage 3c: the recovery set is in the vendor ramdisk).

## 4. Display assumptions re-checked from the v2.7 DT (`provenance/dt.txt`)

| item | v66 (stage 3c) | v2.7 (Unit 2) |
|---|---|---|
| base dtb / overlay | dtb 0 + dtbo 10 (PVT1.1) | dtb 0 + dtbo 11 (PVT1.1), **overlay byte-identical** |
| panel | meta,eureka_panel_sharp | same (runtime `msm_drm.dsi_display0=meta,eureka_panel_sharp`) |
| timing@0 | 2064x2208/link, HFP 38 HBP 54 HPW 20, VFP 2918 VBP 30 VPW 2, 90 Hz | identical |
| topology / DSC | <4 4 2>; 8 bpc, 8 bpp, slice 1032x32, 2/pkt, block prediction, disable-default-pps | identical |
| MDP clock max | 550 MHz | identical |
| SSPPs | 4 VIG + 6 DMA, smart-DMA prio 7 8 9 10 1 2 3 4 5 6 | identical |
| blendstages / zpos max | 11 / 10 | identical |
| pipe order, swap-mixers | v1; absent | identical |
| panel orientation | absent | `"180"`: connector-blob text only, not applied |
| on/off command delays | 120/120 ms on, 120/250 ms off | 84/0 ms on, 0/56 ms off (+ batch flags) |
| max refresh | 120, steps 5/24 | 240, no steps |
| new | — | `meta,ddic-family`, `meta,freerun-histogram`; driver: Tokki-A `backlight_changes_blocked = 1` at start |

The 4 x 1032 layout with zpos {0,0,1,1} still holds: the per-pipe width limit (~1128 px at 550 MHz,
vtotal 5158) is unchanged, and the SDE plane caps (pipe_idx, max_upscale 20/1, primary_smart_plane_id),
zpos range, quad-pipe coordinate conversion, staging and vote defaults are unchanged in the v2.7 driver
source (2026-10-13 research). fs-pattern discovers the planes at run time; no change was needed for
that. fs-pattern v0.7 changes only run 1 (reset) and the picture (README §3, §4).

## 5. What the builder enforces

Stage 3c's checks with the v2.7 inputs (README §2): the AVB provenance step first; pins for the stock
boot, vendor_boot, vbmeta, vbmeta_system, kernel (+ release string), the vendor module list (131,
provenance), the vendor file list (143), OUR module list `modules.load.v66` (95) with
`tools/module-list-check.py` on the v2.7 vendor modules, init.sh's two vendor-index pins equal to the
pinned vendor_boot's `modules.dep` / `modules.softdep`, no script naming `backlight_changes_blocked`
outside a comment (J-129), busybox, fs-reboot, fs-reboot-final, fs-supervise, **fs-pattern v0.7**, pid1-hold.sh,
fsb1-enc.sh, fsb1-pace.sh, fs-done; init.sh, fs-phase.sh, fs-probe.sh, fs-idle.sh recorded; static-ELF
checks; the applet table; LF-only scripts; no debugfs (lexical) and the mount whitelist; fs-idle.sh names
no tty; the exact ramdisk list; no symlinks; no vendor collision (v2.7's vendor ramdisk adds
`adb_debug.prop` and `first_stage_ramdisk/fstab.*`, text only); the union lacks the loader paths and
`/valve`; only the five ELF files; the BLAKE2 scan with the v2.7 vendor_boot; kernel bytes unchanged;
the header differs only in `ramdisk size`; every file equals the staged one; a fresh nonce per build.

## 6. Offline fixtures (all [D])

| suite | result |
|---|---|
| fs-pattern v0.7.1 (`tools/fixtures.sh`, 2026-10-14) | **199 PASS, 0 failures** (incl. the fs-probe.sh dmesg filter check `tools/probe-dmesg-check.sh` 6/6) (`fixtures/RESULTS.txt`): every v0.7 check below (unit tests now **88/88**: + the v2.7 list (305 = 136 + 169, one expected mode at index 0 with the v66 timing, the near-duplicates not expected, the policy on it incl. a splash mode not in the list, the late reordering, 513 > MAXMODES); **30 mock scenarios**: + `reset-v27`, `quad-v27`, `solid-v27` (Unit 2's connector set 33/55/65, types 15/16/10, 37/305/0 modes; essential 14214 / 17040 / 17055 B, below the -max fixtures), `reset-v27-late`, `quad-v27-late` (the expected mode at index 250 behind near-duplicates: chosen, same timing in r1 and r2), `reset-toomany` (exit 30); **static 79/79**); section (j): `tools/v27-modes.py` 7/7 (validated on v66's 24 logged modes), the C mock's list = the model's line for line, the **v0.7-limit control** (MAXMODES 128) fails the three v2.7 scenarios with exit 30 exactly as Unit 2's r1 did, `check_delta071.py` 7/7 (device build = v0.7 + the fix only). Timing: CONSISTENT (`fixtures/check-timing-3d.txt`). The v0.7 run of 2026-10-13: | fs-pattern v0.7 (`tools/fixtures.sh`) | **186 PASS, 0 failures** (`fixtures/RESULTS.txt`): unit tests **77/77** (v0.6's 63 + fdiv, eye mapping, eye sine, Q16 table, the identity blit = v0.6's 180°, options, build_reset, black buffer); render/refusal/stdout/strace/signal/clamp/backstop fixtures of v0.6; reset refusals and stat-not-open; option refusals and records; **24 mock scenarios** incl. reset, reset-inactive, reset-off-reject, reset-on-reject, reset-max (essential 14299 + budget 38912 ≤ 57344) and quad-vig-roll0-direct; **static v0.7 vs v0.6: 75/75**; the v0.7 picture checked independently (float forward mapping) for 8 roll/eyes settings x 2 nonces + 5 default nonces (31 checks each: characters per eye, F upright, bars per group, measured roll within 0.35°, every group inside its mixer, margins, levels, envelope); 4 negative controls (wrong roll/eyes expectations fail); roll 0 + eyes direct = the stage-3c binary's render byte for byte (3 nonces); the Python port = the C render byte for byte (3 settings); roll 0 + eyes swap = ONE 180° rotation of the whole frame [left eye | right eye] (whole-frame-180-equivalence); the previews |
| timing (`tools/check-timing-3d.py`) | **CONSISTENT** (`fixtures/check-timing-3d.txt`): stage-3c PHASE_WORST/MAXLINES/guards unchanged; r1 has no hold; encode and dmesg re-measured (`fixtures/encode-timing.txt`, `dmesg-timing.txt`) |
| paced emission (`tools/pace_evidence.py`) | **63/63** (`fixtures/pace/RESULTS.txt`, exp `s3d_`) |
| builder (`test-builder.sh`) | **27/27** (`fixtures/builder/RESULTS.txt`): the stage-3c negatives, + v66 boot / vendor_boot / vbmeta instead of v2.7 (AVB or pin refusal), + the v0.6 fs-pattern binary, + a module list with a v2.7-only module added (pin refusal), + a script naming `backlight_changes_blocked`, + init.sh's `MODDEP_SHA` one digit off (refused); `module-list-check.py` itself: the pinned list accepted, a not-closed list (qcom_q6v5_pas added), a list without msm_drm and a list naming a file v2.7 lacks refused; two builds with one nonce bit-identical; **the candidate rebuilt with its own nonce and stamp: `3d730337…c224` again, identical cpio** |
| whole image (`test-image.sh`, the candidate's initramfs under qemu/bwrap) | **27/27** (`fixtures/image/RESULTS.txt`): stage 3c's scenarios with r1 = the reset (replayed reset streams; the genuine fs-pattern reports no device), the fs-pattern arguments checked (`reset <c1>`; `show-off-quad <c2> 10 /dev/dri/card0 roll=21 eyes=swap`), `c-sim-reset-fail` (reset exit 50 → r2 skipped `run1-supervisor`) replacing `c-sim-unclean`; every record VALID as `exp=s3d_<ph>`; the sandbox has the REAL v2.7 `modules.dep`/`modules.softdep` (text only, no .ko): `MODULE_INDEX` logged in every scenario; **`c-modules-real`**: the image's own 95 entries each tried once, nothing else, the vendor list (a decoy) never read; **`c-modules-refused`**: `modules.dep` one line off: `MODULES_REFUSED` + `ERROR_modules`, no module tried, no shell, reboot `error-modules` at T0 + 60 s; the other scenarios use a 3-module subset of the list (harness fake, for time) |

**Not exercised offline:** every real DRM ioctl (the mock model only), whether the reset's step B
takes the splash path and clears it, the lastclose power-off, run 2's full power-on on v2.7, the
`backlight_changes_blocked` effect (README §7: run 2 may be dim or dark), the 95-module load and the
vendor-index check on the device, the v2.7 ABL's acceptance of
the image, the optical result (swap/roll), the tty/USB timing, thermal behaviour.

## 7. Changes from the stage-3c image

| # | stage 3c | stage 3d | why |
|---|---|---|---|
| 1 | v66 boot/vendor_boot/kernel (Unit 1) | v2.7 OTA boot/vendor_boot/kernel (Unit 2), AVB-checked | Unit 2's own build (PM, J-126) |
| 2 | 97 modules (the vendor's v66 list) | 95 modules from our own `/lib/fs/modules.load` (the v66 set minus 2 debug modules), resolved against v2.7's files | PM decision J-129 |
| 2b | — | the device's `modules.dep` / `modules.softdep` SHA-256 checked before any module; mismatch: fail closed | image review B |
| 3 | r1 `show <c1> 3` (lit run 1, 2 x 2064) | r1 `reset <c1>` (disable, dark black re-enable, close) | PM decision 1 (2026-10-13) |
| 4 | r2 gated on run 1's commit/hold/close | r2 gated on the reset (`gate_reset`) | follows #3 |
| 5 | fs-pattern v0.6, eye = buffer half, no roll | v0.7: per-eye, eyes=swap, roll=21 | PM decision 2 (J-125 observation) |
| 6 | `exp=s3c_<ph>`; product `FrameShift stage3c` | `exp=s3d_<ph>`; `FrameShift stage3d` | identity |
| 6b | — | `backlight_changes_blocked` never written (builder lint) | PM decision J-129 |
| 7 | header diff: ramdisk size + signature size | ramdisk size only | v2.7 stock signature size is 0 |
