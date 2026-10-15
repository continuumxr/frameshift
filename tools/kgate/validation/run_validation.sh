#!/bin/bash
# Positive validation of tools/kgate (gate mode) on the existing v2.7 builds
# (offline, read-only use of the build trees; no device access).  Run in WSL:
#   bash <repo>/tools/kgate/validation/run_validation.sh
# Inputs pinned in validation/requests/:
#   <dev>.profile.json      declared sources, pinned counts, pinned reference sha256
#   <dev>-<group>.txt       requested options (scripts/config syntax); none.txt for stock builds
#   <dev>-<build>.allow     explicit allowlist of unrequested .config differences (if any)
# Full reference.json files go to ~/work/kgate-refs/<device>/.
# WRITES: per-device logs/JSON, SUMMARY.txt and negative/ under tools/kgate/validation/ (in the repo),
#         and reference.json/required_crcs.txt/inventory.tsv under ~/work/kgate-refs/<device>/.
# READS ONLY: firmware/, ~/work/fs006-kernel/v27/*.img, ~/work/kgate*/out*/ build trees.
# Gate mode requires the profile to equal its committed git blob (the profiles are the trust root);
# set KGATE_WAIVE_COMMITTED="reason" only to show results before a pending commit (recorded waiver).
set -u
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
K="python3 -I -B $REPO/tools/kgate/kgate.py"
V=$REPO/tools/kgate/validation
Q=$V/requests
FW=$REPO/firmware
OLD=$REPO/relays/FS-A-006-raw
REFS=~/work/kgate-refs
# Refuse BEFORE touching the committed records (SUMMARY.txt, per-device logs/JSON) when the
# firmware or build-tree inputs are absent (they are gitignored and never published).
missing=""
for _in in "$FW/quest3/v2.7-user_ota" "$FW/quest3/extracted/v2.7-user_ota/kernel.config" "$FW/quest2/v2.7-user_ota" \n           "$FW/quest3s/v2.7-user_ota" "$FW/questpro/v2.7-user_ota" ~/work/fs006-kernel/v27 ~/work/kgate27 \n           ~/work/kgateq2 ~/work/kgateq3s ~/work/kgateqpro; do
  [ -e "$_in" ] || missing="$missing $_in"
done
if [ -n "$missing" ]; then
  echo "REFUSED: run_validation.sh needs the firmware and kernel build inputs (gitignored, never published); missing:$missing" >&2
  echo "Nothing was written; the committed validation records are unchanged." >&2
  exit 2
fi
mkdir -p "$REFS"
SUMMARY=$V/SUMMARY.txt
: > "$SUMMARY"
note() { echo "$*" | tee -a "$SUMMARY"; }
note "# kgate positive validation (gate mode) $(date -u +%FT%TZ)"
note "# tool: $(sha256sum $REPO/tools/kgate/kgate.py | cut -c1-16) kgate.py, $(sha256sum $REPO/tools/kgate/btf_kind_scan.py | cut -c1-16) btf_kind_scan.py"
WAIVE="stock-config build: it is the baseline Module.symvers of this device's option-group builds"

reference() {   # reference <dev> <old-core-list> <old-req-list> <args...>
  local dev=$1 oldcore=$2 oldreq=$3; shift 3
  local out=$V/$dev; mkdir -p "$out"
  $K reference --device "$dev" --profile "$Q/$dev.profile.json" --out "$REFS/$dev" --require-modprobe --json "$out/reference.summary.json" "$@" > "$out/reference.log" 2>&1
  local rc=$?
  cp "$REFS/$dev/required_crcs.txt" "$REFS/$dev/inventory.tsv" "$out/" 2>/dev/null
  note "[$dev] reference rc=$rc  $(grep -E '^(PASS (reference|profile|module-lists)|ERROR|WARN)' "$out/reference.log" | head -5 | tr '\n' '|')"
  if [ ! -f "$oldcore" ] || [ ! -f "$oldreq" ]; then
    # public copy: the FS-A-006 evidence lists are withheld (relays/FS-A-006-raw/README.md)
    note "[$dev] SKIP (withheld evidence): FS-A-006 evidence list comparison; relays/FS-A-006-raw is not in the public copy"
    return 0
  fi
  LC_ALL=C join <(tr -d '\r' < "$oldcore" | LC_ALL=C sort -u) <(tr -d '\r' < "$oldreq" | LC_ALL=C sort -k1,1) > "$out/old_required_crcs.txt"
  if LC_ALL=C diff <(LC_ALL=C sort "$out/old_required_crcs.txt") <(LC_ALL=C sort "$out/required_crcs.txt") > "$out/old_vs_new_required.diff"; then
    note "[$dev] required set identical to FS-A-006 evidence list ($(wc -l < "$out/required_crcs.txt") pairs)"
  else
    note "[$dev] required set DIFFERS from FS-A-006 evidence list: $(grep -c '^<' "$out/old_vs_new_required.diff") old-only, $(grep -c '^>' "$out/old_vs_new_required.diff") new-only"
  fi
  rm -f "$out/old_required_crcs.txt"
}

check() {   # check <dev> <name> <args...>
  local dev=$1 name=$2; shift 2
  local out=$V/$dev allow=()
  [ -f "$Q/$dev-$name.allow" ] && allow=(--allow-config-changes "$Q/$dev-$name.allow")
  $K check --device "$dev" --profile "$Q/$dev.profile.json" --build "$name" --label "$dev-$name" --reference "$REFS/$dev/reference.json" \
     --json "$out/check-$name.json" "${allow[@]}" ${KGATE_WAIVE_COMMITTED:+--waive-committed-profile "$KGATE_WAIVE_COMMITTED"} "$@" > "$out/check-$name.log" 2>&1
  local rc=$?
  note "[$dev-$name] exit=$rc  $(grep -E '^(PASS|FAIL) crc' "$out/check-$name.log" | head -1)  | $(grep -E '^RESULT' "$out/check-$name.log" | cut -c1-60)"
  grep -E '^(FAIL|ERROR|WARN) |^PASS (baseline|requested|config-binding|input-binding|reference-integrity|build-pins|base-config)' "$out/check-$name.log" | sed "s/^/      /" | tee -a "$SUMMARY" > /dev/null
}

# stock build:  check <dev> stock <outdir> <kernel> <stock config>
stock() { local dev=$1 B=$2 KF=$3 CFG=$4
  check "$dev" stock --symvers $B/Module.symvers --vmlinux $B/vmlinux --kernel $B/$KF --config $B/.config \
    --requested $Q/none.txt --requested-config "$CFG" --waive-baseline "$WAIVE"; }
# option group: group <dev> <name> <outdir> <stock outdir> <kernel> <stock config>
group() { local dev=$1 g=$2 B=$3 S=$4 KF=$5 CFG=$6
  check "$dev" "$g" --symvers $B/Module.symvers --vmlinux $B/vmlinux --kernel $B/$KF --config $B/.config \
    --requested $Q/$dev-$g.txt --requested-config "$CFG" --baseline-symvers $S/Module.symvers; }

# ---------------- Quest 3 (v2.7; vendor_dlkm/odm_dlkm/vendor images pre-extracted from the v2.7 OTA into ~/work/fs006-kernel/v27)
D=$FW/quest3/v2.7-user_ota; X=~/work/fs006-kernel/v27; B=~/work/kgate27; C=$FW/quest3/extracted/v2.7-user_ota/kernel.config
reference quest3 "$OLD/kernel-gate/v27-core-syms-needed.txt" "$OLD/kernel-gate/v27-vendor-required-crcs.txt" \
  --vendor-boot "$D/vendor_boot.img" --boot "$D/boot.img" \
  --ext4 "vendor_dlkm=$X/vendor_dlkm.img" --ext4 "odm_dlkm=$X/odm_dlkm.img" --ext4 "vendor=$X/vendor.img" --stock-kernel "$D/boot.img"
stock quest3 $B/out arch/arm64/boot/Image $C
for g in a a2; do group quest3 $g $B/out-$g $B/out arch/arm64/boot/Image $C; done

# ---------------- Quest 2
D=$FW/quest2/v2.7-user_ota; B=~/work/kgateq2
reference quest2 "$OLD/kernel-gate-q2/q2-core-syms-needed.txt" "$OLD/kernel-gate-q2/q2-vendor-required-crcs.txt" \
  --boot "$D/boot.img" --ext4 "vendor=$D/vendor.img" --stock-kernel "$D/boot.img"
stock quest2 $B/out arch/arm64/boot/Image.gz $D/kernel.config
for g in acm a a2; do group quest2 $g $B/out-$g $B/out arch/arm64/boot/Image.gz $D/kernel.config; done

# ---------------- Quest 3S (Quest 3 tree + Q3S stock config)
D=$FW/quest3s/v2.7-user_ota; B=~/work/kgateq3s
reference quest3s "$OLD/kernel-gate-siblings/q3s-core_syms_needed.txt" "$OLD/kernel-gate-siblings/q3s-req_versions.txt" \
  --vendor-boot "$D/vendor_boot.img" --boot "$D/boot.img" \
  --ext4 "vendor_dlkm=$D/vendor_dlkm.img" --ext4 "odm_dlkm=$D/odm_dlkm.img" --ext4 "vendor=$D/vendor.img" --stock-kernel "$D/boot.img"
stock quest3s $B/out arch/arm64/boot/Image $D/kernel.config
group quest3s a2 $B/out-a2 $B/out arch/arm64/boot/Image $D/kernel.config

# ---------------- Quest Pro (Quest 2 tree + QPro stock config)
D=$FW/questpro/v2.7-user_ota; B=~/work/kgateqpro
reference questpro "$OLD/kernel-gate-siblings/qpro-core_syms_needed.txt" "$OLD/kernel-gate-siblings/qpro-req_versions.txt" \
  --boot "$D/boot.img" --ext4 "vendor=$D/vendor.img" --stock-kernel "$D/boot.img"
stock questpro $B/out arch/arm64/boot/Image.gz $D/kernel.config
group questpro a2 $B/out-a2 $B/out arch/arm64/boot/Image.gz $D/kernel.config

note "# end $(date -u +%FT%TZ)"

# ---------------- negative real-data checks (attack A11 equivalents; expected to be REJECTED)
NEG=$V/negative; mkdir -p $NEG
B=~/work/kgate27/out-a2; D=$FW/quest3s/v2.7-user_ota
$K check ${KGATE_WAIVE_COMMITTED:+--waive-committed-profile "$KGATE_WAIVE_COMMITTED"} --device quest3 --profile $Q/quest3s.profile.json --build a2 --reference $REFS/quest3s/reference.json --symvers $B/Module.symvers --vmlinux $B/vmlinux \
  --kernel $B/arch/arm64/boot/Image --config $B/.config --requested $Q/quest3s-a2.txt --requested-config $D/kernel.config \
  --baseline-symvers ~/work/kgateq3s/out/Module.symvers --json $NEG/q3build-q3sref-device-quest3.json > $NEG/q3build-q3sref-device-quest3.log 2>&1
note "[negative] Quest 3 a2 build, Quest 3S reference, --device quest3: exit=$? $(grep -E '^ERROR' $NEG/q3build-q3sref-device-quest3.log | head -1 | cut -c1-150)"
$K check ${KGATE_WAIVE_COMMITTED:+--waive-committed-profile "$KGATE_WAIVE_COMMITTED"} --device quest3s --profile $Q/quest3s.profile.json --build a2 --reference $REFS/quest3s/reference.json --symvers $B/Module.symvers --vmlinux $B/vmlinux \
  --kernel $B/arch/arm64/boot/Image --config $B/.config --requested $Q/quest3s-a2.txt --requested-config $D/kernel.config \
  --allow-config-changes $Q/quest3s-a2.allow --baseline-symvers ~/work/kgateq3s/out/Module.symvers --json $NEG/q3build-q3sref-device-quest3s.json > $NEG/q3build-q3sref-device-quest3s.log 2>&1
note "[negative] Quest 3 a2 build mislabelled quest3s: exit=$? $(grep -E '^(FAIL|ERROR) ' $NEG/q3build-q3sref-device-quest3s.log | head -3 | cut -c1-120 | tr '\n' '|')"
note "# negatives end $(date -u +%FT%TZ)"
