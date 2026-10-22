class_name ClassDefinition
extends Resource
## Данные игрового класса вайфу (Этап 3: 8 классов × 3 формы = 24 ресурса).
## Каждая форма — отдельный ClassDefinition; форма I выбирается в лобби,
## формы II/III открываются сервером через evolution_chain формы I.
## Боевая логика едина (PlayerPawn); формы отличаются данными: статами,
## трейтами (shockwave/execute/frenzy) и визуальным слотом (model_scene/.glb).

## Типы оружия процедурной заглушки (пока нет .glb) — см. player_visuals.gd.
enum VisualWeapon {
	NONE = 0, HAMMER = 1, SWORD = 2, DUAL_BLADES = 3, WRENCH_GUN = 4,
	STAFF = 5, MIC = 6, RIFLE = 7, FLASK = 8, SHIELD_GAUNTLET = 9,
}
## Типы причёсок процедурной заглушки.
enum VisualHair { SHORT = 0, LONG = 1, TWINTAILS = 2, PONYTAIL = 3, BRAID = 4, BOB = 5, WAVY = 6 }

@export var id: StringName = &"berserk"
@export var display_name: String = "Берсерка"
@export_multiline var description: String = ""
@export var color: Color = Color.MAGENTA

## --- Форма эволюции (Этап 3) ---
@export_range(0, 2) var form_index: int = 0 ## 0 = форма I (базовая/выбираемая), 1 = II, 2 = III.
@export var base_id: StringName = &"" ## Для форм II/III: id базового класса (форма I).
@export var unlock_level: int = 0 ## Уровень прогрессии для открытия этой формы (серверное условие).
@export var implemented: bool = false ## true только у полностью реализованных классов (доступ в лобби).

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

## Заготовка мета-прогрессии (не используется в забеге — формула в ProgressionBalance).
@export var xp_curve_base: float = 100.0
## Цепочка эволюции формы I: [ClassDefinition формы II, ClassDefinition формы III].
@export var evolution_chain: Array[Resource] = []

## --- Боевые трейты форм (данные; хуки в PlayerPawn/HitboxComponent) ---
## Канон Берсерка (GAME_DESIGN §6.6): ударная волна, бонусы при низком HP,
## усиленное отбрасывание, мощные добивания. Все поля нейтральны по умолчанию —
## класс без трейтов играет базовый комплект (удар + рывок).
@export_group("Traits: ударная волна (комбо)")
@export var shockwave_every_n_hits: int = 0 ## Каждый N-й подтверждённый удар — волна; 0 = выкл.
@export var shockwave_radius: float = 4.5
@export var shockwave_damage_mult: float = 0.5 ## Доля урона атаки для волны.
@export var shockwave_knockback: float = 10.0

@export_group("Traits: добивание")
@export_range(0.0, 1.0) var execute_threshold: float = 0.0 ## HP-доля цели ниже этой — добивание; 0 = выкл.
@export var execute_damage_mult: float = 1.0

@export_group("Traits: неистовство (низкое HP)")
@export_range(0.0, 1.0) var frenzy_hp_threshold: float = 0.0 ## Собственное HP ниже доли — режим неистовства; 0 = выкл.
@export var frenzy_damage_mult: float = 1.0
@export var frenzy_attack_cd_mult: float = 1.0 ## < 1 — атаки быстрее.

## --- Визуальный слот формы (изолирован от боевой логики) ---
@export_group("Visual slot")
## Сюда в Godot Inspector назначается сцена импортированной модели (.glb) формы.
## Если задана — процедурная заглушка не строится, используется модель.
@export var model_scene: PackedScene = null
@export var visual_weapon: int = VisualWeapon.HAMMER
@export var visual_hair: int = VisualHair.LONG
@export var visual_hair_color: Color = Color(0.95, 0.2, 0.45)
@export var visual_accent: Color = Color(1.0, 0.85, 0.35) ## Отделка/свечение/оружие.
@export_range(0.0, 2.0) var visual_glow: float = 0.0 ## 0 — без свечения, форма III — максимум.
@export var visual_scale: float = 1.0 ## Общая крупность силуэта формы.
