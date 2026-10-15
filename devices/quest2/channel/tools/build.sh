#!/bin/bash
# FrameShift Quest 2 channel — build fs-rpcd (static aarch64) plus a native
# ASan/UBSan build used only by the fixtures. Run inside WSL:
#   wsl.exe -e bash <repo>/devices/quest2/channel/tools/build.sh
# Offline only: builds and inspects binaries; touches no device.
# Same compiler and flags as devices/quest3/common/tools/build.sh (fs-supervise).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest2/channel
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
SRC=$HERE/src/fs-rpcd.c
OUT=$HERE/build
mkdir -p "$OUT"

die() { echo "BUILD FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -c1-64; }
[ -x "$CLANG" ] || die "clang missing"

CFLAGS="--target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE \
 -Wall -Wextra -Werror -fno-ident"
# rev 6 (nit H): -z separate-code puts the executable segment on pages of its own (no .rodata
# tail on an executable page); tools/seg-check.py verifies the linked binary below.
LDFLAGS="-fuse-ld=lld -Wl,--build-id=none -Wl,-z,separate-code"
build() {  # build <output>
    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS $LDFLAGS -s -o "$1" "$SRC"
}
build "$OUT/fs-rpcd"
build "$OUT/fs-rpcd.rebuild"
B=$OUT/fs-rpcd
# outputs are captured first: `cmd | grep -q` under pipefail can return 141 (review M1)
FILEOUT=$(file -b "$B"); HDR=$(readelf -h "$B"); PH=$(readelf -l "$B"); DYN=$(readelf -d "$B" 2>/dev/null || true)
case "$FILEOUT" in *"ARM aarch64"*) ;; *) die "not aarch64" ;; esac
case "$HDR" in *"Type:"*"EXEC"*) ;; *) die "not ET_EXEC" ;; esac
case "$PH" in *INTERP*) die "has a program interpreter" ;; esac
case "$DYN" in *NEEDED*) die "has dynamic dependencies" ;; esac
cmp -s "$B" "$OUT/fs-rpcd.rebuild" || die "build is not reproducible"
SEG_LINE=$(python3 -I -B "$HERE/tools/seg-check.py" "$B") || { echo "$SEG_LINE"; die "executable-page check (tools/seg-check.py)"; }
rm -f "$OUT/fs-rpcd.rebuild"
# the compiled-in bounds must be the documented ones (README §3.3)
for c in "REQ_MAX        64" "REQ_MS         3000" "WRITE_MS       30000" "COLLECT_MAX    (8 \* 1024 \* 1024)" "COLLECT_S_MAX  104" "MAXCONN_MAX    1000" "REAP_MS        2000" "REAP_KILL_MS   2000" "TRAIL_MS       75" "SWEEP_MS       2000"; do
    grep -q "^#define $c" "$SRC" || die "bound changed: $c"
done
# Exec / shell gates (revision 2 M1, revision 3 N2, revision 4 final re-review R2). No pipes into
# grep -q (pipefail SIGPIPE, review M1). The binary DOES contain "/bin/sh": static glibc links
# popen/posix_spawn/execvpe through libio; what is checked is fs-rpcd's OWN code:
#   1. textual (tools/src-gate.sh): no asm/__asm/__asm__/svc/hvc/smc token, no call of
#      system/popen/posix_spawn*/exec* (except one execve)/execveat/vfork/clone*/syscall;
#   2. object (tools/undef-gate.sh): the allowlist matches the pin below; every external symbol
#      of fs-rpcd.o is allowlisted; exactly one relocation names execve and it is a direct call
#      (CALL26/JUMP26; a function-pointer take fails); no svc/hvc/smc instruction in the object;
#   3. binary: the "/bin/sh" string is recorded (present, from glibc), not denied.
# Defence in depth on top of source review; tools/fixtures-build.sh shows each gate rejecting a
# crafted temp-copy variant (syscall, system, popen, execvp, posix_spawn, dlopen, inline svc,
# execve function pointer, second execve call, vfork, an edited allowlist; rev 5: token-pasted
# .word/.byte/.inst svc/hvc/smc, _Pragma, a constant placed in .text by a section attribute).
ALLOW_PIN=58ceb1e849cf1e519ff896fdcad9c80dc16ebd77539657a1cd8f30d19e0ec701   # sha256 of the REVIEWED tools/fs-rpcd.undef.allow
SRC_LINE=$("$HERE/tools/src-gate.sh" "$SRC" "$CLANG") || { echo "$SRC_LINE"; die "source gate"; }
LLVM_NM=$(dirname "$CLANG")/llvm-nm
LLVM_OBJDUMP=$(dirname "$CLANG")/llvm-objdump
[ -x "$LLVM_NM" ] && [ -x "$LLVM_OBJDUMP" ] || die "llvm-nm/llvm-objdump missing"
# shellcheck disable=SC2086
"$CLANG" $CFLAGS -c -o "$OUT/fs-rpcd.o" "$SRC" || die "object build"
"$HERE/tools/undef-gate.sh" "$LLVM_NM" "$LLVM_OBJDUMP" "$OUT/fs-rpcd.o" "$HERE/tools/fs-rpcd.undef.allow" "$ALLOW_PIN" "$OUT/fs-rpcd.undef" > "$OUT/gate.out" || { cat "$OUT/gate.out"; die "object gate"; }
GATE_LINE=$(tail -1 "$OUT/gate.out"); rm -f "$OUT/gate.out" "$OUT/fs-rpcd.o"
grep -qx execve "$OUT/fs-rpcd.undef" || die "object does not reference execve"
# revision 4 (final re-review R3): the -T cap must be usable for the largest DEADLINE PID 1 allows
python3 -I -B "$HERE/tools/check-timing.py" > "$OUT/timing.out" || { cat "$OUT/timing.out"; die "timing check (tools/check-timing.py)"; }
TIMING_LINE=$(grep '^R3 ' "$OUT/timing.out"); rm -f "$OUT/timing.out"
strings -a "$B" > "$OUT/fs-rpcd.strings"
if grep -qx '/bin/sh' "$OUT/fs-rpcd.strings"; then BINSH=present; else BINSH=absent; fi
rm -f "$OUT/fs-rpcd.strings"

# native sanitizer build (fixtures only; never shipped)
gcc -O1 -g -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer -o "$OUT/fs-rpcd.asan" "$SRC" || die "native asan build"
# native plain build + waitpid shim (fixtures only: X5 simulates an unreapable runner via LD_PRELOAD)
gcc -O1 -g -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -o "$OUT/fs-rpcd.native" "$SRC" || die "native build"
gcc -O1 -shared -fPIC -Wall -Wextra -Werror -o "$OUT/shim-nowait.so" "$HERE/tools/shim_nowait.c" -ldl || die "shim build"

{
echo "fs-rpcd build record"
echo "date_utc:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "compiler:   $("$CLANG" --version | head -1)"
echo "command:    $CLANG $CFLAGS $LDFLAGS -s -o build/fs-rpcd src/fs-rpcd.c" | tr -s ' '
echo "source:     src/fs-rpcd.c sha256=$(sha "$SRC")"
echo "libc:       $(dpkg-query -W -f='${Package} ${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown) (static glibc)"
echo "binary:     build/fs-rpcd sha256=$(sha "$B") size=$(stat -c %s "$B")"
echo "elf:        $(file -b "$B")"
echo "checks:     aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild, bounds unchanged"
echo "framing:    these gates are defence in depth against ACCIDENTAL or CARELESS changes; a determined source editor with control of the toolchain can defeat any static gate, so human source review of src/fs-rpcd.c remains the control"
echo "gates:      textual (tools/src-gate.sh), on the raw text AND on clang -E output restricted to lines from src/fs-rpcd.c: no asm/__asm/__asm__/svc/hvc/smc token, no ## / _Pragma, no backslash-newline splice outside a directive, no trigraph, no digraph %:, no call of system/popen/posix_spawn*/exec* except one execve, execveat, vfork, clone*, syscall: $SRC_LINE"
echo "gates:      object (tools/undef-gate.sh): $GATE_LINE"
echo "gates:      object raw scan (tools/obj-scan.py, fail closed): ELF64/LE/AArch64/ET_REL with a sane section table; exactly one code section (PROGBITS .text, SHF_EXECINSTR); no svc/hvc/smc encoding in its raw words; no \$d in code; every relocation into .text is an instruction relocation (CALL26 JUMP26 ADR_PREL_PG_HI21[_NC] ADD_ABS_LO12_NC LDST8/16/32/64/128_ABS_LO12_NC CONDBR19 TSTBR14) on a word of its instruction class, so data relocations (ABS*/PREL*) cannot write an svc at link time; RELA only, into .text or a known data section"
echo "gates:      execve: the relocation check limits execve CALL SITES to one direct call; it does not constrain the arguments or how often that site runs (arguments: source review: argv = { -c runner path, validated 32-hex challenge }, env = { PATH=/bin:/sbin })"
echo "gates:      allowlist tools/fs-rpcd.undef.allow sha256=$(sha "$HERE/tools/fs-rpcd.undef.allow") (pinned in build.sh); crafted-variant and malformed-object rejections: tools/fixtures-build.sh"
echo "link:       -z separate-code; linked binary (tools/seg-check.py): $SEG_LINE"
echo "timing:     tools/check-timing.py CONSISTENT; $TIMING_LINE"
echo "gates:      scope: fs-rpcd's own source text, preprocessed text, symbols, relocations and raw code bytes, under the default lld section mapping; not a proof about libc internals"
echo "subreaper:  prctl(PR_SET_CHILD_SUBREAPER) at start; reparented runner orphans are SIGKILLed after each collect (<= 2 s, WNOHANG reaping)"
echo "/bin/sh:    string $BINSH in the binary: static glibc links popen/posix_spawn/execvpe (via libio); fs-rpcd's object does not reference them (object gate above)."
echo "fixture:    build/fs-rpcd.native + build/shim-nowait.so (x86_64, fixtures only; LD_PRELOAD waitpid shim for X5)"
echo "fixture:    build/fs-rpcd.asan ($(gcc --version | head -1); -fsanitize=address,undefined; x86_64, fixtures only)"
} | tee "$OUT/BUILD.txt"
