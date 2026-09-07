# The patches, and why each one exists

Thirteen kernel patches, one U-Boot patch and two userspace ones. They are
applied in filename order by plain `git apply` — no fuzz, no `--3way` — so a
patch either applies or the build stops.

They are not all the same kind of thing, and the split is deliberate:

| | | |
|---|---|---|
| **0001** | this board's device tree | ours; will never be upstreamed |
| **0002** | MMC node names | ours; works around the vendor U-Boot |
| **0003–0012** | driver fixes | bugs anyone on this hardware hits. One fix per patch, so they stay submittable |
| **0013** | codec rail voltages | a defect the upstream DTS has too — mainline's copy of this board file is byte-for-byte identical |
| **uboot/0001** | autoboot delay and console rate | two defconfig lines; the difference between a debuggable board and one you can only recover over USB |
| **libv4l-rkmpp/0001–0002** | userspace | applied inside the rootfs build |

If you add one, keep that distinction. A patch that mixes a board choice with
a driver fix cannot be sent anywhere.

## 0001 — dts: describe this board

Four patches used to live here — board bring-up, the VPU nodes, the Wi-Fi
board type and the audio card. They are one patch now, because they are all
board *configuration* rather than fixes, none of them is upstreamable, and as
four diffs on one file they bought nothing but a fixed apply order and four
sets of context that shifted whenever any of them changed.

* **`rockchip,pwm_id` / `rockchip,pwm_voltage` on vdd_log.** The BSP U-Boot
  programs this PWM rail from the *kernel's* device tree. Without them it
  cannot compute the duty cycle, settles on the wrong voltage, and the board
  browns out and resets before reaching the kernel - silently, with no error,
  because it is a power event and not a crash.
* **`regulator-init-microvolt` on LDO_REG4 (vccio_sd).** Same consumer: the
  SD card's I/O rail, which the 4.4 tree brings up at 3.0 V.
* **No `stdout-path`.** U-Boot honours it and hangs inside `initr_serial`
  rebuilding its console around it. The 4.4 tree has none. `bootargs` is for
  Linux and stays; only `stdout-path` has to go.
* **`bootargs` restored.** Removing the whole `chosen` node along with
  `stdout-path` took the console with it, and the kernel then booted in total
  silence on both serial and HDMI. The two properties serve different
  consumers and only one is the problem.
* **`aliases { mmc0/mmc1 }` and `broken-cd`.** Ordering and card detection.
  The numbering matches what U-Boot already reports: SD is 1, eMMC is 0.
  Note the aliases are **edited in place**, not added as a second `aliases`
  node. dtc merges two of them, and the merge kept mainline's
  `mmc2 = &sdhci` next to the new `mmc0 = &sdhci`, so the eMMC answered to
  two sequence numbers while `sdio0` was left with none:

  ```
  mmc0 = "/sdhci@fe330000";
  mmc1 = "/dwmmc@fe320000";
  mmc2 = "/sdhci@fe330000";     <- same node twice
  ```

  U-Boot takes the first match and booted anyway. `sdio0` needs no alias of
  its own - it carries no block device.
* **`console=ttyS2,115200n8`.** 1500000 reads fine, but the header has no
  flow control and the UART overruns on a burst into the board; measurements
  are under uboot/0001. Previously recorded here as "writes corrupt on this
  wiring; a console you cannot type on is not a console.
* **CPU rates pinned** (`ARMCLKB` 1.2 GHz, `ARMCLKL` 816 MHz) because
  cpufreq is off - see below. **The whole of rk3399.dtsi's `&cru`
  `assigned-clocks` list is restated alongside them**, because a property
  assigned in an override node replaces the .dtsi's rather than merging with
  it. An earlier version of this node listed only the two ARM clocks and so
  silently deleted the other seventeen, leaving CPLL in slow mode at 24 MHz
  and `aclk_isp0`/`aclk_vio` at 12 MHz. Nothing failed loudly; the ISP just
  could not write frames fast enough. See docs/patches.md, 0001 (clocks).
* **HDMI IN**: `ext_cam_clk`, `hdmiin_gpios` pinctrl, `tc358749x@1f`, and the
  graph through `mipi_dphy_rx0` to `rkisp1_0`.
* **`interrupts = <RK_PB4 IRQ_TYPE_LEVEL_HIGH>`**, because that is what the
  driver asks for: `tc35874x_probe()` requests the irq with
  `IRQF_TRIGGER_HIGH`. With `LEVEL_LOW` the two disagree and `request_irq()`
  wins, so a freshly booted board looks fine - the mapping is created from
  the property, then immediately reprogrammed. The disagreement only shows on
  a rebind, where the second `of_irq_get()` finds a live mapping of the other
  type:

  ```
  irq: type mismatch, failed to map hwirq-12 for gpio@ff780000!
  ```

  (hwirq 12 is gpio2 RK_PB4.) The bridge then has no interrupt, the CSI link
  never comes back, and only a reboot clears it. This is the likeliest
  explanation for the one unexplained stuck receiver in docs/known-issues.md.
* **RK_PB4 is `pcfg_pull_none` in `hdmiin_gpios`, not `pcfg_output_high`.**
  It is the interrupt line named in the property above; the group had it
  driven as an output at the same time. It worked only because
  `rockchip_irq_set_type()` clears the line's `port_ddr` bit and turns it
  back into an input behind pinctrl's back - visible on the board as
  `gpio-76 ( |interrupt ) in lo IRQ` rather than `out hi`.
* **`link-frequencies = 372600000`**, matching what the PLL is actually
  programmed to. See 0005 - and the trap in 0012 for why leaving it at
  297 MHz was not merely cosmetic.

### The VPU nodes

Nothing was missing. The drivers were compiled in from the start —
`CONFIG_ROCKCHIP_MPP_SERVICE=y`, `CONFIG_ROCKCHIP_MPP_VEPU2=y`,
`CONFIG_ROCKCHIP_IOMMU=y` — and roadmap.md has said so since the H.264
survey. What no one checked is that every node those drivers bind to
inherits `status = "disabled"` from `rk3399.dtsi`, and this board's DTS
never turns them on:

```
mpp-srv        rockchip,mpp-service      disabled
vepu@ff650000  rockchip,vpu-encoder-v2   disabled
iommu@ff650800 rockchip,iommu            disabled
```

So the board came up with no `/dev/mpp_service` at all, and every piece of
MPP userspace — `mpi_enc_test`, `libv4l-rkmpp`, gstreamer's `mpph264enc` —
would have failed at `open()`. The `/opt/rkmpp` variant has been shipping a
built, working userspace against a kernel with nothing listening. Step 1 of
`try-h264.sh`, the step the whole H.264 decision was supposed to hinge on,
could only ever have printed "no kernel side to talk to".

Rockchip does this enabling in `rk3399-linux.dtsi`, which is included by
their board files and not by ours.

#### Which of the two VPU bindings

`rk3399.dtsi` describes the same registers twice, both disabled, and only
one may be enabled:

| node | compatible | driver |
|---|---|---|
| `video-codec@ff650000` | `rockchip,rk3399-vpu` | mainline `hantro` |
| `vepu@ff650000` | `rockchip,vpu-encoder-v2` | Rockchip MPP service |

This takes the MPP one. `hantro` has no H.264 encoder at all —
`hantro_h1_jpeg_enc.c` is its only encoder and everything else in the driver
decodes — so the mainline node cannot do the job the patch exists for.
`CONFIG_VIDEO_HANTRO` is not set in our config anyway, so the mainline node
had no driver behind it either way.

#### Encode only, deliberately

`vdpu`, `rkvdec`/`vdec_mmu` and `iep`/`iep_mmu` stay disabled. A KVM encodes
the captured screen and never decodes anything; enabling them brings up two
more power domains and another IOMMU at boot for nothing. Turning them on
later is three more `okay` blocks — `rk3399-linux.dtsi` is the reference for
what a full set looks like.

The one thing worth knowing before doing that: `rk3399.dtsi` sizes the MPP
service for two consumers (`rockchip,taskqueue-count = <2>`,
`rockchip,resetgroup-count = <2>`) and `vepu` and `vdpu` share taskqueue and
reset group 0. `mpp_service.c` creates the queues from the count regardless
of who registers, so a queue with no members is one idle kthread, not an
error.

#### What it settled

Both questions it was written to make answerable. `/dev/mpp_service` appears,
VEPU2 encodes, and ustreamer drives it through `LD_PRELOAD` for both codecs -
MJPEG since `libv4l-rkmpp/0001`, H.264 since `0002`. Choosing the MPP binding
over mainline `hantro` is what made the second half possible at all: hantro
has a JPEG encoder and nothing else.

### The Wi-Fi NVRAM board type

One property, `brcm,board-type = "AP6356S"`, on the `wifi@1` node.

brcmfmac loads two files per chip: the firmware, `brcmfmac4356-sdio.bin`, and
a per-board NVRAM blob that carries PA gains, antenna configuration and the
country code. It finds the second by board type, and with no `brcm,board-type`
it falls back to the root compatible - so it would ask for
`brcmfmac4356-sdio.xunlong,rk3399-orangepi.txt`, which no linux-firmware
release ships.

linux-firmware does ship `brcmfmac4356-sdio.AP6356S.txt`, and it is what
every other RK3399 board with this module ends up loading: `firefly-rk3399`,
`nanopc-t4`, `nanopi-m4` and `vamrs,rock960` are all symlinks to that one
file upstream. This board is simply not one of the ones a symlink was added
for. A board-type is the documented way to say so from the device tree, and
it keeps the fix in the tree we already patch rather than in a rootfs file
whose only content would be a symlink.

### HDMI IN audio

Device tree only. Enables `i2s0` on the stock `i2s0_2ch_bus`, adds the
ALC5651 on i2c1 at 0x1a under the mainline `realtek,rt5651` binding, and
hangs a `simple-audio-card` called `tc358743` off the pair.

The first version of this patch described a different board. It enabled
`i2s0` as a **slave** on a hand-rolled three-pin group, because the receiver
was thought to drive the SoC's I2S directly. Sheet 25 of the schematic says
otherwise once you look at it as a picture rather than as a text dump:

```
TC358749  --I2S-->  ALC5651 port 2   (DACDAT2/LRCK2/BCLK2, receiver masters)
RK3399    --I2S-->  ALC5651 port 1   (via R7107..R7112, SoC masters, incl. MCLK)
```

`I2S0_SCLK_HDMIIN` and `I2S0_SCLK` are different nets that never meet. So:

**The SoC is the master**, not the slave - `bitclock-master` and
`frame-master` point at the *cpu* node.

**Six pins, not three.** `i2s0_2ch_bus` already covers SCLK, LRCK_RX,
LRCK_TX, SDI0, SDO0 and GPIO4_A0/`I2S_CLK`. That last one is the codec's only
MCLK source; the old patch deliberately left it out on the theory that the
receiver drove the same net, which was the same mistake inverted. There is no
reason to define a group by hand.

**A real codec, not `linux,spdif-dir`.** The stub made sense only while the
receiver was believed to be on the far end. The ALC5651 answers 0x6281 at
register 0xff, which is what `rt5651_i2c_probe()` requires, so the mainline
driver binds it unchanged.

**A `Microphone` widget named `HDMIIN` routed to `"AIF2 Playback"`.** Nothing
binds `rt5651-aif2` to a dai_link, so that DAI widget has no incoming DAPM
path; the walk back from `AIF1 Capture` through `IF2 DAC` finds no endpoint
and the loopback stays powered down. The widget supplies one. The vendor 4.4
machine driver `rockchip_rt5651_tc358749x.c` does exactly this, for exactly
this reason.

The card is still called `tc358743` although the part is a TC358749 - and on
this board the card is really the ALC5651. That name is an interface, not a
description: it is what kvmd's stock janus config asks for. Naming it
accurately would have meant editing `janus.plugin.ustreamer.jcfg` in the
image build, and that is a pacman backup file - an upstream change to it
lands as a `.pacnew`, and merging that the usual way would silently drop the
edit and take WebRTC audio with it, with no error from janus.

No kernel config change: `SND_SOC_ROCKCHIP_I2S`, `SND_SOC_RT5651` and
`SND_SIMPLE_CARD` were all already `=y` in the vendor defconfig.

**Run on hardware, and it does not finish the job.** The card registers, the
PCM opens, the DAPM chain powers up end to end, and capture returns silence
because the codec's Stereo2 DAC never gets a clock from the receiver. Apply
0013 before drawing any conclusion from this - without it the codec's I2C is
unreliable and every DAPM register write fails. docs/known-issues.md has the
measurement and why none of the three routes evaluated changes the outcome.

The patch stays in the series anyway. It is the substrate any future attempt
needs, and the card it creates is inert: janus opens `hw:tc358743,0` only
when a WebRTC client asks for audio and then gets silence rather than an
error, and `/proc/asound/card0/pcm0c/sub0/status` reads `closed` otherwise.
No log spam, no measurable CPU. Audio work is parked until someone puts a
scope on the ALC5651's pins 28 and 29.

It does not carry sound; see docs/known-issues.md. The description is kept
because it is correct and was expensive to establish.

## 0002 — MMC node names

Renamed `mmc@fe320000`/`mmc@fe330000` to `dwmmc@`/`sdhci@` to match the
names in U-Boot's own device tree. `init_kernel_dtb()` calls `dm_scan_fdt()`
on the kernel DTB while its own devices are still bound; differing names make
it bind a second device for the same controller, and the two then fight:

```
Device 'mmc@fe320000': seq 1 is in use by 'dwmmc@fe320000'
Could not get mmc 1
```

at which point U-Boot cannot read the card it is booting from. Linux binds on
compatible, not node name, so the rename costs nothing.

## 0003 — the one that mattered most

`rk808-regulator` was missing from `rk8xx_regulator_id_table`.

`platform_match()` returns the id_table result and never falls back to name
matching when a driver has an id_table:

```c
if (pdrv->id_table)
    return platform_match_id(pdrv->id_table, pdev) != NULL;
/* fall-back to driver name match */   <- unreachable
```

So the RK808 regulator driver never bound, silently, with no error. Eleven
devices deferred forever behind it: the SD card (`vqmmc regulator not
available`), ethernet PHY, saradc, display-subsystem, cpufreq.

Mainline's version of this driver has **no id_table at all** and matches by
name, which works. Rockchip added the table for their RK805/809/816/817/818
and left the original chip out of it. It survives because `develop-6.12`
targets RK3588, which uses a different PMIC and a different driver entirely.

This one is upstreamable - to Rockchip, not mainline.

## 0004 — rkisp1: reset the capture crop on `VIDIOC_S_FMT`

`drivers/media/platform/rockchip/isp1/capture.c`

`stream->dcrop` is written in exactly two places: `VIDIOC_S_SELECTION`, and
once at async-complete by `_set_pipeline_default_fmt()`. That second one seeds
it from whatever the sensor reported at that moment, clamped to
`CIF_ISP_INPUT_W_MIN`/`CIF_ISP_INPUT_H_MIN`:

```c
#define CIF_ISP_INPUT_W_MIN  32
#define CIF_ISP_INPUT_H_MIN  16
```

For a camera sensor that is harmless — it reports a real size at probe time.
An HDMI bridge does not: it has no format until a source is plugged in and the
timings are detected, so the seed is the clamp itself, 32x16, and nothing ever
moves it again. `VIDIOC_S_FMT` does not, which is both the bug and a spec
violation — S_FMT is defined to reset the selection rectangles to defaults.

The failure is silent. Capture "works": buffers are dequeued at the right frame
rate and the right size. But the ISP is asked to crop to 32x16 and then upscale
roughly 40x back, far outside what the resizer can do, and every frame comes
back solid black.

```
rkisp1: stream 0 crop: 1280x720 -> 32x16
rkisp1: stream 0 rsz/scale: 32x16 -> 1280x720
```

Verified from userspace before writing the patch: `--get-selection` returned
32x16, and setting it to the full frame made the resizer drop out of the
pipeline entirely (`stream 0 crop disabled`).

## 0005 — tc35874x: advertise the link frequency the PLL actually uses

`drivers/media/i2c/tc35874x.c`

The Rockchip MIPI D-PHY has no way to measure its input. It reads
`V4L2_CID_LINK_FREQ` from the sensor, doubles it, and uses the result to pick
an hsfreqrange bucket for its HS receiver. So that control is not informational
— it is the receiver's tuning.

Read back from the chip while running: `PLLCTL0 = 0x4089` → prd 5, fbd 138 →
27 MHz / 5 × 138 = **745.2 Mbps per lane**. The driver advertised 310 MHz,
i.e. 620 Mbps, putting the receiver in the 600–650 Mbps bucket while the
transmitter ran 20% faster.

This is a 6.12 regression, and the diff against 4.4 shows how it happened:

| | 4.4 (vendor) | 6.12 |
|---|---|---|
| `set_pll` 4-lane override | none — probe-derived 594 Mbps | prd 5, fbd 138 → 745.2 Mbps |
| `set_csi` HS timing counters | REF_02 defaults for 594 Mbps | retuned set |
| `link_freq_menu_items[0]` | 310 MHz | 310 MHz (**not updated**) |

Rockchip raised the link rate and retuned the *transmitter's* timing counters
to match, but left the one constant that tells the *receiver* what to expect.

The patch sets it to 372.6 MHz. It is still wrong for the interlaced / ≤33 fps
case, which `set_pll()` runs at prd 2, fbd 65 = 877.5 Mbps; fixing that
properly needs a two-entry menu and an index selected in `set_pll()`, which
raises a ctrl-handler locking question (the existing call site uses the
lock-held `__v4l2_ctrl_s_ctrl` variant). Deliberately left for later rather
than guessed at.

The patch also changes how the control is *set*. `V4L2_CID_LINK_FREQ` is an
integer menu, so its value is an index, but the vendor code passed the
frequency:

```c
__v4l2_ctrl_s_ctrl(state->link_freq, link_freq_menu_items[0]);   /* 372600000 */
```

That works only because the menu has one entry and the core clamps to
`max`, which is 0. Add the second entry the paragraph above calls for and it
becomes a silent wrong-entry selection - so the call now passes `0`.
Behaviour today is identical; the landmine is gone.

Verified on hardware: `data_rate_mbps` goes 620 -> 745, the per-frame
`CIF_ISP_PIC_SIZE_ERROR` storm stops, and captured buffers contain real video
instead of zeros.

## 0006 — rkisp1: refresh the IOMMU after the CIF soft reset

`drivers/media/platform/rockchip/isp1/rkisp1.c` (plus a `is_mmu` flag in
`dev.h`/`dev.c`)

`rkisp1_isp_stop()` ends with `writel(CIF_IRCL_CIF_SW_RST, base + CIF_IRCL)`,
which resets the whole CIF block — including the ISP's own MMU. `DTE_ADDR` goes
to 0, paging turns off, MMU interrupts are masked, and nothing turns them back
on. Only the first stream-on after boot ever delivered pixels.

Nothing about it looks like a DMA problem: buffers dequeue at full frame rate
with `bytesused` set, interrupt counts match a working stream, `ISP_ERR` stays
0, and every ISP/MI/D-PHY/bridge register reads byte-for-byte the same. The
MMU registers are the only difference, and the MMU interrupt that would have
said so was masked by the same reset.

Every other Rockchip media driver here already does the refresh after that exact
write, with the same comment: `isp/hw.c`, `ispp`, `cif`, `vpss`, `fec`, `aiisp`.
isp1 was missed.

Only runs in process context — `rockchip_iommu_enable()` polls with
`readx_poll_timeout()`, which sleeps, so the ISR error path in `rkisp1_isp_stop()`
is deliberately left alone and a stream started after one of those is still
blank.

Verified: five consecutive 1920x1080 streams, `nonzero 82944000/82944000`,
zero errors, where previously only the first worked.

## 0007 — rkisp1: forward DV timings and source-change events

`drivers/media/platform/rockchip/isp1/capture.c`, `dev.c`, `dev.h`

On a Raspberry Pi PiKVM the capture node *is* the TC358743, so ustreamer's
`--dv-timings` talks to it directly and the stream follows a target that
switches video mode. Here the capture node is the ISP main path, three
entities downstream, and it implemented none of it:

```
CAP: Failed to query DV-timings, trying QuerySTD ...
CAP: Can't subscribe to V4L2_EVENT_SOURCE_CHANGE: Inappropriate ioctl for device
```

The patch forwards all five DV-timings ioctls to the bridge, and relays
`V4L2_EVENT_SOURCE_CHANGE` from the subdev to the capture nodes via
`v4l2_dev->notify`. `S_DV_TIMINGS` also re-reads the sensor format and re-runs
the pipeline defaults, so the ISP pads and the MP/SP sizes follow the new
timings — the work that otherwise needs media-ctl before every stream.

Two traps, both of which look like "ioctl not implemented" from userspace:

* The async subdev bound to the ISP is the **MIPI D-PHY**, not the bridge —
  `dev->sensors[0].sd` is one hop short. Forwarding to it returns
  `-ENOIOCTLCMD`, which the core reports as ENOTTY. The patch walks the media
  graph upstream to the first subdev that actually implements DV timings.
* `-ENOIOCTLCMD` is 515. `echo 3 > /sys/class/video4linux/video0/dev_debug`
  showing `error -515` is what distinguished "not wired up" from "wired up but
  aimed at the wrong subdev".

Verified: ustreamer reaches `CAP: Capturing started` at 1920x1080 YUYV, kvmd
reports `online=true, captured_fps=60`, and `/api/streamer/snapshot` returns a
52 KB 1920x1080 JPEG over HTTPS.

## 0008 — usb: f_mass_storage: per-LUN CD-ROM inquiry string

`drivers/usb/gadget/function/{f_mass_storage.c,storage_common.c,storage_common.h}`

kvmd-otg writes `lun.0/inquiry_string_cdrom` unconditionally and dies if it is
not there:

```
PermissionError: [Errno 13] Permission denied: .../lun.0/inquiry_string_cdrom
```

(EACCES, not ENOENT — writing to a configfs attribute that does not exist looks
like a permissions problem, which sent the first look in the wrong direction.)

Upstream `f_mass_storage` has one `inquiry_string` per LUN. kvmd wants two,
because the same LUN reports as a CD-ROM for ISO images and as a flash drive
otherwise, and some BIOSes only offer to boot from something that identifies as
a real optical drive. The patch adds `inquiry_string_cdrom` alongside it, its
configfs attribute, and makes `do_inquiry()` prefer it while `->cdrom` is set,
falling back to `inquiry_string` and then to the common string.

The DTS half of this — turning the Type-C dwc3 into a peripheral so a UDC
exists at all — is in patch 0001; see docs/patches.md, "Deliberate compromises".

## 0009 — dw-hdmi: don't fail probe without Rockchip's route nodes

`drivers/gpu/drm/bridge/synopsys/dw-hdmi.c`

`get_force_logo_property()` reads one optional boolean out of Rockchip's
vendor-only `display-subsystem/route/route-hdmi` nodes and returns -ENODEV when
they are missing; the caller treats that as a probe failure. A mainline-derived
board dts has no such nodes, so HDMI output could never probe:

```
dwhdmi-rockchip ff940000.hdmi: can't find route
rockchip-drm display-subsystem: failed to bind ff940000.hdmi: -19
```

The patch makes absent nodes mean "no forced logo" — the same answer an
explicitly disabled `route-hdmi` already gave.

Applying this alone made the board stop booting, which took patch 0010 to
explain — with HDMI finally probing, the next bug downstream got reached. See
docs/patches.md, 0009 and 0010.

## 0010 — dw_hdmi-rockchip: guard the optional PHY in late_register

`drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c`

```
Unable to handle kernel NULL pointer dereference at 0x0000000000000340
pc : dw_hdmi_encoder_late_register+0x20/0x68
lr : drm_encoder_register_all+0x5c/0x88
Workqueue: events_unbound deferred_probe_work_func
```

`if (!hdmi->phy->debugfs)` — unguarded. `hdmi->phy` comes from
`devm_phy_optional_get()` and is NULL on SoCs whose HDMI PHY is inside the
controller rather than a separate device; RK3399 is one. The other four uses of
`hdmi->phy` in that file all test it first. 0x340 is
`offsetof(struct phy, debugfs)`.

It presented as a board that never came back from a reboot rather than as a
crash, because the oops happened inside `deferred_probe_work_func`: the
deferred-probe worker died and everything queued behind it, ethernet included,
never probed. The same failure mode already recorded for the cpufreq oops —
worth remembering as the signature of "board boots, kernel lives, nothing
works".

With no separate PHY there is nothing to hand the debugfs directory to, so the
patch registers it and drops the dentry.

## 0011 — rkisp1: forward the EDID ioctls to the bridge

`drivers/media/platform/rockchip/isp1/capture.c`

The other half of 0007. Everything in PiKVM that touches the EDID —
`kvmd-tc358743.service`, `kvmd-edidconf --apply` — points `VIDIOC_S_EDID` at
`/dev/kvmd-video`, because on a Pi the tc358743 *is* the capture device. Here
that node is this driver's mainpath and the receiver is two hops further up
the graph, so both EDID ioctls came back `ENOTTY` and nothing kvmd did to the
EDID reached the source.

`.vidioc_g_edid` / `.vidioc_s_edid` hand off to the subdev that
`rkisp1_get_sensor_sd()` finds, the same walk 0007 added. `struct
v4l2_subdev_edid` is a `#define` for `struct v4l2_edid` and `->edid` is a user
pointer on both sides, so it is a straight pass-through; only `->pad` needs
zeroing, since the subdev op indexes its own pads and the video node has none.
`S_EDID` refuses while buffers are allocated — setting the EDID drops HPD, and
the source will re-negotiate underneath a running stream.

`determine_valid_ioctls()` gates both on the same `is_vid && is_rx` branch as
the DV-timings ioctls, which 0007 already proved this device satisfies.

Note for whoever adds patch 0012 to this file: 0007 and 0011 both add entries
to `rkisp1_v4l2_ioctl_ops`, which is what broke `apply_patches`' old
per-patch "is it already applied?" check. See `build/scripts/common.sh`.

## 0012 — tc35874x: size the CSI FIFO from the mode

`drivers/media/i2c/tc35874x.c`

1024x768p60 came back as wide green bands with the picture sheared across
them — 24% of every frame zero-filled. Green is what zero-filled YUV turns
into, and the shear is lines that ended early: the bridge's CSI FIFO was
running dry partway through each line.

The FIFO (512 x 32, per `struct tc35874x_platform_data`) sits between the HDMI
receiver and the CSI-2 transmitter, and the transmitter drains it much faster
than the receiver fills it — 372.6 MB/s here against 127 MB/s for a 63.6 MHz
pixel clock. So the bridge buffers part of a line before it starts sending.
Start too early and the tail of the line goes out as zeroes.

Filling at F bytes/s, draining at D, starting after N bytes buffered, the FIFO
lasts `N/(D-F)` seconds and ships `N*D/(D-F)` bytes. For a line of L bytes:

```
N >= L * (D - F) / D          level = N / 4   (32-bit words)
```

The vendor's version is a table — 370 for 1080p60 and 720p60, 350 for
720x576/720x480, 300 for everything else — tuned for the two modes they cared
about. Measured on this board:

| mode | pixel clock | formula | table | result |
|---|---|---|---|---|
| 1920x1080p60 | 148.5 MHz | 194 | 370 | fine |
| 1280x720p60 | 74.25 MHz | 384 | 370 | marginal, passes |
| 1024x768p70 | 75 MHz | 305 | 300 | marginal, passes |
| 1024x768p60 | 63.6 MHz | 337 | 300 | **24% of every frame zero-filled** |
| 800x600p60 | 40 MHz | 314 | 300 | expected to fail |
| 640x480p60 | 25.175 MHz | 276 | 300 | fine |

A FIFOCTL sweep at 1024x768p60 (65 MHz DMT variant) puts the real edge between
316 — 27.8% zero-filled — and 320, against the formula's 333. It errs about 4%
high, which is the direction to err in.

The computed value is a **floor** under the vendor table, never a replacement:
the tuned levels are known good and there is nothing to gain by lowering
1080p60 from 370 to 194. Verified on hardware — 1024x768p60 now programs
FIFOCTL to 337 and captures with zero zero-filled bytes.

### The trap in it

D has to be the rate the PLL is actually programmed to, and the obvious source
for that — `endpoint.link_frequencies[0]`, which probe already reads — is
wrong. The device tree still says 297 MHz, the REF_02 default; patch 0005
found that `tc35874x_set_pll()` programs 372.6 MHz and fixed the *control* to
report it, leaving the property alone. Using the property computes 292 for a
mode that needs 337, which lands under the table's 300 and changes nothing at
all. Nothing warns; the patch simply has no effect. So this uses
`link_freq_menu_items[0]`, the same number the D-PHY is given.

The interlaced and <=33 fps cases are excluded rather than computed:
`set_pll()` runs those at prd 2, fbd 65 — 877.5 Mbps, not the 745.2 the
control advertises — so the arithmetic does not apply and the D-PHY is
mismatched anyway. They keep the vendor's flat 300, which is what they had.

Fixed at the root as of the series audit below: `link-frequencies` in the
bridge's endpoint now says 372600000. Nothing reads it for the D-PHY, and
`pdata.pll_fbd` derived from it is overwritten by `set_pll()`, so it was inert
— but it had misled two patches, and it also happened to make `bps_pr_lane`
come out at exactly the `594000000` that suppresses the driver's own
"untested bps per lane" warning. The D-PHY timing counters really are the
REF_02 594 Mbps values, so that warning *should* fire. It now does.

This patch still reads `link_freq_menu_items[0]` rather than the property.
That is deliberate: the menu is what the D-PHY is given, so it is the one
number guaranteed to describe the link the receiver is tuned for.

## 0013 — dts: give the codec rails their real voltages

Three RK808 LDOs in mainline's `rk3399-orangepi.dts` carry the regulator's
whole adjustable span instead of the board's voltage, and the regulator core
leaves a rail alone when its power-on default already sits inside
`[min,max]`. On this board that default is the bottom of each span:

| rail | as shipped | vendor 4.4 |
|---|---|---|
| `vcca1v8_codec` (LDO_REG7) | 0.8 V | 1.8 V |
| `vcca3v0_codec` (LDO_REG5) | 1.8 V | 3.0 V |
| `vcc3v0_tp` (LDO_REG2) | 1.8 V | 3.0 V |

`vcca1v8_codec` is the ALC5651's supply and also the reference `&io_domains`
uses for the audio IO domain, which covers GPIO3D and GPIO4A - i2s0 and
**i2c1**. Undervolted, the codec probes fine on a single read and then
corrupts sustained traffic: 2000 back-to-back device-ID reads returned
10-20% either NAKed or with bits stuck high (0x6281 arriving as 0x62ff,
0x67ff, 0x7fff), while the TC358749 on the same bus was 2000/2000 perfect.
After the patch the codec is 2000/2000 too.

In the kernel that presented as `-ENXIO` out of `regmap_update_bits()` on
0x61, 0x62 and 0x84 and nothing else - precisely the registers with no entry
in `rt5651_reg[]`, which therefore need a hardware read before the write.
Those are DAPM's power and ASRC registers, so the card built, `amixer`
appeared to work, and nothing was ever powered on.

The other LDOs here are described just as loosely but happen to power on at
the right voltage; pinning them would change nothing measurable, so they are
left alone.

Applies standalone.

## uboot/0001 — an autoboot you can interrupt, at a rate you can type at

Two lines of the vendor's `configs/rk3399_defconfig`.

**`CONFIG_BOOTDELAY=0` → `2`.** The vendor defconfig boots straight through,
so this image had no U-Boot prompt at all — no way to choose a different boot
device, load a kernel over the network, or read a partition back when the
kernel is the broken thing. That is not a theoretical loss. An experiment that
left a non-booting bootloader on the eMMC had no software route back at all,
because the BootROM reads eMMC before it looks at the card (see
[emmc.md](emmc.md)) and nothing in between ever stopped to ask; recovery meant
maskrom mode, a USB-C cable and the MASKROM key.

The stop key is **Ctrl+C**, not any key — this U-Boot is built with
`CONFIG_AUTOBOOT_KEYED`, and it says so:

```
Hit key to stop autoboot('CTRL+C'):  2  1  0
```

`bootcmd` is `boot_android ${devtype} ${devnum};bootrkp;run distro_bootcmd;`
and there is no `boot` command in this build, so `run bootcmd` is how you
continue by hand.

**`CONFIG_BAUDRATE=1500000` → `115200`.** 1500000 is the Rockchip convention
and every RK3399 defconfig ships it, so this is the line that needs
justifying. It comes down to the debug header having three pins.

Measured on this board, a CH341 straight onto the header, 1900 bytes each way:

| | board → host | host → board |
|---|---|---|
| **115200** | 1900 / 1900 | 1900 / 1900 |
| **1500000** | 1900 / 1900 | **1878 / 1900** |

`/proc/tty/driver/serial` says what happened: `oe:2`, and zero framing or
parity errors. The bytes arrive intact and the receiver drops them. Send the
same 1900 bytes in 32-byte chunks 2 ms apart and it is 1900/1900 with the
overrun count unchanged — so the link is clean at 1500000 and what fails is a
sustained burst.

That is structural rather than a fault. `ttyS2` reports
`base_baud = 1500000`: a 24 MHz `uartclk` and a divisor of exactly 1, the
ceiling for this UART, feeding a 64-byte FIFO with no CTS to fall back on
because the header carries TX, RX and ground and nothing else. Anything longer
than a keystroke — a pasted command, most obviously — is a burst. 115200 has
thirteen times the slack and needs no flow control to survive one.

The other thing worth ruling out is the adapter. An RS-232 transceiver in the
path — the common USB-to-RS232 into an RS-232-to-TTL board rig — is specified
to 235 kbps in the SP3232E/MAX3232 family, so 1500000 is well outside its
sheet. That has not been measured here, and at least one person reports that
rig working at 1500000, so treat it as the first thing to swap out rather than
as the explanation.

This supersedes an earlier note in this tree that said the board "corrupts on
write" at 1500000. It does not. The bytes arrive intact — no framing errors,
none — and the receiver drops them when they arrive faster than it drains
them, and only then.

The kernel console was already at 115200 (patch 0001's `bootargs`), so this
also stops the console changing speed halfway through every boot. What still
speaks at 1500000 is `trust.img`, the prebuilt BL31 blob from `rkbin`; its
handful of lines arrive as garbage and are the only thing left that does.

## pikvm.config — kernel options

* `USB_CONFIGFS_F_HID`: the vendor defconfig omits it. Without it there is no
  keyboard or mouse and the KVM is a capture card.
* `VIDEO_ROCKCHIP_RKISP1=y`, `VIDEO_ROCKCHIP_ISP1` off: the tree ships three
  ISP drivers and two of them define `rkisp1_isp_isr`, so enabling both fails
  at link time. We take the vendor one, which the working 4.4 HDMI-IN device
  tree binds to.
* `FRAMEBUFFER_CONSOLE`, `ROCKCHIP_DW_HDMI`, `FB`, `DRM_FBDEV_EMULATION`: the
  vendor defconfig leaves all of these off, so `console=tty1` has nothing to
  render to and HDMI stays black even after a successful boot. During
  bring-up a black screen makes a hung board indistinguishable from a board
  that is running fine but has stopped talking.
* `ARM_ROCKCHIP_CPUFREQ` **=m**, not built in: built in it oopsed during
  deferred probe and took the SD card down with it. As a module, loaded
  after the rootfs is mounted, it works. See below.
* `CFG80211=m`, not `=y`: built in it requests `regulatory.db` during init,
  before the real rootfs is mounted, and there is no retry - so the kernel
  stays on the world domain `00` and `iw reg set` has nothing to select
  from. Paired with `wireless-regdb` in the rootfs package list. Full
  reasoning in the fragment and in docs/known-issues.md.
* `BRCMFMAC=m` with `WL_ROCKCHIP` off: the Wi-Fi module is an AP6356S, a
  BCM4356 on SDIO, and the vendor defconfig drives it with Rockchip's
  `bcmdhd` fork. That driver cannot work on this image, and not for a reason
  a config option can fix - it wants Rockchip's `rfkill-wlan`, which wants a
  `wireless-wlan` device tree node holding `WIFI_REG_ON` and
  `WIFI_HOST_WAKE`. Our DTS is the mainline-shaped one and has the mainline
  arrangement instead - `cap-sdio-irq` and an `mmc-pwrseq` on the SDIO
  controller, and a `wifi@1` child with `compatible = "brcm,bcm4329-fmac"` -
  which is what mainline `brcmfmac` binds to and is also, per CLAUDE.md, the
  code we would rather be running. Nothing in the device tree needed
  changing; only the driver choice was wrong. 0001's `brcm,board-type`
  supplies the one thing that was genuinely missing.

## libv4l-rkmpp/0001 — reach the hardware JPEG encoder

`patches/libv4l-rkmpp/`, applied in `build/docker/Dockerfile.rootfs`.

Six defects stood between ustreamer and the VPU, and none of them was the
encoder. Each is described in the patch header; the shape worth remembering
is that four of the six are things the plugin already implemented and then
refused to let anyone use:

* Every control existed, but only under `VIDIOC_S_EXT_CTRLS`. ustreamer uses
  the older single-control ioctl, got `ENOTTY`, and aborted before it ever
  set a format.
* `V4L2_CID_JPEG_COMPRESSION_QUALITY` was handled, behind a class check that
  rejected the JPEG class it belongs to.
* `V4L2_PIX_FMT_JPEG` was missing from the format table, so the JPEG encoder
  could only be reached by asking for a video stream.
* A compressed format with `sizeimage == 0` was rejected, though V4L2 has the
  driver fill that in and ustreamer only sets it for H.264.

The other two are ordinary bugs: the encoder was configured with the
macroblock-padded size, so 1080 lines were encoded and marked as 1088; and
importing a dma-buf always demanded `PROT_WRITE`, which fails on the
read-only fd that `VIDIOC_EXPBUF` hands out by default.

Measured on hardware, 1080p60 in, static screen, one client:

| | software JPEG | hardware JPEG |
|---|---|---|
| ustreamer CPU | 316% | 76% |
| captured | 47-55 fps | 60 fps |
| delivered | 1 fps | 30 fps |
| worst frame interval | 1629 ms | 52 ms |
| SoC temperature | 78 C | 65 C |
| big-cluster throttle | 5/7 | 0/7 |

Those last three rows are the ones the user actually feels, and two of them
are not the encoder's doing - see the streamer settings in
`overlay/usr/lib/kvmd/main.yaml` and `usr/lib/pikvm/ustreamer-encoder`.
Hardware encoding made the *old* streamer settings wrong: `--workers=1`
serialises the copy with the hardware wait and caps the stream at 19 fps, and
`--drop-same-frames=30` was a bandwidth optimisation priced when a frame cost
three CPU cores.

The last two rows are the interesting ones. The CPU encoder was the board's
main heat source, so removing it also removed the thermal throttling, and the
A72 cluster now runs at 1416 MHz where it previously sat at 816.

## libv4l-rkmpp/0002 — reach the hardware H.264 encoder

Same plugin, same VPU, a separate patch because it shares nothing with 0001
but the file it edits. 0001 made MJPEG work and shipped; this one is about
the H.264 sink that WebRTC and VNC's h264 encoding need.

The encoder itself was never the problem here either - `mpi_enc_test`
produces decodable 1080p on this board, and so does the plugin when Chromium
drives it. What was wrong was the control interface a *stateful* V4L2 client
meets. ustreamer sets seven controls before it touches a format and treats
the first failure as fatal, and four of the seven were wrong:

| control | was | why it mattered |
|---|---|---|
| `H264_I_PERIOD` | rejected if non-zero | ustreamer sets this and never `GOP_SIZE` |
| `H264_PROFILE` | `CONSTRAINED_BASELINE` rejected | the profile WebRTC requires |
| `H264_LEVEL` | stored unconverted | silently marks 1080p as level 1.1 |
| `REPEAT_SEQ_HEADER` | not implemented | and implementing it is what breaks the deadlock |

Two of these are worth more than a table row.

**The level was a silent one.** V4L2 passes an enumerator and MPP wants the
`level_idc` that goes in the SPS. They are unrelated numbers:
`V4L2_MPEG_VIDEO_H264_LEVEL_4_0` is 11, and `level_idc` 11 is level *1.1*.
So a 1080p stream was marked as a level whose limits it exceeds by two orders
of magnitude. Nothing rejects that; a decoder that sizes its buffers from the
SPS gets 99 macroblocks and fails, and one that ignores the SPS is fine. It
would have been found late, on whichever client was strict.

**The deadlock was the interesting one, and it dissolves rather than gets
fixed.** `REPEAT_SEQ_HEADER` means "put the parameter sets in front of every
IDR". Honouring it makes the plugin's out-of-band header redundant, and the
out-of-band header is the whole deadlock:

* the plugin defaults to `separate_header = true`, a Chromium-shaped default
* so on the first pass the encoder thread takes the single CAPTURE buffer,
  fills it with the SPS/PPS, and loops - without releasing the frame the
  client queued on OUTPUT
* ustreamer dequeues OUTPUT before CAPTURE, which is the documented order:
  the input buffer is the one it needs back first
* so ustreamer blocks in `VIDIOC_DQBUF` on a buffer the encoder is holding,
  while the encoder waits for a CAPTURE buffer only the blocked client can
  return

Neither side reports anything. The stream simply never starts. With inline
headers there is no separate-header pass, so the case never arises - and the
separate-header path is still there for clients that ask for it. It is just
no longer what a client gets when it asked for the opposite.

`REQBUFS` honours the requested count exactly (`queue->num_buffers =
reqbufs->count`), so "one buffer per queue" is really one, not a minimum the
plugin rounds up.

## Deliberate compromises

**cpufreq is a module, loaded after the rootfs is up.** It used to be off
entirely. Built in, it oopsed once the RK808 regulators bound and it stopped
deferring:

```
Internal error: Oops: ... pc : rockchip_pll_clk_rate_to_scale+0x54
  rockchip_adjust_opp_table / rockchip_cpufreq_adjust_table
  dt_cpufreq_probe / rockchip_cpufreq_probe
```

The damage was never the lost DVFS. The oops happened inside
`deferred_probe_work_func`, so it killed the deferred-probe worker and
nothing still waiting on it - the SD card included - ever probed. A board
that cannot find its own root filesystem is not debuggable in place.

`CONFIG_ARM_ROCKCHIP_CPUFREQ=m` removes that failure mode by construction.
The driver has no `MODULE_DEVICE_TABLE`; it registers its own platform device
from `module_init`, so nothing autoloads it and the boot path never touches
it. `overlay/usr/lib/modules-load.d/zz-rockchip-cpufreq.conf` loads it from
systemd, on an already-mounted rootfs, where the same oops would cost one
service instead of the machine.

Loaded that way on hardware it does **not** oops. Measured immediately after:

| | pinned (before) | cpufreq (after) |
|---|---|---|
| A53 x4 | 816 MHz fixed | 1416 MHz steady |
| A72 x2 | 1200 MHz fixed | 816-1200 MHz, thermally governed |
| 1080p JPEG encode | 83 ms (A53) / 41 ms (A72) | 51 ms (A53) / 47 ms (A72) |
| cpu-thermal cooling devices | none | `cpufreq-cpu0`, `cpufreq-cpu4` |

Two things that were quietly broken are fixed by the same change. `vdd_cpu_b`
is now driven by the OPP table instead of sitting wherever it booted, so the
1000 mV ceiling that capped the big cluster at 1200 MHz is gone - the
regulator goes to 1500 mV and the 1800 MHz OPP is reachable. And the
`cpu-thermal` zone finally has cooling devices: before this, its only one was
`devfreq-ff9a0000.gpu`, so the 70 C and 85 C passive trips could do nothing
but slow down a GPU that a headless KVM never uses, and the sole real limit
was the 115 C critical trip, which is a hard power-off.

The big cluster now sits at 816 MHz most of the time rather than a pinned
1200. That is not a regression, it is the thermal governor doing a job that
previously nobody was doing: the board idles at 72 C against a 70 C first
passive trip, so it has almost no headroom, and the heat is coming from
ustreamer's software JPEG encoding. Moving that to hardware is what gives the
A72 its clock back. Until then, physical cooling converts directly into CPU
frequency for the first time.

Still =m rather than =y on purpose. "Does not oops when loaded late" is not
evidence that it is safe to probe during boot, and the downside of being
wrong about that is a board that will not boot.

The `assigned-clock-rates` pinning in patch 0001 stays. It is what the
clusters run at between kernel init and systemd loading the module - without
it the A72 comes up at 12 MHz.

An older note here recorded the cause as clk-pll.c's `if (!pll)` after a
`container_of()` being dead code, with the CPU clock's parent not being a
Rockchip PLL. The first half is true and is still a latent bug worth fixing
upstream. The second half does not hold on this tree: `armclkl`'s parent is
`lpll` and `armclkb`'s is `bpll`, both Rockchip PLLs. So the recorded cause
was never confirmed, and since the driver no longer crashes there is nothing
left to reproduce.

---

## Cross-patch consistency

The series is applied by `apply_patches()` in `build/scripts/common.sh`, in
filename order, with plain `git apply` onto a tree reset to HEAD. What that
does and does not guarantee:

* **One hard ordering dependency.** 0011 needs 0007: both add entries to
  `rkisp1_v4l2_ioctl_ops`, and 0011's context contains 0007's. Everything
  else applies standalone to a clean tree. 0013 touches the same board DTS as
  0001 but edits nodes that were already there, so it does not depend on it -
  verified by regenerating both against a clean tree and confirming the
  resulting DTS was byte-for-byte what the old five-patch series produced.
* **0012 depends on 0005 semantically, not textually.** It applies cleanly
  without it and then computes against a 310 MHz link — silently low. There
  is no guard for this beyond the ordering; see "The trap in it" above.
* **0001 is a plain unified diff**, not `git format-patch` output: it has no
  `diff --git` or `index` line, because it is generated by diffing the board
  DTS against `HEAD`'s copy. `git apply` takes it happily; `git apply --3way`
  and `git am -3` will not, since they need a blob hash to merge against.
  That is fine for this series, which is applied with plain `git apply`, but
  regenerate it the same way rather than hand-editing it:

  ```sh
  git -C sources/kernel-rk612 show HEAD:arch/arm64/boot/dts/rockchip/rk3399-orangepi.dts > /tmp/dts.orig
  diff -u --label a/arch/arm64/boot/dts/rockchip/rk3399-orangepi.dts \
          --label b/arch/arm64/boot/dts/rockchip/rk3399-orangepi.dts \
          /tmp/dts.orig sources/kernel-rk612/arch/arm64/boot/dts/rockchip/rk3399-orangepi.dts
  ```

* **The `index` lines are real on the rest.** 0006 and 0007 both used to claim
  `0d0d6fd52..1b0669c4b` for `dev.h`, which is the hash of that file with
  *both* applied — they had been exported from a combined tree. Plain
  `git apply` ignores index lines, which is why nothing ever went wrong, but
  `git apply --3way` and `git am -3` would have merged against the wrong
  blob. All index lines were recomputed by stepping the series and hashing
  each file before and after its own patch; 0002-0012 all apply with `--3way`
  cleanly.
* **`apply_patches()` compares against HEAD, not the index.** `git diff
  --quiet` only sees worktree-vs-index, so a tree whose changes happen to be
  staged — which is exactly what `git apply --3way` leaves behind — looked
  clean, the reset was skipped, and 0001 failed on a file that already
  carried it. `git checkout -- .` has the mirror-image problem: it restores
  *from* the index. Both now name HEAD explicitly, and the index is reset
  afterwards.
