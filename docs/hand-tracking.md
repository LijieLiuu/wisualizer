# Continuous finger tracking

## Supported build

The continuous hand API was verified against these exact upstream revisions:

| Component | Revision |
| --- | --- |
| [Godot engine](https://github.com/zilongpa/godot/commit/0a8f8c79179b6db19ce865b97331fbe7ca27d280) | `0a8f8c79179b6db19ce865b97331fbe7ca27d280` |
| [GodotRealityKit plugin](https://github.com/zilongpa/plugins-for-godot/commit/fbfdaaeddd5899bfcae109eecbed253937c84aa4) | `fbfdaaeddd5899bfcae109eecbed253937c84aa4` |
| godot-cpp (plugin's `deps.conf`) | `6c9ee5d7ea2d94051968c4c048309eb6b3b04b5d` |

Apply this repository's [native patch](../patches/godotrealitykit-hand-tracking.patch)
**before building the plugin**. The application requires its
`RealityKitHandTracking.get_api_revision() == 2` capability marker and the pinned
engine hash. To upgrade from revision 1, apply the current patch in a fresh
checkout of the pinned plugin and rebuild the addon using the steps below.
Older addons leave **Track fingers…** disabled. Joint positions come from
Godot's standard `XRHandTracker` API.

Use a separate plugin checkout so an existing toolchain remains available:

```sh
# Run from the Wisualizer repository; choose an unused path for the clone.
WISUALIZER_ROOT="$PWD"
git clone --branch arvr4mp https://github.com/zilongpa/plugins-for-godot.git ../plugins-handtracking
git -C ../plugins-handtracking checkout --detach fbfdaaeddd5899bfcae109eecbed253937c84aa4
python3 tools/apply_hand_tracking_patch.py ../plugins-handtracking --check
python3 tools/apply_hand_tracking_patch.py ../plugins-handtracking
cd ../plugins-handtracking/godotrealitykit
scons config=debug
# Install into the project's local addon directory after backing up any old addon.
ditto out/addons/GodotRealityKit "$WISUALIZER_ROOT/addons/GodotRealityKit"
```

Follow the plugin's [build prerequisites](https://github.com/zilongpa/plugins-for-godot/blob/fbfdaaeddd5899bfcae109eecbed253937c84aa4/godotrealitykit/documentation/Building.md):
Xcode with the visionOS SDK, Metal toolchain, SCons and Python. Its pinned
`deps.conf` builds the matching engine and godot-cpp, including device and
Simulator slices. If building the engine separately, pass the plugin's
`scripts/build/swift-frontend-wrapper.sh` as `SWIFT_FRONTEND` for visionOS;
it supplies the SwiftUI macro plugin paths required by newer Xcode toolchains.
The patch installer rejects other plugin revisions and edits to its target
files; repeating it on the exact applied patch is harmless.

Open the project using the resulting custom editor, import resources, and use
**Export Project → visionOS** with **Export With Debug** enabled. The debug addon
contains the matching engine template. Release export requires separately
building and installing `scons config=release`; a debug-only addon is insufficient.
Binaries, SDKs, generated Xcode projects and signing settings stay local.

## Using the model's immersive space

Open a model with a scalar field on Vision Pro and choose **Options → Track
fingers…**. This enters the model's immersive space or uses it if already open.
The model keeps its drag handle, rotation, field picker, playback controls and
fingertip sound. The hand controls appear below the field picker in Options.
Choose **Track fingers…** again to close those controls. The library's **Settings**
window controls debug markers and the sounds under the two index fingers.

Select a hand and fingertip and move it into the field. Choose **Pin A** or
**Pin B** to keep its current position in field coordinates. Each click
samples the selected finger again. Moving the model, changing playback time
or briefly losing tracking preserves the two locations. The readout reports
the cell and value at each location and computes **B − A** when both contain
data. Switching to a different field clears the previous pair.

Open **Inspect…** to chart those points over the model timeline, export a
CSV, or save the positions for the same ZIP and model. Other volumes from
the ZIP follow the shared playback clock and keep their own probes.

Apple provides ARKit hand data in a [Full Space](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data).
The application requests hand-tracking permission through
`NSHandsTrackingUsageDescription`. If the selected hand or joint is
unavailable, fingertip placement is disabled. The inspector can also place
probes by cell index. Use the model's immersive control to return to its
ordinary volume.

## Coordinates

GodotRealityKit publishes the left and right hands through the standard
`XRHandTracker` API. Joint coordinates already include the hand anchor.
The volume backend maps the joint into the model window's world. The selected
field's inverse global transform maps the resulting point into its unit cube,
which includes the lower faces and excludes the upper faces. A/B locations
are stored in that cube so they follow rotations, translations and changes
of scale. The addon exposes tracking flags for individual joints and treats
the derived palm separately. Fingertip placement uses only tracked, valid,
finite positions. A sheared field is unavailable for hand placement because
the native renderer cannot preserve its transform.

## Tracking loss and validation

The native patch consumes `anchorUpdates` and caches each hand independently.
It preserves per-joint `isTracked` and rejects nonfinite poses. Before reading
a hand, the workbench calls `is_hand_sample_fresh(window_id, hand)` (0 for
left, 1 for right). This checks the active view and the ARKit source time
of the pose published to that hand's Godot tracker. A sample older than
0.25 seconds is unavailable even if ARKit has delivered a newer anchor that
the renderer has yet to publish. The same check protects Pin A, Pin B and
the live fingertip readout between periodic cleanup ticks. Each native view has its own ownership
identity, so delayed cleanup or updates from an old view cannot alter a new
view's global trackers. Hosts rejected before presentation are also cleaned up.
Loss, provider failure, permission denial, suspension and window closure clear
tracking flags and the default pose. Session tasks are canceled on exit. A failed
provider is retried only after re-entering the space or an inactive/active
transition. The application immediately hides invalid joints and disables
sampling; committed field positions remain separate from live hand data.

The timestamp comparison uses `CACurrentMediaTime()`. Apple specifies mach
absolute seconds for [hand-anchor query times](https://developer.apple.com/documentation/arkit/handtrackingprovider/handanchors(at:))
and the [QuartzCore clock](https://developer.apple.com/documentation/quartzcore/cacurrentmediatime()).
Using that same epoch for `AnchorUpdate.timestamp` is an inference from the
hand-tracking API contract; confirm timestamp freshness on the physical device.

The [test commands](../README.md#tests) cover joint validity, partial hands,
coordinate transforms, tracking loss and recovery, and fresh pin sampling.
Integration fixtures exercise the drag handle, stereo sound, joint markers,
per-model history, shared playback, held source frames and window cleanup.
Patch installer tests use local Git fixtures and run offline.

Desktop fixtures verify application behavior with synthetic joint positions.
Native compilation and unsigned export validate the integration but do not
establish physical hand alignment, permission behavior or headset usability.
Before a device demo, verify consent/denial, each fingertip on both hands,
occlusion and reacquisition, the scale and reach of the field, pinning with the
opposite hand, backgrounding, and closing/reopening the space on a Vision Pro.
