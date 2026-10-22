class_name ClassDefinition
extends Resource
## Данные игрового класса вайфу. Этап 1: один класс (Берсерка).
## Архитектура готова к 8 классам и эволюциям (evolution_chain — Этап 3).

@export var id: StringName = &"berserk"
@export var display_name: String = "Берсерка"
@export_multiline var description: String = ""
@export var color: Color = Color.MAGENTA

## Базовые характеристики движения и выживания.
@export var max_health: float = 120.0
@export var move_speed: float = 7.0
@export var acceleration: float = 45.0
@export var friction: float = 40.0
@export var jump_velocity: float = 0.0 ## 0 — без прыжка (арена-слэшер), оставить на будущее.

## Ближний бой.
@export var attack_damage: float = 26.0
@export var attack_range: float = 2.6 ## Радиус зоны поражения удара.
@export var attack_arc_deg: float = 120.0 ## Сектор удара (для проверки угла на сервере).
@export var attack_windup: float = 0.14 ## Задержка до активации хитбокса.
@export var attack_active: float = 0.12 ## Окно активности хитбокса.
@export var attack_recover: float = 0.22 ## Восстановление после удара.
@export var attack_cooldown: float = 0.14 ## Пауза между ударами после восстановления.
@export var attack_knockback: float = 9.0 ## Сила отбрасывания врагов (ТЗ §13).
@export var attack_move_lock: float = 0.55 ## Насколько сильно удар сковывает движение (0..1).

## Рывок-уклонение.
@export var dodge_speed: float = 16.0
@export var dodge_duration: float = 0.22
@export var dodge_cooldown: float = 1.1
@export var dodge_iframes: float = 0.28

## Повреждённое состояние.
@export var respawn_time: float = 5.0
@export var respawn_health_factor: float = 0.6

## Заготовки под Этапы 2-3 (не используются в вертикальном срезе, но данные уже типизированы).
@export var xp_curve_base: float = 100.0
@export var evolution_chain: Array[Resource] = [] ## ClassDefinition -> ClassDefinition (формы 2 и 3).
