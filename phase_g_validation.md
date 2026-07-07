# Phase G — validation on target (2026-07-07, evening)

Target: Jetson Orin Nano devkit, boot entry `imx415` (now DEFAULT — no serial
console attached), module autoloads at boot via OF alias (no modules-load.d
needed).

## Ladder status (guide §8.1)

| Rung | Result |
|---|---|
| 1. I2C/probe | ✅ `imx415 9-0037: tegracam sensor driver:imx415_v2.0.6`; chip-ID check passed; unsigned-module taint warning is expected and harmless |
| 2. media graph | ✅ `imx415 9-0037 → nvcsi → vi-output`, fmt `SGBRG10_1X10/3864x2192@1/15` |
| 3. formats | ✅ fourcc **GB10**, 3864×2192 @15 fps (passport §10 row closed) |
| 4. controls | ✅ gain 0–30000/300, exposure 119–66431, frame_rate ≤15 fps — DT contract intact |
| 5. capture | ✅ 30/30 frames, delta locked 66.665 ms = **15.00 fps**, zero jitter, no errors (after the embedded_metadata_height fix below) |
| 6. frame content | ✅ real scene, geometry clean (uniform row means top/bottom, no OB band), GBRG planes sane |
| 7. stability 10 min | ⏳ pending |
| controls change image | ⏳ pending (exposure sweep) |

## Debug story: every frame discarded (fixed)

First capture: frames at exactly 15 fps, full bytesused, but VI discarded all —
`corr_err: discarding frame 0, flags: 0, err_data 16384` per frame.

- err_data is **deprecated** on T234 (camrtc-capture.h) and not filled by any
  kernel code (RCE firmware internal); 16384 = 1<<14 ≈ FALCON_ERROR class =
  CHANSEL fault family. Don't try to decode it numerically.
- RTCPU ftrace (`events/tegra_rtcpu`) emits **0 events** on this target/L4T —
  the §8.2 recipe is a dead end here; `/sys/kernel/debug/camrtc` doesn't exist.
- v4l2-ctl does **not** write errored buffers to `--stream-to` (cap.raw was 0 B).
- Root cause found by comparing with the **working FRAMOS IMX715 overlay** for
  the same devkit/port/lanes (`reference/fr_imx715-cam1-2lane-overlay-l4t-r36.4.4.dts`):
  every mode there has `embedded_metadata_height = "1"` — the sensor family
  transmits 1 embedded-data line per frame. RP1 (RPi) tolerates it silently;
  Tegra VI raises CHANSEL_EMBED_INFRINGE and discards the frame.
- Fix: `embedded_metadata_height = "1"` in mode0 (commit 300230b). One reboot
  later: perfect capture.

## VI RAW10 memory format — measured, definitive (closes Додаток A "shift")

VI writes 10-bit samples into 16-bit little-endian words **MSB-aligned with
LSB replication**: `raw16 = (p << 6) | (p >> 4)`. Verified on a full frame:
100.00% of pixels match this encoding exactly.

- To get 10-bit values: `p = raw16 >> 6` (**shift = 6**, same as RPi's CFE).
- Stride: **no padding** on Jetson — 7728 B/row = 3864×2 exactly (RPi pads to
  7744; slice `[:, :3864]` there).
- Full-range max = 65472+15 = 65487 (1023<<6 | 1023>>4).

First frame stats (dim indoor evening scene): 10-bit min 0 / max 183 /
mean 68.5 vs black level 50; GBRG plane means G 69.6 / B 62.8 / R 71.8 —
R slightly above G is consistent with tungsten light and/or IR-CUT open.
Comparison render vs RPi reference: both scenes coherent, no artifacts.

## Frame analysis snippets (workstation)

```python
a = np.fromfile("jetson_frame0.raw", dtype=np.uint16, count=3864*2192).reshape(2192, 3864)
p = a >> 6   # 10-bit
```
Full renderer: scratchpad `render_frame.py` pattern — luminance = 2×2 quad mean;
quick color: G=(0,0)+(1,1), B=(0,1), R=(1,0), subtract black 50, gray-world WB.

## Remaining

1. Exposure/gain reaction test (means must track control values).
2. 10-minute stability stream (9000 frames, no `--stream-to`).
3. Final checklist §10 + IR-CUT polarity (hardware, still open from Phase A).
