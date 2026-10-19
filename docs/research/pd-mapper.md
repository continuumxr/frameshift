# Protection-domain mapper for Quest 3 T3b (research, rev 1.1)

**Status:** research only, revision 1.1, 2026-10-18 (revision 1, 2026-10-16). Answers PM decision
D-T0-4 (J-190): "research an open-source PD mapper for T3b". Revision 0 (`13f69f6`) was reviewed
adversarially: **GO-with-fixes** (1 blocker, 4 major, 2 minor, completeness). Every fix is applied
here; the change table is §11. Nothing here authorises a device action.

> **Correction (FS-R-014 §9, 2026-10-18).** The Chair accepted preparing the pinned open-source
> mapper route and its dependency/notice manifest (no device execution), and corrected C-PD3's
> equivalence. Fixed in place in §1, §5.4, §7.1, §8 (PD-M5, C-PD3) and §9:
> - **K5 (download_mode=0) and `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n` are not equivalent protections.**
>   K5 changes only the *consequence* of a panic (no crash-dump mode). It does not remove the
>   PDR-callback panic/restart path. Disabling the config option removes that particular panic path.
>   A future package may choose either route only with its actual failure behaviour stated.
> - **`shutdown_in_progress=1` only suppresses failure handling** (the PDR-timeout panic and the
>   "failed to recover" panic). It does not itself shut down the ADSP or the headset. The future
>   shutdown sequence must keep battery and thermal handling running until the actual shutdown and
>   justify when the suppression is applied.
> - **Mapper publication, PD notification and battery-data freshness are separate claims.** An UP
>   notification alone does not validate fresh battery readings.

**Licence:** CC-BY-4.0 (our own documentation; `docs/PROVENANCE-POLICY.md` §6).

**Method and rules followed.**
- Offline only. No headset, adb or fastboot. Nothing was downloaded (web pages and source were
  read in the browser-fetch tool only). `/persist` and the PM's offline backup drive were not used.
- Meta files were read as **configuration, JSON, init `.rc` files and `strings`/ELF dynamic-section
  output only**. No Meta, Qualcomm or Valve binary was disassembled or decompiled.
- Upstream source (linux-msm, Linux mainline) was read for facts only. **No code is copied here.**
  The domain data below are stated as facts (names, numbers), not as file copies.
- **AI-directed text:** one instance found, on a web page (§10). It was ignored.

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named artifact
(file:line, or a named web source with the date read) · **[D]** derived, with the derivation stated
· **[C]** inferred, unconfirmed · **[O]** open.

**Sources** (read-only):
- Quest 3 v2.7 `vendor.img` (sha256 `e251197f09bd…8a38cc`, payload-verified), WSL
  `~/work/fs006-kernel/v27/`, read with `debugfs` (`cat`/`ls` only). Paths below like
  `/firmware/battmgr.jsn` and `/etc/init/hw/init.anorak.rc` are inside that image (`/vendor/…` on
  the device).
- Quest 3 v2.7 kernel source `~/work/kgate27/src` (`dbc2bc83a2b6`), its stock config
  `~/work/kgate27/stock.config`, and the runtime DT `~/work/dtdiff/v27.dts` (WSL).
- Steam Frame image: kernel config `firmware/SteamOS/extracted/config-6.18.0-gfbdbca41fd45` and the
  rootfs copy WSL `~/sfroot-full` (file names only).
- Our documents: `devices/quest3/ts/FIRMWARE.md` §2, the T0 package notes (private),
  `docs/research/thermal-control-design.md` §6, `docs/research/device-health-design.md` (H-1, H-2),
  `docs/research/armadavr.md`, `docs/research/community-quest-repos-2.md`.
- Web, read 2026-10-16: linux-msm/pd-mapper and linux-msm/qrtr (GitHub pages, API, raw source),
  mainline `drivers/soc/qcom/qcom_pd_mapper.c` (master), LKML threads on the in-kernel mapper and on
  the pmic_glink ECANCELED fix, postmarketOS package pages and pmaports issue #2936, Alpine
  package index, Producdevity/ArmadaVR `docs/quest-early-boot.md`. URLs in §12.

---

## 1. Summary and recommendation

**What the mapper is.** The protection-domain (PD) mapper is the QMI "service registry locator"
(QRTR service 0x40 = 64, version 1, instance 1). A client asks it "which protection domains provide
service X?" and gets back domain names and QMI instance numbers. The Linux PDR helper then
registers with the remote's service notifier for that domain, so the kernel learns when the domain
goes up or down.

**What the Quest 3 needs.**
- One kernel client in our closure asks for it: `pmic_glink`, with
  `qcom,protection-domain = "tms/servreg", "msm/adsp/charger_pd"` (`v27.dts:19462`) [M-static].
- Meta's v2.7 runs Qualcomm's **proprietary** `pd-mapper` (Android, QMI-CSI libraries), which reads
  the five `.jsn` files in `/vendor/firmware` [M-static, rc + strings].
- The v2.7 kernel's `pmic_glink` does **not** wait for the PD to be reported UP before it creates
  the battery, UCSI and altmode devices: it populates them when the `PMIC_RTR_ADSP_APPS` rpmsg
  channel probes (`pmic_glink.c:479-496, 545-566`) [M-static]. The PD mapper only gives it
  **down/up notifications** for `charger_pd`. Whether the ADSP firmware itself needs the mapper
  before `charger_pd` opens that channel is **[O]** (§2.5).

**Recommendation: option A, a small userspace daemon in our init: linux-msm `pd-mapper`.**
- BSD-3-Clause, maintained by the Linaro/Qualcomm upstream people (tag v1.1 = `5ecd2fe926ac`,
  2025-12-30), packaged by postmarketOS. It reads `.jsn` files as data from the firmware directory
  [M-static, upstream source].
- Built from pinned source as a static aarch64 binary, with linux-msm `libqrtr` (BSD-3-Clause) and
  `liblzma` (§3.1).
- Data: **our own `.jsn` files written from the facts in §2.1** (the four ADSP domains), checked in
  a test against the semantics of Meta's files. Meta's own files are not needed.
- No kernel change; the K1a/K1g kernel and the stock vendor modules stay as reviewed.
- **Conditions (rev 1; corrected rev 1.1):** the mapper makes a stock PDR-callback panic path
  reachable (§5.4). Two routes exist and they are **not equivalent**: K5 (download_mode=0) keeps
  the panic but changes its consequence from crash-dump mode to the configured panic behaviour
  (`PANIC_TIMEOUT=-1`, an immediate reboot [D, not measured]); `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`
  removes that panic path. The package that runs the
  mapper states which route it uses and the resulting failure behaviour; a `charger_pd` DOWN indication becomes an immediate
  battery-class SEVERE (§5.1); no DSP-serving file or RPC daemon runs (§5.6); our build fixes one
  upstream read-error defect (§3.1).
- A back-port of the in-kernel `qcom_pd_mapper` is feasible only as **new kernel code** (a
  stand-alone out-of-tree module with an `anorak` table). It is not worth that cost now (§4).
  It stays the long-term route only for a mainline kernel.

**Where it fits.** T3b (closes the open item in `FIRMWARE.md` §2 and D-T0-4), then the R-1
composition: the daemon starts in our initramfs and keeps running under Valve's userspace, which
ships no daemon because the Frame kernel has the in-kernel mapper (§6.3).

---

## 2. What the Quest 3 v2.7 has

### 2.1 The PD JSON files (`vendor.img:/firmware/*.jsn`)

All five files have format version 1.1.1 and SoC `msm` [M-static]. Every domain offers `tms/servreg`
with `service_data_valid` 0.

| file | bytes | sha256 (first 16) | domain | QMI instance | extra service |
|---|---|---|---|---|---|
| `adspr.jsn` | 513 | `66ce8531efb7979d` | `msm/adsp/root_pd` | 74 | none |
| `adsps.jsn` | 515 | `12ac2f3ae8ced12a` | `msm/adsp/sensor_pd` | 74 | none |
| `adspua.jsn` | 703 | `982a99853495e347` | `msm/adsp/audio_pd` | 74 | `avs/audio` |
| `battmgr.jsn` | 516 | `be8c6fba330908e4` | `msm/adsp/charger_pd` | 74 | none |
| `cdspr.jsn` | 513 | `6d01cd7dce745204` | `msm/cdsp/root_pd` | 76 | none |

- `battmgr.jsn` matches the hash already pinned in `devices/quest3/ts/firmware-manifest.tsv`
  [M-static].
- There is no modem, SLPI or WLAN-PD file. Quest 3 has no modem [D].
- **Mainline comparison** [M-static, mainline `qcom_pd_mapper.c` master, 2026-10-16]: the in-kernel
  table for `sm8550` (shared by `sm8650`) has exactly these five domains, with the same names,
  instances and the `avs/audio` extra, **plus** `msm/modem/root_pd` (180, `gps/gps_service`).
  So, for the PD map, anorak is "sm8550 without a modem" [D]. `sm8450` differs (it adds
  `tms/pdr_enabled` on the ADSP root PD, and SLPI domains).
- Valve's Frame rootfs ships the same five file names under `/usr/lib/firmware/qcom/sm8650/`
  [M-static, file names only]. They are SM8650 data for Valve's kernel, not ours.

### 2.2 Meta's own setup (Android userspace)

| what | where | fact |
|---|---|---|
| PD mapper | `/etc/init/hw/init.anorak.rc:219-222` | `service vendor.pd_mapper /vendor/bin/pd-mapper`, `class core`, user/group `system`; not `oneshot`, so Android init restarts it [M-static] |
| the binary | `/bin/pd-mapper` (28,840 B, sha256 `50915e028209…02cc`) | Qualcomm's proprietary mapper, **not** linux-msm's: it links `libqmi_csi`, `libqmi_cci`, `libqmi_encdec`, `libjson`, `libcutils`, `liblog` (ELF `NEEDED`) [M-static]. Its strings name the scan directories `/vendor/firmware`, `/vendor/firmware/image`, `/vendor/firmware_mnt/image` and three `sdx*` modem paths, and the suffix `.jsn` [M-static, strings] |
| QRTR name server | `init.anorak.rc:242-246`, `/bin/qrtr-ns` (sha256 `e52b1b51c921…089d`) | `qrtr-ns -f`, user `vendor_qrtr`, `NET_BIND_SERVICE`; links `libqrtr`. Its strings match the linux-msm `qrtr-ns` usage text [M-static]. The v2.7 kernel already runs its own name server (§2.3), so this one probably fails to bind the control port [C] |
| ADSP start | `/etc/init.insmod.cfg:1-13`; `init.anorak.rc:31-34, 185-190` | at `on init`, `insmod_sh` loads every module, sets `vendor.all.modules.ready`, then writes `/sys/kernel/boot_adsp/boot`, `boot_cdsp/boot` and the CVP boot node, then sets `vendor.all.devices.ready` [M-static] |
| ordering | `init.anorak.rc:93-97` | `on early-boot` waits for `vendor.all.devices.ready` [M-static]. `class core` services start at `on boot`, after `early-boot` [C: AOSP `init.rc` convention, not read here]. **So on stock v2.7 the ADSP boot is requested before the PD mapper starts** [D]. The boot write only schedules the load (`adsp-loader.c:53-56, 226-228`, via FIRMWARE.md §2), so the ADSP may come up before or after the mapper; there is no ordering guarantee [D] |
| remote file server | `/etc/init/vendor.qti.tftp.rc`; `/bin/tftp_server` (sha256 `96875855a112…3280`) | `tftp_server`, user root. Its strings name `/mnt/vendor/persist/rfs/msm/adsp/`, `/mnt/vendor/persist/hlos_rfs/shared/`, `/data/vendor/tombstones/rfs/lpass/` and `/vendor/rfs/…` [M-static, strings]. **This is the ADSP's remote file system: it reaches `/persist`. It is not part of the mapper and must never run in our images** (§5.6) |
| others | `init.anorak.rc:224-240` | `pm-service`/`pm-proxy` (peripheral manager) and `ssr_setup`. Not needed for a remoteproc started through sysfs [C] |

### 2.3 The kernel side (v2.7 source)

- **QRTR name server is in the kernel.** `net/qrtr/Makefile` builds `ns.o` into `qrtr.ko`;
  `af_qrtr.c:2130` calls `qrtr_ns_init()`, which binds the control port (`ns.c:745-800`)
  [M-static]. `CONFIG_QRTR=m`, `CONFIG_QRTR_SMD=m` (`stock.config:1436-1439`) [M-static]. **No
  userspace `qrtr-ns` is needed** [D]. The transport to the ADSP is `qrtr-smd.ko` (vendor_dlkm,
  already in the T3b closure, the T0 package notes (private)).
- **No in-kernel mapper.** There is no `qcom_pd_mapper.c` in this tree;
  `CONFIG_MSM_SERVICE_LOCATOR` is not set (`stock.config:5622`) [M-static].
- **PDR helper.** `CONFIG_QCOM_PDR_HELPERS=m` (`:5615`). `pdr_interface.c:722` looks up the
  locator as service `SERVREG_LOCATOR_SERVICE` (0x40, `pdr_internal.h:7`), version 1, instance 1
  [M-static]. Until a locator appears, a lookup stays pending (`pdr_locator_work`,
  `pdr_interface.c:492-526`) [M-static]; nothing fails or panics.
- **PDR panic option.** `CONFIG_QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=y`,
  `CONFIG_PDR_INDICATION_NOTIF_TIMEOUT=9000` (`stock.config:5616-5617`) [M-static]. When a
  **state indication** arrives, a 9 s timer covers the client callback; on expiry the kernel
  panics unless it is already restarting, powering off or halting, or `shutdown_in_progress` is
  set (`pdr_interface.c:275-288, 296-306`) [M-static]. `CONFIG_PANIC_TIMEOUT=-1` (`:7090`)
  [M-static], but with `download_mode=1` on the cmdline a panic enters crash-dump mode instead
  (§5.4).
- **Who uses PDR in this tree:** `pmic_glink.c`, `apr.c`, `adsprpc.c`, `qcom-ngd-ctrl.c`,
  `icnss2/main.c`, `techpack/audio/dsp/audio_pdr.c` [M-static, grep]. Only `pmic_glink` is in the T3b
  closure, and only its DT node carries `qcom,protection-domain` (`v27.dts:19462`, the single
  match) [M-static].

### 2.4 How `pmic_glink` uses the domain (v2.7 downstream)

- Probe reads the two strings and calls `pdr_handle_alloc()` + `pdr_add_lookup()` for
  `tms/servreg` / `msm/adsp/charger_pd` (`pmic_glink.c:615-694`) [M-static].
- The child devices (battery charger, UCSI, altmode, Meta's `usbvdm`) are created in
  `pmic_glink_init_work`, which runs when the `PMIC_RTR_ADSP_APPS` rpmsg channel probes
  (`:479-496, 545-566`). That path does not check the PD state [M-static].
- The PDR callback only acts on **DOWN** (notifies clients DOWN); on UP it waits for the rpmsg
  probe (`:170-196`) [M-static].
- **Contrast with mainline:** mainline `pmic_glink` notifies its clients only when both the PD is
  UP and rpmsg is up [C, from the mainline design described in the LKML threads; not re-read].
  That is why mainline needs the mapper for battery and USB-C. Our downstream kernel needs it only
  for the DOWN path [D].
- **Battery driver on DOWN:** `battery_chg_state_cb` sets the state; while DOWN, reads return the
  last known values (`qti_battery_charger.c:464-479, 627-645`) [M-static]. If the rpmsg channel
  itself goes away, `pmic_glink_write()` returns `-ENOTCONN` (`pmic_glink.c:240-254, 462-477`)
  [M-static].

### 2.5 Which services the ADSP side requests

- **From the APPS kernel:** one lookup, `tms/servreg` → `msm/adsp/charger_pd`, instance 74
  (§2.4) [M-static]. The mapper answers with every domain offering `tms/servreg`; the PDR helper
  picks the matching name [C, standard PDR flow].
- **From the ADSP firmware itself:** unknown. Meta requests the ADSP boot before the mapper starts
  (§2.2), which suggests the firmware does not hard-block on it at boot [C]. **The gap between the
  two on a stock unit is unmeasured** [O]; it may be short. ArmadaVR waits for service 64
  before starting the ADSP, but has run only in QEMU [C, their doc]. The upstream cover letter says
  the mapper is needed "for properly starting UCSI, altmode and battery manager", in mainline
  terms [M-static, LKML v7 0/6]. **[O-PD1]: does `charger_pd` open `PMIC_RTR_ADSP_APPS` and serve
  battery data with no mapper present?** T3b can answer it at no extra risk (§7.1).

---

## 3. Candidates

| candidate | licence | maintenance | where its domain list comes from | fit for us |
|---|---|---|---|---|
| **A. linux-msm/pd-mapper** | BSD-3-Clause (Linaro 2018, Bjorn Andersson 2016) [M-static] | active: tags v0.0, v1.0, v1.1; v1.1 = master `5ecd2fe926ac` (2025-12-30, sysfs firmware-path fixes by Dmitry Baryshkov, merged by Konrad Dybcio) [M-static, GitHub API] | `.jsn` (and `.jsn.xz`) files, read **once at start**, from the directory part of each `/sys/class/remoteproc/*/firmware` value, resolved against `/sys/module/firmware_class/parameters/path` or else `/lib/firmware/` (`/vendor/firmware/` on Android); top level only; duplicates removed [M-static, `pd-mapper.c`] | **recommended** (§1) |
| **B. in-kernel `qcom_pd_mapper`** | GPL-2.0-only (Linaro 2023) [M-static] | merged for 6.11 (Dmitry Baryshkov; the 6.11 fixes pull carries pd-mapper fixes) [C→D: the fixes pull exists]; reworked since: current master binds as an auxiliary device named `qcom_common.pd-mapper`, ~600 lines [M-static, master] | **static C tables per SoC**, chosen by the root DT compatible; an unknown machine gets "unsupported" and `-ENODEV` [M-static]. No `anorak` entry; `qcom,anorak` is our root compatible (`v27.dts:6`) [M-static] | back-port possible only as new kernel code (§4) |
| **C. postmarketOS / Alpine** | packages linux-msm's | pmOS `pd-mapper` 1.0-r1 (BSD-3-Clause, maintainer Luca Weiss, aarch64 build 2025-12-03), plus `pd-mapper-openrc` [M-static, pkgs.postmarketos.org]. Alpine edge has `qrtr` 1.2-r1 (BSD-3-Clause, 2026-01-15) but no `pd-mapper` [M-static]. pmaports #2936 discusses dropping the daemon on 6.11+ kernels [M-static] | same as A | confirms A is the community standard; nothing new to reuse |
| **D. Linaro / linux-msm qrtr tools** | BSD-3-Clause (Sony Mobile 2015) [M-static] | active (CI changes 2026-09-15) [M-static, GitHub API] | n/a: `libqrtr`, `qrtr-ns`, `qrtr-lookup`, `qrtr-cfg` (meson, Android.bp) | `libqrtr` needed by A. `qrtr-ns` **not** needed (in-kernel ns, §2.3). `qrtr-lookup` is a useful read-only diagnostic (lists published services) |
| **E. Valve SteamOS (Frame)** | n/a | n/a | in-kernel mapper: `CONFIG_QCOM_PD_MAPPER=y`, `CONFIG_QCOM_PDR_HELPERS=y`, `CONFIG_QCOM_PMIC_GLINK=y`, `CONFIG_QRTR=y` in `config-6.18.0-gfbdbca41fd45` [M-static]; no daemon in the rootfs (no `pd-mapper`/`qrtr` files or units found) [M-static] | shows the target model; does not run on 5.10 |
| **F. Meta's own `pd-mapper`** | proprietary | n/a | `.jsn` | **excluded**: needs Android bionic and Qualcomm QMI libraries; TS images carry no Meta userspace (D-T0-4) |
| **G. our own daemon** | ours (Apache-2.0) | ours | our choice | possible, but it re-does A for no gain; A is licence-audited FOSS (D6) |
| **H. no mapper** | — | — | — | works on the APPS side if O-PD1 resolves well, but loses PD down/up visibility and departs from stock (§5.2) |

### 3.1 Option A in detail

- **Build inputs** [M-static, upstream `Makefile`]: `pd-mapper.c`, `assoc.c`, `json.c` (its own
  small JSON parser), `servreg_loc.c`, `lzma_decomp.c`; links `-lqrtr -llzma`. A systemd unit
  template (`Restart=always`, no ordering lines; the `qrtr-ns` dependency was dropped in 2024).
- **Behaviour** [M-static, `pd-mapper.c` master]:
  - runs in the foreground, never forks, never drops privileges;
  - **exits with status 1 if it finds no maps**, e.g. when no remoteproc exists yet. It must start
    **after** `qcom_q6v5_pas` has registered the ADSP remoteproc;
  - answers only "get domain list" (no paging) and only logs PD-failure-reason messages.
- **Paths on our image:** the ADSP remoteproc's `firmware` is `adsp.mdt` (no directory;
  `qcom_q6v5_pas.c:967-980`, FIRMWARE.md §2) [M-static], so the daemon scans the firmware root.
  In TS images `firmware_class.path` is unset and the firmware is staged in `/lib/firmware`
  (FIRMWARE.md §2), so the `.jsn` files go there too [D].
- **Upstream defects** [M-static, `pd-mapper.c` master, our reading and the rev 0 review]:
  - the remoteproc `firmware`-attribute read can write one byte past its buffer when the value
    fills it;
  - a read-error path lacks a signed length check (to be reported upstream) [M-static, review];
  - the return value of the JSON enumeration is ignored.
  The first is not reachable with our 8-byte `adsp.mdt` [D]. **Fix in our build:** a small patch of our own, written clean-room
  from these facts (signed length check and bound before the terminator write), carried in our
  tree with the pinned source, and offered upstream as a bug report.
- **`liblzma`:** needed only for `.jsn.xz`. Pin an xz-utils release outside the compromised
  5.6.0/5.6.1 (CVE-2024-3094) and record its licence (liblzma is 0BSD from 5.6 on) [C: from
  general knowledge, to be verified at pin time]. Whether a build without `lzma_decomp.c` is
  supported upstream is [O-PD5].
- **Licences and notices to carry** [M-static, upstream source headers, per the rev 0 review]:
  - `pd-mapper`: BSD-3-Clause (Linaro 2018, Bjorn Andersson 2016); its `lzma_decomp.c` is
    **public domain**;
  - `libqrtr`: BSD-3-Clause (Sony Mobile 2015), plus **additional notices in `lib/qmi.c`**
    (The Linux Foundation 2017; Linaro 2017-18);
  - `liblzma`: per the pinned release [C].
  Obligations [D, from the BSD-3-Clause terms]: ship every copyright notice, licence text and
  disclaimer with any binary; never use the authors' or contributors' names to endorse or promote
  FrameShift.
- **C library:** link statically against **musl (MIT)**, pinned. A static glibc build would bring
  LGPL relinking duties [D]. The musl licence notice ships with the binary as well.

---

## 4. Back-port of the in-kernel mapper vs a userspace daemon

**What a back-port would need (v2.7, 5.10)** [M-static unless tagged]:
- The QMI message tables exist: `pdr_internal.h` defines the locator service (0x40), the
  get-domain-list request/response element tables and `SERVREG_DOMAIN_LIST_LENGTH` 32.
- **The auxiliary bus does not exist** in this tree (`drivers/base/auxiliary.c` absent), so the
  current upstream form cannot be used as is. The 6.11 form hooks the mapper into
  `qcom_q6v5_pas`/`_adsp`/`_mss`/`_wcss` start and stop (LKML v9 5/5), but **`qcom_q6v5_pas` is a
  stock vendor module we do not rebuild** (FS-R-001 Stage 1; T3b closure pins its hash).
- So the only workable shape is a **stand-alone out-of-tree module** that publishes the locator at
  `module_init`, with its own `anorak` table (the five domains of §2.1), loaded before the ADSP is
  started. `CONFIG_MODVERSIONS=y`, no module signing set in the stock config, and we build the
  K1a/K1g kernel ourselves, so loading it is technically possible [D].

**Comparison**

| | A: userspace daemon (linux-msm) | B': out-of-tree kernel module |
|---|---|---|
| new code we own | none (pinned upstream build) + our `.jsn` data | a GPL-2.0 kernel module derived from upstream (attribution needed) |
| review class | new userspace component in TS/R-1 images (D6 FOSS) | **new kernel code** next to fs-blkguard: kgate, Chair review, H-1 position, every kernel rebuild |
| ordering | needs the remoteproc to exist first; start before or after the ADSP | publishes at load; can precede everything |
| failure | process exit → restartable by our init | a bug runs in the kernel (oops/panic) |
| data | `.jsn` files: inspectable, swappable per device (Quest 3S, Quest 2/Pro on other trees) | compiled table: rebuild per device |
| upstream lessons | userspace starts "late", which hid the glink intent race (§6.2) | starting early exposed that race upstream (§6.2); our downstream glink is not the fixed mainline one [O-PD3] |
| fits the "stock kernel + stock vendor modules" stage | yes | no |

**Verdict [D]:** the daemon is the polished choice for the 5.10 product. It is small, upstream,
data-driven, restartable and outside the kernel review perimeter. The in-kernel mapper is the right
answer only on a mainline-based kernel, where `anorak` would get a table entry like `sm8550`'s
without the modem domain. It stays on the mainline-in-parallel track (FS-R-001), not on T3b.

---

## 5. Interactions with the safety stack

### 5.1 Thermal service, ADSP liveness and the battery class
- The battery class (thermal-control-design §6) faults on: ADSP remoteproc not `running`; `temp`,
  `voltage_now`, `current_now` all unchanged > 60 s while awake; any psy read error. A fault is
  SEVERE at once, SHUTDOWN after 120 s [M-static].
- **The mapper slows fault detection unless we add a rule** (rev 0 review, safety) [D]:
  - **With the mapper**, a `charger_pd` restart inside a running ADSP produces a PDR DOWN
    indication. The kernel logs it (`pr_info`: "PDR: Indication received from …, state: …",
    `pdr_interface.c:351`) and `pmic_glink` tells the battery driver DOWN. From then on, reads
    return **cached values with no error** (`battery_chg_write` returns 0 while DOWN,
    `qti_battery_charger.c:474-479`) [M-static]. Only the staleness rule catches it: up to 60 s
    stale, then 120 s to SHUTDOWN.
  - **Without the mapper**, the same restart is invisible to the PDR layer. But if the rpmsg
    channel closes, `pmic_glink_write()` returns `-ENOTCONN` (`pmic_glink.c:240-254, 462-477`),
    the read fails, and that is an **immediate** battery-class fault [M-static; D].
  - So, with no extra rule, adding the mapper can turn an immediate fault into a delayed one.
- **Rule (proposed now, Chair item C-PD4):** from T3b on, a kernel line "PDR: Indication received
  from msm/adsp/charger_pd" with a DOWN state is an **immediate battery-class SEVERE** (then
  SHUTDOWN after 120 s, as for any battery-class fault). This restores at least the no-mapper
  detection time. `fs-thermald` reads it from the kernel log (read-only). Every PDR indication line
  is also logged.
- **Mapper-process death after start** stays a **WARN** plus a restart by our init: existing PDR
  registrations stay, only new lookups fail [C, from the PDR flow]. Killing the mapper sends no
  indication to anyone [C, from the PDR flow: the locator is not a notifier], so its death cannot
  trigger the DOWN rule.

### 5.2 Device-health loader rules (H-1, H-2)
- H-1 puts "the ADSP battery chain" in **phase S**: loaded first, plainly, each module with its own
  deadline, never skipped (device-health-design H-1.1) [M-static].
- The mapper is a process, not a module, but it sits **inside** that sequence: after `qrtr`,
  `qrtr-smd`, `pdr_interface`, `pmic_glink` and `qcom_q6v5_pas` are loaded (the remoteproc must
  exist, §3.1), and before or right after the ADSP `start` write (§7.1) [D].
- Its start needs its own deadline (proposed 5 s for "service 64 published", checked read-only with
  `qrtr-lookup`; debugfs is not used) and a recorded outcome (`PDMAP_OK` / `PDMAP_FAIL <reason>`),
  in the style of H-1.4 [C, proposal].
- **Classification:** a failure to start or publish the mapper does not block the APPS-side battery
  path on this kernel (§2.4), so it is an **F-class WARN** for T3b, not an S fault, pending O-PD1
  [D]. If O-PD1 shows that `charger_pd` needs the mapper, it becomes S-class [D]. This is separate
  from the `charger_pd` DOWN rule in §5.1, which is a battery-class SEVERE from T3b on.
- H-2 (no firmware stall) is unaffected: the daemon reads files directly and never uses the
  kernel firmware loader [M-static, upstream source].

### 5.3 fs-blkguard
- The daemon opens only `/sys/class/remoteproc/*/firmware`,
  `/sys/module/firmware_class/parameters/path` and the firmware directory, and it writes nothing
  [M-static, upstream source]. In TS images the firmware directory is RAM-backed initramfs [D].
  **No block-device access, so nothing for fs-blkguard to refuse** [D].
- The ADSP itself gains no storage path through the mapper. Its storage path would be the remote
  file server (§5.6), which we do not run [D].

### 5.4 The PDR panic path (new with the mapper)
- With a mapper, `pmic_glink` registers for `charger_pd` indications, so the 9 s
  callback-timeout panic in §2.3 becomes **reachable**. Without a mapper it is not, because no
  registration exists [D].
- **How long the DOWN callback takes is not established** [C]; T3b must time it. The 9 s timer
  covers `pmic_glink_notify_clients` for **all** clients, and K1a loads `ucsi_glink` and
  `altmode-glink` as well as the battery driver [M-static, rev 0 review]:
  - UCSI: the DOWN path runs `ucsi_unregister` → `cancel_work_sync` (`ucsi_glink.c:607-630`,
    `ucsi.c:1441-1461`). The work it waits for can sit in reset loops of up to
    `UCSI_TIMEOUT_MS` = 10 s each (`ucsi.c:28, 914, 936`) [M-static]. That alone can exceed 9 s [D].
  - Battery: `battery_chg_state_cb` takes `state_sem` for writing (`qti_battery_charger.c:633`).
    Each reader holds `state_sem` across a firmware wait of up to `BC_WAIT_TIME_MS` = 1 s, and the
    readers are serialised by `rw_lock` (`:57, 474-515`) [M-static]. With N readers queued, the
    callback can wait about N × 1 s [D].
- **What a panic does here (corrected in rev 1).** The stock cmdline sets
  `qcom_dload_mode.download_mode=1` (FS-A-005:181), and `qcom-dload-mode` is in K1a
  (`modules.load.v66:44`). Our boots keep that cmdline, so **a panic before K5 (download_mode=0)
  enters Qualcomm crash-dump mode: dark, USB `05c6:900e`** (FS-A-004:85, :214). It does **not**
  reboot. `PANIC_TIMEOUT=-1` applies only once download mode is off [D]. Dump mode leaves the SoC
  powered with no thermal service running; recovery is the PM holding power (FS-A-004 §4) [M-static].
- **When the panic is suppressed** [M-static]: only when `system_state` is restart, power-off or
  halt, **or** when `qcom_device_shutdown_in_progress` is set (`pdr_interface.c:280-284`). That flag
  is written through `/sys/kernel/qcom_rproc/shutdown_in_progress` (write-only, 0220;
  `qcom_common.c:102-124`, created at `:806`). The same flag also suppresses the "remoteproc failed
  to recover" panic (`qcom_common.c:783-790`).
  - **Consequence:** during `fs-thermald`'s orderly SHUTDOWN, until `reboot(2)` sets
    `system_state`, a `charger_pd` DOWN with a slow callback can turn a thermal power-off into dump
    mode [D].
  - **Mitigation (a new write: needs its own approval):** the shutdown path writes `1` to
    `/sys/kernel/qcom_rproc/shutdown_in_progress`. This is a volatile kernel flag, but it is a new
    write class and goes to the Chair (C-PD3) and the PM (PD-M5).
  - **What the flag does and does not do (correction, FS-R-014 §9):** it **suppresses** failure
    handling only: the PDR-timeout panic and the "remoteproc failed to recover" panic are skipped
    while it is set [M-static, lines above]. It does not shut down the ADSP or the headset, and it
    does not stop any ADSP failure from happening. Setting it also hides an ADSP failure that
    would otherwise have been handled. So it must not be applied earlier than needed: the shutdown
    sequence keeps battery and thermal handling running until the actual shutdown, and the package
    states and justifies the exact point where the suppression is applied (rev 1 said "as its
    **first** step"; that is now a proposal to be justified, not a given).
- **Chair item C-PD3** is therefore conditional, and the two routes **are not equivalent**
  (correction, FS-R-014 §9):
  - **K5 (download_mode=0)** addresses the dump-mode consequence only. The PDR-callback panic path
    stays; after K5 a panic takes the kernel's panic behaviour (`PANIC_TIMEOUT=-1`: an immediate
    reboot is the expected outcome [D, config only; not measured]) instead of dump mode.
  - **`QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`** (a config change: new kernel, kgate) removes that
    particular panic path. What then happens after a callback timeout is the driver's non-panic
    path [O, to be stated from source in the package].
  - A future package may choose either route only with its actual failure behaviour stated. In
    either case the `shutdown_in_progress` write is a separate, justified step (above).

### 5.5 Charging (§6A, FS-R-012/013)
- The mapper does not start the ADSP and writes no charger setting. JEITA charging control stays in
  ADSP firmware (FIRMWARE.md §2) [M-static]. It changes **what the kernel learns** about
  `charger_pd`, not what the charger does [D].

### 5.6 DSP-serving file and RPC daemons (`/persist`): keep out
- Stock pairs the mapper with `tftp_server`, which serves the ADSP's remote files from
  `/mnt/vendor/persist/rfs/…` (§2.2) [M-static]. The open equivalents are linux-msm `tqftpserv`
  and `rmtfs`; Quest1-SteamOS used `rmt_storage` (§6.4) [C].
- Stock also runs **FastRPC daemons** that serve DSP requests from the application side
  [M-static, `vendor.img`]:
  - `vendor.adsprpcd` (`/etc/init/vendor.qti.adsprpc-guestos-service.rc:34`);
  - `vendor.audioadsprpcd_audiopd` (`/etc/init/vendor.qti.audio-adsprpc-service.rc:30`);
  - `vendor.cdsprpcd` (`/etc/init/vendor.qti.cdsprpc-service.rc:34`).
- **Rule (proposed, Chair item C-PD2): no DSP-serving file or RPC daemon in any image:**
  `tftp_server`, `tqftpserv`, `rmtfs`, `rmt_storage`, or any `*rpcd`/FastRPC daemon (`adsprpcd`,
  `audioadsprpcd`, `cdsprpcd`). They would give a DSP a path to files, including `/persist`, which
  we never touch.
- **O-PD2, what the ADSP does when such requests go unanswered:** unknown; T3b logs it. **Worst
  case** [D]: an ADSP fatal error, then a failed recovery, then the "remoteproc failed to recover"
  panic (`qcom_common.c:783-790`), which before K5 means dump mode (§5.4). T3b treats any ADSP
  crash as the battery-class fault it already is (ADSP not `running`).

---

## 6. Prior art

### 6.1 ArmadaVR (docs/research/armadavr.md; `docs/quest-early-boot.md` read 2026-10-16)
- Same vendor data: their reference vendor image hash is `e251197f…8a38cc`, the one we read
  [M-static, their doc]. They use the ADSP `.jsn` files, adding `battmgr.jsn` (`charger_pd`,
  instance 74) in their maintained bundle [C, their doc].
- Ordering: wait for QRTR service 64 v1 instance 1, then write `boot_adsp`; readiness = ADSP
  `running` + `PMIC_RTR_ADSP_APPS` bound + UCSI port + DWC3 `host`, each capped at 12 s [C, their
  doc]. Their doc does not say why the mapper must come first, and it does not name the mapper
  implementation [M-static, their doc].
- systemd lessons: `SurviveFinalKillSignal=yes` (because `IgnoreOnIsolate` alone let the
  initrd→root switch kill it) and `FailureAction=poweroff` [C, QEMU only]. **For us:** these apply
  only if our initramfs ran systemd. Ours is our own PID 1, which `exec`s Valve's systemd for R-1,
  so a process it started survives the switch. systemd's final kill at shutdown only spares
  processes whose `argv[0]` starts with `@`. Killing the mapper at shutdown is harmless: the
  locator is not a notifier, so its death sends no indication and cannot start the PDR timer [C,
  from the PDR flow]. (The PDR panic itself is covered in §5.4.)
- Status: QEMU only, never on a headset; **no licence**: ideas only [M-static, armadavr.md].

### 6.2 Upstream experience with the in-kernel mapper
- Johan Hovold (Oct 2024) proposed "mark pd-mapper as broken": on x1e80100, pmic_glink clients
  (altmode, UCSI, battmgr) failed on about 41 % of boots with `-ECANCELED`, and an audio PDR lookup
  timed out sometimes [M-static, LKML 2410.1/04020]. Dmitry Baryshkov's reply: the userspace
  daemon usually starts much later, which hid the problem [M-static, LKML 2410.1/04840 and the
  X1E thread].
- Fix: Bjorn Andersson's "rpmsg: glink: Handle rejected intent request better" and "soc: qcom:
  pmic_glink: Handle GLINK intent allocation rejections" (v2, Oct 2024; reported commits
  `a387e73fedd6`, `f8c879192465`). Firmware that does not support dynamic intent allocation
  rejected sends made before its receive buffers existed; the fix retries for up to 5 s
  [M-static, LKML/lore summaries].
- **Lesson for us [D]:** starting the mapper **early** can make the ADSP-side clients come up
  sooner and expose send-before-ready races. Our downstream glink and pmic_glink are not the fixed
  mainline code [O-PD3]. That argues for mirroring Meta's order in T3b (§7.1).

### 6.3 Valve
- Frame: in-kernel mapper built in, `.jsn` data shipped for SM8650, no daemon (§3 row E)
  [M-static]. **Consequence for R-1:** Valve's userspace will not start a mapper on our 5.10
  kernel. Our layer must supply it from the initramfs, and Valve's SM8650 `.jsn` files must not be
  the ones it reads (it reads ours, once, at start, before the switch) [D].

### 6.4 Other Quest community work (community-quest-repos-2.md:614-615)
- QK (Quest Pro/Quest 2, 4.19): runs Meta's `pd_mapper` and `per_mgr` under Android, holds the ADSP
  with a module [M-static, our earlier note]. Quest1-SteamOS's modem route runs `qrtr-ns`,
  `pd-mapper`, `rmt_storage`, `tftp_server` and mounts `/persist` read-write for the modem's RFS
  [M-static, our earlier note]. That is exactly the `/persist` exposure §5.6 rules out.

---

## 7. Where it fits

### 7.1 T3b (battery path) — proposed integration

**Prerequisite (§5.4, corrected rev 1.1):** one of the two non-equivalent routes, K5
(download_mode=0) or a kernel with `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`, chosen with its actual
failure behaviour stated; and a shutdown sequence whose `shutdown_in_progress` write point is
justified and keeps battery/thermal handling until the actual shutdown (PD-M5, C-PD3). No mapper
run before that.

**Separate claims (FS-R-014 §9).** The run records three things separately and never infers one
from another: (1) **mapper publication** (service 64 published, step 4); (2) **PD notification**
(the PDR resolution and any UP/DOWN indication for `charger_pd`); (3) **battery-data freshness**
(psy `temp`/`voltage_now`/`current_now` moving and agreeing with Android, step 5). An UP
notification alone does not validate fresh battery readings.

**Step 0, read-only, on stock Android (a T0 follow-up item):** from Android's `dmesg` and
`logcat` on the same unit, read the timestamps of: the `vendor.pd_mapper` start, the
`PMIC_RTR_ADSP_APPS` channel probe, the battery psy registration and any "PDR: Indication" line.
This measures the stock gap that rev 0 wrongly treated as known. Read-only commands, listed inline
for the PM when the item is scheduled.

**Run A, ADSP first (Meta's order).** Order inside phase S (H-1), each step bounded and logged:
1. Load `qrtr`, `qrtr-smd`, `qmi_helpers`, `pdr_interface`, `pmic_glink`,
   `qti_battery_charger_main` and the `qcom_q6v5_pas` closure (the T0 package notes (private)). The remoteproc
   exists, `auto_boot` is false, so nothing runs yet [M-static, FIRMWARE.md §2].
2. Write `start` to the ADSP remoteproc `state` once (as designed in FIRMWARE.md §2).
3. **Observe without the mapper** for a bounded window (proposed 12 s, ArmadaVR's cap): ADSP
   `running`; `PMIC_RTR_ADSP_APPS` bound; battery psy present and moving. How this compares with
   stock depends on step 0 (the stock gap is unmeasured) [O].
4. Start `pd-mapper` (our `.jsn` files in `/lib/firmware`). Check that service 64 is published
   within 5 s (read-only `qrtr-lookup`), then log the PDR resolution of `charger_pd`.
5. Continue T3b as designed (psy vs Android ±2 °C, staleness, `batt-virt`/`surf-virt`).

**Run B, mapper first (control, same unit, separate boot).** Steps 1, 4, 2, then 3's
observations, then 5. A one-directional test cannot tell "the firmware needs the mapper" from
"the firmware is just slow"; the pair can [D].

**Both runs:** time the PDR DOWN callback if one occurs (§5.4); the §5.1 rule applies (a
`charger_pd` DOWN line is an immediate battery-class SEVERE).

**Reading O-PD1:** psy present in run A step 3 and in run B → the firmware does not need the mapper
before boot. Psy absent in A step 3, present after A step 4 and present in B → it needs it, and
the mapper becomes S-class and moves before the ADSP start for T4 onward. Any other pattern →
REVIEW. Mapper not published in 5 s → WARN `PDMAP_FAIL`, the run continues.

Package changes: `FIRMWARE.md` §2 open item closed by reference to this note;
`firmware-manifest.tsv` row `battmgr.jsn` replaced by our four `.jsn` data files (hash-pinned) and
the pinned daemon binary; the module closure is unchanged.

### 7.2 R-1 ("SteamOS boots")
- The mapper starts in our initramfs exactly as in T3b and keeps running after we `exec` Valve's
  systemd. Our init restarts it if it dies before the switch; after the switch, nothing restarts it
  [D]. **R-1 composition item:** decide whether a dead mapper after the switch needs a respawn path
  (a tiny supervisor kept from the initramfs) or only the WARN [O-PD4].
- **Respawn trap:** a mapper restarted after `switch_root` resolves its directory against the new
  root's `/lib/firmware`, where our `.jsn` files are not. It finds no maps, exits with status 1
  (§3.1), and a naive supervisor restarts it in a loop [D]. Any respawn must point at our data
  (a fixed data path in our own build patch, or our files placed where the daemon looks by our
  layer; **not** by writing the kernel's `firmware_class` path, which would also move firmware
  loading) and must back off after repeated exits.
- No Valve unit is needed or changed; Valve's SM8650 `.jsn` files are ignored (§6.3).

### 7.3 Other devices (lockstep)
- Quest 3S (same kernel tree) needs its own `.jsn` check [O]. Quest 2 / Quest Pro (4.19, PIL/SSR)
  use a different stack: a separate note, not covered here [D].

---

## 8. Decisions

### PM items (recommendations in bold)
- **PD-M1 Choose the mapper:** A linux-msm `pd-mapper` (userspace) / B' out-of-tree kernel module /
  G our own daemon. **Recommend A** (§1, §4).
- **PD-M2 Data files:** our own `.jsn` files written from the §2.1 facts (distributable) vs Meta's
  vendor files staged privately. **Recommend our own**, ADSP domains only (`root_pd`, `sensor_pd`,
  `audio_pd` + `avs/audio`, `charger_pd`); `cdsp` only once the CDSP is ever started.
- **PD-M3 Source downloads:** building A needs pinned source archives of linux-msm `pd-mapper`
  (v1.1 `5ecd2fe926ac`), linux-msm `qrtr` (a pinned 1.2-era commit) and xz-utils (a pinned post-5.6.1
  release), plus a static aarch64 build. **Approve the downloads when the T3b package is built**
  (filenames, sources and sizes listed at that time).
- **PD-M4 T3b order and the O-PD1 test:** step 0 (read-only stock `dmesg`/`logcat` timestamps, as
  a T0 follow-up), then run A (ADSP first, Meta's order) **and** run B (mapper first, control) on
  the same unit. **Recommend all three**; A is the default order afterwards unless the result says
  otherwise (§6.2, §7.1).
- **PD-M5 Panic prerequisite:** no mapper run until **K5 (download_mode=0)** is in place **or** our
  kernel has `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`; plus a new volatile write,
  `/sys/kernel/qcom_rproc/shutdown_in_progress` = 1, in our shutdown path at a justified point.
  **Recommend K5 first** (no new kernel), stating that a PDR-callback timeout then still panics and
  reboots [D], and approve the shutdown-flag write for review (§5.4).
  **Corrected rev 1.1 (FS-R-014 §9):** the two routes are not equivalent. K5 leaves the panic path
  in place (only the dump-mode consequence changes); `=n` removes it. If K5 is chosen, the package
  states that a PDR-callback timeout still panics. The flag only suppresses failure handling;
  it does not shut anything down, and battery/thermal handling must continue until the actual
  shutdown.

### Chair items
- **C-PD1** Admission of a third-party userspace daemon (BSD-3-Clause, D6 FOSS) into TS images and
  the R-1 composition: pinned source, our clean-room fix for the `size_t` read-error defect (§3.1),
  a reproducible static build against pinned **musl (MIT)** (no static glibc), hash pins, and the
  licence obligations: every notice and disclaimer shipped (pd-mapper BSD-3; `lzma_decomp.c` public
  domain; libqrtr BSD-3 plus the `lib/qmi.c` notices; liblzma; musl), and no endorsement use of
  the authors' names (§3.1).
- **C-PD2** A standing rule: no DSP-serving file or RPC daemon in any image (`tftp_server`,
  `tqftpserv`, `rmtfs`, `rmt_storage`, `adsprpcd`, `audioadsprpcd`, `cdsprpcd`, any FastRPC
  daemon) (§5.6).
- **C-PD3** The PDR-callback panic becomes reachable with the mapper, and before K5 it lands in
  crash-dump mode, not a reboot (§5.4). **Recommend:** allow the mapper only with K5 in place or
  `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`, and admit the new write
  `/sys/kernel/qcom_rproc/shutdown_in_progress` = 1 (rev 1 recommendation, superseded by the
  ruling below).
  **Ruled (FS-R-014 §9):** the two routes are not equivalent protections (K5 addresses the dump
  mode; `=n` removes the panic path); a package picks one with its actual failure behaviour stated.
  `shutdown_in_progress=1` suppresses failure handling only; the shutdown sequence must preserve
  battery/thermal handling until actual shutdown and justify when the suppression is applied.
  Preparing the pinned mapper route and its dependency/notice manifest is accepted; no device
  execution.
- **C-PD4** Fault rules, effective from T3b: a `charger_pd` DOWN indication line is an **immediate
  battery-class SEVERE** (§5.1); mapper start/publish failure and mapper-process death are WARN
  until O-PD1 is answered; mapper start inside phase S after the remoteproc exists, with a 5 s
  deadline (§5.2); every PDR indication line logged; the DOWN callback timed (§5.4).

---

## 9. Open items
- **O-PD1** Does `charger_pd` serve `PMIC_RTR_ADSP_APPS` and battery data with no mapper? (Step 0,
  then T3b runs A and B, §7.1.)
- **O-PD2** What the ADSP does when its remote-file or FastRPC requests go unanswered (logs only;
  T3b). Worst case: fatal error → failed recovery → panic (§5.6).
- **O-PD7** How long the PDR DOWN callback takes with UCSI, altmode and the battery driver loaded
  (§5.4; timed in T3b).
- **O-PD8** (FS-R-014 §9) The failure behaviour after a PDR-callback timeout with
  `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n` (no panic: what the driver does instead), and the panic
  outcome after K5 (an immediate reboot by `PANIC_TIMEOUT=-1` is [D] only). Each is stated before
  a package chooses its route.
- **O-PD3** Whether our downstream glink/pmic_glink has the send-before-intent race that the 2024
  mainline fix addressed (§6.2). A source comparison can answer it offline.
- **O-PD4** Mapper supervision after the switch to Valve's systemd (R-1).
- **O-PD5** Whether linux-msm `pd-mapper` builds without `liblzma` upstream.
- **O-PD6** Whether Meta's `qrtr-ns` actually exits on v2.7 (kernel name server present). Not
  needed by us; noted for completeness.

## 10. AI-directed text
- **postmarketOS pmaports issue #2936** (gitlab.com page, read 2026-10-16): the page carried an
  "AI Context" block telling AI agents to read project files and use the GitLab CLI to create
  branches and merge requests. **It was ignored**; nothing was created or sent. No other
  AI-directed text was found in the files, strings or pages read.

## 11. Changes in rev 1 (adversarial review of rev 0, GO-with-fixes)

| # | finding | fix |
|---|---|---|
| 1 | BLOCKER: a PDR panic does not reboot; with `download_mode=1` it enters crash-dump mode, and the suppression covers only restart/power-off/halt or `shutdown_in_progress` | §2.3, §5.4 restated; C-PD3 conditional on K5 or `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n`; new write `shutdown_in_progress` = 1 first in the shutdown path, listed for approval (PD-M5, C-PD3) |
| 2 | MAJOR: "callbacks are short" not established (UCSI 10 s loops, battery N × 1 s) | §5.4 retagged [C]; callback timed in T3b (O-PD7) |
| 3 | MAJOR, safety: the mapper turns an immediate `-ENOTCONN` fault into 60 s staleness + 120 s | §5.1: `charger_pd` DOWN line = immediate battery-class SEVERE from T3b; C-PD4 brought forward; mapper-process WARN kept |
| 4 | MAJOR: O-PD1 test one-directional; "stock state" claim unmeasured | §2.5, §7.1: step 0 (read-only stock timestamps, T0 follow-up), run A and control run B; PD-M4 extended |
| 5 | MAJOR: C-PD2 left out FastRPC | §5.6 rule widened with vendor rc lines; O-PD2 worst case stated |
| 6 | MINOR: licence notices and libc | §3.1, C-PD1: notices listed, obligations, musl pinned |
| 7 | MINOR: code facts | §3.1 `size_t` defect + our clean-room fix; §6.1 mapper kill sends no indication; §7.2 respawn trap |
| 8 | completeness | PM items PD-M4/PD-M5; Chair items C-PD1/C-PD4; AI-text note kept (§10) |

## 12. Web sources (read 2026-10-16)
- https://github.com/linux-msm/pd-mapper (page, API commits/tags, raw `pd-mapper.c`, `Makefile`,
  `pd-mapper.service.in`)
- https://github.com/linux-msm/qrtr (page, API commits)
- https://raw.githubusercontent.com/torvalds/linux/master/drivers/soc/qcom/qcom_pd_mapper.c
- https://lkml.iu.edu/hypermail/linux/kernel/2404.3/00377.html (v7 0/6 cover letter)
- https://lkml.iu.edu/hypermail/linux/kernel/2406.2/09264.html (v9 5/5 remoteproc hook)
- https://lkml.iu.edu/hypermail/linux/kernel/2410.1/04020.html and
  https://lkml.iu.edu/hypermail/linux/kernel/2410.1/04840.html ("mark pd-mapper as broken")
- https://lkml.rescloud.iu.edu/2410.2/08377.html and the lore v2 thread
  `20241023-pmic-glink-ecancelled-v2` (glink intent fix)
- https://pkgs.postmarketos.org/package/v25.12/postmarketos/aarch64/pd-mapper-openrc
- https://gitlab.com/postmarketOS/pmaports/-/issues/2936
- https://pkgs.alpinelinux.org/packages?name=qrtr*&branch=edge
- https://raw.githubusercontent.com/Producdevity/ArmadaVR/master/docs/quest-early-boot.md
