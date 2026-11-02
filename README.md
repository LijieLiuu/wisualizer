# Wisualizer

An Apple Vision Pro teaching app (GaTech VIP): open a ZIP of Ansys EnSight
results and play its frames in a 3D volume, with notes beside it. The same
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

Open the project in that editor and press F5 for the desktop view, or export
with the `visionOS` preset and run the generated Xcode project on Apple Vision
Pro or the visionOS Simulator (set your signing team in Xcode).

## Use

The first window is the library. **Open…** opens a ZIP, after asking whether
to add it to the library, which keeps a copy to open again later; pick one
there to open it again, or delete it from the library (the original file
stays). Each ZIP opens as its own volume, so several can be open at once. A
ZIP with notes shows them beside the volume; see [ZIPs](#zips).

Resize the volume from its bottom corners; marks there show where when it
opens. On Apple Vision Pro, pinch and drag the model to turn it, like Apple's
globe: sideways turns it about the vertical, up and down tilts it, and the
tilt springs back when you let go. The volume makes room for it to turn any
way, and **Reset** in the options turns it back. On desktop, drag to orbit the view. The bar below it plays, pauses and scrubs the frames, and shows or hides
the notes and the options (speed, loop, debug view). With a keyboard, Space
plays or pauses and the arrow keys step a frame.

## ZIPs

A ZIP has a `meta.json` that says where its models, fields, notes and images
are; [docs/zip-format.md](docs/zip-format.md) describes it. A model is one
GLB, or a folder with a GLB per frame, which plays a few frames at a time
without the whole ZIP in memory. A ZIP can have several models and several
fields.

### Making one

The desktop build makes ZIPs in a workspace: **New…** in the library starts an
empty one, and the pencil beside a ZIP opens it there.

- **Frames**: the timeline. Importing GLBs or bricks with solver times fills
  it in when it's empty; times can be changed, and frames added or removed.
- **Models**: **Import GLBs…** takes the GLBs EnSight exports. Pick all of a
  model's GLBs, one per time step, named alike but for the step's number,
  and they become a model that changes; a GLB on its own becomes one that
  doesn't. Rename and reorder them here.
- **Fields**: **Import bricks…** takes the brick headers EnSight writes beside
  each brick (`*_meta0001` and so on), one field per variable. Set the name,
  quantity, unit and range. Imports preserve the header's spatial box.
  **Fit to models** is an optional visual alignment heuristic; check the source
  coordinate system before using it.
- **Images**: what the notes show. **Insert into notes** adds an `[img]` tag.
- **Files**: **Import files…** includes vector data, CSV, TXT, or other supporting
  files unchanged. Each file must be smaller than 2 GiB. Review their names
  and remove any you do not need. These files travel with the ZIP; use **Models**, **Fields**, or **Images** for content
  the viewer should display.
- **Notes**: BBCode on the left, as it will look on the right. **Import TXT…**
  reads a UTF-8 text file, with a choice to replace or append when notes already
  exist. A UTF-8 byte-order mark is accepted; other encodings report an error.

**Save** writes the ZIP into the library, **Save As…** somewhere else, and
**Preview** saves and opens it. Importing a single static GLB also creates its
first frame, so a model with notes and supporting files can be saved directly.
A playable package needs at least one GLB and one frame. Files such as scientific
vectors are preserved without converting or interpreting their values.

Existing and newly added supporting files are retained after reopening and
saving again, including files not listed by older package manifests. Duplicate
names are rejected without overwriting files. Saving locks the editor until it
finishes and replaces the destination only after writing a complete valid ZIP;
a failed save keeps the previous package and the current edits.

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

`[url=frame:9]frame 9[/url]` is a link that pauses on frame 9.

Shared scenes use `Window` and `SpatialVolume3D` only; platform differences stay
inside `addons/spatial/`. On desktop, a window's ornaments are drawn inside it.
Alerts and file pickers are the system's where the platform has them; run with
`-- --godot-dialogs` to try Godot's own, which other platforms get.

## Scalar analysis

On **Fields**, use **Export statistics CSV…** to export the current draft,
including unsaved edits, without saving or changing its ZIP. Each field/frame
produces valid and missing sample counts, minimum, maximum and mean, with its
name, quantity, declared unit, source and recorded `solver_time`. Times retain
their frame order; no time unit is assumed. Byte 0 means missing, while a valid
sample that decodes to numerical zero is included. All-missing frames have blank
min/max/mean. These are summaries of quantized exported scalar samples, not
estimates of solver accuracy or volume integrals.

BOV imports are applied only when the whole batch passes validation. Dimensions,
payload lengths, value ranges and spatial boxes must be valid and consistent
within a field. With an existing timeline, solver times must match a unique frame
exactly; unmatched times and occupied field/frame slots are rejected. Add or edit
frame times before importing. The editor never silently replaces a frame's data.
CSV export refuses to replace source files and keeps previous output on failure.

## Tests

Use the custom Godot editor described above and import project resources first.
Fixtures run in temporary directories, outside the library:

```sh
for test in zip_files zip_packaging scalar_validation scalar_import field_analysis; do
  "$WISUALIZER_GODOT" --headless --path . --script "res://tests/${test}_test.gd"
done
"$WISUALIZER_GODOT" --headless --path . --script res://tests/zip_workspace_test.gd -- --godot-dialogs
```

Checks cover ZIP round trips and failed writes, malformed scalar data, import
rollback, independent numerical examples, CSV preservation and workspace actions.
