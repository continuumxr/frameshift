#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build and run every offline suite of the thermal service (parts 1 and 2). In WSL:
#   bash devices/thermal/tools/run_all.sh [--local]
# Results go to devices/thermal/fixtures/<suite>/RESULTS.txt (the fan sweep
# takes about 7 min with 4 jobs on a loaded machine). --local also
# runs the local-only differential against Meta's real vendor images
# (never committed beyond its summary lines). Offline: no device, no download.
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
B=$HOME/fsth-build
F=$T/fixtures
QEMU=$(command -v qemu-aarch64 || true)
mkdir -p "$F"/{build-record,ref,metacfg,accept,tables,core,core-aarch64,sweep,real-local,exec,stage,valve,consumers}
rc=0
bash "$T/tools/build.sh" "$B" > /dev/null || { echo "build failed"; exit 1; }
sed -n '2,$p' "$B/BUILD.txt" | grep -v '^compiler\|^libc' > "$F/build-record/BUILD.txt"   # hashes only, toolchain lines vary
cd "$T"
run() { # suite cmd...
    local s=$1; shift
    if "$@" > "$F/$s/RESULTS.txt" 2>&1; then echo "PASS $s: $(tail -1 "$F/$s/RESULTS.txt")"
    else echo "FAIL $s: $(tail -1 "$F/$s/RESULTS.txt")"; rc=1; fi
}
run ref bash -c "python3 -I tools/ref/test_core_ref.py 2>&1 | tail -4; python3 -I tools/ref/test_ref.py | grep 'as expected'"
run metacfg python3 -I tools/test_metacfg.py --bin "$B/fs-metacfg-test" --prod "$B/fs-metacfg" \
    ${QEMU:+--qemu "$QEMU" --bin-a64 "$B/fs-metacfg-test.a64"}
run tables python3 -I tools/test_tables.py --bin "$B/fs-thermald" --bins "$B/fs-metacfg" "$B/fs-metacfg.a64" "$B/fs-thermald-sim.a64" \
    "$B/fs-thermald.a64" "$B/fs-thermald-trial.a64" "$B/fs-thermald-logonly.a64" "$B/fs-thermald-logonly-trial.a64" "$B/fs-poweroff-final.a64"
run accept python3 -I tools/test_accept.py --bin "$B/fs-thermald" --metacfg "$B/fs-metacfg-test" --fake "$B/fakehelper"
run core python3 -I tools/sim/scenarios.py --bin "$B/fs-thermald"
# part 2: the executor (EXEC-SPEC §6), the PID 1 TRIP branch, the Valve layer, the notice consumers
run exec python3 -I tools/sim/exec_scenarios.py --bin "$B/fs-thermald" --fakepid1 "$B/fakepid1" --stepgroup "$B/stepgroup" \
    --logonly-bin "$B/fs-thermald-logonly-test"
[ -f tools/stage/test_pid1_trip.sh ] && run stage bash tools/stage/test_pid1_trip.sh "$B"
[ -f tools/test_valve_units.py ] && run valve python3 -I tools/test_valve_units.py --build "$B"
[ -f tools/test_consumers.py ] && run consumers python3 -I tools/test_consumers.py --build "$B"
# the fan sweep (CORE-SPEC S-3): native only, SWEEP_JOBS parallel runs (default 4; WSL is shared)
run sweep python3 -I tools/sim/sweep.py --bin "$B/fs-thermald" --jobs "${SWEEP_JOBS:-4}"
if [ -n "$QEMU" ]; then
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$QEMU" "$B/fs-thermald-sim.a64" > "$B/fs-thermald-a64.sh"
    chmod +x "$B/fs-thermald-a64.sh"
    run core-aarch64 python3 -I tools/sim/scenarios.py --bin "$B/fs-thermald-a64.sh"
fi
if [ "${1:-}" = "--local" ]; then
    run real-local bash tools/test_real_local.sh "$B"
fi
exit $rc
