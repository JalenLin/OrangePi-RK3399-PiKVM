#!/usr/bin/env bash
# Build the kernel and pack it into the Rockchip boot.img.
#
# boot.img is an Android boot image (kernel Image + resource.img, which
# carries the DTB). It is written raw to the "boot" partition; there is no
# filesystem there, so no extlinux.conf and no /boot to edit.
#
# Two tracks, selected by KERNEL_TRACK (see config/board.conf):
#   rk612 - Rockchip BSP 6.12, the default and the one that boots
#   bsp   - vendor 4.4, kept for reference; too old for current systemd
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

case "${KERNEL_TRACK}" in
    rk612)
        KDIR="${SOURCES}/kernel-rk612"
        fetch_repo kernel-rk612 "${KERNEL_RK612_REPO}" "${KERNEL_RK612_BRANCH}"
        DEFCONFIG="${KERNEL_RK612_DEFCONFIG}"
        BOOT_TARGET="${KERNEL_RK612_BOOT_TARGET}"
        DTB="${KERNEL_RK612_DTB}"
        PATCHDIR="${PATCHES}/kernel-6.12"
        # Absolute path on purpose. The container puts the vendor's Linaro
        # 6.3 toolchain first on PATH for the 4.4 track, and that compiler is
        # too old for 6.12 - it fails with "no option -Wattribute-warning",
        # which GCC only grew in 9.x. Naming the distro cross-gcc explicitly
        # keeps the two tracks from stealing each other's compiler.
        CROSS="/usr/bin/aarch64-linux-gnu-"
        ;;
    bsp)
        KDIR="${SOURCES}/kernel-bsp"
        fetch_repo kernel-bsp "${KERNEL_BSP_REPO}" "${KERNEL_BSP_BRANCH}"
        fetch_repo toolchain  "${TOOLCHAIN_REPO}"  "${TOOLCHAIN_BRANCH}"
        DEFCONFIG="${KERNEL_BSP_DEFCONFIG}"
        BOOT_TARGET="${KERNEL_BSP_BOOT_TARGET}"
        DTB="${KERNEL_BSP_DTB}"
        PATCHDIR="${PATCHES}/kernel-4.4"
        # Resolves to the Linaro 6.3 toolchain via PATH, which is what the
        # vendor 4.4 tree expects.
        CROSS="aarch64-linux-gnu-"
        ;;
    *)
        die "unknown KERNEL_TRACK '${KERNEL_TRACK}' (want: rk612 | bsp)"
        ;;
esac

KREL="$(basename "${KDIR}")"
OUT="${OUTPUT}/kernel"

apply_patches "${KDIR}" "${PATCHDIR}"

msg "track ${KERNEL_TRACK}: configuring with ${DEFCONFIG} + pikvm.config"
kbuild_run "
    set -e
    cd sources/${KREL}
    make ARCH=arm64 CROSS_COMPILE=${CROSS} ${DEFCONFIG}
    ./scripts/kconfig/merge_config.sh -m -O . .config \
        /work/config/kernel-fragments/pikvm.config
    make ARCH=arm64 CROSS_COMPILE=${CROSS} olddefconfig
"

# merge_config only warns when the tree cannot honour a symbol. For the ones
# PiKVM cannot run without, a silent drop would surface much later as a dead
# keyboard on the target, so fail here instead.
msg "verifying required symbols survived olddefconfig"
required=(
    CONFIG_VIDEO_TC35874X
    CONFIG_USB_CONFIGFS_F_HID
    CONFIG_USB_CONFIGFS_MASS_STORAGE
    # The HDMI console is a debugging lifeline, not a nicety - see the
    # fragment. Losing it silently is exactly the failure it exists to catch.
    CONFIG_FRAMEBUFFER_CONSOLE
    CONFIG_ROCKCHIP_DW_HDMI
)
missing=()
for sym in "${required[@]}"; do
    grep -qE "^${sym}=(y|m)$" "${KDIR}/.config" || missing+=("${sym}")
done
(( ${#missing[@]} == 0 )) || die "kernel config lost required symbols: ${missing[*]}"

msg "building kernel + ${BOOT_TARGET}"
kbuild_run "
    set -e
    cd sources/${KREL}
    make ARCH=arm64 CROSS_COMPILE=${CROSS} -j\$(nproc) ${BOOT_TARGET}
    make ARCH=arm64 CROSS_COMPILE=${CROSS} -j\$(nproc) modules
    rm -rf /work/output/modules
    make ARCH=arm64 CROSS_COMPILE=${CROSS} \
        INSTALL_MOD_PATH=/work/output/modules modules_install
"

mkdir -p "${OUT}"
[[ -f "${KDIR}/boot.img" ]] || die "kernel did not produce boot.img"
cp -f "${KDIR}/boot.img" "${OUT}/"
cp -f "${KDIR}/arch/arm64/boot/dts/rockchip/${DTB}.dtb" "${OUT}/" 2>/dev/null || true

# The bare Image and DTB as well as boot.img, because the two bootloader
# tracks want different things from the same build. The BSP U-Boot reads the
# raw Android boot.img out of partition 3; mainline cannot parse that format at
# all and reads /boot off the root filesystem instead. Copying both here keeps
# that choice in mkimage.sh, where the rest of the layout lives, rather than
# making it a second kernel build.
[[ -f "${KDIR}/arch/arm64/boot/Image" ]] || die "kernel did not produce Image"
cp -f "${KDIR}/arch/arm64/boot/Image" "${OUT}/"

msg "kernel ready in output/kernel (track ${KERNEL_TRACK}):"
ls -lh "${OUT}"
