class_name BossAct1
extends EnemyBase
## Босс акта I «Маэстро Ордена Гламура» (Этап 5.1). Наследует EnemyBase:
## здоровье/урон/репликация/физика/ловушки работают штатно. Добавлены фазы
## по доле HP (1 / 2 / 3): рост скорости и телеграфируемый радиальный импульс
## (WARN-кольцо -> удар по площади) начиная со второй фазы.
## Устойчив к станлокам: hitstun мал, heavy-порог недосягаем (данные .tres).

signal phase_changed_on_server(phase_index: int)

const PULSE_RADIUS: float = 5.0
const PULSE_CD: float = 4.5

var phase_index: int = 1
var _speed_mult: float = 1.0
var _pulse_cd_left: float = 2.0
var _pulse_mode: bool = false

func _ready() -> void:
	super._ready() ## здоровье/хитбоксы/сигнал died_on_server базового класса
	add_to_group("boss_unit")
	health.health_changed.connect(_on_hp_changed)

func _on_hp_changed(_current: float, _maximum: float) -> void:
	if not Net.is_server() or health.is_dead:
		return
	var f := health.health_factor()
	var new_phase := 1 if f > 0.6 else (2 if f > 0.3 else 3)
	if new_phase != phase_index:
		phase_index = new_phase
		_speed_mult = 1.0 + 0.25 * float(phase_index - 1)
		fx_boss_phase.rpc(phase_index)
		phase_changed_on_server.emit(phase_index)

## Таймер импульса — поверх базовой симуляции (только сервер, только CHASE).
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not Net.is_server() or state != State.CHASE or phase_index < 2:
		return
	_pulse_cd_left -= delta
	if _pulse_cd_left <= 0.0 and _hero_within(PULSE_RADIUS + 2.5):
		_pulse_mode = true
		fx_boss_telegraph.rpc()
		_set_state(State.WINDUP)

func _hero_within(radius: float) -> bool:
	for node in get_tree().get_nodes_in_group("hero_units"):
		var u := node as Node3D
		if u == null or not is_instance_valid(u):
			continue
		var h := u.get_node_or_null(^"Health") as HealthComponent
		if h == null or h.is_dead:
			continue
		if u is PlayerPawn and (u as PlayerPawn).state == PlayerPawn.State.DOWN:
			continue
		if u.global_position.distance_to(global_position) <= radius:
			return true
	return false

## Фаза 2+: скорость преследования растёт (переопределение движения CHASE).
func _chase_move(delta: float, dir: Vector3, dist: float) -> void:
	if dist > def.attack_range * 0.8:
		var move_dir := dir
		if _strafe_timer > 0.0:
			var perp := Vector3(-dir.z, 0.0, dir.x) * _strafe_sign
			move_dir = (dir * 0.35 + perp * 0.95).normalized()
		var spd := def.move_speed * _speed_mult
		_ctrl_vel.x = move_toward(_ctrl_vel.x, move_dir.x * spd, def.acceleration * delta)
		_ctrl_vel.z = move_toward(_ctrl_vel.z, move_dir.z * spd, def.acceleration * delta)
	else:
		_decay_ctrl(delta)

## Вход в STRIKE: в режиме импульса бьём площадью вместо хитбокса выпада.
func _begin_strike() -> void:
	if _pulse_mode:
		_radial_pulse()
		return
	super._begin_strike()

func _strike_move(_delta: float) -> void:
	if _pulse_mode:
		_decay_ctrl(_delta, 1.0) ## импульс — стойка на месте, без рывка
		return
	super._strike_move(_delta)

func _set_state(new_state: int) -> void:
	var prev := state
	super._set_state(new_state)
	if new_state == State.CHASE and prev == State.RECOVER:
		_pulse_mode = false
		_pulse_cd_left = PULSE_CD
	if new_state == State.DEAD:
		_pulse_mode = false

## Радиальный удар: урон и отбрасывание героям в радиусе, по одному разу за импульс.
func _radial_pulse() -> void:
	if not Net.is_server() or not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("hero_units"):
		var u := node as Node3D
		if u == null or not is_instance_valid(u):
			continue
		var h := u.get_node_or_null(^"Health") as HealthComponent
		if h == null or h.is_dead:
			continue
		if u is PlayerPawn and (u as PlayerPawn).state == PlayerPawn.State.DOWN:
			continue
		var to_t := u.global_position - global_position
		to_t.y = 0.0
		if to_t.length() > PULSE_RADIUS:
			continue
		var dir := to_t.normalized() if to_t.length_squared() > 0.001 else -global_transform.basis.z
		var dmg := Units.make_damage(def.attack_damage * 1.2, self, owner_peer, dir, 12.0, u.global_position)
		if h.take_damage(dmg) and u.has_method("on_damage_received"):
			u.call("on_damage_received", dmg)
	fx_pulse_hit.rpc()

# ------------------------------------------------------------------ RPC
@rpc("authority", "call_local", "reliable")
func fx_boss_phase(p: int) -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.85, 0.3), 6.0)
	Sfx.play("evolve", -4.0)
	Events.local_announcement.emit("Маэстро Ордена: фаза %d!" % p, 2.0)

@rpc("authority", "call_local", "reliable")
func fx_boss_telegraph() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.3, 0.25), PULSE_RADIUS)
	Sfx.play("count", -4.0, 0.8)

@rpc("authority", "call_local", "unreliable")
func fx_pulse_hit() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.6, 0.2), PULSE_RADIUS * 0.9)
	Sfx.play("shockwave", -3.0)
