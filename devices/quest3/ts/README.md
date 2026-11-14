# Meta Quest 3: thermal service inputs

The Meta Quest 3 side of FrameShift's thermal and battery service. The service itself is in
[devices/thermal/](../../thermal/).

| path | what it does |
|---|---|
| `firmware-manifest.tsv` | the firmware files the service relies on, by name and SHA-256 only (no firmware bytes); the files stay on the owner's headset |
| `target/fs-ts-info.sh` | read-only checks of the image's composition that each thermal-service test image runs first, before the service starts |
| `tools/test_ts_info.sh` | the offline tests of those checks |
| `fixtures/ts-info/` | their recorded results |

**Temperature sensor test:** under stock Meta Horizon OS, the sensors the service needs were
identified and read on both units (2026-10-18), and the headsets' fan-trip tables matched the
service's built-in table. The thermal service tests on FrameShift's own kernel come next.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
