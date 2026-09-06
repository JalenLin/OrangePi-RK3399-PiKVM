#!/usr/bin/env bash
#
# Hardware H.264 experiment. Run this on the board; it changes nothing
# permanent and starts no services.
#
# Background: kvmd's WebRTC path needs ustreamer to publish an H.264 sink,
# which needs a V4L2 M2M H.264 encoder. This board has the hardware but no
# such kernel device - RK3399's encoder is reachable only through Rockchip's
# MPP. libv4l-rkmpp is a userspace shim that tries to make MPP look like a
# V4L2 M2M device, so ustreamer could drive it unmodified.
#
# It may well not work. The plugin's own README says it is full of
# Chromium-shaped assumptions, and ustreamer issues raw V4L2 ioctls rather
# than going through libv4l, so it only sees the plugin via an LD_PRELOAD
# shim. The point of this script is to find that out cheaply.
set -uo pipefail

PREFIX=/opt/rkmpp
export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"

say() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m   ok:\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m   no:\033[0m %s\n' "$*"; }

# -----------------------------------------------------------------------------
say "1. Does the hardware encoder work at all?"
# -----------------------------------------------------------------------------
# This is the load-bearing question, and it is independent of every layer
# above it. If mpi_enc_test cannot encode, nothing else here matters and the
# problem is the kernel's MPP service, not the shim.
if [[ ! -e /dev/mpp_service && ! -e /dev/vpu_service ]]; then
    bad "no /dev/mpp_service or /dev/vpu_service - MPP has no kernel side to talk to"
    ls -l /dev/{mpp,vpu,rkvenc}* 2>/dev/null || true
    # This was the state on every image before kernel patch 0013. The drivers
    # were built in; the device tree nodes they bind to were all disabled, so
    # nothing registered. If you see this, check the DTB rather than the
    # config: fdtget -t s <dtb> /mpp-srv status should say "okay".
    bad "if this is an image without kernel patch 0013, that is the reason"
fi

if [[ -x "${PREFIX}/bin/mpi_enc_test" ]]; then
    "${PREFIX}/bin/mpi_enc_test" -w 1920 -h 1080 -t 7 -n 30 -o /tmp/rkmpp-test.h264 2>&1 | tail -20
    if [[ -s /tmp/rkmpp-test.h264 ]]; then
        ok "encoded $(stat -c%s /tmp/rkmpp-test.h264) bytes to /tmp/rkmpp-test.h264"
        ok "the H.264 hardware works; route A (MPP inside ustreamer) is viable"
    else
        bad "mpi_enc_test produced nothing"
    fi
else
    bad "${PREFIX}/bin/mpi_enc_test missing - was the image built with the rkmpp stage?"
fi

# -----------------------------------------------------------------------------
say "2. Set up the libv4l-rkmpp dummy encoder device"
# -----------------------------------------------------------------------------
# The plugin's "device" is a plain file whose contents configure it. The name
# is arbitrary: ustreamer 6.65 takes --h264-m2m-device, so nothing has to be
# claimed at a fixed path. (An older note here said /dev/video11 was compiled
# in with no override. That was wrong for this version.)
DEV=/dev/video-enc0
cat > "${DEV}" <<CFG
enc
type=enc
codecs=H.264
max-width=1920
max-height=1080
log-level=2
CFG
chmod 660 "${DEV}"
chgrp video "${DEV}" 2>/dev/null || true
ok "wrote ${DEV}"

# -----------------------------------------------------------------------------
say "3. Is the plugin actually loadable?"
# -----------------------------------------------------------------------------
PLUGIN="${PREFIX}/lib/libv4l/plugins/libv4l-rkmpp.so"
if [[ -f "${PLUGIN}" ]]; then
    ok "plugin present: ${PLUGIN}"
    if ldd "${PLUGIN}" | grep -q "not found"; then
        bad "plugin has unresolved libraries"
        ldd "${PLUGIN}" | grep "not found"
    else
        ok "plugin links cleanly"
    fi
else
    bad "plugin missing at ${PLUGIN}"
fi

# -----------------------------------------------------------------------------
say "4. Replay ustreamer's encoder sequence against the shim"
# -----------------------------------------------------------------------------
# This does not need a working capture chain, which is the point: it issues
# exactly the ioctls ustreamer's m2m.c issues, in the same order with the same
# arguments, so it answers "would ustreamer drive this?" on its own.
#
# v4l2convert.so is libv4l's LD_PRELOAD shim: it intercepts open/ioctl/mmap and
# routes them through libv4l2, which is what gives a raw-ioctl program like
# ustreamer any chance of reaching the plugin. It must be OUR patched copy -
# the system one cannot forward mmap to a plugin.
CONVERT="${PREFIX}/lib/libv4l/v4l2convert.so"
if [[ ! -f "${CONVERT}" ]]; then
    bad "${CONVERT} missing; cannot preload"
    exit 1
fi

LD_PRELOAD="${CONVERT}" python3 "${PREFIX}/ustreamer-m2m-probe.py" \
    "${DEV}" 1920 1080 UYVY 60 /tmp/rkmpp-shim.h264 2>&1 \
    | grep -v "^\[[0-9]" | grep -v "^mpp\[" || true

say "What the results mean"
cat <<'NOTE'
  Step 1 is the load-bearing one: mpi_enc_test talks to MPP directly and asks
  whether this board's H.264 encoder works at all. If it fails, the problem is
  the kernel side and no userspace shimming will help - check the DTB before
  the config, since a =y driver with a disabled node registers nothing. That
  was the state of every image before kernel patch 0013.

  This script is now a diagnostic, not an experiment. Both codecs run in
  hardware on the shipped image, through the same VEPU2:

    MJPEG  the live stream, via /dev/video-enc-mjpeg
    H.264  the WebRTC and VNC-h264 sink, via /dev/video-enc-h264

  Both are set up by usr/lib/tmpfiles.d/pikvm-rkmpp.conf and driven by
  usr/lib/pikvm/ustreamer-encoder. What used to block H.264 - four controls
  the plugin got wrong, one of which deadlocked the buffer handshake - is
  fixed in patches/libv4l-rkmpp/0002. Step 4 replays ustreamer's ioctl
  sequence in ustreamer's own order, so it now either completes or names the
  step that regressed.

  If the stream is up and you want to know whether it is really the hardware
  doing the work, this script is the slow way to find out. The fast way:

    grep -c . /sys/kernel/debug/mpp_service/session_summary   # sessions
    cat /sys/class/devfreq/*/cur_freq                         # VPU clock

  A VPU parked at 50 MHz with the stream running means something fell back.
NOTE
