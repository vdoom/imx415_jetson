# IMX415 ISP tuning (Argus color/contrast) — started 2026-07-13

`camera_overrides.isp` — hand-written override file for the JP6.2.2 nvargus
daemon. v1 fixes the two things the 2026-07-13 snap comparison proved wrong
with NVIDIA's default tuning:

1. **Black level** (`opticalBlack.*` = 60/1023): default under-subtracts the
   IMX415 pedestal → milky, low-contrast image with purple-lifted shadows.
   This was also why the user's old IMX219 overrides file (`reference/
   camera_overrides.isp.stashed`, pedestal 64) "looked better" in contrast —
   its accepted keys were doing exactly this one job.
2. **CCM** (`colorCorrection.srgbMatrix`): RPi-calibrated matrix for this
   module (4605 K entry of `reference/imx415-tuning-pisp.json`), transposed —
   NVIDIA's layout is column-sum-1, i.e. the transpose of the usual
   rows-sum-1 convention (verified against the IMX219 reference file where
   all three columns sum to exactly 1.0).

## Schema ground truth (JP6.2.2, R36.5.0)

Learned by diffing the daemon journal against the stashed IMX219 file — the
daemon logs `Error: Invalid isp config attribute` per rejected line and
silently accepts the rest:

| Accepted | Rejected (do not bother) |
|---|---|
| `opticalBlack.manualBias{R,GR,GB,B}` + `.float.*` | `gtm.*`, `ltm.*`, `dae.*` (tone) |
| `colorCorrection.srgbMatrix[0..2]` | `scene.brightnessKey`, `scene.toneTable.*` |
| `awb.GrayLine*`, `awb.{High,Low}U`, `awb.{UtoMIRED,MIREDtoU,UtoCCT,CCTtoU}` | `saturation.strength`, `sharpness.strength`, `noiseReduction.strength` |
| `lensShading.*`, `falloff_srfc.controlPoint`, `ap15Function.lensShading` | `sensor.companding.*`, `awb.nightmode.*`, `em.*` |

Consequence: **black level is the only contrast lever** on this JetPack —
there is no tone-curve control. Saturation/EE are available at runtime
instead (`nvarguscamerasrc saturation=… ee-mode=…`).

## Iteration loop

```bash
# target:
sudo cp camera_overrides.isp /var/nvidia/nvcam/settings/
sudo systemctl restart nvargus-daemon
./argus_check.sh snap
journalctl -u nvargus-daemon --no-pager | grep -ci "Invalid isp config"  # must be 0 for our file
# host:
scp orca@<ip>:/tmp/argus_snap.jpg snap_v1.jpg
```

The file applies globally, which is fine — this boot entry has only the
IMX415. Restore the user's IMX219 file (`~/camera_overrides.isp.stashed` on
target) only if the stock imx219 boot entry is ever used again.

## Follow-up ideas (in priority order, all optional)

- AWB calibration curve from the RPi `ct_curve` if casts show up under
  incandescent/daylight extremes (needs conversion into NVIDIA's U-space
  gray-line parametrization — nontrivial, derive only if needed).
- Per-CT CCM is impossible (single matrix); if 4605 K proves wrong for the
  dominant use (e.g. IR-CUT night mode), swap in a different table entry.
- LSC surfaces if corner falloff/color shading bothers — needs a flat-field
  capture session (gray card / diffuser over the lens).
