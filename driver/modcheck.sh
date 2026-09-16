#!/usr/bin/env bash
# Root-free ground truth for a freshly built nv_imx415.ko: the module must
# agree with the running kernel and with the prebuilt tegra-camera.ko on
# every imported symbol's modversion CRC. The CRC covers the full type
# expansion of each prototype, so a wrong conftest.h (e.g. the pmc field of
# struct camera_common_data) shows up here as a CRC mismatch instead of as
# memory corruption after modprobe.
#
# The L4T 6.8 kernel writes the "extended" __versions record format
# (u32 record length, u32 crc, NUL-padded name), which kmod 31's
# `modprobe --dump-modversions` rejects - hence the small parser below.
#
# Usage: ./modcheck.sh [nv_imx415.ko]
set -u
KO="${1:-nv_imx415.ko}"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
NV_OOT="${NV_OOT:-/usr/src/nvidia/nvidia-public}"
TC="/lib/modules/$(uname -r)/updates/drivers/media/platform/tegra/camera/tegra-camera.ko"

[ -f "$KO" ] || { echo "no $KO - build first" >&2; exit 1; }

echo "== $KO =="
modinfo "$KO" | grep -E '^(vermagic|depends|alias):'
want=$(modinfo -F vermagic "$TC" 2>/dev/null || true)
have=$(modinfo -F vermagic "$KO")
if [ -n "$want" ] && [ "$want" != "$have" ]; then
	echo "FAIL: vermagic differs from tegra-camera.ko ($want)"; exit 1
fi
echo "vermagic matches tegra-camera.ko"

dump_versions() { # <module.ko> -> "crc name" lines (classic or extended records)
	local raw; raw=$(mktemp)
	objcopy -O binary --only-section=__versions "$1" "$raw" || { rm -f "$raw"; return 1; }
	python3 - "$raw" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
if not data:
    sys.exit("empty __versions section")
first = struct.unpack_from('<I', data, 0)[0]
# extended record: u32 length (small, 4-aligned) + u32 crc + NUL-padded name;
# classic record: u32 crc + 4 pad + name in a fixed 64-byte slot
ext = 8 < first < 256 and first % 4 == 0 and data[8:9] != b'\0'
i = 0
while i + 8 <= len(data):
    if ext:
        n, crc = struct.unpack_from('<II', data, i)
        if n == 0 or (i + n > len(data) and not data[i:].strip(b'\0')):
            break  # section padding
        if n < 9 or i + n > len(data):
            sys.exit(f"corrupt extended record at {i}")
        name = data[i + 8:i + n].split(b'\0')[0].decode()
        i += n
    else:
        crc = struct.unpack_from('<I', data, i)[0]
        name = data[i + 8:i + 64].split(b'\0')[0].decode()
        i += 64
    if name:
        print(f'0x{crc:08x} {name}')
PY
	rm -f "$raw"
}

echo "== modversion CRCs (imports vs kernel + nvidia-public Module.symvers) =="
bad=0; n=0
while read -r crc sym; do
	n=$((n+1))
	ref=$(awk -v s="$sym" '$2==s {print $1; exit}' "$NV_OOT/Module.symvers" "$KDIR/Module.symvers")
	if [ -z "$ref" ]; then
		echo "  MISSING  $sym (no exporter in either Module.symvers)"; bad=1
	elif [ "$ref" != "$crc" ]; then
		echo "  MISMATCH $sym: module $crc, exporter $ref"; bad=1
	fi
done < <(dump_versions "$KO")
if [ "$n" = 0 ]; then
	echo "FAIL: could not read any modversion record from $KO"; exit 1
fi
if [ "$bad" = 0 ]; then
	echo "all $n imported symbols match (CRC-exact), incl. the tegra-camera ones"
	echo "PASS"
else
	echo "FAIL: fix conftest.h / headers before installing"; exit 1
fi
