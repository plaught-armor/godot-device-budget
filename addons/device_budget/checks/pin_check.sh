#!/usr/bin/env bash
# Proves pin.sh against a fake cpu tree, with no root: the cores it picks, the affinity the command
# runs under, the cap written and put back on every exit, and the refusals when the cap cannot be
# written or does not take. Also that run_suite.sh PIN=1 runs its scenes pinned. Linux only.
#
#   addons/device_budget/checks/pin_check.sh [pin.sh copy]
#
# Exit: the number of failed checks.
# WHY: addons/device_budget/README.md §3.9
D="$(cd "$(dirname "$0")" && pwd)"; P="${1:-$D/../pin.sh}"; W="$(mktemp -d)"; bad=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; bad=$((bad+1)); fi; }
export PIN_SYS="$W/sys" PIN_SUDO="" PIN_SPIN=0 PIN_CORES=2 PIN_MHZ=1234
MAX=5575866
# The fake tree: every online cpu with a max clock and a busy clock under the cap.
while IFS=, read -r cpu _; do
  mkdir -p "$W/sys/cpu$cpu/cpufreq"
  echo $MAX >"$W/sys/cpu$cpu/cpufreq/scaling_max_freq"
  echo 1200000 >"$W/sys/cpu$cpu/cpufreq/cpuinfo_avg_freq"
done < <(lscpu -p=CPU,ONLINE | grep -v '^#' | grep ',Y$')
mkdir -p "$W/sys/cpufreq"; echo 0 >"$W/sys/cpufreq/boost"
# Every cpu on the two highest cores, from lscpu, as one sorted line.
want="$(lscpu -p=CPU,CORE,ONLINE | grep -v '^#' | grep ',Y$' | sort -t, -k2,2n | awk -F, '
  { core[NR] = $2; cpu[NR] = $1 } END { n = 0; last = -1
    for (i = NR; i >= 1; i--) { if (core[i] != last) { n++; last = core[i] } if (n > 2) break; print cpu[i] } }' | sort -n | paste -sd,)"
maxes() { cat "$W"/sys/cpu*/cpufreq/scaling_max_freq | sort | uniq -c | sed 's/^ *//' | paste -sd' '; }
inner='grep Cpus_allowed_list /proc/self/status | cut -f2 >"$W/allowed"
  echo "$DEVICE_BUDGET_PIN" >"$W/state"; maxes >"$W/during"; exit 3'
export W; export -f maxes
out="$(bash "$P" bash -c "$inner" 2>&1)"; code=$?
echo "$out" | sed 's/^/      | /'
got="$(python3 -c "
import sys
out=[]
for part in sys.argv[1].split(','):
    a,_,b=part.partition('-'); out+=range(int(a),int(b or a)+1)
print(','.join(map(str,sorted(out))))" "$(cat "$W/allowed")")"
check "cpus are the two highest cores and their siblings ($got)" '[ "$got" = "$want" ]'
check "command sees the state it runs under" 'grep -q "^cpus=$(cat "$W/allowed") cap_mhz=1234 busy_mhz=1200-1200 boost=0$" "$W/state"'
n=$(tr , '\n' <<<"$want" | wc -l)
check "cap on the pinned cpus only, during the run" 'grep -qx "$n 1234000 $(( $(ls -d "$W"/sys/cpu[0-9]* | wc -l) - n )) $MAX" "$W/during" || grep -qx "$(( $(ls -d "$W"/sys/cpu[0-9]* | wc -l) - n )) $MAX $n 1234000" "$W/during"'
check "command's exit code passes through" '[ $code -eq 3 ]'
check "cap put back after the run" '[ "$(maxes)" = "$(ls -d "$W"/sys/cpu[0-9]* | wc -l) $MAX" ]'
# The cap read back above the cap: refused before the command runs, and put back.
for c in ${want//,/ }; do echo 1500000 >"$W/sys/cpu$c/cpufreq/cpuinfo_avg_freq"; done
rm -f "$W/ran"
bash "$P" touch "$W/ran" >/dev/null 2>&1; code=$?
check "cap that does not take: 125, no run" '[ $code -eq 125 ] && [ ! -e "$W/ran" ]'
check "cap that does not take: put back" '[ "$(maxes)" = "$(ls -d "$W"/sys/cpu[0-9]* | wc -l) $MAX" ]'
for c in ${want//,/ }; do echo 1200000 >"$W/sys/cpu$c/cpufreq/cpuinfo_avg_freq"; done
PIN_MHZ=0 bash "$P" touch "$W/ran" >/dev/null 2>&1; code=$?
check "PIN_MHZ=0 runs uncapped" '[ $code -eq 0 ] && [ -e "$W/ran" ]'
rm -f "$W/ran"
PIN_SUDO=false bash "$P" touch "$W/ran" >/dev/null 2>&1; code=$?
check "cap that cannot be written: 125, no run" '[ $code -eq 125 ] && [ ! -e "$W/ran" ]'
# A suite with PIN=1 runs its scenes pinned; the fake Godot records what it ran under.
mkdir -p "$W/logs"
PIN=1 GODOT="$D/fake_godot.sh" FAKE_ARGS="$W/args" LOGS="$W/logs" TIMEOUT=2 GPU_INDEX=1 \
  bash "$D/../run_suite.sh" res://good.tscn >/dev/null 2>&1; code=$?
check "PIN=1 suite passes, its scene pinned" '[ $code -eq 0 ] && grep -q "^pin cpus=\(.*\) cap_mhz=1234 .* allowed \1$" "$W/args"'
rm -rf "$W"
exit $bad
