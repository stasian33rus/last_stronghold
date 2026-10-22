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

## Локальные косметические запросы (каждый пир исполняет у себя).
signal local_hitstop_request(world_pos: Vector3, strength: float)
signal local_camera_shake(strength: float)
signal local_announcement(text: String, duration: float)

## Матч: фаза/результат (эмитит MatchController на всех пирах).
signal match_phase_changed(phase: int)
signal match_ended(victory: bool, stats: Dictionary)
