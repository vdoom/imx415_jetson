# IMX415 device tree overlay (Phase E)

**Written 2026-07-07.** Canonical versioned copies; the build lives in the BSP
tree at `.../source/hardware/nvidia/t23x/nv-public/overlay/` (same .dts + one
`dtbo-y` line in that dir's Makefile). Built artifact:
`.../source/kernel-devicetree/generic-dts/dtbs/tegra234-p3767-camera-p3768-imx415.dtbo`.

- `tegra234-p3767-camera-p3768-imx415.dts` — the overlay source.
- `imx415-overlay-decompiled.dts` — decompile of the **built** dtbo, for
  byte-level review (diff it against `../reference/imx219-C-donor-decompiled.dts`
  to see exactly what changed vs the stock donor).

## Status: running on target since Phase G (2026-07-07); 4-lane since 2026-07-08; IR-CUT pinmux validated 2026-07-11; Argus/ISP properties (dtbo 53381cb5) **validated on target 2026-07-13**; 72 dB gain range added 2026-07-13 (dtbo sha1 1c0a9101, pairs with ko 5cea9ce1) — awaiting target validation.

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
| `embedded_metadata_height` | **"1"** — the sensor sends 1 embedded-data line per frame; with "0" VI discards every frame (`corr_err ... err_data 16384`, = CHANSEL_EMBED_INFRINGE). Found 2026-07-07 during Phase G via the working FRAMOS IMX715 overlay (`../reference/fr_imx715-cam1-2lane-overlay-l4t-r36.4.4.dts`); RPi's RP1 receiver tolerates the line silently, Tegra VI does not |
| kept as donor | reset-gpios PAC.00 active-high, serial_c, port-index 2, VI/NVCSI graph, both gpio hogs, 22pin jetson-header-name |
| **4-lane upgrade (2026-07-08)** | bus-width 2→4, num_lanes "4", pix_clk_hz 356400000, max_framerate 30 fps, exp 59–33200 µs; CAM1 has 4 lanes wired (proof: FRAMOS cam1-4lane overlay), module routes 4 lanes (proof: RPi forum 4lane test); validated 2-lane state = git tag `phase1-2lane-15fps` + `deploy/2lane-15fps-backup/` |
| **IR-CUT pinmux (2026-07-11)** | new `fragment@1` targeting `&pinmux`: `extperiph2_clk_pp1` (CAM1 pin 18 = module FFC "IR-CUT" line) → `rsvd1`/GPIO. Stock EXTPERIPH2 mux force-drove the line to 0 V = filter stuck at night. As GPIO the pad is hi-Z when unclaimed (physical switch works); PP.01 (main gpio line 113) drives day/night from software (`tools/ircut.sh`). Validated on target 2026-07-11 via runtime `pinmux-select` before baking in. See `phase_g_validation.md` |
| **72 dB gain (2026-07-13)** | `max_gain_val` 30000 → **72000** in both modes (paired driver change raises the register clamp 100 → 240): 0–30 dB analog, digital above, 0.3 dB steps — the range the Rockchip and FRAMOS IMX715 drivers ship. Argus gain range becomes 1–3981×. Mixed old/new ko+dtbo combos degrade safely (clamp at 30 dB) — the dB→register mapping itself is unchanged |
| **Argus/ISP additions (2026-07-12)** | three deltas, all Argus-userspace-only (kernel/V4L2 behavior unchanged, module untouched): (1) `use_decibel_gain = "true"` in the sensor node — our gain control is dB×1000, this makes the camera core convert its linear multipliers to dB (same property as the Argus-supported FRAMOS IMX715 overlays); (2) `lens_imx415@IMX41598` under `bus@0` with the real Waveshare optics (EFL 3.95 mm, F/2.0 from the spec PDF; zeros for unknown fields per stock convention); (3) `drivernode1` (`v4l2_lens`) in module1 pointing at it — restores the stock imx219-C module shape that Phase E had dropped. See `../argus_isp.md` |

## Deploy reminder (Phase F, from passport.md §2.1)

Copy dtbo to `/boot/`, then in `/boot/extlinux/extlinux.conf` clone the
`UARTFix` entry as a new `imx415` LABEL: **remove**
`tegra234-p3767-camera-p3768-imx219-dual.dtbo` from OVERLAYS, **keep**
`disable-uart1-dma.dtbo`, **add** our dtbo. Back up extlinux.conf first (sudo).
Module goes to `/lib/modules/5.15.185-tegra/updates/` + `depmod -a`.
