extends Node
## Events — глобальная шина событий (autoload). Развязывает системы:
## бой/HUD/камера/эффекты подписываются на сигналы, не зная друг о друге.

## Локальная пешка игрока готова (на клиенте-владельце и на сервере для хоста).
signal local_pawn_ready(pawn: Node)

## Сервер зафиксировал наше попадание (для статистики/будущих комбо, Этап 4).
signal server_hit_landed(attacker: Node, target: Node, damage: Dictionary)

## Реплицированное состояние сущности изменилось (для визуала/HUD).
signal sync_state_changed(unit: Node, new_state: int)
signal sync_attack_started(unit: Node)
## Эволюция формы (Этап 3): эмитится на КАЖДОМ пире — на сервере из _apply_form,
## на клиентах из репликации поля "f" (BodySync). unit — пешка, form_index 1/2.
signal unit_evolved(unit: Node, form_index: int, form_name: String)

## Локальные косметические запросы (каждый пир исполняет у себя).
signal local_hitstop_request(world_pos: Vector3, strength: float)
signal local_camera_shake(strength: float)
signal local_announcement(text: String, duration: float)

## Матч: фаза/результат (эмитит MatchController на всех пирах).
signal match_phase_changed(phase: int)
signal match_ended(victory: bool, stats: Dictionary)

## Прогрессия и магазин (Этап 2) — локальные события для UI.
## Всплывающее уведомление: kind = "xp" | "coins" | "levelup" | "shop" | "info".
signal local_toast(text: String, kind: String)
## Обновлённое локальное состояние прогрессии (словарь-зеркало серверного).
signal progression_updated(state: Dictionary)
## Сервер открыл выбор улучшения: ids (до 3), дедлайн (msec по часам принимающего пира).
signal upgrade_offer_opened(ids: Array, deadline_msec: int)
signal upgrade_offer_closed
## Ответ магазина конкретному пиру.
signal shop_result_msg(ok: bool, text: String)
## Межволновая фаза: обновлённый список ready (peer_id -> bool) — для HUD.
signal wave_ready_state_changed(states: Dictionary)
