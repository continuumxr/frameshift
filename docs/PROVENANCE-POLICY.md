# FrameShift provenance and licence policy

Draft, 2026-10-14 (J-155 task; PM direction J-156; licences decided J-157). Owner: the PM. Applies to this repository, to
every public export of it, and to anything FrameShift distributes (installers, images, releases).

> **Not legal advice.** This policy was drafted by the project's AI assistant from the project
> record and general knowledge of open-source licensing. No lawyer has reviewed it. Every point
> marked **[LAWYER]** must be checked by a qualified lawyer before the next public export that
> adds code, and before any image, installer or release is distributed. Section 10 is the
> checklist for that review.

Evidence tags as elsewhere in the project: [M] measured/seen, [D] deduced, [C] claimed by others,
[O] open.

---

## 1. Principles

1. **Our own original code, as much as possible; Meta's code, as little as possible; legally
   disentangled** (PM, J-155). Originality is about expression: modified or paraphrased Meta
   code stays derivative; code written from specifications, public interfaces and observation
   is ours.
2. **Never alter Meta's firmware blobs or Valve's SteamOS image** (PM, J-156). Adaptation lives
   in **bridges**: our own original modules and services, plus **minimal hook patches** to Meta's
   GPL-2.0 kernel source. Valve's rootfs is used byte-unmodified (read-only, dm-verity) with our
   layer beside it (PROJECT_SETUP §0.0). Meta's firmware stays on the user's headset and is
   read from it.
3. **The public repo contains only material we developed ourselves, or have explicit permission
   to post** (PM, J-90). Excluded: copied third-party text beyond a short citation, anything
   extracted from Meta binaries or firmware, disassembly, captures of third-party tool output.
   Kept: our analysis with citations, and data our tools generated from Meta's **public
   GPL-2.0** kernel source, with attribution.
4. **Meta interface identifiers** (JSON key names, sensor names, mitigation level names),
   **threshold numbers and hashes** may appear in public material; **file contents never**
   (PM, J-123).
5. **Behaviour is learned from public interfaces and runtime observation only; no disassembly
   or decompilation** of Valve, Meta or Qualcomm binaries (J-90, J-120, J-152).
6. **Licence-audited FOSS packages may be shipped** with their notice and source obligations;
   proprietary components are never redistributed (PM D6, J-118; FS-R-011 §7 D6).
7. **Licence and source review before publication** (FS-R-011 §8): verify the published tree's
   manifests and licensing/source material before any public flip or export.

## 2. Origin categories

Every file in the public export set has exactly one category in `docs/provenance/files.tsv`
(codes in brackets).

| # | category | code | what it covers | licence we apply | rules |
|---|---|---|---|---|---|
| 2.1 | **Our own original: code** | `own:code` | scripts, tools, host software, our C programs, build scripts, repo config | Apache-2.0 (§6) | clean-room rules (§3) |
| 2.2 | **Bridge code: our own original** | `own:bridge` | the adaptation layer (J-120, J-156): our own userspace services, adapters, SteamVR/OpenXR plugins, and our own kernel modules | userspace: Apache-2.0; kernel modules: GPL-2.0-only (§6) | clean-room (§3); talks to Meta/Valve only through public interfaces (UAPI, D-Bus, documented plugin APIs); none in the export set yet |
| 2.3 | **Our own original: docs, records, fixtures** | `own:doc`, `own:record`, `own:fixture` | documentation, rulings, journal; logs and results of our tools and runs; synthetic or generated test data | docs: CC-BY-4.0; records and fixtures: Apache-2.0 (§6) | records may cite third-party identifiers, sizes and hashes (§1.4), never contents |
| 2.4 | **Hook patches to Meta's GPL source: derived, keep minimal and tracked** | `gpl:hook-patch` | patches against Meta's published GPL-2.0 kernel (`oculus-linux-kernel`) or upstream Linux | **GPL-2.0-only** (the kernel's licence), in `kernel-patches/` | smallest change that gives a bridge its hook; one row per patch with the upstream tree, tag/commit and file, and why the hook is needed; prefer upstream (mainline) code over Meta's where it exists (route (c), J-155) |
| 2.5 | **Derived from GPL source: data** | `gpl:data` | tables our tools generated from Meta's public GPL-2.0 source (config option lists, allowlists) | Apache-2.0, GPL-2.0 attribution kept **[LAWYER]** | attribution to the source tree; no copied source text beyond identifiers |
| 2.6 | **Third-party under another licence** | `third-party:<SPDX>` | anything not written by us that we are allowed to copy (e.g. a licence text, a vendored FOSS file) | its own licence, unchanged | keep its licence text and notices; record origin URL, version and hash; none in the export set except the Apache-2.0 licence text itself (`legal`) |
| 2.7 | **Observed facts about Meta/Valve artefacts** | `observed:meta`, `observed:valve` | our own readouts of headers, identifiers, module lists, hashes, manifests | Apache-2.0 for our readout **[LAWYER]** | identifiers, numbers and hashes only (§1.4); verbatim files or listings are **not** allowed (flag) |
| 2.8 | **Meta/Valve non-redistributable** | `nonredist:meta`, `nonredist:valve` | firmware, proprietary binaries, partition images and dumps, OTA payloads, Valve's images and packages, Meta's prebuilt kernel and modules | **none granted** | **never committed to the public repo, never redistributed**. Read from the user's own device at install time, or fetched from Valve by the user. Any row with this code in `files.tsv` is a release blocker |
| 2.9 | **Public-only placeholder** | `public:placeholder` | READMEs that replace withheld folders in the public copy (prepared privately for each export) | CC-BY-4.0 | — |
| 2.10 | **Unclear** | `[O]` | anything not yet classified | — | blocks the export until classified |

Where Meta's (or Valve's) **non-GPL** material is needed at run time (firmware, calibration, the
vendor thermal configuration, vendor modules), FrameShift reads it **from the user's own
headset** (J-118 thermal-config rule; J-132: no further `/persist` access by the project) and
keeps it on that user's machine and headset. SteamOS comes **from Valve's servers**, fetched by
the user and verified against Valve's keys (PROJECT_SETUP §0.0); we host nothing of Valve's.

## 3. Clean-room rules for new code

1. Write from **specifications, public interfaces and observation**: kernel UAPI headers and
   documentation, published standards (USB, DRM/KMS, OpenXR), Valve's and Meta's public
   documentation, the behaviour of software running in our own environment (calls made, files
   opened, messages exchanged), and our own measurements.
2. **No disassembly or decompilation** of third-party binaries, and no use of anyone else's
   disassembly (J-152: such evidence is discarded and restated as [O]). `strings`-level
   identifiers and package metadata are allowed (as in `usb-link-design.md`).
3. **No paraphrasing of non-free code.** Do not open a non-free source file and rewrite it.
   Facts (an ioctl number, a register offset documented in GPL source, a sysfs path, a JSON key)
   may be used; structure, sequence and expression of non-free code may not.
4. **GPL source** (Meta's kernel, upstream Linux) may be read and used as the kernel licence
   allows. Code copied or adapted from it is **GPL-2.0-only** and lives in `kernel-patches/` (or a
   GPL-2.0 kernel module), never in Apache-licensed files. Writing a userspace bridge after
   reading GPL kernel code is fine for interface facts; do not transplant its code into
   non-GPL files.
5. **Unlicensed public repositories** (no licence file) grant nothing: cite and learn ideas,
   never copy code or text (FS-R-011 §8 for ArmadaVR; the same for any other).
6. **Private sources** (Discord, DMs, community reports) are not quoted publicly without
   permission (J-119); technical content is paraphrased without attribution.
7. Each new source file records its origin in a short header: SPDX identifier, "written for
   FrameShift", and the public references it relies on. A file that is not written from scratch
   says what it derives from.
8. **Reviewers and research agents get these rules in their brief** (J-152).

## 4. What never enters the public repo

- Meta firmware, OTA payloads, partition images or dumps (`*.img`, `*.bin`), vendor modules
  (`*.ko`), DTB/DTS extracts or device-tree property values beyond identifiers, `/persist` or
  calibration files, `Module.symvers` or CRC tables read from firmware, prebuilt Meta kernels.
- Valve images, rootfs chunks, packages, `.raucb` bundles, keyrings, verbatim configs, unit or
  rule files, server listings or manifests.
- Disassembly or decompiled output of any third-party binary.
- Verbatim third-party text beyond a short citation (one line, attributed), private messages,
  headset serials (J-90).
- **Public scope (J-90, J-106, J-157):** no unlock methods or results, no privilege-escalation
  steps or privileged-shell usage, no tools that need them, no Android-side
  workarounds, no device captures or run logs. Stating the project's assumption ("an
  already-unlocked headset") is allowed.
- Synthetic test data is allowed only if a generator in the repo produces it (e.g.
  `tools/kgate/fixtures/make_fixtures.py`) and it contains no vendor bytes.

**Enforcement:** the project's export tooling (private, because it names what it withholds)
computes the public export set and refuses an export that breaks these rules: withheld folders
and evidence, relays and rulings not prepared for publication, captures, firmware-type and
binary files outside generated fixtures, leftover merge conflicts, known device serials in any
letter case, and a list of out-of-scope terms. It also applies a fixed set of wording
redactions to every export, and reports any redaction that no longer matches.

## 5. Obligations for anything we distribute

Nothing is distributed today: the public repo holds sources and records only; images are built
locally in `build/` (gitignored). The moment FrameShift hands out **any binary** (image,
installer, initramfs, prebuilt tool), these apply **[LAWYER]**:

| component | licence | obligations |
|---|---|---|
| BusyBox (our images use the Ubuntu `busybox-static` 1.37.0 build) | GPL-2.0 | ship the GPL-2.0 text; the **exact corresponding source** of that build (the Ubuntu source package and its patches), either alongside or by a written offer valid for 3 years; keep its copyright notices; pointing to Ubuntu's archive alone may not be enough **[LAWYER]** |
| Linux kernel (Meta's GPL-2.0 kernel source plus our hook patches; or upstream) | GPL-2.0-only | ship or offer the complete corresponding source of the kernel and modules we built: Meta's tree at the exact tag, our patches, the `.config`, and the build scripts; GPL-2.0 text and notices |
| Meta's **prebuilt** kernel binary (current stage images repack the stock kernel from the device's own boot image) | GPL-2.0 binary from Meta, source correspondence [O] | **we do not redistribute it**: the installer builds the boot image on the user's machine from the user's own boot image. If ever redistributed, we would owe corresponding source we may not hold [O] |
| glibc, statically linked into our tools (e.g. fs-pattern, fs-supervise) | LGPL-2.1-or-later | LGPL text and notice; source of the glibc version used; and, for static linking, our **object files or source plus build scripts** so a user can relink with a modified glibc (our sources are public, which helps) **[LAWYER]** |
| FOSS packages from Valve's repositories (D6) | each package's own licence | per-package licence audit from the actual files, not metadata labels (FS-R-011 §7 D3); notices and source as each licence requires |
| AOSP tools used at build time (e.g. `mkbootimg`, `avbtool`) | Apache-2.0 | none while only used locally; licence and NOTICE if ever shipped |
| our own code | §6 | licence text, NOTICE, SPDX headers |

Every distributed artefact gets: a `LICENSES/` folder with each licence text, a third-party
notice file listing every component with version, licence and source location, and a
`SOURCES` record (hash-pinned) generated by the build. A release with any `[O]` row in its
component list is not shipped.

## 6. Licence for our own code — decided (PM, J-157)

| what | licence |
|---|---|
| tools, host scripts, on-device services and bridges (userspace), build scripts, test fixtures and records | **Apache-2.0** (unchanged from J-90; the public `LICENSE`) |
| kernel patches (`kernel-patches/`) and FrameShift's own kernel modules | **GPL-2.0-only** |
| documentation (Markdown files and other prose, including relays, rulings and the journal) | **CC-BY-4.0** |

Notes:
- **pid.codes:** a USB product ID from pid.codes needs a public open-source licence (J-152,
  PD-8c). Apache-2.0 is expected to qualify; **acceptance is to be confirmed** with pid.codes.
- Apache-2.0 code cannot be combined into a GPL-2.0-only work (the FSF considers them
  incompatible), so kernel-side code is GPL-2.0-only from its first line; userspace bridges talk
  to it only through UAPI. **[LAWYER]**: confirm they stay separate works.
- The CC-BY-4.0 legal code is in the public tree (`LICENSES/CC-BY-4.0.txt`, added with the PM's
  approval, J-166); the export refuses if it is missing.
- **SPDX plan:** new source files get an `SPDX-License-Identifier` header from now on
  (`Apache-2.0`, or `GPL-2.0-only` for kernel code). Existing files keep their bytes for now,
  because their SHA-256 values are pinned in build records, sign-off sheets and relay
  manifests; headers are added in one sweep when a stage is next rebuilt and re-pinned, with
  `files.tsv` as the licence record meanwhile.
- A short `CONTRIBUTING` with the Developer Certificate of Origin.
- Options considered (for the record): MIT instead of Apache-2.0 (no patent grant; relicensing
  published files needs every contributor's consent); GPL for userspace (copyleft, more friction
  for vendors; GPL-3.0 cannot enter a GPL-2.0-only kernel).

## 7. The per-file record

- `docs/provenance/files.tsv`: one row per file in the **current public export set**, columns
  `path`, `category`, `licence`, `source/notes`. A note starting `FLAG:` is a pre-export
  problem; `[O]` marks anything unclear.
- A private generator (part of the export tooling) computes the export set, classifies each
  file by ordered rules, scans its exported bytes, and reports files that are unrecorded,
  uncategorised, flagged, refused, stale or drifted. It is run before every export round and
  every commit that adds files; `files.tsv` is regenerated from it and its diff reviewed.
- Snapshot: the commit that last changed `files.tsv` gives the counts in its message.

## 8. Trademarks

**Nominative use only.** We name Meta, Quest, Valve, Steam, SteamOS and Steam Frame only to say
what FrameShift works with ("runs SteamOS on a Meta Quest 3"). Rules:

- no logos, icons, product imagery or trade dress of Meta or Valve;
- no wording that implies endorsement, partnership or official status;
- no trademark in the project, product, package, repository or domain name (FrameShift is
  fine); no "Steam"/"Quest" in our binary or service names exposed to users;
- marks used as adjectives, sparingly, with the notice below in the README and in every
  release.

**Standard notice (boilerplate for the README and any release notes; PM, J-156):**

> Meta and Quest are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and Steam Frame
> are trademarks of Valve Corporation; other names are the property of their respective owners.
> FrameShift is not affiliated with or endorsed by them.

`NOTICE` and the README carry this notice and the J-157 licences.
**[LAWYER]**: check the wording and the nominative-use rules.

## 9. Pre-export review (2026-10-14)

A full trial export was scanned for binary content, file types, verbatim third-party text,
copyright and licence markers, disassembly, quotes, device serials and out-of-scope terms, and
reviewed adversarially. What was found (device evidence and dumps, verbatim Valve server
output, firmware readouts, run logs, out-of-scope wording, literal NUL bytes in two documents)
is withheld or redacted by the export tooling, which now refuses any recurrence. The per-file
details are kept in the private record.

Still open [O], for the lawyer: `devices/quest3/stage3d/modules.load.v66` (our list of 95
module names, within J-123) and the `gpl:data` tables.

## 10. Pre-release checklist for the lawyer

Before the next public export that adds code, and before any binary release:

- [ ] **Origin categories (§2):** agree the categories, especially whether `observed:*` readouts
      (identifiers, header fields, DT property values, module lists, hashes) and `gpl:data`
      tables are free of third-party copyright or GPL obligations.
- [ ] **Pre-export review (§9):** confirm the withholding and redactions (private record).
- [ ] **Clean-room rules (§3):** adequate for an AI-assisted project? Is an AI-written bridge
      that read GPL kernel code for interface facts still free to be Apache-2.0?
- [ ] **Our licences (§6, J-157):** Apache-2.0 code, GPL-2.0-only kernel parts, CC-BY-4.0 docs;
      DCO; patent grant; pid.codes eligibility (to be confirmed).
- [ ] **Kernel route (e′):** modified Meta GPL modules: confirm GPL-2.0 compliance plan and that
      Meta's published source matches the binaries we build against [O].
- [ ] **Distribution obligations (§5):** BusyBox (Ubuntu build) source; kernel corresponding
      source; static glibc relinking; FOSS packages from Valve's repos (D6); format of the
      third-party notice file and written offers.
- [ ] **Never-redistribute model (§2.8, §4):** reading Meta firmware and calibration from the
      user's own device at install time, and building the boot image on the user's machine from
      the stock kernel: any issue under Meta's device terms of service?
- [ ] **Valve:** fetching SteamOS from Valve's servers on the user's behalf; the backup-image
      EULA's personal-use grant and the runtime-overlay question (FS-R-011 §7); our layer beside
      an unmodified rootfs.
- [ ] **Trademarks (§8):** the standard notice; nominative-use rules; the project name.
- [ ] **Interoperability and anti-circumvention:** the project assumes an already-unlocked
      headset and publishes no unlock material (J-90, J-106); confirm that reading the device
      and re-hosting the OS raise no DMCA §1201 / EU Software Directive art. 6 issue.
- [ ] **Patents:** codecs, display or tracking techniques in bridges [O].
- [ ] **Data protection:** no serials, personal data or private messages in the public record.
- [ ] **Credits:** consent before naming contributors (private list; J-123 open decisions).
