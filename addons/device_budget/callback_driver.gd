class_name CallbackDriver
extends BudgetDriver

## The smallest custom driver: one Callable plays each frame, and nothing is proved about the play.
## WHY: addons/device_budget/README.md §3.2

## Called each process frame as play(t_s: float, delta_s: float) -> StringName, returning the
## phase's name.
var play: Callable


func _init(frame_play: Callable) -> void:
	play = frame_play


func setup(_scene: Node, _tree: SceneTree) -> PackedStringArray:
	if not play.is_valid():
		return ["PREMISE the callback driver's Callable is not valid"]
	return []


func drive(t_s: float, delta_s: float, _timed: bool) -> StringName:
	return play.call(t_s, delta_s)
