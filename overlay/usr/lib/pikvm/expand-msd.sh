#!/usr/bin/env bash
# Grow the MSD partition to fill the card, once, on first boot.
#
# The image is built only as large as it has to be, so a freshly flashed card
# has the MSD partition sitting at its minimum size with the rest of the card
# unallocated - and the GPT's backup header still at the end of the *image*
# rather than the end of the device, so that space is not even addressable.
#
# MSD is deliberately the last partition. It is the only one that can grow:
# rootfs has MSD behind it and would have to be moved, so rootfs is sized at
# build time (IMG_ROOT_SIZE_MB) instead.
set -euo pipefail

log() { echo "expand-msd: $*"; }

root_src="$(findmnt -no SOURCE /)"          # e.g. /dev/mmcblk1p4
case "${root_src}" in
    /dev/mmcblk*p[0-9]*) disk="${root_src%p[0-9]*}" ;;
    /dev/sd[a-z][0-9]*)  disk="${root_src%%[0-9]*}" ;;
    *) log "don't know how to find the disk for ${root_src}, giving up"; exit 0 ;;
esac
part=5
node="${disk}$(case "${disk}" in /dev/mmcblk*) echo "p${part}";; *) echo "${part}";; esac)"

[[ -b "${node}" ]] || { log "${node} does not exist, nothing to expand"; exit 0; }

# sfdisk rewrites both GPT copies, which is what moves the backup header to the
# real end of the device; without that the free space stays unusable.
log "growing ${node} to the end of ${disk}"
echo ",+" | sfdisk --force -N "${part}" "${disk}"
partx -u "${disk}" || true
udevadm settle 2>/dev/null || true

log "growing the filesystem on ${node}"
e2fsck -fp "${node}" || true      # resize2fs refuses on an unchecked fs
resize2fs "${node}"

log "done: $(findmnt -no SIZE "${node}" 2>/dev/null || lsblk -no SIZE "${node}")"
