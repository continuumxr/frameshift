# Meta Quest 3: first shell

The first FrameShift test image: Meta's stock kernel with a startup program of our own.

| path | what it does |
|---|---|
| `init.sh` | the startup program (PID 1). It brings up a USB serial gadget, answers a fresh one-time challenge from the PC to prove which image is running, and writes nothing to the headset's storage |
| `fs-reboot.c` | a minimal helper that restarts the headset into the bootloader |
| `build.sh` | builds the boot image from the owner's own stock boot image and pinned tools |
| `test-gadget.sh`, `test-modorder.sh` | offline checks, in a sandbox, of the USB gadget setup and of the module load order (the second needs the owner's own stock vendor ramdisk) |

**Result:** passed on a Meta Quest 3 on 2026-10-08 by temporary boot.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
