/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * imx415_mode_tbls.h - sensor mode tables for the Sony IMX415 sensor.
 *
 * Register values taken from the Raspberry Pi kernel driver
 * drivers/media/i2c/imx415.c (branch rpi-6.12.y), which is the reference
 * configuration validated with the Waveshare IMX415-98 module:
 * INCK = 37.125 MHz, lane rate 891 Mbps/lane, 4 lanes, RAW10, all-pixel
 * 3864x2192 @ 30 fps. Multi-byte registers are split little-endian (low
 * byte at the low address), matching imx415_write() in the RPi driver.
 *
 * Copyright (c) 2026, project imx415_jetson.
 */

#ifndef __IMX415_I2C_TABLES__
#define __IMX415_I2C_TABLES__

#define IMX415_TABLE_WAIT_MS	0
#define IMX415_TABLE_END	1

#define imx415_reg struct reg_8

/*
 * Leaving standby requires a long settling delay: the datasheet states
 * 63 us, but the RPi reference driver found that even 30 ms is not enough
 * and uses 80 ms before starting the master mode operation.
 */
static const imx415_reg imx415_start_stream[] = {
	{0x3000, 0x00},	/* MODE: operating */
	{IMX415_TABLE_WAIT_MS, 80},
	{0x3002, 0x00},	/* XMSTA: master mode start */
	{IMX415_TABLE_WAIT_MS, 3},
	{IMX415_TABLE_END, 0x00}
};

static const imx415_reg imx415_stop_stream[] = {
	{0x3002, 0x01},	/* XMSTA: stop */
	{0x3000, 0x01},	/* MODE: standby */
	{IMX415_TABLE_END, 0x00}
};

static const imx415_reg imx415_mode_common[] = {
	/* readout: all-pixel mode, no flip. Bit-depth registers (ADBIT/
	 * MDBIT/ADBIT1) are set per-mode below, not here. */
	{0x301C, 0x00},	/* WINMODE */
	{0x3022, 0x00},	/* ADDMODE */
	{0x3030, 0x00},	/* REVERSE */
	/* output VSYNC on XVS and low on XHS */
	{0x30C0, 0x22},	/* OUTSEL */
	{0x30C1, 0x00},	/* DRV */

	/* INCK 37.125 MHz / 891 Mbps clock config (imx415_clk_params[]) */
	{0x3008, 0x7F},	/* BCWAIT_TIME [15:8]=0x00 */
	{0x3009, 0x00},
	{0x300A, 0x5B},	/* CPWAIT_TIME [15:8]=0x00 */
	{0x300B, 0x00},
	{0x3033, 0x05},	/* SYS_MODE */
	{0x3115, 0x00},	/* INCKSEL1 */
	{0x3116, 0x24},	/* INCKSEL2 */
	{0x3118, 0xC0},	/* INCKSEL3 */
	{0x3119, 0x00},
	{0x311A, 0xE0},	/* INCKSEL4 */
	{0x311B, 0x00},
	{0x311E, 0x24},	/* INCKSEL5 */
	{0x400C, 0x00},	/* INCKSEL6 */
	{0x4074, 0x01},	/* INCKSEL7 */
	{0x4004, 0x48},	/* TXCLKESC_FREQ = 0x0948 */
	{0x4005, 0x09},

	/* 891 Mbps D-PHY timing (imx415_linkrate_891mbps[]) */
	{0x4018, 0x7F},	/* TCLKPOST */
	{0x4019, 0x00},
	{0x401A, 0x37},	/* TCLKPREPARE */
	{0x401B, 0x00},
	{0x401C, 0x37},	/* TCLKTRAIL */
	{0x401D, 0x00},
	{0x401E, 0xF7},	/* TCLKZERO */
	{0x401F, 0x00},
	{0x4020, 0x3F},	/* THSPREPARE */
	{0x4021, 0x00},
	{0x4022, 0x6F},	/* THSZERO */
	{0x4023, 0x00},
	{0x4024, 0x3F},	/* THSTRAIL */
	{0x4025, 0x00},
	{0x4026, 0x5F},	/* THSEXIT */
	{0x4027, 0x00},
	{0x4028, 0x2F},	/* TLPX */
	{0x4029, 0x00},

	/* 4-lane MIPI output */
	{0x4001, 0x03},	/* LANEMODE = 3 (4-lane) */
	{0x4002, 0x00},

	/* SONY magic registers (imx415_init_table[]) */
	{0x32D4, 0x21},
	{0x32EC, 0xA1},
	{0x3452, 0x7F},
	{0x3453, 0x03},
	{0x358A, 0x04},
	{0x35A1, 0x02},
	{0x36BC, 0x0C},
	{0x36CC, 0x53},
	{0x36CD, 0x00},
	{0x36CE, 0x3C},
	{0x36D0, 0x8C},
	{0x36D1, 0x00},
	{0x36D2, 0x71},
	{0x36D4, 0x3C},
	{0x36D6, 0x53},
	{0x36D7, 0x00},
	{0x36D8, 0x71},
	{0x36DA, 0x8C},
	{0x36DB, 0x00},
	{0x3724, 0x02},
	{0x3726, 0x02},
	{0x3732, 0x02},
	{0x3734, 0x03},
	{0x3736, 0x03},
	{0x3742, 0x03},
	{0x3862, 0xE0},
	{0x38CC, 0x30},
	{0x38CD, 0x2F},
	{0x395C, 0x0C},
	{0x3A42, 0xD1},
	{0x3A4C, 0x77},
	{0x3AE0, 0x02},
	{0x3AEC, 0x0C},
	{0x3B00, 0x2E},
	{0x3B06, 0x29},
	{0x3B98, 0x25},
	{0x3B99, 0x21},
	{0x3B9B, 0x13},
	{0x3B9C, 0x13},
	{0x3B9D, 0x13},
	{0x3B9E, 0x13},
	{0x3BA1, 0x00},
	{0x3BA2, 0x06},
	{0x3BA3, 0x0B},
	{0x3BA4, 0x10},
	{0x3BA5, 0x14},
	{0x3BA6, 0x18},
	{0x3BA7, 0x1A},
	{0x3BA8, 0x1A},
	{0x3BA9, 0x1A},
	{0x3BAC, 0xED},
	{0x3BAD, 0x01},
	{0x3BAE, 0xF6},
	{0x3BAF, 0x02},
	{0x3BB0, 0xA2},
	{0x3BB1, 0x03},
	{0x3BB2, 0xE0},
	{0x3BB3, 0x03},
	{0x3BB4, 0xE0},
	{0x3BB5, 0x03},
	{0x3BB6, 0xE0},
	{0x3BB7, 0x03},
	{0x3BB8, 0xE0},
	{0x3BBA, 0xE0},
	{0x3BBC, 0xDA},
	{0x3BBE, 0x88},
	{0x3BC0, 0x44},
	{0x3BC2, 0x7B},
	{0x3BC4, 0xA2},
	{0x3BC8, 0xBD},
	{0x3BCA, 0xBD},
	{IMX415_TABLE_WAIT_MS, 10},
	{IMX415_TABLE_END, 0x00}
};

/*
 * Full frame 3864x2192 @ 30 fps (4 lanes at 891 Mbps).
 * VMAX = 2250 (2192 active + 58 vblank), HMAX = 1100 (the hmax_min the
 * RPi driver enforces for 4 lanes at 891 Mbps): line time = 1100 x 12 /
 * 891 MHz = 14.81 us -> 1 / (2250 x 14.81 us) = 30.0 fps.
 */
static const imx415_reg imx415_mode_3864x2192_30fps[] = {
	{0x3031, 0x00},	/* ADBIT: 10-bit AD */
	{0x3032, 0x00},	/* MDBIT: 10-bit output */
	{0x3701, 0x00},	/* ADBIT1: 10-bit analog */
	{0x3024, 0xCA},	/* VMAX = 2250 = 0x0008CA */
	{0x3025, 0x08},
	{0x3026, 0x00},
	{0x3028, 0x4C},	/* HMAX = 1100 = 0x044C */
	{0x3029, 0x04},
	{0x3050, 0x08},	/* SHR0 = 8 -> max exposure (VMAX - 8 lines) */
	{0x3051, 0x00},
	{0x3052, 0x00},
	{0x3090, 0x00},	/* GAIN_PCG_0 = 0 dB */
	{0x3091, 0x00},
	{IMX415_TABLE_WAIT_MS, 10},
	{IMX415_TABLE_END, 0x00}
};

/*
 * Full frame 3864x2192 12-bit @ 30 fps (4 lanes at 891 Mbps).
 * Identical to the 10-bit mode except the three bit-depth registers
 * (verified against the Rockchip driver: the 10->12 bit delta is exactly
 * ADBIT/MDBIT/ADBIT1; VMAX/HMAX/link timing are unchanged). 12-bit RAW at
 * 30 fps = 3.05 Gb/s, within the 4x891 = 3.56 Gb/s CSI budget.
 */
static const imx415_reg imx415_mode_3864x2192_12bit_30fps[] = {
	{0x3031, 0x01},	/* ADBIT: 12-bit AD */
	{0x3032, 0x01},	/* MDBIT: 12-bit output */
	{0x3701, 0x03},	/* ADBIT1: 12-bit analog */
	{0x3024, 0xCA},	/* VMAX = 2250 */
	{0x3025, 0x08},
	{0x3026, 0x00},
	{0x3028, 0x4C},	/* HMAX = 1100 */
	{0x3029, 0x04},
	{0x3050, 0x08},	/* SHR0 = 8 */
	{0x3051, 0x00},
	{0x3052, 0x00},
	{0x3090, 0x00},	/* GAIN_PCG_0 = 0 dB */
	{0x3091, 0x00},
	{IMX415_TABLE_WAIT_MS, 10},
	{IMX415_TABLE_END, 0x00}
};

enum {
	IMX415_MODE_3864x2192_30FPS,		/* mode0: 10-bit */
	IMX415_MODE_3864x2192_12BIT_30FPS,	/* mode1: 12-bit */

	IMX415_MODE_COMMON,
	IMX415_START_STREAM,
	IMX415_STOP_STREAM,
};

static const imx415_reg *mode_table[] = {
	[IMX415_MODE_3864x2192_30FPS] = imx415_mode_3864x2192_30fps,
	[IMX415_MODE_3864x2192_12BIT_30FPS] = imx415_mode_3864x2192_12bit_30fps,

	[IMX415_MODE_COMMON] = imx415_mode_common,
	[IMX415_START_STREAM] = imx415_start_stream,
	[IMX415_STOP_STREAM] = imx415_stop_stream,
};

static const int imx415_30fps[] = {
	30,
};

/*
 * WARNING: frmfmt ordering must match the modeN node order in the
 * device tree overlay. mode0 = 10-bit, mode1 = 12-bit (same geometry;
 * selected via the sensor_mode control / csi_pixel_bit_depth).
 */
static const struct camera_common_frmfmt imx415_frmfmt[] = {
	{{3864, 2192}, imx415_30fps, 1, 0, IMX415_MODE_3864x2192_30FPS},
	{{3864, 2192}, imx415_30fps, 1, 0, IMX415_MODE_3864x2192_12BIT_30FPS},
};

#endif /* __IMX415_I2C_TABLES__ */
