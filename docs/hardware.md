# OrangePi RK3399 — the parts that matter for PiKVM

Everything here was read out of the vendor kernel tree
(`sources/kernel-bsp`, branch `master` = 4.4.179), not from marketing pages.

## HDMI IN

The board's HDMI input is a **Toshiba TC358749XBG**, an HDMI → MIPI-CSI-2
bridge. This is the same class of part PiKVM V2 uses (TC358743), which is why
so much of PiKVM transfers directly.

* 1080p60 capable, **no HDCP** — the chip supports it, the board doesn't
  license it. Sources that insist on HDCP will not be captured.
* I²C address **`0x1f`** on i2c-1, confirmed on hardware. The two vendor
  trees disagreed - 4.4.103 says `0x0f`, 4.4.179 names the node
  `tc358749x@0f` but declares `reg = <0x1f>` - so it was settled by driving
  the power rails from userspace and running `i2cdetect -y -r 1`, which
  answered at `1f`. The vendor's node *name* is the typo.
* The chip is unpowered until its pinctrl drives the rails, so an i2c scan
  finds nothing until the device tree node exists. That is a chicken-and-egg
  worth knowing before concluding the bridge is dead.

### Capture pipeline

```
TC358749XBG  --4-lane MIPI CSI-2-->  mipi_dphy_rx0  -->  rkisp1_0 @ 0xff910000
   (i2c1, 0x0f)                                            -> /dev/video*
```

`link-frequencies = 297000000` → 594 Mbps/lane × 4 lanes ≈ 2.38 Gbps, which is
the 1080p60 UYVY configuration.

### Control GPIOs

From the 4.4.103 DTS, which spells them out individually:

| function      | GPIO       |
|---------------|------------|
| power         | gpio2 6    |
| power 1.8V    | gpio2 9    |
| power 3.3V    | gpio2 5    |
| csi-ctl       | gpio2 10   |
| standby       | gpio2 8    |
| reset         | gpio2 7    |
| interrupt     | gpio2 12   |

The 4.4.179 DTS collapses these to just `reset-gpios` + an interrupt, and
leaves the rails to the regulator framework. The full table is recorded here
because a mainline device tree has to reconstruct it.

## HDMI IN audio

The receiver extracts the embedded audio and puts it out as I2S, and that
port **does not go to the SoC**. Sheet 25 of the vendor schematic has two
buses that only look alike by name, and they never meet:

| net | from | to |
|---|---|---|
| `I2S0_SCLK_HDMIIN` | TC358749 A_SCK (J9) | ALC5651 BCLK2 (pin 29) |
| `I2S0_LRCK_RX_HDMIIN` | TC358749 A_WFS (H10) | ALC5651 LRCK2 (pin 28) |
| `I2S0_SDI0_HDMIIN` | TC358749 A_SD0 (H9) | ALC5651 DACDAT2 (pin 27) |
| `I2S_CLK_HDMIIN` | TC358749 A_OSCK (G10) | TP50271, and nothing else |
| `I2S0_SCLK` | RK3399 GPIO3_D0 | ALC5651 BCLK1 (pin 33), via R7110 |
| `I2S0_LRCK_RX` | RK3399 GPIO3_D1 | ALC5651 LRCK1 (pin 32), via R7111 |
| `I2S0_SDI0` | RK3399 GPIO3_D3 | ALC5651 ADCDAT1 (pin 30), via R7107 |
| `I2S0_SDO0` | RK3399 GPIO3_D7 | ALC5651 DACDAT1 (pin 31), via R7108 |
| `I2S_CLK` | RK3399 GPIO4_A0 | ALC5651 MCLK (pin 34), via R7112 |

`A_SD1..A_SD3` (J10, K9, K8) are unused, so the receiver's link is two
channels - which matches what the video driver asks for (`MASK_AUDCHNUM_2`).

So the codec sits between the receiver and the SoC, and the SoC never sees
the receiver's audio directly. An earlier version of this page claimed the
opposite; it was inferred from net-name similarity in a text dump of the
schematic, and rendering sheet 25 as an image disproved it. If you are about
to trust a `_HDMIIN` suffix, don't.

Three consequences:

* **The SoC is the clock master on its own link, not a slave.** It drives
  BCLK1, LRCK1 and - through R7112 - the codec's MCLK.
* **GPIO4_A0 must be claimed.** It is the only source of the codec's system
  clock; nothing else on the board drives that pin. The stock
  `i2s0_2ch_bus` group already covers it along with the other five pins, so
  there is no reason to define a group by hand.
* **Getting the receiver's audio into a capture buffer means going through
  the codec**, which is what patch 0001 sets up and what "The one link that
  does not work" below is about.

The ALC5651 is register-compatible with the Realtek RT5651: the ID register
at 0xff reads 0x6281, which is exactly what `rt5651_i2c_probe()` insists on,
so the mainline `realtek,rt5651` binding drives it unchanged. It sits at
0x1a on i2c1, the same bus as the receiver at 0x1f.

### The rails feeding it were wrong

`vcca1v8_codec` (RK808 LDO_REG7) is the codec's digital/IO supply *and* the
reference `&io_domains` uses for the audio IO domain, which covers GPIO3D and
GPIO4A - so i2s0 and i2c1 both. Mainline's `rk3399-orangepi.dts` described it
and `vcca3v0_codec` with the regulator's whole adjustable span instead of the
board voltage, and the core leaves such a rail wherever it powered on. Result:

| rail | as shipped | should be |
|---|---|---|
| `vcca1v8_codec` | 0.8 V | 1.8 V |
| `vcca3v0_codec` | 1.8 V | 3.0 V |
| `vcc3v0_tp` | 1.8 V | 3.0 V |

Undervolted, the codec half-works in a way that is easy to misread. Patch
0013 pins the three. Symptoms before it, all measured:

```
# 2000 back-to-back reads of the device ID, driver unbound
before:  ok 1966  bad 34   values 0x6281 x1827, 0x62ff x84, 0x67ff x25, 0x7fff x7
after:   ok 2000  bad 0    values 0x6281 x2000
```

The same burst against the TC358749 at 0x1f was 2000/2000 both times, so it
is the device, not the bus. In the kernel it surfaces as `-ENXIO` out of
every `regmap_update_bits()` on a register with no cache default - which is
exactly the set DAPM needs (0x61/0x62 power, 0x84 ASRC) - so the sound card
builds, `amixer` appears to take, and capture returns silence.

### The one link that does not work

With the rails fixed, everything on the SoC side of the codec works and was
measured:

* codec -> SoC: the analogue ADC's own noise floor arrives (rms 0.75 -> 2.46
  when `Stereo1 ADC L1 Mux` is switched from `DD MIX` to `ADC`)
* SoC -> codec -> SoC: a 1 kHz tone played on the card comes back through
  `IF1 DAC -> DAC MIXL -> DD MIXL -> Stereo1 ADC MIXL -> IF1 ADC1` at full
  level (peak 29262 for a 28000-amplitude tone)

The receiver's side is healthy too: `AU_STATUS0` has `S_A_SAMPLE`, clearing
`AUDIO_INT` leaves only `I_AF_LOCK` set, `FORCE_MUTE` is 0, `SDO_MODE1` is
I2S, `CONFCTL` has `AUDCHNUM_2 | AUDOUTSEL_I2S` and picks up `ABUFEN` while
the video stream runs, `SYSCTL` leaves `MASK_I2SDIS` clear, and the refclk
block is programmed for 27 MHz (`SYS_FREQ` 0x0a8c, `LOCKDET_REF` 0x041eb0,
`NCO_F0_MOD` 27 MHz).

What is dead is the codec's **Stereo2 DAC** - the block every AIF2 -> AIF1
route has to cross. It passes nothing with all power bits forced
(`PWR_DIG1` 0xd806, `PWR_DIG2` 0xce00 - those are all the bits the chip
implements), unmuted (`DAC2_CTRL` 0x0000, `DAC2_DIG_VOL` 0xafaf), with ASRC
on, with ASRC off, with sysclk at 256 fs and at 512 fs, and with auto-mute
disabled on the receiver.

The one thing that changed it: making the codec the **I2S2 master** raised
the capture noise floor from +-1 LSB to +-48, i.e. the Stereo2 DAC starts
running the moment I2S2 has a clock and does nothing when it has none. That
is the signature of BCLK2/LRCK2 not arriving from the receiver.

Whether the receiver is not driving them or the board does not fit the parts
that carry them cannot be told apart from software. The nets above are drawn
on the schematic; whether they are stuffed on this board is a question for a
scope on the codec's pins 28 and 29. The suspicion is worth stating plainly:
the vendor's own OrangePi RK3399 device tree never wires HDMI IN audio, and
the vendor machine driver that does (`rockchip_rt5651_tc358749x.c`) belongs
to a different Rockchip board.

**The ALSA card is called `tc358743`, and the part is a TC358749** - and, on
this board, the card is really the ALC5651. That is deliberate:
`hw:tc358743,0` is what kvmd's janus config asks for and what every PiKVM
troubleshooting note names, so the stock config is correct as shipped and
nothing in the image build has to edit kvmd's files. If you are matching
`aplay -l` against this page, that is the discrepancy.

Whether audio is arriving at the receiver is one read, and it needs no sound
card:

```
$ v4l2-ctl -d /dev/kvmd-video-bridge --list-ctrls | grep audio
    audio_present 0x009819a1 (bool) : default=0 value=1 flags=read-only
```

There is no audio path *to* the target. That would be a UAC2 gadget function
on the Type-C port, and none is configured.

## Two drivers exist for this chip

The vendor tree carries both, and it matters which one is in play:

1. `drivers/media/i2c/tc35874x.c` — a fork of **mainline's `tc358743.c`**
   (Cisco/Hans Verkuil), extended to cover the TC358749XBG. Selected by
   `compatible = "toshiba,tc358749"`, `CONFIG_VIDEO_TC35874X`. Uses the modern
   V4L2 fwnode graph and feeds `rkisp1`. **This is what we build.**
2. `drivers/media/i2c/soc_camera/rockchip/tc358749xbg_v4l2-i2c-subdev.c` — the
   older soc_camera driver, paired with CIF-ISP10. Used by the 4.4.103 DTS.
   Dead end; soc_camera was deleted from mainline years ago.

That the vendor already did (1) is the single most useful fact in this
project: the mainline port is a diff against a file that still exists
upstream, not a driver written from scratch.

## USB gadget

RK3399 has two USB 3.0 OTG controllers (dwc3). `usbdrd_dwc3_0` is already
`dr_mode = "otg"` in `rk3399.dtsi`, so the Type-C port can act as the HID and
mass-storage gadget for the target machine.

**The vendor defconfig does not enable `CONFIG_USB_CONFIGFS_F_HID`.** Without
it there is no keyboard or mouse and the KVM is just a capture card. This is
why `config/kernel-fragments/pikvm.config` exists, and why
`build-kernel.sh` hard-fails if the symbol goes missing.

The gadget presents four interfaces: three HID (keyboard, absolute mouse,
relative mouse) and one mass storage. Measured against a Raspberry Pi 3 host,
the keyboard's interrupt IN endpoint is serviced at **250 reports/s, a 4 ms
interval** — `f_hid.c` hardcodes `bInterval = 4` for every HID function, which
at high speed asks for 1 ms, so this host is giving it a quarter of that. It
is far more than a keyboard or an absolute mouse needs, and worth knowing only
because it is the number to compare against if input ever goes sluggish.

Measure it with blocking writes, not the obvious non-blocking loop: the gadget
buffers exactly one report, so a burst of non-blocking writes returns `EAGAIN`
after the first one on a perfectly healthy endpoint.

```sh
python3 -c 'import os,time
fd=os.open("/dev/kvmd-hid-keyboard",os.O_WRONLY); t=time.time(); n=0
while time.time()-t < 10: os.write(fd,bytes(8)); n+=1
print(n/10, "reports/s")'
```

## Video encoding

| | vendor 4.4 | mainline |
|---|---|---|
| JPEG (MJPEG stream) | MPP only, not V4L2 M2M | `hantro` exposes V4L2 M2M JPEG |
| H.264 (WebRTC) | MPP only | not supported (hantro does JPEG + VP8) |

That table is the state before the MPP work. Both codecs now run on VEPU2
through `libv4l-rkmpp`; see `patches.md` and `roadmap.md`.

## ATX

Not wired, and off in `main.yaml`. This section is what it would take, and
which pins it has to use.

Three independent sources, and they agree:

* the vendor **user manual**, section 5 "GPIO Specifications" - the 40-pin
  table with the header labels
  <https://docs.google.com/document/d/1wH-UDqlEJvHBR4NCsnNBuH_unl5DqqIh/edit>
  (`/export?format=txt` on that document id gets a greppable copy)
* the **schematic**, sheet 29 `EXTPORT KEY` for connector
  `J9002 GPIO_EXT DIP40-254`, and sheets 15/16 for the SoC pins and their pad
  supplies
  <https://drive.google.com/file/d/1iDkHu_wSkNacgAYSK6NZa_ogHQb9Ez_S/view>
* this tree's own `rk3399-orangepi.dts`, for what is already claimed

Both vendor documents are reachable from the product page linked in
CLAUDE.md, via its "Service & Download" tab.

### What ATX control actually is

Four wires to the target's front-panel header, and none of them is a bus:

| | direction | what it connects to |
|---|---|---|
| power switch | out | the two header pins the case's power button shorts |
| reset switch | out | the two the reset button shorts |
| power LED | in | across the power LED pins |
| HDD LED | in | across the HDD LED pins |

The outputs are momentary shorts, not levels - kvmd holds one for
`click_delay` (0.1 s) for a press, or `long_click_delay` (5.5 s) to force a
power-off, which is why that default is longer than the 4 s an ATX supply
requires.

**All four have to be optically isolated.** The KVM and the target are
separate machines with separate supplies and no common ground; tying their
grounds together through a GPIO is how you get current flowing somewhere
nobody designed for. The outputs drive optocoupler LEDs and the
phototransistors do the shorting; the inputs are the mirror image, an
optocoupler LED across the target's own LED and the phototransistor read by
the GPIO. PiKVM's own v2 hardware is exactly this, and there is nothing
board-specific about the circuit.

The LED inputs are also what makes `power_on` and `power_off` different from
`click_power`: kvmd reads the power LED first and does nothing if the machine
is already in the state asked for. Without the LED inputs those become
guesses, so wire them even if the buttons are what you actually want.

### The header is Pi-shaped, and that is a trap

`J9002` is labelled like a Raspberry Pi's: `GPIO17`, `GPIO18`, `GPIO22`,
`GPIO23`, `GPIO24`, `GPIO25` and so on, at the same physical positions a Pi
puts those BCM numbers. So a PiKVM ATX harness plugs straight in, and the
labels invite you to keep kvmd's defaults.

Two of those four defaults are already taken:

| kvmd default | header | pin | RK3399 | state |
|---|---|---|---|---|
| `reset_switch_pin: 27` | GPIO27 | 13 | GPIO2_C1 | **UART0_TXD - Bluetooth** |
| `hdd_led_pin: 22` | GPIO22 | 15 | GPIO2_C2 | **UART0_CTS - Bluetooth** |
| `power_switch_pin: 23` | GPIO23 | 16 | GPIO2_A2 | free |
| `power_led_pin: 24` | GPIO24 | 18 | GPIO2_A3 | free |

`&uart0` is `status = "okay"` in `rk3399-orangepi.dts` and carries the
`brcm,bcm43438-bt` node, with `pinctrl-0 = <&uart0_xfer &uart0_cts
&uart0_rts>`. That muxes GPIO2_C0..C3 - header pins 11, 13, 15 and 22 - to
UART0, so libgpiod cannot have them and taking them would cost the board its
Bluetooth.

They are also the wrong voltage. The schematic's own net name for the pad
supply of that group is `APIO3_VDD_1V8` (sheet 15), matching
`DRV_TYPE_IO_1V8_ONLY` for gpio2 groups C and D in `rk3399_pin_banks[]`.
GPIO2_A/B are on `APIO2`, which the device tree ties to
`bt656-supply = <&vcc_3v0>` - 3.0 V, and enough for an optocoupler LED.

So: **stay in GPIO2 group A or B.** Group C is Bluetooth's and 1.8 V.

### The debug UART is 3.0 V, not 3.3

Worth stating plainly, because every USB-to-TTL adapter drawer has a 5 V one
in it and this board does not survive that gracefully.

UART2 is on `gpio4` group C, which RK3399 puts in the `gpio1830` IO domain,
and this board's device tree ties that domain to `vcc_3v0`
(`gpio1830-supply = <&vcc_3v0>`). The running kernel says so too, rather than
this being read off the source:

```
rockchip-iodomain ff770000.syscon:io-domains: gpio1830(3000000 uV) supplied by vcc_3v0
```

and `/sys/class/regulator` has `vcc_3v0` at `3000000 uV`. So the pads run at
3.0 V, and the absolute maximum on an input is
VDD_IO + 0.3 V = **3.3 V**. A 3.3 V adapter sits exactly on that limit, which
is the normal thing everyone does. A 5 V adapter is 1.7 V over it, and the
only reason such a board appears to work is that the pad's ESD clamp is
conducting the difference away — which is a diode being used as a component
it is not.

Note the asymmetry, because it makes a bad adapter look fine: the board's TX
at 3.0 V clears a 5 V part's input threshold comfortably, so reading the
console works perfectly. It is only the adapter's TX into the board that is
out of spec, and it will usually still be readable. Working is not evidence of
being in spec here.

**An RS-232 transceiver is the same hazard, and a quieter one**, because its
logic level is whatever you fed its VCC. An SP3232E powered from header pin 2
— 5 V, if the header follows the Raspberry Pi labelling the rest of it does —
puts 0–5 V on its TTL output and into this pin, exactly like a 5 V USB-TTL
board. The fix is one wire: the part runs from 3.0 to 5.5 V, so move its VCC
to a 3.3 V pin. Meter the pin first rather than trusting the silkscreen.

What this looks like in practice, and why it goes unnoticed for a long time:
UART idle is logic high, so the pin sits at the adapter's high level
continuously, not only during traffic. Above roughly VDD_IO + 0.5 V the pad's
ESD clamp conducts, and the current — set by the driver's output impedance,
single-digit mA for a CMOS output — is injected into `vcc_3v0`. That rail
carries the whole `gpio1830`, `bt656` and `pmu1830` domains here, so it sinks
a few mA without moving; on a board where it were lightly loaded, the symptom
would be the rail rising and unrelated things misbehaving. So this is a
lifetime and reliability question rather than a "the board stops working"
question, which is precisely why it survives review.

Two things are **not** known here and would settle it: whether the board has
series resistors on the debug UART lines, which would make all of the above
moot, and whether `vcc_3v0` actually moves with an adapter attached. The
vendor schematic answers the first; a meter answers the second.

### What is actually free

Everything on the header is bank `gpio2` except SPI1/I2C4 (`gpio1`), the
debug UART (`gpio4`) and the two DNP pins. Within `gpio2`, this is what this
image leaves alone:

| header | pin | RK3399 | line | why it is free |
|---|---|---|---|---|
| GPIO4 | 7 | GPIO2_A0 | 0 | `i2c2` is disabled |
| GPIO18 | 12 | GPIO2_A1 | 1 | `i2c2` is disabled |
| GPIO23 | 16 | GPIO2_A2 | 2 | DVP unused; we capture over MIPI CSI |
| GPIO24 | 18 | GPIO2_A3 | 3 | same |
| GPIO5 | 29 | GPIO2_A4 | 4 | `pcie0` is disabled |
| GPIO21 | 40 | GPIO2_B3 | 11 | `spi2` is disabled |

And what is not, which matters more:

| header | pin | RK3399 | taken by |
|---|---|---|---|
| TX / RX | 8, 10 | GPIO4_C4/C3 | the debug console (`ttyS2`) — **3.0 V**, see below |
| GPIO17/27/22/25 | 11, 13, 15, 22 | GPIO2_C0..C3 | UART0 - Bluetooth |
| GPIO6 | 31 | GPIO2_A5 | **HDMI IN rail** (`hdmiin_gpios`) |
| GPIO13 | 33 | GPIO2_A6 | **HDMI IN rail** |
| GPIO19 | 35 | GPIO2_A7 | **TC358749 reset** |
| GPIO26 | 37 | GPIO2_B0 | HDMI IN |
| GPIO16 | 36 | GPIO2_B1 | HDMI IN |
| GPIO20 | 38 | GPIO2_B2 | HDMI IN |
| GPIO12 | 32 | GPIO2_B4 | TC358749 interrupt |
| SDA / SCL | 3, 5 | GPIO1_B3/B4 | `i2c4`, which is `okay` |

Six of the header's GPIOs are the HDMI IN subsystem. That is the whole point
of this board, so treat that block as unavailable rather than negotiable.

### The assignment this image assumes

```
                       header  RK3399     gpio2 line   default bias
  power_switch_pin        16   GPIO2_A2        2       pull-down
  reset_switch_pin        18   GPIO2_A3        3       pull-down
  power_led_pin            7   GPIO2_A0        0       pull-up
  hdd_led_pin             12   GPIO2_A1        1       pull-up
```

Four contiguous lines, all 3.0 V, all free, and the two outputs on the two
pins whose reset default is a pull-**down**. That last part is the reason
this is not simply "keep kvmd's defaults where they happen to fit". The
schematic writes the SoC's default bias into the pin name - `GPIO2_A2/VOP_D2/
CIF_D2_d` is pulled down, `GPIO2_A0/VOP_D0/CIF_D0/I2C2_SDA_u` is pulled up -
and nothing in our device tree configures these pins, so that reset default
is what holds from power-on until kvmd claims the line. An output that floats
high before kvmd drives it low is a power or reset button being held down
during boot.

By the same token the two inputs sit on pull-ups, so an optocoupler that is
not conducting reads 1. Expect `power_led_inverted: true` and
`hdd_led_inverted: true`; confirm by powering the target on and seeing which
way round the web UI gets it.

Grounds for the harness: pins 6, 9, 14, 20, 25, 30, 34, 39. 3.3 V: pins 1 and
17.

### Deriving a line number

Rockchip writes pins as `GPIO<bank>_<group><index>` with groups A-D. libgpiod
wants a flat number within the bank:

```
line = group * 8 + index        A=0, B=1, C=2, D=3
```

So `GPIO2_A2` is bank 2, line 2, and `GPIO2_C1` is bank 2, line 17.

The bank is the other half. `/dev/kvmd-gpio0` .. `/dev/kvmd-gpio4` are matched
by register address in `99-kvmd.rules`, so the number in the name is always
the bank in the SoC manual - which is not true of `/dev/gpiochipN`, that being
probe order.

`gpioinfo` prints the same numbering, but **do not use it to decide whether a
line is free** - it only knows about lines someone requested through the gpio
chardev, and a pin muxed to a peripheral by pinctrl is not that. Measured on
this board: GPIO2_C0..C3 are UART0's, and gpioinfo lists all four as plain
`unnamed input` with no consumer. The six HDMI IN pins look equally innocent.

The file that actually knows is pinctrl's:

```
/sys/kernel/debug/pinctrl/pinctrl-rockchip-pinctrl/pinmux-pins
```

Pin numbers there are `bank * 32 + line`, so gpio2 line 0 is pin 64. What it
says on this image, and what confirms both tables above:

```
pin 64 (gpio2-0): (MUX UNCLAIMED) (GPIO UNCLAIMED)      <- power_led
pin 65 (gpio2-1): (MUX UNCLAIMED) (GPIO UNCLAIMED)      <- hdd_led
pin 66 (gpio2-2): (MUX UNCLAIMED) (GPIO UNCLAIMED)      <- power_switch
pin 67 (gpio2-3): (MUX UNCLAIMED) (GPIO UNCLAIMED)      <- reset_switch
pin 69 (gpio2-5): 1-001f ... function hdmiin group hdmiin-gpios
pin 71 (gpio2-7): 1-001f gpio2:71 function hdmiin group hdmiin-gpios
pin 80 (gpio2-16): ff180000.serial ... function uart0 group uart0-xfer
pin 83 (gpio2-19): ff180000.serial ... function uart0 group uart0-rts
pin 90 (gpio2-26): serial0-0 ... function bluetooth group bt-wake-l
```

`pinconf-pins` in the same directory carries the bias, and confirms the choice
of which pins carry the outputs:

```
pin 64 (gpio2-0): input bias pull up   ... pin output (1 level)
pin 66 (gpio2-2): input bias pull down ... pin output (0 level)
```

### Turning it on

The block in `/etc/kvmd/override.yaml` carries this assignment, commented out.
Uncomment it once the optocouplers are built.

The one thing that was actively wrong before, and is worth not repeating: this
used to be `type: gpio` with no pins at all, so kvmd used its Raspberry Pi
defaults - BCM 22/23/24/27 on `/dev/kvmd-gpio`, which resolved to `gpiochip0`.
On RK3399 gpio0 is the small PMU bank, GPIO0_A0..A7 and GPIO0_B0..B5, and
lines 22, 23, 24 and 27 are not pins at all. `pinctrl-rockchip` declares every
bank as 32 lines regardless, so nothing failed: the buttons in the web UI
worked, wrote register bits that leave the die nowhere, and reported success.
