Revision 1 (commit e890a7a) run through the revision-2 fixtures, for the before/after table in README.md.
supervise-native-rev1.txt: SRC=<e890a7a src/fs-supervise.c> OUT=<dir> tools/fixtures-supervise-native.sh
deadline-rev1.txt: HOLD=<e890a7a target/pid1-hold.sh> OUT=<dir> tools/fixtures-deadline.sh (run before fs-done-honest was added and before parallel results were serialised)
