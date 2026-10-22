class_name PlayerCameraRig
extends Node3D
## Камера третьего лица с фиксированным углом (ТЗ §14: читаемость боёв,
## поддержка 8 игроков — у каждого клиента активна только своя камера).
## top_level: позиция задаётся вручную, следует за пешкой; рыскание = 0 (Этап 1),
## наклон фиксированный. Зум колесом мыши в разумных пределах.

const BASE_OFFSET := Vector3(0.0, 12.5, 9.5)
const ZOOM_MIN := 0.65
const ZOOM_MAX := 1.45
const SHAKE_DECAY := 5.5

var target: Node3D
var zoom_factor: float = 1.0
var _shake: float = 0.0
var _active := false

@onready var _camera: Camera3D = $Camera3D

func _ready() -> void:
	top_level = true
	_camera.current = false
	process_mode = Node.PROCESS_MODE_ALWAYS

func activate_for(pawn: Node3D) -> void:
	target = pawn
	_active = true
	_camera.current = true
	Events.local_camera_shake.connect(_on_camera_shake)

func get_active_camera() -> Camera3D:
	return _camera if _active else null

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event.is_action("camera_zoom_in"):
		zoom_factor = clampf(zoom_factor - 0.1, ZOOM_MIN, ZOOM_MAX)
	elif event.is_action("camera_zoom_out"):
		zoom_factor = clampf(zoom_factor + 0.1, ZOOM_MIN, ZOOM_MAX)

func _process(delta: float) -> void:
	if not _active or target == null:
		return
	var desired := target.global_position + BASE_OFFSET * zoom_factor
	global_position = global_position.lerp(desired, minf(1.0, delta * 10.0))
	if _shake > 0.01:
		_shake = maxf(0.0, _shake - SHAKE_DECAY * delta * _shake - 0.4 * delta)
		var s := _shake * 0.25
		global_position += Vector3(randf_range(-s, s), randf_range(-s, s), randf_range(-s, s))
	## Камера смотрит чуть впереди цели.
	var look_at_pos := target.global_position + Vector3(0.0, 1.0, 0.0)
	var dir := look_at_pos - global_position
	if dir.length_squared() > 0.01:
		_camera.look_at_from_position(global_position, look_at_pos, Vector3.UP)
	else:
		_camera.global_position = global_position

func _on_camera_shake(strength: float) -> void:
	if _active:
		_shake = minf(1.2, _shake + strength)
