# Known issues and limitations

What this board does not do, or does with a caveat. Everything here is
measured on hardware rather than assumed. The debugging that produced these
conclusions is not in this repo; what survived it is.

## HDMI IN audio does not work

There is a sound card — patch 0001 enables `i2s0`, binds the ALC5651 and
builds a `simple-audio-card` named `tc358743`, which is the device kvmd's
stock janus config already opens. It captures **silence**.

The receiver is extracting audio correctly (`audio_present` reads 1 while the
target plays). The problem is the board's wiring:

```
TC358749  --I2S-->  ALC5651 port 2        (receiver is master)
RK3399 i2s0 <----->  ALC5651 port 1        (SoC is master)
```

The two buses never meet. Any route from HDMI IN to the SoC has to cross the
codec's internal Stereo2 DAC, and that block does not run — setting the codec
as I2S2 master raises the ADC noise floor from ±1 to ±48, which is the
signature of a block waiting for a clock that never arrives. `I2S_CLK_HDMIIN`
lands on test point TP50271 and nowhere else.

Everything on the SoC side was proved good by measurement: codec→SoC works,
and SoC→codec→SoC carries a 1 kHz tone at peak 29262 through DAC L1 → DD MIXL
→ Stereo1 ADC. Three implementation routes were evaluated (a vendor-style AIF2
`dai_link`, the digital loopback, and `audio-graph-card2` codec-to-codec) and
all three sit downstream of the same missing clock.

**Parked.** The next step is physical — a scope on the ALC5651's pins 28 and
29 while the target plays audio — not more code. The device tree description
is kept rather than deleted because it is correct and was expensive to
establish.

There is no UAC2 gadget function either, so audio *to* the target is out of
scope entirely.

## Wi-Fi cannot see DFS channels

The AP6356S works — mainline `brcmfmac`, associates, gets DHCP, survives a
reboot. But the BCM4356 firmware **does not scan 5 GHz DFS channels (52–144)
in station mode**, so an AP on channel 100–144 is invisible no matter what the
regulatory domain says.

Diagnosed rather than guessed: with `country TW` and channels 100–144 enabled,
three full scans found nothing in 5250–5730 while 5220, 5785 and 5825 returned
networks every time. `iw phy0 channels` shows the DFS channels with `Radar
detection` and **no `Channel widths` line at all**.

Use 36–48 or 149–165. This is firmware behaviour and there is nothing to fix
on this side. `overlay/etc/wpa_supplicant/README` has the details and the
two `iw reg set` traps that go with it.

Wi-Fi is also deliberately not enabled by default: a `wpa_supplicant` with no
network block fails at boot, and most of these boards will only ever use the
wired port. `wlan.network` sets `RouteMetric=2048` so ethernet stays preferred.

## `vcgencmd` noise

kvmd's health module polls `vcgencmd get_throttled` every `info.hw.state_poll`
seconds. There is no VideoCore here, and kvmd cannot be told to skip the probe
— both the "command failed" and "did not parse" paths log before returning
`None`. Unmitigated that is ~17,000 journal lines a day on a board whose
rootfs is an SD card.

`overlay/usr/lib/pikvm/vcgencmd` answers `throttled=0x0` and `override.yaml`
points `info.hw.vcgencmd_cmd` at it. **Read that value as "this SoC has no
Raspberry Pi-style power reporting", not as a health guarantee.** RK3399 does
throttle, through its own thermal zones, which kvmd would not understand.

## Non-fatal boot messages

All three are cosmetic and expected:

* `dwhdmi-rockchip: error -ENXIO: IRQ index 1 not found` — the
  mainline-derived HDMI node has one interrupt; the BSP driver wants two.
* `hdmi-sound` deferred with `asoc-simple-card: parse error` — no HDMI audio
  *output*. Unrelated to HDMI IN audio above.
* `failed to parse resources for logo display` — the vendor U-Boot splash
  handoff, which this image does not use.

## ATX power control ships disabled

The GPIO assignment is settled from the vendor schematic and this tree's
device tree rather than guessed (see docs/hardware.md), but the optocouplers
do not exist on this board, so nothing is wired up.

Note for anyone enabling it: **kvmd's four Raspberry Pi defaults are BCM pin
numbers and mean something else entirely here.** Two of them collide with the
RK3399's Bluetooth UART.

## The receiver got stuck once

Seen once and never reproduced: the bridge sat at status `0x0b` with TMDS
present and `PHY_PLL` never setting, surviving a PHY reset, an EDID revert and
a full HPD cycle, and clearing only on a reboot. A dozen later transitions all
recovered on their own, including a full DDC5V drop and return.

A plausible mechanism was found afterwards. The device tree had declared the
bridge's interrupt `IRQ_TYPE_LEVEL_LOW` while `tc35874x_probe()` requests it
with `IRQF_TRIGGER_HIGH`. On a cold boot `request_irq()` wins and the
interrupt works, but the two agree only by accident, and re-mapping the same
hwirq with the other type fails:

```
irq: type mismatch, failed to map hwirq-12 for gpio@ff780000!
```

A bridge with no interrupt cannot report that the source came back — which
fits "recovers on nothing but a reboot" exactly. Patch 0001 now says
`LEVEL_HIGH`, and also changes the same pin from `pcfg_output_high` to
`pcfg_pull_none`, since it was being driven as an output while used as an
interrupt input.

**Not proven** — the original event was never reproduced — but it is the only
mechanism found that fits.

## Modes not yet verified

Patch 0012 sizes the bridge's CSI FIFO from the mode, replacing a vendor table
that covered 1080p60 and 720p60 and left everything else on a flat 300. That
is verified at 1024x768p60 (FIFOCTL 337, zero zero-filled bytes over 30
frames, against 24% before). **800x600p60 and 720x400p70 are unverified** —
the formula says the old table under-served them too, so they should have been
broken before and clean now, but nobody has looked.

## Deliberately not done

**Read-only root.** Considered and declined. The wear mitigations that are in
place instead — journal to RAM, `commit=600`, MSD mounted `ro` except during
writes — are in docs/image-layout.md.

**Mainline U-Boot.** See docs/roadmap.md.
