#!/usr/bin/env bash
# Install NVIDIA's JetPack 7.2.1 "camera hotfix" on the target (run with sudo).
#
# Why: L4T R39 makes a binary NITO tuning file mandatory for Argus and the
# stock daemon refuses the legacy text-config mode (NVCAMERA_NITO_PATH=CONFIG)
# outright. NVIDIA's public "Jetson Customer IQ Migration Tools" package
# (JetPack 7.2.1 download archive) ships a hotfix whose patched libnvscf.so
# accepts CONFIG mode again AND auto-converts the dumped binary cfg to a
# <badge>.nito on the device with /usr/sbin/nvcfg2nito - i.e. it both makes
# Argus work now (legacy config + camera_overrides.isp) and produces the
# native NITO for later (tools/nito_migrate.sh).
#
# The package is NVIDIA-proprietary (Tegra Software License), so it is not
# stored in this repo: it is downloaded from NVIDIA's CDN and verified by
# sha256, or taken from HOTFIX_ZIP=<local path>.
#
#   sudo ./install_camera_hotfix.sh            # download + install
#   sudo HOTFIX_ZIP=~/x.zip ./install_camera_hotfix.sh
#   sudo ./install_camera_hotfix.sh --restore  # put the original files back
set -euo pipefail
cd "$(dirname "$0")"

URL="https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.1/jetson_customer_iq_migration_tools_r39.2.1_jp_7.2.1_ga.zip"
SHA256="15976d2e1cdd78d042436c50d743233e101a647b1515ec04517398c5a5b2118c"
L4T_EXPECTED="R39 (release), REVISION: 2.1"
STATE=/var/lib/imx415-camera-hotfix          # backups + manifest for --restore
DROPIN_SRC=nvargus-daemon-legacy-isp.conf
DROPIN=/etc/systemd/system/nvargus-daemon.service.d/10-legacy-isp-config.conf

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo" >&2; exit 1; }

restore() {
	[ -f "$STATE/manifest" ] || { echo "nothing to restore ($STATE/manifest missing)"; exit 0; }
	while IFS=$'\t' read -r kind dest backup; do
		case "$kind" in
			replaced) cp -pv "$backup" "$dest" ;;
			added)    rm -fv "$dest" ;;
		esac
	done < "$STATE/manifest"
	ldconfig
	rm -rf "$STATE"
	systemctl restart nvargus-daemon 2>/dev/null || true
	echo "restored - stock camera libraries back in place"
	exit 0
}
[ "${1:-}" = "--restore" ] && restore

head -1 /etc/nv_tegra_release | grep -qF "$L4T_EXPECTED" \
	|| { echo "ERROR: this hotfix is for L4T $L4T_EXPECTED, target has: $(head -1 /etc/nv_tegra_release)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="${HOTFIX_ZIP:-}"
if [ -z "$ZIP" ]; then
	ZIP="$WORK/iq_tools.zip"
	echo "==> downloading NVIDIA's IQ migration tools package"
	curl -fL --progress-bar -o "$ZIP" "$URL"
fi
echo "$SHA256  $ZIP" | sha256sum -c - || { echo "ERROR: package checksum mismatch - refusing to install" >&2; exit 1; }

echo "==> extracting camera_hotfix.tbz2"
unzip -q -o "$ZIP" -d "$WORK/zip"
TBZ=$(find "$WORK/zip" -name camera_hotfix.tbz2 | head -1)
[ -n "$TBZ" ] || { echo "ERROR: camera_hotfix.tbz2 not in package" >&2; exit 1; }
mkdir -p "$WORK/fs" && tar xjf "$TBZ" -C "$WORK/fs"

echo "==> installing (backups + manifest in $STATE)"
mkdir -p "$STATE/backup"
: > "$STATE/manifest.new"
while IFS= read -r -d '' f; do
	rel=${f#"$WORK/fs"}
	dest="/$rel"
	mode=0644; case "$dest" in /usr/sbin/*) mode=0755;; esac
	if [ -f "$dest" ]; then
		if cmp -s "$f" "$dest"; then
			# keep an earlier manifest entry for this path if one exists
			grep -P "\t$dest\t" "$STATE/manifest" 2>/dev/null >> "$STATE/manifest.new" || true
			continue
		fi
		if ! grep -qP "\t$dest\t" "$STATE/manifest" 2>/dev/null; then
			b="$STATE/backup/$(echo "$dest" | tr / _)"
			cp -p "$dest" "$b"
			printf 'replaced\t%s\t%s\n' "$dest" "$b" >> "$STATE/manifest.new"
		else
			grep -P "\t$dest\t" "$STATE/manifest" >> "$STATE/manifest.new"
		fi
	else
		printf 'added\t%s\t-\n' "$dest" >> "$STATE/manifest.new"
	fi
	install -D -m "$mode" -o root -g root "$f" "$dest"
	echo "  $dest"
done < <(find "$WORK/fs" -type f -print0)
mv "$STATE/manifest.new" "$STATE/manifest"
ldconfig

if [ -f "$DROPIN_SRC" ]; then
	echo "==> nvargus-daemon drop-in (CONFIG mode + HOME) -> $DROPIN"
	install -D -m 0644 "$DROPIN_SRC" "$DROPIN"
	systemctl daemon-reload
fi
systemctl restart nvargus-daemon && echo "nvargus-daemon restarted"

echo
echo "Done. /usr/sbin/nvcfg2nito: $(/usr/sbin/nvcfg2nito 2>&1 | head -1)"
echo "Next: tools/argus_check.sh should stream now (legacy config + overrides)."
echo "      Then tools/nito_migrate.sh capture  -> generates the IMX415 NITO"
echo "           sudo tools/nito_migrate.sh install -> switch to native NITO mode"
