#!/bin/bash
# Run the kgate fixture tests (offline; needs python3, mke2fs, debugfs; modprobe optional).
#   bash tools/kgate/test_kgate.sh [--results FILE]
exec python3 -I "$(dirname "$(readlink -f "$0")")/test_kgate.py" "$@"
