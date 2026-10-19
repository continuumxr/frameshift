#!/bin/bash
# fs-blkguard probe: runs test-scope.c (FS-R-014 s.3 fixtures and the K1g r3 4K regression) against this checkout's
# fsbg-probe.c and writes RESULTS-scope.txt; with --r2 <ref> it also runs the SAME test against fsbg-probe.c as of that
# git ref (the r2 code, 512-byte rounding) and writes RESULTS-scope-r2code.txt, which must show the 4K regression
# failing with "Invalid argument" at R3 dtbo_a (as on Unit 2, J-207). Offline (WSL or Linux), silent, writes only a
# temporary directory and the RESULTS files.
#   bash tools/blkguard/probe/test/run-scope.sh [--r2 a537251e]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CFLAGS="-O1 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -Wl,--wrap=open,--wrap=pread,--wrap=pread64"
run() {   # run <probe source> <out file> <label>
  local src=$1 out=$2 label=$3 rc
  gcc $CFLAGS -DFSBG_PROBE_SRC="\"$src\"" -o "$T/test-scope" "$HERE/test-scope.c" 2> "$T/cc.txt" || { cat "$T/cc.txt"; return 2; }
  {
    echo "# test-scope.c (FS-R-014 s.3 fixtures; K1g r3 4K regression), $(date -u +%FT%TZ); $label fsbg-probe.c $(sha256sum < "$src" | cut -c1-16); test-scope.c $(sha256sum < "$HERE/test-scope.c" | cut -c1-16); $(gcc --version | head -1); built with -Wl,--wrap=open,--wrap=pread,--wrap=pread64"
    ( cd "$HERE" && "$T/test-scope" 2>&1 ); rc=$?
    echo "# exit $rc"
  } > "$out"
  tail -2 "$out"
}
run "$REPO/tools/blkguard/probe/fsbg-probe.c" "$HERE/RESULTS-scope.txt" "this checkout's"
if [ "${1:-}" = "--r2" ] && [ -n "${2:-}" ]; then
  git -C "$REPO" show "$2:tools/blkguard/probe/fsbg-probe.c" > "$T/fsbg-probe-r2.c" || exit 2
  run "$T/fsbg-probe-r2.c" "$HERE/RESULTS-scope-r2code.txt" "the r2 code ($2)"
  sed -i "s#$T/#<tmp>/#g" "$HERE/RESULTS-scope-r2code.txt"
fi
