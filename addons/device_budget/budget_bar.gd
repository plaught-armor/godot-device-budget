class_name BudgetBar
extends RefCounted

## One bar's verdict on one window. Transient: BudgetSystem.bars builds it, the writers read it.

## The bar's name as the report prints it, e.g. "FRAME p99".
var name: String = ""
## The measured value, and the budget it is held to, in `unit`.
var value: float = 0.0
var budget: float = 0.0
var unit: String = "ms"
## Whether the value is within the budget; meaningless when skipped.
var passed: bool = true
## Whether the bar was not held: its budget is zero, or the build cannot measure it.
var skipped: bool = false
## The failure line printed when the bar fails; empty otherwise.
var message: String = ""
