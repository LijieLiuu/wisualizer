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
`RealityKitHandTracking.get_api_revision() == 1` capability marker and the pinned
engine hash. An older addon, or the unpatched upstream addon, leaves **Track
fingers…** disabled with an explanation. The marker is only a compatibility
check; actual hand data still comes from Godot's standard `XRHandTracker` API.

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

## Interaction and permission

On Vision Pro, open a scalar-field document and choose **Options → Track
fingers…**. This opens a mixed immersive space and a separate controls window.
Only one document can own this space at a time. Opening it pauses playback and
ends the shared-volume probe gesture; existing committed A/B locations remain.
Sampling starts only after the addon confirms that visionOS actually presented
the space. If opening does not finish within 15 active seconds, the workbench
closes with a retry message. This also handles rapid reopening while visionOS
is still dismissing the previous space.

Apple exposes ARKit hand data in a [Full Space](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data),
which hides other applications. Mixed immersion keeps the surroundings visible.
The project enables `xr/visionos/enable_hand_tracking` and supplies an explicit
`NSHandsTrackingUsageDescription` in its export preset. Allow hand tracking when
visionOS asks. If unavailable or denied, the controls show no tracked hands and
disable pinning. **Return to windows** remains available; existing gesture probes
and manual cell selection can be used in the shared windows.

- Select the left or right hand and any fingertip. Both tracked skeletons remain
  visible, with the selected finger highlighted.
- Move that fingertip inside the field box to read the current cell's scalar
  value. Missing cells show **No data**; a valid physical zero remains a value.
- Use the other hand to choose **Pin A** or **Pin B**. Each click reads the current
  joint again. Merely moving a finger does not change committed locations or
  invalidate an existing history analysis.
- **History and export…** opens the existing inspector for frame histories, CSV
  export and saved probe positions. Playback controls inspect the same field
  locations in other frames.
- Adjust the field extent, rotate it, or choose **Move near fingertip** to bring
  it within reach. These controls move the field independently of the tracked
  hands. **Reset placement** restores its initial position.
- **Return to windows**, closing either hand-inspection window, or closing the
  document stops the workbench. Returning to windows preserves committed points.

## API and coordinate contract

The upstream [HandAnchors provider](https://github.com/zilongpa/plugins-for-godot/blob/fbfdaaeddd5899bfcae109eecbed253937c84aa4/godotrealitykit/GodotRealityKit/RealityKit/HandAnchors.swift)
publishes `/user/hand_tracker/left` and `/user/hand_tracker/right` through
`XRServer`. There are 26 Godot joint slots: 25 directly mapped ARKit wrist/finger
joints and a derived palm. This app uses only positions with both
`POSITION_VALID` and `POSITION_TRACKED`, after checking `has_tracking_data`.
The derived palm is not advertised or displayed as a tracked measurement.
The API does not supply per-joint timestamps, radii, velocities or numerical
confidence; the app does not synthesize those as measurements.

Joint transforms already include the hand-anchor transform. The matching
provider removes the immersive window's orthonormal tracking origin and world
scale. The app reverses those operations once:

```text
world_point = orthonormal(origin.global_transform) * (joint.origin * XRServer.world_scale)
field_unit = inverse(field.global_transform) * world_point
```

Neither the default palm pose nor `XRServer.reference_frame` is applied again.
Only finite coordinates in the half-open field cube `[0, 1)` can be sampled.
Physical size and placement controls account for `XRServer.world_scale`.
Sheared field axes remain unavailable because the native renderer cannot
preserve that transform. Rotated fields and nonuniform orthogonal axes work.

The immersive `Window` owns its 3D world and contains an `XROrigin3D` and
`XRCamera3D` before it becomes visible. It contains no `SpatialVolume3D` or
`RealityVolumeCamera3D`; these would select a different native host. Its models
use independent frame readers rather than reparenting a live shared-volume model.

## Tracking loss and validation

The native patch consumes `anchorUpdates` and caches each hand independently.
It preserves per-joint `isTracked`, rejects nonfinite poses, expires samples
older than 0.25 seconds using the ARKit update timestamp, and also checks
freshness when scene updates stop. Each native view has its own ownership
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
coordinate transforms, loss/recovery, renderer reuse, field boundaries, missing
versus zero, fresh pin sampling, history preservation, document isolation,
physical scaling, window cleanup and scrollable controls. Patch installer tests
use local Git fixtures and require neither network access nor an Apple SDK.

Desktop fixtures verify application behavior with synthetic joint positions.
Native compilation and unsigned export validate the integration but do not
establish physical hand alignment, permission behavior or headset usability.
Before a device demo, verify consent/denial, each fingertip on both hands,
occlusion and reacquisition, the scale and reach of the field, pinning with the
opposite hand, backgrounding, and closing/reopening the space on a Vision Pro.
