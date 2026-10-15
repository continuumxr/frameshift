# Meta Quest 3

**Active — primary target (PM ordering, 2026-10-09; J-37). Stage 1
ACHIEVED (FS-R-005, 2026-10-08).** The Quest 3S has its own directory,
`devices/quest3s/`, and receives Quest 3 kernel/OS changes in lockstep.

- **SoC:** XR2 Gen 2, Qualcomm platform `anorak` [M]; Adreno 740v3
  (`0x43050b00`).
- **CPUs:** 2 + 4, max 2.05 / 2.36 GHz [M].

**Unit 2 hardware note (PM report, 2026-10-09):** faulty IPD slider, which
has caused issues on newer firmware; may matter for SteamOS (IPD sensing).
Record it in Unit 2's baseline and the checklist before using Unit 2 as the
v2.7 platform (J-69).

**Status (2026-10-11):** Stage 1 achieved. Trial (i) (stage 2a) registered
COMPATIBILITY FAIL at step 4, a listing-rule defect (FS-R-009). Trial (iii)
(stage 3a display) registered INCONCLUSIVE, with no light seen (FS-R-010;
kept INCONCLUSIVE by FS-R-011 §3). **Trial (iii-b)** (`stage3b/`, image
`ea60d6cd…5841`, nonce `6cf0f15867f14edc`) is **concurred to execute by
FS-R-011 §1 (J-104)**: Unit 1, v66 slot A, one temporary boot, no
flash, no retry, DEADLINE 200 s / backstop 201 s, the 91 s runner guard, the
PM physically present with the reviewed sign-off, recovery procedure and
registered outcomes. Clarifications A (three extra host pins) and B ("dark
gap" wording) are recorded in `SIGNOFF.md`. **Run 2026-10-11 (J-107):** machine
side PASS; run 1 dark (the panel was handed over asleep), run 2 lit but garbled
(per-pipe throughput exceeded, J-108/J-109). Next: the stage-3c rerun
(`stage3c/DESIGN.md`). Overview: root `README.md`.

**Units (PM, 2026-10-08; Unit 2 identified 2026-10-10, J-83):**
- **Unit 1** (`QUEST3UNIT1`): v66, slot A; `fastboot boot`
  only, **never flashed**. All trials so far ran on it.
- **Unit 2** (`QUEST3UNIT2`): was v71 `50352750111100511`,
  slot `_b`. Reserved for the first `fastboot flash` work, after its
  baseline. An official stock-firmware update was started by the PM; the
resulting state is not yet recorded. **FS-R-011 §8
  (J-104):** before **any** FrameShift action on Unit 2, establish its
  resulting fingerprint, slot, kernel and effective firmware inputs, and do
  not reuse the v71 identities above as v2.7 identities. The trial (iii-b)
  concurrence does not migrate to Unit 2.

**Build target: v2.7** (`5.10.246-gd7102a837402`):
- public source `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f`;
- clang r450784e (14.0.7);
- the stock v2.7 vendor modules need `module_layout 0xb1f01218`.

**Stage 1:** the stock kernel plus our initramfs, started with
`fastboot boot`. Verified USB ACM channel; HOST_ACK; recovery to Android.
Builder and observer in `stage1/`. Result: FS-A-005 (private review record).

**Kernel rebuild gate (v2.7): PASSED (steps 2 and 3).**
- The public source reproduces all 2601 vendor-required CRCs.
- Adding DEVTMPFS, FHANDLE, AUTOFS=m, BTRFS=m, USER_NS and PID_NS changes
  no existing CRC.
- SYSVIPC and POSIX_MQUEUE are still excluded: they change layouts
  (JOURNAL J-31).

**Trials (Unit 1, temporary boot):**
- `stage2a/`: trial (i), Valve's loader, libc, `uname` and `b2sum` on the
  stock kernel. 2026-10-09; FS-A-009 / FS-R-009.
- `stage3a/`: trial (iii), the first static display pattern. 2026-10-10;
  FS-A-010 / FS-R-010; spent.
- `stage3b/`: trial (iii-b), a bright pattern run twice with the backlight set
  to 127, and paced FSB1. Built (J-82); concurred to execute by FS-R-011 §1
  (J-104); **run 2026-10-11** (J-107): machine PASS, run 1 dark, run 2 lit
  but garbled; cause analysed in J-108/J-109.
- `stage3c/`: the rerun, in design (`stage3c/DESIGN.md`, J-109): interactive
  per-phase flow, 4 × 1032 planes with explicit zpos, optional run 3.
- Shared PID 1 infrastructure is in `common/`, host tools in `host/`, and
  procedures in `RECOVERY.md` and `SIGNOFF.md`.

**Next (2026-10-11):** the attended trial (iii-b) on Unit 1 (concurred,
FS-R-011 §1), one step at a time, then its return package (FS-R-011 §9).
Then Unit 2's new baseline after its firmware move (FS-R-011 §8). *(The earlier "Next: FS-A-006" list was
done: FS-A-006 was ruled by FS-R-006.)*

**Safety:** `docs/PROJECT_SETUP.md` §6A; status in
`docs/DEVICE_PORT_CHECKLIST.md`.
- Android userspace enforces the skin and battery shutdown thresholds; the
  kernel DT also mitigates (`batt-virt-limit`, `surf-virt-limit` CPU maps).
  The GPU has a kernel devfreq cooling path; whether it acts autonomously
  is [O] (FS-R-006 §4).
- The fan is capped at `silent_rpm` (4000 RPM) on panel blank, not stopped, **on v2.7** [M-static, DT]. **On Unit 1's v66 the fan driver stops the fan on blank** (FS-A-008 §3; PROJECT_SETUP §6A.3).
- Battery data comes through the ADSP.
- **Never use the bootloader menu's "Switch Boot Slot" option.** It was added in Meta firmware of the v74–v83 era; per the PM it does nothing useful and can brick the unit [PM report, 2026-10-10, J-75]. Whether the Quest 3 menu has the same option on its firmware is [O]; never use it either way.

**Research:**
- `docs/research/FS-A-006-*.md`
- `docs/research/perf-envelope-quest3.md`

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
