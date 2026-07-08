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
#define TEGRA_CID_SENSOR_MODE_ID 0x009a2008

/*
 * Color correction matrices from the Raspberry Pi calibrated tuning file
 * for this sensor (libcamera src/ipa/rpi/pisp/data/imx415.json, rpi.ccm).
 * Applied to white-balanced linear RGB; interpolated by color temperature.
 */
struct CcmEntry {
	float ct;
	float m[9];
};
static const CcmEntry ccm_table[] = {
	{ 2698, { 1.572f, -0.328f, -0.245f, -0.613f, 1.705f, -0.092f,
		  -0.434f, 0.481f, 0.953f } },
	{ 2930, { 1.696f, -0.530f, -0.166f, -0.671f, 1.785f, -0.113f,
		  -0.418f, 0.546f, 0.872f } },
	{ 3643, { 1.726f, -0.724f, -0.002f, -0.459f, 1.405f, 0.054f,
		  -0.145f, -0.798f, 1.943f } },
	{ 4605, { 1.499f, -0.419f, -0.080f, -0.392f, 1.695f, -0.302f,
		  0.016f, -0.885f, 1.870f } },
	{ 5658, { 1.388f, -0.232f, -0.156f, -0.375f, 1.703f, -0.328f,
		  -0.013f, -0.720f, 1.734f } },
};
#define CCM_TABLE_LEN (sizeof(ccm_table) / sizeof(ccm_table[0]))

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
};

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

static void cap_open(Capture *c, const char *dev, uint32_t pixfmt,
		     int sensor_mode)
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

	/* Select the DT modeN (0 = 10-bit, 1 = 12-bit) before S_FMT. */
	ctrl.id = TEGRA_CID_SENSOR_MODE_ID;
	ctrl.value = sensor_mode;
	if (xioctl(c->fd, VIDIOC_S_CTRL, &ctrl) < 0)
		fprintf(stderr, "warning: sensor_mode not set (%s)\n",
			strerror(errno));

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

/* Gray-world white balance gains from one raw frame (CPU, subsampled). */
static void gray_world(const uint16_t *raw, int pitch16, int shift, float black,
		       float *wr, float *wg, float *wb)
{
	double sr = 0, sg = 0, sb = 0;
	long n = 0;
	for (int y = 0; y < SENSOR_H - 1; y += 16) {
		const uint16_t *r0 = raw + (size_t)y * pitch16;
		const uint16_t *r1 = r0 + pitch16;
		for (int x = 0; x < SENSOR_W - 1; x += 16) {
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
	if (n && sr > n && sb > n) { /* require some real signal */
		*wr = (float)(sg / sr);
		*wb = (float)(sg / sb);
		*wg = 1.0f;
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
	int crop1080 = 0, awb = 0, linear = 0, bits = 10;
	float wb_r = 1.0f, wb_g = 1.0f, wb_b = 1.0f;
	float ct = 4600.0f; /* default: daylight-ish CCM; 0 = identity */

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
		else if (!strcmp(argv[i], "--crop1080"))
			crop1080 = 1;
		else if (!strcmp(argv[i], "--awb"))
			awb = 1;
		else if (!strcmp(argv[i], "--linear"))
			linear = 1;
		else if (!strcmp(argv[i], "--wb") && i + 3 < argc) {
			wb_r = atof(argv[++i]);
			wb_g = atof(argv[++i]);
			wb_b = atof(argv[++i]);
		} else if (!strcmp(argv[i], "--ct") && i + 1 < argc)
			ct = atof(argv[++i]);
		else if (!strcmp(argv[i], "--no-ccm"))
			ct = 0.0f;
		else {
			fprintf(stderr,
				"usage: %s [--device /dev/video0] [--frames N]\n"
				"  [--snap out.ppm] [--snap-at N] [--bits 10|12]\n"
				"  [--crop1080] [--awb] [--wb R G B] [--ct kelvin]\n"
				"  [--no-ccm] [--linear]\n",
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
	ccm_for_ct(ct, p.ccm);
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
	cap_open(&cap, dev, pixfmt, sensor_mode);
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
	if (!zero_copy)
		CUDA_CHECK(cudaMalloc(&d_raw, cap.sizeimage));
	CUDA_CHECK(cudaMalloc(&d_rgb, (size_t)out_w * out_h * 3));
	h_rgb = (uint8_t *)malloc((size_t)out_w * out_h * 3);

	dim3 blk(32, 8);
	dim3 grd((out_w + blk.x - 1) / blk.x, (out_h + blk.y - 1) / blk.y);
	cudaEvent_t ev0, ev1;
	CUDA_CHECK(cudaEventCreate(&ev0));
	CUDA_CHECK(cudaEventCreate(&ev1));

	double t_start = 0;
	float kern_ms_sum = 0;
	double copy_s_sum = 0;

	for (int i = 0; i < frames; i++) {
		struct v4l2_buffer b;
		int idx = cap_dqbuf(&cap, &b);

		if (i == 0) {
			if (awb) {
				gray_world((const uint16_t *)cap.buf_start[idx],
					   pitch16, p.shift, p.black, &p.wb_r,
					   &p.wb_g, &p.wb_b);
				printf("awb gains: R %.3f G %.3f B %.3f\n",
				       p.wb_r, p.wb_g, p.wb_b);
			}
			t_start = now_s();
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
	cudaFree(d_rgb);
	free(h_rgb);
	return 0;
}
