#!/usr/bin/env bash
# Stands in for Godot in run_suite_check.sh: prints a device list under --verbose; otherwise
# acts out the scene named in BUDGET_SCENE (good, bad, silent, crash_clean, hang).
# WHY: addons/device_budget/README.md §3.6
for a in "$@"; do
  if [ "$a" = "--verbose" ]; then
    printf 'Devices:\n  #0: Big Discrete GPU - Supported, Discrete\n  #1: Small iGPU (RADV) - Supported, Integrated\n'
    exit 0
  fi
done
echo "args $*" >>"$FAKE_ARGS"
dir="$BUDGET_REPORT_DIR"; scene="$(basename "$BUDGET_SCENE" .tscn)"
pass() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="%s" tests="2" failures="%s" skipped="0">\n<testcase name="a"/>\n</testsuite>\n' "$BUDGET_SCENE" "$1" >"$dir/$scene.junit.xml"; }
echo "BUDGET frame mean 1.0"
case "$scene" in
  good) pass 0; exit 0 ;;
  bad) pass 1; echo "ERROR: runner: FAIL"; exit 1 ;;
  silent) exit 0 ;;
  crash_clean) pass 0; exit 134 ;;
  hang) sleep 5; exit 0 ;;
esac
