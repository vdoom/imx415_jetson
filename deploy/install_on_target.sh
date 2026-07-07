#!/usr/bin/env bash
# Phase F installer for the IMX415 camera port (Jetson Orin Nano, JP 6.2.2).
# Run ON THE TARGET, from this directory:
#   sudo ./install_on_target.sh
#
# Installs nv_imx415.ko + the DT overlay and adds an 'imx415' boot entry
# cloned from the existing 'UARTFix' entry (imx219-dual overlay removed,
# disable-uart1-dma kept). Does NOT change the DEFAULT entry.
set -euo pipefail
cd "$(dirname "$0")"

KVER_EXPECTED="5.15.185-tegra"
EXTLINUX=/boot/extlinux/extlinux.conf
DTBO=tegra234-p3767-camera-p3768-imx415.dtbo
KO=nv_imx415.ko
MODDIR="/lib/modules/$(uname -r)/updates/drivers/media/i2c"

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: run with sudo" >&2
	exit 1
fi
if [ "$(uname -r)" != "$KVER_EXPECTED" ]; then
	echo "ERROR: running kernel $(uname -r) != $KVER_EXPECTED." >&2
	echo "The module was built for $KVER_EXPECTED - rebuild on the host first." >&2
	exit 1
fi
sha1sum -c checksums.sha1

echo "==> 1/4 backing up $EXTLINUX"
cp -v "$EXTLINUX" "$EXTLINUX.bak-imx415-$(date +%Y%m%d%H%M%S)"

echo "==> 2/4 installing kernel module to $MODDIR"
install -v -D -m 0644 "$KO" "$MODDIR/$KO"
depmod -a

echo "==> 3/4 installing overlay to /boot"
install -v -m 0644 "$DTBO" "/boot/$DTBO"

echo "==> 4/4 adding 'imx415' boot entry"
if grep -qE '^LABEL[[:space:]]+imx415[[:space:]]*$' "$EXTLINUX"; then
	echo "LABEL imx415 already present - leaving $EXTLINUX unchanged"
else
	TMP=$(mktemp)
	awk -v dtbo="/boot/$DTBO" '
		/^LABEL[[:space:]]/ { inblk = ($2 == "UARTFix") }
		inblk { block = block $0 "\n" }
		END {
			if (block == "") exit 2
			n = split(block, lines, "\n")
			out = ""
			for (i = 1; i <= n; i++) {
				line = lines[i]
				if (line ~ /^LABEL[[:space:]]/)
					line = "LABEL imx415"
				else if (line ~ /MENU LABEL/)
					line = "      MENU LABEL UARTFix + IMX415 camera overlay"
				else if (line ~ /^[[:space:]]*OVERLAYS[[:space:]]/) {
					sub(/^[[:space:]]*OVERLAYS[[:space:]]*/, "", line)
					m = split(line, ovl, ",")
					line = "      OVERLAYS "
					first = 1
					for (j = 1; j <= m; j++) {
						if (ovl[j] == "" || ovl[j] ~ /imx219/)
							continue
						line = line (first ? "" : ",") ovl[j]
						first = 0
					}
					line = line (first ? "" : ",") dtbo
				}
				if (line != "")
					out = out line "\n"
			}
			printf "\n%s", out
		}
	' "$EXTLINUX" > "$TMP" || { echo "ERROR: no UARTFix entry found in $EXTLINUX - add the entry manually (see README.md)" >&2; rm -f "$TMP"; exit 1; }

	if ! grep -q "$DTBO" "$TMP"; then
		# UARTFix had no OVERLAYS line at all
		printf '      OVERLAYS /boot/%s\n' "$DTBO" >> "$TMP"
	fi

	cat "$TMP" >> "$EXTLINUX"
	rm -f "$TMP"
	echo "--- new entry appended: ---"
	sed -n '/^LABEL imx415/,$p' "$EXTLINUX"
fi

echo
echo "Done. Next steps (guide phase F/G):"
echo "  1. sudo reboot - pick 'imx415' in the boot menu on the serial console"
echo "     (or set 'DEFAULT imx415' in $EXTLINUX once validated)."
echo "  2. sudo modprobe nv_imx415"
echo "  3. dmesg | grep -iE 'imx415|tegracam' ; ls /dev/video*"
echo "  4. After successful validation, enable autoload:"
echo "     echo nv_imx415 | sudo tee /etc/modules-load.d/imx415.conf"
