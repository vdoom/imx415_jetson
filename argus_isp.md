# Argus/ISP support (Phase H) — host work done 2026-07-12; core VALIDATED on target 2026-07-13

## Target validation 2026-07-13

- **Argus works**: daemon enumerates both modes, `fps` and `snap` ran clean.
  The enumeration line proves the dB conversion:
  `Analog Gain range min 1.000000, max 31.622776` = exactly 0–30 dB as
  linear multipliers; exposure range 59000–33200000 ns = the DT 59–33200 µs.
- **`view` initially failed** with `not-negotiated (-4)`: `v4l2sink`'s
  buffer-pool proposal on a v4l2loopback device breaks `nvvidconv`'s
  allocation query. Fixed in `tools/argus_check.sh` with the standard
  `identity drop-allocation=1` shim before `v4l2sink`.
- **Stray tuning file found**: the target had a
  `/var/nvidia/nvcam/settings/camera_overrides.isp` — per the user, an old
  image-quality fix **for the stock IMX219**. The file is global (applies
  to every camera), so it was silently tuning the IMX415 too — that
  explains `LSC: LSC surface is not based on full res!` (IMX219-sized
  lens-shading surface vs our 3864×2192). This JP6 daemon also rejects a
  large chunk of its attributes (`em.*`, `ltm.*`, `dae.*`, …) — it's from
  an older JetPack's schema. Stashed to `~/camera_overrides.isp.stashed`
  (restore only if the IMX219 boot entry is used again); colors must be
  judged on snaps taken *after* the stash + daemon restart. If both
  cameras ever run together, write a module-scoped override for the
  IMX415 badge instead of a global file.

Goal: `nvarguscamerasrc`/libargus pipelines (hardware ISP: demosaic, AE, AWB,
noise reduction, YUV out) on top of the existing IMX415 port, without breaking
the validated raw-V4L2 + CUDA path.

## What Argus needs vs what we already had

Argus discovers cameras from the device tree (`tegra-camera-platform` module
list) and drives the sensor through the same tegracam V4L2 controls the raw
path uses (gain / exposure / frame_rate / group_hold / sensor_mode_id). The
Phase D/E work already provided ~everything: full per-mode control properties,
`use_sensor_mode_id`, real `pix_clk_hz`/`line_length` (validated by the
exposure/gain work), `embedded_metadata_height = "1"`, and a stock-shaped
platform module with badge/position/orientation. **The driver needed zero
changes** (ko stays sha1 19169df3).

Three DT gaps were closed on 2026-07-12 (dtbo sha1 53381cb5). All three are
read only by the Argus userspace (nvargus daemon parses the DT via the
`sysfs-device-tree` path); the kernel ignores them, so raw V4L2 semantics are
byte-for-byte unchanged:

1. **`use_decibel_gain = "true"`** in the sensor node. Argus's gain API is a
   *linear multiplier* (`setGainRange`, `gainrange` on nvarguscamerasrc); our
   driver's gain control is **dB × 1000** (validated against I2C readback).
   Without this property Argus would write its linear values straight into a
   dB control — monotonic (AE would still converge) but wrong scale and wrong
   reported gains. With it, the camera core converts linear → dB before
   setting the control. Proof of concept: the Argus-supported FRAMOS IMX715
   overlays (`reference/fr_imx715-*.dts`) ship exactly this with the same
   0.3 dB/step register (gain_factor 10, 0..720 = 0..72 dB; ours: factor
   1000, 0..30000 = 0..30 dB analog).
2. **`lens_imx415@IMX41598`** node under `bus@0`: EFL 3.95 mm, F/2.0 (real
   values from `reference/IMX415-98-IR-CUT-Camera-Specification.pdf`; 98° FOV,
   fixed focus 20 cm–∞). Argus surfaces these as camera properties.
3. **`drivernode1` (`pcl_id = "v4l2_lens"`)** in the platform module pointing
   at the lens node — restores the stock imx219-C module shape (Phase E had
   dropped it for lack of lens data).

Non-changes, checked deliberately:

- **Gain stays 0–30 dB analog.** The IMX415 register accepts up to 72 dB
  (analog+digital, same 0.3 dB steps — the FRAMOS sibling ships 720); the
  driver caps at 100 (30 dB). Extending would help Argus AE in the dark but
  changes the validated driver + the raw-path AE tool's assumptions —
  deliberate follow-up, not part of this phase.
- **No `tegra-camera-platform` bandwidth props** (`num_csi_lanes`,
  `isp_peak_byte_per_pixel`, …): the stock JP6 p3768 overlays don't set them
  either (checked `tegra234-camera-rbpcv2-imx219.dtsi`).
- **`devname` in drivernode0**: stock JP6 omits it; the `sysfs-device-tree`
  path is what matters.
- **`override_enable` assert in `set_mode`** (the 2026-07-10 fix) stays: Argus
  reprograms exposure/gain per-frame immediately after stream-on, so the
  one-time application of cached control values at most affects the first
  frames.

## Deploy (user, on target)

Standard flow, dtbo-only change (fresh dated copy — remember the 2026-07-10
stale-deploy trap):

```bash
# host:
scp -r deploy/ orca@<jetson-ip>:~/imx415_deploy_20260712/
# target:
cd ~/imx415_deploy_20260712 && sudo ./install_on_target.sh   # idempotent
sudo reboot   # boot the imx415 entry
```

## Validate (user, on target) — `tools/argus_check.sh`

```bash
./argus_check.sh            # DT check + 300-frame fps run through the ISP (mode0)
./argus_check.sh fps 1      # same, 12-bit mode1
./argus_check.sh snap       # AE/AWB-settled JPEG -> /tmp/argus_snap.jpg
./argus_check.sh view       # ISP -> /dev/video10 -> ustreamer in the browser
sudo ./argus_check.sh debug # foreground daemon with PCL/SCF logs (if anything fails)
```

Success criteria: `fps` reports average ≈29.9–30.0 for both modes; `snap` is a
correctly exposed, correctly white-balanced photo; daemon journal free of
SCF/ICP errors across repeated runs.

## Known caveats going in

1. ~~The 4-lane row slip is NOT compensated in the Argus path~~ —
   **RESOLVED 2026-07-13, and the answer is a root-cause bombshell: the
   Argus/ISP output has NO row slip.** Full-res crops of the v2 target snap
   (sharp bezel edges, 3× nearest-neighbor) show clean straight edges — a
   ±8/±12 px 4-row staircase would be unmissable at that zoom and cannot be
   smoothed away by NR. Same sensor, same 4-lane/891M link, same HMAX — so
   the slip is NOT a sensor/link/PHY defect: it lives in how the *kernel
   V4L2 capture path* programs NVCSI/VI versus how Argus's RTCPU-driven
   capture path does. Consequences: (a) ISP consumers need no compensation,
   ever; (b) the raw-V4L2 path still slips and keeps the CUDA dezigzag;
   (c) the pending root-cause probe changes target: diff the VI/NVCSI
   channel programming between the two paths (not HMAX margin, not FFC
   reseat).
2. **Colors come from NVIDIA's default tuning** — no `.isp` override shipped.
   ~~If not good enough: tuning file follow-up.~~ **Resolved 2026-07-13**:
   default tuning proved unacceptable (milky haze = under-subtracted black
   level, confirmed by snap comparison vs the old IMX219 overrides whose
   pedestal block was doing the heavy lifting). Our own override file lives
   in `tuning/camera_overrides.isp` (pedestal 60/1023 + RPi-calibrated CCM);
   schema ground truth and iteration loop in `tuning/README.md`.
3. **Two modes, same resolution** (10-bit mode0 / 12-bit mode1): Argus mode
   selection by resolution is ambiguous — always pass `sensor-mode=0|1`
   explicitly (the check script does).
4. **Mixing Argus and raw tools**: Argus sets `sensor_mode` itself and the
   control **latches across processes** (the 2026-07-08 gotcha); the raw
   tools already pin it, keep doing that. Don't run v4l2 streams and Argus
   concurrently — one consumer at a time, and `sudo systemctl restart
   nvargus-daemon` if the daemon ever wedges after a killed client.
