// SPDX-License-Identifier: GPL-2.0-only
/*
 * nv_imx415.c - Sony IMX415 sensor driver (tegracam)
 *
 * Skeleton based on nv_imx219.c; sensor register semantics from the
 * Raspberry Pi kernel driver drivers/media/i2c/imx415.c (rpi-6.12.y)
 * and the Sony IMX415 datasheet.
 */

#include <nvidia/conftest.h>

#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/gpio.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_gpio.h>

#include <media/tegra_v4l2_camera.h>
#include <media/tegracam_core.h>

#include "../platform/tegra/camera/camera_gpio.h"
#include "imx415_mode_tbls.h"

/* imx415 - sensor parameter limits */
#define IMX415_MIN_FRAME_LENGTH			2250
#define IMX415_MAX_FRAME_LENGTH			0xfffff
#define IMX415_MIN_INTEGRATION_LINES		4
#define IMX415_MIN_SHR0				8
#define IMX415_GAIN_REG_MAX			100
#define IMX415_ANALOG_GAIN_DB_MAX		30

/* imx415 sensor register address */
#define IMX415_MODE_ADDR			0x3000
#define IMX415_REGHOLD_ADDR			0x3001
#define IMX415_XMSTA_ADDR			0x3002
#define IMX415_VMAX_ADDR_LOW			0x3024
#define IMX415_VMAX_ADDR_MID			0x3025
#define IMX415_VMAX_ADDR_HIGH			0x3026
#define IMX415_SHR0_ADDR_LOW			0x3050
#define IMX415_SHR0_ADDR_MID			0x3051
#define IMX415_SHR0_ADDR_HIGH			0x3052
#define IMX415_GAIN_PCG_0_ADDR_LOW		0x3090
#define IMX415_GAIN_PCG_0_ADDR_HIGH		0x3091
#define IMX415_SENSOR_INFO_ADDR_LOW		0x3f12
#define IMX415_SENSOR_INFO_ADDR_HIGH		0x3f13
#define IMX415_SENSOR_INFO_MASK			0xfff
#define IMX415_CHIP_ID				0x514

static const struct of_device_id imx415_of_match[] = {
	{ .compatible = "sony,imx415", },
	{ },
};
MODULE_DEVICE_TABLE(of, imx415_of_match);

static const u32 ctrl_cid_list[] = {
	TEGRA_CAMERA_CID_GAIN,
	TEGRA_CAMERA_CID_EXPOSURE,
	TEGRA_CAMERA_CID_FRAME_RATE,
	TEGRA_CAMERA_CID_SENSOR_MODE_ID,
};

struct imx415 {
	struct i2c_client		*i2c_client;
	struct v4l2_subdev		*subdev;
	u32				frame_length;
	s64				last_exposure_us;
	struct camera_common_data	*s_data;
	struct tegracam_device		*tc_dev;
};

static const struct regmap_config sensor_regmap_config = {
	.reg_bits = 16,
	.val_bits = 8,
	.cache_type = REGCACHE_RBTREE,
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 4, 0)
	.use_single_rw = true,
#else
	.use_single_read = true,
	.use_single_write = true,
#endif
};

static inline int imx415_read_reg(struct camera_common_data *s_data,
	u16 addr, u8 *val)
{
	int err = 0;
	u32 reg_val = 0;

	err = regmap_read(s_data->regmap, addr, &reg_val);
	*val = reg_val & 0xff;

	return err;
}

static inline int imx415_write_reg(struct camera_common_data *s_data,
	u16 addr, u8 val)
{
	int err = 0;

	err = regmap_write(s_data->regmap, addr, val);
	if (err)
		dev_err(s_data->dev, "%s: i2c write failed, 0x%x = %x",
			__func__, addr, val);

	return err;
}

static int imx415_write_table(struct imx415 *priv, const imx415_reg table[])
{
	return regmap_util_write_table_8(priv->s_data->regmap, table, NULL, 0,
		IMX415_TABLE_WAIT_MS, IMX415_TABLE_END);
}

/* Multi-byte registers are little-endian: low byte at the low address */
static int imx415_write_reg16(struct camera_common_data *s_data,
	u16 addr_low, u16 val)
{
	int err;

	err = imx415_write_reg(s_data, addr_low, val & 0xff);
	if (err)
		return err;

	return imx415_write_reg(s_data, addr_low + 1, (val >> 8) & 0xff);
}

static int imx415_write_reg24(struct camera_common_data *s_data,
	u16 addr_low, u32 val)
{
	int err;

	err = imx415_write_reg16(s_data, addr_low, val & 0xffff);
	if (err)
		return err;

	return imx415_write_reg(s_data, addr_low + 2, (val >> 16) & 0xff);
}

static int imx415_set_group_hold(struct tegracam_device *tc_dev, bool val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct device *dev = tc_dev->dev;
	int err;

	/* REGHOLD: 1 = hold register updates, 0 = apply atomically */
	err = imx415_write_reg(s_data, IMX415_REGHOLD_ADDR, val ? 0x01 : 0x00);
	if (err) {
		dev_dbg(dev, "%s: group hold control error\n", __func__);
		return err;
	}

	return 0;
}

static int imx415_set_gain(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct device *dev = tc_dev->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err;
	u32 gain;

	if (val < mode->control_properties.min_gain_val)
		val = mode->control_properties.min_gain_val;
	else if (val > mode->control_properties.max_gain_val)
		val = mode->control_properties.max_gain_val;

	/*
	 * val is dB x gain_factor; the GAIN_PCG_0 register counts 0.3 dB
	 * steps: reg = dB / 0.3, range 0..100 (0..30 dB).
	 */
	gain = (u32)(val * IMX415_GAIN_REG_MAX /
		(IMX415_ANALOG_GAIN_DB_MAX *
		 mode->control_properties.gain_factor));

	if (gain > IMX415_GAIN_REG_MAX)
		gain = IMX415_GAIN_REG_MAX;

	dev_dbg(dev, "%s: val: %lld (/%d) [dB], gain reg: %u\n",
		__func__, val, mode->control_properties.gain_factor, gain);

	err = imx415_write_reg16(s_data, IMX415_GAIN_PCG_0_ADDR_LOW, gain);
	if (err) {
		dev_dbg(dev, "%s: gain control error\n", __func__);
		return err;
	}

	return 0;
}

static int imx415_set_exposure(struct tegracam_device *tc_dev, s64 val);

static int imx415_set_frame_rate(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct imx415 *priv = (struct imx415 *)tc_dev->priv;
	struct device *dev = tc_dev->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err;
	u32 frame_length;

	if (val == 0 || mode->image_properties.line_length == 0)
		return -EINVAL;

	/* frame rate is set through VMAX; HMAX (line length) stays fixed */
	frame_length = (u32)(mode->signal_properties.pixel_clock.val *
		(u64)mode->control_properties.framerate_factor /
		mode->image_properties.line_length / val);

	if (frame_length < IMX415_MIN_FRAME_LENGTH)
		frame_length = IMX415_MIN_FRAME_LENGTH;
	else if (frame_length > IMX415_MAX_FRAME_LENGTH)
		frame_length = IMX415_MAX_FRAME_LENGTH;

	dev_dbg(dev, "%s: val: %llde-6 [fps], VMAX: %u [lines]\n",
		__func__, val, frame_length);

	err = imx415_write_reg24(s_data, IMX415_VMAX_ADDR_LOW, frame_length);
	if (err) {
		dev_dbg(dev, "%s: frame rate control error\n", __func__);
		return err;
	}

	priv->frame_length = frame_length;

	/*
	 * SHR0 encodes exposure relative to VMAX, so a VMAX change silently
	 * changes the integration time (VMAX - SHR0). Re-derive SHR0 for
	 * the last requested exposure - also covers stream-on overrides,
	 * which apply exposure *before* frame rate (tegracam_override_cids
	 * order), i.e. against the previous VMAX.
	 */
	if (priv->last_exposure_us)
		return imx415_set_exposure(tc_dev, priv->last_exposure_us);

	return 0;
}

static int imx415_set_exposure(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct imx415 *priv = (struct imx415 *)tc_dev->priv;
	struct device *dev = tc_dev->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err;
	u32 integration_lines;
	u32 max_integration_lines;
	u32 shr0;

	if (mode->signal_properties.pixel_clock.val == 0 ||
		mode->control_properties.exposure_factor == 0 ||
		mode->image_properties.line_length == 0)
		return -EINVAL;

	integration_lines = (u32)(val *
		mode->signal_properties.pixel_clock.val /
		mode->control_properties.exposure_factor /
		mode->image_properties.line_length);

	max_integration_lines = priv->frame_length - IMX415_MIN_SHR0;

	if (integration_lines < IMX415_MIN_INTEGRATION_LINES)
		integration_lines = IMX415_MIN_INTEGRATION_LINES;
	else if (integration_lines > max_integration_lines) {
		integration_lines = max_integration_lines;
		dev_dbg(dev,
			"%s: exposure limited by frame_length: %u [lines]\n",
			__func__, max_integration_lines);
	}

	/* longer integration = smaller SHR0; SHR0 = VMAX - integration */
	shr0 = priv->frame_length - integration_lines;

	dev_dbg(dev, "%s: val: %lld [us], integration: %u [lines], SHR0: %u\n",
		__func__, val, integration_lines, shr0);

	err = imx415_write_reg24(s_data, IMX415_SHR0_ADDR_LOW, shr0);
	if (err) {
		dev_dbg(dev, "%s: exposure control error\n", __func__);
		return err;
	}

	priv->last_exposure_us = val;

	return 0;
}

static struct tegracam_ctrl_ops imx415_ctrl_ops = {
	.numctrls = ARRAY_SIZE(ctrl_cid_list),
	.ctrl_cid_list = ctrl_cid_list,
	.set_gain = imx415_set_gain,
	.set_exposure = imx415_set_exposure,
	.set_frame_rate = imx415_set_frame_rate,
	.set_group_hold = imx415_set_group_hold,
};

static int imx415_power_on(struct camera_common_data *s_data)
{
	int err = 0;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = s_data->dev;

	dev_dbg(dev, "%s: power on\n", __func__);
	if (pdata && pdata->power_on) {
		err = pdata->power_on(pw);
		if (err)
			dev_err(dev, "%s failed.\n", __func__);
		else
			pw->state = SWITCH_ON;
		return err;
	}

	if (unlikely(!(pw->avdd || pw->iovdd || pw->dvdd)))
		goto skip_power_seqn;

	if (pw->reset_gpio) {
		if (gpiod_cansleep(gpio_to_desc(pw->reset_gpio)))
			gpio_set_value_cansleep(pw->reset_gpio, 0);
		else
			gpio_set_value(pw->reset_gpio, 0);
	}

	usleep_range(10, 20);

	if (pw->avdd) {
		err = regulator_enable(pw->avdd);
		if (err)
			goto imx415_avdd_fail;
	}

	if (pw->iovdd) {
		err = regulator_enable(pw->iovdd);
		if (err)
			goto imx415_iovdd_fail;
	}

	if (pw->dvdd) {
		err = regulator_enable(pw->dvdd);
		if (err)
			goto imx415_dvdd_fail;
	}

	usleep_range(10, 20);

skip_power_seqn:
	/*
	 * Release XCLR (active-high release on this carrier board). The
	 * sensor does not respond on I2C at all while XCLR is held low.
	 */
	if (pw->reset_gpio) {
		if (gpiod_cansleep(gpio_to_desc(pw->reset_gpio)))
			gpio_set_value_cansleep(pw->reset_gpio, 1);
		else
			gpio_set_value(pw->reset_gpio, 1);
	}

	/*
	 * Datasheet asks for 20 us from XCLR release to first I2C access;
	 * the RPi driver found that unreliable and waits 100 us. Use a
	 * larger margin, matching the imx219 dual-camera workaround.
	 */
	usleep_range(10000, 10100);

	pw->state = SWITCH_ON;

	return 0;

imx415_dvdd_fail:
	regulator_disable(pw->iovdd);

imx415_iovdd_fail:
	regulator_disable(pw->avdd);

imx415_avdd_fail:
	dev_err(dev, "%s failed.\n", __func__);

	return -ENODEV;
}

static int imx415_power_off(struct camera_common_data *s_data)
{
	int err = 0;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = s_data->dev;

	dev_dbg(dev, "%s: power off\n", __func__);

	if (pdata && pdata->power_off) {
		err = pdata->power_off(pw);
		if (err) {
			dev_err(dev, "%s failed.\n", __func__);
			return err;
		}
	} else {
		if (pw->reset_gpio) {
			if (gpiod_cansleep(gpio_to_desc(pw->reset_gpio)))
				gpio_set_value_cansleep(pw->reset_gpio, 0);
			else
				gpio_set_value(pw->reset_gpio, 0);
		}

		usleep_range(10, 20);

		if (pw->dvdd)
			regulator_disable(pw->dvdd);
		if (pw->iovdd)
			regulator_disable(pw->iovdd);
		if (pw->avdd)
			regulator_disable(pw->avdd);
	}

	usleep_range(5000, 5000);
	pw->state = SWITCH_OFF;

	return 0;
}

static int imx415_power_put(struct tegracam_device *tc_dev)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct camera_common_power_rail *pw = s_data->power;

	if (unlikely(!pw))
		return -EFAULT;

	if (likely(pw->dvdd))
		devm_regulator_put(pw->dvdd);

	if (likely(pw->avdd))
		devm_regulator_put(pw->avdd);

	if (likely(pw->iovdd))
		devm_regulator_put(pw->iovdd);

	pw->dvdd = NULL;
	pw->avdd = NULL;
	pw->iovdd = NULL;

	if (likely(pw->reset_gpio))
		gpio_free(pw->reset_gpio);

	return 0;
}

static int imx415_power_get(struct tegracam_device *tc_dev)
{
	struct device *dev = tc_dev->dev;
	struct camera_common_data *s_data = tc_dev->s_data;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct clk *parent;
	int err = 0;

	if (!pdata) {
		dev_err(dev, "pdata missing\n");
		return -EFAULT;
	}

	/* Sensor MCLK (aka. INCK) */
	if (pdata->mclk_name) {
		pw->mclk = devm_clk_get(dev, pdata->mclk_name);
		if (IS_ERR(pw->mclk)) {
			dev_err(dev, "unable to get clock %s\n",
				pdata->mclk_name);
			return PTR_ERR(pw->mclk);
		}

		if (pdata->parentclk_name) {
			parent = devm_clk_get(dev, pdata->parentclk_name);
			if (IS_ERR(parent)) {
				dev_err(dev, "unable to get parent clock %s",
					pdata->parentclk_name);
			} else
				clk_set_parent(pw->mclk, parent);
		}
	}

	/* analog 2.9v */
	if (pdata->regulators.avdd)
		err |= camera_common_regulator_get(dev,
				&pw->avdd, pdata->regulators.avdd);
	/* IO 1.8v */
	if (pdata->regulators.iovdd)
		err |= camera_common_regulator_get(dev,
				&pw->iovdd, pdata->regulators.iovdd);
	/* dig 1.1v */
	if (pdata->regulators.dvdd)
		err |= camera_common_regulator_get(dev,
				&pw->dvdd, pdata->regulators.dvdd);
	if (err) {
		dev_err(dev, "%s: unable to get regulator(s)\n", __func__);
		goto done;
	}

	/* Reset (XCLR) GPIO */
	pw->reset_gpio = pdata->reset_gpio;
	err = gpio_request(pw->reset_gpio, "cam_reset_gpio");
	if (err < 0) {
		dev_err(dev, "%s: unable to request reset_gpio (%d)\n",
			__func__, err);
		goto done;
	}

done:
	pw->state = SWITCH_OFF;

	return err;
}

static struct camera_common_pdata *imx415_parse_dt(
	struct tegracam_device *tc_dev)
{
	struct device *dev = tc_dev->dev;
	struct device_node *np = dev->of_node;
	struct camera_common_pdata *board_priv_pdata;
	const struct of_device_id *match;
	struct camera_common_pdata *ret = NULL;
	int err = 0;
	int gpio;

	if (!np)
		return NULL;

	match = of_match_device(imx415_of_match, dev);
	if (!match) {
		dev_err(dev, "Failed to find matching dt id\n");
		return NULL;
	}

	board_priv_pdata = devm_kzalloc(dev,
		sizeof(*board_priv_pdata), GFP_KERNEL);
	if (!board_priv_pdata)
		return NULL;

	gpio = of_get_named_gpio(np, "reset-gpios", 0);
	if (gpio < 0) {
		if (gpio == -EPROBE_DEFER)
			ret = ERR_PTR(-EPROBE_DEFER);
		dev_err(dev, "reset-gpios not found\n");
		goto error;
	}
	board_priv_pdata->reset_gpio = (unsigned int)gpio;

	err = of_property_read_string(np, "mclk", &board_priv_pdata->mclk_name);
	if (err)
		dev_dbg(dev,
			"mclk name not present, assume sensor driven externally\n");

	err = of_property_read_string(np, "avdd-reg",
		&board_priv_pdata->regulators.avdd);
	err |= of_property_read_string(np, "iovdd-reg",
		&board_priv_pdata->regulators.iovdd);
	err |= of_property_read_string(np, "dvdd-reg",
		&board_priv_pdata->regulators.dvdd);
	if (err)
		dev_dbg(dev,
		"avdd, iovdd and/or dvdd reglrs. not present, assume sensor powered independently\n");

	return board_priv_pdata;

error:
	devm_kfree(dev, board_priv_pdata);

	return ret;
}

static int imx415_set_mode(struct tegracam_device *tc_dev)
{
	struct imx415 *priv = (struct imx415 *)tegracam_get_privdata(tc_dev);
	struct camera_common_data *s_data = tc_dev->s_data;

	int err = 0;

	/*
	 * Raw V4L2 sensor with no Argus/ISP consumer: actually program
	 * user gain/exposure/frame_rate controls into the hardware. With
	 * the tegracam default (false), the values cached by S_CTRL are
	 * never applied at stream-on and the sensor streams at mode
	 * defaults (gain 0, SHR0 8). Setting the field at probe does not
	 * survive: the VI channel re-inits its control handler on first
	 * open of the video device and v4l2_ctrl_handler_setup() pushes
	 * the OVERRIDE_ENABLE control default (0) through s_ctrl, which
	 * clears it (vi/channel.c). set_mode runs at every stream-on
	 * *before* tegracam checks the flag, so asserting it here wins.
	 * NB the OVERRIDE_ENABLE control readback stays at its own cached
	 * value (usually 0) - it is never synced from this field.
	 */
	s_data->override_enable = true;

	err = imx415_write_table(priv, mode_table[IMX415_MODE_COMMON]);
	if (err)
		return err;

	if (s_data->mode < 0)
		return -EINVAL;
	err = imx415_write_table(priv, mode_table[s_data->mode]);
	if (err)
		return err;

	return 0;
}

static int imx415_start_streaming(struct tegracam_device *tc_dev)
{
	struct imx415 *priv = (struct imx415 *)tegracam_get_privdata(tc_dev);

	return imx415_write_table(priv, mode_table[IMX415_START_STREAM]);
}

static int imx415_stop_streaming(struct tegracam_device *tc_dev)
{
	struct imx415 *priv = (struct imx415 *)tegracam_get_privdata(tc_dev);

	return imx415_write_table(priv, mode_table[IMX415_STOP_STREAM]);
}

static struct camera_common_sensor_ops imx415_common_ops = {
	.numfrmfmts = ARRAY_SIZE(imx415_frmfmt),
	.frmfmt_table = imx415_frmfmt,
	.power_on = imx415_power_on,
	.power_off = imx415_power_off,
	.write_reg = imx415_write_reg,
	.read_reg = imx415_read_reg,
	.parse_dt = imx415_parse_dt,
	.power_get = imx415_power_get,
	.power_put = imx415_power_put,
	.set_mode = imx415_set_mode,
	.start_streaming = imx415_start_streaming,
	.stop_streaming = imx415_stop_streaming,
};

static int imx415_board_setup(struct imx415 *priv)
{
	struct camera_common_data *s_data = priv->s_data;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = s_data->dev;
	u8 reg_val[2];
	u16 sensor_info;
	int err = 0;

	if (pdata->mclk_name) {
		err = camera_common_mclk_enable(s_data);
		if (err) {
			dev_err(dev, "error turning on mclk (%d)\n", err);
			goto done;
		}
	}

	err = imx415_power_on(s_data);
	if (err) {
		dev_err(dev, "error during power on sensor (%d)\n", err);
		goto err_power_on;
	}

	/*
	 * SENSOR_INFO is not readable in standby: leave standby first and
	 * wait the (empirical, see imx415_start_stream[]) 80 ms.
	 */
	err = imx415_write_reg(s_data, IMX415_MODE_ADDR, 0x00);
	if (err)
		goto err_reg_probe;
	msleep(80);

	err = imx415_read_reg(s_data, IMX415_SENSOR_INFO_ADDR_LOW,
		&reg_val[0]);
	if (err) {
		dev_err(dev, "%s: error during i2c read probe (%d)\n",
			__func__, err);
		goto err_reg_probe;
	}
	err = imx415_read_reg(s_data, IMX415_SENSOR_INFO_ADDR_HIGH,
		&reg_val[1]);
	if (err) {
		dev_err(dev, "%s: error during i2c read probe (%d)\n",
			__func__, err);
		goto err_reg_probe;
	}

	sensor_info = ((reg_val[1] << 8) | reg_val[0]) &
		IMX415_SENSOR_INFO_MASK;
	if (sensor_info != IMX415_CHIP_ID)
		dev_err(dev, "%s: invalid sensor model id: 0x%04x\n",
			__func__, sensor_info);
	else
		dev_dbg(dev, "%s: detected IMX415 sensor\n", __func__);

	err = imx415_write_reg(s_data, IMX415_MODE_ADDR, 0x01);

err_reg_probe:
	imx415_power_off(s_data);

err_power_on:
	if (pdata->mclk_name)
		camera_common_mclk_disable(s_data);

done:
	return err;
}

static int imx415_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	struct i2c_client *client = v4l2_get_subdevdata(sd);

	dev_dbg(&client->dev, "%s:\n", __func__);

	return 0;
}

static const struct v4l2_subdev_internal_ops imx415_subdev_internal_ops = {
	.open = imx415_open,
};

#if defined(NV_I2C_DRIVER_STRUCT_PROBE_WITHOUT_I2C_DEVICE_ID_ARG) /* Linux 6.3 */
static int imx415_probe(struct i2c_client *client)
#else
static int imx415_probe(struct i2c_client *client,
	const struct i2c_device_id *id)
#endif
{
	struct device *dev = &client->dev;
	struct tegracam_device *tc_dev;
	struct imx415 *priv;
	int err;

	dev_dbg(dev, "probing v4l2 sensor at addr 0x%0x\n", client->addr);

	if (!IS_ENABLED(CONFIG_OF) || !client->dev.of_node)
		return -EINVAL;

	priv = devm_kzalloc(dev,
			sizeof(struct imx415), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	tc_dev = devm_kzalloc(dev,
			sizeof(struct tegracam_device), GFP_KERNEL);
	if (!tc_dev)
		return -ENOMEM;

	priv->i2c_client = tc_dev->client = client;
	tc_dev->dev = dev;
	strncpy(tc_dev->name, "imx415", sizeof(tc_dev->name));
	tc_dev->dev_regmap_config = &sensor_regmap_config;
	tc_dev->sensor_ops = &imx415_common_ops;
	tc_dev->v4l2sd_internal_ops = &imx415_subdev_internal_ops;
	tc_dev->tcctrl_ops = &imx415_ctrl_ops;

	err = tegracam_device_register(tc_dev);
	if (err) {
		dev_err(dev, "tegra camera driver registration failed\n");
		return err;
	}
	priv->tc_dev = tc_dev;
	priv->s_data = tc_dev->s_data;
	priv->subdev = &tc_dev->s_data->subdev;
	priv->frame_length = IMX415_MIN_FRAME_LENGTH;
	tegracam_set_privdata(tc_dev, (void *)priv);

	err = imx415_board_setup(priv);
	if (err) {
		tegracam_device_unregister(tc_dev);
		dev_err(dev, "board setup failed\n");
		return err;
	}

	err = tegracam_v4l2subdev_register(tc_dev, true);
	if (err) {
		tegracam_device_unregister(tc_dev);
		dev_err(dev, "tegra camera subdev registration failed\n");
		return err;
	}

	/*
	 * The FRAME_RATE control is created at 0 and range-clamping then
	 * leaves its value at min_framerate (2 fps), not default_framerate:
	 * v4l2_ctrl_modify_range() clamps the current value into the new
	 * range but never applies the new default. With overrides enabled,
	 * every stream-on would program VMAX for 2 fps unless userspace set
	 * frame_rate explicitly (measured on target: VMAX 33750). Start the
	 * control at the DT default (30 fps); later user writes persist -
	 * the VI channel's first-open handler re-init only re-applies
	 * defaults of controls it owns, not the subdev's.
	 */
	{
		struct v4l2_ctrl *ctrl = v4l2_ctrl_find(
			&tc_dev->s_data->tegracam_ctrl_hdl->ctrl_handler,
			TEGRA_CAMERA_CID_FRAME_RATE);

		if (ctrl)
			v4l2_ctrl_s_ctrl_int64(ctrl,
				tc_dev->s_data->sensor_props.sensor_modes[0]
					.control_properties.default_framerate);
		else
			dev_warn(dev, "no frame_rate control to initialize\n");
	}

	dev_dbg(dev, "detected imx415 sensor\n");

	return 0;
}

#if defined(NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT) /* Linux 6.1 */
static int imx415_remove(struct i2c_client *client)
#else
static void imx415_remove(struct i2c_client *client)
#endif
{
	struct camera_common_data *s_data = to_camera_common_data(&client->dev);
	struct imx415 *priv;

	if (!s_data) {
		dev_err(&client->dev, "camera common data is NULL\n");
#if defined(NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT) /* Linux 6.1 */
		return -EINVAL;
#else
		return;
#endif
	}
	priv = (struct imx415 *)s_data->priv;

	tegracam_v4l2subdev_unregister(priv->tc_dev);
	tegracam_device_unregister(priv->tc_dev);

#if defined(NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT) /* Linux 6.1 */
	return 0;
#endif
}

static const struct i2c_device_id imx415_id[] = {
	{ "imx415", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, imx415_id);

static struct i2c_driver imx415_i2c_driver = {
	.driver = {
		.name = "imx415",
		.owner = THIS_MODULE,
		.of_match_table = of_match_ptr(imx415_of_match),
	},
	.probe = imx415_probe,
	.remove = imx415_remove,
	.id_table = imx415_id,
};
module_i2c_driver(imx415_i2c_driver);

MODULE_DESCRIPTION("Media Controller driver for Sony IMX415");
MODULE_AUTHOR("NVIDIA Corporation");
MODULE_LICENSE("GPL v2");
