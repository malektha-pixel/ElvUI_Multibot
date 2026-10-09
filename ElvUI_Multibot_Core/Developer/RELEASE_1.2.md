# ElvUI_Multibot_Core 1.2.0

## Scope

Core 1.2.0 is a strictly additive subscriber-driven release for the planned `ElvUI_Multibot_BotInspect`. It adds current-equipment observation without changing the authority, route, or contract of any existing inventory/action service.

## Added domain

`BOT.EQUIPMENT`

- scope: `BOT`
- provider: `CLIENT_INSPECT`
- refresh: on demand/shared
- source: `CLIENT_INSPECT`
- authority: client observation only
- persistent: no
- session scoped: yes
- slots: WoW UI `1..19`, normalized by Core to server equipment `0..18`

Core owns `NotifyInspect`, readiness/probing, slot reads, deduplication, serialization, timeouts, session cleanup, and unavailable handling. Subscriber modules only use the Core data API.

## Compatibility

API version remains 1.

No existing public method signature is changed. No existing domain is reinterpreted. In particular:

- `BOT.INVENTORY` remains the flat compatibility/metadata inventory view.
- `BOT.INVENTORY_EXACT` remains the bridge-authoritative physical carried-stack view.
- `GetInventoryEquipmentCandidates()` remains candidate classification only.
- `GetInventoryCapabilities().equipment.readback`, `bridgeReadback`, and `authoritativeEquippedState` keep their previous bridge-authoritative meaning.
- `ITEM.EQUIP` and `ITEM.UNEQUIP` keep their route, arguments, verification, transaction, and error behavior; they only gain `BOT.EQUIPMENT` as an additional invalidated domain.

A 1.1.0 subscriber that never acquires/refreshes `BOT.EQUIPMENT` should have no behavioral change.

## Additive API v1 helpers

```lua
API:GetEquipmentView(botRef)
API:GetEquipmentSlotMap()
API:GetEquipmentObservationAvailability(botRef)
API:GetEquipmentObservationCapabilities(botRef)
```

The generic data API is still sufficient:

```lua
API:Acquire(moduleName, "BOT.EQUIPMENT", botRef)
API:Get("BOT.EQUIPMENT", botRef)
API:GetMeta("BOT.EQUIPMENT", botRef)
API:Refresh("BOT.EQUIPMENT", botRef, callback)
API:Release(moduleName, "BOT.EQUIPMENT", botRef)
```

## Inspect coordination

WoW's Inspect context is shared. Core therefore keeps one active equipment observation at a time and queues different-bot observations. Equivalent reads for one bot are already deduplicated by the Data Broker pending-read key. If Blizzard's Inspect frame is visibly inspecting a different unit, Core refuses with `INSPECT_CONTEXT_BUSY` instead of stealing the user's visible Inspect context.

Core uses `INSPECT_READY` when that event is accepted by the client, but does not depend on it exclusively. Bounded positive-evidence probes cover 3.3.5 clients/cores where equipment links become readable after `NotifyInspect` without a usable ready event. An all-empty equipment set is accepted only from explicit inspect readiness, preventing a missing response from being fabricated as nineteen empty slots.

## Mutation integration

`ITEM.EQUIP` and `ITEM.UNEQUIP` now invalidate `BOT.EQUIPMENT` in addition to their previous affected domains. If `BOT.EQUIPMENT` currently has subscriber interest, Core schedules one delayed re-observation. There is no periodic equipment poller.

## Session/unavailable behavior

In the 1.2 live-data contract, equipment observations are not themselves persistent and are never written into persistent snapshots. Core 1.3 may retain a separate historical copy in the last-known store; the live `BOT.EQUIPMENT` value remains session-scoped. Core session reset clears the live observation queue and cache. When a bot leaves the live bridge roster, its equipment snapshot is removed. A stale or currently unavailable observation is not returned by `API:Get("BOT.EQUIPMENT", bot)` as current equipment.
