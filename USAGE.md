# Running the IMX415 on the Orin Nano — both pipelines (2026-07-13)

Two independent, fully-installed ways to consume the camera. **Only one may
drive the sensor at a time** (the VI capture channel is single-owner) —
switch by stopping one and starting the other; no reboot, no config change.

| | **Argus/ISP path** | **CUDA debayer path** |
|---|---|---|
| Engine | NVIDIA hw ISP via nvargus daemon | our GPU kernels on raw `/dev/video0` |
| Color | ISP + `tuning/camera_overrides.isp` (v3: pedestal + saturation s=1.4) | RPi-calibrated CCM/ALSC/AWB + own AE |
| Row slip | **clean** (no compensation needed) | compensated in-kernel (dezigzag) |
| Exposure | Argus AE (max 30 dB / 33 ms) | `--ae` loop (same sensor limits) |
| Output | NVMM/YUV into GStreamer/Argus apps | RGB8 on GPU (`d_rgb` integration point) |
| Best for | encoding, RTSP, DeepStream, "just a camera" | custom CUDA/ML consumers, full control |
| Docs | `argus_isp.md`, `tuning/README.md` | `tools/cuda_debayer/README.md` |

## Run the Argus/ISP path

```bash
./argus_check.sh            # health check: 300 frames, ~30.0 fps expected
./argus_check.sh snap       # AE/AWB-settled JPEG -> /tmp/argus_snap.jpg
./argus_check.sh view       # ISP -> /dev/video10 loopback (browser/webcam apps)
./argus_check.sh fps 1      # 12-bit mode1 (pass sensor-mode as 2nd arg)
```

Or any GStreamer pipeline directly (always pass `sensor-mode` — the two
modes share one resolution and differ only in bit depth):

```bash
gst-launch-1.0 nvarguscamerasrc sensor-id=0 sensor-mode=0 \
  ! 'video/x-raw(memory:NVMM),width=3864,height=2192,framerate=30/1,format=NV12' \
  ! nvvidconv ! ...   # nvv4l2h265enc / nvjpegenc / appsink / ...
```

Runtime look knobs on `nvarguscamerasrc`: `saturation=` (0–2; stacks ON TOP
of the tuning file's s=1.4 — don't double up), `exposurecompensation=`
(−2..2), `ee-mode=`/`ee-strength=` (edge enhancement), `tnr-mode=` (noise).
Persistent look lives in `/var/nvidia/nvcam/settings/camera_overrides.isp`
(canonical copy + the single `s` knob: `tuning/`; installer deploys it).

## Run the CUDA debayer path

```bash
cd tools/cuda_debayer   # (on the target; build once with `make`)
./imx415_debayer --ae --frames 300                 # live run, AE + auto color
./imx415_debayer --ae --snap out.ppm               # corrected snapshot
./imx415_debayer --ae --loopback /dev/video10      # webcam bridge daemon
./imx415_debayer --bits 12 --ae --frames 300       # 12-bit mode1
```

Full flag reference (AE targets, manual WB/CT, `--linear` for ML, crop,
dezigzag): `tools/cuda_debayer/README.md`.

## Switching between them

```bash
# whichever is running: Ctrl-C (or pkill -f imx415_debayer / pkill -f gst-launch)
# then start the other. Two gotchas:
sudo systemctl restart nvargus-daemon   # only if Argus wedges after a killed client
v4l2-ctl -d /dev/video0 -c sensor_mode=0  # only before MANUAL v4l2-ctl captures -
                                          # the ctrl latches across processes; our
                                          # tools already pin it themselves
```

## Watching in a browser / webcam apps (either path)

Both paths can feed the same `/dev/video10` loopback (one producer at a
time); every consumer downstream is identical.

One-time setup:

```bash
sudo apt install v4l2loopback-dkms ustreamer
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback video_nr=10 card_label="IMX415" exclusive_caps=1' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
sudo modprobe v4l2loopback video_nr=10 card_label="IMX415" exclusive_caps=1
```

Then:

```bash
# pick ONE producer:
./argus_check.sh view                              # ISP look
./imx415_debayer --ae --loopback /dev/video10      # CUDA look

# consume from anything:
ustreamer -d /dev/video10 -s 0.0.0.0 -p 8080       # browser: http://<jetson>:8080/stream
guvcview -d /dev/video10                           # desktop app (reliable)
cheese                                             # start AFTER the producer; known flaky
ffplay /dev/video10 · vlc v4l2:///dev/video10 · OpenCV VideoCapture(10)
```

With `exclusive_caps=1` the loopback is a camera **only while a producer
feeds it** — start the producer first, launch the viewer app fresh after.

## IR-CUT (shared by both paths)

```bash
./tools/ircut.sh day|night|auto    # day = filter in (validated: PP.01 high)
```
