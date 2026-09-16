/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Stand-in for the BSP-only <dt-bindings/tegra234-p3767-0000-common.h>
 * (hardware/nvidia/t23x/nv-public in the Jetson Linux source tree), so the
 * IMX415 overlay builds standalone from the installed kernel headers
 * (dt-bindings/gpio/tegra234-gpio.h, dt-bindings/pinctrl/pinctrl-tegra.h).
 *
 * Only what the overlay uses is provided. JETSON_COMPATIBLE_P3768 is the
 * exact list carried by the stock L4T r39.2.1 camera overlays
 * (/boot/tegra234-p3767-camera-p3768-imx219-C.dtbo decompiled) and by our
 * r36.5.0 build - the two are identical, every P3767 module variant on the
 * P3768 carrier, "super" profiles included.
 */

#ifndef __DT_BINDINGS_TEGRA234_P3767_0000_COMMON_H__
#define __DT_BINDINGS_TEGRA234_P3767_0000_COMMON_H__

#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/gpio/tegra234-gpio.h>

#define JETSON_COMPATIBLE_P3768 \
	"nvidia,p3768-0000+p3767-0000", \
	"nvidia,p3768-0000+p3767-0001", \
	"nvidia,p3768-0000+p3767-0003", \
	"nvidia,p3768-0000+p3767-0004", \
	"nvidia,p3768-0000+p3767-0005", \
	"nvidia,p3768-0000+p3767-0000-super", \
	"nvidia,p3768-0000+p3767-0001-super", \
	"nvidia,p3768-0000+p3767-0003-super", \
	"nvidia,p3768-0000+p3767-0004-super", \
	"nvidia,p3768-0000+p3767-0005-super"

#endif
