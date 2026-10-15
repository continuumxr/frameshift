#!/bin/bash
# FrameShift stage-2a — generate T1-pins.json and the raw pin evidence (FS-R-006 §5 A).
# Run inside WSL: bash t1-pin.sh <outdir> [--hash-image]
# Reads ~/sfroot-full (read-only). Writes only text into <outdir> and ../T1-pins.json.
set -euo pipefail
OUT=${1:?usage: t1-pin.sh <outdir> [--hash-image]}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
R=$HOME/sfroot-full
RESTORE=$HOME/fsout                         # FS-A-001 btrfs-restore copy (second extraction path)
IMG=$ROOT/firmware/SteamOS/steamframe-oobe-repair-20260922.5153644-0.3.0.img
IMG_SHA_EXPECT=081a38c051e99c09db6ae91be994b67ef3347ea71f330d803ab861f0ba8cc654   # FS-A-001 §10
LLVM=$HOME/toolchains/clang-r450784e/bin
mkdir -p "$OUT"
P=$OUT/provenance.txt; : > "$P"
say() { printf '%s\n' "$*" | tee -a "$P"; }

FILES="lib/ld-linux-aarch64.so.1 lib/libc.so.6 bin/uname bin/b2sum"
: > "$OUT/readelf-crosscheck.txt"

say "# T1 provenance  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "image: $IMG"
say "image size: $(stat -c %s "$IMG")"
if [ "${2:-}" = --hash-image ]; then
  h=$(sha256sum "$IMG" | cut -c1-64)
  say "image sha256 (recomputed): $h"; [ "$h" = "$IMG_SHA_EXPECT" ] && say "image sha256 == FS-A-001 §10 value: YES" || say "image sha256 == FS-A-001 §10 value: NO"
else
  say "image sha256 (FS-A-001 §10, not recomputed in this run): $IMG_SHA_EXPECT"
fi
say "partition: GPT #2 'rootfs-A', first LBA 655394 x 512 = byte offset $((655394*512)), 5120 MiB, btrfs, unique GUID 0ee15513-80cf-4627-813f-d05477340f0b (FS-A-002 bundle partition-table.txt)"
say "rootfs copy: $R (kernel read-only loop mount of rootfs-A, copied with cp -a; FS-A-002 §1, §4 A)"
say "os-release: $(grep -E '^(BUILD_ID|VERSION_ID|VARIANT_ID)=' "$R/usr/lib/os-release" | tr '\n' ' ')"
say "usr/lib/os-release sha256: $(sha256sum "$R/usr/lib/os-release" | cut -c1-64) (FS-A-002 bundle MANIFEST: 3abf391a1b4b7ec94e81ed5b19e8d1aefcb1cae5b041f56d4cab92cb3c3350f7)"
say ""; say "## symlink chain"
for l in lib bin; do say "$l: $(stat -c '%F' "$R/$l") -> $(readlink "$R/$l")"; done
for f in $FILES; do
  say "$f -> $(realpath --relative-to="$R" "$R/$f")  [$(stat -c '%F' "$(realpath "$R/$f")"), no further links: $( [ -L "$(realpath "$R/$f")" ] && echo NO || echo yes )]"
done
say ""; say "## second extraction path ($RESTORE, btrfs restore; files > inline-extent size restored intact per FS-A-001)"
for f in $FILES; do
  t=usr/$f; a=$(sha256sum "$R/$t" | cut -c1-64); b=$(sha256sum "$RESTORE/$t" 2>/dev/null | cut -c1-64 || true)
  say "$t: mount-copy=$a restore-copy=${b:-absent} $( [ "$a" = "$b" ] && echo MATCH || echo DIFFER )"
done
say ""; say "## pacman ownership (usr/lib/holo/pacmandb/local)"
for f in $FILES; do
  t=usr/$f
  own=$(grep -lx "$t" "$R"/usr/lib/holo/pacmandb/local/*/files 2>/dev/null | xargs -r -n1 dirname | xargs -r -n1 basename | tr '\n' ' ')
  say "$t: ${own:-not found}"
done

say ""; say "## readelf cross-check (GNU binutils $(readelf --version | head -1 | awk '{print $NF}'); llvm-readelf $($LLVM/llvm-readelf --version | grep -m1 -i version | awk '{print $NF}'))"
for f in $FILES; do
  F=$R/usr/$f
  { echo "### $f"; readelf -hlW "$F" | grep -E 'Class|Machine|Type:|INTERP|interpreter|LOAD'; readelf -dW "$F" | grep -E 'NEEDED|RPATH|RUNPATH|FLAGS|SONAME';
    readelf -nW "$F" | grep -E 'ABI|PROPERTY|Properties' || true; $LLVM/llvm-readelf --notes "$F" | grep -iE 'property|AArch64 feature' || echo "(llvm-readelf: no GNU property notes)";
    echo "-- version needs"; readelf -VW "$F" | sed -n '/Version needs/,$p' | grep -E 'File:|Name:' || echo "(none)";
    echo "-- undefined versioned symbols"; readelf -W --dyn-syms "$F" | awk '$7=="UND" && $8!="" {print $8}' | sort; } >> "$OUT/readelf-crosscheck.txt"
done
say "written: readelf-crosscheck.txt"

# Loader/libc/coreutils-affecting environment variables (glibc 2.39 unsecvars.h,
# rtld.c process_envvars, tunables env aliases, locale, coreutils). For each, report
# whether its name (or, for LD_*, the suffix rtld matches after "LD_") occurs as a
# string in the pinned binaries: presence means the binary can read it.
python3 -I - "$R/usr/lib/ld-linux-aarch64.so.1" "$R/usr/lib/libc.so.6" "$R/usr/bin/uname" "$R/usr/bin/b2sum" > "$OUT/ldso-envvars.txt" <<'PY'
import sys
bins = {p.rsplit("/", 1)[1]: open(p, "rb").read() for p in sys.argv[1:]}
names = """LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_BIND_NOW LD_BIND_NOT
LD_DYNAMIC_WEAK LD_PROFILE LD_PROFILE_OUTPUT LD_SHOW_AUXV LD_WARN LD_VERBOSE LD_TRACE_LOADED_OBJECTS
LD_TRACE_PRELINKING LD_HWCAP_MASK LD_ORIGIN_PATH LD_USE_LOAD_BIAS LD_ASSUME_KERNEL LD_PREFER_MAP_32BIT_EXEC
LD_LIBRARY_VERSION GLIBC_TUNABLES MALLOC_CHECK_ MALLOC_TOP_PAD_ MALLOC_PERTURB_ MALLOC_MMAP_THRESHOLD_
MALLOC_TRIM_THRESHOLD_ MALLOC_MMAP_MAX_ MALLOC_ARENA_MAX MALLOC_ARENA_TEST MALLOC_TRACE GCONV_PATH
GETCONF_DIR GMON_OUTPUT_PREFIX HOSTALIASES LOCALDOMAIN LOCPATH NIS_PATH NLSPATH RESOLV_HOST_CONF
RES_OPTIONS TMPDIR TZ TZDIR LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES POSIXLY_CORRECT _POSIX2_VERSION""".split()
print("# name | binaries containing the name (LD_* also matched by suffix, as rtld compares after 'LD_')")
for n in names:
    keys = [n.encode()]
    if n.startswith("LD_"):
        keys.append(n[3:].encode())
    hit = [b for b, d in bins.items() if any(b"\x00" + k + b"\x00" in d or (b"\x00" + k + b"=") in d for k in keys)]
    print(f"{n} | {' '.join(hit) if hit else '(not found as a string; still required absent)'}")
PY
say "written: ldso-envvars.txt"

python3 -I "$HERE/elfpin.py" inspect $(for f in $FILES; do echo "$R/usr/$f"; done) > "$OUT/elfpin-inspect.json"
python3 -I - "$OUT/elfpin-inspect.json" "$R" "$HERE/../T1-pins.json" <<'PY'
import json, sys
ins, R, dst = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
order = [("lib/ld-linux-aarch64.so.1", "usr/lib/ld-linux-aarch64.so.1", "lib -> usr/lib"),
         ("lib/libc.so.6", "usr/lib/libc.so.6", "lib -> usr/lib"),
         ("bin/uname", "usr/bin/uname", "bin -> usr/bin"),
         ("bin/b2sum", "usr/bin/b2sum", "bin -> usr/bin")]
files = []
for staged, real, link in order:
    e = ins[f"{R}/{real}"]
    files.append({"path": staged, "rootfs_link_path": "/" + staged, "rootfs_real_path": "/" + real,
                  "symlink": link, **{k: e[k] for k in (
        "size", "sha256", "blake2b512", "elf_class", "e_machine", "e_type", "pt_interp", "dt_needed",
        "dt_rpath", "dt_runpath", "dt_soname", "dt_flags", "dt_flags_1", "aarch64_bti", "aarch64_pac",
        "gnu_property", "pt_load_align", "abi_tag", "verneed")}})
pins = {
  "schema": "frameshift.t1-pins.v1",
  "ruling": "FS-R-006 §5 A (experiment (i))",
  "source": {"image": "steamframe-oobe-repair-20260922.5153644-0.3.0.img",
             "image_sha256": "081a38c051e99c09db6ae91be994b67ef3347ea71f330d803ab861f0ba8cc654",
             "partition": {"index": 2, "label": "rootfs-A", "first_lba": 655394, "byte_offset": 335561728,
                           "size_mib": 5120, "fs": "btrfs", "unique_guid": "0ee15513-80cf-4627-813f-d05477340f0b"},
             "build_id": "20260922.6152327", "version_id": "0.3.0", "variant_id": "vr", "channel": "rc",
             "extraction": "kernel read-only loop mount of rootfs-A, cp -a to WSL ~/sfroot-full (FS-A-002 §1)"},
  "staged_root": "/valve",
  "loader": "lib/ld-linux-aarch64.so.1",
  "executables": ["bin/uname", "bin/b2sum"],
  "expected_pt_interp": "/lib/ld-linux-aarch64.so.1",
  "expected_pt_interp_hex": "2f6c69622f6c642d6c696e75782d616172636836342e736f2e3100",
  "invocation": "/valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib /valve/bin/<prog> [args]",
  "total_bytes": sum(f["size"] for f in files),
  "files": files,
}
json.dump(pins, open(dst, "w"), indent=1); open(dst, "a").write("\n")
print("wrote", dst, "total", pins["total_bytes"])
PY
say "written: ../T1-pins.json"
