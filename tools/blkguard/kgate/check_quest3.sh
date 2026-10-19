#!/bin/bash
# fs-blkguard CRC-neutrality check: gates the patched Quest 3 group-"a" build (build_quest3.sh)
# with tools/kgate in gate mode, exactly as validation/run_validation.sh gates the unpatched
# group-"a" build (same profile pins, request list, allowlist, stock-build baseline), and
# compares Module.symvers byte for byte with the unpatched group-"a" build.
# Offline; no device access.  Run in WSL from the repo:
#   bash tools/blkguard/kgate/check_quest3.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
K="python3 -I -B $REPO/tools/kgate/kgate.py"
Q=$REPO/tools/kgate/validation/requests
FW=${FW:-$REPO/firmware}   # firmware/ is not in git: set FW to a checkout that has it
C=$FW/quest3/extracted/v2.7-user_ota/kernel.config
B=~/work/blkguard/out-a; U=~/work/kgate27/out-a; S=~/work/kgate27/out
OUT=$REPO/tools/blkguard/kgate/results; mkdir -p $OUT
LOG=$OUT/check-quest3-a-blkguard.log
{
echo "# fs-blkguard kgate check $(date -u +%FT%TZ)"
echo "# tool: $(sha256sum $REPO/tools/kgate/kgate.py | cut -c1-16) kgate.py"
echo "# patched build: $B ($(git -C ~/work/blkguard/src log -1 --format='%h %s'))"
echo "# unpatched group-a build: $U ; stock-build baseline: $S"
$K check --device quest3 --profile $Q/quest3.profile.json --build a --label quest3-a-blkguard \
  --reference ~/work/kgate-refs/quest3/reference.json --json $OUT/check-quest3-a-blkguard.json \
  --allow-config-changes $Q/quest3-a.allow \
  --symvers $B/Module.symvers --vmlinux $B/vmlinux --kernel $B/arch/arm64/boot/Image --config $B/.config \
  --requested $Q/quest3-a.txt --requested-config $C --baseline-symvers $S/Module.symvers \
  --stock-kernel $FW/quest3/v2.7-user_ota/boot.img
echo "# kgate exit=$?"
echo "# Module.symvers patched vs unpatched group-a:"
cmp $B/Module.symvers $U/Module.symvers && echo "IDENTICAL ($(sha256sum < $B/Module.symvers | cut -c1-16), $(wc -l < $B/Module.symvers) rows)"
echo "# vmlinux exports (symbol, CRC) patched vs unpatched group-a:"
diff <(awk '$3=="vmlinux"{print $2,$1,$4}' $U/Module.symvers | sort) <(awk '$3=="vmlinux"{print $2,$1,$4}' $B/Module.symvers | sort) \
  && echo "IDENTICAL ($(awk '$3=="vmlinux"' $B/Module.symvers | wc -l) vmlinux exports)"
echo "# .config patched vs unpatched group-a:"
cmp $B/.config $U/.config && echo "IDENTICAL"
echo "# new symbols in the patched vmlinux (none may be exported):"
$HOME/toolchains/clang-r450784e/bin/llvm-nm $B/vmlinux | grep -i -E 'fs_blkguard|fsbg' | sort
echo "# __ksymtab entries naming the guard (expect none):"
$HOME/toolchains/clang-r450784e/bin/llvm-nm $B/vmlinux | grep -E '__ksymtab_.*(fs_blkguard|fsbg)' || echo "none"
} 2>&1 | tee $LOG
