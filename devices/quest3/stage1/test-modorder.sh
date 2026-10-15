#!/bin/bash
# Offline test of init.sh's module-ordering logic (no device, no real insmod).
#
# Runs the exact function block from init.sh inside a bwrap sandbox with the
# stock vendor ramdisk's lib/modules bound at /lib/modules, and insmod stubbed
# to record the order. Then checks:
#   1. every module in modules.load.recovery is loaded exactly once;
#   2. every module comes after all its modules.dep dependencies;
#   3. every softdep "pre:" module (that exists) comes before its user.
# Usage: test-modorder.sh <extracted vendor ramdisk root>
set -euo pipefail
VR=${1:?path to extracted vendor ramdisk root}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# exact block from init.sh: from "MD=/lib/modules" through the load loop's "done"
sed -n '/^MD=\/lib\/modules$/,/^done$/p' "$HERE/init.sh" | tr -d '\r' > "$W/block.sh"
grep -q 'load_mod "\$MD/\$m"' "$W/block.sh" || { echo "could not extract block"; exit 1; }

cat > "$W/run.sh" <<'EOF'
insmod() { echo "$1" >> /tmp/order; return 0; }
log() { :; }
. /tmp/block.sh
EOF
cp "$W/block.sh" "$W/block-copy.sh"

bwrap --ro-bind / / --ro-bind "$VR/lib/modules" /lib/modules \
      --bind "$W" /tmp --dev /dev --proc /proc --unshare-all --die-with-parent \
      sh /tmp/run.sh

M=$VR/lib/modules
python3 - "$W/order" "$M" <<'PY'
import sys, os, re
order = [l.strip() for l in open(sys.argv[1]) if l.strip()]
M = sys.argv[2]
pos = {m: i for i, m in enumerate(order)}
errs = []
want = ["/lib/modules/" + l.strip() for l in open(M + "/modules.load.recovery") if l.strip()]
dups = len(order) - len(set(order))
missing = [w for w in want if w not in pos]
for line in open(M + "/modules.dep"):
    mod, _, deps = line.strip().partition(":")
    if mod in pos:
        for d in deps.split():
            if d not in pos or pos[d] > pos[mod]:
                errs.append(f"{mod} loaded before dep {d}")
for line in open(M + "/modules.softdep"):
    m = re.match(r"softdep (\S+) pre:(.*?)(post:.*)?$", line.strip())
    if not m: continue
    user = "/lib/modules/" + m.group(1).replace("_", "-") + ".ko"
    for p in m.group(2).split():
        f = "/lib/modules/" + p + ".ko"
        if os.path.exists(M + "/" + p + ".ko") and user in pos and (f not in pos or pos[f] > pos[user]):
            errs.append(f"softdep: {f} not before {user}")
print(f"loaded {len(order)} modules, {len(set(order))} unique, duplicates {dups}, missing {len(missing)}")
print("dependency/softdep violations:", len(errs))
for e in errs[:10]: print("  ", e)
print("first 12 in load order:", [os.path.basename(x) for x in order[:12]])
i = {os.path.basename(x): n for n, x in enumerate(order)}
print("USB chain positions:", {k: i.get(k) for k in ["phy-msm-snps-hs.ko", "phy-msm-ssusb-qmp.ko", "dwc3-msm.ko", "ucsi_glink.ko", "pwm-qti-lpg.ko", "leds-qti-tri-led.ko", "reboot-mode.ko"]})
sys.exit(1 if (errs or dups or missing) else 0)
PY
