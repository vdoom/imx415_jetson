# imx415_debayer — CUDA debayer pipeline (Phase H)

Single-file CUDA app: V4L2 mmap capture of the raw GB10 stream → one fused
GPU kernel → packed RGB8 in device memory at 1932×1096 (or 1920×1080 with
`--crop1080`), 30 fps.

The kernel fuses: 10-bit unpack (`raw16 >> 6`, the measured VI alignment) →
black-level subtract (50) → GBRG 2×2 quad debayer to half resolution (no
zippering, effectively 2×2 binning) → white balance → normalize → gamma 2.2
(or `--linear` for inference).

## Build (on the Jetson)

```bash
cd cuda_debayer
make            # uses /usr/local/cuda/bin/nvcc, -arch=sm_87
```

## Run

```bash
./imx415_debayer --frames 300                      # bench: expect ~30 fps
./imx415_debayer --snap out.ppm --awb              # save frame 30 as PPM
./imx415_debayer --crop1080 --linear --frames 300  # inference-style config
```

- `--awb` — gray-world white balance from the first frame
- `--wb R G B` — manual channel gains
- `--linear` — skip gamma (linear RGB for ML preprocessing)
- Sensor exposure/gain are *not* set here — use v4l2-ctl before/independently:
  `v4l2-ctl -d /dev/video0 -c exposure=16000,gain=6000`
- Only one process can own /dev/video0 — stop the MJPEG viewer first.

## Integration point

After the kernel launch, `d_rgb` holds the processed frame on the GPU —
marked in `main.cu` with `>>> Integration point <<<`. Hand that pointer to
your consumer (CUDA preprocessing for inference, NVENC via NvBufSurface
copy, etc.). For zero-copy tightening later: the HtoD memcpy (~3–5 ms of
the 33 ms budget) can be eliminated with V4L2 DMABUF export + EGLImage /
NvBufSurface import, at the cost of significant plumbing — do it only if
the copy actually shows up in your profiles.

## Validation status

- Compiled clean for sm_87 (CUDA 12.6).
- Kernel functionally verified on the host GPU against a real captured
  Jetson frame (geometry, colors, AWB): 0.20 ms/frame on a GTX 1060.
- End-to-end 30 fps bench on the Orin: pending first run on target.
