class_name CameraPathDriver
extends BudgetDriver

## Plays a scene with no controllable body: moves a Camera3D along a Path3D at a set speed, facing
## along the path, looping at its end. Proves the camera covered the path in each timed window.
## WHY: addons/device_budget/README.md §3.2

## The Path3D and the Camera3D, relative to the scene's root; empty finds the scene's first of each.
var path_node: NodePath = ^""
var camera_node: NodePath = ^""
## Speed (m/s) along the path, in wall time.
var speed_m_s: float = 4.0
## Least share (0+) of the path's length the camera must cover in a timed window; 1 is one lap.
var min_cover: float = 1.0
## Start of every line this driver prints.
var line_prefix: String = "BUDGET"

var _path: Path3D = null
var _camera: Camera3D = null
var _length_m: float = 0.0
var _offset_m: float = 0.0
var _covered_m: float = 0.0


func setup(scene: Node, _tree: SceneTree) -> PackedStringArray:
	_path = _find(scene, path_node, "Path3D") as Path3D
	_camera = _find(scene, camera_node, "Camera3D") as Camera3D
	var out: PackedStringArray = []
	if _path == null or _path.curve == null:
		out.append("PREMISE the scene has no Path3D with a curve")
	if _camera == null:
		out.append("PREMISE the scene has no Camera3D")
	if not out.is_empty():
		return out
	_length_m = _path.curve.get_baked_length()
	if _length_m <= 0.0:
		return ["PREMISE the Path3D's curve has no length"]
	_camera.make_current()
	return out


func drive(_t_s: float, delta_s: float, _timed: bool) -> StringName:
	var step_m: float = speed_m_s * delta_s
	_offset_m = fmod(_offset_m + step_m, _length_m)
	_covered_m += step_m
	_place()
	return &"path"


func window_opened() -> void:
	_covered_m = 0.0


func report_lines() -> PackedStringArray:
	return ["%s path   covered %.1f m of a %.1f m path" % [line_prefix, _covered_m, _length_m]]


func premise() -> PackedStringArray:
	var least_m: float = min_cover * _length_m
	if _covered_m < least_m:
		return ["PREMISE the camera covered %.1f m of %.1f" % [_covered_m, least_m]]
	return []


# Sets the camera on the path at the current offset, its -Z along the path.
func _place() -> void:
	var local: Transform3D = _path.curve.sample_baked_with_rotation(_offset_m, true)
	_camera.global_transform = _path.global_transform * local


# The node at `at` under `scene`, or, when `at` is empty, the first node of `type` in it.
static func _find(scene: Node, at: NodePath, type: String) -> Node:
	if not at.is_empty():
		return scene.get_node_or_null(at)
	if scene.is_class(type):
		return scene
	var found: Array[Node] = scene.find_children("*", type, true, false)
	return found[0] if not found.is_empty() else null
