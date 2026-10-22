class_name HealthComponent
extends Node
## Здоровье боевой единицы. Изменяется ТОЛЬКО на сервере (server-authoritative, ТЗ §16).
## На клиентах значение перезаписывается репликацией (BodySync payload) и вызывает
## те же сигналы, чтобы HUD/визуал работали единообразно.

signal damage_taken(amount: float, damage: Dictionary)
signal healed(amount: float)
signal died(damage: Dictionary)
signal health_changed(current: float, maximum: float)

@export var max_health: float = 100.0
@export var invulnerable: bool = false

var health: float = 100.0
var is_dead: bool = false
## Кратковременная неуязвимость (айфреймы рывка, респаун).
var invulnerable_until_msec: int = 0

func _ready() -> void:
	health = max_health

func setup(maximum: float) -> void:
	max_health = maximum
	health = maximum
	is_dead = false

## Полный путь получения урона. Вызывается только серверной логикой (hitbox активен лишь на сервере).
func take_damage(damage: Dictionary) -> bool:
	if is_dead or invulnerable:
		return false
	if Time.get_ticks_msec() < invulnerable_until_msec:
		return false
	var amount: float = float(damage.get("amount", 0.0))
	if amount <= 0.0:
		return false
	health = maxf(0.0, health - amount)
	damage_taken.emit(amount, damage)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		is_dead = true
		died.emit(damage)
	return true

func heal(amount: float) -> void:
	if is_dead or amount <= 0.0:
		return
	health = minf(max_health, health + amount)
	healed.emit(amount)
	health_changed.emit(health, max_health)

func grant_invulnerability(duration_sec: float) -> void:
	invulnerable_until_msec = Time.get_ticks_msec() + int(duration_sec * 1000.0)

## Для репликации: клиент применяет присланное сервером значение без сигнальной логики смерти дважды.
func replicate_state(new_health: float, new_dead: bool) -> void:
	var changed := !is_equal_approx(health, new_health) or is_dead != new_dead
	health = new_health
	is_dead = new_dead
	if changed:
		health_changed.emit(health, max_health)

func health_factor() -> float:
	return clampf(health / maxf(1.0, max_health), 0.0, 1.0)
