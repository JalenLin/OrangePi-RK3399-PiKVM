# OrangePi RK3399 PiKVM image builder
#
#   make all             - bootloader, kernel, rootfs, then the image
#   make emmc-image      - the same build, laid out for this board's eMMC
#   make images          - list what has been built
#   make flash SD=/dev/sdX
#   make flash-emmc      - write the eMMC image over USB, board in maskrom
#
# Each step is resumable: rerunning a target reuses what is already in
# sources/ and output/. See docs/building.md.

S := build/scripts

KERNEL_TRACK ?= rk612
export KERNEL_TRACK
# bsp | mainline. Only bsp boots; see docs/roadmap.md.
UBOOT_TRACK ?= bsp
export UBOOT_TRACK
IMG      := output/orangepi-rk3399-pikvm-$(KERNEL_TRACK).img
EMMC_IMG := output/orangepi-rk3399-pikvm-$(KERNEL_TRACK)-emmc.img
# Shipped prebuilt in the vendor blob repo that `make uboot` already fetches,
# so the maskrom route needs nothing installed on the host.
RKDEV    := sources/external-bsp/rkbin/tools/rkdeveloptool
# It needs raw USB access. A container with the USB bus bound in is cheaper
# than sudo, and this build already requires docker for everything else.
RKRUN    := docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb -v $(CURDIR):/work -w /work opi-pikvm/rkdev $(RKDEV)

.PHONY: all uboot kernel rootfs image emmc-image flash flash-emmc images clean distclean clean-docker footprint help

all: uboot kernel rootfs image

uboot:
	@$(S)/build-uboot.sh

kernel:
	@$(S)/build-kernel.sh

rootfs:
	@$(S)/build-rootfs.sh

image:
	@$(S)/mkimage.sh

# Not part of `all`: most boards will only ever be flashed to a card, and this
# reassembles from the same output/ the SD image was built from, so it is a
# three-minute afterthought rather than a second build. The two images differ
# in six partition GUIDs and nothing else - see config/board.conf.
emmc-image:
	@TARGET_MEDIUM=emmc $(S)/mkimage.sh

# Deliberately not wired into `all`: this writes to a block device.
flash:
	@test -n "$(SD)" || { echo "usage: make flash SD=/dev/sdX"; exit 1; }
	@test -b "$(SD)" || { echo "$(SD) is not a block device"; exit 1; }
	@echo "About to overwrite $(SD):"
	@lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$(SD)"
	@read -p "Type YES to continue: " a; [ "$$a" = YES ] || exit 1
	@test -f "$(IMG)" || { echo "$(IMG) does not exist - build it with 'make all'"; exit 1; }
	@echo "Writing $(IMG)"
	sudo dd if=$(IMG) of=$(SD) bs=4M status=progress conv=fsync
	sync

# eMMC has no device node on this machine - the board itself is the target,
# over the Type-C port, with the BootROM in maskrom mode answering. `db` puts
# the loader in DRAM, `wl 0` writes the image from sector 0. docs/emmc.md has
# how to get the board into maskrom, and two other ways to do this that do not
# need it.
flash-emmc:
	@test -f "$(EMMC_IMG)" || { echo "$(EMMC_IMG) does not exist - build it with 'make emmc-image'"; exit 1; }
	@test -x "$(RKDEV)" || { echo "$(RKDEV) is missing - run 'make uboot' first"; exit 1; }
	@docker image inspect opi-pikvm/rkdev >/dev/null 2>&1 || docker build -t opi-pikvm/rkdev -f build/docker/Dockerfile.rkdev build/docker
	@lsusb | grep -q "2207:" || { echo "no Rockchip device on USB - hold MASKROM and power on, and plug the board close to the root hub (see docs/emmc.md)"; exit 1; }
	@echo "Board in maskrom:"; lsusb | grep "2207:"
	@read -p "Type YES to overwrite that board's eMMC: " a; [ "$$a" = YES ] || exit 1
	$(RKRUN) db $$(ls output/uboot/rk3399_loader_*.bin | head -1)
	$(RKRUN) td
	$(RKRUN) wl 0 $(EMMC_IMG)
	$(RKRUN) rd

# What has actually been built, so you can tell the cards apart.
images:
	@ls -lh output/*.img 2>/dev/null || echo "  (no images built yet)"

# Build products only. Upstream checkouts in sources/ are left alone, since
# re-cloning them costs several GB of download.
clean:
	rm -rf output/*

distclean: clean clean-docker
	rm -rf sources/* .cache

# Nothing in this project installs onto the host: the toolchain, the image
# tools and the aarch64 rootfs all live in containers. The one exception is
# the qemu-aarch64 binfmt handler, which is by nature global - building an
# aarch64 rootfs on x86_64 means the host kernel has to know how to run
# aarch64 binaries. This removes both.
clean-docker:
	-docker rmi -f opi-pikvm/kbuild:20.04 opi-pikvm/rootfs:latest opi-pikvm/rkdev
	-docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-aarch64
	-docker rmi -f tonistiigi/binfmt:latest

# What this build has actually put on the machine.
footprint:
	@echo "== docker images =="
	@docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'opi-pikvm|binfmt' || echo "  (none)"
	@echo "== binfmt handlers =="
	@ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -i qemu | sed 's/^/  /' || echo "  (none)"
	@echo "== disk under this project =="
	@du -sh sources output .cache 2>/dev/null | sed 's/^/  /'

help:
	@sed -n '2,9p' Makefile
