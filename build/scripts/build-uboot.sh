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

# make.sh also packs rk3399_loader_*.bin - the same TPL+SPL as idbloader.img,
# but wrapped in the format the BootROM's USB protocol takes rather than the
# one it reads off a card. It is what `rkdeveloptool db` pushes into DRAM to
# make a board in maskrom mode able to write its own eMMC, so it belongs
# alongside the images rather than only in the source tree. See docs/emmc.md.
shopt -s nullglob
loaders=( "${UBOOT_DIR}"/rk3399_loader_*.bin )
shopt -u nullglob
(( ${#loaders[@]} )) || die "U-Boot did not produce rk3399_loader_*.bin"
cp -f "${loaders[@]}" "${OUT}/"

msg "bootloader ready in output/uboot:"
ls -lh "${OUT}"
