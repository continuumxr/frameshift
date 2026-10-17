# Stage 3d - standing repeats under FS-R-012 (the operative checklist)

**Status: DRAFT (2026-10-15; adversarially reviewed, fixes applied in 416f33e; for the Chair in FS-A-013).** This file carries the conditions of the Chair's binding ruling
FS-R-012 (private review record) (§3, §4, §5, §6; J-178) for every **standing repeat** of the fixed stage-3d display package.
It is **not** one of the 19 pinned host files and does not change any of them: the pinned package (`SIGNOFF-3d.md`
host-pin table, `WALKTHROUGH.md`, the host tools) stays byte-for-byte as reviewed (FS-R-012 §6: "do not silently alter
the 19-file standing package"). Where this file and the walkthrough differ, **this file adds conditions; it never
relaxes one**. Where this file and FS-R-012 differ, FS-R-012 controls.

The procedure itself is `WALKTHROUGH.md` steps 0 to 18 (cross-referenced below as "step N"); the console texts and
the gates are `../SIGNOFF-3d.md` A to F. Nothing here is copied from them; it says what must be true **around**
them for a repeat to be covered by FS-R-012 §4.

Tags: [M] measured · [M-static] artifact · [D] derived · [C] unconfirmed · [O] open.

---

## 1. Scope: the fixed package only (FS-R-012 §4)

A repeat is covered only if **all** of these hold. Anything else is not a standing repeat (§7 below).

| item | the fixed value |
|---|---|
| reference image | `fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5` (`build\stage3d\20261014T014738Z-<attempt nonce withheld>\boot-stage3d.img`) |
| fs-pattern | v0.7.1 `bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a` (step 0-pre; `BUILD-RECORD.txt`) |
| host tools | the **19** pins of the post-829da45 `SIGNOFF-3d.md` host-pin table, within package zip `2a8cd98dc2b0d060f73e4a3e052f10466762ddd286bfb0212c368101d4f8f9ed` |
| units | Unit 1 `QUEST3UNIT1`, Unit 2 `QUEST3UNIT2` (one unit per run) |
| firmware | build `52433670036000520`, slot A (`_a`), kernel `5.10.246-gd7102a837402` |
| vbmeta digest | `66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a` (BA16) |

- **The spent nonces are references only.** `<attempt nonce withheld>` (Unit 1, J-144) and `<attempt nonce withheld>` (Unit 2,
  J-146) are SPENT; their images are references, never execution candidates (FS-R-012 §4). `<attempt nonce withheld>`
  (the first candidate, v0.7) is also SPENT (FS-R-012 §1: refused before boot, then a boot with RESET NOT DONE /
  too_many_modes), and `2b2596964c0812b1` (superseded, never booted) is withdrawn: neither is ever used (step 0).
- **A fresh single-use nonce each time**, from a nonce-only rebuild of the reference, with the actual-image nonce-only
  check `fs-nonceonly3d.ps1` printing `NONCE-ONLY REBUILD: OK` (step 0; the observer repeats the check).
- **The master attempt ledger** `build\stage3d\attempted\` (and `abandoned\`) is kept as is: every spent nonce stays
  recorded; nothing in it is deleted, moved or reused (README §6 item 1; HOST.md §2 item 1).
- The 19 host pins are the `Get-FileHash` list of step 1; the 4 stage-3d docs (`README.md`, `HOST.md`, `IMAGE.md`,
  `WALKTHROUGH.md`) and this file are not in that list.

## 2. Before every repeat: the kernel-WARNING review (FS-R-012 §3) - the Arbiter

The pinned classifier does not report kernel WARNINGs in every phase (that is for its next reviewed revision), so
**before every repeat** the Arbiter inspects by hand **every phase's decoded probe output** of the most recent run(s),
including **p0** and the **reset (r1)**, and r2 (and r3 if it ran):

1. Decode each phase record of the most recent run on each unit with the reference decoder, from the repository
   root in `powershell.exe`, one phase at a time (as in FS-A-012 §5). The decoder does not create its `--dump`
   folder: first `New-Item -ItemType Directory <cycle>\warning-review\<ph>` (`<cycle>` of the run reviewed).

   `python -I -B devices\quest3\common\tools\fsb1.py check --exp s3d_<ph> --nonce <nonce> --chal <chal> --steps <steps> --dump <cycle>\warning-review\<ph> <observe dir>\collect\phase-<ph>.raw`

   - `<ph>` and `<steps>` (the classifier's `S3dSteps`): `p0` `hash,probe0`; `r1` `probe1,pattern1`; `r2`
     `probe2,pattern2`; `r3` (only if it ran) `probe3,pattern3`;
   - `<nonce>`: the run's nonce; `<chal>`: the 32-hex `chal=` of that phase's own `FSB1 BEGIN v=1 exp=s3d_<ph> …`
     line in `phase-<ph>.raw` (fresh per phase);
   - it must print `VALID` and one `step` line per step; `<N>.out` is step N's stdout (each equal to its STEP
     `out_sha256`), `<N>.err` its stderr. Anything else: the record is not reviewable; PAUSE (item 5).
   - Checked offline on `<attempt nonce withheld>` r1 (2026-10-15): `VALID`, and `1.out` is byte-identical to the
     FS-A-012 drafting file `decoded-drafting-20261014/r1-probe1.out`.

   Read every probe output (`probe0` … `probe3`) **and** every `.err` in full, not only the classifier's summary.
2. List every `WARNING:` trace (with its call chain), every `*ERROR*` and `[sde error]` line, per phase.
3. Compare with the **known baseline** (FS-R-012 §3; README §3, "Observed on v2.7"; FS-A-012 §5.4.3/§5.4.4):
   - r1 (reset): the **two** documented `WARNING … drm_atomic_helper.c:229 set_best_encoder` traces (step A's
     TEST_ONLY check and its commit);
   - r1: the **planned -7 rejection** of B's first, single-plane TEST_ONLY (`_sde_crtc_check_plane_layout` "invalid
     horizontal destination", `crtc… failed plane layout check -7`), then `reset_on_split` accepted and committed,
     `reset_close rc=0`;
   - p0: the 23 `dsi_display_dfps_calc_front_porch … Invalid new_hfp` driver-init lines documented in FS-A-012
     (not WARNINGs; recorded; a change in them counts as an unexplained change below).
4. **Append the findings to the report** of that run (a dated file `<cycle>\warning-review-<utc>.txt` of the run
   reviewed, marked as a later review, plus the summary in the next relay). Before the **first** repeat after
   FS-R-012 this covers both spent runs (`<attempt nonce withheld>`, `<attempt nonce withheld>`), all phases, not only r1 and p0.
5. **PAUSE standing repeats for review** (no further repeat until the Chair has reviewed it) on any of:
   - a new WARNING (any phase), or a baseline WARNING more or fewer times;
   - a changed reset outcome (anything but `RESET-DONE` with the records above, e.g. `RESET-NOT-DONE`,
     `ALREADY-INACTIVE`, another rc);
   - a recovery fault (the unit did not return to fastboot by itself, a manual power-off was needed, a crash-dump
     mode, a missing AF/AA);
   - any other unexplained change against the earlier runs.
- The classifier's **"dmesg-flags=none" is r2-only** and limited to its filter; it never stands for p0, r1 or r3.
- The reset is the unchanged A/B/C reset. Dropping step A is not a nonce-only change and is outside this file
  (FS-R-012 §3).

## 3. Each repeat: the conditions in order (FS-R-012 §4)

| # | condition | where |
|---|---|---|
| 1 | fresh nonce, nonce-only check, ledger | §1; step 0 (and step 0-pre for the fs-pattern hash) |
| 2 | the §2 warning review of the last run(s) is done and shows no pause condition | §2 |
| 3 | **matched host pins** and **preflight `preflight OK` before BA** | step 1 (pins), step 2 (phase A checks pins and image); `fs-observe3d.ps1 -Preflight` (`SIGNOFF-3d.md` A) |
| 4 | phase A's automatic checks run **every cycle**; standing acceptance and carry-over only as implemented (same tool set, same PC day, unchanged speakers) | step 2 (steps 3, 4 only if named) |
| 5 | the **serial, firmware, slot and module-index** conditions: `-Serial` names the unit; BA04 `_a`, BA16 the vbmeta digest, BA20 `user`, BA23 the serial, BF02 `current-slot: a` (the observer refuses otherwise); the image's module-index check (README §1, §6; a refusal shows as "no gadget", back in fastboot about a minute later) | steps 6, 7, 9; `SIGNOFF-3d.md` C |
| 6 | the console checklist with a **fresh B** and a **fresh E** (never carried over) | steps 5, 8 |
| 7 | **the PM present** at the headset and **typing the nonce** (`-ConfirmNonce`) | steps 8, 9 |
| 8 | entry temperature reading (§4 below), **BA/BF**, the **five-minute dwell limit** (BA start to boot, ≤ 300 s), then **AF/AA** | steps 5 to 9, 16 |
| 9 | device timing unchanged: **DEADLINE 200 s**, **backstop 201 s**, **idle limit 120 s**, **phase guards 34/68/82/64 s** | README §1 and §6 item 9; `tools/check-timing-3d.py` CONSISTENT (pinned); built into the reference image (nonce-only rebuild) |
| 10 | the **unchanged reset** (A/B/C), the conditional diagnostic phase (run 3) and the runtime writes as reviewed | the image; README §3 |
| 11 | **one step at a time**: the Arbiter gives the next step only after checking the result (and any recovery) of the current one | the walkthrough's rule |
| 12 | the **follow-up reading(s) after AA** (§4.2 below) | after step 16 |
| 13 | the **statement of §5** in the report; raw battery output kept (§6) | §5, §6 |
| 14 | **reporting in the next relay** (the run, its warning review, its readings, departures) | the next FS-A relay |

Unit 2's IPD/proximity and Unit 1's proximity
faults are recorded, never compensated.

## 4. Thermal conditions (FS-R-012 §5)

### 4.1 Entry: one reading (unchanged; enforced by the pinned tools)

- one valid, fresh `dumpsys battery` reading on **the named unit** (step 5; at most 900 s before BA);
- temperature **below 350 (35.0 °C)**;
- status **3, 4 or 5** accepted; status **2 (charging) only below 300 (30.0 °C)**; status 1 never;
- **BA10** independently satisfies the same rule;
- battery level **above 50 %** (the observer checks it at BA10; the Arbiter also reads the `level` line at step 5);
- the dwell and the recovery are unchanged.

These are bench admission conditions for this short, attended test, not a general thermal policy. Status 5 is an
accepted reported state, not proof of zero charging current or of thermal equilibrium.

### 4.2 After AA: the MANDATORY follow-up reading(s)

**This overrides J-145's PM decision that the post-run follow-ups "can end once the headset is back in Android at a
normal temperature".** FS-R-012 §5: "DO NOT CONCUR with dropping follow-ups merely because Android booted." (J-145's
other part, a reading while charging accepted below 30.0 °C, stands as accepted in §4.1.)

1. **AA10 at 400 (40.0 °C) or more: the ≥ 40 °C procedure at once** (`../RECOVERY.md` "Battery after the attempt":
   power-menu power-off while connected, physical observation that the unit is off, then unplug; shutdown and unplug
   are two separate observations). No follow-up reading is taken by rebooting.
2. Otherwise **at least one scheduled reading about 5 minutes after AA** (AA = the end of the AA capture, step 16).
   The pinned phase-E text (`SIGNOFF-3d.md` E) schedules +5 and +10 min, then every 5 min while it rises: follow it;
   it satisfies this minimum.
3. **Continue** (every 5 min) while the temperature is **rising or concerning** (operational reading of "concerning":
   350 or more, or higher than the reading before). Any reading at **400 or more: the ≥ 40 °C procedure
   immediately**.
4. **A physical shutdown and unplug-to-cool takes precedence** over any reading. **Never reboot (or power on) only to
   obtain a temperature reading.** If the unit is off, the follow-up is recorded as "not taken: unit off (cooling)"
   with the time.
5. The highest observed reading is recorded.

**The follow-up command (read-only; the PM types it in the same `powershell.exe` (Windows PowerShell 5.1) window, from
the repository root, with the headset in Android; `<n>` = 1, 2, …):**

```
cmd.exe /d /c "adb -s <serial> shell dumpsys battery > <cycle>\followup-<n>-battery.txt 2>&1"; [DateTime]::UtcNow.ToString('o'); Get-Content -LiteralPath <cycle>\followup-<n>-battery.txt
```

- It is the walkthrough's own reading (step 5: `adb -s <serial> shell dumpsys battery`, then the PC's UTC on the last
  line), with the output redirected **inside the quoted `cmd.exe` string**, so `cmd.exe` (not PowerShell) writes the
  file and the raw bytes are kept (`<withheld document>` §2 explains why a PowerShell `>` would re-encode them).
  `Get-Content` only displays the file. Nothing is written on the headset.
- The PM reports the `temperature`, `status` and `level` lines and the UTC line.
- **Logged:** the raw file `<cycle>\followup-<n>-battery.txt` (raw capture, never edited) and one line per reading in
  `<cycle>\followups.txt`, written by the Arbiter at the time (contemporaneous note): `<n>`, the UTC, minutes after
  AA, temperature, status, level, the raw file's SHA-256, who read it. Both go into the run's attempt log and the next
  relay.

## 5. Persistent state: the required statement (FS-R-012 §6)

Identity, slot and lock before/after checks (BA/BF/AF/AA on the user-build rows) are accepted for these repeats. Each
repeat's report includes, verbatim:

> misc, devinfo and partition-content invariance were not measured.

The vbmeta-digest comparison is a derivation, not readback proof; the module-index pin checks the
index files, not every module's bytes. The derived-baseline exception is for this display package only.

## 6. Records: raw, contemporaneous, later

- **Raw battery output** is kept wherever there is one: the step-5 console output, `ba10-battery.txt`,
  `aa10-battery.txt`, each `followup-<n>-battery.txt`.
- Keep three kinds of record **distinct** and label them:
  - **raw captures** (tool outputs, `capture.raw`, the battery files): never edited;
  - **contemporaneous notes** (`notes.txt` with the PM's own words, `followups.txt`, the attempt log written during
    the run);
  - **later amendments** (re-runs of the classifier, decoded probes, the warning review, corrections): in separate,
    dated files or sections marked "later", naming what they amend; never written into a raw capture or presented as
    console output.
- A blank checklist field is a departure to report, not something to fill in afterwards (FS-R-012 §1).

## 7. What a standing repeat does NOT cover (FS-R-012 §4, last paragraph)

A different image or host package (including any change to the 19 pinned files or to this package's device side),
another firmware or device, **debugfs**, **calibration reads**, **GPU command submission**, **Valve userspace**,
**flashing**, an **installed boot**, or **another backlight control**. Each needs its own concrete, reviewed package.
No additional display repeat is required to "earn" the milestone, and none is a prerequisite for the stage 3/4 work.
