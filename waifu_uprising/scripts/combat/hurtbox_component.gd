class_name HurtboxComponent
extends Area3D
## Зона получения урона. Принадлежит боевой единице (unit_path).
## Сама не мониторит — её «видят» HitboxComponent противника.

@export var unit_path: NodePath = NodePath("..")

var _unit: Node

func _ready() -> void:
	_unit = get_node_or_null(unit_path)
	monitoring = false
	monitorable = true

func get_unit() -> Node:
	if _unit == null:
		_unit = get_node_or_null(unit_path)
	return _unit

func receive_hit(damage: Dictionary) -> void:
	var unit := get_unit()
	if unit == null or not is_inside_tree():
		return
	var health := unit.get_node_or_null(^"Health") as HealthComponent
	if health == null and unit.has_method("get_health"):
		health = unit.get_health()
	if health == null:
		return
	if health.take_damage(damage):
		if unit.has_method("on_damage_received"):
			unit.on_damage_received(damage)
