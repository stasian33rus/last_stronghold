extends Node3D
## Визуал Берсерки (Этап 1 — оригинальные примитивы с правильными пропорциями, ТЗ §14).
## Косметика: опрашивается состояние владельца (одинаково работает на сервере и клиентах),
## реакции на попадания приходят через fx_* RPC. Логика боя здесь НЕ живёт.

var pawn: PlayerPawn
var _bob_time: float = 0.0
var _last_state: int = -1
var _materials: Array[StandardMaterial3D] = []
var _orig_emissions: Array[Color] = []
var _swing_tween: Tween
var _body_tween: Tween
var _base_scale: Vector3

@onready var weapon_pivot: Node3D = $WeaponPivot

func _ready() -> void:
	pawn = get_parent() as PlayerPawn
	_base_scale = scale
	## Материалы делаем уникальными на экземпляр, чтобы вспышка урона не красила всех сразу.
	for child in get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.get_active_material(0).duplicate() as StandardMaterial3D
		if mat != null:
			mi.material_override = mat
			_materials.append(mat)
			_orig_emissions.append(mat.emission if mat.emission_enabled else Color.BLACK)

func _process(delta: float) -> void:
	if pawn == null:
		return
	var st: int = pawn.state
	if st != _last_state:
		_on_state_changed(_last_state, st)
		_last_state = st
	var hv := Vector2(pawn.velocity.x, pawn.velocity.z).length()
	match st:
		PlayerPawn.State.RUN:
			_bob_time += delta * (6.0 + hv * 1.4)
			position.y = absf(sin(_bob_time)) * 0.07
			rotation.z = sin(_bob_time) * 0.05
		PlayerPawn.State.IDLE:
			_bob_time += delta * 2.0
			position.y = sin(_bob_time) * 0.02
			rotation.z = lerpf(rotation.z, 0.0, delta * 8.0)
		PlayerPawn.State.DODGE:
			position.y = 0.0
			rotation.z = lerpf(rotation.z, 0.0, delta * 8.0)
		_:
			pass

func _on_state_changed(from: int, to: int) -> void:
	match to:
		PlayerPawn.State.DOWN:
			_play_down()
		_:
			if from == PlayerPawn.State.DOWN:
				_play_respawn()

func _play_down() -> void:
	if _body_tween != null and _body_tween.is_valid():
		_body_tween.kill()
	_body_tween = create_tween()
	_body_tween.tween_property(self, "rotation:x", -PI / 2.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

func _play_respawn() -> void:
	if _body_tween != null and _body_tween.is_valid():
		_body_tween.kill()
	rotation.x = 0.0
	_body_tween = create_tween()
	_body_tween.tween_property(self, "scale", _base_scale * 1.25, 0.12)
	_body_tween.tween_property(self, "scale", _base_scale, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)

## Короткая белая вспышка при получении урона.
func flash() -> void:
	for i in _materials.size():
		var mat := _materials[i]
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.85)
		mat.emission_energy_multiplier = 4.0
	var tween := create_tween()
	tween.tween_interval(0.07)
	tween.tween_callback(func() -> void:
		for i in _materials.size():
			var mat := _materials[i]
			mat.emission = _orig_emissions[i]
			mat.emission_enabled = _orig_emissions[i] != Color.BLACK
			mat.emission_energy_multiplier = 1.0
	)

## Замах молота (вызывается fx_swing RPC на всех пирах).
func play_swing() -> void:
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = create_tween()
	_swing_tween.tween_property(weapon_pivot, "rotation:x", -2.3, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(weapon_pivot, "rotation:x", 0.95, 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_swing_tween.tween_property(weapon_pivot, "rotation:x", -0.15, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
