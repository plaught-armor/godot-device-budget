extends SceneTree

## Proves, on the engine this runs on, what the budget's CPU column assumes of
## `Performance.TIME_PHYSICS_PROCESS`: it holds the worst physics tick of the last wall second,
## refreshed once a second, and starts over each second. One physics tick stalls for SPIKE_MS; the
## monitor is read every process frame. Headless.
##
##     godot --headless --path . --fixed-fps 60 --script res://addons/device_budget/checks/second_max_check.gd
##
## Rows:
#   HELD     the monitor changed value at most once per wall second of the run, and far less often
#            than frames were read
#   MAX      after the stall, the monitor read at least SPIKE_MS: the tick's own time, not a mean
#            or the last tick
#   SECOND   the stall's reading was held for at least HOLD_S of wall time, so a once-a-second
#            sample cannot miss it
#   RESET    a later reading fell back under QUIET_MS: the maximum is per second, not per run
## WHY: addons/device_budget/README.md §4.1

## Wall seconds the lane runs, and the wall second after start at which the stall is taken.
const RUN_S: float = 4.5
const SPIKE_AT_S: float = 1.5
## Milliseconds the one stalled physics tick sleeps.
const SPIKE_MS: float = 30.0
## Least wall seconds the stall's reading must be held.
const HOLD_S: float = 0.8
## A reading under this (ms) is a second with no stall in it.
const QUIET_MS: float = 10.0

var _start_usec: int = 0
var _spiked: bool = false
var _frames: int = 0
var _changes: int = 0
var _last_ms: float = -1.0
var _held_from_usec: int = 0
var _longest_hold_s: float = 0.0
var _peak_ms: float = 0.0
var _quiet_after_peak: bool = false
var _failures: int = 0


func _initialize() -> void:
	_start_usec = Time.get_ticks_usec()
	print("SECOND engine %s" % Engine.get_version_info()["string"])


func _physics_process(_delta: float) -> bool:
	if not _spiked and _elapsed_s() >= SPIKE_AT_S:
		_spiked = true
		OS.delay_usec(int(SPIKE_MS * 1000.0))
	return false


func _process(_delta: float) -> bool:
	var now: int = Time.get_ticks_usec()
	var ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_frames += 1
	if ms != _last_ms:
		_close_hold(now)
		_changes += 1
		_last_ms = ms
		_held_from_usec = now
		if _peak_ms >= SPIKE_MS and ms < QUIET_MS:
			_quiet_after_peak = true
		_peak_ms = maxf(_peak_ms, ms)
	if _elapsed_s() < RUN_S:
		return false
	_close_hold(now)
	_report()
	return true


# Ends the current reading's hold at `now`; records it when it is the stall's reading.
func _close_hold(now: int) -> void:
	if _last_ms >= SPIKE_MS:
		_longest_hold_s = maxf(_longest_hold_s, float(now - _held_from_usec) / 1e6)


func _elapsed_s() -> float:
	return float(Time.get_ticks_usec() - _start_usec) / 1e6


func _report() -> void:
	var seconds: float = _elapsed_s()
	print(
		(
			"SECOND frames %d, %d value changes in %.2f s; peak %.2f ms held %.2f s; quiet after %s"
			% [_frames, _changes, seconds, _peak_ms, _longest_hold_s, _quiet_after_peak]
		)
	)
	_check(_spiked, "PREMISE the stall was never taken")
	_check(
		_changes <= ceili(seconds) + 1 and _frames >= 5 * _changes,
		"HELD %d changes over %d frames in %.2f s" % [_changes, _frames, seconds],
	)
	_check(_peak_ms >= SPIKE_MS, "MAX the monitor peaked at %.2f ms of %.1f" % [_peak_ms, SPIKE_MS])
	_check(
		_longest_hold_s >= HOLD_S,
		"SECOND the stall read for %.2f s of %.1f" % [_longest_hold_s, HOLD_S],
	)
	_check(_quiet_after_peak, "RESET no reading under %.1f ms after the stall" % QUIET_MS)
	print("SECOND %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error("second_max_check: " + message)
