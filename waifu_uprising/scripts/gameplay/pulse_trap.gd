class_name PulseTrap
extends Area3D
## Боевая ловушка «импульсная зона» (Этап 4.3): переиспользуемый тип для арен.
## Серверная машина состояний: IDLE -> WARN -> ACTIVE -> COOLDOWN -> IDLE...
##  - IDLE: ожидание интервала; зона почти невидима;
##  - WARN: заметный телеграф на полу + короткий звуковой сигнал;
##  - ACTIVE: урон/отбрасывание целям в зоне, НЕ чаще одного раза за активацию;
##  - COOLDOWN: остывание, затем возврат в IDLE.
## Урон считает ТОЛЬКО сервер; клиенты зеркалят состояние событийным RPC и
## показывают декоративную визуализацию. По умолчанию ловушка бьёт только врагов
## (friendly fire для игроков выключен флагом affects_players).

enum TState { IDLE = 0, WARN = 1, ACTIVE = 2, COOLDOWN = 3 }

signal state_changed_on_peer(new_state: int) ## локально на каждом пире (тесты/HUD)

@export var interval: float = 6.0 ## ожидание между циклами
@export var warn_time: float = 1.2 ## телеграф перед активацией
@export var active_time: float = 0.6 ## опасная фаза
@export var cooldown_time: float = 2.6 ## перезарядка
@export var damage: float = 28.0
@export var knockback_force: float = 10.0
@export var affects_players: bool = false ## дружелюбный огонь выключен по умолчанию
@export var start_offset: float = 0.0 ## рассинхрон циклов нескольких ловушек

var state: int = TState.IDLE
var _t: float = 0.0
var _hit_ids: Dictionary = {} ## hit-once per activation
var _zone: Dictionary = {}    ## instance_id -> unit (Hurtbox-единицы в зоне)
var _mat: StandardMaterial3D
var _pulse_t: float = 0.0

@onready var telegraph: MeshInstance3D = $Telegraph

func _ready() -> void:
	add_to_group("traps")
	_t = -start_offset
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(1.0, 0.55, 0.2, 0.06)
	_mat.emission_enabled = true
	_mat.emission = Color(1.0, 0.5, 0.15)
	_mat.emission_energy_multiplier = 0.0
	if telegraph != null:
		telegraph.material_override = _mat
	area_entered.connect(_on_zone_entered)
	area_exited.connect(_on_zone_exited)
	_apply_visual(state)

func _on_zone_entered(a: Area3D) -> void:
	var hb := a as HurtboxComponent
	if hb == null:
		return
	var unit = hb.get_unit()
	if unit != null:
		_zone[unit.get_instance_id()] = unit

func _on_zone_exited(a: Area3D) -> void:
	var hb := a as HurtboxComponent
	if hb == null:
		return
	var unit = hb.get_unit()
	if unit != null:
		_zone.erase(unit.get_instance_id())

func _physics_process(delta: float) -> void:
	if not Net.is_server():
		return
	_t += delta
	match state:
		TState.IDLE:
			if _t >= interval:
				_set_state(TState.WARN)
		TState.WARN:
			if _t >= warn_time:
				_hit_ids.clear() ## лимит повторного срабатывания — на активацию
				_set_state(TState.ACTIVE)
		TState.ACTIVE:
			_tick_damage()
			if _t >= active_time:
				_set_state(TState.COOLDOWN)
		TState.COOLDOWN:
			if _t >= cooldown_time:
				_set_state(TState.IDLE)

func _set_state(st: int) -> void:
	state = st
	_t = 0.0
	fx_state.rpc(st)

## Урон по целям в зоне: не чаще раза за активацию, выход из зоны = выход из набора.
func _tick_damage() -> void:
	for id in _zone.keys():
		var u := _zone[id] as Node
		if u == null or not is_instance_valid(u):
			_zone.erase(id)
			continue
		if _hit_ids.has(id):
			continue
		var foe := u as EnemyBase
		var pawn := u as PlayerPawn
		if foe == null and not (affects_players and pawn != null):
			continue
		if pawn != null and (pawn.state == PlayerPawn.State.DOWN or pawn.health.is_dead):
			continue
		if foe != null and (foe.state == EnemyBase.State.DEAD or foe.health.is_dead):
			continue
		_hit_ids[id] = true
		var u3 := u as Node3D
		var dir: Vector3 = (u3.global_position - global_position) if u3 != null else Vector3.ZERO
		dir.y = 0.0
		dir = dir.normalized() if dir.length_squared() > 0.001 else Vector3(0.0, 0.0, 1.0)
		var dmg := Units.make_damage(damage, self, 0, dir, knockback_force, u.global_position)
		var h := u.get_health() as HealthComponent
		if h != null and h.take_damage(dmg) and u.has_method("on_damage_received"):
			u.call("on_damage_received", dmg)

## Событийная репликация состояния: клиенты зеркалят state и визуал.
@rpc("authority", "call_local", "reliable")
func fx_state(st: int) -> void:
	state = st
	_apply_visual(st)
	state_changed_on_peer.emit(st)
	if st == TState.WARN:
		Sfx.play("count", -8.0)
	elif st == TState.ACTIVE:
		Sfx.play("shockwave", -6.0, 1.25)

func _apply_visual(st: int) -> void:
	if _mat == null:
		return
	match st:
		TState.IDLE:
			_mat.albedo_color = Color(1.0, 0.55, 0.2, 0.06)
			_mat.emission_energy_multiplier = 0.0
		TState.WARN:
			_mat.albedo_color = Color(1.0, 0.5, 0.15, 0.28)
			_mat.emission_energy_multiplier = 1.2
		TState.ACTIVE:
			_mat.albedo_color = Color(0.7, 0.9, 1.0, 0.55)
			_mat.emission_energy_multiplier = 3.0
		TState.COOLDOWN:
			_mat.albedo_color = Color(0.4, 0.4, 0.45, 0.10)
			_mat.emission_energy_multiplier = 0.0

## Мигание телеграфа в WARN — локальная косметика на каждом пире.
func _process(delta: float) -> void:
	_pulse_t += delta
	if _mat != null and state == TState.WARN:
		_mat.emission_energy_multiplier = 1.0 + sin(_pulse_t * 18.0) * 0.8
