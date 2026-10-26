class_name ProgressionSystem
extends Node
## ProgressionSystem — серверный авторитет опыта, уровней, улучшений и магазина (Этап 2).
## Все начисления и траты происходят ТОЛЬКО здесь; клиентские RPC валидируются
## (отправитель == владелец состояния, фаза, баланс, лимиты, актуальность предложения).
## Узел живёт в сцене арены; клиентская часть — зеркало local_state для HUD.

var balance: ProgressionBalance
## peer_id -> ProgressionState (сервер). На клиенте пуст, кроме local_state-зеркала.
var states: Dictionary = {}
## Зеркало собственного состояния на клиенте (для HUD).
var local_state: Dictionary = {}

var _contrib: Dictionary = {} ## instance_id врага -> {peer_id: суммарный урон}
var _mc: MatchController
var _wave_manager: WaveManager

func _ready() -> void:
	add_to_group("progression_system")
	var path := Game.progression_balance_path
	balance = load(path) as ProgressionBalance
	if balance == null:
		push_error("[Progression] Баланс не загружен: %s" % path)
		balance = ProgressionBalance.new()
	if Net.is_server():
		_setup_server()

func _setup_server() -> void:
	var snapshot: Dictionary = Game.match_players_snapshot
	if snapshot.is_empty():
		snapshot = Net.players
	for peer_id in snapshot.keys():
		var st := ProgressionState.new()
		st.peer_id = int(peer_id)
		states[int(peer_id)] = st
	var mcs := get_tree().get_nodes_in_group("match_controller")
	_mc = mcs[0] if mcs.size() > 0 else null
	var arena := get_parent()
	if arena != null:
		_wave_manager = arena.get_node_or_null(^"WaveManager") as WaveManager
	if _wave_manager != null:
		_wave_manager.enemy_spawned.connect(_register_enemy)
	## Все пиры сразу видят своё начальное состояние.
	for peer_id in states.keys():
		sync_to(int(peer_id))
	print("[Progression] Состояния созданы для пиров: %s" % str(states.keys()))

# ------------------------------------------------------------------ XP за врагов

func _register_enemy(enemy: Node) -> void:
	if not Net.is_server():
		return
	var foe := enemy as EnemyBase
	if foe == null:
		return
	foe.health.damage_taken.connect(_on_enemy_damaged_xp.bind(foe))
	foe.died_on_server.connect(_on_enemy_died_rewards)

func _on_enemy_damaged_xp(amount: float, damage: Dictionary, foe: EnemyBase) -> void:
	var peer := int(damage.get("attacker_peer", 0))
	if not states.has(peer):
		return
	var key := foe.get_instance_id()
	var entry: Dictionary = _contrib.get(key, {})
	entry[peer] = float(entry.get(peer, 0.0)) + amount
	_contrib[key] = entry

## Награда РОВНО ОДИН раз за смерть: XP пропорционально вкладу урона, монеты — добившему.
func _on_enemy_died_rewards(foe: EnemyBase, killing_damage: Dictionary) -> void:
	if not Net.is_server():
		return
	if _mc != null and (_mc.phase == MatchController.Phase.VICTORY or _mc.phase == MatchController.Phase.DEFEAT):
		return ## после финала матча награды не начисляются
	if foe.has_meta("rewards_granted"):
		return ## защита от повторного сигнала/вызова (двойные награды недопустимы)
	foe.set_meta("rewards_granted", true)
	var key := foe.get_instance_id()
	var contrib: Dictionary = _contrib.get(key, {})
	_contrib.erase(key)
	var category: int = foe.def.category if foe.def != null else 0
	var xp_total := balance.xp_for_category(category)
	var total_dmg := 0.0
	for peer in contrib.keys():
		total_dmg += float(contrib[peer])
	if total_dmg > 0.0:
		for peer in contrib.keys():
			var share := float(contrib[peer]) / total_dmg
			var xp := maxi(1, int(round(xp_total * share)))
			add_xp(int(peer), xp)
	var killer := int(killing_damage.get("attacker_peer", 0))
	if states.has(killer):
		add_coins(killer, balance.coins_kill, "Монеты за убийство")

## Награда за разрушение объекта (ящики и пр.) — вызывается сигналом destructible_destroyed.
func grant_prop_reward(peer_id: int) -> void:
	if not Net.is_server() or not states.has(peer_id):
		return
	if _mc != null and (_mc.phase == MatchController.Phase.VICTORY or _mc.phase == MatchController.Phase.DEFEAT):
		return
	add_xp(peer_id, balance.xp_crate)
	add_coins(peer_id, balance.coins_crate, "Монеты за разрушение")

# ------------------------------------------------------------------ XP / уровни

func add_xp(peer_id: int, amount: int) -> void:
	if not Net.is_server() or amount <= 0:
		return
	var st: ProgressionState = states.get(peer_id, null)
	if st == null:
		return
	if st.level >= balance.max_level:
		return ## максимальный уровень: опыт больше не копится (поведение зафиксировано конфигом)
	st.xp += amount
	_toast(peer_id, "+%d XP" % amount, "xp")
	var leveled := false
	while st.level < balance.max_level and st.xp >= balance.xp_required(st.level):
		st.xp -= balance.xp_required(st.level)
		st.level += 1
		st.pending_choices += 1
		leveled = true
	if st.level >= balance.max_level:
		st.xp = 0
	if leveled:
		_toast(peer_id, "УРОВЕНЬ %d! Выберите улучшение" % st.level, "levelup")
		## Эволюция (Этап 3): сервер проверяет порог уровня после каждого уровня.
		_check_evolution(peer_id, st.level)
	_try_open_offer(peer_id)
	sync_to(peer_id)

## Серверный триггер эволюции: пешка сама проверяет цепочку форм (идемпотентно).
func _check_evolution(peer_id: int, level: int) -> void:
	if not is_inside_tree():
		return ## окно смены сцены: система прогрессии уничтожается
	var pawn := _pawn_of(peer_id)
	if pawn == null or not is_instance_valid(pawn):
		return
	pawn.try_evolve_for_level(level)

func add_coins(peer_id: int, amount: int, reason: String = "") -> void:
	if not Net.is_server() or amount == 0:
		return
	var st: ProgressionState = states.get(peer_id, null)
	if st == null:
		return
	st.coins = maxi(0, st.coins + amount)
	if amount > 0:
		_toast(peer_id, "+%d монет%s" % [amount, (" (%s)" % reason) if reason != "" else ""], "coins")
	sync_to(peer_id)

# ------------------------------------------------------------------ предложения улучшений

func eligible_upgrades(st: ProgressionState) -> Array:
	var result: Array = []
	for def in Content.all_upgrades():
		var taken: int = int(st.upgrade_levels.get(def.id, 0))
		if taken < def.max_level:
			result.append(def)
	return result

func _try_open_offer(peer_id: int) -> void:
	var st: ProgressionState = states.get(peer_id, null)
	if st == null or st.offer_active or st.pending_choices <= 0:
		return
	var pool := eligible_upgrades(st)
	if pool.is_empty():
		st.pending_choices = 0 ## улучшений нет — корректно закрываем выбор без зависания
		sync_to(peer_id)
		return
	## Серверный детерминированный RNG (Game.rng от match_seed) — клиентский random не используется.
	var indices := range(pool.size())
	for i in range(indices.size() - 1, 0, -1):
		var j := Game.next_rand() % (i + 1)
		var tmp: int = indices[i]
		indices[i] = indices[j]
		indices[j] = tmp
	var chosen: Array[StringName] = []
	for k in range(mini(3, indices.size())):
		chosen.append((pool[indices[k]] as UpgradeDefinition).id)
	st.offer_ids = chosen
	st.offer_active = true
	st.offer_deadline_msec = Time.get_ticks_msec() + int(balance.choice_time * 1000.0)
	if Net.is_online():
		cl_offer.rpc_id(peer_id, chosen, int(balance.choice_time * 1000.0))
	elif peer_id == Net.my_id():
		cl_offer_local(chosen, int(balance.choice_time * 1000.0))

func _process(_delta: float) -> void:
	if not Net.is_server():
		return
	var now := Time.get_ticks_msec()
	var fight_time := _delta if (_mc != null and _mc.phase == MatchController.Phase.FIGHT) else 0.0
	for peer_id in states.keys():
		var st: ProgressionState = states[peer_id]
		## Автовыбор по истечении серверного таймера — первое предложение (безопасный fallback).
		if st.offer_active and now >= st.offer_deadline_msec:
			if st.offer_ids.size() > 0:
				_apply_choice(int(peer_id), st.offer_ids[0], true)
		## Временные баффы тикают только в бою (фаза FIGHT).
		if fight_time > 0.0 and st.buffs.size() > 0:
			var changed := false
			for i in range(st.buffs.size() - 1, -1, -1):
				var b: Dictionary = st.buffs[i]
				if float(b["remaining"]) > 0.0:
					b["remaining"] = float(b["remaining"]) - fight_time
					if float(b["remaining"]) <= 0.0:
						st.buffs.remove_at(i)
						changed = true
			if changed:
				_refresh_pawn(int(peer_id), st)
				sync_to(int(peer_id))

# ------------------------------------------------------------------ выбор улучшения

@rpc("any_peer", "call_remote", "reliable")
func cl_choose(id_str: String) -> void:
	if not Net.is_server():
		return
	if not is_inside_tree():
		return ## окно смены сцены (реванш/меню): multiplayer == null — RPC устарел
	var peer := multiplayer.get_remote_sender_id()
	if not states.has(peer):
		return
	_apply_choice(peer, StringName(id_str), false)

## Единая точка применения: валидация -> эффект РОВНО один раз -> синхронизация.
func _apply_choice(peer_id: int, id: StringName, auto: bool) -> void:
	var st: ProgressionState = states.get(peer_id, null)
	if st == null or not st.offer_active:
		return ## повторный RPC / выбор без открытого предложения — эффекта нет
	if not st.offer_ids.has(id):
		_toast(peer_id, "Недопустимый выбор улучшения", "info")
		return
	var def := Content.get_upgrade(id)
	if def == null:
		st.offer_active = false
		st.offer_ids.clear()
		sync_to(peer_id)
		return
	st.offer_active = false
	st.offer_ids.clear()
	st.pending_choices = maxi(0, st.pending_choices - 1)
	st.upgrade_levels[id] = int(st.upgrade_levels.get(id, 0)) + 1
	if def.target == UpgradeDefinition.Target.SELF:
		_refresh_pawn(peer_id, st)
	else:
		var giga := _gigachad()
		if giga != null:
			giga.add_team_upgrade(def.effect, def.value)
	var suffix := " (автовыбор)" if auto else ""
	_toast(peer_id, "Улучшение: %s ур.%d%s" % [def.display_name, int(st.upgrade_levels[id]), suffix], "levelup")
	if Net.is_online():
		cl_offer_close.rpc_id(peer_id)
	elif peer_id == Net.my_id():
		Events.upgrade_offer_closed.emit()
	sync_to(peer_id)
	_try_open_offer(peer_id) ## несколько накопленных уровней -> следующее предложение

# ------------------------------------------------------------------ магазин

@rpc("any_peer", "call_remote", "reliable")
func cl_buy(item_str: String) -> void:
	if not Net.is_server():
		return
	if not is_inside_tree():
		return ## см. cl_choose
	try_buy(multiplayer.get_remote_sender_id(), StringName(item_str))

## Полная серверная валидация покупки. Возвращает успех (используется и тестами).
func try_buy(peer_id: int, id: StringName) -> bool:
	if not Net.is_server():
		return false
	var st: ProgressionState = states.get(peer_id, null)
	if st == null:
		return false
	if _mc == null or _mc.phase != MatchController.Phase.INTERMISSION:
		_shop_fail(peer_id, "Магазин открыт только между волнами")
		return false
	var def := Content.get_shop_item(id)
	if def == null:
		_shop_fail(peer_id, "Неизвестный предмет")
		return false
	if st.coins < def.price:
		_shop_fail(peer_id, "Недостаточно монет (%d/%d)" % [st.coins, def.price])
		return false
	if def.limit_per_intermission >= 0 and int(st.purchase_intermission.get(id, 0)) >= def.limit_per_intermission:
		_shop_fail(peer_id, "Лимит покупок в эту интермиссию исчерпан")
		return false
	if def.limit_per_match >= 0 and int(st.purchase_match.get(id, 0)) >= def.limit_per_match:
		_shop_fail(peer_id, "Лимит покупок за матч исчерпан")
		return false
	var pawn := _pawn_of(peer_id)
	if pawn == null and def.effect != ShopItemDefinition.Effect.DAMAGE_TAKEN_PERM:
		_shop_fail(peer_id, "Персонаж недоступен")
		return false

	## Списание и учёт — атомарно, до применения эффекта.
	st.coins -= def.price
	st.purchase_match[id] = int(st.purchase_match.get(id, 0)) + 1
	st.purchase_intermission[id] = int(st.purchase_intermission.get(id, 0)) + 1
	match def.effect:
		ShopItemDefinition.Effect.HEAL_PCT:
			pawn.health.heal(pawn.effective_max_health() * def.value)
		ShopItemDefinition.Effect.DAMAGE_BUFF_TIMED:
			st.buffs.append({"effect": def.effect, "value": def.value, "remaining": def.duration})
		ShopItemDefinition.Effect.DAMAGE_TAKEN_PERM:
			st.buffs.append({"effect": def.effect, "value": def.value, "remaining": -1.0})
		ShopItemDefinition.Effect.MAX_HEALTH_ADD:
			pawn.health.add_max_health(def.value)
		ShopItemDefinition.Effect.LIFESTEAL_ON_KILL:
			st.lifesteal_on_kill += def.value
	_refresh_pawn(peer_id, st)
	_shop_ok(peer_id, "Куплено: %s (−%d монет)" % [def.display_name, def.price])
	sync_to(peer_id)
	return true

# ------------------------------------------------------------------ межволновая фаза

@rpc("any_peer", "call_remote", "reliable")
func cl_wave_ready(value: bool) -> void:
	if not Net.is_server():
		return
	if not is_inside_tree():
		return ## см. cl_choose
	set_wave_ready(multiplayer.get_remote_sender_id(), bool(value))

func set_wave_ready(peer_id: int, value: bool) -> void:
	if not Net.is_server():
		return
	var st: ProgressionState = states.get(peer_id, null)
	if st == null:
		return
	st.wave_ready = value
	_broadcast_ready_states()
	if _mc != null:
		_mc.on_wave_ready_changed()

func are_all_wave_ready() -> bool:
	if states.is_empty():
		return false
	for st in states.values():
		if not (st as ProgressionState).wave_ready:
			return false
	return true

func _broadcast_ready_states() -> void:
	var map := {}
	for peer_id in states.keys():
		map[int(peer_id)] = (states[peer_id] as ProgressionState).wave_ready
	if Net.is_online():
		cl_ready_states.rpc(map)
	else:
		Events.wave_ready_state_changed.emit(map)

## Серверный вход в интермиссию: сброс лимитов/готовности, награда за волну, воскрешение.
func on_intermission_start(alive_peers: Array) -> void:
	if not Net.is_server():
		return
	for peer_id in states.keys():
		var st: ProgressionState = states[peer_id]
		st.purchase_intermission.clear()
		st.wave_ready = false
	for peer_id in alive_peers:
		add_coins(int(peer_id), balance.coins_wave_clear, "волна отбита")
	_revive_downed()
	_broadcast_ready_states()
	for peer_id in states.keys():
		sync_to(int(peer_id))

func _revive_downed() -> void:
	for node in get_tree().get_nodes_in_group("player_pawns"):
		var pawn := node as PlayerPawn
		if pawn != null and pawn.state == PlayerPawn.State.DOWN:
			pawn.revive_now(0.5)

# ------------------------------------------------------------------ модификаторы характеристик

func compute_mods(st: ProgressionState) -> Dictionary:
	var m := {
		"max_health_mult": 1.0,
		"damage_mult": 1.0,
		"attack_cd_mult": 1.0,
		"speed_mult": 1.0,
		"range_mult": 1.0,
		"kb_mult": 1.0,
		"dodge_cd_mult": 1.0,
		"iframe_add": 0.0,
		"respawn_add": 0.0,
		"damage_taken_mult": 1.0,
	}
	for id in st.upgrade_levels.keys():
		var def := Content.get_upgrade(id)
		if def == null or def.target != UpgradeDefinition.Target.SELF:
			continue
		var lvl := int(st.upgrade_levels[id])
		match def.effect:
			UpgradeDefinition.Effect.MAX_HEALTH_MULT:
				m["max_health_mult"] += def.value * lvl
			UpgradeDefinition.Effect.DAMAGE_MULT:
				m["damage_mult"] += def.value * lvl
			UpgradeDefinition.Effect.ATTACK_CD_MULT:
				m["attack_cd_mult"] *= pow(1.0 - def.value, lvl)
			UpgradeDefinition.Effect.SPEED_MULT:
				m["speed_mult"] += def.value * lvl
			UpgradeDefinition.Effect.RANGE_MULT:
				m["range_mult"] += def.value * lvl
			UpgradeDefinition.Effect.KNOCKBACK_MULT:
				m["kb_mult"] += def.value * lvl
			UpgradeDefinition.Effect.DODGE_CD_MULT:
				m["dodge_cd_mult"] *= pow(1.0 - def.value, lvl)
			UpgradeDefinition.Effect.IFRAME_ADD:
				m["iframe_add"] += def.value * lvl
			UpgradeDefinition.Effect.RESPAWN_FACTOR_ADD:
				m["respawn_add"] += def.value * lvl
			UpgradeDefinition.Effect.DAMAGE_TAKEN_MULT:
				m["damage_taken_mult"] *= pow(1.0 - def.value, lvl)
	for b in st.buffs:
		match int(b["effect"]):
			ShopItemDefinition.Effect.DAMAGE_BUFF_TIMED:
				m["damage_mult"] *= 1.0 + float(b["value"])
			ShopItemDefinition.Effect.DAMAGE_TAKEN_PERM:
				m["damage_taken_mult"] *= 1.0 - float(b["value"])
	## Защита от вырожденных значений: никаких отрицательных/нулевых cooldown и бесконечной неуязвимости.
	m["attack_cd_mult"] = clampf(m["attack_cd_mult"], 0.45, 1.5)
	m["dodge_cd_mult"] = clampf(m["dodge_cd_mult"], 0.45, 1.5)
	m["damage_taken_mult"] = clampf(m["damage_taken_mult"], 0.3, 1.0)
	m["max_health_mult"] = maxf(0.5, m["max_health_mult"])
	m["speed_mult"] = clampf(m["speed_mult"], 0.5, 2.0)
	return m

func _refresh_pawn(peer_id: int, st: ProgressionState) -> void:
	var pawn := _pawn_of(peer_id)
	if pawn == null:
		return
	pawn.apply_progression(compute_mods(st), {"lifesteal": st.lifesteal_on_kill})

# ------------------------------------------------------------------ синхронизация / утилиты

func sync_to(peer_id: int) -> void:
	var st: ProgressionState = states.get(peer_id, null)
	if st == null:
		return
	var payload := st.to_sync_dict(balance)
	if Net.is_online():
		cl_prog.rpc_id(peer_id, payload)
	elif peer_id == Net.my_id():
		local_state = payload
		Events.progression_updated.emit(payload)

func _toast(peer_id: int, text: String, kind: String) -> void:
	if Net.is_online():
		cl_toast.rpc_id(peer_id, text, kind)
	elif peer_id == Net.my_id():
		Events.local_toast.emit(text, kind)

func _shop_fail(peer_id: int, text: String) -> void:
	push_warning("[Progression] Отказ покупки peer %d: %s" % [peer_id, text])
	if Net.is_online():
		cl_shop_result.rpc_id(peer_id, false, text)
	else:
		Events.shop_result_msg.emit(false, text)

func _shop_ok(peer_id: int, text: String) -> void:
	if Net.is_online():
		cl_shop_result.rpc_id(peer_id, true, text)
	else:
		Events.shop_result_msg.emit(true, text)

func _pawn_of(peer_id: int) -> PlayerPawn:
	for node in get_tree().get_nodes_in_group("player_pawns"):
		var pawn := node as PlayerPawn
		if pawn != null and pawn.owner_peer == peer_id:
			return pawn
	return null

func _gigachad() -> GigaChad:
	var gs := get_tree().get_nodes_in_group("gigachad")
	return gs[0] if gs.size() > 0 else null

## Публичный запрос выбора (для UI и тестов): на клиенте уходит RPC на сервер.
func request_choose(id: StringName) -> void:
	if Net.is_online() and not Net.is_server():
		cl_choose.rpc_id(1, String(id))
	else:
		_apply_choice(Net.my_id(), id, false)

func request_buy(id: StringName) -> void:
	if Net.is_online() and not Net.is_server():
		cl_buy.rpc_id(1, String(id))
	else:
		try_buy(Net.my_id(), id)

func request_wave_ready(value: bool) -> void:
	if Net.is_online() and not Net.is_server():
		cl_wave_ready.rpc_id(1, value)
	else:
		set_wave_ready(Net.my_id(), value)

# ------------------------------------------------------------------ клиентские RPC (косметика/зеркало)

@rpc("authority", "call_local", "reliable")
func cl_prog(payload: Dictionary) -> void:
	local_state = payload
	Events.progression_updated.emit(payload)

@rpc("authority", "call_local", "reliable")
func cl_offer(ids: Array, duration_msec: int) -> void:
	cl_offer_local(ids, duration_msec)

func cl_offer_local(ids: Array, duration_msec: int) -> void:
	var as_names: Array[StringName] = []
	for id in ids:
		as_names.append(StringName(str(id)))
	Events.upgrade_offer_opened.emit(as_names, Time.get_ticks_msec() + duration_msec)

@rpc("authority", "call_local", "reliable")
func cl_offer_close() -> void:
	Events.upgrade_offer_closed.emit()

@rpc("authority", "call_local", "reliable")
func cl_toast(text: String, kind: String) -> void:
	Events.local_toast.emit(text, kind)

@rpc("authority", "call_local", "reliable")
func cl_shop_result(ok: bool, text: String) -> void:
	Events.shop_result_msg.emit(ok, text)

@rpc("authority", "call_local", "reliable")
func cl_ready_states(map: Dictionary) -> void:
	Events.wave_ready_state_changed.emit(map)
