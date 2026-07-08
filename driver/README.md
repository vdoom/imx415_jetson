# nv_imx415 driver sources (Phase D)

**Written 2026-07-07** on the build host. These are the canonical versioned
copies; the build happens in the BSP tree at
`~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra/source/nvidia-oot/drivers/media/i2c/`
(same files + one Makefile line, see `Makefile.patch.note`). If the copies
ever diverge, the BSP tree is the one that was actually built — re-sync from
there.

## Status: builds clean (zero warnings, `-Werror` active)

`nv_imx415.ko`: vermagic `5.15.185-tegra SMP preempt mod_unload modversions aarch64`
(= target), alias `of:N*T*Csony,imx415*`, depends `tegra-camera`.
**Not yet tested on hardware** — that's Phase F/G.

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
