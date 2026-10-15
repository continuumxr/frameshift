# Quest 2 (hollywood) v2.7 — first offline look

*Edited for publication: names and links removed or paraphrased.*

Source: `firmware/quest2/ota/q2_52242990024200150.zip`, copied from the PM's
archive, hash in
`firmware/quest2/PROVENANCE.txt`. `boot`, `dtbo` and `vendor` were extracted
to `firmware/quest2/v2.7-user_ota/` with the stdlib payload extractor.
2026-10-08.

## Build and layout [M-static]

- **Build:** `oculus/hollywood/hollywood:14/UP1A.231005.007.A1/52242990024200150:user`,
  release keys, SPL 2026-06-03. That is the same Android 14 base and SPL as
  Quest 3 v2.7.
- **Kernel:** `4.19.325-cip128-st12-g49638c7a8637`, built with **Android
  clang 14.0.7 (r450784e)**, the same toolchain as Quest 3 v2.7.
- **Boot image header v2:** kernel and DTB in `boot`.
- **Payload partitions:** abl, aop, boot, cmnlib(64), devcfg, dtbo, hyp,
  imagefv, keymaster, modem, odm, product, qupfw, recovery, system,
  system_ext, tz, uefisecapp, vbmeta(_system, _vendor), vendor, xbl(_config).
  There is **no vendor_boot and no vendor_dlkm**, so this is the pre-GKI
  layout; modules ship in `vendor`. Seen on v2.1; v2.7 to be listed.
- **The Image carries IKCONFIG**, extracted to
  `firmware/quest2/v2.7-user_ota/kernel.config`.

## Config versus Valve userspace [M-static]

- **Off, the same gaps as Quest 3:** DEVTMPFS, FHANDLE, BTRFS_FS, AUTOFS_FS,
  USER_NS, PID_NS, SYSVIPC, POSIX_MQUEUE, CGROUP_PIDS.
- **On:** EXT4, OVERLAY_FS, MODVERSIONS (no MODULE_SIG), CGROUP_BPF,
  BPF_SYSCALL, SECCOMP_FILTER, PSTORE_RAM, ARM64_VA_BITS=39.
- **`USB_CONFIGFS_ACM` is off, unlike Quest 3; `USB_CONFIGFS_NCM` is on.**
  The Quest 3 stage-1 ACM command channel does not exist on the stock Quest
  2 kernel. Options are an NCM-based channel or a rebuilt kernel [D].

## Kernel gate (2026-10-08): PASSED

See JOURNAL J-32 and FS-A-006 (private review record).
- Public source `6bde5fc06b25` = the public commit for the exact build number (source identity with Meta's internal build is [O]).
- 838/838 vendor-required CRCs; `module_layout 0x74b4ebeb`.
- ACM, DEVTMPFS, FHANDLE, AUTOFS, BTRFS, USER_NS and PID_NS change no
  existing CRC.
- **Meta kernel source for 4.19.325-cip128:** found (exact). This
  resolves the [O] below.

## Implications [D/C]

- **Shared with Quest 3 (device-independent):**
  - the Track B Valve-userspace work: rootfs handling, unit masking, updater
    isolation;
  - the builder, observer and collector tooling;
  - the toolchain.
- **Device-specific:** kernel generation (4.19 vs 5.10), boot image format
  (v2 vs v4), module location, DT, firmware, charger and display.
- **systemd 257 on 4.19 lacks 5.x features:** pidfd (5.3+), clone3, newer
  mount APIs. Fallbacks are expected, but Quest1-SteamOS needed backports
  on 4.4 [C].
- **SM8250 has substantial mainline support** (PROJECT_SETUP §3.1). A
  mainline kernel may be a better Quest 2 route than rebuilding the 4.19 CIP
  kernel [C]. This is open, and not decided here.
- **Meta kernel source for 4.19.325-cip128:** not yet checked [O].
