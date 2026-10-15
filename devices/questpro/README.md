# Meta Quest Pro

**Tertiary target (PM ordering, 2026-10-09; J-37); offline/build only, in lockstep with the Quest 3/Quest 2 changes.** Re-added (2026-10-08) after being dropped
earlier.

- **SoC:** XR2+ Gen 1, Qualcomm `kona` family (SM8250-class).
- **Kernel:** the **same source tree as the Quest 2** (Meta's README lists
  `hollywood` and `seacliff`), built with its own config (127 lines
  differ).
- **No PM-owned unit.** A third-party tester may run reviewed images later
  (`docs/PROJECT_SETUP.md` §6A item 9).

**Firmware held:** v2.7 OTA `QPro_51503870024400340.zip` (Android 14,
`seacliff`, SPL 2026-06-03) at `firmware/questpro/ota/`. boot, dtbo and
vendor are extracted, plus IKCONFIG.
- **Kernel:** `4.19.325-cip128-st12-g49638c7a8637` (clang 14.0.7). That is
  the Quest 2 v2.7 release string, but not the same binary.
- **Boot header v2;** no vendor_boot or vendor_dlkm.
- **Same userspace config gaps as the Quest 2;** **no USB ACM gadget** (NCM
  only).

**Kernel gate: PASSED** (JOURNAL J-36; Quest 2 tree `6bde5fc06b25` + the
Quest Pro config). 776/776 vendor-required CRCs, `module_layout
0x74b4ebeb`. Adding the ACM gadget, DEVTMPFS, FHANDLE, AUTOFS, BTRFS,
USER_NS and PID_NS changes no existing CRC. Force `COMPAT_VDSO` off in the
image, as on the Quest 2.

**Governor:** the stock config defaults to the **`performance`** CPU
governor (as on the Quest 2), and the gated superset keeps it. Any image
must switch to schedutil/msm-adreno-tz with caps (`PROJECT_SETUP.md`
§6A.4).

**Strategy (PM):** do the work on the Quest 2 and Quest 3, then port the
fixes. The Quest Pro is expected to be ~90% complete through the Quest 2
work [C].

**Safety specifics:** the device checklist must be completed. In
particular, **H1: the eye- and face-tracking IR illuminators** (eye safety)
must stay under vendor-equivalent control. The cooling and the rear battery
also differ from the Quest 2.

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
