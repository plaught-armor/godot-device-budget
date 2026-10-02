class_name InputTrack
extends Resource

## A recorded play: action changes and mouse motion, each keyed by wall seconds from the start of
## the recording. Written by InputRecorder, played by InputReplayDriver. Parallel arrays: the i-th
## entry of each action array is one change, the i-th entry of each motion array one frame's motion.
## WHY: addons/device_budget/README.md §3.5

## Seconds the recording ran.
@export var length_s: float = 0.0
## When each action change happened (s, ascending), which action, and its strength after (0 = released).
@export var action_times_s: PackedFloat32Array = []
@export var action_names: PackedStringArray = []
@export var action_strengths: PackedFloat32Array = []
## When each frame's mouse motion arrived (s, ascending), and its summed relative motion (px).
@export var motion_times_s: PackedFloat32Array = []
@export var motion_relative: PackedVector2Array = []
