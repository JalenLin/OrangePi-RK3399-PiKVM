# First boot checklist

Run these in order on a freshly flashed board. Every step has passed on the
shipped image, and the output each one shows is what this board printed. Use
the list to find where yours stops: each step only makes sense once the one
before it passes.

Serial console: **115200 8N1** on the debug UART, for the whole boot. RK3399
boards conventionally use 1500000 and the vendor U-Boot defaults to it, but
the header has no flow control and the UART overruns on bursts at that rate,
so both U-Boot and the kernel were moved down (`patches/uboot/0001`, which has
the measurements). The prebuilt BL31 blob still prints its own lines at
1500000; those few bytes of garbage are expected.

Use a **3.3 V** USB-to-TTL adapter straight onto the header, and check the
jumper — this header is 3.0 V and a 5 V adapter is over the pads' absolute
maximum. It will appear to work, because the direction that is out of spec is
the one you type into. If the adapter is fixed at 5 V, a 1 kΩ resistor in
series on its TX makes it safe. See docs/hardware.md.

A USB-to-RS232 adapter feeding an RS-232-to-TTL board is fine at 115200; it is
only worth suspecting if you go back up to 1500000, where those transceivers
are outside their 235 kbps sheet.

```sh
picocom -b 115200 /dev/ttyUSB0
```

U-Boot waits two seconds for Ctrl+C, so you can stop at a prompt when the
kernel is the thing that is broken.

The kernel log has a few dozen lines that look like failures and are not -
missing optional IRQs, a critical-clock WARNING with a backtrace. They are
listed in docs/known-issues.md; check there before chasing one.

## 1. Does it boot at all?

If U-Boot prints but the kernel never starts, the boot partition is the
suspect — `boot.img` is written raw at sector 49152 and nothing validates it.
If the kernel starts but panics on mounting root, the partition GUID is wrong;
check `sfdisk --dump /dev/mmcblk1` reports
`614e0000-0000-4b53-8000-1d28000054a9` on partition 4 — or `615e…54a9` on
`/dev/mmcblk0` if you are booting the eMMC, where the prefix differs on
purpose (see [emmc.md](emmc.md)). If it drops into emergency mode instead,
the usual cause is a second card or the eMMC carrying the same image - see
"Two media carrying the same image collide" in known-issues.md.

```sh
uname -r                       # 6.12.69-...
cat /proc/device-tree/model    # Orange Pi RK3399 Board
```

## 2. Is the HDMI IN bridge there?

The TC358749 sits on i2c1 at `0x1f`. Once its driver has bound, `i2cdetect`
shows it as `UU`, not as an address:

```sh
i2cdetect -y 1                 # UU at 1a (the audio codec) and at 1f
journalctl -k -b -o cat | grep -E 'tc35874x|rkisp1 '
```

Expect, among others:

```
tc35874x 1-001f: driver version: 00.01.01
m00_b_tc35874x 1-001f: tc358749 found @ 0x3e (rk3x-i2c)
rkisp1 ff910000.rkisp1: rkisp1 driver version: v00.01.05
```

`0x1f` with nothing bound means the driver failed probe on a clock or a rail,
and the GPIO and rail table in hardware.md is where to look. Nothing at
`0x1f` at all means the chip is held in reset or unpowered.

`rkisp1: Missing rockchip,grf property` and, every time a stream starts,
`can not get first iq setting in stream on`, are the vendor ISP looking for
sensor tuning this YUV path does not use. Harmless.

## 3. What is the video node called?

```sh
ls -l /dev/kvmd-video /dev/kvmd-video-bridge
cat /sys/class/video4linux/video0/name     # rkisp1_mainpath
```

`/dev/kvmd-video` is the ISP's main path, not the receiver; the receiver is
the subdev behind `/dev/kvmd-video-bridge`. docs/capture.md explains why that
matters. A node present without the symlink means the name in
`overlay/usr/lib/udev/rules.d/99-kvmd.rules` no longer matches - fixable in
place, then `udevadm trigger`.

## 4. Does it see a source?

`kvmd-tc358743.service` loads the EDID into the receiver at boot. Without it
a source sees nothing to drive and the receiver reports no signal.

```sh
systemctl is-active kvmd-tc358743
v4l2-ctl -d /dev/kvmd-video --query-dv-timings
```

With a 1080p60 source plugged in, the timings report `Active width: 1920`,
`Active height: 1080`, `Total width: 2200`, `Total height: 1125`. No timings
with the service active usually means the source has not re-read the EDID;
unplug and replug it. To load the EDID by hand:

```sh
v4l2-ctl -d /dev/kvmd-video-bridge --set-edid=pad=0,file=/etc/kvmd/tc358743-edid.hex
```

## 5. Capture a frame

kvmd holds the capture node while anyone is watching, so stop it first:

```sh
systemctl stop kvmd
v4l2-ctl -d /dev/kvmd-video --set-dv-bt-timings query
v4l2-ctl -d /dev/kvmd-video --set-fmt-video=width=1920,height=1080,pixelformat=YUYV \
    --stream-mmap --stream-count=60 --stream-to=/tmp/f.raw
ls -l /tmp/f.raw               # 248832000 bytes: 60 frames of 1920x1080x2
systemctl start kvmd
```

`v4l2-ctl` prints the rate as it goes; it should settle at 60 fps. The format
is YUYV, not the UYVY a Pi uses: the main path has no UYVY at all, see
capture.md.

## 6. USB gadget

```sh
systemctl is-active kvmd-otg
ls /sys/class/udc              # fe800000.usb
ls /dev/hidg*                  # hidg0 hidg1 hidg2
```

Keyboard, absolute mouse, relative mouse, plus a mass-storage function for
the virtual CD/flash drive. No UDC at all means the Type-C controller is not
in peripheral mode: patch 0001 sets `dr_mode = "peripheral"` on
`usbdrd_dwc3_0`, and `cat /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode`
shows what the running device tree says. Then plug the Type-C port into the
target and check that it sees a keyboard and a mouse.

## 7. The web UI, and the encoder behind it

```sh
systemctl is-active kvmd kvmd-nginx kvmd-janus kvmd-media
```

Browse to `https://<board-ip>/`. The MJPEG stream and WebRTC (H.264) should
both work. ustreamer only runs while someone is watching, so check the
encoder with the page open:

```sh
cat /proc/mpp_service/sessions-summary
grep ff650000.vepu /proc/interrupts        # count rises while streaming
top -b -c -n2 -d2 | grep kvmd/streamer | tail -1
```

Expect VEPU2 sessions with `format` `mjpeg` (two, one per JPEG worker), plus
an `h264` one for the WebRTC/VNC sink, and the streamer at 10-40% of one core
at 1080p, depending on how well the picture compresses. The command line
should show `--encoder=m2m-video`. If it says `--encoder=cpu`, the wrapper in
`/usr/lib/pikvm/ustreamer-encoder` did not find the hardware path and fell
back to software JPEG, which costs about three cores; the wrapper's tests say
what it looks for.

## 8. HDMI output

```sh
cat /sys/class/drm/card0-HDMI-A-1/status   # connected, with a monitor
```

The board's own HDMI OUT carries the text console at the monitor's preferred
mode (1080p60 on a 1080p screen). Hot-plug works either way round. Nothing
on a KVM needs this, but it is the quickest way to a login prompt without the
UART.

---

## 9. Optional: VPU diagnostic

If step 7 fell back to software, this narrows down where:

```sh
/opt/rkmpp/try-h264.sh
```

**Step 1 is the one that matters.** `mpi_enc_test` talks to Rockchip's MPP
directly and asks whether the encoder works at all, independently of the
plugin, libv4l and ustreamer:

* passes → the silicon and the kernel MPP service are fine; the problem is in
  userspace, and the remaining steps narrow it down
* fails → the problem is the kernel side (`/dev/mpp_service`), and no amount
  of userspace shimming will help. First check the DTB rather than the config:
  `fdtget -t s <dtb> /mpp-srv status` must say `okay`. A `=y` config symbol
  only means the driver was built, not that a node exists for it to bind to -
  that distinction hid this for two images.

Step 4 replays ustreamer's own encoder ioctl sequence against the plugin, so
it does not need a working capture chain. On the shipped image every step
passes. It runs alongside kvmd without disturbing it; the VPU takes several
sessions at once.
