# Quest 3 stage 3c: the interactive per-phase display run (device side)

**Status (2026-10-12): built and fixture-tested offline; CANDIDATE image only (the build-review
rebuild: DESIGN.md "Build-review fixes" maps every R-B/R-C finding to its fix; reviews done J-111..J-114).
Not run on any device yet; no adb, fastboot or COM port was used for it.** The design is `DESIGN.md`
(revision 3, R-A applied); this package implements its device side exactly. The host side
(`../host/*3c*`) is written in parallel against the same interfaces (§5 of this README lists them).
Stage 3b (`../stage3b/`) is spent and unchanged; its image, builder, binary and pins still reproduce
the trial-(iii-b) evidence.

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C] hypothesis · [O] open.
Fixture runs are [D] evidence (qemu-user, bwrap, WSL), not [M].

**The image:** `IMAGE.md` (identity, contents, timing, records, fixtures). **Outcomes:** DESIGN §11
(proposed `../common/OUTCOMES.md` §10, not edited here). **Recovery:** `../RECOVERY.md` (stage-3c rows
still to be added by the docs step of DESIGN §12.5).

## 1. What the run does (DESIGN §1, §4)

One temporary `fastboot boot` of a new image with a fresh nonce on Unit 1. After the stage-1
bring-up (fs-verify, fs-ack, fs-status), the host sends one `fs-phase` command per phase, each
answered by its own paced FSB1 record and live FSPM1 markers, with the PM's readings in between
while the panel is off:

| phase | what runs | lit |
|---|---|---|
| p0 | the integrity hash of `/bin/fs-pattern` (concurrent) and probe0: irq0, the mods snapshot (cmdline, dmesg), **the one backlight write 127** and its read-back | no |
| r1 | probe1 (read-back, pre, go+1 s, mid at 1.5 s, end, post), then `fs-pattern show <c1[0:8]> 3`: the v0.5 run-1 commit path (2 x 2064 on the active splash CRTC, reported dark in trial (iii-b): no panel-on sent [D], BLU IRQ 0 [M]; not zero emission, FS-R-010 §2; deliberately committed as the wake step) with the v0.6 picture | 3 s (expected dark) |
| r2 | the 2 s pause after run 1, probe2 (mid at 5 s), `fs-pattern show-off-quad <c2[0:8]> 10`: inactive CRTC required (exit 31), split probe (TEST_ONLY only), then quad_vig, then quad_dma, 4 planes x 1032 px with zpos {0,0,1,1} | 10 s |
| r3 | only if the host's run-3 rule holds: the pause after run 2, probe3 (mid at 2.5 s), `fs-pattern show-off-solid <c3[0:8]> 5`: the red field on the same quad layout | 5 s |

Then the gated `fs-done`. The device adds an idle limit (120 s; 180 s for a stuck phase) on top of
the unchanged DEADLINE 200 s / backstop 201 s.

## 2. Files

| path | what |
|---|---|
| `DESIGN.md` | the design, revision 3 (input; unchanged by this package) |
| `src/fs-pattern.c` | fs-pattern **v0.6** (one file, no libdrm). With `-DFSP_UNIT_TEST`: unit tests and a mock DRM device that runs the WHOLE show path (`sim`) and the logging (`propsim`) |
| `init.sh` | PID 1: stage 3b's init plus `/run/fs.deadline` and the idle limit (IMAGE.md §8) |
| `fs-phase.sh` | the per-phase runner `/bin/fs-phase` (constants TW, TQ, PAUSE_CS, PAUSE_ITER, HEADROOM, PHASE_WORST_*, MAXLINES_* at its top) |
| `fs-probe.sh` | the probe helper and the one backlight write (roles p0, r1, r2, r3) |
| `fs-idle.sh` | the device-side idle limit (DESIGN §5.9) |
| `build-image.sh`, `test-builder.sh`, `test-image.sh` | the builder, its negative/reproducibility fixtures, the whole-image harness driver |
| `tools/build.sh` | WSL build of fs-pattern and its unit-test binary (static-ELF checks, bit-identical rebuild) -> `build/BUILD.txt` (= `BUILD-RECORD.txt`) |
| `tools/fixtures.sh` | the fs-pattern suite -> `fixtures/RESULTS.txt` |
| `tools/check_propsim.py` | re-derives every value of the mock model independently; checks the `sim` and `propsim` streams and the mock's atomic log |
| `tools/check_static.py` | static checks against the v0.5 source (hold and request builder identical, the a_prop set, zpos confinement, no new ioctl) |
| `tools/check_render.py` | independent render checker (characters, centre line, quadrant map, margins, white/mean envelope; `--solid`) |
| `tools/preview.py` | stdlib port of the drawing code, byte-identical to the C render; the previews for the PM |
| `tools/check_stream.py` | the FSP1 validator (a byte copy of stage 3b's) |
| `tools/image-harness-3c.py` | the whole-image harness (derived from stage 3b's, which is unchanged) |
| `tools/pace_evidence.py` | the paced-emission evidence per phase -> `fixtures/pace/` |
| `tools/check-timing-3c.py` | the stage-3c timing check (DESIGN §9), incl. the host constants when the host files are present |
| `tools/encode-timing.sh`, `tools/dmesg-timing.sh` | the encoder at the maximum streams; the probe's new dmesg filter on a 1 MB log |
| `fixtures/` | the outputs (RESULTS files; `fixtures/preview/` the PNGs for the PM; `fixtures/image/<scenario>/capture.raw` + `.idx` for the host replay tests) |

## 3. fs-pattern v0.6 (DESIGN §6)

```
fs-pattern show            NONCE HOLD_S [DEV]   # run 1: the v0.5 show commit path; the v0.6 picture
fs-pattern show-off-quad   NONCE HOLD_S [DEV]   # run 2: inactive CRTC (else exit 31), split probe, quad_vig, quad_dma
fs-pattern show-off-solid  NONCE HOLD_S [DEV]   # run 3: as show-off-quad, every pixel XRGB 0x00FF0000
fs-pattern show-off        NONCE HOLD_S [DEV]   # = v0.5 (fixtures only; not called by fs-phase)
fs-pattern render | render-solid NONCE W H OUT.ppm ; holdtest NONCE HOLD_S MOCK   # offline
```

- **Picture** (§6.3): field 0x80, marks 0xFF; no frame or corner square; the 8 characters and their
  underline unchanged; the vertical arm on the mixer seam; a centre line from M_X = 480 to ew − 480
  (8 px); per mixer an upright F above k bars: LM0 2, LM1 1, LM2 4, LM3 3, so an upright, correctly
  staged image reads "1 | 2" in one eye and "3 | 4" in the other. White 2.64–2.90 % for the fixture
  nonces, 3.09 % for the worst case `bbbbbbbb` (v0.5: 3.76 %); mean ≤ 131.92/255 (v0.5: 132.78).
- **Quad plan** (§6.2): the planes come from their `capabilities` blobs: type from `max_upscale`
  (20 VIG, 1 DMA, else not selectable), index from `pipe_idx`, rect from `primary_smart_plane_id`.
  An eligible plane has GETPLANE ok, XR24, our CRTC possible, type ≠ cursor, crtc 0 or ours, the 10
  layout properties and `zpos`, and a parsed blob with `pipe_idx` and `max_upscale`. Each attempt
  needs exactly one candidate per slot: none → `unavailable-missing`, two or more →
  `unavailable-ambiguous` (no TEST_ONLY). Order: split probe (attempt 0, TEST_ONLY only, never
  committed) → quad_vig (attempt 1: VIG0–3 rect 0) → quad_dma (attempt 2: DMA3 r0, its r1, DMA2 r0,
  its r1). Plane k: SRC_X = CRTC_X = 1032 k, width 1032, full height, `zpos` = FSP_QUAD_Z[k] =
  {0, 0, 1, 1}. The first accepted quad request is committed once (ALLOW_MODESET). None accepted:
  exit 50 `no_quad_accepted`, nothing committed.
- **The 2 × 2064 policy (build review, wording):** run 1 (`show`) **deliberately commits** the reviewed
  v0.5 2 × 2064 split as the wake step (DESIGN §6.1, Q16, PM "run 1 unchanged"). The rule "2 × 2064
  only as TEST_ONLY" applies to the quad modes (runs 2/3): there the split request is a probe and only a
  quad layout can be committed. `tools/check_static.py` checks both (the split probe's `a_commit` carries
  TEST_ONLY, `ok` is assigned only in the quad loop, the quad branch commits only `qtag`).
- **Essential-record cap (build review):** `connector` / `mode` / `plane` / `plane_caps` records are
  essential only up to 3 / 24 / 20 / 20 (`FSP_ESS_*`, the counts of the maximum fixtures, asserted by
  `check-timing-3c.py`); every further one is optional (inside the opt budget), so the stream bounds hold
  whatever counts the device reports.
- **Only new SET:** `zpos`, only in `a_plane_z`, only with `FSP_QUAD_Z[k]`. `hold()`, the request
  builder (`struct areq`, `a_obj`, `a_prop`, `a_plane`, `a_plane_off`, `a_commit`), the mode policy
  and the exit-code table are textually identical to v0.5 (`tools/check_static.py`).
- **Logging** (§6.5, GET ioctls only, no new ioctl; the ioctl set is v0.5's and includes
  `SET_CLIENT_CAP`, per fd, needed for any atomic request): `plane_caps` per plane (essential in the quad
  modes), `post_state` and `post_plane` after the commit and before `hold_start`, the connector
  capabilities blob, full property lists in show/show-off-quad; FSP_BLOB_MAX 8192, FSP_OPT_MAX 38912,
  FSP_OPT_MAX_SOLID 10240. The run-1 (`show`) plan and attempt records are byte-identical in format to
  v0.5's; against the mock they reproduce trial (iii-b)'s real attempt records exactly (objs, props,
  planes_off, rc).

**Build** (v0.6, build-review rebuild; `BUILD-RECORD.txt`): `src/fs-pattern.c` `5f67a4d8…2fe9`;
`build/fs-pattern` **`066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc`** (664,168 B,
static aarch64, stripped, bit-identical rebuild); `build/fs-pattern-unittest` `8a9ffd6f…e433` (offline
only). (Before the build review: `3c33e1a2…08d6`, withdrawn.)
Toolchain, headers and `libc.a` as v0.5.

**Previews** (`fixtures/preview/`; the Python port is byte-identical to the C render): the pattern
(`pattern-v0.6-3f9c07ab-viewer-1032x552.png`, `-scanout-4128x2208.png`, `-mixermap-1032x552.png` with
the mixers and their bar counts marked, `-digits-left.png`), the F reference sheet
(`F-reference-u-i-m-v.png`: upright u, half-turn i, mirrored m, flipped top–bottom v) and the red
field (`solid-red-v0.6-viewer-1032x552.png`). Publishing them to `docs/research/pattern-preview/` is
left to the docs step (outside this package's scope).

## 4. Probes, the one write, the idle limit (DESIGN §5.9, §7)

The node list is stage 3b's (sysfs and /proc only; never card0, never debugfs, never the decoy
nodes `blu_default_duty`, `blu_max_overlap_us`, `fifo_trim`). The only write is p0's `127` to
`panel0-backlight/brightness`, once per boot. dmesg filter
`dsi|sde|drm|blu|splash|panel|backlight|bl_|warn|smmu|fault|underrun|iommu|timeout|esd|dsc`
(case-insensitive), lines newer than the previous point, the last 80, ≤ 200 B each, ≤ 4096 B, read
at mods, mid and post only (0.65 s over a 1 MB log under qemu; `fixtures/dmesg-timing.txt`).
`fs-idle.sh` forks nothing in its loop and never writes the tty; it writes `/run/fs.collected`
(`idle`) after 120 s without a running phase, or 180 s with one.

## 5. Interfaces the host side must match

All grammars are DESIGN §5 verbatim, with these decisions taken where the DESIGN left room. The
integration pass checked every item against the host files (`../host/fs-collect3c.ps1`,
`fs-classify3c.ps1`, `fs-observe3c.ps1`, `fixtures/stage3c/gen3c.ps1`) and settled the two that
differed (items 1 and 6); DESIGN §5.2, §5.4, §6.2 and §6.5 now state them, and host test-host3c
section Z2 replays every `fixtures/image/<scenario>/capture.raw` through the host collector and
classifier (expected class per scenario).

1. **Plan lists use `.` and need no %XX** (THE encoding, both sides: the stage-3b packed-list
   convention; the host's `ConvertTo-Fs3cIntList` accepts only this form and reads a `%XX`- or
   `,`-encoded list as no list) (DESIGN's `71,97,100,103`, `vig:0`, `unavailable:missing`,
   `0,0,1,1` cannot appear raw in an FSP1 value): `quad_vig=71.97.100.103`,
   `quad_dma=115.134.112.131` or `quad_dma=unavailable-missing|unavailable-ambiguous`,
   `pipe_vig=vig-0.vig-1.vig-2.vig-3`, `pipe_dma=dma-3.dma-3.dma-2.dma-2`, `max_upscale_vig=20.20.20.20`,
   `max_upscale_dma=1.1.1.1`, `zpos_before_vig=0.0.0.0`, `zpos_before_dma=…`, `zpos_set=0.0.1.1`,
   `splash_set=match|differs`, `attempts=<n>` (the number of TEST_ONLY requests planned: split probe +
   available quads), `split_probe=0|1`; an unavailable attempt's lists read
   `-`. Per-attempt keys carry `_vig`/`_dma` (the DESIGN's unsuffixed `pipe`/`max_upscale`/
   `zpos_before` would be ambiguous across two attempts).
2. **test_commit / commit:** `attempt=0 layout=split_probe`, `attempt=1 layout=quad_vig`,
   `attempt=2 layout=quad_dma` (fixed numbers; an unavailable attempt has no record), `modeset=1`;
   the commit record is `commit rc=0 attempt=<1|2> modeset=1 layout=quad_<vig|dma> commit_ms=<n>`.
   `show` keeps v0.5's `single`/`split` records.
3. **plane_caps:** `plane read_rc caps_bytes max_linewidth pipe_idx max_upscale smart zpos nv12`
   (`smart` = `primary_smart_plane_id`; absent values read `none`).
4. **post_state:** `conn topology_val topology_name dsc_mode_val control_val crtc active mode_id
   core_clk core_ab core_ib llcc_ab llcc_ib dram_ab dram_ib getcrtc_rc mode_valid fb`.
5. **post_plane:** `slot plane crtc_id fb_id crtc_x crtc_y crtc_w crtc_h src_x src_y src_w src_h
   src_frac zpos`; CRTC_X/Y as raw signed GET values (the kernel's right-half rewrite is NOT undone:
   expected 0/1032/0/1032); **SRC_* as whole pixels** (raw >> 16), `src_frac` = the OR of the four
   fractional parts (0).
6. **FSXE1:** `FSXE1 p=<ph|-> ran=<0|1> error=<why> END`; `p=-` only when the argument count or the
   phase word is bad. Every refusal closes the session (`/run/fsb3c/closed`; build review: `/run/fsb3c`
   is made before the first check, so a malformed first command closes it too, `c-usage-then-p0`).
   After the `rec` marker every pacer failure is `emit-<rc>` (rc 3 included). `record-too-large
   lines=N max=M`, `step<i>` and `end` are decided before the `rec` marker (no `rec` precedes them);
   `emit-<rc>` is the only refusal after `rec` (`rec` = the emission starts; with the pinned pacer an
   emit refusal comes before any record byte, a partial record would need a tty write failure).
   ran=1 refusals of a lit phase are preceded by `begin`, `go`, `end` (DESIGN §5.2, host `gen3c.ps1`
   `ran1`/`ran1emit` alike).
7. **FSPM1:** `FSPM1 n=<nonce16> p=<ph> e=<begin|go|end|skip|rec> t=<uptime_ms> END` (≤ 55 bytes);
   p0: `begin`, `rec`; a run: `begin`, `go`, `end`, `rec`; a skipped run: `begin`, `skip`, `rec`;
   `rec` is followed by the record's empty line. `t=0` if `/proc/uptime` is unreadable.
8. **Chain:** the device stores the first 16 hex of `rec_sha256` from its own END line only after the
   record was emitted completely; `<prev>` for r1/r2/r3 must equal it.
9. **Skip reasons** (FSK1 lines): r1 `p0-write-missing`, `probe-late`, `brightness-not-verified`;
   r2 `run1-not-run`, `run1-supervisor`, `run1-no-accepted-commit`, `run1-close-not-clean`,
   `run1-exit`, `run1-stream`, `pause-fault`, `probe-late`, `brightness-not-verified`; r3 the same
   with `run2-*` plus `run2-not-quad`.
10. **Probe output:** `== point <name> run=<ph> up=<s>` sections; names `mods` (p0), `pre`, `go+1`,
    `mid`, `end`, `post` (r phases); every interrupt sample under `-- irq` (or `-- irq (+0.5 s)` at
    mid), ending `-- at <uptime>`; p0's write line `write_rc=<0|1|nonode> readback=<v>`, the r-phase
    read-back `readback=<v>` (no write).
11. **Idle limit token:** `/run/fs.collected` contains `idle` (pid1-hold reboots `collected`).
12. **Host-side facts checked in the integration pass:** exp `s3c_<ph>`; steps `hash`,`probe0` /
    `probe<n>`,`pattern<n>`; FSK1 skip line `FSK1 run=<n> skipped reason=<why> END` (read by the pinned
    `Get-FsS3bRun`); MANIFEST title `FrameShift Quest 3 stage-3c image (` and source keys
    `init.sh source`, `fs-phase.sh`, `fs-probe.sh`, `fs-idle.sh` (read by `fs-observe3c.ps1`; test
    Z2.2 checks the candidate's MANIFEST against the repository); the `N … phase-end p=<ph>` index
    notes are written by the collector only (a harness capture has none; its slices then end at the
    next host write, which `fs-classify3c` accepts); the classifier's fs-pattern pin
    `$script:S3cPatternPin` = `066bdc3e…27bc` (the build above), also the collector's p0 integrity pin
    (build review: no lit phase unless p0's hash step MEASURED it).
13. **Harness monotonic stamps:** the `sim-*` fakes print pre-framed FSP1 streams, so their
    `t0_ms`/`start_ms` are fixture values, one base per phase (r1 21000, r2 41000, r3 61000 ms) so
    that the host's pause check (start − previous start − held − close) reads plausibly; the real pause
    is measured by the runner (`c-pause`, on `/proc/uptime`).

## 6. Precedent and credit

The one-plane-per-mixer layout follows the public work of `machachu56/quest-kexec-q2` (branch
`quest2-port` @ `9c96c192d`: Quest 2 on Meta's stock SDE driver; DESIGN §3, research §B.1), which
found and documented the same failure class and its cure. **No code is copied**: fs-pattern keeps its
own reviewed request builder. The repository's licence checked 2026-10-12: GPL-2.0 (root LICENSE; its Monado driver files BSL-1.0; research "Licence check"); citation only.

## 7. Fixtures (all offline) and open items

Results: `IMAGE.md` §7. **Not covered offline:** every real DRM ioctl after `open` (the mock model
only), whether a quad layout is accepted, the real caps blobs, the topology, the optical result, the
off→on behaviour, the real interrupts and dmesg, the tty/USB timing, legibility.

Open items: DESIGN §15 Q1 (a) `zpos_max` = 10 on v66 and (d) PARALLEL multirect auto-selected
are now recorded (source + the real v66 DT; nothing predicts a rejection); the encode term (the
cold 0.75 s repetition and the END pass now in the model, TQ 3 s: PHASE_WORST 23/38/47/39, G
34/68/82/64; DESIGN §9.1, for the PM); the quest-kexec-q2 licence (closed 2026-10-12: GPL-2.0); the reviews (done, J-111..J-114).
