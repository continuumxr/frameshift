# SteamOS update channels (Steam Frame, with Steam Deck context)

Research for FS-R-011 §7 D7 and the PM release policy (2026-10-07:
FrameShift releases only from Valve's `stable` channel; `beta` maybe later
as opt-in). Agent pass, 2026-10-12. **Unreviewed.**

Tags: **[M-static]** read by us from a file or listing; **[D]** deduced
from code or config we read; **[C]** claimed by a source we did not verify
end to end (press, summaries, other docs); **[O]** open.

Method: read-only inspection of WSL `~/sfroot-full` (rootfs build
`20260922.6152327`); public web pages; prior repo records (FS-A-002 §3,
FS-A-003 §5a, `valve-image-slot-in.md` §1, `devices/quest3/stage2a/T1-PINS.md`).
Nothing downloaded, executed or sent to a device. `client.conf` server
URLs and credentials are **not** reproduced; only its branch and variant
lists are quoted.

---

## 1. The four things D7 says to keep apart

| question | where the answer lives |
|---|---|
| **Signature authentication** | CMS signature of the `.raucb` against a RAUC keyring: `trusted_keys/` (`CN=steamdeck-images`, the "stable" key) or `development_keys/` (`CN=steamos-dev-images`) |
| **Manifest branch** | the `branch` field of the server-side `*.manifest.json` for that build |
| **Official recovery provenance** | the file is the one Valve serves on its public download page |
| **Public release designation** | Valve's Steam news post / patch notes naming the version and channel |

They can disagree; §4 shows that they do for the recovery image.

## 2. Channels the Frame client knows

**[M-static]** Package `steamos-customizations-deckard` ships two atomupd
configs:

| file | `Variants` | `Branches` | `BranchesDev` |
|---|---|---|---|
| `/etc/steamos-atomupd/client.conf` (the one with service credentials) | `vr` | `stable;rc;beta;bc;preview;pc;main` | `rc;beta;bc;preview;pc;main` |
| `/usr/lib/steamos-atomupd/client.conf` (no credentials) | `vr` | `stable;rc;beta;bc;preview;pc;main` | `main;staging` |

For comparison, the Deck test data shipped in `atomupd-daemon`'s installed
tests has `Variants = steamdeck;vanilla`, same `Branches`, and
`BranchesDev = pc;main;staging` [M-static].

**[D] What `BranchesDev` does** (strings of `/usr/lib/atomupd-daemon`,
MIT, `gitlab.steamos.cloud/holo/atomupd-daemon`): selecting a branch in
`BranchesDev` makes the daemon trust `/etc/rauc/development_keys`
("Trusting the dev keys because of the selected branch …"); selecting one
outside it disables them ("Images in branch … shouldn't be signed with dev
keys, disabling them"). A `remote-info.conf` from the server can replace the
known branch lists. Which of the two files governs on a device, and what
the server's remote info says, is **[O]**. FS-A-003 §5a measured the result
that matters: a 0.4.4 `beta` bundle verifies **only** against the dev key,
and only `stable` and `goldmaster` bundles verified against the stable key
[M-static, one bundle re-checked; rest from the research pass].

| channel | what it is | who it's for | signing (Frame) | how selected |
|---|---|---|---|---|
| `stable` | public release; Valve news posts without "Beta" (e.g. "SteamOS 0.4 for Steam Frame", 2026-10-08, "released to all users") [C] | everyone; the image default | stable key `CN=steamdeck-images` (2021 cert, same CN as the Deck) [M-static] | default (`default_update_branch: "stable"` in the image's `manifest.json`) [M-static] |
| `rc` | release candidate for stable [C, from naming] | Valve internal / testers [C] | dev key (in `BranchesDev`) [D]; not checked per build [O] | hidden; dev/advanced only [C] |
| `beta` | public beta; Valve posts titled "SteamOS 0.4.x Beta for Steam Frame" [C] | users who accept testing builds [C] | dev key [M-static for 0.4.4] | Settings → System → System Update Channel [C, Valve announcement page via summary] |
| `bc` | beta candidate [C, naming] | internal [C] | dev key [D] | hidden [C] |
| `preview` | Deck: earliest public OS testing channel ("SteamOS 3.x Preview") [C]. Frame: no Valve post found using it [O] | testers who accept breakage [C] | dev key [D] | Deck: same menu; whether the Frame UI offers it is [O] |
| `pc` | preview candidate [C, naming] | internal [C] | dev key [D] | hidden [C] |
| `main` | development head; e.g. 0.5.5 `20261007.6021410` was `main` while 0.4.4 was beta (FS-A-002 §3, J-07) [M-static] | Valve developers; community calls it the most experimental [C] | dev key [D] | Deck: Developer → "Show Advanced Update Channels", then OS Update Channel → Main [C] |
| `staging` | listed only in the `/usr/lib` `BranchesDev` and as a `vr/staging/` directory [M-static] | internal [C] | dev key [D] | `steamos-select-branch staging` accepts it [M-static] |
| `oobe/`, `goldmaster/`, `mr/` | server directories, not client branches [M-static]. `oobe/` holds image records for recovery/OOBE builds; `goldmaster/` is likely the factory image line [C]; `mr/` unknown [O] | — | goldmaster bundles stable-signed (FS-A-003 §5a) [C, not re-checked] | not selectable |

Notes:
- **Branch selection plumbing [M-static]:** `steamos-select-branch`
  (deprecated wrapper) maps legacy `rel` ↔ `stable` and calls
  `atomupd-manager switch-branch`; `steamos-update` calls
  `atomupd-manager check/update`. The daemon stores the choice in
  `/etc/steamos-atomupd/preferences.conf` (legacy `/var/lib/steamos-branch`);
  neither exists in the recovery rootfs, so the manifest default (`stable`)
  applies [D]. The Steam UI drives the same daemon over D-Bus [C].
- **Branch is not a property of the build [M-static, `image.py`]:** Valve's
  own comment says branch is not stored in os-release "because images can
  be promoted to different branches after they have been built". A build's
  manifest branch can therefore change; re-check at ingest, never cache.
- **"More stable branches too" [M-static, `imagepool.py`]:** the server can
  offer a client builds from more stable branches as well
  (`BranchesToConsider`), so a beta device can land on a stable build.
- **`skip: true`** marks an image that is in the pool but is never an update
  candidate (`should_be_skipped`) [M-static].
- **Deck history [C]:** SteamOS 3.3 notes (2022-08-02) defined Stable as the
  "recommended experience for most users", Beta = client beta + stable OS,
  Preview = client beta + OS beta. Later Deck posts treat Beta and Preview
  as separate OS channels; the mapping has changed over time. Deck legacy
  variants were `steamdeck` (= stable) and `steamdeck-<branch>` [M-static,
  `convert_from_legacy_variant`].
- **Valve's public source:** the `gitlab.steamos.cloud` project pages were
  behind a bot check and were not read [O]; licences from the pacman DB:
  atomupd client LGPL-2.1, daemon MIT, customizations LGPLv2+ [M-static].

## 3. What Valve recommends for general users

- Deck: Stable, "recommended experience for most users" (Valve's 3.3 notes,
  as reproduced by steamdeckhq.com) [C].
- Frame: the image ships `default_update_branch: "stable"` [M-static];
  Valve presents beta as an opt-in under System Update Channel and released
  0.4 "to all users" on 2026-10-08 [C]. No Frame page found that ranks the
  channels explicitly [O]. **[D]** Stable is Valve's default and its
  recommendation for general users on both devices.

## 4. The official recovery image and the channels

Image: `steamframe-oobe-repair-20260922.5153644-0.3.0.img` (the
`?ver=steamframe` download; EULA "SteamOS and Steam Client Back-Up Image",
personal use, no checksum on the page [C, fetched 2026-10-12]).

| layer | value | source |
|---|---|---|
| rootfs build | `20260922.6152327`, 0.3.0, variant `vr` (`/usr/lib/os-release`, atomupd `manifest.json`) | [M-static] |
| server manifest for that rootfs build | branch **`rc`** (listing 2026-10-07) | FS-A-002 §3 [M-static] |
| OOBE record | `/etc/os-release` `BUILD_ID=20260922.5152327`; `vr/oobe/20260922.5152327/` manifest: branch **`main`**, 0.3.0, `"skip": true` | slot-in §1.1 [M-static] |
| on-disk update default | `default_update_branch: "stable"`, no `branch` field (so atomupd treats it as `stable`) | [M-static] + [D] `image.py` |
| marker | empty `/etc/steamos-oobe-image` | T1-PINS §1 [M-static] |
| stable-signed 0.3.0 builds | `20260918.6125208`, `20260922.6101926`: **not** the recovery rootfs | FS-A-003 §5a [C, research pass] |
| signer of the `6152327` rc bundle | not checked | [O] |

Reading:
- **[D]** "main" in the OOBE manifest does not mean the OS is the `main`
  development head: the rootfs inside is the 0.3.0 build that the server
  filed under `rc`, the same version as the stable 0.3.0 builds.
- **[C]** The OOBE record is filed under `main` with `skip: true` so the
  update pool knows the build but never offers it as an update; that is
  bookkeeping, not a release designation. Not confirmed by Valve.
- **[D]** It is also **not** a stable release: its rootfs build is not one
  of the stable-signed builds and its manifest branch is `rc`. It is
  officially provided, but by branch it is rc content packaged as OOBE.
- **[D]** On a real Frame it is a bootstrap: it tracks `stable` from first
  boot and atomupd moves it to the current stable build. In FrameShift,
  atomupd never runs, so our updater has to do that step.

## 5. Recommendation (plain language)

- **Update channel for general users: Valve `stable` only.** Accept a build
  only when all three hold: its CMS signature verifies against the stable
  key anchored in our repo (not fetched with the bundle); its server
  manifest says `branch: stable` at ingest time; and a Valve Steam news post
  names that version as a non-beta release. Never trust the dev key;
  `rc`, `bc`, `pc`, `preview`, `main` and `staging` are excluded. A later
  opt-in `beta` would need the dev key and its own policy decision.
- **First-install base: a stable-signed, stable-branch bundle rebuilt on the
  user's machine (route U1)**, i.e. today the 0.4 stable build once
  confirmed. Use the recovery image (R1) only if the PM grants the explicit
  D7 exception for that exact file, labelled "official recovery, rc/OOBE
  content", and only as a bootstrap our updater immediately replaces with
  the current stable build before general use.

**Evidence still needed:**
1. The 0.4 stable build ID, its manifest (`branch: stable`) and a stable-key
   signature check, matched to Valve's 2026-10-08 post (small metadata
   fetch; needs PM approval per slot-in Phase 0.2).
2. The signer of the `6152327` rc bundle, and whether the recovery
   `rootfs-A` equals that or any published slot image (Phase 0.2).
3. Which `client.conf` and what server `remote-info.conf` govern
   `BranchesDev` on a device.
4. Whether the Frame UI offers Preview or advanced channels.
5. Valve's intent for third-party use of the `vr/` update path (slot-in
   §1.2), unchanged.

## 6. Sources

Local (read-only, `~/sfroot-full`): `etc/steamos-atomupd/{client.conf,manifest.json}`
(branch/variant keys only), `usr/lib/steamos-atomupd/client.conf`,
`usr/bin/{steamos-select-branch,steamos-update}`, strings of
`usr/lib/atomupd-daemon`, `usr/lib/python3.12/site-packages/steamosatomupd/{image.py,imagepool.py}`,
`etc/rauc/{trusted_keys,development_keys}` certificate subjects,
`usr/lib/holo/pacmandb/local/*/{desc,files}`, `usr/lib/installed-tests/atomupd-daemon-0/data/`.

Online (accessed 2026-10-12):
- Valve, "SteamOS 0.4 for Steam Frame", https://store.steampowered.com/news/app/4165890/view/675134162359812787 (body not rendered; details via https://steamcommunity.com/app/4165890/announcements/detail/527161296156696117) [C]
- Valve, "SteamOS 0.4.3 Beta for Steam Frame", https://store.steampowered.com/news/app/4165890/view/675133527946166416 (title only)
- MIXED, https://mixed-news.com/en/steamos-0-4-steam-frame-all-users-error-17-steamvr-beta/ [C]
- GamingOnLinux, https://www.gamingonlinux.com/2026/10/steamos-0-4-5-beta-for-steam-frame-and-steam-client-update-for-frame-released/ [C]
- Valve download page, https://store.steampowered.com/steamos/download/?ver=steamframe (EULA, no checksum)
- SteamOS 3.3 notes as reproduced, https://steamdeckhq.com/news/steam-deck-client-update-and-steamos-3-3-8-2-2022/ [C]
- Main channel how-to, https://steamdeckhq.com/news/steamos-3-7-makes-first-appearance-steam-deck/ [C]
- `gitlab.steamos.cloud/steamos/steamos-atomupd`, `…/atomupd-daemon`: bot check, not read.

Repo: FS-A-002 (private review record) §3, FS-A-003 (private review record) §5a,
`docs/research/valve-image-slot-in.md` §1, `devices/quest3/stage2a/T1-PINS.md`,
FS-R-011 (private review record) §7 D7, `docs/PROJECT_SETUP.md` release policy.


## 7. Addendum: SteamOS 0.4 stable metadata (PM-approved fetch, 2026-10-12)

Files and hashes: `docs/research/steamos-stable-0.4-metadata/` (`FETCH-LOG.txt`).
Public unauthenticated URLs only; no credentials; no bundle, chunk or image
bytes. **Unreviewed.**

- **Build [M-static]:** `vr/20261007.6125817/deckard-stable-20261007.6125817-0.4.5.manifest.json`
  (361 B, sha256 `22625b88…1f6260`): `branch: "stable"`, `version: "0.4.5"`,
  `buildid: "20261007.6125817"`, variant `vr`, arch `aarch64`, gitsha
  `4b4cd26b…`, SteamVR 2.18.2. Server Last-Modified 2026-10-08 23:21:16 UTC.
  Files in that directory carry a `deckard-stable-` prefix; the 17 newer build
  directories are all `deckard-<build>-0.5.5` (dev) [M-static, listings].
- **Release designation [M-static, Steam Web API]:** "SteamOS 0.4 for Steam
  Frame", posted 2026-10-08 23:23:09 UTC, "released for all users"
  (https://store.steampowered.com/news/app/4165890/view/675134162359812787;
  API gid `1846018067931649`). Its notes include the 0.4.5 beta's only new
  item (headset chroma fix). **[D]** The post names "0.4", the build is 0.4.5,
  promoted to stable two minutes before the post: this is the build the post
  announces. Valve does not state the build ID in the post.
- **Signature [O]:** no detached signature file exists; RAUC's CMS signature
  is in the `.raucb` trailer (bundle 2,283,618 B, HEAD only). Reading it needs
  an HTTP Range read of part of the bundle, outside the approved scope, so it
  was not fetched and the stable-key check is **not done**. Anchor ready:
  `~/sfroot-full/etc/rauc/trusted_keys/ba942c60.0`, `CN=steamdeck-images`,
  SHA-256 `D5:62:FE:FE:…:59:B6:02:D9`.
- So of §1's four checks: manifest branch **stable** and public designation
  **match**; signature authentication **open** pending PM decision.

## 8. Addendum: 0.4.5 stable bundle signature check (PM-approved, 2026-10-12)

Details, commands and hashes: `docs/research/steamos-stable-0.4-metadata/SIGNATURE-CHECK.txt`.
One public download, no credentials; the bundle itself is kept only in the
gitignored `firmware/valve/steamos-0.4.5-stable/` and is never committed.
Nothing from it was run. **Unreviewed.**

- **Bundle [O]:** `deckard-stable-20261007.6125817-0.4.5.raucb`, 2,283,618 B,
  sha256 `e3d14c21…52bcbb8d`; Last-Modified and ETag match the earlier HEAD.
  RAUC **plain** format: squashfs (padded to 2,281,472 B), then a 2,138 B
  detached CMS signature, then an 8-byte size.
- **Signature [O]:** `openssl cms -verify` with the payload as detached
  content **succeeds** against the stable root `CN=steamdeck-images`
  (`ba942c60.0`, SHA-256 `D5:62:FE:FE:…:59:B6:02:D9`). The signer is a
  Frame leaf key `CN=frame-images` (SHA-256 `8A:6B:D4:22:…:21:FA:BA`,
  issued 2026-02-05 by `steamdeck-images`). It **fails** against the dev
  key `CN=steamos-dev-images`, and fails when one payload byte is changed.
- **Manifest [O]:** `compatible=steamos-aarch64` (matches the Frame's
  `system.conf`), `version=20261007.6125817` (matches the build ID in the
  `.manifest.json`), `format=plain`, one image `rootfs.img.caibx` (casync
  index) for a 10 GiB rootfs, sha256 `692b998b…119bcc3c` (recorded, not
  checked: chunks not fetched).
- So all of §1's checks now pass for this build: manifest branch **stable**,
  public designation **matches**, signature **authentic (stable key)**.
