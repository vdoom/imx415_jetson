# Phase C — sources, toolchain, clean baseline build (host)

**Date:** 2026-07-07 · **Machine:** `nvidia@nvidia-workstation` (x86_64, Ubuntu 22.04, i5-7400)
**Covers:** guide §4 (Фаза C) end-to-end, including the §4.5 existing-driver check.
**Result: ✅ complete — clean baseline build reproduces stock artifacts exactly.**

---

## 1. Layout on host

| What | Where |
|---|---|
| BSP (`Linux_for_Tegra`) | `~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra` — **R36.5.0, GCID 43688277**, exact match with target |
| Kernel tree | `source/kernel/kernel-jammy-src` (name confirmed — closes §4.4 [ВЕРИФІКУВАТИ]) |
| OOT drivers | `source/nvidia-oot/` (donors `drivers/media/i2c/nv_imx219.c` + `imx219_mode_tbls.h` present) |
| DT overlays | `source/hardware/nvidia/t23x/nv-public/overlay/` (donor `tegra234-p3767-camera-p3768-imx219-C.dts` present) |
| Toolchain | `~/l4t-toolchain/aarch64--glibc--stable-2022.08-1/` — Bootlin gcc 11.3.0 |
| RPi register source | `~/src/rpi-linux` — shallow clone, branch **rpi-6.12.y**, HEAD `a923c1dcd` |

All three source tarballs (`kernel_src`, `kernel_oot_modules_src`,
`nvidia_kernel_display_driver_source`) sha1-verified before extraction.
Host build deps (guide §1.2) were all already installed.

⚠️ Toolchain download: the NVIDIA r36 URL 404s; working source is
`https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2022.08-1.tar.bz2`.

## 2. Build recipe (verified working)

```bash
cd ~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra/source
export CROSS_COMPILE=$HOME/l4t-toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
export ARCH=arm64
make -C kernel                                   # defconfig + Image + dtbs + in-tree modules (~30 min)
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src
make modules                                     # hwpm → nvidia-oot → nvgpu → nvdisplay (~15 min)
make dtbs                                        # overlays → kernel-devicetree/generic-dts/dtbs/
```

Notes:
- `make -C kernel` **must run before** `make modules` — the OOT build compiles
  against the built tree via `KERNEL_HEADERS` (needs `.config` + `Module.symvers`).
- `LOCALVERSION=-tegra` is applied automatically by `kernel/Makefile`.
- DTB output dir confirmed: `kernel-devicetree/generic-dts/dtbs/` (closes §4.4 note).

## 3. Baseline verification (all pass)

| Check | Result |
|---|---|
| Kernel image + release | `arch/arm64/boot/Image` built; `kernel.release` = **5.15.185-tegra** = target's `uname -r` |
| `nv_imx219.ko` vermagic | `5.15.185-tegra SMP preempt mod_unload modversions aarch64` — **byte-for-byte match** with target's OOT modules (passport §2.2) |
| Built `imx219-C.dtbo` vs target's stock `/boot` copy | decompiled sources **identical** (diff clean vs `reference/imx219-C-donor-decompiled.dts`) — toolchain reproduces stock artifacts exactly |
| media/i2c warnings | none (nvidia-oot builds with `-Werror` anyway) |

## 4. §4.5 — existing IMX415 driver check: NO drop-in exists

- **FRAMOS** `framosimaging/framos-jetson-drivers`: branches l4t-r36.3…r36.4.4 —
  **no imx415** in any (FSM-IMX415 product obsolete). But they ship
  **`fr_imx715.c`** — IMX715 is IMX415's sibling with the same register layout
  (VMAX 0x3024, HMAX 0x3028, SHR0 0x3050, GAIN_PCG_0 0x3090). GPL-2.0. Saved to
  `reference/fr_imx715-l4t-r36.4.4.c` + `reference/fr_imx715_mode_tbls-l4t-r36.4.4.h`
  as a secondary donor for Phase D (real tegracam driver of this L4T generation
  for a register-compatible sensor — use to cross-check ctrl-callback math and
  mode-table structure; its DT assumes FRAMOS adapter boards, so DT stays
  imx219-C-based).
- **VC-MIPI** `VC-MIPI-modules/vc_mipi_nvidia`: lists IMX415 but only works with
  Vision Components' own module hardware (onboard controller) — not usable for
  the bare Waveshare module.

**Conclusion:** Phase D proceeds as planned — `nv_imx219.c` skeleton + rpi-6.12.y registers.

## 5. rpi-6.12.y imx415.c — confirmed contents + Phase D caveat

- `imx415_clk_params[]` has `.inck = 37125000` entries across all 5 link freqs;
  `imx415_linkrate_891mbps[]` present — matches Phase A expectations.
- ⚠️ The 6.12 driver uses **CCI register helpers**: tables are
  `struct cci_reg_sequence` and register width is encoded in the address macro
  (`CCI_REG8/16/24(addr)`), multi-byte values written as a single logical write.
  Translating to tegracam `reg_8` tables requires manual byte-splitting
  **little-endian** (per guide §5.3.9) — do not copy table lines mechanically.

## 6. What's next (Phase D)

1. `cp nv_imx219.c nv_imx415.c`, `cp imx219_mode_tbls.h imx415_mode_tbls.h`,
   add `obj-m += nv_imx415.o` inside `ifdef CONFIG_MEDIA_SUPPORT` in the Makefile.
2. Registers from `~/src/rpi-linux/drivers/media/i2c/imx415.c`
   (init table + 37.125 MHz/891 Mbps clk params + linkrate table + LANEMODE=1).
3. Controls per corrected timing: 15 fps, line time ≈29.63 µs
   (`rpi5_imx415_data.md` §2.3); cross-check against `reference/fr_imx715-*.c`.
4. Iterate `make modules` until clean (`-Werror` in effect).
