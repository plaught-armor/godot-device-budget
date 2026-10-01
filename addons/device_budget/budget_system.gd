class_name BudgetSystem
extends RefCounted

## The pure half of the budget: a window's samples in, its statistics, bar verdicts and report lines
## out. No scene tree, so it runs headless and replays a report's JSON offline. Never instantiated.
## WHY: addons/device_budget/README.md §4, §7

## Worst timed frames a report prints.
const WORST_SHOWN: int = 5


## Arithmetic mean of `values`; 0 when empty.
static func mean(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sum: float = 0.0
	for v: float in values:
		sum += v
	return sum / float(values.size())


## Largest of `values`, floored at 0; 0 when empty.
static func most(values: PackedFloat32Array) -> float:
	var top: float = 0.0
	for v: float in values:
		top = maxf(top, v)
	return top


## The nearest-rank value at `fraction` (0-1) of `values`; 0 when empty. Does not mutate `values`.
static func percentile(values: PackedFloat32Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: PackedFloat32Array = values.duplicate()
	sorted.sort()
	return sorted[clampi(int(ceilf(fraction * float(sorted.size()))) - 1, 0, sorted.size() - 1)]


## How many of `values` exceed `limit`.
static func count_over(values: PackedFloat32Array, limit: float) -> int:
	var over: int = 0
	for v: float in values:
		over += 1 if v > limit else 0
	return over


## The per-second physics maxima (s) as the CPU column: ms, times `cpu_scale`.
static func cpu_ms(window: BudgetWindow, cpu_scale: float) -> PackedFloat32Array:
	var out: PackedFloat32Array = []
	for s: float in window.physics_s:
		out.append(s * 1000.0 * cpu_scale)
	return out


## The per-second process maxima (s) as ms.
static func process_ms(window: BudgetWindow) -> PackedFloat32Array:
	var out: PackedFloat32Array = []
	for s: float in window.process_s:
		out.append(s * 1000.0)
	return out


## Whether at least `min_drawn` (0-1) of `frames` timed frames were drawn.
static func drawn_enough(drawn: int, frames: int, min_drawn: float) -> bool:
	return float(drawn) >= min_drawn * float(frames)


## Whether every frame's delta (s) was one value, which is what a fixed clock gives.
## WHY: addons/device_budget/README.md §4.5
static func clock_fixed(least_delta_s: float, most_delta_s: float) -> bool:
	return most_delta_s - least_delta_s < 1e-9


## The eight bars of `profile` against `window`, in report order; a zero budget comes back skipped.
static func bars(
	window: BudgetWindow,
	profile: BudgetProfile,
	cpu_scale: float,
) -> Array[BudgetBar]:
	var cpu: PackedFloat32Array = cpu_ms(window, cpu_scale)
	var hitches: int = count_over(window.wall_ms, profile.hitch_ms)
	var out: Array[BudgetBar] = []
	var frame_mean: float = mean(window.wall_ms)
	var frame_p99: float = percentile(window.wall_ms, 0.99)
	var gpu_mean: float = mean(window.gpu_ms)
	var gpu_p99: float = percentile(window.gpu_ms, 0.99)
	var cpu_mean: float = mean(cpu)
	out.append(_bar("FRAME mean", frame_mean, profile.frame_mean_ms, "ms", "%.2f ms over %.1f"))
	out.append(_bar("FRAME p99", frame_p99, profile.frame_p99_ms, "ms", "%.2f ms over %.1f"))
	out.append(_bar("GPU mean", gpu_mean, profile.gpu_mean_ms, "ms", "%.2f ms over %.1f"))
	out.append(_bar("GPU p99", gpu_p99, profile.gpu_p99_ms, "ms", "%.2f ms over %.1f"))
	out.append(_bar("CPU mean", cpu_mean, profile.cpu_tick_ms, "ms", "%.2f ms over %.1f"))
	var hitch: BudgetBar = _bar("HITCH", float(hitches), float(profile.hitch_max), "frames", "")
	hitch.skipped = profile.hitch_ms <= 0.0
	hitch.passed = hitch.skipped or hitches <= profile.hitch_max
	if not hitch.passed:
		hitch.message = (
			"HITCH %d frames over %.1f ms, most %d" % [hitches, profile.hitch_ms, profile.hitch_max]
		)
	out.append(hitch)
	out.append(
		_bar("MEMORY video", window.video_mb, profile.video_max_mb, "MB", "%.1f MB over %.0f")
	)
	var memory_static: BudgetBar = _bar(
		"MEMORY static",
		window.static_mb,
		profile.static_max_mb,
		"MB",
		"%.1f MB over %.0f",
	)
	if window.static_mb < 0.0:
		memory_static.skipped = true
		memory_static.passed = true
		memory_static.message = ""
	out.append(memory_static)
	return out


## The failure line of each held bar `window` breaks, in report order; empty when it meets them all.
static func failures(
	window: BudgetWindow,
	profile: BudgetProfile,
	cpu_scale: float,
) -> PackedStringArray:
	var out: PackedStringArray = []
	for bar: BudgetBar in bars(window, profile, cpu_scale):
		if not bar.skipped and not bar.passed:
			out.append(bar.message)
	return out


## The warm-up line: the worst warm-up frame (ms) and how many warm-up frames were hitches.
static func warm_line(prefix: String, worst_ms: float, hitches: int, hitch_ms: float) -> String:
	return "%s warm   worst %.1f ms, %d frames over %.1f ms" % [prefix, worst_ms, hitches, hitch_ms]


## The frame, GPU, CPU and process lines of `window`, in that order.
static func column_lines(
	prefix: String,
	window: BudgetWindow,
	cpu_scale: float,
) -> PackedStringArray:
	var cpu: PackedFloat32Array = cpu_ms(window, cpu_scale)
	var process: PackedFloat32Array = process_ms(window)
	var out: PackedStringArray = []
	out.append(
		(
			"%s frame  mean %6.2f  p99 %6.2f  max %6.2f ms"
			% [prefix, mean(window.wall_ms), percentile(window.wall_ms, 0.99), most(window.wall_ms)]
		)
	)
	out.append(
		(
			"%s gpu    mean %6.2f  p99 %6.2f  max %6.2f ms"
			% [prefix, mean(window.gpu_ms), percentile(window.gpu_ms, 0.99), most(window.gpu_ms)]
		)
	)
	out.append(
		(
			"%s cpu    mean %6.2f  p99 %6.2f  max %6.2f ms (worst physics tick per second, x%.1f)"
			% [prefix, mean(cpu), percentile(cpu, 0.99), most(cpu), cpu_scale]
		)
	)
	out.append(
		(
			"%s process mean %6.2f  max %6.2f ms (worst per second, report only)"
			% [prefix, mean(process), most(process)]
		)
	)
	return out


## The WORST_SHOWN longest timed frames of `window`, longest first, each with its frame and phase.
static func worst_lines(prefix: String, window: BudgetWindow) -> PackedStringArray:
	var out: PackedStringArray = []
	for i: int in worst_frames(window):
		out.append(
			(
				"%s worst  #%d frame %d (%s): wall %.2f  gpu %.2f ms"
				% [
					prefix,
					out.size() + 1,
					i + window.first_frame + 1,
					window.phases[i],
					window.wall_ms[i],
					window.gpu_ms[i],
				]
			)
		)
	return out


## Indices of the WORST_SHOWN longest timed frames of `window`, longest first.
static func worst_frames(window: BudgetWindow) -> PackedInt32Array:
	# Array[int], not packed: sort_custom exists only on Array.
	var order: Array[int] = [] # gdlint: ignore[S6]
	for i: int in window.wall_ms.size():
		order.append(i)
	var wall: PackedFloat32Array = window.wall_ms
	order.sort_custom(
		func(a: int, b: int) -> bool:
			return wall[a] > wall[b],
	)
	var out: PackedInt32Array = []
	for k: int in mini(WORST_SHOWN, order.size()):
		out.append(order[k])
	return out


## The memory line; a negative static read prints as not available.
static func memory_line(prefix: String, video_mb: float, static_mb: float) -> String:
	if static_mb < 0.0:
		return "%s memory video %.1f MB  static n/a" % [prefix, video_mb]
	return "%s memory video %.1f MB  static %.1f MB" % [prefix, video_mb, static_mb]


## The drawn-frames line.
static func drawn_line(prefix: String, drawn: int, frames: int) -> String:
	return "%s drawn  %d of %d timed frames" % [prefix, drawn, frames]


## `window` as the JSON record a report carries and Gate A replays.
static func window_to_json(window: BudgetWindow) -> Dictionary:
	return {
		"first_frame": window.first_frame,
		"wall_ms": window.wall_ms,
		"gpu_ms": window.gpu_ms,
		"physics_s": window.physics_s,
		"process_s": window.process_s,
		"phases": window.phases,
		"drawn": window.drawn,
		"video_mb": window.video_mb,
		"static_mb": window.static_mb,
	}


## A window read back from its JSON record; exact when the JSON was written at full precision.
static func window_from_json(record: Dictionary) -> BudgetWindow:
	var window: BudgetWindow = BudgetWindow.new()
	window.first_frame = int(record["first_frame"])
	window.wall_ms = record["wall_ms"]
	window.gpu_ms = record["gpu_ms"]
	window.physics_s = record["physics_s"]
	window.process_s = record["process_s"]
	window.phases = record["phases"]
	window.drawn = int(record["drawn"])
	window.video_mb = record["video_mb"]
	window.static_mb = record["static_mb"]
	return window


# A bar of `value` against `budget`, failing when over; `shape` formats value and budget into the
# failure line after the name. A budget of zero or less skips it.
static func _bar(
	name: String,
	value: float,
	budget: float,
	unit: String,
	shape: String,
) -> BudgetBar:
	var bar: BudgetBar = BudgetBar.new()
	bar.name = name
	bar.value = value
	bar.budget = budget
	bar.unit = unit
	bar.skipped = budget <= 0.0
	bar.passed = bar.skipped or value <= budget
	if not bar.passed and not shape.is_empty():
		bar.message = name + " " + shape % [value, budget]
	return bar
