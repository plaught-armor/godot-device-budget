class_name BudgetTrace
extends RefCounted

## Splits every physics tick into parts by script priority, plus one column per bracketed node, and
## prints the mean of each part and the worst ticks by each. Host milliseconds, not scaled.
##
## Parts of a tick, in order:
#   total   the whole tick, from the runner's `_physics_process` to its next callback
#   pre     engine work before the first script: interpolation prepare, physics sync, queries
#   p-      scripts at priority below 0
#   p0      scripts at priority 0, everything left at default
#   p+      scripts above priority 0
#   post    after the last script: navigation, the physics step, the interpolation flush
#   <name>  a bracketed node and its subtree, a slice of whichever band its priority puts it in
## WHY: addons/device_budget/README.md §3.8

## Worst ticks printed per column.
const TOP: int = 10
## Ticks a sort key can index: about 46 hours at 60 ticks a second.
const KEY_SPAN: int = 10000000
## Columns before the brackets, by index: total, then the bands.
enum Band {
	TOTAL,
	PRE,
	MINUS,
	ZERO,
	PLUS,
	POST,
}

## Priority of each band marker, from first to last.
static var band_priorities: PackedInt32Array = [-100000, -1, 0, 100000]
## Column names, the bands first and then each bracket in the order it was added.
var names: PackedStringArray = ["total", "pre", "p-", "p0", "p+", "post"]

var _bands: Array[Marker] = []
var _ins: Array[Marker] = []
var _outs: Array[Marker] = []
var _tick_usec: int = 0
var _open: bool = false
# One row of columns and one note per kept tick.
var _rows: Array[PackedFloat64Array] = []
var _notes: PackedStringArray = []


## Adds the band markers to `root`, each last at its priority so it runs after every node of it.
func _init(root: Node) -> void:
	for priority: int in band_priorities:
		var marker: Marker = Marker.new()
		marker.process_physics_priority = priority
		root.add_child(marker)
		_bands.append(marker)


## Adds column `column`: markers just before `node` and just after it and its subtree, at its
## priority. A null node adds nothing.
func bracket(column: String, node: Node) -> void:
	if node == null:
		return
	var before: Marker = Marker.new()
	before.process_physics_priority = node.process_physics_priority
	node.add_sibling(before)
	node.get_parent().move_child(before, node.get_index())
	var after: Marker = Marker.new()
	after.process_physics_priority = node.process_physics_priority
	node.add_sibling(after)
	names.append(column)
	_ins.append(before)
	_outs.append(after)


## Starts a tick at `now` (µs).
func open(now: int) -> void:
	_tick_usec = now
	_open = true


## Ends the open tick at `now` (µs) and returns its row of columns; empty when none was open.
func close(now: int) -> PackedFloat64Array:
	var row: PackedFloat64Array = []
	if not _open:
		return row
	_open = false
	var stamps: PackedInt64Array = [_tick_usec]
	for band: Marker in _bands:
		stamps.append(band.stamp)
	stamps.append(now)
	row.append(_ms(now - _tick_usec))
	for i: int in range(1, stamps.size()):
		row.append(_ms(stamps[i] - stamps[i - 1]))
	for i: int in _ins.size():
		row.append(_ms(_outs[i].stamp - _ins[i].stamp))
	return row


## Keeps `row` from close() with `note`, for the report.
func keep(row: PackedFloat64Array, note: String) -> void:
	_rows.append(row)
	_notes.append(note)


## The report, each line behind `prefix`: tick count and total percentiles, the mean of every
## column, then the TOP worst ticks by total, by each bracket, by p- and by post.
func lines(prefix: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var n: int = _rows.size()
	if n == 0:
		out.append("%s no ticks timed" % prefix)
		return out
	var totals: PackedFloat64Array = []
	var sums: PackedFloat64Array = []
	sums.resize(names.size())
	for row: PackedFloat64Array in _rows:
		totals.append(row[Band.TOTAL])
		for c: int in names.size():
			sums[c] += row[c]
	totals.sort()
	out.append(
		(
			"%s ticks %d  mean %.3f  p50 %.3f  p99 %.3f  p999 %.3f  max %.3f ms (host)"
			% [
				prefix,
				n,
				sums[Band.TOTAL] / n,
				_at(totals, 0.5),
				_at(totals, 0.99),
				_at(totals, 0.999),
				totals[-1],
			]
		)
	)
	var means: PackedStringArray = []
	for c: int in range(1, names.size()):
		means.append("%s %.3f" % [names[c], sums[c] / n])
	out.append("%s mean  %s" % [prefix, "  ".join(means)])
	var order: PackedInt32Array = [Band.TOTAL]
	for c: int in range(Band.size(), names.size()):
		order.append(c)
	order.append(Band.MINUS)
	order.append(Band.POST)
	for c: int in order:
		out.append_array(_worst_by(prefix, c))
	return out


# The TOP ticks with the largest value in column `c`, every column of each.
func _worst_by(prefix: String, c: int) -> PackedStringArray:
	var out: PackedStringArray = ["%s worst by %s" % [prefix, names[c]]]
	var n: int = _rows.size()
	# Value in microseconds in the high digits, tick index in the low seven, so one sort ranks both.
	var keys: PackedInt64Array = []
	for i: int in n:
		keys.append(maxi(int(_rows[i][c] * 1000.0), 0) * KEY_SPAN + i)
	keys.sort()
	keys.reverse()
	for k: int in mini(TOP, n):
		var i: int = keys[k] % KEY_SPAN
		out.append("%s   tick %5d  %s | %s" % [prefix, i, _row_text(_rows[i]), _notes[i]])
	return out


# "total 1.934 | pre 0.021 p- 0.919 ... | player 0.638 mass 0.185" for one row.
func _row_text(row: PackedFloat64Array) -> String:
	var bands: PackedStringArray = []
	for c: int in range(Band.PRE, Band.size()):
		bands.append("%s %.3f" % [names[c], row[c]])
	var text: String = "total %6.3f | %s" % [row[Band.TOTAL], " ".join(bands)]
	if names.size() == Band.size():
		return text
	var brackets: PackedStringArray = []
	for c: int in range(Band.size(), names.size()):
		brackets.append("%s %.3f" % [names[c], row[c]])
	return text + " | " + " ".join(brackets)


static func _ms(usec: int) -> float:
	return float(usec) / 1000.0


# The value at `fraction` of an ascending array.
static func _at(sorted: PackedFloat64Array, fraction: float) -> float:
	return sorted[clampi(int(fraction * float(sorted.size())), 0, sorted.size() - 1)]


## Stamps the time (µs) on each physics tick; its priority and its place in the tree say where.
class Marker:
	extends Node
	var stamp: int = 0


	func _physics_process(_delta: float) -> void:
		stamp = Time.get_ticks_usec()
