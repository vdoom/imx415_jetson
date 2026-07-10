#!/usr/bin/env bash
# IMX415 exposure/gain ground-truth check. Run ON THE TARGET with sudo:
#   sudo bash expo_gain_check.sh
#
# Captures dark -> bright -> dark (detects stale/one-behind application)
# and reads the sensor registers over I2C mid-stream each time.
#
# Expected when the driver override fix works:
#   exposure=1000  gain=0     -> GAIN 0x00 0x00, SHR0 0x87 0x08 0x00 (2183)
#   exposure=33000 gain=15000 -> GAIN 0x32 0x00, SHR0 0x17 0x00 0x00 (23)
#   VMAX always 0xca 0x08 0x00 (2250)
# Mode defaults (= overrides NOT applied): GAIN 0x00 0x00, SHR0 0x08 0x00 0x00.
# Mean brightness must track the settings: bright >> dark, a1 ~= a2.
set -u

# NB the loaded module binary cannot be fingerprinted on this kernel (no
# CONFIG_MODULE_SRCVERSION_ALL) - reload (rmmod+modprobe) or reboot after
# installing so the file below is what is actually running.
KO=/lib/modules/$(uname -r)/updates/drivers/media/i2c/nv_imx415.ko
echo "== installed module file =="
sha1sum "$KO" 2>/dev/null || echo "MISSING: $KO"
echo

cap() { # exposure_us gain_mdb outfile
	v4l2-ctl -d /dev/video0 --set-ctrl sensor_mode=0 \
		--set-fmt-video=width=3864,height=2192,pixelformat=GB10 \
		--set-ctrl bypass_mode=0,exposure="$1",gain="$2" \
		--stream-mmap --stream-count=90 --stream-skip=80 \
		--stream-to="$3" >/dev/null 2>&1 &
	local pid=$!
	sleep 2
	echo "-- exposure=$1 gain=$2 -> $3"
	echo "   GAIN_PCG_0: $(i2ctransfer -f -y 9 w2@0x37 0x30 0x90 r2)"
	echo "   SHR0      : $(i2ctransfer -f -y 9 w2@0x37 0x30 0x50 r3)"
	echo "   VMAX      : $(i2ctransfer -f -y 9 w2@0x37 0x30 0x24 r3)"
	wait "$pid"
}

cap 1000  0     /tmp/a1.raw
cap 33000 15000 /tmp/b1.raw
cap 1000  0     /tmp/a2.raw

echo
python3 - <<'EOF'
import numpy as np
for f in ('/tmp/a1.raw', '/tmp/b1.raw', '/tmp/a2.raw'):
    d = np.fromfile(f, np.uint16) >> 6
    if d.size == 0:
        print(f, ' EMPTY (capture produced no valid frames)')
        continue
    print(f, ' mean', round(float(d.mean()), 1),
          ' sat%', round(float((d >= 1020).mean() * 100), 1))
EOF
