# PiKVM on OrangePi RK3399

A buildable SD card image that turns the OrangePi RK3399 into a
[PiKVM](https://github.com/pikvm/pikvm), using the board's own HDMI IN rather
than a USB capture dongle.

The board's HDMI input is a Toshiba TC358749XBG HDMI→CSI-2 bridge — the same
class of part PiKVM V2 uses — so the entire PiKVM userspace applies unchanged.
All of the porting work is on the kernel side.

## What works

Verified on hardware, not inferred from config symbols:

| | |
|---|---|
| **Video** | 1080p60 HDMI IN capture, follows source mode changes |
| **MJPEG** | encoded on the SoC's VPU, ~50% of one core |
| **H.264 / WebRTC** | same VPU, Constrained Baseline 1080p, `kvmd-janus` and `kvmd-media` serving |
| **HID** | keyboard and mouse over the Type-C port, verified end to end against a real target |
| **Mass storage** | ISO/CD-ROM emulation, read back from the target; store expands to fill the card on first boot |
| **Network** | gigabit ethernet; Wi-Fi on mainline `brcmfmac` (AP6356S) |
| **Storage** | SD card or the onboard 14.6 GB eMMC, booted and verified on both |
| **Kernel** | Rockchip BSP 6.12.69, with 13 patches |
| **Userland** | Arch Linux ARM + PiKVM's own packages, systemd 261 |

**HDMI IN audio does not work** and is parked — the receiver's I2S is wired to
the audio codec rather than to the SoC. See
[docs/known-issues.md](docs/known-issues.md), which is worth reading before
you start.

## Build

```sh
make all                 # bootloader, kernel, rootfs, image  (~2 h, mostly rootfs)
make flash SD=/dev/sdX   # prompts before it overwrites anything
```

The board also has 14.6 GB of eMMC, and `make emmc-image` builds the same
image laid out for it — three minutes on top of a build you already have. It
has to be a separate image: the vendor U-Boot decides `root=` from the medium
it booted off and hardcodes a different partition GUID for each.
[docs/emmc.md](docs/emmc.md) has that, three ways to write it, and the boot
order — which is not what it looks like, and is the one thing there that can
cost you a board.

Everything builds in containers; nothing installs on your machine except one
qemu binfmt handler. Individual steps (`make uboot`, `kernel`, `rootfs`,
`image`) are resumable.

**[docs/building.md](docs/building.md) is the full guide** — what you need,
what each step does, the serial console (its baud rate changes mid-boot), and
how to add a patch or change the kernel config.

Then `root` / `root` over SSH and `admin` / `admin` on the web UI. Change
both. [docs/bringup.md](docs/bringup.md) is a nine-step checklist for
confirming the hardware came up.

## Documentation

| | |
|---|---|
| [docs/building.md](docs/building.md) | building, flashing, serial console, changing things |
| [docs/hardware.md](docs/hardware.md) | the board itself: pins, rails, GPIO, what is wired to what |
| [docs/patches.md](docs/patches.md) | every patch and why it exists |
| [docs/image-layout.md](docs/image-layout.md) | the SD card's partition layout and why it is not negotiable |
| [docs/emmc.md](docs/emmc.md) | installing to the onboard eMMC instead of a card |
| [docs/capture.md](docs/capture.md) | EDID, video modes, following a mode change |
| [docs/known-issues.md](docs/known-issues.md) | what does not work, and what is only cosmetic |
| [docs/bringup.md](docs/bringup.md) | first-boot checklist |
| [docs/roadmap.md](docs/roadmap.md) | where this is going, and the routes evaluated and rejected |

## Layout

```
config/board.conf              pinned sources, SD layout, target settings
config/kernel-fragments/       the Kconfig PiKVM needs on top of the vendor defconfig
build/docker/                  cross-build and rootfs container definitions
build/scripts/                 one script per build stage
overlay/                       files grafted into the rootfs (kvmd config, udev, systemd)
patches/kernel-6.12/           kernel patches, applied in filename order
patches/libv4l-rkmpp/          userspace patches, applied inside the rootfs build
docs/logs/                     a known-good boot log to diff against
sources/                       upstream checkouts - cloned by the build, gitignored
output/                        build products (gitignored)
```

## Design notes

**Why Arch Linux ARM.** It is what PiKVM upstream targets, so `kvmd` and
`ustreamer` install from PiKVM's own pacman repository instead of being
repackaged, and staying current with upstream stays cheap.

**Why Rockchip's 6.12 BSP and not mainline.** One reason only:
`drivers/media/i2c/tc35874x.c` exists nowhere else, and mainline's
`tc358743.c` does not support the TC358749. Everything else about the branch —
the board DTS, the boot flow, the kernel version — mainline would have
matched. See [docs/roadmap.md](docs/roadmap.md); moving to mainline is still
the goal, and the diff has been measured.

**Why the SD layout is copied sector-for-sector.** The RK3399 BootROM looks
for its loader at a fixed offset and U-Boot locates the rootfs by partition
GUID. These are constraints, not choices.

**Why the VPU work is not optional.** Without it ustreamer software-encodes
MJPEG at 316% CPU and 78 °C, thermally throttling the big cluster, and cannot
do H.264 at all — ustreamer has no software H.264 encoder, so there is no
WebRTC either. There used to be a variant built without it. It was strictly
worse in every measurement, so it has been removed.

## Licence

The kernel and `libv4l-rkmpp` patches are derivative works of GPL-2.0 code and
carry that licence. See [LICENSE](LICENSE).
