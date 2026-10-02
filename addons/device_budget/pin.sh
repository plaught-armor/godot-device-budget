#!/usr/bin/env bash
# Run a command on a few physical cores and their SMT siblings, with those cores' clock capped, and
# read back what took effect. Linux only.
#
# WHY: addons/device_budget/README.md §3.9
#
#   addons/device_budget/pin.sh godot --resolution 1280x800 --path . --script res://...
#   PIN=1 addons/device_budget/run_suite.sh res://levels/forest.tscn   # the same, for a suite
#
# Environment (every one optional):
#   PIN_CORES   physical cores to run on, the highest-numbered ones (default 4)
#   PIN_MHZ     clock cap on those cores' CPUs in MHz (default 3500); 0 leaves the clock alone
#   PIN_SUDO    what the cap's sysfs writes run under (default "sudo -n"; empty when already root)
#   PIN_SPIN    seconds each pinned CPU is kept busy while its clock is read back (default 1)
#   PIN_SYS     the cpu directory (default /sys/devices/system/cpu)
#   NAME        the start of this script's own lines (default pin)
#
# The command sees DEVICE_BUDGET_PIN, the effective state on one line, and the runners record it.
# The cap is put back when the command ends, however it ends.
#
# Exit: the command's exit code; 125 when the pin could not be set or did not take effect.
set -u

NAME="${NAME:-pin}"
PIN_CORES="${PIN_CORES:-4}"
PIN_MHZ="${PIN_MHZ:-3500}"
PIN_SUDO="${PIN_SUDO-sudo -n}"
PIN_SPIN="${PIN_SPIN:-1}"
PIN_SYS="${PIN_SYS:-/sys/devices/system/cpu}"
# Most the read-back clock may sit over the cap, as a fraction of it.
CAP_SLACK=0.03

say() { echo "$NAME: $*"; }
die() { echo "$NAME: $*" >&2; exit 125; }

[ $# -gt 0 ] || die "no command to run"
command -v taskset >/dev/null || die "no taskset; PIN needs Linux and util-linux"
command -v lscpu >/dev/null || die "no lscpu"

# The CPUs of the PIN_CORES highest-numbered physical cores, siblings included, as "4,12,5,13,...".
pick_cpus() {
  lscpu -p=CPU,CORE,ONLINE | awk -F, -v want="$PIN_CORES" '
    /^#/ || $3 != "Y" { next }
    { cpus[$2] = ($2 in cpus) ? cpus[$2] "," $1 : $1; if ($2 > top) top = $2 }
    END {
      out = ""; n = 0
      for (c = top; c >= 0 && n < want; c--) if (c in cpus) { out = out (out == "" ? "" : ",") cpus[c]; n++ }
      if (n == want) print out
    }'
}

# Prints the clock (MHz) each CPU in $@ reads while all of them are busy, as "min max".
busy_mhz() {
  local spins=() cpu mhz lo=0 hi=0
  for cpu in "$@"; do
    taskset -c "$cpu" bash -c 'while :; do :; done' &
    spins+=($!)
  done
  sleep "$PIN_SPIN"
  for cpu in "$@"; do
    mhz=$(cat "$PIN_SYS/cpu$cpu/cpufreq/cpuinfo_avg_freq" 2>/dev/null \
      || cat "$PIN_SYS/cpu$cpu/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    mhz=$((mhz / 1000))
    [ $lo -eq 0 ] || [ "$mhz" -lt $lo ] && lo=$mhz
    [ "$mhz" -gt $hi ] && hi=$mhz
  done
  kill "${spins[@]}" 2>/dev/null
  wait "${spins[@]}" 2>/dev/null
  echo "$lo $hi"
}

cpus="$(pick_cpus)"
[ -n "$cpus" ] || die "fewer than $PIN_CORES online physical cores"
IFS=, read -r -a cpu_list <<<"$cpus"

# The cap: each pinned CPU's own scaling_max_freq, the old value kept to put back.
declare -A old_max=()
restore() {
  local cpu
  for cpu in "${!old_max[@]}"; do
    echo "${old_max[$cpu]}" | $PIN_SUDO tee "$PIN_SYS/cpu$cpu/cpufreq/scaling_max_freq" >/dev/null \
      || echo "$NAME: could not put back cpu$cpu's scaling_max_freq ${old_max[$cpu]}" >&2
  done
}
trap restore EXIT
if [ "$PIN_MHZ" -gt 0 ]; then
  for cpu in "${cpu_list[@]}"; do
    file="$PIN_SYS/cpu$cpu/cpufreq/scaling_max_freq"
    [ -r "$file" ] || die "no $file; this kernel exposes no clock cap"
    old="$(cat "$file")"
    echo $((PIN_MHZ * 1000)) | $PIN_SUDO tee "$file" >/dev/null 2>&1 \
      || die "cannot write $file under '$PIN_SUDO'; run as root, or PIN_MHZ=0 for cores only"
    old_max[$cpu]="$old"
  done
fi

taskset -cp "$cpus" $$ >/dev/null || die "cannot pin to cpus $cpus"
allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/$$/status)"
read -r lo hi <<<"$(busy_mhz "${cpu_list[@]}")"
if [ "$PIN_MHZ" -gt 0 ]; then
  awk -v hi="$hi" -v cap="$PIN_MHZ" -v s="$CAP_SLACK" 'BEGIN { exit !(hi <= cap * (1 + s)) }' \
    || die "the cap did not take: busy cpus read up to $hi MHz against a $PIN_MHZ MHz cap"
fi
boost="$(cat "$PIN_SYS/cpufreq/boost" 2>/dev/null || echo -)"
export DEVICE_BUDGET_PIN="cpus=$allowed cap_mhz=$PIN_MHZ busy_mhz=$lo-$hi boost=$boost"
say "$DEVICE_BUDGET_PIN"
"$@"
code=$?
trap - EXIT
restore
exit $code
