class_name SpatialPlatform
extends RefCounted
## Which way this run shows the app's windows and volumes. Decided once, at
## startup, so every part of the addon agrees.

enum Kind {
	## Native visionOS windows and RealityKit volumes, through GodotRealityKit.
	VISIONOS,
	## Ordinary OS windows; volumes are viewed through an orbit camera.
	DESKTOP,
	## An OpenXR headset: windows become panels and volumes boxes in one world.
	XR,
}

## Passed after "--" on the command line, runs the XR layout without a
## headset: the mouse looks around and points.
const SIMULATOR_ARGUMENT := "--xr-simulator"

static var _kind := -1


static func current() -> Kind:
	if _kind < 0:
		_kind = _detect()
	return _kind as Kind


## True when the XR layout runs on a desktop, without a headset.
static func is_simulated_xr() -> bool:
	return current() == Kind.XR and not _is_openxr_running()


static func _detect() -> Kind:
	if OS.has_feature("visionos") and ClassDB.class_exists(&"RealityVolumeCamera3D"):
		return Kind.VISIONOS
	if _is_openxr_running() or SIMULATOR_ARGUMENT in OS.get_cmdline_user_args():
		return Kind.XR
	return Kind.DESKTOP


static func _is_openxr_running() -> bool:
	var openxr := XRServer.find_interface("OpenXR")
	return openxr != null and openxr.is_initialized()
