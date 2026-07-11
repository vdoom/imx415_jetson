# imx415_debayer — CUDA debayer pipeline (Phase H)

Single-file CUDA app: V4L2 mmap capture of the raw GB10 stream → one fused
GPU kernel → packed RGB8 in device memory at 1932×1096 (or 1920×1080 with
`--crop1080`), 30 fps.

The kernel fuses: 10-bit unpack (`raw16 >> 6`, the measured VI alignment) →
black-level subtract (60, from the RPi calibrated tuning file) → GBRG 2×2 quad
debayer to half resolution (no zippering, effectively 2×2 binning; R and B
are bilinearly resampled to the quad center — co-sited with G — killing the
green/magenta edge fringing of a naive quad collapse: |R−B| on a synthetic
achromatic edge drops 40→10 for realistic 4 px edges, 159→79 worst-case hard
step) → white balance → **ALSC lens-shading correction** → highlight clamp →
**color-correction matrix** → gamma 2.2 (or `--linear` for inference).
The lens's own lateral CA is *not* corrected (the RPi tuning file's `rpi.cac`
block is empty for this module — no factory calibration exists).

## ⚠ 4-lane link row slip — auto-compensated (`--no-dezigzag` disables)

The 4-lane/891M link delivers frames with a deterministic transport defect:
2-row blocks alternately displaced ±8 sensor px horizontally (period 4 rows,
pattern `+8 −8 −8 +8` by `row & 3`), measured directly on raw CFA planes —
present in every frame, absent in the archived 2-lane capture. Visible as
green/purple fringes on every edge plus fake "soft focus" (the ±8 px comb
averages into horizontal blur; fine text is unreadable). Root cause is in
the sensor/link layer, not the sensor registers (byte-for-byte upstream) —
diagnose with `tools/zigzag_check.sh` (HMAX-margin test) and by reseating
the FFC cable. Until a hardware-level fix is found, the tool measures the
slip at startup from scene texture (retries if too flat) and reads every
sensor row at its compensated x in the kernel — validated on the captured
artifact frame: fringes gone, box text legible again. Raw `/dev/video0`
consumers other than this tool still see the slip.

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
./imx415_debayer --ae --frames 300                  # point-and-use: AE + auto color
./imx415_debayer --ae --snap out.ppm                # exposed + color-corrected snap
./imx415_debayer --exposure 33000 --gain 21000 \
                 --snap out.ppm                     # manual exposure, auto color
./imx415_debayer --crop1080 --linear --frames 300   # inference-style config
./imx415_debayer --bits 12 --ae --snap out12.ppm    # 12-bit mode (mode1)
```

- `--ae` — auto-exposure: meters the mean green level (full frame,
  subsampled, ~0.15 ms CPU every other frame) and drives sensor exposure
  first, then gain, in a damped log-domain loop (deadband ±10%, ~4-frame
  settle per step, converges in ~1 s from a bad start). Highlight guard
  steps down when >2% of samples clip. `--exposure/--gain` seed the loop.
- `--ae-target F` — linear mean target, default 0.10 (≈0.35 after gamma)
- `--ae-max-exp US` — exposure ceiling before gain kicks in, default 33000
  (stays within the 30 fps frame; raise only if lower fps is acceptable)
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
- `--loopback /dev/videoN` — re-export the processed stream (see below)
- `--frames 0` — run until Ctrl-C (default when `--loopback` is given)
- Only one process can own /dev/video0 — stop the MJPEG viewer first.

## Loopback bridge — use the camera from any app

`--loopback` turns the tool into a producer daemon: it owns /dev/video0,
runs AE + the color pipeline, converts RGB→YUYV on the GPU (BT.601,
host-verified kernel) and writes frames into a v4l2loopback device. Every
V4L2 app then sees a normal 1932×1096@30 webcam named "IMX415" — this is
the missing libcamera/nvargus layer for this sensor.

One-time setup on the Jetson:

```bash
sudo apt install v4l2loopback-dkms   # builds against 5.15.185-tegra
sudo modprobe v4l2loopback video_nr=10 card_label="IMX415" exclusive_caps=1
# persist across reboots:
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback video_nr=10 card_label="IMX415" exclusive_caps=1' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
```

Run the bridge, then consume from anything:

```bash
./imx415_debayer --ae --loopback /dev/video10 &

ffplay /dev/video10                          # local display
vlc v4l2:///dev/video10                      # local display
gst-launch-1.0 v4l2src device=/dev/video10 ! xvimagesink
python3 -c "import cv2; c=cv2.VideoCapture(10); ..."   # OpenCV
# browser over LAN (same workflow as view_stream.py):
sudo apt install ustreamer
ustreamer -d /dev/video10 -s 0.0.0.0 -p 8080   # then http://<jetson>:8080/
```

Notes: `exclusive_caps=1` is required for Chrome/WebRTC to accept the
device. The YUYV conversion adds one GPU kernel + a 4.2 MB host-visible
write per frame (host-mapped pinned buffer, no separate DtoH copy). AWB
locks once at startup; restart the bridge after drastic lighting-type
changes (CT/CCM re-lock — AE keeps adapting continuously regardless).

## Integration point

After the kernel launch, `d_rgb` holds the processed frame on the GPU —
marked in `main.cu` with `>>> Integration point <<<`. Hand that pointer to
your consumer (CUDA preprocessing for inference, NVENC via NvBufSurface
copy, etc.).

## Validation status — VALIDATED on target (2026-07-10)

- 30.0 fps sustained, zero-copy input, kernel 1.9 ms/frame with the full
  color pipeline (ALSC + CCM add ~0.7 ms over the 1.17 ms raw kernel).
- **AE validated on target**: dark room from 10 ms/0 dB start → 33 ms +
  10.2 dB in 4 steps (~1.3 s), means 0.005→0.026→0.067→0.088, settles in
  the deadband, no overshoot/hunting, 29.99 fps; every step matches the
  controller math exactly. AWB dark-retry engaged as designed (locked at
  frame 38 after AE brightened the scene). `--snap` waits for color lock
  since the fix below the trace was taken.
- Auto color validated on target: warm chandelier scene → CT est. 3109 K,
  white ceiling renders neutral (r/g 1.007, b/g 1.036), blown lamp rolls to
  white (no pink halo), corner color shading strongly reduced by ALSC.
- CT estimate consistent between 10-bit and 12-bit modes (3109 vs 3118 K on
  the same scene).
- IR-cut day mode confirmed by data: raw R/G 0.54 under mixed light — an
  IR-open sensor would show R/G ≈ 1.
