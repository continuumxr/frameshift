# Meta Quest 3S

**Quaternary target (PM ordering, 2026-10-09; J-37); offline/build only, in lockstep with the Quest 3/Quest 2 changes.**

- **SoC:** XR2 Gen 2, the same `anorak` platform as the Quest 3 [C,
  per-DT confirmation pending].
- **Kernel:** the **same source tree as the Quest 3** (Meta's README lists
  `eureka`, `panther` and `xse_panther`), built with its own config
  (36 lines differ).
- **No PM-owned unit.** A third-party tester may run reviewed images later
  (`docs/PROJECT_SETUP.md` §6A item 9).

**Firmware held:** v2.7 OTA `v2.7_q3s_3814840020600610.zip` (Android 14,
`panther`, SPL 2026-06-02) at `firmware/quest3s/ota/`. boot, vendor_boot,
dtbo, vendor, vendor_dlkm and odm_dlkm are extracted, plus IKCONFIG.
- **Kernel:** `5.10.246-gd7102a837402` (clang 14.0.7). That is the Quest 3
  v2.7 release string, but not the same binary.
- **Boot header v4;** USB ACM gadget **present** (as on the Quest 3).
- **Same userspace config gaps as the Quest 3.**

**Kernel gate: PASSED** (JOURNAL J-36; Quest 3 tree `dbc2bc83a2b6` + the
Quest 3S config). 2583/2583 vendor-required CRCs, `module_layout
0xb1f01218`. Adding DEVTMPFS, FHANDLE, AUTOFS, BTRFS, USER_NS and PID_NS
changes no existing CRC.

**Strategy (PM):** do the work on the Quest 3, then port the fixes. The
Quest 3S is expected to be ~90% complete through the Quest 3 work [C].

**Safety specifics:** complete the device checklist. Its display, cooling
and battery differ from the Quest 3 (to be extracted).

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
