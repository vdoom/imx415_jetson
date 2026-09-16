#!/usr/bin/env bash
# Generate and install the IMX415 NITO tuning file on JetPack 7 (R39).
#
# Prerequisite: deploy/install_camera_hotfix.sh done (patched libnvscf +
# /usr/sbin/nvcfg2nito) and the daemon running in CONFIG mode (the drop-in
# deploy/nvargus-daemon-legacy-isp.conf). In that mode every Argus capture
# makes the daemon dump the mode's binary cfg to /root/binary_<n>.cfg and
# auto-convert it into /root/<badge>.nito (knobset n = sensor mode n).
#
#   ./nito_migrate.sh capture         # no root: one Argus capture per sensor
#                                     # mode (0 = 10-bit, 1 = 12-bit)
#   sudo ./nito_migrate.sh install    # copy /root/<badge>.nito into
#                                     # /var/nvidia/nvcam/settings, switch the
#                                     # daemon to native NITO mode, restart
#   sudo ./nito_migrate.sh revert     # back to CONFIG mode (overrides file)
set -u
cd "$(dirname "$0")"
BADGE=jakku_rear_IMX415          # tegra-camera-platform module1 badge (dt/)
NITO_DIR=/var/nvidia/nvcam/settings
DROPIN=/etc/systemd/system/nvargus-daemon.service.d/10-legacy-isp-config.conf
W=3864; H=2192

capture_mode() { # <sensor-mode>
	echo "== Argus capture, sensor mode $1 (dumps + converts knobset $1) =="
	gst-launch-1.0 -q nvarguscamerasrc sensor-id=0 sensor-mode="$1" num-buffers=30 \
		! "video/x-raw(memory:NVMM),width=$W,height=$H,framerate=30/1,format=NV12" \
		! fakesink >/dev/null 2>&1 \
		|| { echo "!! capture failed - is the daemon in CONFIG mode with the hotfix? journalctl -u nvargus-daemon"; return 1; }
	sleep 1
	journalctl -u nvargus-daemon --no-pager --since "1 min ago" 2>/dev/null \
		| grep -E "Auto-converted NITO|Binary Cfg file|nvcfg2nito failed|Updated parameters written" | tail -4
}

case "${1:-}" in
capture)
	if ! systemctl show nvargus-daemon -p Environment | grep -q NVCAMERA_NITO_PATH=CONFIG; then
		echo "!! daemon is not in CONFIG mode (drop-in missing?) - run sudo deploy/install_on_target.sh first"; exit 1
	fi
	[ -x /usr/sbin/nvcfg2nito ] || { echo "!! /usr/sbin/nvcfg2nito missing - run sudo deploy/install_camera_hotfix.sh"; exit 1; }
	capture_mode 0 && capture_mode 1
	echo
	echo "== expected result: /root/$BADGE.nito with knobsets 0 and 1 (root-only, check with sudo ls -la /root/*.nito) =="
	echo "Next: sudo $0 install"
	;;
install)
	[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
	SRC=/root/$BADGE.nito
	[ -f "$SRC" ] || { echo "!! $SRC not found - run '$0 capture' first (ls /root/*.nito: $(ls /root/*.nito 2>/dev/null))"; exit 1; }
	install -v -m 0644 -o root -g root "$SRC" "$NITO_DIR/$BADGE.nito"
	cp -v "$SRC" "../deploy/$BADGE.nito" 2>/dev/null && chown "$(stat -c %U:%G ../deploy)" "../deploy/$BADGE.nito" \
		&& echo "(copy kept in deploy/ for future installs)"
	install -v -m 0644 ../deploy/nvargus-daemon-nito.conf "$DROPIN"
	systemctl daemon-reload && systemctl restart nvargus-daemon
	echo "== native NITO mode. Verify: ./argus_check.sh, then:"
	echo "   journalctl -u nvargus-daemon --no-pager | grep -E 'nito file .* found|Found override file' | tail -2"
	;;
revert)
	[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
	install -v -m 0644 ../deploy/nvargus-daemon-legacy-isp.conf "$DROPIN"
	systemctl daemon-reload && systemctl restart nvargus-daemon
	echo "== back to CONFIG mode (legacy config + camera_overrides.isp)"
	;;
*)
	sed -n 2,16p "$0"; exit 2 ;;
esac
