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
