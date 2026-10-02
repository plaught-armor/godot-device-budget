class_name BudgetRunner
extends SceneTree

## Holds a played scene to a BudgetProfile. WINDOWED: it prices frames that are actually drawn,
## and exits 2 under --headless. Run it as is, or extend it and set the fields in _configure().
##
##     godot --resolution 1280x800 --path . --script res://addons/device_budget/budget_runner.gd
##     BUDGET_SCENE=res://main.tscn BUDGET_SECONDS=30 godot --resolution 1280x800 ...
##
## Environment, each name behind `env_prefix` (BUDGET_ here):
#   SCENE        the scene to play (default `scene_path`)
#   SECONDS      the window, at least 1 (default the profile's window_s)
#   CPU_SCALE    the multiplier from this host's CPU time to the device's (default 1)
#   PROFILE      a BudgetProfile .tres (default `profile`, else steam_deck_60.tres)
#   RAMP         a stress kind: every window that meets the budget adds RAMP_STEP of it (default 2)
#   REPORT_DIR   where the JSON and JUnit reports go (default user://device_budget)
#   TRACE        1 splits every timed physics tick into parts and prints the worst (BudgetTrace)
## Exit: 0 on a pass, 1 on any failure, 2 under --headless. A ramp is a measurement: it exits 0
## unless a PREMISE fails.
## WHY: addons/device_budget/README.md §3.1, §6

## Most ramp steps a run takes, and frames after each step left out of the next window.
## WHY: addons/device_budget/README.md §3.3
const RAMP_MAX_STEPS: int = 32
const RAMP_SETTLE_FRAMES: int = 120
const DEFAULT_PROFILE: String = "res://addons/device_budget/profiles/steam_deck_60.tres"
const DEFAULT_REPORT_DIR: String = "user://device_budget"
## Version of the JSON report's shape.
const SCHEMA: int = 1

## Config, set in _configure(): the profile, the driver, the scene, the environment prefix, the
## report's line and error prefixes, the least CPU scale taken, and the stress's name and kinds
## for a ramp that finds none.
var profile: BudgetProfile = null
var driver: BudgetDriver = null
var scene_path: String = ""
var env_prefix: String = "BUDGET_"
var line_prefix: String = "BUDGET"
var error_prefix: String = "budget_runner"
var cpu_scale_floor: float = 0.0
var stress_label: String = "stress hook"
var ramp_kinds: PackedStringArray = []

var _seconds: float = 20.0
var _cpu_scale: float = 1.0
var _failures: int = 0
var _frame: int = 0
var _last_usec: int = 0
var _boot_usec: int = 0
var _timed_usec: int = 0
var _wall_ms: PackedFloat32Array = []
var _gpu_ms: PackedFloat32Array = []
var _physics_s: PackedFloat64Array = []
var _process_s: PackedFloat64Array = []
var _phases: PackedStringArray = []
var _cpu_sample_usec: int = 0
var _cpu_skipped: bool = false
var _least_delta_s: float = INF
var _most_delta_s: float = 0.0
var _warm_worst_ms: float = 0.0
var _warm_hitches: int = 0
var _stress: BudgetStress = null
var _drawn_at_start: int = 0
# The ramp: which kind it adds (empty for none), how many a step, steps taken, the frame the
# current window's timing starts on, and the last count that passed.
var _ramp_kind: String = ""
var _ramp_step: int = 2
var _ramp_steps: int = 0
var _window_from: int = 0
var _ramp_passed: int = -1
# What the reports carry: every closed window, each PREMISE check, every line and failure printed.
var _windows: Array[Dictionary] = []
var _checks: Array[Dictionary] = []
var _printed: PackedStringArray = []
var _errors: PackedStringArray = []
# The per-tick trace under <prefix>TRACE=1; null otherwise.
var _trace: BudgetTrace = null


## Sets the config fields. Called first in _initialize; the base reads only the environment.
func _configure() -> void:
	pass


## The stress hook `scene` offers, before it enters the tree; null for none.
func _find_stress(_scene: Node) -> BudgetStress:
	return null


## The trace's bracket columns in `scene`, by column name, in print order. A null node adds none.
func _trace_columns(_scene: Node) -> Dictionary[String, Node]:
	return { }


## Words appended to a kept tick's note, after the play phase. Called once per kept tick.
func _trace_note() -> String:
	return ""


func _initialize() -> void:
	_configure()
	if DisplayServer.get_name() == "headless":
		print("%s: windowed only — it prices drawn frames" % error_prefix)
		quit(2)
		return
	_read_env()
	_window_from = profile.warm_frames
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var packed: PackedScene = load(scene_path) as PackedScene if not scene_path.is_empty() else null
	_check("scene", packed != null, "PREMISE %s did not load" % scene_path)
	if packed == null:
		quit(1)
		return
	var scene: Node = packed.instantiate()
	_stress = _find_stress(scene)
	_start_ramp()
	root.add_child(scene)
	var problems: PackedStringArray = driver.setup(scene, self)
	for problem: String in problems:
		_check("driver setup", false, problem)
	if not problems.is_empty():
		quit(1)
		return
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if OS.get_environment(env_prefix + "TRACE") == "1":
		_start_trace(scene)
	process_frame.connect(_on_process_frame)


# Builds the trace: its bands on root, then a bracket per column the subclass names in `scene`.
func _start_trace(scene: Node) -> void:
	_trace = BudgetTrace.new(root)
	var columns: Dictionary[String, Node] = _trace_columns(scene)
	for column: String in columns:
		_trace.bracket(column, columns[column])


# Opens a trace tick; the engine calls this before any node's physics.
func _physics_process(_delta: float) -> bool:
	if _trace != null:
		var now: int = Time.get_ticks_usec()
		_close_tick(now)
		_trace.open(now)
	return false


func _process(_delta: float) -> bool:
	if _trace != null:
		_close_tick(Time.get_ticks_usec())
	return false


# Ends the open trace tick at `now` and keeps it when it falls in a timed window.
func _close_tick(now: int) -> void:
	var row: PackedFloat64Array = _trace.close(now)
	if row.is_empty() or _frame <= _window_from:
		return
	var phase: String = _phases[-1] if not _phases.is_empty() else "?"
	_trace.keep(row, phase + _trace_note())


# Fills the config the subclass left unset, and the run's settings, from the environment.
func _read_env() -> void:
	var profile_env: String = OS.get_environment(env_prefix + "PROFILE")
	if not profile_env.is_empty():
		profile = load(profile_env) as BudgetProfile
	if profile == null:
		profile = load(DEFAULT_PROFILE) as BudgetProfile
	if driver == null:
		driver = BudgetDriver.new()
	var scene_env: String = OS.get_environment(env_prefix + "SCENE")
	if not scene_env.is_empty():
		scene_path = scene_env
	_seconds = profile.window_s
	var seconds_env: String = OS.get_environment(env_prefix + "SECONDS")
	if not seconds_env.is_empty():
		_seconds = maxf(1.0, seconds_env.to_float())
	var scale_env: String = OS.get_environment(env_prefix + "CPU_SCALE")
	if not scale_env.is_empty():
		_cpu_scale = maxf(cpu_scale_floor, scale_env.to_float())


func _on_process_frame() -> void:
	var now: int = Time.get_ticks_usec()
	var wall: float = 0.0 if _last_usec == 0 else float(now - _last_usec) / 1000.0
	_last_usec = now
	if _boot_usec == 0:
		_boot_usec = now
	_frame += 1
	var delta_s: float = root.get_process_delta_time()
	# Wall seconds, not frames: the frame rate is uncapped.
	var phase: StringName = driver.drive(
		float(now - _boot_usec) / 1e6,
		delta_s,
		_frame > _window_from,
	)
	if _frame <= _window_from:
		if _frame > 1 and _frame <= profile.warm_frames:
			_warm_worst_ms = maxf(_warm_worst_ms, wall)
			_warm_hitches += 1 if wall > profile.hitch_ms else 0
		if _frame == _window_from:
			_open_window(now)
		return
	_sample(now, wall, delta_s, phase)
	if float(now - _timed_usec) / 1e6 >= _seconds:
		if not _ramp_kind.is_empty() and _ramp_next():
			return
		process_frame.disconnect(_on_process_frame)
		driver.release()
		_report()


# Records one timed frame, and the engine's per-second maxima when a second has passed.
## WHY: addons/device_budget/README.md §4.1
func _sample(now: int, wall: float, delta_s: float, phase: StringName) -> void:
	_wall_ms.append(wall)
	_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	_phases.append(phase)
	_least_delta_s = minf(_least_delta_s, delta_s)
	_most_delta_s = maxf(_most_delta_s, delta_s)
	if now - _cpu_sample_usec >= 1000000:
		_cpu_sample_usec = now
		if _cpu_skipped:
			_physics_s.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
			_process_s.append(Performance.get_monitor(Performance.TIME_PROCESS))
		_cpu_skipped = true


# Reads <prefix>RAMP and <prefix>RAMP_STEP; a ramp lays none of its kind at start, so the first
# window prices the scene without it. Runs before the scene enters the tree.
func _start_ramp() -> void:
	_ramp_kind = OS.get_environment(env_prefix + "RAMP")
	var step_env: String = OS.get_environment(env_prefix + "RAMP_STEP")
	if not step_env.is_empty():
		_ramp_step = maxi(1, step_env.to_int())
	if _ramp_kind.is_empty():
		return
	var kinds: PackedStringArray = _stress.kinds() if _stress != null else ramp_kinds
	var known: bool = _ramp_kind in kinds
	_check(
		"ramp",
		_stress != null and known,
		(
			"PREMISE %sRAMP=%s needs %s and a %s"
			% [env_prefix, _ramp_kind, _either(kinds), stress_label]
		),
	)
	if _stress == null or not known:
		_ramp_kind = ""
		return
	_stress.set_start(_ramp_kind, 0)


# Restarts the timed window at this frame: every sample, the clock read and the driver's counts.
func _open_window(now: int) -> void:
	_wall_ms.clear()
	_gpu_ms.clear()
	_physics_s.clear()
	_process_s.clear()
	_phases.clear()
	_least_delta_s = INF
	_most_delta_s = 0.0
	_cpu_skipped = false
	_cpu_sample_usec = now
	_timed_usec = now
	_drawn_at_start = Engine.get_frames_drawn()
	driver.window_opened()


# The current window's samples, with memory read now.
func _window() -> BudgetWindow:
	var window: BudgetWindow = BudgetWindow.new()
	window.first_frame = _window_from
	window.wall_ms = _wall_ms.duplicate()
	window.gpu_ms = _gpu_ms.duplicate()
	window.physics_s = _physics_s.duplicate()
	window.process_s = _process_s.duplicate()
	window.phases = _phases.duplicate()
	window.drawn = Engine.get_frames_drawn() - _drawn_at_start
	window.video_mb = (
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)
		/ 1048576.0
	)
	# MEMORY_STATIC is not available in release builds.
	window.static_mb = (
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		if OS.is_debug_build()
		else -1.0
	)
	return window


# Ends a ramp window. When it met every budget and steps remain, adds a step of the ramped kind,
# schedules the next window after the settle frames and returns true; else returns false.
func _ramp_next() -> bool:
	var window: BudgetWindow = _window()
	var drawn: bool = BudgetSystem.drawn_enough(
		window.drawn,
		window.wall_ms.size(),
		profile.min_drawn,
	)
	if not drawn or not BudgetSystem.failures(window, profile, _cpu_scale).is_empty():
		return false
	_ramp_passed = _stress.count(_ramp_kind)
	_say("%s ramp   %s %d passes" % [line_prefix, _ramp_kind, _ramp_passed])
	if _ramp_steps >= RAMP_MAX_STEPS:
		return false
	_record(window, [])
	_stress.add(_ramp_kind, _ramp_step)
	_ramp_steps += 1
	_window_from = _frame + RAMP_SETTLE_FRAMES
	return true


func _report() -> void:
	var window: BudgetWindow = _window()
	var frames: int = window.wall_ms.size()
	var gpu_name: String = RenderingServer.get_video_adapter_name()
	_say(
		(
			"%s scene=%s gpu=%s window=%s frames=%d"
			% [line_prefix, scene_path, gpu_name, root.size, frames]
		)
	)
	_say(BudgetSystem.warm_line(line_prefix, _warm_worst_ms, _warm_hitches, profile.hitch_ms))
	for line: String in BudgetSystem.column_lines(line_prefix, window, _cpu_scale):
		_say(line)
	for line: String in BudgetSystem.worst_lines(line_prefix, window):
		_say(line)
	_say(BudgetSystem.memory_line(line_prefix, window.video_mb, window.static_mb))
	for line: String in driver.report_lines():
		_say(line)
	_hold_premise(window)
	for line: String in driver.activity_lines():
		_say(line)
	if _ramp_kind.is_empty():
		for failure: String in driver.activity():
			_check("activity", false, failure)
	var budget: PackedStringArray = BudgetSystem.failures(window, profile, _cpu_scale)
	_record(window, budget)
	if _ramp_kind.is_empty():
		for message: String in budget:
			_fail(message)
	else:
		_say(_ramp_line(window, budget))
	_say_build()
	if _trace != null:
		for line: String in _trace.lines(line_prefix + " trace"):
			_say(line)
	_say("%s %s" % [line_prefix, "PASS" if _failures == 0 else "FAIL"])
	_write_reports(window)
	quit(1 if _failures > 0 else 0)


# Holds every PREMISE of the closed window, printing the drawn line among them.
## WHY: addons/device_budget/README.md §4
func _hold_premise(window: BudgetWindow) -> void:
	var frames: int = window.wall_ms.size()
	_check(
		"cpu samples",
		window.physics_s.size() >= int(_seconds) - 2,
		"PREMISE only %d CPU samples in %.0f s" % [window.physics_s.size(), _seconds],
	)
	_check(
		"frames",
		frames >= profile.min_frames,
		"PREMISE only %d frames timed of %d" % [frames, profile.min_frames],
	)
	_say(BudgetSystem.drawn_line(line_prefix, window.drawn, frames))
	_check(
		"drawn",
		BudgetSystem.drawn_enough(window.drawn, frames, profile.min_drawn),
		(
			"PREMISE only %d of %d timed frames were drawn: is the window visible?"
			% [window.drawn, frames]
		),
	)
	_check(
		"clock",
		frames < 2 or not BudgetSystem.clock_fixed(_least_delta_s, _most_delta_s),
		"PREMISE every frame's delta was %.6f s: a fixed clock reports the pin" % _most_delta_s,
	)
	_check(
		"window size",
		Vector2i(root.size) == profile.resolution,
		"PREMISE the window is %s, the profile needs %s" % [root.size, profile.resolution],
	)
	_check(
		"vsync",
		DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED,
		"PREMISE vsync is on: a pinned frame rate reports the pin",
	)
	_check("max fps", Engine.max_fps == 0, "PREMISE Engine.max_fps is %d, not 0" % Engine.max_fps)
	var driver_failures: PackedStringArray = driver.premise()
	for failure: String in driver_failures:
		_check("driver", false, failure)
	if driver_failures.is_empty():
		_check("driver", true, "")


# The ramp's result line.
func _ramp_line(window: BudgetWindow, budget: PackedStringArray) -> String:
	var passed: String = "none" if _ramp_passed < 0 else str(_ramp_passed)
	var head: String = "%s RAMP %s: passes at %s" % [line_prefix, _ramp_kind, passed]
	if not BudgetSystem.drawn_enough(window.drawn, window.wall_ms.size(), profile.min_drawn):
		return head + ", stopped on an undrawn window"
	if budget.is_empty():
		return head + ", stopped at the step cap"
	return head + ", fails at %d on %s" % [_stress.count(_ramp_kind), budget[0]]


# Prints what the budgets depend on beyond the scene: the build, the worker pool against the
# device's threads, and a CPU scale below 1.
## WHY: addons/device_budget/README.md §4.6
func _say_build() -> void:
	var pool: int = ProjectSettings.get_setting("threading/worker_pool/max_threads")
	var device_threads: int = profile.device.hardware_threads if profile.device != null else 0
	_say(
		(
			"%s build  %s debug=%s pool=%d host_threads=%d device_threads=%d cpu_scale=%.2f"
			% [
				line_prefix,
				Engine.get_version_info()["string"],
				OS.is_debug_build(),
				pool,
				OS.get_processor_count(),
				device_threads,
				_cpu_scale,
			]
		)
	)
	if device_threads > 0 and (pool <= 0 or pool > device_threads):
		_say(
			(
				"%s build  WARNING worker pool %d is not capped at the device's %d threads"
				% [line_prefix, pool, device_threads]
			)
		)
	if _cpu_scale < 1.0:
		_say(
			(
				"%s build  WARNING cpu scale %.2f is below 1: this host is slower than the device"
				% [line_prefix, _cpu_scale]
			)
		)


# Keeps `window` and its failures for the reports.
func _record(window: BudgetWindow, failures: PackedStringArray) -> void:
	var record: Dictionary = BudgetSystem.window_to_json(window)
	record["failures"] = failures
	record["ramp_count"] = _stress.count(_ramp_kind) if not _ramp_kind.is_empty() else -1
	_windows.append(record)


# Writes the JSON report and the JUnit XML under <prefix>REPORT_DIR, named after the scene.
## WHY: addons/device_budget/README.md §6
func _write_reports(window: BudgetWindow) -> void:
	var dir: String = OS.get_environment(env_prefix + "REPORT_DIR")
	if dir.is_empty():
		dir = DEFAULT_REPORT_DIR
	var made: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if made != OK:
		push_error("%s: cannot make %s (%d)" % [error_prefix, dir, made])
		return
	var base: String = dir.path_join(scene_path.get_file().get_basename())
	var bars: Array[BudgetBar] = BudgetSystem.bars(window, profile, _cpu_scale)
	_write_text(base + ".json", JSON.stringify(_json(window, bars), "", false, true))
	_write_text(base + ".junit.xml", BudgetReport.junit(scene_path, _checks, bars))


func _json(window: BudgetWindow, bars: Array[BudgetBar]) -> Dictionary:
	return {
		"schema": SCHEMA,
		"scene": scene_path,
		"cpu_scale": _cpu_scale,
		"seconds": _seconds,
		"warm_worst_ms": _warm_worst_ms,
		"warm_hitches": _warm_hitches,
		"env": BudgetReport.env(root.size),
		"profile": BudgetReport.profile(profile),
		"premise": _checks,
		"bars": BudgetReport.bars(bars),
		"worst": BudgetSystem.worst_frames(window),
		"ramp": {
			"kind": _ramp_kind,
			"step": _ramp_step,
			"steps": _ramp_steps,
			"passed": _ramp_passed,
		},
		"windows": _windows,
		"printed": _printed,
		"errors": _errors,
	}


func _write_text(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("%s: cannot write %s (%d)" % [error_prefix, path, FileAccess.get_open_error()])
		return
	file.store_string(text)
	file.close()


# "a", "a or b", "a, b or c".
static func _either(words: PackedStringArray) -> String:
	if words.size() < 2:
		return "".join(words)
	return ", ".join(words.slice(0, -1)) + " or " + words[-1]


# Prints `line` and keeps it for the JSON report.
func _say(line: String) -> void:
	print(line)
	_printed.append(line)


# Records the PREMISE check `name` for the reports; when it fails, fails the run with `message`.
func _check(name: String, ok: bool, message: String) -> void:
	_checks.append({ "name": name, "pass": ok, "message": "" if ok else message })
	if not ok:
		_fail(message)


# Fails the run: counts `message`, keeps it for the JSON report and prints it as an error.
func _fail(message: String) -> void:
	_failures += 1
	_errors.append(message)
	push_error("%s: %s" % [error_prefix, message])
