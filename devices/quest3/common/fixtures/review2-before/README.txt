Revision 3 (commit 05a2dd2) run through the revision-4 fixtures (second review S1/S2).
deadline-05a2dd2.txt: HOLD=<05a2dd2 target/pid1-hold.sh> OUT=<dir> tools/fixtures-deadline.sh -> 27/31: static-clamp (the shell DIED at '08 04': arithmetic syntax error), frozen-clock (no reboot at all with the backstop killed), octal-clock (no reboot: the loop shell exited), static-pid1-exec (3 sites, no deadline-ticks).
misc-cli-05a2dd2.txt: a missing capture gave a traceback and exit 1, which that revision's table reads as EXPECTED.
huge-clock and set-eu also pass on 05a2dd2: they are kept as guards, not as regressions.
