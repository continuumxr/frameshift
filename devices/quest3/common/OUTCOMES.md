# Outcome classes: experiment (i), stage 2a (§1–§7), the display test, stage 3a (§8), and trial (iii-b), stage 3b (§9)

**Answers:** FS-R-006 §5 F. Retain PASS, compatibility FAIL, integrity fault
and INCONCLUSIVE, with explicit precedence. **Supersedes the table in
FS-A-006 §5.3** where they differ. Changes:
- explicit, exhaustive precedence;
- the supervisor's end class replaces bare exit codes;
- integrity is measured by busybox steps;
- the `--list` rule follows T1-PINS §3.

**Revision 2** (adversarial review, S6):
- tool faults, including every `why≠none`, sit in rules **before**
  compatibility FAIL;
- a missing pinned file is an INTEGRITY FAULT;
- the `absent` parse is defined;
- `exec-failed` is split by errno;
- every step falls into exactly one class, and a catch-all closes the
  table.

**Revision 3** (second review):
- **S3:** a step ended by an *outside* SIGKILL, SIGTERM, SIGINT or SIGHUP
  (OOM killer, operator; not our timer) is a TOOL FAULT, not a
  compatibility FAIL.
- **Precedence:** a working `hash` step that *measured* a mismatch is an
  INTEGRITY FAULT even if `absent` had a tool fault.

**Revision 4** (coordinated round, 2026-10-09; decision J-49):
- **Step 8 `inv`**: a read-only inventory (FS-A-006 §5.1), **informational
  only**. It can never change the outcome class (§2, §3, §6).
- **§8**: the stage-3a (display test) classes and precedence.

**Revision 5** (FS-R-009 §3 and §4, 2026-10-09):
- The step-4 `list` content rule is **versioned** (§5):
  - **v1** (registered): applies to the runs registered under it (trial (i),
    nonce `<attempt nonce withheld>`), which therefore keep their registered result;
  - **v2A** (amended rule A, `stage2a/LISTING-RULE-A.md`): applies to every
    later run.
- **Selection.** `fs-classify.ps1 -ListRule v1|v2A` (CLI; the functions take
  `-ListRule`) selects a version; the name is case-sensitive. Without it, a
  registered run gets v1 and any other run gets v2A.
- **Registered-run lock (FS-R-009 §3).** A run registered under v1 can only
  be classified under v1, so its registered result cannot be re-graded.
- **Refusals.** These are checked before §6 and are never a verdict:
  - `-ListRule` naming any other rule for a registered run is refused:
    - CLI: `usage: rule-version refused for registered run: …`, exit 64,
      no OUTCOME line;
    - functions: **INCONCLUSIVE, rule 0**, reason
      `rule-version refused for registered run: …`, with no step classes;
  - an unknown version name is refused the same way:
    - CLI: usage, exit 64;
    - functions: INCONCLUSIVE, rule 0, reason `unknown list rule version: …`.
  - Rule 0 means "refused before §6". It is not a §6 row, and rule 8 stays
    unreachable.
- Every classification names the rule it applied (`ListRule`; the CLI line
  `Step-4 list rule applied: …`). Nothing else changes.

**Revision 6** (FS-R-010, 2026-10-10): **§9**, the stage-3b (trial (iii-b))
classes: machine side, optical side per run and per eye, and the combined
registered result. §1–§8 are unchanged, so the registered results of trial (i)
and trial (iii) reproduce exactly (`host/test-host2.ps1`; `host/test-host3b.ps1`
section D re-classifies the trial-(iii) capture: INCONCLUSIVE, §8 rule 2).
Implemented by `host/fs-classify3b.ps1` (dot-sourced by `fs-classify.ps1`).

**Status:** offline. Implemented by `host/fs-classify.ps1`
(`Get-FsStage2aOutcome`, `Get-FsStage3aOutcome`) with fixtures in
`host/test-host2.ps1` (sections K, L and S).

## 1. Inputs

| input | source |
|---|---|
| stage-1 class | `Get-FsOutcome` (`stage1/fs-proto.ps1`): PASS / DEVICE_REJECTED / TRANSPORT/SHELL FAILURE / INCONCLUSIVE |
| running kernel release | the verified `FSV1` record's `kernel=` |
| FSB1 verdict | `Test-Fsb1Record` with `exp=stage2a`, the image nonce, the challenge sent **once**, and the step list of §2 |
| pins | `stage2a/T1-pins.json` |

## 2. Step list (stage 2a)

Every step runs under `fs-supervise` with an empty environment.
`X = /valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib`.

| i | id | kind | program |
|---|---|---|---|
| 1 | `hash` | integrity (busybox) | `/bin/busybox sha256sum /valve/lib/ld-linux-aarch64.so.1 /valve/lib/libc.so.6 /valve/bin/uname /valve/bin/b2sum` |
| 2 | `absent` | integrity (busybox) | `/bin/busybox sh -c 'for p in /etc/ld.so.preload /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1 /usr/lib/libc.so.6; do [ -e "$p" ] || [ -L "$p" ] && echo "$p"; done; exit 0'` |
| 3 | `diag` | Valve | `X --list-diagnostics` |
| 4 | `list` | Valve | `X --list /valve/bin/b2sum` |
| 5 | `uname` | Valve | `X /valve/bin/uname -r` |
| 6 | `b2kat` | Valve | `X /valve/bin/b2sum` (stdin `/dev/null`) |
| 7 | `b2chal` | Valve | `X /valve/bin/b2sum` with `-i` a RAM file of exactly `<nonce>:<challenge>` (printf `%s`, no newline) |
| 8 | `inv` | **informational** (busybox) | `/bin/busybox sh /bin/fs-inv`: `cat` of `/proc/modules`, of `/sys/class/remoteproc/*/{name,state}` and of `/sys/class/power_supply/*/uevent`, and `ls -l` of the ADSP platform driver link. Read-only; a missing path is printed as `(absent)`/`(none)`, never an error |

**Step 8 is informational (revision 4).**
- Only its presence, its supervisor fields (`end`, `code`, `sig`, `why`) and
  its output are recorded and reported.
- It has its own class, **INFO**, whatever happened: a tool fault, a
  non-zero exit, a timeout, missing paths or an empty output are **noted,
  never escalated**.
- No rule of §6 reads step 8.
- Framing still applies: a record must carry all 8 steps (FSB1-SPEC §4
  `step-count`). A record without step 8 is not a valid stage-2a record
  (rule 2), exactly as one without step 7 would be. That is a framing
  check, not an escalation of the inventory.
- **Why last:** it runs after every outcome-bearing step, so a slow sysfs
  read (a `power_supply` uevent read calls into the drivers, e.g. the bq27
  fuel gauge over I2C) cannot delay or disturb them. Its own timeout bounds
  it.

## 3. Per-step classes (each step is in exactly one)

**TOOL FAULT** (our side failed, so the step says nothing about Valve). Any
of:
- `end` ∈ `refused internal nosup unreaped`;
- `why` ≠ `none`: `capture-write-failed` (for example tmpfs full, so a
  short capture is *our* truncation), `strays-alive`, `no-proc`, or any
  other token;
- `end=exec-failed` with an errno other than `ENOEXEC` (8) or `ELIBBAD`
  (80). Examples: `EACCES`, `ENOMEM`, `ENOENT`, `E2BIG`, `ETXTBSY`. These
  are environment or tooling conditions, not a format the kernel rejected.
- `end=signaled` with `sig` ∈ {9 SIGKILL, 15 SIGTERM, 2 SIGINT, 1 SIGHUP}
  (and therefore `term_ms=-1`: our timer had not fired). These signals come
  from outside the program: the OOM killer, an operator, a dying session.
  The program did not fail by itself. Signals a program raises through its
  own fault (SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGABRT, SIGSYS, SIGTRAP…)
  stay FAILED.

**For an integrity step** (1–2), when not a tool fault: **MEASURED** or
**UNPARSEABLE**, per §4.

**For a Valve step** (3–7), when not a tool fault, it is OK or FAILED:
- **OK** when all of these hold:
  - `end=exited`, `code=0`, `sig=0`;
  - `strays=0`, `pipes=eof`;
  - `out_kept = out_total`, `err_total = 0`;
  - its §5 content check is met.
- **FAILED** otherwise. That includes:
  - `exited` with a nonzero code;
  - `signaled` with any signal **not** in the outside-signal list above
    (SIGILL, SIGSEGV, SIGBUS, SIGABRT…);
  - `timer-term`, `timer-kill` (a hang; the evidence is the end class and
    `term_ms`/`kill_ms`, never a 143);
  - `exec-failed` with `ENOEXEC`/`ELIBBAD`;
  - `strays>0` or `pipes=open` with `why=none`;
  - more output than the cap (`out_total > out_kept` with `why=none`, so
    the binary itself wrote too much);
  - any stderr;
  - wrong content.

## 4. Integrity steps: exact parse

**`hash`** (busybox `sha256sum`): `end=exited`, `code` 0 or 1, `sig=0`,
`strays=0`, `pipes=eof`. Each of the four pinned paths appears **exactly
once**, either:
- on stdout as `^[0-9a-f]{64}  <path>$` (stdout lines in pin order), or
- on stderr as `^sha256sum: can't (open|read) '<path>': .+$` (cannot be
  read: missing, unreadable, a directory). This is the reviewed busybox's
  exact format, checked under qemu: `can't open '…': No such file or
  directory`, `can't read '…': Is a directory`, exit 1.

No other line may appear. `code=1` exactly when stderr is non-empty.
- The parse holds → **MEASURED**:
  - a stderr line (missing or unreadable pinned file) → integrity
    mismatch;
  - a digest that differs from its pin → integrity mismatch;
  - all four digests equal the pins (`2ddc56a0…a037e`, `be7ee393…bbb3b`,
    `4295f034…31f1`, `90154680…6402`) → integrity shown.
- Anything else → **UNPARSEABLE**.

**`absent`**: `end=exited code=0 sig=0`, `strays=0`, `pipes=eof`, stderr
empty, and stdout is zero or more lines. Each line is exactly one of the
five listed paths, at most once each, in list order.
- The parse holds → **MEASURED**:
  - empty stdout → integrity shown;
  - any listed path → integrity mismatch (the path could redirect library
    loading; T1-PINS §3).
- Anything else → **UNPARSEABLE**.

## 5. Valve content checks (exact; on the decoded bytes)

| step | content check |
|---|---|
| `diag` | Contains the lines `version.version="2.39"`, `version.release="stable"`, `path.system_dirs[0x0]="/usr/lib/"` and `dl_pagesize=0x1000`. Contains **no line starting `env[`** (the loader saw an empty environment; the T1 qemu run under fs-supervise had none) |
| `list` | **v1** (registered; trial (i) only): exactly 3 LF-terminated lines, each matching in full, in this order: <br>`\tlinux-vdso.so.1 (0x[0-9a-f]{16})` <br>`\tlibc.so.6 => /valve/lib/libc.so.6 (0x[0-9a-f]{16})` <br>`\t/lib/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1 (0x[0-9a-f]{16})` <br>**v2A** (amended rule A, FS-R-009 §4; all later runs): either those 3 lines, or ONE first line matching `\t \(0x[0-9a-f]{16}\)` (the unnamed main-program map) followed by those 3 lines. Its address must be nonzero and distinct from the 3 required addresses; there is no ordering condition. Anything else fails (`stage2a/LISTING-RULE-A.md`) |
| `uname` | Exactly `<kernel>\n` (`<kernel>` = FSV1 `kernel=`, expected `5.10.198-01402-g1c5986fe21ee`) |
| `b2kat` | Exactly `786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce  -\n` |
| `b2chal` | Exactly BLAKE2b-512(`<nonce>:<challenge>`) + `  -\n`, computed on the host. The newline variant still FAILS, reported as "newline variant" |

## 6. Precedence (apply in order; the first match is the outcome)

| # | condition | outcome |
|---|---|---|
| 1 | stage-1 class is not PASS | **that stage-1 class**. FSB1 text is reported as data only |
| 2 | no FSB1 record, a `Test-Fsb1Record` rejection (FSB1-SPEC §4), or completion after the host's collection deadline | **INCONCLUSIVE** (with the rejection code) |
| 3 | step 1 or step 2 MEASURED an integrity mismatch (even if the other integrity step is a TOOL FAULT or UNPARSEABLE) | **INTEGRITY FAULT**: an image or build fault, not a compatibility result. Stop and investigate |
| 4 | step 1 or step 2 is a TOOL FAULT or UNPARSEABLE (and neither measured a mismatch) | **INCONCLUSIVE**: integrity unmeasured |
| 5 | any Valve step (3–7) is a TOOL FAULT (step 8 `inv` is never consulted) | **INCONCLUSIVE**: our side failed during the Valve steps |
| 6 | any Valve step is FAILED | **compatibility FAIL**. Report the lowest failing step first, and list all |
| 7 | every Valve step is OK (with integrity shown by both 1 and 2) | **PASS** |
| 8 | anything else (not reachable if §3–§4 are implemented as written) | **INCONCLUSIVE** |

**Why this order:**
- **2 before everything:** fields from an invalid record cannot be
  trusted.
- **3 before 4 (revision 3):** a mismatch that a working step measured is
  evidence on its own. The other integrity step failing does not undo it.
  A step that did not work measures nothing, so it can never produce rule
  3.
- **4 before 5–6:** results about files that are not the pinned files
  mean nothing.
- **5 before 6 (as the review asked):** if our supervisor failed anywhere
  in the Valve phase, the run is not used as compatibility evidence.
  Definite failures in other steps are still listed in the report as
  data.

**Separate gates.** Never merged into the outcome:
- the persistent-state check (`MISC-RULE.md`, plus the partition and slot
  checks of FS-A-006 §5.5 item 3; method private). STOP halts further trials
  whatever the outcome;
- the recovery result.

**Scope of a PASS** (FS-R-006 §5): these selected binaries and libraries
execute on the stock Quest kernel. It does not establish systemd, Steam or
a functioning SteamOS system.

## 7. What the exit status is (and is not) used for

The classifier reads `end`, `code`, `sig`, `errno`, `term_ms`, `kill_ms`
and `why`. It never infers a timeout from a code:
- `end=exited code=143` is a program that exited 143;
- a timeout is `end=timer-term` or `end=timer-kill`.

(`fs-supervise` fixtures `exit143`, `term143`.)

## 8. Stage 3a: the display test (revision 4)

**Inputs.**
- The stage-1 class and the verified `FSV1` record, as in §1.
- The FSB1 verdict of `Test-Fsb1Record`, with `exp=stage3a`, the image
  nonce, the challenge sent **once** (`fs-display <chal>`), and steps
  `hash,pattern`.
- The `fs-pattern` pin: SHA-256 `c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a`
  (v0.4; `stage3a/build-image.sh`).

**Steps.**

| i | id | program (under `fs-supervise`) |
|---|---|---|
| 1 | `hash` | `-t 3`: `/bin/busybox sha256sum /bin/fs-pattern` |
| 2 | `pattern` | `-t 16 -g 3`: `/bin/fs-pattern show <chal[0:8]> 10` (stdout: the supervisor's pipe → a RAM file) |

**`hash` parse (exact).**
- MEASURED shown: `end=exited code=0 sig=0`, `strays=0`, `pipes=eof`,
  stderr empty, and stdout exactly `<64 hex>  /bin/fs-pattern\n` with the
  digest equal to the pin.
- MEASURED mismatch:
  - the same form, with any other digest; or
  - `end=exited code=1`, stdout empty, stderr exactly one line
    `sha256sum: can't (open|read) '/bin/fs-pattern': <text>`.
- TOOL FAULT: the §3 rules.
- Anything else: UNPARSEABLE.

**The FSP1 stream** (the `pattern` step's stdout payload) is checked with
the `stage3a/tools/check_stream.py` rules:
- every record matches the grammar, with `len` and CRC-32 correct;
- `seq` runs 0, 1, 2, … with no gap;
- one nonce throughout;
- the last record is `eos`, right after `exit`, with `records` equal to the
  count and `dropped=0`.

On top of that, the host requires:
- the nonce equals the first 8 characters of the challenge;
- the `exit` record's `code` equals the process exit code;
- the capture was not truncated (`out_kept = out_total`) and stderr is
  empty.

A stream meeting all of this is **sound**.

**Precedence** (first match wins):

| # | condition | outcome |
|---|---|---|
| 1 | stage-1 class is not PASS | that class |
| 2 | no record, an FSB1 rejection, or completion after the host's collection deadline | **INCONCLUSIVE** |
| 3 | `hash` MEASURED a mismatch (a digest that is not the pin, or `can't open/read`) | **INTEGRITY FAULT** |
| 4 | `hash` is a TOOL FAULT or UNPARSEABLE | **INCONCLUSIVE**: integrity unmeasured |
| 5 | `pattern` is a TOOL FAULT (§3 rules, including an outside SIGKILL/TERM/INT/HUP) | **INCONCLUSIVE** |
| 6 | `pattern` ended `timer-term` or `timer-kill`, or `signaled` with any other signal (for example its own SIGALRM backstop, 14), or `exec-failed` with ENOEXEC/ELIBBAD | **DISPLAY FAIL** (hang, stall or not runnable) |
| 7 | `pattern` `exited`, but the stream is not sound (above) | **INCONCLUSIVE**: the evidence is unreadable |
| 8 | `exited` code 10, 11, 12, 20, 21, 30, 40 or 50 (README "Exit codes": no device; not a DRM node; not msm_drm; no connector; atomic/planes/properties; mode refused; buffer; every TEST_ONLY rejected) | **NO-DISPLAY**, with that reason. No real commit was made |
| 9 | `exited` code 60 (the real commit failed) or 1 (internal error during the hold) | **DISPLAY FAIL** |
| 10 | `exited` code 0, **and** a `commit rc=0` record, **and** `hold_end rc=0 reason=deadline`, **and** `exit code=0 reason=held_to_deadline shown=1` | **PASS (machine side)** |
| 11 | anything else: code 0 without the records of rule 10; code 2 or 3 (our invocation was refused); code 70 (stopped by a signal that was not our timer); any other code | **INCONCLUSIVE** |

**Scope of the stage-3a PASS.**
- It is the **machine side only**: `fs-pattern` committed one frame, the
  driver accepted it, and the hold ran to its deadline.
- **The real success criterion is the PM reading the 8 characters through
  the lenses, on both eyes**, plus the orientation marks
  (`stage3a/README.md` "The image").
- A machine-side PASS with a wrong or missing reading is a display result
  to investigate, not a PASS. `shown=1` never proves that light reached
  the eye.

**Separate gates**, as in §6: the misc rule, the partition/slot
checks, and recovery.

## 9. Stage 3b: trial (iii-b), the revised display test (revision 6, FS-R-010)

§8 stays as written for stage 3a. This section is new and applies only to
records with `exp=stage3b`.

### 9.1 Inputs

- The stage-1 class and the verified `FSV1` record, as in §1.
- The FSB1 verdict of `Test-Fsb1Record`, with `exp=stage3b`, the image nonce,
  the challenge sent **once** (`fs-display <chal>`), and the steps below.
- The `fs-pattern` v0.5 pin: SHA-256
  `4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6`
  (`stage3b/build-image.sh`).
- The PM's readings (§9.5), recorded after the attempt as four `FSR1` lines
  (`fs-classify.ps1 -Stage 3b -Readings <file>`).

### 9.2 Steps (`stage3b/fs-display.sh`)

| i | id | program (under `fs-supervise`) | role |
|---|---|---|---|
| 1 | `hash` | `-t 2 -g 1 -c 256`: `/bin/busybox sha256sum /bin/fs-pattern` (runs concurrently from the start) | integrity |
| 2 | `probe1` | `-t 26 -g 1 -c 16384`: `/lib/fs/fs-probe.sh run1` | informational, plus the backlight evidence |
| 3 | `pattern1` | `-t 9 -g 3 -c 40960`: `/bin/fs-pattern show <chal[0:8]> 3` | run 1 |
| 4 | `probe2` | `-t 32 -g 1 -c 12288`: `/lib/fs/fs-probe.sh run2` | informational, plus the backlight evidence |
| 5 | `pattern2` | `-t 16 -g 3 -c 28672`: `/bin/fs-pattern show-off <chal[0:8]> 10` | run 2 |

A run that the runner does not start is still a step: `/bin/busybox echo
"FSK1 run=<n> skipped reason=<why> END"` (`-t 2 -g 1 -c 256`). Its stdout must
be exactly that one line; anything else is not a skip record.

**Parses.**
- `hash`: exactly as §8 (`<64 hex>  /bin/fs-pattern\n`, the v0.5 pin).
- A run step: a skip record; or a hang (`timer-term`, `timer-kill`,
  `signaled` with a signal that is not an outside KILL/TERM/INT/HUP,
  `exec-failed` with ENOEXEC/ELIBBAD); or a TOOL FAULT (§3); or `exited` with
  a **sound** FSP1 stream (§8's definition: the `check_stream.py` rules, nonce
  = `chal[0:8]`, `exit code` = the process exit code, not truncated, stderr
  empty).
- Run facts from a sound stream: **committed** (`commit rc=0`); **held**
  (also `hold_end rc=0 reason=deadline` and `exit rc=0 code=0
  reason=held_to_deadline shown=1`); **clean close** (held and `hold_end
  close_rc=0`); the monotonic stamps `hold_start start_ms`, `hold_end
  held_ms`, `close_ms`; `start mode=`; `crtc_state active=`; the
  `precondition` record (show-off).
- Backlight evidence: in `probe1`, the lines `== backlight-write
  node=/sys/class/backlight/panel0-backlight/brightness value=127` (count)
  and `write_rc=<rc> readback=<v>`; in `probe2`, `readback=<v>` and no write
  line. **Verified before run 1** = exactly one write line and read-back
  `127`; **verified before run 2** = read-back `127` and no write.
- **Pause** = run 2 `start_ms` − (run 1 `start_ms` + `held_ms` + `close_ms`):
  from the end of run 1's close (the panel-off path) to the start of run 2's
  commit (the panel-on path), on CLOCK_MONOTONIC of the same boot.

### 9.3 What the runner guarantees (and the classifier re-checks)

- Run 1 starts only if the brightness was verified before it.
- Run 2 starts only if run 1's supervisor reported `end=exited code=0 sig=0
  strays=0 pipes=eof why=none`, its stream has the accepted commit, `hold_end
  rc=0 reason=deadline … close_rc=0`, `exit … shown=1` and `eos … dropped=0`,
  and the brightness was verified again before run 2.
- Run 2 is `show-off`: `fs-pattern` commits nothing unless the CRTC is
  **provably inactive** at start (GETCRTC succeeded, the ACTIVE property was
  found, ACTIVE = 0); otherwise it records `precondition rc=-16` and exits 31.
- The runner pauses at least 2 s between run 1's end and run 2's start.

A record in which the runner departed from these rules is INCONCLUSIVE
("runner inconsistency"), never a verdict.

### 9.4 Machine side: precedence (first match wins)

| # | condition | outcome |
|---|---|---|
| 1 | stage-1 class is not PASS | that class |
| 2 | no record, an FSB1 rejection, or completion after the host's collection deadline | **INCONCLUSIVE** |
| 3 | the decoded steps are not the §9.2 list, or the nonce/challenge are missing | **INCONCLUSIVE** |
| 4 | `hash` MEASURED a mismatch | **INTEGRITY FAULT** |
| 5 | `hash` TOOL FAULT or UNPARSEABLE | **INCONCLUSIVE** (integrity unmeasured) |
| 6 | runner inconsistency: more than one write line in `probe1`, any write line in `probe2`, run 1 skipped but run 2 not skipped, or run 2 executed without run 1's accepted commit and clean close | **INCONCLUSIVE** |
| 7 | run 1's step is a TOOL FAULT | **INCONCLUSIVE** |
| 8 | run 1 skipped (its reason is reported, e.g. `brightness-not-verified`, `probe1-late`) | **INCONCLUSIVE**: no display experiment took place |
| 9 | run 1 hang or not runnable | **DISPLAY FAIL** |
| 10 | run 1 `exited`, stream not sound | **INCONCLUSIVE** (evidence unreadable) |
| 11 | run 1 ran without the brightness verified before it, or its mode is not `show` | **INCONCLUSIVE** (runner inconsistency) |
| 12 | run 1 exit 10, 11, 12, 20, 21, 30, 40 or 50 | **NO-DISPLAY** (no commit), with the reason |
| 13 | run 1 exit 60 or 1 | **DISPLAY FAIL** |
| 14 | run 1 exit 0 without being held, or any other code | **INCONCLUSIVE** |
| 15 | run 1 committed and held, but its close was not clean | **RUN 1 ONLY** (run 2 not executed) |
| 16 | run 1 clean; run 2 skipped (reason reported) | **RUN 1 ONLY**: no off→on experiment |
| 17 | run 2's step is a TOOL FAULT | **INCONCLUSIVE** |
| 18 | run 2 hang or not runnable | **DISPLAY FAIL** |
| 19 | run 2 `exited`, stream not sound | **INCONCLUSIVE** |
| 20 | run 2 ran without the brightness verified before it, or its mode is not `show-off` | **INCONCLUSIVE** (runner inconsistency) |
| 21 | run 2 exit 31 with `precondition rc=-16` and no commit | **PRECONDITION UNMET: CRTC ACTIVE**: no off→on claim (FS-R-010 §4) |
| 22 | run 2 (with a proven inactive CRTC) exit 10–50: **NO-DISPLAY**; exit 60 or 1: **DISPLAY FAIL** | as stated, "run 1 committed" in the reason |
| 23 | the pause stamps are missing, or the pause is below 2000 ms | **INCONCLUSIVE**: not the registered experiment |
| 24 | anything else, including run 2 without a proven inactive CRTC (`precondition rc=0`, `active_prop` non-zero, `getcrtc_rc=0`, `crtc_state active=0`) and exit 31 without the precondition record | **INCONCLUSIVE** |
| 25 | run 1: accepted commit, held, clean close; run 2: proven inactive CRTC at start, committed and held; pause ≥ 2000 ms; brightness verified before both runs | **PASS (machine side)** |

The probe steps never change the class beyond rules 6, 11 and 20 (they are
informational, as stage 2a's `inv`). A probe killed by the runner after its
time (`end=nosup`) is reported, not escalated.

### 9.5 Optical side (the PM's readings)

**Form.** Exactly four lines, one per run and eye, no other lines (comments
starting `#` are ignored):

```
FSR1 run=<1|2> eye=<left|right> obs=<DARK|LIT|GARBLED|READ> [chars=<8 of 0-9 A-F ?>]
```

`DARK` = no light seen; `LIT` = light without a pattern; `GARBLED` = a
pattern that cannot be read (lines, noise, misplaced parts); `READ` = the
characters as read (`chars=` required with READ and only with READ; `?` for a
character that could not be read). A malformed, missing or duplicated line
makes the optical side **INCONCLUSIVE**. "No light seen" is not a measurement
of zero emitted light (FS-R-010 §2).

**Precedence** (first match wins). Per run, the record is in one of three
states: *machine-shown* (it shows the run committed and held: run 1 when the
machine side got past rule 5 (integrity measured) and run 1's sound stream shows
the commit, the hold to its deadline and the clean exit; run 2 only with rule 25); *no commit* (it shows the run made no
commit: a skip record, or a run without `commit rc=0`, e.g. exit 10–50 or 31);
*absent or unusable* (no record, a rejected or late record, a record over the
emitter's size cap (`FSDE1 error=record-too-large`), an integrity fault (rules
1–5), or a run step that is a tool fault, a hang or unsound, or that committed
but is not the registered run).

| # | condition | optical result |
|---|---|---|
| O1 | in one run, BOTH eyes read all 8 characters correctly (exactly `chal[0:8]` in upper case), and that run is machine-shown | **OPTICAL PASS** |
| O2a | both eyes correct in a run with *no commit* | **INCONCLUSIVE**: contradicts the record |
| O2b | both eyes correct in a run whose record is *absent or unusable* | **INCONCLUSIVE**: the commit cannot be confirmed |
| O3 | a correct reading in one eye only, in a *machine-shown* run | **ONE-EYE ONLY**: a display result to investigate, not a PASS |
| O3a | a correct one-eye reading only in runs with *no commit* | **INCONCLUSIVE**: contradicts the record |
| O3b | a correct one-eye reading only in runs whose record is *absent or unusable* | **INCONCLUSIVE**: cannot be confirmed |
| O4 | any eye in any run LIT, GARBLED or READ (not correct) | **LIT BUT GARBLED**: a lighting finding, not a PASS |
| O5 | all four DARK, and both runs machine-shown | **BOTH DARK** |
| O6 | otherwise (all four DARK) | **DARK** |

**Labels** (reported with the result): **RUN 1 DARK, RUN 2 LIT** when run 1 is
DARK in both eyes, run 2 is lit in at least one eye, and the machine side is
rule 25; **PRECONDITION UNMET: no off→on claim for run 2** with rule 21.

### 9.6 The registered result

- **STAGE PASS** only with OPTICAL PASS in a machine-shown run: machine side
  rule 25 (either run), or rule 15/16/21 with the reading in run 1.
- Everything else is registered as *not a stage PASS*, with the machine
  outcome, the optical result and the labels, e.g. `not a stage PASS:
  machine PASS (machine side); optical LIT BUT GARBLED (lighting finding,
  not PASS); RUN 1 DARK, RUN 2 LIT`.
- FAIL and INCONCLUSIVE classes are preserved as in §8. The CLI exit codes:
  10 PASS (machine side), 12 INTEGRITY FAULT, 13 stage 1 not PASS, 14
  INCONCLUSIVE, 15 NO-DISPLAY, 16 DISPLAY FAIL, 17 PRECONDITION UNMET, 18 RUN 1
  ONLY. The optical result and the registered line are printed, not encoded
  in the exit code. When the runner printed a refusal instead of a record
  (e.g. `FSDE1 error=record-too-large lines=N max=2070 END`), the CLI prints it
  (`RUNNER REFUSAL: …`) and the rule-2 reason carries it.

**Separate gates**, as in §6: the misc rule, the partition/slot
checks, recovery, and the temperature procedure (`devices/quest3/SIGNOFF.md`).
