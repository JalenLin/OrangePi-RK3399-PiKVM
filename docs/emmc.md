# Installing to eMMC

The board has 14.6 GB of eMMC soldered on, and PiKVM runs from it exactly as
well as from a card. What you get for moving: nothing to fall out of a slot,
nothing whose write endurance is a mystery, and the SD slot free — which also
means the card stays your recovery path, because of the boot order below.

Everything here is verified on the board unless a section says otherwise.

## The one fact that shapes all of this

An eMMC image is **not** an SD image written to a different device. The two
carry different partition GUIDs, and that is forced on us from below.

The BSP U-Boot appends `root=` to the kernel command line itself, and it picks
the value from a hardcoded two-way branch on the medium it booted from
(`common/boot_rkimg.c`):

```c
if (!strcmp(boot_media, "emmc"))
        ... "androidboot.mode=normal root=PARTUUID=615e0000-0000"
else
        ... "androidboot.mode=normal root=PARTUUID=614e0000-0000"
```

Thirteen characters, compiled in, with nothing in the image able to override
them. So the rootfs on a card must have a GUID starting `614e0000-0000` and
the rootfs on eMMC must start `615e0000-0000`. Cross them over and the board
stops at `Waiting for root device PARTUUID=…`.

The truncation is worth understanding rather than working around, because it
is also the reason the split is a *good* idea. The kernel matches `PARTUUID=`
by prefix — `match_dev_by_uuid()` compares only `strlen()` of what it was
given — across every block device it can see. Thirteen characters would match
a card's rootfs *and* its MSD partition, and on a board with both media
installed it would match all four. Keeping the medium in the prefix is what
stops an SD boot from mounting the eMMC's root filesystem, or the reverse.

The GUIDs are the vendor's, not an invention here: `615e…54a9` is what the
vendor's own `external/install_to_emmc` writes.

## Boot order: the eMMC's loader runs first and then hands over to the card

The observable behaviour is simple — **to boot from eMMC, take the card
out** — and it held every time it was tried:

* Before any of this, the eMMC held a complete factory Android 8.1 image — a
  Rockchip loader at sector 64, a parameter block at sector 8192, no GPT. With
  a PiKVM card in the slot the board booted the **card**.
* After installing PiKVM to eMMC, with the card still in, it still booted the
  card. It booted eMMC on the first power-up with the slot empty.

The mechanism is not what that behaviour suggests, and the difference is the
one thing in this document that can cost you a board.

**The BootROM reads eMMC first.** It does not look at the card until the eMMC
has no loader it can use. What makes the card win is one stage later: the BSP
U-Boot scans for a boot device itself and prefers SD, which is exactly why it
then reports `storagemedia=sd`. The card is chosen *by the bootloader that
came off the eMMC*, not ahead of it.

This was measured the expensive way. Testing mainline U-Boot meant writing its
TPL/SPL to the eMMC, and mainline's SPL takes its boot order from
`u-boot,spl-boot-order = "same-as-spl", &sdhci, &sdmmc` — it stays on the
device the ROM loaded it from. With that on the eMMC and a perfectly good
PiKVM card in the slot, the board ran the eMMC's TPL, stalled, and never
looked at the card. Serial confirmed it: `U-Boot TPL 2025.07` with the card
in.

So the corollary to draw is the opposite of the comfortable one:

> **A card is a recovery path only while the eMMC carries a loader that hands
> over to it.** Replace the eMMC's bootloader with one that does not, and the
> board boots nothing at all — card or no card — and only maskrom gets it
> back.

Nothing in the three routes below does that: they all write the same BSP
bootloader the card runs. It is worth knowing before you write your own.

## Building the image

```sh
make emmc-image        # after `make all`, or any time output/ is populated
```

That is `output/orangepi-rk3399-pikvm-rk612-emmc.img`, and it reassembles from
the same `output/` the SD image was built from — three minutes, not a second
build. It is byte-identical to the SD image apart from six partition GUIDs and
the two `PARTUUID=` values in `/etc/fstab`.

Both files are in `output/` at once and nothing about a written device tells
them apart afterwards, so the medium is in the filename.

## Three ways to write it

### 1. Stream the image in from a running SD boot

The board is up on a card and reachable over the network. This needs no free
space on the board — the image never lands in a file:

```sh
pigz -1 -c output/orangepi-rk3399-pikvm-rk612-emmc.img \
  | ssh root@<board> 'gzip -dc | dd of=/dev/mmcblk0 bs=4M conv=fsync status=none'
```

2 min 16 s here for the 6.2 GB image over gigabit; most of it is zeroes, which
is why compressing on the way is worth the flag. `/dev/mmcblk0` is always the
eMMC and `/dev/mmcblk1` always the card — the kernel DTS pins that with
`aliases { mmc0 = &sdhci; mmc1 = &dwmmc; }`, and `lsblk` shows the eMMC as the
one with `mmcblk0boot0` and `mmcblk0boot1` siblings.

Then power off, remove the card, power on. The MSD partition grows to fill the
eMMC on that first boot exactly as it does on a card — 8.4 GB here, with the
6 GB rootfs ahead of it.

### 2. `pikvm-install-emmc`: copy the running system across

On the board, no image and no build machine involved:

```sh
pikvm-install-emmc          # asks before it destroys anything; -y skips that
```

4 minutes measured. It is the vendor's `install_to_emmc` rewritten for this
image's layout, and what it does is worth knowing before you trust it:

* reads the partition layout back off the card it is running from, rather than
  restating the numbers `config/board.conf` owns
* copies sectors 64 through the end of the boot partition as one raw block —
  idbloader, `uboot`, `trust` and `boot` are none of them filesystems — while
  stepping over the GPT, which must not be copied
* recreates the partition table with the `615e` GUIDs, sizing the MSD store to
  fill the eMMC
* copies the root filesystem with `tar --one-file-system` (this image ships no
  `rsync`)
* rewrites `/etc/fstab`, whose two lines both name partitions by GUID

The result differs from the image in one way that may be the reason to prefer
it: it carries your configuration — Wi-Fi credentials, changed passwords, an
`override.yaml` — because it is a copy of the system you already set up.

### 3. Maskrom mode, from the host over USB

For a board with no card and no running system — and the route back from a
bootloader that does not boot, which is the only reason it is not last.

```sh
make flash-emmc            # needs the board in maskrom, on the Type-C port
```

That runs `rkdeveloptool db <loader>` to put a loader in DRAM and
`rkdeveloptool wl 0 <image>` to write from sector 0. Both the tool and the
loader are already in the tree: the tool is a prebuilt x86-64 binary in the
vendor blob repo (`sources/external-bsp/rkbin/tools/rkdeveloptool`, which
`make uboot` fetches) and the loader is `rk3399_loader_v1.22.119.bin`, which
`make uboot` packs and copies to `output/uboot/`. Nothing to install.

Getting the board in is physical, and the vendor's own instructions
(`board/rockchip/evb_rk3399/README` in the BSP U-Boot tree) are the whole of
it: **power on, or press RESET, with the MASKROM key held.** The host then
shows

```
Bus 003 Device 034: ID 2207:330c Fuzhou Rockchip ... RK3399 in Mask ROM mode
```

Four things this cost time to learn, all of them verified here on a board that
genuinely needed rescuing:

* **Plug the board close to the root hub.** Behind two levels of USB hub the
  loader downloads fine and then the board fails to come back:
  `usb 3-2.1.2-port1: unable to enumerate USB device`, and `rkdeveloptool`
  reports no device at all. One hub level worked.
* **`ld` does not exist** in the bundled `rkdeveloptool` 1.2. Use `td`.
* **`td` fails in maskrom and succeeds after `db`.** "Test Device failed!"
  before the loader is downloaded is normal; `Test Device OK.` afterwards is
  the signal that the board is in loader mode and will accept `wl`.
* **Keep the 12 V supply connected.** The Type-C port is not a power source
  for this board: PiKVM puts it in device role, so the PHY classifies the
  cable as an SDP and takes 500 mA —
  `phy usb2phy@e450.6: charger = USB_SDP_CHARGER` in the kernel log — which is
  not enough to run Linux. On USB power alone this board reaches systemd and
  hard-resets at about eight seconds, over and over, with no panic and nothing
  in the log to explain it.

**Restoring only the bootloader is seconds, not a 6 GB write.** If the
partitions and the root filesystem are intact and it is the boot chain you
broke, write the three blobs back where the layout puts them:

```sh
RK=sources/external-bsp/rkbin/tools/rkdeveloptool
$RK db    output/uboot/rk3399_loader_v1.22.119.bin
$RK wl 64    output/uboot/idbloader.img
$RK wl 24576 output/uboot/uboot.img
$RK wl 32768 output/uboot/trust.img
$RK rd
```

`rkdeveloptool` needs raw USB access, so run it as root — or in a container
with `--privileged -v /dev/bus/usb:/dev/bus/usb`, which is how `make
flash-emmc` avoids asking for a password it does not need for anything else.

Routes 1 and 2 need none of this, which is why they are listed first.

## Checking it worked

```
# cat /proc/cmdline
storagemedia=emmc androidboot.storagemedia=emmc ... root=PARTUUID=615e0000-0000 ...

# findmnt -no SOURCE /
/dev/mmcblk0p4

# lsblk
mmcblk0      14.6G
|-mmcblk0p4     6G  /
`-mmcblk0p5   8.4G  /var/lib/kvmd/msd
```

`storagemedia=emmc` is the one to look at: it is U-Boot reporting which branch
of that hardcoded `root=` it took, so it confirms the whole chain at once. If
it says `sd`, the card is still in the slot.

## What was on the eMMC before

Worth recording, because it is what a board arrives with and it is gone the
moment you install over it:

```
sector 64     Rockchip idbloader (encrypted IDB, magic 0xFCDC8C3B)
sector 8192   "PARM" parameter block - FIRMWARE_VER:8.1, MACHINE:3399,
              and an mtdparts= line describing an Android layout
              (uboot, trust, misc, resource, kernel, boot, recovery,
              backup, security, cache, system, metadata, vendor, oem,
              frp, userdata)
sector 16384  "LOADER"
sector 24576  "BL3X"
```

No GPT anywhere — the partition table *is* that parameter block, which is why
`lsblk` shows a 14.6 GB disk with no partitions on an untouched board. There
is no copy of it in this repository and Orange Pi does not publish one as a
plain file, so treat installing over it as one-way.

## Going back to a card

Put one in and power on. The eMMC's BSP U-Boot picks the card up and hands
over to it, and the eMMC install sits there untouched until the card comes out
again. Two PiKVM installations on one board do not collide, which is the whole
point of the GUID split.

This works because the eMMC is running the same BSP U-Boot the card is. It is
not a property of the board.
