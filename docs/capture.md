# HDMI IN: EDID, modes, and mode changes

The capture chain is TC358749 → MIPI D-PHY → rkisp1, and the node ustreamer
opens (`/dev/kvmd-video`) is the **ISP main path**, not the receiver. That one
fact explains most of what is unusual here compared with a PiKVM V2, where the
capture device *is* the TC358743.

Consequences you will run into:

* The capture node's format list is the ISP's (YUYV / 422P / NV16 / NV61 /
  NV12 …) and contains **no UYVY**. The bridge does send UYVY over CSI, but
  that is the ISP's *input* format on its sink pad. `main.yaml` therefore says
  `--format=yuyv`, not the `uyvy` a Pi uses.
* The receiver is a subdev two hops upstream, and its number is not stable
  across boots. `99-kvmd.rules` creates `/dev/kvmd-video-bridge` for it,
  matched on `KERNELS=="1-001f"` plus `ATTR{name}=="*tc35874x*"`.

## EDID

**The EDID is what decides everything a source will offer you.** The receiver
is not the constraint: `tc35874x_timings_cap` is 1–10000 pixels each way, up
to 310 MHz, with CEA861 | DMT | GTF | CVT all set.

`overlay/etc/kvmd/tc358743-edid.hex` replaces kvmd's default. It is the vendor
driver's two blocks concatenated, plus established timings. Why not kvmd's:
its default prefers 1280x720p60 and its CEA block carries no VIC 16, so
1080p60 is reachable only through the GTF/CVT ranges. This one's preferred
detailed timing is 1080p60 and its CEA block lists VIC 16 as native — the only
mode this capture path has been validated at. Both carry an LPCM audio block.

Two defects were fixed on the way here, and both are worth knowing about:

* **The driver writes only its base block.** `EDID_1920x1080_60[]` says at
  byte 0x7e that one extension block follows, but the driver never writes
  `EDID_extend[]`, which sits right next to it in the same file. A source that
  reads block 1 gets whatever the DDC returns past 128 bytes, with a checksum
  that does not match.
* **The established timings were all zero.** Bytes 0x23–0x25 unset and the
  standard timings unused meant the base block offered exactly two modes:
  1920x1080p60 and 1280x720p60. Everything else (640x480, 480p, 576p) lived
  only in the CEA extension, and 800x600 / 1024x768 / 720x400 were nowhere at
  all. Plenty of firmware reads only the base block, so **to a BIOS this
  receiver looked like a two-mode display.**

The shipped file sets `0x23 = 0xAF` and `0x24 = 0xED`, which puts 720x400@70
(the VGA text mode firmware falls back to), 640x480@60/72/75,
800x600@56/60/72/75, 832x624@75, 1024x768@60/70 and 1280x1024@75 into the base
block where legacy firmware looks. The preferred timing is still the 1080p60
DTD, so anything reading the whole EDID still picks 1080p60. `edid-decode`
passes both blocks with no warnings.

Confirmed from a connected Linux target's own mode list: 1920x1080 (six
rates), 1280x1024, 1280x720, 1024x768 (60 and 70 only — exactly the bits set),
832x624, 800x600 (four rates), 720x576, 720x480, 640x480 (six), 720x400.

To go back to kvmd's default:

```sh
kvmd-edidconf --import-preset v2 --device=/dev/kvmd-video-bridge --apply
```

Patch 0011 forwards `VIDIOC_G_EDID` / `VIDIOC_S_EDID` from the capture node to
the bridge, so `kvmd-edidconf --apply` works on its own default device with no
`--device` flag. The udev symlink is belt-and-braces — but keep it, because it
is what you want when poking the receiver by hand.

## Following a mode change

Works end to end. Switching a target from 1080p60 to 1080p30:

```
CAP: Got V4L2_EVENT_SOURCE_CHANGE: Source changed
CAP: Capturing stopped
CAP: Detected DV-timings: 1920x1080p30.00, pixclk=74250000, vsync=45, hsync=280
CAP: Capturing started
```

Event, teardown, re-query, restart in about 1.5 s. `online` never drops and
the ISP logs no errors. This needs patch 0007 (the capture node implements
none of the DV-timings ioctls or the source-change event on its own) and the
`--dv-timings` flag in `main.yaml`.

Two traps when testing this:

* **`tc35874x_format_change` fires on the transient as well as the settled
  reading.** A switch produced `1920x123p60.00` and `1920x17p60.00` tens of
  milliseconds before landing on the right numbers. The horizontal count stays
  correct throughout, which is what identifies them as half-finished DE
  measurements rather than real modes.
* **Changing the resolution in Windows is not a test of this.** With GPU
  scaling on — the default for a non-native mode on an external display — the
  desktop is scaled and the link stays at the EDID's preferred timing. A dozen
  resolution changes produce a dozen `1920x1080p60` re-locks and nothing else.
  **Change the refresh rate instead**; scaling cannot fake a 74.25 MHz pixel
  clock.

## Low-resolution modes

Arriving at a low-resolution mode used to give green bands with the picture
sheared across them at 1024x768p60, while 1024x768p70 was clean. That is a CSI
FIFO underrun in the bridge: the vendor driver's FIFO level table covers
1080p60 and 720p60 and leaves every other mode on a flat 300, which is below
what pixel clocks under roughly 70 MHz need.

Patch 0012 computes it from the mode instead. Verified at 1024x768p60:
FIFOCTL programs to 337, and 30 frames capture with zero zero-filled bytes,
against 24% before. See docs/known-issues.md for what is still unverified.

## The colour path is unity

Worth knowing before chasing a colour bug that is not there. The whole ISP
colour path was read back live: cross-talk matrix identity, AWB gains 0x100
(= 1.0), and BLS, LSC, gamma-out and CPROC all disabled.

A dark capture is almost certainly the source. One that looked like a hardware
fault measured as `out = 16 + 0.2 × (in − 16)` — white scaled, but the
limited-range black point left at exactly 16. A gain anywhere in the ISP would
have pulled black down with it; preserving black while crushing white is a
compositing operation in display space, i.e. a UI dim overlay. It was a
screensaver.

**The bridge's internal colour-bar generator is not usable as a test pattern.**
Setting `CONFCTL` YCBCRFMT to `COLORBAR` (0x0cd4 → 0x0c94) produces no frames
at all — `VIDIOC_DQBUF` blocks indefinitely, zero bytes, zero errors.
