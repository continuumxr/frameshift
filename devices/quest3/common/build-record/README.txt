Tracked copies of the gitignored build records in devices/quest3/common/build/
(fix round 6, images review N4): BUILD.txt (fs-supervise and fs-reboot-final
build: compiler, flags, source and binary SHA-256, checks), fs-reboot-final.check
(check_final.py: the simulated syscall sequence and arguments), .dis (the
disassembly the build checks), .layout. The binaries themselves stay in build/
and are pinned by SHA-256 in the stage-2a/3a builders.
