# K1g order gate, revision 1: the one supersession (for the Chair, FS-R-016 §5, c3-ii)

**Status:** built and reviewed offline, not used. Nothing in this delta has run on a headset. It comes to the Chair as the
gate-delta round that FS-R-016 §5 asks for, before any K1g r3 attempt. Prepared on the PM's authority ("You may prepare
the gate change offline", 2026-10-19, J-215) and under FS-R-016 §5 ("The Chair concurs with preparing this offline
delta"). The PM-controlled tool-permission layer refused nothing during this work.

Branch `feat/k1g-gate` (from master `53bf907e`, which carries FS-R-016). The cover note gives the head commit.

## 1. What changed, and why

Before this delta, `devices/quest3/host/fs-k1g-units.ps1` (`adf53f8c…`):
- refused Unit 2 any new K1g attempt, because the r2 attempt `<attempt nonce withheld>` is in the ledger and the observer
  records (`Get-FsK1gPriorAttempts`);
- required every Unit 2 K1g attempt to be a bound, clean K1G PASS (`Get-FsK1gUnit2Outcome`). The r2 K1G REVIEW record
  therefore blocked Unit 1 for good, and N1 too, because N1 reads the same function (FS-A-016 §4.6, §5).

FS-R-016 §3 accepted that record as K1G REVIEW. §4 concurred r3. §5 concurred "implementing the narrowly specified
exception" and set its required behaviour. This delta implements exactly that exception. It is all in
`fs-k1g-units.ps1`, the only executable that changes.

## 2. The required behaviour (FS-R-016 §5), and where each part is implemented

| §5 requirement | implementation (`fs-k1g-units.ps1`) |
|---|---|
| Retain the historical ledger entry, observer, collector and REVIEW record | Nothing is deleted, moved or rewritten. The gate only reads. |
| Recognise only the exact historical Unit 2 nonce, serial, outcome and full record hash | `$script:FsK1gSupersession` pins serial `QUEST3UNIT2`, nonce `<attempt nonce withheld>`, `K1G REVIEW` and classify-k1g.json sha256 `b01996d74606a219b347982a8be24e47014da7f9974def08d39f9aeeb8f593bd`. `Test-FsK1gSupersededRecord` requires all four. |
| Validate its existing evidence bindings first | The record reaches the exception only through `Get-FsK1gUnitRecords`, unchanged. Schema, nonce, serial, Fixture=false, outcome, the SHA-256 of observe.json, collect.json and capture.raw, the pinned classifier, banner, config and module count must already hold. The exception then also requires: the build copy and the committed evidence copy byte-identical to the pin; the ledger entry and its evidence copy byte-identical to `14ba6565…42ad`; the guard line (`FSBG-PROBE RESULT: ABORT nonce=<attempt nonce withheld> cases=0 pass=0 fail=0 mode=device`); the ABORT-before-arming item as the reason's only item; a clean after-session record. |
| Both discovery paths, ledger and observer | `Test-FsK1gSupersededPrior`: every hit from the ledger enumeration and from the observe.json enumeration of `Get-FsK1gPriorAttempts` must be the historical attempt's own ledger entry or its own `observe-*\observe.json`. **A third path** (safety review): any Unit 2 `attempt.lock` outside the historical directory also refuses. Register-FsAttempt writes that lock with the ledger note. |
| Admit exactly one new Unit 2 attempt of the r3 lineage, through the existing nonce-only checks | Unit 2 is admitted only when Unit 2's bound K1g attempts are exactly the historical one, **and** the checkout's candidate table `fs-nonceonly-k1g.ps1` hashes to the pinned `085f1494…`. That table holds `1ee9f105…` as the only current candidate. The observer's unchanged checks then accept only that image, or a nonce-only rebuild of it proven by opening both images. |
| Once spent, refuse another regardless of outcome | Registering the new attempt creates a ledger entry, and later an observe.json and an attempt.lock. Any of these is a hit outside the historical attempt, so the attempt is refused with or without an outcome record (tests S5, S9, S13). |
| Unit 1 and N1 blocked until the successor is a bound, clean r3 K1G PASS | `Get-FsK1gUnit2Outcome`: the historical record is set aside only if it is exactly the pinned one. Then **exactly one** other Unit 2 attempt must exist. Its ledger time must be later, compared as UTC times. It must be a bound, clean K1G PASS (`Get-FsK1gCleanPass`, unchanged) and of the r3 lineage (`Test-FsK1gSupersedingCandidate`, §3). No Unit 2 attempt.lock may exist outside the records. N1 reads this function unchanged (`fs-n1-units.ps1:177`). |
| Any other REVIEW/FAIL, unresolved attempt, malformed evidence, missing binding or orphan observer still blocks | Every other case falls through to the unchanged rule: every Unit 2 attempt must be a clean PASS. Orphan observers and unbound records still block in `Get-FsK1gUnitRecords`. **Added** (safety review): while the committed evidence of the historical attempt is in the checkout, a K1g ledger without that attempt is refused instead of being read as "no attempt" (`Get-FsK1gHistoryMissing`). |
| Keep the historical REVIEW visible and accurate; never a PASS | Every message reads "the r2 attempt <attempt nonce withheld> stays K1G REVIEW (the probe ABORTed before arming, cases=0; classify-k1g.json b01996d7…), superseded for progression (not a PASS) by the r3 candidate lineage 1ee9f105… under FS-R-016 s.3, s.5". `Get-FsK1gUnit2Outcome` returns it as `Superseded` with Outcome `K1G REVIEW`. Nonce, Outcome, File and Sha256 are always the successor's. |
| No force switch, blanket REVIEW exclusion, ledger deletion or "latest record wins" | There is no parameter, environment variable or flag. The exception is one pinned record. A REVIEW of any other class is never recognised (S6b). Exactly one successor is permitted (S8 "two attempts"), so "latest" is never used. |

The ruling itself is pinned: `Ruling = FS-R-016`, and `RulingSha256 = a3d138f990e7435a4c2d57ac0793bb1bc7a834c0e806cc430a3a5c6e79569b9d`, the SHA-256 of
FS-R-016 (private review record) as committed (LF). If the ruling file is missing or differs, the exception is refused (S3, S4, S8).

## 3. Why the successor is r3 and not r2 (FS-R-016 §5, last paragraph)

r2 and r3 share the kernel banner, the config and the module count. The classifier record therefore cannot tell them
apart, and the gate does not use those facts for lineage. The restriction rests on two links:
1. **At the attempt (prevention).** The one further Unit 2 attempt is admitted only while `fs-nonceonly-k1g.ps1` is the
   pinned `085f1494…` file.
   - In that file the current reviewed candidate is `1ee9f105…` (r3, probe `c1de030c…`). The r2 candidate `d24d1559…`
     is marked withdrawn.
   - The observer, unchanged and pinned, refuses any image other than that candidate or a nonce-only rebuild of it. A
     rebuild is proven by opening both images: the kernel bytes are identical and only the nonce in /init differs.
   - It also refuses any MANIFEST whose probe is not the pinned `c1de030c…` (`FsObsBaseline.FsbgProbe`).
   - A changed candidate table switches the exception off (S3).
2. **After the attempt (Unit 1 and N1).** `Test-FsK1gSupersedingCandidate` checks the successor's own bound evidence:
   - observe.json, bound by the record's ObserveJsonSha256, must say either "a nonce-only rebuild of the reviewed
     candidate (1c8ade5c6ec2b063 -> <its nonce>; fs-nonceonly-k1g checks passed)" or "the reviewed candidate (1ee9f105…)"
     (with that image hash and the candidate's own nonce). These are the observer's exact texts;
   - its ledger entry must name the same image;
   - its build MANIFEST must name its nonce, that image and probe `c1de030c…`. The r2 probe is `1d37e5f2…`.

**Decision:** a later change of the candidate table does not reopen or close anything for Unit 1 or N1. The successor's
lineage is its own evidence (test S7a).

## 4. The code delta

`devices/quest3/host/fs-k1g-units.ps1`: `adf53f8c…` → **`41e8107f73a9002908c366d944008ba5460a1fe8a3c62a97c3decb7886ccee80`**.
The exact diff is `git diff 53bf907e <head> -- devices/quest3/host/fs-k1g-units.ps1`, reproduced in
`devices/quest3/k1g/review/gate-r1.diff`.
- **Header comment:** what the one supersession does and does not do. Hand edits of the pinned record are now detected.
- **`$script:FsK1gSupersession`** (17 pinned values) and `$script:FsK1gRepoRoot` (the repository root, for the evidence
  copies and `relays\`; the host tests point it elsewhere).
- **New functions:**
  - `Get-FsK1gLfSha`: SHA-256 with CR-LF read as LF;
  - `Get-FsK1gUnitLocks`: the attempt.lock discovery path;
  - `Get-FsK1gHistoryMissing`;
  - `ConvertFrom-FsK1gLedgerUtc`;
  - `Test-FsK1gSupersessionPins`: the pins are well-formed and self-consistent, and the ruling file hash matches;
  - `Test-FsK1gSupersededRecord`;
  - `Test-FsK1gSupersedingCandidate`;
  - `Test-FsK1gSupersededPrior`.
- **Changed functions:**
  - `Get-FsK1gUnit2Outcome`: the supersession branch, the history-missing refusal, and a `Superseded` field in the
    result;
  - `Get-FsK1gPriorAttempts`: on a hit it calls `Test-FsK1gSupersededPrior`; with no hit, Unit 2 still needs the
    historical attempt; a `Superseded` flag;
  - `Get-FsK1gOrderGate`: Unit 1 is called through the same function. For Unit 2 the Why also names the historical
    REVIEW.
- **Untouched:** `Get-FsK1gUnitRecords`, `Get-FsK1gCleanPass`, `Get-FsK1gK1aGate`, `Test-FsK1gMemTotal`,
  `Test-FsK1gK1aCaptureMem`, every K1a rule and every existing pin.

**Other executables:** none changed. `fs-n1-units.ps1`, `fs-observe-k1g.ps1`, the K1g sign-off tooling (private),
`fs-classify-k1g.ps1`, `fs-nonceonly-k1g.ps1` and the N1 tools are byte-identical to master.

**Data the gate now reads** (disclosed, FS-R-016 §5). None of these files is executable, and each is pinned or bound
inside the gate:
- FS-R-016 (private review record), by its pinned hash;
- `devices/quest3/evidence/unit2-k1g-20261019/observe/classify-k1g.json` and
  `devices/quest3/evidence/k1g-attempt-ledger-20261019/<attempt nonce withheld>.attempted`, by their pinned hashes;
- `fs-nonceonly-k1g.ps1`, read for its hash only; it is already a SIGNOFF-k1g host pin;
- under `build\k1g`: the successor's `MANIFEST.txt`, its ledger entry, and every `attempt.lock`.

**Generator and tests** (not pins):
- the K1g sign-off tooling (private): prose only (§5);
- the K1g host suite (private): section S, plus `New-Attempt` parameters for nonce, ledger time, ledger image, observe.json
  extras, reason and guard line;
- the N1 host suite (private): section UG;
- both suites now run their legacy order-gate fixtures against a repository root without the committed K1g evidence
  (`$noEv`), as their build roots never held the historical attempt.

## 5. SIGNOFFs: new identities and pin diffs

| file | before (master) | **after** |
|---|---|---|
| the K1g sign-off sheet (private) | `782e2a77e623aaeaf0c34908da2061ff32aa53b95d574bcf50277f36dd7e1c7e` | **`38d1c21dc39a650341e6434dfce16280306144e2354ad891c77bb3de30ab3c7a`** |
| the N1 sign-off sheet (private) | `a1adc9e502049961a75596b229e943a6421f2c01cc9dc40ab0cd3b8429355c76` | **`be6f7f4fff76990336b51e58f5d067be16cfe80a3c36441910760f61674ca0bf`** |

**Pin diff, each SIGNOFF (the only changed pin line in either file):**
```
-| `devices\quest3\host\fs-k1g-units.ps1` | `adf53f8cd3ca4655641c5a747a0f46e9aeb8a8e3f90a3e120959dd404fdcf57d` |
+| `devices\quest3\host\fs-k1g-units.ps1` | `41e8107f73a9002908c366d944008ba5460a1fe8a3c62a97c3decb7886ccee80` |
```
- In both files the other host pins are unchanged (SIGNOFF-k1g: 21 rows, SIGNOFF-n1: 23 rows), and so are the image pins
  and the checklist texts copied from the pinned checklists.
- **SIGNOFF-n1 differs from `a1adc9e5…` in that one line only.**
- **SIGNOFF-k1g also changes in generated prose** (the K1g sign-off tooling (private)), disclosed separately:
  - the status paragraph. It said "the order gate (fs-k1g-units.ps1, unchanged) still refuses Unit 2 a second K1g
    attempt…", which would now be false. It now cites FS-R-016 and this delta;
  - one new paragraph after "THE ORDER GATE", describing the one supersession.

  No pin, question or checklist text changed.

## 6. Tests (offline, silent, `FS_SILENT=1`, against the same merged tree)

| suite | result | new cases |
|---|---|---|
| the K1g host suite (private) → the K1g host suite (private) | **89 cases, 0 failed** (master: 71) | S0–S14 (18 lines, most aggregating many sub-cases) |
| the N1 host suite (private) → the N1 host suite (private) | **107 cases, 0 failed** with `-SkipRebuild` (N3, N4, O6, the real WSL image rebuild, skipped: §8) (master: 103) | UG1–UG6 |

Requirement → test (the sub-case counts are inside each line):

| FS-R-016 §5 "Bring" item | tests |
|---|---|
| committed pins = committed facts | S0 |
| positive fixture, the one permitted path (real r2 evidence) | S1, S9 (checklist phase A and observer) |
| altered nonce, serial, hash; every other pin and the ruling | S3 (15 cases) |
| missing or altered bound files | S4: 8 files × (8 single-byte flips, append, truncate, delete), each with a restore control; UG2 (capture missing, record edited); S8 (ruling edited or missing) |
| extra attempts, a second r3 attempt | S5 (6 outcomes, ledger-only, orphan or unreadable observer, a second observe dir, another nonce, no serial), S9, S13 (hidden successor by attempt.lock) |
| the class rule (no blanket REVIEW exclusion) | S6 control, S6b (14 cases) |
| Unit 1 and N1 refused with no successor | S2, S12 (historical attempt missing), UG1, UG4 (N1 phase A and observer) |
| Unit 1 and N1 refused with REVIEW/FAIL and an unclean PASS | S8 (20 cases, each through both Unit 1 and N1's function), UG2 |
| Unit 1 and N1 accepted with the valid clean successor | S7, S7b, S10 (observer integration), UG3, UG5 (N1 phase A and observer integration) |
| ledger time compared as time | S14 |
| SIGNOFF pins the working gate | S11, UG6 |

## 7. Adversarial review and dispositions

Two independent reviewers worked read-only on the working tree.

**(a) Safety: ACCEPT WITH FIXES, no BLOCKER.**
- **Attacks that held:**
  - a copied build folder;
  - a second historical-nonce directory, or a second observe dir in it;
  - a renamed nonce directory;
  - an upper-case ledger name;
  - a ledger entry naming the other unit or no serial;
  - registered but not yet observed;
  - an orphan or unreadable observe.json;
  - path-case, trailing `\` and `..` variants;
  - every byte edit;
  - every non-REVIEW or other-REVIEW class;
  - every successor defect;
  - no supersession for Unit 1.

| # | finding | disposition |
|---|---|---|
| 1 MINOR | Removing the historical attempt (or using a working copy without it) switched the lineage restriction off. | **Fixed:** `Get-FsK1gHistoryMissing` in both functions; test S12. |
| 2 MINOR | Hiding the successor (deleting its ledger entry, renaming its observe dir) re-admitted Unit 2, and could hide a failed successor from Unit 1. | **Fixed:** attempt.lock as a third discovery path in the supersession paths; test S13. `Get-FsK1gUnitRecords` is unchanged, so the K1a gate is unaffected. |
| 3 NOTE | Ledger times were compared as text. | **Fixed:** compared as UTC times; test S14. |
| 4 NOTE | The lineage text (ledger `image=`, MANIFEST) is not bound by the record; only observe.json is. | **Disclosed** (§8). The image bytes are not re-hashed at gate time. Forging them is the documented hand-edit class. |
| 5 MINOR | CHANGES-gate-r1.md missing; disclosures. | **This file.** |
| 6 NOTE | The superseded record is in messages only, not persisted in observe.json or the checklist entry. | **Disclosed** (§8). Persisting it would change the observer and the checklist pins. |
| 7 NOTE | Unit 1's gate does not check the candidate table. | **Disclosed** (§8). |
| 8 NOTE | A registration failure or a DEVICE_REJECTED handoff also spends the one further attempt. | **Disclosed** (§8), for the PM. |
| 9 NOTE | "(= its git blob)" was imprecise. | **Fixed:** "its committed LF bytes". |

**(b) Correctness and tests: ACCEPT WITH FIXES, no BLOCKER.**
- It mapped every requirement to tests and judged S4, S6 and S7 to carry positive controls, so none passes vacuously.
- No state leaks between cases. Callers and existing tests are unaffected.

| # | finding | disposition |
|---|---|---|
| 1 MAJOR | Disclosure: prose beyond the pin; the new data inputs; no SIGNOFF pin-equality test. | **Fixed:** §4–§5; tests S11 and UG6. |
| 2 MINOR | No N1 integration through phase A and the observer. | **Fixed:** UG4 and UG5. |
| 3 MINOR | REVIEW not shown in N1's PRIOR RESULTS, the K1g A5 block or observe.json; the stale comment at `fs-n1-units.ps1:8-9`. | **Disclosed** (§8), left unchanged: editing would change other pins. |
| 4 MINOR | The ALTERED SERIAL expectation was too loose; no ruling-edited case with a valid successor; the candidate-table-after-the-fact decision. | **Fixed:** S3 now expects "pinned values are malformed"; S8 adds the ruling edited and missing; S7a records the decision. |
| 5 MINOR | Early returns lacked `Superseded`. | **Fixed.** |
| 6 MINOR | `Get-FsK1gLfSha` was slow (a byte loop). | **Fixed:** an ISO-8859-1 round trip. |
| 7 NOTE | Message wording for an unreadable observe.json. | **Fixed:** "or an observe.json that cannot be read … (or cannot be told apart)". |
| 8, 9 NOTE | Clock skew fails closed; deleting the successor together with its ledger entry. | The latter is now also caught by attempt.lock (S13), unless the lock goes too: the documented falsification class. |

After the fixes, both suites were re-run in full (§6). There was no further review round.

## 8. Limits and residual risks (stated plainly)

- **Hand-edit class, unchanged in kind.** The gate trusts the files bound to records. The historical record is now pinned
  byte for byte. A successor's MANIFEST, ledger `image=` and attempt.lock are plain text written at the attempt.
  Deliberately forging them, or deleting a whole successor (its directory, ledger entry and lock), would be
  falsification of a test record. The one further attempt also rests on build\k1g being the shared ledger
  (FS-R-013 §2).
- **The historical REVIEW is visible in the gate messages:**
  - phase A's `order-gate` check line (`checklist-k1g.txt` and `.json`);
  - the observer console's "unit order OK" line, which is printed before observe.log exists and so is not in it;
  - the Unit 1 and N1 refusal and acceptance texts.

  It is **not** shown in the K1g A5 "UNIT 2 RESULT" block, in N1's PRIOR RESULTS, or in the observe.json
  `Unit2Outcome*` fields. Those list the successor PASS only. Changing them would change the checklist, observer and N1
  pins.
- **Stale comment:** `fs-n1-units.ps1:8-9` still says every Unit 2 K1g attempt must be a clean K1G PASS. The function it
  calls now implements FS-R-016 §5/§6. The comment is left unchanged to keep SIGNOFF-n1 to one pin line.
- **What spends the one further attempt:** it is spent at registration. A DEVICE_REJECTED handoff, a registration
  failure after the ledger entry, an interrupted observer, or a probe ABORT all spend it ("regardless of outcome").
  A repeat would need the Chair again.
- **Unit 1's gate does not check the candidate table.** That needs no new rule: the observer only accepts the current
  reviewed candidate, and any table change is a reviewed SIGNOFF-k1g pin change.
- **Working copies:** the gate refuses Unit 2, Unit 1 and N1 in a checkout that has the committed evidence but a
  `build\k1g` without the historical attempt. That is intended (§2).
- **Scratch-directory incident (disclosed):** while preparing this delta I ran a scratch script, `smoke2.ps1`, from the
  session scratch directory. Another session had overwritten it with its own R-1 dry-run replay. That script ran
  `fs-observe-r1.ps1 -DryRun -ReplayRaw` on fixtures from the R-1 clone (`%TEMP%\fs-r1`), wrote only into the scratch
  directory (`o1`, `sess1`), and touched no device, no repository and no build directory. My scripts now live under
  `scratchpad\gate\` with distinct names.
- **Build-directory incident (disclosed):** the N1 suite's case N3 rebuilds an N1 image with `n1/build-image.sh`. That
  builder takes its inputs and its output directory (`OUTBASE`) from the main checkout (`FS_INPUT_ROOT`, default
  `<repo>`), not from the clone. While diagnosing why N3 failed in the clone (a missing
  ignored input, `n1/build/fs-xfer`), I ran the builder by hand. Those runs left **three new, unspent N1 nonce-only
  candidate directories** in the main checkout's ignored `build\n1`: `20261019T203505Z-ac29d1b0246a7b8b`,
  `20261019T203903Z-7037ab8f9eb0af13` and `20261019T204248Z-82d350189190b327`.
  - No tracked file, ledger, evidence or device was touched. Nothing references these directories.
  - They are left in place for the PM to keep or delete.
  - The final N1 run therefore used `-SkipRebuild`, so N3, N4 and O6 did not run. They test the N1 image builder, which this delta
    does not touch.

## 9. Asked of the Chair

Review this gate delta and both new SIGNOFF identities, as FS-R-016 §5 (c3-ii) requires, before the one Unit 2 K1g r3
attempt, then N1 on Unit 2, then the one Unit 1 K1g r3 attempt (FS-R-016 §5, §6). The PM's live sign-off and the
FS-R-015 §4 / FS-R-016 §6 envelope apply unchanged.
