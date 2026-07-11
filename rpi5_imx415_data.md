# RPi5 IMX415 — Phase A validation data

Collected on the live Raspberry Pi 5 that currently runs the Waveshare IMX415-98
IR-CUT camera, to feed the Jetson Orin Nano port (Phase A of
`imx415_jetson_porting_guide.md`).

- **Date:** 2026-07-05
- **Board:** Raspberry Pi 5 Model B Rev 1.1 (BCM2712)
- **OS:** Debian GNU/Linux 13 (trixie)
- **Kernel:** `6.12.47+rpt-rpi-2712`
- **Overlay in use:** `dtoverlay=imx415,cam0,clk-37125` (in `/boot/firmware/config.txt`)
- **Camera stack:** libcamera v0.7.0+rpt20260205, rpicam-apps
- Camera was **already configured and working** on **CAM0** — no config edit or reboot was needed.

---

## 1. Passport (the numbers that matter for the port)

| Parameter | Value | How confirmed |
|---|---|---|
| **Crystal / INCK** | **37.125 MHz** | `clk_summary`: `cam0_clk = 37125000` feeding `10-0037` as `inck` |
| **I2C address** | **0x37** ⚠️ (NOT 0x1a) | probe line `imx415 10-0037`; `i2cdetect -y 10` → `UU` at 0x37; DT `reg = <0x37>` |
| **I2C bus** | **10** (`/dev/i2c-10`; `i2c-6`→`i2c-10` symlink) | probe line `10-0037`, `v4l2-ctl`, media graph |
| **Sensor subdev** | `/dev/v4l-subdev2` = `imx415 10-0037` | `media-ctl`, sysfs name |
| **DT compatible** | `sony,imx415` | `/proc/device-tree/.../imx415@37/compatible` |
| **Resolution (only mode)** | **3864 × 2192** | `rpicam-hello --list-cameras`, subdev fmt |
| **Bayer order** | **GBRG** | `MEDIA_BUS_FMT_SGBRG10_1X10` (0x300e); `rpicam` `SGBRG10_CSI2P` |
| **Bit depth** | **10-bit** | mbus code / list-cameras |
| **CSI lanes** | **2** (`data-lanes = <1 2>`) | DT endpoint |
| **Link frequency** | **445.5 MHz** | `link_frequency` ctrl (idx 2) + DT `link-frequencies = <445500000>` |
| **Pixel rate (V4L2 ctrl)** | **891 000 000** | `pixel_rate` control (read-only) |
| **Full-frame frame rate** | **15 fps** ⚠️ (NOT 30) | `rpicam --list-cameras` "15.00 fps"; confirmed by VMAX/HMAX math below |
| **VMAX (default)** | **2250** (= 2192 active + 58 vblank) | `vertical_blanking` min/def = 58; exposure max = VMAX−8 = 2242 |
| **HMAX (derived)** | **≈ 2200** (H-total = 26400 px @ 891 MHz) | active 3864 + `horizontal_blanking` 22536 = 26400; 26400/12 = 2200 |
| **Line time (derived)** | **≈ 29.63 µs** | 26400 / 891 MHz = 1/(15·2250) |
| **Exposure range** | **4 … 2242 lines** (step 1) | `exposure` control |
| **Analogue gain range** | **0 … 100** (step 1 = 0.3 dB → 0…30 dB) | `analogue_gain` control |
| **Regulators (DT supplies)** | `avdd`, `dvdd`, `ovdd` | DT node children |
| **Orientation / rotation (DT)** | orientation = 2, rotation = 180 | DT node; H+V flip active in subdev |
| **libcamera tuning file** | `/usr/share/libcamera/ipa/rpi/pisp/imx415.json` | present (83 KB) |
| **Sensor black level (tuning)** | 3840 on 16-bit scale = **60 in 10-bit** | tuning JSON `rpi.black_level` |
| **RPi kernel branch for registers** | **`rpi-6.12.y`** | matches `uname -r` 6.12.47; `clk-37125` overlay param only exists ≥ 6.12.y |
| **Driver build (pin)** | `srcversion D307833D7F402E825690CE0`, vermagic `6.12.47+rpt-rpi-2712` | `modinfo imx415` — the exact driver this HW was validated on |
| **Reset / XCLR GPIO** | **none** in the RPi overlay (power sequenced by regulators only) | DT node has no `*-gpios`/reset/xclr property |
| **Modes advertised** | exactly one: 3864×2192 (no crop/bin) | subdev `--list-subdev-framesizes` → single range → confirms guide §9.1 |
| **IR-CUT polarity** | **day (filter IN) = control HIGH, night = LOW** — closed 2026-07-11 on Jetson via the FFC line, no wiring needed | see §6 update; IR-remote verified on target |

---

## 2. ⚠️ Corrections to the porting guide (read before Phase D/E)

The live hardware contradicts several assumptions baked into
`imx415_jetson_porting_guide.md`. Fix these before writing the driver / DT:

1. **I2C address is `0x37`, not `0x1a`.** The guide says 0x1a everywhere
   (§2.3, §3.2, §6.2 `reg = <0x1a>`, node `@1a`, §8.3). For this module use:
   - DT node: `imx415_cam0: imx415@37 { reg = <0x37>; … }`
   - `i2cdetect` on Jetson: expect the device at **0x37**.
   - Everything else about the address in the guide is wrong for this unit.
   > The IMX415 address is strap-selectable (0x1a / 0x37); Waveshare's board
   > straps it to **0x37**.

2. **Full-frame rate is 15 fps at 2-lane, not 30 fps.** The guide's "≈30 fps
   at 2-lane / 891 Mbps" (§5.0, §5.3.10, DT `max_framerate = 30000000`) is not
   achievable at 2 lanes: payload 3864·2192·10·30 = **2.54 Gb/s** > 2·891 =
   **1.782 Gb/s** of CSI capacity. The RPi reference driver ships **15 fps**
   (HMAX ≈ 2200). Use **15 fps** for the 2-lane port, or move to **4 lanes**
   if you truly need 30 fps.
   - DT `frmfmt` / `max_framerate` → **15** fps (`15000000`).
   - Guide's HMAX min "1100" is the *30 fps / 4-lane* figure; the real 2-lane
     default is **HMAX ≈ 2200** (derived from H-total 26400 / 12; copy the exact
     register value from the `rpi-6.12.y` `imx415_mode_*[]` table — don't hand-compute it).

3. **Recompute the tegracam DT timing for 15 fps** (guide §6.2 used 30 fps):
   - `pix_clk_hz = 178200000` — **unchanged** (445.5 M × 2 DDR × 2 lanes / 10 b).
   - `line_length` → **5280** (was 2640): `pix_clk_hz / (line_length·VMAX) = 15`
     → `178.2e6 / (LL·2250) = 15` → LL = 5280.
   - line time ≈ **29.63 µs** (guide assumed 14.8 µs @ 30 fps):
     - `min_exp_time` ≈ 4 lines → **≈ 119 µs** (was 59).
     - `max_exp_time` ≈ 2242 lines → **≈ 66430 µs** (was 33200).
     - `min_framerate`/`max_framerate` around **15 fps**.
   - Gain DT block (0…30 dB, step 0.3 dB, 0…100 steps) matches the guide.

4. **Register source branch is `rpi-6.12.y`, not `rpi-6.6.y`.** The guide's
   "verified constants" (§5.0) were checked against rpi-6.6.y, but this camera
   is validated on the 6.12.y driver (and 6.6.y lacks the `clk-37125` overlay
   param this unit needs). Clone and diff registers against **rpi-6.12.y**:
   `git clone --depth=1 --branch rpi-6.12.y https://github.com/raspberrypi/linux`.

5. **RAW alignment for the Appendix A viewer:** on the RP1 CFE the 10-bit data
   comes out **MSB-aligned in 16-bit** (max sample = 65472 = 1023≪6), so the
   viewer needs **`shift = 6`** for the RPi reference frame. Jetson's VI may
   differ (try 0…6 as the guide says); this fixes the RPi reference.

6. **No reset/XCLR GPIO on the RPi module.** The RPi imx415 node has no
   `reset-gpios` (only `avdd/dvdd/ovdd` supplies) — the driver brings the sensor
   up via power sequencing, not a discrete reset line. Keep this in mind for the
   Jetson `power_on()` (§5.3.5): the donor imx219 overlay supplies a connector
   `reset-gpios`; if the Waveshare board doesn't wire XCLR to that pin, probe can
   still succeed. Don't assume a reset toggle is mandatory.

7. **Confirmed as guide states (no change):** Bayer **GBRG** /
   `SGBRG10_1X10`; single full-frame mode 3864×2192; 10-bit; link freq
   **445.5 MHz** for INCK 37.125; 2-lane; supplies dvdd/ovdd/avdd; compatible
   `sony,imx415`; VMAX default 2250; gain 0…100 steps.

---

## 3. Evidence (command output)

### 3.1 Probe / detection
```
$ dmesg | grep -i imx415
imx415 10-0037: Detected IMX415 image sensor
rp1-cfe 1f00110000.csi: found subdevice .../i2c@88000/imx415@37
rp1-cfe 1f00110000.csi: Using sensor imx415 10-0037 for capture

$ rpicam-hello --list-cameras
0 : imx415 [3864x2192 10-bit GBRG] (.../imx415@37)
    Modes: 'SGBRG10_CSI2P' : 3864x2192 [15.00 fps - (0,0)/3864x2192 crop]
```

### 3.2 Crystal (decisive)
```
$ sudo grep -i cam /sys/kernel/debug/clk/clk_summary
 cam0_clk   ...  37125000  ...  10-0037   inck
```
→ input clock is **37.125 MHz**, consumed by the imx415 as `inck`.

### 3.3 I2C
```
$ sudo i2cdetect -y -r 10
30: -- -- -- -- -- -- -- UU -- ...      # UU at 0x37 = claimed by driver
```

### 3.4 Sensor subdev
```
$ v4l2-ctl -d /dev/v4l-subdev2 --list-subdev-mbus-codes
	0x300e: MEDIA_BUS_FMT_SGBRG10_1X10
$ v4l2-ctl -d /dev/v4l-subdev2 --get-subdev-fmt 0
	Width/Height : 3864/2192   Mediabus Code : 0x300e (SGBRG10_1X10)

$ v4l2-ctl -d /dev/v4l-subdev2 -L
exposure           : min=4   max=2242   step=1   default=2242
vertical_blanking  : min=58  ...        default=58            # VMAX = 2192+58 = 2250
horizontal_blanking: min=22536 step=12  default=22536         # H-total = 3864+22536 = 26400
analogue_gain      : min=0   max=100    step=1   default=0
link_frequency     : value=2 (445500000)   [297M,360M,445.5M,720M,742.5M]
pixel_rate         : 891000000 (read-only)
test_pattern       : 0..12 (color bars available)
```

### 3.5 Device-tree endpoint
```
imx415@37/compatible          = "sony,imx415"
imx415@37/reg                 = 0x37
imx415@37/{avdd,dvdd,ovdd}-supply present
imx415@37/rotation = 180 , orientation = 2
port/endpoint/data-lanes       = <1 2>          # 2 lanes
port/endpoint/clock-lanes      = <0>
port/endpoint/link-frequencies = <445500000>    # 445.5 MHz
clock-names                    = "inck"  (cam0_clk @ 37.125 MHz)
```

### 3.6 Media graph (topology, for Jetson media-ctl comparison)
```
imx415 10-0037 :0  (SGBRG10_1X10/3864x2192)
   -> csi2 :0  -> csi2 :4 (SGBRG16_1X16/3864x2192)
      -> pisp-fe -> /dev/video4 (rp1-cfe-fe_image0)   # ISP path (default)
      -> /dev/video0 (rp1-cfe-csi2_ch0)               # raw CSI path
```

### 3.7 Driver build & single-mode / reset check
```
$ modinfo imx415
description: Sony IMX415 image sensor driver
srcversion:  D307833D7F402E825690CE0
vermagic:    6.12.47+rpt-rpi-2712 SMP preempt mod_unload modversions aarch64

$ v4l2-ctl -d /dev/v4l-subdev2 --list-subdev-framesizes pad=0,code=0x300e
	Size Range: 3864x2192 - 3864x2192          # only the full frame → guide §9.1 confirmed

# imx415@37 node children (no *-gpios / reset / xclr present):
avdd-supply clock-names clocks compatible dvdd-supply name orientation
ovdd-supply phandle port reg rotation status
```

---

## 4. Reference frames (saved in `rpi5_reference/`)

| File | What | Notes |
|---|---|---|
| `ref_day.jpg` | 3864×2192 processed JPEG (auto AE/AWB via ISP) | visual reference of the scene |
| `ref_raw.raw` | 3 frames, unpacked 16-bit Bayer | see geometry below |

Captured with:
```
rpicam-still -n -t 2000 -o rpi5_reference/ref_day.jpg
rpicam-raw  -n --frames 3 --mode 3864:2192:10:U -o rpi5_reference/ref_raw.raw   # then truncated to 3 frames
```

**`ref_raw.raw` geometry — important:**
- Format `SGBRG16` (GBRG, little-endian uint16), **10-bit data MSB-aligned** (value = `sample >> 6`).
- **Stride = 7744 bytes**, not 3864·2 = 7728 → **16 bytes (4 px) row padding**.
  Reshape as **3872 uint16/row**, then slice `[:, :3864]`. This is exactly the
  stride > width case Appendix A warns about.
- Frame size = 7744 · 2192 = 16 974 848 bytes; file holds 3 identical-scene frames.

Quick sanity stats (frame 0, in 16-bit units):
```
min=1920  max=65472(=1023<<6)  mean=12646  median=10112
GBRG plane means:  G1=15947  B=8283  R=10404  G2=15951   # green highest → real daylight-ish scene
```
Viewer (`Додаток A`): use **`shift = 6`** and **width = 3872** (or crop to 3864) for this file.

---

## 5. Reproduce
```bash
# state
uname -r
grep imx415 /boot/firmware/config.txt
# detection + params
dmesg | grep -i imx415
rpicam-hello --list-cameras
sudo i2cdetect -y -r 10
v4l2-ctl -d /dev/v4l-subdev2 -L
v4l2-ctl -d /dev/v4l-subdev2 --list-subdev-mbus-codes
sudo grep -i cam /sys/kernel/debug/clk/clk_summary   # crystal
media-ctl -p -d /dev/media0
```

---

## 6. IR-CUT — CLOSED 2026-07-11 (no wiring was needed)

The premise below ("must be wired to a Pi GPIO") turned out wrong: the spec
drawing (`reference/IMX415-98-IR-CUT-Camera-Specification.pdf`) shows the
control comes in over the FFC — module pin 5 "IR-CUT" (H-bridge direction),
pin 6 "GPIO-H". On the Jetson P3768 CAM1 connector pin 5 lands on pin 18 =
pad `extperiph2_clk_pp1` = GPIO PP.01, which the stock MCLK pinmux was
force-driving to 0 V (= filter stuck at night, switch dead).

**Result (validated on target):** pinmux the pad to `rsvd1`/GPIO (overlay
fragment@1) → line hi-Z when unclaimed = physical switch works; drive PP.01
to select the mode from software (`tools/ircut.sh`). **Polarity: day
(filter IN) = HIGH, night (IR) = LOW.** Full story:
`phase_g_validation.md`, "IR-CUT control line found on the FFC".

Everything else in Phase A was already complete — Phase A is now fully closed.

---

## 7. Filled passport rows (guide §10) obtainable on RPi

| Guide row | Value |
|---|---|
| Кварц модуля | **37.125 МГц** |
| I2C-адреса | **0x37** (not 0x1a) |
| Bayer-порядок | **GBRG** |
| Розміри кадру reference-драйвера | **3864×2192**, single mode, **15 fps** |
| link_freq для INCK 37.125 | **445.5 МГц** |
| pix_clk_hz (розрахунок) | **178 200 000** (line_length 5280, 15 fps) |
| Полярність IR-CUT | **день = HIGH, ніч = LOW** (закрито 2026-07-11 на Jetson через FFC/PP.01 — §6) |

Jetson-side rows (L4T version, CAM port, I2C bus on Jetson, donor overlay,
tegra_sinterface, fourcc on VI) are filled during Phases B–G on the devkit.
