#!/bin/bash
# FrameShift Quest 2 channel - TEXTUAL source gate for fs-rpcd (rev 4 R2; rev 5 V1; rev 6).
#   src-gate.sh SRC CLANG
# Textual checks on the C source. They are defence in depth against accidental or careless
# changes, on top of human source review and the object gate (undef-gate.sh / obj-scan.py);
# a determined editor with toolchain control can defeat any static gate.
# On the RAW text:
#   - no asm/__asm/__asm__ token, no svc/hvc/smc token;
#   - no "##" token pasting, no _Pragma (rev 5);
#   - (rev 6) no backslash-newline line splice outside a preprocessor directive, no trigraph
#     (??= ??/ ??' ??( ??) ??! ??< ??> ??-), no digraph %: / %:%: (# / ##);
#   - no call of a shell-capable, raw-syscall or extra process-creation function:
#     system popen posix_spawn[p] execl[p|e] execv[p] execvpe fexecve execveat vfork clone
#     clone3 __clone syscall (a name followed by "(");
#   - exactly one "execve(".
# On the PREPROCESSED text (rev 6; CLANG -E with the shipped target/flags, keeping only the lines
# the line markers attribute to SRC itself, so system headers are not judged):
#   - the same token and call checks, and exactly one "execve(" - a token built by pasting,
#     splicing, trigraphs or digraphs appears here even if the raw text hides it.
set -u
SRC=$1 CLANG=${2:-}
fail() { echo "SOURCE GATE FAILED: $*"; exit 1; }
[ -f "$SRC" ] || fail "no source"
[ -x "$CLANG" ] || fail "no clang given (src-gate.sh SRC CLANG)"
TOK='(^|[^A-Za-z0-9_])(asm|__asm|__asm__|svc|hvc|smc)([^A-Za-z0-9_]|$)'
FORB='(^|[^A-Za-z0-9_])(system|popen|posix_spawnp?|execl|execlp|execle|execv|execvp|execvpe|fexecve|execveat|vfork|clone|clone3|__clone|syscall)[[:space:]]*\('
EXV='(^|[^A-Za-z0-9_])execve[[:space:]]*\('
checks() {  # checks FILE LABEL
    if grep -nE "$TOK" "$1" > /dev/null; then fail "$2: inline assembly or a supervisor-call token: $(grep -nE "$TOK" "$1" | head -3 | tr '\n' ' ')"; fi
    if grep -nE "$FORB" "$1" > /dev/null; then fail "$2: forbidden call: $(grep -nE "$FORB" "$1" | head -3 | tr '\n' ' ')"; fi
    local n; n=$(grep -oE "$EXV" "$1" | wc -l)
    [ "$n" = 1 ] || fail "$2: expected exactly one execve( , found $n"
}
# ---- raw text
if grep -nE '##|_Pragma' "$SRC" > /dev/null; then
    fail "raw: token pasting or _Pragma: $(grep -nE '##|_Pragma' "$SRC" | head -3 | tr '\n' ' ')"
fi
if grep -nE "\?\?[=/'()!<>-]" "$SRC" > /dev/null; then fail "raw: trigraph: $(grep -nE "\?\?[=/'()!<>-]" "$SRC" | head -3 | tr '\n' ' ')"; fi
if grep -nE '%:' "$SRC" > /dev/null; then fail "raw: digraph %: : $(grep -nE '%:' "$SRC" | head -3 | tr '\n' ' ')"; fi
SPL=$(awk 'BEGIN { cont = 0; pp = 0; bad = "" }
    { if (!cont) pp = ($0 ~ /^[ \t]*#/)
      if ($0 ~ /\\[ \t]*\r?$/) { if (!pp) bad = bad NR " "; cont = 1 } else cont = 0 }
    END { print bad }' "$SRC")
[ -z "$SPL" ] || fail "raw: backslash-newline splice outside a preprocessor directive at line(s) $SPL"
checks "$SRC" raw
# ---- preprocessed text, lines from SRC only
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$CLANG" --target=aarch64-linux-gnu -std=c11 -D_GNU_SOURCE -E "$SRC" -o "$T/pp.i" 2> "$T/pp.err" || fail "clang -E failed: $(head -c 300 "$T/pp.err")"
awk -v want="$SRC" '
    /^# [0-9]+ "/ { f = $3; gsub(/^"|"$/, "", f); mine = (f == want); next }
    mine { print }' "$T/pp.i" > "$T/mine.i"
[ -s "$T/mine.i" ] || fail "preprocessed: no lines attributed to $SRC (line markers not found)"
if grep -n '^[[:space:]]*#[[:space:]]*pragma' "$T/mine.i" > /dev/null; then fail "preprocessed: #pragma produced in $SRC"; fi
checks "$T/mine.i" preprocessed
echo "src-gate: OK (raw + preprocessed: no asm/svc token, no ## / _Pragma / splice / trigraph / digraph, no forbidden call, one execve)"
exit 0
