extends Node3D

## The example's player: walks on the ui_up/ui_down/ui_left/ui_right actions at `speed_m_s` along
## its facing, and turns on the mouse's horizontal motion. Input is read both ways a game reads it:
## actions polled per physics tick, motion from _unhandled_input.

## Walking speed (m/s) and turn (rad per pixel of mouse motion).
@export var speed_m_s: float = 4.0
@export var turn_rad_per_px: float = 0.004


func _physics_process(delta: float) -> void:
	var input: Vector2 = Input.get_vector(&"ui_left", &"ui_right", &"ui_up", &"ui_down")
	var move: Vector3 = global_basis * Vector3(input.x, 0.0, input.y)
	global_position += move * speed_m_s * delta


func _unhandled_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		rotate_y(-motion.relative.x * turn_rad_per_px)
