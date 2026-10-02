#!/usr/bin/env bash
# Run a budget runner over several scenes, one windowed process each, and merge their JUnit reports.
#
# WHY: addons/device_budget/README.md §3.6
#
#   addons/device_budget/run_suite.sh res://levels/forest.tscn res://levels/town.tscn
#
# Environment (every one optional):
#   GODOT           the Godot binary (default `godot` on PATH)
#   RUNNER          the runner script (default res://addons/device_budget/budget_runner.gd)
#   PREFIX          the runner's env_prefix (default BUDGET_); the scene goes in <PREFIX>SCENE
#   DEVICE_BOARDS   board names that mean this host IS the device, space separated (default
#                   "Jupiter Galileo", the Steam Deck LCD and OLED)
#   HOST_CPU_SCALE  <PREFIX>CPU_SCALE when not on the device (default 1); 1 on the device
#   GPU_INDEX       the --gpu-index to use; unset picks the first Integrated GPU off the device
#   RESOLUTION      the window (default 1280x800)
#   TIMEOUT         seconds before a scene's process is killed (default 300)
#   LOGS            where the logs and reports go (default ${TMPDIR:-/tmp}/device_budget)
#   LINES           an ERE; matching log lines are echoed under each scene (default ^BUDGET )
#   NAME            the start of this script's own lines (default run_suite)
#
# Exit: the number of failing scenes, at most 124; 125 when the suite could not start.
set -u

NAME="${NAME:-run_suite}"
GODOT="${GODOT:-$(command -v godot || true)}"
RUNNER="${RUNNER:-res://addons/device_budget/budget_runner.gd}"
PREFIX="${PREFIX:-BUDGET_}"
DEVICE_BOARDS="${DEVICE_BOARDS:-Jupiter Galileo}"
RESOLUTION="${RESOLUTION:-1280x800}"
TIMEOUT="${TIMEOUT:-300}"
LOGS="${LOGS:-${TMPDIR:-/tmp}/device_budget}"
LINES="${LINES:-^BUDGET }"
PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"

say() { echo "$NAME: $*"; }
die() { echo "$NAME: $*" >&2; exit 125; }

# Prints the --gpu-index of the first Integrated device in Godot's verbose device list, or nothing.
# The list only prints from a windowed run of a project with a main scene, so it probes a scratch one.
integrated_gpu() {
  local probe
  probe="$(mktemp -d)" || return
  printf '[application]\nrun/main_scene="res://p.tscn"\n' >"$probe/project.godot"
  printf '[gd_scene format=3]\n\n[node name="P" type="Node"]\n' >"$probe/p.tscn"
  timeout 60 "$GODOT" --verbose --resolution 320x200 --path "$probe" --quit-after 2 2>&1 |
    sed -n 's/^ *#\([0-9]*\): .* - Supported, Integrated$/\1/p' | head -n 1
  rm -rf "$probe"
}

# Wakes every connected monitor that is off; fails the suite if one stays off. Linux only.
# WHY: addons/device_budget/README.md §4.7
monitors_on() {
  local off=()
  for status in /sys/class/drm/card*-*/status; do
    [ -r "$status" ] || continue
    [ "$(cat "$status")" = "connected" ] || continue
    [ "$(cat "${status%status}dpms" 2>/dev/null)" = "Off" ] && off+=("${status%/status}")
  done
  [ ${#off[@]} -eq 0 ] && return 0
  say "monitors off: ${off[*]##*/}; waking them"
  if command -v kscreen-doctor >/dev/null; then
    kscreen-doctor --dpms on >/dev/null 2>&1
  elif command -v xset >/dev/null; then
    xset dpms force on
  fi
  for _ in 1 2 3 4 5; do
    sleep 1
    local still=0
    for dir in "${off[@]}"; do
      [ "$(cat "$dir/dpms")" = "Off" ] && still=1
    done
    [ $still -eq 0 ] && return 0
  done
  die "a monitor is still off; turn it on, a monitor that is off makes the frame numbers fake"
}

# Escapes the five XML specials in $1.
xml() {
  local s="${1//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  echo "${s//\'/&apos;}"
}

[ -n "$GODOT" ] && [ -x "$GODOT" ] || die "no Godot binary at '$GODOT'; set GODOT=<path>"
[ $# -gt 0 ] || die "no scenes; name them as res:// paths"
mkdir -p "$LOGS" || die "cannot make $LOGS"

board=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)
on_device=0
for name in $DEVICE_BOARDS; do
  [ "$board" = "$name" ] && on_device=1
done
scale_var="${PREFIX}CPU_SCALE"
gpu_args=()
if [ $on_device -eq 1 ]; then
  export "$scale_var=${!scale_var:-1.0}"
else
  export "$scale_var=${!scale_var:-${HOST_CPU_SCALE:-1.0}}"
  index="${GPU_INDEX:-}"
  if [ -z "$index" ]; then
    index="$(integrated_gpu)"
    [ -n "$index" ] || die "no Integrated GPU in Godot's device list; set GPU_INDEX"
  fi
  gpu_args=(--gpu-index "$index")
fi
say "board=$board on_device=$on_device cpu_scale=${!scale_var} gpu=${gpu_args[*]:-default}"
export "${PREFIX}REPORT_DIR=$LOGS"

failed=0
suites=""
cases=0
failures=0
for scene in "$@"; do
  base="$(basename "$scene" .tscn)"
  log="$LOGS/$base.log"
  junit="$LOGS/$base.junit.xml"
  rm -f "$LOGS/$base.json" "$junit"
  monitors_on
  env "${PREFIX}SCENE=$scene" timeout "$TIMEOUT" "$GODOT" "${gpu_args[@]}" \
    --resolution "$RESOLUTION" --path "$PROJECT" --script "$RUNNER" >"$log" 2>&1
  code=$?
  suite=""
  [ -r "$junit" ] && suite="$(grep -v '^<?xml' "$junit")"
  # A run fails on a non-zero exit, and on a missing report whatever its exit.
  if [ $code -eq 0 ] && [ -n "$suite" ]; then
    echo "PASS  $base"
  else
    why="exit $code"
    [ $code -eq 124 ] && why="timed out after $TIMEOUT s"
    [ -z "$suite" ] && why="$why, no report"
    echo "FAIL  $base ($why, log $log)"
    failed=$((failed + 1))
    # Every case in the report passing still has to show as a failure.
    if [ -z "$suite" ] || grep -q 'failures="0"' <<<"$suite"; then
      suite="<testsuite name=\"$(xml "$scene")\" tests=\"1\" failures=\"1\" skipped=\"0\">
  <testcase name=\"run\" classname=\"$(xml "$scene")\"><failure message=\"$(xml "$why"), log $(xml "$log")\"/></testcase>
</testsuite>"
    fi
  fi
  grep -E "$LINES" "$log" | sed -e 's/^ERROR: //' -e 's/^/      /'
  cases=$((cases + $(sed -n '1s/.* tests="\([0-9]*\)".*/\1/p' <<<"$suite")))
  failures=$((failures + $(sed -n '1s/.* failures="\([0-9]*\)".*/\1/p' <<<"$suite")))
  suites+="$suite"$'\n'
done

merged="$LOGS/suite.junit.xml"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuites name=\"$(xml "$NAME")\" tests=\"$cases\" failures=\"$failures\">"
  printf '%s' "$suites"
  echo '</testsuites>'
} >"$merged"
say "junit $merged"
say "$failed of $# failed"
exit $((failed > 124 ? 124 : failed))
