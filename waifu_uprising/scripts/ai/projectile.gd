class_name SpitProjectile
extends Node3D
## Серверный снаряд «Плевальщика» (Этап 2).
## Сервер: прямолинейный полёт, проверка попадания по дистанции до героев,
## исчезновение по попаданию/таймауту/выходу за арену, лимит одновременных
## задаёт арена. Клиент: только интерполяция BodySync и косметика.
## Никакой авторитетной логики на клиентах.

var direction := Vector3.FORWARD
var speed: float = 15.0
var damage: float = 12.0
var knockback: float = 3.0
var lifetime: float = 3.0

const HIT_RADIUS: float = 1.0
const ARENA_BOUND: float = 25.0

func _ready() -> void:
	add_to_group("projectiles")

func _physics_process(delta: float) -> void:
	if not Net.is_server():
		return
	global_position += direction * speed * delta
	lifetime -= delta
	if lifetime <= 0.0 or absf(global_position.x) > ARENA_BOUND or absf(global_position.z) > ARENA_BOUND:
		expire_now()
		return
	for unit in get_tree().get_nodes_in_group("hero_units"):
		var n3 := unit as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		var h := n3.get_node_or_null(^"Health") as HealthComponent
		if h == null or h.is_dead:
			continue
		if n3 is PlayerPawn and n3.state == PlayerPawn.State.DOWN:
			continue
		## Сравнение в плоскости XZ: снаряд летит на высоте груди, а origin
		## героев — у ног; 3D-дистанция систематически промахивалась бы.
		var to_hero := n3.global_position - global_position
		to_hero.y = 0.0
		var hit_radius := HIT_RADIUS * (1.4 if n3 is GigaChad else 1.0)
		if to_hero.length() <= hit_radius:
			_hit_hero(n3, h)
			return

func _hit_hero(unit: Node3D, health_comp: HealthComponent) -> void:
	## attacker_peer = 0: урон NPC не приписывается игрокам (статистика/награды).
	var dmg := Units.make_damage(damage, null, 0, direction, knockback, global_position)
	if health_comp.take_damage(dmg):
		if unit.has_method("on_damage_received"):
			unit.call("on_damage_received", dmg)
	expire_now()

func expire_now() -> void:
	if is_inside_tree():
		queue_free() ## спавнер синхронно удалит снаряд на клиентах

# ------------------------------------------------------------------ репликация

func get_sync_payload() -> Dictionary:
	return {"p": global_position, "y": atan2(-direction.x, -direction.z), "v": direction * speed}

func apply_sync_payload(payload: Dictionary) -> void:
	if payload.has("p"):
		global_position = payload["p"]
	if payload.has("y"):
		rotation.y = payload["y"]
