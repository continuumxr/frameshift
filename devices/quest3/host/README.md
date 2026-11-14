# Meta Quest 3: PC-side build helper

| path | what it does |
|---|---|
| `fs-gitcheck.sh`, `fs-gitcheck.ps1` | check that a pinned third-party git checkout (for example AOSP `mkbootimg`) is exactly the pinned commit, with no modified, untracked or ignored files, before a builder uses it (POSIX shell for the WSL builders, and a PowerShell twin) |
| `fixtures/gitcheck/run-gitcheck-fixtures.sh` | offline regression tests: builds throwaway repositories and checks every refusal |

Run the tests in WSL: `sh devices/quest3/host/fixtures/gitcheck/run-gitcheck-fixtures.sh`.

The PC-side tools that drive and record test runs on a headset (serial session, attempt
checks, outcome classification) are not part of this public tree. How a run is judged is
described in [How FrameShift works](../../../docs/HOW-FRAMESHIFT-WORKS.md#10-how-claims-are-checked).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
