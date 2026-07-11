# Phase G — validation on target (2026-07-07, evening)

Target: Jetson Orin Nano devkit, boot entry `imx415` (now DEFAULT — no serial
console attached), module autoloads at boot via OF alias (no modules-load.d
needed).

## Ladder status (guide §8.1)

| Rung | Result |
|---|---|
| 1. I2C/probe | ✅ `imx415 9-0037: tegracam sensor driver:imx415_v2.0.6`; chip-ID check passed; unsigned-module taint warning is expected and harmless |
| 2. media graph | ✅ `imx415 9-0037 → nvcsi → vi-output`, fmt `SGBRG10_1X10/3864x2192@1/15` |
| 3. formats | ✅ fourcc **GB10**, 3864×2192 @15 fps (passport §10 row closed) |
| 4. controls | ✅ gain 0–30000/300, exposure 119–66431, frame_rate ≤15 fps — DT contract intact |
| 5. capture | ✅ 30/30 frames, delta locked 66.665 ms = **15.00 fps**, zero jitter, no errors (after the embedded_metadata_height fix below) |
| 6. frame content | ✅ real scene, geometry clean (uniform row means top/bottom, no OB band), GBRG planes sane |
| 7. stability | ✅ full 10-min soak (9000 frames) completed: flat 15.00 fps on every readout, no degradation, dmesg free of camera errors |
| controls change image | ✅ measured: exposure 2→40 ms gave 17× signal above black (theory ≤20×); gain 0→15 dB gave 5.4× (theory 5.62×) — SHR0 and GAIN_PCG_0 math confirmed end-to-end |

## Debug story: every frame discarded (fixed)

First capture: frames at exactly 15 fps, full bytesused, but VI discarded all —
`corr_err: discarding frame 0, flags: 0, err_data 16384` per frame.

- err_data is **deprecated** on T234 (camrtc-capture.h) and not filled by any
  kernel code (RCE firmware internal); 16384 = 1<<14 ≈ FALCON_ERROR class =
  CHANSEL fault family. Don't try to decode it numerically.
- RTCPU ftrace (`events/tegra_rtcpu`) emits **0 events** on this target/L4T —
  the §8.2 recipe is a dead end here; `/sys/kernel/debug/camrtc` doesn't exist.
- v4l2-ctl does **not** write errored buffers to `--stream-to` (cap.raw was 0 B).
- Root cause found by comparing with the **working FRAMOS IMX715 overlay** for
  the same devkit/port/lanes (`reference/fr_imx715-cam1-2lane-overlay-l4t-r36.4.4.dts`):
  every mode there has `embedded_metadata_height = "1"` — the sensor family
  transmits 1 embedded-data line per frame. RP1 (RPi) tolerates it silently;
  Tegra VI raises CHANSEL_EMBED_INFRINGE and discards the frame.
- Fix: `embedded_metadata_height = "1"` in mode0 (commit 300230b). One reboot
  later: perfect capture.

## VI RAW10 memory format — measured, definitive (closes Додаток A "shift")

VI writes 10-bit samples into 16-bit little-endian words **MSB-aligned with
LSB replication**: `raw16 = (p << 6) | (p >> 4)`. Verified on a full frame:
100.00% of pixels match this encoding exactly.

- To get 10-bit values: `p = raw16 >> 6` (**shift = 6**, same as RPi's CFE).
- Stride: **no padding** on Jetson — 7728 B/row = 3864×2 exactly (RPi pads to
  7744; slice `[:, :3864]` there).
- Full-range max = 65472+15 = 65487 (1023<<6 | 1023>>4).

First frame stats (dim indoor evening scene): 10-bit min 0 / max 183 /
mean 68.5 vs black level 50; GBRG plane means G 69.6 / B 62.8 / R 71.8 —
R slightly above G is consistent with tungsten light and/or IR-CUT open.
Comparison render vs RPi reference: both scenes coherent, no artifacts.

## Frame analysis snippets (workstation)

```python
a = np.fromfile("jetson_frame0.raw", dtype=np.uint16, count=3864*2192).reshape(2192, 3864)
p = a >> 6   # 10-bit
```
Full renderer: scratchpad `render_frame.py` pattern — luminance = 2×2 quad mean;
quick color: G=(0,0)+(1,1), B=(0,1), R=(1,0), subtract black 50, gray-world WB.

## Guide §10 final checklist (Phase 1)

- [x] Frames captured without errors in dmesg (30 saved + ~1000 streamed clean)
- [x] Frame reacts to gain/exposure controls (quantitatively correct)
- [x] 10-min stream — 9000 frames, flat 15.00 fps, clean dmesg (2026-07-07 ~21:00)
- [x] Image comparable to RPi reference (coherent scene, sane GBRG levels, shift 6)
- [x] Reproducible from clean reboot: DEFAULT=imx415 entry + module autoload via
      OF alias — the successful capture after reboot proves the whole chain

**Phase 1 goal met: raw V4L2 Bayer pipeline at 3864×2192@15fps GBRG works.**

## 4-lane / 30 fps upgrade — VALIDATED (2026-07-08)

Switched mode0 to 4 lanes @ 891 Mbps/lane (LANEMODE=3, HMAX=1100, commit
3820183). On target:

- Transport-only stream (`--stream-mmap`, no file): **flat 30.00 fps**, 300/300
  frames, dmesg clean. 4-lane link on CAM1 + Waveshare FPC is solid — the
  RPi5 "purple stripes" (RP1 receiver saturation) do not reproduce on Orin.
- Frame content clean: GBRG plane means G 101 / B 66 / R 99 / G2 101, uniform
  rows, full 0..1023 range in a lit scene.
- ⚠️ Writing to disk at 30 fps (508 MB/s via `--stream-to`) starves the default
  4-buffer queue on page-cache writeback (repeating 66.6 ms deltas + one 2.3 s
  stall). Use `--stream-mmap=16` for disk recording, or don't put the disk in
  the loop (GPU consumers are unaffected).
- Exposure range at 30 fps: 59–33200 µs (max = full frame time); lower fps via
  `-c frame_rate=...` extends it dynamically (driver stretches VMAX).
- Fallback to the validated 2-lane/15fps state: git tag `phase1-2lane-15fps`
  or `deploy/2lane-15fps-backup/` (two files + reboot).

## IR-CUT investigation — RESOLVED as a Jetson-side drive limitation (2026-07-10)

Measured with an IR remote into the lens (90-frame captures, counting
saturated pixels):

| Condition | px>900 (90 frames) | Verdict |
|---|---|---|
| Jetson, switch pos 1 | 412,982 | IR passes — filter OUT |
| Jetson, switch pos 2 | 414,528 | IR passes — filter OUT |

**On the Jetson the filter is always in night/IR mode; the physical switch has
no effect.** Controlled swap test (same module, same switch position): on RPi5
one power-up click puts it in the switch-selected mode and the switch toggles
day/night live; back on Jetson, one power-up click always lands on night.

Dead ends ruled out by experiment (2026-07-10):
- No light sensor on the board (inspected).
- The `GP0` pad next to +3V3/GND is NOT a working IR-CUT control on Jetson:
  it reads ~0 V always (0.00/0.05 V depending on switch position, i.e. weakly
  coupled to the switch network), stays 0 V during streaming (so it is NOT the
  XCLR net), and neither edges nor held 3.3 V on it (through stream restarts
  AND a full reboot) change anything.
- The physical switch NEVER clicks/acts on Jetson — streaming or idle — while
  on RPi5 it toggles day/night live with a click.

**Root-cause level measurement (the breakthrough):** the coil behind the 2-pin
connector (red/black wires) is driven by an H-bridge with a **continuously
held ±3.2 V**, and polarity alone selects the mode — measured on the RPi5:
**day (IR-CUT) = −3.17 V, night (IR) = +3.16 V** (same probe orientation).
Whatever direction-input the bridge honors on the Pi is stuck at "night" on
Jetson (likely related to how each platform drives the connector control
line, but with a working coil-level fix the board logic no longer matters).

**Consequences:** on Jetson the camera is a good IR/night camera; daytime
color is IR-polluted and no AWB/CCM can correct it (the calibrated CCMs
assume IR-blocked light).

**Fix (chosen): drive the coil directly, bypassing the board logic.**
- Tier 1 (no parts): unplug the 2-pin coil connector from the camera board and
  feed the coil from the Jetson 40-pin header (3.3 V = pin 1, GND = pin 6) at
  the day polarity. The coil is designed for continuous energization (the
  Pi's own board holds ±3.2 V on it permanently). Wrong polarity is harmless —
  it just selects night; verify with the IR-remote test and swap if needed.
- Tier 2 (software day/night): dual H-bridge breakout (DRV8833/L9110S) between
  two 40-pin GPIOs and the coil → `gpioset`-controlled polarity.

## IR-CUT control line found on the FFC — spec PDF pinout (2026-07-11, VALIDATED)

`reference/IMX415-98-IR-CUT-Camera-Specification.pdf` (Waveshare drawing)
lists the module's 22-pin FFC pinout, and it includes **pin 5 = IR-CUT** and
**pin 6 = GPIO-H** — the bridge control comes over the ribbon, no wire mod
needed. The module numbering is the mirror of the host connector numbering
(module pin n ↔ host pin 23−n; verified across all 22 pins: 3V3/SDA/SCL,
clock pair MCP/MCN ↔ host 9/8, all four data pairs including P/N polarity).
On the P3768 CAM1 connector this lands as:

| Module pin (PDF) | P3768 CAM1 pin | Tegra net | State today |
|---|---|---|---|
| 6 GPIO-H | 17 CAM1_PWDN | PAC.00 | our DT `reset-gpios`, high while streaming |
| 5 IR-CUT | 18 CAM1_MCLK | `extperiph2_clk_pp1` = **PP.01** | pinmux = extperiph2, clock gated → **pad actively drives 0 V, always** |

This explains every 2026-07-10 observation at once:
- filter stuck at night on Jetson: IR-CUT line is force-driven low by the
  gated MCLK output (tristate disabled in the p3767 pinmux BCT);
- the switch clicks on RPi5 but never on Jetson: the Pi drives its CAM_GPIO
  connector line, Tegra never does;
- holding external 3.3 V on the GP0 pad did nothing: GP0 is (weakly coupled
  to) this net, and the Tegra push-pull pad was fighting it low the whole
  time — the injection never actually raised the net.

**Test (target, no reboot, reversible).** First restore the coil to the
module's 2-pin connector (undo the Tier-1 header feed), then:

```bash
# 1. detach the pad from the gated clock: mux extperiph2_clk_pp1 to a RSVD
#    function (= GPIO mode on t234; any of rsvd1/2/3 works)
sudo sh -c 'echo "extperiph2_clk_pp1 rsvd1" > /sys/kernel/debug/pinctrl/2430000.pinmux/pinmux-select'
# 2. drive it — PP.01 = main-gpio line 113 (14*8+1); --mode=wait keeps the
#    line claimed until Enter
gpioinfo | grep -n "PP.01"                  # confirm chip/line, unclaimed
sudo gpioset --mode=wait $(gpiofind PP.01)=1   # listen for the click
sudo gpioset --mode=wait $(gpiofind PP.01)=0   # and back
```

Do this while streaming (GPIO-H/PAC.00 is only held high by the driver then)
and try both physical switch positions; confirm with the IR-remote test.
Record which level = day (filter IN) — that closes the last Phase A passport
row (`rpi5_imx415_data.md` §6). Re-probe GP0 while toggling: if it follows
PP.01 it is this net, giving a scope point.

**VALIDATED on target 2026-07-11 (user):** the pinmux-select command alone
re-enabled the physical switch (pad hi-Z once detached from the gated clock
→ the module's own switch network regains the line), and `gpioset` on PP.01
switches modes from software. Exactly as predicted.

**Persistence (done on host 2026-07-11):** the debugfs poke does NOT survive
reboot, so the pinmux is now baked into the camera overlay as `fragment@1`
(`dt/tegra234-p3767-camera-p3768-imx415.dts`): `extperiph2_clk_pp1` →
`rsvd1`, pull none, tristate disable, input disable, applied as a pinctrl
hog at pinmux probe. **No gpio-hog on purpose** — unclaimed the pad is hi-Z
so the physical switch works; software overrides by claiming PP.01.
Rebuilt dtbo in `deploy/` (sha1 `5a6fa834`, ko unchanged `19169df3`);
install = copy dtbo over `/boot/tegra234-p3767-camera-p3768-imx415.dtbo`
+ reboot (extlinux entry already points at it; use a FRESH dated scp dir —
see stale-deploy trap). Runtime helper: `tools/ircut.sh day|night|auto|
status` (background gpioset holds the level; `auto` releases to the
switch).

**DEPLOYED & VALIDATED on target 2026-07-11 (user: "works fine")** — dtbo
installed, pinmux hog applies at boot, physical switch and `ircut.sh`
day/night both work with no manual pinmux poke. IR-CUT is DONE on Jetson.
**Polarity confirmed: day (filter IN) = PP.01 HIGH, night (IR) = LOW**
(`LEVEL_DAY=1` as shipped) — recorded in `passport.md` and
`rpi5_imx415_data.md` §6/§7; last open Phase A row closed.

## Sensor controls silently ignored without override_enable=1 — measured (2026-07-10)

Symptom while validating day-mode color: exposure sweep 59→33000 µs and gain
0→30000 mdB produced **bit-identical noise floors** — yet every `v4l2-ctl -c`
returned success. Direct I2C readback (bus 9, addr 0x37, `i2ctransfer -f`)
while streaming showed GAIN_PCG_0=0 and SHR0=8 (mode defaults) regardless of
what was set; writing GAIN_PCG_0 directly over I2C brightened the stream at
the next frame, proving sensor + bus healthy.

**Root cause:** the tegracam framework only *caches* user gain/exposure/
frame_rate writes and applies them to the sensor at stream-on **only when the
`override_enable` control (0x009a2065, default 0) is 1**. With it 0 (our
state all along), S_CTRL succeeds, registers never change, and the sensor
streams at mode defaults: SHR0=8 (≈ full-frame exposure) and gain 0.

Consequences for earlier results: every capture until now ran at gain 0 /
max exposure — the "green day mode", the washed-out `day.ppm`, and all
low-light noise complaints were symptoms of this, not of AWB/CCM.

**Fix:** set `override_enable=1` before streaming — now done by
`tools/view_stream.py` and `tools/cuda_debayer` (which also gained
`--exposure/--gain`). With it, register readback confirms exact programming
(gain 10000 mdB → GAIN_PCG_0=0x21=33 steps ≙ 9.9 dB; exposure 20000 µs @
VMAX 2250 → SHR0=900 exactly). Mid-stream control changes also land
register-exact once the flag is set — it gates all user control writes,
not just the stream-start application.

**Proper fix (driver-side):** `driver/nv_imx415.c` `imx415_set_mode()` now
asserts `s_data->override_enable = true` at every stream-on. A first attempt
set it at probe — defeated on target: the VI channel re-inits its control
handler at first open of /dev/video0 and handler_setup applies the
OVERRIDE_ENABLE default (0), clearing the field (`vi/channel.c`). set_mode
runs before tegracam's override check in s_stream, so it wins. NB the
`-C override_enable` readback is the VI channel's cached control value —
it reads 0 even when the fix works; verify behaviorally
(`tools/expo_gain_check.sh`). Details in `driver/README.md`. The userspace
setting stays as belt-and-suspenders.

**Enabling overrides exposed two more bugs (2026-07-10, I2C readback):**
the FRAME_RATE control value sat at min_framerate = 2 fps (created at 0,
range-clamped — the DT default is never applied to the *value*), so every
stream-on programmed VMAX 33750 → 2 fps streams; and overrides apply
exposure before frame rate, so SHR0 was computed against the previous VMAX
(requested 1 ms → actual 467 ms on the first stream after load — this
produced the seemingly "inverted" brightness during validation). Fixed in
the driver: FRAME_RATE control initialized to default_framerate at probe;
set_frame_rate re-derives SHR0 from the last requested exposure after
every VMAX write.

**Day-mode color confirmed by data** (same session): raw ratios under mixed
light R/G 0.54, B/G 0.31 — red is not IR-inflated, so the IR-CUT coil wire
mod holds the filter in the day position. Gray-world point sits ~0.07 off
the RPi-calibrated AWB CT curve (different IR-cut glass/lens than RPi's
calibration unit) — WB must stay gray-world; the curve is only good for CT
estimation (CCM/ALSC selection). See tools/cuda_debayer/README.md.

## Remaining / next (Phase H)

1. ~~IR-CUT~~ **DONE 2026-07-11** — FFC pin 18 / PP.01, pinmux fragment@1 in
   the overlay + `tools/ircut.sh`; deployed and validated on target (see
   "IR-CUT control line found on the FFC" above).
2. Phase H options: CUDA debayer + GPU crop/scale to 1080p (recommended first),
   4-lane rework for 30 fps (verify Waveshare PCB routes lanes 3/4 and CAM1 on
   p3768 has 4 lanes wired), sensor-side binned 1080p (donor tables in
   reference/ FRAMOS file), second camera on CAM0.
