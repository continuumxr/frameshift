# Step-4 `--list` rule, option B: NOT ADOPTED (FS-R-009 §4)

**Status: rejected alternative. Kept for the record only. Do not apply.**
The Chair adopted amended rule A instead (`LISTING-RULE-A.md`, FS-R-009 §4).
`LISTING-RULE-B.patch` has never been applied to any file on any branch.

## Idea

Run step 4 with `LD_TRACE_LOADED_OBJECTS=1`. ld.so then writes
`mode_trace_program` false (glibc 2.39 `rtld.c:2714-2718`), so the unnamed
main-map line is never printed, and the registered three-line rule (v1)
would hold. Offline evidence: qemu `cortex-a72`, 15/15 runs for `b2sum` and
15/15 for `uname` gave exactly 3 lines with `=1`
(FS-A-009 (private review record)).
`LD_TRACE_LOADED_OBJECTS=2` prints the line every time.

## Patch (`LISTING-RULE-B.patch`, `git apply --check` clean on `d4c0bb7`; not compiled or run)

1. `common/src/fs-supervise.c`: one whole-string exception,
   `allowed_kv[] = { "LD_TRACE_LOADED_OBJECTS=1" }`, checked before the
   `LD_` prefix refusal. `=2`, `=1x` and every other `LD_*` stay refused;
   the syntax and duplicate checks still apply.
2. `common/target/fsb1-enc.sh`: `fsb1_run` accepts one `-e KEY=VAL`, passed
   to fs-supervise.
3. `stage2a/fs-valve.sh`: step 4 runs with `-e LD_TRACE_LOADED_OBJECTS=1`.

## Why it costs more than A (review and rebuild implications)

- **Departs from the empty-environment rule** (FS-R-006 §5 A). The supervisor
  guarantee in the fs-supervise header would carry an exception.
  - The exception is global: any caller of fs-supervise could pass the
    variable to any step.
  - With it, every dynamic program started through ld.so becomes a listing,
    so a misplaced `-e` would silently change what a step measures.
- **Supervisor change**: a new fs-supervise binary, its native fixtures
  (`tools/fixtures-supervise*.sh`) extended with the new acceptance and the
  `=2`/`=1x` refusals, a rebuilt `common/build-record`, and a re-review of
  fs-supervise (it is shared PID-1 infrastructure, also used by stage 3a).
- **Encoder change**: `fsb1-enc.sh` revision bump, plus its fixtures
  (`tools/fixtures-fsb1.sh`).
- **Image change**:
  - a rebuilt stage-2a image with a **fresh nonce**, a new MANIFEST and image
    hash;
  - the new `fs-valve.sh` hash;
  - the harness (`test-image.sh`) and `test-host.ps1` re-run;
  - IMAGE.md tables updated, adversarial review, a new sign-off.
  - The stage-3a image is affected too if fs-supervise is shared.
- **Untested on the device**: the evidence for `=1` comes from qemu only. On
  the Quest 3 the `--list` and environment paths of Valve's ld.so would run
  for the first time in a counted attempt.

Rule A needs none of this: it changes only the host classifier, and the next
run needs only the rebuild with a fresh nonce that any re-run requires.
