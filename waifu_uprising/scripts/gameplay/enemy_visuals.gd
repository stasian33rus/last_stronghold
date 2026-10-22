extends Node3D
## Визуал «Пижона» (Этап 1 — примитивы: манерный силуэт, цилиндр, жабо, шпага).
## Телеграф атаки (ТЗ §9.1): во время WINDUP персонаж откидывается и мигает золотом —
## атака читается с первого взгляда. Косметика; логика боя — в enemy_ai.gd (сервер).

var enemy: EnemyBase
var _last_state: int = -1
var _bob_time: float = 0.0
var _materials: Array[StandardMaterial3D] = []
var _orig_emissions: Array[Color] = []
var _pose_tween: Tween
var _telegraph_pulse: float = 0.0
var _base_scale: Vector3
var _accent_mat: StandardMaterial3D

@onready var weapon_pivot: Node3D = get_node_or_null(^"WeaponPivot")
## Акцентная деталь для телеграфа: «Accent» у новых архетипов, «Hat» у Пижона.
@onready var accent: MeshInstance3D = get_node_or_null(^"Accent") if get_node_or_null(^"Accent") != null else get_node_or_null(^"Hat")

func _ready() -> void:
	enemy = get_parent() as EnemyBase
	_base_scale = scale
	scale = _base_scale * 0.35 ## появление: «вырастает» из точки спавна
	var grow := create_tween()
	grow.tween_property(self, "scale", _base_scale, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for child in get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.get_active_material(0).duplicate() as StandardMaterial3D
		if mat != null:
			mi.material_override = mat
			_materials.append(mat)
			_orig_emissions.append(mat.emission if mat.emission_enabled else Color.BLACK)
	if accent != null:
		_accent_mat = accent.get_active_material(0).duplicate() as StandardMaterial3D
		accent.material_override = _accent_mat

func _process(delta: float) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var st: int = enemy.state
	if st != _last_state:
		_on_state_changed(_last_state, st)
		_last_state = st
	match st:
		EnemyBase.State.DEAD:
			pass ## падение и растворение запускаются в _on_state_changed
		EnemyBase.State.WINDUP:
			## Пульсирующий золотой телеграф + лёгкое покачивание.
			_telegraph_pulse += delta * 14.0
			var glow := (sin(_telegraph_pulse) * 0.5 + 0.5) * 3.5 + 0.5
			if _accent_mat != null:
				_accent_mat.emission_enabled = true
				_accent_mat.emission = Color(1.0, 0.85, 0.2)
				_accent_mat.emission_energy_multiplier = glow
			rotation.z = sin(_telegraph_pulse * 0.5) * 0.06
		_:
			var hv := Vector2(enemy.velocity.x, enemy.velocity.z).length()
			if hv > 0.8:
				## Манерная походка: покачивание «подиумного» шага.
				_bob_time += delta * (7.0 + hv)
				position.y = absf(sin(_bob_time)) * 0.09
				rotation.z = sin(_bob_time * 0.5) * 0.12
			else:
				_bob_time += delta * 2.2
				position.y = sin(_bob_time) * 0.03
				rotation.z = lerpf(rotation.z, 0.0, delta * 6.0)
			if _accent_mat != null:
				_accent_mat.emission_energy_multiplier = lerpf(_accent_mat.emission_energy_multiplier, 0.4, delta * 8.0)

func _on_state_changed(_from: int, to: int) -> void:
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	_pose_tween = null
	match to:
		EnemyBase.State.WINDUP: ## поклон перед выпадом
			_telegraph_pulse = 0.0
			_pose_tween = create_tween()
			_pose_tween.tween_property(self, "rotation:x", 0.25, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			Sfx.play("count", -14.0, 0.75)
		EnemyBase.State.STRIKE: ## выпад шпагой
			_pose_tween = create_tween()
			_pose_tween.tween_property(self, "rotation:x", -0.35, 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			if weapon_pivot != null:
				_pose_tween.parallel().tween_property(weapon_pivot, "position:z", -0.85, 0.09)
				_pose_tween.tween_property(weapon_pivot, "position:z", -0.35, 0.25)
				_pose_tween.parallel().tween_property(self, "rotation:x", 0.0, 0.25)
			else:
				_pose_tween.parallel().tween_property(self, "rotation:x", 0.0, 0.25)
		EnemyBase.State.HITSTUN: ## комичная пощёчина
			_pose_tween = create_tween()
			_pose_tween.tween_property(self, "rotation:z", 0.4, 0.06)
			_pose_tween.tween_property(self, "rotation:z", 0.0, 0.2).set_trans(Tween.TRANS_BOUNCE)
		EnemyBase.State.DEAD: ## драматичное падение
			_pose_tween = create_tween()
			_pose_tween.tween_property(self, "rotation:x", -PI / 2.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			_pose_tween.parallel().tween_property(self, "position:y", -0.6, 0.9).set_delay(0.35)
			Sfx.play("enemy_die", -6.0)
			for mat in _materials:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_pose_tween.parallel().tween_method(_fade_all, 1.0, 0.0, 0.7).set_delay(0.4)
		_:
			pass

func _fade_all(alpha: float) -> void:
	for mat in _materials:
		var c := mat.albedo_color
		c.a = alpha
		mat.albedo_color = c

## Белая вспышка при получении урона (вызывается fx_hit RPC).
func flash() -> void:
	for mat in _materials:
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.9, 0.9)
		mat.emission_energy_multiplier = 3.5
	var tween := create_tween()
	tween.tween_interval(0.07)
	tween.tween_callback(func() -> void:
		for i in _materials.size():
			var mat := _materials[i]
			mat.emission = _orig_emissions[i]
			mat.emission_enabled = _orig_emissions[i] != Color.BLACK
			mat.emission_energy_multiplier = 1.0
	)
