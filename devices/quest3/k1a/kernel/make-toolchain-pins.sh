#!/bin/bash
# K1a kernel: (re)writes the toolchain pins that build-kernel.sh checks before it builds (review M1, m5). Offline, WSL.
#   toolchain.sha256          sha256 of every binary the build runs (the clang/LLVM tools the make variables name, AOSP make,
#                             pahole, which writes the vmlinux .BTF and so the Image bytes, and pahole's dwarves/dw/elf
#                             libraries) and the sample-PGO profile vmlinux.profdata
#   toolchain-clanglib.sha256 sha256 of every file of clang's resource directory (lib64/clang/14.0.7: the compiler's own
#                             headers and runtime files)
#   toolchain.links           each tool name the make variables use -> the file it resolves to (ld.lld -> lld, ...)
# Recorded, not pinned (build-record.txt): python3, perl, tar, xz, the host kernel and glibc.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CL=$HOME/toolchains/clang-r450784e/bin
TOOLS="clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-size llvm-strip"
{
  for b in $TOOLS; do readlink -f "$CL/$b"; done | sort -u
  readlink -f "$HOME/toolchains/build-tools/bin/make"
  readlink -f /usr/bin/pahole
  ldd /usr/bin/pahole | awk '$3 ~ /^\// {print $3}' | grep -E 'libdwarves|libdw|libelf' | xargs -r -n1 readlink -f | sort -u
  readlink -f "$HOME/work/kgate27/src/vmlinux.profdata"
} | xargs sha256sum > "$HERE/toolchain.sha256"
find "$CL/../lib64/clang" -type f | LC_ALL=C sort | xargs sha256sum | sed "s#$(readlink -f "$CL/..")#$HOME/toolchains/clang-r450784e#" > "$HERE/toolchain-clanglib.sha256"
for b in $TOOLS; do printf '%s %s\n' "$b" "$(readlink -f "$CL/$b")"; done > "$HERE/toolchain.links"
echo "toolchain.sha256: $(wc -l < "$HERE/toolchain.sha256") files; toolchain-clanglib.sha256: $(wc -l < "$HERE/toolchain-clanglib.sha256") files; toolchain.links: $(wc -l < "$HERE/toolchain.links")"
