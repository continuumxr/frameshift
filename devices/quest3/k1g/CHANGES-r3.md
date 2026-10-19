# K1g revision 3: changes and reasons (for the Chair)

**Status:** built offline on 2026-10-19 on branch `feat/k1g-r3` (base `master` `a537251e`). No device command was run.
**Pending the Chair.** FS-R-015 §4 concurred K1g r2 (candidate `d24d1559…`, probe `1d37e5f2…`); its Unit 2 attempt
(nonce `<attempt nonce withheld>`, J-207) is **K1G REVIEW**: the probe failed closed before arming. r3 is a probe-only change
and needs the Chair's ruling before any attempt uses it. The Unit 2 r2 record
(private evidence) is unchanged.

| pin | r2 (concurred, FS-R-015 §4) | r3 |
|---|---|---|
| probe source `fsbg-probe.c` | `37f1177789ed3fcf015797393167577c787b4774d3b0371c32455fcd1734a019` | `7226f45b2742b755f6fdef1d6cb5ace35f0801344e9fc7ceaa0d2c8b1ff17890` |
| probe binary (`build-probe.sh`, two builds byte-identical: `fixtures/probe-build-r3.txt`) | `1d37e5f2384cbdb946cbd6ed3756829d6fa14631b2e17120ff21dcd7c0ca5cf9` | `c1de030c51f1ee4b785c96b1f497bc6339d2b404f2431f07edf3aac39375077d` |
| candidate image (45,002,752 bytes) | `d24d155966ac45e9005e85d2a6c00cef585c4967bd67890e9d75dc7b1f4742a4` | `1ee9f1059d91b1f100e6bde31910980c65befa42c5dd5b8de12e38d187ff2ce4` |
| K1g kernel (Image) | `65740722b532b4235e2d35b517bf70d7753e63f42b7b7ee5c869117d999042d3` | **unchanged** (byte-identical, `fixtures/image-delta/RESULTS.txt`) |
| the K1g sign-off sheet (private) | `ceee35b4252fcce788b566bcd87639faee6e4e415ecece1649a8873162558ffc` | `782e2a77e623aaeaf0c34908da2061ff32aa53b95d574bcf50277f36dd7e1c7e` |

## 1. The defect (J-207)

- **Evidence (Unit 2, r2).** The decoded FSB1 record (`fsb1.py check --exp k1g --nonce <attempt nonce withheld> --chal
  6acb86dda984bb82a5f16bf46dbc1a17`, 9 steps, VALID) has, in step 9: R1 `/dev/sde9` 61,607,936/61,607,936 PASS, R2
  `/dev/sde20` 5,058,560/5,058,560 PASS, then `ROW H /dev/sde13 bytes=0/12564 … -> Invalid argument`, every later row
  "not read", `ABORT: 1 hashing row(s) failed closed before arming (6 later row(s) not read)`. The probe records no block
  size. **Unit 1's** boot log does [M]: every UFS LUN (sda–sdf) has **4096-byte logical blocks**
  (FS-A-005, run on `QUEST3UNIT1`: FS-A-005 (private review record) lines 505–535; `sde`
  is 1,048,576 × 4096 bytes). For **Unit 2** it is derived [D]: the same model and storage layout, and exactly the
  refusal pattern that rule predicts (R1, R2 aligned and passed; R3 unaligned and `EINVAL`).
- **Cause (confirmed).** `hash_node_do()` rounded each `O_DIRECT` read up to 512 bytes (r2 `fsbg-probe.c:517-522`).
  Linux 5.10 `blkdev_direct_IO` refuses (`EINVAL`) an offset, length or buffer that is not a multiple of the device's
  logical block size. R1 and R2 are multiples of 4096 and passed; R3 `dtbo_a` 12,564 → 12,800 is not, so `pread`
  returned `EINVAL` before any byte was hashed (`bytes=0`).
- **Which rows would have failed** (same rule): R3 `dtbo_a` (12,564 → 12,800), **R4 `vbmeta_a`** (5,632, already a
  multiple of 512, not of 4096) and **R5 `vbmeta_system_a`** (3,136 → 3,584). R7d `misc` (1,048,576) and R8 `devinfo`
  (4,096) are multiples of 4096 and would have passed; R6 (sizes) does no read.
- **Why the tests missed it.** The QEMU/UML disks and the scope fixture were 512-byte devices (or plain files with
  `O_DIRECT` stripped). r1's `O_DIRECT` → plain reopen (removed under FS-R-014 §3.3) had masked the same refusal.
  The r2 review (R6) asked for the 512-byte round-up to be disclosed; nobody checked the unit's block size. The
  r2 README disclosure (b) ("the accepted Android rows read whole 4 KiB pages anyway") was wrong.
- **What it did.** It failed closed as designed: no row after R2 was opened, the guard was never armed, no guard
  test case was attempted (J-207).

## 2. The fix (probe only)

- Each read is rounded up to **`DIO_ALIGN` = 4096** bytes, and only the row's bytes are hashed. 4096 is a multiple of
  512, so the same rounding serves the 512-byte decoys and VM disks.
- **A fixed constant, not `BLKSSZGET`:** the hashing open keeps `BLKGETSIZE64` as its only ioctl (as reviewed). No
  scope change. A device with logical blocks larger than 4096 would get `EINVAL` and fail closed.
- **Fail closed at the end of the node:** if the rounded read would pass the end of the node, the row fails
  (`ERANGE`, printed as its own reason: "the read rounded to 4096 bytes would pass the end of the node") before the
  read is issued. On a 4096-byte-block device a node's size is a multiple of 4096, so this path is defensive there. The r2 code fell back to an unaligned read there (`rd = want`).
- **The whole aligned length is required:** a read that returns less than its aligned length fails the row (r2 accepted
  any count ≥ the row's bytes).
- **Buffer:** `posix_memalign(DIO_ALIGN, 1 MiB)` (the same 4096 as before, now named); every read length ≤ 1 MiB; every
  offset is 0, a multiple of 1 MiB, or (head/tail rows, decoys only) the node size − 1 MiB.
- Bytes read beyond each range, all inside the same allowlisted partition: R3 16,384 for 12,564, R4 8,192 for 5,632,
  R5 4,096 for 3,136 (README §3 disclosure (b), corrected).
- **Unchanged (FS-R-014 §3 / FS-R-015 §4):** one open per row, `O_RDONLY|O_DIRECT|O_CLOEXEC`, no reopen; the allowlist
  gate before the open; persist never opened; the first failure stops every later read; the EIO retry is decoy-only;
  the timing bounds (`fixtures/bounds.txt`, re-derived: unchanged).

## 3. Tests

All silent (FS_SILENT=1), offline, on the final source `7226f45b…`.

| suite | r3 result | what is new |
|---|---|---|
| scope fixture (`test-scope.c`, `run-scope.sh`) | **89/89** | every fake node emulates 4096-byte logical blocks (`--wrap=pread`: offset, length and buffer checked as 5.10's `blkdev_direct_IO`); partition-size dtbo/vbmeta/vbmeta_system nodes; sections 10–12 (each row alone on 4096 and 512 bytes with its read lengths, the whole pass on both, `ERANGE` at a node end, a short aligned read) |
| the same fixture against the r2 source (`a537251e`) | **61 failures** | the regression proof: R3, R4, R5 `Invalid argument`; the whole 4K pass fails |
| identity (`test-identity.c`) | 15/15 host and aarch64 | unchanged |
| QEMU | strict 213, boot-off 223, protect 181, device-mode 149, K1g layout 149, ufs-strict 224, ufs-device 169, devicesim 196; dupname, timeout, mismatch, quest-ident ABORT (as r2) | **devicesim-4k 196/196 PASS**, **devicesim-4k-mismatch ABORT** (R4 differs, later rows not read), **devicesim-4k-r2code ABORT** with `ROW H /dev/vdb3 bytes=0/12564 … -> Invalid argument` (Unit 2's line reproduced); every disk unchanged |
| UML | 192/212/170/82/82, unpatched ABORT (as r2) | **strict-4k 156/156, k1g-layout-4k 82/82** on a 4096-byte `scsi_debug` disk (156 < 192: the probe's VM-only SCSI decoy GPT is in 512-byte LBAs, so that disk shows no partitions). Only strict-4k reads the 4K disk (whole, in 1 MiB reads) and runs its guard cases; k1g-layout-4k (testkernel mode) hashes only the probe's own decoys. The unaligned ranges are tested on 4096-byte blocks by QEMU devicesim-4k and the scope fixture only |
| mutation (UML) | 15/15 runs detected (8 hooks), the same counts as r2 | rerun on the r3 probe |
| image builder | 56/56 | the candidate rebuilt byte-identical at its nonce; nonce-only OK against a fresh nonce |
| image smoke (QEMU user) | 11/11 | rerun on the r3 candidate |
| host (the K1g host suite (private)) | 71/71 | rerun with the r3 pins |
| timing bounds (`check-bounds-k1g.py`) | PASS, unchanged | 6,656 bytes more read on the unit than r2 read (7,340 beyond the ranges), against 78 MiB in 0.38 s |
| image delta (`image-delta-k1g.py`) | `PROBE-ONLY DELTA: OK` | kernel `65740722…` byte-identical; only `/bin/fsbg-probe` and the `/init` nonce differ from `d24d1559…` |

The QEMU 4K runs are the closest offline model of the unit: a real 5.10-family kernel, real `O_DIRECT` on 4096-byte
virtio blocks, and the real v2.7 dtbo/vbmeta/vbmeta_system images. A first QEMU attempt during this work stopped
with `ABORT: time:` on the 128 MiB `mtdblock0` row in vm mode while another session's kernel build loaded the host;
it was stopped and rerun on an idle host (the committed logs).

## 4. Package changes

- `tools/blkguard/probe/fsbg-probe.c`: `DIO_ALIGN`, the read loop, the `ERANGE` reason (the only probe change).
- Pins: `k1g/build-image-k1g.sh` (`EXPECT_FSBG_PROBE`, `EXPECT_FSBG_PROBE_SRC`), `host/fs-observe-k1g.ps1`
  (`FsbgProbe`), `host/fs-nonceonly-k1g.ps1` (r3 the current candidate; r2 kept, withdrawn, as the image-delta
  reference), the K1g sign-off sheet (private) regenerated (two host pins changed: `fs-observe-k1g.ps1`, `fs-nonceonly-k1g.ps1`; the
  status text in the K1g sign-off tooling (private)).
- Tests: `test-scope.c`, new `run-scope.sh`, `run_qemu.sh` (`mkquest4k`, three 4K runs, `INITRD`), new
  `tools/blkguard/vm/mkgpt.py` (our own GPT writer for 4096-byte LBAs), `run_uml.sh` (two 4K runs).
- Docs: README status, §3 disclosure (b) (it was wrong about 4 KiB pages), §8 r3 rows; the design note §3;
  `review/REVIEWS-k1g.md` (r3 rows); this file.
- `.gitattributes`: `tools/blkguard/**/RESULTS*.txt text eol=lf` (J-207: CRLF working copies of the two RESULTS files
  made the image builder's clean-checkout check refuse on the Windows checkout).
- Evidence of the two probe builds: `fixtures/probe-build-r3.txt`.
- **Merge with history kept** (no squash or rebase): the candidate's MANIFEST names `checkout HEAD 014c64dd`, a commit
  of this branch. Cite `9ff2c938` or later for the package: `514bbbd9` accidentally captured the mutation suite's
  temporary edit of `run_uml.sh` (`fsbg.forceq`) and a `run_uml.sh.bak`; both were gone again in `9ff2c938` (no
  image source and no committed log was affected; the committed UML logs were made before the mutation run).
- The candidate was built with the probe at the builder's default path (`build/k1g/probe/fsbg-probe`, now the r3
  binary; the r2 binary is kept beside it as `fsbg-probe.r2-1d37e5f2`), so a fresh-nonce rebuild on the Arbiter's
  checkout matches the candidate's MANIFEST line for line.

## 5. For the Chair and the Arbiter

1. **Read scope (for concurrence).** The rows read up to the next 4096-byte boundary inside the same allowlisted
   partitions: R3 16,384 bytes for 12,564 (3,820 more), R4 8,192 for 5,632 (2,560 more), R5 4,096 for 3,136 (960
   more). FS-R-015 §4 accepted the r2 reads (12,800 / 5,632 / 3,584). The partitions are 24 MiB (dtbo_a) and 64 KiB
   (vbmeta_a, vbmeta_system_a), so nothing outside them is read; only the range's bytes are hashed.
2. **No new ioctl.** The fixed 4096 alignment was chosen over `BLKSSZGET`, so the reviewed "no other ioctl than
   BLKGETSIZE64" holds. A logical block larger than 4096 would fail closed (`EINVAL`).
3. **The order gate blocks r3 as committed (decision needed).** `host/fs-k1g-units.ps1` is unchanged:
   `Get-FsK1gPriorAttempts` refuses Unit 2 a new K1g attempt because the r2 attempt `<attempt nonce withheld>` is in the
   ledger, and Unit 1's gate requires every Unit 2 K1g attempt to be a clean K1G PASS, so the r2 REVIEW record blocks
   Unit 1 for good. FS-R-013 §5 allows a repeat only through a reviewed package revision or the Chair's ruling.
   The narrowest revision would name that one attempt (nonce, serial, outcome, and the SHA-256 `b01996d7…f593bd` of
   its bound `classify-k1g.json`) as superseded for both rules. It is **not** in this package: it relaxes a safety
   gate and needs the Chair's and the PM's decision first.
4. **Process lesson.** The r2 review asked for the 512-byte round-up to be disclosed but no one checked it against the
   units' block size, although Unit 1's boot log had it (FS-A-005). The harnesses now include 4096-byte devices.
5. J-207's "the test harnesses use 512-byte sectors" was true of r2; r3 adds the 4K runs (a new journal entry, not an
   edit).
