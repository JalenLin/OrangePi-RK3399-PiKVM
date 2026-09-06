# Captured boot logs

* **`rk612-boot-ok.log`** — the 6.12 track reaching a login prompt, captured
  over the debug UART. This is what a healthy boot looks like on this board;
  diff against it when yours stops somewhere.

Note the rate change across a boot: U-Boot is compiled for 1500000 and the
kernel and login prompt run at 115200, so a terminal fixed at one rate sees
garbage for the other half. See docs/building.md.

The SoC serial number is redacted; it identifies one physical chip and is of
no use to anyone else.
