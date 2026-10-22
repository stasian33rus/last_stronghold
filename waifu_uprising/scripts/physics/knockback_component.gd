class_name KnockbackComponent
extends Node
## Компонент отбрасывания для CharacterBody3D (ТЗ §13: «удары должны иметь вес»).
## Владелец каждый физический кадр забирает накопленную скорость через consume().
## Работает на сервере; клиенты видят результат через репликацию позиции.

@export var decay: float = 9.0 ## Экспоненциальное затухание, 1/с.
@export var max_speed: float = 30.0

var kb_velocity: Vector3 = Vector3.ZERO

func apply(direction: Vector3, force: float, knockback_mass: float = 1.0) -> void:
	if force <= 0.0:
		return
	var dir := direction
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var impulse := dir * (force / maxf(0.2, knockback_mass))
	impulse.y = maxf(0.0, force * 0.12) ## лёгкий подскок — читается «вес» удара
	kb_velocity = (kb_velocity + impulse).limit_length(max_speed)

func consume(delta: float) -> Vector3:
	var result := kb_velocity
	kb_velocity = kb_velocity.move_toward(Vector3.ZERO, kb_velocity.length() * decay * delta + 0.02)
	if kb_velocity.length_squared() < 0.01:
		kb_velocity = Vector3.ZERO
	return result

func cancel() -> void:
	kb_velocity = Vector3.ZERO
