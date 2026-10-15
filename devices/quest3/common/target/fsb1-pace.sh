#!/bin/busybox sh
# FrameShift common — PACED emission of a finished FSB1 record (busybox ash;
# sourced after fsb1-enc.sh, not run). Added for stage 3b (FS-R-010 §5).
# fsb1-enc.sh (encoder revision 5, pinned by the stage-2a/3a images) is NOT
# changed; this file only adds an emitter. The framing and both decoders are
# unchanged (FSB1-SPEC.md §9).
#
#   fsb1_emit_paced REC TICK MAXLINES
#
# Emits EXACTLY the bytes `fsb1_emit REC` emits (one empty line, then the
# record file byte for byte), but in chunks of FSB1_PACE_LINES (10) lines,
# with a pause of FSB1_PACE_TICK (0.1 s) after every full chunk:
#   - the pause is `read -t 0.1` on the private FIFO TICK (opened O_RDWR, so
#     the open never blocks; nothing writes it, so the read times out). It is a
#     builtin: the loop forks NOTHING (common/DEADLINE.md §2 property 5: step
#     runners avoid fork-heavy loops). `sleep 0.1` (a fork per chunk) is used
#     only if TICK is not a FIFO;
#   - the lines are read with the `read -r` builtin and written with the
#     `printf` builtin, one printf per chunk;
#   - byte identity is guaranteed by refusal, not by repair: the record must
#     be a regular file, end with "\n", hold only bytes 0x20-0x7E between the
#     newlines (as fsb1-enc.sh writes it), and have at most MAXLINES lines.
#     Otherwise NOTHING is written and the function returns 3 (too many lines)
#     or 4 (not emittable byte for byte). The caller then prints its own
#     refusal line (FSDE1 ... END); the host classifies a missing record
#     INCONCLUSIVE.
# MAXLINES is the runner's MAXIMUM PERMITTED record size, in lines: the
# emission-time bound is derived from it (stage3b/IMAGE.md §4).
#
# Applets: sh (builtins read, printf, test), wc, tr, tail; sleep only as
# the fallback above. All are in the stage-1 busybox 1.37 applet table.

FSB1_PACE_LINES=${FSB1_PACE_LINES:-10}
FSB1_PACE_TICK=${FSB1_PACE_TICK:-0.1}

_fsb1_pause() {  # _fsb1_pause TICK: about FSB1_PACE_TICK seconds, fork-free when TICK is a FIFO
    if [ -p "$1" ]; then
        read -r -t "$FSB1_PACE_TICK" _fsb1_x <> "$1"
    else
        sleep "$FSB1_PACE_TICK"
    fi
    return 0
}

fsb1_emit_paced() {  # fsb1_emit_paced REC TICK MAXLINES
    [ $# -eq 3 ] && [ -f "$1" ] && [ ! -L "$1" ] || return 2
    case "$3" in ''|*[!0-9]*) return 2 ;; esac
    local n line chunk k nl
    n=$(wc -l < "$1" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) return 4 ;; esac
    [ "$n" -ge 1 ] || return 4
    [ "$n" -le "$3" ] || return 3
    # last byte must be "\n" (else `read` would drop or alter the last line)
    [ "$(tail -c 1 "$1" | tr -d '\n' | wc -c | tr -d ' ')" = 0 ] || return 4
    # only printable ASCII between the newlines (no CR, TAB, NUL, backslash
    # processing issues): what fsb1-enc.sh writes; anything else is refused
    if [ "$(tr -d '\n\040-\176' < "$1" | wc -c | tr -d ' ')" != 0 ]; then return 4; fi
    nl='
'
    printf '\n'
    chunk=''
    k=0
    while IFS= read -r line; do
        chunk="$chunk$line$nl"
        k=$((k + 1))
        if [ "$k" -ge "$FSB1_PACE_LINES" ]; then
            printf '%s' "$chunk"
            chunk=''
            k=0
            _fsb1_pause "$2"
        fi
    done < "$1"
    [ -z "$chunk" ] || printf '%s' "$chunk"
    return 0
}
