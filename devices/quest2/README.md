# Meta Quest 2

*Edited for publication: names and links removed or paraphrased.*

**Secondary target, after the Quest 3 (PM device ordering, 2026-10-09; J-37).**

- **SoC:** XR2 (Gen 1), SM8250-class, Adreno 650.
- **CPU:** 1.80/2.42/2.84 GHz.
- **GPU:** bin 0, 587 MHz [M-static, Meta firmware tables].

**Status (2026-10-10):** the unit is **on v2.7** (slot b) (J-75; details
under "Unit status" below). The
USB channel (`channel/`) is built offline and has never run on a headset.
FS-R-010 §7 asks for the complete channel folder so the Chair can review the
implementation. It was supplied in the consolidated FS-A-011 (sent
2026-10-11, J-103), and **FS-R-011 §4 accepts continued offline work** (use
UDC `a600000.dwc3` explicitly, no fallback; "possibly partially sent" on a
failed host send; the FSB1 validator is still required). **No Quest 2
execution is concurred**; the Quest 2 DEADLINE is not lengthened to fit the
channel (J-104). No Quest 2 device trial is proposed yet. The Quest 2 still needs its own eventual
thermal and recovery assessment (FS-R-010 §7): the read-only baseline's
unreadable or literal-glob thermal output does not establish an absence of
thermal zones or cooling devices. On the v2.7 kernel config
(`CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0`) and the empty static
usermode-helper path, **the successful-no-op helper path supplies no dependable forced shutdown through the generic thermal core on this configuration** (FS-R-011 §6 wording; the Chair
checked the exact Quest 2 tree `6bde5fc0`) [M-static config; D]. Vendor notify
paths and hardware over-temperature protection remain unassessed [O], and the
current stage images load no thermal-zone drivers (J-96, J-99, J-104).

**Port target: v2.7 only (PM, 2026-10-09; JOURNAL J-66).** The port runs on
a Quest 2 that is itself on v2.7 (see "Unit status"). Plan:
`devices/quest2/PORT-PLAN.md`. PID 1 will set `schedutil` at boot (PM).

**PM's unit:** one **retail** Quest 2, on **v59** *(as of 2026-10-09; it
is now on v2.7)*. `fastboot boot`
only (flashing is done on Unit 2, a Quest 3); never flashed by FrameShift.
Its stock firmware was moved to Meta's official v2.7 by the PM (PM
executive decision). Its bootloader
`model-revision` reads `Hollywood (DVT)`, which is the production label on
this unit (PM).
- **adb baseline (2026-10-09, read-only)** [M]: serial `QUEST2UNIT`,
  `hollywood` Rev11; build `50670960048600150` (Android 12, SPL
  2023-08-05); kernel `4.19.157+`; **slot `_a`**. Evidence FS-A-006 (private review record).
- **Frequency tables on the unit match the static analysis** [M]: CPU
  1.8048/2.4192/2.8416 GHz, GPU Adreno 650v3 305–587 MHz.
- **`fastboot getvar all` (2026-10-09)** [M]:
  `hw-revision:20001`, `model-revision:Hollywood (DVT)` (meaning [O]);
  slot a successful, **slot b never marked successful** but still
  bootable with retries (not a known-good fallback; a slot-a failure could
  fall through to it);
  `super` 6 GiB. Evidence FS-A-006 (private review record).

**Unit status (2026-10-10, J-75):** on v2.7 (52242990024200150, slot b);
`ro.boot.vbmeta.digest` = `91b7f93d…`, matching the offline digest.
Evidence: `evidence/`.

**Build target: v2.7** (`q2_52242990024200150`, Android 14). Held at
`firmware/quest2/ota/`; boot, dtbo, vendor and IKCONFIG extracted to
`firmware/quest2/v2.7-user_ota/`.
- **Kernel:** `4.19.325-cip128-st12-g49638c7a8637` (clang r450784e).
- **Boot image:** header v2 (DTB in boot); no `vendor_boot` or
  `vendor_dlkm`.
- **Same userspace config gaps as the Quest 3;** **no USB ACM gadget** (NCM
  only).
- **USB channel (offline, rev 6):** `channel/` (README first). NCM gadget,
  IPv6 link-local from the nonce, static responder `fs-rpcd`, host
  transport `host/fs-transport-tcp.ps1`. Fixtures: device 37/37 sections,
  host 98/98, build gate 43/43, timing check consistent (planning cap
  T_max = ⌊DEADLINE − 194.075 s⌋, i.e. 104 s at 299 s; a planning result
  under stated assumptions, not a hardware timing guarantee; the real
  send-time runner guard is retained, FS-R-010 §7). Adversarially reviewed
  through rev 5; rev 6 (gate-only hardening) had a narrow review ("ready
  for the Chair as offline work", J-75). **Never run on a headset.**
  FS-R-010 §7 reviewed the design (suitable for continued offline
  preparation); the implementation review was incomplete because source
  and binary were not in the FS-A-010 bundle. The complete folder was in
  the consolidated FS-A-011 (sent 2026-10-11); **FS-R-011 §4: ACCEPT
  continued offline work**, no Quest 2 execution (`channel/README.md`).
  - The ELF "for GNU/Linux 3.7.0" annotation of `fs-rpcd` does not
    establish complete static-libc compatibility with the 4.19 kernel
    (FS-R-010 §7).
- **Kernel rebuild gate: PASSED** (JOURNAL J-32).
  - Exact public source `6bde5fc06b25` reproduces all 838 vendor-required
    CRCs.
  - Adding the ACM gadget, DEVTMPFS, FHANDLE, AUTOFS, BTRFS, USER_NS and
    PID_NS changes no existing CRC.
  - PM: add ACM in any kernel we build.
  - Possible no-rebuild route: `u_serial` + `usb_f_acm` built as modules
    [C].

**Safety:**
- **Never use the bootloader menu's "Switch Boot Slot" option.** It was added in Meta firmware of the v74–v83 era; per the PM it does nothing useful and can brick the unit [PM report, 2026-10-10, J-75].
- The stock kernel defaults to the **`performance`** governor.
- Skin and battery shutdown thresholds are enforced by userspace (thermal
  HAL); kernel DT mitigation is to be checked (FS-R-006 §4).
- The fan curve is in the kernel DT.
- The cells are about 5 years old.
- Checklist status: `docs/DEVICE_PORT_CHECKLIST.md`.

**Research:**
- `docs/research/quest2-v2.7-first-look.md`
- `docs/research/perf-envelope-quest1-2.md`

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
