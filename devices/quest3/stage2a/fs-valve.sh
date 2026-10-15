#!/bin/busybox sh
# FrameShift stage 2a — fs-valve <challenge>: the experiment (i) step runner.
# Installed in the image as /bin/fs-valve (build-image.sh, hash in MANIFEST).
# Run ONCE per attempt by the host (host/fs-collect.ps1 verb `fs-valve`).
#
# Steps: devices/quest3/common/OUTCOMES.md §2 (revision 4: 8 steps; step 8
# `inv` is informational and never changes the outcome), with the --list rule
# of T1-PINS §3 (checked on the host). Every step runs under /bin/fs-supervise
# (empty environment, new session, absolute program path, TERM->KILL,
# capped capture into RAM files under /run/fsb). The record is FSB1
# (common/FSB1-SPEC.md), built in RAM by common/target/fsb1-enc.sh and
# written to stdout (the ACM tty) by fsb1_emit: one empty line (encoder
# revision 5), then ONE cat.
#
# Refusals print one "FSVE1 error=<why> END" line (no FSB1 text, so the
# host sees no record: INCONCLUSIVE). The runner never runs twice in one
# boot: /run/fsb is created with mkdir, which fails if it exists.
#
# Step timeouts (IMAGE.md "Timing"; checked by tools/check-timing.py against
# init.sh's DEADLINE and host/fs-collect.ps1's budget): steps 1-7 -t 5, step 8
# -t 10, grace 2 s (the fs-supervise default). Worst case per step
# t + 2 + 3 (reap) + 3 (strays) + 1 (drain) = 14 s (steps 1-7), 19 s (step 8).
. /lib/fs/fsb1-enc.sh || { echo "FSVE1 error=no-encoder END"; exit 1; }

c=$1
n=$(cat /run/fs.nonce 2>/dev/null)
case "$c" in ''|*[!0-9a-f]*) echo "FSVE1 error=bad-challenge END"; exit 1 ;; esac
[ "${#c}" -eq 32 ] || { echo "FSVE1 error=bad-challenge END"; exit 1; }
case "$n" in ''|*[!0-9a-f]*) echo "FSVE1 error=bad-nonce END"; exit 1 ;; esac
[ "${#n}" -eq 16 ] || { echo "FSVE1 error=bad-nonce END"; exit 1; }
[ $# -eq 1 ] || { echo "FSVE1 error=usage END"; exit 1; }

D=/run/fsb
mkdir -m 0700 "$D" 2>/dev/null || { echo "FSVE1 error=already-run END"; exit 1; }
REC=$D/record
# the challenge input: exactly "<nonce>:<challenge>", no newline (T1-PINS §5)
printf '%s:%s' "$n" "$c" > "$D/chal.in" || { echo "FSVE1 error=write END"; exit 1; }

L=/valve/lib/ld-linux-aarch64.so.1
LP=/valve/lib
T=5
TINV=10
fsb1_begin "$REC" stage2a "$n" "$c" 8                                                   || { echo "FSVE1 error=begin END"; exit 1; }
fsb1_run "$REC" 1 hash   "$D" $T -- /bin/busybox sha256sum /valve/lib/ld-linux-aarch64.so.1 /valve/lib/libc.so.6 /valve/bin/uname /valve/bin/b2sum \
                                                                                        || { echo "FSVE1 error=step1 END"; exit 1; }
fsb1_run "$REC" 2 absent "$D" $T -- /bin/busybox sh -c 'for p in /etc/ld.so.preload /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1 /usr/lib/libc.so.6; do [ -e "$p" ] || [ -L "$p" ] && echo "$p"; done; exit 0' \
                                                                                        || { echo "FSVE1 error=step2 END"; exit 1; }
fsb1_run "$REC" 3 diag   "$D" $T -- "$L" --inhibit-cache --library-path "$LP" --list-diagnostics \
                                                                                        || { echo "FSVE1 error=step3 END"; exit 1; }
fsb1_run "$REC" 4 list   "$D" $T -- "$L" --inhibit-cache --library-path "$LP" --list /valve/bin/b2sum \
                                                                                        || { echo "FSVE1 error=step4 END"; exit 1; }
fsb1_run "$REC" 5 uname  "$D" $T -- "$L" --inhibit-cache --library-path "$LP" /valve/bin/uname -r \
                                                                                        || { echo "FSVE1 error=step5 END"; exit 1; }
fsb1_run "$REC" 6 b2kat  "$D" $T -- "$L" --inhibit-cache --library-path "$LP" /valve/bin/b2sum \
                                                                                        || { echo "FSVE1 error=step6 END"; exit 1; }
fsb1_run "$REC" 7 b2chal "$D" $T -i "$D/chal.in" -- "$L" --inhibit-cache --library-path "$LP" /valve/bin/b2sum \
                                                                                        || { echo "FSVE1 error=step7 END"; exit 1; }
fsb1_run "$REC" 8 inv    "$D" $TINV -- /bin/busybox sh /bin/fs-inv \
                                                                                        || { echo "FSVE1 error=step8 END"; exit 1; }
fsb1_end "$REC" "$n" "$c"                                                               || { echo "FSVE1 error=end END"; exit 1; }
fsb1_emit "$REC"
