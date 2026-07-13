# IMX415 → Jetson Orin Nano: full camera bring-up

Complete, from-scratch port of the **Waveshare IMX415-98** camera module
(Sony IMX415, 8.4 MP, 22-pin FFC, IR-CUT) to the **Jetson Orin Nano devkit**
(P3768 carrier, CAM1 connector) on **JetPack 6.2.2 / L4T r36.5.0** — no
vendor driver existed for this combination. Everything here was built on an
x86 host against the exact target BSP and validated on the device.

## What works (all target-validated)

- **Kernel driver** `nv_imx415.ko` (tegracam): 3864×2192 @ 30 fps over
  4 CSI lanes @ 891 Mbps, 10-bit and 12-bit modes, correctly functioning
  V4L2 exposure/gain/frame-rate controls (incl. fixes for tegracam's
  silent control-caching traps).
- **Device-tree overlay** for CAM1: full Argus-grade mode tables, embedded-
  metadata handling, IR-CUT pinmux fix (software day/night switching).
- **Two independent consumption pipelines**, switchable at runtime:
  - **Argus / hardware ISP** — `nvarguscamerasrc`, hand-built ISP tuning
    (black level + saturation), clean of the raw-path row-slip artifact;
  - **CUDA debayer** — custom GPU pipeline on raw `/dev/video0`:
    RPi-calibrated CCM/ALSC color, auto-exposure, row-slip compensation,
    zero-copy V4L2 → GPU.
- **Webcam bridge**: either pipeline → v4l2loopback → any V4L2 app,
  browser live view via ustreamer.
- **One-shot installer** for the target (module + overlay + boot entry +
  ISP tuning, idempotent, checksum-verified).

## Start here

| Goal | Doc |
|---|---|
| Run the camera (either pipeline, switching, browser view, IR-CUT) | [USAGE.md](USAGE.md) |
| Install everything on a target | [deploy/README.md](deploy/README.md) |

## Documentation map

**Hardware & ground truth**

- [passport.md](passport.md) — the "passport": every measured fact about
  the module, carrier and target (pinouts, clocks, link config, register
  ground truth, validation checklists).
- [rpi5_imx415_data.md](rpi5_imx415_data.md) — reference captures and
  timing data of this module on a Raspberry Pi 5 (the known-good donor
  configuration the port was derived from).
- [imx415_jetson_porting_guide.md](imx415_jetson_porting_guide.md) — the
  original end-to-end porting plan the project followed (Ukrainian).

**Build & implementation**

- [host_build_phase_c.md](host_build_phase_c.md) — host toolchain setup and
  the verified BSP build recipe (kernel, OOT modules, dtbs).
- [driver/README.md](driver/README.md) — driver design, register
  provenance, and the exposure/gain/frame-rate fix story
  (`override_enable`, VMAX/SHR0 interaction).
- [dt/README.md](dt/README.md) — overlay deltas vs the stock imx219-C
  donor, incl. the embedded-metadata and IR-CUT stories.
- [deploy/README.md](deploy/README.md) — shipped artifacts, installer
  behavior, first-validation steps.

**Runtime, ISP & color**

- [USAGE.md](USAGE.md) — running both pipelines and everything downstream.
- [argus_isp.md](argus_isp.md) — Argus/ISP enablement (Phase H): what the
  camera core needed, gain-semantics (`use_decibel_gain`), validation log,
  and the row-slip root-cause finding.
- [tuning/README.md](tuning/README.md) — ISP tuning: the JP6 override-file
  schema ground truth (accepted vs rejected keys) and the v1→v3 iteration
  log (pedestal, CCM-vs-AWB interaction, saturation matrix).
- [tools/cuda_debayer/README.md](tools/cuda_debayer/README.md) — the GPU
  pipeline: fused debayer kernel, calibrated color, auto-exposure,
  row-slip measurement/compensation, loopback bridge.

**Validation history**

- [phase_g_validation.md](phase_g_validation.md) — first light on the
  target and the hard-won VI facts (embedded metadata, RAW10 memory
  format, error-code decoding).

## Provenance

Register tables and mode timings from the Raspberry Pi kernel's `imx415.c`
(rpi-6.12.y); color calibration from Raspberry Pi's libcamera PiSP tuning
for this exact sensor; FRAMOS `fr_imx715` (register-compatible sibling,
same L4T generation) as the tegracam reference; NVIDIA's `nv_imx219.c` as
the driver skeleton. Key reference files are archived in `reference/`.
