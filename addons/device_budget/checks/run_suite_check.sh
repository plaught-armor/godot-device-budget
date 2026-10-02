#!/usr/bin/env bash
# Proves run_suite.sh on a fake Godot, in seconds and with no window: the GPU pick, the board name
# and its fallback order, the monitor check, pass and fail per scene, timeouts, stale reports and
# the merged JUnit.
#
#   addons/device_budget/checks/run_suite_check.sh [run_suite.sh copy]
#
# Exit: the number of failed checks.
# WHY: addons/device_budget/README.md §3.6
D="$(cd "$(dirname "$0")" && pwd)"; R="${1:-$D/../run_suite.sh}"; W="$(mktemp -d)"; bad=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; bad=$((bad+1)); fi; }
export GODOT="$D/fake_godot.sh" FAKE_ARGS="$W/args" LOGS="$W/logs" TIMEOUT=2
mkdir -p "$W/logs"
printf '<?xml version="1.0"?>\n<testsuite name="stale" tests="5" failures="0" skipped="0">\n</testsuite>\n' >"$W/logs/silent.junit.xml"
out="$(LINES="^BUDGET |runner: " bash "$R" res://good.tscn res://bad.tscn res://silent.tscn res://crash_clean.tscn res://hang.tscn 2>&1)"; code=$?
echo "$out" | sed 's/^/      | /'
check "integrated GPU picked" 'grep -q -- "--gpu-index 1 " "$W/args"'
check "exit counts 4 failures" '[ $code -eq 4 ]'
check "good passes" 'grep -q "^PASS  good" <<<"$out"'
check "silent fails on stale report" 'grep -q "^FAIL  silent (exit 0, no report" <<<"$out"'
check "crash with clean report fails" 'grep -q "^FAIL  crash_clean (exit 134," <<<"$out"'
check "hang times out" 'grep -q "^FAIL  hang (timed out after 2 s" <<<"$out"'
check "log lines echoed" '[ $(grep -c "^      BUDGET frame" <<<"$out") -eq 5 ]'
check "error prefix stripped" 'grep -q "^      runner: FAIL" <<<"$out"'
check "merged junit parses, 7 cases 4 failures" 'python3 -c "
import xml.etree.ElementTree as E,sys
r=E.parse(sys.argv[1]).getroot()
assert r.tag==\"testsuites\" and r.get(\"tests\")==\"7\" and r.get(\"failures\")==\"4\", r.attrib
assert len(r)==5
" "$W/logs/suite.junit.xml"'
# Board: a copy reading a fake DMI file and device-tree model.
mkdir -p "$W/dmi" "$W/dt"
sed -e "s#/sys/devices/virtual/dmi/id#$W/dmi#g" -e "s#/proc/device-tree#$W/dt#g" "$R" >"$W/board.sh"
printf 'Pi 5\0' >"$W/dt/model"; echo " Jupiter " >"$W/dmi/product_name"
out="$(GPU_INDEX=1 bash "$W/board.sh" res://good.tscn 2>&1)"
check "board: DMI first, edges dropped" 'grep -q "^run_suite: board=Jupiter on_device=1 " <<<"$out"'
: >"$W/dmi/product_name"
: >"$W/args"
out="$(DEVICE_BOARDS="Nope,Pi 5" GPU_INDEX=1 bash "$W/board.sh" res://good.tscn 2>&1)"
check "board: empty DMI falls to device tree, NUL dropped" 'grep -q "^run_suite: board=Pi 5 " <<<"$out" && ! grep -q "null byte" <<<"$out"'
check "on the device: no gpu index" 'grep -q " on_device=1 " <<<"$out" && ! grep -q -- "--gpu-index" "$W/args"'
rm "$W/dmi/product_name" "$W/dt/model"
out="$(GPU_INDEX=1 bash "$W/board.sh" res://good.tscn 2>&1)"
check "board: neither file, unknown" 'grep -q "^run_suite: board=unknown on_device=0 " <<<"$out"'
GPU_INDEX=0 bash "$R" res://good.tscn >/dev/null 2>&1
check "GPU_INDEX overrides" 'grep -q -- "--gpu-index 0 " "$W/args"'
# Monitors: a copy reading a fake DRM tree, with no tool to wake it.
mkdir -p "$W/drm/card9-DP-1"; echo connected >"$W/drm/card9-DP-1/status"; echo Off >"$W/drm/card9-DP-1/dpms"
sed -e "s#/sys/class/drm#$W/drm#g" -e 's/kscreen-doctor/no-such-tool-1/g' -e 's/xset/no-such-tool-2/g' "$R" >"$W/dark.sh"
: >"$W/args"
out="$(bash "$W/dark.sh" res://good.tscn 2>&1)"; code=$?
check "monitor off stops suite (125, no run)" '[ $code -eq 125 ] && [ ! -s "$W/args" ]'
echo On >"$W/drm/card9-DP-1/dpms"
bash "$W/dark.sh" res://good.tscn >/dev/null 2>&1; code=$?
check "monitor on runs" '[ $code -eq 0 ]'
rm -rf "$W"
exit $bad
