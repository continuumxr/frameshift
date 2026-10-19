# VA_BITS for K1i: 39-bit (Meta) or 48-bit (Valve)?

**Status:** research and recommendation only, rev 2, 2026-10-19 UTC (rev 1, 2026-10-18, `c9f4f62`;
rev 0, 2026-10-17, `a88ac62`). Rev 2 adds §6, the `wlan.ko` reconciliation (the K1i precondition T0 that
FS-R-015 §7 accepts as K1i preparation), and pointers to it in §0, §2.4, §4 and §5.
**Licence:** CC-BY-4.0 (our own documentation; `docs/PROVENANCE-POLICY.md` §6).

> **Correction (FS-R-015 §7, 2026-10-18).** The Chair accepted the VA48 + SysV IPC preparation and
> the VA39 control, and asked for six overclaims to be corrected. They are fixed in place below:
> 1. Valve's shipped VA48 configuration does not establish Valve's entire supported/tested matrix
>    (§0, §1.2 summary, §3.2, §3.5, §4 item 2).
> 2. Public current FEX/Wine/V8 source does not establish how the exact Steam-delivered versions behave
>    (§0, §1.2).
> 3. A fixed high mapping can fail outside the address range. An ordinary mmap hint can instead be
>    ignored, and the kernel places the mapping elsewhere (§0, §1.2).
> 4. "No new class of rebuild work" stands. "No extra cost" was too broad (§4 item 1).
> 5. Matching names, modinfo, CRCs and section sizes supports source/build correspondence. It does
>    not establish identical code (§0, §2.4).
> 6. The `module_layout` rejection is a prediction that remains to be demonstrated (§0, §2.2).
>
> The recommendation and the test plan are unchanged. No K1i boot is concurred.

No device was touched, and nothing under `/persist` or `E:` was read or written. Nothing was
downloaded or built for rev 0/1. (Rev 2 built `wlan.ko` only, offline, in a separate object directory;
§6 lists its inputs.) All commands were read-only and time-bounded: `find`, `strings`, `readelf`,
`modinfo`, `modprobe --dump-modversions` and `nm` on local copies. The sources were Meta's v2.7 GPL
tree (`~/work/kgate27/src`, commit `dbc2bc83a2b6`), our K1a build output (`~/work/kgate27/out-k1a`),
the stock v2.7 module set (`~/work/fs006-kernel/v27req/ko`, 272 modules), Valve's 0.4.5 rootfs
(`~/sf045-full`, read-only), and public upstream source and pages read on the web. Public source
was read through a fetch tool that summarises the page, so claims about those files are only as
exact as that summary. Clean-room: facts only, no code copied.

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named file, image
or source · **[D]** derived · **[C]** inferred, unconfirmed, web or community · **[O]** open.

---

## 0. The answer in brief

- **Recommendation: switch K1i to `ARM64_VA_BITS_48` (4-level page tables) now, in the same
  step as SysV IPC.** Package a VA39 control image (SysV IPC only) beside it, so that a failed
  boot can be bisected (§4).
- **Why now:** K1i already breaks the vendor-module ABI. SYSVIPC adds fields to `task_struct`,
  so every vendor module has to be rebuilt anyway (FS-A-006 group b; FS-A-013 §3.2). VA48 adds
  no new class of work to that step. Doing it later would mean a second rebuilt set, a second
  gate, a second per-module table, a second Chair round, and a second two-unit boot cycle [D].
- **Who needs 48-bit:** nothing in Valve's 0.4.5 stack *hard-requires* it according to the source
  we could read. In the **current public** source we read, FEX, Wine and Chromium/V8 detect a
  small address space and shrink to fit; the exact versions Steam delivers were not examined, so
  their behaviour is [O]. The 0.4.5 kernel Valve ships is VA48 with 4 levels (its embedded config)
  [M-static]; that is the configuration we can see, not Valve's entire supported or tested matrix
  [O]. On 39-bit, x86-64 and Win64 programs get 512 GiB instead of 128 TiB. A program that
  *requires* a fixed mapping above 2^39 fails; one that only passes an ordinary mmap hint there
  gets the hint ignored and a mapping elsewhere, which matters only if it relies on the hinted
  address. Stearlight reports a high-address failure for Proton/EAC (§1) [D/C].
- **Stock 39-bit modules cannot be used on a 48-bit kernel.** They bake in the 39-bit
  linear-map and vmemmap constants. 27 to 33 of them, including `msm_kgsl`, `arm_smmu`, `msm_drm`
  and `qcom-scm`, import the layout variables that show they inline that arithmetic. A rejection
  on `module_layout` is predicted [C] and **remains to be demonstrated** (kgate, §4 T2). Either
  way, the full set must be rebuilt from source (§2).
- **No module lacks source.** All 272 stock module names are produced by our K1a build, all
  `intree: Y`. For 271 of 272, the modinfo, imported-symbol CRCs and section sizes match stock.
  That supports source/build correspondence; it does not establish identical code (§2.4).
  **`wlan.ko` does not match** (§2.4). It must be reconciled before any rebuilt set ships, VA48
  or not [M-static]. **Rev 2: reconciled (§6).** The cause was two make variables that Meta's build
  passes and ours did not (`TARGET_BUILD_VARIANT=user`, plus disabling the qcacld build tag). With them,
  our `wlan.ko` matches stock on modinfo, all 469 imports and CRCs, and every non-debug section, and is
  byte-identical once debug info is stripped, except for the vermagic hash and the build ID [M-static].
- **The cost is small:** about 8 to 16 KiB of extra page tables per process (single-digit MiB
  in total), one more page-walk level on TLB misses, and fewer user PAC bits (16 down to 7).
  KGSL, the SMMU, Gunyah and TrustZone have no CPU-VA-width dependency in the source we read
  (§3) [M-static/D].

---

## 1. Who needs 48-bit VA in Valve's 0.4.5 userspace?

### 1.1 What is in the image

| Component | Where it lives in 0.4.5 | Evidence |
|---|---|---|
| Valve's own kernel | `boot/Image-6.18.0-ge66bc2ca6f8c`. Its embedded config (IKCONFIG) has `ARM64_VA_BITS_48=y`, `PGTABLE_LEVELS=4`, `ARM64_4K_PAGES=y`, `SYSVIPC=y`, `MODVERSIONS` off | [M-static]. The same holds for `firmware/SteamOS/extracted/config-6.18.0-gfbdbca41fd45` L326, L446 to L448 [M-static] |
| FEX | **Not in the OS image.** It is a Steam-delivered tool: `/usr/bin/FEXBash` expects `~/.steam/steam/steamapps/common/FEX-Emu` (`fex-compat-tool`) and `SteamLinuxRuntime_4` | `usr/bin/FEXBash` [M-static] |
| x86 graphics for FEX guests | `usr/share/guestos/fex-mesa`: x86-64 and i386 Mesa, including an x86-64 `libvulkan_freedreno.so` (`graphics_provider.json`) | [M-static] |
| Proton / Wine | **Not in the OS image** (delivered by Steam). Only tuning is present: `usr/lib/sysctl.d/51-proton-max-maps.conf` (`vm.max_map_count = 2147483642`) and `etc/security/limits.d/15-proton-nice.conf` | [M-static] |
| box64 | **Absent.** No file matches in the rootfs | `find` [M-static] |
| Steam client | Bootstrap `usr/lib/steam/steam.tar.zst` with a **native ARM64 client** (`steamrtarm64/`, 171 entries: `steamwebhelper`, `libcef.so`, CEF strings `Chrome/126.0.6478.183`), plus x86 `ubuntu12_32/`, `ubuntu12_64/` and `steamrt64/` | tar listing, `strings` [M-static] |
| SteamVR | `/opt/steamvr` (1.3 GB): native `bin/linuxarm64` (`vrserver`, `vrcompositor`, …), `vrwebhelper/linuxarm64`, plus `bin/linux64` and `vrclient_x64.dll` for x86 apps | [M-static]. No VA-related strings found in `bin/linuxarm64` (a weak negative) |

### 1.2 Per component: what breaks or degrades at 39-bit

**Scope of this section (correction, FS-R-015 §7).** The FEX, Wine and V8 rows describe the
**current public** source (`main`/`master`, read 2026-10-17 through a summarising fetch tool). FEX
and Proton/Wine are delivered by Steam, not shipped in the OS image (§1.1), and the Steam client's
CEF is 126. The exact delivered versions were not examined. So each row is a lead about that
component's design, not a statement of how the version a Frame user actually runs behaves [O].

**Fixed mappings and hints [D].** A request with `MAP_FIXED` or `MAP_FIXED_NOREPLACE` above the
39-bit user range cannot be satisfied there and fails. A plain mmap address hint above the range is
not an error: the kernel ignores the hint and places the mapping elsewhere. Code that then assumes
the hinted address, or checks for it and gives up, may fail later. Which of the two cases applies
depends on the program.

- **FEX** (public `FEXCore/Source/Utils/Allocator.cpp`, `main`, read 2026-10-17)
  [M-static, via fetch summary]:
  - `GetHostVABits()` probes 57, 52, 48, 47, 42, 39 and 36 bits by trying a `PROT_NONE`
    `MAP_FIXED_NOREPLACE` mapping at the top of each range. 39 is a supported answer.
  - `Setup48BitAllocatorIfExists()` does nothing below 48 bits. On a 48-bit host it reserves the
    gaps in `[2^47, 2^48)`, so that x86-64 guest pointers stay inside the 47-bit canonical user
    range, and it installs its own 64-bit allocator.
  - **Consequence at 39:** FEX runs, but without that allocator, and the guest and the JIT share
    512 GiB. x86-64 guest code that needs a fixed mapping above 2^39 fails; a hint above 2^39
    is ignored and the mapping lands lower, which breaks only code that relies on the hinted
    address [D]. All of this is the current public source; the Steam-delivered FEX version was
    not checked [O].
  - FEX's README states no VA requirement [M-static, via fetch summary].
  - FEX-2211's notes record an earlier Wine-preloader stack conflict on 48-bit hosts, since fixed
    [C, release notes].
  - Issue #5946 (open, 2026-09-10): Wine does not reserve the upper 128 TiB, so non-canonical
    pointers can leak to x86-64 guests on 48-bit hosts. That is a 48-bit-host issue that FEX
    mitigates on the Linux side [C].
- **Wine / Proton core** (public `dlls/ntdll/unix/virtual.c` and `loader/preloader.c`, `master`)
  [M-static, via fetch summary]:
  - On Win64 (including aarch64), the user-space limit is `0x7fffffff0000`, just under 2^47.
  - `get_host_addr_space_limit()` probes the real host limit, and `map_view()` clamps to it.
  - The ARM64EC code bitmap is mapped top-down, not at a fixed address. One bit per 4 KiB page
    over 128 TiB is about 4 GiB of VA [D].
  - The preloader reserves only up to 8 GiB (`0x10000` to `0x200000000`), and a failed
    reservation is non-fatal.
  - **So the public Wine `master` core, as summarised, tolerates 39-bit.** Windows programs get
    512 GiB instead of 128 TiB [D]. Whether the Wine inside the Proton version Steam delivers
    behaves the same is [O].
- **Windows programs, launchers and anti-cheat under Proton:**
  - Stearlight reports Proton/EAC launches failing with "Failed to initialize Wine helper
    buffer" on Quest 2's 39-bit kernel, because the launcher wants addresses from `0x700100000000`
    upward (`docs/research/stearlight.md` §4.5) [C, author report].
  - That address is about 2^46.8: inside a 48-bit user space, outside a 39-bit one [D].
  - Which component asks for it, and whether it is a fixed request or a hint that the program then
    checks, is not known [O]. This is the concrete reported failure at 39-bit [C, author report].
- **Steam client (native ARM64, CEF 126):**
  - `libcef.so` contains "Failed to reserve virtual memory for process-wide V8 pointer
    compression cage" and "Failed to reserve allocator region" [M-static strings]. The cage is
    4 GiB.
  - Public V8 `src/sandbox/sandbox.cc` assumes 48 bits on non-Android Linux. If the 1 TB sandbox
    reservation fails, it halves the request down to a partially-reserved sandbox, and it is fatal
    only if even the minimum fails [M-static, via fetch summary].
  - Expected: works at 39-bit, with a weaker partially-reserved V8 sandbox if CEF enables it [C].
    This reads V8 `main`; the V8 inside CEF 126 was not checked [O].
  - Chromium on Android runs on 39-bit kernels every day [C].
- **SteamVR (native ARM64):** no evidence either way [O]. x86-64 VR apps run under FEX and
  inherit the FEX row.
- **Mesa / Turnip on KGSL:** GPU VA is KGSL's own and is independent of CPU VA_BITS (§3.3).
  Android runs this stack on 39-bit [C].
- **32-bit guests** (i386 under FEX, WoW64): 4 GiB address space, unaffected [D].

**Summary [D]:** in the current public source, 39-bit is a supported-but-degraded mode for FEX,
Wine and V8; the Steam-delivered versions are [O]. It is a hard failure for a program that requires
a fixed mapping above 2^39, and possibly for one that relies on a high hint being honoured
(stearlight's reported case, mechanism [O]). Valve's shipped 0.4.5 kernel is VA48; whether Valve
supports or tests VA39 anywhere is not established by that config [O].

---

## 2. Stock vendor modules on a 48-bit kernel

### 2.1 What a module bakes in

From `arch/arm64/include/asm/memory.h` and `pgtable.h` in the v2.7 tree [M-static]:

- `PAGE_OFFSET = -(1 << VA_BITS)` (L44 to L45). That is `0xffffff8000000000` at 39 bits and
  `0xffff000000000000` at 48 bits [D].
- `VMEMMAP_START` (L50), `_PAGE_END` (L62) and, with KASAN off, `KASAN_SHADOW_END` (L79) are
  compile-time functions of `VA_BITS` / `VA_BITS_MIN`. `MODULES_VADDR` and `KIMAGE_VADDR`
  follow from them (L46 to L48).
- `__phys_to_virt` ORs in `PAGE_OFFSET` (L274), `__lm_to_phys` masks it (L256), and
  `__is_lm_address` compares against it (L254). `vmemmap` is `VMEMMAP_START - (memstart_addr >>
  PAGE_SHIFT)` (`pgtable.h` L27).
- These are inline macros, so the constants end up in each module's machine code. The runtime
  variables `memstart_addr`, `vabits_actual` and `kimage_voffset` are exported and are read at
  run time.

Stock modules that import those variables, i.e. that contain the inlined layout arithmetic
(`modprobe --dump-modversions` on the 272 stock modules) [M-static]:

- `memstart_addr`: 27 modules, including `msm_kgsl`, `arm_smmu`, `msm_drm`, `qcom-scm`,
  `qcom_dma_heaps`, `mem_buf`, `secure_buffer`, `cnss2`, `wlan`, `msm_video`, `camera`,
  `smcinvoke_mod`, `qseecom-mod` and `zsmalloc`.
- `vabits_actual`: 33 modules. `kimage_voffset`: 12 modules.

**Consequence [D]:** a 39-bit module on a 48-bit kernel would compute wrong virtual and physical
addresses in `virt_to_phys`, `page_address` and `virt_to_page`. That means silent memory
corruption in the GPU, IOMMU, DMA-heap and TrustZone paths. These modules must not load.

### 2.2 Would the loader refuse them?

- **vermagic does not help.** Stock is `5.10.246-gd7102a837402 SMP preempt mod_unload modversions
  aarch64`, ours is `5.10.246-gdbc2bc83a2b6 …` [M-static modinfo]. There is no VA field.
  `same_magic()` skips the release part when the module has CRCs (`kernel/module.c` L1373 to
  L1381) [M-static]. That is why stock modules loaded on K1a.
- **The CRCs of the layout variables do not help.** `vabits_actual 0xc56a41e6`, `memstart_addr
  0x9688de8b` and `kimage_voffset 0xe4bbc1dd` are CRCs of plain `u64`/`s64` declarations
  (`need.txt`) [M-static]. genksyms hashes the type text, so they should be identical at 48 bits
  [D].
- **`module_layout` is predicted to change [C; remains to be demonstrated, FS-R-015 §7].** The
  chain is:
  `module_layout()` (`kernel/module.c` L4878) takes `struct module *`. In `module.c`,
  `struct module_sect_attr` holds a `struct bin_attribute` (L1544). Its `mmap` takes a
  `struct vm_area_struct *` (`include/linux/sysfs.h` L176). That leads through `vm_operations_struct`
  to `struct vm_fault`, which holds `pud_t *pud` (`include/linux/mm.h` L543). `pud_t` is
  `struct { pudval_t pud; }` only when `PGTABLE_LEVELS > 3` (`pgtable-types.h` L33 to L34), and
  the folded `pgtable-nopud.h` type otherwise (L49 to L52). Every symbol whose type graph reaches
  `vm_area_struct` (`file_operations`, `mm_struct`, …) should change CRC too.
- **To prove:** a kgate run of the VA48 config against the stock reference must FAIL, and must
  show `module_layout` changed (§4, T2). If it does not change, the loader would accept stock
  modules whose imports happen to keep their CRCs. The K1i index check, which allows only our
  rebuilt set by hash, would then be the only barrier and must be made mandatory.

### 2.3 So: is the full rebuilt set needed?

**Yes [D].** At 48 bits every stock module is suspect, not only the ones whose imports change
CRC. K1i already plans "a single pinned rebuilt module set, accompanied by the per-module
provenance/CRC table" (FS-R-013 §5). With VA48 that set is simply **all 272** modules, plus the 6
new ones from K1a (`btrfs`, `autofs4`, `raid6_pq`, `xor`, `xor-neon`, `xxhash_generic`).

### 2.4 Do we have source for all of them? (Checked against K1a's output)

The comparison covered 272 stock modules against the 278 `.ko` in `out-k1a` (read-only)
[M-static]:

| Check | Result |
|---|---|
| Stock module names not produced by our build | **0**. Every stock module is built from Meta's tree |
| `intree:` | `Y` for all 272, in both the stock and the built modules |
| modinfo (excluding `filename` and `vermagic`; covering description, license, depends, softdep, aliases, params) | identical, 272/272 |
| imported symbols and CRCs (`__versions`) | identical, **271/272** |
| `.text` / `.data` / `.rodata` sizes | identical, **271/272** |
| `srcversion` | present in only 2 modules (`r8152`, `snd-soc-ak4333`); both equal |

**`wlan.ko` (qcacld-3.0) is the exception:**

- Ours imports 16 symbols that stock does not (484 against 468 undefined): `seq_read`,
  `single_open`, `panic_notifier_list`, `__nlmsg_put`, notifier-chain calls and others.
- Its sections are larger: `.text 0x621868` against `0x5a8320`, `.data 0x5de10` against
  `0xf940`, `.rodata 0x17f319` against `0x118471`.
- Our build selects `CONFIG_QCA_CLD_WLAN_PROFILE="qca6490"` in-kernel (`KERNEL_BUILD=y` path,
  `drivers/staging/qcacld-3.0/Kbuild` L14 to L22 and L61 to L63) [M-static]. Meta probably built
  it with a different profile or debug setting, perhaps as an external module [C].
- **This is a source/build difference that FS-R-013 §5 says must stay individually visible.** It
  blocks shipping our `wlan.ko` until reconciled. It is independent of VA48 [O].
- **Rev 2 (§6):** the profile guess above was wrong. Meta's module also uses the `qca6490` profile and
  was built in-tree. The difference is a build-variant setting: `TARGET_BUILD_VARIANT=user` and
  `WLAN_DISABLE_BUILD_TAG=y`. With both, the module is reconciled [M-static].

"Bit-identical" in the K1a record means our three runs are identical to *each other*. Our
modules are **not** byte-identical to Meta's: the vermagic strings differ, ours are unstripped, and
`wlan.ko` differs as above. Matching names, modinfo, CRCs and section sizes support source/build
correspondence (the same source and configuration very probably produced both); they do not
establish identical code. K1a loaded Meta's binaries, so our built modules have never run. The
K1i rebuilt-set index check and the per-module evidence stay required (FS-R-015 §7).

---

## 3. Other impacts

### 3.1 Memory

- With 4 KiB pages, VA39 uses 3 levels and the top table covers 512 GiB. VA48 adds one level: the
  PGD covers 256 TiB, and each 512 GiB slice that is in use needs one more 4 KiB PUD table [D].
- A typical arm64 process touches two slices (the PIE near `0xaaaa…`, and mmap and stack near
  2^48). That is about +8 KiB per process. An x86-64 guest under FEX might touch 3 or 4 slices,
  about +16 KiB. `PROT_NONE` reservations such as FEX's `[2^47, 2^48)` allocate no tables
  until touched [D].
- 300 to 500 processes come to roughly 2.5 to 8 MiB, about 0.1 % of 8 GiB. Kernel tables add a
  few pages. vmemmap size scales with RAM, not with VA [D].
- K1i should report `PageTables:` from `/proc/meminfo` against K1a [O].

### 3.2 TLB and performance

- A TLB miss that also misses the core's walk caches costs one more memory access [D]. The
  impact is normally small (low single-digit percent on TLB-heavy work) [C].
- Valve's shipped 0.4.5 kernel pays this cost [M-static: their config]. There is no change on TLB
  hits.
- Large blocks are unaffected: 1 GiB and 2 MiB blocks exist in both layouts [D].

### 3.3 KGSL, SMMU and the GPU bridge route

- **The KGSL GPU address space is its own and fixed:**
  - SVM `0x10_0000_0000` to `0x40_0000_0000` and VA `0x40_0000_0000` to `0x80_0000_0000`
    (`drivers/gpu/msm/kgsl_iommu.h` L68 to L71). That is 2^39 at most, whatever the CPU VA_BITS
    [M-static].
  - SVM ("use CPU map") placement searches only inside the SVM window (`kgsl.c`
    `get_svm_unmapped_area`, `kgsl_iommu.c` L1573 to L1574). That window lies inside the user
    space of both layouts [M-static/D].
  - Ordinary KGSL mmaps use the process's normal `get_unmapped_area` (`kgsl.c` L5101) and can
    land anywhere in user space, which is harmless [M-static].
- **The SMMU uses `arm_smmu` (v2, `CONFIG_ARM_SMMU=m`, `ARM_SMMU_V3` off).**
  - Its io-pgtables (LPAE, FAST) are separate from the CPU tables.
  - The only CPU-`VA_BITS` users in the driver trees are `arm-smmu-v3.c` L1960 and
    `arm-smmu-v3-sva.c`, which are not built [M-static].
  - There is no SVA (sharing CPU page tables with a device) on this platform [D].
- **A grep for hard-coded 39-bit constants** (`BIT(39)`, `<< 39`, `0x8000000000`, …) across
  `drivers/gpu/msm`, `drivers/soc/qcom`, `drivers/iommu`, qcacld core, `techpack`, `drivers/virt`
  and `kernel/sched` found only KGSL's GPU-side `KGSL_IOMMU_VA_END64` [M-static]. That is
  evidence, not proof: implicit assumptions can hide in code that this grep cannot see [C].
- **GPU bridge route (e′, `gpu-route-decision.md`):**
  - The bridge is a rebuilt module, so it is unaffected by the choice beyond "build for the kernel
    you run".
  - M3 (GPU VA windows per fd) and M4 (VM_BIND onto KGSL bind-ranges) are about the **GPU** VA.
    That space stays ≤ 2^39 under KGSL in either case, and the bridge must report KGSL's range,
    not mainline msm's larger one [D].
- **Stock 5.10 Android exposure:**
  - `ARM64_VA_BITS_39` is the Kconfig default with 4 KiB pages (`arch/arm64/Kconfig` L1003), and
    `gki_defconfig` does not override it [M-static].
  - Qualcomm and Meta's 5.10 vendor drivers are therefore exercised mostly on 39-bit. VA48 makes
    us an early user of this driver set at 48 bits: the main residual risk [C].

### 3.4 Hypervisor (Gunyah) and TrustZone

- Stage-1 translation (`TCR_EL1` T0SZ/T1SZ) belongs to the EL1 kernel. Gunyah owns stage-2,
  whose size is set by the IPA/PA width, which is already `PA_BITS=48`.
- No vendor driver touches `TCR_EL1`: a grep of `drivers/virt`, `drivers/soc/qcom` and
  `drivers/firmware/qcom*` found nothing [M-static].
- The Gunyah resource manager shares memory by IPA (`include/linux/gunyah/gh_rm_drv.h` L108
  `ipa_base`). SCM and TrustZone calls take `phys_addr_t` (`include/linux/qcom_scm.h` L88, L164,
  L168) [M-static].
- No hypervisor or TrustZone constraint on CPU VA size was found [D].
- Minidump and ramdump records hold kernel VAs, but only offline crash parsers read them, and those
  take VA_BITS from vmcoreinfo or config [C]. This has no runtime effect.
- The boot path is VA-agnostic: arm64 Image boot protocol, ABL, `kaslr-seed` [C].

### 3.5 Security side effects

- **User pointer-auth bits drop from 16 to 7.** The user PAC mask is `GENMASK_ULL(54,
  vabits_actual)` (`arch/arm64/include/asm/compiler.h` L15) [M-static]. Valve's shipped VA48
  config has the same trade-off [D].
- **mmap ASLR range grows.** `ARCH_MMAP_RND_BITS_MAX` goes from 24 to 33 (`Kconfig` L253, L258)
  [M-static]. The default `ARCH_MMAP_RND_BITS=18` is unchanged unless we raise it. Valve keeps 18
  [M-static].
- MTE, TBI, KPTI and CFI are unaffected [D].

### 3.6 Tooling

- kgate decodes the ELF sections `__ksymtab*`, `__kcrctab*` and kallsyms. A grep found no
  hard-coded kernel VA base in `tools/kgate/kgate.py` [M-static, weak]. Confirm with its fixtures
  on the first VA48 build [O].
- If KASAN is ever enabled for a debug build, `KASAN_SHADOW_OFFSET` follows VA_BITS through
  Kconfig [M-static `memory.h` L73].

---

## 4. Recommendation for K1i

**Switch to VA48 in K1i (now) [D].** Reasons, in order:

1. K1i already rebuilds the whole module set. VA48 adds **no new class of rebuild work** to that
   step. It is not free (correction, FS-R-015 §7): it adds the K1i-39 control image and its pinned
   runs, the T2/T5/T6 checks, the runtime costs in §3, and the residual risk of being an early user
   of these drivers at 48 bits (§3.3). Deferring it buys a second complete K1 cycle later.
2. It matches the configuration Valve ships in 0.4.5 (VA48, 4 levels). That shipped config does
   not establish Valve's entire supported/tested matrix [O].
3. It removes the address-range failure for fixed mappings between 2^39 and 2^48 (the reported
   Proton/EAC case, §1.2 [C]) and, in current public FEX source, FEX's reduced allocator mode.
4. The costs (§3) are small and match what Valve's shipped config pays.
5. The PM's preference for the polished long-term solution: VA39 would be a permanent deviation
   from the platform we port.

**Against, and the mitigation:** two changes in one boot step blur a failure's cause. And
Meta's 5.10 drivers are mostly exercised at 39 bits (§3.3). So build **two** images in the same
pinned pipeline. **K1i-48** (SysV IPC + VA48) is the target. **K1i-39** (SysV IPC only) is the
control, booted only if K1i-48 fails, to split "SysV/rebuild" from "VA48".

**Test plan** (offline first; device steps only under the K1i concurrence):

| # | Step | Pass condition |
|---|---|---|
| T0 | Reconcile `wlan.ko` (§2.4): find the profile or debug setting Meta used, without changing source | rebuilt `wlan.ko` matches stock modinfo, imports and section sizes, or the difference is listed in the per-module table for the Chair (FS-R-013 §5). **Met offline in rev 2 (§6); K1i's build must carry the two make variables** |
| T1 | kgate request `quest3-k1i-48.txt`: the K1g config + group b + `ARM64_VA_BITS_48` (`PGTABLE_LEVELS=4` follows). Record the olddefconfig fallout (`ARCH_MMAP_RND_BITS_MAX` 24 → 33, and others). Pinned build ×2 (about 3 h each); likewise `quest3-k1i-39.txt` | both images bit-identical across runs; every option listed with its reason (FS-A-013 §3.2) |
| T2 | kgate of K1i-48 against the **stock** reference | **FAIL is the expected result**: record the changed-CRC count and that `module_layout` changed (supporting the predicted refusal; the refusal itself is shown only by an actual load attempt, T5 being a simulation). If `module_layout` is unchanged, the index check becomes the mandatory barrier and is tested as such |
| T3 | kgate of K1i-48 against **our pinned rebuilt reference** | PASS; BTF kinds ≤ 15 |
| T4 | Per-module table (all 272 + 6): source path, shipped hash, rebuilt hash, modinfo, import and CRC diff against stock, section sizes, the `memstart_addr`/`vabits_actual` importers flagged | complete; no stock-only module; every difference visible |
| T5 | Module-load simulation (extend K1a's module-load test): every rebuilt module resolves against K1i-48's `Module.symvers` in `modules.dep` order; every stock module is rejected | 278/278 resolve; 272/272 stock refused |
| T6 | Add a read-only VA probe to the K1i runner: a `MAP_FIXED_NOREPLACE` probe at the top of the 39-, 47- and 48-bit ranges (FEX's method); print `PageTables:` | probe reports 48; `PageTables` delta against K1a recorded |
| T7 | K1i boot: Unit 2, then Unit 1 (FS-R-013): the K1a runner, the K1g probes repeated and refused, the rebuilt set loaded with its index check passed, a MemTotal check | as K1a, plus T6. K1i-39 only if K1i-48 fails |
| T8 | Later (R-1 / G-stages): FEX logs its detected host VA as 48 and takes the 48-bit allocator path; one Proton title, and one launcher that needs high mappings if we can find one | runs; no "helper buffer" class failure |

**Decisions for the PM (to be raised in chat):**

- (a) Adopt VA48 in K1i. Recommended: yes.
- (b) Package the K1i-39 control image. Recommended: yes.
- (c) Make the `wlan.ko` reconciliation (T0) a K1i precondition. Recommended: yes.
- An extra guard is possible: module signing with a FrameShift key, so that only our set loads.
  It has owner-control implications ("owners keep full admin control") and is not recommended
  without the PM's decision [O].
- The other devices are out of scope here. Quest 2 (4.19) is also VA39, and the same reasoning
  will apply under lockstep [O].

---

## 5. AI-directed text found

None. FEX's README and issue #5946, the V8 and Wine source pages, and the stearlight README were
checked. No local file read for this note contained text addressed to an AI. Rev 2 (§6) read the
qcacld-3.0 `Kbuild` and `configs/`, `README.meta.md`, the `build.config.*` files and the stock
module's strings. None contained text addressed to an AI.

---

## 6. wlan.ko reconciliation (rev 2, 2026-10-19 UTC)

This is K1i precondition T0 (§4), the "stated wlan reconciliation" that FS-R-015 §7 accepts as K1i
preparation. It was done offline. No device was touched, no download was made, and `E:` and `/persist`
were not touched. The pinned outputs (`out`, `out-k1a`, `out-k1g`) were only read. The source is Meta's
v2.7 tree `dbc2bc83a2b6` (clean). The stock module is `~/work/fs006-kernel/v27req/ko/wlan.ko` (sha256
`738d4c6a…b7368`; the 272-module v2.7 CRC reference set described in `docs/JOURNAL.md`). Clean room: Meta's binary was only compared
(`modinfo`, `modprobe --dump-modversions`, `llvm-nm`, `llvm-readelf`, section hashes, `cmp`). Nothing was
copied from it.

### 6.1 Cause [M-static]

Our build ran qcacld-3.0 in its **debug-variant** configuration. Meta's ran it in the **user** (shipping)
configuration with the build tag off. Two make variables that the kernel `.config` does not carry decide
this. Both are read only by qcacld:

1. **`TARGET_BUILD_VARIANT`** (Android's build variant, which the Android/Meta build environment exports).
   `drivers/staging/qcacld-3.0/configs/default_defconfig` (included through `qca6490_defconfig`) enables a
   debug feature set whenever it is not `user`:
   - L782–785: `CONFIG_FEATURE_PKTLOG`, `CONFIG_WLAN_DEBUG_CRASH_INJECT`;
   - L1424–1426: `CONFIG_DESC_DUP_DETECT_DEBUG`;
   - L1651–1670: `BUILD_DIAG_VERSION`, `CONFIG_DP_TRACE`, `CONFIG_WLAN_SYSFS_DP_TRACE`,
     `CONFIG_TRACE_RECORD_FEATURE`, `CONFIG_ENABLE_MTRACE_LOG`, `CONFIG_FEATURE_FW_LOG_PARSING`,
     `CONFIG_PTT_SOCK_SVC_ENABLE`, `CONFIG_WLAN_LOGGING_SOCK_SVC`,
     `CONFIG_QCACLD_WLAN_CONNECTIVITY_DIAG_EVENT`, `CONFIG_WMI_INTERFACE_EVENT_LOGGING`,
     `CONFIG_WLAN_HANG_EVENT`, and the `WLAN_LOG_DEBUG/ENTER/EXIT` log levels.

   Our K1a build left the variable unset, so all of these were compiled in.
2. **The qcacld build tag.** `default_defconfig` L282–286 sets `CONFIG_BUILD_TAG := y` unless
   `WLAN_DISABLE_BUILD_TAG=y` or `DEVELOPER_DISABLE_BUILD_TIMESTAMP=y`. `Kbuild` L4884–4900 then runs
   `git reflog` / `git log` in the source tree at build time and defines `BUILD_TAG`.
   `core/hdd/src/wlan_hdd_main.c` L578–581 appends it to `g_wlan_driver_version` (in `.data`). Stock's
   version string is the bare `5.2.1.60`. Ours is `5.2.1.60; cld:; cmn:; dev:wlan`; the IDs are empty
   because our clone is shallow. The two `fatal: ambiguous argument 'dbc2bc83a~..HEAD'` lines in K1a's
   `build.log` come from this. Apart from the mismatch, this makes K1a's `wlan.ko` depend on the git
   state of the source tree, a latent reproducibility hazard.

The 16 extra imports, each traced to the object that imports it in K1a's tree and to its option:

| Extra import(s) | Object | Option (debug variant only) |
|---|---|---|
| `___ratelimit`, `complete_and_exit`, `panic_notifier_list`, `atomic_notifier_chain_register/unregister`, `__nlmsg_put` | `cmn/utils/logging/src/wlan_logging_sock_svc.o` | `CONFIG_WLAN_LOGGING_SOCK_SVC` (`-DWLAN_LOGGING_SOCK_SVC_ENABLE`) |
| `__nlmsg_put`, `skb_queue_purge` | `cmn/utils/fwlog/dbglog_host.o` | `CONFIG_FEATURE_FW_LOG_PARSING` (object built only then, Kbuild L2112) |
| `__nlmsg_put` | `cmn/utils/ptt/src/wlan_ptt_sock_svc.o` | `CONFIG_PTT_SOCK_SVC_ENABLE` |
| `atomic_notifier_call_chain`, `atomic_/blocking_notifier_chain_register/unregister`, `blocking_notifier_call_chain` | `cmn/qdf/src/qdf_notifier.o` | `CONFIG_WLAN_HANG_EVENT` (object built only then, Kbuild L1048) |
| `seq_read`, `seq_lseek`, `seq_vprintf`, `single_open`, `single_release` | `cmn/wmi/src/wmi_unified.o` | `CONFIG_WMI_INTERFACE_EVENT_LOGGING` |

The larger `.text`/`.data`/`.rodata`/`.bss` come from the same debug set (DP trace, mtrace, WMI event
logs and their buffers). The stock strings agree. Stock has 0 `wlan_logging` and 0 `ptt_sock` strings,
against our 50 and 12.

**Ruled out:** the WLAN profile (stock also uses `qca6490`: the same `.config` value, and every
section is identical once the variables are set), an external-module build (stock's `__FILE__` strings
are the in-tree `drivers/staging/qcacld-3.0/…`, and `intree: Y`), and kernel Kconfig (`stock.config` and
K1a's `.config` have identical WLAN/CNSS symbols; `CONFIG_DEBUG_FS` is off in both).
`TARGET_BUILD_VARIANT` appears elsewhere in Meta's tree only in comments (`techpack/audio/*/Kbuild`).
`WLAN_DISABLE_BUILD_TAG` and `DEVELOPER_DISABLE_BUILD_TIMESTAMP` appear nowhere else.

**Which of the two equivalent knobs Meta used** (`WLAN_DISABLE_BUILD_TAG` or
`DEVELOPER_DISABLE_BUILD_TIMESTAMP`) cannot be read from the binary [O]. Both only gate `CONFIG_BUILD_TAG`,
so the output is the same [D]. We use `WLAN_DISABLE_BUILD_TAG=y`, the narrower name.

### 6.2 Fix

Add two make variables to the kernel build's command line. **No source change and no `.config` change.**

```
TARGET_BUILD_VARIANT=user WLAN_DISABLE_BUILD_TAG=y
```

They affect only qcacld. In the reconciliation build, all 685 recompiled objects were under
`drivers/staging/qcacld-3.0`, with 0 other `CC` lines. `vmlinux` (sha256 `8686b77c…`) and
`Module.symvers` (`0ce513c3…`) stayed equal to K1a's [M-static]. The K1i build script must pass both on
every `make` (K1i action; also proposed for adoption into the K1 build scripts generally).

### 6.3 Comparison, before and after [M-static]

"Before" is K1a's `out-k1a/…/wlan.ko` (sha256 `1e3710cd…`). "After" is this build (sha256
`1449c8b9…`). The intermediate row is `TARGET_BUILD_VARIANT=user` alone (sha256 `c6def188…`).

| Property | Stock | Before (K1a) | `user` only | After (both variables) |
|---|---|---|---|---|
| modinfo (excluding `filename`, `vermagic`) | — | identical | identical | identical |
| `__versions` entries (names + CRCs) | 469 | 485 (+16) | 469, identical | **469, identical** |
| undefined symbols | 468 | 484 | 468, identical | **468, identical** |
| `.text` size / bytes | 0x5a8320 | 0x621868 / differ | same / identical | **same / identical** |
| `.data` size / bytes | 0xf940 | 0x5de10 / differ | 0xf950 (version string +0x10) | **same / identical** |
| `.rodata` size / bytes | 0x118471 | 0x17f319 / differ | same / identical | **same / identical** |
| `.bss` size | 0x55868 | 0x14f7d8 | same | **same** |
| non-debug sections with equal size | 50 sections | 30 of 50 | 46 of 50 | **47 of 50** (`.symtab`, `.strtab`, `.shstrtab` differ only because ours carries `.debug_*`) |
| whole file after `llvm-strip --strip-debug` of a **copy** of ours | 19,996,776 B | — | same size; 867,009 bytes differ (the `.data` shift) | **same size, identical section table; 29 bytes differ** |

### 6.4 What remains different, and why

- **9 bytes in `.modinfo`: the vermagic release hash** (`5.10.246-gd7102a837402` against our
  `5.10.246-gdbc2bc83a2b6`). This is the git hash of the tree each kernel was built from. Meta's shipped
  kernel commit `d7102a837402` is not the published `dbc2bc83a2b6` (§2.2). It is expected and harmless,
  because the loader skips the release part when CRCs are present (§2.2).
- **20 bytes: the GNU build ID** (`562dca7b…` against `afaa2787…`). It is a hash over the linked output,
  so it differs because the vermagic and the debug info differ.
- **Debug info:** our `.ko` is unstripped. Stock was stripped with `--strip-debug` (as an Android
  `INSTALL_MOD_STRIP=1` install does). Whether K1i ships stripped modules is a packaging choice, not a
  build difference [O].
- **Code identity:** with debug info stripped, every byte of every section matches stock except the two
  items above. That includes `.text`, `.rodata`, `.data`, all relocation sections and the symbol table.
  This is the closest a rebuild from the published tree can come: the vermagic hash comes from the
  source commit, and the build ID follows from it [D]. It still says nothing about how the module
  behaves at run time. Our built modules have never run (§2.4).

**Incidental finding (outside `wlan.ko`; for T4) [M-static].** The same stripped byte comparison for
the other 271 modules against K1a's output: **270** are the same size and differ only in the vermagic
and build-ID bytes (≤ 29 bytes). **`socinfo.ko`** is the same size but differs in 5,555 bytes, mostly
`.rodata`. Four hardware-platform name strings in stock appear in Meta's published
`drivers/soc/qcom/socinfo.c` as `unknownN` placeholders (L64–L96). This is a published-source
redaction, not a build setting. Its modinfo, imports, CRCs and section sizes still match, which is why
§2.4 counted it as matching. It should get its own row in the T4 per-module table [O].

### 6.5 Build recipe (deterministic)

- **Script:** `~/work/k1i-wlan/build-wlan.sh` (WSL, outside the repo; sha256 `d1c9ffea…7d007`).
  1. It refuses to write under `~/work/kgate27`.
  2. It checks the source commit and that the tree is clean.
  3. It checks K1a's toolchain pins (`devices/quest3/k1a/kernel/toolchain.sha256`,
     `toolchain-clanglib.sha256`, `toolchain.links`) and K1a's `.config` sha256 `4aa0c894…`.
  4. It copies `~/work/kgate27/out-k1a` with `cp -a` to `<outdir>`, which keeps the timestamps, so only
     objects whose command line changes are rebuilt.
  5. It runs K1a's exact make line with the extra variables:

```
setarch x86_64 -R ~/toolchains/build-tools/bin/make -C ~/work/kgate27/src O=<outdir> \
  <K1a ENVV: ARCH=arm64 … LLVM=1 LLVM_IAS=1 …, as in devices/quest3/k1a/kernel/build-kernel.sh> \
  TARGET_BUILD_VARIANT=user WLAN_DISABLE_BUILD_TAG=y -j12 modules
```

  The environment is K1a's: `KBUILD_BUILD_USER=frameshift`, `KBUILD_BUILD_HOST=k1a`,
  `KBUILD_BUILD_VERSION=1`, `KBUILD_BUILD_TIMESTAMP="Wed Oct 14 00:00:00 UTC 2026"`, `TZ=UTC`,
  `LANG=C.UTF-8`, `umask 022`.
- **Invocation:** `build-wlan.sh ~/work/k1i-wlan/out ~/work/k1i-wlan/logs-runN TARGET_BUILD_VARIANT=user
  WLAN_DISABLE_BUILD_TAG=y`.
- **Runs:**
  - run 1: 2026-10-19T02:23Z, 1608 s, kept as `~/work/k1i-wlan/out-run1`;
  - run 2: 02:52Z, 1395 s, at the same path `~/work/k1i-wlan/out`.

  The two `wlan.ko` are **bit-identical** (`cmp`), sha256 `1449c8b9c90b3aad0a6fd56fbe637a7b4719fd5c598deaf7cf8f13efd2e6e11a`.
- **Records:** `~/work/k1i-wlan/logs-run{1,2}/` (build record and build log).
- **Comparison scripts:** `~/work/k1i-wlan/cmp-wlan.sh` (modinfo, `__versions`, undefined symbols,
  section sizes and hashes; outputs `cmp-before.txt`, `cmp-user.txt`, `cmp-after.txt`) and
  `cmp-stripped.sh` (strips a copy, compares byte by byte, maps the differences to sections; output
  `cmp-after-stripped.txt`).
- **For K1i:** pass the two variables in the full pinned build. The K1i rebuilt set's `wlan.ko` then
  differs from this one only through the K1i kernel changes. The VA48/SysV changes will move CRCs and
  code, so the stock comparison is meaningful only at the K1a configuration (as here).

## Sources

- Local [M-static]:
  - `~/sf045-full` (0.4.5 rootfs: `boot/Image-6.18.0-ge66bc2ca6f8c` IKCONFIG, `usr/bin/FEXBash`,
    `usr/share/guestos/fex-mesa/`, `usr/lib/steam/steam.tar.zst`, `opt/steamvr/`, `usr/lib/sysctl.d/`)
  - `firmware/SteamOS/extracted/config-6.18.0-gfbdbca41fd45`
  - `devices/quest3/k1a/kernel/k1a.config` and `BUILD-RECORD.txt`
  - `~/work/kgate27/{src,out-k1a,stock.config,need.txt}`
  - `~/work/fs006-kernel/v27req/{ko,req_versions.txt}`
  - Rev 2 (§6): `~/work/kgate27/src/drivers/staging/qcacld-3.0/{Kbuild,configs/default_defconfig,configs/qca6490_defconfig,core/hdd/src/wlan_hdd_main.c}`,
    `~/work/kgate27/src/{README.meta.md,build.config.anorak,drivers/soc/qcom/socinfo.c}`,
    `~/work/kgate27/k1a-logs/run1/build.log`, `~/work/k1i-wlan/{build-wlan.sh,cmp-*.sh,cmp-*.txt,logs-run1,logs-run2,out-run1,out}`
- Repo: `docs/research/stearlight.md` §4.5, `gpu-route-decision.md` §M3/M4,
  `FS-A-006-userspace.md` L42, FS-A-006 (private review record) L319, FS-A-013 (private review record) §3.2,
  FS-R-013 (private review record) L152, `docs/PROJECT_SETUP.md` §3.
- Web (read 2026-10-17, via fetch summary):
  - [FEX Allocator.cpp](https://raw.githubusercontent.com/FEX-Emu/FEX/main/FEXCore/Source/Utils/Allocator.cpp)
  - [FEX README](https://raw.githubusercontent.com/FEX-Emu/FEX/main/Readme.md)
  - [FEX issue #5946](https://github.com/FEX-Emu/FEX/issues/5946)
  - [FEX-2211 release notes](https://github.com/FEX-Emu/FEX/releases/tag/FEX-2211)
  - [Wine virtual.c](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/ntdll/unix/virtual.c)
    (first 100k characters only)
  - [Wine preloader.c](https://raw.githubusercontent.com/wine-mirror/wine/master/loader/preloader.c)
  - [V8 sandbox.cc](https://raw.githubusercontent.com/v8/v8/main/src/sandbox/sandbox.cc)
