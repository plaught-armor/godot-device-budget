class_name InputRecorder
extends RefCounted

## Records the actions of the InputMap and the mouse's relative motion into an InputTrack, once per
## process frame. A press and release inside one frame records as both. Feed it every window event
## through on_input() and call sample() every process frame.
## WHY: addons/device_budget/README.md §3.5

## Least change in an action's strength that is recorded.
const STRENGTH_STEP: float = 0.01

var track: InputTrack = InputTrack.new()

var _actions: Array[StringName] = []
var _strengths: PackedFloat32Array = []
var _motion: Vector2 = Vector2.ZERO


## Starts a recording of every action in the InputMap; the actions' current state is the baseline.
func _init() -> void:
	_actions = InputMap.get_actions()
	_strengths.resize(_actions.size())
	for i: int in _actions.size():
		_strengths[i] = Input.get_action_strength(_actions[i])


## Adds a window event's mouse motion to the current frame's.
func on_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		_motion += motion.relative


## Records what changed since the last sample, at `t_s` seconds from the start of the recording.
func sample(t_s: float) -> void:
	for i: int in _actions.size():
		var action: StringName = _actions[i]
		var strength: float = Input.get_action_strength(action)
		if strength == 0.0 and _strengths[i] == 0.0 and Input.is_action_just_pressed(action):
			_add_action(t_s, action, 1.0)
			_add_action(t_s, action, 0.0)
		elif (
			absf(strength - _strengths[i]) >= STRENGTH_STEP
			or (strength == 0.0) != (_strengths[i] == 0.0)
		):
			_add_action(t_s, action, strength)
			_strengths[i] = strength
	if _motion != Vector2.ZERO:
		track.motion_times_s.append(t_s)
		track.motion_relative.append(_motion)
		_motion = Vector2.ZERO
	track.length_s = t_s


func _add_action(t_s: float, action: StringName, strength: float) -> void:
	track.action_times_s.append(t_s)
	track.action_names.append(action)
	track.action_strengths.append(strength)
