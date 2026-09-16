# JetPack 7.2 port (branch `JP7`) — 2026-09-16

Port of the validated JetPack 6.2.2 bring-up (branch `main`) to
**JetPack 7.2 / L4T R39.2.1** (GCID 46758480, kernel `6.8.12-1021-tegra`,
Ubuntu 24.04). Done natively on the target — this branch was built on the
Jetson itself, not cross-built on an x86 host.

**Status (2026-09-16 15:05): installed, booted, raw V4L2 path VALIDATED
on JP7.** With `DEFAULT imx415` the overlay is live (gain max 72000, lens
node), `nv_imx415` binds `9-0037`, the media graph links sensor → nvcsi →
vi, GB10 and GB12 enumerate at 3864x2192@30 and both stream at a flat
30.00 fps; the exposure/gain ladder (1 ms/0 dB → 33 ms/15 dB → 1 ms/0 dB)
gives means 50.6 → 173.7 → 50.6, i.e. the JP6 numbers. **CUDA debayer path
VALIDATED on JP7 (CUDA 13.2, 15:08):** `--ae` run and `--snap` at 29.99 fps,
1.75 ms/frame kernel, zero-copy, AE converged (33 ms / 9.6 dB), AWB 4010 K,
snapshot user-confirmed working. **Argus/ISP path:
blocked by a JP7 policy change** (§6) — fix shipped in `deploy/`, needs one
more sudo step.

## 1. Environment (the target this branch was built on)

| | JetPack 6.2.2 (`main`) | JetPack 7.2 (`JP7`) |
|---|---|---|
| Board | Orin Nano devkit Super (P3768 + P3767-0005) | **Orin NX Engineering Reference Devkit** (P3768 + P3767-0001) |
| L4T | R36.5.0, kernel 5.15.185-tegra, Ubuntu 22.04 | **R39.2.1, kernel 6.8.12-1021-tegra, Ubuntu 24.04.4** |
| OOT tree | `nvidia-oot` (full sources in the BSP on a host) | `nvidia-public` — only **headers** installed (`/usr/src/nvidia/nvidia-public/include`, `Module.symvers`); no `.c`, no `nvidia/conftest.h` |
| Kernel headers | BSP `kernel-jammy-src` | `nvidia-l4t-kernel-headers` → `/lib/modules/6.8.12-1021-tegra/build` (Ubuntu-style, `.config` + `Module.symvers` + prebuilt `scripts/`) |
| Compiler | Bootlin gcc 11.3 cross | native gcc 13.3 (kernel built with 13.2 — same major, Kbuild only warns) |
| Base DTB (extlinux FDT) | `kernel_tegra234-p3768-0000+p3767-0005-nv-super.dtb` | `/boot/dtb/kernel_tegra234-p3768-0000+p3767-0001-nv.dtb` |
| extlinux entries | `primary`, `JetsonIO`, `UARTFix` (custom) | `primary`, `JetsonIO` (DEFAULT, imx219-dual overlay) |
| Camera module | Waveshare IMX415-98 on CAM1 | **same module**, verified 2026-09-16: XCLR (gpiochip0 138) high → ACK at 0x37 on i2c-9, VMAX = 0xca 0x08 0x00 = 2250 (power-on default, = passport §1.1) |
| gpio lines (libgpiod v1.6.3 on both) | PAC.00 = 138, PP.01 = 113 | PAC.00 = 138 (same), **PP.01 = 93** |
| CUDA | 12.6 | 13.2 — `tools/cuda_debayer` compiles and runs (`--help`) unchanged |

## 2. What changed (and what did not)

**Kernel driver — source unchanged in behavior.** The only edit in
`nv_imx415.c` is dropping `#include "../platform/tegra/camera/camera_gpio.h"`
(an OOT-tree-relative path, nothing from it was used). Cross-checked against
the public R38.4 `nv_imx219.c` (OE4T mirror of `linux-nv-oot`, branch
`l4t/l4t-r38.4`): NVIDIA's own driver of this generation still uses the same
legacy gpio API, the same `NV_I2C_DRIVER_STRUCT_*` conftest macros and the
same `tegracam_ctrl_ops`/`camera_common_sensor_ops` — our driver already had
all of that from Phase D. The two tegracam quirks the driver works around
are still in the R38.4 framework sources (`tegracam_v4l2.c` applies cached
controls only `if (s_data->override_enable)`; `tegracam_ctrls.c` creates
FRAME_RATE with `.def = CTRL_U64_MIN`), so both workarounds stay.

**Kernel driver — build changed.** No OOT sources on the target, so the
driver now builds standalone (`driver/Makefile`, Kbuild `M=` against the
installed headers, `KBUILD_EXTRA_SYMBOLS` = nvidia-public's `Module.symvers`).
NVIDIA's headers `#include <nvidia/conftest.h>`, which nobody ships:
`driver/conftest.sh` generates it by compiling probe snippets with the
kernel's own Kbuild flags (single-object `make M=... probe.o`), with a
control snippet so a broken harness fails loudly instead of yielding
"everything absent". Result on this kernel:

| macro | value | why it matters |
|---|---|---|
| `NV_I2C_DRIVER_STRUCT_PROBE_WITHOUT_I2C_DEVICE_ID_ARG` | present | probe signature (Linux ≥ 6.3) |
| `NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT` | absent | remove returns void (Linux ≥ 6.1) |
| `NV_V4L2_ASYNC_CONNECTION_STRUCT_PRESENT` | present | used by `mc_common.h` (not by us; kept for other sensor drivers) |
| **`NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT`** | **present** | adds `struct tegra_pmc *pmc` to `struct camera_common_data` — a **layout** change of a struct shared with the prebuilt `tegra-camera.ko`. The header comment says "Linux v7.0", but the L4T 6.8 kernel backports it (`soc/tegra/pmc.h`). Guessing "absent" would have produced a module that loads and corrupts memory. |

`driver/modcheck.sh` turns that into ground truth without root: every
imported symbol's modversion CRC (which hashes the full type expansion of
the prototype, `camera_common_data` included) must equal the exporter's in
the kernel / nvidia-public `Module.symvers`. **PASS: 42/42 CRC-exact**,
vermagic `6.8.12-1021-tegra SMP preempt mod_unload modversions aarch64` =
`tegra-camera.ko`. (The 6.8 L4T kernel writes the *extended* `__versions`
record format, which kmod 31's `modprobe --dump-modversions` rejects — the
script parses the section itself.)

**Device-tree overlay — unchanged, and provably so.** The R39 stock
`imx219-C` overlay (decompiled from `/boot`) has the same node paths,
labels (`gpio`, `gpio_aon`, `cam_i2c`, `pinmux`), properties and compatible
list as the R36 donor, and the pin name `extperiph2_clk_pp1` exists in the
6.8 kernel image. The overlay now also builds standalone (`dt/Makefile`:
cpp + dtc against the kernel's `dt-bindings`, plus
`dt/include/dt-bindings/tegra234-p3767-0000-common.h` standing in for the
BSP-only header). The result is **byte-identical to the JP6 artifact**
(sha1 `1c0a9101`), and `fdtoverlay` applies it cleanly to the R39 base DTB
(`make -C dt check`). Note (both JetPacks): the donor's `gpio@6000d000`
hog node does not exist in either base DTB, so the `cam1-pwdn`/`cam0-pwdn`
hogs there are dead — which is also why the driver can `gpio_request`
PAC.00 without a conflict. Left donor-identical on purpose.

**Installer.** `deploy/install_on_target.sh` expects kernel
`6.8.12-1021-tegra` and clones the **DEFAULT** extlinux entry (`JetsonIO`
on a stock JetPack 7 devkit; `primary` as fallback, in which case it adds
the `FDT` line for the base DTB). Stock camera overlays (`imx219`/`imx477`/
`camera-p3768-*`) are dropped from `OVERLAYS`, ours is added; `DEFAULT` is
untouched. Dry-run of the generator against this machine's live
`extlinux.conf` produced the expected entry for both source labels.

**Removed on this branch.** `deploy/2lane-15fps-backup/` (5.15 binaries,
JP6-only) — still on `main` and at tag `phase1-2lane-15fps`.

**Tools/docs.** `tools/ircut.sh` fallback line 113 → 93 (name lookup was
always primary). Kernel-version references updated across the READMEs.

## 3. Build recipe (on the target, no root)

```bash
# driver: conftest.h -> nv_imx415.ko -> modversion CRC check
make -C driver check
# overlay: dtbo -> apply-test against /boot/dtb base -> decompile for review
make -C dt check decompile
# stage + checksums
cp driver/nv_imx415.ko dt/tegra234-p3767-camera-p3768-imx415.dtbo tuning/camera_overrides.isp deploy/
(cd deploy && sha1sum nv_imx415.ko tegra234-p3767-camera-p3768-imx415.dtbo camera_overrides.isp install_on_target.sh > checksums.sha1)
```

Both Makefiles take `KDIR=` (kernel build dir) and the driver one `NV_OOT=`
(nvidia-public dir), so the same recipe works on a host holding those two
trees. The in-BSP-tree route (`driver/Makefile.patch.note`, `dt/README.md`)
is still valid for R39 but was not exercised here (no BSP tree on this
machine).

## 4. Artifacts on this branch

| file | sha1 | built |
|---|---|---|
| `deploy/nv_imx415.ko` | `a21723d9…` | 2026-09-16 on target, vermagic 6.8.12-1021-tegra |
| `deploy/tegra234-p3767-camera-p3768-imx415.dtbo` | `1c0a9101…` | 2026-09-16 on target — identical bytes to the JP6 dtbo |
| `deploy/camera_overrides.isp` | `fa4d34a7…` | unchanged (tuning v3) |

## 5. Validation still to do (needs sudo — user)

```bash
cd ~/src/imx415_jetson/deploy && sudo ./install_on_target.sh   # verifies kernel + checksums first
sudo reboot        # pick 'imx415' at the boot menu (serial console), or set DEFAULT imx415
# after boot:
lsmod | grep nv_imx415; ls /dev/video0; media-ctl -p -d /dev/media0 | grep -A3 imx415
sudo dmesg | grep -iE "imx415|tegracam|nvcsi|vi5"        # expect probe OK, no i2c errors
v4l2-ctl -d /dev/video0 --list-formats-ext                # GB10 + GB12, 3864x2192@30
sudo bash tools/expo_gain_check.sh                        # register-exact exposure/gain (JP6 numbers)
sudo bash tools/gain72_check.sh                           # 72 dB ladder; note: expects ko sha1 a21723d9 now
./tools/argus_check.sh; ./tools/argus_check.sh snap       # ISP path; then check the ISP schema note in tuning/README.md
./tools/ircut.sh day                                      # PP.01 by name (line 93)
```

Expected results are the JP6 ones (`driver/README.md`, `phase_g_validation.md`).
Things most likely to differ on R39 and worth a look: the nvargus daemon's
accepted ISP override keys (`journalctl -u nvargus-daemon | grep -c "Invalid
isp config"` must stay 0), and whether the JP7 `JetsonIO` entry's
`imx219-dual` overlay was the only camera consumer (it was: no `/dev/video*`
existed before, the imx219 probes fail without hardware).

## 6. JetPack 7 NITO policy (found 2026-09-16, first Argus run)

The R39 daemon aborts ISP init for our module:

```
Error: NvCameraIspInitialize: NvCameraIspGetNitoPathIfEnabled() returned error
| NITO file is made the default in this Jetpack release.            |
| User is expected to provide a NITO file for the camera module in  |
| the directory /var/nvidia/nvcam/settings ...                      |
| If the NITO file is not supported, you can still use the legacy   |
| Configuration file ... $ export NVCAMERA_NITO_PATH=CONFIG          |
```

JP6 used the legacy configuration path unconditionally; JP7 requires a
per-module binary `.nito` (made with NVIDIA's Camera Partner Toolkit, which
we do not have) unless the daemon is told otherwise. Fix: systemd drop-in
`deploy/nvargus-daemon-legacy-isp.conf` → `/etc/systemd/system/
nvargus-daemon.service.d/10-legacy-isp-config.conf` setting
`Environment=NVCAMERA_NITO_PATH=...` plus `Environment=HOME=/root` (installer
step 6/6). **`=CONFIG` turned out to be a dead end on R39.2.1** (tested
15:31): with HOME set the daemon dumps the merged legacy config to
`/root/binary.cfg`, then prints "legacy way of using text based
configuration file by setting NVCAMERA_NITO_PATH=CONFIG is not allowed
anymore" and aborts — the dump is meant to be converted to a NITO on a
Windows host with NVIDIA's Camera Partner Toolkit (not public; nothing on
the device converts it: only `nvtunerd`, `libnvcameratools`,
`nvargus_nvraw`). Each stock NITO embeds its module Part# (`RBP194` in
imx219.nito, `RBPCV3` in imx477.nito, `liimx185`, `P5V27C`) and the daemon
logs `nito file %s found. Badge "%s" SensorModel "%s" Modulename "%s"`
when it resolves one by name. Current stand-in: an explicit
`NVCAMERA_NITO_PATH=/var/nvidia/nvcam/settings/imx219.nito` (closest
shipped sensor: Sony, 10-bit, pedestal 64). Our
`camera_overrides.isp` is an *override* on top of that legacy config, as on
JP6. The daemon does log "Found override file [...camera_overrides.isp]"
on R39, so the text override format itself is still consumed; whether every
key we use is still accepted is checked after the first successful run
(`journalctl -u nvargus-daemon | grep -c "Invalid isp config"`, was 0 so far
but the parser had not reached our keys before the NITO abort).
