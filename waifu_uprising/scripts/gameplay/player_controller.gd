class_name PlayerPawn
extends CharacterBody3D
## Пешка игрока (Этап 1 — класс «Берсерка»).
## Сетевая модель (ТЗ §16):
##  - сервер симулирует движение/бой ВСЕХ пешек (авторитет);
##  - клиент-владелец лишь отправляет команды ввода (unreliable_ordered + reliable для действий);
##  - состояние репликуется BodySync-снапшотами и интерполируется на клиентах.
## Offline (одиночная игра без пира) работает по той же серверной ветке.

enum State { IDLE = 0, RUN = 1, ATTACK = 2, DODGE = 3, DOWN = 4 }

const GRAVITY: float = 24.0
const AIM_PLANE_Y: float = 1.0

var team: int = Units.Team.HERO
var owner_peer: int = 1
var player_name: String = "Игрок"
var class_id: StringName = &"berserk"
var class_def: ClassDefinition

## Реплицируемое состояние.
var state: int = State.IDLE
var aim_yaw: float = 0.0
var attack_id: int = 0
var kills: int = 0
var damage_dealt: float = 0.0

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
	add_to_group("player_pawns")
	add_to_group("hero_units")
	_build_base_stats()
	health.setup(st["max_health"])
	health.died.connect(_on_died)
	hitbox.damage = st["attack_damage"]
	hitbox.knockback_force = st["attack_knockback"]
	hitbox.owner_team = Units.Team.HERO
	var hb_shape := hitbox.get_node_or_null(^"CollisionShape3D")
	if hb_shape != null:
		_hitbox_base_scale = hb_shape.scale
	name_label.text = player_name
	if is_local_pawn():
		camera_rig.activate_for(self)
		Events.local_pawn_ready.emit(self)

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
	st["attack_damage"] = d.attack_damage * float(m.get("damage_mult", 1.0))
	st["attack_knockback"] = d.attack_knockback * float(m.get("kb_mult", 1.0))
	var cd := float(m.get("attack_cd_mult", 1.0))
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
	health.incoming_damage_multiplier = float(m.get("damage_taken_mult", 1.0))
	hitbox.damage = st["attack_damage"]
	hitbox.knockback_force = st["attack_knockback"]
	var hb_shape := hitbox.get_node_or_null(^"CollisionShape3D")
	if hb_shape != null:
		hb_shape.scale = _hitbox_base_scale * clampf(float(m.get("range_mult", 1.0)), 0.5, 2.0)

func effective_max_health() -> float:
	if st.has("max_health"):
		return float(st["max_health"])
	return class_def.max_health if class_def != null else 100.0

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
	}
	if external_input != null:
		var e: Dictionary = external_input
		result["move"] = (e.get("move", Vector2.ZERO) as Vector2).limit_length(1.0)
		result["aim_yaw"] = float(e.get("aim_yaw", aim_yaw))
		result["press_attack"] = bool(e.get("press_attack", false))
		result["press_dodge"] = bool(e.get("press_dodge", false))
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
	_prev_attack_pressed = attack_pressed

func _consume_local_input() -> void:
	var s := _sample_input()
	_latest_input["move"] = s["move"]
	_latest_input["aim_yaw"] = s["aim_yaw"]
	var attack_pressed: bool = s["press_attack"]
	if attack_pressed and not _prev_attack_pressed:
		try_attack()
	if s["press_dodge"]:
		try_dodge()
	_prev_attack_pressed = attack_pressed

@rpc("any_peer", "call_remote", "unreliable_ordered")
func sv_input(seq: int, move: Vector2, aim: float) -> void:
	if not Net.is_server():
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
	if multiplayer.get_remote_sender_id() != owner_peer:
		return
	match action:
		"attack":
			try_attack()
		"dodge":
			try_dodge()

# ------------------------------------------------------------------ серверная симуляция

func try_attack() -> void:
	if not Net.is_server() or class_def == null:
		return
	if state == State.DOWN or state == State.ATTACK or state == State.DODGE:
		return
	if _attack_cd_left > 0.0:
		return
	state = State.ATTACK
	_state_time = 0.0
	_attack_phase = 0
	attack_id += 1
	_attack_cd_left = float(st["attack_windup"]) + float(st["attack_active"]) + float(st["attack_recover"]) + float(st["attack_cooldown"])
	fx_swing.rpc()

func try_dodge() -> void:
	if not Net.is_server() or class_def == null:
		return
	if state == State.DOWN or state == State.DODGE or state == State.ATTACK:
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

func _server_sim(delta: float) -> void:
	_attack_cd_left = maxf(0.0, _attack_cd_left - delta)
	_dodge_cd_left = maxf(0.0, _dodge_cd_left - delta)
	_state_time += delta

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
		_:
			pass

	if state == State.DODGE:
		_ctrl_vel = _dodge_dir * float(st["dodge_speed"])
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
	if _state_time >= windup + active + recover:
		state = State.IDLE
		_state_time = 0.0
		hitbox.deactivate()

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
