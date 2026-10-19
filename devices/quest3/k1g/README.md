# Quest 3 K1g: the boot-chain write guard is proven (offline package)

**Status (2026-10-19, r3): the probe-only fix after the r2 Unit 2 attempt was K1G REVIEW (J-207: the probe failed
closed before arming; its `O_DIRECT` reads were rounded to 512 bytes and the unit's UFS LUNs have 4096-byte logical
blocks, so R3 `dtbo_a` got `EINVAL`). Every hashing read is now whole 4096-byte blocks (§3 disclosure (b)); the guard
kernel is byte-identical (`fixtures/image-delta/RESULTS.txt`); candidate `1ee9f105…`, probe `c1de030c…` (source
`7226f45b…`). Changes and reasons: `CHANGES-r3.md`. Built, tested and REVIEWED OFFLINE on branch `feat/k1g-r3`;
submitted as a delta for the Chair's review. FS-R-015 §4 concurred r2 only: nothing runs on r3 before the Chair rules.
The order gate (`../host/fs-k1g-units.ps1`) is unchanged, so as committed it still refuses Unit 2 a second K1g attempt
and keeps Unit 1 blocked on the r2 REVIEW record (CHANGES-r3 §5). Nothing was booted; no device command was run.**
The r2 status below is kept as the history of the package.

**Status (2026-10-18, r2): the FS-R-014 §3 corrections on branch `feat/k1g-r2`: the probe's content-read allowlist,
stop on the first failure and no open fallback, with the guard kernel unchanged (`fixtures/image-delta/RESULTS.txt`).
Built, tested and REVIEWED OFFLINE (internal reviews and their dispositions: `review/REVIEWS-k1g.md`); submitted as a
delta for the Chair's review. FS-R-014 halted execution of the FS-A-014 candidate `c3c92a09…`; nothing runs before
the Chair rules on this delta. Nothing was booted. No adb, fastboot or COM port
was used; no device command was run.** **Execution uses files byte-equal to the reviewed commit** (the K1g sign-off sheet (private):
the host-pin table checked by phase A, the kernel/probe/candidate pins checked by the builder and the observer, and a
fresh-nonce image accepted only as a nonce-only rebuild of the reviewed candidate). The Chair accepted bringing
K1g (FS-R-013 §5, §6); this directory is the concrete package it asked for: the exact patch, the probe source and
binary, the exact-image kgate result, the VM and mutation evidence, the allowlists, the timing bounds and the expected
refusal/counter table. **K1g runs only after both K1a attempts (Unit 2, then Unit 1) and only with the Chair's
ruling on this package; Unit 2 first.**

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C] hypothesis · [O] open. Everything here is
[M-static] or [D] (offline tests), not [M].

the K1g sign-off sheet (private) is the authority for the final pins (host files, kernel, probe and the reviewed candidate image).

## 1. What K1g is

PROJECT_SETUP §3 K1g and PD-10: `fs-blkguard` is built and proven on the device **before any Valve software runs**.
The K1g image is the K1a image with exactly three changes:

1. **The kernel:** Meta's v2.7 source `dbc2bc83a2b6` **plus the fs-blkguard patch** (`a9c63e24cb76`;
   `tools/blkguard/patches/0001-*.patch`, GPL-2.0-only, 902 insertions / 3 deletions, no export, struct or
   Kconfig change), built with the **exact K1a config** (`k1a/kernel/k1a.config`, byte-identical), the K1a
   toolchain pins and build identity, except the build host `k1g` (`kernel/build-kernel-k1g.sh`). Bit-identical
   rebuild checked (§2).
2. **PID 1** (`init.sh` = K1a's plus section 2b): after the complete module closure (the 95 stock modules), the
   guard proof runs **once**: `/bin/fsbg-probe --compact --nonce=<nonce>` under fs-supervise (TERM 25 s, KILL 2 s
   later). Stages `BLKGUARD_STARTED`, `BLKGUARD_DONE result=<PASS|FAIL|ABORT|none>`. Its report stays in RAM.
3. **The runner** (`fs-k1g.sh`): K1a's 8 read-only steps plus a 9th, `blkguard`, which reports the probe's result,
   the fs-supervise report and the first 8 lines of `/proc/fs_blkguard` (`fs-k1g-info.sh`).

Everything else is K1a's: vendor_boot from the slot, the 95-module list and index pins, ACM only, the deadline
(200 s, backstop 201 s, ack window 150 s), fs-verify/fs-ack/fs-status/fs-done, one attempt per image, a fresh nonce
per attempt (nonce-only rebuild, `tools/nonce-only-k1g.py`), the spent-nonce ledger shared with K1a.

## 2. The kernel (`kernel/`)

| item | value |
|---|---|
| source | `~/work/k1g/src` = a pristine checkout of `a9c63e24cb76` (parent `dbc2bc83a2b6`); the build checks that `git format-patch` of it equals the committed patch file, and that the tree is clean including ignored files |
| config | `k1a/kernel/k1a.config` `4aa0c894…826b` (the K1a request list; the patch adds no Kconfig symbol) |
| identity | `KBUILD_BUILD_HOST=k1g`, otherwise K1a's (timestamp, user, version); banner `Linux version 5.10.246-ga9c63e24cb76 (frameshift@k1g) (…) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026` (release token from the patched commit) |
| object path | `~/work/kgate27/out-k1g` for every rebuild (ASLR off, as K1a) |
| Image | `65740722b532b4235e2d35b517bf70d7753e63f42b7b7ee5c869117d999042d3`, 42,969,600 bytes |
| vmlinux | `be84f21eb8a5698b7c5378beeb4f18194d35e30ec0648ed64a9e31d9f78cd984` |
| Module.symvers | byte-identical to K1a's (the patch exports nothing); `.config` `4aa0c894…`; 278 `.ko` (`kernel/record/run1/manifest.txt`) |
| rebuild | run 2 at the same path, compared with `k1a/kernel/compare-builds.sh` (reused unchanged; it reads the builder's `EXPECT_K1A_*` pin names, with the builder's two pin lines passed without their trailing comments): **BIT-IDENTICAL** (Image, vmlinux, .config, Module.symvers, System.map, 278 `.ko`; `kernel/record/compare-run1-run2.txt`, `kernel/BUILD-RECORD.txt`) |
| kgate | `kernel/gate-k1g.sh`: gate mode on the exact K1g build, label `quest3-k1g`, the profile's `k1a` build pins (the request list and allowlist are K1a's; the trust root is not edited): **gate PASS**, crc 2601/2601, baseline 0 of 14059 changed (`tools/kgate/validation/quest3/check-k1g.{json,log}`) |

## 3. The probe (`tools/blkguard/probe/fsbg-probe.c`, `build-probe.sh`)

Static aarch64, built reproducibly (`build-probe.sh`: fixed flags, no build id; two builds byte-identical) and pinned
by the image builder (binary and source). Device mode, as run by PID 1:

1. **Pre-checks, nothing created:** `/proc/fs_blkguard` version 1; boot state `protect`, unsealed; build hazards
   `none` (or `modules` before the latch); the Quest's boot-chain and unit-unique names visible (16 named partitions:
   `xbl_a/b`, `tz_a/b`, `abl_a`, `boot_a`, `vbmeta_a`, `persist`, `misc`, `frp`, `devinfo`, `modemst1/2`, `fsg`,
   `cdt`, `ddr`; sysfs metadata only). Any failure: **ABORT** (exit 2), no armed guard test case attempted.
2. **Device nodes** from sysfs (PID 1's `/dev` is a tmpfs with `mdev -s`; the probe itself makes no node for the
   real `persist`), then **RAM/tmpfs decoys** (a GPT image on
   tmpfs at `loop6`, `ram1`, descriptors opened before arming, `dm-200` over `ram1`, `loop7` over an `O_RDWR` fd of
   `ram1`).
3. **Before-hashes**, reads only, fail-closed in the form of the readback proposal (private), §5.1 (each row bounded like
   `timeout -k 5 <the time left in the pass, at most 10>` (§5); it must hash exactly the bytes it requires; never the empty-input
   hash; no retry and no second open on real storage: exactly one `O_RDONLY|O_DIRECT` open per row, FS-R-014 §3.3).
   **Content-read allowlist (FS-R-014 §3.1):** enumeration and guard coverage use sysfs metadata and the guard's own
   verdict table only; content is read ONLY from the decoys and from the partitions of the accepted readback rows:
   **R1–R5** (`boot_a`, `vendor_boot_a`, `dtbo_a`, `vbmeta_a`, `vbmeta_system_a` over their AVB-covered ranges, which
   must equal PROPOSAL §3's expected v2.7 values), **R6** (the `misc` and `devinfo` sizes: `BLKGETSIZE64` on an
   `O_RDONLY` open, no I/O), **R7d** (`misc` whole, 1 MiB) and **R8** (`devinfo` whole, 4 KiB), whose before/after
   pairs must be equal. The allowlist is checked by the kernel's partition name of the device the node refers to,
   BEFORE any open; `persist` is never opened for anything (no row, no test case); no whole-LUN and no other
   partition is read. Each readback name must be carried by exactly one node. **The first failure stops every later
   row** (a read error, short read, expected-content mismatch, refused open or time bound; FS-R-014 §3.2): nothing
   more is opened, the partial result is kept, ABORT before arming.
   **Disclosures (review of r2):** (a) the whole LUN that holds `persist`, and its sg/bsg nodes, remain targets of the
   Q cases (Q4–Q10, Q12–Q14, A3: zero-length or no-data commands, refused ioctls, INQUIRY); none reads content and none
   opens the `persist` partition node. Q5 (the rescan) and Q13 (`IOC_PR_REGISTER`) are state-changing operations whose
   execution is prevented by the dropped `CAP_SYS_ADMIN` and the expected guard refusal, not write-incapable ones
   (FS-R-015 §4, which accepts these LUN-level targets for the pinned operations, arguments and privilege handling only). (b) `O_DIRECT` reads are whole 4096-byte blocks (**K1g r3**:
   the Quest 3's UFS LUNs have 4096-byte logical blocks: Unit 1 [M], FS-A-005 (private review record)
   lines 505-535; Unit 2 [D], the same model and the J-207 refusal pattern; and 5.10's `blkdev_direct_IO` refuses an offset, length or buffer that is not a multiple of it): a
   row hashes exactly its range but reads up to the next 4096-byte boundary, inside the same allowlisted partition
   (R3 `dtbo_a` reads 16,384 bytes for its 12,564-byte range, R4 `vbmeta_a` 8,192 for 5,632, R5 `vbmeta_system_a`
   4,096 for 3,136; R1, R2, `misc` and `devinfo` are whole 4 KiB multiples). A rounded read that would pass the end
   of the node, or a read that returns less than its aligned length, fails closed. The alignment is a fixed constant,
   not `BLKSSZGET` (no new ioctl); 4096 is a multiple of 512, so the 512-byte decoys and VM disks are read the same
   way (each is a whole number of MiB; a 512-byte node whose size is not a multiple of 4096 would fail closed). r2
   rounded to 512 bytes, which the unit refused with `EINVAL` at R3 (J-207, K1G REVIEW). (c) R6's open (`O_RDONLY`, `BLKGETSIZE64`, no I/O) runs in the probe itself without a
   row bound: a hung open would end at fs-supervise's 25 s timer, classified as an unarmed time stop (INCONCLUSIVE).
   (d) A partition that cannot be identified by its device at the moment of use is not opened either (fail closed).
   *Context only (PM clarification, 2026-10-17): the project's rule forbids writes or changes to `/persist`; reads are
   allowed. The probe nevertheless keeps the Chair's narrower FS-R-014 §3.1 allowlist (no access to `persist` at all),
   because any change of the read scope needs the Chair's review.*
4. **Latch and arm (FS-R-013 §6(2))**: `kernel.modules_disabled=1`, then the sealing request; read back the mode, the
   seal and the latch; a second request must be refused (seal test); every real block node must show a `deny-*`
   verdict. Any disagreement: ABORT.
5. **Mechanism phase** on the decoys (every guarded path with real data, full capabilities; each target re-verified
   RAM-backed first).
6. **Protected phase**, only if every mechanism case passed: the reduced-privilege/read-only cases on the real nodes,
   `/dev/sg*` and `/dev/bsg/*`, except `persist` (never opened: one `SKIP  Q*` line). **No write-mode open of a real
   node (no Q11; PM decision, FS-R-013 §6(1)).**
7. **After-hashes**, the same rows; every hash must equal its before value; the first failed row stops the rest
   (a CHANGED row or a read error is K1G FAIL; a time bound K1G REVIEW).

The compact report (stdout) carries the pre-check lines, R1–R6, the arming and seal lines, every failing line, the
hash verification, one `SERIES` line per case id, a digest of all accepted rows before and after, and the result line.
At most 24 failing lines are printed, then one suppression line. The full log stays in `/run/fsbg/full.log` (RAM,
not transmitted). PID 1 mounts `/run` as a 32 MiB tmpfs (the 16 MiB decoy image lives there; the VM K1g-layout and
devicesim runs mount the same size).

## 4. Allowlists (exact)

| state | request | when |
|---|---|---|
| boot default | none: `protect`, unsealed (boot storage guarded from the first instruction) | kernel boot |
| **K1g** | `strict allow=disk:ram0,disk:dm-200,disk:dm-201,disk:loop7,part:fsbg_decoy_rw` | PID 1 section 2b, after the 95 modules and `modules_disabled=1` |
| R-1 (later, not this package) | `strict allow=disk:ram0` | our initramfs, before `switch_root` |

No Quest partition is named `fsbg_decoy_rw`; `dm-200`/`dm-201`/`loop7` exist only as the probe's RAM stacks, whose
leaf (`ram1`) is not allowlisted, so their writes must still be refused (cases S1, S2, S4).

## 5. Timing bounds (`tools/check-bounds-k1g.py`)

| bound | value |
|---|---|
| PID 1 deadline / backstop / ack window | 200 s / 201 s / 150 s (K1a's, FS-R-013 §3: kept) |
| the guard proof in PID 1 (before the gadget) | fs-supervise `-t 25 -g 2`: worst 34.5 s (TERM 25 s, KILL 2 s later, the supervisor's own 7.5 s) |
| the probe's before-hash pass | **8 s from the probe's start** (decoy set-up included); over it: `ABORT: time:` before arming |
| the probe's after-hash pass | must end by **20 s** from the start (5 s before the TERM, so a row's KILL still fits) |
| each hash row | the time left in its pass, **at most 10 s** (+5 s KILL); a row timeout stops all further reads of that pass |
| runner | 9 steps, `MAXLINES 2463`, `RUNNER_WORST 127 s`: the device refuses to start it after **T0 + 73 s** |
| host start limit | **BootStartUtc + 53 s** (200 − 15 s give-up − 127 − 5 s margin; K1a: 65 s) |
| BA-to-boot dwell | ≤ 300 s (K1a's) |

**Why the total probe budget is not larger.** The proof runs inside PID 1 before the gadget, so its time comes out of
the host's start window: the gadget appeared at about BootStartUtc + 21 s in stage 3d (the same module set), and the
runner must be sent by BootStartUtc + 53 s. With the deadline kept at 200 s (FS-R-013 §3) the proof can have about
25 s. A larger total budget would need a longer K1g deadline (for example 260 s: the runner start limit would move to
T0 + 133 s); that is a change to a Chair-kept bound and is **not** proposed here. Instead the probe now (a) hashes about
ten times faster where the CPU allows and (b) measures its own pace before it arms anything.

**The hashing.** The probe uses the ARMv8 SHA-256 instructions when the CPU reports `HWCAP_SHA2` **and** a known-answer
self-test (FIPS 180-4 "abc", and 4 KiB of pseudo-random data against the portable code) agrees; otherwise the portable
C code. Meta's kernel config builds `CONFIG_CRYPTO_SHA2_ARM64_CE=y`, which suggests the unit's cores have the
instructions [C]. Both implementations give the same digests (`tools/blkguard/probe/bench/sha-bench.c`: 64 MiB, equal
to Python's hashlib; and every QEMU run, where `armv8-ce` was selected and every R1–R5 row matched the expected v2.7
value). The probe prints the implementation, the before-pass seconds, the MiB hashed, two CPU clocks and the governor
(`PRE pace`), so the first K1g run measures the unit's real pace.

**The worst case (derivation [D] from the measurements, with the assumptions marked [C]).**

| quantity | value | source |
|---|---|---|
| volume per pass on the unit (r2, FS-R-014 §3.1) | ≈ 79.6 MiB: R1–R5 ≈ 63.6 MiB, R7d `misc` 1 MiB, R8 `devinfo` 4 KiB, decoys ≈ 15 MiB (`ram1` 8 MiB, `loop6` head/tail 2 MiB, five 1 MiB decoy partitions); no other real node is read. (The FS-A-014 candidate read ≈ 206 MiB: every node whole if ≤ 8 MiB, else head and tail.) | the probe's row table; QEMU devicesim `PRE pace ... hashed=79 MiB` |
| portable SHA-256 on the host | 98–131 MiB/s = 19–25 cycles/byte at the nominal 2.59 GHz (i7-10750H; turbo makes the true figure higher) | `sha-bench.c`, three runs [M, host] |
| portable SHA-256, slowest plausible unit core | 50 cycles/byte (an in-order core, twice the host's) at 300 MHz ≈ 5.7 MiB/s | [C] |
| ARMv8 SHA-256, slowest plausible unit core | 4 cycles/byte at 300 MHz ≈ 71 MiB/s | [C]; not measurable offline |
| UFS read, slowest plausible | 50 MiB/s with 1 MiB `O_DIRECT` reads (HS-G4 UFS reads well above 1 GiB/s) | [C] |
| clocks at the proof | `cpufreq.default_governor=performance` in the DTB bootargs ([M] on Android's command line), so the cores run at their maximum unless throttled; the thermal admission rule keeps the unit cool | [M]/[C] |

| case | before-pass (8 s budget) | whole proof (TERM at 25 s) | outcome |
|---|---|---|---|
| ARMv8, normal clocks (≥ 1.8 GHz), UFS ≥ 500 MiB/s | ≈ 0.3 s | ≈ 2 s | PASS path, margin > 20× |
| portable, normal clocks | ≈ 2.5 s | ≈ 6 s | PASS path, margin ≈ 3× on the pass budget |
| ARMv8 at 300 MHz, UFS at 50 MiB/s | ≈ 2.7 s | ≈ 6.5 s | PASS path, margin ≈ 3× |
| portable at 300 MHz | ≈ 15.5 s | — | **stops before arming** after 8 s: `ABORT: time:` |

The arithmetic of the bounds is unchanged (`tools/check-bounds-k1g.py`: before-pass 8 s, after-pass end 20 s, rows ≤ 10 s
+ 5 s KILL, fs-supervise TERM at 25 s; runner start T0 + 73 s, host BootStartUtc + 53 s); only the volume fell, so every
margin grew.

So a slow unit can no longer run out of time **after** arming: the before-pass is the same work as the after-pass,
and if it does not fit in 8 s the probe stops before any armed guard test case is attempted. The only way left for time to stop the
proof after arming is an after-pass far slower than the before-pass (a row then hits its bound): that is an ABORT
after arming, classified **K1G REVIEW** (the invariance check is incomplete), never FAIL or PASS.

**How a time stop is classified.** A pre-arming time stop (`ABORT: time:`, or fs-supervise's timer stopping the probe
while the guard is still unarmed: mode protect, sealed 0, modules_disabled 0) is **INCONCLUSIVE**: not a guard verdict
and not a K1g result. It still uses that unit's single attempt (the gate refuses a second K1g attempt on the unit),
because the unit was booted with our kernel. **This package proposes that the Chair may authorise a nonce-only repeat
for that case** (FS-R-013 §5 allows nonce-only repeats when the package and outcome justify them):
no armed guard test case was attempted (decoy set-up and the before-pass reads had run), so the repeat is the same
experiment. It is never automatic; enacting it needs the Chair's
ruling and a reviewed revision of the order gate naming the superseded attempt. A late runner start (after
BootStartUtc + 53 s) stays INCONCLUSIVE as in K1a.

In QEMU the before-pass budget is 120 s and rows are bounded at 60 s (emulated hashing); the earlier devicesim run in
which R1 hit the old 10 s bound with the host busy (`qemu-devicesim-under-load.log`, probe `2aa1f153…`) is what the
VM bounds now avoid. `devicesim-timeout` (`fsbg.prebudget=1`, VM only) shows the pre-arming time stop: ABORT before
arming, no armed guard test case attempted, the Quest-named disks unchanged.

## 6. Expected refusals and counters (device)

Every case passes only if the call fails with the expected errno, the guard's counter for that path moved by the
expected amount, and no other counter moved (`docs/research/fs-blkguard-design.md` §7.2 has the full case table).
N = the visible real block nodes (Unit 2's baseline: 6 whole disks + 87 partitions = 93 [M, Android-side list]);
D = the whole sd disks (6); G = `/dev/sg*`; B = SCSI bsg nodes; U = UFS bsg nodes (1).

| series | target | expected | counter delta |
|---|---|---|---|
| N1, N2 | decoy nodes (ram1, loop6, loop6p1-p4, p6: 7) | `EPERM` | open +1 each |
| N3–N5 | the same 7 | `EPERM` | discard/zeroout +1 each |
| N6 | the same 7 | `EPERM` | roset +1 |
| N7–N10 | ram1, loop6 | `EPERM` | blkpg (3) / rrpart +1 each |
| N11 | loop6p2 (`persist`, swap header) | `EPERM` | open +1 |
| P1–P5, P7–P10 | descriptors to `ram1` opened before arming | `EPERM` | write/fallocate/discard/zeroout +1 each |
| P11 | mmap + msync on `ram1` | `EIO` | bio ≥ 1 |
| S1, S2 | `dm-200` (rw over ram1), `dm-201` (ro over the decoy `loop6p1` = `xbl_a`, ro flag cleared) | `EIO` | bio ≥ 1 |
| S3 | a new rw dm table over `persist` | `EPERM` | open +1 |
| S4 | `loop7` (over a pre-armed fd of ram1) | `EIO` | write ≥ 1 |
| A1, A2, A3 | `loop6p5`, `ram0`, INQUIRY on each sd disk | success | none |
| Q1, Q2 | N − 1 real nodes (every node except `persist`, never opened), `O_RDONLY`, zero length | `EPERM` (stock: `EBADF`) | discard / zeroout +1 each |
| Q3 | N − 1 (not `persist`), `CAP_SYS_ADMIN` dropped | `EPERM` (stock: `EACCES`) | roset +1 |
| Q4, Q5 | D, nonexistent partition 250 / rescan, admin dropped | `EPERM` (stock: `EACCES`) | blkpg / rrpart +1 |
| Q6, Q7 | D, WRITE(10) of 0 blocks / SYNCHRONIZE CACHE, no data, rawio dropped | `EPERM` (stock: `EPERM`, +0) | scsi +1 |
| Q8 | G, as Q6 | `EPERM` (stock: `EPERM`, +0) | sg +1 |
| Q9 | B, as Q6 | `EPERM` (stock: `EPERM`, +0) | scsi +1 |
| Q10 | U, a 36-byte `ufs_bsg_request` (QUERY_REQ, READ DESCRIPTOR of the DEVICE descriptor), rawio dropped | `EPERM` (stock: `EPERM`, +0) | bsg +1 |
| Q12 | D, `UFS_IOCTL_QUERY` READ of `bBootLunEn` | `EPERM` (stock: the attribute is read) | scsi-ioctl +1 |
| Q13 | D, `IOC_PR_REGISTER`, admin dropped | `EPERM` (stock: refused) | pr +1 |
| Q14 | D, `SG_SCSI_RESET_NOTHING`, admin and rawio dropped | `EPERM` (stock: `EACCES`) | scsi-ioctl +1 |
| H, H' | the 14 content rows (7 decoys, R1–R5, R7d `misc`, R8 `devinfo`) | PASS, every after-hash = its before-hash; R1–R5 = the expected values; the first failure stops the rest | none |

**Q10 and Q12 offline.** Q10 now runs in QEMU on a real UFS host model: the test kernel adds `ufshcd-pci` and
`ufs-bsg` (with a test-only PCI id for QEMU's UFS controller, `tools/blkguard/vm/qemu-test-only-ufs-pci-id.patch`,
never in a device kernel), so `/dev/bsg/ufs-bsg0` and the UFS well-known LUNs exist; `ufs-device` runs Q10 (refused,
bsg +1) and Q9 on the well-known LUNs, and `ufs-strict` adds **C19**, the same UFS query with full capabilities, which
the stock kernel would execute and the guard refuses (bsg +1). UML has no UFS host, so Q10 cannot run there. **Q12
cannot run in QEMU:** `UFS_IOCTL_QUERY` is installed by Qualcomm's `ufs-qcom` vendor driver, which binds only to
Qualcomm UFS hardware; QEMU's PCI UFS host has no driver ioctl (the probe skips Q12 there and says so). Q12's path
(`scsi_ioctl` to the host driver's ioctl) runs in UML on `scsi_debug`'s host ioctl, and the `no-scsi-ioctl` mutant
shows it fails without the hook. What only the device run establishes for Q12: that on the unit's own `ufs-qcom`
host the guard refuses the vendor query before the driver sees it (scsi-ioctl +1 on each of the 6 disks), with the
query built as a read so that an unguarded kernel would only read `bBootLunEn`.

The classifier (`host/fs-classify-k1g.ps1`) requires every series above with `fail=0`, the consistency
Q1 = Q2 = Q3 = N − 1 (persist never opened: one `SKIP  Q*` line naming the node of the `PRE scope` line), H = H' = 14 content rows (no row outside the allowlist), and Q4 = Q5 = Q6 = Q7 = Q12 = Q13 = Q14 = D, the five R rows before and after and the two R6 rows,
`HASH verify: <n> nodes, 0 failed or changed`, equal row digests, the eight guard lines (mode strict, sealed 1, the
allowlist above, modules_disabled 1, hazards none, a positive refusal total), fs-supervise `end=exited code=0`, no
stderr, and no Q11, C* or test-kernel marker. It also requires a valid positive **MemTotal** (FS-R-013 §2).

## 7. Conditions carried from FS-R-013 (host side; `host/*-k1g.ps1`)

- **Order:** K1g opens only after BOTH K1a attempts have bound, clean K1A PASS outcome records (Unit 2, then Unit 1);
  Unit 1's K1g only after Unit 2's clean K1G PASS and A5 (reported to the PM). Any REVIEW, FAIL, INTEGRITY FAULT,
  INCONCLUSIVE or missing record blocks; no shortcut. **No automatic repeat** (enforced: a unit with any earlier
  K1g attempt in the ledger, whatever its outcome, is refused; a repeat needs a reviewed package revision or the
  Chair's ruling).
- **The K1a-gate interaction (note for the Chair and the PM).** The K1g order gate (`host/fs-k1g-units.ps1`) is
  fail-closed over **every** K1a attempt of both units: each must be a bound, clean K1A PASS. So if the Chair
  authorises a K1a repeat (for example after a K1a INCONCLUSIVE), the earlier non-PASS K1a attempt stays in the
  ledger and **K1g stays blocked**, even after the repeat passes, until a reviewed revision of this gate names the
  superseded attempt. That is deliberate (no silent override of a K1a record); it means a K1a repeat must be followed
  by a K1g gate revision before K1g can open. The same applies to a K1g nonce-only repeat (§5).
- The single-reading admission rule (battery above 50 %, freshness, the named unit, status 3/4/5 below 35 °C or
  status 2 below 30 °C); BA/BF, presence and typed nonce; dwell ≤ 300 s; AF immediately on return to fastboot, then
  Android recovery and prompt AA; follow-ups at about +5 and +10 min after the end of AA, continuing while rising or
  concerning; immediate shutdown and cooling at ≥ 40 °C (physical shutdown and unplugging take precedence; never
  restart merely to obtain a reading); `../RECOVERY-K1g.md` (K1a's `RECOVERY.md` §4b for K1g, plus the guard's state across a hang and what a refused write looks like; `RECOVERY.md` stays pinned and unedited: the Th + 260 s fallback schedule, the immediate
  dump-mode rule, no EDL or flashing tool).
- Identity/slot before and after, with the Chair's sentence (FS-R-013 §3, verbatim): "misc, devinfo and
  partition-content invariance were not measured." and, as a separate K1g addition (not part of the Chair's text):
  "Within the K1g boot, the probe's fail-closed read rows measured the listed ranges before and after the guard
  cases." Optional after-rows are the PM's choice, not part of this package ([removed for publication]).
- The R0–R5 readback precondition (FS-R-012 §6) per unit, as for K1a.

## 8. Evidence (offline)

Stamp (r3): every row marked **r3** was regenerated for the image sources at `014c64d` (probe source `7226f45b…`,
binary `c1de030c…`, kernel `65740722…`, unchanged; candidate `1ee9f105…`). The r2 table below is kept as the r2 record: the files its **r2** rows point to
(scope, image delta, QEMU, UML, mutation, builder, image, host) now hold the r3 runs summarised here; its unmarked
rows (the kernel, its patch, the decision logic, kgate, the SHA-256 bench) are reused unchanged. Probe build record:
`fixtures/probe-build-r3.txt` (two builds byte-identical).

| suite | result | where |
|---|---|---|
| **r3: the 4K regression in the scope fixture** (J-207) | 89/89 (the 69 r2 cases plus 20): every fake node now has the unit's 4096-byte logical blocks and every `O_DIRECT` `pread` is checked as 5.10's `blkdev_direct_IO` checks it (offset, length and buffer a multiple of the block size, else `EINVAL`); dtbo/vbmeta/vbmeta_system nodes of partition size (1 MiB, 64 KiB, 64 KiB); each row alone on 4096- and 512-byte blocks (R3 reads 16,384, R4 8,192, R5 4,096; all reads 4096-aligned; the hash equals the expected value); the whole pass on both; a node exactly as long as an unaligned range fails closed before any read (`ERANGE`); a read returning less than its aligned length fails closed. **The same test against the r2 source: 61 failures**, R3, R4 and R5 `Invalid argument` (`RESULTS-scope-r2code.txt`) | `tools/blkguard/probe/test/test-scope.c`, `run-scope.sh`, `RESULTS-scope.txt`, `RESULTS-scope-r2code.txt` |
| **r3: QEMU on 4096-byte blocks** | **devicesim-4k 196/196 PASS**: the Quest-named virtio disks with `logical_block_size=4096` (GPT in 4096-byte LBAs, `tools/blkguard/vm/mkgpt.py`), R1–R5 = the expected v2.7 values, R6, R7d, R8; **devicesim-4k-mismatch** (R4 differs): every later row `not read`, ABORT; **devicesim-4k-r2code** (the same 4K run with the r2 source): `ROW H /dev/vdb3 bytes=0/12564 … -> Invalid argument`, every later row not read, ABORT before arming, as on Unit 2; every disk unchanged | `tools/blkguard/vm/results/qemu-devicesim-4k*.log`, `qemu-summary.txt` |
| **r3: UML on 4096-byte blocks** | strict-4k 156/156 and k1g-layout-4k 82/82 PASS with `scsi_debug.sector_size=4096` (strict-4k hashes the whole 4K SCSI disk in 1 MiB `O_DIRECT` reads and runs its guard cases; k1g-layout-4k, in testkernel mode, hashes only the probe's own decoys; the probe's VM-only SCSI decoy GPT is written in 512-byte LBAs, so on this disk the kernel finds no partitions and the partition cases do not run: hence 156, not 192. The unaligned ranges are tested on 4096-byte blocks only by QEMU devicesim-4k and the scope fixture) | `tools/blkguard/vm/results/uml-*-4k.log` |
| **r3:** every other suite on the r3 probe | identity 15/15 (host and aarch64); QEMU strict 213, boot-off 223, protect 181, device-mode 149, K1g layout 149, ufs-strict 224, ufs-device 169, devicesim 196, dupname/timeout/mismatch ABORT, quest-ident ABORT; UML 192/212/170/82/82, unpatched ABORT; mutation 15/15 runs detected (8 hooks; the same counts as r2); builder 56/56 (the candidate rebuilt byte-identical at its nonce; nonce-only OK); image smoke 11/11; host 71/71; timing bounds re-derived, unchanged | `tools/blkguard/`, `fixtures/`, the K1g host suite (private) |
| **r3: the image delta** | `PROBE-ONLY DELTA: OK` against the r2 candidate `d24d1559…`: the kernel bytes identical (42,969,600 bytes, `65740722…`); only `bin/fsbg-probe` changed (and `/init` by the nonce) | `fixtures/image-delta/RESULTS.txt` |

Stamp (r2): every row marked **r2** was regenerated for the image sources at `f5cf9f0` (probe source `37f11777…`,
binary `1d37e5f2…`, kernel `65740722…`, unchanged); the other rows are reused unchanged from the FS-A-014 package
(FS-R-014 §3: "Reuse unchanged evidence; submit the affected delta"). Later commits change documentation, review
records, host pins and evidence files only.

| suite | result | where |
|---|---|---|
| **r2: read scope and stop-on-first-failure fixtures** (FS-R-014 §3) | 69/69: the real content pass with every `open()` intercepted; 25 discovery orders with look-alike and unexpected names (persist, userdata, metadata, boot_b, BOOT_A, boot_a_old, `misc `, vbmeta, whole LUNs, persistbak, modemst1, fsc): only the 7 allowlisted partitions opened; the gate refuses excluded rows before any open; a duplicate name stops before any open; every failure kind (read error, range beyond the node, content differs, missing node, wrong R6 size) at every row: no later open; the after-pass stops at the first CHANGED row or read error (FAIL) and opens nothing with less than 1 s left (time); a failure before the real rows opens nothing; no reopen without `O_DIRECT`; `node_open_allowed` fails closed | `tools/blkguard/probe/test/test-scope.c`, `RESULTS-scope.txt` |
| **r2: the image delta** | `PROBE-ONLY DELTA: OK`: the kernel bytes identical to the FS-A-014 candidate's (42,969,600 bytes, `65740722…`); the header identical except the ramdisk size; only `bin/fsbg-probe` changed (and `/init` by the nonce); every other ramdisk file byte-identical | `fixtures/image-delta/RESULTS.txt`, `tools/image-delta-k1g.py` |
| decision logic (harness) | 74,272 checks, 0 failures (the kernel patch is unchanged) | `tools/blkguard/harness/RESULTS.txt` |
| **VM-only modes on real hardware** (FS-A-014 draft, MAJOR) | 15/15 identity/gate cases (host and aarch64): every VM-only mode refused on a Quest (device tree compatible/model, or the Quest's stock boot arguments) and on anything not positively a test VM; QEMU **quest-ident** (virt + the Quest's boot arguments + `fsbg.testkernel`): `ABORT: VM-only mode(s) testkernel refused` before anything | `tools/blkguard/probe/test/RESULTS.txt`, `tools/blkguard/vm/results/qemu-quest-ident.log` |
| **r2:** QEMU aarch64 (generic arm64 kernel, same patch revision, plus `ufshcd-pci`/`ufs-bsg` and the test-only UFS PCI id; probe source as recorded in `qemu-summary.txt`) | strict 213/213, strict from boot-off 223/223, protect 181/181 (vm mode: unchanged), device-mode 149/149 and K1g layout 149/149 (the decoy disks' `persist` partitions are now never opened), ufs-strict 224/224 (C19), ufs-device 169/169 (**Q10**); **devicesim 196/196 PASS** (R1–R5 = the expected v2.7 values, R6, R7d, R8; `PRE scope`; `hashed=79 MiB`; the three persist partitions never opened); **devicesim-mismatch** (R4 differs): every later row `not read`, ABORT before arming; devicesim-dupname ABORT before any open; devicesim-timeout `ABORT: time:`; quest-ident ABORT; every decoy, UFS LU and Quest-named disk unchanged on the host | `tools/blkguard/vm/results/qemu-*` |
| **r2:** UML (same tree and patch, test-only !SMP build fix) | 192/212/170/82 PASS, K1g layout 82/82 PASS (**Q12** on `scsi_debug`'s host ioctl); unpatched kernel ABORT; host decoys unchanged | `tools/blkguard/vm/results/uml-*` |
| **r2:** mutation (each hook disabled) | every mutant detected (8 hooks, 15 runs); protected-phase cases write nothing without the hook | `tools/blkguard/vm/results/mutants/` |
| SHA-256 implementations | portable and ARMv8 give the same digest over 64 MiB (= Python hashlib); host portable 98–131 MiB/s (19–25 cycles/byte at 2.59 GHz) | `tools/blkguard/probe/bench/sha-bench.c` |
| kgate on the exact K1g build | **gate PASS** (exit 0): crc 2601/2601, baseline 0/14059, Module.symvers = K1a's | `tools/kgate/validation/quest3/check-k1g.*` |
| bit-identical rebuild | **BIT-IDENTICAL** (run 1 = run 2) | `kernel/record/` |
| **r2:** image builder and its negatives | 56/56 PASS (incl. two same-nonce builds byte-identical, the candidate rebuilt byte-identical at its nonce, nonce-only OK/refusals) | `fixtures/builder/` |
| **r2:** QEMU-user smoke test of the image's PID 1 | 11/11 scenarios PASS (the probe meets a kernel without the guard and ABORTs having created nothing) | `fixtures/image/` |
| **r2:** host side | 71/71 PASS (the K1g host suite (private); the 14 content rows, Q1–Q3 = N − 1, PRE scope and the persist SKIP required, rows outside the allowlist flagged, fixtures k1g-timeabort/-budgetabort); `fs-nonceonly-k1g.ps1` on the candidate and a fresh-nonce rebuild: `NONCE-ONLY REBUILD: OK`; a test-override build refused | the K1g host suite (private) |
| **r2:** candidate image (superseded by r3 `1ee9f105…`; its Unit 2 attempt was K1G REVIEW, J-207) | `build\k1g\20261018T004649Z-a6718ea6bc4fe516\boot-k1g.img` `d24d1559…f4742a4` (built at `f5cf9f0`; kernel run 1, unchanged; probe `1d37e5f2…`, source `37f11777…`); the FS-A-014 candidate `c3c92a09…` is kept as the delta reference and recorded as withdrawn (halted by FS-R-014 §3) | the K1g sign-off sheet (private) |

What the evidence cannot show: the K1g kernel booting (no QEMU model of the Quest 3) and the guard acting on the
unit; that is the device step. Guard counters and unchanged sampled hashes cover the tested paths and ranges only
(FS-R-013 §6).

## 9. Residuals (FS-R-013 §6(3), honest list; design note §6)

The guard does not settle: device settings reachable through sysfs (sd `cache_type`, UFS `wb_on`, power levels);
GPIO, I2C, firmware loading and NVM writers; EFI variables; PCI/DMA; other privileged kernel or device interfaces;
and it assumes a trusted kernel and secure world. Refusing USB disks and pass-through on every device is deliberate,
conservative over-protection for K1g and the isolated R-1 experiment, not a product default.
