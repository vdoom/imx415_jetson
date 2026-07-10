#!/usr/bin/env python3
"""Live viewer for the IMX415 raw V4L2 pipeline on Jetson.

Reads raw GB10 frames from /dev/video0 via v4l2-ctl, debayers with OpenCV,
applies a mild auto-stretch (black-level subtract + percentile normalize +
gamma), and serves MJPEG over HTTP.

Usage (on the Jetson):
    python3 view_stream.py [--port 8080] [--exposure US] [--gain MDB] [--window]
Then open  http://<jetson-ip>:8080/  in a browser.
--window shows a local X11 window instead of serving HTTP (needs a display).

Requires: python3-numpy, python3-opencv (sudo apt install -y python3-opencv)
"""
import argparse
import subprocess
import numpy as np
import cv2
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

W, H = 3864, 2192
FRAME_BYTES = W * H * 2
BLACK_8BIT = 12.5  # sensor black level 50 on the 10-bit scale


def v4l2_cmd(args):
    ctrls = f"bypass_mode=0,exposure={args.exposure},gain={args.gain}"
    # Pin sensor_mode=0 (10-bit) BEFORE the format: the mode control latches
    # across processes, so a prior 12-bit run would otherwise leave the sensor
    # emitting RAW12 while we ask VI for GB10 -> every frame discarded.
    return ["v4l2-ctl", "-d", args.device,
            "--set-ctrl", "sensor_mode=0",
            f"--set-fmt-video=width={W},height={H},pixelformat=GB10",
            "--set-ctrl", ctrls,
            "--stream-mmap", "--stream-to=-"]


def frames(args):
    """Yield processed BGR preview frames forever."""
    proc = subprocess.Popen(v4l2_cmd(args), stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, bufsize=FRAME_BYTES)
    wb_gains = None  # EMA-smoothed gray-world gains (B, G, R)
    try:
        while True:
            buf = proc.stdout.read(FRAME_BYTES)
            if len(buf) < FRAME_BYTES:
                break
            raw = np.frombuffer(buf, dtype=np.uint16).reshape(H, W)
            # VI stores 10-bit MSB-aligned in 16-bit -> top 8 bits are the pixel
            bay8 = (raw >> 8).astype(np.uint8)
            # V4L2 GBRG == OpenCV BayerGR (OpenCV names by row1 cols 1,2)
            bgr = cv2.cvtColor(bay8, cv2.COLOR_BayerGR2BGR)
            bgr = cv2.resize(bgr, (W // args.scale, H // args.scale),
                             interpolation=cv2.INTER_AREA)
            f = np.clip(bgr.astype(np.float32) - BLACK_8BIT, 0.0, None)
            # gray-world white balance (raw Bayer is green-heavy by design);
            # EMA-smoothed across frames so the preview doesn't flicker
            means = f.reshape(-1, 3).mean(axis=0) + 1e-3
            gains = np.clip(means[1] / means, 0.25, 4.0)
            wb_gains = gains if wb_gains is None \
                else 0.9 * wb_gains + 0.1 * gains
            f *= wb_gains
            f *= 255.0 / max(float(np.percentile(f, 99.0)), 1.0)
            f = np.clip(f, 0.0, 255.0) / 255.0
            yield (255.0 * np.power(f, 1.0 / 2.2)).astype(np.uint8)
    finally:
        proc.kill()


def serve(args):
    class MJPEGHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            try:
                for img in frames(args):
                    ok, jpg = cv2.imencode(".jpg", img,
                                           [cv2.IMWRITE_JPEG_QUALITY, 80])
                    if not ok:
                        continue
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n")
                    self.wfile.write(jpg.tobytes())
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *a):
            pass

    print(f"Serving MJPEG on http://0.0.0.0:{args.port}/  (Ctrl-C to stop)")
    ThreadingHTTPServer(("0.0.0.0", args.port), MJPEGHandler).serve_forever()


def window(args):
    for img in frames(args):
        cv2.imshow("IMX415", img)
        if cv2.waitKey(1) & 0xFF in (27, ord("q")):
            break
    cv2.destroyAllWindows()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--scale", type=int, default=4,
                    help="preview downscale factor (default 4 -> 966x548)")
    ap.add_argument("--exposure", type=int, default=33000,
                    help="exposure in us (119..66430)")
    ap.add_argument("--gain", type=int, default=6000,
                    help="gain in milli-dB (0..30000, step 300)")
    ap.add_argument("--window", action="store_true",
                    help="local X11 window instead of HTTP server")
    args = ap.parse_args()
    window(args) if args.window else serve(args)
