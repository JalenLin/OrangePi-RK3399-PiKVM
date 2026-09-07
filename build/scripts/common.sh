#!/usr/bin/env bash
# Shared helpers. Sourced by every build script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES="${ROOT}/sources"
OUTPUT="${ROOT}/output"
PATCHES="${ROOT}/patches"
CONFIG="${ROOT}/config"

# shellcheck source=/dev/null
source "${CONFIG}/board.conf"

KBUILD_IMAGE="opi-pikvm/kbuild:20.04"

msg()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# Clone-or-update a pinned upstream checkout under sources/.
fetch_repo() {
    local dir="$1" repo="$2" branch="$3"
    if [[ -d "${SOURCES}/${dir}/.git" ]]; then
        msg "${dir}: already present, skipping fetch"
    else
        msg "${dir}: cloning ${repo} (${branch})"
        git clone --depth 1 -b "${branch}" "${repo}" "${SOURCES}/${dir}"
    fi
}

# Apply every *.patch in a directory, from a clean tree.
#
# The patches are the source of truth and the source tree is a scratch
# checkout that fetch_repo manages, so this resets it to HEAD first rather
# than trying to work out what is already applied. The previous version
# checked each patch individually with `git apply --check --reverse` and
# skipped the ones that reversed cleanly; that breaks as soon as two patches
# touch the same lines. 0007 and 0011 both add entries to rkisp1's
# v4l2_ioctl_ops table, so with 0011 applied, 0007 no longer reverses - and it
# would not forward-apply either, leaving the build dead with "patch does not
# apply" on a tree that was in fact perfectly fine.
#
# Note what this means: anything hand-edited in sources/ is discarded on the
# next build. Turn it into a patch first.
#
# The reset happens whether or not there are any patches, which is not an
# accident. patches/uboot does not exist, so the early "no patches, nothing to
# do" return this used to take meant the U-Boot tree was the one tree the
# build never reset - and it silently shipped bring-up instrumentation for
# weeks. Every image built in that window carries "MARK: soc_clk_dump done"
# and a #define DEBUG in lib/initcall.c; docs/logs/rk612-boot-ok.log still
# shows it. A tree that is reset only when someone remembered to add a patch
# directory is not a scratch checkout, it is a hiding place.
apply_patches() {
    local tree="$1" dir="$2"
    shopt -s nullglob
    local ps=( "${dir}"/*.patch )
    shopt -u nullglob

    # Compare against HEAD, not the index, and restore from HEAD too.
    # "git diff" alone only sees worktree-vs-index, so a tree whose changes
    # happen to be staged - which is what "git apply --3way" leaves behind -
    # looks clean, the reset is skipped, and the first patch fails on a file
    # that already carries it. "git checkout -- ." has the mirror-image
    # problem: it restores from the index, so it would put the staged copy
    # straight back.
    if ! git -C "${tree}" diff --quiet HEAD 2>/dev/null; then
        msg "  resetting $(basename "${tree}") to HEAD"
        git -C "${tree}" checkout HEAD -- . || die "cannot reset ${tree}"
        git -C "${tree}" reset -q || die "cannot reset the index of ${tree}"
    fi
    for p in "${ps[@]}"; do
        msg "  applying: $(basename "${p}")"
        git -C "${tree}" apply "${p}" || die "failed to apply ${p}"
    done
}

ensure_kbuild_image() {
    if ! docker image inspect "${KBUILD_IMAGE}" >/dev/null 2>&1; then
        msg "building ${KBUILD_IMAGE}"
        docker build -t "${KBUILD_IMAGE}" -f "${ROOT}/build/docker/Dockerfile.kbuild" \
            "${ROOT}/build/docker"
    fi
}

# Run a command inside the cross-build container, as the calling user so the
# build artifacts do not end up root-owned.
kbuild_run() {
    ensure_kbuild_image
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "${ROOT}:/work" \
        -v "${SOURCES}/toolchain:/toolchain:ro" \
        -e "MAKEFLAGS=-j$(nproc)" \
        -w /work \
        "${KBUILD_IMAGE}" \
        bash -c "$*"
}

# Same container, but as root. Needed for image assembly, where files must keep
# their target ownership. Note this still never mounts anything: mke2fs -d
# populates the filesystem image directly, so no loop device or privileged
# container is involved.
kbuild_run_root() {
    ensure_kbuild_image
    docker run --rm \
        -v "${ROOT}:/work" \
        -w /work \
        "${KBUILD_IMAGE}" \
        bash -c "$*"
}
