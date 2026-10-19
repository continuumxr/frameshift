#!/bin/bash
# Build and run the fs-blkguard policy harness against the policy header taken
# verbatim from the kernel patch (single source of truth).  Offline; WSL or Linux.
#   bash tools/blkguard/harness/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$(ls "$HERE"/../patches/0001-*.patch)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
( cd "$T" && git apply --include='block/fs-blkguard-policy.h' "$PATCH" )
echo "policy header: $(sha256sum "$T/block/fs-blkguard-policy.h" | cut -c1-16) (from $(basename "$PATCH"))"
gcc -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$T/block" \
    -o "$T/test_policy" "$HERE/test_policy.c"
"$T/test_policy"
