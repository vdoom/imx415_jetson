#!/usr/bin/env bash
# Root-cause diagnostic for the 4-lane link row slip (alternating ~16 px
# horizontal displacement of 2-row blocks; shows as green/purple edge
# fringes + softness). Measures the slip amplitude from raw captures at
# the stock HMAX=1100, then pokes larger HMAX values mid-stream (more
# line-timing margin, temporarily lower fps) to see if the slip vanishes.
#
# Run ON THE TARGET with sudo, camera pointed at a detailed scene:
#   sudo bash zigzag_check.sh
# Stop any stream (bridge/viewer) first.
set -u
DEV=/dev/video0

measure() { python3 - "$1" << 'EOF'
import sys, numpy as np
raw = np.fromfile(sys.argv[1], np.uint16, count=16939776//2)
if raw.size < 16939776//2:
    print('  capture too short'); sys.exit(0)
p = (raw.reshape(2192, 3864) >> 6).astype(np.float32)
G1 = p[0::2, 0::2]
sh = []
for y in range(100, 1000, 9):
    a = G1[y, 300:1500] - G1[y, 300:1500].mean()
    b = G1[y+1, 300:1500] - G1[y+1, 300:1500].mean()
    if a.std() < 4 or b.std() < 4: continue
    c = np.correlate(a, b, 'same')
    s = int(np.argmax(c)) - len(a)//2
    if abs(s) <= 16: sh.append(abs(s))
if len(sh) < 15:
    print(f'  not enough texture ({len(sh)} pairs) - point at a detailed scene')
else:
    print(f'  zigzag amplitude: {np.median(sh)*2:.0f} sensor px  ({len(sh)} row pairs; 0 = clean)')
EOF
}

echo "== baseline (HMAX=1100, 30 fps) =="
v4l2-ctl -d $DEV --set-ctrl sensor_mode=0 \
  --set-fmt-video=width=3864,height=2192,pixelformat=GB10 \
  --set-ctrl bypass_mode=0,exposure=20000,gain=10000 \
  --stream-mmap --stream-count=8 --stream-skip=7 --stream-to=/tmp/zz.raw >/dev/null 2>&1
measure /tmp/zz.raw

for HM in 1150 1200 1400; do
	LO=$(printf '0x%02x' $((HM & 0xff)))
	HI=$(printf '0x%02x' $((HM >> 8)))
	echo "== HMAX=$HM (mid-stream poke; fps drops while testing) =="
	# stream-on rewrites the mode table, so poke DURING the stream:
	# frames 110..120 are written well after the poke at ~1.5 s
	v4l2-ctl -d $DEV --set-ctrl bypass_mode=0 \
	  --stream-mmap --stream-count=120 --stream-skip=110 \
	  --stream-to=/tmp/zz.raw >/dev/null 2>&1 &
	PID=$!
	sleep 1.5
	i2ctransfer -f -y 9 w2@0x37 0x30 0x01 0x01           # REGHOLD
	i2ctransfer -f -y 9 w4@0x37 0x30 0x28 $LO $HI        # HMAX LE
	i2ctransfer -f -y 9 w2@0x37 0x30 0x01 0x00
	wait $PID
	measure /tmp/zz.raw
done
echo "(every stream start restores HMAX=1100 - nothing persists)"
