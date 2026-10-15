#!/bin/bash
# FrameShift Quest 2 channel - OBJECT gate for fs-rpcd (rev 3 N2; rev 4 final re-review R2).
#   undef-gate.sh LLVM_NM LLVM_OBJDUMP OBJECT ALLOWLIST ALLOWLIST_SHA256 OUT_UNDEF
# Checks on the compiled fs-rpcd.o (fs-rpcd's own code only; libc is linked later):
#   1. pin: sha256(ALLOWLIST) equals ALLOWLIST_SHA256 (pinned in build.sh), so editing the list
#      fails the build unless the pin is edited too (a second, visible change to review);
#   2. the allowlist names nothing forbidden (shell-capable, raw syscall, extra process creation,
#      dynamic loading);
#   3. every undefined (external) symbol of the object is in the allowlist (llvm-nm -u), written
#      sorted to OUT_UNDEF - a denylist could not see a new route such as syscall(SYS_execve);
#   4. relocations: exactly ONE relocation names execve, and it is a direct branch
#      (R_AARCH64_CALL26 or R_AARCH64_JUMP26). Taking execve's address (a function pointer) adds
#      ADR_PREL_PG_HI21/ADD_ABS_LO12_NC relocations and fails; a second call site fails;
#   5. the object's own code contains no svc/hvc/smc instruction (llvm-objdump -d): no inline
#      system call reaches the kernel without going through an allowlisted libc function;
#   6. (rev 5, verification V1) tools/obj-scan.py reads the RAW bytes of every executable section
#      and refuses any aligned word encoding svc/hvc/smc ((w & 0xffe0001f) in d4000001..3) and any
#      $d mapping symbol in code. Step 5 alone misses data emitted into .text (.word/.byte), which
#      objdump prints as data, not as svc.
# Step 4 limits execve call SITES to one; it does not constrain the arguments or how often that
# site runs (arguments: source review).
# These prove properties of the object's symbols, relocations and instructions; they are defence
# in depth on top of source review, not a proof about what the allowlisted functions can do.
set -u
NM=$1 OBJDUMP=$2 OBJ=$3 ALLOW=$4 PIN=$5 OUTU=$6
fail() { echo "UNDEF GATE FAILED: $*"; exit 1; }
[ -x "$NM" ] || fail "llvm-nm missing"
[ -x "$OBJDUMP" ] || fail "llvm-objdump missing"
[ -f "$OBJ" ] || fail "no object"
[ -f "$ALLOW" ] || fail "no allowlist"
got=$(sha256sum "$ALLOW" | cut -c1-64)
[ "$got" = "$PIN" ] || fail "allowlist sha256 $got does not match the pin in build.sh ($PIN)"
FORBID='system|popen|posix_spawnp?|execl|execlp|execle|execv|execvp|execvpe|fexecve|execveat|vfork|clone|clone3|__clone|__libc_system|syscall|ptrace|dlopen|dlsym'
ALLOWED=$(grep -Ev '^(#|$)' "$ALLOW" | sort -u)
if printf '%s\n' "$ALLOWED" | grep -Eqx "$FORBID"; then fail "allowlist contains a forbidden entry"; fi
printf '%s\n' "$ALLOWED" | grep -qx execve || fail "allowlist lacks execve (the one fixed runner exec)"
SYMS=$("$NM" -u "$OBJ") || fail "llvm-nm failed"
printf '%s\n' "$SYMS" | awk 'NF {print $NF}' | sort -u > "$OUTU"
EXTRA=$(comm -23 "$OUTU" <(printf '%s\n' "$ALLOWED"))
MISSING=$(comm -13 "$OUTU" <(printf '%s\n' "$ALLOWED"))
[ -n "$MISSING" ] && echo "undef-gate: allowlisted but unused: $(printf '%s ' $MISSING)"
if [ -n "$EXTRA" ]; then fail "symbols outside the allowlist: $(printf '%s ' $EXTRA)"; fi
REL=$("$OBJDUMP" -r "$OBJ") || fail "llvm-objdump -r failed"
EXR=$(printf '%s\n' "$REL" | awk '$NF == "execve" {print $2}')
NEX=$(printf '%s\n' "$EXR" | grep -c .)
[ "$NEX" = 1 ] || fail "expected exactly one relocation naming execve, found $NEX: $(printf '%s ' $EXR)"
case "$EXR" in R_AARCH64_CALL26|R_AARCH64_JUMP26) ;; *) fail "the execve relocation is $EXR, not a direct call" ;; esac
DIS=$("$OBJDUMP" -d "$OBJ") || fail "llvm-objdump -d failed"
NSVC=$(printf '%s\n' "$DIS" | grep -cwE 'svc|hvc|smc')
[ "$NSVC" = 0 ] || fail "the object's own code contains $NSVC svc/hvc/smc instruction(s)"
SCAN=$(python3 -I -B "$(dirname "$0")/obj-scan.py" "$OBJ"); src=$?
[ $src = 0 ] || fail "raw scan: $SCAN"
echo "undef-gate: OK ($(wc -l < "$OUTU") symbols, all allowlisted; allowlist pin matches; one execve call site ($EXR); no svc/hvc/smc in the disassembly; $SCAN)"
exit 0
