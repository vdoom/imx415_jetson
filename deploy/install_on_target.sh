#!/usr/bin/env bash
# Installer for the IMX415 camera port - JetPack 7.2 / L4T R39 (kernel
# 6.8.12-tegra) on the P3768 carrier (Jetson Orin Nano / Orin NX devkits).
# Run ON THE TARGET, from this directory:
#   sudo ./install_on_target.sh
#
# Installs nv_imx415.ko + the DT overlay + the Argus ISP tuning and adds an
# 'imx415' boot entry cloned from the current DEFAULT entry (normally
# 'JetsonIO' on JetPack 7, 'primary' as fallback): the stock camera
# overlays (imx219/imx477) are dropped from OVERLAYS, ours is added, and an
# FDT line is added if the source entry had none. Does NOT change the
# DEFAULT entry - the old entries stay bootable.
set -euo pipefail
cd "$(dirname "$0")"

KVER_EXPECTED="6.8.12-1021-tegra"
EXTLINUX=/boot/extlinux/extlinux.conf
DTBO=tegra234-p3767-camera-p3768-imx415.dtbo
KO=nv_imx415.ko
ISP=camera_overrides.isp
NVCAM=/var/nvidia/nvcam/settings
MODDIR="/lib/modules/$(uname -r)/updates/drivers/media/i2c"

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: run with sudo" >&2
	exit 1
fi
if [ "$(uname -r)" != "$KVER_EXPECTED" ]; then
	echo "ERROR: running kernel $(uname -r) != $KVER_EXPECTED." >&2
	echo "The module was built for $KVER_EXPECTED - rebuild first (driver/Makefile: make check)." >&2
	exit 1
fi
sha1sum -c checksums.sha1

echo "==> 1/5 backing up $EXTLINUX"
cp -v "$EXTLINUX" "$EXTLINUX.bak-imx415-$(date +%Y%m%d%H%M%S)"

echo "==> 2/5 installing kernel module to $MODDIR"
install -v -D -m 0644 "$KO" "$MODDIR/$KO"
depmod -a

echo "==> 3/5 installing overlay to /boot"
install -v -m 0644 "$DTBO" "/boot/$DTBO"

echo "==> 4/5 adding 'imx415' boot entry"
if grep -qE '^LABEL[[:space:]]+imx415[[:space:]]*$' "$EXTLINUX"; then
	echo "LABEL imx415 already present - leaving $EXTLINUX unchanged"
else
	# clone the DEFAULT entry (JetsonIO on a stock JetPack 7 devkit), else primary
	DEFAULT_LABEL=$(awk '/^DEFAULT[[:space:]]/ {print $2; exit}' "$EXTLINUX")
	SRC=""
	for cand in "$DEFAULT_LABEL" JetsonIO primary; do
		[ -n "$cand" ] || continue
		if grep -qE "^LABEL[[:space:]]+$cand[[:space:]]*$" "$EXTLINUX"; then
			SRC=$cand; break
		fi
	done
	[ -n "$SRC" ] || { echo "ERROR: no LABEL to clone in $EXTLINUX - add the entry manually (see README.md)" >&2; exit 1; }
	# base DTB for an FDT line, only needed if the cloned entry has none
	BASE_DTB=$(ls /boot/dtb/kernel_tegra234-p3768-0000+p3767-*.dtb 2>/dev/null | head -1 || true)
	echo "cloning entry '$SRC'"

	TMP=$(mktemp)
	awk -v src="$SRC" -v dtbo="/boot/$DTBO" -v basedtb="$BASE_DTB" '
		/^LABEL[[:space:]]/ { inblk = ($2 == src) }
		# keep only the entry itself: no comments, no blank lines
		inblk && !/^[[:space:]]*(#|$)/ { block = block $0 "\n" }
		END {
			if (block == "") exit 2
			n = split(block, lines, "\n")
			# indentation of the entry body (first indented line)
			indent = "      "
			for (i = 1; i <= n; i++)
				if (lines[i] ~ /^[[:space:]]+[A-Z]/) {
					indent = lines[i]; sub(/[A-Z].*/, "", indent); break
				}
			out = ""; has_fdt = 0; has_ovl = 0
			for (i = 1; i <= n; i++) {
				line = lines[i]
				if (line ~ /^LABEL[[:space:]]/)
					line = "LABEL imx415"
				else if (line ~ /^[[:space:]]*MENU LABEL/)
					line = indent "MENU LABEL IMX415 camera overlay (cloned from " src ")"
				else if (line ~ /^[[:space:]]*FDT[[:space:]]/)
					has_fdt = 1
				else if (line ~ /^[[:space:]]*OVERLAYS[[:space:]]/) {
					has_ovl = 1
					sub(/^[[:space:]]*OVERLAYS[[:space:]]*/, "", line)
					m = split(line, ovl, ",")
					line = indent "OVERLAYS "
					first = 1
					for (j = 1; j <= m; j++) {
						# drop the stock CSI camera overlays: they claim the same
						# i2c mux / CSI port / VI channel as ours
						if (ovl[j] == "" || ovl[j] ~ /camera-p3768|imx219|imx477/)
							continue
						line = line (first ? "" : ",") ovl[j]
						first = 0
					}
					line = line (first ? "" : ",") dtbo
				}
				if (line != "")
					out = out line "\n"
			}
			if (!has_fdt && basedtb != "")
				out = out indent "FDT " basedtb "\n"
			if (!has_ovl)
				out = out indent "OVERLAYS " dtbo "\n"
			printf "\n%s", out
		}
	' "$EXTLINUX" > "$TMP" || { echo "ERROR: could not extract entry '$SRC' from $EXTLINUX" >&2; rm -f "$TMP"; exit 1; }

	if ! grep -q "$DTBO" "$TMP" || ! grep -qE '^[[:space:]]*FDT[[:space:]]' "$TMP"; then
		echo "ERROR: generated entry lacks FDT or OVERLAYS - add it manually (see README.md):" >&2
		cat "$TMP" >&2; rm -f "$TMP"; exit 1
	fi

	cat "$TMP" >> "$EXTLINUX"
	rm -f "$TMP"
	echo "--- new entry appended: ---"
	sed -n '/^LABEL imx415/,$p' "$EXTLINUX"
fi

echo "==> 5/5 installing ISP tuning override to $NVCAM"
if [ -f "$ISP" ]; then
	mkdir -p "$NVCAM"
	# don't silently clobber someone else's tuning (e.g. an IMX219 fix)
	if [ -f "$NVCAM/$ISP" ] && ! cmp -s "$ISP" "$NVCAM/$ISP"; then
		cp -v "$NVCAM/$ISP" "$NVCAM/$ISP.bak-$(date +%Y%m%d%H%M%S)"
	fi
	install -v -m 0664 "$ISP" "$NVCAM/$ISP"
	systemctl restart nvargus-daemon 2>/dev/null \
		&& echo "nvargus-daemon restarted" \
		|| echo "(nvargus-daemon not running - tuning applies on next start)"
else
	echo "(no $ISP in this deploy dir - skipping)"
fi

echo
echo "Done. Next steps:"
echo "  1. sudo reboot - pick 'imx415' in the boot menu on the serial console"
echo "     (or set 'DEFAULT imx415' in $EXTLINUX once validated)."
echo "  2. dmesg | grep -iE 'imx415|tegracam' ; ls /dev/video*   (module autoloads"
echo "     from the DT compatible; 'sudo modprobe nv_imx415' if it did not)"
echo "  3. tools/expo_gain_check.sh, tools/argus_check.sh, tools/gain72_check.sh"
echo "  4. Optional autoload insurance:"
echo "     echo nv_imx415 | sudo tee /etc/modules-load.d/imx415.conf"
