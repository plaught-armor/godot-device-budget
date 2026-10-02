class_name CalibrationSystem
extends RefCounted

## The arithmetic of a calibration: medians, the scale from host to device with its range, the
## spread between workloads, and the GPU stand-in verdict. Pure, never instantiated.
## WHY: addons/device_budget/README.md §3.7

## The workloads, in the order a calibration runs them. W1–W3 price the CPU bar; W4 is printed only.
enum Workload {
	W1_SCRIPT,
	W3_2MB,
	W3_64MB,
	W2_PHYSICS,
	W4_RENDER_CPU,
	GPU_FILL,
	GPU_VERTEX,
}

## Profile key of each workload, by Workload.
static var names: PackedStringArray = [
	"w1_script",
	"w3_2mb",
	"w3_64mb",
	"w2_physics",
	"w4_render_cpu",
	"gpu_fill",
	"gpu_vertex",
]

## Host GPU time over device GPU time at or above which the stand-in is weaker than the device.
const GPU_WEAKER_AT: float = 1.1
## Ratio below which the stand-in is stronger than the device, so its GPU bars are not evidence.
const GPU_STRONGER_BELOW: float = 0.9
## Spread (largest over smallest scale, less one) past which one CPU scale is not valid.
const MAX_SPREAD: float = 0.25


## The median of `runs`; the mean of the middle two for an even count, 0 when empty.
static func median(runs: PackedFloat64Array) -> float:
	if runs.is_empty():
		return 0.0
	var sorted: PackedFloat64Array = runs.duplicate()
	sorted.sort()
	var middle: int = sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) / 2.0


## The multiplier from host time to device time: x the median, y the least, z the most the host's
## runs allow. Zero when either side has no time.
static func scale(host_runs: PackedFloat64Array, device_ms: float) -> Vector3:
	var host_ms: float = median(host_runs)
	if host_ms <= 0.0 or device_ms <= 0.0:
		return Vector3.ZERO
	var sorted: PackedFloat64Array = host_runs.duplicate()
	sorted.sort()
	return Vector3(device_ms / host_ms, device_ms / sorted[-1], device_ms / sorted[0])


## Largest over smallest of `scales`, less one; 0 for fewer than two.
static func spread(scales: PackedFloat64Array) -> float:
	if scales.size() < 2:
		return 0.0
	var sorted: PackedFloat64Array = scales.duplicate()
	sorted.sort()
	return sorted[-1] / sorted[0] - 1.0


## The verdict printed for a host GPU `ratio` (host time over device time).
static func gpu_verdict(ratio: float) -> String:
	if ratio >= GPU_WEAKER_AT:
		return "GPU stand-in weaker than the device by x%.2f: a pass is a pass on the device" % ratio
	if ratio >= GPU_STRONGER_BELOW:
		return "GPU stand-in about equal to the device (x%.2f): a pass is marginal evidence" % ratio
	return (
		"GPU stand-in STRONGER than the device by x%.2f: GPU bars are not evidence" % (1.0 / ratio)
	)


## The scale with the largest median of `scales` (each from scale()); ZERO when every one is.
static func largest(scales: PackedVector3Array) -> Vector3:
	var best: Vector3 = Vector3.ZERO
	for each: Vector3 in scales:
		if each.x > best.x:
			best = each
	return best
