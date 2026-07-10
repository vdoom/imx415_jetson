// SPDX-License-Identifier: MIT
/*
 * imx415_debayer - CUDA debayer pipeline for the IMX415 raw V4L2 camera
 * (Jetson Orin Nano, JetPack 6).
 *
 * V4L2 mmap capture (GB10, 3864x2192) -> one fused CUDA kernel:
 *   10-bit unpack (VI stores MSB-aligned: p = raw16 >> 6)
 *   -> black level subtract (50)
 *   -> GBRG 2x2 quad debayer to half resolution (1932x1096, no zippering)
 *   -> white balance -> normalize -> optional gamma
 *   -> packed RGB8 in device memory.
 *
 * The device buffer `d_rgb` after process_frame() is the integration point
 * for downstream consumers (CUDA inference preprocessing, NVENC, ...).
 *
 * Build on the Jetson:  make        (see Makefile; needs /usr/local/cuda)
 * Bench:                ./imx415_debayer --frames 300
 * Snapshot:             ./imx415_debayer --snap out.ppm --awb
 * 1080p center crop:    ./imx415_debayer --crop1080 --snap out.ppm
 */

#include <cuda_runtime.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#define SENSOR_W 3864
#define SENSOR_H 2192
/* 10-bit scale; from the RPi calibrated tuning file (rpi.black_level
 * 3840 on the 16-bit scale), not the 50 the BLKLEVEL register suggests. */
#define BLACK_LEVEL 60.0f
#define NUM_BUFFERS 8
#define TEGRA_CID_VI_BYPASS_MODE 0x009a2064
/*
 * Without OVERRIDE_ENABLE=1 the tegracam framework only CACHES user
 * gain/exposure/frame_rate writes (S_CTRL returns 0) and never programs
 * the sensor - measured on this board: GAIN_PCG_0/SHR0 stay at mode
 * defaults through any v4l2-ctl -c gain=.../exposure=... Setting it makes
 * the framework apply the cached controls at stream start.
 */
#define TEGRA_CID_OVERRIDE_ENABLE 0x009a2065
#define TEGRA_CID_SENSOR_MODE_ID 0x009a2008
#define TEGRA_CID_GAIN 0x009a2009
#define TEGRA_CID_EXPOSURE 0x009a200a

/*
 * CCM table, AWB CT curve and ALSC (lens shading) grids from the Raspberry
 * Pi calibrated tuning file for this sensor (libcamera
 * src/ipa/rpi/pisp/data/imx415.json), regenerate with gen_tuning.py.
 */
#include "tuning_data.h"

#define CUDA_CHECK(call)                                                     \
	do {                                                                 \
		cudaError_t e_ = (call);                                     \
		if (e_ != cudaSuccess) {                                     \
			fprintf(stderr, "CUDA error %s at %s:%d\n",          \
				cudaGetErrorString(e_), __FILE__, __LINE__); \
			exit(1);                                             \
		}                                                            \
	} while (0)

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do {
		r = ioctl(fd, req, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

/* ------------------------------------------------------------------ */
/* CUDA kernel                                                         */
/* ------------------------------------------------------------------ */

struct ProcParams {
	int shift;      /* raw16 -> pixel: 6 for 10-bit, 4 for 12-bit (VI MSB-aligns) */
	float black;    /* black level on the unpacked scale */
	float scale;    /* 1 / (maxval - black) */
	float wb_r, wb_g, wb_b;
	float ccm[9];    /* row-major color matrix (identity to disable) */
	float inv_gamma; /* 1/2.2, or 1.0 for linear output */
	int ox, oy;      /* crop offset in output (half-res) coordinates */
	/* ALSC gain grids (ALSC_GRID^2, device memory), NULL = disabled;
	 * alsc_l is pre-baked with the luminance strength on the host */
	const float *alsc_r, *alsc_b, *alsc_l;
};

/* Bilinear sample of a 32x32 ALSC grid at full-res pixel coords (fx, fy). */
__device__ static float alsc_sample(const float *tab, float fx, float fy)
{
	float gx = fx * (float)ALSC_GRID / SENSOR_W - 0.5f;
	float gy = fy * (float)ALSC_GRID / SENSOR_H - 0.5f;
	gx = fminf(fmaxf(gx, 0.0f), ALSC_GRID - 1.0f);
	gy = fminf(fmaxf(gy, 0.0f), ALSC_GRID - 1.0f);
	int x0 = (int)gx, y0 = (int)gy;
	int x1 = min(x0 + 1, ALSC_GRID - 1), y1 = min(y0 + 1, ALSC_GRID - 1);
	float ax = gx - x0, ay = gy - y0;
	float top = tab[y0 * ALSC_GRID + x0] * (1.0f - ax) +
		    tab[y0 * ALSC_GRID + x1] * ax;
	float bot = tab[y1 * ALSC_GRID + x0] * (1.0f - ax) +
		    tab[y1 * ALSC_GRID + x1] * ax;
	return top * (1.0f - ay) + bot * ay;
}

__global__ void debayer_gbrg_half(const uint16_t *__restrict__ raw,
				  int raw_pitch16, uint8_t *__restrict__ rgb,
				  int out_w, int out_h, ProcParams p)
{
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;
	if (x >= out_w || y >= out_h)
		return;

	int sx = 2 * (x + p.ox);
	int sy = 2 * (y + p.oy);
	const uint16_t *r0 = raw + (size_t)sy * raw_pitch16;
	const uint16_t *r1 = r0 + raw_pitch16;

	/* GBRG quad: (0,0)=G1 (0,1)=B (1,0)=R (1,1)=G2; VI MSB-aligns the
	 * N-bit sample in 16 bits, so the pixel value is raw16 >> shift. */
	int s = p.shift;
	float g1 = (float)(r0[sx] >> s) - p.black;
	float b = (float)(r0[sx + 1] >> s) - p.black;
	float r = (float)(r1[sx] >> s) - p.black;
	float g2 = (float)(r1[sx + 1] >> s) - p.black;

	float R = fmaxf(r, 0.0f) * p.scale * p.wb_r;
	float G = fmaxf(0.5f * (g1 + g2), 0.0f) * p.scale * p.wb_g;
	float B = fmaxf(b, 0.0f) * p.scale * p.wb_b;

	/* lens shading: Cr/Cb color gains + attenuated luminance gain,
	 * sampled at the 2x2 quad center */
	if (p.alsc_r) {
		float fx = sx + 1.0f, fy = sy + 1.0f;
		float lum = alsc_sample(p.alsc_l, fx, fy);
		R *= alsc_sample(p.alsc_r, fx, fy) * lum;
		G *= lum;
		B *= alsc_sample(p.alsc_b, fx, fy) * lum;
	}

	/* clamp before the CCM: G saturates first, so unclamped WB'd R/B
	 * would tint blown highlights pink through the matrix */
	R = fminf(R, 1.0f);
	G = fminf(G, 1.0f);
	B = fminf(B, 1.0f);

	float Rc = p.ccm[0] * R + p.ccm[1] * G + p.ccm[2] * B;
	float Gc = p.ccm[3] * R + p.ccm[4] * G + p.ccm[5] * B;
	float Bc = p.ccm[6] * R + p.ccm[7] * G + p.ccm[8] * B;

	R = fminf(fmaxf(Rc, 0.0f), 1.0f);
	G = fminf(fmaxf(Gc, 0.0f), 1.0f);
	B = fminf(fmaxf(Bc, 0.0f), 1.0f);
	if (p.inv_gamma != 1.0f) {
		R = __powf(R, p.inv_gamma);
		G = __powf(G, p.inv_gamma);
		B = __powf(B, p.inv_gamma);
	}

	uint8_t *px = rgb + 3 * ((size_t)y * out_w + x);
	px[0] = (uint8_t)(255.0f * R + 0.5f);
	px[1] = (uint8_t)(255.0f * G + 0.5f);
	px[2] = (uint8_t)(255.0f * B + 0.5f);
}

/* ------------------------------------------------------------------ */
/* V4L2 capture                                                        */
/* ------------------------------------------------------------------ */

struct Capture {
	int fd;
	void *buf_start[NUM_BUFFERS];
	size_t buf_len[NUM_BUFFERS];
	unsigned int pitch_bytes;
	unsigned int sizeimage;
};

/* int64 controls (sensor_mode/gain/exposure) need S_EXT_CTRLS; S_CTRL
 * only handles 32-bit and returns EINVAL. */
static void set_i64_ctrl(int fd, uint32_t id, int64_t val, const char *name)
{
	struct v4l2_ext_control ec = {};
	ec.id = id;
	ec.value64 = val;
	struct v4l2_ext_controls ecs = {};
	ecs.which = V4L2_CTRL_WHICH_CUR_VAL;
	ecs.count = 1;
	ecs.controls = &ec;
	if (xioctl(fd, VIDIOC_S_EXT_CTRLS, &ecs) < 0)
		fprintf(stderr, "warning: %s not set (%s)\n", name,
			strerror(errno));
}

static void cap_open(Capture *c, const char *dev, uint32_t pixfmt,
		     int sensor_mode, int64_t exposure_us, int64_t gain_mdb)
{
	c->fd = open(dev, O_RDWR | O_NONBLOCK);
	if (c->fd < 0) {
		perror(dev);
		exit(1);
	}

	struct v4l2_control ctrl = {};
	ctrl.id = TEGRA_CID_VI_BYPASS_MODE;
	ctrl.value = 0;
	if (xioctl(c->fd, VIDIOC_S_CTRL, &ctrl) < 0)
		fprintf(stderr, "warning: bypass_mode not set (%s)\n",
			strerror(errno));

	/* Without this the sensor silently ignores gain/exposure (see top). */
	ctrl.id = TEGRA_CID_OVERRIDE_ENABLE;
	ctrl.value = 1;
	if (xioctl(c->fd, VIDIOC_S_CTRL, &ctrl) < 0)
		fprintf(stderr, "warning: override_enable not set (%s)\n",
			strerror(errno));

	/* Select the DT modeN (0 = 10-bit, 1 = 12-bit) before S_FMT. The
	 * requested pixel format (GB10/GB12) also drives mode selection,
	 * so this is belt-and-suspenders for the same-resolution modes. */
	set_i64_ctrl(c->fd, TEGRA_CID_SENSOR_MODE_ID, sensor_mode,
		     "sensor_mode");

	/* <0 = leave the cached value (last v4l2-ctl -c setting) */
	if (exposure_us >= 0)
		set_i64_ctrl(c->fd, TEGRA_CID_EXPOSURE, exposure_us,
			     "exposure");
	if (gain_mdb >= 0)
		set_i64_ctrl(c->fd, TEGRA_CID_GAIN, gain_mdb, "gain");

	struct v4l2_format fmt = {};
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	fmt.fmt.pix.width = SENSOR_W;
	fmt.fmt.pix.height = SENSOR_H;
	fmt.fmt.pix.pixelformat = pixfmt;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(c->fd, VIDIOC_S_FMT, &fmt) < 0) {
		perror("VIDIOC_S_FMT");
		exit(1);
	}
	if (fmt.fmt.pix.width != SENSOR_W || fmt.fmt.pix.height != SENSOR_H ||
	    fmt.fmt.pix.pixelformat != pixfmt) {
		fprintf(stderr, "driver did not accept %ux%u fmt 0x%08x\n",
			SENSOR_W, SENSOR_H, pixfmt);
		exit(1);
	}
	c->pitch_bytes = fmt.fmt.pix.bytesperline;
	c->sizeimage = fmt.fmt.pix.sizeimage;

	struct v4l2_requestbuffers req = {};
	req.count = NUM_BUFFERS;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(c->fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
		perror("VIDIOC_REQBUFS");
		exit(1);
	}

	for (unsigned int i = 0; i < req.count; i++) {
		struct v4l2_buffer b = {};
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (xioctl(c->fd, VIDIOC_QUERYBUF, &b) < 0) {
			perror("VIDIOC_QUERYBUF");
			exit(1);
		}
		c->buf_len[i] = b.length;
		c->buf_start[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
				       MAP_SHARED, c->fd, b.m.offset);
		if (c->buf_start[i] == MAP_FAILED) {
			perror("mmap");
			exit(1);
		}
		if (xioctl(c->fd, VIDIOC_QBUF, &b) < 0) {
			perror("VIDIOC_QBUF");
			exit(1);
		}
	}

	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(c->fd, VIDIOC_STREAMON, &type) < 0) {
		perror("VIDIOC_STREAMON");
		exit(1);
	}
}

/* Blocks (select) until a frame is ready; returns buffer index. */
static int cap_dqbuf(Capture *c, struct v4l2_buffer *b)
{
	fd_set fds;
	struct timeval tv = { 5, 0 };
	FD_ZERO(&fds);
	FD_SET(c->fd, &fds);
	if (select(c->fd + 1, &fds, NULL, NULL, &tv) <= 0) {
		fprintf(stderr, "capture timeout/error\n");
		exit(1);
	}
	memset(b, 0, sizeof(*b));
	b->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	b->memory = V4L2_MEMORY_MMAP;
	if (xioctl(c->fd, VIDIOC_DQBUF, b) < 0) {
		perror("VIDIOC_DQBUF");
		exit(1);
	}
	return b->index;
}

static void cap_close(Capture *c)
{
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &type);
	for (int i = 0; i < NUM_BUFFERS; i++)
		if (c->buf_start[i])
			munmap(c->buf_start[i], c->buf_len[i]);
	close(c->fd);
}

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

/* CT-interpolated CCM from the tuning table; identity if ct <= 0. */
static void ccm_for_ct(float ct, float *m)
{
	if (ct <= 0.0f) {
		for (int i = 0; i < 9; i++)
			m[i] = (i % 4 == 0) ? 1.0f : 0.0f;
		return;
	}
	if (ct <= ccm_table[0].ct) {
		memcpy(m, ccm_table[0].m, 9 * sizeof(float));
		return;
	}
	if (ct >= ccm_table[CCM_TABLE_LEN - 1].ct) {
		memcpy(m, ccm_table[CCM_TABLE_LEN - 1].m, 9 * sizeof(float));
		return;
	}
	for (unsigned int i = 1; i < CCM_TABLE_LEN; i++) {
		if (ct <= ccm_table[i].ct) {
			float f = (ct - ccm_table[i - 1].ct) /
				  (ccm_table[i].ct - ccm_table[i - 1].ct);
			for (int j = 0; j < 9; j++)
				m[j] = (1.0f - f) * ccm_table[i - 1].m[j] +
				       f * ccm_table[i].m[j];
			return;
		}
	}
}

/*
 * Gray-world channel ratios (r = R/G, b = B/G) from the central half of
 * one raw frame (CPU, subsampled). Central crop: lens shading is ~flat
 * there, so the estimate doesn't need ALSC applied first. Returns 0 if
 * the frame is too dark to trust.
 */
static int measure_ratios(const uint16_t *raw, int pitch16, int shift,
			  float black, float *r_ratio, float *b_ratio)
{
	double sr = 0, sg = 0, sb = 0;
	long n = 0;
	for (int y = SENSOR_H / 4; y < 3 * SENSOR_H / 4; y += 16) {
		const uint16_t *r0 = raw + (size_t)y * pitch16;
		const uint16_t *r1 = r0 + pitch16;
		for (int x = SENSOR_W / 4; x < 3 * SENSOR_W / 4; x += 16) {
			float g1 = (float)(r0[x] >> shift) - black;
			float b = (float)(r0[x + 1] >> shift) - black;
			float r = (float)(r1[x] >> shift) - black;
			float g2 = (float)(r1[x + 1] >> shift) - black;
			sr += r > 0 ? r : 0;
			sb += b > 0 ? b : 0;
			sg += 0.5 * ((g1 > 0 ? g1 : 0) + (g2 > 0 ? g2 : 0));
			n++;
		}
	}
	if (!n || sr <= n || sb <= n || sg <= n) /* require real signal */
		return 0;
	*r_ratio = (float)(sr / sg);
	*b_ratio = (float)(sb / sg);
	return 1;
}

/*
 * Estimate the illuminant CT by projecting measured (r, b) ratios onto
 * the calibrated AWB CT curve (the locus of neutral-patch ratios over
 * illuminant temperature). CT only selects the CCM and ALSC tables; the
 * WB gains stay pure gray-world — this module sits ~0.07 off the RPi
 * curve (different IR-cut filter/lens than the calibrated unit), so
 * clamping the white point to the curve's transverse limits (0.011/0.014)
 * was tried and leaves a visible green cast on known-neutral surfaces.
 */
static float awb_ct_estimate(float rm, float bm)
{
	float best_d2 = 1e30f, best_ct = 4600.0f;

	for (unsigned int i = 0; i + 1 < CT_CURVE_LEN; i++) {
		float dx = ct_curve[i + 1].r - ct_curve[i].r;
		float dy = ct_curve[i + 1].b - ct_curve[i].b;
		float len2 = dx * dx + dy * dy;
		float t = ((rm - ct_curve[i].r) * dx +
			   (bm - ct_curve[i].b) * dy) / len2;
		t = fminf(fmaxf(t, 0.0f), 1.0f);
		float pr = ct_curve[i].r + t * dx;
		float pb = ct_curve[i].b + t * dy;
		float d2 = (rm - pr) * (rm - pr) + (bm - pb) * (bm - pb);
		if (d2 < best_d2) {
			best_d2 = d2;
			best_ct = ct_curve[i].ct +
				  t * (ct_curve[i + 1].ct - ct_curve[i].ct);
		}
	}

	return best_ct;
}

/* WB gains for a forced CT: the curve point itself (manual WB by kelvin). */
static void awb_gains_for_ct(float ct, float *wr, float *wb)
{
	float rm, bm;
	if (ct <= ct_curve[0].ct) {
		rm = ct_curve[0].r;
		bm = ct_curve[0].b;
	} else if (ct >= ct_curve[CT_CURVE_LEN - 1].ct) {
		rm = ct_curve[CT_CURVE_LEN - 1].r;
		bm = ct_curve[CT_CURVE_LEN - 1].b;
	} else {
		rm = bm = 0;
		for (unsigned int i = 1; i < CT_CURVE_LEN; i++) {
			if (ct <= ct_curve[i].ct) {
				float f = (ct - ct_curve[i - 1].ct) /
					  (ct_curve[i].ct - ct_curve[i - 1].ct);
				rm = ct_curve[i - 1].r +
				     f * (ct_curve[i].r - ct_curve[i - 1].r);
				bm = ct_curve[i - 1].b +
				     f * (ct_curve[i].b - ct_curve[i - 1].b);
				break;
			}
		}
	}
	*wr = 1.0f / rm;
	*wb = 1.0f / bm;
}

/*
 * Build the three ALSC grids for a color temperature: Cr/Cb blended
 * between the two calibrated CTs, luminance pre-baked with its strength.
 * dst must hold 3 * ALSC_GRID^2 floats: [Cr | Cb | lum].
 */
static void alsc_build(float ct, float *dst)
{
	int n = ALSC_GRID * ALSC_GRID;
	float f = (ct - ALSC_CT_LO) / (float)(ALSC_CT_HI - ALSC_CT_LO);
	f = fminf(fmaxf(f, 0.0f), 1.0f);
	for (int i = 0; i < n; i++) {
		dst[i] = (1.0f - f) * alsc_cr_3000[i] + f * alsc_cr_5000[i];
		dst[n + i] = (1.0f - f) * alsc_cb_3000[i] + f * alsc_cb_5000[i];
		dst[2 * n + i] =
			1.0f + ALSC_LUM_STRENGTH * (alsc_lum[i] - 1.0f);
	}
}

static void save_ppm(const char *path, const uint8_t *rgb, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (!f) {
		perror(path);
		return;
	}
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	fwrite(rgb, 1, (size_t)w * h * 3, f);
	fclose(f);
	printf("saved %s (%dx%d)\n", path, w, h);
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
	const char *dev = "/dev/video0";
	const char *snap_path = NULL;
	int frames = 300;
	int snap_at = 30;
	int out_w = SENSOR_W / 2, out_h = SENSOR_H / 2; /* 1932x1096 */
	int crop1080 = 0, awb = 1, linear = 0, bits = 10;
	int use_alsc = 1, no_ccm = 0, wb_manual = 0;
	int64_t exposure_us = -1, gain_mdb = -1; /* <0 = keep cached value */
	float wb_r = 1.0f, wb_g = 1.0f, wb_b = 1.0f;
	float ct = 0.0f; /* 0 = auto from AWB; --ct forces */

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--device") && i + 1 < argc)
			dev = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc)
			frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--snap") && i + 1 < argc)
			snap_path = argv[++i];
		else if (!strcmp(argv[i], "--snap-at") && i + 1 < argc)
			snap_at = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--bits") && i + 1 < argc)
			bits = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--exposure") && i + 1 < argc)
			exposure_us = atoll(argv[++i]);
		else if (!strcmp(argv[i], "--gain") && i + 1 < argc)
			gain_mdb = atoll(argv[++i]);
		else if (!strcmp(argv[i], "--crop1080"))
			crop1080 = 1;
		else if (!strcmp(argv[i], "--awb"))
			awb = 1; /* default; kept for compatibility */
		else if (!strcmp(argv[i], "--no-awb"))
			awb = 0;
		else if (!strcmp(argv[i], "--no-alsc"))
			use_alsc = 0;
		else if (!strcmp(argv[i], "--linear"))
			linear = 1;
		else if (!strcmp(argv[i], "--wb") && i + 3 < argc) {
			wb_r = atof(argv[++i]);
			wb_g = atof(argv[++i]);
			wb_b = atof(argv[++i]);
			wb_manual = 1;
		} else if (!strcmp(argv[i], "--ct") && i + 1 < argc)
			ct = atof(argv[++i]);
		else if (!strcmp(argv[i], "--no-ccm"))
			no_ccm = 1;
		else {
			fprintf(stderr,
				"usage: %s [--device /dev/video0] [--frames N]\n"
				"  [--snap out.ppm] [--snap-at N] [--bits 10|12]\n"
				"  [--exposure US] [--gain MDB] [--crop1080]\n"
				"  [--no-awb] [--wb R G B] [--ct kelvin]\n"
				"  [--no-ccm] [--no-alsc] [--linear]\n",
				argv[0]);
			return 1;
		}
	}
	if (bits != 10 && bits != 12) {
		fprintf(stderr, "--bits must be 10 or 12\n");
		return 1;
	}

	/*
	 * VI MSB-aligns the N-bit sample in a 16-bit word, so the pixel is
	 * raw16 >> (16 - bits). Black level 60 (10-bit, from the RPi tuning
	 * file) scales with bit depth. 10-bit = mode0/GB10, 12-bit = mode1/GB12.
	 */
	uint32_t pixfmt = (bits == 12) ? V4L2_PIX_FMT_SGBRG12
				       : V4L2_PIX_FMT_SGBRG10;
	int sensor_mode = (bits == 12) ? 1 : 0;
	float maxval = (bits == 12) ? 4095.0f : 1023.0f;

	ProcParams p = {};
	p.shift = 16 - bits;
	p.black = BLACK_LEVEL * (bits == 12 ? 4.0f : 1.0f);
	p.scale = 1.0f / (maxval - p.black);
	p.wb_r = wb_r;
	p.wb_g = wb_g;
	p.wb_b = wb_b;
	ccm_for_ct(0, p.ccm); /* identity; real CCM picked at frame 0 */
	p.inv_gamma = linear ? 1.0f : (1.0f / 2.2f);
	if (crop1080) {
		out_w = 1920;
		out_h = 1080;
		p.ox = (SENSOR_W / 2 - out_w) / 2; /* 6 */
		p.oy = (SENSOR_H / 2 - out_h) / 2; /* 8 */
	}

	/* must precede any CUDA context creation (for zero-copy mapping) */
	cudaSetDeviceFlags(cudaDeviceMapHost);

	Capture cap = {};
	cap_open(&cap, dev, pixfmt, sensor_mode, exposure_us, gain_mdb);
	int pitch16 = cap.pitch_bytes / 2;

	/*
	 * Zero-copy: on Tegra the iGPU shares DRAM with the CPU, so the
	 * V4L2 capture buffers (uncached DMA memory - a CPU memcpy from
	 * them runs at ~1 GB/s = 17 ms/frame) can be registered with CUDA
	 * and read by the kernel directly. Falls back to memcpy if the
	 * registration is refused.
	 */
	uint16_t *d_bufmap[NUM_BUFFERS] = {};
	int zero_copy = 1;
	for (int i = 0; i < NUM_BUFFERS && zero_copy; i++) {
		if (cudaHostRegister(cap.buf_start[i], cap.buf_len[i],
				     cudaHostRegisterMapped) != cudaSuccess ||
		    cudaHostGetDevicePointer((void **)&d_bufmap[i],
					     cap.buf_start[i], 0) != cudaSuccess)
			zero_copy = 0;
	}
	if (!zero_copy)
		cudaGetLastError(); /* clear the sticky error */

	printf("capture: %dx%d GB%d (mode%d), pitch %u B; out: %dx%d RGB8%s; %s\n",
	       SENSOR_W, SENSOR_H, bits, sensor_mode, cap.pitch_bytes, out_w,
	       out_h, linear ? " (linear)" : "",
	       zero_copy ? "zero-copy input" : "memcpy input (fallback)");

	uint16_t *d_raw = NULL;
	uint8_t *d_rgb, *h_rgb;
	float *d_alsc = NULL;
	if (!zero_copy)
		CUDA_CHECK(cudaMalloc(&d_raw, cap.sizeimage));
	CUDA_CHECK(cudaMalloc(&d_rgb, (size_t)out_w * out_h * 3));
	if (use_alsc)
		CUDA_CHECK(cudaMalloc(&d_alsc,
				      3 * ALSC_GRID * ALSC_GRID *
					      sizeof(float)));
	h_rgb = (uint8_t *)malloc((size_t)out_w * out_h * 3);

	dim3 blk(32, 8);
	dim3 grd((out_w + blk.x - 1) / blk.x, (out_h + blk.y - 1) / blk.y);
	cudaEvent_t ev0, ev1;
	CUDA_CHECK(cudaEventCreate(&ev0));
	CUDA_CHECK(cudaEventCreate(&ev1));

	double t_start = 0;
	float kern_ms_sum = 0;
	double copy_s_sum = 0;
	int color_at = frames > 8 ? 8 : frames - 1;

	for (int i = 0; i < frames; i++) {
		struct v4l2_buffer b;
		int idx = cap_dqbuf(&cap, &b);

		if (i == 0)
			t_start = now_s();

		/* AWB after a short warm-up: exposure/gain programmed at
		 * stream-on only take effect a few frames in */
		if (i == color_at) {
			/* AWB -> CT estimate -> CCM/ALSC selection, all
			 * from the calibrated tuning data */
			float ct_used = ct; /* >0 = forced via --ct */
			if (awb) {
				float rm, bm;
				if (measure_ratios(
					    (const uint16_t *)cap.buf_start[idx],
					    pitch16, p.shift, p.black, &rm,
					    &bm)) {
					float ct_est = awb_ct_estimate(rm, bm);
					if (!wb_manual) {
						p.wb_r = 1.0f / rm;
						p.wb_g = 1.0f;
						p.wb_b = 1.0f / bm;
					}
					if (ct_used <= 0)
						ct_used = ct_est;
					printf("awb: R/G %.3f B/G %.3f -> "
					       "%.0f K, gains R %.3f B %.3f\n",
					       rm, bm, ct_est, p.wb_r,
					       p.wb_b);
				} else {
					fprintf(stderr,
						"awb: frame too dark, "
						"keeping current gains\n");
				}
			} else if (!wb_manual && ct_used > 0) {
				awb_gains_for_ct(ct_used, &p.wb_r, &p.wb_b);
				p.wb_g = 1.0f;
				printf("wb from --ct %.0f K: gains R %.3f "
				       "B %.3f\n",
				       ct_used, p.wb_r, p.wb_b);
			}
			if (ct_used <= 0)
				ct_used = 4600.0f; /* nothing measured/forced */
			if (!no_ccm)
				ccm_for_ct(ct_used, p.ccm);
			if (use_alsc) {
				float h_alsc[3 * ALSC_GRID * ALSC_GRID];
				alsc_build(ct_used, h_alsc);
				CUDA_CHECK(cudaMemcpy(d_alsc, h_alsc,
						      sizeof(h_alsc),
						      cudaMemcpyHostToDevice));
				p.alsc_r = d_alsc;
				p.alsc_b = d_alsc + ALSC_GRID * ALSC_GRID;
				p.alsc_l = d_alsc + 2 * ALSC_GRID * ALSC_GRID;
			}
			printf("color: CT %.0f K, CCM %s, ALSC %s\n", ct_used,
			       no_ccm ? "off" : "on", use_alsc ? "on" : "off");
		}

		const uint16_t *src;
		if (zero_copy) {
			src = d_bufmap[idx];
		} else {
			double c0 = now_s();
			CUDA_CHECK(cudaMemcpy(d_raw, cap.buf_start[idx],
					      cap.sizeimage,
					      cudaMemcpyHostToDevice));
			copy_s_sum += now_s() - c0;
			src = d_raw;
		}

		CUDA_CHECK(cudaEventRecord(ev0));
		debayer_gbrg_half<<<grd, blk>>>(src, pitch16, d_rgb, out_w,
						out_h, p);
		CUDA_CHECK(cudaEventRecord(ev1));
		CUDA_CHECK(cudaEventSynchronize(ev1));
		float ms;
		CUDA_CHECK(cudaEventElapsedTime(&ms, ev0, ev1));
		kern_ms_sum += ms;

		/*
		 * d_rgb now holds the processed frame on the GPU.
		 * >>> Integration point: hand d_rgb to your consumer here <<<
		 */

		if (snap_path && i == snap_at) {
			CUDA_CHECK(cudaMemcpy(h_rgb, d_rgb,
					      (size_t)out_w * out_h * 3,
					      cudaMemcpyDeviceToHost));
			save_ppm(snap_path, h_rgb, out_w, out_h);
		}

		if (xioctl(cap.fd, VIDIOC_QBUF, &b) < 0) {
			perror("VIDIOC_QBUF");
			exit(1);
		}

		if (i > 0 && i % 100 == 0) {
			double el = now_s() - t_start;
			printf("frame %4d  avg %.2f fps  copy %.2f ms  "
			       "kernel %.3f ms\n",
			       i, i / el, 1e3 * copy_s_sum / i,
			       kern_ms_sum / i);
		}
	}

	double el = now_s() - t_start;
	printf("done: %d frames in %.2f s = %.2f fps "
	       "(copy %.2f ms, kernel %.3f ms per frame)\n",
	       frames, el, (frames - 1) / el, 1e3 * copy_s_sum / frames,
	       kern_ms_sum / frames);

	if (zero_copy)
		for (int i = 0; i < NUM_BUFFERS; i++)
			cudaHostUnregister(cap.buf_start[i]);
	cap_close(&cap);
	if (d_raw)
		cudaFree(d_raw);
	if (d_alsc)
		cudaFree(d_alsc);
	cudaFree(d_rgb);
	free(h_rgb);
	return 0;
}
