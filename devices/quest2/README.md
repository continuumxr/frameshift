# Meta Quest 2

The Meta Quest 2 follows once SteamOS boots on the Meta Quest 3. The work so far is offline only:
no FrameShift image has run on a Quest 2.

- **Platform:** Qualcomm XR2 (Gen 1), Adreno 650. FrameShift builds for Meta Horizon OS v2.7,
  from Meta's published kernel source for that release (Linux 4.19).
- **Kernel gate:** Meta's published source reproduces the symbol versions Meta's stock modules
  expect, and the extra options SteamOS needs first change none of them.
- **Memory:** with 6 GB, the Quest 2 will read the SteamOS image from the PC over USB instead of
  holding it in memory.
- **USB:** Meta's stock Quest 2 kernel has no USB serial gadget, so a first test image on the
  stock kernel talks to the PC over a USB network link.

| folder | what its code does |
|---|---|
| [channel/](channel/) | the USB network channel for a first Quest 2 test image (offline draft) |
| [analysis/](analysis/) | offline tools that inspect the owner's own Quest 2 firmware (boot image layout, verified-boot data, device tree) |

**Safety notes:** never use the bootloader menu's "Switch Boot Slot" option. The stock kernel
defaults to the `performance` CPU governor; FrameShift images set a capped governor instead.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
