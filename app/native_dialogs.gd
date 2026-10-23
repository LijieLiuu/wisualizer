extends RefCounted
## Whether to use the system's own alerts and file pickers, where it has
## them. With [code]--godot-dialogs[/code] after [code]--[/code] on the command
## line, Godot draws them instead, as on platforms without them; for trying
## those out on any computer.

const FLAG := "--godot-dialogs"


static func alerts() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG) and not FLAG in OS.get_cmdline_user_args()


## Godot's own file dialog at this size, in window pixels; the system's
## sizes itself.
const FILE_DIALOG_SIZE := Vector2i(1800, 1200)


## Applies the choice to every [FileDialog] under [param node], and starts
## them in Downloads, where exports usually land.
static func apply_to(node: Node) -> void:
	for dialog: FileDialog in node.find_children("*", "FileDialog", true, false):
		dialog.use_native_dialog = not FLAG in OS.get_cmdline_user_args()
		dialog.size = FILE_DIALOG_SIZE
		dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
