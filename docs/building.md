# Building the image

Everything builds in containers. Nothing installs onto your machine except
one qemu binfmt handler, which is global by nature — building an aarch64
rootfs on x86_64 means the host kernel has to know how to run aarch64
binaries. `make clean-docker` removes both the images and the handler.

## What you need

* Docker, and a user who can run it
* ~15 GB free for a default build, ~25 GB if you also fetch the dead 4.4
  track: upstream checkouts are most of it (`sources/` is 5.8 GB for `rk612`
  alone and 11 GB with both, `.cache/` 1.6 GB), plus a 6.7 GB image
* A network connection for the first build — see below
* An x86_64 host. Cross-compilation is the only path that has been run.

No cross-toolchain, no `mkimage`, no `parted` on the host — those live in
`opi-pikvm/kbuild:20.04`, built from `build/docker/Dockerfile.kbuild`.

## Where the sources come from

You do not fetch anything by hand, and `sources/` is deliberately not in the
repository — it is 5.8 GB of other people's git history. The build clones what
it needs, on demand, the first time a step needs it. A first build therefore
needs network access; later builds do not.

| `sources/` | from | branch | size | needed by |
|---|---|---|---|---|
| `kernel-rk612` | `rockchip-linux/kernel` | `develop-6.12` | 3.8 GB | `make kernel` |
| `toolchain` | `orangepi-xunlong/toolchain` | `aarch64-linux-gnu-6.3` | 869 MB | `make uboot` |
| `external-bsp` | `orangepi-xunlong/OrangePiRK3399_external` | `orangepi-rk3399_v1.4` | 834 MB | `make uboot` |
| `uboot-bsp` | `orangepi-xunlong/OrangePiRK3399_uboot` | `master` | 261 MB | `make uboot` |
| `kernel-bsp` | `orangepi-xunlong/OrangePiRK3399_kernel` | `master` | 5.1 GB | only `KERNEL_TRACK=bsp` |

`external-bsp` is Rockchip's `rkbin` blob repository — the DDR init and BL31
that end up in `idbloader.img` and `trust.img`. Rockchip's `make.sh` looks for
it at `../external/rkbin` relative to the U-Boot tree, which is why
`build-uboot.sh` leaves a `sources/external` symlink pointing at it, and why
`sources/` is laid out this way rather than however you might prefer.

The `toolchain` checkout is Linaro GCC 6.3, and it is only there because the
vendor U-Boot wants it. The 6.12 kernel is built with the distro cross-gcc
inside the container instead — 6.3 is too old for it and fails on
`-Wattribute-warning`.

Three more things are downloaded by `make rootfs`, into the Docker build
rather than into `sources/`: Rockchip's `mpp`, `linuxtv.org`'s v4l-utils
tarball with a mmap patch from `JeffyCN/meta-rockchip`, and
`JeffyCN/libv4l-rkmpp`. The Arch Linux ARM rootfs tarball is cached in
`.cache/`, and PiKVM's own packages come from `files.pikvm.org` during the
build. All of the URLs are in `config/board.conf` and
`build/docker/Dockerfile.rootfs`.

### Two things worth knowing about the checkouts

**They are branch tips, not commits.** `fetch_repo` in
`build/scripts/common.sh` does `git clone --depth 1 -b <branch>`, so what you
get is whatever that branch pointed at on the day you cloned. This tree was
built against `kernel-rk612` at `470f9dccb`. Nothing enforces that, so two
machines cloning a month apart can be building different code — if that
matters to you, check out a specific commit yourself after the first fetch.

**They are never updated.** `fetch_repo` skips any directory that already has
a `.git`, so a checkout is fetched exactly once and then left alone forever.
To move to newer upstream code, delete the directory and let the next build
re-clone it.

**Anything you edit in `sources/` by hand will be destroyed.** Before applying
patches, the build resets the tree with `git checkout HEAD -- .` — it does not
try to work out what is already applied, because two patches touching the same
lines make that unreliable. Turn your change into a patch first; see *Changing
things* below.

## The four steps

```sh
make all          # = uboot kernel rootfs image
```

Each step is resumable and reuses whatever is already in `sources/` and
`output/`, so a failed run is picked up rather than restarted. Run them one at
a time while you are changing things:

| | builds | into | roughly |
|---|---|---|---|
| `make uboot` | idbloader / uboot / trust, plus the maskrom loader | `output/uboot/` | 2 min |
| `make kernel` | Image + DTB, packed as `boot.img` | `output/kernel/`, `output/modules/` | 15 min |
| `make rootfs` | Arch Linux ARM + PiKVM + `/opt/rkmpp` | `output/rootfs.tar` | 60–90 min |
| `make image` | the GPT card image | `output/*.img` | 3 min |
| `make emmc-image` | the same, for the onboard eMMC | `output/*-emmc.img` | 3 min |

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

## Writing the eMMC instead

The board has 14.6 GB of eMMC and boots from it perfectly well, but it is not
the same image — the vendor U-Boot hardcodes a different rootfs GUID per
medium, so `make emmc-image` builds a second file. `make flash-emmc` writes it
over USB with the board in maskrom mode, and there are two routes that need no
maskrom at all. All of it, and the boot order that decides which medium wins,
is in [emmc.md](emmc.md).

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
