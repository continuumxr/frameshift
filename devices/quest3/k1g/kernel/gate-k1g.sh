#!/bin/bash
# K1g kernel gate: tools/kgate `check` in GATE MODE on the K1g build (Meta v2.7 + fs-blkguard, the EXACT K1a config)
# against Meta's STOCK v2.7 vendor modules (the pinned Quest 3 reference ~/work/kgate-refs/quest3/reference.json),
# with the pinned stock-config build's Module.symvers as the baseline. Adapted copy of ../../k1a/kernel/gate-k1a.sh
# (not edited). The profile's "k1a" build pins are used: the K1g request list and allowlist ARE quest3-k1a.txt and
# quest3-k1a.allow (the patch adds no Kconfig symbol, and the K1g .config is byte-identical to k1a.config), so the
# trust root (quest3.profile.json) is not edited. FS-R-006: the exact K1g config and build are what is gated here.
# Usage: gate-k1g.sh [<K1g object dir>]   (default ~/work/kgate27/out-k1g)
# Writes tools/kgate/validation/quest3/check-k1g.json and check-k1g.log in this checkout. Exit = kgate's exit code.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
B=${1:-$HOME/work/kgate27/out-k1g}
S=$HOME/work/kgate27/out                       # the stock-config build: Module.symvers 7b5cfa8f... (profile pin)
V=$REPO/tools/kgate/validation
Q=$V/requests
C=$ROOT/firmware/quest3/extracted/v2.7-user_ota/kernel.config
SK=$ROOT/firmware/quest3/v2.7-user_ota/boot.img
cd "$REPO" || exit 2
python3 -I -B "$REPO/tools/kgate/kgate.py" check --device quest3 --profile "$Q/quest3.profile.json" --build k1a --label quest3-k1g \
    --reference "$HOME/work/kgate-refs/quest3/reference.json" --stock-kernel "$SK" \
    --json "$V/quest3/check-k1g.json" --allow-config-changes "$Q/quest3-k1a.allow" \
    --symvers "$B/Module.symvers" --vmlinux "$B/vmlinux" --kernel "$B/arch/arm64/boot/Image" --config "$B/.config" \
    --requested "$Q/quest3-k1a.txt" --requested-config "$C" --baseline-symvers "$S/Module.symvers" > "$V/quest3/check-k1g.log" 2>&1
rc=$?
grep -E '^(PASS|FAIL|ERROR|WARN|RESULT)' "$V/quest3/check-k1g.log" | cut -c1-200
echo "kgate exit=$rc"
exit $rc
