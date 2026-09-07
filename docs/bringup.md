# First boot checklist

Run these in order on the real board. Each step tells you which of the
project's unverified assumptions was wrong, and most of them can be fixed
without rebuilding the whole image.

Serial console: **1500000 8N1** on the debug UART (RK3399 boards use this
non-standard rate; 115200 will show you garbage and look like a dead board).

```sh
picocom -b 1500000 /dev/ttyUSB0
```

## 1. Does it boot at all?

If U-Boot prints but the kernel never starts, the boot partition is the
suspect — `boot.img` is written raw at sector 49152 and nothing validates it.
If the kernel starts but panics on mounting root, the partition GUID is wrong;
check `sfdisk --dump /dev/mmcblk1` reports
`614e0000-0000-4b53-8000-1d28000054a9` on partition 4 — or `615e…54a9` on
`/dev/mmcblk0` if you are booting the eMMC, where the prefix differs on
purpose (see [emmc.md](emmc.md)).

## 2. Is the bridge chip actually at 0x0f?

The two vendor device trees disagree (`0x0f` vs `0x1f`), so settle it:

```sh
i2cdetect -y 1
```

If the chip answers at an address the DTS does not name, nothing else in the
capture chain will come up. Fix the `reg` in the DTS and rebuild the kernel.

## 3. Did the driver bind?

```sh
dmesg | grep -iE 'tc3587|rkisp|mipi'
```

Expect the tc35874x probe to succeed and rkisp1 to register. A probe that
fails on clocks or regulators points at the GPIO/rail table in
`hardware.md` — the 4.4.179 DTS leaves rails to the regulator framework, and
this board may need them driven explicitly the way 4.4.103 did.

## 4. What is the video node called?

```sh
v4l2-ctl --list-devices
ls -l /dev/kvmd-video          # created by our udev rule
```

`/dev/kvmd-video` missing but a node present means the udev rule's
`ATTR{name}` guess is wrong. Read the real name:

```sh
cat /sys/class/video4linux/video0/name
```

and correct `overlay/usr/lib/udev/rules.d/99-kvmd.rules`. This one is fixable
in place on the running board — no rebuild needed to test.

## 5. Does it see a source?

Plug a live HDMI source in, then:

```sh
v4l2-ctl -d /dev/kvmd-video --query-dv-timings
v4l2-ctl -d /dev/kvmd-video --set-edid=file=/etc/kvmd/tc358743-edid.hex --fix-edid-checksums
v4l2-ctl -d /dev/kvmd-video --set-dv-bt-timings query
```

No timings usually means EDID was never presented to the source, or hot-plug
detect is not wired — both are bridge-side, not capture-side.

## 6. Capture a frame

```sh
v4l2-ctl -d /dev/kvmd-video --set-fmt-video=pixelformat=UYVY --stream-mmap --stream-count=1 --stream-to=/tmp/f.raw
ls -l /tmp/f.raw
```

This is the moment of truth for the rkisp1 YUV422 question in
`roadmap.md`. If 1080p60 fails but 1080p30 works, you have hit the MIPI FIFO
bandwidth limit; note which and record it.

## 7. HID gadget

```sh
ls /dev/hidg*                  # expect hidg0, hidg1
systemctl status kvmd-otg
```

Nothing there means the OTG port is not in peripheral mode. Check
`dr_mode` on `usbdrd_dwc3_0` and whether the Type-C port is being held in host
mode by the extcon/typec driver.

## 8. The web UI

```sh
systemctl status kvmd kvmd-nginx
journalctl -u kvmd -b --no-pager | tail -50
```

Then browse to `https://<board-ip>/`. Expect MJPEG to work and WebRTC not to —
that is a known gap, not a bug. Watch CPU while streaming: software MJPEG is
the cost of the BSP track, and how expensive it really is decides how much the
mainline track is worth.

---

## 9. Optional: the hardware H.264 experiment (rkmpp variant only)

Only on a card flashed from `orangepi-rk3399-pikvm-rk612-rkmpp.img`, and only
on a kernel carrying patch 0001 - before that the codec nodes were disabled in
the device tree and step 1 could not do anything but fail. Do this *after*
steps 1-8 pass on the `base` card, so that a failure here is unambiguous.

```sh
/opt/rkmpp/try-h264.sh
```

The script's four steps answer different questions, and they are not equally
important:

**Step 1 is the one that matters.** `mpi_enc_test` talks to Rockchip's MPP
directly and asks whether this board's H.264 encoder works at all. Its answer
holds regardless of everything above it:

* passes → the silicon and the kernel MPP service are fine, so hardware H.264
  is reachable; it is only a question of how userspace gets at it
* fails → the problem is the kernel side (`/dev/mpp_service`), and no amount
  of userspace shimming will help. First check the DTB rather than the config:
  `fdtget -t s <dtb> /mpp-srv status` must say `okay`. A `=y` config symbol
  only means the driver was built, not that a node exists for it to bind to -
  that distinction is what hid this for two images.

**Step 4 replays ustreamer's own encoder ioctl sequence** against the shim, so
it does not need a working capture chain to be meaningful. It has been run:
the data path works and the control path does not - every `VIDIOC_S_CTRL`
returns `ENOTTY`, which is the first thing ustreamer does and the thing it
aborts on. Rerun it if you change the plugin; the interesting line is the
`-- controls --` block.

Record which step failed and how - that is what picks between routes A, A' and
B in `roadmap.md`.

Nothing here runs at boot or is referenced by any service. To remove the whole
experiment from a running system: `rm -rf /opt/rkmpp`.
