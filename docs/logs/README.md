# Captured boot logs

* **`rk612-boot-ok.log`** — the 6.12 track reaching a login prompt, captured
  over the debug UART. This is what a healthy boot looks like on this board;
  diff against it when yours stops somewhere.

It predates several later changes, so do not read those parts of it as current:

* **The console rate.** U-Boot was still compiled for 1500000 when this was
  captured, and the kernel and login prompt for 115200, so a terminal fixed at
  one rate sees garbage for the other half. Both are 115200 now and only the
  BL31 blob still prints at 1500000. See docs/building.md.
* **Wi-Fi.** `cfg80211` was still built in, so the log carries a
  `failed to load regulatory.db`, and Rockchip's vendor `bcmdhd` driver was
  still enabled, so it also carries a screenful of `[dhd]` failures right at
  the login prompt. Neither happens now: `CONFIG_CFG80211=m` loads the
  database off the real rootfs, and the vendor driver is off in favour of
  mainline `brcmfmac`. See config/kernel-fragments/pikvm.config.
* **HDMI output.** In this capture the display subsystem never finishes
  binding - `bound ...vop` repeats, then `display-subsystem: deferred probe
  pending` - so there is no console on HDMI. On the current image it binds
  and the console comes up at 1080p60. For the boot messages that are
  expected now, see docs/known-issues.md rather than this file.

The SoC serial number is redacted; it identifies one physical chip and is of
no use to anyone else.
