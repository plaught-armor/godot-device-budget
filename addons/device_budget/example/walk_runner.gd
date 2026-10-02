extends BudgetRunner

## The device-budget runner on the walk scene: an InputReplayDriver plays walk_track.tres into the
## walker, looping, and the scene is held to steam_deck_60.tres. WINDOWED; exits 2 under --headless.
##
##     godot --resolution 1280x800 --path . --script res://addons/device_budget/example/walk_runner.gd


func _configure() -> void:
	scene_path = "res://addons/device_budget/example/walk.tscn"
	var replay: InputReplayDriver = InputReplayDriver.new()
	replay.track = load("res://addons/device_budget/example/walk_track.tres") as InputTrack
	replay.body_node = ^"Walker"
	driver = replay
