extends SceneTree

## Proves InputRecorder and InputReplayDriver round-trip a play: a scripted input sequence is fed
## through Input while the example's walker plays, recorded, then replayed into a fresh walker,
## which must end where the recorded one did. Headless.
##
##     godot --headless --path . --script res://addons/device_budget/checks/replay_check.gd
##
## Rows:
#   ACTIONS  the track holds every scripted action change, a same-frame tap as a press and a release
#   MOTION   the track's motion sums to the scripted motion
#   PLAYED   the recorded walker moved and turned at all
#   POSE     at each of _pose_at_s, the replayed walker is within POSE_M and POSE_RAD of where the
#            recorded one was
#   RELEASED after the last scripted input, the replay holds no scripted action pressed
## Environment: REPLAY_TRACK, a path the recorded track is also saved to.
## WHY: addons/device_budget/README.md §3.5

const SCENE: String = "res://addons/device_budget/example/walk.tscn"
## Wall seconds the scripted play runs, and the seconds the two walkers' poses are compared at;
## the last is after the last scripted input and before the replay loops.
const RUN_S: float = 6.0
var _pose_at_s: PackedFloat32Array = [1.0, 2.5, 4.0, 5.8]
## The script: when (s), which action, strength after. One tap presses and releases at once.
var _script_times_s: PackedFloat32Array = [0.2, 2.0, 3.0, 3.0, 5.0, 5.0, 5.5, 5.5]
const SCRIPT_ACTIONS: Array[StringName] = [
	&"ui_up",
	&"ui_up",
	&"ui_up",
	&"ui_right",
	&"ui_up",
	&"ui_right",
	&"ui_left",
	&"ui_left",
]
var _script_strengths: PackedFloat32Array = [1.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0]
## Mouse motion fed between these seconds, MOTION_STEP_PX a frame until MOTION_PX is sent.
const MOTION_FROM_S: float = 2.0
const MOTION_PX: float = 300.0
const MOTION_STEP_PX: float = 10.0
## Most distance (m) and turn (rad) between the recorded and the replayed walker at one moment.
const POSE_M: float = 0.3
const POSE_RAD: float = 0.05

var _failures: int = 0
var _start_usec: int = 0
var _fed: int = 0
var _motion_sent: float = 0.0
var _scene: Node = null
var _recorder: InputRecorder = null
var _driver: InputReplayDriver = null
var _poses: Array[Transform3D] = []
var _pose_index: int = 0


func _initialize() -> void:
	print("REPLAY engine %s" % Engine.get_version_info()["string"])
	_scene = (load(SCENE) as PackedScene).instantiate()
	root.add_child(_scene)
	_recorder = InputRecorder.new()
	root.window_input.connect(_recorder.on_input)


func _process(_delta: float) -> bool:
	var now: int = Time.get_ticks_usec()
	if _start_usec == 0:
		_start_usec = now
	var t_s: float = float(now - _start_usec) / 1e6
	if _recorder != null:
		_take_pose(t_s)
		_record(t_s)
	elif _driver != null:
		_driver.drive(t_s, 0.0, true)
		_compare_pose(t_s)
		if _pose_index == _pose_at_s.size():
			_finish()
			return true
	return false


# Feeds the script due by `t_s` and samples the recorder; at RUN_S, starts the replay.
func _record(t_s: float) -> void:
	_recorder.sample(t_s)
	while _fed < _script_times_s.size() and _script_times_s[_fed] <= t_s:
		var event: InputEventAction = InputEventAction.new()
		event.action = SCRIPT_ACTIONS[_fed]
		event.strength = _script_strengths[_fed]
		event.pressed = event.strength > 0.0
		Input.parse_input_event(event)
		_fed += 1
	if t_s >= MOTION_FROM_S and _motion_sent < MOTION_PX:
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.relative = Vector2(MOTION_STEP_PX, 0.0)
		Input.parse_input_event(motion)
		_motion_sent += MOTION_STEP_PX
	if t_s < RUN_S:
		return
	root.window_input.disconnect(_recorder.on_input)
	_check_track(_recorder.track)
	var end: Transform3D = _walker().global_transform
	var start: Transform3D = (load(SCENE) as PackedScene) \
			.instantiate() \
			.get_node(^"Walker") \
			.transform
	_check(end.origin.distance_to(start.origin) > 1.0, "PLAYED the recorded walker did not move")
	_check(not end.basis.is_equal_approx(start.basis), "PLAYED the recorded walker did not turn")
	_check(
		_poses.size() == _pose_at_s.size(),
		"PLAYED %d of %d poses taken" % [_poses.size(), _pose_at_s.size()],
	)
	_save(_recorder.track)
	_start_replay(_recorder.track)


func _check_track(track: InputTrack) -> void:
	for action: StringName in [&"ui_up", &"ui_right", &"ui_left"]:
		var want: PackedFloat32Array = []
		for i: int in SCRIPT_ACTIONS.size():
			if SCRIPT_ACTIONS[i] == action:
				want.append(_script_strengths[i])
		var got: PackedFloat32Array = []
		for i: int in track.action_names.size():
			if StringName(track.action_names[i]) == action:
				got.append(track.action_strengths[i])
		_check(got == want, "ACTIONS %s recorded %s, the script fed %s" % [action, got, want])
	var summed: Vector2 = Vector2.ZERO
	for relative: Vector2 in track.motion_relative:
		summed += relative
	_check(
		is_equal_approx(summed.x, MOTION_PX) and summed.y == 0.0,
		"MOTION the track sums to %s, the script fed (%.0f, 0)" % [summed, MOTION_PX],
	)


func _start_replay(track: InputTrack) -> void:
	_recorder = null
	_scene.free()
	_scene = (load(SCENE) as PackedScene).instantiate()
	root.add_child(_scene)
	_driver = InputReplayDriver.new()
	_driver.track = track
	_driver.body_node = ^"Walker"
	for problem: String in _driver.setup(_scene, self):
		_check(false, problem)
	_start_usec = 0
	_pose_index = 0


func _walker() -> Node3D:
	return _scene.get_node(^"Walker") as Node3D


# During the recording: keeps the walker's pose at each of _pose_at_s as `t_s` passes it.
func _take_pose(t_s: float) -> void:
	if _pose_index < _pose_at_s.size() and t_s >= _pose_at_s[_pose_index]:
		_poses.append(_walker().global_transform)
		_pose_index += 1


# During the replay: holds the walker's pose to the recorded one at each of _pose_at_s.
func _compare_pose(t_s: float) -> void:
	if _pose_index >= mini(_poses.size(), _pose_at_s.size()) or t_s < _pose_at_s[_pose_index]:
		return
	var pose: Transform3D = _walker().global_transform
	var want: Transform3D = _poses[_pose_index]
	var off_m: float = pose.origin.distance_to(want.origin)
	var off_rad: float = absf(angle_difference(pose.basis.get_euler().y, want.basis.get_euler().y))
	print(
		"REPLAY at %.1f s: %.3f m, %.4f rad from the recording"
		% [_pose_at_s[_pose_index], off_m, off_rad]
	)
	_check(
		off_m <= POSE_M and off_rad <= POSE_RAD,
		"POSE at %.1f s the replayed walker is %.3f m, %.4f rad from the recorded one"
		% [_pose_at_s[_pose_index], off_m, off_rad],
	)
	_pose_index += 1


func _finish() -> void:
	for action: StringName in SCRIPT_ACTIONS:
		_check(
			not Input.is_action_pressed(action),
			"RELEASED %s is still held after the script" % action,
		)
	_driver.release()
	print("REPLAY %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _save(track: InputTrack) -> void:
	var path: String = OS.get_environment("REPLAY_TRACK")
	if path.is_empty():
		return
	var err: Error = ResourceSaver.save(track, path)
	_check(err == OK, "the track did not save to %s: %s" % [path, error_string(err)])


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error("replay_check: " + message)
