#!/usr/bin/env bash
# FrameShift session helper (unpinned; Arbiter's passive f1 readings only). Polls `dumpsys battery` on ONE named unit
# until a reading meets the admission rule, then prints PASSABLE; prints ALERT and stops at the rule's stop threshold
# (r1/r2: >= 40.0 C; r3: >= 43.0 C). It never changes the device. The pinned phase B / BA10 checks remain the only
# admission decision; this loop only decides when to take the formal reading (FS-R-019 s.2: "Fix passive wait loops to
# implement the actual accepted status predicate").
#   usage: fs-wait-admission.sh <serial> <r1|r2|r3> [interval_s=30] [max_readings=120]
#   r1 = FS-R-012 s.5: 100<=t<=349, level>50, status 3/4/5, or status 2 only when t<300; ALERT at t>=400.
#   r2 = FS-R-019 s.4 (admission r2): as r1, but status 2 is also accepted when level>70; ALERT at t>=400.
#   r3 = thermal r3 (devices/quest3/THERMAL-R3.md, PM direction 2026-11-08; host/fs-admission-r3.ps1 holds the same
#        limits): 100<=t<=399, level>50, status 2/3/4/5 (1 never); ALERT at t>=430. Use r3 only for tools that enforce
#        it (K1g/N1 on the thermal r3 package, once the Chair has ruled).
set -u
serial=${1:?serial}; rule=${2:?r1|r2|r3}; every=${3:-30}; max=${4:-120}
case "$rule" in r1|r2|r3) ;; *) echo "rule must be r1, r2 or r3" >&2; exit 2;; esac
case "$rule" in r3) stop=430;; *) stop=400;; esac
ok() {  # $1 status, $2 level, $3 temperature (deci-C)
  local s=$1 l=$2 t=$3
  case "$rule" in
    r3) [ "$t" -ge 100 ] && [ "$t" -le 399 ] && [ "$l" -gt 50 ] || return 1
        case "$s" in 2|3|4|5) return 0;; esac
        return 1;;
  esac
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
    [ "$t" -ge "$stop" ] && { echo "ALERT: temperature $t >= $stop: alert the PM at once; run nothing further"; exit 3; }
    ok "$s" "$l" "$t" && { echo "PASSABLE ($rule)"; exit 0; }
  fi
  [ "$i" -lt "$max" ] && sleep "$every"
done
echo "NOT YET: no passing reading in $max readings"; exit 1
