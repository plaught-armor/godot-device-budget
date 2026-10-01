extends BudgetRunner

## The device-budget runner on the example scene: a CameraPathDriver flies the camera round the
## scene's Path3D, and the scene is held to steam_deck_60.tres. WINDOWED; exits 2 under --headless.
##
##     godot --resolution 1280x800 --path . --script res://addons/device_budget/example/example_runner.gd


func _configure() -> void:
	scene_path = "res://addons/device_budget/example/example.tscn"
	driver = CameraPathDriver.new()
