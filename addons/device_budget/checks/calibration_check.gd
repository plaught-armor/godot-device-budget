extends SceneTree

## Proves CalibrationSystem's arithmetic on fixed inputs: the median, the scale and its range, the
## spread between workloads, the GPU verdict bands at and either side of each boundary, and the
## pick of the largest scale. Headless, no frames.
##
##     godot --headless --path . --script res://addons/device_budget/checks/calibration_check.gd
##
## Rows:
#   MEDIAN    odd and even counts, unsorted input, and empty
#   SCALE     median, least and most scale from the host's runs; zero when either side has no time
#   SPREAD    largest over smallest less one; zero for one value
#   VERDICT   weaker at and above 1.1, about equal from 0.9 to under 1.1, STRONGER below 0.9
#   TIMED     STRONGER holds under the GPU floor; weaker and about equal need the floor's work
#   LARGEST   the entry with the largest median scale, not the largest least or most; zero for none
## WHY: addons/device_budget/README.md §3.7

## Tolerance of a float row; Vector3 holds 32-bit floats.
const EPSILON: float = 1e-6

var _failures: int = 0


func _initialize() -> void:
	_check_median()
	_check_scale()
	_check_spread()
	_check_verdict()
	_check_timed()
	_check_largest()
	print("CALIBRATION %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _check_median() -> void:
	_near("MEDIAN odd", CalibrationSystem.median([5.0, 1.0, 3.0]), 3.0)
	_near("MEDIAN even", CalibrationSystem.median([4.0, 1.0, 3.0, 2.0]), 2.5)
	_near("MEDIAN empty", CalibrationSystem.median([]), 0.0)


func _check_scale() -> void:
	var scale: Vector3 = CalibrationSystem.scale([2.0, 4.0, 5.0], 8.0)
	_near("SCALE median", scale.x, 2.0)
	_near("SCALE least", scale.y, 1.6)
	_near("SCALE most", scale.z, 4.0)
	_check("SCALE no device", CalibrationSystem.scale([2.0], 0.0) == Vector3.ZERO)
	_check("SCALE no host", CalibrationSystem.scale([], 8.0) == Vector3.ZERO)


func _check_spread() -> void:
	_near("SPREAD three", CalibrationSystem.spread([2.0, 2.5, 3.0]), 0.5)
	_near("SPREAD one", CalibrationSystem.spread([2.0]), 0.0)


func _check_verdict() -> void:
	_verdict(1.2, "weaker")
	_verdict(CalibrationSystem.GPU_WEAKER_AT, "weaker")
	_verdict(1.09, "about equal")
	_verdict(CalibrationSystem.GPU_STRONGER_BELOW, "about equal")
	_verdict(0.89, "STRONGER")
	_check("VERDICT stronger factor", CalibrationSystem.gpu_verdict(0.5).contains("by x2.00"))


func _check_timed() -> void:
	var floor_ms: float = CalibrationSystem.GPU_FLOOR_MS
	_check("TIMED stronger under floor", CalibrationSystem.gpu_timed(0.5, floor_ms * 0.5))
	_check("TIMED weaker under floor", not CalibrationSystem.gpu_timed(1.5, floor_ms * 0.5))
	_check("TIMED equal under floor", not CalibrationSystem.gpu_timed(1.0, floor_ms * 0.5))
	_check("TIMED weaker at floor", CalibrationSystem.gpu_timed(1.5, floor_ms))


func _check_largest() -> void:
	var scales: PackedVector3Array = [
		Vector3(2.0, 1.8, 2.2),
		Vector3(3.0, 2.0, 3.5),
		Vector3(2.5, 2.4, 3.9),
	]
	_check("LARGEST pick", CalibrationSystem.largest(scales) == Vector3(3.0, 2.0, 3.5))
	_check("LARGEST none", CalibrationSystem.largest([]) == Vector3.ZERO)


func _verdict(ratio: float, word: String) -> void:
	var verdict: String = CalibrationSystem.gpu_verdict(ratio)
	_check("VERDICT %.2f is %s: %s" % [ratio, word, verdict], verdict.contains(" %s " % word))


func _near(row: String, got: float, want: float) -> void:
	_check("%s got %f want %f" % [row, got, want], absf(got - want) < EPSILON)


func _check(row: String, ok: bool) -> void:
	print("CALIBRATION %s %s" % ["ok  " if ok else "FAIL", row])
	if not ok:
		_failures += 1
		push_error("calibration_check: " + row)
