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

## Validation status — VALIDATED on target (2026-07-08)

- Orin Nano, 300-frame bench: **30.0 fps, zero-copy input, kernel 1.17 ms/frame**
  (3.5% of the 33 ms budget), copy 0.00 ms, CPU core freed.
- The first (memcpy) variant measured 17.3 ms/frame for the HtoD copy — the
  V4L2 buffers are uncached DMA memory (~1 GB/s for CPU reads). The zero-copy
  path (cudaHostRegister + device pointer) eliminates it entirely on Tegra.
- Kernel functionally verified against a real captured frame on a host GPU
  (geometry, colors, AWB) before deployment.
