class_name BudgetWindow
extends RefCounted

## One timed window's raw samples and memory reads, as the runner took them. Transient: built at a
## window's end or read back from a report's JSON, and handed to BudgetSystem.
## WHY: addons/device_budget/README.md §7

## Frame count at which the window's timing opened; its first timed frame is this plus one.
var first_frame: int = 0
## Wall-clock time (ms) of each timed frame.
var wall_ms: PackedFloat32Array = []
## The viewport's measured GPU time (ms) of each timed frame.
var gpu_ms: PackedFloat32Array = []
## The engine's worst physics tick (s) of each second after the first, unscaled.
var physics_s: PackedFloat64Array = []
## The engine's worst process step (s) of each second after the first.
var process_s: PackedFloat64Array = []
## The driver's phase name of each timed frame.
var phases: PackedStringArray = []
## Frames the engine drew while the window was timed.
var drawn: int = 0
## Video memory (MB) at the window's end.
var video_mb: float = 0.0
## Static memory (MB) at the window's end; negative when the build cannot report it.
var static_mb: float = 0.0
