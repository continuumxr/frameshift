# Quest 3 stage 3a: `fs-pattern` (one static test image on the panels)

> **Status update (2026-10-10):** the status line below is historical. Stage 3a
> was proposed in FS-A-007, concurred in FS-R-008, and **run as trial (iii)** on
> 2026-10-10 (nonce `17449af173f0633a`). The registered outcome is
> INCONCLUSIVE, and no light was seen (FS-A-010, FS-R-010, J-73). The image is
> **spent**. Its successor is `../stage3b/` (trial (iii-b)). See also the
> backlight correction in the JOURNAL Corrections table.

**Status: v0.4, built and fixture-tested offline only. NOT proposed for a
device.** Running it on a headset needs Chair review in FS-A-007 (FS-R-006
authorises no hardware action) and the PM's live sign-off (PROJECT_SETUP
§6A.7).

History (all reviewed versions kept in `build/prev/` with their sources):
- **v0.1** (`175cece4…`): first adversarial review found one blocker (a
  stalled stdout could keep the image up to the 150 s backstop with
  SIGTERM ineffective) and five should-fix items.
- **v0.2** fixed them.
- **v0.3** (`2c72c297…`): hold maximum lowered to 45 s. Second review: no
  blocker, two should-fix items and four nits.
- **v0.4** fixes those, and lowers the hold maximum to **10 s** (PM
  decision).

Each fix has a check that fails on the version before and passes after
("Before/after"). v0.4 has not yet been re-reviewed.

Builds on `docs/research/display-bringup-quest3.md` (J-41). Stage 3 runs in
parallel with stage 2 (J-40); the display-before-headless ordering is
itself an ask for FS-A-007.

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C]
hypothesis · [O] open.

## Files

| path | what |
|---|---|
| `src/fs-pattern.c` | the program (one file, no libdrm; kernel uapi `drm.h`/`drm_mode.h` from the v2.7 source). With `-DFSP_UNIT_TEST`, `main()` is replaced by unit tests (and a `stream` sample mode for the validator) |
| `tools/build.sh` | WSL build: the tool (static-ELF checks, bit-identical rebuild) and the unit-test binary; writes `build/BUILD.txt` |
| `tools/fixtures.sh` | all offline fixtures under `qemu-aarch64`; writes `fixtures/*.txt` and `fixtures/RESULTS.txt` |
| `tools/check_stream.py` | validator for FSP1 streams: grammar, `len`, `crc`, `seq`, `eos` |
| `tools/check_render.py` | independent checker of a render: decodes the nonce from the pixels, checks levels and marks; writes the PNG previews |
| `tools/regress.sh` | before/after regression (R1–R12) |
| `tools/policy_harness.c` | the same mode-policy and empty-value requirement checks compiled against the v0.3 or v0.4 source (R8) |
| `build/fs-pattern`, `build/BUILD.txt` | the binary and its build record |
| `build/fs-pattern-unittest` | unit-test build (offline only, never in an image) |
| `build/prev/` | reviewed v0.1 and v0.3 binaries and sources (v0.3 validator too) |
| `fixtures/` | fixture outputs, previews, `regress-v0.{1,3,4}.txt`; `fixtures/input/emptyval-v0.3.txt` is the second reviewer's repro |

## Invocation and contract

```
fs-pattern show     NONCE HOLD_S [DEVICE] > /run/<file>   # DEVICE defaults to /dev/dri/card0
fs-pattern render   NONCE W H OUT.ppm                      # offline: same drawing code; no DRM
fs-pattern holdtest NONCE HOLD_S MOCKPATH                  # offline: same hold code; no DRM
```

- `NONCE`: exactly 8 lowercase hex characters, fresh from the host per
  attempt; shown on the panels in upper case.
- `HOLD_S`: decimal, 1 to 6 digits, at least 1; clamped to the compiled
  maximum of **10 s** (reported as `clamped=1`). The build fails if the
  constant is set above 10. Reading 8 characters needs well under 10 s,
  and no fan is driven in this image.
- Path arguments: 1 to 200 bytes, else usage error (no silent cut).
- **stdout must be a regular file (tmpfs), a pipe/FIFO, or `/dev/null`.**
  Anything else (a tty, the USB serial gadget, a socket) is refused with
  exit 3 and nothing is written.
  - A pipe/FIFO is switched to `O_NONBLOCK`: a record that does not fit is
    dropped and counted, never waited for.
  - Records are shorter than `PIPE_BUF`, so a pipe write is all-or-nothing
    (no torn records).
  - SIGPIPE and SIGXFSZ are ignored, so a closed reader or a file-size
    limit makes `write()` fail (EPIPE/EFBIG) and the record is counted as
    dropped.
  - So no `write()` can block or kill the process, before or after the
    commit.
- **PID 1 contract** (aligned with `devices/quest3/common/FSB1-SPEC.md`):
  - Run it as one step under `fs-supervise`, with `-t` at least HOLD_S +
    5 + 1 (the image-time bound plus margin; 16 s for the 10 s maximum,
    well inside the supervisor's 60 s cap). `fs-supervise` captures stdout
    through a drained pipe into a RAM file, gives the child an empty
    environment and stdin `/dev/null`, and resets signal dispositions.
  - The FSB1 encoder then carries that capture as the step's base64 `DATA`
    payload, with `out_len` and `out_sha256` over the exact bytes. It is
    emitted to the USB channel only after the child has been reaped.
    Newline translation on the tty is FSB1's concern; FSP1 records never
    cross the tty raw.
  - FSP1 stays this program's local log format. The host decodes the FSB1
    payload, then validates the FSP1 stream inside it with the
    `check_stream.py` rules.
  - Suggestion for FS-A-007: take the 8-hex display nonce from the first
    8 characters of the FSB1 challenge (`chal`), so the decoder can check
    that every FSP1 record's `nonce=` equals `chal[0:8]`.

## Sequence (`show`)

1. stdout check (above). Block SIGTERM/SIGINT/SIGHUP (reset to default
   first, so an inherited "ignore" cannot swallow them); ignore SIGPIPE
   and SIGXFSZ; unblock SIGALRM; `alarm(30)` as the backstop for
   everything before the real commit.
2. **`stat(DEVICE)` first.** Only a character device with major 226 is
   ever opened (exit 10 if absent, 11 otherwise). Then `open(O_RDWR |
   O_NOCTTY | O_CLOEXEC)`. `fstat` must show the same `st_rdev` as the
   `stat`, else the fd is closed and the program exits 11 (`node_changed`).
3. `DRM_IOCTL_VERSION`: the driver must be `msm_drm`, else exit 12.
4. `SET_CLIENT_CAP` ATOMIC (and UNIVERSAL_PLANES). ATOMIC refused → exit
   21. There is no legacy `SETCRTC` path.
5. `GETRESOURCES`; `GETCONNECTOR` for every connector (all reported);
   choose the first connected one, preferring DSI. Every mode is reported
   in full ([O6]). Encoder → CRTC.
6. `GETCRTC` and the CRTC `ACTIVE` property, logged as `crtc_state`
   (`mode_valid`, `active_prop`, `active`, `in_list`, `interlaced`,
   `expected`).
7. **Mode policy:**
   - The current mode is used only if the CRTC is **ACTIVE=1**, the mode
     is **in the connector's list** and it is **progressive**. That case is
     a plane swap on the timing already being scanned out.
   - Otherwise: exactly **4128 × 2208 @ 90 Hz, progressive**, from the
     list.
   - Otherwise exit 30.
8. Planes: primary = type PRIMARY, drives our CRTC, XRGB8888, not attached
   to another CRTC; helper = another such non-cursor plane (used only for
   the split layout). Any required property missing → exit 21.
9. One XRGB8888 dumb buffer of the mode size; map, draw once, unmap;
   `ADDFB2`; mode blob.
10. **Plan (logged as `plan`) and TEST_ONLY attempts:**
    - **No-modeset plane swaps** (single, then split) only when the
      current mode was chosen (so the CRTC is ACTIVE).
    - **`ALLOW_MODESET` attempts** (single, then split; connector
      `CRTC_ID`, CRTC `MODE_ID` + `ACTIVE=1`) only when the mode is exactly
      the expected one.
    - So a current mode that is not 4128×2208@90 gets plane swaps only,
      and is never modeset.
    - Other planes on our CRTC are turned off in the same request. The
      request builder refuses rather than truncates (exit 21).
    - All attempts rejected, or none allowed: exit 50, **no real commit.**
11. Real commit: the accepted request, `ALLOW_MODESET` only if that
    attempt carried it; blocking; **one ioctl attempt, no retry.**
    Immediately before it: `alarm(HOLD_S + 5)`, and `commit_t0` is read
    from CLOCK_MONOTONIC.
12. Hold until `commit_t0 + HOLD_S`: an absolute deadline computed once.
    `sigtimedwait` waits on the blocked stop signals and the deadline is
    re-checked on every wake-up. A stop signal ends the hold early.
13. **`close(fd)` as soon as the wait ends**, before any further `write()`
    (shown by syscall order under `qemu -strace`). Then `hold_end`, `exit`,
    `eos`, `_exit`.

A pending stop signal between steps ends the run before the next device
action (`step=signal at=…`, exit 70).

### What it does not do

- No sysfs, debugfs, backlight, brightness or BLU access; no DCS. In
  `show` the only path opened is DEVICE, and only after `stat` shows a DRM
  node. The backlight stays at the boot level (changes blocked by the
  driver, research §1). **Correction (J-75): wrong for v66.** v66 has no
  changes-blocked gate and reprograms the BLU at 1000/1000 (≈ 8.2 % duty)
  on our full-modeset commit [D, near-match source]
  (`docs/research/display-handoff-dark.md` §3).
- No animation, no page flips, no second commit, no blank/unblank
  toggling, no legacy modeset.
- No regulator, GPIO, clock, fan or governor changes.

## How long the image can stay up (honest bound)

Measured from the start of the real commit ioctl:

- **Normally: HOLD_S (≤ 10 s)**, then the time `close()` takes in the
  kernel.
- **If anything in our process stalls after the commit:** SIGALRM at
  **HOLD_S + 5 s (≤ 15 s)** terminates it, and the kernel runs the same
  release path on exit. stdout cannot be the stall, and stop signals stay
  effective throughout the hold.
- **The release path itself** is not bounded by us. In v2.7 its designed
  waits are `LASTCLOSE_TIMEOUT_MS` = 500 ms each (`msm_drv.c:79`): one in
  preclose (`:1624`) and up to three in lastclose (`:1114`, `:1158`,
  `:1177`), plus the commits themselves [M-static]. A signal cannot
  interrupt an uninterruptible kernel wait.
- **Not bounded by any userspace layer:** a kernel hang inside the commit
  or the release path. That falls to PID 1's dead-man and the PM's manual
  recovery.

So **the client's own** time is at most about 15 s plus the kernel
release-path duration, provided the kernel returns. That is **not** a
bound on physical panel exposure: whether closing turns the panels or
backlight off on v66 is [O] (the v2.7 source suggests it does [D]). If
release leaves the frame displayed, it may remain until recovery; T0 +
170/171 s are intended reboot timings, not guaranteed panel-off times
(FS-R-007 §4).
- If the close does not turn them off, our last frame (this pattern) may
  stay displayed until recovery (the PID 1 reboot is intended at T0 + 170
  s, backstop 171 s; not guaranteed; `IMAGE.md` §4).
- The PM's dark check before `fs-done` is the control for this. Recover as soon as the PM has read
the code. PID 1 supervision with KILL escalation stays a separate required
layer (FS-R-006 §5C/D); its deadline must not depend on HOST_ACK or
collection.

The 15 s figure assumes the device stays awake. CLOCK_MONOTONIC and
`alarm()` both stop counting during system suspend, so a suspend would
stretch it.
- **Bounded claim:** our init and helpers never request suspend: no write
  to `/sys/power/state`, and no suspend daemon is in the image
  [M-static, the ramdisk list].
- Whether a vendor module or driver could suspend autonomously is not
  established [O].
- If it did, nothing runs while the device is suspended. The PID 1 loop's
  clock (`/proc/uptime`, boot time) keeps counting, so the loop would reboot
  on resume. The backstop's `sleep` (monotonic) would be delayed.
- The PM's manual route is the remaining bound
  (`devices/quest3/RECOVERY.md`).

## What closing does (v2.7 source [D]; v66 behaviour [O], see [O7])

**After our commit succeeded** (we are DRM master, the first opener):
1. `msm_release` → preclose (`msm_drv.c:1622-1629`) →
   `_sde_kms_remove_fbs` (`sde_kms.c:2577-2660`): our FB is still on a
   plane (refcount > 1), so it is force-removed from the planes with a null
   commit.
2. `drm_release` → `drm_lastclose` (`drm_file.c:497`) → `msm_lastclose`
   (`msm_drv.c:1095`). Splash handoff is over.
   - There is no fbdev: `CONFIG_DRM_FBDEV_EMULATION` is unset in the v2.7
     stock config (`~/work/kgate27/stock.config:3773`) and in the v66
     config stage 1 ran
     (`firmware/quest3/extracted/v66_unit1_slotA/kernel.config:3792`).
     So `priv->fbdev` is NULL and the kms_client branch is taken
     (`msm_drv.c:1165-1170`). With fbdev emulation enabled, the fbdev
     restore at `:1165-1167` would run instead, and the result could
     differ.
   - That client never probes (no `drm_client_modeset_probe` in the
     techpack), so its modesets carry no mode, and
     `__drm_atomic_helper_set_config` disables the CRTC: **panels off.**
3. `sde_kms_lastclose` resets custom properties (`msm_drv.c:1182-1183`,
   `sde_kms.c:2781`).
4. Consequence: a second run in the same boot finds ACTIVE=0, so it takes
   the expected-mode modeset path.

**If no commit of ours happened** (exits 12–50, DRM opened):
- Preclose finds no FB on a plane ("skip commit as no fb(s)").
- In lastclose the splash check (`msm_drv.c:1112`) is still true, and
  `sde_kms_trigger_null_flush` returns -EINVAL when every DSI display is
  still in splash (`sde_kms.c:3858`), so lastclose returns early.
- **The panels stay as ABL left them.**

**Exits 2, 3 and 10 never open anything.** Exit 11 never opens a
non-DRM path, because `stat` runs first. The one exception is a node
swapped between `stat` and `open`: the `fstat` comparison detects it and
closes the fd at once (`node_changed`). `holdtest` refuses a DRM node at
the `stat`, without opening it.

Closing is the intended, bounded end of the test. That supersedes "never
close the fd" in research §2.3 step 6; the replacement wording has been
given to the PM.

## The image

Per buffer half (2064 × 2208 for the expected mode), drawn in "viewer"
coordinates and rotated 180° inside each half, because the panel node
says orientation 180 (`eureka-panel-sharp.dtsi:34`) [D]. The image is
unchanged since v0.1 (identical render bytes, sha256 `ed8e82df…94dab3`
for `3f9c07ab`):

- background grey 0x10;
- border 0x60 (8 px, inset 24 px);
- an orientation square 0x60 at the viewer's **top-left**;
- a centre cross 0x70 (arms ±184 px);
- the nonce as 8 block digits (5×7 cells of 21 px: 105 × 147 px per
  digit), grey 0x90, above the cross, **underlined**. Zero is slashed;
  A–F are upper case;
- **link bars** below the cross: 1 bar in the buffer's left half (DSI 0),
  2 in the right half (DSI 1).

Only levels 0x10/0x60/0x70/0x90 are used; nothing is above 0x90. 3.6 % of
pixels are lit; the mean level is 19.6/255.

The PM reports, per eye:
- the 8 characters;
- whether the underline is below the digits and the square at top-left
  (if not, the orientation is not 180° as derived);
- the number of bars (this maps eye ↔ DSI link).

If the image appears upside down, read it with the underline as the
baseline.

Previews (sample nonce `3f9c07ab`):
- `fixtures/preview-3f9c07ab-viewer.png`: what each eye should see, 1/4
  scale;
- `fixtures/preview-3f9c07ab-scanout.png`: the buffer as scanned out, 1/4;
- `fixtures/preview-3f9c07ab-digits.png`: the left-eye digits at 1:1;
- every glyph: `fixtures/preview-01234567-digits.png` and
  `preview-89abcdef-digits.png`.

## Output (FSP1, local log format)

One record per line, each written with a single `write()`, terminated by
`\n` only:

```
FSP1 nonce=<8 hex|none> seq=<n> step=<id> rc=<int> [<key>=<value> ...] len=<n> crc=<8 hex> END
```

- `len` is the number of bytes before ` len=`. `crc` is the CRC-32 (IEEE
  802.3, as zlib `crc32`) of those bytes, as 8 lowercase hex digits.
- `seq` counts from 0 without gaps. `rc` is 0 or the negative errno.
- Keys are `[a-z0-9_]+`. Values are `[A-Za-z0-9_./%-]+`, **never empty**.
  - Outside strings (paths, driver and mode names) are percent-encoded
    (`%XX`).
  - **An empty string is written as `-`, and a literal `-` as `%2D`.** For
    example, a zeroed mode name from `GETCRTC` with no mode gives `name=-`.
  - A record that would not fit its 1024-byte line, or a string not
    terminated within its bound, is replaced by `step=overflow orig_step=…
    orig_rc=…` with the same `seq`. Nothing is silently cut.
- **The last record is `step=eos records=<n> dropped=<n> overflows=<n>
  out=<file|pipe|null>`, right after `step=exit`.**
  - A stream without it is INCOMPLETE.
  - A gap, a duplicate, a bad `len`/`crc`, a changed nonce or anything
    after `eos` makes it INVALID (`tools/check_stream.py`).
- Steps (`show`), in order: `start` · `open` · `version` · `caps` ·
  `resources` · `connector`* · `chosen_connector` · `mode`* · `pipeline` ·
  `crtc_state` · `chosen_mode` · `planes` · `plane`* · `atomic_props` ·
  `buffer` · `plan` · `test_commit`(1–4) · `commit` · `hold_start` ·
  `hold_end` · `exit` · `eos`.
  - Optional steps: `signal`, `usage`, `overflow`.
  - The stream stops at the first failing step, followed by `exit` and
    `eos`.
- `shown=1` means the real commit returned success. Only the PM reading
  the nonce proves that light reached the eye.

## Exit codes

| code | meaning | real commit made? |
|---|---|---|
| 0 | image committed and held to the deadline | yes |
| 1 | internal error (hold wait failed and the hold ended early; render I/O) | maybe (`shown=`) |
| 2 | usage error (nonce, hold, argument count, path length; mock path is a DRM device) | no |
| 3 | stdout is not a regular file, pipe/FIFO or `/dev/null`; **nothing written** | no |
| 10 | no device (`stat`/`open`: ENOENT, ENODEV, ENXIO, ENOTDIR) | no |
| 11 | not a DRM char device (seen by `stat`, never opened); other stat/open failure; node changed between `stat` and `open` | no |
| 12 | `DRM_IOCTL_VERSION` failed or the driver is not `msm_drm` | no |
| 20 | no connected connector, or a resources/connector read failed | no |
| 21 | ATOMIC cap refused; no usable encoder/CRTC/plane; properties missing; request overflow | no |
| 30 | neither an ACTIVE, listed, progressive current mode nor 4128×2208@90 | no |
| 40 | dumb buffer / mmap / ADDFB2 / mode blob failed | no |
| 50 | every allowed TEST_ONLY attempt rejected, or none allowed | **no** |
| 60 | the real commit failed (one attempt) | attempted, failed |
| 70 | SIGTERM/SIGINT/SIGHUP before the deadline (fd closed first) | maybe (`shown=`) |
| 142 | killed by its own SIGALRM (30 s before the commit; HOLD_S + 5 s after it); no `exit`/`eos` | maybe |
| 137 / 143 | killed by the supervisor's KILL / TERM default action | maybe |

143 is an exit status only; it does not prove that a timer fired (FS-R-006
§5C). The evidence is `fs-supervise`'s report: `end=timer-term` or
`end=timer-kill`.

## Safety constraints

- Static, dark, one commit (research §3; PROJECT_SETUP §6A). We never
  unblock or write the backlight; the forbidden writes listed in research
  §3 have no code path here.
- Client time: see "How long the image can stay up" (≈ 15 s plus the kernel
  close path).
- Thermal: there is no tsens and no fan control in a stage-1-style image
  (research §3, [O5]), hence the 10 s maximum. Display state is not a
  cooling control (FS-R-006 §4).
- DRM master: the first opener of card0 becomes master. No other DRM
  client may run, and the preclose null commit requires us to be master.

Integration sketch (for FS-A-007, not implemented):
1. After `MODULES_READY`, create the node if needed: `[ -c /dev/dri/card0 ]
   || mknod /dev/dri/card0 c 226 0` (check `/sys/class/drm/card0/dev`
   first).
2. Run `fs-supervise -t 16 -g 3 -o /run/fsp.out -r /run/fsp.err --
   /bin/fs-pattern show <chal[0:8]> 10`, with the PM looking through the
   lenses.
3. FSB1-encode the step and emit it after the child is reaped.

## Build

```
wsl.exe -e bash <repo>/devices/quest3/stage3a/tools/build.sh
```

The exact command, toolchain and hashes are in `build/BUILD.txt`.
- The binary links static glibc from `libc6-dev-arm64-cross`; `libc.a` is
  hashed in `BUILD.txt`.
- glibc provides the syscall wrappers plus a few library routines:
  `malloc` (in `render` only), `memcpy`/`memset`/`strcmp`/`strlen`, and the
  signal-set helpers. The tool uses no stdio and no locale; stdio appears
  only in the unit-test build.
- The script enforces aarch64, ET_EXEC, no INTERP and no NEEDED (as the
  stage-1 builder does), and a bit-identical second build.

Current build (v0.4, 2026-10-09):
- `src/fs-pattern.c` sha256 `237ea6f26f20698f08b473701096ac42282b53d30a8eb87dec03ecff47d94305`
- `build/fs-pattern` sha256 `c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a`
  (615 528 bytes, static aarch64, stripped)
- `build/fs-pattern-unittest` sha256 `cb05c17a…6b8696` (offline only)
- `libc.a` sha256 `76a89dad8c7ecb9ccd4efdfa190315c04f8172c08d3fac1623d98dd07002bac7`
  (libc6-dev-arm64-cross 2.43-2ubuntu2cross1)
- headers: v2.7 `drm.h` `db489b54…1df297`, `drm_mode.h` `113ba3bd…43901f`
- `clang-r450784e --target=aarch64-linux-gnu -static -O2 -std=c11
  -D_GNU_SOURCE -D__user= -Wall -Wextra -Werror
  -Wno-missing-field-initializers -fno-ident -I<v2.7>/include/uapi/drm
  -fuse-ld=lld -Wl,--build-id=none -s` (exact line in `build/BUILD.txt`)

## Fixtures

```
wsl.exe -e bash <repo>/devices/quest3/stage3a/tools/fixtures.sh
```

All fixtures run the exact aarch64 binaries under `qemu-aarch64` (user
mode). WSL has no `/dev/dri`; the script refuses to run, before touching
any result file, if one appears. No fixture issues a DRM ioctl.

Result on v0.4: **85 checks, 0 failures** (`fixtures/RESULTS.txt`;
per-run output in `fixtures/<name>.txt`).

| fixture | result |
|---|---|
| unit tests (`fixtures/unittest.txt`) | 28/28. Mode policy: the current mode is used only if ACTIVE, listed and progressive; otherwise exact 4128×2208@90; everything else rejected. Attempt plan: no modeset for a non-expected mode; zero attempts when nothing is allowed. Also: request overflow refused and not sent; CRC-32 check value; framing bytes; overflow record keeps `seq`; unterminated string → overflow; `-`/`%2D` tokens; path 200/201 |
| render 4128×2208, three nonces covering every glyph | nonce decoded from **both** halves; levels only 0x10/0x60/0x70/0x90; 3.6 % lit; marks in place; deterministic; image bytes identical to v0.1 |
| `show` with no `/dev/dri/card0`; absent path; regular file; `/dev/null` | 10 (`at=stat`); 10; 11; 11 |
| `qemu -strace`: `show` on `/dev/null` | `newfstatat` only, no `openat`: a non-DRM path is never opened |
| `qemu -strace`: `holdtest` | `stat` before `open`; open flags `O_RDONLY\|O_NOCTTY\|O_CLOEXEC` |
| `qemu -strace`: close before write | after the last `rt_sigtimedwait`, `close(3)` comes before the next `write(1,…)`, both at the deadline and after SIGTERM |
| usage: no args, bad nonces, hold 0 / `1e3` / 7 digits, extra arg, 201-byte path | all exit 2 |
| stdout on a tty (via `script`) | exit 3, nothing written |
| stdout `/dev/null`; pipe | accepted (`out=null`, `out=pipe`) |
| `ulimit -f 0` (file-size limit) | exit 0: writes fail with EFBIG and are counted, not death by SIGXFSZ |
| blocked stdout (full FIFO, nobody drains) | hold 3 s → exit 0 at 3.0 s; hold 999 s + TERM at 2 s → exit 70 promptly |
| hold 3 s | `held_ms=3000`, `alarm_s=8` |
| re-armed alarm: hold 3 s, SIGSTOP at 1 s, SIGCONT at 10 s | SIGALRM (142) |
| hold 999 s + SIGTERM / SIGINT / SIGHUP / SIGINT with the parent ignoring it | `clamped=1` (999 → 10); exit 70 in 15–36 ms |
| hold 999 s left alone | exit 0 at `held_ms=10000` (the 15 s alarm is not reached) |
| backstop: SIGSTOP at 2 s, SIGCONT at 18 s | SIGALRM (142), no `hold_end`. The alarm was due at 15 s; the kill landed 18 ms after SIGCONT, because a stopped process can only die once continued. Under qemu this measures delivery at SIGCONT, not at 15 s |
| empty values | the unit-test `stream` sample writes `name=- drv=- dash=%2D` and validates COMPLETE; the reviewer's v0.3 record (`name=`) stays INVALID |
| framing of **every** fixture stream (30 files) | 27 COMPLETE; the two SIGALRM kills INCOMPLETE (by design); the tty refusal EMPTY |
| validator negatives | deleted middle record → INVALID (seq gap); deleted `eos` → INCOMPLETE; one byte changed → INVALID (crc) |

### Before/after

`tools/regress.sh`, run on each version
(`fixtures/regress-v0.1.txt`, `-v0.3.txt`, `-v0.4.txt`):

| check | v0.1 | v0.3 | v0.4 |
|---|---|---|---|
| R1 blocked stdout, hold 3 s | FAIL (142 at 150 s) | PASS | PASS |
| R1b blocked stdout, TERM in the hold | FAIL (142, 148 s after TERM) | PASS | PASS |
| R2 alarm re-armed to HOLD_S + 5 | FAIL | PASS | PASS |
| R3 tty stdout refused | FAIL | PASS | PASS |
| R4 framing len/crc/seq/eos | FAIL | PASS | PASS |
| R5 close before the `hold_end` write (v0.1: record check; v0.3+: `qemu -strace` order) | FAIL | PASS | PASS |
| R6 no legacy SETCRTC (source) | FAIL | PASS | PASS |
| R7 real commit one attempt (source) | FAIL | PASS | PASS |
| **R8 mode policy + empty values** (`policy_harness.c`, 29 checks) | n/a | **FAIL** (10: inactive current used; unlisted or interlaced current used; modeset with 72 Hz or unlisted modes; `name=` empty) | PASS |
| **R9 stat before open** (`qemu -strace`) | n/a | **FAIL** (`openat("/dev/null",O_RDWR\|O_CLOEXEC)`) | PASS |
| **R10 SIGXFSZ ignored** (`ulimit -f 0`) | n/a | **FAIL** (exit 153) | PASS |
| R11 close before write after SIGTERM (`qemu -strace`) | n/a | PASS | PASS |
| **R12 hold maximum 10 s** | n/a | **FAIL** (`hold=45`) | PASS |

R5 and R11 pass on v0.3 too: v0.2 already closed first, and the second
review asked only for syscall-level evidence in place of the program's own
`fd_closed=1` claim.

Not covered offline (these need the device): every DRM ioctl after
`open`, the mode list, `GETCRTC`/`ACTIVE`, plane acceptance, the TEST_ONLY
attempts, the commit, the close behaviour, and legibility through the
lenses. The mode policy and the attempt plan are covered by unit tests and
the harness, using the same functions. The `holdtest` refusal of a real
major-226 node is not exercised (it would need such a node); the same
`stat`-first code path is exercised on `/dev/null`.

## Open unknowns

From the research note (§5):
- **[O1]** What the panels showed in stage 1: lit black or unlit.
- ~~**[O2]** Whether stock recovery draws on the Quest 3 panels~~
  **closed by the PM's report** (J-43): stock recovery lights the Quest 3
  panels. This is a **PM report** (an observation without a recorded
  artifact), not [M]. It supports the route (the same modules, plain DRM,
  no compositor). It does not show what our own commit does.
- **[O3]** Whether the first commit after the splash handoff is a plane
  swap or a full enable, and whether one 4128-wide plane passes TEST_ONLY.
  The tool tries both in that order and reports which passed.
- **[O4]** The boot-default BLU luminance and duty with changes blocked.
  (J-75: on v66 there is no blocking. The commit programs about 8.2 %
  duty [D]; trial (iii) emitted no light.)
- **[O5]** The thermal envelope of a held display with no tsens and the fan
  undriven.
- **[O6]** The full mode list (this tool prints it, and the current CRTC
  mode and ACTIVE).
- **[O7]** Whether the v66 driver matches v2.7 on the backlight, splash
  and close paths cited here.

Specific to this tool:
- Whether SDE accepts a plain atomic request without its private plane
  properties. minui's QTI backend sets more; TEST_ONLY answers this
  harmlessly. [O]
- Whether planes left attached from the splash need turning off (the tool
  does so in the same request). [O]
- Whether `GETCRTC` reports a valid mode with ACTIVE=1 during continuous
  splash. Research says the CRTC is marked active with the preferred mode
  (`sde_kms.c:3612-3619`). [D]/[O]
- Whether the 180° rotation and the eye ↔ link mapping are as derived
  (the underline, the square and the bars answer it). [D]/[O]
