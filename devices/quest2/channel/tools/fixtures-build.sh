#!/bin/bash
# FrameShift Quest 2 channel - build-gate fixtures (rev 3 N2; rev 4 final re-review R2). Run inside WSL:
#   wsl.exe -e bash <repo>/devices/quest2/channel/tools/fixtures-build.sh
# Crafted variants are made from a TEMP COPY of src/fs-rpcd.c (the repo source is never edited):
# each appends one function, is compiled with the shipped flags, and must be REJECTED by the
# source gate (tools/src-gate.sh) AND/OR the object gate (tools/undef-gate.sh, with the committed
# allowlist and the pin read from build.sh). The real source passes both. Also: an allowlist that
# lists a forbidden name, and an edited allowlist whose sha256 no longer matches the pin, are
# refused. Writes fixtures/buildgate/RESULTS.txt.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest2/channel
CL=$HOME/toolchains/clang-r450784e/bin
NM=$CL/llvm-nm
OD=$CL/llvm-objdump
ALLOW=$HERE/tools/fs-rpcd.undef.allow
GATE=$HERE/tools/undef-gate.sh
SGATE=$HERE/tools/src-gate.sh
PIN=$(sed -n 's/^ALLOW_PIN=\([0-9a-f]\{64\}\).*/\1/p' "$HERE/tools/build.sh")
FX=$HERE/fixtures/buildgate; mkdir -p "$FX"; SUM=$FX/RESULTS.txt; : > "$SUM"
W=$(mktemp -d /tmp/fsq2gate.XXXXXX); trap 'rm -rf "$W"' EXIT
CFLAGS="--target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -fno-ident"
echo "fs-rpcd.c     sha256=$(sha256sum "$HERE/src/fs-rpcd.c" | cut -c1-64)" | tee -a "$SUM"
echo "allowlist     sha256=$(sha256sum "$ALLOW" | cut -c1-64) (pin in build.sh: $PIN)" | tee -a "$SUM"
echo "undef-gate.sh sha256=$(sha256sum "$GATE" | cut -c1-64)" | tee -a "$SUM"
echo "src-gate.sh   sha256=$(sha256sum "$SGATE" | cut -c1-64)" | tee -a "$SUM"
res() { local l; if [ "$2" = 0 ]; then l="$1 PASS $3"; else l="$1 FAIL $3"; fi; echo "$l" | tee -a "$SUM"; }
[ -n "$PIN" ] || { res B-pin-readable 1 "no ALLOW_PIN in build.sh"; exit 1; }

# variant NAME INCLUDES BODY WANT : WANT = src (the source gate must reject), obj (the object gate
# must reject), both (each must reject). The body goes into a new function in a temp copy.
variant() {
    local n=$1 want=$4 so oo sr=0 orc=0
    { printf '%s\n' "$2"; cat "$HERE/src/fs-rpcd.c"; printf '\nvoid fs_crafted_%s(void);\nvoid fs_crafted_%s(void) { %s }\n' "$n" "$n" "$3"; } > "$W/$n.c"
    so=$("$SGATE" "$W/$n.c" "$CL/clang"); sr=$?
    # shellcheck disable=SC2086
    if ! "$CL/clang" $CFLAGS -c -o "$W/$n.o" "$W/$n.c" 2> "$W/$n.cc"; then
        # want=srccc: the shipped flags themselves refuse it (e.g. -Werror,-Wtrigraphs); the source gate must too
        if [ "$want" = srccc ] && [ $sr = 1 ]; then res "B-$n-rejected(src+compiler)" 0 "src: $so | compiler: $(grep -m1 error "$W/$n.cc" | head -c 160)"
        else res "B-$n" 1 "did not compile: $(head -c 200 "$W/$n.cc")"; fi
        return
    fi
    oo=$("$GATE" "$NM" "$OD" "$W/$n.o" "$ALLOW" "$PIN" "$W/$n.undef"); orc=$?
    local ok=1
    case $want in
        src)  [ $sr = 1 ] && ok=0 ;;
        obj)  [ $orc = 1 ] && ok=0 ;;
        both) [ $sr = 1 ] && [ $orc = 1 ] && ok=0 ;;
    esac
    res "B-$n-rejected($want)" $ok "src: $so | obj: $oo"
}
# the real source passes both gates
"$SGATE" "$HERE/src/fs-rpcd.c" "$CL/clang" > "$W/real.src"; rs=$?
# shellcheck disable=SC2086
"$CL/clang" $CFLAGS -c -o "$W/real.o" "$HERE/src/fs-rpcd.c" || exit 1
out=$("$GATE" "$NM" "$OD" "$W/real.o" "$ALLOW" "$PIN" "$W/real.undef"); ro=$?
[ $rs = 0 ] && [ $ro = 0 ]; res B-real-source-passes $? "src: $(cat "$W/real.src") | obj: $out"
variant syscall_execve '#include <sys/syscall.h>' 'char *a[] = { "/bin/sh", 0 }; syscall(SYS_execve, "/bin/sh", a, a);' both
variant syscall_any '#include <sys/syscall.h>' 'syscall(SYS_getpid);' both
variant system '#include <stdlib.h>' 'if (system("id")) {}' both
variant popen '#include <stdio.h>' 'FILE *f = popen("id", "r"); if (f) pclose(f);' both
variant execvp '#include <unistd.h>' 'char *a[] = { "sh", 0 }; execvp("sh", a);' both
variant posix_spawn '#include <spawn.h>' 'pid_t p; char *a[] = { "sh", 0 }; posix_spawn(&p, "/bin/sh", 0, 0, a, a);' both
variant dlopen '#include <dlfcn.h>' 'if (dlopen("x", 0)) {}' obj
variant vfork '#include <unistd.h>' 'if (vfork() == 0) _exit(0);' both
# rev 4: inline supervisor call (no symbol at all: only the svc token / instruction scans see it)
variant inline_svc '' '__asm__ volatile("mov x8, #221\n\tsvc #0" ::: "x8", "memory");' both
# rev 4: execve taken as a function pointer (extra ADR/ADD relocations; the textual gate does not
# see "execve(" twice, the relocation count does)
variant execve_fnptr '#include <unistd.h>' 'static int (*volatile fp)(const char *, char *const[], char *const[]); fp = execve; char *a[] = { "sh", 0 }; fp("/bin/sh", a, a);' obj
# rev 4: a second direct execve call site
variant execve_second_call '#include <unistd.h>' 'char *a[] = { "sh", 0 }; execve("/bin/sh", a, a);' both
# rev 5 (verification V1): token-pasted inline asm emitting a raw svc/hvc/smc as DATA in .text.
# objdump prints .word/.byte as data, so only the raw-word scan (obj-scan.py) sees them; the
# source gate refuses the ## that builds __asm__.
variant paste_word_svc '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".word 0xd4000001");' both
variant paste_byte_svc '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".byte 0x01,0x00,0x00,0xd4");' both
variant paste_word_hvc '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".word 0xd4000002");' both
variant paste_inst_smc '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".inst 0xd4000003");' both
variant paste_word_svc_imm '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".word 0xd401ffe1");' both
# _Pragma is refused by the source gate (it can carry anything to the compiler)
variant pragma '' '_Pragma("GCC diagnostic push") _Pragma("GCC diagnostic pop")' src
# no asm token, no ##: a constant placed in .text by a section attribute - the object scan alone
variant section_text_word '' 'static const unsigned int fs_w __attribute__((used, section(".text"))) = 0xd4000001u; (void)fs_w;' obj
# rev 6: data relocations into code. ".reloc ., R_AARCH64_ABS32, 0xd4000001" over a nop: the object
# shows a nop and lld writes svc #0 into it. B = built with ## ; D = a line splice building __asm__
# around a raw .inst svc; E = a line splice around the .reloc+nop (the reviewer's bypass E).
variant B_paste_reloc_abs32 '#define FS_CAT(a,b) a##b' 'FS_CAT(__as, m__) volatile(".reloc ., R_AARCH64_ABS32, 0xd4000001\n\tnop");' both
variant D_splice_inst_svc '' $'__as\\\nm__ volatile(".inst 0xd4000001");' both
variant E_splice_reloc_abs32 '' $'__as\\\nm__ volatile(".reloc ., R_AARCH64_ABS32, 0xd4000001\\n\\tnop");' both
variant E2_splice_reloc_prel32 '' $'__as\\\nm__ volatile(".reloc ., R_AARCH64_PREL32, main\\n\\tnop");' both
variant E3_splice_reloc_abs16 '' $'__as\\\nm__ volatile(".reloc ., R_AARCH64_ABS16, 0x0001\\n\\tnop");' both
# an INSTRUCTION relocation on a word that is not its instruction class: ADRP-HI21 rewrites bits
# 5-23 and 29-30, so a crafted 0xd4e00001 (not an svc encoding) could become svc #0 at link time
variant F_splice_hi21_on_fake_svc '' $'__as\\\nm__ volatile(".reloc ., R_AARCH64_ADR_PREL_PG_HI21, main\\n\\t.inst 0xd4e00001");' both
# trigraph ??/ splice (-std=c11 enables trigraphs; the shipped -Werror makes -Wtrigraphs fatal, so
# the compiler refuses it as well) and digraph %:%: paste
variant G_trigraph_splice '' $'__as??/\nm__ volatile(".inst 0xd4000001");' srccc
variant H_digraph_paste '%:define FS_CAT(a,b) a%:%:b' 'FS_CAT(__as, m__) volatile(".inst 0xd4000001");' both
# rev 6: the PREPROCESSED check on its own: a macro from a local header expands to __asm__ inside
# the source's lines; the raw text of the .c has no asm token, no ##, no splice
printf '%s\n' '#define FS_HIDE __asm__' > "$W/fs_evil.h"
variant I_macro_from_local_header '#include "fs_evil.h"' 'FS_HIDE volatile(".inst 0xd4000001");' both
# rev 6: malformed objects (crafted from a temp copy of the real object) must FAIL CLOSED
for m in m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11; do
    python3 -I -B "$HERE/tools/elf-mutate.py" "$W/real.o" "$W/$m.o" $m
    out=$(python3 -I -B "$HERE/tools/obj-scan.py" "$W/$m.o"); rc=$?
    gout=$("$GATE" "$NM" "$OD" "$W/$m.o" "$ALLOW" "$PIN" "$W/$m.undef" 2>&1); grc=$?
    [ $rc = 2 ] && [ $grc != 0 ]
    res "B-malformed-$m-fails-closed" $? "obj-scan rc=$rc: $out | undef-gate rc=$grc"
done
# rev 6: the linked binary's executable pages (nit H): the shipped link passes, the default link
# (no -z separate-code) is refused because .rodata's tail shares the first executable page
python3 -I -B "$HERE/tools/seg-check.py" "$HERE/build/fs-rpcd" > "$W/seg1"; r1=$?
# shellcheck disable=SC2086
"$CL/clang" $CFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o "$W/default-link" "$HERE/src/fs-rpcd.c"
python3 -I -B "$HERE/tools/seg-check.py" "$W/default-link" > "$W/seg2"; r2=$?
if [ -f "$HERE/build/fs-rpcd" ]; then res B-seg-shipped-binary-separate-code $r1 "$(cat "$W/seg1")"
else echo "B-seg-shipped-binary-separate-code SKIP (withheld evidence: the fs-rpcd binary is not in the public copy; build it with tools/build.sh)" | tee -a "$SUM"; fi
[ $r2 = 1 ]; res B-seg-default-link-refused $? "$(cat "$W/seg2")"
# an allowlist that lists a forbidden name is refused outright (pin updated to match, so only the
# forbidden-entry rule can refuse it)
cp "$ALLOW" "$W/bad.allow"; echo syscall >> "$W/bad.allow"
out=$("$GATE" "$NM" "$OD" "$W/real.o" "$W/bad.allow" "$(sha256sum "$W/bad.allow" | cut -c1-64)" "$W/x.undef"); rc=$?
[ $rc = 1 ] && case "$out" in *"forbidden entry"*) true ;; *) false ;; esac
res B-forbidden-allowlist-entry-refused $? "$out"
# rev 4: an EDITED allowlist (a harmless-looking addition) with the build.sh pin unchanged
cp "$ALLOW" "$W/edited.allow"; echo getppid >> "$W/edited.allow"
out=$("$GATE" "$NM" "$OD" "$W/real.o" "$W/edited.allow" "$PIN" "$W/y.undef"); rc=$?
[ $rc = 1 ] && case "$out" in *"does not match the pin"*) true ;; *) false ;; esac
res B-edited-allowlist-refused-by-pin $? "$out"
n=$(awk '$2 == "PASS"' "$SUM" | wc -l); f=$(awk '$2 == "FAIL"' "$SUM" | wc -l); s=$(awk '$2 == "SKIP"' "$SUM" | wc -l)
if [ "$s" -gt 0 ]; then echo "TOTAL $n PASS, $f FAIL, $s SKIP" | tee -a "$SUM"; else echo "TOTAL $n PASS, $f FAIL" | tee -a "$SUM"; fi
[ "$f" = 0 ]
