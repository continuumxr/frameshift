#!/bin/busybox sh
# FrameShift common — FSB1 record encoder (busybox ash; sourced, not run).
# Spec: devices/quest3/common/FSB1-SPEC.md. Shared by stage2a/stage3a step
# runners. Applets used: sh cat printf base64 awk sha256sum cut wc sed grep tr
# (all in the stage-1 busybox 1.37 applet table).
#
# Usage (from a step runner; REC is a file in RAM, e.g. /run/fsb/record):
#   . /lib/fs/fsb1-enc.sh
#   fsb1_begin REC EXP NONCE CHAL NSTEPS
#   fsb1_run   REC I ID DIR TIMEOUT [-i INFILE] -- /ABS/PROG [ARG]...
#   ...                         (one fsb1_run, or fsb1_step, per step, I = 1..NSTEPS)
#   fsb1_end   REC NONCE CHAL
#   fsb1_emit  REC              (one empty line, then one cat of the finished record to stdout)
#
# The encoder never writes a payload byte to the tty: payloads go out only
# as base64 inside DATA lines, so tty newline translation cannot alter them.
# Every function returns nonzero on a usage error; a step runner must then
# stop and emit nothing (the host classifies a missing record INCONCLUSIVE).

FSB1_SUP=${FSB1_SUP:-/bin/fs-supervise}
FSB1_FSUP_RE='^FSUP1 end=(exited|signaled|timer-term|timer-kill|exec-failed|unreaped|refused|internal) code=-?[0-9]+ sig=[0-9]+ errno=[0-9]+ ms=-?[0-9]+ term_ms=-?[0-9]+ kill_ms=-?[0-9]+ out_total=[0-9]+ out_kept=[0-9]+ err_total=[0-9]+ err_kept=[0-9]+ strays=[0-9]+ pipes=(eof|open|none) why=[a-z-]+ END$'

_fsb1_hex() {  # _fsb1_hex VALUE LEN: exactly LEN lowercase hex characters
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -eq "$2" ]
}
_fsb1_tok() {  # _fsb1_tok VALUE: [a-z0-9_]{1,16}
    case "$1" in ''|*[!a-z0-9_]*) return 1 ;; esac
    [ "${#1}" -le 16 ]
}
_fsb1_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 3 ]; }

fsb1_begin() {  # fsb1_begin REC EXP NONCE CHAL NSTEPS
    [ $# -eq 5 ] && _fsb1_tok "$2" && _fsb1_hex "$3" 16 && _fsb1_hex "$4" 32 && _fsb1_num "$5" || return 2
    [ "$5" -ge 1 ] && [ "$5" -le 32 ] || return 2
    [ -e "$1" ] && return 3                      # never append to an old record
    printf 'FSB1 BEGIN v=1 exp=%s nonce=%s chal=%s steps=%s\n' "$2" "$3" "$4" "$5" > "$1"
}

_fsb1_data() {  # _fsb1_data REC I S FILE: DATA lines for one stream (none if empty)
    [ -s "$4" ] || return 0
    base64 -w 64 "$4" | awk -v i="$2" -v s="$3" '{ printf "FSB1 DATA i=%s s=%s n=%d %s\n", i, s, NR - 1, $0 }' >> "$1"
}
_fsb1_len() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
_fsb1_sha() {
    if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1
    else printf '' | sha256sum | cut -d' ' -f1; fi
}

fsb1_step() {  # fsb1_step REC I ID FSUPFILE OUTFILE ERRFILE
    [ $# -eq 6 ] && _fsb1_num "$2" && _fsb1_tok "$3" && [ -f "$1" ] || return 2
    local sup f
    sup=$(cat "$4" 2>/dev/null)
    # exactly one well-formed FSUP1 line, else a fixed "nosup" field set
    if [ "$(printf '%s\n' "$sup" | wc -l)" = 1 ] && printf '%s\n' "$sup" | grep -Eq "$FSB1_FSUP_RE"; then
        f=$(printf '%s\n' "$sup" | sed -e 's/^FSUP1 //' -e 's/ END$//')
    else
        f="end=nosup code=-1 sig=0 errno=0 ms=-1 term_ms=-1 kill_ms=-1 out_total=0 out_kept=0 err_total=0 err_kept=0 strays=0 pipes=none why=no-report"
    fi
    printf 'FSB1 STEP i=%s id=%s %s out_len=%s out_sha256=%s err_len=%s err_sha256=%s\n' \
        "$2" "$3" "$f" "$(_fsb1_len "$5")" "$(_fsb1_sha "$5")" "$(_fsb1_len "$6")" "$(_fsb1_sha "$6")" >> "$1"
    _fsb1_data "$1" "$2" o "$5"
    _fsb1_data "$1" "$2" e "$6"
}

fsb1_run() {  # fsb1_run REC I ID DIR TIMEOUT [-i INFILE] -- /ABS/PROG [ARG]...
    local rec i id dir t inopt
    rec=$1 i=$2 id=$3 dir=$4 t=$5
    shift 5
    _fsb1_num "$i" && _fsb1_tok "$id" && _fsb1_num "$t" || return 2
    inopt=""
    if [ "$1" = "-i" ]; then inopt=$2; shift 2; fi
    [ "$1" = "--" ] || return 2
    shift
    [ -e "$dir/$i.out" ] || [ -e "$dir/$i.err" ] || [ -e "$dir/$i.sup" ] && return 3
    if [ -n "$inopt" ]; then
        "$FSB1_SUP" -t "$t" -i "$inopt" -o "$dir/$i.out" -r "$dir/$i.err" -- "$@" > "$dir/$i.sup" 2>/dev/null
    else
        "$FSB1_SUP" -t "$t" -o "$dir/$i.out" -r "$dir/$i.err" -- "$@" > "$dir/$i.sup" 2>/dev/null
    fi
    fsb1_step "$rec" "$i" "$id" "$dir/$i.sup" "$dir/$i.out" "$dir/$i.err"
}

fsb1_end() {  # fsb1_end REC NONCE CHAL
    [ $# -eq 3 ] && [ -f "$1" ] && _fsb1_hex "$2" 16 && _fsb1_hex "$3" 32 || return 2
    local n h
    n=$(wc -l < "$1" | tr -d ' ')
    h=$(sha256sum "$1" | cut -d' ' -f1)
    printf 'FSB1 END v=1 nonce=%s chal=%s lines=%s rec_sha256=%s\n' "$2" "$3" "$n" "$h" >> "$1"
}

# One empty line first (revision 5; host/COLLECTOR.md §6): if the target does
# not echo the command, BEGIN would otherwise follow the prompt on the same
# line ("~ # FSB1 BEGIN ...") and the whole-capture decode would find no line
# STARTING with "FSB1 BEGIN" (no-begin). The decoders ignore lines outside the
# record, so the empty line costs nothing when the command is echoed.
fsb1_emit() { [ -f "$1" ] || return 2; printf '\n'; cat "$1"; }
