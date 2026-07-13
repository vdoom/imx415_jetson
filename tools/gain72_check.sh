#!/usr/bin/env bash
# 72 dB gain ground-truth check (2026-07-13 update: ko 5cea9ce1 + dtbo
# 1c0a9101). Run ON THE TARGET with sudo, AFTER install + reboot:
#   sudo bash gain72_check.sh
#
# Steps gain across the old 30 dB ceiling and reads GAIN_PCG_0 (0x3090)
# over I2C mid-stream. reg = dB/0.3, little-endian 16-bit:
#   gain=15000 (15 dB)  -> 0x32 0x00   (old validated point, sanity)
#   gain=30000 (30 dB)  -> 0x64 0x00   (old ceiling)
#   gain=45000 (45 dB)  -> 0x96 0x00   (DIGITAL territory - the new part)
#   gain=72000 (72 dB)  -> 0xf0 0x00   (new max)
#   gain=90000          -> v4l2 REJECTS it (ctrl max is 72000)
# OLD-MODULE SYMPTOM: 45000/72000 read back 0x64 0x00 (clamped at 100).
# Brightness (fixed 1 ms exposure) must rise with every step.
set -u

KO=/lib/modules/$(uname -r)/updates/drivers/media/i2c/nv_imx415.ko
echo "== installed module file (expect 5cea9ce19fd3cc51f286cd4ef65eea42532d874b) =="
sha1sum "$KO" 2>/dev/null || echo "MISSING: $KO"
echo "== live DT gain range (expect max 72000) =="
tr -d '\0' < /proc/device-tree/bus@0/cam_i2cmux/i2c@1/rbpcv415_c@37/mode0/max_gain_val; echo
echo

cap() { # gain_mdb outfile
	v4l2-ctl -d /dev/video0 --set-ctrl sensor_mode=0 \
		--set-fmt-video=width=3864,height=2192,pixelformat=GB10 \
		--set-ctrl bypass_mode=0,exposure=1000,gain="$1" \
		--stream-mmap --stream-count=90 --stream-skip=80 \
		--stream-to="$2" >/dev/null 2>&1 &
	local pid=$!
	sleep 2
	echo "-- gain=$1 -> GAIN_PCG_0: $(i2ctransfer -f -y 9 w2@0x37 0x30 0x90 r2)"
	wait "$pid"
}

cap 15000 /tmp/g15.raw
cap 30000 /tmp/g30.raw
cap 45000 /tmp/g45.raw
cap 72000 /tmp/g72.raw

echo
echo "-- gain=90000 (beyond max - v4l2 must refuse):"
v4l2-ctl -d /dev/video0 --set-ctrl gain=90000 2>&1 | head -2 \
	|| echo "   (rejected, as expected)"

echo
echo "== mean brightness at 1 ms exposure - must be strictly increasing =="
python3 - <<'EOF'
import numpy as np
prev = -1; ok = True
for f in ('/tmp/g15.raw', '/tmp/g30.raw', '/tmp/g45.raw', '/tmp/g72.raw'):
    d = np.fromfile(f, np.uint16) >> 6
    if d.size == 0:
        print(f, ' EMPTY (capture produced no valid frames)'); ok = False; continue
    m = float(d.mean())
    print(f, ' mean', round(m, 1), ' sat%', round(float((d >= 1020).mean()*100), 1))
    ok &= m > prev; prev = m
print('BRIGHTNESS MONOTONIC:', 'PASS' if ok else 'FAIL',
      '(saturated scene? point somewhere darker and rerun)')
EOF
echo
echo "Argus side: ./argus_check.sh - the enumeration line must now say"
echo "  'Analog Gain range min 1.000000, max 3981.xxx' (was 31.62)"
