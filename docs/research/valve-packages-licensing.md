# Valve package repositories, Holo Core and redistribution — research for a Chair ruling

*Edited for publication: names and links removed or paraphrased.*

Agent report, 2026-10-10. Online research plus local docs. **This is research
to inform a Chair ruling. It is not legal advice.** No lawyer has reviewed it.
Licence and terms texts were read; I did not consult any lawyer or regulator.

**Tags:**
- **[M-static]**: what I saw myself on a public page or listing (URL and date given).
- **[C]**: a claim made by an external source (terms text, vendor statement, news, community).
- **[D]**: my inference.
- **[O]**: unknown.

Where a point rests on a **terms or licence text**, this report says so. Where
it rests only on **community opinion or news**, it says that too.

**Chair rulings since this report (FS-R-011 §7, 2026-10-11, J-104):**
- **Licensing correction (D1/D3/D6).** Valve's Frame-specific download page
  (`https://store.steampowered.com/steamos/download/?ver=steamframe`)
  currently presents the **backup-image EULA** (the "SteamOS and Steam
  Client Back-Up Image" terms). That replaces this report's "written for the
  Deck image; no Frame EULA found" (§2.2). Its personal-use grant and
  redistribution restrictions **do not settle the runtime-overlay
  question**, and the text states **no Frame-only hardware restriction**;
  none is to be inferred.
- **D6.** FOSS rights follow each component's own licence, not whether
  Valve or Collabora built it; there is no blanket basis for calling all
  repository-built FOSS packages non-redistributable. Mixed-image
  redistribution restrictions do not erase separate FOSS grants; public
  package hosting grants nothing for proprietary components. Whether
  licence-audited FOSS packages fall within an exception to the PM's "no
  Valve binaries" policy (PROJECT_SETUP §6A item 9) is a **PM decision,
  open [O]** (§5.1 option (b), §5.2 item 2).
- **D3.** Permission is determined from actual per-file/package licences,
  not authorship or a metadata label alone (§2.1's licence fields are
  labels, an input to that audit).
- **"Our own code only" is inaccurate** for any image we ship that contains
  BusyBox, a kernel or statically linked glibc: their source, licence,
  notice and linking obligations apply (§5.3).
- **D7.** A trusted "stable" signing key does not by itself establish a
  stable manifest branch; keep signature authentication, manifest branch,
  official recovery provenance and public release designation distinct
  (§5.2 item 3).

**Method and limits:**
- I fetched HTML directory listings, a few small text configs (`pacman.conf`,
  mirrorlist) and **one repository metadata index**:
  `deckard-arch-hotfixes-release-0.4.db.tar.xz`, 109,892 B. That index is
  what any `pacman -Sy` downloads. I read it for the package licence fields.
- I downloaded **no packages, no rootfs and no images**, and installed nothing.
- Nothing behind authentication was attempted. No token was used. In
  particular, the Frame's own `DO_NOT_SHARE` repo token (community-quest-repos-2
  §7, S14) was not used.
- `gitlab.steamos.cloud` and `gitlab.archlinux.org` block automated fetches
  (Anubis). Their README and licence files were therefore **not read**.

---

## 0. Summary

1. **Public reachability.**
   - Valve's package host serves the Frame ("deckard") repositories, the
     Holo Core preview and the Deck mirror **without credentials**. The host
     root and `robots.txt` return HTTP 401 [M-static].
   - No terms of use, README or licence notice is posted on the listings
     [M-static].
   - Valve's SteamOS (Deck) EULA calls the **Deck** Arch mirror "publicly
     available ... under the open source licenses referenced there" [C, terms
     text]. No equivalent statement was found for the `archlinux-deckard*`
     (Frame) paths [O].
   - **Being reachable is not a licence grant** [D].
2. **The Frame stack contains proprietary components.** Valve's own package
   metadata labels the following:
   - `deckard-steam-rel` and `deckard-steamvr-rel`: "LicenseRef-steam-subscriber-agreement, Proprietary";
   - about 17 `deckard-*` hardware packages: "Proprietary";
   - `linux-firmware-deckard`: "custom";
   - `widevine` and `google-chrome`: "custom";
   - the Frame kernels `linux-618-deckard` and `linux-72-deckard`: licence
     field `GPL-2.0-only no-source-release` (package metadata as published) [M-static].
3. **Valve's terms text forbids redistributing the Steam client without a
   separate licence.**
   - SteamOS EULA §1.1–1.2: "non-redistributable"; redistribution, "including
     packaging ... or pre-installing ... on hardware, is prohibited without
     first obtaining a separate license from Valve" [C, terms text].
   - Steam Subscriber Agreement §2.G (revised 2026-09-10): no copying or
     reproduction without prior written consent [C, terms text].
   - The only redistribution grant found covers the small **Linux bootstrapper**
     (install agreement, 2013). Its conditions: shipped in its entirety,
     "bootstrap" files unmodified, no fees, not integrated. I found this text
     only in **secondary sources** [C].
4. **Holo Core** is the public aarch64 Arch port by Valve and Collabora,
   announced 2026-07-17.
   - It contains **no Steam, SteamVR or `deckard-*` packages** [M-static].
   - It publishes about 4,217 source tarballs [M-static].
   - It is a **preview** snapshot, not the Frame's shipped base, and not a
     "stable" channel [C/D].
5. **Ranking by legal safety [D]:**
   1. **(a)** our code plus an on-device fetch from Valve;
   2. **(b)** a FOSS-only base, with full GPL compliance done by us;
   3. **(c)** full images, **only** with a written licence from Valve, i.e.
      after **(d)**.

   **(d)** costs nothing and should run in parallel. **(c) without
   permission: do not.**

---

## 1. Valve's public SteamOS package repositories

### 1.1 Hosts and paths (observed 2026-10-10)

| URL | HTTP | Contents [M-static] |
|---|---|---|
| `https://steamdeck-packages.steamos.cloud/` | **401** (nginx "Authorization Required") | root index gated; `robots.txt` also 401 |
| `…/archlinux-mirror/` | 200 | Deck-era repos: `core-*`, `extra-*`, `community-*`, `jupiter-*`, `holo-*` (variants `-main`, `-rel`, `-staging`, `-beta`, `-3.x`); e.g. `jupiter-main/os/x86_64/` and `holo-main/os/x86_64/` return 200 |
| `…/archlinux-deckard/archlinux/main/` | 200 | Frame base: `core`, `extra`, `multilib` (empty for aarch64), `*-debug`, `extra-archive`, **`sources/packages/` (3,131 `.src.tar.gz`)**, `pacman.conf`, `pacman.mirrorlist`, **`system.rootfs.zst` 316.5 MiB, 2026-10-05**. core 271 and extra 4,126 package files |
| `…/archlinux-deckard-hotfixes/` | 200 | `goldmaster/`, about 55+ `mr-NNNN/` merge-request repos, `release/…` |
| `…/archlinux-deckard-hotfixes/release/0.4.x/` | 200 | repo `deckard-arch-hotfixes-release-0.4`, 773 entries in the index (477 non-debug package names). Its **`source/` holds 1 tarball** (`steamdeck-kde-presets-3.8.3-9.src.tar.gz`) |
| `…/holo-core-aarch64-preview/` | 200 | `mash-20251118/`, `.2/`, `.3/` |
| `…/holo-core-aarch64-preview/mash-20251118.3/` | 200 | `core` (254), `extra` (4,306), `*-debug`, **`sources/packages/` (4,217 `.src.tar`)**, `system.rootfs.zst` 367.1 MiB (2026-07-10) |
| `…/misc/` | 200 | e.g. `steam-snapshots/` (see Jovian, §3) |
| `https://holo-packages.steamos.cloud/` | 401 at root | the Collabora post names it as the Holo Core binary host |
| `https://steamdeck-images.steamos.cloud/vr/` | 200 | Frame RAUC bundles (FS-A-002 §3) |

Further observations:
- The repo `pacman.conf` files ship with **`SigLevel = Optional`**, so
  signatures are not enforced [M-static]. This is an integrity concern for any
  installer we write (§5).
- The `archlinux-deckard` mirrorlist points to
  `holo-packages-ci.steamos.cloud`, a CI host [M-static].
- **QK2** (machachu56/quest-kexec-q2, branch `quest2-port`, `tools/steamos/pacman.conf`, read 2026-10-10) [M-static]:
  - It uses `archlinux-deckard/archlinux/main` for core and extra.
  - It uses `archlinux-deckard-hotfixes/release/0.4.x` for Steam, SteamVR,
    FEX, gamescope and Mesa.
  - Its `tools/steamos-rootfs.sh` fetches `…/archlinux-deckard/archlinux/main/system.rootfs.zst`
    and installs `deckard-steam-rel` on top. It then unpacks
    `/usr/lib/steam/steam.tar.zst` into the user's home.
  - It contains **no credential**.

### 1.2 Access, gates, terms

- **No credential, token or click-through gate** stands in front of the paths
  above [M-static]. I attempted nothing behind the 401s.
- **The Frame device itself uses an authenticated repo.** Its image's pacman
  config carries a token marked `DO_NOT_SHARE` (community-quest-repos-2 §7,
  S14, from Q1 `docs/phase0-recon.md:22`) [M-static, local]. The open
  `archlinux-deckard*` paths therefore exist **alongside** a gated channel
  [D]. Whether Valve *intends* the open paths for public use is **[O]**.
- **No terms of use or licence notice** appears on any listing, and no README
  was found [M-static].
- **The only Valve terms text that names the package host** is the SteamOS
  (Steam Deck image) EULA at
  `https://store.steampowered.com/steamos/download/?ver=steamdeck`, read
  2026-10-10. It says:
  - SteamOS "is publicly available at https://steamdeck-packages.steamos.cloud/archlinux-mirror/ under the open source licenses referenced there";
  - the package licences and FOSS source are listed at `gitlab.steamos.cloud`;
  - SteamOS "includes ... third party software subject to proprietary licenses".

  [C, terms text.] This covers the **Deck `archlinux-mirror`** and does not
  mention the `archlinux-deckard` (Frame) or Holo Core paths [M-static].
  Applying it to the Frame paths is **[D] at best**.
- **The Steamworks Steam Frame debugging page** documents `pacman -S
  deckard-mesa-android-aarch64-debug` on the device. It names no repositories
  and states no terms [C]
  (`https://partner.steamgames.com/doc/steamhardware/steamframe/debugging`).
- **Conclusion [D].** The repos are *publicly reachable* and partly
  *described as public* (the Deck mirror). Nothing found makes them
  *redistributable as a whole*. Each package's own licence governs it (§2).

---

## 2. Licence makeup of a SteamOS / Holo rootfs

### 2.1 What Valve's own metadata says (Frame hotfix repo `release-0.4`, index of 2026-10-07)

I read the `%LICENSE%` field of every non-debug package (477 names) [M-static]:

| Class | Packages (examples) | Licence field |
|---|---|---|
| **Steam client** | `deckard-steam-rel` ("Steam rel client package") | `LicenseRef-steam-subscriber-agreement`, `Proprietary` |
| **SteamVR** | `deckard-steamvr-rel` | `LicenseRef-steam-subscriber-agreement`, `Proprietary` |
| **Steam (Arch-style)** | `steam` | `LicenseRef-steam-subscriber-agreement` |
| **Valve Frame hardware/userspace** | `deckard-hw-support`, `-charger`, `-display-tools`, `-eeprom`, `-fpga`, `-ftm`, `-iw-event-logger`, `-kitchen-sink`, `-led-control`, `-mte-utils`, `-power-monitor`, `-typec-logger`, `screenyhttp`, `softapmanager` | `Proprietary` |
| mixed | `deckard-boot-images` (Proprietary + OFL-1.1), `deckard-vulkan-layers-*-aarch64` (Proprietary + MIT) | |
| **Firmware** | `linux-firmware-deckard` (from `gitlab.steamos.cloud/deckard/deckardos/linux-firmware`) | `custom` |
| **Third-party proprietary** | `widevine` 4.10.2710.0 (Google CDM), `google-chrome` 150 | `custom`, `custom:chrome` |
| **Frame kernels** | `linux-618-deckard` (incl. `6.18.0+gfbdbca41fd45`, our build's kernel), `linux-72-deckard` | `GPL-2.0-only` `no-source-release` (metadata label) |
| older kernels | `linux-616-deckard`, `linux-617-deckard`, `deckard-linux-6.16-sm8650` | `GPL-2.0-only` |
| kernel modules | `linux-6xx-v4l2loopback-deckard` | `Proprietary` (upstream v4l2loopback is GPL-2.0; [D] metadata inconsistency) |
| Valve open source | `gamescope` (MIT), `deckard-steamvr-session` (MIT), `deckard-steamos-customizations` (MIT), `steamos-customizations-deckard` (LGPLv2+), `lepton-compat` (MIT) | open |
| Qualcomm driver | `deckard-qualcomm-graphics-driver-android-aarch64` | `Apache-2.0` (as labelled; source URL on gitlab.steamos.cloud) |
| Mesa builds | `deckard-mesa-*` | `custom` (upstream Mesa is MIT) |
| rest | Qt, KDE, bluez, bash, FEX, etc. | GPL, LGPL, MIT, BSD, Apache, as upstream Arch |

Notes:
- **`no-source-release` [M-static].** Valve's own packaging marks the Frame
  kernels "no-source-release". The hotfix repo's `source/` directory holds
  one tarball, and no kernel source is in it. FS-A-002 §6 already found no
  Frame kernel tree on gitlab.steamos.cloud.
  - [D]: whoever redistributes these kernel binaries takes on the GPL-2.0
    source obligation. FrameShift could not meet it, because the source was
    not found in the locations checked.
  - [O]: whether Valve provides the source on request or by other means.
- **Base repo (`archlinux-deckard/main`).** This is an Arch-derived FOSS
  distribution with a published source tree (3,131 tarballs, e.g. glibc
  2.43, systemd 259.3, linux-firmware 20260221) [M-static].
  - It also carries the usual Arch redistributable-but-non-free items:
    `linux-firmware-*` under per-file WHENCE terms, `nvidia-open-dkms`,
    `openh264`, `ffmpeg` [M-static names].
  - [D] `openh264`: Cisco's patent licence covers only Cisco-distributed
    binaries.
  - [D] `ffmpeg`: it contains patent-encumbered codecs. For a hobby project
    the patent exposure is low, but it is not zero.

### 2.2 Which proprietary parts carry redistribution restrictions (terms texts)

**SteamOS EULA "for SteamOS and Steam Client Back-Up Image"** (Deck image page, read 2026-10-10) [C, terms text]:
- §1.1 grants a "limited, non-exclusive, non-redistributable,
  non-sublicenseable" licence for personal use.
- §1.2: no copying, modifying or redistributing. Also: "Any redistribution
  ... including packaging ... with or pre-installing ... on hardware, is
  prohibited without first obtaining a separate license from Valve."
- The EULA also states: "You are responsible for complying with applicable
  third party licenses in your use and/or redistribution."
- ~~[D] It is written for the Deck image. The Frame has no published recovery
  image or EULA that I found [O].~~ *Superseded (FS-R-011 §7 licensing
  correction, J-104):* Valve's Frame-specific download page
  (`…/steamos/download/?ver=steamframe`) currently presents this
  backup-image EULA. Its personal-use grant and redistribution restrictions
  do not settle whether a runtime overlay is permitted, and it states no
  Frame-only hardware restriction (do not invent one). Valve's posture on
  redistribution is nonetheless unambiguous.

**Steam Subscriber Agreement** (`store.steampowered.com/subscriber_agreement/`, "last updated on September 10, 2026") [C, terms text]:
- §1.B: "Content and Services" include "the Steam client software".
- §2.A: licence for personal, non-commercial use.
- §2.G: may not "copy ... reproduce" without Valve's prior written consent,
  nor reverse engineer, modify, or "rent, lease or license" to others.
- §4.B: may not "tamper with the execution of Steam".
- [D] This matters even under option (a). FrameShift must not *patch* Steam
  or SteamVR binaries. Wrappers, environment variables and our own
  drivers/layers are the safer pattern. Whether running Steam on non-Valve
  hardware through our shims counts as "tamper[ing]" is **[O]**.

**Linux bootstrapper redistribution grant** ("Steam Install Agreement", Linux client, added 2013-02-07) [C, **secondary sources only**]:
- The text is reproduced in a reader comment on GamingOnLinux, 2013-02-08
  (`gamingonlinux.com/2013/02/steam-can-be-legally-packaged-in-any-distro/`),
  and reported by Phoronix.
- It grants a limited, terminable licence to reproduce and distribute the
  "Program", on these conditions:
  - distribute it in its entirety;
  - do not modify files with "bootstrap" in the name;
  - charge no fee;
  - do not integrate it with other software.
- I could not retrieve the current primary text [O].
- **Distributor practice consistent with it:**
  - Arch `multilib/steam` 1.0.0.87-3, licence
    `LicenseRef-steam-subscriber-agreement` (archlinux.org, updated
    2026-08-22) [M-static].
  - nixpkgs `steam-unwrapped` (source
    `repo.steampowered.com/steam/archive/stable/…`) is labelled
    `unfreeRedistributable` [M-static].
  - Debian ships `steam-installer` in **contrib** (version
    `1:1.0.0.87~ds-3`). It "downloads and installs the Steam client" instead
    of carrying it [C, packages.debian.org].
  - Fedora proper excludes Steam. It lives in RPM Fusion **nonfree** [C,
    secondary sources].
- **[D] Scope.** The grant covers the **small x86 Linux bootstrapper**.
  The full client self-updates after first run, on the user's machine.
  - Whether the grant covers `deckard-steam-rel` is **[O]**. That package is
    aarch64, carries a full `steam.tar.zst`, and is labelled SSA plus
    Proprietary.
  - Checking whether it contains an install-agreement file would require
    downloading it, which I did not do.

**Other components [D, general knowledge, not verified this session]:**
- **Widevine CDM:** redistribution needs Google's agreement.
- **Google Chrome:** governed by Google's terms.
- **`linux-firmware-deckard` ("custom"):** the terms are unknown [O]. They
  may include Qualcomm blobs under non-redistributable terms.
- **SteamVR (SSA):** the same posture as Steam.

**Trademark [D].** "Steam", "SteamOS" and "Steam Frame" are Valve marks.
Naming or branding an image so that it implies Valve endorsement is a
separate risk, independent of copyright.

---

## 3. Precedents

| Project | What it ships vs. fetches | Valve stance found |
|---|---|---|
| **HoloISO** (`github.com/holoiso-eol/holoiso`, archived **2024-02-12**) | ISO built from Valve's repos. README: "Most of the code and packages, are straight from Valve"; "includes Valve's pacman.conf repositories". Whether the ISO carried the Steam client is [O]. Successor is an "immutable" edition [C] | No takedown or Valve statement found [O]. End of life given as replacement by a new edition, not as legal reasons [C, news] |
| **ChimeraOS** (`ChimeraOS/chimeraos`, `manifest`) | Image installs Arch `steam` (the bootstrapper), `linux-firmware-valve` and others (`manifest:148,204`) [M-static]. The installer downloads the system image [C]; full client self-updates [D] | none found |
| **Bazzite** (`ublue-os/bazzite`, `Containerfile`) | Image installs `steam` (`:357`), Valve-derived `jupiter-*` and `steamdeck-*` packages, and a `bootstrap_steam.tar.gz` for gamescope-session (`:671`) [M-static]. Which repo supplies `steam` is [O] | none found. Ships widely without known Valve objection [C, news] |
| **Jovian-NixOS** | **Closest precedent for option (a).** `pkgs/steam-jupiter/unwrapped.nix` downloads `steamdeck-packages.steamos.cloud/misc/steam-snapshots/steam_jupiter_stable_bootstrapped_20251031.0.tar.xz` via `fetchurl` **on the user's machine at build time** [M-static]; no Valve binaries in the repo. Package licences: `jupiter-hw-support` MIT, `jupiter-fan-control` GPL-3.0+ [M-static]. Issue #587 (Frame aarch64, 2026-09-28) asked whether Valve's package-server binaries are acceptable and whether the Frame kernel source exists. **Closed "not planned" 2026-09-29, unanswered** [C] | none |
| **SteamFork** (`SteamFork/distribution`) | Fork of HoloISO. Project code MIT; "each component ... under its respective license"; runs its **own signed repos** [C]. Details [O] | none found |
| **Q1 / NQ1** (local, §8 of community-quest-repos-2) | Q1 publishes **no** `holo.img` because Steam/SteamVR "cannot be redistributed". NQ1 CI builds only the public Holo Core part and leaves Steam/SteamVR out [M-static, local] | — |

**Valve's statements on SteamOS for other hardware** [C, news]:
- CES 2025: SteamOS licensed to OEMs under "Powered by SteamOS" (Lenovo
  Legion Go S). **OEM pre-installation is a licensed programme**, consistent
  with EULA §1.2.
- SteamOS 3.7.8 (2025) adds "improved support for other AMD powered
  handhelds". Users may install Valve's own image on them.
- On ARM: Valve staff (kisak-valve, 2026-10-05, steam-for-linux #13689, via
  secondary report) restated "Steam for Linux is not currently supported on
  ARM based hardware".
- **No Valve statement was found on running the Frame userspace on
  non-Valve hardware, or on third-party Frame images** [O].
- **No Valve takedown** of any project above was found [O]. This is an
  absence of evidence, not evidence of tolerance.

---

## 4. Holo Core

- **What it is [C].** A "pure aarch64 port of Arch Linux ... the basis for
  the OS running on the Steam Frame". Built by Collabora with Valve.
  - Announced in the Collabora blog, Denis Pynkin, **2026-07-17**
    (`collabora.com/news-and-blog/news-and-events/building-an-arch-linux-aarch64-port-for-holo-core.html`).
    Also reported by Phoronix and GamingOnLinux.
  - Published "allowing anyone to begin to explore the port and experiment".
  - It is a snapshot of the Arch "state" repo at commit `97c0a0b47d15`, plus
    aarch64 changes.
  - The build tooling "is not yet ready to be published".
- **Published artefacts [C]:**
  - sources at `gitlab.steamos.cloud/holo/holo-core-aarch64-preview`;
  - binaries at `holo-packages.steamos.cloud/holo-core-aarch64-preview/mash-20251118`,
    mirrored at `steamdeck-packages.steamos.cloud/holo-core-aarch64-preview/`
    [M-static];
  - a container `registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base-devel`.
- **Licensing:**
  - The blog states **no licence or terms** [C]. Each package carries its
    upstream Arch licence [D].
  - `mash-20251118.3/sources/packages/` publishes 4,217 source tarballs
    [M-static]. These support GPL/LGPL compliance for anyone redistributing
    the binaries, subject to §5.3.
  - Package names include **no `steam`, `steamvr`, `deckard-*`, `holo-*` or
    `jupiter-*`** [M-static].
  - It does include `linux-firmware-*` (20251111), which is redistributable
    under WHENCE terms [M-static/D].
  - The `pacman.conf` uses `SigLevel = Optional` [M-static].
- **Relation to the Frame rootfs [D]:**
  - The Frame's base comes from the **`archlinux-deckard`** repos, a later
    snapshot. Its `main` holds glibc 2.43 and systemd 259.3 sources, with a
    rootfs from 2026-10-05.
  - The Holo Core preview `mash-20251118.3` has glibc 2.42 and a rootfs from
    2026-07-10.
  - Our Frame rc build (20260922) has systemd **257.7** (community-quest-repos-2
    §1.4). It matches neither `main` today nor, presumably, the preview.
  - QK2 calls the `archlinux-deckard/main` rootfs "Holo Core". That is a
    community label [C]. Whether Valve calls it Holo Core is [O].
  - The Frame-specific layer (hardware daemons, firmware, kernel, Steam,
    SteamVR, Mesa) comes from the `archlinux-deckard-hotfixes` repos, not
    from Holo Core. The Jovian issue #587 author makes the same observation
    [C].
- **Against the "Valve stable only" policy [D]:**
  - The Holo Core preview is explicitly a **preview**.
  - `archlinux-deckard/main` is a moving **main** branch.
  - `release/0.4.x` serves the **0.4** line. SteamOS 0.4.1 for the Frame was
    a **beta** on 2026-09-26 [C, news].
  - **None of these is self-evidently "stable".** The only artefact that
    carries a channel label is the signed RAUC bundle on
    `steamdeck-images.steamos.cloud/vr/`: its manifest has a `branch` field
    and is verifiable against `stable_keyring.pem` (FS-A-002 §3).
  - Whether a `branch: stable` Frame build exists today is [O]. (FS-A-002
    saw `rc` and `main`.)

---

## 5. Options for FrameShift, ranked by legal safety [D]

### 5.1 Ranking

**1. (a) Ship only our own code plus an installer that fetches Valve's packages on the user's device from Valve's public servers.**
- *Why safest:* FrameShift redistributes nothing of Valve's, and no GPL
  obligation arises for Valve's binaries (we do not convey them). This is the
  Jovian pattern and our own FS-A-002 §3 design.
- *Residual issues:*
  1. The user is bound by the SSA and EULA when the installer obtains Steam.
     The installer should **show Valve's terms (links) and require the user
     to accept them**, and should not pre-accept on their behalf.
  2. Do **not patch** Valve binaries on the device (SSA §2.G, §4.B). Use
     wrappers and our own drivers/layers.
  3. **Never** use the Frame's `DO_NOT_SHARE` token or any gated path.
     Using it would be unauthorised access, not public download.
  4. Valve may close the open paths at any time. This is an availability
     risk, not a legal one.
  5. Integrity: the repos use `SigLevel = Optional`. Prefer the signed RAUC
     bundle verified against `stable_keyring.pem` (also the cleanest fit for
     "Valve stable only"), or enforce `holo-keyring` signatures and pin hashes.
  6. Mass use of Valve's CDN for non-Valve hardware has no stated
     permission. Its legal weight is [O]; it is low as a copyright matter.
  7. Third-party testers: the images handed over contain no Valve binaries,
     which meets PROJECT_SETUP §6A item 9 on its face.

**2. (b) Ship an open-source-only base (e.g. Holo Core preview or `archlinux-deckard` core/extra FOSS) plus our code; Steam/SteamVR self-install via (a).**
- *Legal basis:* the FOSS licences permit redistribution.
- *Our obligations as distributor:*
  - **GPL/LGPL source for every binary we ship.** GPL-2.0 §3: accompany the
    binaries with source, or give a written offer valid three years. §3(c)
    pass-through applies only to non-commercial distribution *of a binary
    received with such an offer*. Valve's repos give no written offer, so
    **relying on a link to Valve's server is weak under GPLv2**. GPLv3 §6(d)
    allows a third-party server only if we ensure it stays available.
    **Safest: mirror the exact matching `.src.tar` files ourselves**, which
    the published `sources/` directories make possible.
  - Keep the licence texts. Keep the linux-firmware WHENCE and licence files.
  - LGPL: allow relinking (normally satisfied with shared libraries).
  - **Exclude:** every `Proprietary`/`custom`/SSA package listed in §2.1
    (`steam*`, `deckard-*` proprietary, `linux-firmware-deckard`, `widevine`,
    `google-chrome`, `deckard-mesa-*` until "custom" is resolved), and the
    `linux-*-deckard` kernels (`no-source-release`).
  - Consider excluding `openh264`, and builds of `ffmpeg` with
    patent-encumbered codecs.
  - Do not use "SteamOS" branding.
- *Policy question for the Chair [O]:* are Valve- or Collabora-**built FOSS**
  binaries "Valve binaries" under §6A item 9? The text is ambiguous. If yes,
  (b) collapses into (a). If no, (b) is permissible with the obligations
  above.
  *Ruled in part (FS-R-011 §7 D6, J-104):* FOSS rights follow the
  component's licence, not its builder; whether "Valve binaries" in §6A
  item 9 excludes licence-audited FOSS packages is now a **PM policy
  decision [O]**, not a Chair question. A FOSS-only base may be researched
  offline as a control/development base; it does not deliver the genuine
  Frame SteamOS experience.

**3. (d) Ask Valve** (in parallel with 1 or 2, at no cost).
- Ask for written permission covering redistribution of the Frame userspace,
  or use of the open repos by a non-Valve-hardware installer. Also ask about
  the Frame kernel source (`no-source-release`) and the `linux-firmware-deckard`
  terms.
- A written "yes" is the only route that makes (c) safe. Silence or "no"
  leaves (a)/(b).

**4. (c) Redistribute full images including Steam, SteamVR and the `deckard-*` proprietary packages.**
- **Prohibited by Valve's terms text without a separate licence** (EULA
  §1.2; SSA §2.G).
- It would also make us the GPL distributor of kernels whose source we have
  not located.
- **Do not do this without (d) succeeding in writing.**
- Note: even Q1's author declined to publish `holo.img` for this reason.

### 5.2 Suggested decisions for the Chair (to rule on)

*Outcome (FS-R-011 §7, J-104):* item 1: the runtime-adaptation architecture
was accepted (D1, an architecture, not a legal conclusion); item 2: FOSS
rights follow the licence, the policy exception is a PM decision (D6, [O]);
item 3: direction accepted, but signature, manifest branch, recovery
provenance and release designation are distinct, and the main/OOBE recovery
input needs an explicit PM exception (D7, [O]); hotfix/package-repository
exclusion is a reasonable scope choice, not proof every package there is a
preview. Items 4–5 were not ruled on.

1. Whether option (a) is the default distribution model. This includes the
   rule "no Valve proprietary binary leaves Valve's servers except onto the
   end user's own device".
2. Whether "Valve binaries" in §6A item 9 covers Valve-built **FOSS** binaries
   (this decides whether (b) is allowed).
3. What "Valve stable only" means at package level. Proposal [D]: only
   artefacts from a signed RAUC bundle whose manifest says the stable branch.
   Explicitly **not** `archlinux-deckard/main`, the 0.4.x hotfixes, or the
   Holo Core preview.
4. Whether to authorise a written query to Valve (d), and through which
   channel.
5. The QK2 question (FS-A-010 §7.4):
   - an image **built** QK2's way and **shared** would include
     `deckard-steam-rel`, the base rootfs and other packages;
   - that is redistribution of SSA/Proprietary packages, i.e. option (c), and
     not permitted without a Valve licence [D];
   - QK2's *script*, run by each user on their own machine, is a form of
     option (a).

### 5.3 GPL source obligations for anything we do redistribute (checklist) [D]

- Our kernel builds (Meta-derived, GPL-2.0): full corresponding source, the
  config and build scripts, either shipped with the image or offered in
  writing for three years.
- Our initramfs (busybox GPL-2.0 etc.): same. This includes our stage
  boot images (BusyBox, the kernel they carry, and statically linked glibc
  in helpers such as `fs-pattern`; for static LGPL linking, the relinking
  obligation applies [D]). "Our own
  code only" is inaccurate for any such image (FS-R-011 §7 D6, J-104).
- Any FOSS userspace binaries we ship: matching source tarballs mirrored by
  us. Record the exact package versions in a manifest.
- GPL-2.0 code reused from QK/QK2: keep the licence and attributions, and
  publish our modifications.
- BSL-1.0 Monado code: keep the notice.
- Never ship binaries whose source we cannot produce (e.g. `linux-618-deckard`).

---

## 6. Unknowns [O]

- Whether Valve intends the unauthenticated `archlinux-deckard*` paths for
  public or third-party use. No notice was found, and a gated, tokened
  channel also exists.
- The current primary text of the Linux bootstrapper redistribution grant,
  and whether it covers `deckard-steam-rel` or aarch64 snapshots.
- The `linux-firmware-deckard` licence terms. The `deckard-mesa-*` "custom"
  licence.
- Whether the Frame kernel source is available on request ("no-source-release").
- The licence/README content of `gitlab.steamos.cloud/holo/holo-core-aarch64-preview`
  (blocked by Anubis).
- Whether HoloISO ISOs carried the Steam client. Which repo supplies Bazzite's
  `steam`.
- Any Valve statement on Frame userspace on non-Valve hardware. Any takedowns.
- Whether a `branch: stable` Frame RAUC build exists.
- How local law applies to the SSA (e.g. EU interoperability exceptions for
  reverse engineering). This is out of scope and would need a lawyer.

## 7. Sources (accessed 2026-10-10 unless stated)

- SteamOS EULA (Steam Deck image page): https://store.steampowered.com/steamos/download/?ver=steamdeck&l=english
- Steam Subscriber Agreement (rev. 2026-09-10): https://store.steampowered.com/subscriber_agreement/
- Valve package host listings: https://steamdeck-packages.steamos.cloud/archlinux-mirror/ ; …/archlinux-deckard/archlinux/main/ ; …/archlinux-deckard-hotfixes/release/0.4.x/ (index `deckard-arch-hotfixes-release-0.4.db.tar.xz`, Last-Modified 2026-10-07) ; …/holo-core-aarch64-preview/mash-20251118.3/
- Collabora, "Building an Arch Linux aarch64 port for Holo Core" (2026-07-17): https://www.collabora.com/news-and-blog/news-and-events/building-an-arch-linux-aarch64-port-for-holo-core.html
- Phoronix: https://www.phoronix.com/news/Holo-Core-Experimental-ARM64 ; GamingOnLinux (2026-07): https://www.gamingonlinux.com/2026/07/collabora-announce-a-preview-of-holo-core-an-aarch64-port-of-arch-linux-for-steam-frame/
- Steamworks, Steam Frame debugging: https://partner.steamgames.com/doc/steamhardware/steamframe/debugging
- Arch `steam`: https://archlinux.org/packages/multilib/x86_64/steam/ ; Debian `steam-installer`: https://packages.debian.org/sid/steam-installer ; Valve launcher repo: https://repo.steampowered.com/steam/
- 2013 redistribution licence: https://www.gamingonlinux.com/2013/02/steam-can-be-legally-packaged-in-any-distro/ ; https://www.phoronix.com/news/MTI5NzI ; https://www.phoronix.com/news/MTIyOTI ; https://github.com/ValveSoftware/steam-for-linux/issues/66
- QK2: https://github.com/machachu56/quest-kexec-q2 (branch `quest2-port`: `tools/steamos/pacman.conf`, `tools/steamos-rootfs.sh`)
- Jovian-NixOS: `pkgs/steam-jupiter/unwrapped.nix` (branch `development`); issue https://github.com/Jovian-Experiments/Jovian-NixOS/issues/587 ; nixpkgs `pkgs/by-name/st/steam-unwrapped/package.nix`
- HoloISO: https://github.com/holoiso-eol/holoiso ; news https://www.gamingonlinux.com/2024/01/the-original-steamos-like-linux-distro-holoiso-now-dead-replaced-with-immutable-version/
- ChimeraOS `manifest`: https://github.com/ChimeraOS/chimeraos ; Bazzite `Containerfile`: https://github.com/ublue-os/bazzite ; SteamFork: https://github.com/SteamFork/distribution
- Powered by SteamOS / Legion Go S: https://www.heise.de/en/news/Legion-Go-S-Valve-releases-SteamOS-for-other-handhelds-10231287.html ; https://www.techradar.com/computing/gaming-pcs/goodbye-windows-11-valves-steamos-is-now-available-on-the-legion-go-s-with-some-support-for-other-amd-powered-handhelds
- Steam on ARM statement (secondary): https://xenospectrum.com/en/steam-linux-arm-support-boundary/
- Local: `docs/research/community-quest-repos-2.md` §1.4, §7 (S14), §8; FS-A-010 (private review record) §7.4; FS-A-002 (private review record) §3, §6; `docs/research/FS-A-006-ports.md`; `docs/PROJECT_SETUP.md` §6A item 9.
