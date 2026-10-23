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
└── images/                   optional: what the notes show
```

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
  "notes": "notes.txt"
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
