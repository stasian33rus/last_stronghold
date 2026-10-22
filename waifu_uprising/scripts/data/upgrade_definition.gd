class_name UpgradeDefinition
extends Resource
## Определение внутризабежного улучшения (Этап 2, ТЗ §12).
## Эффекты РЕАЛЬНО меняют характеристики: применяются сервером через
## ProgressionSystem -> PlayerPawn.refresh_effective_stats() / GigaChad.

enum Rarity { COMMON = 0, RARE = 1, EPIC = 2 }
enum Target { SELF = 0, GIGACHAD = 1 }

## Семантика эффектов (см. ProgressionSystem.compute_mods):
## *_MULT аддитивные: (1 + value*уровень); *_CD_MULT и DAMAGE_TAKEN_MULT:
## мультипликативное сокращение ((1 - value)^уровень, с полом); *_ADD: value*уровень.
enum Effect {
	MAX_HEALTH_MULT,
	DAMAGE_MULT,
	ATTACK_CD_MULT,
	SPEED_MULT,
	RANGE_MULT,
	KNOCKBACK_MULT,
	DODGE_CD_MULT,
	RESO_HEAL_MULT,
	RESO_RATE_MULT,
	IFRAME_ADD,
	RESPAWN_FACTOR_ADD,
	DAMAGE_TAKEN_MULT,
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var rarity: int = Rarity.COMMON
@export_range(1, 10) var max_level: int = 3
@export var effect: int = Effect.MAX_HEALTH_MULT
@export var value: float = 0.15
@export var target: int = Target.SELF
## Цвет акцента карточки (fallback иконки — крупные символы/цвет, без внешних текстур).
@export var color: Color = Color(0.6, 0.65, 0.85)
@export var glyph: String = "+"

static func rarity_name(r: int) -> String:
	match r:
		Rarity.COMMON: return "Обычное"
		Rarity.RARE: return "Редкое"
		Rarity.EPIC: return "Эпическое"
	return "?"

static func rarity_color(r: int) -> Color:
	match r:
		Rarity.COMMON: return Color(0.62, 0.68, 0.85)
		Rarity.RARE: return Color(0.3, 0.9, 1.0)
		Rarity.EPIC: return Color(1.0, 0.62, 0.92)
	return Color.WHITE
