extends SceneTree

## Proves BudgetReport.board on fake board files: the engine's model name first, the DMI file over the
## device-tree file, NULs and edge whitespace dropped, and "" when nothing names the board. Headless.
##
##     godot --headless --path . --script res://addons/device_budget/checks/board_check.gd
##
## Rows:
#   MODEL     a model name the engine knows wins over every file
#   DMI       GenericDevice falls to the first file, which wins over the second
#   TREE      no first file, or an empty one: the device-tree model, its NUL and newline dropped
#   NONE      no file names the board: ""
## WHY: addons/device_budget/README.md §3.6

const DIR: String = "user://board_check"

var _failures: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var dmi: String = DIR.path_join("product_name")
	var tree: String = DIR.path_join("model")
	var files: PackedStringArray = [dmi, tree]
	_write(dmi, "Jupiter\n".to_utf8_buffer())
	var arm: PackedByteArray = "Raspberry Pi 5 Model B Rev 1.0".to_utf8_buffer()
	arm.append(0)
	_write(tree, arm)
	_same("MODEL known", BudgetReport.board("MacBookPro18,3", files), "MacBookPro18,3")
	_same("DMI over tree", BudgetReport.board(BudgetReport.GENERIC_MODEL, files), "Jupiter")
	_same("DMI on empty model", BudgetReport.board("", files), "Jupiter")
	_write(dmi, " \n".to_utf8_buffer())
	_same(
		"TREE under empty DMI",
		BudgetReport.board(BudgetReport.GENERIC_MODEL, files),
		"Raspberry Pi 5 Model B Rev 1.0",
	)
	DirAccess.remove_absolute(dmi)
	_same(
		"TREE without DMI",
		BudgetReport.board(BudgetReport.GENERIC_MODEL, files),
		"Raspberry Pi 5 Model B Rev 1.0",
	)
	DirAccess.remove_absolute(tree)
	_same("NONE", BudgetReport.board(BudgetReport.GENERIC_MODEL, files), "")
	DirAccess.remove_absolute(DIR)
	print("BOARD %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _write(path: String, bytes: PackedByteArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _same(label: String, got: String, want: String) -> void:
	if got == want:
		print("ok    %s" % label)
		return
	_failures += 1
	print("FAIL  %s: got '%s', want '%s'" % [label, got, want])
