# nv_imx415 driver sources (Phase D)

**Written 2026-07-07** on the build host. These are the canonical versioned
copies; the build happens in the BSP tree at
`~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra/source/nvidia-oot/drivers/media/i2c/`
(same files + one Makefile line, see `Makefile.patch.note`). If the copies
ever diverge, the BSP tree is the one that was actually built — re-sync from
there.

## Status: builds clean (zero warnings, `-Werror` active)

**72 dB gain (2026-07-13, ko sha1 5cea9ce1):** `IMX415_GAIN_REG_MAX`
100 → 240, dB max 30 → 72 (paired DT `max_gain_val` 72000). The
dB→register mapping (reg = dB/0.3) is byte-identical below 30 dB — only
the clamp moved — so the 2026-07-10 register-exact validation still
holds; >30 dB engages the sensor's digital gain (Rockchip ships 0–0xf0,
FRAMOS IMX715 uses the same 240/72 conversion). **VALIDATED on target
2026-07-13** (`tools/gain72_check.sh`): GAIN_PCG_0 byte-exact at
15/30/45/72 dB → 0x32/0x64/0x96/0xf0, brightness strictly increasing,
Argus enumerates gain 1–3981×. NB values beyond 72000 are silently
CLAMPED by the v4l2 framework (spec behavior), not rejected.

`nv_imx415.ko`: vermagic `5.15.185-tegra SMP preempt mod_unload modversions aarch64`
(= target), alias `of:N*T*Csony,imx415*`, depends `tegra-camera`.
**Not yet tested on hardware** — that's Phase F/G.

## override_enable default (fixed 2026-07-10, v2: set in set_mode, not probe)

`imx415_set_mode()` now asserts `s_data->override_enable = true` at every
stream-on. **The first attempt set it at probe — that does not work**: the
VI channel re-inits its control handler on first open of /dev/video0 and
`v4l2_ctrl_handler_setup()` pushes the OVERRIDE_ENABLE control default (0)
through s_ctrl, which clears the field (`vi/channel.c`, the
`TEGRA_CAMERA_CID_OVERRIDE_ENABLE` case; found on target: after a clean
boot with the probe-fix module, `-C override_enable` read 0). In
`tegracam_v4l2.c` s_stream the framework calls `set_mode` *before* the
`if (s_data->override_enable)` gate that applies cached gain/exposure/
frame_rate, so asserting it there always wins.

Verification is **behavioral** — the OVERRIDE_ENABLE control readback is
the VI channel's own cached value (default 0), never synced from the field,
so `-C override_enable` reading 0 is normal and meaningless. Instead:
stream and check `v4l2-ctl -c gain=15000` visibly brightens, or set
exposure/gain before a capture and confirm brightness tracks the values.
Consequence: the control can no longer disable the applied-at-stream-on
behavior persistently (next stream-on re-asserts it) — intentional, the
caching default protects nothing here. Argus (added 2026-07-12, DT-only —
see `../argus_isp.md`) is unaffected: it reprograms exposure/gain per-frame
through the same controls right after stream-on, so the one-time cached
application at most colors the first frames. The driver's gain contract
stays **dB × 1000** for everyone; Argus converts its linear multipliers
itself because the DT sets `use_decibel_gain = "true"` (userspace-only
property, the kernel never reads it).

**Two follow-up fixes (2026-07-10, found by on-target I2C readback once
overrides started applying):**

1. **FRAME_RATE control started at min (2 fps), not the DT default.**
   tegracam creates the control at 0 and `v4l2_ctrl_modify_range()` then
   clamps the *current value* to min_framerate — it never applies the new
   default. With overrides active, every stream-on programmed VMAX 33750
   (2 fps) unless userspace set frame_rate explicitly. Probe now
   initializes the control to `default_framerate` (30 fps) after subdev
   registration; later user writes persist (the VI channel's first-open
   handler re-init only re-applies defaults of controls it owns).
2. **`set_frame_rate` re-applies the last requested exposure.** SHR0
   encodes exposure relative to VMAX, and stream-on overrides apply
   exposure *before* frame rate (`tegracam_override_cids` order), i.e.
   against the previous VMAX — first stream after a frame-rate change got
   a wildly wrong integration time (measured: requested 1 ms, got 467 ms).
   `priv->last_exposure_us` is re-derived after every VMAX write.

Current `deploy/nv_imx415.ko` = sha1 19169df3 (vermagic = target).
Module sha1 history: 560f3796 = 2-lane Phase F originals, d3eab08c =
4-lane, b1868dae = +12-bit, a89d348c = probe-fix (broken), 9d066f36 =
set_mode fix (streams 2 fps), 19169df3 = +frame-rate default + exposure
re-derive.

**VALIDATED on target 2026-07-10** (`tools/expo_gain_check.sh`, I2C
readback mid-stream, 19169df3 installed): VMAX 2250 (30 fps) in all runs;
exposure=1000 µs → SHR0 2183 (= 67 lines = 1.00 ms exact), gain 0;
exposure=33000 µs, gain=15000 → SHR0 23 (= 2227 lines = 33.0 ms exact),
GAIN_PCG_0 0x32 (15.0 dB). Means reproducible across repeat runs
(50.6/168.7/50.8). Plain `v4l2-ctl -c exposure=...,gain=...` works with
no override_enable dance.

Why: the tegracam framework **silently discards** user gain/exposure/
frame_rate writes unless `override_enable` (control 0x009a2065, default 0)
is 1 — S_CTRL returns success but the sensor registers never change.
Measured on target 2026-07-10 by direct I2C readback while streaming:
GAIN_PCG_0/SHR0 stayed frozen at mode defaults (gain 0, SHR0 8) through any
`v4l2-ctl -c`; full experiment log in `phase_g_validation.md`. With the flag
set, both stream-start application and mid-stream changes are register-exact
(gain 15000 mdB → GAIN_PCG_0 0x32; exposure 10000 µs → SHR0 1575 @ VMAX 2250).

Rationale for a driver-side default: this sensor is raw-V4L2-only (no
Argus/ISP tuning exists for it), so NVIDIA's default-0 protects nothing here
and only breaks standard V4L2 tooling. The OVERRIDE_ENABLE control remains
functional for switching the caching behavior back at runtime. The field is
set once at probe and survives device open/close cycles (verified on target:
nothing re-applies the control default after probe).

Until the rebuilt .ko is deployed, userspace must set `override_enable=1`
itself — `tools/view_stream.py` and `tools/cuda_debayer` already do, and
that stays in place as belt-and-suspenders (harmless with the new driver).

## Provenance of every register value

| Block | Source |
|---|---|
| Init table ("Sony magic" + readout/RAW10 setup) | rpi-6.12.y `imx415_init_table[]`, byte-for-byte |
| Clock config (INCK 37.125 MHz / 891 Mbps) | rpi-6.12.y `imx415_clk_params[]` entry {37125000, 891M}; cross-checked identical to FRAMOS `fr_imx715_891_data_rate[]` |
| D-PHY timing (891 Mbps) | rpi-6.12.y `imx415_linkrate_891mbps[]` |
| LANEMODE = 1 (2-lane) | rpi-6.12.y `IMX415_LANEMODE_2` |
| VMAX 2250 / HMAX 2200 / SHR0 8 defaults | rpi-6.12.y mode + `hmax_min[0]`=2200 for 2-lane@891M → 15 fps |
| 16/24-bit registers split little-endian | matches CCI `CCI_REG16_LE/24_LE` semantics of the RPi driver |

## Design decisions

- **Control semantics** (tegracam callbacks):
  - gain: DT `gain_factor=1000`, val = dB×1000 → reg = val/300 (0.3 dB steps, 0..100)
  - exposure: µs → lines via `pixel_clock/exposure_factor/line_length`; `SHR0 = VMAX − lines`, clamped to [4 lines, VMAX−8]
  - frame rate: via VMAX (24-bit), `line_length` (HMAX·12=26400 px) stays fixed
  - group hold: REGHOLD 0x3001 (1=hold, 0=apply) — real implementation, unlike imx219's no-op
- **80 ms standby-exit wait** in `imx415_start_stream[]` and `board_setup()`:
  datasheet says 63 µs; the RPi driver found even 30 ms insufficient and uses
  80 ms. Do not "optimize" this away.
- **Chip-ID probe check**: SENSOR_INFO 0x3F12/13 (& 0xFFF == 0x514) — readable
  only out of standby, hence the wakeup dance in `board_setup()`.
- **power_on releases XCLR high** (PAC.00 on CAM1) — sensor is I2C-dead while
  XCLR is low (verified empirically on the devkit, `passport.md` §1.3).
- **Expected DT mode0 properties** (must match; 4-lane values since 2026-07-08):
  `pix_clk_hz=356400000`, `line_length=5280`, `gain_factor=1000`,
  `min/max_gain_val=0/30000`, `step_gain_val=300`, `exposure_factor=1000000`,
  `min/max_exp_time≈59/33200`, `framerate_factor=1000000`,
  `min/max_framerate` up to `30000000`, `pixel_phase=gbrg`,
  `csi_pixel_bit_depth=10`, `num_lanes=4`, `tegra_sinterface=serial_c`,
  `embedded_metadata_height=1` (sensor sends 1 embedded line per frame —
  "0" makes VI discard every frame; learned in Phase G).
  Note `line_length=5280` in DT ≠ sensor H-total 13200: tegracam only uses it
  with `pix_clk_hz` for exposure/framerate math (356.4e6/5280 = 67500 lines/s
  = real line rate 1/14.81 µs ✓).
- **4-lane switch (2026-07-08)**: LANEMODE=3, HMAX=1100 (rpi driver's
  hmax_min for 4-lane@891M) → 30.0 fps. The validated 2-lane/15fps state is
  git tag `phase1-2lane-15fps` and `deploy/2lane-15fps-backup/`.
- **Sensor modes (2026-07-08)**:
  - mode0 = 3864x2192 **10-bit** 30fps (validated).
  - mode1 = 3864x2192 **12-bit** 30fps. Differs from mode0 by exactly three
    registers (ADBIT 0x3031, MDBIT 0x3032, ADBIT1 0x3701), verified against the
    Rockchip driver; same VMAX/HMAX/891M link. DT `mode1`: csi_pixel_bit_depth
    12, pix_clk_hz 297000000, line_length 4400. Select via `sensor_mode`
    control (0/1) or by requesting GB10 vs GB12. **Validated on target
    2026-07-08**: both GB10+GB12 enumerate at 3864x2192@30, GB12 streams flat
    30.00 fps clean; CUDA `--bits 12` 30.01 fps. NB: `sensor_mode` is an int64
    control -> needs VIDIOC_S_EXT_CTRLS, not S_CTRL (format also selects mode).
  - Crop 720p90 and binned 1944x1097 were requested but Rockchip only ships
    them at 2-lane/2376M and 594M respectively (not our 4-lane/891M) — those
    need derived timing and are deferred, not lifted verbatim.
