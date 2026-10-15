# Quest 3 common: shared PID 1 infrastructure for stage 2a and stage 3a

**Status (round 5, 2026-10-09):** encoder revision 5 and OUTCOMES
revision 4, from the coordinated round with `host/` revision 3 and the
stage-2a/3a images.
- `target/fsb1-enc.sh` `fsb1_emit` writes **one empty line before
  `FSB1 BEGIN`** (`host/COLLECTOR.md` §6). Fixtures `noecho-prompt-emitted`
  and `noecho-prompt-joined`: 38/38 now; the revision-4 encoder scores 37/38
  in the same harness (`fixtures/round5-before/`).
- `OUTCOMES.md` revision 4:
  - stage-2a step 8 `inv`, informational (never changes the class);
  - §8, the stage-3a classes and precedence.
- `src/`, `build/`, `pid1-hold.sh` and `fs-done` are unchanged; their
  suites were re-run (table below).

**Earlier status:**
2026-10-09 (revision 3 plus the second review's S1–S3 and nits):
- no device was used, and no adb or fastboot;
- no Valve binary is in the repo;
- reviews:
  - first adversarial review: NOT READY (B1, B2, S1–S7, nits); fixed in
    revision 2;
  - second review (`05a2dd2`): no blocker; S1–S3 and nits fixed in
    revision 4 (table below);
- not proposed for a device. That needs FS-A-007, the Chair, then the PM's
  live sign-off.

**What it serves:** two separate future experiments that share one PID 1
toolkit:
- **stage 2a:** the four pinned Valve files (`../stage2a/T1-PINS.md`);
- **stage 3a:** the `fs-pattern` display test (`../stage3a/README.md`).

**Rulings it answers:**
- FS-R-006 §5 B (FSB1);
- §5 C (bounded supervision);
- §5 D (deadline);
- §5 F (outcome classes);
- §6 (misc rule);
- and the launch half of §5 A.

**Tags:** [M] hardware output · [M-static] artifact · [D] derivation ·
[C] hypothesis · [O] open.
- Source files and built binaries are [M-static] (named artifacts).
- Fixture runs (qemu-user, native WSL) are **fixtures**, cited as [D]
  evidence about user-space behaviour under the WSL kernel. They are not
  [M] and not observations of the Quest kernel (fix round 6).

## Files

| path | what |
|---|---|
| `src/fs-supervise.c` | one-child supervisor (C; built static aarch64 for the device) |
| `tools/build.sh` | WSL build: clang r450784e, static, ELF checks, bit-identical rebuild, limit check → `build/fs-supervise`, `build/BUILD.txt` |
| `tools/fixtures-supervise.sh` | 51 fixtures, the aarch64 binary under qemu → `fixtures/supervise/` |
| `tools/fixtures-supervise-native.sh`, `tools/testprogs/` | 19 fixtures, the same source built natively with gcc (timing, descriptors, sessions, signals, descendants) → `fixtures/supervise-native/` |
| `FSB1-SPEC.md` | record framing v1 (normative decoder procedure) |
| `target/fsb1-enc.sh` | encoder for busybox ash |
| `target/fsb1-pace.sh` | paced emitter (stage 3b only; the same bytes as `fsb1_emit`, 10 lines per 0.1 s by default, stage 3b sets 20; refuses records over MAXLINES; FSB1-SPEC.md §9) |
| `tools/fsb1.py`, `host/fsb1.ps1` | independent decoders: Python reference, and PowerShell 5.1 for the collector |
| `tools/fixtures-fsb1.sh`, `tools/fsb1_mutate.py`, `tools/test_fsb1.py`, `host/test-fsb1.ps1` | FSB1 fixtures → `fixtures/fsb1/` |
| `DEADLINE.md`, `target/pid1-hold.sh`, `target/fs-done` | PID 1 deadline and early recovery |
| `src/fs-reboot-final.c` | PID-1-safe reboot helper that PID 1 `exec`s: RESTART2 "bootloader", then RESTART, then sleeps for ever. Never exits |
| `tools/fixtures-deadline.sh` | deadline harness (only the reboot syscall faked; reviewed busybox under qemu) → `fixtures/deadline/` |
| `OUTCOMES.md` | PASS / compatibility FAIL / INTEGRITY FAULT / INCONCLUSIVE: per-step classes and exhaustive precedence |
| `MISC-RULE.md`, `tools/misc_rule.py`, `tools/test_misc_rule.py` | misc before/after rule → `fixtures/misc/` |

## How the pieces fit (one stage-2a attempt)

1. **PID 1** (a stage-2a `init.sh`):
   - `fs_hold_init`, then `fs_start_backstop` (both logged when armed);
   - modules, USB, gadget, helpers, shell;
   - `fs_hold_loop`: fork-free and FIFO-safe; HOST_ACK is only recorded;
     PID 1's own reboots `exec` `fs-reboot-final` (no fork); the backstop
     child fork-execs `fs-reboot`.
2. **Host:** `fs-verify`, `fs-ack`, then **one** request:
   `fs-valve <challenge>`.
3. **Step runner** (`fs-valve`; open):
   - `fsb1_begin`;
   - per step, `fsb1_run`: fs-supervise (empty environment, new session,
     deadline, TERM→KILL, capped capture), then encode;
   - `fsb1_end`, `fsb1_emit`.
4. **Host:** `Test-Fsb1Record`, then OUTCOMES §6, then `fs-done` at once.
   PID 1 reboots within ~1 s. Otherwise the deadline does it.
5. **After the return to Android:** `misc_rule.py` (MISC-RULE), with the
   other before/after checks.

## Build

```
wsl.exe -e bash <repo>/devices/quest3/common/tools/build.sh
```

| | |
|---|---|
| compiler | Android clang 14.0.7 (r450784e), `--target=aarch64-linux-gnu -static -O2`, lld, `--build-id=none -s`; static glibc 2.43 |
| source | `src/fs-supervise.c` SHA-256 `cc1ba7bbe48a9d73356a3a450b72cfa82a55fc39ff248677a5cf798c1ceda910` |
| binary | `build/fs-supervise` SHA-256 `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74`, 676,952 B (`build/` is gitignored; this hash is the record) |
| checks | aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild, compiled limits unchanged |
| fs-reboot-final | source `cd657ae3762fc06692ebe1f38e114e10937fe844da5e18538cb09c14d9be9d8e`; binary `build/fs-reboot-final` `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` (808 B, freestanding). The build checks from the disassembly: exactly 3 syscalls = reboot, reboot, nanosleep (looped); no exit; only mode string "bootloader"; bit-identical rebuild |
| revision 1 (reviewed) | source `49df8e34…a268bea`, binary `84ff3ba7…22853a` |

## Fixture runs (revision 3)

| suite | command (WSL unless noted) | result |
|---|---|---|
| fs-supervise, aarch64 under qemu | `bash …/tools/fixtures-supervise.sh` | **51/51** |
| fs-supervise, native gcc build | `bash …/tools/fixtures-supervise-native.sh` | **19/19** |
| revision-1 "before" results | `fixtures/review1-before/` | supervise-native 5/19, deadline 16/21 |
| FSB1, Python | `bash …/tools/fixtures-fsb1.sh` | **38/38** (round 5; before, encoder rev 4 with `ENC=`: 37/38) |
| FSB1, PowerShell (Windows) | `powershell.exe -NoProfile -File devices\quest3\common\host\test-fsb1.ps1` | **38/38**, agrees with Python 38/38 |
| deadline | `bash …/tools/fixtures-deadline.sh` | **31/31** (incl. exec checks, the real `fs-reboot-final` under qemu with its syscall arguments, frozen and octal clocks) |
| misc rule (Windows or WSL) | `python -I devices/quest3/common/tools/test_misc_rule.py` | **26/26** (18 classification + 8 CLI/exit-code) |
| revision-3 "before" results | `fixtures/review2-before/` | deadline 27/31 (frozen-clock, octal-clock, static-clamp, static-pid1-exec FAIL); misc CLI: a missing capture gave exit 1 = EXPECTED |

**Output directory.** By default every harness writes into its tracked
`fixtures/` directory. To run without touching tracked files:

| harness | option |
|---|---|
| `fixtures-supervise.sh`, `fixtures-supervise-native.sh`, `fixtures-fsb1.sh`, `fixtures-deadline.sh` | `OUT=<dir>` |
| `test_misc_rule.py` | `OUT=<dir>` (environment) |
| `test-fsb1.ps1` | `-FixDir <dir>` (reads cases from, and writes results to, that dir; point it at an `OUT` of `fixtures-fsb1.sh`) |

## Second review fixes (revision 4), with before/after

| finding | fix | fixture (05a2dd2 → rev 4) |
|---|---|---|
| **S1a** the clock is a replaceable file (frozen bind mount) | Withdrew "no file PID 1 reads can move it". Added a loop-iteration counter as a second, file-independent clock (`deadline-ticks`); the backstop's kernel-timer sleep is the third. The clock is read only if `[ -f ]` | `frozen-clock` (clock frozen, ack, backstop killed): **no reboot at all** → `deadline-ticks` |
| **S1b** leading zero → ash arithmetic error → PID 1 exits | `_fs_num`: only `0` or `[1-9][0-9]{0,8}` reaches `$(( ))`/tests, else the fail-safe fallback; all operands audited (DEADLINE §2.8) | `octal-clock`: **shell exited** → `deadline` (fail-safe); `static-clamp` with `"08 04"`, `"1234567890 5"`, `"010 009"`: **shell died** → PASS. `huge-clock` (20 digits) passes on both (guard) |
| S1 `set +eu` | in `fs_hold_init` and `fs_hold_loop` | `set-eu` (preventive; passes on both) |
| **S2** misc: an unreadable capture read as EXPECTED | every exception → INCONCLUSIVE; verdict exit codes 10–14 (never 0/1/2) | CLI: missing before or after, a directory, short, usage, codes disjoint. 05a2dd2: a missing capture → traceback, exit 1 = EXPECTED |
| **S3** an outside SIGKILL/TERM/INT/HUP classed as compatibility FAIL | OUTCOMES §3: TOOL FAULT when the timer had not fired | spec |
| nit: precedence | a *measured* integrity mismatch ranks first, even if the other integrity step failed | spec |
| nit: final liveness check | `waitpid` loop until ≤ 0 | by inspection (not deterministic to provoke) |
| nit: a child can SIGSTOP the supervisor | documented (`fs-supervise.c` header; only the PID 1 deadline bounds it) | doc |
| nit: check-then-open race on reads | listed with the append race (DEADLINE §2.4) | doc |
| nit: fs-reboot-final arguments | `tools/check_final.py` (in `build.sh`) simulates the code. The qemu `-strace` fixture matches magics, commands, the `"bootloader\0"` pointer and `&{3600,0}` | `fs-reboot-final-never-exits` |
| nit: FSB1-SPEC status; `absent` in `valid-t1` | updated; `valid-t1` now has 7 steps (OUTCOMES §2) | `valid-t1` VALID |
| harnesses wrote into tracked dirs | `OUT=` / `-FixDir` everywhere (above) | — |
| (found while re-running) FSB1 fixture timing under host load (load average 15) | generous step timeouts in the framing fixture; check failures now print instead of exiting silently | `fixtures-fsb1.sh` 36/36 |

## Review fixes (first adversarial review), with before/after

## Review fixes (first adversarial review), with before/after

**Method.** "Before" is the reviewed revision 1 (commit `e890a7a`), run
through the **new** fixtures:
- **supervise:** `SRC=<rev1 source> OUT=… fixtures-supervise-native.sh`.
  Result: rev 1 5/19, rev 2 19/19.
- **deadline:** `HOLD=<rev1 pid1-hold.sh> OUT=… fixtures-deadline.sh`.
  Result: rev 1 16/21, rev 2 22/22.

| finding | fix | fixture (rev 1 → rev 2) |
|---|---|---|
| **B1** one FIFO stops both timers | `fs_reboot`: the reboot helper is the **first** command; no /run or /dev access before the syscall on either path; reasons logged when armed. Loop reads only after `[ -f ]` via `read -t 1 <>` (never blocks on a FIFO); appends only to regular or new files | `fifo-logs` FAIL (no reboot at all) → PASS; `fifo-stalled` FAIL (no reboot at all) → PASS; `fifo-collected` FAIL → PASS; `static-reboot-first` FAIL → PASS |
| **B2** fast writers starve the deadline | bounded read bursts (64 KiB / 10 ms per stream); clock checked between bursts; KILL scheduled from when TERM was actually sent, give-up from when KILL was | native `flood1` FAIL (TERM at 1868 ms) → PASS (~1000); `flood4` FAIL (`unreaped`, TERM/KILL at 14815 ms) → PASS; `flood4ign` FAIL (KILL 0 ms after TERM) → PASS (gap 1001 ms) |
| **S1** inherited fds | exec-error pipe moved to fd 3 (CLOEXEC), `close_range(4,…)`, loop fallback | `fdleak` FAIL → PASS (child fds exactly 0 1 2) |
| **S2** caller's session/tty | `setsid()` in the child | `session` (run inside a pty) FAIL (`sid≠pid`, tty 34819) → PASS (`sid=pid`, tty 0) |
| **S3** inherited SIG_IGN | SIGCHLD and SIGALRM reset to default and unblocked at start | `sigchld-ignored` FAIL → PASS; `sigalrm-ignored` FAIL → PASS |
| **S4** surviving descendants unreported | exact /proc-free liveness check (`waitpid(-1,WNOHANG)==0`) → `why=strays-alive`, or `why=no-proc` when /proc is unusable, exit 7. Session hunt plus atomic whole-group kills of every found group | `noproc` FAIL (`strays=0 why=none`) → PASS (`why=no-proc`, exit 7). `hopper` passed in this rev-1 run (the review saw survivors); in a rev-2 run before the group kill it survived and was reported `strays-alive`; with group kill: PASS ×3 |
| **S5** fork failure kills PID 1 | fork-free loop: clock via `read`; pause via `read -t 1` on a private FIFO; `sleep` only as a fallback; no `rm`/`cut`/`$(…)` in the loop. Residual risk documented (DEADLINE §2.5) | `fork-free-loop` FAIL (4 children in 3 s) → PASS (1, the backstop) |
| **S6** OUTCOMES misclassifications | per-step classes: TOOL FAULT (any `why≠none`, tool `end`s, exec-failed with errno other than ENOEXEC/ELIBBAD) ranked before FAIL; missing pinned file is INTEGRITY FAULT; exact `hash` and `absent` parses; catch-all INCONCLUSIVE | specification (no classifier yet; open item 4). The `sha256sum` error format was checked under qemu |
| **S7** false stage-1 claim | DEADLINE §1 corrected: ash evaluates `$(( - T0 ))`; the shell survives; `fail()` and the ack window silently never fire; the dead-man covers them | doc |
| nit: duplicate `-g/-c/-i` | refused | `dup-option-g/c/i` FAIL → PASS |
| nit: `alarm(0)` before the report | moved after the write | by inspection |
| nit: bionic/musl env names | `SCUDO_OPTIONS`, `LIBC_DEBUG_MALLOC_OPTIONS`, `LIBC_DEBUG_MALLOC_ENABLE`, `LIBC_HOOKS_ENABLE`, `MUSL_LOCPATH` refused | `env-SCUDO_OPTIONS`, `env-LIBC_DEBUG_MALLOC_OPTIONS`, `env-MUSL_LOCPATH` FAIL → PASS |
| nit: `fs-done` says "queued" on failure | `queued` only after a successful write+mv, else `error=write`, exit 1 | `fs-done-honest` PASS (rev 1 printed `queued` unconditionally) |
| nit: escape fixture | asserts setsid succeeded (escapee pid = sid) | qemu `escape` PASS; native `escape` (`setsid=ok`) PASS |
| nit: flood fixture | 4 concurrent writers on both streams (qemu); the native suite adds the timing floods | qemu `flood` PASS |
| nit: MISC V range | documented as widened from the 5 changed bytes to the 3 whole words | doc |
| nit: README overclaims | reworded (below) | doc |

## Design decisions

**fs-supervise instead of busybox `timeout`.**
- Busybox 1.37 `timeout -k` signals only the program's PID. It does not
  report how the program ended, and it controls neither the environment
  nor the output.
- Under qemu, `timeout -k 1 1 sh -c 'sleep 37 & exec sleep 38'` returned
  143 and left `sleep 37` running.

**fs-supervise.**
- It reports exactly one of: exited N / signaled S / timer-term /
  timer-kill / exec-failed / unreaped.
- Its limits are compiled in: timeout ≤ 60 s, grace ≤ 10 s, cap ≤ 1 MiB,
  and a 90 s self-alarm.

**The child.**
- New session: no controlling tty, its own group.
- Empty environment.
- Fds 0–2 only.
- Default signal dispositions.

**Descendants.**
- The child's group gets TERM, then KILL.
- After the child is reaped, the descendants that can be found are killed:
  its group, processes reparented to fs-supervise (as subreaper), its
  session, and the whole process groups of anything found.
- **Whether any descendant is still alive afterwards is known exactly**,
  without /proc, and reported (`why=strays-alive` / `no-proc`, exit 7). It
  is never claimed that every descendant was killed: a descendant that
  leaves every hunted group and session before the hunt can survive, and
  is then reported.

**Capture.**
- Through pipes into fresh `O_EXCL|O_NOFOLLOW` files, with a cap.
- The pipes are drained in bounded bursts, so the deadline keeps time
  under any write rate (native floods).
- A child that keeps writing is ended by the deadline. If a descendant
  outside fs-supervise's reach still holds a pipe, the drain stops after
  1 s and reports `pipes=open`.

**FSB1.**
- Payloads are base64. The tty can then change only line terminators, and
  the decoder strips trailing CRs. CRLF-mangled records **validate** by
  design. A CR elsewhere, or any altered character, is rejected.
- Hashes are over the exact captured bytes.

**One record, one request.** Two BEGINs, stray FSB1 text, duplicate or
reordered steps, or a wrong nonce or challenge: rejected, never resolved.

**Deadline.**
- It lives in PID 1's own loop. There is a backstop child, and HOST_ACK is
  only recorded.
- Host input can only shorten the hold.
- **Neither timer touches a file before the reboot syscall.**
- One FIFO can no longer silence both timers. The loop itself can still
  be stalled by a FIFO swapped in during the microseconds of a guarded
  append; the backstop then reboots (DEADLINE §2.4).

**misc rule.**
- C accepts only `E0→E0`, `E1→E1`, `E0→E1`.
- V changes are RECORDED as "presumed reboot-related".
- Everything else is STOP.
- A missing or short capture is INCONCLUSIVE.

## Not done (open)

**Round 5:**
- Items 1-4 are **done**: `host/` revision 3 (collector, E1, the stage-2a and stage-3a classifier) and the stage-2a/3a images (`../stage2a/IMAGE.md`, `../stage3a/IMAGE.md`).
- Item 5 is **decided**: no software watchdog (J-49).
- They are kept below for the record.

1. **Host collector redesign** (FS-R-005 §5 D1; FS-A-006 §5.5 item 1):
   - one command at a time with a target-emitted completion marker;
   - echo distinguished from completion;
   - continuation and partial-output detection;
   - stop on missing completion;
   - fixtures.

   `Test-Fsb1Record` is a component it will call, not the collector.
2. **E1 git checks** in the builder (`--git-dir`/`--work-tree`,
   `GIT_DIR`/`GIT_WORK_TREE` unset, a `core.worktree` regression
   negative).
3. **The stage-2a `fs-valve` runner and init.**
   - The runner implements OUTCOMES §2.
   - The init sources `pid1-hold.sh` and routes every post-shell timer
     reboot through `fs_reboot_pid1` (PID 1) or `fs_reboot` (backstop).
   - The builder copies `fs-supervise`, `fs-reboot-final`, `fsb1-enc.sh`,
     `pid1-hold.sh` and `fs-done` hash-enforced, and requires
     `base64 awk wc head mkfifo`.
   - The same for stage 3a.
4. **A host outcome classifier** for OUTCOMES §3–§6 (PS 5.1) with
   fixtures, and a PS port of the misc rule.
5. **The software-watchdog decision** (FS-R-006 §5 E).
6. **Untested fs-supervise paths:**
   - `end=unreaped` (a D-state child);
   - `why=capture-write-failed` (tmpfs full);
   - everything on the real Quest kernel with a real busybox PID 1.
7. **Residual risks** (DEADLINE §2.4–2.5, §2.8–2.9):
   - the check-then-open race for appends and reads (`host_ack`, tick
     FIFO, clock file);
   - a forged clock file delays the primary clock. The iteration counter
     (at worst about 3 × DEADLINE) and the backstop's kernel timer remain,
     but a host that also kills the backstop leaves only the counter;
   - a child can SIGSTOP fs-supervise; only the PID 1 deadline bounds
     that;
   - the `sleep` fallback fork (only if the tick FIFO is gone);
   - the fork fallback if `fs-reboot-final` is not an executable file;
   - an exec failing despite the check;
   - RLIMIT_NPROC cannot bound root children.

   The reboot itself no longer forks (revision 3).
8. **Re-review** of revision 4.
