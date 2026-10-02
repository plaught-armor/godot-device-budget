class_name CalibrateRunner
extends SceneTree

## Measures the calibration workloads on this host, RUNS times each, and prints each one's time,
## its scale to the device's reference time, the CPU scale the budget would take, and the GPU
## stand-in verdict. WINDOWED at 1280x800; exits 2 under --headless.
##
##     godot --resolution 1280x800 --path . --script res://addons/device_budget/calibrate_runner.gd
##
## Environment, each name behind `env_prefix` (CALIBRATE_ here):
#   PROFILE   a DeviceProfile .tres holding the device's reference_ms (default steam_deck.tres)
#   SAVE      a .tres path: write this host's medians there as a DeviceProfile
#   LABEL     the saved profile's label (default this host's CPU name)
## Exit: 0 when every workload was measured, 1 on a PREMISE failure, 2 under --headless.
## WHY: addons/device_budget/README.md §3.7

const DEFAULT_PROFILE: String = "res://addons/device_budget/profiles/steam_deck.tres"
## Runs per workload, and frames each windowed run spans after the workload's first WARM_FRAMES.
const RUNS: int = 5
const WARM_FRAMES: int = 30
const RUN_FRAMES: int = 60
## Window the GPU workloads are defined at.
const GPU_SIZE: Vector2i = Vector2i(1280, 800)
## Least share of a windowed run's frames that must be drawn.
const MIN_DRAWN: float = 0.95
## W1 loop iterations; W3 chase steps and array sizes (int32 slots); W2 ticks per run.
const SCRIPT_ITERATIONS: int = 300_000
const CHASE_STEPS: int = 1_000_000
const SLOTS_2MB: int = 524_288
const SLOTS_64MB: int = 16_777_216
const PHYSICS_TICKS: int = 90
## W2 pile: boxes a side and layers; characters walking through it.
const PILE_SIDE: int = 6
const PILE_LAYERS: int = 6
const WALKERS: int = 8
## W4: separately drawn boxes, and the small viewport they draw into.
const DRAWS: int = 2000
const DRAW_VIEWPORT: Vector2i = Vector2i(160, 100)
## GPU workloads: fragment loop count, vertex loop count, and the plane's subdivisions a side.
const FILL_LOOPS: int = 1024
const VERTEX_LOOPS: int = 64
const PLANE_SUBDIVIDE: int = 999

var env_prefix: String = "CALIBRATE_"
var line_prefix: String = "CALIBRATE"
var error_prefix: String = "calibrate_runner"

var _device: DeviceProfile = null
var _save_path: String = ""
var _save_label: String = ""
var _failures: int = 0
# Each workload's run times (ms), by CalibrationSystem.Workload.
var _results: Array[PackedFloat64Array] = []
var _stage: int = 0
var _run: int = 0
var _frame: int = 0
var _samples: PackedFloat64Array = []
var _drawn_from: int = 0
var _stage_node: Node = null
var _measured_rid: RID = RID()
var _chase: PackedInt32Array = []
var _walkers: Array[CharacterBody3D] = []
var _ticks_this_frame: int = 0
var _ticks_this_run: int = 0
var _tick_start_usec: int = 0


class _Probe:
	extends RefCounted
	var acc: int = 0


	func step(i: int) -> int:
		acc = (acc + i * 3) & 0xFFFF
		return acc


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("%s: windowed only — the GPU workloads need drawn frames" % error_prefix)
		quit(2)
		return
	_read_env()
	if _device == null:
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for _w: int in CalibrationSystem.Workload.size():
		_results.append(PackedFloat64Array())
	_say_host()
	physics_frame.connect(_on_physics_frame)
	process_frame.connect(_on_process_frame)
	_enter_stage()


func _read_env() -> void:
	var path: String = OS.get_environment(env_prefix + "PROFILE")
	path = DEFAULT_PROFILE if path.is_empty() else path
	_device = load(path) as DeviceProfile
	if _device == null:
		push_error("%s: PREMISE %s is not a DeviceProfile" % [error_prefix, path])
	_save_path = OS.get_environment(env_prefix + "SAVE")
	_save_label = OS.get_environment(env_prefix + "LABEL")
	if _save_label.is_empty():
		_save_label = OS.get_processor_name()


func _say_host() -> void:
	var types: PackedStringArray = ["other", "integrated", "discrete", "virtual", "cpu"]
	var gpu_type: int = RenderingServer.get_video_adapter_type()
	print(
		(
			"%s host  cpu=%s threads=%d gpu=%s (%s) engine=%s debug=%s"
			% [
				line_prefix,
				OS.get_processor_name(),
				OS.get_processor_count(),
				RenderingServer.get_video_adapter_name(),
				types[gpu_type] if gpu_type < types.size() else "unknown",
				Engine.get_version_info()["string"],
				OS.is_debug_build(),
			]
		)
	)
	var estimated: String = " ESTIMATED" if _device.reference_estimated else ""
	print("%s device  %s, reference times%s" % [line_prefix, _device.label, estimated])
	var engine: String = Engine.get_version_info()["string"]
	var build: String = "debug" if OS.is_debug_build() else "release"
	if _device.engine_version != engine or _device.build_type != build:
		print(
			(
				"%s WARN device times are from %s %s, this run is %s %s: the scales compare unlike builds"
				% [line_prefix, _device.engine_version, _device.build_type, engine, build]
			)
		)


# Builds what the current stage measures, and starts its first run.
func _enter_stage() -> void:
	_run = 0
	_frame = 0
	_samples.clear()
	var w: int = _stage
	if w == CalibrationSystem.Workload.W3_2MB:
		_chase = _cycle(SLOTS_2MB)
	elif w == CalibrationSystem.Workload.W3_64MB:
		_chase = _cycle(SLOTS_64MB)
	elif w == CalibrationSystem.Workload.W2_PHYSICS:
		Engine.physics_ticks_per_second = 60
		_start_pile()
	elif w == CalibrationSystem.Workload.W4_RENDER_CPU:
		_stage_node = _build_draws()
	elif w == CalibrationSystem.Workload.GPU_FILL:
		_stage_node = _build_fill()
	elif w == CalibrationSystem.Workload.GPU_VERTEX:
		_stage_node = _build_vertex()
	if _stage_node != null:
		root.add_child(_stage_node)
		_measure(_stage_node)
	_drawn_from = Engine.get_frames_drawn()


# Turns render timing on for the viewport the stage draws into.
func _measure(node: Node) -> void:
	var sub: SubViewport = node as SubViewport
	_measured_rid = sub.get_viewport_rid() if sub != null else root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_measured_rid, true)


func _on_physics_frame() -> void:
	_ticks_this_frame += 1
	if _ticks_this_frame == 1:
		_tick_start_usec = Time.get_ticks_usec()
	for walker: CharacterBody3D in _walkers:
		var ahead: Vector3 = Vector3.UP.cross(walker.position).normalized()
		walker.velocity = ahead * 4.0 - walker.position * 0.2 + Vector3.DOWN * 2.0
		walker.move_and_slide()


func _on_process_frame() -> void:
	var now: int = Time.get_ticks_usec()
	var ticks: int = _ticks_this_frame
	_ticks_this_frame = 0
	if _stage >= CalibrationSystem.Workload.size():
		return
	var w: int = _stage
	if w <= CalibrationSystem.Workload.W3_64MB:
		_sample(_time_cpu(w))
		_end_run()
	elif w == CalibrationSystem.Workload.W2_PHYSICS:
		_ticks_this_run += ticks
		if ticks == 1:
			_samples.append(float(now - _tick_start_usec) / 1000.0)
		if _ticks_this_run >= PHYSICS_TICKS:
			_end_run()
	else:
		_frame += 1
		if _frame > WARM_FRAMES or _run > 0:
			_samples.append(_render_ms(w))
		if _samples.size() >= RUN_FRAMES:
			_end_run()


func _sample(ms: float) -> void:
	_samples.append(ms)


# One run of a CPU workload that runs inside one frame; returns its milliseconds.
func _time_cpu(w: int) -> float:
	var start: int = Time.get_ticks_usec()
	if w == CalibrationSystem.Workload.W1_SCRIPT:
		_script_work(SCRIPT_ITERATIONS)
	else:
		_chase_work(_chase, CHASE_STEPS)
	return float(Time.get_ticks_usec() - start) / 1000.0


func _render_ms(w: int) -> float:
	if w == CalibrationSystem.Workload.W4_RENDER_CPU:
		return RenderingServer.viewport_get_measured_render_time_cpu(_measured_rid)
	return RenderingServer.viewport_get_measured_render_time_gpu(_measured_rid)


# Closes the current run: keeps its median, then starts the next run or the next stage.
func _end_run() -> void:
	var w: int = _stage
	_results[w].append(CalibrationSystem.median(_samples))
	_samples.clear()
	_run += 1
	if w == CalibrationSystem.Workload.W2_PHYSICS:
		_stop_pile()
		if _run < RUNS:
			_start_pile()
	if _run < RUNS:
		return
	if w >= CalibrationSystem.Workload.W4_RENDER_CPU:
		_check_drawn(w)
	if _stage_node != null:
		_stage_node.queue_free()
		_stage_node = null
	_chase = []
	_say_workload(w)
	_stage += 1
	if _stage < CalibrationSystem.Workload.size():
		_enter_stage()
	else:
		_finish()


func _check_drawn(w: int) -> void:
	var frames: int = WARM_FRAMES + RUNS * RUN_FRAMES
	var drawn: int = Engine.get_frames_drawn() - _drawn_from
	if float(drawn) < MIN_DRAWN * float(frames):
		_fail(
			(
				"PREMISE %s drew %d of %d frames: is the monitor off?"
				% [CalibrationSystem.names[w], drawn, frames]
			)
		)
	var size: Vector2i = Vector2i(root.size)
	if w >= CalibrationSystem.Workload.GPU_FILL and size != GPU_SIZE:
		_fail("PREMISE window %s, the GPU workloads are defined at %s" % [size, GPU_SIZE])


func _say_workload(w: int) -> void:
	var runs: PackedFloat64Array = _results[w]
	var sorted: PackedFloat64Array = runs.duplicate()
	sorted.sort()
	var line: String = (
		"%s %-13s host %8.3f ms (%.3f–%.3f)"
		% [
			line_prefix,
			CalibrationSystem.names[w],
			CalibrationSystem.median(runs),
			sorted[0],
			sorted[-1],
		]
	)
	var device_ms: float = _device.reference_ms.get(CalibrationSystem.names[w], 0.0)
	if device_ms > 0.0 and w >= CalibrationSystem.Workload.GPU_FILL:
		var ratio: float = CalibrationSystem.median(runs) / device_ms
		line += "  device %8.3f ms  host over device x%.2f" % [device_ms, ratio]
	elif device_ms > 0.0:
		var scale: Vector3 = CalibrationSystem.scale(runs, device_ms)
		line += (
			"  device %8.3f ms  scale x%.2f (%.2f–%.2f)" % [device_ms, scale.x, scale.y, scale.z]
		)
	else:
		line += "  no device reference"
	print(line)


func _finish() -> void:
	_say_cpu()
	_say_gpu()
	if not _save_path.is_empty():
		_save()
	quit(1 if _failures > 0 else 0)


# The CPU scale the budget takes: the largest of W1–W3, or a range when they disagree.
func _say_cpu() -> void:
	var scales: PackedVector3Array = []
	var medians: PackedFloat64Array = []
	for w: int in CalibrationSystem.Workload.W4_RENDER_CPU:
		var device_ms: float = _device.reference_ms.get(CalibrationSystem.names[w], 0.0)
		var scale: Vector3 = CalibrationSystem.scale(_results[w], device_ms)
		if scale.x > 0.0:
			scales.append(scale)
			medians.append(scale.x)
	if scales.is_empty():
		print("%s cpu  no W1–W3 reference in the profile: no scale" % line_prefix)
		return
	var top: Vector3 = CalibrationSystem.largest(scales)
	var spread: float = CalibrationSystem.spread(medians)
	medians.sort()
	if spread > CalibrationSystem.MAX_SPREAD:
		print(
			(
				"%s cpu  W1–W3 spread %d%%: one scale is not valid; the CPU bar is x%.2f–x%.2f, held at x%.2f"
				% [line_prefix, roundi(spread * 100.0), medians[0], medians[-1], top.z]
			)
		)
		return
	print(
		(
			"%s cpu  scale x%.2f (%.2f–%.2f), the largest of W1–W3; spread %d%%"
			% [line_prefix, top.x, top.y, top.z, roundi(spread * 100.0)]
		)
	)


# The GPU verdict from the GPU workload that favours the host most.
func _say_gpu() -> void:
	var ratio: float = INF
	for w: int in range(
		CalibrationSystem.Workload.GPU_FILL,
		CalibrationSystem.Workload.GPU_VERTEX + 1,
	):
		var device_ms: float = _device.reference_ms.get(CalibrationSystem.names[w], 0.0)
		if device_ms > 0.0:
			ratio = minf(ratio, CalibrationSystem.median(_results[w]) / device_ms)
	if ratio == INF:
		print("%s gpu  no GPU reference in the profile: no verdict" % line_prefix)
		return
	var verdict: String = CalibrationSystem.gpu_verdict(ratio).replace("device", _device.label)
	print("%s gpu  %s" % [line_prefix, verdict])


func _save() -> void:
	var host: DeviceProfile = DeviceProfile.new()
	host.label = _save_label
	host.hardware_threads = OS.get_processor_count()
	host.reference_estimated = false
	host.engine_version = Engine.get_version_info()["string"]
	host.build_type = "debug" if OS.is_debug_build() else "release"
	for w: int in CalibrationSystem.Workload.size():
		host.reference_ms[CalibrationSystem.names[w]] = CalibrationSystem.median(_results[w])
	var err: Error = ResourceSaver.save(host, _save_path)
	if err != OK:
		_fail("could not save %s: %s" % [_save_path, error_string(err)])
		return
	print("%s saved %s" % [line_prefix, _save_path])


func _fail(message: String) -> void:
	_failures += 1
	push_error("%s: %s" % [error_prefix, message])


# W1: typed arithmetic, static and instance calls, Array, Dictionary and packed-array work.
static func _script_work(iterations: int) -> int:
	var acc: int = 0
	var f: float = 0.0
	var list: PackedInt32Array = []
	var table: Dictionary[int, int] = { }
	var packed: PackedFloat64Array = []
	packed.resize(256)
	var probe: _Probe = _Probe.new()
	for i: int in iterations:
		acc = (acc * 31 + i) & 0xFFFF
		f += sqrt(float(i & 1023)) * 0.5
		acc += _static_step(i) + probe.step(i)
		list.append(acc)
		if list.size() > 64:
			list.clear()
		table[i & 127] = acc
		var other: int = (i * 5) & 127
		if table.has(other):
			acc ^= table[other]
		packed[i & 255] = f
		f -= packed[(i * 7) & 255] * 0.25
	return acc + int(f)


static func _static_step(i: int) -> int:
	return (i ^ 0x5A5A) & 0xFF


# W3: follows `chase` from slot 0 for `steps` steps; every step is a dependent load.
static func _chase_work(chase: PackedInt32Array, steps: int) -> int:
	var at: int = 0
	for _i: int in steps:
		at = chase[at]
	return at


# One random cycle through `slots` slots (Sattolo), seeded so every host chases the same path.
static func _cycle(slots: int) -> PackedInt32Array:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1
	var chase: PackedInt32Array = []
	chase.resize(slots)
	for i: int in slots:
		chase[i] = i
	for i: int in range(slots - 1, 0, -1):
		var j: int = rng.randi_range(0, i - 1)
		var held: int = chase[i]
		chase[i] = chase[j]
		chase[j] = held
	return chase


# W2: a floor, a pile of boxes stacked to topple, and walkers circling through it.
func _start_pile() -> void:
	var pile: Node3D = Node3D.new()
	pile.add_child(_body(StaticBody3D.new(), Vector3(40.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0)))
	for layer: int in PILE_LAYERS:
		for x: int in PILE_SIDE:
			for z: int in PILE_SIDE:
				var at: Vector3 = Vector3(
					x * 0.6 - 1.5 + layer * 0.1,
					0.3 + layer * 0.6,
					z * 0.6 - 1.5,
				)
				pile.add_child(_body(RigidBody3D.new(), Vector3(0.5, 0.5, 0.5), at))
	_walkers.clear()
	for i: int in WALKERS:
		var walker: CharacterBody3D = CharacterBody3D.new()
		var shape: CollisionShape3D = CollisionShape3D.new()
		var capsule: CapsuleShape3D = CapsuleShape3D.new()
		capsule.radius = 0.3
		capsule.height = 1.8
		shape.shape = capsule
		walker.add_child(shape)
		var angle: float = TAU * i / WALKERS
		walker.position = Vector3(cos(angle) * 2.5, 0.9, sin(angle) * 2.5)
		pile.add_child(walker)
		_walkers.append(walker)
	_stage_node = pile
	_ticks_this_run = 0
	if _run > 0:
		root.add_child(pile)


func _stop_pile() -> void:
	_walkers.clear()
	_stage_node.free()
	_stage_node = null


func _body(body: PhysicsBody3D, size: Vector3, at: Vector3) -> PhysicsBody3D:
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	return body


# W4: DRAWS boxes, each with its own material, drawn into a small viewport.
func _build_draws() -> SubViewport:
	var view: SubViewport = SubViewport.new()
	view.size = DRAW_VIEWPORT
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 40.0)
	view.add_child(camera)
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(0.4, 0.4, 0.4)
	var side: int = ceili(sqrt(float(DRAWS)))
	for i: int in DRAWS:
		var box: MeshInstance3D = MeshInstance3D.new()
		box.mesh = mesh
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.albedo_color = Color.from_hsv(float(i) / DRAWS, 0.8, 0.9)
		box.material_override = material
		box.position = Vector3((i % side) - side * 0.5, (i / side) - side * 0.5, 0.0) * 0.5
		view.add_child(box)
	return view


# GPU fill: a full-window rectangle whose every pixel runs FILL_LOOPS iterations.
func _build_fill() -> CanvasLayer:
	var shader: Shader = Shader.new()
	shader.code = (
		"""
shader_type canvas_item;
void fragment() {
	vec2 p = UV * 8.0;
	float v = 0.0;
	for (int i = 0; i < %d; i++) {
		v += sin(p.x * float(i) * 0.01 + v) * cos(p.y + v * 0.5);
	}
	COLOR = vec4(fract(v), 0.0, 0.0, 1.0);
}
"""
		% FILL_LOOPS
	)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = shader
	var rect: ColorRect = ColorRect.new()
	rect.material = material
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var layer: CanvasLayer = CanvasLayer.new()
	layer.add_child(rect)
	return layer


# GPU vertex: a plane of about a million vertices, each running VERTEX_LOOPS iterations.
func _build_vertex() -> Node3D:
	var shader: Shader = Shader.new()
	shader.code = (
		"""
shader_type spatial;
render_mode unshaded, cull_disabled;
void vertex() {
	float h = 0.0;
	for (int i = 0; i < %d; i++) {
		h += sin(VERTEX.x * 3.0 + float(i) * 0.1 + h) * cos(VERTEX.z * 3.0 + h) * 0.01;
	}
	VERTEX.y += h;
}
void fragment() {
	ALBEDO = vec3(0.2, 0.5, 0.2);
}
"""
		% VERTEX_LOOPS
	)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = shader
	var plane: PlaneMesh = PlaneMesh.new()
	plane.subdivide_width = PLANE_SUBDIVIDE
	plane.subdivide_depth = PLANE_SUBDIVIDE
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = plane
	mesh.material_override = material
	var scene: Node3D = Node3D.new()
	scene.add_child(mesh)
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0.0, 1.5, 1.5)
	camera.rotation = Vector3(-PI / 4.0, 0.0, 0.0)
	scene.add_child(camera)
	return scene
