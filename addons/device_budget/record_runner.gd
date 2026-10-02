class_name RecordRunner
extends SceneTree

## Plays a scene for a person and records their input into an InputTrack for InputReplayDriver.
## WINDOWED. The recording ends when the window closes or after SECONDS, and is saved to TRACK.
##
##     BUDGET_SCENE=res://main.tscn BUDGET_TRACK=res://tracks/walk.tres godot --path . \
##         --script res://addons/device_budget/record_runner.gd
##
## Environment, each name behind `env_prefix` (BUDGET_ here):
#   SCENE    the scene to play (default `scene_path`)
#   TRACK    where the track is saved (default `track_path`)
#   SECONDS  stop after this many seconds (default: when the window closes)
## Exit: 0 when the track was saved, 1 when it was not (or held no input), 2 under --headless.
## WHY: addons/device_budget/README.md §3.5

## Config, set in _configure() or from the environment.
var scene_path: String = ""
var track_path: String = "res://input_track.tres"
var env_prefix: String = "BUDGET_"
var error_prefix: String = "record_runner"

var recorder: InputRecorder = null
var _seconds: float = INF
var _start_usec: int = 0
var _saved: bool = false


## Sets the config fields. Called first in _initialize; the base reads only the environment.
func _configure() -> void:
	pass


func _initialize() -> void:
	_configure()
	if DisplayServer.get_name() == "headless":
		print("%s: windowed only — a person plays the scene" % error_prefix)
		quit(2)
		return
	var scene_env: String = OS.get_environment(env_prefix + "SCENE")
	if not scene_env.is_empty():
		scene_path = scene_env
	var track_env: String = OS.get_environment(env_prefix + "TRACK")
	if not track_env.is_empty():
		track_path = track_env
	var seconds_env: String = OS.get_environment(env_prefix + "SECONDS")
	if not seconds_env.is_empty():
		_seconds = maxf(1.0, seconds_env.to_float())
	var packed: PackedScene = load(scene_path) as PackedScene if not scene_path.is_empty() else null
	if packed == null:
		push_error("%s: %s did not load" % [error_prefix, scene_path])
		quit(1)
		return
	root.add_child(packed.instantiate())
	recorder = InputRecorder.new()
	root.window_input.connect(recorder.on_input)
	process_frame.connect(_on_process_frame)


func _on_process_frame() -> void:
	var now: int = Time.get_ticks_usec()
	if _start_usec == 0:
		_start_usec = now
	var t_s: float = float(now - _start_usec) / 1e6
	recorder.sample(t_s)
	if t_s >= _seconds:
		process_frame.disconnect(_on_process_frame)
		quit(0 if _save() else 1)


func _finalize() -> void:
	if recorder != null and not _saved:
		_save()


# Writes the track to track_path; false, with an error printed, when it could not.
func _save() -> bool:
	_saved = true
	if recorder.track.action_times_s.is_empty() and recorder.track.motion_times_s.is_empty():
		push_error("%s: no input was recorded; %s not written" % [error_prefix, track_path])
		return false
	var err: Error = ResourceSaver.save(recorder.track, track_path)
	if err != OK:
		push_error("%s: saving %s failed: %s" % [error_prefix, track_path, error_string(err)])
		return false
	print(
		"%s: %.1f s, %d action changes, %d motion frames saved to %s"
		% [
			error_prefix,
			recorder.track.length_s,
			recorder.track.action_times_s.size(),
			recorder.track.motion_times_s.size(),
			track_path,
		]
	)
	return true
