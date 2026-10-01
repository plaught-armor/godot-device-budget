class_name DeviceProfile
extends Resource

## The device a BudgetProfile prices: how to recognise it, its hardware threads, and the CPU scale
## from a host to it with where that scale came from.
## WHY: addons/device_budget/README.md §3.4

## Name printed in the report.
@export var label: String = ""
## DMI board names (`/sys/devices/virtual/dmi/id/product_name`) that identify the device.
@export var board_names: PackedStringArray = []
## Hardware threads the device runs; 0 when unknown.
@export var hardware_threads: int = 0
## Multiplier from host CPU time to the device's, applied off the device.
## WHY: addons/device_budget/README.md §5
@export var cpu_scale: float = 1.0
## Whether cpu_scale is an estimate rather than a measurement on the device.
@export var cpu_scale_estimated: bool = true
## Engine version and build type the reference numbers were measured on; empty when none were.
@export var engine_version: String = ""
@export var build_type: String = ""
