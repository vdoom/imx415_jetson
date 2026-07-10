# Deploy package (Phase F) — built 2026-07-07, module rebuilt 2026-07-10

Contents:
- `nv_imx415.ko` — vermagic `5.15.185-tegra SMP preempt mod_unload modversions aarch64`;
  rebuilt 2026-07-10 (sha1 19169df3): `set_mode` asserts `override_enable`
  at every stream-on so v4l2 gain/exposure/frame_rate writes actually
  program the sensor; FRAME_RATE control initialized to the 30 fps DT
  default (was stuck at min = 2 fps); exposure re-derived after VMAX
  changes (see `driver/README.md`). NB `-C override_enable` reads 0 even
  when this works (VI-channel cached value) — verify behaviorally:
  `tools/expo_gain_check.sh`, or mid-stream `v4l2-ctl -c gain=15000`
  must visibly brighten.
  ⚠ Install only from a freshly copied deploy dir — a stale copy on the
  target reinstalls old artifacts and its checksums still self-verify
  (this bit us on 2026-07-10: a Phase-F-era `~/imx415_deploy` brought back
  the embedded-metadata bug).
- `tegra234-p3767-camera-p3768-imx415.dtbo` — the CAM1 overlay
- `checksums.sha1` — verified by the installer
- `install_on_target.sh` — one-shot installer (idempotent, run with sudo)

## How to deploy

```bash
# from the host (or copy the deploy/ dir any way you like):
scp -r deploy/ orca@<jetson-ip>:~/imx415_deploy/

# on the target:
cd ~/imx415_deploy
sudo ./install_on_target.sh
```

The installer: verifies the running kernel is `5.15.185-tegra` and the file
checksums; backs up `extlinux.conf` (timestamped); puts the module into
`/lib/modules/5.15.185-tegra/updates/drivers/media/i2c/` + `depmod -a`; copies
the dtbo to `/boot/`; appends a new `LABEL imx415` boot entry cloned from
`UARTFix` with `imx219-dual.dtbo` removed and our overlay added. It does
**not** touch the `DEFAULT` line or any existing entry — the old boot entries
stay intact, so a bad overlay is recoverable by picking another entry at the
boot menu (serial console).

## First validation after reboot (Phase G, guide §7.3/§8.1)

```bash
sudo modprobe nv_imx415
dmesg | grep -iE "imx415|tegracam"      # expect probe OK, no I2C errors
ls /dev/video*                          # expect /dev/video0
media-ctl -p -d /dev/media0             # imx415 9-0037 -> nvcsi -> vi chain
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=3864,height=2192,pixelformat=<fourcc from above> \
  --set-ctrl bypass_mode=0 \
  --stream-mmap --stream-count=100 --stream-to=/tmp/cap.raw --verbose
```

Expected: 10-bit Bayer GBRG 3864x2192, 30 fps ('<' markers in --verbose;
package is 4-lane since 2026-07-08 — 2-lane/15fps fallback in 2lane-15fps-backup/).
View frames with the guide's Appendix A viewer (try shift 0..6).
After validation: `echo nv_imx415 | sudo tee /etc/modules-load.d/imx415.conf`
and optionally `DEFAULT imx415` in extlinux.conf.
