# Kernel patches

FrameShift's kernel patches are licensed **GPL-2.0-only**
(SPDX-License-Identifier: GPL-2.0-only), the licence of the Linux kernels they
apply to (full text: [LICENSES/GPL-2.0-only.txt](../LICENSES/GPL-2.0-only.txt)).
This overrides the repository's default Apache-2.0 licence for kernel patches
and for FrameShift's own kernel modules.

## Published patches

- **fs-blkguard, the boot-storage write guard:**
  [tools/blkguard/patches/](../tools/blkguard/patches/). It applies to Meta's
  published Meta Quest 3 kernel source for Meta Horizon OS v2.7 and refuses
  every way of writing the headset's boot chain while armed. Its virtual-machine
  tests, probe and policy harness are beside it in
  [tools/blkguard/](../tools/blkguard/).

The patches for the kernel for Steam (the features SteamOS needs and the
restart lockdown) passed on both test headsets; they will be published with the
first release.

## Kernel configuration

The kernel configurations FrameShift builds with, and the scripts that build
them, are in the package folders under [devices/quest3/](../devices/quest3/)
(for example `devices/quest3/k1a/kernel/`). Meta's kernel source itself is not
included: Meta publishes it per release.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
