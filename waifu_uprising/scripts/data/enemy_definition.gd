class_name EnemyDefinition
extends Resource
## Данные архетипа врага Ордена Гламура. Этап 1: «Пижон» (ближний боец).

@export var id: StringName = &"fop"
@export var display_name: String = "Пижон"
@export var scene_path: String = "res://scenes/enemies/fop.tscn"
@export var color: Color = Color("b96bd6")
## Категория награды (ProgressionBalance): 0 = обычный, 1 = элита, 2 = босс.
@export_range(0, 2) var category: int = 0

@export var max_health: float = 60.0
@export var move_speed: float = 4.2
@export var acceleration: float = 24.0
@export var friction: float = 18.0
## Масса влияет на восприимчивость к отбрасыванию: kb * (1 / knockback_mass).
@export var knockback_mass: float = 1.0

@export var attack_damage: float = 10.0
@export var attack_range: float = 2.2 ## Дистанция, с которой начинается выпад.
@export var attack_windup: float = 0.55 ## Телеграф: поклон/стойка перед выпадом (ТЗ §9.1).
@export var attack_active: float = 0.14
@export var attack_recover: float = 0.55
@export var attack_lunge_speed: float = 9.0 ## Рывок вперёд во время выпада.
@export var attack_knockback: float = 4.5

@export var aggro_radius: float = 30.0
@export var hitstun_time: float = 0.28
@export var heavy_hitstun_threshold: float = 7.0 ## Отбрасывание сильнее этого значения -> длительный стаггер.
@export var heavy_hitstun_time: float = 0.5
