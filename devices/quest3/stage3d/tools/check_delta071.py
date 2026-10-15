#!/usr/bin/env python3
"""fs-pattern v0.7.1 against v0.7: the device build differs ONLY by the J-141 fix. Offline; stdlib only.

usage: check_delta071.py V071/src/fs-pattern.c V07/src/fs-pattern.c
(V07: `git show 5cec9d3:devices/quest3/stage3d/src/fs-pattern.c`, the source of the reviewed v0.7 binary 7c9fa98c...)

Only the DEVICE build is compared (the text before "#else /* FSP_UNIT_TEST"), without the leading header comment. The
v0.7.1 text with exactly these changes undone must equal the v0.7 text byte for byte:
  - FSP_VERSION "0.7.1" (was "0.7");
  - the FSP_LOG_MODES define and its #if/#error guard (new, after the essential-cap guard);
  - MAXMODES 512 with its comment (was 128) and its #if/#error guard (new);
  - in run_show's mode loop: the 4-line "not logged, counted in opt_skipped" branch (new).
Everything else (the mode policy, the request builder, the reset, the quad branch, the loggers, every limit other than
MAXMODES) is therefore v0.7's, which the stage-3d reviews A-E covered. Prints CHECK lines; exit 1 on any FAIL.
"""
import sys

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail)).rstrip())
    fails += 0 if ok else 1


def device(path):
    t = open(path, encoding="utf-8").read().split("#else /* FSP_UNIT_TEST")[0]
    i = t.index(" */\n") + 4             # end of the leading header comment
    return t[i:]


UNDO = [  # (v0.7.1 text, v0.7 text)
    ('#define FSP_VERSION        "0.7.1"\n', '#define FSP_VERSION        "0.7"\n'),
    ('#define FSP_LOG_MODES      48    /* v0.7.1: mode records logged (optional beyond FSP_ESS_MODES); expected modes always */\n'
     '#if FSP_LOG_MODES < FSP_ESS_MODES || FSP_LOG_MODES > 64\n'
     '#error "FSP_LOG_MODES must be FSP_ESS_MODES..64"\n'
     '#endif\n', ''),
    ('#define MAXMODES 512    /* v0.7.1 (was 128): v2.7 lists 305 (338 before pruning; README §3a limit table) */\n',
     '#define MAXMODES 128\n'),
    ('#if MAXMODES < 480\n'
     '#error "MAXMODES must hold 2 timing nodes x 240 refresh rates (v2.7: 338 built, 305 listed)"\n'
     '#endif\n', ''),
    ('\t\tif (i >= FSP_LOG_MODES && !is_expected_mode(&modes[i])) {   /* v0.7.1: not logged, counted */\n'
     '\t\t\tg_opt_skipped++;\n'
     '\t\t\tcontinue;\n'
     '\t\t}\n', ''),
]


def main():
    new, old = device(sys.argv[1]), device(sys.argv[2])
    t = new
    for a, b in UNDO:
        n = t.count(a)
        check("v0.7.1 change present exactly once: %s" % a.strip().splitlines()[0][:70], n == 1, "%d occurrence(s)" % n)
        t = t.replace(a, b)
    same = t == old
    detail = ""
    if not same:
        import difflib
        d = list(difflib.unified_diff(old.splitlines(), t.splitlines(), "v0.7", "v0.7.1-undone", lineterm="", n=0))
        detail = " | ".join(d[2:8])
    check("device build: v0.7.1 with exactly these changes undone == v0.7, byte for byte (nothing else changed)", same, detail)
    check("v0.7 had MAXMODES 128 (the J-141 limit)", "#define MAXMODES 128\n" in old)
    sys.exit(1 if fails else 0)


main()
