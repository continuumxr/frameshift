# Quest 3 K1a: our own kernel boots (offline package)

**Status (2026-10-15): built, gated and packaged OFFLINE (kernel, image and host side); awaiting the Chair: the K1a proposal (FS-A-013 §3.1 C1,
§3.2 C1/C8) and THIS package, which goes to the Chair as its concrete package (in FS-A-013) before any boot. Nothing was booted. No adb, fastboot or COM port was used; no device command was run.** The device
step needs the Chair's ruling on this concrete package, the package reviews and the PM at the headset (the K1a walkthrough (private)).
**FS-R-012 §9:** a rebuilt-kernel boot needs its concrete package first: this package goes to the Chair as its
concrete package (in FS-A-013) and is ruled on before any boot. **FS-R-012 §6:** the stage-3d derived-baseline exception does not carry into a
rebuilt-kernel package; a direct, read-only readback of the slot's boot, vendor_boot, dtbo, vbmeta and vbmeta_system
over their AVB-covered ranges is a precondition ([removed for publication]).

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C] hypothesis · [O] open.
Everything here is [M-static] (build outputs, hashes) or [D] (fixtures under qemu-user, bwrap, WSL), not [M].

## 1. What K1a is

The milestone of `docs/PROJECT_SETUP.md` §3 and FS-A-013 §2.2: **a FrameShift-built kernel (expected CRC-neutral
options; Meta's stock vendor modules; no USER_NS/PID_NS) boots by a temporary `fastboot boot` and reaches our PID
1, on both units** (PM decisions J-157/J-158: K1a, then K1g, then K1i; both units at the PM's request): **Unit 2
first; Unit 1 only after Unit 2's result has been checked and reported to the PM**, each with its own fresh nonce
(a nonce-only rebuild), readback rows and attempt-ledger entry. `host/fs-k1a-units.ps1` holds the two units and the
order gate: the observer and checklist phase A open Unit 1 **only** when every Unit 2 attempt has a bound outcome
record (the classifier's `classify-k1a.json`) of **K1A PASS** whose after-session record (checklist phase F) is clean:
AF and AA without a STOP, no recovery fault, no manual power-off, no dump mode, all follow-up readings finished below
40 °C. A K1A REVIEW blocks Unit 1 (FS-R-012 §3; after the Chair's review Unit 1 needs a new reviewed package revision or
the Chair's ruling); K1A FAIL, INTEGRITY FAULT,
INCONCLUSIVE, an unclean PASS or a Unit 2 attempt without an outcome record (no console, an interrupted observer)
block Unit 1 until a new package review. The record is written once and carries the pinned banner, config
and module count the classifier checked. Not detected (residual risk, documented): a deliberate hand edit of the record,
the checklist, the capture or collect.json (FSB1 has no MAC), of file write times, deleting, renaming or overwriting
raw follow-up files, or removing a whole attempt with its ledger entry. Phase A asks A5
(the result was reported), and the observer checks A5 approved the current record. Known hardware faults,
recorded and never compensated: Unit 2's IPD slider and proximity sensor, Unit 1's proximity sensor; K1a reads no
sensor, so neither affects a K1a result.

- **The kernel:** Meta's public v2.7 source `dbc2bc83a2b6` plus the K1a request list, built with the toolchain,
  make variables and build identity of the kernel gate (§2). Bit-identical rebuild (§2.3).
- **The modules:** Meta's **stock** v2.7 vendor modules, unchanged, from the unit's own vendor_boot (the
  95-module set of stage 3d, J-129). The gate shows that every one of them matches our kernel's symbol versions
  (§3). Our build's own new modules (`btrfs.ko`, `autofs4.ko`, ...) are **not** in the image and are not loaded.
- **The image** (`build-image.sh`): our kernel in place of the stock kernel, plus a ramdisk derived from the
  proven stage-3d PID 1 with the display parts removed (§4). `fastboot boot` takes vendor_boot (vendor ramdisk,
  DT, vendor command line) from the slot, as in every stage.
- **What it shows when it runs:** `/proc/version` and `uname -v` carry our pinned build identity; the running
  kernel's own config hashes to the gated `.config`; the 95 stock modules load with no symbol-version refusal;
  our ACM console comes up (ACM only, PM decision J-179); `MemTotal` is recorded; once PID 1 runs it returns the unit to fastboot within the
  stage-3d deadline (a hang or panic of our kernel before PID 1 runs needs the manual route of `../RECOVERY.md` §4b).
  **No panel write**; FrameShift's own tools write nothing to storage (the cycle's `adb reboot bootloader` makes
  Android write the misc bootloader message, as in every stage; after a panic or oops our kernel may write pstore
  records and the bootloader a crash minidump [C]; `../RECOVERY.md` §4b). `PANIC_ON_OOPS` is off and
  `PANIC_TIMEOUT=-1` (both as stock): a panic reboots at once, normally straight into Android.

## 2. The kernel (`kernel/`)

### 2.1 Config delta against stock v2.7 (`kernel/BUILD-RECORD.txt`)

Requested (`tools/kgate/validation/requests/quest3-k1a.txt`):

| option | stock | K1a | why |
|---|---|---|---|
| DEVTMPFS | n | y | systemd hard requirement (stage3-4-plan §4.1) |
| DEVTMPFS_MOUNT | — | y | the brief's "DEVTMPFS (+mount)"; affects only a non-initramfs root (Kconfig help) |
| FHANDLE | n | y | systemd hard requirement |
| AUTOFS_FS | n | m | systemd automounts (optional; gated as group a) |
| BTRFS_FS | n | m | Valve's rootfs (stage 4) |
| BTRFS_FS_POSIX_ACL | — | y | Valve's rootfs ACLs |
| TMPFS_XATTR | n | y | overlay opaque directories on a tmpfs upper |
| TMPFS_POSIX_ACL | n | y | logind `uaccess` ACLs |

Kconfig fallout (allowlisted, `quest3-k1a.allow` = `quest3-a.allow`): `CRYPTO_XXHASH=m`, `RAID6_PQ=m`,
`RAID6_PQ_BENCHMARK=y`, `XOR_BLOCKS=m` (BTRFS selects); plus the host toolchain probes `CC_CAN_LINK`,
`CC_CAN_LINK_STATIC` (present in the stock-config build too) and `PAHOLE_VERSION` (WARN by design). Unchanged and
**not** requested: SYSVIPC, POSIX_MQUEUE (K1i), USER_NS, PID_NS (FS-R-006 §2). BLK_DEV_RAM is already `=y` in
stock (16 × 8 MiB); R0 sizes it on the command line later. `FS_POSIX_ACL` was already `=y` in stock, so neither
POSIX_ACL option changes a core structure.

### 2.2 Toolchain and flags (the gate's, FS-A-006 (private review record), `repro_q3.sh`)

- AOSP clang/LLD **r450784e** (14.0.7, "Android (8508608, based on r450784e)"), AOSP make 4.3, pahole v1.31.
  `build-kernel.sh` checks three pin files (written by `kernel/make-toolchain-pins.sh`) before any make:
  `toolchain.sha256` (16 files: the clang tools, make, pahole and its libraries, `vmlinux.profdata`),
  `toolchain-clanglib.sha256` (716 files: clang's resource dir) and `toolchain.links` (9 tool names resolve to their
  pinned files). Python, perl, tar, xz and glibc versions are recorded, not pinned. The script runs with
  `pipefail` and dies if the manifest step fails.
- `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-
  REAL_CC=<clang> LLVM=1 LLVM_IAS=1` with LD/AR/NM/OBJCOPY/OBJDUMP/READELF/OBJSIZE/STRIP = the r450784e LLVM tools,
  HOSTCC clang, HOSTLDFLAGS=-fuse-ld=lld, PYTHON=python3; targets `Image modules`; `olddefconfig` from the
  CRLF-stripped stock `kernel.config`.
- **Pinned build identity:** `KBUILD_BUILD_TIMESTAMP="Wed Oct 14 00:00:00 UTC 2026"`, `KBUILD_BUILD_USER=frameshift`,
  `KBUILD_BUILD_HOST=k1a`, `KBUILD_BUILD_VERSION=1`; `TZ=UTC`, `LANG=C.UTF-8`, umask 022.
- **ASLR off** (`setarch x86_64 -R` on every make): `repro_q3.sh` showed clang r450784e's sample-PGO annotation
  (`CONFIG_META_SAMPLE_PGO`, stock) is address-dependent; with ASLR off the build is bit-identical.
- Same object path for every rebuild: `~/work/kgate27/out-k1a`.

### 2.3 Results

Summary: `kernel/BUILD-RECORD.txt`; full records and manifests: `kernel/record/run{1,2,3}/` [M-static].

| output | sha256 |
|---|---|
| `arch/arm64/boot/Image` (42,967,552 bytes) | `087f0e72999922909e9583b95ae956f0186d6c1a337b71308b845456689e1840` |
| `vmlinux` | `8686b77c44ae1ebffa8f3844b3ef0162c30a332b379b2075aec9698e930fb8ca` |
| `.config` (= `kernel/k1a.config`) | `4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b` |
| `Module.symvers` | `0ce513c3af499dff91fd634f0ac940c50f9b5fe84f3bf6867776fe27d5ded621` |
| `System.map` | `ee48a288fea6aa9aa170626289aaa10026ddd9d6a28c62b62ea5802527155931` |
| 278 `.ko` (our build's; K1a loads none of them) | list `f2fbdb1bb86b6e662bf88aee03e33abc97fe95fb0b8def8bf00b161930fc3602` |

Banner (`/proc/version`): `Linux version 5.10.246-gdbc2bc83a2b6 (frameshift@k1a) (Android (8508608, based on
r450784e) clang version 14.0.7 (…), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026`; `uname -v` =
`#1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026`.

**Reproducibility:** three builds at the same object path, ASLR off. Run 2 (same script as run 1) and run 3 (the
final `build-kernel.sh`, sha256 `604ba1e1…`, every toolchain pin checked) are **bit-identical rebuilds** of run 1:
the same `.config`, vmlinux, Image, Module.symvers, System.map and all 278 `.ko`, and the Images are `cmp`-equal
(`kernel/compare-builds.sh`, with the builder's `EXPECT_K1A_KERNEL` / `EXPECT_K1A_CONFIG` pins checked;
`kernel/record/compare-run1-run2.txt`, `compare-run1-run3.txt`).

## 3. The gate (FS-R-006 §2/§3; `kernel/gate-k1a.sh`)

`tools/kgate` 2.3 `check` in **gate mode**, profile build `k1a` (pins committed first: the profile is the trust
root), reference = Meta's stock v2.7 module inventory (`reference_sha256 daf9546e…`, 272 unique modules, 2601
vendor-required (symbol, CRC) pairs), baseline = the pinned stock-config build's `Module.symvers` (`7b5cfa8f…`).

**Result: PASS (exit 0), build ACCEPTED** (`tools/kgate/validation/quest3/check-k1a.{json,log}`; the K1a build
of run 1, `~/work/kgate27/out-k1a-1`) [M-static]:

- `crc`: **2601/2601** vendor-required (symbol, CRC) pairs match; `module-layout` `0xb1f01218` matches;
- `baseline`: **0 of 14059** stock-build vmlinux exports changed or removed, **0 added**;
- `vermagic-image` / `vermagic`: `5.10.246-gdbc2bc83a2b6 SMP preempt mod_unload modversions aarch64` (the release
  differs from the shipped `-gd7102a837402`; under modversions the loader does not compare it);
- `export-collision`, `namespace`, `gpl-only`, `unversioned-imports`: PASS; `btf-kinds`: no kinds beyond stock;
- `requested-options`: all 8 satisfied; `requested-config`: only the allowlisted fallout (6) and the pahole probe
  (WARN) differ from stock; `config-binding` / `input-binding`: the `.config` is the Image's IKCONFIG, and
  Module.symvers, vmlinux and the Image belong to one build.

**CRC-neutral as expected: no option moves to K1i.** (Group a had already passed with `BTRFS_FS_POSIX_ACL` off,
J-31; the newly gated `BTRFS_FS_POSIX_ACL`, `TMPFS_XATTR`, `TMPFS_POSIX_ACL` and `DEVTMPFS_MOUNT` change no export
CRC [M-static]. By source, none of them changes a structure in a header: `FS_POSIX_ACL` was already on, no header
tests TMPFS_XATTR/TMPFS_POSIX_ACL/DEVTMPFS_MOUNT/FHANDLE/AUTOFS/BTRFS, and DEVTMPFS only switches the
`devtmpfs_mount()` prototype [D].)

**What a PASS means** (kgate README): the build matches the checked symbol-version interfaces of Meta's shipped
modules; complete module compatibility and runtime behaviour remain open (FS-R-006 §2). The module-load
simulation (§5.3) replays the image's own loader against the same interfaces; the device run is the test.

## 4. The image (`build-image.sh`, `init.sh`, `fs-k1a.sh`, `fs-k1a-info.sh`)

- **Kernel:** the K1a Image, pinned by sha256, size, banner and embedded IKCONFIG (= `kernel/k1a.config`); the
  builder also requires the committed kgate result `tools/kgate/validation/quest3/check-k1a.json` to be a gate-mode
  PASS (exit 0, build k1a, no waiver, 2601/2601, module_layout, 0 changed exports) **for exactly this Image and
  config**, and the module-loader vermagic string (our release plus the stock modules' flags SMP preempt mod_unload
  modversions aarch64; the release itself is not compared under modversions) to be in the Image.
- **Header:** the stock v2.7 boot.img's fields (header v4, os version/patch level); the only differences from stock
  are `kernel_size` and `ramdisk size` (the stock signature size is already 0).
- **PID 1 (`init.sh`)** = stage 3d's (deadline 200 s, backstop 201 s, ack window 150 s, error delay 60 s; the
  vendor module index pins; our 95-module list; USB role; fs-verify/fs-ack/fs-status/fs-done; the console; the
  hold) with: product "FrameShift K1a"; the gadget stays **ACM only** (PM decision J-179); the display parts
  removed (no fs-phase/fs-pattern/fs-probe/fs-idle, no `/dev/dri` node, no interrupt sample); no idle limit.
  `/dev` stays tmpfs + mdev (the reviewed mounts); devtmpfs is only reported.
- **Runner (`fs-k1a <challenge>`):** once per boot; one paced FSB1 record `exp=k1a`, 8 steps under fs-supervise,
  all reads: `kernel` (uname -r/-v, /proc/version, /proc/cmdline), `config` (sha256 of `zcat /proc/config.gz`
  and the K1a option lines), `mem` (MemTotal …), `modules` (count, taint, the loader's lines, /proc/modules),
  `kmsg` (one kernel-log read: symbol-version or vermagic refusals, and every WARNING/BUG/oops-class line with counts, FS-R-012 §3), `fs` (/proc/filesystems, /proc/mounts),
  `usb` (UDC and state, the linked functions, product and serial), `log` (/run/fs.log). Bounds (`tools/check-bounds-k1a.py`): MAXLINES 2120,
  RUNNER_WORST 115 s (fs-supervise worst case t + g + 7.5 per step), refused (`time`) unless it ends before T0 + 200 s, i.e. it must start by T0 + 85 s.
- **Lexical guards** (builder): stage 3d's (no debugfs, the five reviewed mounts, no backlight_changes_blocked) plus
  K1a's: no DRM node, backlight or panel path in any non-comment script line; the info helper redirects into no
  file and calls no writing command.
- **One attempt per image:** a fresh nonce per run (USB serial `FS-<nonce>`); a nonce-only rebuild leaves the
  kernel bytes identical, proven by `tools/nonce-only-k1a.py` (FS-A-013 §2.2 note 1).

**The current candidate** (never booted; the reference of every nonce-only rebuild; `host/fs-nonceonly-k1a.ps1`
table) [M-static]:

| | |
|---|---|
| directory | `build\k1a\20261015T163855Z-ecbcbd4f7b6f43c0` (gitignored) |
| image | `boot-k1a.img`, 44,552,192 bytes, sha256 `42cda89e9db47c548759a549ab00dabed8879925c47d70f74e4be5107237e79c` |
| nonce | `ecbcbd4f7b6f43c0` (USB serial `FS-ecbcbd4f7b6f43c0`); unspent |
| kernel | `087f0e72…1840` (42,967,552 bytes), byte-identical in the image (AOSP re-unpack) |
| built from | checkout `c921128` (the image sources are clean there; `build-image.sh` refuses a dirty checkout) |
| withdrawn, never booted, deleted | `80bd5ab6…` (review fixes), `fa39b471…` (NCM, J-179), `5726b948…` (modver → kmsg), `7b8e432f…` (full-package review fixes) |

For each run a fresh nonce: rebuild, then `host\fs-nonceonly-k1a.ps1` (or `tools/nonce-only-k1a.py`) against this
candidate; the observer refuses anything else.

## 5. Tests (all offline)

Every result below is recorded under `fixtures/` (and the K1a host suite (private)) [M-static, offline]. The
candidate is `20261015T163855Z-ecbcbd4f7b6f43c0` (`42cda89e…`); the kernel is the run-1 Image (`087f0e72…`).

| suite | result | file |
|---|---|---|
| builder negatives and reproducibility (`test-builder.sh`) | **46/46** | `fixtures/builder/RESULTS.txt` |
| QEMU smoke test of the image (`test-image.sh`) | **11/11 scenarios, 194 checks** | `fixtures/image/RESULTS.txt` |
| module-load simulation (`tools/modload-sim.sh`) | **4/4** | `fixtures/modload/RESULTS.txt` |
| runner bounds (`tools/check-bounds-k1a.py`) | **9/9, RESULT PASS** | `fixtures/bounds.txt` |

### 5.1 The builder (`test-builder.sh`)

40 refusals, each with its expected `BUILD REFUSED` reason and nothing published: the kernel (tampered, missing,
stock v2.7, the group-a build, a symlink), the config, the gate result (missing, FAIL, waived, a CRC mismatch,
report-only, a check missing, another reference, a changed baseline, an extra check, another vmlinux, another tool
version, another build), the pinned userspace binaries and scripts, the stock inputs (v66 boot/vendor_boot/vbmeta),
the module list and index pin, an extra ramdisk file, bad nonces, CR line ends, the lexical guards (debugfs, an
extra mount, a DRM node, a backlight write, info-helper writes, `insmod`, backlight_changes_blocked) and a dirty
checkout. Then reproducibility: the same nonce and stamp give the same image twice (`9dd5246c…`); a nonce-only
rebuild leaves the kernel bytes identical and changes only the nonce inside `/init` (and its negatives: a cpio that
differs beyond the nonce, the same nonce); **the candidate rebuilt from this checkout with its own nonce and stamp
is `42cda89e…` again**, and a fresh-nonce rebuild of it is NONCE-ONLY OK.

### 5.2 The QEMU smoke test (`test-image.sh`, `tools/image-harness-k1a.py`)

The ramdisk unpacked from the built image runs as PID 1 in a bwrap sandbox under qemu-aarch64 user mode, with the
real deadlines, fs-supervise, encoder, pacer and runner. Scenarios: `c-full` (verify, ack, runner, fs-done: the
8-step record decodes; banner, config hash, MemTotal, loader lines, a clean kernel log, the faked filesystems and
mounts, ACM-only gadget `acm.gs0`, product and serial), `c-kmsg-findings` (canned 5.10 lines through the image's
own busybox filters: 4 symbol-version/vermagic refusals, 1 taint note, 1 WARNING in 3 lines), `c-repeat`
(already-run), `c-bad-challenge`, `c-time` (the runner's own `time` refusal), `c-no-ack`, `c-ack-no-done`,
`c-done-early`, `c-bind-fail`, `c-modules-real` (the image's 95-module list against the real v2.7 modules.dep and
softdep) and `c-modules-refused` (an index one line off the pin: no module, no shell, reboot error-modules).
Every scenario also checks the deadline and backstop, PID 1's exec of fs-reboot-final, no access to a decoy
backlight or DRM node (inotify) and the tty accounting. What is fake: §5.4.

### 5.3 The module-load simulation (`tools/modload-sim.sh`, `tools/modload-sim-k1a.py`)

For each of the 95 modules the image loads, in its order, it applies the 5.10 loader's checks against a build's
`Module.symvers` and Image: vermagic (the release token skipped under modversions, the other tokens equal),
`module_layout`, every undefined symbol exported by vmlinux or by a module loaded earlier, the same CRC for every
versioned import, GPL-only and namespaced exports, and no duplicate export. Cases: the K1a build 95/95 PASS; the stock-config
build 95/95 PASS; a perturbed K1a symvers FAIL (33/95, as it must); the list plus extra modules FAIL (101, not the
expected 95). **Note (review m6):** the simulation reads the `.ko` files and Module.symvers with kgate's own parsers
(`parse_ko` and its symvers reader), so it is not independent of the gate's parsing: a parser fault would affect
both. It replays the loader's order and dependencies, which the gate does not; the device run remains the test.

### 5.5 The host side and the readback check

the K1a host suite (private) (102): replays of the harness captures through the collector (COLLECTED-VALID, the
runner's time refusal, the runner start gate at BootStartUtc + 65 s, CLI refusals), the classifier (C0-C14: replay
labelled FIXTURE, every FAIL fact, REVIEW on a WARNING/BUG line, a wrapped log or a truncated step, INTEGRITY FAULT,
INCONCLUSIVE, taint notes reported only, the outcome record for bound results only), the observer (preflight,
sign-off gate, an unknown serial refused, a stage-3d image refused), the nonce-only check (including a real
fresh-nonce rebuild in WSL), the checklist (phases A, B, E; the readback per unit; the battery level above 50 %,
malformed levels, a reading on another unit; Unit 1's phase A before Unit 2's outcome) and full attempts with every
device dependency a recording fake (exactly one fastboot boot; a readback transcript changed after phase A, BA10
level 50 or missing, a recorded level edited, absent or a number: refused; both units: Unit 1 refused before Unit 2's
outcome record or with one that does not bind, accepted after it with A5, its own nonce and ledger entry).

### 5.4 What the tests cannot show

- **The kernel booting.** It cannot boot the Quest in QEMU: no QEMU machine models the anorak SoC, Meta's DT
  and the vendor_boot handoff. The QEMU smoke test runs the image's own userspace (busybox, fs-supervise, the
  scripts) under qemu-aarch64 **user mode** on the WSL kernel; the kernel facts it reports are fakes: bind mounts
  for /proc/version, config.gz, meminfo, cmdline, modules, filesystems and the taint value, and a seccomp
  user-notification listener for the kernel log (syslog(2): busybox runs `dmesg` as a built-in applet) and
  /proc/mounts (a symlink, which a bind cannot fake). No host data reaches the fixtures; the image is unchanged.
- **Device timing of the steps.** Under qemu-user every busybox fork re-executes the emulator, so a step is far
  slower than on the unit; on a heavily loaded host the 4 s `kmsg` step can hit its timer. The harness is run on a
  quiet host (3 scenarios in parallel); the device bounds come from `tools/check-bounds-k1a.py`, not from QEMU.
- **Runtime module behaviour** beyond symbol versions (FS-R-006 §2): struct layouts the CRCs do not cover,
  Kconfig-dependent inline code in headers, timing. The options are chosen so that no core structure changes
  (`FS_POSIX_ACL` already on; no header uses TMPFS_XATTR/TMPFS_POSIX_ACL/DEVTMPFS_MOUNT) [D, source grep].

## 6. Open items (for the review and the PM)

1. **The ruling** on the K1a proposal (FS-A-013 §3.1/§3.2) and on THIS concrete package, sent to the Chair in
   FS-A-013 (FS-R-012 §9: the Chair reviews the concrete package before any boot) and **the readback precondition** (FS-R-012 §6, step 0b): the device step waits for both. The Chair may want a QEMU
   boot of the same Image (not possible on a Quest machine model; a generic `virt` boot would show little) or a
   stock-config rebuild booted first as a control (`~/work/kgate27/out-repro`, bit-identical, ready to package).
2. **The K1a host side** is written (offline): `host/fs-observe-k1a.ps1`, the K1a sign-off tooling (private), `fs-collect-k1a.ps1`,
   `fs-classify-k1a.ps1`, `fs-nonceonly-k1a.ps1`, the K1a sign-off sheet (private); adapted copies or library users of the stage-3d
   and stage-3b tools, which are not edited. Its own review and the PM's walkthrough of the console remain.
3. **ACM only** (PM decision J-179): K1a carries no NCM function; NCM stays with the USB Stage A work.
4. **The runner must be sent by T0 + 85 s** (RUNNER_WORST 115 s against the 200 s deadline). The host collector
   sends it only before BootStartUtc + 65 s (its budget check; BootStartUtc is not later than T0); a later start is
   INCONCLUSIVE with fs-done sent at once. Whether the unit reaches SHELL_READY early enough is [C] (stage 3d's
   sessions did so within the first minute).
5. **No idle limit** (stage 3c's fs-idle.sh went with the display parts): the hold ends at fs-done, at the ack
   window (150 s after SHELL_READY without fs-ack) or at the deadline (T0 + 200 s).
6. **The kernel release string** is `5.10.246-gdbc2bc83a2b6` (public source) where the shipped kernel says
   `-gd7102a837402`; modversions makes the loader skip it, and our loader uses `insmod` with full paths, so no
   `/lib/modules/<release>` lookup happens [D]. Anything on the unit keyed on the release is not exercised by K1a.
7. **Our six new modules** (`btrfs.ko`, `autofs4.ko`, `xor.ko`, `xor-neon.ko`, `raid6_pq.ko`, `xxhash_generic.ko`) are built but
   not packaged; they belong to the stage-4 rootfs work (and are rebuilt with K1i).
8. **The package reviews:** an internal adversarial review of the scripts (GO-with-fixes; MAJOR 1-4 and MINOR 5-9
   applied), then the full-package review in two parts: host side GO-with-fixes (all applied), kernel/gate/image
   NO-GO on one blocker, the missing rebuild proof (B1), now closed by runs 2 and 3 (bit-identical); its other
   findings applied (toolchain pins M1, compare-builds pins m5, harness fakes M2; `git log`). The Chair's review of
   the concrete package and the PM's sign-off remain.

## 7. Files

| file | role |
|---|---|
| `kernel/build-kernel.sh` | the reproducible kernel build (pins checked first) |
| `kernel/toolchain.sha256`, `toolchain-clanglib.sha256`, `toolchain.links` | the pinned toolchain files, the PGO profile, clang's resource dir and the tool links |
| `kernel/make-toolchain-pins.sh` | writes the three pin files |
| `kernel/compare-builds.sh` | the bit-identical rebuild check |
| `kernel/gate-k1a.sh` | the kgate gate-mode run (writes `tools/kgate/validation/quest3/check-k1a.*`) |
| `kernel/k1a.config` | the gated `.config` (= the Image's IKCONFIG) |
| `kernel/BUILD-RECORD.txt`, `kernel/record/` | build records, manifests, the rebuild comparison |
| `init.sh`, `fs-k1a.sh`, `fs-k1a-info.sh` | PID 1, the runner, the read-only fact helper |
| `build-image.sh` | the image builder (pins, gate binding, lints, MANIFEST) |
| `test-builder.sh` | builder negatives, same-nonce reproducibility, nonce-only checks |
| `test-image.sh`, `tools/image-harness-k1a.py` | the QEMU smoke test of the PID-1 logic |
| `tools/modload-sim.sh`, `tools/modload-sim-k1a.py` | the module-load simulation against the v2.7 index |
| `tools/nonce-only-k1a.py` | the nonce-only rebuild check |
| `tools/check-bounds-k1a.py` | the runner's bounds re-derived from its source |
| `fixtures/` | the recorded results of all of the above |
| `../host/*-k1a.ps1`, the K1a sign-off sheet (private) | the host side (observer, checklist, collector, classifier, nonce-only check, the two units and their order `fs-k1a-units.ps1`, pins) |
| the K1a walkthrough (private) | the eventual run (draft; awaiting the Chair's ruling on this concrete package) |
