class_name PlayerPawn
extends CharacterBody3D
## Пешка игрока (Этап 3 — 8 классов × 3 формы, единая боевая логика).
## Сетевая модель (ТЗ §16):
##  - сервер симулирует движение/бой ВСЕХ пешек (авторитет);
##  - клиент-владелец лишь отправляет команды ввода (unreliable_ordered + reliable для действий);
##  - состояние репликуется BodySync-снапшотами и интерполируется на клиентах.
## Offline (одиночная игра без пира) работает по той же серверной ветке.

enum State { IDLE = 0, RUN = 1, ATTACK = 2, DODGE = 3, DOWN = 4, SKILL = 5 }

const GRAVITY: float = 24.0
const AIM_PLANE_Y: float = 1.0

var team: int = Units.Team.HERO
var owner_peer: int = 1
var player_name: String = "Игрок"
## class_id — ВСЕГДА id базовой формы (из лобби); текущая форма — form_index,
## а class_def указывает на ClassDefinition активной формы (I/II/III).
var class_id: StringName = &"berserk"
var class_def: ClassDefinition

## Реплицируемое состояние.
var state: int = State.IDLE
var aim_yaw: float = 0.0
var attack_id: int = 0
var kills: int = 0
var damage_dealt: float = 0.0
## Текущая форма эволюции (0 = I, 1 = II, 2 = III) — реплицируется полем "f".
var form_index: int = 0

## Трейты форм (сервер): счётчик комбо для ударной волны и режим неистовства.
var _combo_hits: int = 0
var _frenzy_active: bool = false

## Валькирия (Этап 3.1) — серверные состояния умения/парирования/фантомов.
var _skill_cd_left: float = 0.0
var _skill_dir := Vector3.ZERO
var _skill_hit_done := false
var _parry_cd_left: float = 0.0
var _parry_window_until_msec: int = 0
var _parry_guard_until_msec: int = 0
var _parries_landed: int = 0 ## счётчик успешных парирований (тесты/HUD)
var _empower_mult: float = 1.0 ## усиление следующей ближней атаки (после парирования)
var _extra_strike_done := false
var _chain_done_this_swing := false
## Очередь эхо-ударов «зеркальных копий» (форма III): серверные таймеры,
## каждый — ОДИН радиальный проход; урон копий НЕ порождает новые копии.
var _phantom_queue: Array = []

## Внешний источник ввода (автотесты / будущие AI-напарники). Если задан — заменяет Input.
var external_input: Variant = null

## Эффективные характеристики: база (ClassDefinition) × серверные модификаторы прогрессии.
## Ресурс class_def НИКОГДА не мутируется — он общий для всех пешек класса.
var st: Dictionary = {}
var _prog_mods: Dictionary = {}
var _lifesteal: float = 0.0
var _hitbox_base_scale := Vector3.ONE

var _seq_out: int = 0
var _seq_in: int = 0
var _latest_input := {"move": Vector2.ZERO, "aim_yaw": 0.0}
var _state_time: float = 0.0
var _attack_phase: int = 0 ## 0 windup / 1 active / 2 recover
var _ctrl_vel := Vector3.ZERO ## управляемая составляющая скорости (без отбрасывания)
var _dodge_dir := Vector3.ZERO
var _dodge_time_left: float = 0.0
var _attack_cd_left: float = 0.0
var _dodge_cd_left: float = 0.0
var _respawn_left: float = 0.0
var _prev_attack_pressed := false
var _prev_skill_pressed := false
var _prev_parry_pressed := false

@onready var health: HealthComponent = $Health
@onready var hitbox: HitboxComponent = $Hitbox
@onready var kb: KnockbackComponent = $Knockback
@onready var visuals: Node3D = $Visuals
@onready var camera_rig: Node3D = $CameraRig
@onready var name_label: Label3D = $NameLabel

func _ready() -> void:
	if class_def == null:
		class_def = Classes.get_class_def(class_id)
	if class_def == null:
		push_error("[PlayerPawn] Класс %s не найден" % class_id)
		return
	## Надёжность: пешка всегда стартует с базовой формы I, даже если в данных
	## class_id ошибочно указывает на форму II/III (лобби такие id отклоняет).
	if class_def.form_index != 0:
		class_id = class_def.base_id
		class_def = Classes.get_form_def(class_id, 0)
		if class_def == null:
			push_error("[PlayerPawn] Базовая форма не найдена для %s" % class_id)
			return
	form_index = 0
	add_to_group("player_pawns")
	add_to_group("hero_units")
	_build_base_stats()
	health.setup(st["max_health"])
	health.died.connect(_on_died)
	health.health_changed.connect(_update_frenzy)
	hitbox.damage = st["attack_damage"]
	hitbox.knockback_force = st["attack_knockback"]
	hitbox.owner_team = Units.Team.HERO
	var hb_shape := hitbox.get_node_or_null(^"CollisionShape3D")
	if hb_shape != null:
		_hitbox_base_scale = hb_shape.scale
	_update_name_label()
	_rebuild_visuals()
	if is_local_pawn():
		camera_rig.activate_for(self)
		Events.local_pawn_ready.emit(self)

func _update_name_label() -> void:
	var suffix := "" if form_index == 0 else (" • II" if form_index == 1 else " • III")
	name_label.text = player_name + suffix

func _rebuild_visuals() -> void:
	if visuals != null and visuals.has_method("rebuild"):
		visuals.rebuild(class_def)

func _build_base_stats() -> void:
	var d := class_def
	st = {
		"max_health": d.max_health,
		"move_speed": d.move_speed,
		"acceleration": d.acceleration,
		"friction": d.friction,
		"attack_damage": d.attack_damage,
		"attack_windup": d.attack_windup,
		"attack_active": d.attack_active,
		"attack_recover": d.attack_recover,
		"attack_cooldown": d.attack_cooldown,
		"attack_knockback": d.attack_knockback,
		"attack_move_lock": d.attack_move_lock,
		"dodge_speed": d.dodge_speed,
		"dodge_duration": d.dodge_duration,
		"dodge_cooldown": d.dodge_cooldown,
		"dodge_iframes": d.dodge_iframes,
		"respawn_time": d.respawn_time,
		"respawn_health_factor": d.respawn_health_factor,
		## Трейты форм (данные ClassDefinition; нейтральны, если не заданы).
		"shockwave_every_n_hits": d.shockwave_every_n_hits,
		"shockwave_radius": d.shockwave_radius,
		"shockwave_damage_mult": d.shockwave_damage_mult,
		"shockwave_knockback": d.shockwave_knockback,
		"execute_threshold": d.execute_threshold,
		"execute_damage_mult": d.execute_damage_mult,
		"frenzy_hp_threshold": d.frenzy_hp_threshold,
		"frenzy_damage_mult": d.frenzy_damage_mult,
		"frenzy_attack_cd_mult": d.frenzy_attack_cd_mult,
		## Валькирия: рывок с круговым ударом (умение).
		"skill_dash_speed": d.skill_dash_speed,
		"skill_dash_duration": d.skill_dash_duration,
		"skill_cooldown": d.skill_cooldown,
		"skill_whirl_radius": d.skill_whirl_radius,
		"skill_whirl_damage_mult": d.skill_whirl_damage_mult,
		"skill_whirl_knockback": d.skill_whirl_knockback,
		## Валькирия: парирование.
		"parry_window": d.parry_window,
		"parry_cooldown": d.parry_cooldown,
		"parry_guard_mult": d.parry_guard_mult,
		"parry_guard_duration": d.parry_guard_duration,
		"parry_empower_mult": d.parry_empower_mult,
		"parry_counter_radius": d.parry_counter_radius,
		"parry_counter_damage_mult": d.parry_counter_damage_mult,
		"parry_counter_knockback": d.parry_counter_knockback,
		"parry_counter_stun": d.parry_counter_stun,
		## Комбо/дальность/цепочки/фантомы.
		"combo_extra_strikes": d.combo_extra_strikes,
		"melee_range_scale": d.melee_range_scale,
		"chain_targets": d.chain_targets,
		"chain_radius": d.chain_radius,
		"chain_damage_falloff": d.chain_damage_falloff,
		"phantom_repeats": d.phantom_repeats,
		"phantom_delay": d.phantom_delay,
		"phantom_damage_mult": d.phantom_damage_mult,
	}

## Сервер применяет прогрессию (улучшения + баффы магазина).
func apply_progression(mods: Dictionary, extra: Dictionary) -> void:
	_prog_mods = mods
	_lifesteal = float(extra.get("lifesteal", 0.0))
	refresh_effective_stats()

func refresh_effective_stats() -> void:
	if class_def == null:
		return
	var d := class_def
	var m := _prog_mods
	_build_base_stats()
	st["max_health"] = d.max_health * float(m.get("max_health_mult", 1.0))
	st["move_speed"] = d.move_speed * float(m.get("speed_mult", 1.0))
	## Неистовство (форма III Берсерки): множители поверх прогрессии, пока HP низкое.
	var frenzy_dmg := float(st["frenzy_damage_mult"]) if _frenzy_active else 1.0
	var frenzy_cd := float(st["frenzy_attack_cd_mult"]) if _frenzy_active else 1.0
	st["attack_damage"] = d.attack_damage * float(m.get("damage_mult", 1.0)) * frenzy_dmg
	st["attack_knockback"] = d.attack_knockback * float(m.get("kb_mult", 1.0))
	var cd := float(m.get("attack_cd_mult", 1.0)) * frenzy_cd
	st["attack_windup"] = maxf(0.03, d.attack_windup * cd)
	st["attack_active"] = maxf(0.05, d.attack_active * cd)
	st["attack_recover"] = maxf(0.03, d.attack_recover * cd)
	st["attack_cooldown"] = maxf(0.0, d.attack_cooldown * cd)
	st["dodge_cooldown"] = maxf(0.3, d.dodge_cooldown * float(m.get("dodge_cd_mult", 1.0)))
	st["dodge_iframes"] = d.dodge_iframes + float(m.get("iframe_add", 0.0))
	st["respawn_health_factor"] = minf(0.95, d.respawn_health_factor + float(m.get("respawn_add", 0.0)))
	## Применение к компонентам (безопасно: максимум растёт — dolечиваем дельту).
	var prev_max := health.max_health
	health.max_health = st["max_health"]
	if health.max_health > prev_max and not health.is_dead:
		health.health = minf(health.max_health, health.health + (health.max_health - prev_max))
	## Защитный бонус парирования множится поверх прогрессии (пока активен).
	var guard_mult := float(st["parry_guard_mult"]) if _parry_guard_active() else 1.0
	health.incoming_damage_multiplier = float(m.get("damage_taken_mult", 1.0)) * guard_mult
	## Усиленная следующая атака (парирование) — до первого завершённого взмаха.
	hitbox.damage = st["attack_damage"] * _empower_mult
	hitbox.knockback_force = st["attack_knockback"]
	hitbox.execute_threshold = float(st["execute_threshold"])
	hitbox.execute_mult = float(st["execute_damage_mult"])
	var hb_shape := hitbox.get_node_or_null(^"CollisionShape3D")
	if hb_shape != null:
		var total_range := float(m.get("range_mult", 1.0)) * float(st["melee_range_scale"])
		hb_shape.scale = _hitbox_base_scale * clampf(total_range, 0.5, 2.2)

func effective_max_health() -> float:
	if st.has("max_health"):
		return float(st["max_health"])
	return class_def.max_health if class_def != null else 100.0

# ------------------------------------------------------------------ эволюция (Этап 3)

## Серверная проверка условия эволюции (уровень прогрессии). Вызывается
## ProgressionSystem после повышения уровня. Идемпотентна: повторные вызовы
## на уже открытой/финальной форме ничего не делают. Возвращает число
## состоявшихся эволюций (0 или больше — возможен скачок сразу на 2 уровня).
func try_evolve_for_level(level: int) -> int:
	if not Net.is_server() or class_def == null or not is_inside_tree():
		return 0
	var evolved := 0
	while true:
		var next_def := Classes.get_next_form(class_id, form_index)
		if next_def == null:
			break
		if level < next_def.unlock_level:
			break
		_apply_form(next_def)
		evolved += 1
	return evolved

## Серверное применение формы: данные и статы меняются здесь; узел пешки НЕ
## пересоздаётся — HP, позиция, улучшения, cooldown, owner_peer и сетевой путь
## спавнера сохраняются (безопасная замена модели и характеристик).
func _apply_form(new_def: ClassDefinition) -> void:
	class_def = new_def
	form_index = new_def.form_index
	## Пересчёт эффективных статов от НОВОЙ базы × накопленные модификаторы.
	## Текущее HP не сбрасывается: при росте максимума refresh долечивает дельту
	## (то же поведение, что у улучшения iron_body).
	refresh_effective_stats()
	_update_name_label()
	_rebuild_visuals()
	Events.unit_evolved.emit(self, form_index, new_def.display_name)
	print("[PlayerPawn] ЭВОЛЮЦИЯ peer %d: %s -> форма %d «%s»" % [owner_peer, class_id, form_index + 1, new_def.display_name])
	fx_evolve.rpc(new_def.display_name)

## Неистовство (канон §6.6: бонусы при потере собственного здоровья) — только сервер.
## Подключено к health_changed(current, maximum); аргументы не нужны — состояние
## читается из health напрямую. Вызывается также напрямую из тестов.
func _update_frenzy(_current: float = 0.0, _maximum: float = 0.0) -> void:
	if not Net.is_server() or class_def == null:
		return
	var threshold := float(st.get("frenzy_hp_threshold", 0.0))
	var want := false
	if threshold > 0.0 and not health.is_dead:
		want = health.health_factor() < threshold
	if want == _frenzy_active:
		return
	_frenzy_active = want
	refresh_effective_stats()
	if visuals != null and visuals.has_method("set_frenzy"):
		visuals.set_frenzy(want)

## Ударная волна (канон §6.6): серверный радиальный урон и отбрасывание
## вокруг пешки. Урон идёт через обычную pipeline (Units.make_damage ->
## HealthComponent), поэтому вклад в XP/статистику/награды учитывается штатно.
func _server_shockwave(radius: float, amount: float, kb_force: float) -> void:
	## is_inside_tree: физика может доставить area-сигнал пешке, уже выведенной
	## из дерева при смене сцены (реванш) — get_tree()/rpc там недопустимы.
	if not Net.is_server() or amount <= 0.0 or not is_inside_tree():
		return
	var center := global_position
	var targets: Array = []
	targets.append_array(get_tree().get_nodes_in_group("enemy_units"))
	targets.append_array(get_tree().get_nodes_in_group("destructibles")) ## форма III «разрушает укрытия»
	for node in targets:
		var body := node as Node3D
		if body == null or not is_instance_valid(body):
			continue
		var th := body.get_node_or_null(^"Health") as HealthComponent
		if th == null or th.is_dead:
			continue
		var to_t := body.global_position - center
		to_t.y = 0.0
		if to_t.length() > radius:
			continue
		var dir := to_t.normalized() if to_t.length_squared() > 0.001 else -global_transform.basis.z
		var dmg := Units.make_damage(amount, self, owner_peer, dir, kb_force, body.global_position)
		if th.take_damage(dmg) and body.has_method("on_damage_received"):
			body.call("on_damage_received", dmg)
	fx_shockwave.rpc(radius)

func is_local_pawn() -> bool:
	return owner_peer == Net.my_id()

func get_health() -> HealthComponent:
	return health

# ------------------------------------------------------------------ ввод

func _physics_process(delta: float) -> void:
	if Net.is_server():
		if (is_local_pawn() or not Net.is_online()) and state != State.DOWN:
			_consume_local_input()
		_server_sim(delta)
	else:
		if is_local_pawn() and Net.is_online():
			_client_send_input()

func _sample_input() -> Dictionary:
	var result := {
		"move": Vector2.ZERO,
		"aim_yaw": aim_yaw,
		"press_attack": false,
		"press_dodge": false,
		"press_skill": false,
		"press_parry": false,
	}
	if external_input != null:
		var e: Dictionary = external_input
		result["move"] = (e.get("move", Vector2.ZERO) as Vector2).limit_length(1.0)
		result["aim_yaw"] = float(e.get("aim_yaw", aim_yaw))
		result["press_attack"] = bool(e.get("press_attack", false))
		result["press_dodge"] = bool(e.get("press_dodge", false))
		result["press_skill"] = bool(e.get("press_skill", false))
		result["press_parry"] = bool(e.get("press_parry", false))
		return result
	var raw := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_yaw := 0.0
	if camera_rig != null:
		cam_yaw = camera_rig.global_rotation.y
	var fwd := Vector3(-sin(cam_yaw), 0.0, -cos(cam_yaw))
	var right := Vector3(cos(cam_yaw), 0.0, -sin(cam_yaw))
	var world_dir := right * raw.x + fwd * (-raw.y)
	result["move"] = Vector2(world_dir.x, world_dir.z).limit_length(1.0)
	result["aim_yaw"] = _mouse_aim_yaw()
	result["press_attack"] = Input.is_action_pressed("attack")
	result["press_dodge"] = Input.is_action_just_pressed("dodge")
	result["press_skill"] = Input.is_action_just_pressed("skill")
	result["press_parry"] = Input.is_action_just_pressed("parry")
	return result

func _mouse_aim_yaw() -> float:
	var cam: Camera3D = camera_rig.get_active_camera() if camera_rig != null else null
	if cam == null:
		return aim_yaw
	var mouse_pos := get_viewport().get_mouse_position()
	var origin: Vector3 = cam.project_ray_origin(mouse_pos)
	var dir: Vector3 = cam.project_ray_normal(mouse_pos)
	if absf(dir.y) < 0.0001:
		return aim_yaw
	var t: float = (AIM_PLANE_Y - origin.y) / dir.y
	if t < 0.0:
		return aim_yaw
	var target: Vector3 = origin + dir * t
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return aim_yaw
	return atan2(-to_target.x, -to_target.z)

func _client_send_input() -> void:
	var s := _sample_input()
	sv_input.rpc_id(1, _seq_out, s["move"], s["aim_yaw"])
	_seq_out += 1
	var attack_pressed: bool = s["press_attack"]
	if attack_pressed and not _prev_attack_pressed:
		sv_request_action.rpc_id(1, "attack")
	if s["press_dodge"]:
		sv_request_action.rpc_id(1, "dodge")
	var skill_pressed: bool = s["press_skill"]
	if skill_pressed and not _prev_skill_pressed:
		sv_request_action.rpc_id(1, "skill")
	var parry_pressed: bool = s["press_parry"]
	if parry_pressed and not _prev_parry_pressed:
		sv_request_action.rpc_id(1, "parry")
	_prev_attack_pressed = attack_pressed
	_prev_skill_pressed = skill_pressed
	_prev_parry_pressed = parry_pressed

func _consume_local_input() -> void:
	var s := _sample_input()
	_latest_input["move"] = s["move"]
	_latest_input["aim_yaw"] = s["aim_yaw"]
	var attack_pressed: bool = s["press_attack"]
	if attack_pressed and not _prev_attack_pressed:
		try_attack()
	if s["press_dodge"]:
		try_dodge()
	var skill_pressed: bool = s["press_skill"]
	if skill_pressed and not _prev_skill_pressed:
		try_skill()
	var parry_pressed: bool = s["press_parry"]
	if parry_pressed and not _prev_parry_pressed:
		try_parry()
	_prev_attack_pressed = attack_pressed
	_prev_skill_pressed = skill_pressed
	_prev_parry_pressed = parry_pressed

@rpc("any_peer", "call_remote", "unreliable_ordered")
func sv_input(seq: int, move: Vector2, aim: float) -> void:
	if not Net.is_server():
		return
	## Гонка смены сцены (реванш/выход в меню): пакет может достичь пешку,
	## уже выведенную из дерева — там multiplayer == null. Игнорируем: пешка
	## уничтожается, её состояние менять нельзя.
	if not is_inside_tree():
		return
	if multiplayer.get_remote_sender_id() != owner_peer:
		return ## валидация: команды принимаются только от владельца пешки (ТЗ §16)
	if seq <= _seq_in:
		return
	_seq_in = seq
	_latest_input["move"] = move.limit_length(1.0)
	_latest_input["aim_yaw"] = aim

@rpc("any_peer", "call_remote", "reliable")
func sv_request_action(action: String) -> void:
	if not Net.is_server():
		return
	if not is_inside_tree():
		return ## см. sv_input: защита от RPC в окно смены сцены
	if multiplayer.get_remote_sender_id() != owner_peer:
		return
	match action:
		"attack":
			try_attack()
		"dodge":
			try_dodge()
		"skill":
			try_skill()
		"parry":
			try_parry()

# ------------------------------------------------------------------ серверная симуляция

func try_attack() -> void:
	if not Net.is_server() or class_def == null:
		return
	if state == State.DOWN or state == State.ATTACK or state == State.DODGE or state == State.SKILL:
		return
	if _attack_cd_left > 0.0:
		return
	state = State.ATTACK
	_state_time = 0.0
	_attack_phase = 0
	_extra_strike_done = false
	_chain_done_this_swing = false
	attack_id += 1
	_attack_cd_left = float(st["attack_windup"]) + float(st["attack_active"]) + float(st["attack_recover"]) + float(st["attack_cooldown"])
	## Зеркальные копии (форма III Валькирии) повторяют взмах: серверная очередь
	## эхо-ударов с ЗАФИКСИРОВАННЫМ сейчас уроном (включая усиление парирования).
	if int(st.get("phantom_repeats", 0)) > 0:
		_schedule_phantoms(2.8 * float(st.get("melee_range_scale", 1.0)),
			float(st["attack_damage"]) * _empower_mult * float(st["phantom_damage_mult"]),
			float(st["attack_knockback"]) * 0.5)
	fx_swing.rpc()

func try_dodge() -> void:
	if not Net.is_server() or class_def == null:
		return
	if state == State.DOWN or state == State.DODGE or state == State.ATTACK or state == State.SKILL:
		return
	if _dodge_cd_left > 0.0:
		return
	var move: Vector2 = _latest_input["move"]
	var dir := Vector3(move.x, 0.0, move.y)
	if dir.length_squared() < 0.01:
		dir = -global_transform.basis.z ## рывок назад, если стоим
	_dodge_dir = dir.normalized()
	_dodge_time_left = st["dodge_duration"]
	state = State.DODGE
	_state_time = 0.0
	_dodge_cd_left = st["dodge_cooldown"]
	kb.cancel()
	health.grant_invulnerability(st["dodge_iframes"])

# ------------------------------------------------------------------ умение Валькирии (Этап 3.1)

## Рывок с круговым ударом (канон §6.1): направленный рывок (движение = физика
## move_and_slide — сквозь стены не проходит), в середине рывка — ОДИН
## радиальный проход урона вокруг пешки (каждая цель поражается не более
## одного раза за активацию). Параметры — данные класса.
func try_skill() -> void:
	if not Net.is_server() or class_def == null or not is_inside_tree():
		return
	if float(st.get("skill_dash_speed", 0.0)) <= 0.0:
		return ## у класса нет умения рывка
	if state == State.DOWN or state == State.ATTACK or state == State.DODGE or state == State.SKILL:
		return
	if _skill_cd_left > 0.0:
		return
	var move: Vector2 = _latest_input["move"]
	var dir := Vector3(move.x, 0.0, move.y)
	if dir.length_squared() < 0.01:
		dir = -global_transform.basis.z ## без движения — рывок по направлению взгляда
	_skill_dir = dir.normalized()
	_skill_hit_done = false
	state = State.SKILL
	_state_time = 0.0
	_skill_cd_left = float(st["skill_cooldown"])
	kb.cancel()
	fx_skill_dash.rpc()

func _advance_skill() -> void:
	var dur := float(st["skill_dash_duration"])
	if not _skill_hit_done and _state_time >= dur * 0.5:
		_skill_hit_done = true
		var amount := float(st["attack_damage"]) * float(st["skill_whirl_damage_mult"])
		_server_shockwave(float(st["skill_whirl_radius"]), amount, float(st["skill_whirl_knockback"]))
		fx_skill.rpc()
		## Копии формы III повторяют и круговой удар.
		if int(st.get("phantom_repeats", 0)) > 0:
			_schedule_phantoms(float(st["skill_whirl_radius"]),
				amount * float(st["phantom_damage_mult"]),
				float(st["skill_whirl_knockback"]) * 0.5)
	if _state_time >= dur:
		state = State.IDLE
		_state_time = 0.0

# ------------------------------------------------------------------ парирование (Этап 3.1)

## Открыть окно парирования (короткое; успех — только если вражеская атака
## пришлась ВНУТРИ окна). Cooldown ограничивает спам; состояние атаки/рывка
## запрещает стойку. Сервер-авторитетно: клиент лишь просит (sv_request_action).
func try_parry() -> void:
	if not Net.is_server() or class_def == null or not is_inside_tree():
		return
	if float(st.get("parry_window", 0.0)) <= 0.0:
		return ## у класса нет парирования
	if state == State.DOWN or state == State.ATTACK or state == State.SKILL:
		return
	if _parry_cd_left > 0.0:
		return
	_parry_cd_left = float(st["parry_cooldown"])
	_parry_window_until_msec = Time.get_ticks_msec() + int(float(st["parry_window"]) * 1000.0)
	fx_parry.rpc()

func _parry_guard_active() -> bool:
	return _parry_guard_until_msec > 0 and Time.get_ticks_msec() < _parry_guard_until_msec

## Вызывается HurtboxComponent/снарядом ДО нанесения урона (только сервер).
## Возврат true = атака полностью отменена парированием. Окно расходуется
## РОВНО один раз: повторные попадания той же или других атак бонус не дублируют.
func try_parry_hit(_damage: Dictionary) -> bool:
	if not Net.is_server():
		return false
	if _parry_window_until_msec <= 0 or Time.get_ticks_msec() > _parry_window_until_msec:
		return false ## окно не открывали или оно истекло — урон идёт штатно
	_parry_window_until_msec = 0 ## окно израсходовано (однократность)
	_parries_landed += 1
	## 1) Защитный бонус: входящий урон снижен на короткое время.
	_parry_guard_until_msec = Time.get_ticks_msec() + int(float(st["parry_guard_duration"]) * 1000.0)
	refresh_effective_stats() ## применит parry_guard_mult к incoming_damage_multiplier
	## 2) Следующая ближняя атака усилена (снимется после первого взмаха).
	_empower_mult = float(st["parry_empower_mult"])
	hitbox.damage = float(st["attack_damage"]) * _empower_mult
	## 3) Контратака: круговой удар вокруг себя (форма III — со стаггером группы).
	_parry_counter()
	fx_parry_success.rpc()
	return true

func _parry_counter() -> void:
	if not is_inside_tree():
		return
	var radius := float(st["parry_counter_radius"])
	var amount := float(st["attack_damage"]) * float(st["parry_counter_damage_mult"])
	var kb_force := float(st["parry_counter_knockback"])
	var stun := float(st["parry_counter_stun"])
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var foe := node as EnemyBase
		if foe == null or not is_instance_valid(foe) or foe.health.is_dead:
			continue
		var to_t := foe.global_position - global_position
		to_t.y = 0.0
		if to_t.length() > radius:
			continue
		var dir := to_t.normalized() if to_t.length_squared() > 0.001 else -global_transform.basis.z
		var dmg := Units.make_damage(amount, self, owner_peer, dir, kb_force, foe.global_position)
		## take_damage эмитит damage_taken — kb/hitstun/эффекты враг обрабатывает
		## штатно (EnemyBase._on_damaged); прямой вызов on_damage_received не нужен.
		if foe.health.take_damage(dmg) and stun > 0.0:
			foe.apply_external_stun(stun)

## Зеркальные копии (форма III): серверные отложенные эхо-удары. Лимит очереди
## защищает от накопления при быстрых активациях; урон копий не вызывает
## on_hit_landed и НЕ порождает новые копии/цепочки (рекурсия исключена).
func _schedule_phantoms(radius: float, amount: float, kb_force: float) -> void:
	var n := int(st.get("phantom_repeats", 0))
	if n <= 0 or amount <= 0.0:
		return
	var delay := float(st.get("phantom_delay", 0.22))
	for i in n:
		if _phantom_queue.size() >= 4:
			break ## жёсткий лимит одновременных эффектов
		_phantom_queue.append({"t": delay * float(i + 1), "radius": radius, "amount": amount, "kb": kb_force})

func _process_phantoms(delta: float) -> void:
	if _phantom_queue.is_empty():
		return
	for i in range(_phantom_queue.size() - 1, -1, -1):
		var ph: Dictionary = _phantom_queue[i]
		ph["t"] = float(ph["t"]) - delta
		if float(ph["t"]) <= 0.0:
			_phantom_queue.remove_at(i)
			_server_shockwave(float(ph["radius"]), float(ph["amount"]), float(ph["kb"]))
			fx_phantom.rpc()

## Цепной удар «Багровой богини»: первый подтверждённый удар взмаха переходит
## на N ближайших врагов в радиусе от ПЕРВИЧНОЙ цели (вне дуги взмаха).
func _do_chain_attack(primary: Node, base_amount: float) -> void:
	if not Net.is_server() or not is_inside_tree() or base_amount <= 0.0:
		return
	var amount := base_amount * float(st["chain_damage_falloff"])
	var origin: Vector3 = global_position
	if primary is Node3D:
		origin = (primary as Node3D).global_position
	var candidates: Array = []
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var foe := node as EnemyBase
		if foe == null or foe == primary or not is_instance_valid(foe) or foe.health.is_dead:
			continue
		var d := foe.global_position.distance_to(origin)
		if d <= float(st["chain_radius"]):
			candidates.append([d, foe])
	candidates.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var hit_any := false
	for i in mini(int(st["chain_targets"]), candidates.size()):
		var foe: EnemyBase = candidates[i][1]
		var to_t := foe.global_position - origin
		to_t.y = 0.0
		var dir := to_t.normalized() if to_t.length_squared() > 0.001 else Vector3.FORWARD
		var dmg := Units.make_damage(amount, self, owner_peer, dir, float(st["attack_knockback"]) * 0.5, foe.global_position)
		if foe.health.take_damage(dmg):
			hit_any = true
	if hit_any:
		fx_chain.rpc()

func _server_sim(delta: float) -> void:
	_attack_cd_left = maxf(0.0, _attack_cd_left - delta)
	_dodge_cd_left = maxf(0.0, _dodge_cd_left - delta)
	_skill_cd_left = maxf(0.0, _skill_cd_left - delta)
	_parry_cd_left = maxf(0.0, _parry_cd_left - delta)
	_state_time += delta
	## Истечение защитного бонуса парирования — однократный пересчёт статов.
	if _parry_guard_until_msec > 0 and Time.get_ticks_msec() >= _parry_guard_until_msec:
		_parry_guard_until_msec = 0
		refresh_effective_stats()
	_process_phantoms(delta)

	if state == State.DOWN:
		_respawn_left -= delta
		_ctrl_vel = Vector3.ZERO
		var kb_down := kb.consume(delta)
		velocity.x = kb_down.x
		velocity.z = kb_down.z
		_apply_gravity(delta)
		if kb_down.y > 0.0 and is_on_floor():
			velocity.y = kb_down.y
		move_and_slide()
		if _respawn_left <= 0.0:
			_respawn()
		return

	## Поворот к прицелу.
	var target_yaw := float(_latest_input["aim_yaw"])
	rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, delta * 18.0))

	var move: Vector2 = _latest_input["move"]
	var desired := Vector3(move.x, 0.0, move.y)
	if desired.length_squared() > 1.0:
		desired = desired.normalized()

	var speed: float = st["move_speed"]
	var control_lock := 0.0
	match state:
		State.ATTACK:
			control_lock = st["attack_move_lock"]
			_advance_attack(delta)
		State.DODGE:
			_dodge_time_left -= delta
			if _dodge_time_left <= 0.0:
				state = State.IDLE
			desired = Vector3.ZERO
		State.SKILL:
			_advance_skill()
			desired = Vector3.ZERO
		_:
			pass

	if state == State.DODGE:
		_ctrl_vel = _dodge_dir * float(st["dodge_speed"])
	elif state == State.SKILL:
		## Рывок умения: движение через move_and_slide — столкновения со
		## стенами/колоннами обрабатываются физикой (сквозь геометрию не проходит).
		_ctrl_vel = _skill_dir * float(st["skill_dash_speed"])
	else:
		desired *= speed * (1.0 - control_lock)
		_ctrl_vel.x = move_toward(_ctrl_vel.x, desired.x, float(st["acceleration"]) * delta)
		_ctrl_vel.z = move_toward(_ctrl_vel.z, desired.z, float(st["acceleration"]) * delta)
		if desired.length_squared() < 0.01:
			_ctrl_vel.x = move_toward(_ctrl_vel.x, 0.0, float(st["friction"]) * delta)
			_ctrl_vel.z = move_toward(_ctrl_vel.z, 0.0, float(st["friction"]) * delta)
		if state != State.ATTACK:
			state = State.RUN if (_ctrl_vel.x * _ctrl_vel.x + _ctrl_vel.z * _ctrl_vel.z) > 1.0 else State.IDLE

	## Итоговая скорость = управление + отбрасывание (КБ не накапливается в velocity).
	var kb_vel := kb.consume(delta)
	velocity.x = _ctrl_vel.x + kb_vel.x
	velocity.z = _ctrl_vel.z + kb_vel.z
	_apply_gravity(delta)
	if kb_vel.y > 0.0 and is_on_floor():
		velocity.y = kb_vel.y
	move_and_slide()

func _advance_attack(_delta: float) -> void:
	var windup: float = st["attack_windup"]
	var active: float = st["attack_active"]
	var recover: float = st["attack_recover"]
	if _attack_phase == 0 and _state_time >= windup:
		_attack_phase = 1
		hitbox.activate(active)
	if _attack_phase == 1 and _state_time >= windup + active:
		_attack_phase = 2
		hitbox.deactivate()
	## «Клинковый танец» (форма II): дополнительный удар комбо — короткая
	## повторная активация хитбокса в восстановлении (hit_once_per_activation
	## сбрасывается на каждую активацию — та же цель может получить оба удара).
	if _attack_phase == 2 and not _extra_strike_done and int(st.get("combo_extra_strikes", 0)) > 0 \
			and _state_time >= windup + active + 0.10 and _state_time < windup + active + recover:
		_extra_strike_done = true
		hitbox.activate(minf(0.12, maxf(0.08, recover * 0.5)))
	if _state_time >= windup + active + recover:
		state = State.IDLE
		_state_time = 0.0
		hitbox.deactivate()
		## Усиление парирования живёт ровно один взмах.
		if _empower_mult != 1.0:
			_empower_mult = 1.0
			hitbox.damage = float(st["attack_damage"])

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, -1.0)

## Серверный хук: наш удар прошёл (статистика + «вес» попадания).
func on_hit_landed(target: Node, dmg: Dictionary) -> void:
	if not Net.is_server():
		return
	damage_dealt += float(dmg.get("amount", 0.0))
	if health != null and target != null and target.has_method("get_health"):
		var th := target.get_health() as HealthComponent
		if th != null and th.is_dead:
			kills += 1
			## «Кровавая грива»: лечение за подтверждённое сервером убийство.
			if _lifesteal > 0.0:
				health.heal(effective_max_health() * _lifesteal)
	Events.server_hit_landed.emit(self, target, dmg)
	## Цепной удар «Багровой богини»: один раз за взмах, от первичной цели.
	## Урон цепочки НЕ вызывает on_hit_landed — рекурсия и дубли наград исключены.
	if state == State.ATTACK and not _chain_done_this_swing and int(st.get("chain_targets", 0)) > 0:
		_chain_done_this_swing = true
		_do_chain_attack(target, float(dmg.get("amount", 0.0)))
	## Комбо-трейт формы II+: каждый N-й подтверждённый удар — ударная волна.
	var every := int(st.get("shockwave_every_n_hits", 0))
	if every > 0 and is_inside_tree():
		_combo_hits += 1
		if _combo_hits % every == 0:
			_server_shockwave(float(st["shockwave_radius"]),
				float(st["attack_damage"]) * float(st["shockwave_damage_mult"]),
				float(st["shockwave_knockback"]))

func on_damage_received(dmg: Dictionary) -> void:
	if Net.is_server():
		kb.apply(dmg.get("knockback_dir", Vector3.ZERO), float(dmg.get("knockback_force", 0.0)) * 0.45, 1.6)
		fx_hit.rpc(dmg.get("hit_position", global_position), float(dmg.get("amount", 0.0)), int(dmg.get("attacker_peer", 1)))
		Sfx.play("hurt", -6.0)

func _on_died(dmg: Dictionary) -> void:
	if not Net.is_server():
		return
	state = State.DOWN
	_respawn_left = st["respawn_time"]
	hitbox.deactivate()
	kb.cancel()
	## Смерть гасит активные эффекты класса: окно/бонус парирования, усиление,
	## очередь фантомов (никаких «посмертных» эхо-ударов).
	_parry_window_until_msec = 0
	_parry_guard_until_msec = 0
	_empower_mult = 1.0
	_phantom_queue.clear()
	kb.apply(dmg.get("knockback_dir", Vector3.FORWARD), 4.0, 1.0)
	get_tree().call_group(&"match_controller", "register_down", owner_peer)
	fx_down.rpc()

func _respawn() -> void:
	revive_now(st["respawn_health_factor"])

## Серверное возрождение (таймер DOWN или милосердный подъём в интермиссии).
func revive_now(health_factor: float) -> void:
	if not Net.is_server():
		return
	var spawn_points := get_tree().get_nodes_in_group("player_spawn_points")
	if spawn_points.size() > 0:
		var m: Marker3D = spawn_points[Game.next_rand() % spawn_points.size()]
		global_position = m.global_position + Vector3(0.0, 0.2, 0.0)
	health.setup(effective_max_health() * clampf(health_factor, 0.05, 1.0))
	health.grant_invulnerability(2.0)
	kb.cancel()
	_respawn_left = 0.0
	state = State.IDLE
	velocity = Vector3.ZERO
	_ctrl_vel = Vector3.ZERO
	fx_respawn.rpc()

# ------------------------------------------------------------------ репликация

func get_sync_payload() -> Dictionary:
	return {
		"p": global_position,
		"y": rotation.y,
		"v": velocity,
		"s": state,
		"hp": health.health,
		"dead": health.is_dead,
		"aid": attack_id,
		"f": form_index,
	}

func apply_sync_payload(payload: Dictionary) -> void:
	if payload.has("p"):
		global_position = payload["p"]
	if payload.has("y"):
		rotation.y = payload["y"]
	if payload.has("v"):
		velocity = payload["v"]
	if payload.has("hp"):
		health.replicate_state(float(payload["hp"]), bool(payload.get("dead", false)))
	var new_state := int(payload.get("s", state))
	if new_state != state:
		state = new_state
		Events.sync_state_changed.emit(self, state)
	var new_aid := int(payload.get("aid", attack_id))
	if new_aid != attack_id:
		attack_id = new_aid
		Events.sync_attack_started.emit(self)
	var new_form := int(payload.get("f", form_index))
	if new_form != form_index:
		_set_form_replicated(new_form)

## Клиентская репликация формы: меняются ТОЛЬКО визуал и подпись (статы и бой
## считает сервер). Def формы резолвится из того же реестра, что и на сервере.
func _set_form_replicated(new_form: int) -> void:
	form_index = new_form
	var fdef := Classes.get_form_def(class_id, new_form)
	if fdef != null:
		class_def = fdef
	_update_name_label()
	_rebuild_visuals()
	Events.unit_evolved.emit(self, form_index, fdef.display_name if fdef != null else "")

# ------------------------------------------------------------------ косметические RPC (локально на каждом пире)

@rpc("authority", "call_local", "unreliable")
func fx_swing() -> void:
	if visuals.has_method("play_swing"):
		visuals.play_swing()
	Sfx.play("swing", -8.0)

@rpc("authority", "call_local", "unreliable")
func fx_hit(hit_pos: Vector3, amount: float, attacker_peer: int) -> void:
	VisualFx.hit_flash(self)
	VisualFx.damage_number(hit_pos, amount, Color(1.0, 0.55, 0.6))
	if attacker_peer == Net.my_id():
		Events.local_hitstop_request.emit(hit_pos, 0.35)
	if is_local_pawn():
		Events.local_camera_shake.emit(0.35)

@rpc("authority", "call_local", "unreliable")
func fx_down() -> void:
	if visuals.has_method("play_down"):
		visuals.play_down()
	Sfx.play("hero_down", -4.0)
	if is_local_pawn():
		Events.local_camera_shake.emit(0.8)

@rpc("authority", "call_local", "unreliable")
func fx_respawn() -> void:
	if visuals.has_method("play_respawn"):
		visuals.play_respawn()

## Эволюция — зрелищное событие для ВСЕХ пиров (ТЗ §7: коротко, без кат-сцены).
@rpc("authority", "call_local", "reliable")
func fx_evolve(form_name: String) -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.55, 0.85), 6.0)
	VisualFx.ring_burst(global_position + Vector3(0.0, 0.5, 0.0), Color(1.0, 0.85, 0.35), 4.0)
	Sfx.play("evolve", -2.0)
	Events.local_announcement.emit("ЭВОЛЮЦИЯ: %s → %s!" % [player_name, form_name], 2.0)

## Ударная волна (трейт форм II/III) — локальная косметика на каждом пире.
@rpc("authority", "call_local", "unreliable")
func fx_shockwave(radius: float) -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.45, 0.3), clampf(radius * 0.8, 2.0, 6.0))
	Sfx.play("shockwave", -6.0)

## --- Косметика Валькирии (Этап 3.1): локально на каждом пире, без авторитета.

@rpc("authority", "call_local", "unreliable")
func fx_skill_dash() -> void:
	if visuals.has_method("play_skill_dash"):
		visuals.play_skill_dash()
	Sfx.play("swing", -6.0, 1.3)

@rpc("authority", "call_local", "unreliable")
func fx_skill() -> void:
	VisualFx.ring_burst(global_position, Color(0.65, 0.8, 1.0), clampf(float(st.get("skill_whirl_radius", 3.0)) * 0.9, 2.0, 5.0))
	Sfx.play("shockwave", -8.0, 1.35)

@rpc("authority", "call_local", "unreliable")
func fx_parry() -> void:
	if visuals.has_method("set_guard_tint"):
		visuals.set_guard_tint(true)
	Sfx.play("ui", -10.0, 0.6)
	## Авто-снятие подсветки стойки, если окно истекло без успеха (косметика).
	var wait := float(st.get("parry_window", 0.3)) + 0.08
	get_tree().create_timer(wait).timeout.connect(func() -> void:
		if is_instance_valid(self) and is_inside_tree() and _parry_window_until_msec == 0:
			if visuals != null and visuals.has_method("set_guard_tint"):
				visuals.set_guard_tint(false))

@rpc("authority", "call_local", "reliable")
func fx_parry_success() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.95, 0.55), 3.5)
	Sfx.play("parry", -2.0)
	if visuals.has_method("play_parry_success"):
		visuals.play_parry_success()
	if is_local_pawn():
		Events.local_announcement.emit("Парирование! Следующая атака усилена", 1.2)

@rpc("authority", "call_local", "unreliable")
func fx_phantom() -> void:
	VisualFx.phantom_slash(self, Color(0.9, 0.2, 0.35))
	Sfx.play("swing", -12.0, 0.7)

@rpc("authority", "call_local", "unreliable")
func fx_chain() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.35, 0.45), 2.4)
	Sfx.play("chain", -8.0)
