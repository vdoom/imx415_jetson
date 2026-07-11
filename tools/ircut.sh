#!/usr/bin/env bash
# IR-CUT day/night control — Waveshare IMX415-98 on P3768 CAM1 (run on target).
#
# The module's H-bridge direction input arrives over the FFC: module pin 5
# "IR-CUT" = CAM1 connector pin 18 = pad extperiph2_clk_pp1 = main GPIO PP.01
# (gpiochip0 line 113). The camera overlay (fragment@1) muxes the pad to
# RSVD1/GPIO at boot, so:
#   - line released -> pad hi-Z -> the module's physical switch selects mode
#   - line driven   -> software overrides the switch
# Levels are held by a background gpioset daemon (libgpiod v1); "auto" kills
# it, returning control to the physical switch.
#
# LEVEL_DAY below = the level that puts the filter IN (day/color mode).
# Verify once with an IR remote (day = remote's LED invisible on stream)
# and flip to 0 if your unit is inverted.

set -eu

LEVEL_DAY=1
LINE_NAME="PP.01"
FALLBACK="gpiochip0 113"   # if gpiofind can't resolve the name

usage() { echo "usage: sudo $0 day|night|auto|status" >&2; exit 1; }
[ $# -eq 1 ] || usage

CHIP_LINE=$(gpiofind "$LINE_NAME" 2>/dev/null || echo "$FALLBACK")
MATCH="gpioset .*${CHIP_LINE#* }="

holder_pids() { pgrep -f "$MATCH" || true; }

release() {
	local pids; pids=$(holder_pids)
	[ -n "$pids" ] && kill $pids 2>/dev/null || true
}

hold() {
	release
	gpioset --mode=signal --background $CHIP_LINE=$1
}

case "$1" in
	day)    hold "$LEVEL_DAY" ;;
	night)  hold "$((1 - LEVEL_DAY))" ;;
	auto)   release ;;
	status)
		pids=$(holder_pids)
		if [ -n "$pids" ]; then
			echo "held by gpioset pid(s): $pids"
			ps -o args= -p $pids
		else
			echo "released (physical switch in control)"
		fi
		;;
	*) usage ;;
esac
