class_name EnemyBase
extends CharacterBody3D
## Базовый враг Ордена Гламура (Этап 1 «Пижон» + архетипы Этапа 2).
## FSM: SPAWN -> CHASE -> WINDUP (телеграф) -> STRIKE -> RECOVER -> CHASE;
##       HITSTUN (прерывание), DEAD (труп с физикой).
## ИИ и бой — ТОЛЬКО на сервере; клиенты получают снапшоты через BodySync.
## Архетипы настраиваются EnemyDefinition (данные) и подклассами:
##  - Громила: тяжёлые параметры + recover_damage_mult (уязвимость после атаки);
##  - Тень: рывки (dash_*) и серия ударов (attack_hits/attack_hit_interval);
##  - Плевальщик: ranged + keep_distance, переопределяет _begin_strike (снаряд).

enum State { SPAWN = 0, CHASE = 1, WINDUP = 2, STRIKE = 3, RECOVER = 4, HITSTUN = 5, DEAD = 6 }

const GRAVITY: float = 24.0

## Этап 4.2 — лёгкое взаимное раздвигание врагов (только сервер). Физические
## тела уже сталкиваются (layer/mask), но при плотном прессинге к цели этого
## недостаточно: добавляем рулёжку-разделение по сетке-хэшу. Без RigidBody3D,
## без телепортов: только ограниченное ускорение, гасимое трением/стенами.
const SEP_RADIUS: float = 0.95
const SEP_ACCEL: float = 16.0
const SEP_CTRL_EXTRA: float = 2.4 ## насколько разделение может превысить скорость бега
const SEP_CELL: float = 1.0
const SEP_MAX_NEIGHBOURS: int = 12 ## предел проверок на тело: O(n·k), не O(n²)
static var _sep_grid: Dictionary = {}
static var _sep_frame: int = -1

var team: int = Units.Team.ENEMY
var owner_peer: int = 1 ## враги всегда принадлежат серверу
var def: EnemyDefinition
var state: int = State.SPAWN

signal died_on_server(enemy: EnemyBase, damage: Dictionary)

var _state_time: float = 0.0
var _target: Node3D
var _retarget_in: float = 0.0
var _ctrl_vel := Vector3.ZERO ## управляемая составляющая скорости (без отбрасывания)
var _sep_vel := Vector3.ZERO ## сглаженная составляющая взаимного раздвигания (Этап 4.2)
var _lunge_dir := Vector3.ZERO
var _strike_hitbox_on := false
var _strike_hits_done := 0
var _strike_next_hit := 0.0
var _corpse_timer: float = -1.0
var _hitstun_duration: float = 0.28
## Анти-застревание (до NavMesh на Этапе 2): контроль смещения + боковой обход.
var _stuck_probe_pos := Vector3.ZERO
var _stuck_timer: float = 0.0
var _strafe_timer: float = 0.0
var _strafe_sign: float = 1.0
## Флаг активной навигации (NavigationAgent3D не имеет рантайм-свойства enabled в 4.7).
var _nav_active: bool = false

@onready var health: HealthComponent = $Health
@onready var hitbox: HitboxComponent = $Hitbox
@onready var kb: KnockbackComponent = $Knockback
@onready var visuals: Node3D = $Visuals
@onready var nav_agent: NavigationAgent3D = get_node_or_null(^"NavAgent")

func _ready() -> void:
	if def == null:
		push_error("[EnemyBase] Не задан EnemyDefinition")
		return
	add_to_group("enemy_units")
	_stuck_probe_pos = global_position
	if nav_agent != null:
		if Net.is_server():
			nav_agent.path_desired_distance = 0.7
			nav_agent.target_desired_distance = maxf(0.5, def.attack_range * 0.6)
			nav_agent.avoidance_enabled = false ## разделение тел обеспечивает физика + strafe
			_nav_active = true
		else:
			nav_agent.set_physics_process(false) ## клиенты не считают навигацию
			_nav_active = false
	health.setup(def.max_health)
	hitbox.damage = def.attack_damage
	hitbox.knockback_force = def.attack_knockback
	hitbox.owner_team = Units.Team.ENEMY
	health.died.connect(_on_died)
	health.damage_taken.connect(_on_damaged)

func get_health() -> HealthComponent:
	return health

func _physics_process(delta: float) -> void:
	if not Net.is_server():
		return ## на клиентах тело двигает BodySync-интерполяция
	_server_ai(delta)

func _server_ai(delta: float) -> void:
	_state_time += delta
	match state:
		State.SPAWN:
			_decay_ctrl(delta, 2.0)
			if _state_time >= 0.35:
				_set_state(State.CHASE)
		State.CHASE:
			_chase(delta)
		State.WINDUP:
			## Телеграф: цель может уйти — бьём туда, где стояли.
			_decay_ctrl(delta, 2.0)
			if _state_time >= def.attack_windup:
				_set_state(State.STRIKE)
		State.STRIKE:
			if not _strike_hitbox_on:
				_strike_hitbox_on = true
				_lunge_dir = _dir_to_target()
				_begin_strike()
			_strike_move(delta)
			_advance_flurry()
			if _state_time >= _strike_duration():
				hitbox.deactivate()
				_set_state(State.RECOVER)
		State.RECOVER:
			_decay_ctrl(delta, 1.0)
			if _state_time >= def.attack_recover:
				_set_state(State.CHASE)
		State.HITSTUN:
			_decay_ctrl(delta, 0.5)
			if _state_time >= _hitstun_duration:
				_set_state(State.CHASE)
		State.DEAD:
			## Труп: только физика (отбрасывание доигрывается), затем удаление.
			hitbox.deactivate()
			_decay_ctrl(delta, 1.0)
			if _corpse_timer >= 0.0:
				_corpse_timer -= delta
				if _corpse_timer <= 0.0:
					queue_free() ## MultiplayerSpawner удалит труп и на клиентах

	## Взаимное раздвигание (Этап 4.2): трупы не расталкиваются.
	if state != State.DEAD:
		_apply_separation(delta)

	## Итоговая скорость = управление + отбрасывание (КБ не накапливается).
	var kb_vel := kb.consume(delta)
	velocity.x = _ctrl_vel.x + kb_vel.x + _sep_vel.x
	velocity.z = _ctrl_vel.z + kb_vel.z + _sep_vel.z
	_apply_gravity(delta)
	if kb_vel.y > 0.0 and is_on_floor():
		velocity.y = kb_vel.y
	move_and_slide()

static func _sep_cell_of(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / SEP_CELL)), int(floor(p.z / SEP_CELL)), 0)

func _sep_rebuild_grid() -> void:
	_sep_grid.clear()
	for n in get_tree().get_nodes_in_group("enemy_units"):
		var e := n as EnemyBase
		if e == null or not is_instance_valid(e) or e.state == State.DEAD or not e.is_inside_tree():
			continue
		var c := _sep_cell_of(e.global_position)
		if not _sep_grid.has(c):
			_sep_grid[c] = []
		_sep_grid[c].append(e)

## Рулёжка-разделение: сумма отталкиваний от соседей ближе SEP_RADIUS, взвешенная
## массами (тяжёлого лёгкий толкает сильнее, чем наоборот). Применение — через
## ограниченное ускорение и кламп управляющей скорости: без дрожания и взлётов.
func _apply_separation(delta: float) -> void:
	if _sep_frame != Engine.get_physics_frames():
		_sep_frame = Engine.get_physics_frames()
		_sep_rebuild_grid()
	var cell := _sep_cell_of(global_position)
	var push := Vector3.ZERO
	var checked := 0
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var arr: Array = _sep_grid.get(Vector3i(cell.x + dx, cell.z + dz, 0), [])
			for o in arr:
				var other := o as EnemyBase
				if other == null or other == self:
					continue
				checked += 1
				if checked > SEP_MAX_NEIGHBOURS:
					break
				var d := global_position - other.global_position
				d.y = 0.0
				var dist := d.length()
				if dist < 0.001:
					## Точное совпадение: детерминированный разворот по id экземпляра.
					var ang := float(int(get_instance_id()) % 628) * 0.01
					d = Vector3(cos(ang), 0.0, sin(ang))
					dist = 0.001
				if dist >= SEP_RADIUS:
					continue
				var w := 1.0 - dist / SEP_RADIUS
				var m_self := def.knockback_mass
				var m_other := other.def.knockback_mass
				push += (d / dist) * w * (m_other / maxf(0.2, m_self + m_other))
	## Отдельная сглаженная составляющая: преследование перезаписывает _ctrl_vel
	## каждый кадр, поэтому разведение живёт своей компонентой скорости.
	var desired := Vector3.ZERO
	if push.length_squared() > 0.000001:
		desired = push.normalized() * minf(push.length() * 3.0, SEP_CTRL_EXTRA)
	_sep_vel = _sep_vel.lerp(desired, clampf(delta * 10.0, 0.0, 1.0))

func _decay_ctrl(delta: float, friction_factor: float = 1.0) -> void:
	var f := def.friction * friction_factor * delta
	_ctrl_vel.x = move_toward(_ctrl_vel.x, 0.0, f)
	_ctrl_vel.z = move_toward(_ctrl_vel.z, 0.0, f)

func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	var prev := state
	state = new_state
	_state_time = 0.0
	if new_state == State.STRIKE:
		_strike_hitbox_on = false
		_strike_hits_done = 0
		_strike_next_hit = 0.0
	## Уязвимость во время восстановления (Громила): множитель входящего урона.
	if new_state == State.RECOVER:
		health.incoming_damage_multiplier = def.recover_damage_mult
	elif prev == State.RECOVER:
		health.incoming_damage_multiplier = 1.0

func _strike_duration() -> float:
	if def.attack_hits > 1 and def.attack_hit_interval > 0.0:
		return maxf(def.attack_active, def.attack_hits * def.attack_hit_interval + 0.08)
	return def.attack_active

## Хук начала удара: ближний бой активирует хитбокс; Плевальщик переопределяет (снаряд).
func _begin_strike() -> void:
	if def.ranged:
		return
	if def.attack_hits > 1 and def.attack_hit_interval > 0.0:
		return ## серия — активации в _advance_flurry
	hitbox.activate(def.attack_active)

## Хук движения во время удара (по умолчанию — выпад вперёд).
func _strike_move(_delta: float) -> void:
	if def.ranged:
		_decay_ctrl(_delta, 1.0)
		return
	_ctrl_vel = _lunge_dir * def.attack_lunge_speed

## Серия ударов (Тень): периодические активации хитбокса во время STRIKE.
func _advance_flurry() -> void:
	if def.attack_hits <= 1 or def.attack_hit_interval <= 0.0 or def.ranged:
		return
	if _strike_hits_done < def.attack_hits and _state_time >= _strike_next_hit:
		_strike_hits_done += 1
		_strike_next_hit = _state_time + def.attack_hit_interval
		hitbox.activate(maxf(0.08, def.attack_hit_interval * 0.8))

# ------------------------------------------------------------------ преследование

func _chase(delta: float) -> void:
	_retarget_in -= delta
	if _target == null or not is_instance_valid(_target) or _retarget_in <= 0.0:
		_target = _acquire_target()
		_retarget_in = 0.5
	_update_stuck_detection(delta)
	if _target == null:
		_decay_ctrl(delta)
		return
	var to_target := _target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()
	if dist > 0.05:
		var dir := to_target / dist
		_face_toward(dir, delta)
		_chase_move(delta, _nav_move_dir(dir), dist)
	if dist <= def.attack_range and _target_is_valid_target():
		_set_state(State.WINDUP)

## Реальная навигация: маршрут NavigationAgent3D вокруг препятствий;
## при отсутствии маршрута/агента — безопасный fallback на прямое движение
## (анти-застревание остаётся защитным механизмом).
func _nav_move_dir(fallback: Vector3) -> Vector3:
	if not _nav_active or _target == null:
		return fallback
	nav_agent.target_position = _target.global_position
	if not nav_agent.is_target_reachable():
		return fallback
	var next := nav_agent.get_next_path_position()
	var to_next := next - global_position
	to_next.y = 0.0
	if to_next.length() < 0.25:
		return fallback
	return to_next.normalized()

func _face_toward(dir: Vector3, delta: float) -> void:
	var desired_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, desired_yaw, minf(1.0, delta * 10.0))

## Движение в преследовании — переопределяется Тенью (рывки) и Плевальщиком (дистанция).
func _chase_move(delta: float, dir: Vector3, dist: float) -> void:
	if dist > def.attack_range * 0.8:
		var move_dir := dir
		if _strafe_timer > 0.0:
			## Обход препятствия: скользим вбок, не теряя направления к цели.
			var perp := Vector3(-dir.z, 0.0, dir.x) * _strafe_sign
			move_dir = (dir * 0.35 + perp * 0.95).normalized()
		_ctrl_vel.x = move_toward(_ctrl_vel.x, move_dir.x * def.move_speed, def.acceleration * delta)
		_ctrl_vel.z = move_toward(_ctrl_vel.z, move_dir.z * def.move_speed, def.acceleration * delta)
	else:
		_decay_ctrl(delta)

## Если хотим бежать, но реально не смещаемся — включаем боковой обход.
func _update_stuck_detection(_delta: float) -> void:
	_stuck_timer -= _delta
	if _strafe_timer > 0.0:
		_strafe_timer -= _delta
	if _stuck_timer > 0.0:
		return
	_stuck_timer = 0.5
	var wants_move := _ctrl_vel.length_squared() > (def.move_speed * 0.4) * (def.move_speed * 0.4)
	if wants_move and global_position.distance_to(_stuck_probe_pos) < 0.35:
		_strafe_timer = 0.7
		if randf() < 0.5:
			_strafe_sign = -_strafe_sign
	_stuck_probe_pos = global_position

func _target_is_valid_target() -> bool:
	if _target == null or not is_instance_valid(_target):
		return false
	var t_health := _target.get_node_or_null(^"Health") as HealthComponent
	if t_health == null or t_health.is_dead:
		return false
	if _target is PlayerPawn and _target.state == PlayerPawn.State.DOWN:
		return false
	return true

## Ближайшая живая цель из героев (игроки и Гигачад). Лежачих игроков не бьём.
func _acquire_target() -> Node3D:
	var best: Node3D = null
	var best_dist := def.aggro_radius
	for unit in get_tree().get_nodes_in_group("hero_units"):
		var n3 := unit as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		var h := n3.get_node_or_null(^"Health") as HealthComponent
		if h == null or h.is_dead:
			continue
		if n3 is PlayerPawn and n3.state == PlayerPawn.State.DOWN:
			continue
		var d := n3.global_position.distance_to(global_position)
		if d < best_dist:
			best_dist = d
			best = n3
	return best

func _dir_to_target() -> Vector3:
	if _target == null or not is_instance_valid(_target):
		return -global_transform.basis.z
	var d := _target.global_position - global_position
	d.y = 0.0
	return d.normalized() if d.length_squared() > 0.001 else -global_transform.basis.z

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, -1.0)

# ------------------------------------------------------------------ реакция на урон

func _on_damaged(_amount: float, damage: Dictionary) -> void:
	if not Net.is_server() or state == State.DEAD:
		return
	hitbox.deactivate()
	var force := float(damage.get("knockback_force", 0.0))
	kb.apply(damage.get("knockback_dir", Vector3.ZERO), force, def.knockback_mass)
	## Отбрасывание с весом: сильный удар -> длительный стаггер, прерывает выпад (ТЗ §13).
	if force >= def.heavy_hitstun_threshold or state == State.WINDUP:
		_hitstun_duration = def.heavy_hitstun_time
	else:
		_hitstun_duration = def.hitstun_time
	_set_state(State.HITSTUN)
	fx_hit.rpc(damage.get("hit_position", global_position), float(damage.get("amount", 0.0)), int(damage.get("attacker_peer", 1)))

func _on_died(damage: Dictionary) -> void:
	if not Net.is_server():
		return
	hitbox.deactivate()
	health.incoming_damage_multiplier = 1.0
	kb.apply(damage.get("knockback_dir", Vector3.FORWARD), float(damage.get("knockback_force", 6.0)) * 1.5, def.knockback_mass)
	_set_state(State.DEAD)
	_corpse_timer = 2.2
	collision_mask = 1 ## труп скользит только по миру
	fx_die.rpc()
	died_on_server.emit(self, damage)

## Внешний стаггер (Волна Резонанса Гигачада / будущие командные комбо, Этап 4). Только сервер.
func apply_external_stun(duration: float) -> void:
	if not Net.is_server() or state == State.DEAD:
		return
	hitbox.deactivate()
	_hitstun_duration = duration
	_set_state(State.HITSTUN)

# ------------------------------------------------------------------ репликация

func get_sync_payload() -> Dictionary:
	return {
		"p": global_position,
		"y": rotation.y,
		"v": velocity,
		"s": state,
		"hp": health.health,
		"dead": health.is_dead,
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

# ------------------------------------------------------------------ косметические RPC

@rpc("authority", "call_local", "unreliable")
func fx_hit(hit_pos: Vector3, amount: float, attacker_peer: int) -> void:
	VisualFx.hit_flash(self)
	VisualFx.damage_number(hit_pos, amount, Color(1.0, 0.9, 0.4))
	Sfx.play("hit", -6.0)
	if attacker_peer == Net.my_id():
		Events.local_hitstop_request.emit(hit_pos, 0.25)
		Sfx.play("heavy_hit", -10.0, randf_range(0.95, 1.1))

@rpc("authority", "call_local", "unreliable")
func fx_die() -> void:
	pass ## звук/поза смерти играет вражеский визуал по смене состояния
