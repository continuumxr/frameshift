# fs-metacfg: reader, record and acceptance (normative spec, rev 1, 2026-10-14; rev 2, 2026-10-15: M-11, M-12; rev 3, 2026-10-15: M-21a)

Implements `docs/research/emergency-shutdown-design.md` (rev 5) §4.5.2–§4.5.3
(option B, approved J-122; P18 fallback). Two independent implementations
follow this text: the C reader `src/fs-metacfg.c` (production) and the
Python reference `tools/ref/metacfg_ref.py` (test oracle). The fixture
writer `tools/fix/mkfix.py` is written from this text **independently of
both readers**. Where code and this file disagree, this file wins and the
code is fixed (or this file is revised and both are fixed).

Rule ids `M-n` are cited by the coverage table in `PLAN.md`.

All integers are little-endian. "Fail `x`" means: stop, emit a record with
status code `x` (§6) and no payload. Any failure is a fallback for the
supervisor; it is never a crash and never "no thresholds".

## 1. Inputs

| | production | test variant (`-DFS_TEST`) |
|---|---|---|
| argv | `fs-metacfg <device> <outfd>` | adds `--root DIR` (prefix for `/sys`, `/proc`, `/dev`), `--super-size N`, `--uevent-sock PATH`, `--allow-regular`, `--seccomp-optional` |
| device | `eureka` (Quest 3) or `hollywood` (Quest 2); anything else: fail `arg` | same |
| expected `super` size | eureka `0x200000000`, hollywood `0x180000000` (F35) | `--super-size` overrides |
| slot source | eureka `/proc/bootconfig`; hollywood `/proc/cmdline` (F37) | under `--root` |

The production build must not contain the strings `--root`, `--allow-regular`
or `--seccomp-optional` (build check, negative test).

## 2. Locate and open `super` (M-1 … M-5)

- **M-1** Scan `<root>/sys/class/block/*/uevent` (each file ≤ 4096 bytes):
  lines `KEY=VALUE`. Entries with `PARTNAME=super` are candidates; take
  `DEVNAME`. Exactly one candidate: continue. Two or more: fail
  `super-ambiguous`.
- **M-2** None found: wait for a uevent with `ACTION=add` and
  `PARTNAME=super` (production: a `NETLINK_KOBJECT_UEVENT` socket opened
  **before** the scan, so an event between scan and wait is not lost; test:
  a bound `AF_UNIX` `SOCK_DGRAM` socket at `--uevent-sock`, carrying the
  same `NUL`-separated `KEY=VALUE` payload after an `action@devpath` head)
  until **1800 ms** after the helper started (`CLOCK_BOOTTIME`). Event-driven
  (`ppoll`), never a sleep loop. Not found: fail `no-super`.
- **M-3** Slot: read the slot file (≤ 65536 bytes). bootconfig: a line
  `androidboot.slot_suffix = "<v>"` (spaces around `=` optional, quotes
  optional); cmdline: a token `androidboot.slot_suffix=<v>`. `<v>` must be
  `_a` (slot 0) or `_b` (slot 1). Missing, duplicated with different values,
  or other: fail `slot`.
- **M-4** Open `<root>/dev/<DEVNAME>` with `O_RDONLY|O_CLOEXEC` only.
  `fstat`: must be a block device (test: a regular file if
  `--allow-regular`); else fail `super-type`. Size: `ioctl(BLKGETSIZE64)`
  (the only ioctl; test regular file: `st_size`). Size must equal the
  expected size; else fail `super-size`.
- **M-5** seccomp (production): after M-4, `PR_SET_NO_NEW_PRIVS` then a
  filter (architecture checked) allowing only `pread64` with fd = the
  `super` fd, `write` with fd = outfd, `close`, `fstat`, `brk`, `mmap`
  without `PROT_EXEC`, `munmap`, `ioctl` with fd = `super` fd and command
  `BLKGETSIZE64`, `clock_gettime`, `rt_sigreturn`, `exit_group`, `exit`;
  anything else `SECCOMP_RET_KILL_PROCESS`. Install failure: fail
  `seccomp` (test with `--seccomp-optional`: continue, and set record flag
  bit 0x1 `seccomp-off`). After the filter the reader uses static buffers
  only (no allocation, no stdio).
- **Read budget:** every `pread` from `super` counts; more than
  **1,048,576** bytes in total: fail `read-budget`. A short read: fail
  `io`.

## 3. LP metadata (M-6 … M-12) [C, liblp format]

Offsets in bytes from the start of `super`. LP sectors are 512 bytes.

- **M-6 Geometry** at 4096 (read 4096 bytes; structure 52 bytes):
  `magic` u32 @0 = `0x616C4467`; `struct_size` u32 @4 = 52; `checksum`
  [32] @8 = SHA-256 of the 52 bytes with the checksum field zeroed;
  `metadata_max_size` u32 @40: > 0, multiple of 512, ≤ 65536;
  `metadata_slot_count` u32 @44: 1…3, and the slot index (M-3) below it;
  `logical_block_size` u32 @48: > 0, multiple of 512 (logged, unused). Any
  failure: fail `lp-geometry`. The backup geometry (8192) is **never** read.
- **M-7 Header** of the slot's **primary** metadata at
  `12288 + slot × metadata_max_size` (read `metadata_max_size` bytes; that
  range must lie inside the device, else `lp-geometry`):
  `magic` u32 @0 = `0x414C5030`; `major_version` u16 @4 = 10;
  `minor_version` u16 @6 ≤ 2; `header_size` u32 @8 = 128 if minor ≤ 1,
  = 256 if minor = 2; `header_checksum` [32] @12 = SHA-256 of
  `header_size` bytes with that field zeroed; `tables_size` u32 @44 ≤
  `metadata_max_size − header_size`; `tables_checksum` [32] @48 = SHA-256
  of the `tables_size` bytes right after the header. Descriptors (each
  `offset, num_entries, entry_size`, u32): partitions @80, extents @92,
  groups @104, block devices @116. Minor 2: `flags` u32 @128
  (`LP_HEADER_FLAG_VIRTUAL_AB_DEVICE` = 1; rev 2: any set flag fails, M-11).
  Failures: magic/version/
  size fail `lp-header`; either checksum fail `lp-checksum`.
- **M-8 Tables:** `entry_size` ≥ 52 / 24 / 48 / 64 (partition / extent /
  group / block device); `num_entries × entry_size` computed without
  overflow; `offset + that` ≤ `tables_size`. Fail `lp-tables`. Only the
  first bytes of each entry (the known structure) are interpreted.
- **M-9 Block devices:** exactly one entry; its `size` u64 @16 equals the
  device size. Fail `lp-blockdev`.
- **M-10 Names:** every partition `name` [36] @0 contains a `NUL` within its
  36 bytes; fail `lp-name`.
- **M-11 The active logical view (rev 2, FS-R-012 §8).** The reader
  applies a deny-list of signals visible in `super`, plus the M-21a
  Virtual A/B policy: any snapshot, COW, overlay or unknown-layout signal
  is a fallback (fail safe, the built-in table, the reason logged). It does not
  substitute "read `vendor<suffix>`" for that: a Virtual A/B device keeps
  its snapshot and merge state on `metadata` and may keep its COW data in
  files on `userdata`, neither of which the reader reads (and reading
  them is not proposed, ESD O27), so every Virtual A/B, snapshot or overlay
  signal visible in `super` is a refusal, not a log entry (an update whose
  LP metadata shows none of them remains, ESD R25).
  **Scope, stated plainly:** M-11 and M-12 are a deny-list of the signals
  visible in `super`'s LP metadata. The reader does not read the snapshot
  or merge state (on `metadata`) nor any COW files (on `userdata`), so
  they do not establish that no update is pending; an update whose LP
  metadata shows none of these signals is accepted (ESD R25, O27), unless
  the vendor `build.prop` declares Virtual A/B, which M-21a (rev 3, the
  PM's decision of 2026-10-15) refuses outright. The real-image test
  (`tools/test_real_local.sh`) wraps OTA vendor images in a synthetic
  `super` (`tools/fix/wrap_super.py`): no real Quest `super` (v2.7 or
  v66) has been exercised; the T0 `lpdump` probe settles the real layout.
  Checked after M-10, before M-12, in this order:
  (a) header `flags` (minor 2) has `VIRTUAL_AB_DEVICE` (0x1): fail
  `vab-device`; (b) any other header flag bit set (an unknown or future
  layout): fail `lp-flags`; (c) any partition whose
  name ends in `-cow`: fail `vab-merge` (F38); (d) any partition group
  named exactly `cow` (libsnapshot's COW group, also when empty): fail
  `vab-cow-group`; (e) a partition named exactly `scratch` (the
  adb-remount overlay storage of debuggable builds): fail `overlay`.
  The vendor partition's attributes are checked in M-12.
- **M-12 Vendor:** exactly one partition named `vendor` + suffix (`_a`/`_b`);
  none: fail `no-vendor`; more: fail `vendor-dup`. `attributes` u32 @36:
  bit 0x8 (`DISABLED`): fail `vendor-disabled`; bit 0x4 (`UPDATED`, set
  on the partitions an update wrote: a snapshot may be pending): fail
  `vab-updated` (rev 2, was logged only); any bit other than `READONLY`
  (0x1) and `SLOT_SUFFIXED` (0x2): fail `lp-attr` (rev 2). Only the
  active slot's partition counts. `first_extent_index` u32 @40, `num_extents`
  u32 @44: ≥ 1, and `first + num` ≤ the extent count without overflow,
  else fail `lp-tables`. Each extent: `num_sectors` u64 @0 > 0;
  `target_type` u32 @8 = 0 (LINEAR) else fail `extent-type`;
  `target_data` u64 @12; `target_source` u32 @20 = 0 else fail
  `extent-source`; `(target_data + num_sectors) × 512` without overflow and
  ≤ the device size, else fail `extent-range`. The extents, in order, map
  the vendor partition's bytes onto `super`.

## 4. ext4 reader (M-13 … M-20)

Byte offsets below are inside the vendor partition, translated through
the M-12 map. No checksum authenticates anything (F34); every field is
bounded before use.

- **M-13 Superblock** at 1024 (1024 bytes): magic u16 @0x38 = `0xEF53`
  else fail `fs-type`; `s_log_block_size` u32 @0x18 = 2 else
  `ext4-blocksize`; feature words exactly compat u32 @0x5C = `0x28`,
  incompat u32 @0x60 = `0x42`, ro_compat u32 @0x64 = `0x407B` (F34:
  `ext_attr dir_index` / `filetype extent` / `sparse_super large_file
  huge_file uninit_bg dir_nlink extra_isize shared_blocks`) else
  `ext4-features`; `s_inode_size` u16 @0x58 = 256 else `ext4-inode-size`.
- **M-14 Geometry:** `s_inodes_count` u32 @0x0, `s_blocks_count_lo` u32
  @0x4 (no `64bit`, so the high word is not read), `s_first_data_block` u32
  @0x14 = 0, `s_blocks_per_group` u32 @0x20 > 0, `s_inodes_per_group` u32
  @0x28 > 0; groups = ceil(blocks / blocks_per_group); `inodes_count` =
  groups × inodes_per_group; else `ext4-geometry`. `blocks × 4096` ≤ the
  vendor partition length, else `ext4-size`.
- **M-15 Inode** `n`: 1 ≤ n ≤ inodes_count else `ext4-inode`; group
  descriptor `(n−1)/ipg` at block 1 + 32 × group (32-byte descriptors);
  `bg_inode_table_lo` u32 @8; table block < blocks_count else
  `ext4-range`; inode at `table × 4096 + ((n−1) % ipg) × 256` (256 bytes).
- **M-16 Inode checks:** `i_flags` u32 @0x20 has `EXTENTS_FL` 0x80000 and not
  `INLINE_DATA_FL` 0x10000000, else `ext4-inode-flags`; `i_size_high` u32
  @0x6C = 0 and `i_size_lo` u32 @0x4 ≤ 65536, else `ext4-isize`.
- **M-17 Extent tree** (root: `i_block` @0x28, 60 bytes): header magic u16
  = `0xF30A` else `ext4-extent-magic`; `eh_entries` u16 @2 ≤ `eh_max` u16
  @4, and `eh_max` ≤ 4 in the inode or ≤ 340 in a block, else
  `ext4-extent-count`; `eh_depth` u16 @6 ≤ 2 (root), and a child's depth
  is exactly its parent's − 1, else `ext4-extent-depth`. Index entry (12
  bytes): `ei_block` u32 @0, child block = `ei_leaf_lo` u32 @4 |
  `ei_leaf_hi` u16 @8 << 32, < blocks_count else `ext4-range`. Leaf entry
  (12 bytes): `ee_block` u32 @0, `ee_len` u16 @4 (0 or > 32768:
  `ext4-uninit`), start = `ee_start_hi` u16 @6 << 32 | `ee_start_lo` u32
  @8; `start + len` ≤ blocks_count else `ext4-range`. Leaves in tree order
  must start at logical block 0 and be contiguous (each `ee_block` = the
  previous end) until they cover ceil(size / 4096) blocks; a gap or a
  short cover: `ext4-hole`.
- **M-18 Directories** (`/` = inode 2, then `etc`): mode u16 @0 type
  `0x4000`, else `ext4-notdir`; size a multiple of 4096. Each block is
  scanned linearly: entry `inode` u32 @0, `rec_len` u16 @4, `name_len` u8
  @6, `file_type` u8 @7, name @8. `rec_len` ≥ 12, multiple of 4, ≤ the
  rest of the block; `name_len + 8 ≤ rec_len`; else `ext4-dirent`. Inode
  0 entries are skipped. At most **16** directory blocks are scanned in
  total, else `ext4-dir-cap`.
- **M-19 Files:** `/etc/thermal_info_config.json` (≤ 65536),
  `/etc/vr_runtime_power_mitigation.json` (≤ 4096), `/build.prop`
  (≤ 65536). Not found: `file-missing`. Mode type must be `0x8000`
  (regular; a symlink `0xA000` or anything else): `file-type`. Size over
  its cap: `file-size`. Content = the first `i_size` bytes of the mapped
  blocks.
- **M-20** Every physical block read must also lie inside the vendor
  partition (it does when M-14's size check and `< blocks_count` hold).

## 5. Content (M-21 … M-26)

- **M-21 build.prop:** lines split on `\n` (a trailing `\r` is stripped);
  `#` comment lines and blank lines skipped; `key=value` split at the first
  `=`; a line without `=` (for example an `import` line) is ignored (rev
  1a). `ro.product.vendor.device` and `ro.vendor.build.version.incremental`
  must each occur exactly once (else `buildprop`); each value 1…92 bytes of
  `[A-Za-z0-9._-]` (else `buildprop`). Other keys are ignored, except:
- **M-21a Virtual A/B policy (rev 3, PM decision 2026-10-15).** On a
  Virtual A/B device the thermal service always uses the built-in table,
  never Meta's runtime values. A `build.prop` line whose key, trimmed on
  both sides of the C-locale `isspace` characters (space, `\t`, `\n`,
  `\v`, `\f`, `\r`) as Android's property loader does (AOSP
  `system/core/init/property_service.cpp`, `LoadProperties`: it skips
  `isspace` before the key and the value and trims it at the end of the
  line and before `=`), starts with `ro.virtual_ab.` (`enabled`,
  `retrofit`, `compression.enabled`, …) and whose value, trimmed the same
  way, is anything other than exactly `false` (`true`, empty, any
  other text) marks a Virtual A/B device: fail `vab-policy`. Checked after
  the M-21 checks (a `buildprop` failure comes first), before M-22. A
  `build.prop` that cannot be read fails anyway (`file-missing`,
  `file-type`, `file-size`, `buildprop`, every ext4 code): fail safe.
  **Property absent: accepted** (the other M-11/M-12 signals clean). Why:
  absence is how non-Virtual-A/B firmware declares itself (Quest 3 v66
  sets no `ro.virtual_ab.*` property, F38), refusing it would remove
  J-118's runtime path from every device; and acceptance (A-4) applies
  only a file set whose JSON hash, digest and vendor incremental match a
  reviewed row, whose `build.prop` was reviewed (v66: no Virtual A/B), so
  a Virtual A/B build that omitted the property would match no row and
  fall back (P18).
- **Adding a known-firmware row (condition, rev 3).** Whoever adds a row
  to `tables/known-firmware.tsv` records the firmware's Virtual A/B status
  from **every** partition's properties (`vendor`, `odm`, `system`
  `build.prop`) and from that unit's `lpdump` output (header flags,
  `-cow` partitions, `cow` group, `UPDATED`), and adds the row only for a
  firmware that is not Virtual A/B in any of them (a Virtual A/B firmware
  is refused by M-21a anyway; a row for it is dead). **Open for the v66
  row:** F38 checked only v66's vendor `build.prop` (no `ro.virtual_ab.*`);
  its `system` and `odm` properties and an `lpdump` of a v66 unit are not
  checked yet (T0).
- **M-22 JSON syntax:** RFC 8259 with these restrictions, else
  `json-syntax`: UTF-8 BOM rejected; only ASCII 0x20–0x7E inside strings;
  no backslash escapes at all; whitespace = space, tab, CR, LF; nothing but
  whitespace after the top value; nesting depth ≤ 4 (the top object is
  depth 1), else `json-depth`.
- **M-23 Keys:** within any object a repeated key: `json-dupkey`. Top
  object keys ⊆ {`Sensors` (required, array), `CoolingDevices` (array)}.
  Sensor object keys ⊆ {`Name` (string, required), `Type` (string,
  required), `HotThreshold` (array, required), `HotHysteresis` (array),
  `VrThreshold` (required), `Multiplier` (required), `Monitor`}. Cooling
  device keys ⊆ {`Name` (string), `Type` (string)}, both required. Any
  other key: `json-unknown-key`. A value of the wrong JSON type, or a
  required key missing: `json-type`.
- **M-24 Values:** each `HotThreshold` / `HotHysteresis` element is a JSON
  number, a numeric string, or the string `NAN` (→ unset). Exactly 7
  elements, else `json-slots`. Numeric grammar (for numbers and numeric
  strings alike): `-?(0|[1-9][0-9]{0,8})(\.[0-9]{1,3})?` (no exponent, at
  most 3 decimals); value in milli-units = the decimal × 1000 exactly; must
  fit int32 and must not equal INT32_MIN. Otherwise `json-number`.
  `Multiplier`: a number or numeric string with the same grammar but up to
  **6** decimals, > 0; stored as `num/den` with `den = 10^decimals`, then
  divided by 10 while both are divisible by 10 (so `0.001` → 1/1000,
  `0.1` → 1/10, `1` and `1.0` → 1/1). Otherwise `json-number`.
  `VrThreshold` must be the string `NAN`, else `json-vr` (O25). `Monitor`,
  if present, must be the literal `true`; a sensor with any set
  `HotThreshold` element must have it; else `json-monitor`. **Rev 1a:** a
  slot element or a `Multiplier` of any other JSON type (`null`, `true`,
  an object, �) is `json-number`; a `Monitor` of any other value or type
  (`false`, `"true"`, �) is `json-monitor`.
- **M-25 Names:** `Name` 1…31 bytes of `[A-Za-z0-9._-]`, else `json-name`;
  two sensors with the same `Name`: `json-dupname`; more than 128 sensors:
  `json-count`; zero sensors: `json-count`. `Type` strings are checked for
  type only (never used for classes, F33/m6). Cooling-device `Name`/`Type`
  are type-checked only (unused, rev 1a).
- **M-26 VR-runtime list:** shipped raw, not parsed (F36).

## 6. Record framing (M-27)

One record on `outfd`, then exit 0. Header, 64 bytes:

| off | type | field |
|---|---|---|
| 0 | char[4] | `FSMC` |
| 4 | u16 | version = 1 |
| 6 | u16 | status (0 = OK, else the code below) |
| 8 | u32 | json_len (≤ 65536) |
| 12 | u32 | vr_len (≤ 4096) |
| 16 | u16 | dev_len (≤ 92) |
| 18 | u16 | incr_len (≤ 92) |
| 20 | u32 | n_entries (≤ 128) |
| 24 | u32 | entry_size = 96 |
| 28 | u32 | lp_header_flags (log only; 0 if minor < 2) |
| 32 | u32 | vendor partition attributes (log only) |
| 36 | u32 | slot index |
| 40 | u32 | flags: 0x1 seccomp-off (test only); 0x2 `UPDATED` seen (rev 2: never set, M-12 refuses `UPDATED`) |
| 44 | u8[20] | zero |

Then `json` bytes, `vr` bytes, `dev` bytes, `incr` bytes, then
`n_entries` entries of 96 bytes: `name` char[32] (the sensor name,
`NUL`-padded), `slot` int32[7] (`HotThreshold` in milli-units),
`hyst` int32[7] (`HotHysteresis`; all unset if the key is absent),
`mult_num` int32, `mult_den` int32. Unset = `INT32_MIN`
(`0x80000000`). Entries sorted by `name` bytes (memcmp of the 32-byte
field). Every sensor of the file is an entry (also those with no set
slot).

On failure: status ≠ 0, every length and `n_entries` 0, `entry_size` 96,
slot as known (else 0), nothing after the header.

**Status codes** (stable; never renumbered):

| code | name | | code | name |
|---|---|---|---|---|
| 1 | arg | | 21 | fs-type |
| 2 | no-super | | 22 | ext4-blocksize |
| 3 | super-ambiguous | | 23 | ext4-features |
| 4 | super-type | | 24 | ext4-inode-size |
| 5 | super-size | | 25 | ext4-geometry |
| 6 | slot | | 26 | ext4-size |
| 7 | seccomp | | 27 | ext4-inode |
| 8 | io | | 28 | ext4-range |
| 9 | read-budget | | 29 | ext4-inode-flags |
| 10 | lp-geometry | | 30 | ext4-isize |
| 11 | lp-header | | 31 | ext4-extent-magic |
| 12 | lp-checksum | | 32 | ext4-extent-count |
| 13 | lp-tables | | 33 | ext4-extent-depth |
| 14 | lp-blockdev | | 34 | ext4-uninit |
| 15 | lp-name | | 35 | ext4-hole |
| 16 | vab-merge | | 36 | ext4-notdir |
| 17 | no-vendor | | 37 | ext4-dirent |
| 18 | vendor-dup | | 38 | ext4-dir-cap |
| 19 | vendor-disabled | | 39 | file-missing |
| 20 | extent-type | | 40 | file-type |
| 41 | file-size | | 47 | json-number |
| 42 | buildprop | | 48 | json-vr |
| 43 | json-syntax | | 49 | json-monitor |
| 44 | json-depth | | 50 | json-name |
| 45 | json-dupkey | | 51 | json-dupname |
| 46 | json-unknown-key | | 52 | json-count |
| 53 | json-slots | | 54 | json-type |
| 55 | extent-source | | 56 | extent-range |
| 57 | vab-device | | 58 | lp-flags |
| 59 | vab-cow-group | | 60 | overlay |
| 61 | vab-updated | | 62 | lp-attr |
| 63 | vab-policy | | | |

The canonical record is the entries region (n × 96 bytes); its SHA-256
is the **parse digest**.

## 7. Acceptance in `fs-thermald` (A-1 … A-9; design §4.5.3)

`fs-thermald` never parses JSON, LP or ext4. It reads the framed record
from the helper with the bounded wait of design §4.5.2 and decides:

- **A-1 framing:** magic, version 1, `entry_size` 96, every length within
  its cap, `n_entries` ≤ 128, and exactly `64 + json + vr + dev + incr +
  96n` bytes received before the 2 s deadline. A short record, an EOF or a
  timeout: fallback `reader-timeout` (deadline) or `reader-bad-record`
  (anything else). The parent reads nothing beyond the framed length.
- **A-2** status ≠ 0: fallback `reader:<name>`.
- **A-3 device:** `dev` = the running device (DT model → `eureka` /
  `hollywood`), else `device-mismatch`.
- **A-4 hashes, computed by `fs-thermald` itself (m5):** H_json = SHA-256
  of `json`, D = SHA-256 of the entries region, H_vr = SHA-256 of `vr`.
  No known-firmware row of this device with that H_json: fallback
  `unknown-hash` (**P18**), the hash logged. Row found: D ≠ row digest:
  fallback `digest-mismatch` plus a fault record; `incr` ≠ row incremental:
  fallback `incremental-mismatch`. H_vr ≠ row's: thresholds unaffected, the
  list is **not exported**, NOTICE `vr-list-unreviewed`.
- **A-5 multiplier:** every class-map sensor present in the record has
  exactly the class map's `num/den`; else `multiplier`.
- **A-6 bounds (step 5):** for every class-map temperature sensor (class
  SOC, SKIN, BATT, USB): slots 0, 4 and 5 unset (`bounds-unset-slot`);
  every set slot in 35000…125000 (`bounds-range`); set slots strictly
  increasing from 1 to 6 (`bounds-order`); for every set slot `hy` (unset →
  0) ≥ 0 (`bounds-hyst`) and `slot − hy` ≥ 20000 (`bounds-release`);
  SHUTDOWN ≤ the class maximum (SOC 115000, BATT 65000, SKIN 60000, USB
  125000) (`bounds-shutdown`). BCL entries are not bounded.
- **A-7 coverage (step 6):** every class-map sensor flagged `json` is an
  entry, with a set-slot mask in its allowed set (`coverage-missing`,
  `coverage-mask`); every entry with any set slot is in the class map
  (`coverage-unmapped`).
- **A-8** order of checks: A-1, A-2, A-3, A-4 (hash, digest, incremental),
  A-5, A-6, A-7; the first failure decides the reason.
- **A-9 result:** accepted: `limits=meta-runtime`, the active set = the
  record's slots/hysteresis for the class-map sensors. Fallback:
  `limits=builtin reason=<code>`, the active set = the device's built-in
  table (`PLAN.md` §3.2), a one-time NOTICE `limits-builtin`; never a WARN.
  A device without built-in values (Quest Pro, Quest 3S): no active set,
  never READY.

## 8. Implementation notes (rev 1a, after the independent implementations)

- **Read budget accounting** (M-5) depends on how a reader splits its
  reads. The C reader reads only the bytes it needs (32-byte group
  descriptors, 256-byte inodes, partial last blocks); the Python reference
  reads differently. Both stop at 1 MiB; a file set within a few hundred
  bytes of the cap may pass one and fail the other (fixture
  `budget-edge-over`, declared; the C reader needs fewer bytes there).
  The three real images stay far below the cap.
- **Check order** where several faults coexist: syntax and depth first,
  then schema errors in document order (C); the reference finds duplicate
  keys over the whole document before the schema. Single-fault fixtures
  agree; multi-fault files fall back either way.
- **M-20 strengthened** (from the reference's review): every group
  descriptor and inode byte range must lie inside `blocks_count � 4096`.
