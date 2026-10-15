#!/bin/busybox sh
# FrameShift stage 3a — fs-display <challenge>: the display-test step runner.
# Installed in the image as /bin/fs-display (build-image.sh, hash in MANIFEST).
# Run ONCE per attempt by the host, with the PM looking through the lenses.
#
# Steps (FSB1 exp=stage3a, 2 steps; IMAGE.md "Expected FSB1 steps"):
#   1 hash     /bin/busybox sha256sum /bin/fs-pattern       (-t 3)
#   2 pattern  /bin/fs-pattern show <chal[0:8]> 10           (-t 16 -g 3)
# The display nonce is the first 8 hex characters of the FSB1 challenge
# (stage3a/README.md "PID 1 contract"), so the host can check every FSP1
# record's nonce= against chal[0:8], and the PM reads those 8 characters.
#
# fs-pattern's stdout is fs-supervise's pipe, drained into the RAM file
# /run/fsb/2.out; it never touches the tty. The FSB1 record (base64 payloads)
# is written to stdout (the ACM tty) with ONE cat after the child is reaped,
# preceded by one empty line written by fsb1_emit (encoder revision 5).
#
# Refusals print one "FSDE1 error=<why> END" line (no FSB1 text: the host
# sees no record, INCONCLUSIVE). Runs at most once per boot (mkdir /run/fsb).
. /lib/fs/fsb1-enc.sh || { echo "FSDE1 error=no-encoder END"; exit 1; }

c=$1
n=$(cat /run/fs.nonce 2>/dev/null)
case "$c" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-challenge END"; exit 1 ;; esac
[ "${#c}" -eq 32 ] || { echo "FSDE1 error=bad-challenge END"; exit 1; }
case "$n" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-nonce END"; exit 1 ;; esac
[ "${#n}" -eq 16 ] || { echo "FSDE1 error=bad-nonce END"; exit 1; }
[ $# -eq 1 ] || { echo "FSDE1 error=usage END"; exit 1; }
d8=$(printf '%s' "$c" | cut -c1-8)
case "$d8" in ????????) ;; *) echo "FSDE1 error=nonce8 END"; exit 1 ;; esac

D=/run/fsb
mkdir -m 0700 "$D" 2>/dev/null || { echo "FSDE1 error=already-run END"; exit 1; }
REC=$D/record

fsb1_begin "$REC" stage3a "$n" "$c" 2                                     || { echo "FSDE1 error=begin END"; exit 1; }
fsb1_run "$REC" 1 hash "$D" 3 -- /bin/busybox sha256sum /bin/fs-pattern   || { echo "FSDE1 error=step1 END"; exit 1; }
# step 2 calls fs-supervise directly (fsb1_run has no -g): grace 3 s per the
# fs-pattern PID 1 contract; the same files and encoder as fsb1_run.
[ -e "$D/2.out" ] || [ -e "$D/2.err" ] || [ -e "$D/2.sup" ] && { echo "FSDE1 error=step2 END"; exit 1; }
/bin/fs-supervise -t 16 -g 3 -o "$D/2.out" -r "$D/2.err" -- /bin/fs-pattern show "$d8" 10 > "$D/2.sup" 2>/dev/null
fsb1_step "$REC" 2 pattern "$D/2.sup" "$D/2.out" "$D/2.err"              || { echo "FSDE1 error=step2 END"; exit 1; }
fsb1_end "$REC" "$n" "$c"                                                 || { echo "FSDE1 error=end END"; exit 1; }
fsb1_emit "$REC"
