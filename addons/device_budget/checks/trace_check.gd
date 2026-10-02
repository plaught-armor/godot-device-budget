extends SceneTree

## Proves BudgetTrace puts a tick's time in the right column: nodes that stall a known time at
## priorities below, at and above 0 land in p-, p0 and p+, a bracketed node's stall lands in its
## column and not its neighbour's, a null node adds no column, and the report prints its tables
## in order. Headless, real physics ticks.
##
##     godot --headless --path . --script res://addons/device_budget/checks/trace_check.gd
##
## Rows:
#   BANDS     each stall's mean is in its band, within SLACK_MS; the other bands are under it
#   BRACKET   the bracketed stall alone fills its column; the unbracketed one beside it does not
#   NULL      a null node adds no column and makes no node
#   LINES     the mean line names every column; the worst-by tables are total, the bracket, p-, post
#   EMPTY     a trace with no kept ticks says so
## WHY: addons/device_budget/README.md §3.8

## Ticks kept before the rows are judged.
const TICKS: int = 30
## Most a band may read over its stall, and most a band with no stall may read (ms).
const SLACK_MS: float = 0.5
## Stall of each node (µs), by where it sits.
const BELOW_US: int = 3000
const AT_US: int = 2000
const BRACKETED_US: int = 1500
const ABOVE_US: int = 1000

var _trace: BudgetTrace = null
var _failures: int = 0
var _kept: int = 0
var _done: bool = false
# Orphan nodes a bracket on a null node left behind; a marker made before failing on it is one.
var _null_orphans: int = 0


func _initialize() -> void:
	_stall(-5, BELOW_US)
	_stall(0, AT_US)
	var bracketed: Node = _stall(0, BRACKETED_US)
	_stall(7, ABOVE_US)
	_trace = BudgetTrace.new(root)
	_trace.bracket("stall", bracketed)
	var orphans: float = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_trace.bracket("none", null)
	_null_orphans = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - orphans)


func _physics_process(_delta: float) -> bool:
	var now: int = Time.get_ticks_usec()
	_close(now)
	_trace.open(now)
	return false


func _process(_delta: float) -> bool:
	_close(Time.get_ticks_usec())
	if _kept >= TICKS and not _done:
		_done = true
		_judge()
		quit(1 if _failures > 0 else 0)
	return false


func _close(now: int) -> void:
	var row: PackedFloat64Array = _trace.close(now)
	if row.is_empty() or _kept >= TICKS:
		return
	_trace.keep(row, "note")
	_kept += 1


func _judge() -> void:
	var lines: PackedStringArray = _trace.lines("T")
	var means: Dictionary[String, float] = _means(lines[1])
	_band("BANDS p-", means["p-"], BELOW_US)
	_band("BANDS p0", means["p0"], AT_US + BRACKETED_US)
	_band("BANDS p+", means["p+"], ABOVE_US)
	_check("BANDS pre under slack %.3f" % means["pre"], means["pre"] < SLACK_MS)
	_check("BANDS post under slack %.3f" % means["post"], means["post"] < SLACK_MS)
	_band("BRACKET stall", means["stall"], BRACKETED_US)
	_check(
		"NULL no column, %d orphan nodes" % _null_orphans,
		(
			_null_orphans == 0 and not means.has("none")
			and _trace.names.size() == BudgetTrace.Band.size() + 1
		),
	)
	var tables: PackedStringArray = []
	for line: String in lines:
		if line.begins_with("T worst by "):
			tables.append(line.trim_prefix("T worst by "))
	_check(
		"LINES tables %s" % ",".join(tables),
		tables == PackedStringArray(["total", "stall", "p-", "post"]),
	)
	_check("LINES rows", lines.size() == 2 + 4 * (1 + BudgetTrace.TOP))
	_check("LINES note", lines[3].ends_with("| note"))
	var holder: Node = Node.new()
	var empty: BudgetTrace = BudgetTrace.new(holder)
	_check("EMPTY", empty.lines("T") == PackedStringArray(["T no ticks timed"]))
	holder.free()
	print("TRACE %s" % ("PASS" if _failures == 0 else "FAIL"))


# A node at `priority` that stalls `usec` on each physics tick, added last to root.
func _stall(priority: int, usec: int) -> Node:
	var node: Stall = Stall.new()
	node.usec = usec
	node.process_physics_priority = priority
	root.add_child(node)
	return node


# "T mean  pre 0.015  p- 0.130 ..." as column name to mean.
static func _means(line: String) -> Dictionary[String, float]:
	var words: PackedStringArray = line.trim_prefix("T mean").split(" ", false)
	var out: Dictionary[String, float] = { }
	for i: int in range(0, words.size() - 1, 2):
		out[words[i]] = words[i + 1].to_float()
	return out


func _band(row: String, got_ms: float, stall_us: int) -> void:
	var want: float = float(stall_us) / 1000.0
	_check("%s %.3f for %.3f" % [row, got_ms, want], got_ms >= want and got_ms < want + SLACK_MS)


func _check(row: String, ok: bool) -> void:
	print("TRACE %s %s" % ["ok  " if ok else "FAIL", row])
	if not ok:
		_failures += 1
		push_error("trace_check: " + row)


## Stalls `usec` (µs) on each physics tick.
class Stall:
	extends Node
	var usec: int = 0


	func _physics_process(_delta: float) -> void:
		OS.delay_usec(usec)
