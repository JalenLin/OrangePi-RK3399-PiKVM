# OrangePi RK3399 PiKVM image builder
#
#   make all             - bootloader, kernel, rootfs, then the image
#   make images          - list what has been built
#   make flash SD=/dev/sdX
#
# Each step is resumable: rerunning a target reuses what is already in
# sources/ and output/. See docs/building.md.

S := build/scripts

KERNEL_TRACK ?= rk612
export KERNEL_TRACK
IMG := output/orangepi-rk3399-pikvm-$(KERNEL_TRACK).img

.PHONY: all uboot kernel rootfs image flash images clean distclean clean-docker footprint help

all: uboot kernel rootfs image

uboot:
	@$(S)/build-uboot.sh

kernel:
	@$(S)/build-kernel.sh

rootfs:
	@$(S)/build-rootfs.sh

image:
	@$(S)/mkimage.sh

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
	-docker rmi -f opi-pikvm/kbuild:20.04 opi-pikvm/rootfs:latest
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
	@sed -n '2,7p' Makefile
