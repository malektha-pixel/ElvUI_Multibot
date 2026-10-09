# ElvUI_Multibot_Core API v1

## Getting the API

```lua
local Core = _G.ElvUI_Multibot_Core
local API, err = Core:GetAPI(1)
```

A module should list `ElvUI` and `ElvUI_Multibot_Core` as required dependencies in its `.toc`.


## Startup readiness

The Core exposes three distinct readiness layers:

```lua
API:IsReady()             -- Core Lua/API initialized
API:IsBridgeReady()       -- HELLO_ACK handshake completed for the current session
API:IsBotRegistryReady()  -- first authoritative ROSTER committed for the current session
```

Modules that need bridge execution can subscribe to `MB_BRIDGE_READY`. Modules that need an authoritative initial bot list can subscribe to `MB_BOT_REGISTRY_READY`. A module loaded after those events should query the readiness methods and current cache instead of assuming it saw the original event.

## Module lifecycle

```lua
API:RegisterModule("MyModule", {
    version = "1.1.0",
    description = "Example consumer",
})
```

On unload/disable where appropriate:

```lua
API:UnregisterModule("MyModule")
```

Unregistration releases Core data interests, event subscriptions, context actions, and owned services.

## Shared data

```lua
API:Acquire(moduleName, domainId, target, options)
API:Release(moduleName, domainId, target)
API:Get(domainId, target)
API:GetMeta(domainId, target)
API:Refresh(domainId, target, callback, options)

-- Core 1.3 historical/display-only access. These never satisfy live reads/actions.
API:GetLastKnown(domainId, botRef)
API:GetLastKnownMeta(domainId, botRef)
API:HasLastKnown(domainId, botRef)
API:GetLastKnownDomains(botRef)

API:GetInventoryView(botRef)
API:GetInventoryExactView(botRef)
API:GetBuybackView(botRef)
API:GetInventorySummary(botRef)
API:GetInventoryLayout(botRef)
API:GetInventoryIndex(botRef)
API:FindInventoryItems(botRef, query)
API:GetInventoryItemCount(botRef, itemId)
API:ResolveInventoryItem(botRef, selector)
API:GetInventoryEquipmentCandidates(botRef, query)
API:GetInventoryCapabilities(botRef)
API:GetEquipmentView(botRef)
API:GetEquipmentSlotMap()
API:GetEquipmentObservationAvailability(botRef)
API:GetEquipmentObservationCapabilities(botRef)
API:GetInventoryActionAvailability(botRef, action, selector, count)
API:GetInventoryMoveAvailability(botRef, sourceBag, sourceSlot, destinationBag, destinationSlot)
API:ExecuteInventoryMove(originModule, botRef, sourceBag, sourceSlot, destinationBag, destinationSlot, callback)
API:GetInventoryUnequipAvailability(botRef, equipmentSlot, itemId)
API:ExecuteInventoryUnequip(originModule, botRef, equipmentSlot, itemId, callback)
API:GetBuybackAvailability(botRef, selector)
API:ExecuteBuyback(originModule, botRef, selector, callback)

-- Core 1.5 structured premade talent-spec mutation.
API:GetTalentSpecApplyAvailability(botRef, specIndex, { slot = "CURRENT" })
API:ApplyTalentSpec(originModule, botRef, specIndex, { slot = "CURRENT" }, callback)
```

`Acquire` establishes interest in a resource and requests it immediately unless `options.refreshNow=false`. Equivalent resources share one in-flight request.

Example:

```lua
API:Acquire("InventoryModule", "BOT.INVENTORY", "Stabby")

local inventory, meta = API:Get("BOT.INVENTORY", "Stabby")
```

Do not mutate returned tables and expect the Core to change; API getters return copies.

### Last-known historical observations (Core 1.3)

`GetLastKnown*` is a separate persisted historical layer for offline/display-only inspection. It never falls back into `API:Get`, never establishes interest, and never participates in preflight, mutation addressing/verification, lifecycle authority, target resolution, or transaction completion. The store is keyed through the existing Managed Roster GUID identity.

Retention is passive: only a successful canonical commit of a descriptor marked `retainLastKnown=true` can update history, and this causes no additional bridge/Inspect request. The retained inspection set includes `BOT.IDENTITY`, `BOT.DETAIL`, `BOT.STATS`, `BOT.TALENT_SPECS`, `BOT.SPELLBOOK`, `BOT.INVENTORY`, `BOT.INVENTORY_EXACT`, and `BOT.EQUIPMENT`. Each domain has its own wall-clock `meta.observedAt`.

`GetLastKnown(domain, bot)` returns a copy of the retained domain value plus historical metadata as its second return. `GetLastKnownMeta` returns metadata only, `HasLastKnown` is a presence check, and `GetLastKnownDomains` lists retained domains/metadata for one managed bot.

### Talents and spellbook (Core 1.5)

`BOT.TALENT_SPECS` preserves the bridge-provided `current` record when present: active slot plus three tree-point totals and a convenience `buildSummary`. If an older bridge omits `TALENT_SPEC_CURRENT`, the canonical list remains valid with `current=nil`. `BOT.SPELLBOOK` now participates in the same LastKnown display-only persistence as talent specs.

`GetTalentSpecApplyAvailability()` is synchronous UI preflight and requires a fresh current talent-spec list. `ApplyTalentSpec()` uses only the structured `TALENT_SPEC_APPLY_V1` route and independently performs a fresh `BOT.TALENT_SPECS` read before dispatch. Core validates the requested premade `specIndex`; omitted/`CURRENT` slot is resolved from that fresh CURRENT record. Offline bots are refused, no chat fallback exists, and canonical talent/spec data is refreshed after authoritative confirmation instead of being optimistically changed.

### Inventory semantics

`GetInventoryView()` returns enriched copies of the authoritative bridge snapshot. Exact bridge hyperlinks are kept as `item.serverLink`; `item.link` prefers that exact value, while `item.clientLink` is the local `GetItemInfo()` link when available. Client metadata is lazily re-resolved on each view read, so a previously uncached item may gain name/type/icon metadata without another server call.

`GetInventoryLayout()` describes the aggregated `BOT.INVENTORY` domain only and therefore remains `FLAT`/non-physical unless that domain itself gains physical rows. Availability of the separate exact snapshot is exposed as `exactSnapshotAvailable`; use `GetInventoryExactView()` for authoritative bag/slot identity.

`ResolveInventoryItem()` accepts an item ID, item hyperlink/item record, or an unambiguous exact item name. It returns aggregate identity/count across the flat metadata snapshot. `GetInventoryExactView()` exposes the separate `INVENTORY_EXACT_V1` physical snapshot with authoritative `bag`, `slot`, `itemId`, `count`, and `soulbound` fields. Modules must not infer bag/slot identity from flat-list order.

`GetInventoryEquipmentCandidates()` filters items whose local metadata contains an equipment location; this is **candidate classification**, not equipped-state readback. Core 1.2 adds the separate `BOT.EQUIPMENT` client-observation domain. `GetInventoryCapabilities().equipment.readback` remains bridge-authoritative only; use `equipment.clientObserved` / `clientObservation` to discover the new native Inspect path.

`GetEquipmentView()` reads that same canonical `BOT.EQUIPMENT` cache. `GetEquipmentSlotMap()` exposes Core's 1-based WoW to 0-based server slot normalization. `GetEquipmentObservationAvailability()` is a non-mutating per-bot preflight; `GetEquipmentObservationCapabilities()` describes the source/authority/session contract. Generic `Acquire/Get/GetMeta/Refresh/Release` remains the primary shared-read interface.

`GetInventoryActionAvailability()` is non-mutating. For semantic USE/EQUIP/SELL/DESTROY/GIVE, Alpha 1.11+ prefers a structured native bridge route when `INVENTORY_EXACT_V1` plus the action-specific capability are fully negotiated. Core refreshes exact inventory immediately before dispatch and freezes the physical source tuple. If the capability is unavailable, the previously validated Playerbots hyperlink route may be chosen **before dispatch** as a compatibility route. A native mutation that was sent is never retried through chat. DESTROY still requires explicit confirmation, SELL still requires merchant context, and GIVE still uses the normal WoW trade lifecycle with final accept/cancel under user control.

## Persistent bot snapshots

Snapshots are an explicit historical/offline-inspection layer. They never replace canonical live domains and never authorize an action.

```lua
API:GetSnapshotRefreshAvailability(botRef, { profile = "STANDARD" })
API:RequestBotSnapshot(botRef, callback, { profile = "STANDARD" })
API:GetBotSnapshot(botRef)
API:GetBotSnapshots()
API:GetBotSnapshotStatus(botRef)
API:GetSnapshotProviders()
API:GetSnapshotProfile("STANDARD")

API:RegisterSnapshotProvider(moduleName, providerId, descriptor)
API:UnregisterSnapshotProvider(moduleName, providerId)
```

`STANDARD` refreshes a bounded set of durable bot domains. `FULL` opts into heavier reads. Snapshot capture always routes through normal Core reads, so equivalent live/subscriber requests still deduplicate. `GetSnapshotRefreshAvailability()` is advisory because cached presence may lag manual summon/unsummon. `RequestBotSnapshot()` performs a fresh deduplicated `BRIDGE.ROSTER` preflight before provider reads and another fresh roster check before atomic commit. A start-time absence returns asynchronous `BOT_OFFLINE`; disappearance during capture returns `BOT_WENT_OFFLINE`. A refused or failed capture never erases the previous persisted snapshot.

Public snapshot events are `MB_SNAPSHOT_STARTED`, `MB_SNAPSHOT_PROGRESS`, `MB_SNAPSHOT_UPDATED`, and `MB_SNAPSHOT_RESULT`.

## Events

```lua
local token = API:Subscribe("MyModule", "MB_DATA_CHANGED", function(event, domainId, targetKey, value, meta)
    -- update only your frontend state
end)

API:Unsubscribe(token)
```

Framed/list data is assembled privately. Consumers only see committed snapshots after the corresponding `*_END` boundary.

## Bots, selections and target resolution

```lua
API:GetBots({ online = true })
API:GetBot("Stabby")
API:GetBotRole("Stabby")
API:GetBotSpec("Stabby")
API:GetBotRange("Stabby")
API:GetBotSubgroup("Stabby")

-- Core-owned transient/working selection. Suitable for Ctrl-click unit frames.
API:SetSelection("PRIMARY", { "Stabby", "Kitten" })
API:AddSelection("PRIMARY", "Frosty")
API:RemoveSelection("PRIMARY", "Kitten")
API:ToggleSelection("PRIMARY", "Stabby")
API:ClearSelection("PRIMARY")
API:GetSelection("PRIMARY")

-- ElvUI-profile-persistent named selections.
API:SaveSelection("Left Flank")                         -- save current PRIMARY list
API:SaveSelection("Ranged", "rangeddps", { dynamic = true })
API:GetSavedSelection("Left Flank")
API:GetSavedSelections()
API:AddToSavedSelection("Left Flank", "selected")
API:RemoveFromSavedSelection("Left Flank", "Stabby")
API:ToggleSavedSelectionMember("Left Flank", "Kitten")
API:LoadSavedSelection("Left Flank", "PRIMARY")
API:DeleteSavedSelection("Left Flank")

API:ResolveTargetSpec("selected")
API:ResolveTargetSpec("saved:Left Flank")
API:ResolveSelection("tank")
API:ResolveSelection("healer")
API:ResolveSelection("meleedps")
API:ResolveSelection("class:ROGUE")
API:ResolveSelection("group:1")
API:GetTargetCatalog()
```

A static saved selection stores normalized bot keys and survives reloads. Static groups can be edited directly with `AddToSavedSelection`, `RemoveFromSavedSelection`, and `ToggleSavedSelectionMember`; the add/remove methods accept normal target specs such as `selected`. A dynamic saved selection stores a selector, reevaluates it against current Core state, and intentionally rejects manual membership edits. Saved members that are currently unavailable remain in the saved key list but are omitted from the actionable `bots` result and appear in `missingKeys`.

Frontends should treat `PRIMARY` as shared state rather than maintaining an independent multi-select. For example, a unit-frame addon can Ctrl-click by calling `ToggleSelection("PRIMARY", bot)` and listen for `MB_SELECTION_CHANGED` to update frame highlighting.

Action target resolution is always frozen at dispatch. Editing `PRIMARY` or a saved selection after a transaction starts cannot silently alter that transaction's targets.

## Actions

```lua
API:CanExecute(actionId, targetSpec, args)
API:GetActionAvailability(actionId, targetSpec, args)
API:Execute(originModule, actionId, targetSpec, args, callback)
API:ExecuteSet(originModule, actionId, selector, args, callback)
API:GetTransaction(transactionId)
```

Example:

```lua
API:Execute("StrategyModule", "STRATEGY.MUTATE", "Stabby", {
    stateScope = "N",
    changes = "+follow,-stay",
})
```

The authoritative cache is not optimistically changed. Confirmed mutations invalidate affected domains; active subscribers trigger coordinated refreshes.

`GetActionAvailability()` returns a read-only preflight description:

```lua
{
    actionId = "FORMATION.SET",
    enabled = true,
    reason = nil,
    scope = "GROUP",
    targets = { ... },
    normalizedArgs = { scope = "GROUP", formation = "near" },
    descriptor = { ... },
}
```

Invalid arguments are rejected during preflight instead of creating an immediately-failed transaction. `Execute()` uses the normalized preflight arguments.

Transaction terminal events include `MB_ACTION_CONFIRMED`, `MB_ACTION_FAILED`, `MB_ACTION_AMBIGUOUS`, and `MB_ACTION_CANCELLED`. Event payloads and `GetTransaction()` return public snapshots without the Core's private callback function.


## RTI and RTSC tactical services

```lua
API:GetRTIIcons()
API:GetRTIAssignment(botRef, "priority")
API:GetRTIAssignment(botRef, "cc")
API:GetRTIAssignmentSummary()
API:PreviewRTIAssignment(targetSpec, "priority", "cross")
API:AssignRTI(moduleName, targetSpec, "priority", "cross", callback)
API:AssignRTI(moduleName, targetSpec, "cc", "moon", callback)
API:RunAssignedRTI(moduleName, targetSpec, "attack", callback)
API:RunAssignedRTI(moduleName, targetSpec, "pull", callback)

local contract = API:GetRTSCPlacementContract()
-- contract.secureType == "macro"
-- contract.macroText == "/cast aedm"
-- contract.slots == 9

API:EnableRTSC(moduleName, callback)
API:PrepareRTSCPlacement(moduleName, targetSpec, optionalSlot, callback)
API:SelectRTSCTargets(moduleName, targetSpec, callback)
API:GoRTSCLocation(moduleName, targetSpec, slot, callback)
API:SaveRTSCLocation(moduleName, slot, callback)
API:UnsaveRTSCLocation(moduleName, slot, callback)
API:CancelRTSC(moduleName, callback)
API:RTSCStrategies(moduleName, targetSpec, enabled, callback)
```

RTI is bridge-native. The convenience assignment helpers fan a resolved set out to per-bot bridge transactions and update Core-known RTI state only after each bridge ACK. The reference protocol has no RTI readback, so state changed outside this Core is not observable.

RTSC is intentionally different: it uses Playerbots chat semantics from the developer reference client. Bare `rtsc` enables RTSC/AEDM and `rtsc cancel` disables it. `EnableRTSC()` exposes the enable operation explicitly; `PrepareRTSCPlacement()` and `SelectRTSCTargets()` also ensure RTSC is enabled before selecting their frozen target set. The Core owns all RTSC chat commands and emits `SENT_UNVERIFIED`; a frontend owns the secure `/cast aedm` world-click button. Consumer modules must not send `rtsc ...` chat commands themselves.

## Module services

Modules may expose non-UI services through the Core:

```lua
API:RegisterService("InventoryModule", "Inventory.Open", InventoryService)
local service, owner = API:GetService("Inventory.Open")
```

Service names are globally unique unless replacement is explicitly requested by the owner contract.

## Context action contributions

A module can contribute an action without knowing which frontend will render it:

```lua
local contributionId = API:RegisterContextAction("InventoryModule", {
    id = "inspect",
    contexts = { "BOT", "UNITFRAME" },
    category = "Inventory",
    label = "Inspect Inventory",
    order = 20,

    predicate = function(context)
        return context and context.bot ~= nil
    end,

    enabled = function(context)
        local bot = API:GetBot(context.bot)
        return bot ~= nil, bot and nil or "Bot unavailable"
    end,

    handler = function(context)
        -- May call InventoryModule's own UI/service.
        -- It still obtains bot data and mutations through Core API.
    end,
})
```

A unit-frame module, radial menu, command palette, etc. can then query:

```lua
local flat = API:GetContextActions("BOT", { bot = "Stabby" })
local tree = API:GetContextTree("BOT", { bot = "Stabby" })
```

And invoke a chosen leaf through the Core:

```lua
API:InvokeContextAction(contributionId, { bot = "Stabby" })
```

The Core stores the registry/tree model. Rendering remains the frontend module's responsibility.

A contribution may also bind directly to a registered Core action instead of providing a custom handler:

```lua
API:RegisterContextAction("FormationModule", {
    id = "near",
    contexts = { "GROUP" },
    label = "Near",
    requirements = { bridgeReady = true },
    coreAction = {
        id = "FORMATION.SET",
        target = "all",
        args = { scope = "GROUP", formation = "near" },
    },
})
```

`coreAction.target` and `coreAction.args` may also be functions of the current context. Common `requirements` supported by the Core are `bridgeReady`, `botRegistryReady`, `bot`, and `capabilities`. A context frontend receives `enabled` and `disabledReason` after these checks and action preflight are evaluated. A contribution must use either `handler` or `coreAction`, not both.

## Capabilities and manifest

```lua
API:GetCapabilities()
API:HasCapability("STATE_FRAMING_V1")
API:GetDomainDescriptor("BOT.INVENTORY")
API:GetActionDescriptor("STRATEGY.MUTATE")
API:GetManifest()
```

`GetManifest()` is intended as a machine-readable development handoff for future modules.

## Forbidden consumer behavior

Consumer modules should not call these directly:

```lua
SendAddonMessage("MBOT", ...)
SendChatMessage(playerbotsCommand, ...)
```

They should not maintain a competing authoritative copy of bridge state. UI-local derived/display state is fine; bridge truth belongs to the Core.


### Inventory mutation helpers (Alpha 1.6)

```lua
API:GetInventoryInteractionContract(action)
API:ExecuteInventoryAction(originModule, botRef, action, selector, options, callback)
```

`selector` may be an item ID, canonical client hyperlink (bridge/server fallback), or inventory record. `options.confirmed=true` is mandatory for `DESTROY`. Native item actions use a freshly resolved physical source from `BOT.INVENTORY_EXACT`; callers may optionally provide `sourceBag` and `sourceSlot` when they need one specific physical stack. Chat compatibility actions retain exact-link variant safety.

## Equipment readback status (Core 1.2)

There is still no **bridge-authoritative** complete equipped-slot snapshot. Core 1.2 instead exposes `BOT.EQUIPMENT` as a complete **client-observed** 19-slot snapshot while the bot is currently inspectable. The distinction is deliberate: the **live** value remains `source=CLIENT_INSPECT`, `authoritative=false`, `persistent=false`, and `sessionScoped=true`. Core 1.3 may retain a separate historical copy only behind `GetLastKnown*`; it is never used as current equipment.

`ITEM.EQUIP` and `ITEM.UNEQUIP` keep their existing mutation contracts and additionally invalidate `BOT.EQUIPMENT`. If a subscriber currently holds equipment interest, Core may re-observe after the mutation; no module should send its own `NotifyInspect`/Inspect traffic for this feature.

Native `ITEM.USE`, `ITEM.SELL`, and `ITEM.DESTROY` are confirmed from their dedicated correlated bridge responses and followed by inventory refresh. Their chat compatibility routes retain the older inventory-count postcondition verification when applicable.


## Alpha 1.8 storage and quest semantic APIs

```lua
API:GetStorageView(botRef, kind)       -- kind: BANK / GBANK
API:GetBankView(botRef)
API:GetGuildBankView(botRef)

API:GetQuestView(botRef)
API:GetQuestMetadata(botRef)
API:RefreshQuestMetadata(botRef, callback, options)
API:FindQuests(botRef, query)
API:ResolveQuest(botRef, selector)
API:GetQuestCapabilities(botRef)
API:GetQuestActionAvailability(botRef, action, selector, options)
API:GetQuestInteractionContract(action)
API:ExecuteQuestAction(originModule, botRef, action, selector, options, callback)
```

`QUEST.ABANDON` is currently the only semantic quest mutation. It requires `{ confirmed = true }`, a fresh structured `BOT.QUESTS` snapshot, and one exact Playerbots-generated quest hyperlink. Core obtains that hyperlink by privately whispering `quests all`; it never synthesizes `Hquest` fields. The destructive `drop` is sent once and is never auto-retried. `Quest removed` chat feedback is supplemental; terminal `CONFIRMED` requires a structured `BOT.QUESTS` refresh proving that quest ID is absent.

Bank/guild-bank/vendor mutations use the same inventory API as normal item actions. `GetInventoryInteractionContract(action)` reports the route/addressing contract. Alpha 1.11 semantic item actions use `BAG_SLOT_ITEM_COUNT` when their native bridge capability is available; older generic bank/guild-bank/vendor `ITEM.ACTION` paths still use their existing item-ID/count contracts unless separately migrated.

### Alpha 1.9 quest metadata enrichment

`BOT.QUESTS` remains authoritative for membership/status. `BOT.QUEST_METADATA` is an on-demand shared chat-backed enrichment domain populated from Playerbots `quests all`. `GetQuestView()` merges exact links/levels/names by quest ID but does not create quest state from chat. Multiple modules requesting metadata concurrently share one Core request/whisper.

## Quest exact-link helpers (Alpha 1.10)

```lua
API:ParseQuestLink(link)
API:GetQuestActionAvailability(targetSpec, "ACCEPT", exactQuestLink, options)
API:ExecuteQuestAction(moduleName, targetSpec, "ACCEPT", exactQuestLink, options, callback)
```

`targetSpec` may be a bot, `selected`, saved/dynamic selection, role/class/subgroup selector, explicit list, or `all`. Acceptance is dispatched as individual whispers to the frozen resolved targets.

### Alpha 1.12 exact inventory operations

`GetInventoryMoveAvailability` / `ExecuteInventoryMove` address explicit physical source and destination positions. Core refreshes `BOT.INVENTORY_EXACT` before send and aborts before mutation if source identity/count or destination occupancy changed.

`GetInventoryUnequipAvailability` / `ExecuteInventoryUnequip` take a **0-based bridge/server equipment slot (0..18)** plus expected item ID. They do not claim a complete equipped-state readback domain.

Full-stack `BANK_DEPOSIT` and `GBANK_DEPOSIT` automatically prefer `ITEM_DEPOSIT_EXACT_V1` when negotiated. A nonzero partial `count` deliberately selects the existing generic bridge route instead.

## Alpha 1.13 structured inventory/economy utilities

`API:GetInventoryActionAvailability()` / `API:ExecuteInventoryAction()` accept selector-free `SELL_GREY` and `SELL_VENDOR` through `INVENTORY_BULK_SELL_V1`; both require a current target and the server decides whether that target is a valid vendor. `OPEN_ITEMS` is intentionally unsupported as of Alpha 1.13.3: preflight returns `INTENTIONALLY_UNSUPPORTED`, no bridge mutation is sent, and `GetInventoryInteractionContract("OPEN_ITEMS")` reports `route=NONE`.

`BOT.BUYBACK` is an on-demand canonical domain sourced from `VENDOR_BUYBACK_V1`. `API:GetBuybackView()` exposes exact server buyback entries with `slot` (74..85), `itemId`, `count`, `price`, and `timestamp`. `GetBuybackAvailability()` / `ExecuteBuyback()` bind the mutation to the exact cached tuple and require both `INVENTORY_EXACT_V1` and `VENDOR_BUYBACK_V1`. Modules should refresh `BOT.BUYBACK` before presenting or executing a buyback selection.


## Alpha 1.14 Altbot lifecycle API

```lua
API:GetAltRosterView()
API:GetLifecycleTargetView(botRef)
API:ResolveBotTarget(botRef, callback)
API:GetBotLifecycleAvailability(botRef, action)
API:GetBotLifecycleContract()
API:ExecuteBotLifecycle(originModule, botRef, action, callback)
```

`action` is `CONNECT` or `DISCONNECT`. Alpha 1.14 lifecycle execution is intentionally restricted to bots present in the authoritative `ALT.ROSTER`; callers never supply or invent GUIDs. The Core resolves the Altbot, freezes the roster GUID, sends one structured lifecycle mutation, and owns all `PENDING` polling and final state convergence. A sent mutation is never retried through another route.

`GetAltRosterView()` returns a copy of the durable Alt-roster snapshot and adds `effectiveState` for transient `CONNECTING`/`DISCONNECTING` presentation while a Core transaction is in flight. The durable `state` field remains the latest authoritative roster value.

`ResolveBotTarget()` is read-only and may be useful for future social-roster modules, but in Alpha 1.14 it does not grant lifecycle authority to anything outside `ALT.ROSTER`.

## Alpha 1.16 managed lifecycle additions

- `GetManagedRosterView()` returns persistent known identities plus live/snapshot overlays. Persistence is not authorization.
- `GetManagedBot(botRef)` returns one managed identity by name or GUID.
- `GetManagedBotLifecycleAvailability(botRef, action)` reports whether Core can attempt the authoritative preflight (`ALT.ROSTER` for current account alts, `BOT_TARGET_RESOLVE` for other managed candidates).
- `RequestBotLifecycle(originModule, botRef, action, callback)` is the preferred lifecycle API for modules. It performs the required fresh preflight before dispatch and returns one final request result containing the underlying transaction when a mutation was sent.
- `ExecuteBotLifecycle(...)` remains the lower-level direct transaction API and requires an already-current execution authority; a persisted Managed Roster record is never sufficient.

## Alpha 1.17 Managed Groups

Persistent organization:

- `GetManagedGroups()`
- `GetManagedGroup(groupRef)`
- `CreateManagedGroup(name)`
- `RenameManagedGroup(groupRef, newName)`
- `DeleteManagedGroup(groupRef)`
- `AddManagedGroupMember(groupRef, botRef)`
- `RemoveManagedGroupMember(groupRef, botRef)`

Bulk lifecycle:

- `GetManagedGroupLifecycleAvailability(groupRef, action, options)`
- `GetManagedGroupLifecycleContract()`
- `RequestManagedGroupLifecycle(originModule, groupRef, action, callback, options)`
- `GetManagedGroupLifecycleRequest(requestId)`
- `GetManagedGroupLifecycleRequests()`

Events:

- `MB_MANAGED_GROUP_UPDATED`
- `MB_MANAGED_GROUP_DELETED`
- `MB_MANAGED_GROUP_LIFECYCLE_STARTED`
- `MB_MANAGED_GROUP_LIFECYCLE_PROGRESS`
- `MB_MANAGED_GROUP_LIFECYCLE_RESULT`

Managed Group membership is not lifecycle authorization. Each bulk member still executes through the standard managed lifecycle request path.


## Managed identity cleanup (1.4.0)

`API:GetForgetManagedBotAvailability(botRef)` returns an additive preflight object. `enabled=true` means the referenced persisted managed GUID can currently be forgotten. Important refusal reasons include `MANAGED_BOT_NOT_FOUND`, `AMBIGUOUS_IDENTITY`, `BOT_ONLINE`, `SNAPSHOT_BUSY`, and `GROUP_MEMBER_BUSY`.

`API:ForgetManagedBot(originModule, botRef, options, callback)` removes Core-owned persisted knowledge/history for exactly one managed GUID. The result includes `status`, `code`, `guid`, `name`, `cleanup`, `rediscoveryAllowed`, `serverCharacterAffected=false`, and `accountLinkAffected=false`. It never sends a server command and never blacklists rediscovery.

Successful forget emits `MB_MANAGED_BOT_FORGOTTEN(guidKey, name, result)`. Groups from which the GUID was removed emit normal `MB_MANAGED_GROUP_UPDATED(..., "MEMBER_FORGOTTEN", guid)`.


## 1.6 exact talents / bot spell API

- `GetTalentView(botRef)` / generic `Get("BOT.TALENTS", botRef)` return exact native-Inspect talent ranks.
- `GetTalentObservationAvailability(botRef)` and `GetTalentObservationCapabilities(botRef)` expose Inspect availability without starting a scan.
- `GetBotSpellEnabled(botRef, spellId)` returns confirmed state only when Core has a trustworthy observation; with the current Playerbots contract it normally returns `nil`/`UNKNOWN` plus any `requestedEnabled` metadata rather than treating a sent `ss` command as confirmation.
- `GetBotSpellEnabledAvailability(botRef, spellId)` / `SetBotSpellEnabled(...)` expose the narrow autonomous-use compatibility semantic.
- `GetBotSpellCastAvailability(botRef, spellId, options)` / `CastBotSpell(...)` expose explicit manual casting.
- `GetBotSpellActionContract(botRef, spellId)` returns the stable managed-GUID macro contract used by BotInspect for normal Blizzard/ElvUI action bars.
