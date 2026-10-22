class_name DestructibleProp
extends StaticBody3D
## Разрушаемый объект арены (Этап 2, ТЗ §11/§13). Ящики — первая реализация
## абстракции: позже колонны/двери используют тот же скрипт.
##
## Модель (server-authoritative):
##  - здоровье и разрушение считает сервер;
##  - разрушение фиксируется РОВНО ОДИН раз (guard по health.is_dead + _destroyed);
##  - клиенты получают событийные RPC (стадия урона / разрушение), не пер-кадр;
##  - обломки — локальная косметика на каждом пире (RigidBody без синхронизации,
##    ограниченное количество, короткое время жизни);
##  - после разрушения сервер снимает коллизию, убирает объект из nav_source
##    и запрашивает перепекание NavigationMesh (проходимость обновляется).

signal destroyed_by(peer_id: int)

@export var max_health: float = 60.0
@export var debris_count: int = 6
@export var debris_lifetime: float = 2.2

var team: int = Units.Team.PROP
var is_destroyed: bool = false

@onready var health: HealthComponent = $Health
@onready var visuals: Node3D = $Visuals
@onready var mesh: MeshInstance3D = $Visuals/Mesh
@onready var collision: CollisionShape3D = $Collision

var _base_material: StandardMaterial3D
var _stage: int = -1

func _ready() -> void:
	add_to_group("destructibles")
	add_to_group("nav_source")
	health.setup(max_health)
	health.died.connect(_on_destroyed)
	## Урон приходит через HurtboxComponent -> on_damage_received (см. ниже).
	if mesh != null:
		_base_material = mesh.get_active_material(0).duplicate() as StandardMaterial3D
		mesh.material_override = _base_material
	_apply_stage(0)

func get_health() -> HealthComponent:
	return health

func on_damage_received(damage: Dictionary) -> void:
	if not Net.is_server():
		return
	VisualFx.damage_number(damage.get("hit_position", global_position), float(damage.get("amount", 0.0)), Color(0.9, 0.75, 0.5))
	var new_stage := _stage_from_factor(health.health_factor())
	if new_stage != _stage:
		_apply_stage(new_stage)
		fx_stage.rpc(new_stage)

func _stage_from_factor(factor: float) -> int:
	if factor > 0.66:
		return 0
	if factor > 0.33:
		return 1
	return 2

## Два визуальных состояния повреждения до разрушения: трещины (темнее/наклон) и критическое состояние.
func _apply_stage(stage: int) -> void:
	_stage = stage
	if _base_material == null:
		return
	match stage:
		0:
			_base_material.albedo_color = Color(0.42, 0.31, 0.2)
			visuals.rotation.z = 0.0
			visuals.scale = Vector3.ONE
		1:
			_base_material.albedo_color = Color(0.34, 0.24, 0.15)
			visuals.rotation.z = 0.05
			visuals.scale = Vector3(0.98, 0.98, 0.98)
		2:
			_base_material.albedo_color = Color(0.25, 0.17, 0.1)
			visuals.rotation.z = -0.08
			visuals.scale = Vector3(0.95, 0.95, 0.95)

func _on_destroyed(damage: Dictionary) -> void:
	if not Net.is_server() or is_destroyed:
		return
	is_destroyed = true
	## Сервер фиксирует разрушение ровно один раз.
	collision_layer = 0
	collision_mask = 0
	if collision != null:
		collision.set_deferred("disabled", true)
	remove_from_group("nav_source")
	var attacker := int(damage.get("attacker_peer", 0))
	fx_destroy.rpc()
	get_tree().call_group(&"arena", "request_nav_rebake")
	destroyed_by.emit(attacker)

# ------------------------------------------------------------------ косметические RPC

@rpc("authority", "call_local", "unreliable")
func fx_stage(stage: int) -> void:
	_apply_stage(stage)
	Sfx.play("hit", -12.0, 0.7)

@rpc("authority", "call_local", "reliable")
func fx_destroy() -> void:
	if visuals != null:
		visuals.visible = false
	Sfx.play("enemy_die", -8.0, 0.6)
	_spawn_debris()

## Локальные обломки: неавторитетная физика, ограниченное число, короткая жизнь.
func _spawn_debris() -> void:
	if visuals == null:
		return
	for i in debris_count:
		var piece := RigidBody3D.new()
		piece.collision_layer = 0
		piece.collision_mask = 1
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.22, 0.22, 0.22)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.4, 0.29, 0.18)
		box.material = mat
		mi.mesh = box
		piece.add_child(mi)
		piece.mass = 1.0
		get_tree().current_scene.add_child(piece)
		piece.global_position = global_position + Vector3(randf_range(-0.5, 0.5), randf_range(0.2, 1.2), randf_range(-0.5, 0.5))
		piece.linear_velocity = Vector3(randf_range(-3.5, 3.5), randf_range(3.0, 6.0), randf_range(-3.5, 3.5))
		piece.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
		## Гарантированная очистка: таймер жизни + автоосвобождение (без утечек).
		piece.add_to_group("debris")
		get_tree().create_timer(debris_lifetime).timeout.connect(func() -> void:
			if is_instance_valid(piece):
				piece.queue_free()
		)
