# device_budget

Holds a played Godot 4 scene to a frame budget for a target device, such as a Steam Deck, and fails
loudly when the run did not happen as described. It is GDScript only, with no GDExtension, so it runs
on whatever engine build your project runs.

A run plays one scene in a real window for a timed window of wall time (20 s by default). It measures
every frame's wall time and GPU time, plus the engine's worst physics tick of each second. It holds
them to a `BudgetProfile`, and then prints a human summary and writes a JSON report and a JUnit XML
report. Exit code 0 is a pass, 1 is a failure, and 2 means the runner was started under `--headless`.

**What it does not claim.** On a machine that is not the device, the CPU bar is your CPU's time times
an estimated scale, and the GPU bar is whatever GPU you ran on (§5, §8). A pass off the device is
evidence; it is not a measurement of the device.

Steam Deck is a trademark of Valve Corporation. This addon is not affiliated with or endorsed by
Valve. The shipped profiles use the name only to say which device their numbers describe.

## §1 — Requirements

- Godot 4.4 or later. Tested on 4.4.1-stable, 4.6-stable and a 4.8 development build.
- A visible window. The runner prices frames the engine actually drew, so it refuses `--headless`.
  Monitors that are asleep (DPMS off) make the engine skip drawing while the main loop runs on; the
  drawn-frames check (§4.3) catches that.
- No editor plugin to enable. The scripts register their classes through `class_name`; run
  `godot --headless --import` once after copying the addon in so the class names resolve.

## §2 — Quick start

Copy `addons/device_budget/` into your project, then run the example:

```sh
godot --resolution 1280x800 --path . --script res://addons/device_budget/example/example_runner.gd
```

It flies a camera round a small scene with `CameraPathDriver` and holds it to
`profiles/steam_deck_60.tres`. To price your own scene with no code, name it in the environment:

```sh
BUDGET_SCENE=res://levels/forest.tscn godot --resolution 1280x800 --path . \
  --script res://addons/device_budget/example/example_runner.gd
```

That needs a `Path3D` and a `Camera3D` in the scene. A scene with a player can be played by a
recorded input track instead (§3.5); `example/walk_runner.gd` replays one. For anything else, write a
runner (§3.1) with a driver that plays your scene (§3.2).

## §3 — The pieces

### §3.1 — BudgetRunner

`BudgetRunner` is a `SceneTree` script: the main loop of the run. Use it as is, or extend it and set
its fields in `_configure()`:

```gdscript
extends BudgetRunner

func _configure() -> void:
	scene_path = "res://levels/forest.tscn"
	profile = preload("res://addons/device_budget/profiles/steam_deck_60.tres")
	driver = MyPlayDriver.new()
	env_prefix = "FOREST_"   # environment names become FOREST_SECONDS, FOREST_PROFILE, ...
	line_prefix = "FOREST"   # every printed line starts with this

func _find_stress(scene: Node) -> BudgetStress:
	return MyStress.new(scene)   # optional, for the ramp (§3.3)
```

Environment, each name behind `env_prefix` (`BUDGET_` by default):

| Name | Meaning | Default |
|---|---|---|
| `SCENE` | the scene to play | `scene_path` |
| `SECONDS` | the timed window, at least 1 | the profile's `window_s` |
| `CPU_SCALE` | multiplier from this host's CPU time to the device's (§5) | 1 |
| `PROFILE` | a `BudgetProfile` `.tres` | `profile`, else `steam_deck_60.tres` |
| `RAMP`, `RAMP_STEP` | a stress kind to ramp, and how many to add a step (§3.3) | none, 2 |
| `REPORT_DIR` | where the JSON and JUnit reports go | `user://device_budget` |
| `TRACE` | `1` splits every timed physics tick into parts and prints the worst ticks (§3.8) | off |

The runner turns vsync off and sets `Engine.max_fps` to 0 itself. Run it without `--fixed-fps`: a
pinned clock reports the pin, not the cost (§4.5).

### §3.2 — Drivers

A `BudgetDriver` plays the scene. The runner calls it on the main thread every process frame, so the
scene is loaded the same way on every run. A driver can also prove the play happened: a body that got
stuck at the spawn point prices an empty room.

| Method | Called | Returns |
|---|---|---|
| `setup(scene, tree)` | once, after the scene enters the tree | PREMISE failures; empty means ready |
| `drive(t_s, delta_s, timed)` | every process frame | the phase's name, printed against the worst frames |
| `window_opened()` | when a timed window opens | — |
| `report_lines()` | at the report | lines describing the play |
| `premise()` | at the report, always held | failures: the scene was not played as described |
| `activity_lines()` / `activity()` | at the report | lines, and failures held off a ramp: the stress was not engaged |
| `release()` | when the run ends | — |

Four ship with the addon:

- `BudgetDriver` plays nothing and proves nothing. Extend it.
- `CallbackDriver.new(callable)` calls `callable(t_s, delta_s) -> StringName` each frame and proves
  nothing. It is the smallest custom driver.
- `CameraPathDriver` moves a `Camera3D` along a `Path3D` at `speed_m_s` (wall time, not frames), and
  faces along the path, looping at its end. Its premise holds that each timed window covered
  `min_cover` of the path's length (one lap by default), so a window too short for the path fails
  instead of pricing part of the scene. It suits fly-throughs and scenes with no controllable body.
- `InputReplayDriver` replays a recorded `InputTrack` into the scene's own input handling, and
  proves a named body moved. It suits a scene with a player. See §3.5.

Drive by wall time (`t_s`, `delta_s`), not by frame count. A frame-counted script plays a shorter,
lighter run on a slow machine, which is the machine the budget is for.

### §3.3 — Stress and the ramp

A `BudgetStress` is the load a scene can be pushed with, by kind: enemies, lights, physics props.
Return one from `_find_stress()`. It needs `kinds()`, `count(kind)`, `set_start(kind, n)` (called
before the scene enters the tree) and `add(kind, n)` (called during the run).

With `RAMP=<kind>` the run becomes a measurement. That kind starts at 0, and every timed window that
meets every budget adds `RAMP_STEP` more. The next window starts after 120 settle frames, so the
frames that spawn the new load are not priced as steady state. The first window that fails ends the
run with `RAMP <kind>: passes at N, fails at M on <bar>`. After 32 steps the run stops at the step
cap. A ramp exits 0 unless a PREMISE fails, because a failing bar is its answer, not an error. It also
stops at a window that was not drawn (§4.3).

### §3.4 — Profiles

A `BudgetProfile` holds the window size, the timed window, the warm-up, the PREMISE thresholds and
eight bars: FRAME mean and p99, GPU mean and p99, CPU mean, HITCH, MEMORY video, MEMORY static. A
budget of zero skips its bar. Its `device` is a `DeviceProfile`: the DMI board names that identify
the device, its hardware threads, and the CPU scale with whether that scale is an estimate.

Shipped:

| Profile | For | FRAME mean / p99 | GPU mean / p99 | CPU | HITCH |
|---|---|---|---|---|---|
| `steam_deck_60.tres` | 60 fps on the Deck's 60 Hz screen | 16.7 / 25 ms | 11 / 25 ms | 8 ms | ≤ 3 over 33.4 ms |
| `steam_deck_verified_30.tres` | the 30 fps at 800p floor of Valve's Verified review | 33.3 / 49.9 ms | 21.9 / 49.9 ms | 8 ms | ≤ 3 over 66.6 ms |

Both hold video memory to 1024 MB, the GPU's default reserved share, and static memory to 4096 MB,
a quarter of the Deck's shared 16 GB. Why the 60 fps numbers: a p99 of 25 ms lets one frame in a
hundred fall to 40 fps, the Deck's own fallback refresh, and no lower. GPU mean is two thirds of the
frame, which leaves room for spikes. The CPU bar is half the frame: game logic runs in the physics
tick, and a tick over 16.7 ms drops a frame outright. A hitch is a frame longer than two refreshes.
These are one project's numbers. Copy a profile and change it for yours.

### §3.5 — Recording and replaying input

A scene with a controllable body is best played by the inputs a person gave it. Record them once,
then replay them on every run:

```sh
# Play the scene in a window; close it (or wait BUDGET_SECONDS) to save the track.
BUDGET_SCENE=res://levels/forest.tscn BUDGET_TRACK=res://levels/forest_walk.tres \
  godot --resolution 1280x800 --path . --script res://addons/device_budget/record_runner.gd
```

```gdscript
extends BudgetRunner

func _configure() -> void:
	scene_path = "res://levels/forest.tscn"
	var replay: InputReplayDriver = InputReplayDriver.new()
	replay.track = load("res://levels/forest_walk.tres") as InputTrack
	replay.body_node = ^"Player"   # the body whose travel proves the play
	driver = replay
```

- `InputTrack` is a `Resource`: the track's length, every action change (time, action, strength;
  strength 0 is a release), and every frame's summed mouse motion.
- `InputRecorder` polls every action in the `InputMap` once a process frame and keeps a change of at
  least `STRENGTH_STEP`. A press and release inside one frame shows only as
  `Input.is_action_just_pressed()`, so it is kept as a press and a release at the same time. Mouse
  motion arrives as events; feed them to `on_input()` and they are summed per frame.
- `RecordRunner` is the window that records: it plays `BUDGET_SCENE` and saves to `BUDGET_TRACK`
  (`res://input_track.tres` by default) after `BUDGET_SECONDS` or when the window closes. It refuses `--headless`, because there is no one to play,
  and it writes nothing (exit 1) when the window closed with no input recorded, so a run nobody played
  cannot leave an empty track for a replay to fail on.
- `InputReplayDriver` sends the track back through `Input.parse_input_event()`, so `Input.is_action_*`,
  `Input.get_vector()` and `_unhandled_input()` see what they saw when it was recorded. It keys the
  track by wall time, so a slow machine replays the same inputs over the same seconds, and loops the
  track for as long as the run lasts, releasing every held action at the end of each lap. Its premise
  holds that the timed window replayed input and that `body_node`, when set, moved at least
  `min_travel_m`; a body that ignored the input, or a track for a different scene, fails.

What a replay does not promise is the same path. Inputs land on the frame after their time, so frame
pacing shifts each one by up to a frame, and a body that integrates its input drifts a little further
every lap. For a budget run that is enough: the body covers the same ground, under the same load.
Mouse motion is recorded as the `relative` your nodes received, so a project whose stretch mode
scales it scales it the same way on both sides.

`checks/replay_check.gd` proves the round trip on the engine you run, headless. It scripts a walk on
`example/walk.tscn`, records it, replays the track into a fresh copy of the scene, and holds the
replayed walker to the recorded one at four moments, within 0.3 m and 0.05 rad. It also checks that
no action is left held. `example/walk_track.tres` is the track it records (`REPLAY_TRACK` names a path
to save it to), and `example/walk_runner.gd` replays it under the budget:

```sh
godot --headless --path . --script res://addons/device_budget/checks/replay_check.gd
godot --resolution 1280x800 --path . --script res://addons/device_budget/example/walk_runner.gd
```

### §3.6 — Running a suite

`run_suite.sh` runs a runner over several scenes, one windowed process each, and merges their JUnit
reports into `suite.junit.xml`:

```sh
GODOT=/path/to/godot addons/device_budget/run_suite.sh res://levels/forest.tscn res://levels/town.tscn
```

- **On the device or standing in for it.** The board name (`/sys/devices/virtual/dmi/id/product_name`)
  is matched against `DEVICE_BOARDS` (the Steam Deck's `Jupiter` and `Galileo` by default). On the
  device the run takes the default GPU and a CPU scale of 1. Anywhere else it takes the first GPU
  Godot lists as `Integrated` (an integrated GPU is weaker than the Deck's, so a pass there holds on
  the Deck) and the CPU scale in `HOST_CPU_SCALE` (§5). The GPU comes from `godot --verbose`'s
  device list, which is the order `--gpu-index` counts in, probed in a scratch project because the
  list only prints from a windowed run with a main scene. `GPU_INDEX` overrides it.
- **The monitors must be on** (§4.7). A connected monitor that reads `Off` is woken with
  `kscreen-doctor --dpms on` (or `xset dpms force on`); one that stays off stops the suite.
  The check runs before each scene, because monitors sleep again mid-suite.
- **Each scene is its own process** under `timeout` (`TIMEOUT`, 300 s), so a hung or crashed scene
  fails alone. Its log and reports go to `LOGS`; the reports from an earlier run are deleted first,
  so a scene that wrote none cannot pass on stale ones.
- **The merged JUnit** holds each scene's `<testsuite>`. A scene that wrote no report, or exited
  non-zero beside a report with no failure, gets a one-case failing suite naming its exit code (or
  the timeout) and its log.
- **Output**: `PASS` or `FAIL` per scene, then the log lines matching `LINES` (an ERE, `^BUDGET ` by
  default) indented beneath it, in log order.

Exit: the number of failing scenes, at most 124; 125 when the suite could not start (no binary, no
scenes, no integrated GPU, a monitor still off). The script's header lists every variable.

`checks/run_suite_check.sh` proves the script on a fake Godot (`checks/fake_godot.sh`) in seconds,
with no window: the GPU pick, the board, the monitor check, each way a scene can pass or fail, and
the merged JUnit. It needs `python3` to parse the XML.

### §3.7 — Calibration

`calibrate_runner.gd` times a fixed set of small workloads on this machine and compares each one
with the time the same workload took on the device. Those times are the device profile's
`reference_ms`. It prints the CPU scale the budget runs should take, and whether this machine's GPU
is weaker or stronger than the device's:

```sh
godot --resolution 1280x800 --path . --script res://addons/device_budget/calibrate_runner.gd
```

Environment, each name behind `CALIBRATE_`:

- `PROFILE`: the `DeviceProfile` holding the device's `reference_ms` (default `profiles/steam_deck.tres`).
- `SAVE`: a `.tres` path. This machine's medians are written there as a `DeviceProfile`, with
  `reference_estimated = false` and the engine and build stamped on it. Run this on the device to
  make its reference.
- `LABEL`: the saved profile's label (default the CPU name).

**The workloads**, in the order they run:

| Key | What it times | Prices |
|---|---|---|
| `w1_script` | 300,000 GDScript iterations of integer and float maths, static and method calls, packed arrays and a typed dictionary | interpreter speed |
| `w3_2mb` | 1M dependent reads chasing a random cycle through 2 MB | cache latency |
| `w3_64mb` | the same chase through 64 MB | memory latency |
| `w2_physics` | one physics tick: an 800-box pile on a floor, every box kept awake, and 8 characters doing `move_and_slide` through it | physics |
| `w4_render_cpu` | the render thread's CPU time for 10,000 boxes, each with its own material, in a 160×100 viewport | draw-call submission |
| `gpu_fill` | a full-window fragment shader looping 1024 times | GPU fill rate |
| `gpu_vertex` | a 1000×1000-quad plane whose vertex shader loops 64 times | GPU vertex rate |

Each workload runs 5 times; the median is the number, and the slowest and fastest runs give the
range printed beside it. The windowed workloads warm up for 30 frames, then time 60.

**The CPU scale** is device time over this machine's time, per workload. The budget takes the
largest of W1, W2 and both W3 rows, since the device's weakest point is the one that bites. When
those scales spread more than 25% apart (largest over smallest, less one), no one number describes
the CPU: the runner prints the range and holds the top of it. W4 is printed, not used; the render
thread's cost depends on the driver as much as the CPU.

**The GPU gets a verdict, not a scale.** A desktop GPU differs from the device's in bandwidth, cache
and clocks in ways one multiplier cannot carry, so the runner only says which way it leans. It takes
host time over device time for both GPU workloads and judges the smaller ratio, the one most
favourable to this machine:

- at or above 1.1: **weaker** than the device. A GPU pass here is a pass on the device.
- from 0.9 up to 1.1: **about equal**. A pass is marginal evidence.
- below 0.9: **STRONGER**. GPU bars measured here are not evidence for the device.

**The GPU floor.** A weaker or about-equal verdict needs at least 1 ms of host GPU time
(`CalibrationSystem.GPU_FLOOR_MS`) behind the judged ratio; under it the runner prints `PREMISE` and
exits 1. A STRONGER verdict stands at any time. A frame's fixed cost lands in the host time: an
empty 1-iteration fill pass costs 0.205 ms on the 7700X's iGPU and 0.026 ms on an RX 7900 XTX. That
cost only inflates host time, so it can make a fast GPU look weaker, never stronger. The floor is
about five times the iGPU's empty frame. W2 keeps every box awake and W4 draws 10,000 boxes for the
same reason on the CPU side: at 216 resting boxes and 2000 draws both took about 0.5 ms, close
enough to the noise that a Deck run could not separate them.

**Premises.** Every windowed workload must draw at least 95% of its frames (§4.3, §4.7), and the GPU
workloads must run in a 1280×800 window. The window is read from the root's real size;
`get_visible_rect()` reports the content-scaled size under a stretch mode. A premise failure prints
`PREMISE` and exits 1. The runner also warns when the profile's times came from a different engine
version or build type, since a debug build's GDScript is slower than a release export's.

**The shipped Deck reference is an estimate.** No Deck has been measured yet, so
`profiles/steam_deck.tres` holds `reference_estimated = true` and times derived from a Ryzen 7 7700X
with a Radeon iGPU, on a debug build:

- CPU rows: the desktop median × 2.1, the estimate from §5. The CPU scale this prints is therefore
  §5's estimate read back, not a measurement, until the profile is replaced by a run with
  `CALIBRATE_SAVE` on a real Deck.
- GPU rows: the iGPU's median ÷ 2.8, the ratio of the Deck's GPU (1.6 TFLOPS) to that iGPU's
  (0.56). The verdicts it gives are as good as that ratio.

`checks/calibration_check.gd` proves the arithmetic (`CalibrationSystem`) headless: the median, the
scale and its range, the spread, each verdict band at and either side of its boundary, the GPU floor
(STRONGER under it, weaker and about equal not, weaker at it), and the pick of the largest scale.

Exit: 0 when every workload was measured, 1 on a premise failure, 2 under `--headless`.

### §3.8 — Per-tick trace

The CPU bar reads the worst tick of each second (§4.1), so the question a failing run leaves is
"which tick, and what was in it". `TRACE=1` answers it without a profiler build. `BudgetTrace` times
each physics tick from the runner's own `_physics_process`, which the engine calls before any node's,
and stamps marker nodes along the way: one added last at priorities -100000, -1, 0 and +100000. A
tick splits into:

| Column | What |
|---|---|
| `total` | the whole tick, from the runner's `_physics_process` to its next callback |
| `pre` | engine work before the first script: interpolation prepare, physics sync, queries |
| `p-` | scripts below priority 0 |
| `p0` | scripts at priority 0, which is everything left at the default |
| `p+` | scripts above priority 0 |
| `post` | after the last script: navigation, the physics step, the interpolation flush |

A subclass adds a column per node it names, a marker just before the node and one just after it and
its subtree, at its own priority. The column is a slice of whichever band that priority puts it in.
A null node adds no column, so a scene without the node runs as is. A note per tick says what the
game was doing; the runner puts the play phase first.

```gdscript
func _trace_columns(scene: Node) -> Dictionary[String, Node]:
	return {"player": scene.find_child("Player", true, false)}

func _trace_note() -> String:
	return " enemies=%d" % _enemies.size()
```

Only ticks inside the timed window are kept. The report prints the tick count and the total's
percentiles, the mean of every column, then the ten worst ticks by total, by each bracket, by `p-`
and by `post`, each with every column and its note. Times are host milliseconds, not scaled by the
CPU scale. The markers add work to every tick, so read the verdict from a run without them.

It cannot see inside a part: a slow bracket names the node, not the function. A profiler sees inside.

`checks/trace_check.gd` proves the split headless: nodes that stall a known time below, at and above
priority 0 land in `p-`, `p0` and `p+`; a bracketed node's stall lands in its column; a null node
adds no column and leaves no node; the tables print in order; an empty trace says so.

### §3.9 — Pinning the host

A second way to stand in for a device is to make the host more like it, then scale only what is
left. `pin.sh` runs a command on a few physical cores and their SMT siblings, with those cores'
clock capped, and reads back what took effect. Linux only.

```sh
addons/device_budget/pin.sh godot --resolution 1280x800 --path . --script res://...
PIN=1 addons/device_budget/run_suite.sh res://levels/forest.tscn   # the same, for each scene
```

- **Cores.** The `PIN_CORES` highest-numbered physical cores (4 by default, like the Deck) and
  their siblings, from `lscpu`. The script pins itself with `taskset`, so the command and every
  thread it starts inherit the mask, and reads the effective mask back from `/proc`.
- **Clock.** Each pinned CPU's own `scaling_max_freq` is set to `PIN_MHZ` (3500 by default; 0 leaves
  the clock alone), so the rest of the machine keeps its clock. The writes need root: they run under
  `PIN_SUDO` (`sudo -n` by default, empty when already root). The old values go back when the
  command ends, however it ends.
- **The clock is read back, not trusted.** The pinned CPUs are kept busy for `PIN_SPIN` seconds and
  their clock read from `cpuinfo_avg_freq`. Above the cap by more than 3%, the pin refuses: some
  drivers accept the write and ignore it.
- **The state is recorded.** The command sees `DEVICE_BUDGET_PIN`, one line with the effective
  CPUs, the cap, the busy clock range and the boost flag. `run_suite.sh` prints it on its first
  line, calibration on its `host` line, and the JSON report carries it under `env.pin`.

Exit: the command's exit code; 125 when the pin could not be set or did not take effect.

**What a pin changes, and what it cannot.** Godot's processor count ignores the mask, so the engine
still reports every host thread; a worker pool sized from it oversubscribes the pinned cores. Pinning
moves threaded work, contention and handoffs. Work on one thread runs the same on a pinned core as
on any other, so for it a pinned and an unpinned run agree by construction. IPC and cache survive
the pin, so a pinned host still needs a CPU scale, measured by calibration (§3.7) under the same pin.

`checks/pin_check.sh` proves the script on a fake cpu tree, with no root: the cores it picks, the
mask the command runs under, the cap on the pinned CPUs only and put back after a pass, a failure
and a refusal, the refusal when the cap cannot be written or does not take, and `PIN=1` through
`run_suite.sh`.

## §4 — Measurement rules

A budget measured on a run that did not happen as described prices nothing. Each rule here cost a
day or a wrong number before it existed. Each check fails loudly as a `PREMISE` line rather than
letting a run pass quietly, and each is a `<testcase>` in the JUnit report.

### §4.1 — The engine's time monitors are per-second maxima

`Performance.TIME_PHYSICS_PROCESS` and `TIME_PROCESS` are not the last frame's time. The engine
refreshes them once a wall second with the worst value of that second, then starts over. Godot's
class reference does not say so. The runner therefore samples them once a second and skips the first
sample of each window, which carries the second before it.

`checks/second_max_check.gd` proves this on the engine you run. It stalls one physics tick by 30 ms
and watches the monitor change value at most once a second, peak at the stall, hold it and fall back.
Run it after every engine upgrade:

```sh
godot --headless --path . --fixed-fps 60 --script res://addons/device_budget/checks/second_max_check.gd
```

The window must also hold at least `SECONDS − 2` CPU samples. A window that lost its samples cannot
price CPU.

### §4.2 — The CPU bar reads the physics tick, not the process step

The process step absorbs the wait on a busy GPU. With the GPU overloaded, the process step's worst
per second read 32 ms while the physics tick read 3 ms, so a CPU bar built on the process step fails
for GPU load. The CPU bar is the mean of the per-second worst physics ticks, times the CPU scale. The
process step is printed and never held.

If your game's logic runs in `_process` rather than `_physics_process`, this bar does not see it;
the FRAME bars do.

### §4.3 — At least 95% of timed frames must be drawn

With the monitors asleep, the compositor stops sending the window frame callbacks. Godot reports the
window minimized and draws nothing while physics, scripts and uploads run on. One run read 2 frames
drawn against 2199 process frames. Every column then lies: FRAME reads the undrawn loop's pacing,
GPU repeats the last measured render, and the renderer can stall on staging buffers that recycle only
when frames are drawn. The runner counts `Engine.get_frames_drawn()` across the window and requires
`min_drawn` of the timed frames.

Before a run on a desktop, check the screens are on. On Linux, read `/sys/class/drm/*/status` for
`connected` and then the same connector's `dpms`.

### §4.4 — Warm-up is reported apart

The first `warm_frames` frames (180 by default) are where pipelines compile. They are printed as their
own line (the worst warm-up frame and its hitches) and kept out of the bars. A cold first-run hitch
mostly comes from the driver's pipeline compile, not from Godot. To see it on Mesa, set
`MESA_SHADER_CACHE_DISABLE=true`; clearing only Godot's own shader cache does not bring it back.

### §4.5 — The clock must be free

A fixed clock (`--fixed-fps`, vsync, `Engine.max_fps`) makes every frame report the pin. The runner
turns vsync off and sets `max_fps` to 0, then checks both. `--fixed-fps` is consumed before
`OS.get_cmdline_args()` sees it, so the only proof is the measured deltas: the run fails if every
frame's delta was one value. The window's size must also equal the profile's `resolution`. Pass
`--resolution` to match it.

### §4.6 — The build is reported beside the verdict

Printed, not held: the engine version, whether it is a debug build, the worker-pool size against the
device's hardware threads, and a CPU scale below 1. A debug or editor build runs scripts slower than
an exported release build, and a profiling build adds its own cost. `MEMORY static` is not available
in release builds, so there the bar is reported as skipped rather than as 0 MB passing.

Cap `threading/worker_pool/max_threads` at the device's threads (8 on a Deck) when you price for it.
A desktop's larger pool hides contention, and Jolt, among others, runs its step on the pool.

### §4.7 — The monitors must be on

With every monitor off (DPMS), Godot reports the window minimized and stops drawing it: the frame
count stalls while physics runs on, frame and GPU times settle on one value in every scene, and
rendering stalls appear that a lit screen never shows. §4.3 fails such a run, but only after it has
run. `run_suite.sh` checks each connected connector's `/sys/class/drm/card*-*/dpms` before each scene
and wakes the monitors that read `Off`. Monitors can sleep again between runs, so a runner started
by hand needs the same check.

## §5 — The CPU scale is an estimate

Off the device, CPU time is multiplied by `CPU_SCALE`. The Deck profile's 2.1 is an estimate for one
desktop CPU (a Ryzen 7 7700X), not a measurement. It is clock (5.4 against 3.5 GHz, 1.54×) times IPC
(Zen 2 to Zen 4 by AMD's figures, 1.34×). Cinebench 2024 single-core gives 1.93 for the same pair.

The estimate ignores the Deck's 4 cores, its 4 MB L3, its memory latency and the 15 W it shares
between CPU and GPU. Each of those makes the Deck slower. Work out your own scale for your CPU from
published single-thread results, or better, run one scene on both machines and divide.
`cpu_scale_estimated` on the `DeviceProfile` records which kind of number it holds.

## §6 — Reports

- **stdout**: one line per column (frame, gpu, cpu, process), the five worst frames with their
  driver phase, memory, drawn frames, the driver's lines, the build, and `PASS` or `FAIL`. Every
  line starts with `line_prefix`, so a suite script can grep them.
- **JSON**, one file per scene under `REPORT_DIR`, versioned by `schema`: `env` (engine, build,
  binary, OS, board, CPU, threads, pool, GPU, audio device, window), the `profile` used, each
  `premise` check, each bar, the worst frames, the ramp, and every timed window's raw samples.
- **JUnit XML**, one `<testsuite>` per scene, one `<testcase>` per premise check and per bar, for CI.

Exit codes: 0 on a pass, 1 on any failure, 2 under `--headless`.

## §7 — Offline replay

`BudgetSystem` is the pure half: a `BudgetWindow` of samples in; statistics, bar verdicts and report
lines out. It has no scene tree, so it runs headless. `BudgetSystem.window_from_json()` reads a
window back from a report's `windows` array, so a recorded run can be re-judged against a changed
profile, or a change to the arithmetic can be proved against old runs, without playing anything.

## §8 — Pricing a device you do not have

The GPU bars are only as good as the GPU the run used. A desktop discrete GPU passes almost anything.
An integrated GPU of a similar class is a closer stand-in: on Linux, pick it with Godot's
`--gpu-index`. Read the GPU name off the report's first line, and treat a pass on a stronger GPU as
saying nothing about the device's GPU.

On the device itself, use `CPU_SCALE=1` and a release export if you can.

## §9 — License

MIT. See `LICENSE`.
