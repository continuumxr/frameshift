#!/bin/bash
# fs-blkguard VM test kernel, QEMU variant: a generic arm64 kernel (upstream arm64 defconfig,
# which supports the QEMU "virt" machine) built from the SAME Meta v2.7 tree with the SAME
# fs-blkguard commit plus the test-only build fix also used for UML (uml-test-only-build-fix.patch).
# Same clang r450784e toolchain as the Quest builds; no LTO.  Offline; no device access.
#   bash tools/blkguard/vm/build_qemu_kernel.sh [unpatched]
set -uo pipefail
W=~/work/blkguard
CL=~/toolchains/clang-r450784e/bin; MK=~/toolchains/build-tools/bin/make
ENVV="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 CC=$CL/clang LD=$CL/ld.lld AR=$CL/llvm-ar NM=$CL/llvm-nm OBJCOPY=$CL/llvm-objcopy OBJDUMP=$CL/llvm-objdump READELF=$CL/llvm-readelf STRIP=$CL/llvm-strip HOSTCC=$CL/clang HOSTLD=$CL/ld.lld HOSTAR=$CL/llvm-ar"
export PATH=$CL:$PATH
if [ "${1:-}" = unpatched ]; then
  S=$W/src-q-nog; O=$W/out-qemu-nog
  [ -d $S ] || { git clone -q --shared $W/src $S && git -C $S checkout -q -b unpatched dbc2bc83a; }
else
  S=$W/src-um; O=$W/out-qemu   # fs-blkguard + the test-only sched build fix (Meta !WALT stubs)
fi
# the QEMU UFS host (hw/ufs, PCI 1b36:0013) needs a test-only PCI id in ufshcd-pci (never in a device kernel)
if [ "${1:-}" != unpatched ] && ! git -C $S log --format=%s | grep -q '^TEST ONLY (QEMU): bind ufshcd-pci'; then
  git -C $S -c user.name=fs-build -c user.email=fs-build@invalid am -q "$(dirname "$0")/qemu-test-only-ufs-pci-id.patch" || { echo "cannot apply the UFS test-only patch"; exit 1; }
fi
echo "== source: $(git -C $S log --oneline -1)"
mkdir -p $O
$MK -C $S O=$O $ENVV defconfig > $O/defconfig.log 2>&1 || { echo "defconfig failed"; exit 1; }
$S/scripts/config --file $O/.config -e VIRTIO -e VIRTIO_MMIO -e VIRTIO_BLK -e SCSI -e SCSI_VIRTIO \
  -e BLK_DEV_SD -e CHR_DEV_SG -e BLK_DEV_BSG -e BLK_DEV_RAM --set-val BLK_DEV_RAM_COUNT 4 \
  --set-val BLK_DEV_RAM_SIZE 8192 -e BLK_DEV_LOOP -e MD -e BLK_DEV_DM -e EFI_PARTITION \
  -e PARTITION_ADVANCED -e DEVTMPFS -e TMPFS -e AIO -e SWAP -e BLK_DEV_INITRD -e RD_GZIP \
  -e PCI -e PCI_HOST_GENERIC -e SCSI_UFSHCD -e SCSI_UFSHCD_PCI -e SCSI_UFS_BSG \
  -d DEVMEM -d KEXEC -d KEXEC_FILE -d HIBERNATION -d DEBUG_FS -d LTO_CLANG -d CFI_CLANG \
  -e RT_THROTTLING_SYSCTL -d SCHED_AUTOGROUP -d WERROR -d QCOM_TSENS -d HID_APPLE -d MMC_SDHCI_MSM -d POWER_RESET_MSM
# (the last line works around Meta vendor code that does not build in a generic defconfig;
#  none of it is block-layer code)
$MK -C $S O=$O $ENVV olddefconfig >> $O/defconfig.log 2>&1
T0=$(date +%s)
rc=0; $MK -k -C $S O=$O $ENVV -j6 Image > $O/build.log 2>&1 || rc=$?
echo "== QEMU kernel build rc=$rc in $(( $(date +%s) - T0 ))s"
[ $rc -eq 0 ] || { grep -m20 -E 'error:|Error ' $O/build.log; exit 3; }
ls -la $O/arch/arm64/boot/Image
