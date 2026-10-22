class_name HitboxComponent
extends Area3D
## Зона нанесения урона. Активируется только на сервере (авторитетный расчёт попаданий, ТЗ §16).
## По умолчанию одно попадание за активацию по каждой цели (hit_once_per_activation).

@export var damage: float = 10.0
@export var knockback_force: float = 6.0
@export var hit_once_per_activation: bool = true
@export var owner_team: int = Units.Team.NONE

var is_active: bool = false
var _hit_targets: Dictionary = {}
var _activation_id: int = 0

func _ready() -> void:
	monitoring = false
	monitorable = false
	area_entered.connect(_on_area_entered)

## Только сервер. Через `duration` секунд выключается автоматически.
func activate(duration: float = 0.15) -> void:
	if not Net.is_server():
		return
	_activation_id += 1
	var my_id := _activation_id
	_hit_targets.clear()
	is_active = true
	monitoring = true
	get_tree().create_timer(duration).timeout.connect(
		func() -> void:
			if my_id == _activation_id:
				deactivate()
	)

func deactivate() -> void:
	_activation_id += 1
	is_active = false
	monitoring = false

func _on_area_entered(area: Area3D) -> void:
	if not is_active or not Net.is_server():
		return
	var hurtbox := area as HurtboxComponent
	if hurtbox == null:
		return
	var unit := hurtbox.get_unit()
	if unit == null:
		return
	if hit_once_per_activation and _hit_targets.has(unit.get_instance_id()):
		return
	var team_value: Variant = unit.get("team")
	var target_team: int = int(team_value) if team_value != null else Units.Team.NONE
	if not Units.is_hostile(owner_team, target_team):
		return
	_hit_targets[unit.get_instance_id()] = true

	var attacker: Node = get_parent_unit()
	var kb_dir := Vector3.ZERO
	var hit_pos: Vector3 = hurtbox.global_position
	if attacker is Node3D:
		kb_dir = hit_pos - (attacker as Node3D).global_position
		kb_dir.y = 0.0
		if kb_dir.length_squared() < 0.0001:
			kb_dir = -(attacker as Node3D).global_transform.basis.z
		kb_dir = kb_dir.normalized()
	var peer_value: Variant = attacker.get("owner_peer") if attacker != null else null
	var attacker_peer: int = int(peer_value) if peer_value != null else 1
	var dmg := Units.make_damage(damage, attacker, attacker_peer, kb_dir, knockback_force, hit_pos)
	hurtbox.receive_hit(dmg)
	if attacker != null and attacker.has_method("on_hit_landed"):
		attacker.on_hit_landed(unit, dmg)

## Единица-владелец хитбокса: первый предок с get_health() или свойством team.
func get_parent_unit() -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method("get_health") or node.get("team") != null:
			return node
		node = node.get_parent()
	return get_parent()
