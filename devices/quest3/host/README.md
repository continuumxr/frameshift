# Quest 3 host tools for stage 2a and stage 3a (collector, classifier, misc rule, E1, before/after)

**Status:** offline only, revision 4 (fix round 6, 2026-10-09). No device,
adb, fastboot or COM port was used.
*(Status 2026-10-11: these tools were concurred and used in trials (i) and
(iii) (FS-R-008); with the later stage-3b additions they are pinned for trial
(iii-b), which FS-R-011 §1 concurs to execute: the FS-A-011 §1.1 pins plus
`fs-native.ps1` `101ddfb1…`, `../common/host/fsb1.ps1` `1f84c633…` and
`../stage1/fs-proto.ps1` `52e007eb…` (FS-R-011 §1A; `../SIGNOFF.md`). The
"re-review is pending" and "nothing here is proposed" lines below are
historical.)*
- **Revision 4** (the package reviews of `cf251bb`):
  - `fs-observe.ps1`, the stage-2a/3a observer, which runs no session (B1);
  - the collector: an ack-window cap (S1), a foreign-ack stop (B1), a
    runner refusal (S2), and a pause for the stage-3a dark check;
  - `fs-classify.ps1 -ObserveDir` (the stage-1 class is derived);
  - the SIGALRM reason-string fix;
  - the `.sh` E1 refuses symlink entries;
  - a UTF-8 BOM on every `.ps1` with non-ASCII text;
  - before/after: the capture method (withheld; method private), the
    Android-landing branch, and stage 3a.
  - Before/after: `fixtures/round6-before.ps1` gives 0/6 on `cf251bb` and
    6/6 now. `fixtures/gitcheck/round6-before.txt` shows G25a failing on
    `cf251bb` and passing now.
- **Revision 3** was a coordinated round with common, stage 2a and stage 3a:
  - `fs-collect.ps1 -Stage 2a|3a`: the `fs-display` verb, and per-stage
    experiment, steps and device deadline (260 s / 170 s, the images'
    `DEADLINE`);
  - `fs-classify.ps1`: stage-2a step 8 `inv` is INFO and never changes the
    class (OUTCOMES rev 4); `Get-FsStage3aOutcome` and `-Stage 3a`
    (OUTCOMES §8), with an FSP1 stream check equal to
    `stage3a/tools/check_stream.py`;
  - fixtures: K74–K81, section S (S01–S46), 3 stage-3a replay captures,
    and F6g updated;
  - before/after: `fixtures/round5-before.ps1` gives 0/6 on `5a8308d` and
    6/6 now (`fixtures/round5-before.*.txt`).
- Revision 1 (`da0ad56`) was reviewed adversarially: NOT READY (1 blocker,
  4 should-fix, nits).
- Revision 2 fixes every finding, each with a fixture that fails on
  `da0ad56` and passes now (section F; table in `COLLECTOR.md` §8).
- Re-review is pending. Nothing here is proposed for a device. That needs
  FS-A-007, the Chair, then the PM's live sign-off.

**Read only, not modified:**
- `../stage1/` (`fs-proto.ps1`: `Test-FsVerify`, `Test-FsAck`,
  `Get-FsGadget`);
- `../common/` (`host/fsb1.ps1`; specifications `OUTCOMES.md` rev 4,
  `MISC-RULE.md`, `tools/misc_rule.py`, encoder revision 5).

## Files

| file | what |
|---|---|
| `fs-observe.ps1` | **the stage-2a/3a observer** (fix round 6, B1). Preflight, then with `-ConfirmNonce` exactly one `fastboot boot`, Th, the gadget watch, `observe.json`. **No session.** `-ThenCollect` starts the collector |
| `fs-collect.ps1` | the serial collector: live `[-Stage 2a|3a] -Port COMn -BootStartUtc … [-HandoffUtc …]` (origin BootStartUtc, FS-R-007 B1), or `-Replay <capture.raw>`. Design, D1, send gate, timing table: `COLLECTOR.md` |
| `fs-classify.ps1` | OUTCOMES rev 4 outcome classifier, stage 2a (§6) and stage 3a (§8). CLI `[-Stage 2a|3a] -CollectDir <dir> -Stage1Class <observer outcome>`, exit 10 PASS (3a: machine side) / 11 compat FAIL / 12 INTEGRITY / 13 stage 1 not PASS / 14 INCONCLUSIVE / 15 NO-DISPLAY / 16 DISPLAY FAIL / 64 / 70 |
| `fs-miscrule.ps1` | port of `common/tools/misc_rule.py` (MISC-RULE v1). Exit 10–14, usage 64, arguments handled exactly as Python's `sys.argv` |
| `fs-gitcheck.ps1`, `fs-gitcheck.sh` | E1 plus revision-2 hardening (below). The `.sh` is for the bash builder |
| `fs-native.ps1` | Add-Type C#: BLAKE2b-512, byte diff, hex, bounded-time Flush/Close, `ConvertTo-FsPrintable` |
| before/after state-capture tooling | withheld from this copy (method private) |
| `fixtures/gen-replay.ps1`, `fixtures/synth.ps1`, `fixtures/replay/` | 37 deterministic replay captures, 3 of them stage 3a (`MANIFEST.sha256`) |
| `fixtures/round5-before.ps1` | the revision-3 probes: run against `5a8308d` (all FAIL) and now (all PASS) |
| `fixtures/round6-before.ps1` | the revision-4 probes: run against `cf251bb` (all FAIL) and now (all PASS); `round6-before.*.txt` |
| `fixtures/findings-da0ad56.ps1` | section F: the review-finding fixtures. `fixtures/findings-da0ad56.before.txt` is their run against `da0ad56` |
| `fixtures/gitcheck/run-gitcheck-fixtures.sh` | E1 regression fixtures (POSIX sh, throwaway repositories) |
| `test-host2.ps1` → `test-host2.output.txt` | all fixtures |
| `fs-collect3d.ps1`, `fs-session3d.ps1`, `fs-classify3d.ps1`, `fs-observe3d.ps1`, `fs-checklist3d.ps1`, `fs-nonceonly3d.ps1` | **stage 3d** (v2.7, either Quest 3 unit; 2026-10-13): the collector, prompts, classifier, observer, console checklist and the nonce-only check (it opens both images; the observer requires it for any image other than the reviewed candidate). Design: `../stage3d/HOST.md`; the PM's steps `../stage3d/WALKTHROUGH.md`; pins `../SIGNOFF-3d.md`. Since J-143/J-145 (`HOST.md` §9): a standing phase-A acceptance and carried-over sound check and rehearsals (`captures\standing\`; `fs-carry3d.ps1`: the tool set and the made record; the sound check is `fs-collect3d.ps1 -S3dSoundCheck`), a reading while charging accepted below 300; `eos opt_skipped` explained in `HOST.md` §2 item 12 |
| `test-host3d.ps1` → its output (private); `fixtures/stage3d/` | the stage-3d suite; the generator `gen3d.ps1` and the canonical replays (`garbled-r3` and the timed `nominal-read` are the two rehearsals) |

## Run

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host2.ps1 [-Scratch <dir>] [-OutFile <file>]
# the review fixtures against another revision (expected to FAIL there):
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host2.ps1 -HostDir <copy of da0ad56>\devices\quest3\host -Only F -OutFile <file>
```

The log goes to `-OutFile` (default `test-host2.output.txt` beside the
script). Scratch defaults to a new `%TEMP%\fs-host2-*` directory.

| section | what | result |
|---|---|---|
| N | BLAKE2b-512 vs RFC 7693, the OUTCOMES KAT, Python hashlib | 9/9 |
| C | command construction (now including `fs-display`), one write site, strict C4 | 22/22 |
| O | `fs-observe.ps1` (round 6, B1): sign-off gate, refusals, exactly one fake `fastboot boot`, no session; dry observer → collector → classifier (`-ObserveDir`); `already-acked`; round 7: copied build folder refused (O19), handoff basis on timeout (O20), fs-done after a foreign ack at the window end (O21); revision 9 (FS-R-007 B1): origin BootStartUtc for every handoff class (O20, O22) and taken before the boot call (O23) | 23/23 |
| R | 42 replay captures (4 stage 3a; round 6 adds `already-acked`, `runner-refused-2a/3a`, `ack-window-reached`; round 7 adds `runner-budget`; revision 9 adds `b1-late-2a/3a`) through the collector, then FSB1, then the classifier | 63/63 |
| X | replay robustness and CLI refusals (exit 20); revision 9: `-HandoffUtc` without `-BootStartUtc`, and Th before BootStartUtc, refused (X10, X11) | 11/11 |
| T | FS-R-007 B1 timing (`fixtures\b1-timing.ps1`): the real observer → live collector command line against a simulated device side; Chair counterexample refused in 3a and 2a (T1, T2), 20 s preparation not added back (T3, T4), origin/evidence recorded (T5), normal and uncertain-handoff behaviour preserved (T6–T8), future origin refused (T9, nit N1) | 10/10 |
| K | stage-2a classifier: every rule and precedence edge, plus step 8 `inv` INFO (K74–K81; OUTCOMES rev 4) | 81/81 |
| S | stage-3a classifier: every §8 rule (S01–S40), the FSP1 check vs Python `check_stream.py` (S41–S42), the `-Stage 3a` replay and CLI (S43–S46), the display cue (S47–S48, round 7), and the revision-8 single-operator protocol: beep/pause/beep order in the index, distinct beeps, 2 fs-status tries, none in 2a, bytes during the pause block fs-done (S49–S54) | 58/58 |
| M | misc: 26 cases, full output identical to Python, plus 7 CLI cases | 33/33 |
| G | E1 (Windows git 2.55) plus the sh fixtures under WSL dash and bash --posix (39/39 each) | 18/18 |
| B | before/after data: read-only allowlist, no `>` anywhere | 12/12 (public copy: SKIP, withheld) |
| P | the before/after capture tool against compiled fake adb/fastboot (revision 8, Chair S2): every phase, read-only invocations only, the misc rule on the captured pair, refusals (P1–P16) | 19/19 (public copy: SKIP, withheld) |
| F | review findings: B1 send gate (9), S2 E1 (8, including sh under WSL dash/bash and Git Bash 34/34), S3 binary captures (5; public copy: SKIP, withheld), S4 escaping (2), S5 classifier (4), nits (14) | 42/42 |
| **total** (revision 9, Chair ruling FS-R-007 B1) | | **401 passed, 0 failed, 0 skipped** (private run; the public copy prints SKIP for withheld sections) |
| B1 before/after | `fixtures\b1-timing.ps1` | `fbca773`: T1–T5 and T9 FAIL, T6–T8 pass (`b1-timing.fbca773.txt`); T9 FAIL on `5c2e3f9` (`b1-timing.5c2e3f9.txt`); now 9/9 (`b1-timing.after.txt`) |
| round 7 before/after | `fixtures\round7-before.ps1`: 5 probes (SF1, NIT4, NIT3, NIT7, display cue) | `685da7c`: 0/5 (`round7-before.685da7c.txt`); now 5/5 (`round7-before.after.txt`) |
| F on `da0ad56` | the same 42 checks against the reviewed revision | **39 FAIL**, 3 pass: two positive controls (F1h, F6i one-argument) and F6k. F6k passes because the old source already met the strict C4 form; the finding was the weak test, now fixed in C4 |

## Revision 2 (review of da0ad56)

- **B1, send gate.** Before every write the collector reads whatever has
  arrived. It then requires:
  - zero bytes since the last settled prompt;
  - the tail of the whole capture byte-identical to the expected prompt;
  - for the first command: nothing received, or a quiet primary prompt.

  Otherwise nothing is sent, ever again, and the result is INCONCLUSIVE.
  `fs-done` goes through the same gate.
- **S2, E1.** Changes, in both `fs-gitcheck.ps1` and `fs-gitcheck.sh`:
  - `GIT_NO_REPLACE_OBJECTS=1`, and any `refs/replace` is refused;
  - `info/grafts` and `objects/info/alternates` are refused;
  - only the repository config is read: `GIT_CONFIG_NOSYSTEM=1`,
    `GIT_CONFIG_GLOBAL=NUL` or `/dev/null`; `GIT_CONFIG_SYSTEM`,
    `GIT_ATTR_SOURCE`, `HOME` and `XDG_CONFIG_HOME` are scrubbed;
  - every blob of the pinned tree is compared with
    `hash-object --no-filters` of the work-tree file;
  - a file-system walk refuses untracked files, nested repositories and
    links.

  **Mode bits** are read from the file system (sh). They are reported as
  "not checkable" where the file system stores no exec bits:
  - Windows;
  - Git Bash;
  - **WSL drvfs without `metadata`, which is where the real AOSP checkout
    lives** (`/mnt/c/...`: every file shows 777).
- **S3.** A byte-exact pull (tooling withheld) replaces the `cmd.exe … >`
  form. The binary bytes never pass through a shell. The host hash must
  equal the device-side hash before `adb reboot bootloader`.
- **S4.** All console output, and every stored reason or note that quotes
  device text, is escaped by `ConvertTo-FsPrintable`.
- **S5, classifier:**
  - `[long]` comparisons replace the `[int]` casts;
  - any internal error is INCONCLUSIVE (rule 8, "classifier error"), never
    a skipped check;
  - CLI codes no longer collide with crash codes. The collector's codes
    were changed the same way (10/11/14/20/70).
- **Nits:**
  - capture write and close errors leave INCONCLUSIVE plus a `RECOVERY:`
    line plus `collect.json`;
  - `W` is logged only after a successful write;
  - live Flush/Close are bounded (2 s/3 s);
  - the host gives up 15 s before the earliest device deadline
    (`-BootStartUtc` required live since revision 9, FS-R-007 B1; timing table in `COLLECTOR.md` §4);
  - misc CLI arguments are handled like Python;
  - `-OutFile`;
  - strict C4.

## Design decisions (unchanged from revision 1)

- Device bytes are data only. Commands come from a fixed verb table plus
  hex tokens, one at a time.
- Raw byte capture, with an index and a SHA-256. The whole capture goes to
  `Test-Fsb1Record`.
- Replay is gated on recorded writes and runs the same engine.
- **Classifier interpretation:** a truncated `hash`/`absent` capture is
  UNPARSEABLE (K20).

## Open

1. **Live transport never run** (SerialPort reads, DTR, a port vanishing).
   Only the bounded-timeout mechanism is tested.
2. ~~Finding for common (FSB1 encoder)~~: **adopted**. Common encoder
   revision 5 prints the empty line; see `COLLECTOR.md` §6.
3. ~~The stage-2a init and runner, and the timing~~: **done**. See
   `stage2a/IMAGE.md` and `stage3a/IMAGE.md`. The runners keep the
   stage-1 `fs-ack`/`fs-status` helpers. Per-step timeouts are sized to the
   record budget (`COLLECTOR.md` §4), and `stage2a/tools/check-timing.py`
   enforces it.
4. **E1 is wired** into the stage-2a and stage-3a builders. They source
   `fs-gitcheck.sh`, and their MANIFEST carries any `NOTE:` it prints
   (fix round 6). `stage1/build.sh` is read-only and keeps its old check.
   - **Mode bits cannot be enforced on the current `/mnt/c` checkout.** To
     enforce them, the PM could move the AOSP checkout to the WSL ext4 file
     system, or mount drvfs with `metadata`.
5. **Before/after:**
   - no comparison script (only misc is automated);
   - the `pstore` rule is a proposal;
   - the capture tooling (withheld) has been run only against a fake adb.
6. **Re-review** of revision 2 (adversarial).
7. **Re-sync with common** if `OUTCOMES.md`, `MISC-RULE.md` or
   `misc_rule.py` change again (last synced: `6761d4c`).
