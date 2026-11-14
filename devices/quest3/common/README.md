# Meta Quest 3: shared startup code

The building blocks every FrameShift test image shares.

| path | what it does |
|---|---|
| `target/pid1-hold.sh` | the image's first process (PID 1): holds the headset for a bounded time and always returns it to the bootloader at its deadline, even if the PC side gives up |
| `target/fs-done` | ends a session early and cleanly, on the PC's request |
| `src/fs-supervise.c` | runs one child program with an empty environment, a time limit and capped output, and reports how it ended |
| `src/fs-reboot-final.c` | the small, checked helper that performs the final restart to the bootloader |
| `target/fsb1-enc.sh`, `target/fsb1-pace.sh` | write results as framed, checksummed records over the USB serial console (paced, so a slow console loses nothing) |
| `tools/fsb1.py`, `host/fsb1.ps1` | two independent decoders for those records (Python, and PowerShell for the PC); damaged or incomplete records are rejected, never repaired |
| `tools/misc_rule.py` | compares before-and-after copies of the headset's restart-control data and classifies any change (its test suite needs owner-specific reference copies and is not included) |
| `tools/build.sh` | builds the static ARM64 helpers with the pinned AOSP clang, twice, and checks they are bit-identical |
| `tools/fixtures-*.sh`, `tools/test_*.py`, `host/test-fsb1.ps1`, `tools/testprogs/` | the offline fixture generators and test suites |
| `fixtures/` | the recorded results of those suites |

## Offline tests

```
python3 devices/quest3/common/tools/test_fsb1.py                          # 38 cases
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\common\host\test-fsb1.ps1
```

The fixture generators (`tools/fixtures-*.sh`) need the built helpers and a pinned static busybox,
which are not in the repository.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
