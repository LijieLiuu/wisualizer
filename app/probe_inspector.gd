extends Window
## Per-document probe analysis. Workers own their reader and never touch scene nodes.

const History := preload("res://app/probe_history.gd")
const NativeDialogs := preload("res://app/native_dialogs.gd")

class Job extends RefCounted:
	var mutex := Mutex.new()
	var stopped := false
	var done := 0
	var total := 0

	func cancel() -> void:
		mutex.lock()
		stopped = true
		mutex.unlock()

	func is_canceled() -> bool:
		mutex.lock()
		var value := stopped
		mutex.unlock()
		return value

	func report(completed: int, count: int) -> void:
		mutex.lock()
		done = completed
		total = count
		mutex.unlock()

	func progress() -> Vector2i:
		mutex.lock()
		var value := Vector2i(done, total)
		mutex.unlock()
		return value

	func analyze(path: String, field_index: int, points: Dictionary, identity: Dictionary) -> Dictionary:
		return History.new().analyze(path, field_index, points, identity, is_canceled, report)

	func export_csv(data: Dictionary, path: String, protected: PackedStringArray) -> Dictionary:
		return {error = History.new().export_csv(data, path, is_canceled, protected), path = path}


@onready var timeline: Control = %Timeline
@onready var readout: Label = %Readout
@onready var status: Label = %Status
@onready var progress: ProgressBar = %Progress
@onready var file_dialog: FileDialog = $File

var document: Node
var result: Dictionary = {}
var _points: Dictionary = {}
var _field := -1
var _active := false
var _generation := 0
var _task_generation := 0
var _thread: Thread
var _job: Job
var _task := ""
var _pending_action := ""
var _dialog_generation := -1
var _session_path := ""


func _ready() -> void:
	NativeDialogs.apply_to(self)
	timeline.frame_selected.connect(_select_frame)


func setup(owner_document: Node) -> void:
	document = owner_document
	refresh()


func is_busy() -> bool:
	return _thread != null


## Called on both playback and gesture changes; only a placement change
## invalidates analysis. A live candidate never launches a ZIP scan.
func refresh() -> void:
	if document == null or not is_node_ready():
		return
	var window_title: String = document.meta.title + " – Probe history"
	if title != window_title:
		title = window_title
	var points: Dictionary = document.inspection.get_committed_points()
	var active: bool = document.inspection.is_active()
	if _field != document.field_index or points != _points or (active and not _active):
		_invalidate()
		if _field != document.field_index:
			_session_path = ""
		_field = document.field_index
		_points = points
	_active = active
	var has_field: bool = _field >= 0 and _field < document.meta.fields.size()
	if has_field:
		var entry = document.meta.fields[_field]
		%CellX.max_value = entry.cells.x - 1
		%CellY.max_value = entry.cells.y - 1
		%CellZ.max_value = entry.cells.z - 1
		readout.text = document.format_probe_readings(_points)
		if active:
			readout.text += "\nPlacement in progress; history uses released pins."
	else:
		readout.text = "This document has no scalar field."
	timeline.set_frame(document.frame)
	%Analyze.disabled = is_busy() or not has_field or points.is_empty() or active
	%Cancel.disabled = not is_busy()
	%Export.disabled = is_busy() or result.is_empty() or active
	%SavePoints.disabled = is_busy() or points.is_empty() or active or not has_field
	%LoadPoints.disabled = is_busy() or active or not has_field
	%SetA.disabled = not has_field or active
	%SetB.disabled = not has_field or active
	%Clear.disabled = points.is_empty() and not active


func _invalidate() -> void:
	_generation += 1
	cancel_analysis()
	result = {}
	timeline.clear()
	file_dialog.hide()
	_pending_action = ""
	status.text = "Positions changed. Select Analyze to read all frames."


func place_cell(slot: int) -> void:
	if document == null or document.meta.fields.is_empty() or document.inspection.is_active():
		return
	var entry = document.meta.fields[document.field_index]
	var cell := Vector3i(int(%CellX.value), int(%CellY.value), int(%CellZ.value))
	var points: Dictionary = document.inspection.get_committed_points()
	var point := (Vector3(cell) + Vector3.ONE * 0.5) / Vector3(entry.cells)
	if Vector3i((point * Vector3(entry.cells)).floor()) != cell:
		status.text = "This cell cannot be represented exactly at the current coordinate precision."
		return
	points[slot] = point
	document.inspection.set_points(points)


func clear_points() -> void:
	document.clear_probes()


func analyze() -> void:
	refresh()
	if %Analyze.disabled:
		return
	var snapshot := History.snapshot(document.meta, document.field_index)
	if not snapshot.error.is_empty():
		status.text = snapshot.error
		return
	result = {}
	timeline.clear()
	_job = Job.new()
	_start("analyze", _job.analyze.bind(document.source_path, document.field_index, _points.duplicate(), snapshot.identity))


func _start(kind: String, work: Callable) -> void:
	_task = kind
	_task_generation = _generation
	_thread = Thread.new()
	var error := _thread.start(work)
	if error != OK:
		_thread = null
		_job = null
		status.text = "Couldn't start the task: " + error_string(error)
	else:
		status.text = "Reading probe history…" if kind == "analyze" else "Exporting probe history…"
		progress.value = 0
	progress.visible = is_busy()
	refresh()


func cancel_analysis() -> void:
	if _job != null:
		_job.cancel()
		if is_node_ready():
			status.text = "Canceling…"


func _process(_delta: float) -> void:
	if _thread == null:
		return
	if _thread.is_alive():
		var completed := _job.progress()
		if completed.y > 0:
			progress.value = 100.0 * completed.x / completed.y
			if _task_generation == _generation and not _job.is_canceled():
				status.text = "Reading frame %d of %d…" % [completed.x, completed.y]
		return
	var completed: Dictionary = _thread.wait_to_finish()
	_thread = null
	var canceled := _job.is_canceled()
	_job = null
	progress.hide()
	if _task_generation != _generation:
		status.text = "Positions changed. Select Analyze to read all frames."
	elif not completed.error.is_empty():
		status.text = completed.error
	elif _task == "analyze":
		if canceled:
			status.text = "Analysis canceled."
		else:
			result = completed
			timeline.set_series(result)
			status.text = "%d frames analyzed. Click the timeline to inspect a frame." % result.rows.size()
	else:
		status.text = "Exported " + str(completed.path).get_file()
	refresh()


func _select_frame(index: int) -> void:
	if document == null or result.is_empty():
		return
	document.set_playing(false)
	document.seek(clampi(index, 0, document.frame_count - 1))


func ask_file(action: String) -> void:
	refresh()
	if is_busy() or _active:
		return
	if action == "export" and result.is_empty():
		return
	if action == "save" and _points.is_empty():
		return
	_pending_action = action
	_dialog_generation = _generation
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE if action == "load" else FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.filters = PackedStringArray(["*.csv ; Probe history CSV"]) if action == "export" else PackedStringArray(["*.json ; Probe positions"])
	file_dialog.title = {"export": "Export probe history", "save": "Save probe positions", "load": "Load probe positions"}[action]
	file_dialog.current_file = "" if action == "load" else document.source_path.get_file().get_basename() + ("-probes.csv" if action == "export" else "-probes.json")
	file_dialog.popup_centered()


func _file_selected(path: String) -> void:
	var action := _pending_action
	_pending_action = ""
	if _dialog_generation != _generation or is_busy() or _active:
		status.text = "The inspection changed. Choose the file again."
		return
	match action:
		"export":
			export_to(path)
		"save":
			save_points(path)
		"load":
			load_points(path)


func export_to(path: String) -> void:
	if is_busy() or result.is_empty() or _active:
		return
	if path.get_extension().to_lower() != "csv":
		path += ".csv"
	_job = Job.new()
	_start("export", _job.export_csv.bind(result.duplicate(true), path, PackedStringArray([_session_path])))


func save_points(path: String) -> void:
	if is_busy() or _active or document.meta.fields.is_empty():
		return
	if path.get_extension().to_lower() != "json":
		path += ".json"
	var error: String = History.new().save_session(document.meta, document.field_index, _points, document.source_path, path)
	status.text = error if not error.is_empty() else "Saved probe positions to " + path.get_file()
	if error.is_empty():
		_session_path = path


func load_points(path: String) -> void:
	if is_busy() or _active:
		return
	var restored: Dictionary = History.new().restore_session(path, document.meta, document.source_path)
	if not restored.error.is_empty():
		status.text = restored.error
		return
	document.select_field(restored.field_index)
	document.inspection.set_points(restored.points)
	_session_path = restored.source_session
	status.text = "Restored probe positions. Select Analyze to read their history."
	refresh()


func _exit_tree() -> void:
	cancel_analysis()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
