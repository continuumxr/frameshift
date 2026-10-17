# T1 pins — genuine Valve files for experiment (i)

**Answers:** FS-R-006 §5 A, for experiment (i) in FS-A-006 §5: pin the hashes,
ELF dependencies and provenance; launch the child with absolute paths and a
controlled environment; check the interpreter line and the library
resolutions.

**Status:** offline work only, 2026-10-09. No device and no adb/fastboot were
used. Nothing was installed. The Valve binaries were staged only in the WSL
scratch directory `~/work/t1pin/stage`, never under a repo path. Pending the
adversarial review and the Chair.

**Machine-readable form:** `T1-pins.json`. `tools/elfpin.py check` enforces
it.

**Raw evidence:** `evidence/`:
- `provenance.txt`
- `readelf-crosscheck.txt`
- `elfpin-inspect.json`
- `ldso-envvars.txt`
- `fixture/` (transcript and per-step stdout, stderr and strace)
- `ramdisk-scan.txt`
- `pin-negative.txt`

**Tags (FS-R-001):** [M-static] read from a named artifact; [D] derived;
[C] inferred; [O] open.
- The qemu runs are **fixtures**: [D] evidence about the binaries'
  user-space behaviour under qemu-user (fix round 6; earlier text called
  them [M-static]).
- The pinned files, their hashes and ELF fields are [M-static].
- Nothing here is an observation of the Quest kernel.

---

## 1. Provenance [M-static]

| link | value | source |
|---|---|---|
| image | `steamframe-oobe-repair-20260922.5153644-0.3.0.img`, 7,516,192,768 B | `firmware/SteamOS/` |
| image SHA-256 | `081a38c051e99c09db6ae91be994b67ef3347ea71f330d803ab861f0ba8cc654`. **Recomputed 2026-10-09; equals FS-A-001 §10** | `evidence/provenance.txt` |
| partition | GPT #2 `rootfs-A`: first LBA 655394 × 512 = byte offset 335,561,728; 5120 MiB; type DPS ARM64 root; unique GUID `0ee15513-80cf-4627-813f-d05477340f0b` | FS-A-002 bundle `partition-table.txt` |
| filesystem | btrfs, single `FS_TREE`, no subvolumes; no tree log to replay | FS-A-001 §1, FS-A-002 §1 |
| extraction | kernel read-only loop mount of `rootfs-A`, copied with `cp -a` to WSL `~/sfroot-full` | FS-A-002 §1, §4 A |
| build identity | `usr/lib/os-release`: `BUILD_ID=20260922.6152327`, `VERSION_ID=0.3.0`, `VARIANT_ID="vr"`. File SHA-256 `3abf391a…3350f7`, equal to the FS-A-002 bundle manifest. Channel `rc` (FS-A-002 §3) | `evidence/provenance.txt` |
| packages | `glibc-2.39-2` owns the loader and libc; `coreutils-9.5-1` owns `uname` and `b2sum` | pacman db `usr/lib/holo/pacmandb/local/*/files` |

**Two build numbers (fix round 6).** The image file name carries
`20260922.5153644`. The rootfs it contains is build `20260922.6152327`.

- **Where each number appears:**
  - `usr/lib/os-release` `BUILD_ID` and `etc/steamos-atomupd/manifest.json`
    `"buildid"` both say `20260922.6152327` [M-static]. The manifest also
    has `"version": "0.3.0"`, `"variant": "vr"` and
    `"default_update_branch": "stable"`.
  - Valve's update server lists `20260922.6152327` as an `rc` build with
    its RAUC bundle (FS-A-002 §3).
  - `20260922.5153644` appears **nowhere** inside the image:
    - not in `etc`, `usr/lib/holo` or `usr/share/steamos` of rootfs-A;
    - not in the restored `efi`/`esp`/`home` copies (`~/fsout`);
    - a raw-byte search of the 7 GB image finds neither number, because
      btrfs stores these files compressed, so that search is not evidence
      of absence.
  - rootfs-A carries an empty marker `etc/steamos-oobe-image`, dated
    2026-09-22 [M-static].
- **[C]** `5153644` numbers the OOBE/repair *image* build: the job that
  packaged rootfs build `6152327` into `steamframe-oobe-repair-…img` the
  same day, from a separate counter. **[O]** until Valve's `oobe/` listing
  or an image manifest says so.
- **For the pins, the rootfs build is what counts:** `20260922.6152327`.
  It is identified three ways: `os-release`, the atomupd manifest, and the
  server listing.

**Channel status (fix round 6).** `20260922.6152327` is an **`rc`** build.
- It is used here **for offline tests and experiment (i) only**.
- FrameShift ships only from Valve's **`stable`** channel (PROJECT_SETUP
  release policy).
- SteamOS 0.4 for Steam Frame was released on `stable` on 2026-10-08
  (J-47). When a 0.4 stable image is obtained, these four files are diffed
  against it, and the pins are either confirmed or redone in a reviewed
  change.

**Symlinks.** The rootfs has `lib -> usr/lib` and `bin -> usr/bin`, both
relative. The pinned files are regular files at their real paths, with no
further links:

| T1 name (link path) | real path in the rootfs |
|---|---|
| `/lib/ld-linux-aarch64.so.1` | `/usr/lib/ld-linux-aarch64.so.1` |
| `/lib/libc.so.6` | `/usr/lib/libc.so.6` |
| `/bin/uname` | `/usr/bin/uname` |
| `/bin/b2sum` | `/usr/bin/b2sum` |

The staged copies in our image are regular files at `/valve/lib/…` and
`/valve/bin/…`. The builder refuses symlinks in the staged tree.

**Three independent witnesses agree on all four files:**
1. the kernel-mount copy;
2. the FS-A-001 `btrfs restore` copy (`~/fsout`). These files are larger
   than an inline extent, so the restore bug does not apply;
3. Valve's own package manifests: `mtree` `sha256digest` and `size` in the
   pacman db for glibc-2.39-2 and coreutils-9.5-1.

## 2. Pins

| file | size (B) | SHA-256 |
|---|---|---|
| `lib/ld-linux-aarch64.so.1` | 204,048 | `2ddc56a02f476765a21e31d69144e68bee933950fe613747d54b87a2369a037e` |
| `lib/libc.so.6` | 1,722,992 | `be7ee393429d493c4d3b996ed25cbb02fabb2896a77efe6d57e5993ead5bbb3b` |
| `bin/uname` | 67,856 | `4295f034edf7d62f721cfe994230ba139646c7872dc2a6899aa681f76fca31f1` |
| `bin/b2sum` | 67,864 | `90154680070cfcb2a3027b8fa26a8091d24333329294a2f4be7a12c7f11f6402` |
| **total** | **2,062,760** | |

| file | BLAKE2b-512 |
|---|---|
| `lib/ld-linux-aarch64.so.1` | `0bcbf291b183e56231710fa7c421885a4cf929999a9fa910b8d50559fb282adbf36ea1af3c0c5d6f14ab2d9f973c7e26fd8914ed9a8f11690519cfdde2b632be` |
| `lib/libc.so.6` | `24975814bcd7bc7ee4097c55849fbc2882002908018f607115521150d54c36449e8f371cde8c998e4124d0e02aed2496c725c17e1c7dc842d225853d0ce6879a` |
| `bin/uname` | `364bac68885d01639992245aca774e77fe1228848ee166ac7375b52cc9133739b905a37c8148727afb67b46a25a1cef02a109a21017bc808cf1219f1d1280168` |
| `bin/b2sum` | `0db8c154887585f26130f207b01a4fbcb3d07a9cebac8f11cf0ff72215e26c4ac8189f7e4065125600b6a393aebe3385d58e936a0e89981798c03b219e1599fe` |

**ELF facts.** Our stdlib parser (`elfpin.py`) and GNU readelf 2.46 agree on
every field. llvm-readelf 14.0.7 (clang-r450784e) was used for the notes
check.

| field | ld-linux-aarch64.so.1 | libc.so.6 | uname | b2sum |
|---|---|---|---|---|
| class / machine | ELF64 LSB / AArch64 | same | same | same |
| e_type | ET_DYN (shared object) | ET_DYN (shared object) | ET_DYN (PIE) | ET_DYN (PIE) |
| PT_INTERP | **none** | `/usr/lib/ld-linux-aarch64.so.1` (libc is executable; not used when it is loaded as a library) | `/lib/ld-linux-aarch64.so.1` | `/lib/ld-linux-aarch64.so.1` |
| PT_INTERP bytes (with NUL) | — | 31 | 27: `2f6c69622f6c642d6c696e75782d616172636836342e736f2e3100` | same as uname |
| DT_NEEDED, in order | **none** | `ld-linux-aarch64.so.1` | `libc.so.6`, `ld-linux-aarch64.so.1` | `libc.so.6`, `ld-linux-aarch64.so.1` |
| DT_SONAME | `ld-linux-aarch64.so.1` | `libc.so.6` | — | — |
| DT_RPATH / DT_RUNPATH | none / none | none / none | none / none | none / none |
| DT_FLAGS / DT_FLAGS_1 | BIND_NOW / NOW | BIND_NOW / NOW | BIND_NOW / NOW PIE | BIND_NOW / NOW PIE |
| GNU_PROPERTY (BTI/PAC) | none | none | none | none |
| PT_LOAD p_align | 0x10000 (64K) | 0x10000 | 0x10000 | 0x10000 |
| GNU_STACK | RW, not executable | same | same | same |
| NT_GNU_ABI_TAG | **none** | Linux 4.4.0 | Linux 4.4.0 | Linux 4.4.0 |
| version needs | — | ld.so: GLIBC_2.17, GLIBC_PRIVATE | ld.so: GLIBC_2.17; libc: GLIBC_2.17, GLIBC_2.34 | ld.so: GLIBC_2.17; libc: GLIBC_2.17, GLIBC_2.34, **GLIBC_2.38** |
| version definitions | GLIBC_2.17, 2.34, 2.35, PRIVATE | 21 versions, GLIBC_2.17 … GLIBC_2.39, GLIBC_ABI_DT_RELR, GLIBC_PRIVATE | — | — |

**Symbol detail.**
- The executables need `ld-linux-aarch64.so.1` for
  `__stack_chk_guard@GLIBC_2.17`.
- `b2sum` needs GLIBC_2.38 for `__isoc23_strtoumax`.
- Both need GLIBC_2.34 for `__libc_start_main`.
- The full lists of undefined versioned symbols are in
  `evidence/readelf-crosscheck.txt`.
- `elfpin.py check` verifies that every required version is defined by the
  pinned file that provides it.

## 3. Launch specification and library resolution

**Exact child command.** Absolute paths only. `cwd` is `/`. stdin is
explicit.

```
cd / && env -i /valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib /valve/bin/uname -r </dev/null
cd / && env -i /valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib /valve/bin/b2sum <input
```

On the device:
- `env` is busybox's applet. It is present in the stage-1 applet table.
- The FS-R-006 §5 C supervisor wraps this command. It is out of scope here.

**Environment.** The child environment is **empty**: `env -i` with no
assignments. The fixture checks that `env -i env` prints 0 bytes.

**Must be absent:** the following loader-, libc- and coreutils-affecting
variables (`evidence/ldso-envvars.txt` shows which binary reads each):

| group | variables |
|---|---|
| loader | `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `LD_DEBUG`, `LD_DEBUG_OUTPUT`, `LD_BIND_NOW`, `LD_BIND_NOT`, `LD_DYNAMIC_WEAK`, `LD_PROFILE`, `LD_PROFILE_OUTPUT`, `LD_SHOW_AUXV`, `LD_WARN`, `LD_VERBOSE`, `LD_TRACE_LOADED_OBJECTS` (it turns any run into `--list`), `LD_HWCAP_MASK`, `LD_ORIGIN_PATH` |
| tunables and malloc | `GLIBC_TUNABLES`, `MALLOC_*`, `MALLOC_TRACE` |
| libc | `GCONV_PATH`, `GETCONF_DIR`, `GMON_OUTPUT_PREFIX`, `HOSTALIASES`, `LOCALDOMAIN`, `LOCPATH`, `NIS_PATH`, `NLSPATH`, `RESOLV_HOST_CONF`, `RES_OPTIONS`, `TMPDIR`, `TZ`, `TZDIR` |
| locale | `LANG`, `LANGUAGE`, `LC_*` |
| coreutils | `POSIXLY_CORRECT`, `_POSIX2_VERSION` |

**Fixture demonstrations** (`evidence/fixture/fixture-transcript.txt`):
- **`LD_PRELOAD` is honoured despite `--library-path`.** The loader tries the
  preload and prints an error.
- **`LD_DEBUG` is honoured.**
- `LD_LIBRARY_PATH` is superseded by `--library-path`, but this is not
  relied on.

**Image conditions** (builder-enforced or checked):
1. `/valve/lib` contains exactly `ld-linux-aarch64.so.1` and `libc.so.6`, and
   `/valve/bin` exactly `uname` and `b2sum`. There are no subdirectories and
   no symlinks; mode 0755. `elfpin.py check` refuses any extra file, missing
   file, subdirectory file or symlink.
2. These paths must be absent from the union initramfs (vendor ramdisk plus
   ours):
   - `/etc/ld.so.preload` (read regardless of the environment; see the
     strace);
   - `/usr/lib/libc.so.6` (this ld.so's only system directory is
     `/usr/lib/`: `--list-diagnostics` gives `path.system_dirs[0x0]="/usr/lib/"`);
   - `/lib/libc.so.6`, `/lib/ld-linux-aarch64.so.1` and `/usr`.

   All of these were checked absent for the stage-1 image
   (`evidence/ramdisk-scan.txt`). `/lib` exists in the vendor ramdisk, but
   only as `/lib/modules`.

**qemu fixture.**
- Tools: qemu-aarch64 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.2), static-pie,
  SHA-256 `e1dc1eb0…48ed20`.
- Invocation:
  `qemu-aarch64 -L ~/work/t1pin/stage -0 /valve/lib/ld-linux-aarch64.so.1 ~/work/t1pin/stage/valve/lib/ld-linux-aarch64.so.1 …`.
  - `-L` resolves the guest's absolute paths inside the stage first.
  - `-0` keeps `argv[0]` identical to the device.
  - The host was checked to lack every fallback path listed above, so a
    missing staged file cannot be satisfied from the host.
- qemu `-strace` logs every file the guest touched.

| step | rc | result |
|---|---|---|
| `--list-diagnostics` | 0 | glibc 2.39 `stable`; `system_dirs` = `/usr/lib/`; `dl_pagesize` 0x1000 (qemu) |
| `--list /valve/bin/b2sum`, `--list /valve/bin/uname` | 0 | exactly 3 lines (below) |
| `uname -r`, `uname -a` | 0 | host release under qemu (expected; on the device it must equal the running kernel) |
| `b2sum --version` | 0 | `b2sum (GNU coreutils) 9.5` |
| `b2sum` known-answer and challenge tests | 0 | §5 |

**Files opened in every positive step**, and nothing else:
1. `openat("/valve/bin/<prog>") = 4`;
2. `faccessat("/etc/ld.so.preload") = ENOENT`;
3. `openat("/valve/lib/libc.so.6") = 4`.

The loader does not open itself: the kernel maps it (here, qemu). No locale,
gconv or cache file is opened.

**Negative controls:**

| control | rc | result |
|---|---|---|
| direct exec of `/valve/bin/b2sum` | 255 | `Could not open '/lib/ld-linux-aarch64.so.1'`. PT_INTERP is not satisfiable in this layout, matching FS-A-006 §5.2.2 |
| without `--library-path` | 127 | tries `/usr/lib/libc.so.6` → ENOENT; "cannot open shared object file" |
| `libc.so.6` removed from `/valve/lib` | 127 | tries `/valve/lib/libc.so.6` then `/usr/lib/libc.so.6`, both ENOENT. **In this qemu layout no other resolution was attempted** [D, one fixture layout]: the loader's search list here is `--library-path`, then its system directory `/usr/lib/`; other layouts (e.g. an `/etc/ld.so.cache`, `LD_LIBRARY_PATH`) are excluded by the builder and `env -i`, not by this control |

**Measured `--list` format.** Every line begins with a tab. The addresses are
ASLR-random, so the output hash differs between runs and only a rule can
be checked:

```
\tlinux-vdso.so.1 (0x[0-9a-f]{16})
\tlibc.so.6 => /valve/lib/libc.so.6 (0x[0-9a-f]{16})
\t/lib/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1 (0x[0-9a-f]{16})
```

**Proposed rule for §5.2.5:**
- The output has exactly these 3 lines, in this order, each matching its
  regex in full (anchored).
- Any other line, or a missing line, fails.
- The vdso line depends on the kernel providing a vDSO [C]: arm64 always
  does. If it is absent on the Quest, the record must show it. It is not
  silently allowed.

**Correction (FS-R-009 §4).** The "exactly 3 lines" rule above (now **v1**)
was defective. glibc 2.39 can print a fourth, first line
`\t (0x<16 hex>)`: the main program's own unnamed map, shown when the
uninitialised `mode_trace_program` byte happens to be set. Trial (i) hit it,
and qemu `-cpu cortex-a72` reproduces it; see
FS-A-009 (private review record). Our qemu fixture never did.

Later runs use **v2A** (amended rule A, `LISTING-RULE-A.md`): the 3 lines
above, optionally preceded by ONE such first line. Its address must be
nonzero and distinct from the 3 required addresses. There is no ordering
condition: the unnamed map lies above the loader in 9 logged qemu runs.

Trial (i) stays classified under v1, as registered.

## 4. Interpreter-line validation

**Builder** (`tools/elfpin.py check T1-pins.json <staged>/valve`; exit 0 =
accept, 1 = refuse). The parser is our own stdlib code; it does not trust
readelf. It requires:
- **For `uname` and `b2sum`:**
  - exactly one PT_INTERP;
  - its bytes are a single NUL-terminated string equal to
    `/lib/ld-linux-aarch64.so.1`, the `expected_pt_interp` value pinned in
    the JSON (hex is pinned too);
  - DT_NEEDED is exactly `["libc.so.6","ld-linux-aarch64.so.1"]`;
  - no DT_RPATH or DT_RUNPATH.
- **For the loader:** no PT_INTERP and no DT_NEEDED.
- **For all four files:** SHA-256, BLAKE2b-512, size, type and machine, BTI
  and PAC flags and p_align equal to the pins, and every needed version
  defined.

Negative fixtures (`tools/t1-pin-negative.sh`, 10 cases, all PASS;
`evidence/pin-negative.txt`):
- the interpreter patched to `/LIB/…` is refused on hash **and** separately
  on PT_INTERP;
- also refused: an appended byte, a flipped byte, a missing file, an extra
  file, an extra subdirectory, a symlink, a non-executable file, and a
  swapped binary.

**On the device.** The `--list` interpreter line's left-hand side is the
program's own PT_INTERP: rtld names its map after it. The fixture proves it:
a `uname` copy patched to `/XYZ/ld-linux-aarch64.so.1` lists
`/XYZ/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1`. So the
anchored `--list` rule in §3 also checks, at runtime, the interpreter line
of the exact file executed. The `sha256sum` step (§5.2.1) ties that file to
the pins.

## 5. b2sum known answers (byte-exact inputs)

**Inputs.** Each was written with `printf`, so there is no locale or `echo`
variation. The challenge string is a **fixture sample only**; the live
challenge comes from the host.

| input | bytes | hex |
|---|---|---|
| empty | 0 | (none) |
| challenge, no newline | 52 | `66732d376331653039643261346238356633363a3966326234633664316538613730333562316439633465326636613830333137` (`fs-7c1e09d2a4b85f36:9f2b4c6d1e8a7035b1d9c4e2f6a80317`) |
| challenge + `\n` | 53 | the same plus `0a` |

**Results.** Valve's `b2sum` under qemu, uutils `b2sum` 0.8.0 (x86_64) and
Python `hashlib.blake2b` agree exactly. The b2sum stdout is 132 bytes:
128 hex digits, two spaces, `-`, newline.

| input | BLAKE2b-512 |
|---|---|
| empty | `786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce` (= expected; `-l 512` gives the same) |
| challenge, no newline | `dffeda405775e59eecd8d2f4a2889a4af3f97a29e62d2e2939fe340ff60b0de857cc3076227b4d69e12dcf2d817faa7170c0a42e1c56d90b0a8eb1dfa23df61a` |
| challenge + `\n` | `6d165f1fd9e234cfc1edd72b739999698890f07b6ebfab3997fd8dda0889cf64370b8a66813a82c63cf98b74e9f32b02f8c00c87aecf5c9bda6664f0895765dd` |

**Recommendations:**
- `fs-valve` should feed the challenge with `printf '%s'`, without a
  newline.
- The host should compute **both** digests. A match with the newline
  variant should be classed as a wrong-output FAIL, but it can then be
  diagnosed rather than appearing as random garbage.

## 6. No other BLAKE2 in the stage-1 image

**Image scanned:** `build/stage1/20261008T024856Z-<attempt nonce withheld>`. Both
ramdisks were unpacked from the images themselves
(`tools/t1-ramdisk-scan.sh`, `evidence/ramdisk-scan.txt`):
- `boot-stage1.img`, SHA-256 `efefe10d…7250`;
- stock `vendor_boot.img`, SHA-256 `1e3b3762…bbdcf`.

**Our ramdisk:**
- 10 entries, identical to `ramdisk.list`;
- 3 regular files: `init`, `bin/busybox`, `bin/fs-reboot`.

**Vendor ramdisk:**
- 107 regular files: 97 relocatable `.ko`, text lists, and 3 AVB public
  keys;
- **no ELF executables or shared objects**.

**Busybox 1.37.0 applet table:** 276 applets, none named b2/blake. The hash
applets are `crc32 md5sum sha1sum sha256sum sha3sum sha512sum`.

**Byte scan** of all 110 files for three indicators:
- the strings `blake2` / `b2sum`;
- the BLAKE2b IV as 64-bit words;
- the BLAKE2 sigma rows.

Results:
- **0 hits.**
- **Positive control:** Valve's `b2sum` hits on the strings and on 8/8 IV
  words.
- **Limits:**
  - Its sigma table was folded away by the compiler, so the sigma test is
    supplementary.
  - The IV equals SHA-512's. A hit would mean "investigate", not "proof".
    Busybox stores the SHA-512 IV as 32-bit halves and does not hit.
- **Conclusion:** absence is strong evidence, not proof. Provenance and the
  pins carry the result (FS-R-006 §5 F).

**Kernel.** The kernel has `CONFIG_CRYPTO_BLAKE2B=y`, from the stock
kernel's own IKCONFIG, `5.10.198-01402-g1c5986fe21ee`. Userspace cannot reach
it: `CONFIG_CRYPTO_USER_API_HASH` (AF_ALG hash) and `CONFIG_CRYPTO_USER` are
not set. `CRYPTO_LIB_BLAKE2S_GENERIC=y` is BLAKE2s, used internally by the
kernel.

## 7. Findings against FS-A-006

1. **No contradiction in the hashes.** All four SHA-256 prefixes and
   suffixes, and the total of 2,062,760 bytes, match §4. The 64K p_align, the
   absence of BTI/PAC, the loader's lack of DT_NEEDED and the executables'
   PT_INTERP are all confirmed.
2. **§5.2.5 `--list` rule needs correcting.**
   - It says the interpreter line is a line "without `=>`". It is not: it
     reads `/lib/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1`.
   - The only line without `=>` is `linux-vdso.so.1`.
   - Replace the rule with the anchored three-line rule in §3.
3. **More precision for §4:**
   - The executables' DT_NEEDED also lists `ld-linux-aarch64.so.1`.
   - `libc.so.6` carries its own PT_INTERP, `/usr/lib/…`.
   - The ABI-tag note is absent from ld.so. It is present in libc and in
     both executables.
   - `b2sum` needs GLIBC_2.38.
4. **The kernel contains BLAKE2b (§4 discrimination).** It is unreachable
   from userspace (no AF_ALG hash). This should be stated rather than
   "no other BLAKE2 implementation in the image".
5. **Environment control (§5.2.2).** `--library-path` does not neutralise
   `LD_PRELOAD`, `LD_AUDIT`, `LD_DEBUG` or `GLIBC_TUNABLES`. `env -i` is
   required, and `/etc/ld.so.preload` must be absent.

## 8. Limits

- **qemu is not the Quest kernel.** The fixture fixes formats, resolution
  and environment handling only.
- **Not tested:** the stock 5.10 kernel's ELF loader, its vDSO, rseq
  (`CONFIG_RSEQ=n`), real hwcaps and ifunc selection (qemu reports
  `dl_hwcap=0x12ffffffb`), and SIGILL risk.
- **qemu `-strace`** shows guest syscalls only, not qemu's own loading of
  the loader.
- **The `--list-diagnostics` output in `evidence/` contains host details**
  (WSL nodename, scratch path). It is a fixture artifact, not a reference.

## 9. Reproduce (in WSL; read-only on `~/sfroot-full`)

```
T=<repo>/devices/quest3/stage2a
bash $T/tools/t1-pin.sh $T/evidence --hash-image      # provenance, cross-check, T1-pins.json
bash $T/tools/t1-qemu-fixture.sh $T/evidence/fixture  # stages ~/work/t1pin/stage, runs qemu steps + controls
bash $T/tools/t1-pin-negative.sh                      # gate negatives (needs the staged tree)
bash $T/tools/t1-ramdisk-scan.sh <repo>/build/stage1/20261008T024856Z-<attempt nonce withheld> $T/evidence
```
