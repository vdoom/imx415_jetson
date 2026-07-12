#!/usr/bin/env bash
# On-target Argus/ISP validation for the IMX415 (run ON THE TARGET).
# Needs the Argus-enabled dtbo (deploy/ sha1 53381cb5, 2026-07-12) live:
# the script verifies use_decibel_gain + the lens node in /proc/device-tree
# first - if missing you booted an older overlay (stale-deploy trap).
#
#   ./argus_check.sh            # enumerate + 30 s fps run, mode0 (10-bit)
#   ./argus_check.sh fps 1      # same for mode1 (12-bit)
#   ./argus_check.sh snap       # JPEG through the ISP -> /tmp/argus_snap.jpg
#   ./argus_check.sh view       # 1932x1096 YUY2 -> /dev/video10 (ustreamer)
#   sudo ./argus_check.sh debug # foreground daemon with PCL/SCF logs
#
# Argus owns exposure/gain/wb (ISP AE/AWB) - do not fight it with v4l2-ctl
# while a pipeline runs. Gain is linear in Argus (1..31.6x = 0..30 dB);
# the DT's use_decibel_gain makes the camera core convert - v4l2-ctl gain
# stays dB*1000 as before.
set -u
MODE="${1:-fps}"
SENSOR_MODE="${2:-0}"
W=3864; H=2192

dt_check() {
	local miss=0
	[ -e /proc/device-tree/bus@0/cam_i2cmux/i2c@1/rbpcv415_c@37/use_decibel_gain ] \
		|| { echo "!! use_decibel_gain missing from live DT"; miss=1; }
	[ -d /proc/device-tree/bus@0/lens_imx415@IMX41598 ] \
		|| { echo "!! lens_imx415 node missing from live DT"; miss=1; }
	if [ $miss = 1 ]; then
		echo "!! live DT predates the Argus dtbo (sha1 53381cb5)."
		echo "!! Install the FRESH deploy dir, reboot the imx415 entry, retry."
		exit 1
	fi
	echo "== live DT has the Argus properties =="
}

daemon_fresh() {
	sudo systemctl restart nvargus-daemon 2>/dev/null \
		|| echo "(could not restart nvargus-daemon - sudo? continuing)"
	sleep 2
}

post_mortem() {
	echo "== pipeline failed - last daemon log lines =="
	journalctl -u nvargus-daemon -n 40 --no-pager 2>/dev/null | tail -40
	echo "== for the full story: sudo ./argus_check.sh debug  (then rerun) =="
	exit 1
}

case "$MODE" in
fps)
	dt_check
	daemon_fresh
	echo "== 300 frames, sensor-mode $SENSOR_MODE, native ${W}x${H} through the ISP =="
	gst-launch-1.0 -v nvarguscamerasrc sensor-id=0 sensor-mode="$SENSOR_MODE" num-buffers=300 \
		! "video/x-raw(memory:NVMM),width=$W,height=$H,framerate=30/1,format=NV12" \
		! fpsdisplaysink text-overlay=false video-sink=fakesink sync=false \
		2>&1 | grep -oE "average: [0-9.]+" | tail -5 || post_mortem
	echo "== expect average: ~30 (29.9x) on the last lines =="
	;;
snap)
	dt_check
	daemon_fresh
	echo "== 90 frames for AE/AWB settle, keeping the last JPEGs =="
	rm -f /tmp/argus_snap_*.jpg
	gst-launch-1.0 nvarguscamerasrc sensor-id=0 sensor-mode="$SENSOR_MODE" num-buffers=90 \
		! "video/x-raw(memory:NVMM),width=$W,height=$H,framerate=30/1,format=NV12" \
		! nvjpegenc \
		! multifilesink location=/tmp/argus_snap_%05d.jpg max-files=3 \
		>/dev/null 2>&1 || post_mortem
	LAST=$(ls -1 /tmp/argus_snap_*.jpg 2>/dev/null | tail -1)
	[ -n "$LAST" ] || post_mortem
	cp "$LAST" /tmp/argus_snap.jpg
	echo "== /tmp/argus_snap.jpg written (AE/AWB-settled ISP output) =="
	echo "== inspect edges: the 4-lane row slip is NOT compensated here =="
	;;
view)
	dt_check
	daemon_fresh
	if [ ! -e /dev/video10 ]; then
		echo "== loading v4l2loopback (video10) =="
		sudo modprobe v4l2loopback video_nr=10 exclusive_caps=1 || exit 1
	fi
	echo "== ISP -> /dev/video10; view with: ustreamer -d /dev/video10 (browser :8080) =="
	echo "== Ctrl-C stops it =="
	gst-launch-1.0 nvarguscamerasrc sensor-id=0 sensor-mode="$SENSOR_MODE" \
		! "video/x-raw(memory:NVMM),width=$W,height=$H,framerate=30/1,format=NV12" \
		! nvvidconv ! "video/x-raw,width=1932,height=1096,format=YUY2" \
		! v4l2sink device=/dev/video10 || post_mortem
	;;
debug)
	echo "== foreground nvargus-daemon with PCL+SCF logs (Ctrl-C to stop; =="
	echo "== afterwards: sudo systemctl restart nvargus-daemon) =="
	systemctl stop nvargus-daemon 2>/dev/null
	pkill -f nvargus-daemon 2>/dev/null
	sleep 1
	export enableCamPclLogs=1 enableCamScfLogs=1
	/usr/sbin/nvargus-daemon 2>&1 | tee /tmp/argus_debug.log
	;;
*)
	echo "usage: $0 [fps|snap|view|debug] [sensor-mode 0|1]"; exit 2
	;;
esac
