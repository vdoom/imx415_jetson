# IMX415 device tree overlay (Phase E)

**Written 2026-07-07.** Canonical versioned copies; the build lives in the BSP
tree at `.../source/hardware/nvidia/t23x/nv-public/overlay/` (same .dts + one
`dtbo-y` line in that dir's Makefile). Built artifact:
`.../source/kernel-devicetree/generic-dts/dtbs/tegra234-p3767-camera-p3768-imx415.dtbo`.

- `tegra234-p3767-camera-p3768-imx415.dts` — the overlay source.
- `imx415-overlay-decompiled.dts` — decompile of the **built** dtbo, for
  byte-level review (diff it against `../reference/imx219-C-donor-decompiled.dts`
  to see exactly what changed vs the stock donor).

## Status: builds clean, diff-verified against donor. NOT yet booted on target.

## Deltas vs imx219-C donor (everything else donor-identical)

| Change | Value |
|---|---|
| overlay-name | "Camera IMX415-98" |
| sensor node | `rbpcv415_c@37`, `compatible = "sony,imx415"`, `reg = <0x37>` |
| badge | `jakku_rear_IMX415` |
| drivernode0 sysfs path | `.../i2c@1/rbpcv415_c@37` |
| drivernode1 (v4l2_lens) + `lens_imx219@RBPCV2` | **removed** (no lens data for this module) |
| `i2c@0` disabled imx219_a stub | **removed** (pointless without imx219 nodes) |
| modes | five imx219 modes → single `mode0` (contract in `../driver/README.md`) |
| `discontinuous_clk` | "no" (IMX415 outputs continuous CSI clock) |
| kept as donor | reset-gpios PAC.00 active-high, serial_c, port-index 2, bus-width 2, VI/NVCSI graph, both gpio hogs, 22pin jetson-header-name |

## Deploy reminder (Phase F, from passport.md §2.1)

Copy dtbo to `/boot/`, then in `/boot/extlinux/extlinux.conf` clone the
`UARTFix` entry as a new `imx415` LABEL: **remove**
`tegra234-p3767-camera-p3768-imx219-dual.dtbo` from OVERLAYS, **keep**
`disable-uart1-dma.dtbo`, **add** our dtbo. Back up extlinux.conf first (sudo).
Module goes to `/lib/modules/5.15.185-tegra/updates/` + `depmod -a`.
