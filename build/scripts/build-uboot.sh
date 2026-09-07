#!/usr/bin/env bash
# Build the RK3399 bootloader.
#
# Two tracks, selected by UBOOT_TRACK (see config/board.conf):
#   bsp      - the vendor's U-Boot 2017.09 fork. The default, and the one that
#              boots. Rockchip's make.sh does the packing; it looks for its
#              blob repository at ../external/rkbin and its toolchain at
#              ../toolchain/, both relative to the U-Boot tree, which is why
#              sources/ is laid out the way it is.
#   mainline - U-Boot v2025.07. Builds; does not boot this board yet. See
#              "Mainline U-Boot" in docs/roadmap.md.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Track-specific, and not cosmetically so: both tracks produce a file called
# idbloader.img, and they are not interchangeable. Sharing one directory meant
# a mainline build silently replaced the BSP loader that mkimage.sh reads,
# leaving output/uboot holding mainline's first stage next to the BSP's
# uboot.img and trust.img - an image that assembles cleanly and boots nothing.
# mkimage.sh only ever looks at output/uboot.
case "${UBOOT_TRACK}" in
bsp)      OUT="${OUTPUT}/uboot" ;;
mainline) OUT="${OUTPUT}/uboot-mainline" ;;
*)        die "unknown UBOOT_TRACK '${UBOOT_TRACK}' (want: bsp | mainline)" ;;
esac

case "${UBOOT_TRACK}" in
bsp)
    UBOOT_DIR="${SOURCES}/uboot-bsp"

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

    # make.sh also packs rk3399_loader_*.bin - the same DDR init and
    # miniloader, but wrapped in the format the BootROM's USB protocol takes
    # rather than the one it reads off a card. It is what `rkdeveloptool db`
    # pushes into DRAM to make a board in maskrom mode able to write its own
    # eMMC, so it belongs alongside the images rather than only in the source
    # tree. See docs/emmc.md.
    shopt -s nullglob
    loaders=( "${UBOOT_DIR}"/rk3399_loader_*.bin )
    shopt -u nullglob
    (( ${#loaders[@]} )) || die "U-Boot did not produce rk3399_loader_*.bin"
    cp -f "${loaders[@]}" "${OUT}/"
    ;;

mainline)
    UBOOT_DIR="${SOURCES}/uboot-ml"

    fetch_repo uboot-ml "${UBOOT_ML_REPO}" "${UBOOT_ML_TAG}"
    fetch_repo tfa      "${TFA_REPO}"      "${TFA_TAG}"

    apply_patches "${SOURCES}/tfa" "${PATCHES}/tfa"
    apply_patches "${UBOOT_DIR}"   "${PATCHES}/uboot-mainline"

    # BL31 is built here rather than taken from rkbin, and that is the whole
    # reason this track boots at all - see the comment on TFA_REPO in
    # config/board.conf. The M0 cross-compiler is for rk3399's power-management
    # firmware, which TF-A builds into BL31.
    # Unconditionally, not "if the elf is missing": TF-A's make is incremental
    # and takes under a minute, and caching it would quietly keep a stale BL31
    # after apply_patches had reset the tree under it.
    bl31="${SOURCES}/tfa/${TFA_BL31}"
    msg "building TF-A ${TFA_TAG} BL31 (PLAT=${TFA_PLAT})"
    kbuild_run "
        set -e
        cd sources/tfa
        make PLAT=${TFA_PLAT} CROSS_COMPILE=/usr/bin/aarch64-linux-gnu- \
             M0_CROSS_COMPILE=arm-none-eabi- bl31 -j\$(nproc)
    "
    [[ -f "${bl31}" ]] || die "TF-A did not produce ${TFA_BL31}"

    msg "building U-Boot ${UBOOT_ML_TAG} (${UBOOT_ML_DEFCONFIG})"
    # ARCH=arm, not arm64: U-Boot has never renamed it. The compiler is named
    # absolutely for the same reason the kernel does it - the container puts
    # the vendor's Linaro 6.3 first on PATH for the dead 4.4 track, and it is
    # far too old for this.
    kbuild_run "
        set -e
        cd sources/uboot-ml
        make ARCH=arm CROSS_COMPILE=/usr/bin/aarch64-linux-gnu- ${UBOOT_ML_DEFCONFIG}
        ./scripts/kconfig/merge_config.sh -m -O . .config \
            /work/config/uboot-fragments/pikvm.config
        make ARCH=arm CROSS_COMPILE=/usr/bin/aarch64-linux-gnu- olddefconfig
        make ARCH=arm CROSS_COMPILE=/usr/bin/aarch64-linux-gnu- \
             BL31=/work/sources/tfa/${TFA_BL31} -j\$(nproc)
    "

    # merge_config only warns when a symbol does not survive, and both of ours
    # decide where the image goes and whether the console can be typed at.
    for sym in "CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x6000" "CONFIG_BAUDRATE=115200"; do
        grep -qx "${sym}" "${UBOOT_DIR}/.config" || die "u-boot config lost ${sym}"
    done

    mkdir -p "${OUT}"
    for f in idbloader.img u-boot.itb; do
        [[ -f "${UBOOT_DIR}/${f}" ]] || die "U-Boot did not produce ${f}"
        cp -f "${UBOOT_DIR}/${f}" "${OUT}/"
    done
    # Written at sector 64 it places both parts where mainline expects them,
    # which is the layout to use if the config fragment is ever dropped.
    cp -f "${UBOOT_DIR}/u-boot-rockchip.bin" "${OUT}/" 2>/dev/null || true

    warn "mainline U-Boot boots this board but nothing yet loads a kernel"
    warn "from it: the kernel lives in a raw Rockchip boot partition that"
    warn "mainline cannot read. See \"Mainline U-Boot\" in docs/roadmap.md."
    ;;

esac

msg "bootloader ready in ${OUT#"${ROOT}/"} (track ${UBOOT_TRACK}):"
ls -lh "${OUT}"
