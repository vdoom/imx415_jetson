# Deploy package — JetPack 7.2 / L4T R39.2.1 (branch `JP7`, rebuilt 2026-09-16)

**JP7 state:** `nv_imx415.ko` sha1 `a21723d9`, vermagic
`6.8.12-1021-tegra SMP preempt mod_unload modversions aarch64`, built natively
on the target and modversion-CRC-verified against the installed kernel and
`tegra-camera.ko` (`driver/modcheck.sh`: 42/42). The dtbo is byte-identical
to the JP6 one (sha1 `1c0a9101`) and applies cleanly to the R39 base DTB.
ISP tuning unchanged (v3). **Not yet installed/booted on JP7** — that needs
sudo; steps in `../jp7_port.md` §5. The installer now expects kernel
`6.8.12-1021-tegra` and clones the DEFAULT extlinux entry (`JetsonIO`, or
`primary` + an FDT line), dropping the stock imx219/imx477 overlays.
`2lane-15fps-backup/` (JP6-only 5.15 binaries) is not on this branch.

**Argus on JP7 = native NITO mode:** `jakku_rear_IMX415.nito` (generated
2026-09-16 from the legacy config + v4-jp7 overrides, knobsets for modes
0 and 1) is installed by step 6 together with `nvargus-daemon-nito.conf`.
Validated: both modes 30.1 fps through the ISP. Only to REGENERATE it
(after a tuning change) are two more pieces needed:
`sudo ./install_camera_hotfix.sh` installs NVIDIA's public JetPack 7.2.1
camera hotfix (R39 otherwise refuses to run the ISP without a per-module
NITO file, and refuses the legacy config mode too) plus the
`nvargus-daemon-legacy-isp.conf` drop-in; then `tools/nito_migrate.sh`
turns the legacy config + our overrides into a native `jakku_rear_IMX415.nito`.
Full story: `../jp7_port.md` §6.

Everything below is the JP6 record; the validation commands still apply.

---

# Deploy package (Phase F) — built 2026-07-07; ko + dtbo rebuilt 2026-07-13 (72 dB gain)

**72 dB gain update (2026-07-13, ko sha1 5cea9ce1, dtbo sha1 1c0a9101):**
gain control range 0–30 dB → **0–72 dB** (analog to 30, digital above,
0.3 dB steps; Rockchip/FRAMOS-matched). Install BOTH artifacts + reboot.
Mixed old/new combinations are safe (silently cap at 30 dB). Validate:
mid-stream `v4l2-ctl -c gain=45000` must brighten beyond gain=30000
(register: i2c reg 0x3090 should read 150 = 0x96); Argus enumeration
line now reports `Analog Gain range min 1.000000, max 3981.xxx`.

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
- `tegra234-p3767-camera-p3768-imx415.dtbo` — the CAM1 overlay; rebuilt
  2026-07-12 (sha1 53381cb5) with the Argus/ISP properties
  (`use_decibel_gain`, lens node + `v4l2_lens` drivernode — see
  `../argus_isp.md`). Raw-V4L2 behavior is untouched. After installing +
  rebooting, validate Argus with `tools/argus_check.sh`.
- `camera_overrides.isp` — ISP tuning for Argus (v3 2026-07-13, user-approved:
  pedestal 60/1023 + pure-saturation matrix s=1.4). Canonical copy lives in
  `../tuning/` — re-copy here + refresh checksums when tuning changes.
  Installer puts it in `/var/nvidia/nvcam/settings/` (backing up any
  different existing file) and restarts nvargus-daemon.
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

The installer: verifies the running kernel (`6.8.12-1021-tegra` on `JP7`;
`5.15.185-tegra` on `main`) and the file checksums; backs up `extlinux.conf`
(timestamped); puts the module into
`/lib/modules/$(uname -r)/updates/drivers/media/i2c/` + `depmod -a`; copies
the dtbo to `/boot/`; appends a new `LABEL imx415` boot entry cloned from the
DEFAULT entry (`JetsonIO` on JP7; `UARTFix` was the JP6 source) with the stock
camera overlays removed and ours added. It does **not** touch the `DEFAULT`
line or any existing entry — the old boot entries stay intact, so a bad
overlay is recoverable by picking another entry at the boot menu (serial
console).

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
