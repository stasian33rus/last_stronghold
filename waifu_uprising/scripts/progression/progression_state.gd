class_name ProgressionState
extends RefCounted
## Серверное состояние прогрессии ОДНОГО игрока (Этап 2).
## Единственный источник истины — ProgressionSystem на сервере;
## клиенты получают только sync-словарь для HUD.

var peer_id: int = 1
var level: int = 1
var xp: int = 0
var coins: int = 0
var pending_choices: int = 0
## id улучшения (StringName) -> взятый уровень.
var upgrade_levels: Dictionary = {}
## Покупки: за матч и за текущую интермиссию (id -> количество).
var purchase_match: Dictionary = {}
var purchase_intermission: Dictionary = {}
var wave_ready: bool = false

## Активное предложение улучшений (серверные поля).
var offer_ids: Array[StringName] = []
var offer_deadline_msec: int = 0
var offer_active: bool = false

## Баффы магазина: {"effect": int, "value": float, "remaining": float} (-1 = постоянный).
var buffs: Array[Dictionary] = []
var lifesteal_on_kill: float = 0.0

func to_sync_dict(balance: ProgressionBalance) -> Dictionary:
	var buff_list: Array = []
	for b in buffs:
		buff_list.append({"effect": int(b["effect"]), "value": float(b["value"]), "remaining": float(b["remaining"])})
	return {
		"peer": peer_id,
		"level": level,
		"xp": xp,
		"xp_need": balance.xp_required(level),
		"max_level": balance.max_level,
		"coins": coins,
		"pending": pending_choices,
		"upgrades": upgrade_levels.duplicate(),
		"buffs": buff_list,
		"lifesteal": lifesteal_on_kill,
		"wave_ready": wave_ready,
	}
