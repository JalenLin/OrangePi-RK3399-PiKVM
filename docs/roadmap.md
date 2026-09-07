# Roadmap

Two tracks, run in that order. The point of the split is that track 1 proves
the hardware and gives a usable device, so track 2 can be judged against
something that actually works rather than against a guess.

## Track 1 — BSP 4.4 (abandoned)

Vendor Linux 4.4.179 + Arch Linux ARM + PiKVM.

**This track is dead, and it was dead before the first image was written.**
systemd 258 removed cgroup v1 support; Arch installs 261; 4.4's cgroup v2 has
no cpu controller, and systemd's own kernel baseline is 5.4. systemd refuses
to start, PID 1 exits, the board panics. No bootarg rescues it.

Pairing a rolling-release userland with a 2016 kernel was the mistake, and
checking systemd's kernel baseline before building would have caught it in a
minute. Track 1.5 is now the real first track.

- [x] Pin upstream sources; reproduce the vendor's exact SD layout
- [x] Kernel config fragment for the PiKVM gaps (`F_HID` above all)
- [x] Board overlay derived from `kvmd-platform-v2-hdmi-rpi4`
- [x] Whole pipeline builds: U-Boot, kernel (4.4.179, `boot.img` 19 MB),
      Arch/PiKVM rootfs (2.6 GB), assembled 3.3 GB image with the partition
      table, rootfs GUID and raw payload offsets verified
- [x] **Verify on hardware** — this list was written before the board had
      ever booted; all of it has since been answered by the board itself:
  - [x] TC358749 I²C address — `0x1f`, as the DTS had it. The bridge probes
        as `hdmi-bridge@1f` on i2c1 and the driver binds.
  - [x] `/dev/video*` node name, so the udev rule actually matches —
        `/dev/kvmd-video` resolves to `video0`, the rkisp1 main path.
  - [x] 1080p60 capture, and what the CPU cost of software MJPEG really is —
        316% and 78 °C, which is what made the VPU work non-optional.
  - [x] HID gadget on the target machine — not just enumerating. Verified end
        to end against a Raspberry Pi 3: text sent through kvmd's API arrives
        as the right reports (`02 00 0b` for a shifted `h`), absolute mouse
        coordinates land where they should, and the target reads a mounted
        image off `/dev/sr0`.
  - [x] ATX GPIO pin assignment - settled on paper from the vendor schematic
        and this tree's own device tree; see docs/hardware.md. Ships
        disabled, because the optocouplers do not exist yet, but the pins are
        chosen rather than guessed. Two of kvmd's four Pi defaults collide
        with the Bluetooth UART, and what was there before pointed all four
        at RK3399's PMU bank, which granted lines that are not pins.

### Inherited Raspberry Pi baggage

`kvmd` hard-depends on `raspberrypi-io-access`, `raspberrypi-utils` and
`janus-gateway-pikvm`, so an Arch install drags them onto a board that is not
a Pi. Nothing breaks - the ATX backend uses libgpiod, and janus is now
started deliberately rather than by accident - but expect
`vcgencmd`-flavoured noise in the logs, and remember that upstream's
packaging assumes a Pi even when its code does not. The ATX defaults are the
sharp end of that assumption: they are BCM pin numbers, and they mean
something entirely different here. See docs/hardware.md.

## Track 1.5 — Rockchip's own 6.12 BSP (current)

Now the default (`KERNEL_TRACK=rk612`). Rockchip
maintains `rockchip-linux/kernel` out to **`develop-6.12`**, and that branch
still carries the pieces we depend on.

What is already there:

* **`drivers/media/i2c/tc35874x.c`** - the TC358749-capable driver, forward
  ported by Rockchip to 6.12, still matching `toshiba,tc358749`. Track 2's
  first work item simply does not exist here.
* **`arch/arm64/boot/dts/rockchip/rk3399-orangepi.dts`**, `model = "Orange Pi
  RK3399 Board"` - our board.
* `rk3399.dtsi` still defines `mipi_dphy_rx0`, `rkisp1_0@ff910000` and
  `isp0@ff910000`, so the capture chain has somewhere to attach.
* `drivers/media/platform/rockchip/` carries `isp`, `isp1` **and** `rkisp1`.
* The Rockchip `%.img` / `boot.img` / `resource.img` make targets survive, so
  our image assembly needs no changes at all.

What is missing:

* **That 6.12 DTS does not wire up HDMI IN.** Its 895 lines contain no
  `tc3587`, `hdmiin`, `rkisp` or `mipi_dphy` node. The nodes have to be
  written - but the 4.4.179 versions transfer nearly verbatim, and the GPIO
  and rail table is already recorded in `hardware.md`.
* No `rk3399_linux_defconfig`; 6.12 uses a unified `rockchip_linux_defconfig`.

Why this matters: it sits exactly where the project wants to be. A 6.12 kernel
answers CLAUDE.md's preference for current code far better than 4.4.179 does,
while keeping a vendor-maintained TC358749 driver and a vendor-maintained ISP -
so it dodges track 2's real risk, which was never the bridge driver but making
mainline `rkisp1` carry YUV422 at 1080p60.

Unknowns worth an afternoon before committing to it: how well Rockchip
actually tests RK3399 on a branch aimed at RK3588; whether the vendor ISP or
`rkisp1` is the one to bind; and whether our BSP U-Boot boots a 6.12 image
unchanged.

### Build status

Builds clean at 6.12.69. Three things had to be fixed to get there, all worth
knowing if you touch this:

* **Compiler.** The container puts the vendor's Linaro 6.3 first on PATH for
  the 4.4 track; 6.12 dies on it with `no option -Wattribute-warning` (GCC 9+
  only). Each track now names its compiler by absolute path.
* **ISP driver collision.** The 6.12 tree ships three ISP drivers and two of
  them define `rkisp1_isp_isr`. `isp/` does not cover RK3399 at all;
  `isp1/` is the vendor driver (`rockchip,rk3399-rkisp1`, what the working
  4.4 HDMI-IN DTS bound to); `rkisp1/` is mainline
  (`rockchip,rk3399-cif-isp`). We take the vendor one.
* **Boot partition.** 6.12's `boot.img` is 41 MiB against the vendor's 32 MiB
  boot partition. Grown to 128 MiB into the unused gap the vendor layout
  already leaves before rootfs; rootfs start is unchanged.

Still to do: the HDMI IN device tree nodes, which 6.12's board DTS does not
have. If this works, it replaces track 2 rather than preceding it.

## Track 2 — mainline

Linux 6.x, per the project's stated preference for current code.

Three pieces of work, in dependency order:

1. **TC358749 support in mainline `tc358743.c`.** The vendor's `tc35874x.c`
   is a fork of that exact file, so this is a diff to extract, not a driver to
   write. Measured: after normalising the `tc358743`→`tc35874x` rename, the
   two files differ by ~310 lines out of 2224 — and most of that is V4L2 API
   drift between 4.4 and 6.x (`v4l2_fwnode_bus_mipi_csi2` vs
   `v4l2_mbus_config_mipi_csi2`, lane flags vs `num_data_lanes`,
   `V4L2_MBUS_CSI2` vs `V4L2_MBUS_CSI2_DPHY`), i.e. changes mainline already
   has in the newer form. The genuinely chip- and board-relevant deltas are
   few:

   - a `link_freq` / `pixel_rate` control pair (310 MHz) — `rkisp1` wants
     `link-frequencies`, so this matters to us regardless of the chip
   - lane count taken from the device tree instead of being recomputed from
     the PLL (`csi_lanes_in_use` vs `num_csi_lanes_needed()`)
   - inverted continuous/non-continuous clock-mode sense
   - a stream stop added to reset the CSI block
   - CEC support dropped

   None of that is a rewrite. It is plausible mainline's driver drives the
   TC358749 nearly as-is and the real work is refclk/PLL and EDID/HPD setup;
   that hypothesis is cheap to test once the board boots.
2. **Device tree.** Mainline already has `rk3399-orangepi.dts`, `rkisp1`, and
   `mipi_dphy_rx0`; the 4.4.179 node is already written against the modern
   fwnode graph binding, so it largely transfers. The regulator/GPIO table in
   `hardware.md` has to be reconstructed.
3. **Make `rkisp1` carry YUV422 at 1080p60.** This is the real risk. Mainline
   `rkisp1` is built for Bayer sensors; its resizers only operate on
   `YUYV8_2X8`, and there is a documented MIPI FIFO error with YUV422 above
   ~1.2 Gbps. Our link is ~2.38 Gbps. Possible outcomes, in order of
   preference: it works; it works only via the mainpath with the resizer in
   bypass; it caps at 1080p30; it needs an rkisp1 fix.

### What mainline buys us

`hantro` exposes the RK3399 VPU's **JPEG encoder as a V4L2 M2M device**, so
ustreamer can switch from `--encoder=cpu` to `--encoder=m2m-image` and stop
burning the A72s on MJPEG. That alone may justify the track.

### H.264, and therefore WebRTC

Neither track streams WebRTC as built, but this is a kernel-driver question
only - and a more tractable one than it first looks.

**ustreamer does not need changing.** Its H.264 encoder is generic V4L2 M2M:
the binary drives `V4L2_CID_MPEG_VIDEO_H264_PROFILE`, `_LEVEL`, `_MAX_QP` and
`_I_PERIOD` through the standard interface, with nothing Raspberry Pi specific
in it. Any conformant V4L2 M2M H.264 encoder makes `--h264-sink` work, and
janus and kvmd's WebRTC path follow with no changes at all.

So the whole problem is: get an H.264 encoder onto RK3399's VPU.

| | H.264 encoder code | usable on RK3399 |
|---|---|---|
| mainline `hantro` | none - `hantro_h1_jpeg_enc.c` is its only encoder, everything else decodes | - |
| BSP `rockchip-vpu` (V4L2 M2M) | `rk3288_vpu_hw_h264e.c` | no - VEPU1 registers; RK3399 is VEPU2 |
| BSP MPP (`RK_VCODEC`, `ROCKCHIP_MPP_SERVICE`) | yes | **yes**, and already enabled in our kernel |

Note what this table says about the tracks: the **BSP is the better starting
point for H.264**, not the worse one. It ships an H.264 encoder implementation
to adapt; mainline has none to adapt at all.

Two routes, if WebRTC turns out to matter:

**A. MPP-backed encoder in ustreamer.** The hardware encoder already works on
RK3399 through Rockchip's MPP - the vendor SDK builds `mpp-release` and
`gstreamer-rockchip`'s `mpph264enc` against it, and our kernel has
`CONFIG_ROCKCHIP_MPP_SERVICE=y` and `CONFIG_ROCKCHIP_MPP_VEPU2=y` with the
`vepu@ff650000` node enabled as of patch 0001 - it was `disabled` when this
paragraph was first written, which is why none of this was testable.
ustreamer already abstracts encoder types
(CPU / HW / M2M), so adding an MPP type is a contained addition. Fastest path
to working WebRTC. Cost: a permanent ustreamer fork - upstream will not take a
dependency on a vendor-proprietary library.

**B. Port the V4L2 M2M H.264 encoder to VEPU2.** `rockchip-vpu`'s
`rk3288_vpu_hw_h264e.c` is a complete H.264 encoder against VEPU1's register
layout; RK3399 needs the same logic against VEPU2. More work than A, and it is
register-level work. But it needs *zero* userspace changes, and the same
driver applies to mainline `hantro` - so it closes this gap on both tracks at
once and is upstreamable.

Recommendation: ship MJPEG first and find out whether WebRTC is actually
needed. If it is, prefer B - A buys speed at the price of a fork you own
forever.

#### What already exists elsewhere

Checked, rather than assumed:

**Rockchip's own BSP has no V4L2 encoder, on any branch.**
`rockchip-linux/kernel` goes up to `develop-6.12`, and its
`drivers/media/platform/rockchip/` holds cif, hdmirx, isp, isp1, ispp, rga,
rkisp1, vpss - no encoder anywhere. VEPU2 is driven by
`drivers/video/rockchip/mpp/mpp_vepu2.c`, i.e. the MPP service. So no Rockchip
kernel, old or new, hands you a V4L2 M2M H.264 encoder.

**Bootlin implemented VEPU2 H.264 out of tree, for exactly this SoC.**
`github.com/bootlin/linux`, branch `hantro/h264-encoding-v5.11`, contains
`rk3399_vpu_hw_h264_enc.c` alongside `rk3399_vpu_regs.h`, plus a userspace
test tool at `github.com/bootlin/v4l2-hantro-h264-encoder`. That file is the
hard, undocumented part of route B already written.

The catch: the companion commit is *"media: Introduce Hantro V4L2 H.264
**stateless** encoding API"*, and it touches
`include/uapi/linux/v4l2-controls.h` and `include/uapi/linux/videodev2.h`. It
invents a stateless encoding uAPI that never merged. ustreamer speaks the
*stateful* API. So this is a reference implementation of the register
programming, not a drop-in - and it is based on 5.11 (2021), so either track
needs a forward-port.

**A userspace shim may skip the kernel entirely - tried, and it does not.**
`github.com/JeffyCN/libv4l-rkmpp` is a libv4l plugin wrapping MPP that
presents `/dev/video-enc0` as a V4L2 M2M device; `src/libv4l-rkmpp-enc.c` is a
real encoder, and the project is alive (last push 2025-04). Its README warns
"there're a lot of chromium related hacks in it, might not work for other
apps", and ustreamer issues raw V4L2 ioctls rather than going through libv4l,
so it needs `LD_PRELOAD=.../v4l2convert.so` to be reached at all.

Measured on the board rather than guessed at, by replaying ustreamer's own
ioctl sequence against it (`/opt/rkmpp/ustreamer-m2m-probe.py`, which is
`m2m.c`'s calls in `m2m.c`'s order). It binds, and more of it works than the
README suggests:

* `VIDIOC_QUERYCAP` returns `driver=rkmpp`, `V4L2_CAP_VIDEO_M2M_MPLANE |
  V4L2_CAP_STREAMING`
* `S_FMT` accepts **UYVY** on the OUTPUT queue and H.264 on CAPTURE, so no
  format conversion is needed between our capture chain and the encoder
* `REQBUFS`/`QUERYBUF`/`mmap`/`STREAMON` all succeed, and it encodes 1080p at
  ~35 fps into a stream ffmpeg decodes cleanly

Three things stop unmodified ustreamer anyway:

1. **`VIDIOC_S_CTRL` is not implemented at all.** Every one returns `ENOTTY`
   (`rkmpp_enc_ioctl: unsupported ioctl cmd: VIDIOC_S_CTRL`). ustreamer sets
   bitrate, GOP, profile, level, `REPEAT_SEQ_HEADER` and min/max QP *before*
   it configures a format, and `_E_XIOCTL` aborts on the first failure - so it
   never reaches any of the parts that work. This is the decisive one: bitrate
   control is not optional for a KVM.
2. **Buffer handshake.** ustreamer dequeues INPUT before CAPTURE; the plugin
   parks the SPS/PPS in the single CAPTURE buffer before it will touch the
   INPUT queue, and with the one buffer per queue ustreamer requests, CAPTURE
   must also be re-queued before INPUT is released. Either order the other way
   round deadlocks.
3. **Geometry.** It pads 1080 to 1088 and emits no SPS cropping, so the stream
   is 1920x1088.

So route 1 is closed as a *drop-in*. What it leaves behind is worth keeping in
view: the encoder underneath is proven working through a V4L2-shaped API with
our exact pixel format, which makes the plugin a plausible base to patch
rather than a dead end.

#### The device tree was the blocker, and it was ours

Everything above was written on the assumption that the kernel side was
ready, because the config said so: `CONFIG_ROCKCHIP_MPP_SERVICE=y`,
`CONFIG_ROCKCHIP_MPP_VEPU2=y`. It was not. `rk3399.dtsi` gives `mpp-srv`,
`vepu@ff650000` and `iommu@ff650800` `status = "disabled"`, Rockchip enables
them in `rk3399-linux.dtsi`, and this board's DTS never included that file.
The board had no `/dev/mpp_service`, so every route below was blocked at
`open()` — including the `mpi_enc_test` run that was supposed to decide
between them. Fixed by patch 0001; see patches.md.

Note what this cost: `/opt/rkmpp` shipped in two images with a fully built
MPP, patched libv4l2 and plugin, against a kernel with nothing listening.
The lesson is the same one the 6.12 track already taught — a config symbol
being `=y` says a driver exists, not that anything binds to it.

#### Where this ended up

Route A' was taken, and it went further than expected. The finding that
reordered everything: **VEPU2 does MJPEG as well as H.264**, from the same
`vepu@ff650000` that patch 0001 enables. `mpi_enc_test -t 8` encodes 1080p
MJPEG at 41.5 fps on this board. So the choice recorded in 0001 - MPP over
mainline hantro, made to keep H.264 reachable - did not cost the JPEG encoder
after all; hantro would have given JPEG only, MPP gives both.

That turned the cheap experiment into the actual fix. MJPEG, not H.264, is
what the KVM runs on every day, and it was costing three of six cores.
`patches/libv4l-rkmpp/0001` makes ustreamer's `--encoder=m2m-image` reach the
VPU: six defects, four of them the plugin refusing to expose things it had
already implemented. See patches.md. Result: ustreamer went from 316% CPU to
50%, the SoC from 78 C to 62 C, and the big cluster stopped being thermally
throttled.

**H.264 followed, through the same door**, and it is verified on hardware -
`ffprobe` on the live sink reports Constrained Baseline, level 40, 1920x1080,
decoding clean.

Once the S_CTRL fix let ustreamer's seven H.264 controls reach the plugin,
what was left was four of those seven being wrong - and
`patches/libv4l-rkmpp/0002` is those four. The two blockers recorded here
previously were both real and both in that set:
`H264_I_PERIOD` refused for any non-zero value, and a deadlock on the single
CAPTURE buffer. The second one did not need a buffer-handshake redesign in
the end; it needed `REPEAT_SEQ_HEADER` to be implemented, after which the
plugin stops wanting a CAPTURE buffer for a separate SPS/PPS and the case
never arises. The other two - constrained-baseline rejected, and the level
enumerator stored as a `level_idc` - had not been reached yet because
I_PERIOD aborted the run first. See patches.md.

So both codecs now run on VEPU2, through two instances of the same plugin:
MJPEG for the live stream, H.264 for the WebRTC and VNC-h264 sink. The rest
of that path was already in the image - janus, `kvmd-media`, the nginx
routes - so wiring it up was configuration, not code.

Route A (MPP inside ustreamer) and route B (a mainline V4L2 driver) go back
on the shelf, and they are worth keeping there for one reason: A' depends on
`libv4l-rkmpp`, which is one person's project with no release since April
2025, plus a patched `libv4l2` and an `LD_PRELOAD`. That is a lot of
unofficial machinery under a working stream. Route B - a VEPU2 encoder in
`hantro` - is still the only version of this that ends with nothing of ours
in userspace at all.

## Mainline U-Boot — it boots, all the way to PiKVM

`make uboot UBOOT_TRACK=mainline` builds U-Boot v2025.07 for this board with
BL31 from mainline TF-A v2.12, and on hardware it comes all the way up:

```
NOTICE:  BL31: v2.12.0(release):v2.12.0
U-Boot 2025.07 (…)
SoC: Rockchip rk3399
Model: Orange Pi RK3399 Board
DRAM:  2 GiB
PMIC:  RK808
MMC:   mmc@fe310000: 3, mmc@fe320000: 1, mmc@fe330000: 0
Net:   eth0: ethernet@fe300000
Hit any key to stop autoboot:  2  1  0
```

BL31, the PMIC, all three MMC controllers, ethernet, a console at 115200 and a
usable prompt. `ext4ls mmc 0:4` reads this image's root filesystem.

Mainline supports the board out of the box —
`configs/orangepi-rk3399_defconfig` and
`arch/arm/dts/rk3399-orangepi-u-boot.dtsi`, the latter carrying
`rk3399-sdram-ddr3-1333.dtsi` and `vdd_log`'s
`regulator-init-microvolt = <950000>`. Two local changes on top:
`config/uboot-fragments/pikvm.config` (where SPL finds the itb, and the
console rate) and `patches/uboot-mainline/0001` (the DT's `stdout-path`, which
overrides `CONFIG_BAUDRATE` in U-Boot proper).

### The one thing that stopped it, and it is not what it looked like

The first attempts died silently after SPL verified the FIT, with nothing on
the console at either baud rate. That was read as a stall in the handoff to
BL31, or as BL31 itself. Both were wrong, and instrumenting SPL showed exactly
what happens:

```
fit read offset c00000, size=2560, dst=3c003c0, count=2560
## Checking hash(es) for config config-1 ... OK
firmware: 'atf-1'
starting
read offset c4c00 = offset from fit c5600
reading from offset c5600 / cc5600 size 37a00 to 10000:
```

SPL stops **inside the read**, before BL31 is ever entered. The addresses say
why:

| | |
|---|---|
| SPL text | `0x00000000` – `0x00019010` (`__image_copy_end`; `0x1bf8d` with its appended DTB) |
| BL31 from `rkbin` v1.28 | loads at `0x00010000`, size `0x37a00` |

Mainline's SPL runs from DRAM address 0 (`CONFIG_SPL_TEXT_BASE=0`) and
reserves `0x0`–`0x40000` for itself (`CONFIG_SPL_MAX_SIZE`). The vendor blob
lands 36 KiB inside that, so SPL overwrites its own running code partway
through loading it and never returns from the read. Note that SPL is careful
about its *data* — BSS at `0x3f80000`, stack at `0x3e00000`, the FIT header
read to `0x3c003c0` — but nothing checks the load address that comes out of
the BL31 ELF's own program headers.

Mainline TF-A links BL31 at `TZRAM_BASE + 0x40000` = `0x40000`
(`plat/rockchip/.../bl31_param.h`), which is exactly where SPL's reservation
ends. **The two are built to fit together and the vendor blob is not.** That
is why `TFA_REPO` is in `config/board.conf` and why the container carries
`gcc-arm-none-eabi` — TF-A builds rk3399's Cortex-M0 power-management firmware
into BL31.

### How the kernel is reached, and the one flag that decides it

Mainline cannot read Rockchip's raw `boot.img`, so the kernel is reached
through `/boot` on the root filesystem instead. That needed no new partition:
bootstd scans `/` **and `/boot/`** on every partition it can read
(`default_prefixes[]` in `boot/bootstd-uclass.c`), and the rootfs is already
`-O ^metadata_csum` ext4 that U-Boot reads. So `mkimage.sh` writes, on this
track only:

```
/boot/pikvm/Image
/boot/pikvm/rk3399-orangepi.dtb
/boot/extlinux/extlinux.conf
```

`/boot/pikvm/` and not `/boot/`, because the Arch kernel package already owns
`/boot/Image` and `/boot/dtbs` and neither is ours. Paths inside
`extlinux.conf` are absolute from the start of the partition.

**The rootfs partition has to be marked bootable**, and this is the piece that
cost an evening. `cmd/bootflow.c` sets `BOOTFLOWIF_ONLY_BOOTABLE`
*unconditionally* — it is not one of the flags `bootflow scan`'s `-b` controls,
so no bootcmd can turn it off — and `bootdev_find_in_blk()` then falls back to
scanning **partition 1 alone** when a disk has nothing marked bootable. Here
that is the raw `uboot` area with no filesystem in it, so the scan finds
nothing and the board stops at a U-Boot prompt with `extlinux.conf` sitting
readable on partition 4 the whole time:

```
=> ext4ls mmc 0:4 /boot/extlinux
      553   extlinux.conf                 <- U-Boot can see it
=> bootflow scan -l
(1 bootflow, 1 valid)                     <- and finds only efi_mgr
=> bootflow scan -l mmc0:4
  0  extlinux  ready  mmc  4  …  /boot/extlinux/extlinux.conf
```

The last line is the proof: naming a partition explicitly sets
`BOOTFLOWIF_SINGLE_PARTITION`, which is the one path that skips the bootable
check. `mkimage.sh` now sets GPT attribute bit 2 (`legacy_bios_bootable`,
which is exactly what `disk/part_efi.c` reads) on partition 4 — on both
tracks, since the BSP U-Boot finds partitions by name and never looks.

### Verified on hardware

Unattended, from power-on, with the flag set:

```
Scanning bootdev 'mmc@fe330000.bootdev':
  1  extlinux  ready  mmc  4  …  /boot/extlinux/extlinux.conf
** Booting bootflow 'mmc@fe330000.bootdev.part_4' with extlinux
Retrieving file: /boot/pikvm/Image
Starting kernel ...
Linux version 6.12.69-… Machine model: Orange Pi RK3399 Board
psci: PSCIv1.1 detected in firmware.
```

and then a working PiKVM: `is-system-running` = `running`, no failed units,
`kvmd`/`kvmd-otg`/`kvmd-nginx`/`kvmd-janus`/`kvmd-media` all active, 1080p on
`/dev/kvmd-video`, `/dev/hidg0..2`, `/dev/mpp_service`, the MSD store mounted,
57 °C.

`/proc/cmdline` is worth looking at, because it is the whole difference:

```
root=PARTUUID=615e0000-0000-4b53-8000-1d28000054a9 earlycon=… console=ttyS2,115200n8 rw rootfstype=ext4 …
```

No `storagemedia=`, no `androidboot.*`, and a full 36-character GUID that came
from `extlinux.conf` rather than from thirteen characters compiled into a
bootloader.

### With a card in the slot

Measured, because the scan order is easy to assume and worth having on record.
A mainline eMMC with an ordinary BSP-track card in the slot:

```
Scanning bootdev 'mmc@fe320000.bootdev':      <- the card, scanned first
Scanning bootdev 'mmc@fe330000.bootdev':      <- eMMC
  1  extlinux  ready  mmc  4  …  /boot/extlinux/extlinux.conf
** Booting bootflow 'mmc@fe330000.bootdev.part_4' with extlinux
```

The card **is** scanned first — `BOOT_TARGETS` is `"mmc1 mmc0 …"` and
`mmc1 = &sdmmc` — and it is scanned successfully; there is simply nothing on
it that bootstd can boot, since a BSP-track card has no `extlinux.conf` and no
partition marked bootable. It falls through to eMMC without complaint, and
Linux still sees the card as a full `mmcblk1`. So the card neither boots nor
interferes.

The rule that follows is the one worth remembering: **do not mix tracks across
media.** A mainline bootloader cannot boot a BSP-track card, and the reverse
combination boots the card the BSP way, using none of this.

**The GUID split cannot be dropped, and finding that out cost a board's
afternoon.** The tempting conclusion from the command line above is that the
SD and eMMC images no longer need to differ, since `root=` no longer comes
from a bootloader guessing at the medium. That is wrong, and it is wrong
because the split was solving two problems, not one:

1. the BSP U-Boot picking `root=` from the medium, with a thirteen-character
   prefix — **mainline does fix this**
2. the kernel's own `PARTUUID=` lookup being ambiguous when two attached media
   carry the same GUID — **mainline does nothing about this**

Demonstrated rather than argued. With an SD-family image on the eMMC and an
ordinary SD-family card in the slot:

```
mmcblk0p4  614e0000-0000-4b53-8000-1d28000054a9    <- eMMC
mmcblk1p4  614e0000-0000-4b53-8000-1d28000054a9    <- the card
```

Two partitions, two devices, one GUID. The kernel took the eMMC's and dropped
into emergency mode when it turned out to be the damaged one. A full
36-character GUID is narrower than the BSP's thirteen characters — it only
collides when two media carry literally the same image — but that is exactly
the "installed to eMMC and left the card in" case, which is the common one.

So `make emmc-image UBOOT_TRACK=mainline` exists and is what belongs on eMMC,
and the two families stay.

### The finished image, booted

`orangepi-rk3399-pikvm-rk612-emmc-uboot-mainline.img`, written to the eMMC as
a single `dd` and read back byte-identical, with the card removed:

```
/dev/mmcblk0p4
root=PARTUUID=615e0000-0000-4b53-8000-1d28000054a9 …   (from extlinux.conf)
running, 0 failed units
kvmd, kvmd-otg, kvmd-nginx, kvmd-janus, kvmd-media all active
mmcblk0p5  8.4G  /var/lib/kvmd/msd                     (grown on first boot)
DV timings: 1920x1080
```

So the whole path is the artifact, not a hand-assembly of its parts.

### And from an SD card, which is a different path

Everything above ran with the BootROM loading mainline from eMMC. Loading it
from a **card** is not the same path, and it was worth checking rather than
assuming: `u-boot,spl-boot-order = "same-as-spl", &sdhci, &sdmmc` has to
resolve `same-as-spl` to the right device, and that resolution had only ever
been exercised one way round.

Tested by erasing the eMMC's loader region so the BootROM falls through to the
card, with the card carrying `*-uboot-mainline.img`'s loader sectors and
`/boot`:

```
U-Boot SPL 2025.07
Trying to boot from MMC2                      <- MMC1 when it came off eMMC
...
Scanning bootdev 'mmc@fe320000.bootdev':      <- the card
  1  extlinux  ready  mmc  4  …  /boot/extlinux/extlinux.conf
** Booting bootflow 'mmc@fe320000.bootdev.part_4' with extlinux
```

`MMC2` rather than `MMC1` is the whole answer: SPL followed the device it was
loaded from, U-Boot proper then found the card's `extlinux.conf`, and the
board came up on `/dev/mmcblk1p4` — running, no failed units, all five kvmd
services, the MSD store at 22.6 G, 1080p, `/dev/hidg0..2`, `/dev/mpp_service`.

Note what that test needs, since it is the reason it came last: the eMMC's
loader has to be gone, because the BootROM reads it first and mainline's SPL
then stays on the device that loaded it. There is no way to run a card's
bootloader on a board whose eMMC has one.

`orangepi-rk3399-pikvm-rk612-uboot-mainline.img` was written to a card as a
single `dd`, read back byte-identical, and booted the same way: `MMC2` out of
SPL, `mmc@fe320000.bootdev.part_4` in U-Boot, root on `/dev/mmcblk1p4` with
the `614e` GUID out of its own `extlinux.conf`, and a working PiKVM — no
failed units, all five kvmd services, MSD grown to 22.6 G, 1080p,
`/dev/hidg0..2`, `/dev/mpp_service`.

Getting the card written at all needs one trick worth writing down, since the
obvious sequence is circular: the card cannot be imaged while the board is
running from it, and the board will not run from eMMC while a bootable card is
present. Zeroing **one sector** — the card's sector 64, where `rkimgtest`
looks for the Rockchip IDB magic — makes the BSP U-Boot skip the card without
touching anything else on it. The board then boots eMMC with the card still
in, and the card can be written whole.

### What it buys, and it is four patches of one kind

Every one of them exists only because the BSP U-Boot calls
`init_kernel_dtb()` — it reads the *kernel's* device tree and drives its own
hardware from it, so vendor-only properties have to be smuggled into a file
that is otherwise Linux's:

* kernel **0002** in full — the `dwmmc@`/`sdhci@` renames exist so the BSP
  U-Boot does not bind a second device for the same controller
* from kernel **0001**: `rockchip,pwm_id` and `rockchip,pwm_voltage` on
  `vdd_log`, `regulator-init-microvolt` on LDO_REG4, and the deletion of
  `stdout-path`

Mainline U-Boot has its own control DTB and never looks at the kernel's, so
all four become dead weight — and the `vdd_log` value is already upstream in
its own `-u-boot.dtsi`.

They are still applied, and have to be: the BSP track is still the default and
every card in existence runs it. Banking them means deciding to drop that
track, which is a bigger call than making this one work.

### Testing it costs less than it did

It used to mean maskrom every time, because the BootROM reads eMMC before the
card and mainline's SPL stays on the device it was loaded from
(`u-boot,spl-boot-order = "same-as-spl", &sdhci, &sdmmc`), so a mainline
U-Boot on eMMC is reached before any card and a card cannot override it.

Now that it reaches a prompt, it recovers itself. With the BSP blobs kept on
the root filesystem, restoring them is four commands and no USB cable:

```
=> ext4load mmc 0:4 0x10000000 /root/bsp/idbloader.img
=> mmc write 0x10000000 40 148
=> ext4load mmc 0:4 0x10000000 /root/bsp/uboot.img
=> mmc write 0x10000000 6000 2000
=> ext4load mmc 0:4 0x10000000 /root/bsp/trust.img
=> mmc write 0x10000000 8000 2000
=> reset
```

Verified: that is how the board was put back after the run above. Keep
maskrom ([emmc.md](emmc.md)) for the case where it does not reach a prompt.

---

## Why this branch, and what it costs

`develop-6.12` looks complete from the outside: it has `tc35874x.c`, it has
`rk3399-orangepi.dts`, it keeps the Rockchip `boot.img` flow. Do not read that
as "RK3399 is supported here". The branch is plainly aimed at RK3588, the
board DTS ships with no HDMI IN wiring at all, and RK3399 on it is an untested
path — which is what the patch series in `patches/kernel-6.12/` is.

Budget for that if you pick it up. The one reason it is still the right
choice: **`tc35874x.c` exists only in Rockchip's tree.** Mainline has `tc358743.c`
and no TC358749 support. Everything else about the branch - the DTS, the boot
flow, the kernel version - mainline or `develop-6.6` would have matched.
Checked and rejected:

* **`develop-6.6`** carries the identical 895-line board DTS and identical
  `tc35874x.c`. Only difference: no rk808 regulator bug. Not worth migrating
  for a bug already patched.
* **mainline v6.12** has the same board DTS again, byte for byte, but no
  TC358749 driver - the one thing that cannot be replaced.

## Still open

* **Capture** - working at 1080p60. See docs/capture.md.
* **`kvmd-otg`** - no `/dev/hidg*`; the OTG port is probably not in
  peripheral mode.
* **`display-subsystem`** deferred, so HDMI output stays black.
* **H.264 and WebRTC** - done. Patch 0001 enables VEPU2 and
  `patches/libv4l-rkmpp/0002` gets ustreamer onto it, so `--h264-sink` is in
  `main.yaml` and `kvmd-media`/`kvmd-janus` are enabled on the rkmpp variant.
  Both verified on hardware.
* **HDMI IN audio - parked, and it needs a scope, not more code.** The sink
  H.264 needed is there, kvmd's janus config already names `hw:tc358743,0`,
  and patch 0001 now makes that card exist. It captures silence. The
  receiver's I2S goes into the ALC5651's second port, not into the SoC, and
  the codec's Stereo2 DAC - which every AIF2 -> AIF1 route has to cross -
  only runs when I2S2 has a clock and has none. Everything on the SoC side of
  the codec was proved good by measurement. All three implementation routes
  that were on the table are accounted for in docs/known-issues.md; none of
  them changes this, because the missing thing is upstream of all of them. Next step is physical: a scope on the ALC5651's pins 28 and 29 while
  the target plays audio. Patch 0013, the rail-voltage fix this turned up, is
  worth keeping regardless of what that scope says.
* **Thermal headroom, not cpufreq.** DVFS works now (`=m`, loaded from
  systemd; see patches.md), and the CPU encoder that was the board's main
  heat source is gone, which took the SoC from 78 C to 65 C and stopped the
  big cluster being throttled. What is left is physical: with a heatsink the
  headroom now converts directly into CPU frequency, which was not true
  before - with no cooling device bound to `cpu-thermal`, extra headroom had
  nothing to spend itself on.
* **`vcgencmd` noise** - kvmd polls a Raspberry Pi throttling interface every
  five seconds and logs a failure each time. Harmless, fills the journal.
* **Wi-Fi credentials.** The hardware works - mainline `brcmfmac` on the
  AP6356S, see patches.md - and is verified as far as it can be without
  someone's password: `wlan0` comes up and scans 2.4 and 5 GHz. `wlan.network`
  is installed, but nothing associates without an SSID and a passphrase,
  which are not ours to ship. Verified end to end once with real ones:
  associates, gets DHCP, survives a reboot, wired stays preferred. One
  caveat that is the router's problem rather than ours - the BCM4356
  firmware does not scan 5 GHz DFS channels (52-144), so an AP on channel
  108 is invisible; use 36-48 or 149-165.
  `/etc/wpa_supplicant/README` is the whole procedure. Deliberately not
  enabled by default: a `wpa_supplicant` with no network block fails at
  boot, and most of these boards will only ever use the wired port.
