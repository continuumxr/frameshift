# Meta Quest 3

The Meta Quest 3 is FrameShift's primary target and the only headset with hands-on work so far
(two test units). FrameShift builds for Meta Horizon OS v2.7, using Meta's published kernel source
for that release (Linux 5.10, Qualcomm XR2 Gen 2 platform).

Every image here is started by a temporary `fastboot boot` from a PC. Nothing is flashed, and the
next normal power-on starts Meta Horizon OS as usual. For the results, see
[What works today](../../docs/WHAT-WORKS-TODAY.md).

## Folders

| folder | what its code does | stage |
|---|---|---|
| [common/](common/) | shared startup code for every test image: the first process (PID 1) with its deadline, a one-child supervisor, the checksummed record format and its decoders | all |
| [stage1/](stage1/) | the first test image: a startup program on Meta's stock kernel that answers a challenge over USB serial | first shell |
| [stage2a/](stage2a/) | the tools of an early trial that ran a few pinned Valve programs under our startup program, read-only | early trial |
| [stage3a/](stage3a/), [stage3b/](stage3b/), [stage3c/](stage3c/), [stage3d/](stage3d/) | the display test images and their test-pattern program, in four revisions | display test |
| [k1a/](k1a/) | FrameShift's first own kernel build and its test image | first kernel boot |
| [k1g/](k1g/) | the kernel with the boot-storage write guard, and the probe image that tests it | boot-storage guard test |
| [n1/](n1/) | a USB network link next to the serial console, with a bounded transfer test | USB network test |
| [h1/](h1/) | an ordered, bounded loader for Meta's driver modules, for later images | kernel test and later |
| [ts/](ts/) | the device inputs of the thermal and battery service | thermal service |
| [host/](host/) | a PC-side helper that checks pinned third-party checkouts before a build | all |

## How a test image is built and checked

- Each package has an image builder (`build-image*.sh`, or `build.sh` for the first shell; run in
  WSL) that assembles a boot image from FrameShift's own files, the owner's own stock boot images
  and a few pinned third-party tools (AOSP `mkbootimg`, a static busybox). The builders check every
  input against a pinned hash and refuse anything else. (The early trial's builder in
  [stage2a/](stage2a/) is not included.)
- `test-builder.sh` checks that the builder refuses bad inputs; `test-image.sh` runs the image's
  startup code offline under QEMU user emulation and namespaces, against recorded fixtures.
- The list of Meta driver modules an image loads is taken from the owner's own firmware and is not
  published here. Builders that need it refuse to start without it.

The PC-side tools that drive and record runs on a headset are not part of this public tree.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
