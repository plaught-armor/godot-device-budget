class_name BudgetDriver
extends RefCounted

## Plays a scene for BudgetRunner. Every method is called on the main thread. This base plays
## nothing and proves nothing; a project extends it or uses CallbackDriver.
## WHY: addons/device_budget/README.md §3.2


## Finds what it drives in `scene`, which is already in `tree`. Returns PREMISE failures; empty
## means ready.
func setup(_scene: Node, _tree: SceneTree) -> PackedStringArray:
	return []


## Drives one process frame. `t_s` is wall seconds since the first frame, `delta_s` the engine's
## process delta, `timed` whether the frame is inside a timed window. Returns the phase's name.
func drive(_t_s: float, _delta_s: float, _timed: bool) -> StringName:
	return &"idle"


## Called on the frame a timed window opens: restart whatever premise() and activity() count.
func window_opened() -> void:
	pass


## Lines printed after the memory line, describing how the scene was played.
func report_lines() -> PackedStringArray:
	return []


## PREMISE failures of the window just closed: the scene was not played as described. Held always.
func premise() -> PackedStringArray:
	return []


## Lines describing whether the stress was engaged, printed on every run.
func activity_lines() -> PackedStringArray:
	return []


## Failures of the stress's engagement. Held off a ramp, not held on one.
func activity() -> PackedStringArray:
	return []


## Releases every input it holds.
func release() -> void:
	pass
