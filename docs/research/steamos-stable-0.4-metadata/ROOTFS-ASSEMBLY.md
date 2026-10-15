# ROOTFS-ASSEMBLY: SteamOS 0.4.5 stable rootfs from Valve's public chunk store

PM-approved (J-149, PD-11), 2026-10-14. Agent pass. **Unreviewed.**
Tags: [M-static] = observed on a named file or artifact; [D] = derived; [O] = open (not used for results).
Purpose: the exact signed 0.4.5 stable rootfs as the first SteamOS boot target.

Scope kept: only chunks that the signed `rootfs.img.caibx` lists were downloaded,
from Valve's public, unauthenticated chunk store. No credentials, no client.conf
(not opened), no Valve keys. No device commands. the PM's offline backup drive and /persist not
touched. Nothing from the downloaded data was executed; every Python run that
read it used `python3 -I` with scripts kept in a separate directory. No new
packages installed (tools already present in WSL: Python 3.14.4 stdlib with
`compression.zstd`, casync 2, OpenSSL 3.5.5, btrfs-progs v6.17.1).
No Valve content is in this repo; the outputs stay in gitignored storage.

## 1. Bundle signature re-check and index extraction [M-static]

Input: `firmware/valve/steamos-0.4.5-stable/deckard-stable-20261007.6125817-0.4.5.raucb`
(sha256 `e3d14c217f934b225b56b45c1800b378583f6fda40b937eb9ac4344052bcbb8d`, as in
SIGNATURE-CHECK.txt). Split as RAUC plain format (8-byte BE size = 2138):

| item | sha256 |
|---|---|
| payload (squashfs, 2,281,472 B) | `e6fe890219e40b843b2eae6bddf9c7516e96bfca437e5c9894b276b33aa79e35` |
| detached CMS (2,138 B) | `15c4531b11d8775962c670b69827336227fdb0038a65a1f556aec6f113a007e9` |
| trust anchor `~/sfroot-full/etc/rauc/trusted_keys/ba942c60.0` | `1d6e246961284ee152cce21e5197a2a0f03dc2fbc0f66a66566850b77714100d` |

- `openssl cms -verify -binary -inform DER -in sig.der -content payload.bin -CAfile ba942c60.0 -out /dev/null`
  -> "CMS Verification successful", rc 0.
- Negative control (payload byte 1000001 set to 0x00) -> "bad signature".
- `unsquashfs -cat` extracted (all hashes identical to SIGNATURE-CHECK.txt):
  - `rootfs.img.caibx` 3,546,384 B, sha256 `297da4055ab821a86a98ba2d4baaf7c3eac1d767f07780058d9c110912a2698e`
  - `manifest.raucm` sha256 `b82af3d82902cc59a9c7887ffd4bd69c946c3aa748bd565759eee3a672fbc62a`,
    `[image.rootfs] size=10737418240`, `sha256=692b998b0a3b9db9963ac77e8e188b2d08ffd99a87beb504d808b446119bcc3c`

## 2. Chunk store URL and its source

Store base used:
`https://steamdeck-images.steamos.cloud/vr/20261007.6125817/deckard-stable-20261007.6125817-0.4.5.castr/`
Chunk path: `<store>/<first 4 hex of id>/<id>.cacnk` (casync layout; confirmed by
one HEAD of the first chunk: 200, 371 B, Last-Modified 2026-10-07 20:04:42 GMT).

How the Frame's updater finds it (read-only, WSL `~/sfroot-full`, rootfs 20260922.6152327):
- `etc/rauc/system.conf` (paraphrased): its casync section enables desync and passes
  install arguments that seed from the installed rootfs index, use the desync
  configuration, install in place and retry on errors. It sets no store URL
  [M-static]. With no store URL, RAUC's public documentation (https://rauc.readthedocs.io/en/latest/advanced.html, "RAUC casync Support") describes the default: the chunk store
  next to the bundle, with the `.castr` extension [D].
- `steamos-atomupd` (`usr/lib/python3.12/site-packages/steamosatomupd/imagepool.py`,
  `_get_rauc_update_path`): the server requires `<name>.castr` next to `<name>.raucb`;
  `client.py` runs `rauc install <bundle URL>`. [M-static]
- `etc/desync/config.json` sets store-options only for
  `https://steamdeck-images.steamos.cloud/*/*/*/` (error-retry-base-interval),
  which matches `vr/<build>/<name>.castr/`. [M-static]
- The public build-directory listing (FETCH-LOG.txt) shows
  `deckard-stable-20261007.6125817-0.4.5.castr/` beside the bundle. [M-static]
- [D] So the store URL used here came from the public `vr/` listing
  (FETCH-LOG.txt) plus RAUC's documented `.castr` default; it is the same place a
  Frame's RAUC/desync would read. The base URL the Frame's client uses for the
  bundle lives in client.conf, which was not opened.

## 3. Index and seed [M-static]

`rootfs.img.caibx`: feature flags `0xa000000000000000` (SHA-512/256 chunk IDs),
chunk size min/avg/max 16384/65536/262144, 88,657 chunks (63,188 unique),
covering 10,737,418,240 B (= manifest `size`).

Seed: rootfs-A of the 0.3.0 recovery image we hold,
`firmware/SteamOS/steamframe-oobe-repair-20260922.5153644-0.3.0.img`, bytes
335,561,728 + 5,368,709,120 (GPT partition 3 "rootfs-A"), copied to WSL scratch
(sha256 `668da2b1d32e9b779a1ee27ed570961ceaaf83a5dfeadd8129b62603223c319d`).
Chunked with `casync make --chunk-size=16384:65536:262144` (same parameters as
the target): 68,347 chunks, 63,295 unique (seed index sha256
`f4aceb02fd71fd7bb60ccdc9619b925b4aea5964b3da4187badb62b37a91a601`, local only).

| | unique chunks | uncompressed bytes |
|---|---|---|
| needed (target) | 63,188 | 4,402,745,357 |
| provided by seed (ID match) | 7,296 | 428,435,576 |
| to download | 55,892 | 3,974,309,781 |

Under the 6 GB report threshold, so the download went ahead without a stop.
[D] The seed shares little (about 10% of unique bytes): 0.3.0 rc and 0.4.5 differ
widely, and btrfs compresses file data, so changed files shift chunk content.

## 4. Download [M-static, from the download log]

- Tool: own stdlib script (urllib, 3 workers, 60 s timeout, up to 8 attempts
  with exponential backoff, User-Agent `frameshift-rootfs-assembly/1`).
- Each chunk: zstd-decompressed, length checked against the index, and
  SHA-512/256 of the decompressed data compared with its ID **before** it was
  kept. Stored compressed in its own untrusted directory (WSL `~/work/rootfs045/dl`).
- 2026-10-14T17:47:55Z .. 18:21:36Z (2021 s, about 1.76 MB/s).
- 55,892 chunks fetched, 0 failed, 1 retry (one read timeout, then OK).
- **Bytes downloaded: 3,554,704,108 B (3.31 GiB) of compressed chunk bodies**,
  plus the one HEAD probe and the partial body of the one timed-out attempt.
- Seeded: 428,435,576 B unique (uncompressed), not downloaded.

## 5. Assembly and verification [M-static]

Every one of the 88,657 index entries was re-read from the seed image or the
chunk cache and its SHA-512/256 re-checked against its ID while writing:

| source | chunk entries | bytes |
|---|---|---|
| seed (0.3.0 rootfs-A) | 31,674 | 6,694,799,519 |
| downloaded | 56,983 | 4,042,618,721 |
| total | 88,657 | 10,737,418,240 |

(23,783 entries are all-zero: 23,782 x the 262,144 B zero chunk, which the
seed provides, and one 85,820 B zero chunk, downloaded. That is why seeded
entries carry far more bytes than seeded unique chunks.)

- Size: 10,737,418,240 B = caibx total = manifest `size`. **Match.**
- **`rootfs.img` sha256 `692b998b0a3b9db9963ac77e8e188b2d08ffd99a87beb504d808b446119bcc3c`
  = `manifest.raucm [image.rootfs] sha256`. Match.** Since the manifest is
  inside the CMS-signed squashfs, the image is the exact signed 0.4.5 stable rootfs.
- No verity root hash exists for this image: plain bundle format, and the
  manifest carries only sha256 and size. [M-static]
- The copy in `firmware/valve/steamos-0.4.5-stable/rootfs.img` was re-hashed on
  the Windows side (`sha256sum`, Git Bash): same value, recorded in `SHA256SUMS`. [M-static]

## 6. Filesystem [M-static]

`btrfs inspect-internal dump-super rootfs.img` (read-only on the file):
btrfs, magic match, fsid `e8f36086-bebf-474f-a7f8-66280e329d6a`, empty label,
generation 10, total_bytes 10,737,418,240, **bytes_used 4,479,242,240**,
sectorsize/nodesize 4096, csum crc32c, compat_ro_flags 0x3, incompat_flags 0x355
(same incompat flags as the 0.3.0 rootfs-A).
`btrfs check --readonly --check-data-csum rootfs.img`: **no error found**
(file data blocks allocated 4,214,153,216; referenced 9,221,201,920).

[M-static] The btrfs fsid equals the bundle's RAUC `UUID` file
(`e8f36086-bebf-474f-a7f8-66280e329d6a`). [M-static] The label is empty here, while
the 0.3.0 recovery image's rootfs-A is labelled `rootfs-A` (5 GiB). [D] The
label (and the 5 GiB size) are likely set by the recovery image build or at
install, not carried in the bundle image; not checked.

## 7. Locations (gitignored, never commit or publish)

`firmware/valve/steamos-0.4.5-stable/`:
- `rootfs.img` (10 GiB, the assembled signed rootfs)
- `rootfs.img.caibx`, `manifest.raucm` (from the signed bundle)
- `SHA256SUMS`

WSL scratch `~/work/rootfs045/` (local only): `bundle/` (split bundle),
`seed/` (0.3.0 rootfs-A copy, seed index), `dl/` (55,892 verified chunks,
untrusted data), `rootfs.img` (sparse working copy), logs. Scripts in
`scripts/` (stdlib; sha256):
`caibx.py` `722758e9a2cacb6d8afd70cafd7ccfe1e62a0eeef61ad38b23780ed452baf86c`,
`fetch.py` `5a046504feaae66dea63fd4dcba667cc357288e800f14701dc7cf256b04676fb`,
`assemble.py` `d257a79d7064fa91b1cb25d2d0f692250dac0c1ca6db136cf8c825cc946f06b2`.
