extends Node3D
## Визуал героини (Этап 3): ДАННЫЕ-драйв процедурная заглушка или внешняя модель.
##  - rebuild(def) строит силуэт по ClassDefinition активной формы: оружие,
##    причёска, цвета, свечение/аура формы, общий масштаб;
##  - если def.model_scene задан (назначается в Godot Inspector — сцена
##    импортированного .glb), процедурная заглушка НЕ строится: модель
##    инстансируется как есть. Это точка подключения финальных моделей
##    (24 слота: 8 классов × 3 формы) без правки боевых скриптов;
##  - косметика: опрашивает состояние владельца (одинаково на сервере и
##    клиентах), реакции на попадания — через fx_* RPC. Логика боя здесь НЕ живёт.
##  - визуальный слой изолирован: HP/физика/сеть — компоненты пешки, здесь
##    только MeshInstance3D-узлы; rebuild не трогает ничего вне $Visuals.

var pawn: PlayerPawn
var _def: ClassDefinition
var _bob_time: float = 0.0
var _last_state: int = -1
var _materials: Array[StandardMaterial3D] = []
var _orig_emissions: Array[Color] = []
var _swing_tween: Tween
var _body_tween: Tween
var _base_scale: Vector3 = Vector3.ONE
var weapon_pivot: Node3D
var _aura_ring: Node3D
var _shards: Array[MeshInstance3D] = []
## AnimationPlayer импортированной .glb-модели (null для процедурной заглушки).
var _anim: AnimationPlayer
var _oneshot_left: float = 0.0
var _frenzy_on := false
var _root: Node3D ## контейнер построенной модели (чтобы rebuild очищал только его)

func _ready() -> void:
	pawn = get_parent() as PlayerPawn
	_base_scale = scale

## Полная перестройка визуала под форму def. Вызывается из PlayerPawn
## (_ready и эволюция/репликация формы). Состояние пешки не затрагивается.
func rebuild(def: ClassDefinition) -> void:
	_def = def
	if _body_tween != null and _body_tween.is_valid():
		_body_tween.kill()
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	if _root != null and is_instance_valid(_root):
		## Мгновенное удаление (не queue_free): повторный rebuild в том же кадре
		## не должен оставлять два «ModelRoot» с коллизией имён.
		remove_child(_root)
		_root.free()
	_root = Node3D.new()
	_root.name = "ModelRoot"
	add_child(_root)
	weapon_pivot = null
	_aura_ring = null
	_anim = null
	_oneshot_left = 0.0
	_shards.clear()
	_materials.clear()
	_orig_emissions.clear()
	if def == null:
		return
	_root.scale = Vector3.ONE * def.visual_scale
	if def.model_scene != null:
		## Внешняя модель (.glb через Inspector) — процедурную заглушку не строим.
		var model := def.model_scene.instantiate()
		model.name = "Model"
		_root.add_child(model)
		## Оружие-пивот для анимации взмаха: ищем точку в модели или создаём у руки.
		var wp := model.find_child("WeaponPivot", true, false) as Node3D
		if wp == null:
			wp = Node3D.new()
			wp.name = "WeaponPivot"
			wp.position = Vector3(0.5, 1.0, -0.1)
			_root.add_child(wp)
		weapon_pivot = wp
		## Управление анимациями glTF (idle/run/attack/skill/parry/hit/death/transform).
		_anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if _anim != null:
			for loop_name in ["idle", "run"]:
				if _anim.has_animation(loop_name):
					_anim.get_animation(loop_name).loop_mode = Animation.LOOP_LINEAR
			if _anim.has_animation("idle"):
				_anim.play("idle")
		_aura_ring = model.find_child("Aura", true, false)
	else:
		_build_procedural(def)
	_collect_materials(_root)

## Одноразовая анимация модели (атака/парирование/трансформация/рывок).
func _play_oneshot(an: String) -> void:
	if _anim == null or not _anim.has_animation(an):
		return
	_oneshot_left = _anim.get_animation(an).length
	_anim.play(an)

func play_parry() -> void:
	_play_oneshot("parry")

func play_transform() -> void:
	_play_oneshot("transform")

func _collect_materials(node: Node) -> void:
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			var mat := mi.get_active_material(0).duplicate() as StandardMaterial3D
			if mat != null:
				mi.material_override = mat
				_materials.append(mat)
				_orig_emissions.append(mat.emission if mat.emission_enabled else Color.BLACK)
		_collect_materials(child)

# ------------------------------------------------------------------ конструктор заглушки

func _mat(color: Color, glow: float = 0.0, metallic: float = 0.0, rough: float = 0.55) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = glow
	return m

func _mesh(parent: Node, mesh: Mesh, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO, mat: StandardMaterial3D = null, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if mat != null:
		mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	parent.add_child(mi)
	return mi

func _build_procedural(def: ClassDefinition) -> void:
	var outfit := _mat(def.color, def.visual_glow * 0.35, 0.1, 0.55)
	var skin := _mat(Color(1.0, 0.86, 0.76), 0.0, 0.0, 0.7)
	var hair := _mat(def.visual_hair_color, def.visual_glow * 0.25, 0.0, 0.4)
	var accent := _mat(def.visual_accent, maxf(def.visual_glow, 0.4), 0.5, 0.35)
	var steel := _mat(Color(0.72, 0.75, 0.82), def.visual_glow * 0.2, 0.85, 0.3)
	var form := def.form_index ## 0/1/2 — гламурность силуэта растёт с формой
	## Ноги.
	var leg := CapsuleMesh.new()
	leg.radius = 0.09
	leg.height = 0.72
	_mesh(_root, leg, Vector3(-0.13, 0.36, 0.0), Vector3.ZERO, skin)
	_mesh(_root, leg, Vector3(0.13, 0.36, 0.0), Vector3.ZERO, skin)
	## Сапоги (акцент формы II+).
	if form >= 1:
		var boot := CylinderMesh.new()
		boot.top_radius = 0.1
		boot.bottom_radius = 0.12
		boot.height = 0.34
		_mesh(_root, boot, Vector3(-0.13, 0.17, 0.0), Vector3.ZERO, accent)
		_mesh(_root, boot, Vector3(0.13, 0.17, 0.0), Vector3.ZERO, accent)
	## Торс.
	var torso := CapsuleMesh.new()
	torso.radius = 0.26 + 0.015 * form
	torso.height = 0.95
	_mesh(_root, torso, Vector3(0.0, 0.98, 0.0), Vector3.ZERO, outfit)
	## Нагрудник — нейтральная равномерная деталь брони для всех форм.
	## Визуальная прогрессия форм передаётся ТОЛЬКО экипировкой (акцентный
	## материал со формы II), свечением, аурой и общим масштабом — силуэт
	## остаётся стилизованным и неоткровенным (контентная безопасность).
	var breastplate := BoxMesh.new()
	breastplate.size = Vector3(0.34, 0.3, 0.08)
	_mesh(_root, breastplate, Vector3(0.0, 1.12, -0.24), Vector3.ZERO, accent if form >= 1 else outfit)
	## Юбка/броня-бедра.
	var skirt := CylinderMesh.new()
	skirt.top_radius = 0.24
	skirt.bottom_radius = 0.36 + 0.04 * form
	skirt.height = 0.34 + 0.05 * form
	_mesh(_root, skirt, Vector3(0.0, 0.72, 0.0), Vector3.ZERO, outfit if form == 0 else accent)
	## Пояс.
	var belt := TorusMesh.new()
	belt.inner_radius = 0.24
	belt.outer_radius = 0.3
	_mesh(_root, belt, Vector3(0.0, 0.86, 0.0), Vector3(90.0, 0.0, 0.0), accent)
	## Руки.
	var arm := CapsuleMesh.new()
	arm.radius = 0.065
	arm.height = 0.62
	_mesh(_root, arm, Vector3(-0.34, 1.02, 0.0), Vector3(0.0, 0.0, 14.0), skin)
	_mesh(_root, arm, Vector3(0.34, 1.02, 0.0), Vector3(0.0, 0.0, -14.0), skin)
	## Наплечники (форма II+).
	if form >= 1:
		var pad := SphereMesh.new()
		pad.radius = 0.11
		pad.height = 0.22
		_mesh(_root, pad, Vector3(-0.33, 1.28, 0.0), Vector3.ZERO, accent)
		_mesh(_root, pad, Vector3(0.33, 1.28, 0.0), Vector3.ZERO, accent)
	## Голова.
	var head := SphereMesh.new()
	head.radius = 0.22
	head.height = 0.44
	_mesh(_root, head, Vector3(0.0, 1.62, 0.0), Vector3.ZERO, skin)
	_build_hair(def, hair)
	_build_weapon(def, steel, accent, outfit)
	## Аура финальной формы: кольцо + парящие осколки (ТЗ §7: «заметные детали формы III»).
	if def.visual_glow >= 1.5:
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 0.75
		ring_mesh.outer_radius = 0.86
		_aura_ring = _mesh(_root, ring_mesh, Vector3(0.0, 0.08, 0.0), Vector3(90.0, 0.0, 0.0), accent)
		var shard := BoxMesh.new()
		shard.size = Vector3(0.1, 0.22, 0.1)
		for i in 3:
			var ang := TAU * float(i) / 3.0
			var sm := _mesh(_root, shard, Vector3(cos(ang) * 0.75, 1.35 + 0.15 * i, sin(ang) * 0.75), Vector3(20.0, 40.0 * i, 10.0), accent)
			_shards.append(sm)

func _build_hair(def: ClassDefinition, hair: StandardMaterial3D) -> void:
	var cap := SphereMesh.new()
	cap.radius = 0.245
	cap.height = 0.49
	_mesh(_root, cap, Vector3(0.0, 1.66, 0.03), Vector3.ZERO, hair, Vector3(1.04, 0.92, 1.1))
	match def.visual_hair:
		ClassDefinition.VisualHair.SHORT:
			pass ## только шапка
		ClassDefinition.VisualHair.LONG:
			var back := BoxMesh.new()
			back.size = Vector3(0.42, 0.78, 0.14)
			_mesh(_root, back, Vector3(0.0, 1.28, 0.16), Vector3(6.0, 0.0, 0.0), hair)
		ClassDefinition.VisualHair.TWINTAILS:
			var tail := CylinderMesh.new()
			tail.top_radius = 0.07
			tail.bottom_radius = 0.045
			tail.height = 0.62
			_mesh(_root, tail, Vector3(-0.3, 1.4, 0.06), Vector3(0.0, 0.0, 22.0), hair)
			_mesh(_root, tail, Vector3(0.3, 1.4, 0.06), Vector3(0.0, 0.0, -22.0), hair)
		ClassDefinition.VisualHair.PONYTAIL:
			var tail := CylinderMesh.new()
			tail.top_radius = 0.08
			tail.bottom_radius = 0.04
			tail.height = 0.7
			_mesh(_root, tail, Vector3(0.0, 1.36, 0.22), Vector3(-24.0, 0.0, 0.0), hair)
		ClassDefinition.VisualHair.BRAID:
			var b := SphereMesh.new()
			b.radius = 0.07
			b.height = 0.14
			for i in 4:
				_mesh(_root, b, Vector3(0.0, 1.5 - 0.16 * i, 0.2), Vector3.ZERO, hair)
		ClassDefinition.VisualHair.BOB:
			var side := BoxMesh.new()
			side.size = Vector3(0.5, 0.3, 0.34)
			_mesh(_root, side, Vector3(0.0, 1.56, 0.02), Vector3.ZERO, hair)
		ClassDefinition.VisualHair.WAVY:
			var w := SphereMesh.new()
			w.radius = 0.12
			w.height = 0.24
			_mesh(_root, w, Vector3(-0.24, 1.42, 0.1), Vector3.ZERO, hair)
			_mesh(_root, w, Vector3(0.24, 1.42, 0.1), Vector3.ZERO, hair)
			_mesh(_root, w, Vector3(0.0, 1.3, 0.2), Vector3.ZERO, hair)

func _build_weapon(def: ClassDefinition, steel: StandardMaterial3D, accent: StandardMaterial3D, outfit: StandardMaterial3D) -> void:
	weapon_pivot = Node3D.new()
	weapon_pivot.name = "WeaponPivot"
	weapon_pivot.position = Vector3(0.5, 1.0, -0.1)
	_root.add_child(weapon_pivot)
	match def.visual_weapon:
		ClassDefinition.VisualWeapon.HAMMER:
			var handle := BoxMesh.new()
			handle.size = Vector3(0.08, 0.08, 1.0)
			_mesh(weapon_pivot, handle, Vector3(0.0, 0.0, -0.45), Vector3.ZERO, _mat(Color(0.42, 0.28, 0.18), 0.0, 0.0, 0.8))
			var headm := BoxMesh.new()
			headm.size = Vector3(0.42, 0.3, 0.52)
			_mesh(weapon_pivot, headm, Vector3(0.0, 0.0, -0.98), Vector3.ZERO, steel)
		ClassDefinition.VisualWeapon.SWORD:
			var blade := BoxMesh.new()
			blade.size = Vector3(0.06, 0.02, 1.15)
			_mesh(weapon_pivot, blade, Vector3(0.0, 0.0, -0.6), Vector3.ZERO, steel)
			var guard := BoxMesh.new()
			guard.size = Vector3(0.26, 0.05, 0.06)
			_mesh(weapon_pivot, guard, Vector3(0.0, 0.0, -0.05), Vector3.ZERO, accent)
		ClassDefinition.VisualWeapon.DUAL_BLADES:
			var blade := BoxMesh.new()
			blade.size = Vector3(0.05, 0.02, 0.8)
			_mesh(weapon_pivot, blade, Vector3(-0.08, 0.0, -0.45), Vector3(0.0, 8.0, 0.0), steel)
			_mesh(weapon_pivot, blade, Vector3(0.08, 0.0, -0.45), Vector3(0.0, -8.0, 0.0), steel)
		ClassDefinition.VisualWeapon.WRENCH_GUN:
			var body := BoxMesh.new()
			body.size = Vector3(0.12, 0.16, 0.5)
			_mesh(weapon_pivot, body, Vector3(0.0, 0.0, -0.25), Vector3.ZERO, steel)
			var barrel := CylinderMesh.new()
			barrel.top_radius = 0.04
			barrel.bottom_radius = 0.05
			barrel.height = 0.34
			_mesh(weapon_pivot, barrel, Vector3(0.0, 0.03, -0.6), Vector3(90.0, 0.0, 0.0), accent)
		ClassDefinition.VisualWeapon.STAFF:
			var shaft := CylinderMesh.new()
			shaft.top_radius = 0.03
			shaft.bottom_radius = 0.035
			shaft.height = 1.5
			_mesh(weapon_pivot, shaft, Vector3(0.0, 0.25, 0.0), Vector3.ZERO, _mat(Color(0.35, 0.22, 0.4), 0.0, 0.1, 0.7))
			var orb := SphereMesh.new()
			orb.radius = 0.13
			orb.height = 0.26
			_mesh(weapon_pivot, orb, Vector3(0.0, 1.02, 0.0), Vector3.ZERO, accent)
		ClassDefinition.VisualWeapon.MIC:
			var body := CylinderMesh.new()
			body.top_radius = 0.04
			body.bottom_radius = 0.05
			body.height = 0.3
			_mesh(weapon_pivot, body, Vector3(0.0, 0.0, -0.15), Vector3(90.0, 0.0, 0.0), steel)
			var headm := SphereMesh.new()
			headm.radius = 0.09
			headm.height = 0.18
			_mesh(weapon_pivot, headm, Vector3(0.0, 0.0, -0.34), Vector3.ZERO, accent)
		ClassDefinition.VisualWeapon.RIFLE:
			var body := BoxMesh.new()
			body.size = Vector3(0.08, 0.14, 0.9)
			_mesh(weapon_pivot, body, Vector3(0.0, 0.0, -0.45), Vector3.ZERO, _mat(Color(0.2, 0.24, 0.22), 0.0, 0.4, 0.5))
			var barrel := CylinderMesh.new()
			barrel.top_radius = 0.025
			barrel.bottom_radius = 0.03
			barrel.height = 0.5
			_mesh(weapon_pivot, barrel, Vector3(0.0, 0.02, -1.05), Vector3(90.0, 0.0, 0.0), steel)
			var scope := BoxMesh.new()
			scope.size = Vector3(0.05, 0.07, 0.22)
			_mesh(weapon_pivot, scope, Vector3(0.0, 0.11, -0.4), Vector3.ZERO, accent)
		ClassDefinition.VisualWeapon.FLASK:
			var glass := _mat(Color(0.6, 1.0, 0.7, 0.55), maxf(def_glow(), 0.6), 0.0, 0.15)
			var body := SphereMesh.new()
			body.radius = 0.12
			body.height = 0.24
			_mesh(weapon_pivot, body, Vector3(0.0, 0.0, -0.2), Vector3.ZERO, glass)
			var neck := CylinderMesh.new()
			neck.top_radius = 0.035
			neck.bottom_radius = 0.05
			neck.height = 0.14
			_mesh(weapon_pivot, neck, Vector3(0.0, 0.14, -0.2), Vector3.ZERO, steel)
		ClassDefinition.VisualWeapon.SHIELD_GAUNTLET:
			var shield := BoxMesh.new()
			shield.size = Vector3(0.5, 0.72, 0.08)
			_mesh(weapon_pivot, shield, Vector3(-0.1, 0.05, -0.3), Vector3(0.0, -18.0, 0.0), steel)
			var trim := TorusMesh.new()
			trim.inner_radius = 0.12
			trim.outer_radius = 0.17
			_mesh(weapon_pivot, trim, Vector3(-0.1, 0.05, -0.36), Vector3(0.0, -18.0, 0.0), accent)
		_:
			pass

func def_glow() -> float:
	return _def.visual_glow if _def != null else 0.0

# ------------------------------------------------------------------ анимации/косметика

func _process(delta: float) -> void:
	if pawn == null or _root == null:
		return
	var st: int = pawn.state
	if st != _last_state:
		_on_state_changed(_last_state, st)
		_last_state = st
	_oneshot_left = maxf(0.0, _oneshot_left - delta)
	## Модель с AnimationPlayer двигает тело сама — процедурный bob не нужен.
	if _anim == null:
		var hv := Vector2(pawn.velocity.x, pawn.velocity.z).length()
		match st:
			PlayerPawn.State.RUN:
				_bob_time += delta * (6.0 + hv * 1.4)
				_root.position.y = absf(sin(_bob_time)) * 0.07
				_root.rotation.z = sin(_bob_time) * 0.05
			PlayerPawn.State.IDLE:
				_bob_time += delta * 2.0
				_root.position.y = sin(_bob_time) * 0.02
				_root.rotation.z = lerpf(_root.rotation.z, 0.0, delta * 8.0)
			PlayerPawn.State.DODGE:
				_root.position.y = 0.0
				_root.rotation.z = lerpf(_root.rotation.z, 0.0, delta * 8.0)
			_:
				pass
	else:
		_bob_time += delta * 2.0
	## Аура финальной формы: вращение кольца (узел Aura модели) и осколков заглушки.
	if _aura_ring != null and is_instance_valid(_aura_ring):
		_aura_ring.rotation.z += delta * 1.6
	for i in _shards.size():
		var sh := _shards[i]
		if is_instance_valid(sh):
			sh.rotation.y += delta * (1.2 + 0.4 * i)
			sh.position.y = 1.35 + 0.15 * i + sin(_bob_time * 1.3 + i * 2.1) * 0.09

func _on_state_changed(from: int, to: int) -> void:
	## Переключение анимаций модели (glTF): циклы — по состоянию, one-shot —
	## через play_swing/play_parry/play_transform и состояние SKILL.
	if _anim != null:
		match to:
			PlayerPawn.State.RUN:
				_oneshot_left = 0.0
				if _anim.has_animation("run"):
					_anim.play("run")
			PlayerPawn.State.IDLE:
				_oneshot_left = 0.0
				if _anim.has_animation("idle"):
					_anim.play("idle")
			PlayerPawn.State.DOWN:
				_oneshot_left = 0.0
				if _anim.has_animation("death"):
					_anim.play("death")
			PlayerPawn.State.SKILL, PlayerPawn.State.DODGE:
				_play_oneshot("skill")
			_:
				pass
	match to:
		PlayerPawn.State.DOWN:
			_play_down()
		_:
			if from == PlayerPawn.State.DOWN:
				_play_respawn()

func _play_down() -> void:
	if _body_tween != null and _body_tween.is_valid():
		_body_tween.kill()
	if _root == null:
		return
	if _anim != null and _anim.has_animation("death"):
		return ## падение играет анимация death модели
	_body_tween = create_tween()
	_body_tween.tween_property(_root, "rotation:x", -PI / 2.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

func _play_respawn() -> void:
	if _body_tween != null and _body_tween.is_valid():
		_body_tween.kill()
	if _root == null:
		return
	if _anim != null:
		if _anim.has_animation("idle"):
			_anim.play("idle")
		return ## модель не ронялась твином — только сброс one-shot
	_root.rotation.x = 0.0
	var target_scale := Vector3.ONE * (_def.visual_scale if _def != null else 1.0)
	_body_tween = create_tween()
	_body_tween.tween_property(_root, "scale", target_scale * 1.25, 0.12)
	_body_tween.tween_property(_root, "scale", target_scale, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)

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
			if i < _orig_emissions.size():
				var mat := _materials[i]
				mat.emission = _orig_emissions[i]
				mat.emission_enabled = _orig_emissions[i] != Color.BLACK
				mat.emission_energy_multiplier = 1.0)

## Неистовство (сервер, форма III): красное свечение силуэта — локальная косметика.
func set_frenzy(on: bool) -> void:
	if _frenzy_on == on:
		return
	_frenzy_on = on
	for i in _materials.size():
		var mat := _materials[i]
		if on:
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.2, 0.15)
			mat.emission_energy_multiplier = 1.6
		else:
			mat.emission = _orig_emissions[i]
			mat.emission_enabled = _orig_emissions[i] != Color.BLACK
			mat.emission_energy_multiplier = 1.0

## Вращение рывка Валькирии (fx_skill_dash).
func play_skill_dash() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = create_tween()
	_swing_tween.tween_property(_root, "rotation:y", _root.rotation.y + TAU, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## Подсветка стойки парирования (открывается/гаснет локально, косметика).
func set_guard_tint(on: bool) -> void:
	for i in _materials.size():
		var mat := _materials[i]
		if on:
			mat.emission_enabled = true
			mat.emission = Color(0.6, 0.8, 1.0)
			mat.emission_energy_multiplier = 1.3
		elif not _frenzy_on:
			mat.emission = _orig_emissions[i]
			mat.emission_enabled = _orig_emissions[i] != Color.BLACK
			mat.emission_energy_multiplier = 1.0

## Короткая вспышка-отдача при успешном парировании.
func play_parry_success() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	var target_scale := Vector3.ONE * (_def.visual_scale if _def != null else 1.0)
	var tw := create_tween()
	tw.tween_property(_root, "scale", target_scale * 1.1, 0.07)
	tw.tween_property(_root, "scale", target_scale, 0.13)
	set_guard_tint(false)

## Замах оружия (вызывается fx_swing RPC на всех пирах).
func play_swing() -> void:
	if _anim != null:
		_play_oneshot("attack")
		return
	if weapon_pivot == null or not is_instance_valid(weapon_pivot):
		return
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = create_tween()
	_swing_tween.tween_property(weapon_pivot, "rotation:x", -2.3, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(weapon_pivot, "rotation:x", 0.95, 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_swing_tween.tween_property(weapon_pivot, "rotation:x", -0.15, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
