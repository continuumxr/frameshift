# Quest 2 port plan: v2.7 only (offline scoping)

> **Status update (2026-10-10):** the PM's unit is now **on v2.7**
> (`52242990024200150`, slot b). `ro.boot.vbmeta.digest` matches the
> computed `91b7f93d…`, and a read-only Q2-P1 baseline has been taken
> (`evidence/v27-baseline/`; J-75). The "on v59 today" text below is
> historical. The channel is `channel/` (rev 6, offline). The misc-capture
> route decision below is still open.
>
> **FS-R-011 §4 (2026-10-11, J-104):** the channel (`channel/`, binary
> `fs-rpcd` `da19367b…`) is **accepted for continued offline work**. The
> eventual candidate uses the UDC **`a600000.dwc3` explicitly**, with no
> silent fallback; a failed host send keeps "possibly partially sent"
> ambiguity (`Sent=false` is not proof nothing arrived); the FSB1 validator
> is still required beyond TCP framing. **No Quest 2 execution is
> concurred.** The Quest 2's own complete candidate, PID 1 deadline,
> effective firmware inputs, thermal/recovery procedure and timing budget
> still need review, and its **DEADLINE is not lengthened merely to fit the
> channel's preparation estimate**. FS-R-011 §6: on the v2.7 config the
> successful-no-op helper path supplies no dependable forced shutdown
> through the generic thermal core; this must inform the Quest 2 trial
> (`docs/research/thermal-control-design.md`).

**Status:** offline draft, revision 2, 2026-10-09. No adb or fastboot was
run, no device was touched and nothing was downloaded. Nothing here is
approved for a device. Every device step below is a **proposal**: it needs
its own relay, adversarial review, a Chair ruling and the PM's live go.

**Target (PM direction, J-66):** a Quest 2 that is **itself on v2.7**, a
genuine v2.7 system: build `52242990024200150`, Android 14, kernel
`4.19.325-cip128-st12-g49638c7a8637`.
- The PM's unit (`QUEST2UNIT`) is on v59 today. Its v59 evidence
  (adb baseline, `getvar all`) predates v2.7. Every unit fact must be read
  again on v2.7 (Q2-P1).
- `fastboot boot` only, never flashed by FrameShift (FS-R-006 §1, FS-R-007).
  Its stock firmware was later moved to Meta's official v2.7 by the PM (PM
  executive decision; J-74/J-75).

**Tags:** [M] hardware output · [M-static] named artifact · [D] derivation ·
[C] hypothesis · [O] open.

**Citation keys:**
- `config:N` = `firmware/quest2/v2.7-user_ota/kernel.config` (the v2.7
  IKCONFIG).
- `dtb1:N`, `dtbo0:N` = `analysis/v27-dt/v27-dtb1.dts` (kona v2.1 base) and
  `v27-dtbo0.dts` (Hollywood DVT overlay).
- Source `src/…` = the exact v2.7 kernel source, `6bde5fc06` "Oculus Quest 2
  kernel project build: 5224299.2420.150" (WSL `~/work/kgateq2/src`; it
  reproduces all 838 vendor CRCs, J-32).
- Gate build = `~/work/kgateq2/out`.

**Offline outputs:**
- `analysis/v27-dt/`: DT split and decompile (revision 1).
- `analysis/v27-stage1/` (new): `bootcheck.py`, `vbmeta.py` and
  `vendor-scan.sh`, their outputs (`boot-layout.txt`, `vbmeta.txt`,
  `vendor-scan.txt`) and `INDEX.txt` with the input hashes.
  - `vbmeta`, `vbmeta_system` and `vbmeta_vendor` were extracted from the
    OTA into `firmware/quest2/v2.7-user_ota/` (gitignored) with the stdlib
    payload extractor.

---

## 0. What changed from revision 1, and why

**Dropped:**
- v59 artifact acquisition (no longer needed; see Why).

**Why** (J-66):
- `fastboot boot` of a v2.7 image on a v59 unit replaces only the kernel,
  the boot DT and our ramdisk, and only for one boot. xbl, abl, tz, hyp,
  aop, the co-processor firmware, `dtbo` and the vendor partitions stay v59.
- That is a **hybrid**. A hybrid trial establishes only the hybrid
  (FS-R-006 §6).
- Targeting v59 instead would mean porting to a firmware too rare to
  matter (PM).
- On a genuine v2.7 unit, the artifacts we already hold *are* the unit's
  firmware, so no dump is needed to build stage 1 [D]. Binding the unit to
  them is a read-only check (§4, Q2-P1).

**The v2.7 artifacts are genuine** [M-static, `analysis/v27-stage1/vbmeta.txt`]:
- The OTA `vbmeta` hash descriptors for `boot` (34,205,696 B) and `dtbo`
  (1,181,768 B) **match** our `boot.img` and `dtbo.img`.
- The fingerprint is `oculus/hollywood/hollywood:14/UP1A.231005.007.A1/…`,
  `ota-type=AB`, a full payload (all partitions, including `xbl`, `abl` and
  `tz`).
- The avbtool-style vbmeta digest (main blob + `vbmeta_system` +
  `vbmeta_vendor`) is
  `91b7f93d686df2cae857548d2be9a2cbd80f8ad85897efc503330c65d50feb26`.
  It is our own implementation and **not yet cross-checked against
  `avbtool`** [D].

---

## 1. Stage-1 equivalent on v2.7

### 1.1 Image

`fastboot boot` of an image made from the stock v2.7 `boot.img` with
**only the ramdisk replaced** (mirrors `devices/quest3/stage1/build.sh`).

- **Layout** [M-static, `boot-layout.txt`]:
  - header **v2**, page 4096, header size 1660;
  - a raw arm64 `Image` (`ARMd` at 0x38), 30,369,808 B, sha256 `2dc11c0a…`;
  - a gzip ramdisk, 2,676,670 B;
  - a **DTB section** of 1,150,513 B: exactly 3 FDTs (dtb0–2), sha256
    `5c56f00a…`;
  - no second stage, no recovery dtbo;
  - an AVB hash footer at the partition end.
- **Builder rules (Quest 2 `build.sh`)** [D]:
  1. Refuse unless the input `boot.img` sha256 is `eebcbbef…` and the vbmeta
     boot descriptor matches.
  2. Carry the kernel bytes **and the DTB section** byte-identical, plus
     every header field.
  3. Replace the ramdisk.
  4. Verify by re-unpacking.
  5. The accepted header diff is **`ramdisk size` only**: v2 has no
     boot-signature section.
  6. The output has no AVB footer, as on the Quest 3 (requires an unlocked
     headset, assumed).
- **Ramdisk gzip, not lz4:** `CONFIG_RD_GZIP=y` (config:170),
  `# CONFIG_RD_LZ4 is not set` (config:175). The stock ramdisk starts
  `1f8b08` [M-static]. The Quest 3 `lz4 -l` step must not be used.
- **cmdline carried verbatim:** `softdog.soft_panic=1 …
  androidboot.hardware=hollywood`. It has no `console=` and no governor
  argument (`boot-header.txt`).
- **The stock ramdisk** is Android's first-stage init. It has 21 entries and
  **no `.ko`** (`boot-layout.txt`).
- `DEVTMPFS` is off (config:1388), so PID 1 runs `mknod` as on the Quest 3.
- **DT selection:**
  - ABL picks one of dtb0–2 by SoC revision and applies an overlay from
    `dtbo_a`. That is standard Qualcomm ABL behaviour [C].
  - On a v2.7 unit, `dtbo_a` is the genuine v2.7 dtbo, so there is no
    hybrid.
  - Which indices are chosen is [O] until Q2-P1 (`ro.boot.dtb_idx`,
    `ro.boot.dtbo_idx`). v59's choice (2/1) does not transfer, because the
    tables differ.

### 1.2 Modules: stage 1 loads none [D]

**Built in** [M-static]:

| function | evidence |
|---|---|
| USB gadget with NCM | config:3591, 3614-3615, 3625-3655 |
| dwc3-msm/DRD | config:3474-3484 |
| display (`techpack/display`, not `DRM_MSM`) | config:2956; gate build `out/techpack/display/msm/msm_drv.o` |
| fan `pwm-tach-fan` | config:4056 |
| thermal: governors, `QCOM_SPMI_TEMP_ALARM`, `QTI_BCL_PMIC5` | config:2520-2559 |
| charger and gauges | config:2345-2380 |
| watchdog | config:4442 |
| tri-LED | config:3727 |

**Vendor modules:** 28, in `vendor/lib/modules` (`vendor-scan.txt`). None
is needed for stage 1:
- **USB host class drivers:** `cdc_ether`, `cdc_subset`, `cdc_ncm`,
  `rndis_host`, `rtl8150`, `r8152`, `usbnet`, `mii`, `cdc-acm`,
  `usbserial`. These are host-side; `cdc-acm.ko` is **not** a gadget ACM.
- Others: `wlan`, `rdbg`, `llcc_perfmon`, `powerstate_mgr`.
- **The audio/ADSP set:** `adsp_loader`, `q6*`, `apr` and the other
  `*_dlkm` modules.

**Keep the firmware-timeout write.** `FW_LOADER_USER_HELPER_FALLBACK=y`
(config:1397-1398) makes every missing firmware request wait for
userspace.

### 1.3 USB channel: NCM gadget plus a fixed-verb TCP responder (recommended)

**Re-checked against the v2.7 config** [M-static]:
- `USB_CONFIGFS_NCM=y` (config:3630, with `NCM_DEBUG`).
- ACM, SERIAL, RNDIS and EEM are off (config:3627-3636). ECM is on, but
  Windows has no inbox ECM driver.
- Networking: `NET`, `PACKET`, `UNIX`, `INET` and `IPV6` (config:836, 844,
  846, 861, 901).
- `f_ncm` carries its own IAD (`src/drivers/usb/gadget/function/f_ncm.c:148-155`).
- Android itself defines `functions/ncm.0` on this firmware
  (`init.kona.usb.rc:57`).
- **USB role:** `dr_mode = "drd"` (`dtb1:12300`), with the in-kernel PD PHY
  as extcon (revision 1 §2). Device mode should follow PC VBUS without a
  remote processor [D]. The Quest 3 `mode=peripheral` write stays only as
  a guarded fallback.
- **UDC:** `a600000.dwc3` on v59 [M]. The v2.7 rc writes
  `${sys.usb.controller}`, whose value on v2.7 is [O] until Q2-P1.

**Windows** [M-static, `C:\Windows\INF` on the PM's PC]:
- `usbncm.inf` matches `USB\Class_02&SubClass_0d&Prot_00`.
- Binding to a Linux `f_ncm` is **untested** [O].

**Addressing** [D]: two options, both device-side only.

| option | device side | host side | notes |
|---|---|---|---|
| **A: IPv6 link-local (recommended)** | `ip link set usb0 up` only. The kernel derives `fe80::` (EUI-64) from the nonce-derived `dev_addr` | Computes the address from the nonce. Needs the adapter's scope id (ifIndex), which the collector finds anyway (§2) | No device daemon, no host configuration |
| **B: IPv4** | Static address on a /30 plus busybox `udhcpd` (applet present) giving one lease, with no router or DNS options | The host refuses if any other adapter has an address in that /30 | One more daemon parsing host packets |

**Responder:**
- The image runs `while :; do nc -l -p <port> -e /bin/fs-rpc; done`.
- The reviewed busybox (sha256 `c2f279d1…`) has `nc` and `udhcpd` in its
  applet table (`build/stage1/20261008T024856Z-112740d1bd6a4ecf/applets.txt:151,244`).
- Its `nc` option string `lp:w:i:f:e:` is present in the binary, so `-l`,
  `-p` and `-e` are compiled in [M-static]. Their runtime behaviour is [O]
  (qemu-user, Q2-P0).
- **Verbs:**
  - `VERIFY <hex>` → FSV1;
  - `ACK <hex>` → FSA1;
  - `STATUS` → FSS1;
  - stages 2a/3a only: `COLLECT <id>` → the FSB1 record of a step baked into
    the image (no free-form arguments), and `DONE` → `fs-done`.
  - Anything else → a new single-line `FSR1 error=refused END`, which needs
    review.

**Framing on TCP:**
- **Unchanged:** the FSV1/FSA1/FSS1 single-line records and the FSB1
  BEGIN/DATA/END records.
- **Per request:** one connection, one record, then close.
- **Validity:** decided only by the record's own END marker, counts and
  hashes. A connection closing early produces an incomplete record, which
  is rejected as before.
- **Byte handling:** TCP is 8-bit clean, so the FSB1 CRLF tolerances are
  unused but kept.

**D1-class safety** [D]:
- There is no tty, so there is no echo, prompt or line discipline.
- `fs-rpc` reads one line with `read -r -t` and a length cap. It matches
  the line with `case` against fixed patterns and validates hex before any
  use, with no `eval`. Host bytes never reach a shell parser.
- Each connection gets a fresh process.
- The host initiates every exchange. Outbound connections are not blocked
  by Windows Firewall.
- **Unchanged from the Quest 3:**
  - logging, recovery and the dead-man never use the socket;
  - the deadline is independent of the ACK;
  - the nonce/challenge proof is the same.

**Fallbacks:**
- ACM through our own `u_serial`/`usb_f_acm` modules (J-26): new kernel
  code, so its own review class.
- A read-only mass-storage LUN as a "black box": no live ACK.

### 1.4 PID 1 deltas from the Quest 3 design

1. **Governor `schedutil` at boot (PM-approved, J-66):**
   - The default is `performance` (config:546). `schedutil` is available
     (config:558), with `SCHED_WALT=y` (config:88).
   - 4.19 has **no `cpufreq.default_governor=` parameter** (only the weak
     `cpufreq_default_governor()`, `src/drivers/cpufreq/cpufreq.c:1057,1075`).
     So the interval from kernel start to PID 1 runs at maximum clocks.
     That is unavoidable without a rebuilt kernel [D].
   - PID 1's first action after mounting sysfs: write `schedutil` to every
     `cpufreq/policy*/scaling_governor` and read each one back.
   - A failure is logged and takes the `fail()` path [D].
2. **Reboot to the bootloader:**
   - `RESTART2 "bootloader"` reaches `msm-poweroff.c:511-514`: PON reason
     BOOTLOADER plus IMEM `0x77665500` at `restart_reason@65c`
     (`dtb1:2310-2313`).
   - `POWER_RESET_QCOM=y` (config:2326); `SYSCON_REBOOT_MODE` is off
     (config:2331).
   - `download_mode` defaults to 0 (`msm-poweroff.c:65`).
   - `PANIC_TIMEOUT=-1` (config:5608): a panic reboots at once and does not
     enter a dump mode.
   - So `fs-reboot` and `fs-reboot-final` are reusable unchanged
     [M-static source].
   - `getvar dload-mode-enabled` on v2.7 is [O].
3. **Hardware watchdog: built in, enabled, kernel-petted, nothing to pet**
   [M-static]:
   - **Enabled:** `QCOM_WATCHDOG_V2=y` (config:4442), on by default
     (`watchdog_v2.c:136-140`).
   - **Petting:** a kernel thread pets it every `pet-time`
     (`watchdog_v2.c:640-680, 940`). Userspace petting exists only with
     DT `qcom,userspace-watchdog` (`:812-818`), which is absent from dtb1
     and dtbo0.
   - **Timings:**
     - pet 9.36 s (`dtb1:1818`);
     - bark 11 s in the base (`dtb1:1817`), **overridden to 12 s by the DVT
       overlay** (`dtbo0:2737-2741`; revision 1 said 11 s);
     - bite = bark + 3 s (`watchdog_v2.c:928-929`).
   - **On a hang:** a kernel hang → bark → panic → reboot into **Android,
     slot a**, not the bootloader [D]. That improves on the Quest 3's F1.
   - **Rules:**
     - never write its sysfs `disable`;
     - never open `/dev/watchdog*`. The **softdog** is built in
       (config:2580) with `NOWAYOUT=y` (config:2573) and `soft_panic=1` on
       the cmdline. It is dormant until opened: start = ping on open, with
       no start-at-boot parameter in this tree (`softdog.c:37-54, 95-160`).
       Once opened it could never be stopped.
   - The v2.7 vendor rc never references a watchdog (`vendor-scan.txt`).
4. **Fan: stops on blank and waits for a panel.** This is fine for a
   headless stage 1, and recorded here:
   - `QCOM_PANEL_EVENT_NOTIFIER` is absent from the config, so probe defers
     until an active DRM panel exists (`pwm-tach-fan.c:1097-1107`).
   - `oculus,silent-rpm` is absent, so `silent_rpm` = 0. The fallback writes
     `rpm_per_sec` instead (`:1229-1231`). On blank the driver applies
     `min(rpm, 0)` (`:683, 725`).
   - In stage 1 the fan is therefore at its power-on default [O], never
     driver-controlled.
   - The image records the hwmon and cooling devices read-only and never
     infers the fan's state.
   - The hold stays short and bounded.
5. **Thermal zones exist in stage 1** (built in, unlike the Quest 3). The
   image records them read-only. The `user_space` zones do nothing.
6. **Charging:** stage 1 charges on PC VBUS under the in-kernel SMB5 JEITA
   bands (revision 1 §3.6) [D].
7. **LEDs:** the tri-LED nodes are labelled `red`, `green` and `blue`
   (`dtbo0:1597-1621`). The Quest 3 `led()` paths probably hold [C].
8. **pmsg:** ramoops with pmsg (`dtbo0:2642-2649`; config:5135-5136). The
   `/dev/pmsg0` log path is reusable [C].
9. **Timers:** `ERR_DELAY`, `ACK_WINDOW` and `DEADMAN` are set from the
   Quest 2's own thermal assessment. The Quest 3's 60/150/300 s are **not**
   inherited. *(FS-R-011 §4: the DEADLINE is never lengthened merely to fit
   the channel's preparation estimate.)*

### 1.5 Checklist status (`docs/DEVICE_PORT_CHECKLIST.md`): Quest 2 on v2.7

All entries are from v2.7 artifacts. Nothing is copied from the Quest 3 or
the Quest Pro.

| item | status |
|---|---|
| A1 | ✅ zones in DT: base 23 `step_wise`/25 `user_space`; DVT overlay 26 `single_step`/19 `user_space`/11 `step_wise`/7 `low_limits_cap` |
| A2/A4 | ⚠️ skin and battery shutdown are userspace-only (perf-envelope) |
| A3 | ✅ v2.7 `thermal_info_config.json` |
| A5 | ✅ temp-alarm built in; S2 kept (source) |
| A6 | ⚠️ `ADRENO_TZ`; autonomous policy [O] |
| A7 | ✅ none needed (built in) |
| B1–B3 | ✅ kernel curve 0–7000 rpm in 1000 steps (`dtbo0:3437-3453`) |
| B4 | ✅ stops on blank (silent 0) |
| B5 | ❌ power-on duty [O] |
| B6 | ❌ |
| B7 | ⚠️ the Quest 2's own policy, still to draft |
| C1/C2 | ✅ SMB5, FG gen4, `bq27z561` |
| C3 | ✅ JEITA (`dtbo0:7121-7137`) |
| C4/C5 | ⚠️ shutdown is userspace; BCL built in, levels [O] |
| C6 | ❌ |
| C7 | ⚠️ about 5 years old; inspection [O] |
| C8 | ✅ 3 profiles |
| D1/D2 | ✅ v59 unit [M]; v2.7 re-read in Q2-P1 |
| D3 | ✅ perf-envelope |
| D4 | ⚠️ `performance` default → PID 1 sets `schedutil` |
| D5 | ❌ |
| E1 | ⚠️ regulators seen; sequencing not reviewed |
| E2 | ⚠️ backlight max 1200; thermal dimming [O] |
| E3 | ✅ blank → fan 0 |
| E4 | ✅ 72/80/90/120 Hz |
| F1 | ✅ msm watchdog kernel-petted, bark 12 s (DVT); softdog dormant |
| F2 | ⚠️ `PANIC_TIMEOUT=-1`, `download_mode` 0; v2.7 getvar [O] |
| F3 | ⚠️ v59 table only; v2.7 slots and partitions [O] |
| F4 | ✅ v2.7 gate (J-32) |
| F5 | ⚠️ no ACM; NCM ✅; DEVTMPFS off |
| F6 | ⚠️ fastboot; Quest 2 button recovery to be documented |
| G1/G2 | ⚠️ ADSP for audio only [D]; firmware partitions [O] |
| G3 | ❌ |
| H1–H6 | ❌ |

---

## 2. Reuse vs Quest 2 versions

| component | verdict |
|---|---|
| `fs-supervise` (static glibc 2.43, ELF minimum kernel 3.7.0) | **Reuse the binary unchanged.** `close_range` is absent on 4.19, so its loop fallback runs (`fs-supervise.c:435-436`). Re-run the fixtures with `close_range` returning ENOSYS [D] |
| `fs-reboot-final`, `stage1/fs-reboot.c` | **Unchanged.** Syscalls only; the v2.7 target path is verified (§1.4.2) |
| FSB1 spec, `fsb1-enc.sh`, `fsb1.ps1` | **Unchanged.** Transport-independent |
| `OUTCOMES.md` classes, `DEADLINE.md`, `pid1-hold.sh`, `fs-done` | **Logic unchanged.** "TRANSPORT/SHELL FAILURE" becomes a transport failure. Timer values are Quest 2's own |
| `MISC-RULE` / `misc_rule.py` | **Structure reusable, V not:** see the misc notes below |
| stage-1 `init.sh`, `build.sh` | **Quest 2 versions:** NCM, net up, `fs-rpc`, governor, no modules; header v2, DTB carry, gzip, pinned input |
| host transport (`fs-collect.ps1`) | **Quest 2 version.** Add a `New-FsTcpTransport` with the same `ReadBytes`/`WriteBytes`/`NowMs`/`Idle`/`Dispose` interface. `Invoke-FsCollectRun` drives a shell prompt (`PromptWaitMs`, …), so it needs a per-verb request/response loop. The deadlines, decoder and `collect.json` are reused |
| observer gadget detection (`Get-FsGadget`) | **Quest 2 version.** The parent match `USB\VID_1D6B&PID_0104\FS-<nonce>` is unchanged. The child is a **net adapter** (UsbNcm) instead of a `PortName`, so the result is ifIndex plus link-local address instead of a COM port. Default serial `QUEST2UNIT` |
| before/after state captures (tooling withheld; method private) | **Quest 2 version** (see the notes below) |

**Misc rule on the Quest 2:**
- **Size matches:** `misc` is 0x100000 = 1,048,576 B (getvar, v59 table
  [M]), the size the rule requires.
- **C and the VAB message are expected:** AOSP `bootloader_message` (C), and
  the VAB message at 0x8000, since `ro.virtual_ab.enabled=true` on v2.7
  [M-static].
- **V (`0x1010–0x101b`) is a Quest 3 observation.** The Quest 2 needs its
  own stock control pair. Make V a per-device parameter [D].
- **The Quest 2 misc capture route needs a Chair decision before Q2-P2.**
  Without a capture, every pair is INCONCLUSIVE, and the rule then forbids
  further trials.

**Before/after state captures** (method private; the v2.7 partition table
is re-read in Q2-P1):
- The Quest 2 has `recovery_a/b` (64 MiB), and v2.7 vbmeta pins `recovery`.
- The Quest 2 has **no `vendor_boot`**.
- `xros_a` and `hyp_xros_a` exist in the v59 table, not in the v2.7 payload;
  their role is [O].

---

## 3. (Removed: v59 routes A/B; see §0.)

---

## 4. Phases

| phase | content | needs |
|---|---|---|
| **Q2-P0 offline (now)** | See the list below | nothing from the unit |
| **Q2-P1 unit on v2.7 + read-only baseline** | Read-only reads, listed as data: compare `ro.boot.vbmeta.digest` with `91b7f93d…` (binds the unit to this OTA); fingerprint, slot, `ro.boot.dtb_idx`/`dtbo_idx`, `sys.usb.controller`, `uname`, cpufreq policies/governors/frequencies, thermal zones, cooling devices, hwmon, LEDs, `dumpsys battery`. `getvar all` only inside a fastboot visit that already happens (J-36) | PM go |
| **Q2-P2 stage-1 proposal** | Stock v2.7 kernel+DTB + our initramfs via `fastboot boot`; NCM/TCP channel (accepted offline, FS-R-011 §4; UDC `a600000.dwc3` explicit); nonce/challenge; Quest 2 timers; `schedutil`; read-only fan, hwmon, zone and battery records; recovery doc (button combo, slot state); misc-capture route ruled | Q2-P1; relay, reviews, Chair, PM live |
| **Q2-P3 Valve-files test** | The stage-2a equivalent on 4.19.325: **own** pins, manifest, gates and outcome classes; `COLLECT` steps baked into the image. glibc vs 4.19 checked offline | Q2-P2 achieved; ruling |
| **Q2-P4 display test** | The stage-3a equivalent: panel from the v2.7 cmdline (Q2-P1); dual-DSI DSC. Panel registration **also brings up the fan driver**, so the Quest 2 thermal policy must be reviewed first | Q2-P3; thermal design |

**Q2-P0 work that can proceed immediately:**
1. `vbmeta`: cross-check the digest with `avbtool`.
2. Quest 2 `build.sh` and its negative tests.
3. `fs-rpc`, the NCM gadget script and the respawn loop, tested under
   qemu-user. This settles busybox `nc -l -e` and the link-local bring-up
   in a netns or WSL veth pair.
4. Host `New-FsTcpTransport` and the per-verb collector loop, with fixtures
   against a WSL loopback responder (IPv4 and `::1`).
5. `Get-FsGadget` with net-adapter fixtures.
6. Re-run the `fs-supervise` fixtures with `close_range` returning ENOSYS.
7. A Quest 2 before/after state-capture list (method private) and per-device misc V.
8. The Quest 2 thermal policy (B7, §6A.3).
9. Adversarial reviews.

---

## 5. Open items

1. Windows `UsbNcm` binding to a Linux `f_ncm` gadget; IPv6 link-local vs
   IPv4 in practice.
2. Busybox `nc -l -p -e` runtime behaviour (qemu-user).
3. The vbmeta digest vs `avbtool`.
4. v2.7 unit facts: DTB/DTBO indices, panel, `sys.usb.controller`,
   partition table, slot state, `dload-mode-enabled`.
5. The misc capture route (Chair).
6. Fan power-on duty; whether a panel registers headless.
7. Quest 2 button-combo recovery, to be documented.
8. Quest 2 stage timers from its own thermal assessment (not stretched to
   fit the channel, FS-R-011 §4).
9. The Quest 2 graceful thermal shutdown path: no dependable forced
   shutdown through the generic thermal core on the v2.7 config (FS-R-011
   §6); vendor notify paths and hardware over-temperature protection [O].
