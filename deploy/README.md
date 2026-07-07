# Deploy package (Phase F) — built 2026-07-07 on the host

Contents:
- `nv_imx415.ko` — vermagic `5.15.185-tegra SMP preempt mod_unload modversions aarch64`
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
