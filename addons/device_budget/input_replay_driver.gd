class_name InputReplayDriver
extends BudgetDriver

## Plays a scene by replaying an InputTrack through Input, keyed by wall time, looping at its end.
## Actions arrive as InputEventAction, motion as InputEventMouseMotion, so polled and event-driven
## input both see them. Proves the play reached the scene by how far `body_node` moved.
## WHY: addons/device_budget/README.md §3.5

## The track to replay.
var track: InputTrack = null
## The Node3D the play moves, relative to the scene's root; empty skips the travel premise.
var body_node: NodePath = ^""
## Least distance (m) the body must move in a timed window, summed frame to frame.
var min_travel_m: float = 1.0
## Start of every line this driver prints.
var line_prefix: String = "BUDGET"

var _viewport: Viewport = null
var _body: Node3D = null
var _start_s: float = -1.0
var _lap: int = 0
var _next_action: int = 0
var _next_motion: int = 0
var _held: Dictionary[StringName, bool] = { }
var _last_position: Vector3 = Vector3.ZERO
var _travel_m: float = 0.0
var _replayed: int = 0


func setup(scene: Node, tree: SceneTree) -> PackedStringArray:
	_viewport = tree.root
	if track == null or track.length_s <= 0.0:
		return ["PREMISE the input track is missing or empty"]
	if track.action_times_s.is_empty() and track.motion_times_s.is_empty():
		return ["PREMISE the input track holds no input"]
	if body_node.is_empty():
		return []
	_body = scene.get_node_or_null(body_node) as Node3D
	if _body == null:
		return ["PREMISE the scene has no Node3D at %s" % body_node]
	return []


func drive(t_s: float, _delta_s: float, _timed: bool) -> StringName:
	if _start_s < 0.0:
		_start_s = t_s
		if _body != null:
			_last_position = _body.global_position
	var played_s: float = t_s - _start_s
	var lap: int = int(played_s / track.length_s)
	if lap != _lap:
		_finish_lap()
		_lap = lap
	_replay_until(played_s - float(lap) * track.length_s)
	if _body != null:
		_travel_m += _body.global_position.distance_to(_last_position)
		_last_position = _body.global_position
	return &"replay"


func window_opened() -> void:
	_travel_m = 0.0
	_replayed = 0


func report_lines() -> PackedStringArray:
	var line: String = "%s replay %d inputs replayed, lap %d of a %.1f s track" % [
		line_prefix,
		_replayed,
		_lap + 1,
		track.length_s,
	]
	if _body != null:
		line += ", body moved %.1f m" % _travel_m
	return [line]


func premise() -> PackedStringArray:
	if _replayed == 0:
		return ["PREMISE no input was replayed in the window"]
	if _body != null and _travel_m < min_travel_m:
		return ["PREMISE the body moved %.1f m of %.1f" % [_travel_m, min_travel_m]]
	return []


func release() -> void:
	for action: StringName in _held.keys():
		_send_action(action, 0.0)
	_held.clear()


# Sends every entry of the track due by `at_s` seconds into the current lap.
func _replay_until(at_s: float) -> void:
	var actions: int = track.action_times_s.size()
	while _next_action < actions and track.action_times_s[_next_action] <= at_s:
		var action: StringName = StringName(track.action_names[_next_action])
		var strength: float = track.action_strengths[_next_action]
		_send_action(action, strength)
		if strength > 0.0:
			_held[action] = true
		else:
			_held.erase(action)
		_next_action += 1
	var motions: int = track.motion_times_s.size()
	while _next_motion < motions and track.motion_times_s[_next_motion] <= at_s:
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.relative = track.motion_relative[_next_motion]
		motion.screen_relative = motion.relative
		motion.position = _viewport.get_mouse_position()
		motion.global_position = motion.position
		Input.parse_input_event(motion)
		_replayed += 1
		_next_motion += 1


# Sends the rest of the lap, releases what it left held, and rewinds to the track's start.
func _finish_lap() -> void:
	_replay_until(track.length_s)
	release()
	_next_action = 0
	_next_motion = 0


func _send_action(action: StringName, strength: float) -> void:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = strength > 0.0
	event.strength = strength
	Input.parse_input_event(event)
	_replayed += 1
