# kgate: offline kernel symbol-version gate

This tool implements FS-R-006 §3: a kernel gate with an actual rejection path. Version 2.3 addresses the findings of five adversarial reviews. Each finding has fixtures, and the before/after runs are in `validation/fixture-results-*.txt`. That is evidence about the listed findings, not a claim that no defects remain.

It replaces the report-only gate scripts and `btfkinds.py` under FS-A-006 (private review record). Those scripts stay as evidence and are not modified.

It runs offline only. It never talks to a device.

## Threat model

kgate catches mismatched, incomplete or wrong builds produced by **our own** build process, and it enforces acceptance. Where feasible it decodes what the kernel loader itself uses: the Image's kallsyms, `__ksymtab*` and `__kcrctab*`.

**kgate is not a defence against a malicious builder who forges binaries.** Someone who edits vmlinux and the Image together, including kallsyms, can in principle construct a consistent forgery. That threat is addressed by **build provenance**. The builder rebuilds from the pinned source commit, the pinned toolchain and the pinned config, and the result must be bit-identical.

Reproducibility status, measured 2026-10-09 by rebuilding the Quest 2 stock config (`validation/reproducibility.txt`):

- Module.symvers and `.config` reproduce exactly.
- vmlinux and Image reproduce only if the object-directory path is the same (or remapped) and the build identity is pinned: `KBUILD_BUILD_TIMESTAMP`, `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`, `KBUILD_BUILD_VERSION`.
- The existing FS-A-006 builds pinned none of these, so they cannot be reproduced bit-for-bit.

**What a PASS means:** the build *matches the checked symbol-version interfaces; complete module compatibility and runtime behaviour remain open* (FS-R-006 §2). A PASS is not "ABI-equivalent" and not "BTF validated".

## Files

| File | Purpose |
|---|---|
| `kgate.py` | `reference` builds a pinned reference from stock images. `check` gates a build. |
| `btf_kind_scan.py` | The **BTF kind scanner**. It replaces `btfkinds.py`. It is not a BTF validator. |
| `test_kgate.py`, `test_kgate.sh` | 170 fixture cases. Each asserts the exit code and the reason (check id + status + message substring). Isolated cases also assert that no other FAIL/ERROR check is present. |
| `fixtures/make_fixtures.py`, `fixtures/data/` | Synthetic fixtures with no vendor binaries. `data/` is generated, and `MANIFEST.sha256` pins it. |
| `validation/run_validation.sh`, `validation/SUMMARY.txt` | Gate-mode results on the real Quest 3 / 2 / 3S / Pro v2.7 builds, plus negative real-data runs. |
| `validation/requests/` | The pinned per-device inputs, kept byte-exact by `validation/.gitattributes` (`-text`). |
| `validation/fixture-results*.txt` | The suite run on this tool, on the pre-review tool (1.0), and on the committed 2.0, 2.1 and 2.2. |

## Exit codes

| Code | kgate.py | btf_kind_scan.py |
|---|---|---|
| 0 | **PASS**: gate mode, every check ran and passed. | Kinds are a subset of the allowed set. |
| 1 | **FAIL**: the build is rejected. | Kinds are beyond the allowed set. |
| 2 | **ERROR**: nothing was concluded (see the list below). | No BTF, malformed BTF, ambiguous BTF, unreadable input, or a usage/internal error. |
| 3 | **REPORT-ONLY** (`check --report-only`) or **BOOTSTRAP** (`reference --bootstrap`). Never a pass. | `--scan-only`: nothing was compared. |

For `kgate.py`, ERROR (exit 2) covers:

- missing, empty or unparseable input;
- failed extraction;
- an incomplete, inconsistent or unpinned reference;
- inputs that are not pinned, or that do not belong to one build;
- usage errors and internal errors.

General rules:

- ERROR takes precedence over FAIL in the exit code.
- An uncaught exception exits 2, never 1. The handler also writes an ERROR JSON.
- Any existing `--json` target is deleted before argument parsing, so no stale PASS file can survive.
- Builders must treat anything but 0 as "not accepted". They must not parse the text output to decide.

## Trust root: the device profiles

The profiles in `validation/requests/<dev>.profile.json` are **the trust root of the gate**. They pin:

- the reference sha256, which in turn pins the stock kernel and therefore the stock base config (its IKCONFIG);
- the per-build request-list, allowlist and baseline hashes;
- the declared sources and the counts.

Anyone who can edit a profile can make a different build pass. So the profiles and the files they hash must be **reviewed and committed**.

- `check` records the profile's sha256 and git blob id (`inputs.profile`).
- **In gate mode the profile must be byte-identical to its committed blob at git HEAD.** This is on by default. Opting out needs `--waive-committed-profile REASON`, which is recorded as a waiver.
- `run_validation.sh` enforces this. `KGATE_WAIVE_COMMITTED="reason"` exists only to show results before a pending commit, and is then recorded in every result.

## Pins: what is anchored where

The device profile is `validation/requests/<dev>.profile.json`.

| Pin | Anchored by |
|---|---|
| `counts.required_from_vmlinux` (2601 / 838 / 2583 / 776) | **Independent**: verified by the Chair in FS-R-006 §2. The re-derived sets are byte-identical to the FS-A-006 lists. |
| `counts.unique_modules`, `counts.module_copies` | Self-referential (first kgate inventory); cross-checked by `modules.load`/`modules.dep` coverage. |
| `reference_sha256` | Self-referential (pinned from this project's own deterministic reference build). |
| `stock_build_symvers_sha256` | Self-referential (our stock-config build). It is the only permitted baseline for that device's option-group builds. |
| `build_sections` | Self-referential: the allocated section names of our stock-config build. No stock vmlinux exists, so this cannot be anchored to stock. Every option-group build of all four devices has the same 38 sections. |
| `builds.<name>.requested_sha256` / `allow_sha256` | Self-referential (hashes of the reviewed request and allowlist files). |
| Stock kernel location | The profile's `stock_kernel` (a path relative to the profile file), or `--stock-kernel`. The reference stores only basenames and sha256, so moving the repo does not change its pinned hash. |
| Base config (`--requested-config`) | **Independent of the operator**: it must parse-equal the IKCONFIG embedded in the device's stock kernel. That stock kernel is pinned by sha256 in the reference, and must be one of the stock `--boot` images. |

## `reference`: build and pin the stock reference

```
kgate.py reference --device D --profile D.profile.json --out DIR --require-modprobe \
   [--vendor-boot IMG] [--boot IMG] [--ext4 LABEL=IMG ...] [--dir LABEL=DIR] --stock-kernel BOOT.IMG
```

**Profile.** The profile declares the exact source set and pins the counts. A different source set, different counts or a device mismatch is an ERROR. Without a profile, `--bootstrap` exits 3.

**Pinning the reference hash.** The output is deterministic and its sha256 is pinned. A re-run that does not reproduce the pin is an ERROR.

**Inventory.** Every copy of every module is kept in the inventory with its source, path, sha256 and size. Nothing is flattened. A path that appears twice in concatenated cpio archives is kept as `path#2`.

**Each of these is an ERROR:**

- **Symlinks:** any symlink inside an ext4 or `--dir` module tree, or a ramdisk symlink inside `*/lib/modules`.
- **Unsupported images:** sparse, EROFS or non-ext4.
- **Modules:** a compressed `.ko`.
- **debugfs:** any stderr output, or a dumped size that differs from the listed size.
- **Ramdisks:** a ramdisk table that does not tile the section; bad gzip/lz4/cpio data.
- **Empty sources:** a zero-module source, unless it is a `--boot` generic ramdisk or a redirect covered at the exact path.
- **Completeness:** a module named by any `modules.load*` or `modules.dep` file that is not in the inventory.
- **Same names:** differing same-name module files, or differing modules that share a `.modinfo` name. This applies unless `--allow-same-name-differing` is given, in which case all copies are required.
- **Module parse:** no `__versions`, no `module_layout`, a vermagic without `modversions`, mixed ELF machines, disagreeing vermagic flags, or conflicting import CRCs.
- **Exports:** export names that cannot be recovered. Exports are read from `__ksymtab_*` symbols, from `___ksymtab+sym` sections, and from `__ksymtab_strings`.
- **modprobe:** disagreement with `modprobe --dump-modversions`.

## `check`: gate a build

```
kgate.py check --device D --profile D.profile.json --build NAME --reference ref.json \
   --symvers Module.symvers --vmlinux vmlinux --kernel Image[.gz] --config .config \
   --requested REQ.txt --requested-config STOCK.config [--allow-config-changes X.allow] \
   (--baseline-symvers STOCKBUILD/Module.symvers | --waive-baseline "REASON")
```

### Gate mode (the default)

- Every enforcement input is required. A missing input is an ERROR. `--report-only` relaxes this and exits 3 at best.
- `--build NAME` selects the profile's per-build pins:
  - The request list and the allowlist must hash to the pinned values.
  - If no allowlist is pinned, none may be given.
  - Option-group builds must use the pinned stock-build Module.symvers as the baseline.
  - The stock build must waive its baseline explicitly.
- `--waive-baseline` is only allowed with a `--requested` list containing only `--none` (the stock-config build).
- A baseline that is the build's own Module.symvers is an ERROR.
- `--requested-config` must parse-equal the stock kernel's IKCONFIG. This applies in report-only mode too.

### Reference integrity

- The pinned sha256, device and counts must match.
- Every derived field is re-derived from the module records.
- The stock kernel is re-scanned, and its hash and kinds must match.
- A structurally invalid reference is an ERROR.

### Waivers

Waivers are recorded in the JSON `waivers` field and on the RESULT line, and only when they actually waived something:

- `baseline`;
- `ikconfig`;
- `allow-no-btf`.

### Checks

| Check | Rejects when |
|---|---|
| `crc` / `missing` / `module-layout` | A required (symbol, CRC) or `module_layout` differs, or is missing from vmlinux (an in-tree module export does not count). |
| `unversioned-imports`, `export-collision`, `symvers-duplicates` | An unversioned vendor import is missing; vmlinux exports a vendor-module symbol; or a symbol has more than one row. |
| `namespace` / `gpl-only` | A namespaced export is not in `import_ns`, or a GPL-only export is used by a non-GPL-compatible module. |
| `baseline-*` | Any export of the pinned stock build changes CRC, export type or namespace, or disappears. |
| `requested-options` | A request is not met. A request for an absent symbol is an ERROR. An empty list must say `--none`. |
| `requested-config` | **Two-way diff** of the `.config` against stock + requests. Every difference must be requested or listed with its exact value in the pinned allowlist. Only `CONFIG_PAHOLE_VERSION` (the host pahole probe; stock 0, ours 131) is WARN. |
| `vermagic` | The flags derived from `.config` differ from the stock modules' flags. |
| `btf-kinds` | Kinds beyond stock. These are ERRORs: no BTF (unless `--allow-no-btf`, which is recorded), malformed or ambiguous BTF, or a gzip Image that is not exactly one member plus zero padding. |
| `config-binding` | ERROR unless the `.config` is byte-identical to the image's embedded IKCONFIG. A kernel without IKCONFIG needs `--waive-ikconfig REASON`. |
| `input-binding` | See below. |

**`input-binding`** reports an ERROR unless all of these hold:

- **Module.symvers ↔ the decoded export tables:** the tool walks every entry of vmlinux's allocated `__ksymtab*` sections, located by the vmlinux section headers.
  - Names and namespaces are decoded only from inside the `__ksymtab_strings` section.
  - The export type is the table holding the entry.
  - The CRC is the `__kcrctab*` entry at the same index. On these kernels, the module loader compares this value with the module's `__versions` entry for a symbol found in that table.
  - **Tie to the loader:** the section headers are not in the Image. So the tool also decodes the Image's own **kallsyms** (base-relative offsets, names, markers, token table; the 4.19 and 5.10 layouts from `scripts/kallsyms.c`) and requires all of the following:
    - The kernel's `__start/__stop___ksymtab*` and `__start___kcrctab*` equal the bounds of the decoded tables. These are the symbols `kernel/module.c` uses.
    - Every entry's address field (PREL32 or absolute) equals the kallsyms address of its own name.
    - Every table is strictly ascending by name (the loader binary-searches it).
    - Allocated sections do not overlap and do not extend past the kernel's `_edata`.
    - The allocated section set equals the stock build's set, pinned in the profile as `build_sections`.
  - The kallsyms tables are *located* through `.symtab` labels, but their contents are validated structurally (counts, order, markers, token index).
  - Entry layout: 12-byte PREL32 with a namespace offset on 5.10 (Quest 3/3S); 8-byte PREL32 `{value_offset, name_offset}` on 4.19 (Quest 2/Pro, from `include/linux/export.h` and the binary). Absolute 16/24-byte layouts are also handled. The layout is derived as table size ÷ CRC count, verified on every entry, and checked against the kernel version.
  - The decoded (name, CRC, type, namespace) set must equal the Module.symvers vmlinux rows, both ways.
  - The non-loaded `.symtab` (`__crc_*`, `__ksymtab_*` symbols, their section index and address) is only a cross-check. Any disagreement is an ERROR; it is never the source of truth.
  - `CONFIG_MODULE_REL_CRCS=y` (relative CRCs) is rejected as unsupported.
- **Image ↔ vmlinux:** the kernel Image equals **exactly** what `objcopy -O binary` produces from vmlinux: every allocated section with contents at its load address, gaps zero-filled, the same length. A truncated or padded Image, or non-zero gap bytes, are rejected.
- **Banner, BTF and IKCONFIG:** the banner (the first `Linux version N.M.`), the BTF blob and the IKCONFIG match.
- **vermagic in the Image:** the Image must contain the module-loader vermagic string `<release> <stock flags>` (check `vermagic-image`).
- **Comparison method:** the Image comparison checks the length first, then streams section by section.

### Recorded hashes

The JSON records the sha256 of the reference, profile (plus its git blob id), vmlinux, kernel image, `.config`, request list, base config, allowlist, baseline and stock kernel.

### Allowlists in the v2.7 validation (`validation/requests/<dev>-<build>.allow`)

**Request fallout:**

- BTRFS_FS -> RAID6_PQ, XOR_BLOCKS, CRYPTO_XXHASH, plus RAID6_PQ_BENCHMARK on 5.10;
- AUTOFS4_FS -> AUTOFS_FS;
- USB_CONFIGFS_ACM -> USB_U_SERIAL, USB_F_ACM.

**Build-environment differences, also present in the stock-config builds:**

- Quest 3 / 3S: `CC_CAN_LINK` and `CC_CAN_LINK_STATIC` (toolchain probes).
- Quest 2 / Pro: `COMPAT_VDSO` and `GENERIC_COMPAT_VDSO`. **These change runtime behaviour for 32-bit userspace** (CRCs are unaffected) and must be forced off in the image config.

## `btf_kind_scan.py` (kind scanner)

One of `--allowed-from STOCK`, `--allowed KINDS` or `--scan-only` (exit 3) is required.

The scanner locates the blob:

- In a vmlinux, it uses the `.BTF` section.
- In a raw Image (or Image.gz with exactly one gzip member, or a boot.img kernel), **every** `magic|version 1|flags 0` occurrence must parse completely. An implausible `hdr_len` or any other defect is malformed (ERROR). Exactly one candidate may parse.

It then checks the blob's structure:

- header and reserved bytes;
- section bounds and overlap;
- the NUL first and last string bytes;
- that every record walks to the exact end of the type section, with known kinds only and reserved bits clear;
- that every `name_off` is in bounds.

Finally, it counts kinds. **This is not BTF validation.**

Decompression (gzip and lz4, for kernels and ramdisks) is capped at 256 MiB. A larger output is an ERROR (exit 2), not an out-of-memory kill.

## What is NOT checked (consequential gaps, FS-R-006 §2)

- **Forged binaries:** see the threat model. A builder who forges vmlinux, the Image *and* kallsyms consistently is out of scope. The defence is a bit-identical rebuild from pinned inputs.

- **CFI**: whether CFI type hashes and jump tables match what the vendor modules were built against. The two-way config diff against the pinned stock IKCONFIG catches a changed `CFI_CLANG` setting, but agreement of the generated CFI metadata is plausible [C], not established.
- **Config-dependent inline code, macros and constants** compiled into the vendor modules: struct layouts not covered by a CRC, static inlines, `#define` and enum values.
- **Export/provider relationships** beyond the collision, namespace and GPL checks.
- **Namespace assumptions** (USER_NS/PID_NS): unchanged CRCs do not repair behaviour compiled into existing vendor modules.
- **Runtime initialisation and behaviour**: device tree, firmware, init order, the actual module loading. Only a boot shows these.
- **Signature or trust policy**: module signing and its enforcement.
- **Stock vmlinux exports that no vendor module uses** (no stock Module.symvers exists).
- **Source-tree provenance**: any source tree that produces the pinned config and the same CRCs/tables passes. The gate does not check which commit or patches the build came from.

## How to run (WSL, Ubuntu; python3, debugfs, lz4, modprobe; mke2fs for the tests)

```sh
bash tools/kgate/test_kgate.sh                     # 170 fixture cases; exit 0 = all as expected
bash tools/kgate/validation/run_validation.sh      # gate-mode run on the real v2.7 builds
```

See `validation/run_validation.sh` for the complete per-device command lines.
