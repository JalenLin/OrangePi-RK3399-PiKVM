#!/usr/bin/env bash
# Assemble the flashable SD card image.
#
# The layout is the vendor's, sector for sector (see config/board.conf). This
# board's BootROM looks for the initial loader at a fixed offset and U-Boot
# finds the rootfs by partition GUID, so these are not free parameters.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMG="${OUTPUT}/${IMG_NAME}.img"

for f in "${OUTPUT}/uboot/idbloader.img" "${OUTPUT}/uboot/uboot.img" \
         "${OUTPUT}/uboot/trust.img" "${OUTPUT}/kernel/boot.img" \
         "${OUTPUT}/${ROOTFS_TAR}"; do
    [[ -f "${f}" ]] || die "missing ${f} - run the earlier build steps first"
done

msg "assembling ${IMG}"
kbuild_run_root "
set -euo pipefail

HOST_UID=$(id -u)
HOST_GID=$(id -g)

OUT=/work/output
IMG=\${OUT}/${IMG_NAME}.img
ROOTDIR=\${OUT}/rootfs.d
ROOTIMG=\${OUT}/rootfs.ext4

rm -rf \"\${ROOTDIR}\" \"\${ROOTIMG}\" \"\${IMG}\"
mkdir -p \"\${ROOTDIR}\"

echo ':: unpacking rootfs'
tar -xf \${OUT}/${ROOTFS_TAR} -C \"\${ROOTDIR}\"

# The rootfs comes out of 'docker export', and the container runtime creates
# /.dockerenv inside every container it starts - so it is in the tarball, and
# without this it would ship on the card. systemd-detect-virt then answers
# \"docker\" on the real board, and systemd skips every unit guarded by
# ConditionVirtualization=!container. The one that matters is
# systemd-timesyncd: it never starts, nothing ever sets the clock, and since
# the board has no RTC every log timestamp stays in 1970. systemd-random-seed
# is skipped for the same reason, so the entropy pool is not seeded across
# boots either.
rm -f \"\${ROOTDIR}/.dockerenv\"

# Kernel modules are built separately from the rootfs, so graft them in.
if [ -d \${OUT}/modules/lib/modules ]; then
    echo ':: installing kernel modules'
    mkdir -p \"\${ROOTDIR}/usr/lib/modules\"
    cp -a \${OUT}/modules/lib/modules/* \"\${ROOTDIR}/usr/lib/modules/\"
fi

# There is no /boot filesystem on this layout - the kernel lives in the raw
# boot.img partition - so the only real mounts are root and the MSD store.
#
# commit=600 on root: ext4 flushes its journal every 10 minutes instead of
# every 5 seconds. This is a wear trade, and the cost is explicit - an unclean
# power loss can lose up to ten minutes of metadata rather than five seconds.
# It is the right trade here because the system writes almost nothing between
# reboots (the journal is in RAM, kvmd's runtime state is in /run and /tmp),
# so in practice there is rarely ten minutes of anything to lose. Anything
# that genuinely matters - an ISO upload - goes to the MSD partition, which is
# mounted separately and remounted rw only for the duration of the write.
#
# kvmd finds its image store by scanning this file for a six-field line whose
# options contain X-kvmd.otgmsd-root= (kvmd/fstab.py). Without that line the
# API reports storage: null and no ISO can ever be uploaded. It is mounted ro
# on purpose: kvmd flips it to rw through kvmd-helper-otgmsd-remount only while
# writing, so a crash mid-upload cannot leave the store dirty.
mkdir -p \"\${ROOTDIR}/var/lib/kvmd/msd\"
cat > \"\${ROOTDIR}/etc/fstab\" <<FSTAB
PARTUUID=${ROOTFS_PART_UUID}  /  ext4  defaults,noatime,commit=600  0  1
PARTUUID=${MSD_PART_UUID}  /var/lib/kvmd/msd  ext4  nodev,nosuid,noexec,ro,errors=remount-ro,X-kvmd.otgmsd-root=/var/lib/kvmd/msd,X-kvmd.otgmsd-user=kvmd  0 2
FSTAB

echo ':: building ext4 rootfs'
SIZE_KB=\$(du -s --block-size=1K \"\${ROOTDIR}\" | awk '{print \$1}')
# The rootfs is a fixed size: MSD is the last partition, so rootfs has no room
# to grow later and first boot cannot widen it. IMG_ROOT_SIZE_MB is the size
# unless the content alone is bigger.
SIZE_MB=\$(( SIZE_KB / 1024 + 512 ))
if [ \"\${SIZE_MB}\" -lt ${IMG_ROOT_SIZE_MB} ]; then SIZE_MB=${IMG_ROOT_SIZE_MB}; fi

truncate -s \"\${SIZE_MB}M\" \"\${ROOTIMG}\"
# ^metadata_csum matches what the vendor kernel and U-Boot expect to read.
mkfs.ext4 -q -F -O ^metadata_csum -b 4096 -L rootfs -d \"\${ROOTDIR}\" \"\${ROOTIMG}\"

echo ':: building ext4 msd store'
MSDIMG=\${OUT}/msd.ext4
rm -f \"\${MSDIMG}\"
truncate -s \"${IMG_MSD_MIN_MB}M\" \"\${MSDIMG}\"
mkfs.ext4 -q -F -O ^metadata_csum -b 4096 -L MSD \"\${MSDIMG}\"

echo ':: creating GPT image'
SEC_MSD=\$(( ${SEC_ROOTFS} + SIZE_MB * 2048 ))
TOTAL_MB=\$(( ${SEC_ROOTFS} / 2048 + SIZE_MB + ${IMG_MSD_MIN_MB} + 2 ))
truncate -s \"\${TOTAL_MB}M\" \"\${IMG}\"

parted -s \"\${IMG}\" mklabel gpt
parted -s \"\${IMG}\" unit s mkpart uboot  ${SEC_UBOOT} ${SEC_UBOOT_END}
parted -s \"\${IMG}\" unit s mkpart trust  ${SEC_TRUST} ${SEC_TRUST_END}
parted -s \"\${IMG}\" unit s mkpart boot   ${SEC_BOOT}  ${SEC_BOOT_END}
parted -s \"\${IMG}\" unit s mkpart rootfs ${SEC_ROOTFS} \$(( SEC_MSD - 1 ))
# MSD last, and only as large as the image needs to be; first boot grows it to
# whatever the card actually is. See overlay/usr/lib/pikvm/expand-msd.sh.
parted -s \"\${IMG}\" -- unit s mkpart msd \${SEC_MSD} -34s

# U-Boot's bootargs name the root filesystem by this GUID, so partition 4 has
# to carry exactly it or the board boots to a rootfs-not-found stop. Partition
# 5 gets a fixed GUID for the same reason fstab names it by PARTUUID: the
# device node moves around, the GUID does not.
sgdisk --partition-guid=4:${ROOTFS_PART_UUID} \"\${IMG}\" >/dev/null
sgdisk --partition-guid=5:${MSD_PART_UUID} \"\${IMG}\" >/dev/null

echo ':: writing bootloader and payloads'
dd if=\${OUT}/uboot/idbloader.img of=\"\${IMG}\" seek=${SEC_LOADER1} conv=notrunc status=none
dd if=\${OUT}/uboot/uboot.img     of=\"\${IMG}\" seek=${SEC_UBOOT}   conv=notrunc,fsync status=none
dd if=\${OUT}/uboot/trust.img     of=\"\${IMG}\" seek=${SEC_TRUST}   conv=notrunc,fsync status=none
dd if=\${OUT}/kernel/boot.img     of=\"\${IMG}\" seek=${SEC_BOOT}    conv=notrunc,fsync status=none
dd if=\"\${ROOTIMG}\"             of=\"\${IMG}\" seek=${SEC_ROOTFS}  conv=notrunc,fsync status=none
dd if=\"\${MSDIMG}\"              of=\"\${IMG}\" seek=\${SEC_MSD}    conv=notrunc,fsync status=none

rm -rf \"\${ROOTDIR}\" \"\${ROOTIMG}\" \"\${MSDIMG}\"

# parted/sgdisk shell out to udevadm to settle the kernel's view of the
# partition table. There is no udev in this container and no real block device
# involved, so those calls fail harmlessly - the on-disk table is still
# written correctly.
chown \"\${HOST_UID}:\${HOST_GID}\" \"\${IMG}\"
sync
"

# The boot partition is 128 MiB (SEC_BOOT..SEC_BOOT_END). Overflowing it
# silently truncates the kernel, which then fails to boot with no useful
# message.
boot_sz=$(stat -c%s "${OUTPUT}/kernel/boot.img")
boot_max=$(( (SEC_BOOT_END - SEC_BOOT + 1) * 512 ))
if (( boot_sz > boot_max )); then
    die "boot.img is ${boot_sz} bytes, larger than the ${boot_max}-byte boot partition"
fi

msg "image ready: ${IMG} ($(du -h "${IMG}" | cut -f1))"
