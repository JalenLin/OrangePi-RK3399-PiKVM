# Building the image

Everything builds in containers. Nothing installs onto your machine except
one qemu binfmt handler, which is global by nature — building an aarch64
rootfs on x86_64 means the host kernel has to know how to run aarch64
binaries. `make clean-docker` removes both the images and the handler.

## What you need

* Docker, and a user who can run it
* ~25 GB free: upstream checkouts are most of it (`sources/` is ~11 GB
  with both kernel tracks fetched, `.cache/` 1.6 GB), plus a 6.7 GB image
* An x86_64 host. Cross-compilation is the only path that has been run.

No cross-toolchain, no `mkimage`, no `parted` on the host — those live in
`opi-pikvm/kbuild:20.04`, built from `build/docker/Dockerfile.kbuild`.

## The four steps

```sh
make all          # = uboot kernel rootfs image
```

Each step is resumable and reuses whatever is already in `sources/` and
`output/`, so a failed run is picked up rather than restarted. Run them one at
a time while you are changing things:

| | builds | into | roughly |
|---|---|---|---|
| `make uboot` | idbloader / uboot / trust | `output/uboot/` | 2 min |
| `make kernel` | Image + DTB, packed as `boot.img` | `output/kernel/`, `output/modules/` | 15 min |
| `make rootfs` | Arch Linux ARM + PiKVM + `/opt/rkmpp` | `output/rootfs.tar` | 60–90 min |
| `make image` | the GPT card image | `output/*.img` | 3 min |

`make rootfs` is the slow one and it is slow for a reason: every `pacman`
invocation runs aarch64 binaries under qemu-user emulation. It is not hung.

## Writing a card

```sh
make flash SD=/dev/sdX
```

It prints `lsblk` for the device and requires you to type `YES`. It is
deliberately not part of `make all`. **Check the device name twice** — this
writes 6.7 GB straight over whatever is there.

To do it by hand:

```sh
sudo dd if=output/orangepi-rk3399-pikvm-rk612.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

The card must be **at least 8 GB**. Anything past the image is claimed by the
MSD partition on first boot; see docs/image-layout.md.

## Serial console

You will want it, especially the first time. The debug UART is a 3-pin header
on the board.

**The baud rate changes mid-boot.** U-Boot is compiled for **1500000**; the
kernel and the login prompt run at **115200**. So a terminal fixed at either
rate shows garbage for the other half of the boot. That is expected, not a
fault.

1500000 reads fine on this wiring but corrupts on write, which is why the
kernel console was moved down — a console you cannot type into is not a
console.

```sh
picocom -b 115200 /dev/ttyUSB0     # kernel and login
picocom -b 1500000 /dev/ttyUSB0    # U-Boot
```

`docs/logs/rk612-boot-ok.log` is a full healthy boot to diff against.

## First boot

Takes a couple of minutes: `pikvm-expand-msd` grows the last partition to fill
the card, and systemd does its first-boot work. Then:

* SSH as `root` / `root` — **change it**
* Web UI on `https://<board>/`, `admin` / `admin` — **change it too**

`docs/bringup.md` is a nine-step checklist for confirming the hardware came up.

## Changing things

**Kernel config.** `config/kernel-fragments/pikvm.config` is merged over
`rockchip_linux_defconfig`. It is a fragment, not a full config, and every
symbol in it has a comment saying why. A few are load-bearing in ways that are
not obvious — `CONFIG_CFG80211` has to be `=m`, because built in it asks for
`regulatory.db` during init while the initramfs is still root, fails with
`-2`, never retries, and pins the radio to the world domain for the whole
boot.

**Kernel patches.** Drop a `NNNN-*.patch` into `patches/kernel-6.12/`. They
are applied in filename order by plain `git apply`, and the tree is reset to
`HEAD` first, so you can rerun `make kernel` freely. There is no `--3way` and
no fuzz: a patch either applies or the build stops.

To regenerate one after editing the source by hand:

```sh
cd sources/kernel-rk612
git diff -- path/to/file > ../../patches/kernel-6.12/00NN-what-it-does.patch
```

Add a prose header above the diff. `git apply` ignores anything before the
first `---`/`diff` line, and docs/patches.md explains what each patch is for.

**Userspace patches.** `patches/libv4l-rkmpp/` is applied inside the rootfs
build. Changing one invalidates the Docker layer cache from that point on, so
expect the `/opt/rkmpp` stage to rebuild (~20 min), not the whole rootfs.

**The overlay.** `overlay/` is copied over the rootfs verbatim, preserving
paths. This is where every board-specific config lives — kvmd's `main.yaml`,
the udev rules, the systemd drop-ins. Editing a file here is a `make rootfs
image` away from a new card, with no kernel rebuild.

## The kernel track

`KERNEL_TRACK` selects which kernel to build. It is in the image filename
because two cards are physically indistinguishable and flashing the wrong one
costs a debugging cycle.

* **`rk612`** (default) — Rockchip BSP 6.12.69. The only one that works.
* **`bsp`** — vendor 4.4.179. Boots, then panics: systemd 258 removed cgroup
  v1, Arch installs 261, and 4.4's cgroup v2 has no cpu controller. Kept only
  for diffing device trees against a tree where HDMI IN was known to work.

## Cleaning

```sh
make clean         # build products only; keeps the multi-GB checkouts
make distclean     # the above, plus sources/, .cache/ and the Docker images
make footprint     # what this project has actually put on your machine
```
