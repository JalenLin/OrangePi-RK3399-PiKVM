#!/usr/bin/env bash
# Build the Arch Linux ARM + PiKVM rootfs and export it as a tarball.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CACHE="${ROOT}/.cache"
CTX="${CACHE}/rootfs-ctx"
TARBALL="$(basename "${ALARM_ROOTFS_URL}")"
ROOTFS_IMAGE="opi-pikvm/rootfs:latest"

mkdir -p "${CACHE}" "${CTX}"

# aarch64 binaries have to run on this x86_64 host to let pacman work inside
# the image, which needs a qemu-user handler registered with the kernel.
if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    msg "registering qemu-aarch64 binfmt handler (needs a privileged container)"
    docker run --privileged --rm tonistiigi/binfmt --install arm64 \
        || die "could not register binfmt for arm64"
fi

if [[ ! -f "${CACHE}/${TARBALL}" ]]; then
    msg "downloading ${TARBALL}"
    curl -fL --progress-bar -o "${CACHE}/${TARBALL}.part" "${ALARM_ROOTFS_URL}"
    mv "${CACHE}/${TARBALL}.part" "${CACHE}/${TARBALL}"
else
    msg "using cached ${TARBALL}"
fi

# Keep the build context minimal: the tarball plus our overlay.
cp -f "${CACHE}/${TARBALL}" "${CTX}/"
rm -rf "${CTX}/overlay"
cp -a "${ROOT}/overlay" "${CTX}/overlay"
# Userspace patches, applied inside the rkmpp stage.
rm -rf "${CTX}/patches"
mkdir -p "${CTX}/patches"
cp -a "${ROOT}/patches/libv4l-rkmpp" "${CTX}/patches/"

msg "building rootfs image (pacman under qemu; slow)"
docker build \
    --platform linux/arm64 \
    -t "${ROOTFS_IMAGE}" \
    -f "${ROOT}/build/docker/Dockerfile.rootfs" \
    --build-arg "PIKVM_REPO_URL=${PIKVM_REPO_URL}" \
    --build-arg "TARGET_HOSTNAME=${TARGET_HOSTNAME}" \
    --build-arg "TARGET_TIMEZONE=${TARGET_TIMEZONE}" \
    --build-arg "TARGET_LOCALE=${TARGET_LOCALE}" \
    --build-arg "TARGET_ROOT_PASSWORD=${TARGET_ROOT_PASSWORD}" \
    "${CTX}"

msg "exporting rootfs tarball"
mkdir -p "${OUTPUT}"
cid="$(docker create --platform linux/arm64 "${ROOTFS_IMAGE}" /bin/true)"
trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
docker export "${cid}" -o "${OUTPUT}/${ROOTFS_TAR}"

msg "rootfs ready: ${ROOTFS_TAR} ($(du -h "${OUTPUT}/${ROOTFS_TAR}" | cut -f1))"
