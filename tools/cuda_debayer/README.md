# imx415_debayer — CUDA debayer pipeline (Phase H)

Single-file CUDA app: V4L2 mmap capture of the raw GB10 stream → one fused
GPU kernel → packed RGB8 in device memory at 1932×1096 (or 1920×1080 with
`--crop1080`), 30 fps.

The kernel fuses: 10-bit unpack (`raw16 >> 6`, the measured VI alignment) →
black-level subtract (60, from the RPi calibrated tuning file) → GBRG 2×2 quad
debayer to half resolution (no zippering, effectively 2×2 binning) → white
balance → **ALSC lens-shading correction** → highlight clamp → **color-
correction matrix** → gamma 2.2 (or `--linear` for inference).

All color calibration data comes from Raspberry Pi's factory tuning file for
this exact sensor (`libcamera .../pisp/data/imx415.json`): the CCM table, the
AWB CT curve, and the 32×32 ALSC shading grids. `tuning_data.h` is generated
from the JSON by `gen_tuning.py`.

## Color pipeline (default: everything auto)

1. **AWB**: gray-world ratios measured on the central half of a warm-up frame
   (frame 8; the first frames don't have exposure applied yet).
2. **CT estimate**: the measured (R/G, B/G) point is projected onto the
   calibrated AWB CT curve → illuminant temperature.
3. **CCM + ALSC**: picked/interpolated for that CT. WB gains stay pure
   gray-world — this module sits ~0.07 off the RPi-calibrated locus (its
   IR-cut glass/lens differ from the unit RPi calibrated), so locking the
   white point to the curve leaves a green cast on neutral surfaces.
4. **Highlights**: channels are clamped to 1.0 *before* the CCM; green
   saturates first, so unclamped WB'd red/blue would tint blown highlights
   pink through the matrix.

## ⚠ override_enable — why exposure/gain ever worked at all

The tegracam framework **silently discards** user gain/exposure/frame_rate
writes unless the `override_enable` control is 1 (default 0): `v4l2-ctl -c
gain=...` returns success but GAIN_PCG_0/SHR0 never change (verified by
direct I2C readback while streaming). The tool now sets `override_enable=1`
at open, and `--exposure/--gain` make it self-contained. Anything else that
captures from this sensor must set it too.

## Build (on the Jetson)

```bash
cd cuda_debayer
make                    # uses /usr/local/cuda/bin/nvcc, -arch=sm_87
python3 gen_tuning.py   # only after changing reference/imx415-tuning-pisp.json
```

## Run

```bash
./imx415_debayer --frames 300                       # bench: expect ~30 fps
./imx415_debayer --exposure 33000 --gain 21000 \
                 --snap out.ppm                     # dim room, full auto color
./imx415_debayer --crop1080 --linear --frames 300   # inference-style config
./imx415_debayer --bits 12 --snap out12.ppm         # 12-bit mode (mode1)
```

- `--exposure US` / `--gain MDB` — sensor exposure (µs) and gain (milli-dB,
  0..30000); omitted = keep the last values set via v4l2-ctl
- `--bits 10|12` — sensor bit depth: selects DT mode0 (GB10) or mode1 (GB12)
  via the sensor_mode control and sets the VI unpack shift (>>6 or >>4)
- `--no-awb` — skip AWB measurement (unity gains unless `--wb`/`--ct`)
- `--wb R G B` — manual channel gains (CT still auto-estimated for CCM/ALSC)
- `--ct <kelvin>` — force CT: picks CCM + ALSC tables, and WB gains from the
  calibrated curve when AWB is off (manual WB by temperature)
- `--no-ccm` — identity CCM (raw WB'd color, e.g. to compare)
- `--no-alsc` — disable lens-shading correction
- `--linear` — skip gamma (linear RGB for ML preprocessing; CCM still applied)
- Only one process can own /dev/video0 — stop the MJPEG viewer first.

## Integration point

After the kernel launch, `d_rgb` holds the processed frame on the GPU —
marked in `main.cu` with `>>> Integration point <<<`. Hand that pointer to
your consumer (CUDA preprocessing for inference, NVENC via NvBufSurface
copy, etc.).

## Validation status — VALIDATED on target (2026-07-10)

- 30.0 fps sustained, zero-copy input, kernel 1.9 ms/frame with the full
  color pipeline (ALSC + CCM add ~0.7 ms over the 1.17 ms raw kernel).
- Auto color validated on target: warm chandelier scene → CT est. 3109 K,
  white ceiling renders neutral (r/g 1.007, b/g 1.036), blown lamp rolls to
  white (no pink halo), corner color shading strongly reduced by ALSC.
- CT estimate consistent between 10-bit and 12-bit modes (3109 vs 3118 K on
  the same scene).
- IR-cut day mode confirmed by data: raw R/G 0.54 under mixed light — an
  IR-open sensor would show R/G ≈ 1.
