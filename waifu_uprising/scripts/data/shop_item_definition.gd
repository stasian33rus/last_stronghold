class_name ShopItemDefinition
extends Resource
## Предмет магазина межволновой фазы (Этап 2, ТЗ §11).
## Эффекты применяются сервером в ProgressionSystem.shop_buy после полной валидация:
## фаза INTERMISSION, цена, баланс, лимиты (за интермиссию и за матч).

enum Effect {
	HEAL_PCT,            ## мгновенное лечение % от макс. HP
	DAMAGE_BUFF_TIMED,   ## временный множитель урона
	DAMAGE_TAKEN_PERM,   ## постоянное (на матч) снижение входящего урона
	MAX_HEALTH_ADD,      ## +макс. HP и столько же текущего
	LIFESTEAL_ON_KILL,   ## лечение % от макс. HP за каждое убийство (постоянно)
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var price: int = 20
@export var effect: int = Effect.HEAL_PCT
@export var value: float = 0.4
## Длительность временного эффекта, сек (0 = постоянный в рамках матча).
@export var duration: float = 0.0
## Лимиты: -1 = без лимита.
@export var limit_per_intermission: int = -1
@export var limit_per_match: int = -1
@export var color: Color = Color(0.8, 0.75, 0.5)
@export var glyph: String = "$"
