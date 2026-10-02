class_name BudgetReport
extends RefCounted

## The machine-readable report writers: JSON sections and JUnit XML, from a run's checks and bars.
## Pure but for `env` and `board`, which read the host. Never instantiated.
## WHY: addons/device_budget/README.md §6

## What OS.get_model_name returns on a platform that does not know the model.
const GENERIC_MODEL: String = "GenericDevice"
## Files that name the board, in the order read: the DMI product name on a PC, the device-tree model
## on an ARM board. run_suite.sh reads the same two.
static var board_files: PackedStringArray = [
	"/sys/devices/virtual/dmi/id/product_name",
	"/proc/device-tree/model",
]


## What the run's numbers depend on beyond the scene: engine build, host, GPU, pool, window (px).
static func env(window: Vector2i) -> Dictionary:
	return {
		"engine": Engine.get_version_info()["string"],
		"debug": OS.is_debug_build(),
		"editor": OS.has_feature("editor"),
		"binary": OS.get_executable_path(),
		"os": OS.get_name(),
		"board": board(OS.get_model_name(), board_files),
		"cpu": OS.get_processor_name(),
		"threads": OS.get_processor_count(),
		"pool": ProjectSettings.get_setting("threading/worker_pool/max_threads"),
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"gpu_type": RenderingServer.get_video_adapter_type(),
		"gpu_api": RenderingServer.get_video_adapter_api_version(),
		"audio_device": AudioServer.output_device,
		"window": [window.x, window.y],
		"pin": OS.get_environment("DEVICE_BUDGET_PIN"),
	}


## The device's board name: `model` unless it is empty or GENERIC_MODEL, else the first of `files`
## that exists and holds a name, its trailing NUL and edge whitespace dropped; "" when none does.
## Reads `files`.
static func board(model: String, files: PackedStringArray) -> String:
	if not model.is_empty() and model != GENERIC_MODEL:
		return model
	for path: String in files:
		if not FileAccess.file_exists(path):
			continue
		var name: String = FileAccess.get_file_as_bytes(path).get_string_from_utf8().strip_edges()
		if not name.is_empty():
			return name
	return ""


## `profile`'s budgets as a JSON object.
static func profile(budget: BudgetProfile) -> Dictionary:
	var device: DeviceProfile = budget.device
	return {
		"label": budget.label,
		"resolution": [budget.resolution.x, budget.resolution.y],
		"window_s": budget.window_s,
		"warm_frames": budget.warm_frames,
		"min_frames": budget.min_frames,
		"min_drawn": budget.min_drawn,
		"frame_mean_ms": budget.frame_mean_ms,
		"frame_p99_ms": budget.frame_p99_ms,
		"gpu_mean_ms": budget.gpu_mean_ms,
		"gpu_p99_ms": budget.gpu_p99_ms,
		"cpu_tick_ms": budget.cpu_tick_ms,
		"hitch_ms": budget.hitch_ms,
		"hitch_max": budget.hitch_max,
		"video_max_mb": budget.video_max_mb,
		"static_max_mb": budget.static_max_mb,
		"device": device.label if device != null else "",
		"cpu_scale_estimated": device.cpu_scale_estimated if device != null else true,
	}


## `bars` as JSON objects: name, value, budget, unit, and whether each passed, was held at all.
static func bars(verdicts: Array[BudgetBar]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for bar: BudgetBar in verdicts:
		out.append(
			{
				"name": bar.name,
				"value": bar.value,
				"budget": bar.budget,
				"unit": bar.unit,
				"pass": bar.passed,
				"evidence": "skipped" if bar.skipped else "held",
				"message": bar.message,
			}
		)
	return out


## One JUnit <testsuite> for `scene`: a testcase per PREMISE check in `checks` (each {name, pass,
## message}) and per bar in `verdicts`, failures carrying the printed line.
static func junit(scene: String, checks: Array[Dictionary], verdicts: Array[BudgetBar]) -> String:
	var cases: PackedStringArray = []
	var failed: int = 0
	var skipped: int = 0
	for check: Dictionary in checks:
		var ok: bool = check["pass"]
		failed += 0 if ok else 1
		cases.append(_case("premise", check["name"], "" if ok else check["message"], false))
	for bar: BudgetBar in verdicts:
		var ok: bool = bar.skipped or bar.passed
		failed += 0 if ok else 1
		skipped += 1 if bar.skipped else 0
		cases.append(_case("bar", bar.name, "" if ok else bar.message, bar.skipped))
	return (
		'<?xml version="1.0" encoding="UTF-8"?>\n'
		+ (
			'<testsuite name="%s" tests="%d" failures="%d" skipped="%d">\n'
			% [scene.xml_escape(true), cases.size(), failed, skipped]
		)
		+ "".join(cases) + "</testsuite>\n"
	)


static func _case(kind: String, name: String, failure: String, skipped: bool) -> String:
	var head: String = '  <testcase classname="%s" name="%s"' % [kind, name.xml_escape(true)]
	if skipped:
		return head + "><skipped/></testcase>\n"
	if failure.is_empty():
		return head + "/>\n"
	return head + '><failure message="%s"/></testcase>\n' % failure.xml_escape(true)
