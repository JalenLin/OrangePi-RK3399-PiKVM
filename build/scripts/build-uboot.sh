#!/usr/bin/env bash
# Build the RK3399 bootloader chain: idbloader.img + uboot.img + trust.img
#
# Rockchip's make.sh does the packing. It looks for its blob repository at
# ../external/rkbin and its toolchain at ../toolchain/, both relative to the
# U-Boot tree - which is why sources/ is laid out the way it is.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

UBOOT_DIR="${SOURCES}/uboot-bsp"
OUT="${OUTPUT}/uboot"

fetch_repo uboot-bsp   "${UBOOT_BSP_REPO}"  "${UBOOT_BSP_BRANCH}"
fetch_repo external-bsp "${EXTERNAL_REPO}"  "${EXTERNAL_BRANCH}"
fetch_repo toolchain   "${TOOLCHAIN_REPO}"  "${TOOLCHAIN_BRANCH}"
ln -sfn external-bsp "${SOURCES}/external"

apply_patches "${UBOOT_DIR}" "${PATCHES}/uboot"

msg "building U-Boot (${UBOOT_BSP_MAKE_TARGET})"
kbuild_run "cd sources/uboot-bsp && ./make.sh ${UBOOT_BSP_MAKE_TARGET}"

mkdir -p "${OUT}"
for f in idbloader.img uboot.img trust.img; do
    [[ -f "${UBOOT_DIR}/${f}" ]] || die "U-Boot did not produce ${f}"
    cp -f "${UBOOT_DIR}/${f}" "${OUT}/"
done

msg "bootloader ready in output/uboot:"
ls -lh "${OUT}"
