#!/bin/bash
# K1a kernel gate: tools/kgate `check` in GATE MODE on the K1a build against Meta's STOCK v2.7 vendor modules
# (the pinned Quest 3 reference ~/work/kgate-refs/quest3/reference.json, profile build "k1a"), with the pinned
# stock-config build's Module.symvers as the baseline (every existing vmlinux export CRC must be unchanged).
# The same arguments run_validation.sh uses for the Quest 3 option groups. Offline; run in WSL.
# Usage: gate-k1a.sh [<K1a object dir>]   (default ~/work/kgate27/out-k1a)
# Writes tools/kgate/validation/quest3/check-k1a.json and check-k1a.log in this checkout. Exit = kgate's exit code
# (0 PASS, 1 FAIL, 2 ERROR); anything but 0 is "not accepted" (an option that changes a CRC moves to K1i).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
B=${1:-$HOME/work/kgate27/out-k1a}
S=$HOME/work/kgate27/out                       # the stock-config build: Module.symvers 7b5cfa8f... (profile pin)
V=$REPO/tools/kgate/validation
Q=$V/requests
C=$ROOT/firmware/quest3/extracted/v2.7-user_ota/kernel.config
SK=$ROOT/firmware/quest3/v2.7-user_ota/boot.img
cd "$REPO" || exit 2
python3 -I -B "$REPO/tools/kgate/kgate.py" check --device quest3 --profile "$Q/quest3.profile.json" --build k1a --label quest3-k1a \
    --reference "$HOME/work/kgate-refs/quest3/reference.json" --stock-kernel "$SK" \
    --json "$V/quest3/check-k1a.json" --allow-config-changes "$Q/quest3-k1a.allow" \
    --symvers "$B/Module.symvers" --vmlinux "$B/vmlinux" --kernel "$B/arch/arm64/boot/Image" --config "$B/.config" \
    --requested "$Q/quest3-k1a.txt" --requested-config "$C" --baseline-symvers "$S/Module.symvers" > "$V/quest3/check-k1a.log" 2>&1
rc=$?
grep -E '^(PASS|FAIL|ERROR|WARN|RESULT)' "$V/quest3/check-k1a.log" | cut -c1-200
echo "kgate exit=$rc"
exit $rc
