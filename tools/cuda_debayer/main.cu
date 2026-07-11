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
#include <csignal>
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

static volatile sig_atomic_t g_stop;

static void on_stop(int sig)
{
	(void)sig;
	g_stop = 1;
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
	/*
	 * Per-sensor-row horizontal compensation, indexed by row & 3.
	 * The 4-lane/891M link delivers rows with a deterministic
	 * alternating ~16 px horizontal slip (2-row blocks, period 4;
	 * measured on raw CFA planes - see zigzag_check). Values are
	 * EVEN pixel counts (CFA phase preserved), measured at startup;
	 * all zero when the link is clean.
	 */
	int rowshift[4];
	/* ALSC gain grids (ALSC_GRID^2, device memory), NULL = disabled;
	 * alsc_l is pre-baked with the luminance strength on the host */
	const float *alsc_r, *alsc_b, *alsc_l;
};

/* Row-shifted x with border clamp; shift is even so CFA phase holds. */
__device__ static inline int shifted_x(int sx, int shift)
{
	int v = sx + shift;

	if (v < 2)
		v = 2;
	if (v > SENSOR_W - 4)
		v = SENSOR_W - 4;
	return v;
}

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

	/*
	 * Every sensor row is read at its own compensated x (p.rowshift,
	 * all even): undoes the 4-lane link's alternating ~16 px row slip
	 * before any demosaic math sees the data. All zero on a clean link.
	 */
	int yn = sy >= 1 ? sy - 1 : sy + 1;		   /* R row north */
	int ys = sy + 2 <= SENSOR_H - 2 ? sy + 2 : sy;	   /* B row south */
	int x0 = shifted_x(sx, p.rowshift[sy & 3]);	   /* G1/B row */
	int x1 = shifted_x(sx, p.rowshift[(sy + 1) & 3]);  /* R/G2 row */
	int xn = shifted_x(sx, p.rowshift[yn & 3]);
	int xs2 = shifted_x(sx, p.rowshift[ys & 3]);
	const uint16_t *rn = raw + (size_t)yn * raw_pitch16;
	const uint16_t *rs = raw + (size_t)ys * raw_pitch16;

	/* GBRG quad: (0,0)=G1 (0,1)=B (1,0)=R (1,1)=G2; VI MSB-aligns the
	 * N-bit sample in 16 bits, so the pixel value is raw16 >> shift. */
	int s = p.shift;
	float g1 = (float)(r0[x0] >> s) - p.black;
	float g2 = (float)(r1[x1 + 1] >> s) - p.black;

	/*
	 * The two G samples average to the quad center, but B sits at
	 * (+0.5,-0.5) and R at (-0.5,+0.5) from it. Taking them as-is
	 * misregisters R against B by a full pixel diagonally - thin
	 * green/magenta fringes on every high-contrast edge (measured
	 * |R-B| up to 159/255 on a synthetic achromatic step). Bilinearly
	 * resample both to the quad center from their 4 nearest CFA sites
	 * (weights 9/3/3/1 over 16): fringing on smooth (lens-blurred)
	 * edges cancels, hard-step worst case halves.
	 */
	float b = 0.5625f * (float)(r0[x0 + 1] >> s) +
		  0.1875f * (float)(r0[x0 - 1] >> s) +
		  0.1875f * (float)(rs[xs2 + 1] >> s) +
		  0.0625f * (float)(rs[xs2 - 1] >> s) - p.black;
	float r = 0.5625f * (float)(r1[x1] >> s) +
		  0.1875f * (float)(r1[x1 + 2] >> s) +
		  0.1875f * (float)(rn[xn] >> s) +
		  0.0625f * (float)(rn[xn + 2] >> s) - p.black;

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

/*
 * RGB8 -> YUYV 4:2:2 (BT.601 limited range) for the v4l2loopback output.
 * One thread per 2-pixel macropixel; chroma is the average of the pair.
 */
__global__ void rgb_to_yuyv(const uint8_t *__restrict__ rgb,
			    uint8_t *__restrict__ yuyv, int w, int h)
{
	int mx = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;

	if (mx >= w / 2 || y >= h)
		return;
	const uint8_t *p = rgb + ((size_t)y * w + 2 * mx) * 3;
	float r0 = p[0], g0 = p[1], b0 = p[2];
	float r1 = p[3], g1 = p[4], b1 = p[5];
	float ra = 0.5f * (r0 + r1);
	float ga = 0.5f * (g0 + g1);
	float ba = 0.5f * (b0 + b1);
	float y0 = 16.0f + 0.257f * r0 + 0.504f * g0 + 0.098f * b0;
	float y1 = 16.0f + 0.257f * r1 + 0.504f * g1 + 0.098f * b1;
	float u = 128.0f - 0.148f * ra - 0.291f * ga + 0.439f * ba;
	float v = 128.0f + 0.439f * ra - 0.368f * ga - 0.071f * ba;
	uint8_t *o = yuyv + ((size_t)y * (w / 2) + mx) * 4;

	o[0] = (uint8_t)fminf(fmaxf(y0, 0.0f), 255.0f);
	o[1] = (uint8_t)fminf(fmaxf(u, 0.0f), 255.0f);
	o[2] = (uint8_t)fminf(fmaxf(y1, 0.0f), 255.0f);
	o[3] = (uint8_t)fminf(fmaxf(v, 0.0f), 255.0f);
}

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
	int r = select(c->fd + 1, &fds, NULL, NULL, &tv);
	if (r < 0 && errno == EINTR)
		return -1; /* interrupted (Ctrl-C) - caller stops cleanly */
	if (r <= 0) {
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

/*
 * Open a v4l2loopback device for writing and set the output format.
 * Consumers (ffplay, VLC, GStreamer, OpenCV, browsers) then read it
 * like a regular webcam.
 */
static int loopback_open(const char *dev, int w, int h)
{
	int fd = open(dev, O_WRONLY);
	if (fd < 0) {
		perror(dev);
		fprintf(stderr,
			"is v4l2loopback loaded?  sudo modprobe v4l2loopback "
			"video_nr=10 card_label=IMX415 exclusive_caps=1\n");
		exit(1);
	}
	struct v4l2_format f = {};
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.bytesperline = w * 2;
	f.fmt.pix.sizeimage = (uint32_t)(w * h * 2);
	f.fmt.pix.colorspace = V4L2_COLORSPACE_SMPTE170M;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		perror("loopback VIDIOC_S_FMT");
		exit(1);
	}
	return fd;
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

/* ------------------------------------------------------------------ */
/* auto-exposure                                                       */
/* ------------------------------------------------------------------ */

#define AE_EXP_MIN_US 59    /* DT min_exp_time */
#define AE_GAIN_MAX_MDB 30000
#define AE_GAIN_STEP_MDB 300 /* driver quantizes to 0.3 dB anyway */
#define AE_SETTLE_FRAMES 4  /* control write lands ~2 frames later */

/*
 * Mean green level (0..1, black-subtracted) and clipped-sample fraction,
 * full frame subsampled 16x16. Same CPU-side read of the uncached buffer
 * as measure_ratios: ~130 KB touched, ~0.15 ms.
 */
static void measure_luma(const uint16_t *raw, int pitch16, int shift,
			 float black, float maxval, float *mean01, float *sat)
{
	double sg = 0;
	long n = 0, nsat = 0;
	float satlvl = 0.98f * maxval;

	for (int y = 0; y < SENSOR_H - 1; y += 16) {
		const uint16_t *r0 = raw + (size_t)y * pitch16;
		const uint16_t *r1 = r0 + pitch16;
		for (int x = 0; x < SENSOR_W - 1; x += 16) {
			/* GBRG quad: G at r0[x] and r1[x+1] */
			float g1 = (float)(r0[x] >> shift);
			float g2 = (float)(r1[x + 1] >> shift);
			if (g1 >= satlvl || g2 >= satlvl)
				nsat++;
			float g = 0.5f * (g1 + g2) - black;
			sg += g > 0 ? g : 0;
			n++;
		}
	}
	*mean01 = n ? (float)(sg / n) / (maxval - black) : 0.0f;
	*sat = n ? (float)nsat / n : 0.0f;
}

/*
 * Detect the 4-lane link's row slip staircase from one raw frame.
 * The link displaces each sensor row horizontally by d[row & 3] (a
 * per-4-row staircase, ~ +12 -12 -4 +4 px measured on this unit).
 * Adjacent rows image nearly the same scene, so the per-boundary
 * offset d[ph+1]-d[ph] is measurable by sub-pixel SAD alignment of
 * their bright-channel (G) samples: G sits at column parity (row & 1),
 * and for content displaced by D the SAD minimum over plane-sample
 * shifts k satisfies  D_b - D_a = (parb - para) - 2k  (sensor px) -
 * sign/baseline validated against synthetic ground truth. Chaining the
 * four boundary medians (with a closure check: they must sum to ~0)
 * gives the absolute staircase up to a harmless global shift.
 * Fills out[4] with even compensation offsets (CFA phase preserved);
 * returns 1 if measured (may be all zero = clean link), 0 if the
 * frame lacks texture or the measurement is inconsistent.
 */
#define SLIP_COLS 1150 /* plane samples per row (from sensor col 600) */
#define SLIP_MAX 16    /* max plane-sample shift = 32 sensor px */

static float slip_adjacent(const uint16_t *raw, int pitch16, int s,
			   int row)
{
	static float a[SLIP_COLS], b[SLIP_COLS];
	int para = row & 1, parb = (row + 1) & 1;
	const uint16_t *pa = raw + (size_t)row * pitch16;
	const uint16_t *pb = pa + pitch16;
	float ma = 0, mb = 0;

	for (int i = 0; i < SLIP_COLS; i++) {
		a[i] = (float)(pa[600 + para + 2 * i] >> s);
		b[i] = (float)(pb[600 + parb + 2 * i] >> s);
		ma += a[i];
		mb += b[i];
	}
	ma /= SLIP_COLS;
	mb /= SLIP_COLS;
	float va = 0, vb = 0;
	for (int i = 0; i < SLIP_COLS; i++) {
		a[i] -= ma;
		b[i] -= mb;
		va += a[i] * a[i];
		vb += b[i] * b[i];
	}
	if (va < 16.0f * SLIP_COLS || vb < 16.0f * SLIP_COLS)
		return 1e9f; /* featureless */

	float sad[2 * SLIP_MAX + 1];
	int besti = -1;
	float best = 1e30f;
	for (int k = -SLIP_MAX; k <= SLIP_MAX; k++) {
		float sum = 0;
		for (int i = SLIP_MAX; i < SLIP_COLS - SLIP_MAX; i++)
			sum += fabsf(a[i] - b[i - k]);
		sad[k + SLIP_MAX] = sum;
		if (sum < best) {
			best = sum;
			besti = k + SLIP_MAX;
		}
	}
	if (besti <= 0 || besti >= 2 * SLIP_MAX)
		return 1e9f;
	float den = sad[besti - 1] - 2 * sad[besti] + sad[besti + 1];
	float frac = (sad[besti - 1] - sad[besti + 1]) / (2 * den + 1e-9f);
	frac = fminf(fmaxf(frac, -1.0f), 1.0f);
	float k = (besti - SLIP_MAX) + frac;

	return (float)(parb - para) - 2.0f * k; /* = D_b - D_a, sensor px */
}

static int cmp_float(const void *a, const void *b)
{
	float d = *(const float *)a - *(const float *)b;
	return (d > 0) - (d < 0);
}

static int measure_rowslip(const uint16_t *raw, int pitch16, int s,
			   int out[4])
{
	float m[4];

	for (int g = 0; g < 4; g++)
		out[g] = 0;

	for (int ph = 0; ph < 4; ph++) {
		float v[96];
		int n = 0;
		for (int row = 200 + ph; row < 2000 && n < 96; row += 20) {
			float o = slip_adjacent(raw, pitch16, s, row);
			if (o < 1e8f)
				v[n++] = o;
		}
		if (n < 10)
			return 0; /* not enough texture */
		qsort(v, n, sizeof(float), cmp_float);
		m[ph] = v[n / 2];
		if (v[3 * n / 4] - v[n / 4] > 3.0f)
			return 0; /* inconsistent scene/motion */
	}
	if (fabsf(m[0] + m[1] + m[2] + m[3]) > 3.0f)
		return 0; /* chain doesn't close - don't trust it */

	float d[4] = { 0, m[0], m[0] + m[1], m[0] + m[1] + m[2] };
	float mean = 0.25f * (d[0] + d[1] + d[2] + d[3]);
	for (int ph = 0; ph < 4; ph++) {
		float c = d[ph] - mean;
		/* nearest even integer: CFA column phase must be kept */
		out[ph] = 2 * (int)floorf(0.5f * c + 0.5f);
	}
	return 1;
}

/*
 * The slip staircase is a property of the link/boot, not the scene, so
 * cache the last good measurement: a bridge started against a blank
 * wall compensates from the cache immediately and re-measures (and
 * refreshes the cache) as soon as the view has texture.
 */
static const char *rowslip_cache_path(void)
{
	static char path[512];
	const char *h = getenv("HOME");

	snprintf(path, sizeof(path), "%s/.imx415_rowslip", h ? h : "/tmp");
	return path;
}

static int rowslip_cache_load(int out[4])
{
	FILE *f = fopen(rowslip_cache_path(), "r");

	if (!f)
		return 0;
	int n = fscanf(f, "%d %d %d %d", &out[0], &out[1], &out[2], &out[3]);
	fclose(f);
	if (n != 4)
		return 0;
	for (int i = 0; i < 4; i++)
		if (out[i] % 2 || abs(out[i]) > 2 * SLIP_MAX)
			return 0;
	return 1;
}

static void rowslip_cache_store(const int rs[4])
{
	FILE *f = fopen(rowslip_cache_path(), "w");

	if (!f)
		return;
	fprintf(f, "%d %d %d %d\n", rs[0], rs[1], rs[2], rs[3]);
	fclose(f);
}

struct AeState {
	int enabled;
	float target;      /* linear mean target, 0..1 */
	int64_t exp_us;    /* current sensor state (we own it) */
	int64_t gain_mdb;
	int64_t exp_max_us;
	int settle;        /* frames until metering resumes */
};

/*
 * One damped AE step: exposure carries the correction until it hits
 * exp_max_us, gain takes the remainder. Log-domain damping (^0.6) plus a
 * +-10% deadband keeps it from hunting; the highlight guard steps down
 * when >2% of samples clip even if the mean is on target (a lamp in a
 * dark room should roll off, not drag the whole frame up).
 */
static void ae_update(struct AeState *ae, int fd, float mean01, float sat)
{
	if (mean01 <= 0.0f)
		return;

	float err = ae->target / mean01;
	err = fminf(fmaxf(err, 0.125f), 8.0f);
	if (sat > 0.02f && err > 0.7f)
		err = 0.7f;
	if (err > 0.90f && err < 1.10f)
		return;

	float factor = expf(0.6f * logf(err));
	double total = (double)ae->exp_us *
		       pow(10.0, ae->gain_mdb / 20000.0) * factor;

	int64_t e = (int64_t)(total + 0.5);
	if (e > ae->exp_max_us)
		e = ae->exp_max_us;
	if (e < AE_EXP_MIN_US)
		e = AE_EXP_MIN_US;
	int64_t g = (int64_t)(20000.0 * log10(total / e) /
				      AE_GAIN_STEP_MDB + 0.5) *
		    AE_GAIN_STEP_MDB;
	if (g < 0)
		g = 0;
	if (g > AE_GAIN_MAX_MDB)
		g = AE_GAIN_MAX_MDB;

	if (e == ae->exp_us && g == ae->gain_mdb)
		return;
	ae->exp_us = e;
	ae->gain_mdb = g;
	ae->settle = AE_SETTLE_FRAMES;
	set_i64_ctrl(fd, TEGRA_CID_EXPOSURE, e, "exposure");
	set_i64_ctrl(fd, TEGRA_CID_GAIN, g, "gain");
	printf("ae: mean %.3f sat %.1f%% -> exposure %lld us, gain %lld mdB\n",
	       mean01, 100.0 * sat, (long long)e, (long long)g);
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
	const char *loopback_path = NULL;
	int frames = 300, frames_given = 0;
	int snap_at = 30;
	int out_w = SENSOR_W / 2, out_h = SENSOR_H / 2; /* 1932x1096 */
	int crop1080 = 0, awb = 1, linear = 0, bits = 10;
	int use_alsc = 1, no_ccm = 0, wb_manual = 0;
	int64_t exposure_us = -1, gain_mdb = -1; /* <0 = keep cached value */
	int ae_on = 0;
	int dezigzag = 1;
	float ae_target = 0.10f; /* linear mean; ~0.35 after gamma 2.2 */
	int64_t ae_exp_max = 33000; /* stays within the 30 fps frame */
	float wb_r = 1.0f, wb_g = 1.0f, wb_b = 1.0f;
	float ct = 0.0f; /* 0 = auto from AWB; --ct forces */

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--device") && i + 1 < argc)
			dev = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
			frames = atoi(argv[++i]);
			frames_given = 1;
		} else if (!strcmp(argv[i], "--loopback") && i + 1 < argc)
			loopback_path = argv[++i];
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
		else if (!strcmp(argv[i], "--ae"))
			ae_on = 1;
		else if (!strcmp(argv[i], "--no-dezigzag"))
			dezigzag = 0;
		else if (!strcmp(argv[i], "--ae-target") && i + 1 < argc)
			ae_target = atof(argv[++i]);
		else if (!strcmp(argv[i], "--ae-max-exp") && i + 1 < argc)
			ae_exp_max = atoll(argv[++i]);
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
				"usage: %s [--device /dev/video0] [--frames N|0=forever]\n"
				"  [--loopback /dev/videoN]  (processed YUYV out)\n"
				"  [--snap out.ppm] [--snap-at N] [--bits 10|12]\n"
				"  [--exposure US] [--gain MDB] [--crop1080]\n"
				"  [--ae] [--ae-target F] [--ae-max-exp US]\n"
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
	if (ae_on) {
		/* AE owns the sensor state, so start from known values
		 * (--exposure/--gain, if given, seed the loop) */
		if (exposure_us < 0)
			exposure_us = 10000;
		if (gain_mdb < 0)
			gain_mdb = 0;
	}
	if (loopback_path && !frames_given)
		frames = 0; /* a bridge runs until Ctrl-C by default */

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

	/* Loopback output: the YUYV buffer is host-mapped pinned memory, so
	 * the conversion kernel writes CPU-visible bytes directly (Tegra
	 * iGPU shares DRAM) and write() needs no separate DtoH copy. */
	int lb_fd = -1, lb_warned = 0;
	uint8_t *h_yuyv = NULL, *d_yuyv = NULL;
	if (loopback_path) {
		lb_fd = loopback_open(loopback_path, out_w, out_h);
		CUDA_CHECK(cudaHostAlloc(&h_yuyv, (size_t)out_w * out_h * 2,
					 cudaHostAllocMapped));
		CUDA_CHECK(cudaHostGetDevicePointer((void **)&d_yuyv, h_yuyv,
						    0));
		printf("loopback: YUYV %dx%d -> %s%s\n", out_w, out_h,
		       loopback_path, frames <= 0 ? " (until Ctrl-C)" : "");
	}

	struct sigaction sa = {};
	sa.sa_handler = on_stop;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	dim3 blk(32, 8);
	dim3 grd((out_w + blk.x - 1) / blk.x, (out_h + blk.y - 1) / blk.y);
	dim3 cgrd((out_w / 2 + blk.x - 1) / blk.x,
		  (out_h + blk.y - 1) / blk.y);
	cudaEvent_t ev0, ev1;
	CUDA_CHECK(cudaEventCreate(&ev0));
	CUDA_CHECK(cudaEventCreate(&ev1));

	double t_start = 0;
	float kern_ms_sum = 0;
	double copy_s_sum = 0;
	int color_at = (frames <= 0 || frames > 8) ? 8 : frames - 1;
	int color_done = 0, awb_retries = 0;
	int stat_every = frames > 0 ? 100 : 900; /* every 30 s when infinite */
	int dezig_at = 5, dezig_done = !dezigzag, dezig_tries = 0;
	if (dezigzag) {
		int cached[4];
		if (rowslip_cache_load(cached)) {
			memcpy(p.rowshift, cached, sizeof(cached));
			printf("dezigzag: cached compensation %+d %+d %+d %+d "
			       "(re-measures from live scene)\n",
			       cached[0], cached[1], cached[2], cached[3]);
		}
	}

	struct AeState ae = {};
	ae.enabled = ae_on;
	ae.target = ae_target;
	ae.exp_us = exposure_us;
	ae.gain_mdb = gain_mdb;
	ae.exp_max_us = ae_exp_max;
	ae.settle = 6; /* skip the stream-start frames (no exposure yet) */
	if (ae.enabled)
		printf("ae: on, target %.3f, exposure %lld us / gain %lld mdB "
		       "start\n",
		       ae.target, (long long)ae.exp_us, (long long)ae.gain_mdb);

	int i = 0;
	for (; (frames <= 0 || i < frames) && !g_stop; i++) {
		struct v4l2_buffer b;
		int idx = cap_dqbuf(&cap, &b);
		if (idx < 0)
			break; /* interrupted */

		if (i == 0)
			t_start = now_s();

		/*
		 * Measure the 4-lane link row slip once, from a real frame
		 * (needs scene texture - retries a few times if too flat).
		 * Compensation applies to every frame from then on.
		 */
		if (!dezig_done && i >= dezig_at) {
			int rs4[4];
			if (measure_rowslip((const uint16_t *)cap.buf_start[idx],
					    pitch16, p.shift, rs4)) {
				memcpy(p.rowshift, rs4, sizeof(rs4));
				rowslip_cache_store(rs4);
				dezig_done = 1;
				if (rs4[0] | rs4[1] | rs4[2] | rs4[3])
					printf("dezigzag: link row slip "
					       "compensated: %+d %+d %+d %+d "
					       "sensor px (row&3)\n",
					       rs4[0], rs4[1], rs4[2], rs4[3]);
				else
					printf("dezigzag: link clean, no "
					       "compensation needed\n");
			} else {
				/* keep trying forever - texture may appear;
				 * cached/zero compensation carries meanwhile */
				if (++dezig_tries == 6)
					fprintf(stderr,
						"dezigzag: scene too flat to "
						"measure so far - %s; will "
						"keep retrying\n",
						(p.rowshift[0] | p.rowshift[1] |
						 p.rowshift[2] | p.rowshift[3])
							? "using cached values"
							: "uncompensated");
				dezig_at = i + (dezig_tries < 6 ? 15 : 60);
			}
		}

		if (ae.enabled) {
			if (ae.settle > 0) {
				ae.settle--;
			} else if (i % 2 == 0) { /* every other frame */
				float m, s;
				measure_luma((const uint16_t *)
						     cap.buf_start[idx],
					     pitch16, p.shift, p.black,
					     maxval, &m, &s);
				ae_update(&ae, cap.fd, m, s);
			}
		}

		/* AWB after a short warm-up: exposure/gain programmed at
		 * stream-on only take effect a few frames in */
		if (!color_done && i >= color_at) {
			/* AWB -> CT estimate -> CCM/ALSC selection, all
			 * from the calibrated tuning data */
			float ct_used = ct; /* >0 = forced via --ct */
			color_done = 1;
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
				} else if (ae.enabled && awb_retries++ < 5 &&
					   (frames <= 0 || i + 30 < frames)) {
					/* AE is still brightening the scene */
					color_at = i + 30;
					color_done = 0;
					fprintf(stderr,
						"awb: frame too dark, "
						"retrying at frame %d\n",
						color_at);
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
			if (color_done) {
				if (ct_used <= 0)
					ct_used = 4600.0f; /* nothing measured */
				if (!no_ccm)
					ccm_for_ct(ct_used, p.ccm);
				if (use_alsc) {
					float h_alsc[3 * ALSC_GRID * ALSC_GRID];
					alsc_build(ct_used, h_alsc);
					CUDA_CHECK(cudaMemcpy(
						d_alsc, h_alsc, sizeof(h_alsc),
						cudaMemcpyHostToDevice));
					p.alsc_r = d_alsc;
					p.alsc_b = d_alsc + ALSC_GRID * ALSC_GRID;
					p.alsc_l = d_alsc +
						   2 * ALSC_GRID * ALSC_GRID;
				}
				printf("color: CT %.0f K, CCM %s, ALSC %s\n",
				       ct_used, no_ccm ? "off" : "on",
				       use_alsc ? "on" : "off");
			}
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
		 * (the loopback writer below is one such consumer)
		 */

		if (lb_fd >= 0) {
			rgb_to_yuyv<<<cgrd, blk>>>(d_rgb, d_yuyv, out_w,
						   out_h);
			CUDA_CHECK(cudaDeviceSynchronize());
			ssize_t sz = (ssize_t)out_w * out_h * 2;
			if (write(lb_fd, h_yuyv, sz) != sz && !lb_warned) {
				perror("loopback write");
				lb_warned = 1;
			}
		}

		/* wait for the color pipeline too: with --ae in a dark scene,
		 * AWB/CCM can lock frames after snap_at (dark-retry) */
		if (snap_path && i >= snap_at && color_done) {
			CUDA_CHECK(cudaMemcpy(h_rgb, d_rgb,
					      (size_t)out_w * out_h * 3,
					      cudaMemcpyDeviceToHost));
			save_ppm(snap_path, h_rgb, out_w, out_h);
			snap_path = NULL; /* once */
		}

		if (xioctl(cap.fd, VIDIOC_QBUF, &b) < 0) {
			perror("VIDIOC_QBUF");
			exit(1);
		}

		if (i > 0 && i % stat_every == 0) {
			double el = now_s() - t_start;
			printf("frame %4d  avg %.2f fps  copy %.2f ms  "
			       "kernel %.3f ms\n",
			       i, i / el, 1e3 * copy_s_sum / i,
			       kern_ms_sum / i);
		}
	}

	if (i > 1) {
		double el = now_s() - t_start;
		printf("done: %d frames in %.2f s = %.2f fps "
		       "(copy %.2f ms, kernel %.3f ms per frame)\n",
		       i, el, (i - 1) / el, 1e3 * copy_s_sum / i,
		       kern_ms_sum / i);
	}

	if (zero_copy)
		for (int j = 0; j < NUM_BUFFERS; j++)
			cudaHostUnregister(cap.buf_start[j]);
	cap_close(&cap);
	if (lb_fd >= 0)
		close(lb_fd);
	if (h_yuyv)
		cudaFreeHost(h_yuyv);
	if (d_raw)
		cudaFree(d_raw);
	if (d_alsc)
		cudaFree(d_alsc);
	cudaFree(d_rgb);
	free(h_rgb);
	return 0;
}
