#!/usr/bin/env python3
"""Fixtures for misc_rule.py: the real Quest 3 Unit 1 misc images plus
synthetic edits of them (made in memory; no image is written to the repo).

    python -I tools/test_misc_rule.py      (from the repo root or anywhere)

Writes fixtures/misc/RESULTS.txt; exit 0 only if every case matches.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import misc_rule  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RAW = os.path.join(ROOT, "relays", "FS-A-005-raw")
if not os.path.exists(os.path.join(RAW, "misc-ctrl0.img")):
    # public copy: the misc dumps are withheld; skip cleanly (RESULTS.txt is left untouched)
    print("SKIP (withheld evidence): relays/FS-A-005-raw misc dumps are not in the public copy; 0 cases run")
    sys.exit(0)
ctrl0 = open(os.path.join(RAW, "misc-ctrl0.img"), "rb").read()
ctrl1 = open(os.path.join(RAW, "misc-ctrl1.img"), "rb").read()
after = open(os.path.join(RAW, "misc-after.img"), "rb").read()
march_path = os.path.join(ROOT, "firmware", "quest3", "unit1_nonslotted", "misc.img")
march = open(march_path, "rb").read() if os.path.exists(march_path) else None


def edit(img, off, data):
    b = bytearray(img)
    b[off:off + len(data)] = data
    return bytes(b)


cases = [
    # name, before, after, expected verdict, note
    ("real-control-ctrl0-ctrl1", ctrl0, ctrl1, "RECORDED", "the PM's stock reboot control (FS-A-005): only V changes"),
    ("real-trial-after-eq-ctrl0", after, ctrl0, "UNCHANGED", "trial-after vs control-before: byte-identical"),
    ("identical", ctrl1, ctrl1, "UNCHANGED", ""),
    ("c-E1-to-E0", ctrl0, edit(ctrl0, 0, bytes(32)), "STOP", "command cleared: never observed"),
    ("c-recovery", ctrl0, edit(ctrl0, 0, b"boot-recovery".ljust(32, b"\0")), "STOP", "other boot command"),
    ("c-junk-after-nul", ctrl0, edit(ctrl0, 0x1f, b"\x01"), "STOP", "E1 string with a non-NUL tail byte"),
    ("c-before-unexpected", edit(ctrl0, 0, b"boot-recovery".ljust(32, b"\0")),
     edit(ctrl0, 0, b"boot-recovery".ljust(32, b"\0")), "STOP", "unexpected before-state, unchanged"),
    ("o-status-field", ctrl0, edit(ctrl0, 0x20, b"\x41"), "STOP", "bootloader_message.status"),
    ("o-just-below-v", ctrl0, edit(ctrl0, 0x100f, b"\x01"), "STOP", "0x100f, adjacent to V"),
    ("o-just-above-v", ctrl0, edit(ctrl0, 0x101c, b"\x03"), "STOP", "0x101c (constant 0x02 in all dumps)"),
    ("o-vab-message", ctrl0, edit(ctrl0, 0x8008, b"\x01"), "STOP", "virtual A/B message"),
    ("o-slot-suffix", ctrl0, edit(ctrl0, 0x800, b"_b"), "STOP", "bootloader_message_ab.slot_suffix"),
    ("v-and-other", ctrl0, edit(ctrl1, 0x1400, b"\x00"), "STOP", "V change plus a change elsewhere"),
    ("truncated-after", ctrl0, ctrl1[:-1], "INCONCLUSIVE", "capture one byte short"),
    ("empty-before", b"", ctrl1, "INCONCLUSIVE", "no before capture (the FS-A-005 situation)"),
]
if march is not None:
    cases += [
        ("real-dump-march-to-ctrl0", march, ctrl0, "RECORDED", "real images, synthetic pairing: E0->E1 plus V"),
        ("c-E0-to-E1-only", march, edit(march, 0, misc_rule.E1), "EXPECTED", "Android 'reboot bootloader' only"),
        ("c-E0-unchanged", march, march, "UNCHANGED", ""),
    ]

lines, bad = [], 0
for name, b, a, want, note in cases:
    got, detail = misc_rule.classify(b, a)
    ok = got == want
    bad += not ok
    lines.append("%-28s %s got=%s want=%s  %s" % (name, "PASS" if ok else "FAIL", got, want, note))
    for d in detail[2:]:
        lines.append("    " + d)
# ---- CLI (second review S2): exit codes and unreadable inputs ----------------
import shutil
import subprocess
import tempfile
tmp = tempfile.mkdtemp(prefix="miscrule-")
b_path, a_path, short = os.path.join(tmp, "b.img"), os.path.join(tmp, "a.img"), os.path.join(tmp, "short.img")
open(b_path, "wb").write(ctrl0)
open(a_path, "wb").write(ctrl1)
open(short, "wb").write(ctrl1[:4096])
cli = [
    ("cli-recorded", [b_path, a_path], 12, "RECORDED"),
    ("cli-unchanged", [b_path, b_path], 10, "UNCHANGED"),
    ("cli-missing-after", [b_path, os.path.join(tmp, "nope.img")], 14, "INCONCLUSIVE"),
    ("cli-missing-before", [os.path.join(tmp, "nope.img"), a_path], 14, "INCONCLUSIVE"),
    ("cli-unreadable-dir", [b_path, tmp], 14, "INCONCLUSIVE"),
    ("cli-short-after", [b_path, short], 14, "INCONCLUSIVE"),
    ("cli-usage", [b_path], 64, None),
]
for name, args, want_rc, want_v in cli:
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "misc_rule.py")] + args, capture_output=True, text=True)
    v = [l for l in r.stdout.splitlines() if l.startswith("VERDICT ")]
    got_v = v[-1].split()[1] if v else None
    ok = r.returncode == want_rc and got_v == want_v and "Traceback" not in r.stderr
    bad += not ok
    lines.append("%-28s %s rc=%d verdict=%s (want rc=%d %s)" % (name, "PASS" if ok else "FAIL", r.returncode, got_v, want_rc, want_v))
codes = set(misc_rule.EXIT.values())
ok = not (codes & {0, 1, 2})
bad += not ok
lines.append("%-28s %s verdict exit codes %s never equal 0/1/2 (traceback=1, argparse/interpreter=2)" % ("cli-codes-disjoint", "PASS" if ok else "FAIL", sorted(codes)))
cases_total = len(cases) + len(cli) + 1
shutil.rmtree(tmp, ignore_errors=True)

if march is None:
    lines.append("(firmware/quest3/unit1_nonslotted/misc.img absent: 3 March-dump cases skipped)")
lines.append("TOTAL pass=%d fail=%d" % (cases_total - bad, bad))
OUTDIR = os.environ.get("OUT") or os.path.join(HERE, "..", "fixtures", "misc")   # OUT=<dir>: write elsewhere
os.makedirs(OUTDIR, exist_ok=True)
open(os.path.join(OUTDIR, "RESULTS.txt"), "w", newline="\n").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if bad else 0)
