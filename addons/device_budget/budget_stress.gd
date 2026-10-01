class_name BudgetStress
extends RefCounted

## The load a scene can be pushed with, by kind, for BudgetRunner's ramp. This base has no kinds;
## a project extends it over its own stress node.
## WHY: addons/device_budget/README.md §3.3


## The kinds the ramp may add, e.g. ["enemies", "lights", "props"].
func kinds() -> PackedStringArray:
	return []


## How many of `kind` are laid so far.
func count(_kind: String) -> int:
	return 0


## Sets how many of `kind` are laid at start; called before the scene enters the tree.
func set_start(_kind: String, _n: int) -> void:
	pass


## Lays `n` more of `kind`, during the run: one ramp step.
func add(_kind: String, _n: int) -> void:
	pass
