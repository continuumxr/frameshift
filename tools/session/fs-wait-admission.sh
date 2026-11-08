#!/usr/bin/env bash
# FrameShift session helper (unpinned; Arbiter's passive f1 readings only). Polls `dumpsys battery` on ONE named unit
# until a reading meets the admission rule, then prints PASSABLE; prints ALERT and stops at >= 40.0 C. It never
# changes the device. The pinned phase B / BA10 checks remain the only admission decision; this loop only decides when
# to take the formal reading (FS-R-019 s.2: "Fix passive wait loops to implement the actual accepted status predicate").
#   usage: fs-wait-admission.sh <serial> <r1|r2> [interval_s=30] [max_readings=120]
#   r1 = FS-R-012 s.5: 100<=t<=349, level>50, status 3/4/5, or status 2 only when t<300.
#   r2 = FS-R-019 s.4 (admission r2): as r1, but status 2 is also accepted when level>70.
set -u
serial=${1:?serial}; rule=${2:?r1|r2}; every=${3:-30}; max=${4:-120}
case "$rule" in r1|r2) ;; *) echo "rule must be r1 or r2" >&2; exit 2;; esac
ok() {  # $1 status, $2 level, $3 temperature (deci-C)
  local s=$1 l=$2 t=$3
  [ "$t" -ge 100 ] && [ "$t" -le 349 ] && [ "$l" -gt 50 ] || return 1
  case "$s" in 3|4|5) return 0;; 2) [ "$t" -lt 300 ] && return 0; [ "$rule" = r2 ] && [ "$l" -gt 70 ] && return 0;; esac
  return 1
}
for i in $(seq 1 "$max"); do
  out=$(adb -s "$serial" shell dumpsys battery 2>&1 | tr -d '\r')
  s=$(printf '%s\n' "$out" | awk '/^ *status:/{print $2; exit}')
  l=$(printf '%s\n' "$out" | awk '/^ *level:/{print $2; exit}')
  t=$(printf '%s\n' "$out" | awk '/^ *temperature:/{print $2; exit}')
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) status: ${s:-?} level: ${l:-?} temperature: ${t:-?}"
  if [[ "$t" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ && "$l" =~ ^[0-9]+$ ]]; then
    [ "$t" -ge 400 ] && { echo "ALERT: temperature $t >= 400: alert the PM at once; run nothing further"; exit 3; }
    ok "$s" "$l" "$t" && { echo "PASSABLE ($rule)"; exit 0; }
  fi
  [ "$i" -lt "$max" ] && sleep "$every"
done
echo "NOT YET: no passing reading in $max readings"; exit 1
