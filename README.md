# Wisualizer

An Apple Vision Pro teaching app (GaTech VIP): open an Ansys ZIP and play the
GLB's scenes as frames in a 3D volume. The same scenes run on desktop with an
orbit camera, and are meant to run on Quest later.

## Run

Use the toolchain snapshot in `~/Developer/wiz-toolchain/` (editor app and
GodotRealityKit addon; see its README). Copy its `addons/GodotRealityKit` into
`addons/`; it is local and not tracked. Press F5 for the desktop view, or export
with the `visionOS` preset and run the generated Xcode project on Apple Vision Pro
or the visionOS Simulator.

## Code

| Path | Purpose |
| --- | --- |
| `app/main.gd` | ZIP import, frame playback, field box, fit to bounds |
| `app/main.tscn` | Controls, native file picker and the model window |
| `app/model.tscn` | Model window: content, field box and its `SpatialVolume3D` |
| `addons/spatial/` | `SpatialVolume3D`: a RealityKit volume on visionOS, an orbit camera elsewhere |

Shared scenes use `Window` and `SpatialVolume3D` only; platform differences stay
inside `addons/spatial/`.
