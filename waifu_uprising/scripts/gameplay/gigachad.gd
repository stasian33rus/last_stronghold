class_name GigaChad
extends CharacterBody3D
## Гигачад — последний источник (ТЗ §8). Защищаемый объект и генератор резонанса.
## Сервер: здоровье, накопление резонанса, авторазряд «Волна Резонанса»
## (лечит героинь рядом и отбрасывает врагов — реальная механика, не декорация).
## Смерть Гигачада = поражение команды (ТЗ §3, Акт I).

enum State { IDLE = 0, PULSE = 1, DOWN = 2 }

const GRAVITY: float = 24.0
const RESONANCE_MAX: float = 100.0

@export var max_health: float = 600.0
@export var resonance_rate: float = 4.0 ## единиц/сек — примерно 25 секунд до полного заряда
@export var pulse_heal: float = 35.0
@export var pulse_radius: float = 9.0
@export var pulse_knockback: float = 11.0

## Командные улучшения резонанса (копятся сервером из выборов игроков, Этап 2).
var team_reso_rate_mult: float = 1.0
var team_pulse_heal_mult: float = 1.0

func add_team_upgrade(effect: int, value: float) -> void:
	if effect == UpgradeDefinition.Effect.RESO_RATE_MULT:
		team_reso_rate_mult += value
	elif effect == UpgradeDefinition.Effect.RESO_HEAL_MULT:
		team_pulse_heal_mult += value

var team: int = Units.Team.HERO
var owner_peer: int = 1
var state: int = State.IDLE
var resonance: float = 0.0

signal defeated

var _state_time: float = 0.0

@onready var health: HealthComponent = $Health
@onready var kb: KnockbackComponent = $Knockback
@onready var visuals: Node3D = $Visuals

func _ready() -> void:
	add_to_group("gigachad")
	add_to_group("hero_units")
	health.setup(max_health)
	health.died.connect(_on_died)
	health.damage_taken.connect(_on_damaged)

func get_health() -> HealthComponent:
	return health

func _physics_process(delta: float) -> void:
	if not Net.is_server():
		return
	_state_time += delta
	if state == State.DOWN:
		var kb_down := kb.consume(delta)
		velocity.x = kb_down.x
		velocity.z = kb_down.z
		_apply_gravity(delta)
		move_and_slide()
		return
	## Резонанс: постоянная генерация (ТЗ §5) с командными улучшениями.
	if state == State.IDLE:
		resonance = minf(RESONANCE_MAX, resonance + resonance_rate * team_reso_rate_mult * delta)
		if resonance >= RESONANCE_MAX:
			_discharge_pulse()
	elif state == State.PULSE and _state_time >= 0.9:
		state = State.IDLE
		_state_time = 0.0
	_apply_gravity(delta)
	var kb_vel := kb.consume(delta)
	velocity.x = kb_vel.x
	velocity.z = kb_vel.z
	if kb_vel.y > 0.0 and is_on_floor():
		velocity.y = kb_vel.y
	move_and_slide()

func _discharge_pulse() -> void:
	resonance = 0.0
	state = State.PULSE
	_state_time = 0.0
	var center := global_position
	## Лечение героинь в радиусе.
	for unit in get_tree().get_nodes_in_group("player_pawns"):
		var pawn := unit as PlayerPawn
		if pawn == null or pawn.health.is_dead:
			continue
		if pawn.global_position.distance_to(center) <= pulse_radius:
			pawn.health.heal(pulse_heal * team_pulse_heal_mult)
	## Отбрасывание врагов — физически ощутимая волна.
	for unit in get_tree().get_nodes_in_group("enemy_units"):
		var foe := unit as EnemyFop
		if foe == null or foe.health.is_dead:
			continue
		var d := foe.global_position - center
		d.y = 0.0
		if d.length() <= pulse_radius:
			foe.kb.apply(d.normalized(), pulse_knockback, foe.def.knockback_mass)
			foe.apply_external_stun(0.4)
	fx_pulse.rpc()

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, -1.0)

func _on_damaged(_amount: float, damage: Dictionary) -> void:
	if not Net.is_server() or state == State.DOWN:
		return
	kb.apply(damage.get("knockback_dir", Vector3.ZERO), float(damage.get("knockback_force", 0.0)) * 0.08, 12.0)
	fx_hit.rpc(damage.get("hit_position", global_position), float(damage.get("amount", 0.0)))

func _on_died(_damage: Dictionary) -> void:
	if not Net.is_server():
		return
	state = State.DOWN
	fx_down.rpc()
	defeated.emit()

# ------------------------------------------------------------------ репликация

func get_sync_payload() -> Dictionary:
	return {
		"p": global_position,
		"y": rotation.y,
		"s": state,
		"hp": health.health,
		"dead": health.is_dead,
		"res": resonance,
	}

func apply_sync_payload(payload: Dictionary) -> void:
	if payload.has("p"):
		global_position = payload["p"]
	if payload.has("y"):
		rotation.y = payload["y"]
	if payload.has("hp"):
		health.replicate_state(float(payload["hp"]), bool(payload.get("dead", false)))
	if payload.has("res"):
		resonance = float(payload["res"])
	var new_state := int(payload.get("s", state))
	if new_state != state:
		state = new_state
		Events.sync_state_changed.emit(self, state)

# ------------------------------------------------------------------ косметические RPC

@rpc("authority", "call_local", "unreliable")
func fx_hit(hit_pos: Vector3, amount: float) -> void:
	VisualFx.hit_flash(self)
	VisualFx.damage_number(hit_pos, amount, Color(1.0, 0.6, 0.6))
	Sfx.play("hurt", -4.0, 0.55) ## низкий «ух» — он же большой

@rpc("authority", "call_local", "reliable")
func fx_pulse() -> void:
	Sfx.play("pulse", -2.0)
	VisualFx.ring_burst(global_position, Color(0.3, 0.9, 1.0), pulse_radius)
	if visuals.has_method("play_pulse"):
		visuals.play_pulse()

@rpc("authority", "call_local", "reliable")
func fx_down() -> void:
	Sfx.play("defeat", -2.0)
