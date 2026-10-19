#!/bin/bash
# fs-blkguard mutation test (UML): disables one hook at a time in the UML TEST tree
# (~/work/blkguard/src-um; never in the device tree), rebuilds incrementally, and runs the
# probe.  Each mutant must make the probe FAIL on exactly the cases that use that hook,
# and the device-mode runs (fsbg.forceq: protected phase forced, VM only) must show that
# the protected-phase cases write nothing even with the hook gone.  The tree is restored
# and rebuilt at the end.  Offline; no device access.
#   bash tools/blkguard/vm/mutants_uml.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
W=~/work/blkguard; S=$W/src-um
OUT=${OUT:-$REPO/tools/blkguard/vm/results}/mutants
mkdir -p "$OUT"
MK="make -C $S ARCH=um O=$W/out-um CC=gcc HOSTCC=gcc KCFLAGS=-Wno-error=unknown-pragmas -j8 linux"
SUM=$OUT/mutants-summary.txt
: > "$SUM"
note() { echo "$*" | tee -a "$SUM"; }
note "# fs-blkguard UML mutation test $(date -u +%FT%TZ); base $(git -C $S log --oneline -1)"

mutate() {   # mutate <name> <file> <python-expr-old> <new>  (exact text replacement, all occurrences)
  local name=$1 file=$2 old=$3 new=$4
  git -C $S checkout -q -- "$file"
  python3 - "$S/$file" "$old" "$new" <<'EOF'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n >= 1, f"pattern not found in {p}"
open(p, "w").write(s.replace(old, new))
print(f"  mutated {n} site(s) in {p}")
EOF
  $MK > "$W/mutant-build-$name.log" 2>&1 || { note "[$name] BUILD FAILED"; git -C $S checkout -q -- "$file"; return 1; }
  for cfg in ${CFGS:-strict-bootoff device-mode}; do
    OUT=$OUT/$name RUNS=$cfg bash "$REPO/tools/blkguard/vm/run_uml.sh" > /dev/null 2>&1
    note "[$name/$cfg] $(grep -a 'FSBG-PROBE RESULT' $OUT/$name/uml-$cfg.log | tr -d '\r' | tail -1)"
    grep -a -E 'host decoy|HOST DECOY' $OUT/$name/uml-summary.txt | sed 's/^/    /' | tee -a "$SUM" > /dev/null
    tr -d '\r' < $OUT/$name/uml-$cfg.log | grep -a -E '^(CASE|ALLOW).*FAIL|^STOP|^HASH .*CHANGED|^HASH verify' \
      | awk '{print "    " $0}' | sort | uniq -c | sort -rn | head -40 | tee -a "$SUM" > /dev/null
  done
  git -C $S checkout -q -- "$file"
}

# the device-mode runs need the protected phase forced: add fsbg.forceq for this script only
sed -i.bak 's/run device-mode        "\$W\/out-um\/linux" fsbg.testkernel$/run device-mode        "$W\/out-um\/linux" fsbg.testkernel fsbg.forceq/' \
  "$REPO/tools/blkguard/vm/run_uml.sh"
trap 'mv -f "$REPO/tools/blkguard/vm/run_uml.sh.bak" "$REPO/tools/blkguard/vm/run_uml.sh"' EXIT

mutate no-bio   block/blk-core.c   "if (unlikely(fs_blkguard_deny_bio(bio)))" "if (0 && unlikely(fs_blkguard_deny_bio(bio)))"
mutate no-open  fs/block_dev.c     "fs_blkguard_deny_bdev(disk, partno, FSBG_PATH_OPEN)" "0"
mutate no-write fs/block_dev.c     "if (fs_blkguard_deny_bdev(I_BDEV(bd_inode)->bd_disk," "if (0 && fs_blkguard_deny_bdev(I_BDEV(bd_inode)->bd_disk,"
mutate no-ioctl block/ioctl.c      "fs_blkguard_deny_bdev(" "0 && fs_blkguard_deny_bdev("
mutate no-scsi  block/scsi_ioctl.c "if (fs_blkguard_deny_cdb(cmd, BLK_MAX_CDB, FSBG_PATH_SCSI))" "if (0 && fs_blkguard_deny_cdb(cmd, BLK_MAX_CDB, FSBG_PATH_SCSI))"
mutate no-sg    drivers/scsi/sg.c  "if (fs_blkguard_deny_cdb(cmnd," "if (0 && fs_blkguard_deny_cdb(cmnd,"
mutate no-scsi-ioctl drivers/scsi/scsi_ioctl.c "fs_blkguard_deny_scsi_ioctl(cmd)" "0"
CFGS="protect" mutate no-sticky block/fs-blkguard.c "		if (READ_ONCE(fsbg_sticky[i]) == q)" "		if (0)"

git -C $S status --short | grep -v '^??' && note "WARNING: test tree not clean" || note "# test tree restored"
$MK > "$W/mutant-build-restore.log" 2>&1 && note "# restored kernel rebuilt: $(sha256sum $W/out-um/linux | cut -c1-16)"
note "# end $(date -u +%FT%TZ)"
