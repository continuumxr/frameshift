# Admission rule r2: charging readings at a high battery level (PROPOSAL for the Chair; not ruled)

**Status: PROPOSED, implemented on branch `feat/admission-r2` for review. Nothing on master changes until the Chair rules and the PM
merges. Every pin below is a runtime pin change that needs that ruling.**

## 1. The PM's direction (2026-10-23)

The PM directed that a new single-reading admission rule be proposed to the Chair: **"allow a run if the headset is over 70%
charge and under 35 celsius"**. The PM's reasons: the current values **"were arbitrary"**, and the rule **"is impeding our
progress"**.

## 2. The rule

Current (FS-R-012 s.5, FS-R-012 (private review record); the charging limit from J-145): a valid, fresh reading on the named unit; below 35.0 deg C;
BA10 independently satisfies the same rule; battery status 3/4/5 accepted; **status 2 (charging) accepted only below 30.0 deg C**;
battery level above 50 %.

Proposed (r2): identical, except that **status 2 is also accepted below 35.0 deg C when the battery level is above 70 %**
(status 2 at a level of 70 % or less still needs a reading below 30.0 deg C). As a formula, with T the reading in tenths of a deg C,
S the `dumpsys battery` status and L the level in %:

```
admit  =  100 <= T <= 349   AND   L > 50   AND   ( S in {3,4,5}   OR   S = 2 AND ( T < 300  OR  L > 70 ) )
```

Unchanged: the 10.0 deg C floor; the 35.0 deg C ceiling for every status; status 1 never; BA10 independently by the same rule; the
freshness (900 s) and the BA tie; the named unit; dwell and recovery; the >= 40.0 deg C procedure; the follow-up readings (at least one
around five minutes after AA, continue if rising or concerning, the last below 35.0 and not above the one before). Status 5 is still an
accepted reported state, not proof of zero charging current. These remain bench admission conditions, not a thermal policy.

## 3. Rationale and evidence

- **Unit 1 K1g r3, 2026-10-23** (nonce <attempt nonce withheld>, committed on master: `git show master:devices/quest3/evidence/unit1-k1g-r3-20261023/attempt-log.md`, `B-battery.txt`,
  `f/B-battery-0231-stopped.txt`): the unit sat at 31-33 deg C
  at 98-100 % with the status flipping between 2, 3 and 5. The 02:31Z reading (status 2, level 90, 330) STOPPED phase B ("while charging
  the reading must be below 300"). About an hour of passive readings followed (330, 310, 330, 320, status 2 at 98-100 %, one status 3 at
  03:12Z that met the rule but was missed) until a status 5 reading (320) at 03:32Z passed. The wait was caused by the charger's status
  report, not by a thermal change: the same unit was at 31-33 deg C in all of it, and the admitted BA10 (status 5, 310), AA10 (status 3,
  330) and follow-ups (status 2, 330; status 5, 330) were no different. A fully charged, plugged-in headset reports 2, 3 or 5 at the
  controller's whim.
- **Unit 2 N1 r3, 2026-10-23** (nonce <attempt nonce withheld>). The record is committed on master, not on this branch (cite it with
  `git show master:<path>`): `devices/quest3/evidence/unit2-n1r3-20261023/attempt-log.md`, `B-battery.txt` and
  `f/B-battery-0440-stopped.txt`. The first reading at 04:40:21Z (status 2, level 95, 300) STOPPED phase B ("while charging the
  reading must be below 300"). Passive readings 30 s apart held at 300 with status 2 at 95-100 % for about 30 minutes, until status 5
  at 05:12:19Z; the formal reading at 05:12:39Z (300, status 5, level 100) passed. The unit was at 30.0 deg C throughout; only the
  charger's status report changed. The later readings were no different (AA10 status 3, 320; follow-ups status 2, 330 and
  status 5, 320). Under r2 the 04:40Z reading (status 2, 95 %, 30.0 deg C) would have been admitted.
- **The old 30.0 deg C charging limit** (J-145) was a precaution set before any of this data; the PM reports the numbers were arbitrary.
  The evidence is that a temperature of 30-35 deg C at a high charge is ordinary for a plugged-in unit and the status flag does not
  separate "safe" from "unsafe".

## 4. The Chair's original concern, and what stays

The Chair's concerns (FS-R-012 s.5): heat while charging, and **delayed temperature rises after AA** ("DO NOT CONCUR with dropping
follow-ups merely because Android booted. These records themselves show delayed rises after AA."). r2 does not touch the follow-ups, the
>= 40 deg C procedure or the physical-shutdown rule. What r2 gives up: a status-2 reading between 30.0 and 34.9 deg C is admitted at a
high charge. What bounds it: 35.0 deg C stays a hard ceiling at phase B and at BA10; the level must be above 70 % (a unit still taking
a large charge, where the charging heat is greatest, is not admitted); BA10 is checked independently by the same rule; the follow-ups
and the stop at >= 40.0 deg C are as before.

## 5. Implementation (branch `feat/admission-r2`)

ONE shared function, `Test-FsAdmissionBatteryRule` in the new `devices/quest3/host/fs-admission-r2.ps1` (text arguments; returns `$null`
or the reason; also holds the T < 350 limit and the limit constants). Dot-sourced by:

| enforcement point | change |
|---|---|
| the K1g sign-off tooling (private), the N1 sign-off tooling (private) phase B, check `battery-rule` | calls the shared rule with the typed reading, status and level; the dead `StatusOk` and `ChargingLimit` copies are removed; the check text, the recorded `Rule` text and the STOP message name the r2 rule. The checks `range-100-349` and `battery-above-50` are unchanged |
| `fs-observe-k1g.ps1`, `fs-observe-n1.ps1`: BA10 reader (`Test-FsObsBa10`) and the re-check of phase B's recorded reading (`Test-FsObsChecklist`) | `Test-FsObsBatteryRule` is now a thin wrapper (optional third argument, the level) over the shared rule; both call sites pass the level |
| `fs-t0-capture.ps1` (`Test-Admission`) | the shared rule; the 10.0-34.9 and level > 50 checks are as before |
| `ts/the T0 package (private) (`admission`) | a Python mirror `admission_battery_ok` (same rule; parity-tested against the PowerShell rule) |
| the K1g sign-off tooling (private), the N1 sign-off tooling (private), `make-signoff-t0.ps1` | the new file is added to the pin lists; the phase B summary text states the r2 rule |

**Not changed, deliberately:** the K1a sign-off tooling (private) / `fs-observe-k1a.ps1` (K1a is complete on both units; its tools are pinned in
the K1a sign-off sheet (private) and their hashes sit in the committed K1a evidence and classifier checks) and the stage 3c/3d tools (completed
stages, no level check). If the Chair wants r2 there too, it is the same one-line call. The documents `ts/README.md` and
`ts/the operator addendum (private) (not pinned) now carry a "proposed (pending Chair ruling)" note beside the current rule; the current rule text is not replaced until the ruling.
the T0 package (private) is pinned and was updated.

### Pin rows that change (SIGNOFFs regenerated on the branch only)

| SIGNOFF | row | old SHA-256 (prefix) | new SHA-256 (prefix) |
|---|---|---|---|
| the K1g sign-off sheet (private) | `host\fs-observe-k1g.ps1` | `62e760f5...` | `8196eb2e...` |
| the K1g sign-off sheet (private) | `host\the K1g sign-off tooling (private) | `c6ae861a...` | `56219799...` |
| the K1g sign-off sheet (private) | `host\fs-admission-r2.ps1` (new row, 22 pins) | none | `cdb9ef4e...` |
| the N1 sign-off sheet (private) | `host\fs-observe-n1.ps1` | `d594998c...` | `8197a6b5...` |
| the N1 sign-off sheet (private) | `host\the N1 sign-off tooling (private) | `93590840...` | `fc7bc0e2...` |
| the N1 sign-off sheet (private) | `host\fs-admission-r2.ps1` (new row, 24 pins) | none | `cdb9ef4e...` |
| `SIGNOFF-t0.md` | `host\fs-t0-capture.ps1` | `794761ac...` | `5fe4d6a4...` |
| `SIGNOFF-t0.md` | `ts\tools\t0_check.py` | `83238b90...` | `052fc46a...` |
| `SIGNOFF-t0.md` | `ts\t0\T0.md` | `66c762c1...` | `dbb47fa1...` |
| `SIGNOFF-t0.md` | `host\fs-admission-r2.ps1` (new row, 20 pins) | none | `cdb9ef4e...` |

(the K1a sign-off sheet (private), `SIGNOFF-3c.md`, `SIGNOFF-3d.md`: no row changes. The image pins and the K1g/N1 gate pins are untouched.)
Consequences of the pin changes, for the Chair: a new cycle directory is needed for any run (the checklist refuses entries written by
another checklist hash), the committed K1g/N1 evidence keeps its old tool hashes (history is not rewritten), and the relay package
manifests of earlier relays remain as sent.

## 6. Tests

| suite | what | result (run on this branch, 2026-10-23, `FS_SILENT=1`) |
|---|---|---|
| `test-host-admission-r2.ps1` (new) | the shared rule against an integer oracle (560 cases), status 2 at 69/70/71 % x 29.9/30.0/34.9/35.0 deg C, status 3/4/5 unchanged, status 1 and malformed text never, observer wrappers identical, Python mirror parity (560 cases), source and pin checks | 15 run, 0 failed, 0 skipped |
| the K1g host suite (private) | L4 (changed: 305 at 70 % STOPs), O8 (changed: BA10 status 2 at 70 % refused), new L4b (phase B matrix, 9 pass and 10 stop cases), new O8b (eight full observer attempts: BA10 status 2 at 71 %/349 accepted and booted, 70 %/299 accepted, 70 %/300, 69 %/349, 71 %/350 and status 1 refused, status 3 unchanged, a typed 71 %/345 accepted) | 91 run, 0 failed, 0 skipped (run with `-ImageSource` on the main checkout's reviewed K1a candidate image, `build\k1a\20261015T163855Z-ecbcbd4f7b6f43c0`, because the worktree has no `build\`; N2/N3 ran) |
| the N1 host suite (private) | new ADM1 (the same matrix at phase B), ADM2 (nine full observer attempts: BA10 and the typed reading) | 131 run, 0 failed, 1 skip line (N3/N4/O6, the real rebuild). **Run with `-SkipRebuild`**: the real rebuild (N3) fails from a git worktree for an environmental reason (WSL `git status` in the worktree), not because of r2. The rebuild path does not touch the admission rule, but it was NOT exercised for this branch |
| `test-host-t0.ps1` | test 4 now at 70 % (STOP); 4b (81 %: admitted), 4c (35.0 deg C at 100 %: STOP); the pin count is 20 files (re-run in full after the pin-count fix) | 53 run, 0 failed, 0 skipped |
| `ts/the T0 package (private) (WSL, native fs-thermald test build) | two admission cases flipped, eleven r2 cases added | 99/99 (earlier run on this branch; not re-run in this fix-up) |

The committed outputs are `devices/quest3/host/test-host-admission-r2.output.txt` (new), the K1g host suite (private), the N1 host suite (private)
and `test-host-t0.output.txt`.

All tests run silent (`FS_SILENT=1`); none beeps or touches a device, `E:` or `/persist`.

## 7. Asks of the Chair

1. Rule that r2 replaces the J-145 charging limit for K1g/N1 (and T0) admission: status 2 below 35.0 deg C at a level above 70 %.
2. Confirm the follow-ups, the >= 40.0 deg C procedure and BA10-by-the-same-rule stay as in FS-R-012 s.5.
3. Confirm the pin changes in section 5, and whether K1a/3c/3d are to be left as they are.
