class_name BudgetProfile
extends Resource

## The budget a played scene is held to: the window it is timed over, the thresholds its PREMISE
## checks hold, and the eight bars. A budget of zero skips its bar.
## WHY: addons/device_budget/README.md §3.4

## Name printed in the report.
@export var label: String = ""
## Window size (px) the runner requires the scene to be drawn at.
@export var resolution: Vector2i = Vector2i(1280, 800)
## Seconds of each timed window.
@export var window_s: float = 20.0
## Frames at the start that are not held to the budget, reported apart.
## WHY: addons/device_budget/README.md §4.4
@export var warm_frames: int = 180
## Fewest timed frames a window must hold.
@export var min_frames: int = 300
## Least share (0-1) of the timed frames the engine must have drawn.
## WHY: addons/device_budget/README.md §4.3
@export_range(0.0, 1.0) var min_drawn: float = 0.95
## Wall-clock frame time (ms): mean, and 99th percentile.
@export var frame_mean_ms: float = 16.7
@export var frame_p99_ms: float = 25.0
## The viewport's measured GPU time (ms): mean, and 99th percentile.
@export var gpu_mean_ms: float = 11.0
@export var gpu_p99_ms: float = 25.0
## Mean (ms) of the engine's worst physics tick of each second, after the CPU scale.
## WHY: addons/device_budget/README.md §4.2
@export var cpu_tick_ms: float = 8.0
## A timed frame longer than hitch_ms (ms) is a hitch; more than hitch_max of them fails.
@export var hitch_ms: float = 33.4
@export var hitch_max: int = 3
## Video memory and static memory (MB).
@export var video_max_mb: float = 1024.0
@export var static_max_mb: float = 4096.0
## The device the budget prices; null for none.
@export var device: DeviceProfile
