# N1 r3: the collector fix, the live-path test and N1 gate revision r1 (for the Chair)

**Status:** built and reviewed offline, not used. Nothing in this delta has run on a headset. No adb, fastboot or COM
port was used, nothing on the PC was changed, E: and /persist were not touched, and `devices/quest3/evidence/` was not
modified. It comes to the Chair because it changes executable host behaviour (FS-R-014 §6: "New executable behavior
still requires its own review") and because Unit 2's one N1 attempt is spent (FS-R-017 §5: "None creates an automatic
retry"; "Report and resolve an unexpected N1 outcome … before continuing the sequence").

Branch `feat/n1-r3`, from master `93774904`. The cover note gives the head commit.

## 1. What happened (J-233, J-234)

Unit 2's N1 r2 attempt, nonce `<attempt nonce withheld>`, was registered at 2026-10-21T16:13:05Z and booted
(`HANDOFF_ACKNOWLEDGED`). The gadget `FS-<attempt nonce withheld>` came up on COM20 at Th+12 s. The PC collector then
refused: `refused: output directory already exists: …\observe-20261021T161305Z\collect`, and it exited with code 20
(`RECOVERY: nothing was sent to the device by this run (the ACM console)`). The device returned to fastboot by itself.
The classifier then exited 70 (`no collect.json`). There is **no outcome record**, and the attempt is spent.

## 2. Root cause, confirmed in the source [D]

r2 `fs-collect-n1.ps1` (`5c1ed6cb…`, kept byte for byte as `host/fixtures/n1/r2-host/fs-collect-n1.ps1.r2`), live branch:

| line | what it does |
|---|---|
| 152 | `if (-not (Test-Path $OutDirK)) { New-Item -ItemType Directory $OutDirK }`: it creates the output directory, so that the NCM job can later write `xfer.json` into it |
| 153 | creates the serial transport (`New-FsRawSerialTransport`). The port is not opened here. |
| 169 | `Start-FsN1XferJob … -OutDir $OutDirK`: the background runspace. r2 `fs-xfer-n1.ps1:305` writes `<OutDir>\xfer.json` when its session ends |
| 170 | `$started = $true` |
| 171 | `Invoke-FsCollectRun -OutDir $OutDirK` → `fs-collect.ps1:769` `New-FsCapture` → **`fs-collect.ps1:205` `if (Test-Path $Dir) { throw "refused: output directory already exists: $Dir" }`**. This runs before `Invoke-FsCollect` and before `Transport.Open()` (`fs-collect.ps1:617`), so `$script:FsLastCtx` stays `$null` |
| 189-191 | the catch: stop the job and wait for it (≤ 30 s). `$ctx` is `$null`, so "nothing was sent" is printed and the exit code is 20 |

The job then wrote `xfer.json` (`Result "stopped"`, 0 bytes, an empty adapter timeline). That file is the only thing in
`collect\`, which matches the committed evidence exactly. The observer does not create `collect\` (`fs-observe-n1.ps1`
creates only `observe-*`). **The live path refused on every run.** It could not be caught offline, because every
offline test used `-N1Replay`, and that path never reaches line 152 and never starts the job.

## 3. The other live-only paths (audit)

The code that runs only live, and is never reached by `-N1Replay`, is: `fs-collect-n1.ps1` 128-171 (live arguments, time
parse, start refusals, gadget/port check, transport, job start), 173-182 (job stop/wait after the engine) and the catch,
plus `fs-xfer-n1.ps1` `Start-FsN1XferJob`, `Wait-FsN1XferJob`, the default lookups in `Find-FsN1Adapter` and the live
client arguments. Two reviewers and I checked each of them.

- **Same class of defect:** none other. No other directory or file is created ahead of the engine.
- **Now exercised end to end offline** by the new test bed (§5): the argument parsing, the BootStartUtc and start
  refusals, the gadget-to-port check, the job runspace (the library loaded by `$PSScriptRoot`, the scriptblock passed as
  text, the `EndInvoke` output shape, `Wait`), the engine in live mode, the post-engine path, the xfer.json write and
  collect.json.
- **Checked by hand on this PC, read-only:** the real `Find-FsN1Adapter` default lookups (Get-PnpDevice,
  Get-PnpDeviceProperty, Get-NetAdapter, Get-NetIPAddress) inside a background runspace, as the job runs them, for a nonce
  no device carries. Result: 0 errors, refusal "no USB\VID_1D6B&PID_0104\FS-0000000000000000 device present". The first
  lookup took about 2.4 s and the next about 1.5 s. In r2 the job never reached its first lookup: it was told to stop
  about 7 s after it started.
- **Still untestable without the device:** the real SerialPort open/flush/close; the PnP child walk to a real UsbNcm
  adapter and its link-local readiness; the connect to `fe80::<nonce>%<ifIndex>`; every real-time budget (T0 + 74 s, the
  23 s responder). The bed's ACM device runs on the engine's virtual clock.
- **Cosmetic, unchanged:** the observer logs Windows' upper-case parent instance ID `FS-611FA148F12D76BB` as a "WRONG
  serial". The gadget and adapter lookups compare case-insensitively, and the K1a/K1g observers do the same.

## 4. The fix (host only; the shared engine is unchanged)

`fs-collect-n1.ps1` (`5c1ed6cb…` → **`4fdc3e47…`**):
- **Refuses an existing `-N1OutDir`** at the start of the live branch, before the gadget lookup. The result is exit 20
  and nothing is started.
- No longer creates the directory. **Only the engine creates it** (`New-FsCapture`, unchanged, which still refuses an
  existing one).
- Starts the job without `-OutDir`.
- After the engine, writes the job's result as `xfer.json` through `Save-FsN1XferResult`. That function:
  - writes only into a directory the engine created (its `capture.raw.idx` exists);
  - never overwrites an existing file;
  - never throws (review B MAJOR-1: a failed write must not lose collect.json).

  The catch branch saves the result the same way.
- `collect.json` gains `HostTools`: the SHA-256 of the six host files that ran (collector, PC-side library, engine,
  fs-native, fs-proto, fsb1). This is the provenance the gate checks (§6).

`fs-xfer-n1.ps1` (`5498c15e…` → **`2b9320ce…`**):
- `Invoke-FsN1XferSession -OutDir` is now optional. The offline tests still pass it; the runspace does not.
- `Start-FsN1XferJob` takes no `OutDir`.

**Every refusal is kept.** `fs-collect.ps1` is byte-identical (`2b90d641…`), so the **K1g pins do not change**, and
SIGNOFF-k1g stays `38d1c21d…`. The K1g collector is untouched.

## 5. The live-path test (the N1 host suite (private) section LV, LV0-LV5)

**How the bed is built.** The shipped collector runs through its **live entry point**
(`-N1Port COM250 -N1Nonce … -N1BootStartUtc … -N1OutDir …`, never `-N1Replay`), in a child `powershell.exe`, inside a
temporary tree:
- it sits beside byte-identical copies of the engine, fs-native, fs-proto and fsb1;
- **one inserted line** in the collector copy, just before its CLI, and **one appended line** in the fs-xfer-n1 copy,
  load the test bed `host/fixtures/n1/live-bed/`;
- LV0 checks the copies **on disk** against their sources and the pins. Each must be exactly its source plus that one
  line, or no run is made.

**What the bed replaces.** It replaces only the hardware edges:
- `Get-FsGadget`: gives the configured gadget on COM250;
- `New-FsRawSerialTransport`: a scripted ACM device. It is the c-full QEMU harness capture behind the pinned engine's
  replay transport, so every write must equal the recorded write. When `fs-n1 <chal>` is written, an FSX1 responder
  starts on `::1`, and the rest of the record is held back until that responder has served the PC side (bounded at
  60 s);
- `New-FsHex`: gives the capture's tokens;
- `New-FsN1Cfg`: sets the harness kernel/PID 1 strings;
- `Find-FsN1Adapter`: a loopback adapter stand-in;
- `Invoke-FsN1Xfer`: the bed first **asserts that the call carried the live arguments** (`fe80::<nonce>`, the
  stand-in's ifIndex, port 47201, mode ok, not a fixture), then sends the real client to `::1` with `Fixture = true`.

Nothing else is replaced: `Start-FsN1XferJob`, `Invoke-FsN1XferSession` and `Wait-FsN1XferJob` run as shipped.

**Results:**
- **LV1, the r2 collector** (its pinned bytes): exit 20, the exact r2 refusal line, "nothing was sent". The port is
  never opened and nothing is written. The directory holds only `xfer.json` (`stopped`, 0 bytes), **as in the Unit 2
  evidence.** The old code reproduces the r2 refusal.
- **LV2/LV3, the r3 collector:** exit 10, COLLECTED-VALID.
  - The engine created the directory: `capture.raw`, `.idx` "mode=live port=COM250", `collect.json` and `xfer.json`.
  - The writes were fs-verify, fs-ack, fs-status, fs-n1 and fs-done, with no divergence.
  - The real job moved 8 MiB each way (Result ok, every check true).
  - collect.json `Xfer` and `HostTools` are as expected.
- **LV4:** the classifier never binds a test-bed result: INCONCLUSIVE, "a replay or a fixture".
- **LV5:** r3 with an existing output directory: exit 20 before anything (no gadget lookup, no transport, no job).

The bed fakes are never loaded by a shipped file. The r2 copies are named `.r2` (`.gitattributes`
`devices/quest3/host/fixtures/n1/** -text`, an existing rule).

## 6. The gate: N1 gate revision r1 (fs-n1-units.ps1, `01eb10a5…` → `1ff87860…`; with §6A `c8b0e913…`; with §6B **`059b7ed9…`**)

The design mirrors K1g gate r1 (FS-R-016 §5, accepted in FS-R-017 §2). Only the N1 order changes. The K1g functions it
reads are unchanged.

| requirement | implementation |
|---|---|
| Recognise only the exact historical attempt | `$script:FsN1Supersession` pins the following, none of it taken from a record:<br>• serial, nonce, image, build and observe directory names;<br>• the SHA-256 of the ledger entry (build\n1 **and** the committed copy), attempt.lock, observe.json and observe.log (both copies), the job's xfer.json (both copies);<br>• the committed console transcript and its three lines (`REFUSED/ERROR: refused: output directory already exists: …`, `RECOVERY: nothing was sent …`, `collector exit: 20`);<br>• the committed classifier transcript (`ERROR: no collect.json …`).<br>`Test-FsN1SupersededAttempt` also checks observe.json's facts and xfer.json's facts (`stopped`, 0 bytes, no connect). |
| …and the absence of any outcome | In both the build copy and the evidence copy, the observe directory holds exactly `collect`, `observe.json` and `observe.log`, and `collect\` holds exactly `xfer.json`. The build directory has no other directory, hidden ones included. No `classify-n1*` exists anywhere under the build directory or the evidence directory. |
| Admit exactly one N1 r3 attempt on Unit 2 | `Test-FsN1SupersededPrior` (Unit 2 only) requires all of the following:<br>• the pins and the ruling hold;<br>• the checkout's candidate table, r3 collector, engine and PC-side library are the pinned files;<br>• every earlier trace is the historical attempt's own. There are **four discovery paths**: the ledger, every observe.json under build\n1, every attempt.lock, and the committed N1 ledger copies (`evidence\n1-attempt-ledger-*`). A trace naming any serial other than exactly Unit 1's counts. |
| Once spent, no other attempt | Registration writes a ledger entry and an attempt.lock, and later an observe.json. Any one of them is a trace outside the historical attempt, so a further attempt is refused with or without an outcome (UN6, UN9, UN11). |
| Keep the historical attempt visible | Every message reads "the N1 r2 attempt <attempt nonce withheld> of Unit 2 stays WITHOUT AN OUTCOME (its collector refused at start …), superseded for progression (not a result, never a PASS) under <ruling>". It is appended to `Get-FsN1Prereq`'s Why, which appears in the phase A `n1-order` line and the observer's "N1 order OK" line. It is never one of the Records (the PRIOR RESULTS lines and A5). |
| Outcome side (the dormant Unit 1 rule) | `Get-FsN1StageOutcome` (stage n1, Unit 2) sets the historical attempt aside only when it is exactly as pinned. It then requires all of the following:<br>• **exactly one** other Unit 2 attempt, later by parsed UTC;<br>• no hidden lock, and no other committed ledger copy;<br>• that attempt shown to be of the r3 lineage by its own bound evidence: observe.json names the reviewed candidate or a nonce-only rebuild of it, the ledger entry names that image, and collect.json `HostTools` names the r3 collector, engine and library;<br>• a bound, clean N1 PASS with MemTotal (the unchanged rule). |
| No switch | There is no parameter, environment variable or "latest wins" rule. The only script variables are the repository root and `$script:FsN1HistoryRequired`. That variable is `$true` as shipped: a ledger without the historical attempt is refused even when the evidence is absent (review A F1). Only the host tests set it to false. |
| Inert until the Chair rules | `Ruling`, `RulingSections` and `RulingSha256` are **empty**, so the supersession is not applied and Unit 2 stays refused (UN1): "no ruling is pinned yet: it awaits the Chair's ruling on N1 r3". **After the Chair's ruling,** the only edit is to pin those three values (the ruling file's committed LF bytes). UN12 checks that fs-n1-units.ps1 with those three lines blanked still hashes to the reviewed `059b7ed9…` (§6B; `c8b0e913…` after §6A, `1ff87860…` before it), so no other byte can change. The edit changes the fs-n1-units.ps1 pin and so SIGNOFF-n1. That one regenerated identity comes back with the next relay. |

`fs-n1-units.ps1:8-9`, the stale comment noted by FS-R-017 §4, is corrected in the same file.

## 6A. Amendment: the historical attempt's after-session facts (Chair-view review MAJOR-2)

**Finding.** The gate recognised `<attempt nonce withheld>` without pinning any phase F fact. FS-R-017 §2 accepted K1g gate r1
because its recognition also requires clean after-session facts. N1 r2's phase F is `clean False`, for one reason only:
the two follow-up readings were 1 s apart, because the PC slept. The PM accepted the late readings (J-234).

**Fix** (`fs-n1-units.ps1` `1ff87860…` → **`c8b0e91381072ea9de836e461bcb79d8684c723d3e1f7f6689fe56987f3c0fc8`**):
- **New pins.** `EvidenceChecklist` is `checklist-n1.json`. `ChecklistSha256` is the committed file's raw bytes,
  `33b76723f0d7505abffaf44c5e44998a2093b670920a0881cfe7759a4329f887`. `FollowUpsNote` is
  `reading 2 is less than 240 s after reading 1`; `Test-FsN1SupersessionPins` accepts only a spacing reason of this form.
- **New check.** `Test-FsN1SupersededChecklist` is called by `Test-FsN1SupersededAttempt`, so the prior side and the
  outcome side both apply it. It requires all of the following, or the attempt is not recognised:
  - the pinned bytes and the schema;
  - exactly one phase F entry, the last one (`PASS`, this nonce and Unit 2);
  - the checks exactly `af-ended-ok`, `aa-ended-ok` and `aa10-below-400` OK, with `follow-ups-finished-below-400` failed
    for the pinned note alone;
  - the answers F1-F6 as recorded (`y n y y y y`);
  - in `After`: `Clean` false and `FollowUpsFinished` false, with `AfOk`, `AaOk`, `ReturnedByItself`, `DumpMode` and
    `RecoveryFault` at their clean values; `FollowUpsNote` equal to the pin; `Aa10Temp` 300 and `MaxTemp` 300;
    `FollowUpsOffUtc` null; `AfSha256` and `AaSha256` equal to the committed `AF\SUMMARY.txt` and `AA\SUMMARY.txt`;
    exactly two follow-ups at 250, bound to the committed `followup-1/2-battery.txt`; the workaround record as recorded;
  - the recorded phase F summary line, exactly.
- **Any other non-clean reason refuses.** The recognised attempt's message now ends with "its after-session record
  (checklist-n1.json 33b76723…) is clean but for the follow-up spacing alone".

**Tests** (the N1 host suite (private)):
- UN0 includes the checklist.
- UN3 gains three pins (31 in all).
- UN4 now covers 16 bound files: the checklist, both SUMMARY.txt files and both follow-up readings were added.
- UN12 pins the new blanked hash `c8b0e913…`.
- **New UN14:** 25 fact cases, each re-pinned to its rewritten bytes so that the fact check, not the hash, refuses
  (AF/AA, a second failing check, dump mode, not back by itself, recovery fault, F1/F2, finished, Clean, another note,
  40.0 deg C, a third reading, a second phase F entry, another nonce or schema). A rewritten-unchanged control, re-pinned,
  opens. The shipped pin on altered bytes is refused, and so is a missing checklist. On the outcome side, a second
  unclean reason blocks an otherwise valid successor.

**New identities:** SIGNOFF-n1 `954de7db…` → **`1dbffff07c99e794def4bbaa3a53e35870a5b47f82ad5e5e6afb9bce2778766c`**
(only the fs-n1-units.ps1 pin line changed). SIGNOFF-k1g is unchanged. The test counts are in §9.

**Disclosed, from earlier in r3:** the N1 sign-off tooling (private) gained one generated prose paragraph (8 lines, after the phase A
paragraph) that describes N1 r3 and the inert supersession. It is prose, not a pin (§7).

## 6B. Delta-review fixes (after §6A)

Four findings of the delta review, each fixed fail-closed and tested in the N1 host suite (private):

1. **Outcome side, hidden attempts.** `Get-FsN1UnitLocks` (used by `Get-FsN1StageOutcome` on the supersession path) now
   lists hidden directories (`-Force`), and counts every attempt.lock that is not exactly Unit 1's as Unit 2's (no
   serial, an unknown serial, or any `serial=` value other than Unit 1's), as the prior side already did. **UN8** gains
   a Unit 2 lock in a hidden directory, a lock naming an unknown serial and a lock with a Unit 1 line then a Unit 2
   line (each blocks the Unit 2 outcome), and a Unit 1 lock control (does not count).
2. **Type-strict, exact-name fact checks.** `Test-FsN1SupersededChecklist` reads every property by its exact name
   (`Get-FsN1Prop`, case-sensitive) and checks each value's JSON type: every `Ok` and `After` flag is `[bool]`;
   `Aa10Temp`, `MaxTemp` and a follow-up's `N` are numbers (`[int]`/`[long]`; ConvertFrom-Json yields Int32 for 300);
   texts (`Temp` '250' as recorded, answers, notes, hashes, the summary) are `[string]`. `Test-FsN1SupersededAttempt`
   and `Test-FsN1SupersedingAttempt` also use exact names, and the historical xfer.json's byte and connect counts must
   be the number 0. **UN14** gains 6 cases, each re-pinned so the fact check (not the hash) refuses: a check `Ok`
   "True", `Aa10Temp` "300", `MaxTemp` "300", a follow-up `N` "1", and the wrong-case names `aa10temp` and `dumpMode`.
3. **Every `serial=` value.** `Get-FsN1NoteSerials` returns every `serial=` value of a ledger entry or lock, and
   `Test-FsN1OnlyUnit1` skips a file only if it names at least one and ALL are exactly Unit 1's (zero stays
   fail-closed). It is used for the ledger, lock and committed-copy paths of `Test-FsN1SupersededPrior`,
   `Get-FsN1CommittedOthers` and `Get-FsN1UnitLocks`. A ledger entry naming more than one serial is refused by
   `Get-FsN1StageOutcome` and counted as a prior attempt of every unit by `Get-FsN1PriorAttempts`. **UN6** (a ledger
   entry and a lock with a Unit 1 line then a Unit 2 line), **UN11** (such a committed copy) and **UN8** (such a lock;
   a two-serial ledger entry) cover it.
4. **collect.json not saved: exit 15.** If `Save-FsCollectJson` throws, `fs-collect-n1.ps1` prints
   `COLLECT.JSON NOT WRITTEN: …` and `NO RESULT: collect.json was not written (status …): this run cannot be
   classified …` and exits **15** (new; unused by the collectors, whose table is now 10/11/14/15/20/70; the N1
   classifier uses 40-44/64/70 and reads no collector code; the observer only prints `collector exit: <n>`), never
   10/11/14. **New LV6:** the live bed with the save made to throw: exit 15, no collect.json, the capture and xfer.json
   kept.

**New identities:** `fs-collect-n1.ps1` `4fdc3e47…` → **`dea946938cea13b728298852dc891e306dd62cdeaceaa16303365083d67f63ba`**
(also pinned as `CollectorSha256`); `fs-n1-units.ps1` `c8b0e913…` → **`059b7ed970fe823c670c4e184fe6875225b2dcfa6e9e09355ac0a98b4205c729`**
(UN12's blanked-ruling hash; the ruling is still empty); SIGNOFF-n1 `1dbffff0…` →
**`19e4b8a40a8b1045df71bd25b787aaacddcfd311f3831d0e3ddb3a9b2e20903c`** (only those two pin lines changed). SIGNOFF-k1g is
unchanged. Tests: §9.

**NOTE.** The history requirement is unconditional: `$script:FsN1HistoryRequired` is `$true` as shipped and
`Get-FsN1HistoryMissing` refuses any Unit 2 N1 ledger without `<attempt nonce withheld>`, so a working copy without the shared
`build\n1` (with that attempt) is blocked. This is intended. Tester images will need a documented path (for example a
reviewed way to seed or name the history) before N1 can be gated there.

## 6C. The ruling fill and the test correction (FS-R-018 s.3, s.4)

**The fill.** Master (docs and relays only, no runtime file) was merged into `feat/n1-r3` so that the gate finds the
committed FS-R-018 (private review record). In `fs-n1-units.ps1` exactly the three authorized values changed: `Ruling = 'FS-R-018'`,
`RulingSections = 's.3, s.4'`, `RulingSha256 = '7fef506fafefbeb64996e55207dbbe9dbc5a015c6271d90c315d49acc986f6b9'`
(the LF SHA-256 of the git blob on master, `git show master:FS-R-018 (private review record) | sha256sum`). No other byte changed;
the comment that describes the pre-ruling state is left as reviewed. With the three values blanked, the file hashes to
**`059b7ed970fe823c670c4e184fe6875225b2dcfa6e9e09355ac0a98b4205c729`** (UN12, and checked separately with sed).

**The test correction (the N1 host suite (private), offline only).** UN0, UN1 and UN9 assumed the shipped gate had no ruling.
- A new `Set-UnNoRuling` builds an explicit **empty-ruling fixture**: the deployed pins with the three Ruling values
  blanked in memory. UN1, UN8's "no ruling" case and UN9's third run use it. Their assertions are unchanged.
- UN0 no longer requires an empty ruling. Its other checks are unchanged.
- The stand-in FS-R-999 positive and tamper cases (UN2, UN3 and the others) are unchanged.
- **New UN15** checks the deployed pins: exactly `FS-R-018`, `s.3, s.4` and `7fef506f…`. The hash must match the
  committed FS-R-018 (private review record), computed both by the test and by the gate's `Get-FsN1LfSha`.
  `Test-FsN1SupersessionPins` must pass against the real repository root (Ref `FS-R-018 s.3, s.4`). On a fresh
  historical-attempt test base, the unchanged deployed pins give: real ruling file → open under FS-R-018 s.3, s.4;
  no ruling file, or one byte appended → refused.
- UN12, UN13 and every other refusal and integration assertion are unchanged. No case is skipped.

**Identities.** `fs-n1-units.ps1` **`1d725bbdfb3ec8b4c05fc6110622efd04b15776414adee6ab1817c2ecc3e16a3`**.
the N1 host suite (private) **`1c9b8e202ebd9fda7a2b955d4a84fa46dedf4ee58db907ef7401d510bb87246d`**. SIGNOFF-n1, regenerated by
the N1 sign-off tooling (private): `19e4b8a4…` → **`8cea3cc65dfb5a50b465b70a5d73cf9268e6aea98b5386d69c7e5f6fe61ee4fc`**. Its only
change is the `fs-n1-units.ps1` pin row (`059b7ed9…` → `1d725bbd…`; a one-line diff). SIGNOFF-k1g is unchanged at `38d1c21d…`.

**Results** (FS_SILENT=1, on the branch after the fill):
- the N1 host suite (private) -BuildRoot <main>\build\n1`: **131 cases, 0 failed, 0 skipped** (130 + UN15).
  - The real rebuild ran: N3, N4 and O6 PASS. LV0–LV6 and UN0–UN15 PASS.
  - **Omitted: O5.** It is optional and runs only if the clone has a `build\k1a` candidate; this clone has none.
  - Afterwards, the main `build\n1` held the same five entries, and the historical ledger entry kept its hash (`55164769…`).
- the K1g host suite (private) -ImageSource <main>\build\k1a\…-ecbcbd4f7b6f43c0`: **89 cases, 0 failed**.

## 7. SIGNOFFs and pin diffs

| file | before (master) | **after** |
|---|---|---|
| the N1 sign-off sheet (private) | `be6f7f4fff76990336b51e58f5d067be16cfe80a3c36441910760f61674ca0bf` | **`19e4b8a40a8b1045df71bd25b787aaacddcfd311f3831d0e3ddb3a9b2e20903c`** (§6B; `1dbffff0…` after §6A, `954de7db…` before it) |
| the K1g sign-off sheet (private) | `38d1c21dc39a650341e6434dfce16280306144e2354ad891c77bb3de30ab3c7a` | **unchanged** (no K1g pin changed) |

```
-| `devices\quest3\host\fs-collect-n1.ps1` | `5c1ed6cb8c27dcf7f0f5c28bd4fd93f6792ce01bfbb274be85a5ccf979bd8795` |
+| `devices\quest3\host\fs-collect-n1.ps1` | `dea946938cea13b728298852dc891e306dd62cdeaceaa16303365083d67f63ba` |
-| `devices\quest3\host\fs-xfer-n1.ps1` | `5498c15e1fbb4af55b9d166bb5d866f9ccbf69131e1aafd0bfd28037ab939394` |
+| `devices\quest3\host\fs-xfer-n1.ps1` | `2b9320ce581f4821334924e5bfffe474d0fed432d7701d190bcf9d48fec93a7e` |
-| `devices\quest3\host\fs-n1-units.ps1` | `01eb10a5ed53d8ce5b6905a0f617de0d2f0469bc3bfcfe604bda69219b8f1d9e` |
+| `devices\quest3\host\fs-n1-units.ps1` | `059b7ed970fe823c670c4e184fe6875225b2dcfa6e9e09355ac0a98b4205c729` |
```

The other 20 host pins are unchanged, and so are the checklist texts. SIGNOFF-n1 also gains **one generated prose
paragraph** (the N1 sign-off tooling (private)), placed after the phase A paragraph, which describes N1 r3 and the inert supersession.
Disclosed: it is prose, not a pin.

## 8. The image

**The image is unchanged.** The delta touches no file the N1 builder reads: init.sh, fs-n1.sh, fs-n1-info.sh,
fs-xfer.c and fs-xfer, the K1a kernel, and the builder itself are all unchanged. The reviewed candidate therefore stays
`build\n1\20261018T005854Z-b1ba58d65e7ffa1a` (`82eefa8a…0436`), and `fs-nonceonly-n1.ps1` (`a8fecbfd…`, the gate's
pinned candidate table) is unchanged. The r3 attempt uses a **fresh nonce-only rebuild made on the day** (WALKTHROUGH step
1), as r2 did. The suite's real rebuild (N3, N4, O6) made a fresh nonce-only rebuild into the main checkout's `build\n1`.
It passed `fs-nonceonly-n1` against b1ba58d6 and the observer's preflight, and was then removed by the test (§9).

## 9. Tests (offline, silent, `FS_SILENT=1`)

| suite | result | new cases |
|---|---|---|
| the N1 host suite (private) -BuildRoot <main checkout>\build\n1` → the N1 host suite (private) | **130 cases, 0 failed, 0 skipped** after §6B (129 after §6A, 128 before it; master's last full run: 110). The real rebuild ran: N3, N4 and O6 PASS. O5 did not run because the clone has no `build\k1a`, an optional input. | LV0–LV6; UN0–UN14 |
| the K1g host suite (private) -ImageSource <main>\build\k1a\…-ecbcbd4f7b6f43c0` → the K1g host suite (private) | **89 cases, 0 failed** (= FS-R-017's record; K1g unchanged; re-run after §6B) | none |

Before the review fixes, the same N1 suite gave 123/0 with `-SkipRebuild`. Reviewer B saw UN9 flake (MAJOR-2, fixed).

**The rebuild (N3).** N3 ran `n1/build-image.sh`, which writes into the main checkout's ignored `build\n1`. It made one
fresh nonce-only candidate; N4 and O6 checked it, and the test then deleted it. Before and after the runs, `build\n1`
holds the same five entries: b1ba58d6, <attempt nonce withheld>, two older candidates and `attempted`. No candidate was left behind, and
no ledger entry or evidence file was touched.

| UN case | covers |
|---|---|
| UN0 | the pins equal the committed facts; the real attempt verifies |
| UN1 | the shipped state: refused, awaiting the Chair |
| UN2 | **the one permitted path** |
| UN3 | 31 pins altered |
| UN4 | 16 bound files × 5 mutations, each with a restore control |
| UN5 | outcome or extra files (11 cases) |
| UN6 | 17 discovery cases (§6B: two-serial ledger entry and lock), plus the Unit 1 control |
| UN7 | Unit 1 never superseded; history required, with or without the evidence |
| UN8 | the outcome side: 18 refusals (§6B: hidden-directory, unknown-serial and two-serial locks, a two-serial ledger entry), a Unit 1 lock control and the valid successor |
| UN9 | phase A and observer integration: one attempt, then none; none without a ruling |
| UN11 | committed ledger copies |
| UN12 | reviewed bytes apart from the ruling pin |
| UN13 | SIGNOFF-n1 pins the working files |
| UN14 | §6A: the historical attempt's after-session facts (31 fact cases with §6B's 6 type and name cases, control, hash, missing file, outcome side) |

## 10. Adversarial reviews and dispositions

Two independent reviewers (model opus) worked read-only on commit `28fe494b`.

**(a) Safety and gate narrowness: ACCEPT WITH FIXES, no BLOCKER.** Attacks that held included:
- a switch, an environment variable or "latest wins";
- copied, renamed or second build/observe directories;
- ledger directories, entries naming no serial, upper-case names;
- an orphan observe.json, hidden locks;
- edits to any of the 11 bound files, an added outcome;
- changed tools or candidate table, an edited ruling;
- `..`, trailing-separator and upper-case roots.

The shipped state is inert.

| # | finding | disposition |
|---|---|---|
| F1 MINOR | The missing-history check depended on the committed evidence ledger being present. | **Fixed:** `$script:FsN1HistoryRequired` (true as shipped; only the tests switch it off); UN7 now also checks with no evidence present. |
| F2 MINOR | Deleting the r3 build directory and its ledger entry reopened the attempt. | **Fixed:** the committed N1 ledger copies are a fourth discovery path, on both the prior side and the outcome side (UN11). **Procedure:** commit the r3 ledger copy with the session's evidence, as for r2. |
| F3 MINOR | CHANGES-r3.md was missing. | **This file.** |
| F4 MINOR | Pinning the ruling after review changes the gate file. | **Fixed:** UN12 (reviewed bytes, with the three Ruling lines blanked); `RulingSections` format is validated. |
| F5 NOTE | Traces naming an unknown or lower-case serial were ignored. | **Fixed:** any serial other than exactly Unit 1's counts (UN6). |
| F6 NOTE | Hidden extra directories were not seen. | **Fixed:** `-Force`; the build directory may hold only the pinned observe directory (UN6). |
| F7 NOTE | xfer.json could be written into a directory someone else created, on the error path. | **Fixed:** it is written only where the engine's capture index exists. |
| F8 NOTE | The LV runs did not depend on LV0. | **Fixed:** no run is made unless every bed verifies. |
| F9 NOTE | The successor's engine was not checked. | **Fixed:** `EngineSha256` pin, checked for the checkout and in the successor's HostTools. |

**(b) Correctness and the live-path test: ACCEPT WITH FIXES, no BLOCKER.**
- It confirmed the root cause line by line.
- It found no other defect of the same class.
- It judged the fix the narrowest correct change, with every refusal kept.
- It judged LV sound and not vacuous: LV1 reproduces r2 with the pinned r2 bytes, and LV2/LV3 pass only with the fix.
- It judged UN3, UN4 and UN6 differential, with positive controls.

| # | finding | disposition |
|---|---|---|
| MAJOR-1 | A throw while writing xfer.json after the engine sent the collector to the catch, so collect.json was lost and the recovery text was contradictory (exit 70). This was a regression against r2, where that write happened inside the runspace. | **Fixed:** `Save-FsN1XferResult` never throws. Re-pinned. |
| MAJOR-2 | UN9 assumed an order between the two nonces in a message, which made it flaky (the ledger enumeration is alphabetical and the test nonce random). | **Fixed:** each nonce is checked separately. |
| MINOR-3 | The bed's client wrapper never exercised the live arguments. | **Fixed:** the wrapper asserts them before substituting (LV3). |
| MINOR-4 | CHANGES-r3.md was missing. | **This file.** |
| NOTE-5 | The xfer.json race on the error path. | **Fixed** (= a F7). |
| NOTE-6 | HostTools covered only three files. | **Fixed:** six files. |

After the fixes both suites were re-run in full (§9). There was no further review round. The Chair reviews the final
bytes named in §4, §6 and §7.

## 11. Limits and residual risks

- **The trust model is the same as K1g gate r1** (FS-R-017 §3: consistency and provenance checks, not authentication
  against a hostile operator). The historical attempt is pinned byte for byte. A successor's observe.json, ledger line,
  lock and HostTools are plain text written at the attempt. Forging them, or removing every trace of a successor
  including its committed ledger copy, would be falsification of a test record.
- **The lock of the historical attempt is not in the committed evidence.** Its hash is pinned from the build copy, and
  the tests rebuild it from its recorded text.
- **The test bed** proves the live control flow and the file handling. It does not prove the real USB, PnP or IPv6
  behaviour, or any real-time budget (§3).
- **What spends the r3 attempt:** as in FS-R-017 §5, registration spends it. A DEVICE_REJECTED handoff, an interrupted
  observer or a collector error after registration all spend it, and a repeat needs the Chair again.

## 12. Asked of the Chair

1. Review the collector fix, the live-path test, the N1 gate revision r1 and the regenerated SIGNOFF-n1 identity.
2. If the Chair concurs, issue a ruling for **one** replacement Unit 2 N1 attempt (N1 r3). The PM then pins that
   ruling's name, sections and LF SHA-256 in `fs-n1-units.ps1`. That is the only edit; UN12 proves it, and SIGNOFF-n1
   is regenerated.
3. The FS-R-015 / FS-R-016 §6 envelope applies unchanged: runner 126 s, device T0+74 s, host BootStartUtc+54 s,
   200/201 s, timing, thermal, readback, nonce, delegation and live assent. N1 still boots the unguarded K1a kernel.
