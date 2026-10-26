# ZIP format

What Wisualizer opens is a ZIP with a `meta.json` at its root that says where
everything is. Nothing is found by guessing at file names, sizes or contents,
and every path in `meta.json` is relative to the ZIP's root.

```
hall-sensor.zip
├── meta.json
├── models/
│   ├── sensor.glb            a model that doesn't change: one GLB
│   └── field-lines/          a model that does: a folder, one GLB per frame
│       ├── 0001.glb
│       └── …
├── fields/
│   └── B/                    a field: a folder, one brick per frame
│       ├── 0001.bin
│       └── …
├── notes.txt                 optional
├── images/                   optional: what the notes show
└── attachments/              optional: vector/source files kept unchanged
```

The desktop build makes and edits these ZIPs in a workspace; see the README.
It copies GLBs and bricks into the ZIP as they are.

## meta.json

```json
{
  "title": "Hall sensor",
  "frames": [{"time": 0.0}, {"time": 1.0}],
  "models": [
    {"name": "Sensor", "path": "models/sensor.glb"},
    {"name": "Field lines", "path": "models/field-lines"}
  ],
  "fields": [
    {
      "name": "B",
      "quantity": "Magnetic flux density",
      "unit": "T",
      "range": [0.0000938, 0.113],
      "cells": [128, 128, 128],
      "box": {"origin": [-40, -40, -40], "size": [80, 80, 80]},
      "path": "fields/B"
    }
  ],
  "field": "B",
  "notes": "notes.txt",
  "attachments": ["attachments/velocity.csv", "attachments/readme.txt"]
}
```

| Key | Meaning |
| --- | --- |
| `title` | Shown as the volume's title. |
| `frames` | The timeline. `time` is the solver time; frames play in this order. |
| `models` | The geometry, all shown together in one volume, each one with a switch. A model's `path` is a GLB, shown at every frame, or a folder of GLBs, one per frame. |
| `fields` | Values on a regular grid, which the debug view shows and controllers feel. |
| `field` | Optional. The name of the field shown first; otherwise the first one. |
| `notes` | Optional. The notes, in Godot BBCode; see the README. |
| `attachments` | Optional list of archive-relative file paths. Supporting data is preserved as bytes; it is not automatically interpreted as a model or field. |

### Models

Each GLB is an ordinary glTF binary in the model's units, which every model
and field in the ZIP shares. A model that is a folder is loaded a few frames
at a time while it plays, so the ZIP needn't fit in memory all at once. A
folder's files, sorted by name, are the frames in order, and there are as
many as there are frames. Models are listed, and switched, in the order of
`models`.

### Fields

| Key | Meaning |
| --- | --- |
| `name` | Short, such as `B`; shown in the field picker. |
| `quantity`, `unit` | Optional, shown with values, such as `0.067 T`. |
| `range` | The values the bytes span: byte 1 is `range[0]`, byte 255 is `range[1]`, linearly. Byte 0 is a cell with no value. |
| `cells` | The grid's size, in cells along x, y and z. |
| `box` | Where the grid is, in model units: `origin` is its corner, `size` its extent. Optional `axes`, three unit vectors, turn it; they default to x, y and z. |
| `path` | A folder of bricks, one per frame, sorted by name like a model's. Each brick is `cells` bytes in all, x fastest, then y, then z. |

### Supporting files

The workspace's **Files** page accepts readable files smaller than 2 GiB each, including EnSight
source data, CSV/TXT vector values, binary vector files, and additional notes.
New files are stored under `attachments/` with their original filenames.
An EnSight header and its referenced data file must both be selected when
including the original source pair; **Fields** remains the import path for
supported scalar byte bricks that the app displays.

A vector dataset has no universal file schema. Including it in `attachments`
preserves its original representation. It does not define how positions,
components, units, or time steps should be parsed or rendered. SVG vector
images remain supported through **Images**.

All listed attachments must exist. File paths must be relative to the ZIP,
without absolute paths, parent-directory segments, backslashes, or duplicate
names that differ only in case. The editor rejects names that would conflict
with a model, field, image, notes file, or another attachment. A batch with an
unreadable source or duplicate name leaves the existing attachment list intact.

On opening an older ZIP, the editor also retains entries not used by its
manifest as supporting files and lists them on **Files**. Removing an entry
there omits it from the next save. Existing attachment paths and the notes'
location are retained so relative references survive editing. The next save
records the retained files in `attachments`. Readers that ignore this optional
field can continue to open the models, fields and notes.

### Writing a package

Disk files are copied in chunks. ZIP source entries use Godot's ZIP reader,
which reads a complete entry into memory. Every file must be smaller than
2 GiB; practical memory limits may be lower. Directory entries are recognized
by their ZIP attributes, including directories without a trailing slash.
Read lengths are checked against the ZIP directory, so a failed read of a
nonempty source cannot silently replace it with an empty file.
Temporary output is created beside the destination with a unique name. Every
read and write must succeed, the archive must close successfully, and its
manifest must reopen before it replaces the destination. Failed replacement
restores the source reader so the current draft can be corrected and retried.
The previous ZIP is never explicitly deleted before replacement. Save As changes
the editor's working target only after a successful save.
