# godot-device-budget

A Godot 4 addon that holds a played scene to a frame budget for a target device, such as a Steam
Deck, and fails loudly when the run did not happen as described. GDScript only.

The addon lives in [`addons/device_budget/`](addons/device_budget/); its
[README](addons/device_budget/README.md) is the documentation. This repository is a minimal host
project around it, so a clone runs the example directly:

```sh
godot --headless --import --path .
godot --resolution 1280x800 --path . --script res://addons/device_budget/example/example_runner.gd
```

To use it in your own project, copy `addons/device_budget/` in.

MIT licence; see [LICENSE](LICENSE).
