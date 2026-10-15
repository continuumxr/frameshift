# Stage 3d input provenance (withheld from the public copy)

The files of this folder (`images.txt`, `dt.txt`, `modules.txt`, `ota.txt`, `avb.txt`,
`runtime.txt`, `SHA256SUMS`) are readouts that `stage3d/tools/v27-inputs.sh` makes from the
stock Horizon OS images and from a headset. They are withheld because they reproduce
firmware content (device-tree property values, including panel command sequences; OTA
metadata) and unit state, which the publication rules keep out of this repository.

Regenerate them from your own firmware and headset with `stage3d/tools/v27-inputs.sh`
(offline, read-only). The image pins the stage-3d documents quote (SHA-256 values) are
unchanged and can be checked against your own files.
