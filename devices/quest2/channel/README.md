# Meta Quest 2: USB network channel (offline draft)

The channel a first Quest 2 test image would use to talk to the PC: a USB network function (NCM)
with an IPv6 link-local address derived from the session's one-time challenge, and a small
responder that accepts only a fixed set of commands. **Offline only: never run on a headset.**

| path | what it does |
|---|---|
| `src/fs-rpcd.c` | the fixed-command TCP responder (static ARM64) |
| `target/fs-ncm.sh` | sets up the NCM gadget, the address and the responder; sourced by the image's startup program |
| `host/fs-transport-tcp.ps1` | the PC side of the channel (PowerShell 5.1) |
| `host/test-transport-tcp.ps1` | its offline tests, against a simulated device in WSL |
| `tools/build.sh`, `build/fs-rpcd.undef`, `tools/fs-rpcd.undef.allow` | build the responder and check which library symbols it uses |
| `tools/src-gate.sh`, `tools/undef-gate.sh`, `tools/obj-scan.py`, `tools/seg-check.py`, `tools/elf-mutate.py` | source and binary gates that refuse unexpected code |
| `tools/rpc.py`, `tools/device_cases.py`, `tools/evil_device.py`, `tools/sim-pid1.sh`, `tools/shim_nowait.c` | test clients, a deliberately misbehaving device and a simulated startup program |
| `tools/fixtures-*.sh`, `tools/host-fixture-wsl.sh`, `tools/check-timing.py`, `fixtures/` | the offline fixtures, the timing check and their recorded results |

Some fixture sections need build inputs that are not in the repository and report themselves as
skipped.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
