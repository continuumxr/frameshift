# Stage 3a boot image: the display test (`fs-pattern` once, under supervision)

**Status:** built and fixture-tested **offline only**, fix round 6 of
2026-10-09, after the package reviews of `cf251bb`. No device, adb,
fastboot or COM port was used.

**Not proposed for a device.** Its use needs FS-A-007, the Chair's
concurrence and the PM's live sign-off.

**What it is.** A separate `fastboot boot` image for Unit 1 (Quest 3, v66,
slot A). It extends the **proven stage-1 image**
(`efefe10dd241fa3525da7b7602b54a47976d6bfb36f27a5dddbb62c0fdf67250`) with:
- the common PID 1 deadline;
- one `fs-pattern` v0.4 run (`README.md`; a 10 s hold cap) under
  `fs-supervise`;
- one FSB1 record.

It carries no Valve file.

**What success means.** The real result is **the PM reading the
8 characters through the lenses on both eyes**. The classifier gives the
machine side only (OUTCOMES §8).

**Tags:** [M] hardware output · [M-static] named artifact · [D] derivation
· [C] hypothesis · [O] open. Fixture runs are [D] evidence (qemu-user,
bwrap, WSL kernel), not [M].

**Recovery:** `devices/quest3/RECOVERY.md`.

## 1. The image

| | |
|---|---|
| file | `build/stage3a/20261009T085209Z-17449af173f0633a/boot-stage3a.img` (gitignored) |
| SHA-256 | **`d2bb28f742db12385287568808326d55b459f82af69ab0fc41192363fecccc23`** |
| size | 43,130,880 B |
| nonce | `17449af173f0633a` (USB serial `FS-17449af173f0633a`). One attempt only; ledger `build/stage3a/attempted` |
| builder | `stage3a/build-image.sh` `da789a3008329f526cfef2472d30d21dc6cdad7bde7e8cc82c200b1ed3c9d73d`; records in the build directory |
| stock boot | `49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50` |
| kernel | `f34165b35a826052ce5b520d9313387c96970b498733f1a7b141dcf4afc94e7b`, byte-identical |
| header | only `ramdisk size` and `boot.img signature size` differ from stock |
| ramdisk | `ramdisk.lz4` `b151c98649d78bdb8d045b93bd7c6e68820b4217321446f40de7dcc38a3af900` (1,915,907 B); cpio `fa2ee5a13832cb24ebe3ab72520a0958cc6f9fcdf8b2a4bd60051d27b0e61c9e` (3,306,496 B, `--reproducible`) |
| vendor_boot | `1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf`; modules list `1ec0253fa9b80e7121722259ab9d6de0f1c4e5015846fea4737cd14af80a6745`; file list `403e891e9eb71e638afe1fceb715f87d6da02cfe4b12df2253c33efddae1c040` |
| E1 | AOSP mkbootimg `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` CLEAN, helper `adbe27e92be16da5d2d8a2bc8f3ea35bd2040cd41ed38068c1360030433487e8`. **E1 notes: mode bits not checkable on this drvfs checkout** |
| scan | `stage2a/tools/t1-ramdisk-scan.sh` `73e969caf90418c6dd0ab9c06f10570ba6656f7472db6e337a3f24af3d28c524`: no BLAKE2 hit |
| reproducibility | same nonce and stamp twice → one image, `f01ebbb04473c25726bb4cfd8bbf1c59bddcb2023230979b8065e27d21eab4e4` (`test-builder.sh`) |
| superseded | in `build/stage3a-superseded/`, not for use: `0a907acaf886c2a678163531d3169ff644e9253b21b8e58f975c590e72775c7a`, `0836441d41ebd2558c8affd5055a1555648cf774f8221b8e8eec0405e68e7dff`, `08cee7103821b451728051434bb0dffd9fedc4aa585307a39ba2c7827e622d0f` (`cf251bb`), `7e84d90299a31b147c5e9714be1f73d3a68789ffa5fb50f084aa0bb854dc4176` |

### Contents (our ramdisk; the vendor ramdisk is stock)

Directories: `bin config dev lib lib/fs proc run sys tmp`.

| path | size | SHA-256 | source |
|---|---|---|---|
| `/init` | 12,416 | `957cb4ec1b8b7d1d145bfa818dbedf082fcc1a6b11ad24180bafa522dfa78871` | `stage3a/init.sh` `2594c410ce5e1dd797bf29fc34dfd5f20d8165ecb8d3acc1a347d5d55061a35c`, nonce substituted |
| `/bin/busybox` | 1,981,032 | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | stage-1 busybox 1.37 |
| `/bin/fs-reboot` | 1,400 | `c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29` | stage-1 helper (backstop) |
| `/bin/fs-reboot-final` | 808 | `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` | `common/build` (record: `common/build-record/`) |
| `/bin/fs-supervise` | 676,952 | `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74` | `common/build` |
| `/bin/fs-pattern` | 615,528 | `c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a` | `stage3a/build`, v0.4 (record: `stage3a/BUILD-RECORD.txt`) |
| `/bin/fs-display` | 2,687 | `008c79cdff01c142cd390398b1bfc47814abcf85de1c78637eb7d959186408fe` | `stage3a/fs-display.sh` |
| `/bin/fs-done` | 705 | `7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959` | `common/target/fs-done` |
| `/lib/fs/pid1-hold.sh` | 7,556 | `4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4` | `common/target`, rev 5 |
| `/lib/fs/fsb1-enc.sh` | 4,943 | `11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7` | `common/target`, rev 5 |

## 2. What the builder enforces

The same checks as stage 2a (`../stage2a/IMAGE.md` §2), without the Valve
parts:
- the pinned `fs-pattern` and five static ELF files;
- the exact ramdisk list (an injected file is refused,
  `inject-extra-file`);
- the union lacks the loader paths and `/valve`;
- the scan finds no BLAKE2;
- the `--reproducible` cpio;
- the E1 notes in the MANIFEST.

## 3. What it does, step by step

1. **Stage-1 §0.**
2. **`fs_hold_init 170 150`.**
3. **The backstop**, then the 97 modules.
4. **The DRM node:** `mknod -m 600 /dev/dri/card0 c 226 0`, only if it is
   not already a character device and sysfs says `226:0`.
5. **Stage-1 USB, gadget, helpers and shell.** `fail()` reboots at T0+60
   (red LED).
6. **`fs_hold_loop`** (no-ack: magenta LED, then the reboot).
7. **Host, once:** `fs-display <chal>`.
   - Step 1 `hash` (`-t 3`): `sha256sum /bin/fs-pattern`.
   - Step 2 `pattern` (`-t 16 -g 3`): `fs-pattern show <chal[0:8]> 10`.
     stdout goes to a RAM file, never the tty.
   - Then one empty line and the record.
8. **Host:**
   - the collector (`-Stage 3a`) beeps on the host (beep 1), pauses 10 s read-only, then beeps again (beep 2; `host/COLLECTOR.md` §11);
   - **the PM confirms the panels are dark** (PM-OBS2);
   - `fs-done`;
   - PID 1 execs `fs-reboot-final`.

## 4. Timing and the panels (one table; `check-timing.py` CONSISTENT)

| quantity | value | source |
|---|---|---|
| device deadline | **T0 + 170 s**; backstop T0 + 171 s | `init.sh` |
| ack window / ERR_DELAY | **150 s / 60 s** (stage 1's values) | `init.sh` |
| host give-up | BootStartUtc + 155 s (BootStartUtc: taken before `fastboot boot` is invoked, <= T0; FS-R-007 B1); pre-runner phases by BootStartUtc + 135 s; the live start is refused with < 30 s of the ack window left (checked again after the gadget lookup) | `fs-collect.ps1 -Stage 3a` |
| display cue (round 7) | the collector prints "=== LOOK INTO THE LENSES NOW … ===" and waits **3 s** (read-only) before `fs-display` | `fs-collect.ps1 -Stage 3a` (`DisplayCueMs`) |
| record budget B / runner worst W | **60.0 s** = 170 − 15 − 20 − 61 (2 fs-status tries, revision 8) − 3 (cue) − 11 (beep 1 + 10 s pre-done pause + beep 2) / **42 s** (`hash` 13 s, `pattern` 27 s, emission 2 s); spare 18.0 s (planning figure: the 20 s now includes the `fastboot boot` transfer (~11 s), so the spare is optimistic; the run-time guard enforces the real time (it decides whether a run proceeds, not safety)). The collector refuses to send `fs-display` with less than 42 + 5 + 11 s left before give-up (round 7 NIT3; revision 8) | `check-timing.py` |
| **client hold** | the requested client hold is **10 s**, measured from commit start; its alarm is scheduled for **15 s**, subject to scheduling, suspend and uninterruptible kernel waits. Closing the descriptor does **not** prove that v66 turns off the panels or backlight [O]. If release leaves the frame displayed, it may remain until recovery; T0 + 170/171 s are **intended reboot timings, not guaranteed physical panel-off times**. Kernel hangs, suspend and failed reboot paths fall to manual recovery (FS-R-007 §4) | fs-pattern v0.4 [M-static source]; FS-R-007 §4 |
| **panels after fs-pattern closes the fd** | **off** per the v2.7 driver source (preclose null commit; lastclose disables the CRTC, README "What closing does") **[D]**; the v66 driver: **[O]** | |
| **worst case** | **[O]** if the [D] close path does not hold on v66, the **last frame, our test pattern**, may stay **lit** (dark greys, max level 0x90, 3.6 % of pixels lit, backlight at its boot level; **J-75 correction: on v66 the commit programs the BLU at 1000/1000, ≈ 8.2 % duty [D]**) until recovery. The PID 1 reboot is intended at T0 + 170 s (backstop 171 s); that is an intended reboot time, not a guaranteed panel-off time, and a kernel hang, suspend or failed reboot leaves it to manual recovery. A dark pixel pattern is not a measurement of backlight power or panel temperature | `init.sh` deadline, README "The image" |
| **control** | the **PM confirms dark before `fs-done`**, single-operator: eyes in the lenses from the cue; beep 1 = the hold has ended, 10 s read-only pause, beep 2 = fs-done (`host/COLLECTOR.md` §11). A lit panel then is recorded as a finding; `fs-done` still follows | |
| measured (harness, no DRM) | record by about T0+19 s; reboot 0.3 s after `fs-done` | `fixtures/image/` |

**Why 170 s.** The live collector needs its worst-case 61 s of
verify/ack/status (2 fs-status tries for stage 3a; 76.5 s with 3 before
revision 8). Under the earlier 60 s it could not run at all. Physical
panel exposure is **not** bounded by `fs-pattern`: the client requests a
10 s hold (alarm scheduled at 15 s), but whether closing turns the panels
off on v66 is [O]. If it does not, the frame may stay displayed until
recovery; the intended reboot at T0 + 170/171 s is not a guaranteed
panel-off time (FS-R-007 §4).
**Errata (FS-R-007 §4):** the pinned on-device `init.sh` header comment
still says the panels stay "black" in the worst case; it is left unchanged
to keep the reviewed image hash, and this text supersedes it. The PM checks
for dark before `fs-done`, and `fs-done` reboots the device about 1 s later,
so in the normal flow a failed close is seen and ended within seconds. No fan is driven and no thermal engine
runs (as in stage 2a, IMAGE §6A there). Stage 1's longer hold is **not**
used as a heat argument (FS-R-006 §4: no event reported is not verified
protection).

## 5. Expected FSB1 steps (`exp=stage3a`, `steps=2`)

| i | id | expected |
|---|---|---|
| 1 | `hash` | `exited 0`, `c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a  /bin/fs-pattern\n` |
| 2 | `pattern` | `exited 0`, a sound FSP1 stream: nonce = `chal[0:8]`, `commit rc=0`, `hold_end reason=deadline`, `exit code=0 reason=held_to_deadline shown=1`, `eos` |

## 6. Outcome mapping (OUTCOMES §8; `fs-classify.ps1 -Stage 3a [-ObserveDir]`)

| # | condition | outcome |
|---|---|---|
| 1 | stage 1 not PASS | that class |
| 2 | no record, rejected, or late | INCONCLUSIVE |
| 3 | `hash` measured a mismatch | INTEGRITY FAULT |
| 4 | `hash` unmeasured | INCONCLUSIVE |
| 5 | `pattern` tool fault | INCONCLUSIVE |
| 6 | `pattern` hang, own-fault signal, ENOEXEC/ELIBBAD | DISPLAY FAIL |
| 7 | the stream is not sound | INCONCLUSIVE |
| 8 | exit code 10/11/12/20/21/30/40/50 | NO-DISPLAY |
| 9 | exit code 60 or 1 | DISPLAY FAIL |
| 10 | exit code 0, committed and held to the deadline | **PASS (machine side)**; the stage passes only with the PM's reading |
| 11 | anything else | INCONCLUSIVE |

The collector's terminal states (a foreign ack, an `FSDE1` refusal, the ack
window) are INCONCLUSIVE.

## 7. Offline fixtures (round 6)

| suite | result |
|---|---|
| builder `test-builder.sh` | **9/9**: 7 refusals; `inject-extra-file` refused; `repro-same-nonce` bit-identical |
| whole image `test-image.sh` | **8/8** (below). No DRM device exists in the sandbox |
| host side `../stage2a/test-host.ps1 -Dir build\stage3a-harness` | all PASS. Classifier and `fs-collect -Stage 3a -Replay`, with `fs-classify -Stage 3a`, agree |

| scenario | result |
|---|---|
| `s3-nodrm` | `pattern` exited 10; FSP1 COMPLETE, every nonce = `chal[0:8]`; **NO-DISPLAY**; reboot `collected` 0.3 s after `fs-done` (T0+19.1) |
| **`s3-pattern-stopped`** (round 6, N5) | the **genuine** fs-pattern (hash intact) is SIGSTOPped from outside as it execs (inotify on the binary): step 2 `timer-kill` (TERM 16 s, KILL 19 s) → **DISPLAY FAIL (rule 6)** with integrity shown; T0+32.8 |
| `s3-hung-pattern` | fs-pattern replaced by an endless script: step 2 `timer-kill`; INTEGRITY FAULT (step 1 measures the replacement) |
| `s3-missing-pattern` | INTEGRITY FAULT |
| `s3-no-ack` | `no-host-ack` at SHELL_READY+150.3; **LEDs magenta** |
| `s3-ack-no-done` | `deadline` at T0+171.0; HOST_ACK did not cancel it |
| `s3-done-early` | `collected` within 0.1 s |
| `s3-no-udc` | `fail()`: `error-udc` at T0+61.2 |

## 8. Changes from the stage-1 init (each justified)

| # | stage 1 | stage 3a | why |
|---|---|---|---|
| 1 | dead-man cancelled by HOST_ACK; then hold | `fs_hold_*`; HOST_ACK only recorded | FS-R-006 §5 D |
| 2 | dead-man 300 s | deadline **170 s** | the host's budget (§4); 300 s stays the ceiling |
| 3 | ack window 150 s, ERR_DELAY 60 s | **the same** | round 6 restored both (the earlier 120 s / 30 s were not needed) |
| 4 | no-ack: magenta, `reboot_bootloader` | magenta, exec `fs-reboot-final` | as stage 2a |
| 5 | log, `sync`, fork `fs-reboot` | exec `fs-reboot-final`; **no `sync`** (nothing persistent is mounted); the backstop child keeps `fs-reboot` | a PID 1 exit is a panic; reboot first |
| 6 | the dead-man after `mdev -s` | the deadline armed first | T0 fixed before any module |
| 7 | — | the DRM node step; `fs-pattern`, `fs-display`, `fs-supervise`, `fs-done`, `/lib/fs/*.sh` | the display test |
| 8 | product `FrameShift stage1` | `FrameShift stage3a` | identity |

## 9. Not exercised offline; open items

**Not exercised offline:**
- every DRM ioctl, the commit and the close path (whether it turns the
  panels off on v66: [O]);
- legibility;
- the `card0` mknod;
- the 97-module load;
- configfs, the UDC and CDC-ACM;
- the real reboot;
- PID 1 signal immunity;
- thermal behaviour [O5].

The machine-side PASS has been exercised only with synthetic committed
streams (host S01, `3a-committed`).

**Open:**
1. Round 6 was re-reviewed (no blocker); round 7 and the final-review host changes have fixtures but no further adversarial round.
2. FS-A-007 asks for the display-before-headless ordering (§3.2, ask 3).
