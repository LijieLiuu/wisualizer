# Wisualizer

An Apple Vision Pro teaching app (GaTech VIP): open an Ansys ZIP and play the
GLB's scenes as frames in a 3D volume. The same scenes run on desktop with an
orbit camera, and are meant to run on Quest later.

## Run

Wisualizer needs a custom Godot 4.7 build and the GodotRealityKit plugin, both
from the `arvr4mp` branch of these forks:

- Engine: [zilongpa/godot](https://github.com/zilongpa/godot/tree/arvr4mp).
  Build the macOS editor and the visionOS export template with SCons.
- Plugin: [zilongpa/plugins-for-godot](https://github.com/zilongpa/plugins-for-godot/tree/arvr4mp).
  Build it with SCons as in its `godotrealitykit/documentation/Building.md`,
  then copy `godotrealitykit/out/addons/GodotRealityKit` into this project's
  `addons/`. The addon is local and not tracked; it also supplies the visionOS
  export template.

Open the project in that editor and press F5 for the desktop view, or export
with the `visionOS` preset and run the generated Xcode project on Apple Vision
Pro or the visionOS Simulator (set your signing team in Xcode).

## Use

The first window is the library. **Add ZIP** copies a ZIP into it and opens it;
pick one to open it again, or delete it from the library (the original file
stays). Each ZIP opens as its own volume, so several can be open at once. A ZIP
with a `notes.txt` (Godot BBCode) shows its notes beside the volume.

Resize the volume from its bottom corners; marks there show where when it
opens. The bar below it plays, pauses and scrubs the frames, and shows or hides
the notes and the options (speed, field box).

## Code

| Path | Purpose |
| --- | --- |
| `app/launcher.gd`, `app/launcher.tscn` | Library: add, open and delete ZIPs |
| `app/document.gd`, `app/document.tscn` | One opened ZIP: volume, notes, controls and options ornaments |
| `app/resize_hint.gd` | Corner marks that show the volume can be resized |
| `app/icons/` | Button icons ([IconPark](https://iconpark.oceanengine.com/)) |
| `addons/spatial/` | `SpatialVolume3D`: a RealityKit volume on visionOS, an orbit camera elsewhere |

Shared scenes use `Window` and `SpatialVolume3D` only; platform differences stay
inside `addons/spatial/`. Deleting asks with the system alert where the platform
has one (`DisplayServer.dialog_show`).
