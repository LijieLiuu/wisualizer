# Wisualizer

An Apple Vision Pro teaching app (GaTech VIP): open a ZIP of Ansys EnSight
results and play each of its models in a 3D volume of its own, with notes
beside them. The same
scenes run on desktop with an orbit camera, where a workspace also makes the
ZIPs, and are meant to run on Quest later.

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

For continuous fingertip placement of A/B probes, build the plugin with the
[hand-tracking patch](docs/hand-tracking.md).

Open the project in that editor and press F5 for the desktop view, or export
with the `visionOS` preset and run the generated Xcode project on Apple Vision
Pro or the visionOS Simulator (set your signing team in Xcode).

The `Windows` preset exports the desktop view as one `.exe`, without
GodotRealityKit. Its template has to come from the same engine build, as the
notes' formulas need its MathJax module. On a Mac, cross-compile it with
MinGW (`brew install mingw-w64`):

```sh
scons platform=windows target=template_release arch=x86_64 use_mingw=yes d3d12=no accesskit=no
```

and copy (or link) `bin/godot.windows.template_release.x86_64.exe` into the
editor's export templates as `4.7.dev/windows_release_x86_64.exe`.

## Use

The first window is the library. **Open…** opens a ZIP, after asking whether
to add it to the library, which keeps a copy to open again later; pick one
there to open it again, or delete it from the library (the original file
stays). Each model opens in its own volume, so several can be open at once. A
ZIP with notes shows them beside the volume; see [ZIPs](#zips). Dots mark
the points a ZIP has labels for: bring a controller to one, or the pointer on a
desktop, to read it. On visionOS, tap a dot (or click it in the simulator) to
show its text; tap the same dot again to hide it, or another dot to switch.

Resize the volume from its bottom corners; marks there show where when it
opens. On Apple Vision Pro, pinch and drag the model to turn it, like Apple's
globe: sideways turns it about the vertical, up and down tilts it, and the tilt
springs back when you let go. The volume makes room for it to turn any way. On
desktop, drag to orbit the view. The bar below it plays, pauses and scrubs the
frames, and shows or hides the notes and the options (speed, parts, labels,
field); playback starts over after the last frame. **Settings** in the library
turns on the debug view and sets how the field sounds under a fingertip. With a keyboard, Space plays
or pauses and the arrow keys step a frame.

### Inspecting a scalar field

On Vision Pro with the patched addon, open **Options → Track fingers…**.
The controls use the model's existing immersive space, along with its drag
handle and fingertip sounds. Select a hand and fingertip, move it into the
selected field, and choose **Pin A** or **Pin B**.
The committed locations follow the field when the model moves. **B − A**
uses the physical values in the selected field's units. Missing cells show
**No data** and a measured zero remains a value.

In the shared window, **Probe** also supports placing A or B by pinching the
field box, dragging and releasing inside it. On desktop or Vision Pro, open
**Inspect…** and enter a cell's zero-based x, y and z indices to set a
location directly.

**Analyze** reads the current model's frames at the committed locations.
Selecting a point in the chart seeks the ZIP's shared clock. **Export CSV…**
writes the displayed time, source brick and its time, A and B readings and
signed difference. A field with fewer steps than the model can use the same
brick for several displayed frames. **Save points…** and **Load points…**
restore placements for the same source and model. See the [hand controls and
build instructions](docs/hand-tracking.md).

## ZIPs

A ZIP has a `meta.json` that says where its models, notes and images are;
[docs/zip-format.md](docs/zip-format.md) describes it. Each model opens in a
volume of its own, so several can sit side by side. A model has parts, its
GLBs, and fields, its bricks; a part or field that changes has a file per
time step, and plays a few steps at a time without the whole ZIP in memory.
A model's timeline is the solver times its files have: nothing lists frames.

### Making one

The desktop build makes ZIPs in a workspace: **New…** in the library starts an
empty one, and the pencil beside a ZIP opens it there. The sidebar lists the
models, with the one picked opened up to its pages, and **+ Add model**; below
them are the notes and images every model shares. A model's own row shows its
name, its order and what it holds, and every page of it is headed with its
name.

- **Parts**: **Import GLBs…** takes the GLBs EnSight exports. Pick all of a
  part's GLBs, one per time step, named alike but for the step's number, and
  they become a part that changes at their solver times; a GLB on its own
  becomes one that doesn't. Rename and reorder them here.
- **Fields**: **Import bricks…** takes the brick headers EnSight writes beside
  each brick (`*_meta0001` and so on), one field per variable, each brick at
  its solver time: the steps can come in any order, a few at a time. Set the
  name, quantity, unit and range. Imports keep the header's spatial box.
  Use the fit control to align the field visually when its coordinates require it.
- **Labels**: text at points in the volume. **Add label** puts one at the
  parts' center; type its text and its point, in the model's units, which the
  page shows the extent of. A radius and the frames it shows at are optional.
- **Timeline**: the model's frames, one for each solver time its GLBs and
  bricks have, and which of them has a step at each. There is nothing to set.
- **Notes**: BBCode on the left, as it will look on the right, beside the
  first model's volume.
- **Images**: what the notes show. **Insert into notes** adds an `[img]` tag.
- **Files**: include supporting CSV, vector or other data as attachments.
  **Import TXT…** on the notes page imports UTF-8 text. The field statistics
  export uses the current draft, including unsaved edits.

**Save** writes the ZIP into the library, **Save As…** somewhere else, and
**Preview** saves and opens it.

### Notes

In `notes.txt`, `[img]images/flow.png[/img]` shows an image from the ZIP, with
any of Godot's `[img]` options, such as `[img width=320]…[/img]`. Paths are
relative to `notes.txt`. PNG, JPEG, WebP and SVG work.

Formulas are TeX: `[math]\frac{\partial u}{\partial t}[/math]` sets one in the
line, on the text's baseline, and `[math=display]…[/math]` on a line of its own.
MathJax typesets them, with all of its packages, such as `ams`, `physics` and
`mhchem`. A formula that doesn't typeset shows its source and what's wrong.
Short formulas can also be plain text, such as `Re = ρUD/μ`.

SVG images, such as formulas exported from LaTeX, stay sharp at any size, and
their `currentColor` takes the notes' text color.

`[url=frame:9]frame 9[/url]` is a link that pauses the first model on frame 9.

## Code

| Path | Purpose |
| --- | --- |
| `app/launcher.gd`, `app/launcher.tscn` | Library: add, make, edit, open and delete ZIPs |
| `app/meta.gd` | Reads a ZIP through its `meta.json` |
| `app/workspace.gd`, `app/workspace.tscn` | Desktop editor for a ZIP: models, their parts, fields and labels, images and notes |
| `app/draft.gd` | What the workspace edits, and saves as a ZIP |
| `app/glb_info.gd`, `app/bov.gd` | Read what the workspace needs from a GLB's JSON and an EnSight brick header |
| `app/native_dialogs.gd` | Whether alerts and file pickers are the system's or Godot's |
| `app/document.gd`, `app/document.tscn` | One model of an opened ZIP: volume, notes, controls and options ornaments |
| `app/model_frames.gd` | One part, loaded a few frames at a time |
| `app/labels.gd` | A volume's labels: a dot at each point, and its text while a controller or the pointer is near |
| `app/resize_hint.gd` | Corner marks that show the volume can be resized |
| `app/icons/` | Button icons ([IconPark](https://iconpark.oceanengine.com/)) |
| `ui/` | The app's look: `theme.tres` (SwiftUI-style buttons, sliders and scroll bars), the Inter font it uses on every platform, and custom controls such as `Scrubber` |
| `branding/` | App icon layers, the rounded macOS icon, boot splash and `generate.gd`, which draws them from `branding/assets/` (`godot --path . -s branding/generate.gd`) |
| `addons/spatial/` | `SpatialVolume3D`: a RealityKit volume on visionOS, an orbit camera elsewhere |

Shared scenes use `Window` and `SpatialVolume3D` only; platform differences stay
inside `addons/spatial/`. On desktop, a window's ornaments are drawn inside it.
Alerts and file pickers are the system's where the platform has them; run with
`-- --godot-dialogs` to try Godot's own, which other platforms get.


## Tests

Import the project with the matching editor. Run the desktop suites with the
revision 2 addon installed to exercise the native event types as well.

```sh
for script in tests/*_test.gd; do
  "$WISUALIZER_GODOT" --headless --path . --script "res://$script" -- --godot-dialogs || exit 1
done
python3 -m unittest discover -s tests -p 'test_hand_tracking_*.py' -v
```
