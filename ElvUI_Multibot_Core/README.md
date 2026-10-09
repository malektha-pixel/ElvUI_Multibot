# ElvUI_Multibot_Core — Version 1.6.4.2

Version 1.6.4.2 adds narrowly scoped Playerbots questgiver actions: Accept Nearby (`accept *`) and confirmed Talk / Turn In (`talk`). Both use Core action transactions and exact target-GUID guards, with outcomes explicitly unverified until quest state changes are observed. It retains the 1.6.4.1 server-stall mitigation: `BOT.TALENT_SPECS` is explicit/on-demand only and is blocked from scheduler polling even if a subscriber supplies an interval. STANDARD/FULL snapshots no longer request the premade-spec list. The public talent-spec API remains available for deliberate explicit use, while `BOT.TALENTS` client Inspect is unchanged.

## 1.6.0 Exact talents and bot-spell semantics

Version 1.6.0 adds exact client-inspected per-talent ranks through `BOT.TALENTS`, sharing the existing serialized native Inspect coordinator with `BOT.EQUIPMENT`. It also adds narrow Core-owned Playerbots compatibility semantics for autonomous spell exclusion and explicit manual bot-spell casts, plus a stable `/mbcastguid` macro contract. Because current Playerbots documents spell-exclusion mutation but no authoritative exclusion-list query, `BOT.SPELL_EXCLUSIONS` is deliberately session-scoped, partial, and non-authoritative rather than pretending full readback exists. A successfully sent `ss` mutation is recorded only as a requested/unverified state until a trustworthy readback contract exists.

## 1.5.0 Talents & Spellbook backend

Version 1.5.0 adds the Core semantics needed by `ElvUI_Multibot_BotInspect` for its Talents & Spellbook inspection tab without changing the existing read architecture. `BOT.SPELLBOOK` now participates in LastKnown retention, and `BOT.TALENT_SPECS` preserves the bridge-provided active talent slot and three tree-point totals when available.

Premade talent changes are exposed only through the structured `TALENT_SPEC_APPLY_V1` bridge capability. Core validates a requested premade index against a fresh `BOT.TALENT_SPECS` response immediately before dispatch and resolves omitted/`CURRENT` slot from that same fresh response. A confirmed bridge result invalidates and refreshes the normal talent/detail/state/spellbook/glyph data paths rather than writing an assumed build into cache. There is no Playerbots chat fallback and no arbitrary custom talent editor in this release.

API version remains 1. Existing 1.4 subscribers remain compatible.

## 1.4.0 managed identity cleanup

Version 1.4.0 adds a Core-owned way for a subscriber such as `ElvUI_Multibot_BotInspect` to deliberately forget a stale persisted managed identity. The operation is keyed by the existing stable Managed Roster GUID and removes only Core-owned persistent history for that identity: Managed Roster record/index, automatic last-known observations, persistent snapshot, and Managed Group membership. It does not delete a server character, unlink an account, disconnect a bot, or prevent later rediscovery.

For safety, Core refuses Forget while the target is currently online/transitioning, while its snapshot capture is active, or while a Managed Group lifecycle request is operating on that GUID. `MB_MANAGED_BOT_FORGOTTEN` lets frontends remove the roster row immediately. API version remains 1 and existing 1.3 subscriber behavior is unchanged unless the new API is explicitly called.

## 1.3.0 automatic last-known observations

Version 1.3.0 adds a strictly separate historical/display-only store for the planned `ElvUI_Multibot_BotInspect`. When Core already performs a successful normal read of an eligible inspection domain, the newest committed value is automatically retained under the bot's existing Managed Roster GUID. This does not perform extra reads, does not replace STANDARD/FULL snapshots, and does not change canonical live `API:Get()` semantics.

Use `API:GetLastKnown(domain, bot)`, `GetLastKnownMeta`, `HasLastKnown`, or `GetLastKnownDomains` only when a frontend explicitly wants historical/offline presentation. The initial retained domains are identity, detail, stats, talent specs, flat inventory, exact inventory, and equipment. API version remains 1; a Core 1.2.0 subscriber that never calls these new APIs should behave exactly as before.

## 1.2.0 client-observed equipment readback

Version 1.2.0 adds one strictly additive backend capability for `ElvUI_Multibot_BotInspect`: `BOT.EQUIPMENT`. Core can now observe an inspectable bot's current 19 equipment slots through the WoW client Inspect/inventory APIs without changing the authority or meaning of `BOT.INVENTORY`, `BOT.INVENTORY_EXACT`, or any existing item mutation. The equipment snapshot is session-scoped, non-persistent, and explicitly **client-observed rather than bridge-authoritative**.

Core serializes Inspect ownership, deduplicates equivalent subscriber reads through the normal Data Broker, maps WoW slots `1..19` to server equipment slots `0..18`, and invalidates the observation after `ITEM.EQUIP` / `ITEM.UNEQUIP`. API version remains 1; a module written for Core 1.1.0 that never requests `BOT.EQUIPMENT` has no required source changes.

## 1.1.0 RTSC compatibility fix

Version 1.1.0 corrects the RTSC/AEDM initialization flaw found while developing `ElvUI_Multibot_ContextMenu`. Core no longer uses `rtsc cancel` as the first step of RTSC preparation/selection because that command disables RTSC and removes AEDM. `RTSC.PREPARE` and `RTSC.SELECT` now enable RTSC first, and the new backward-compatible `API:EnableRTSC()` helper exposes the missing semantic enable operation to subscribers. API version remains 1.

No non-RTSC data domain, bridge route, cache, lifecycle, selection, or existing public method signature changes in 1.1.0. Modules that do not use RTSC require no changes.

## 1.0.1 maintenance update

Version 1.0.1 was a user-interface quality pass over the ElvUI Core options. It improved labels, inline explanations and hover descriptions without changing the Core API, defaults, data model or backend behavior.

## 1.0 release status

Version 1.0.0 promotes the live-validated Alpha 1.17.1 runtime without functional Lua changes. The 1.0 release freezes the initial backend scope around the bridge/data/action infrastructure, canonical shared reads, selections/tactical services, inventory/item workflows, quests, lifecycle, snapshots, Managed Roster, Managed Groups and safe bulk lifecycle.

Talent **read** support remains available through `BOT.TALENT_SPECS`. Talent **mutation** is intentionally unsupported/deferred in 1.0: Core does not expose or dispatch `TALENT_APPLY_V1` or `TALENT_SPEC_APPLY_V1`, even if a server advertises those raw bridge capabilities. Subscriber modules must not treat raw bridge capability advertisement as a Core action contract.

The following remain intentionally outside the 1.0 release scope unless explicitly revisited: SelfBot, account-link creation/removal, `INVENTORY_OPEN_V1`, loot-item/roll mutation, targeted crafting/enchanting primitives, outfit expansion, and automated Rogue Sap.

The original 1.0.0 runtime was byte-for-byte the Alpha 1.17.1 baseline; the 1.0 promotion changed release metadata/documentation only. Version 1.0.1 changed only the ElvUI options presentation text in `Options/Options.lua` plus release metadata/documentation. Version 1.1.0 is the first post-1.0 runtime correction and is intentionally limited to the RTSC/AEDM semantic action path.

## Historical Alpha 1.17.1 hotfix

- Managed Roster/group status no longer treats persisted `lastKnownLifecycle` as current state after reload/session change.
- `effectiveState` is current-session only and reports its authority in `effectiveStateSource`; historical state remains available separately as `lastKnownLifecycle`.
- This is a read-model/presentation fix only. Group lifecycle execution and authorization paths are unchanged from the live-validated Alpha 1.17 implementation.

## Alpha 1.17 notes

- Adds persistent GUID-backed Managed Groups in `ElvUI_Multibot_GroupsDB`. Groups are local organization only; membership never grants control authority.
- Adds bounded bulk lifecycle orchestration (default concurrency 2, hard maximum 4). Every member delegates to the existing `RequestBotLifecycle()` authorization path, preserving fresh Alt-roster checks for own-account bots and fresh target resolution for linked bots.
- Bulk requests freeze membership at start, reserve GUIDs against overlapping group requests, classify already-final members as skips, and expose per-member plus aggregate results/events.
- Guild discovery is intentionally deferred. The group backend is designed to feed future faction-scoped guild/raid management without treating guild membership as lifecycle authority.
- No account link/unlink controls are exposed.


## Alpha 1.15.1 hotfix

- Snapshot online preflight now treats current `BRIDGE.ROSTER` presence (`bot.online=true`) as authoritative evidence that the bot is queryable, even if a previously committed `ALT.ROSTER` lifecycle value still says `OFFLINE` after a manual summon.
- Explicit `DISCONNECTING` still blocks snapshot start/commit. If no live roster presence exists, durable lifecycle `ONLINE`/`OFFLINE` remains the fallback authority.
- This fixes false `BOT_OFFLINE` refusals without changing canonical live state, lifecycle mutation logic, providers, or persistence semantics.

## Alpha 1.15 notes

- Adds an explicit persistent Bot Snapshot service for offline inspection without changing canonical live-state semantics.
- Snapshots live in separate `ElvUI_Multibot_SnapshotsDB` SavedVariables storage keyed by authoritative GUID. They are never used to satisfy `API:Get`, action preflight, lifecycle authorization, or any live gameplay decision.
- `RequestBotSnapshot()` refuses cleanly when the bridge is unavailable, the bot is offline, no authoritative GUID exists, or another snapshot for that GUID is active. Refusals are delivered to the callback/listener as readable structured results and do not alter the previous stored snapshot.
- Capture is staged and atomic: selected providers refresh through the existing shared Data Broker, then the persistent snapshot is replaced only after required providers succeed and the bot is still online in the same bridge session.
- `STANDARD` captures identity, detail, strategies/state, stats, talent specs, compact flat inventory, and quests. `FULL` additionally attempts professions, PvP stats, glyphs, spellbook, skills, reputations, emblems, and compact exact inventory; optional-provider failures are recorded and may produce `complete=false` rather than destroying a usable capture.
- Inventory persistence is compacted to avoid duplicating live derived indexes in SavedVariables, which matters for the future raid-scale managed-roster use case.
- Snapshot providers are registrable by future modules, but snapshot data remains a separate historical layer.
- Snapshot identity reserves authoritative guild/faction/team fields for future providers; Alpha 1.15 does not infer them. Future guild management must support faction-separated guild scopes rather than assuming one global guild.
- HIGH-PRIORITY blocked roadmap item: as soon as the server owner links a test account, runtime-test how linked-account characters enumerate and authorize lifecycle control. No account link/unlink controls are exposed by Core.
- API version remains 1.

## Alpha 1.14 notes

- Adds the authoritative Altbot identity/lifecycle family using `ALT_ROSTER_V1`, `BOT_TARGET_RESOLVE_V1`, and `BOT_LIFECYCLE_V1`.
- `ALT.ROSTER` is a canonical global domain containing authorized account Altbots even when they are offline. It preserves bridge GUID, canonical name, class, level, and authoritative `ONLINE`/`OFFLINE` state.
- `BOT.LIFECYCLE_TARGET` is an on-demand correlated resolver for canonical name -> GUID/lifecycle state.
- Adds semantic `BOT.CONNECT` and `BOT.DISCONNECT`. Alpha 1.14 permits lifecycle mutation only for characters currently present in authoritative `ALT.ROSTER`; target resolution does not broaden the authorization surface.
- Lifecycle mutations are GUID-addressed, token-correlated, non-idempotent transactions. `PENDING` starts 1-second `BOT_LIFECYCLE_STATE` polling within a 12-second total window. Sent mutations are never retried and never fall back to chat.
- Final lifecycle convergence refreshes `BRIDGE.ROSTER`, `ALT.ROSTER`, and the target resolver so durable state replaces transient `CONNECTING`/`DISCONNECTING` presentation.
- `ALT_ROSTER` framing is intentionally excluded from the three-pass bootstrap burst because the protocol is un-tokenized; one deduplicated request is started after capability negotiation completes.
- Account link/unlink controls are not exposed by Core. Server-admin-linked characters may be consumed by future managed-roster work once runtime enumeration/authorization is validated.
- `OPEN_ITEMS` remains intentionally unsupported from Alpha 1.13.3.
- API version remains 1.

## Alpha 1.13.3 notes

- `OPEN_ITEMS` is intentionally unsupported and has no dispatch path in the Core.
- The bridge may continue to advertise `INVENTORY_OPEN_V1`; `/mbcore caps` therefore remains a raw statement of server capabilities, not a promise that every advertised capability is exposed by Core.
- Public inventory preflight returns `INTENTIONALLY_UNSUPPORTED` for `OPEN_ITEMS`. The inventory capability contract exposes a negative marker so frontends can hide the feature deterministically.
- The temporary Alpha 1.13.1 extended timeout and Alpha 1.13.2 inventory-transform verifier have been removed.
- Rationale: live tests showed successful mutation without structured success acknowledgement, while autonomous Playerbots inventory/gear changes make a client-side postcondition unsafe to treat as authoritative proof. The feature is also low-value for the intended UI/module roadmap.
- Bulk sell and exact vendor buyback from Alpha 1.13 remain supported.
- API version remains 1.

## Alpha 1.13.1 notes

- Live positive `OPEN_ITEMS` testing showed a container could be consumed while the Core's generic 10-second `ITEM.ACTION` timer expired before the structured result was correlated.
- `OPEN_ITEMS` now uses a dedicated 45-second structured-ACK retention window, matching the reference client's long-lived pending-token behavior while keeping the Core bounded.
- No retry or chat fallback is allowed after send; a true hard timeout remains `AMBIGUOUS`.
- All Alpha 1.13 capability/API contracts are unchanged.

## Alpha 1.13 notes

- Adds structured container opening (`INVENTORY_OPEN_V1`) and bulk vendor selling (`INVENTORY_BULK_SELL_V1`) through the existing semantic inventory service.
- Adds canonical on-demand `BOT.BUYBACK` plus exact `ITEM.BUYBACK` through `VENDOR_BUYBACK_V1`; buyback mutations are guarded by server slot/item/count/price and require both `INVENTORY_EXACT_V1` and `VENDOR_BUYBACK_V1`.
- `OPEN_ITEMS`, `SELL_GREY`, and `SELL_VENDOR` are selector-free structured actions and never fall back to Playerbots chat after dispatch.
- Successful sells invalidate the buyback domain because vendor buyback history changes with each sale.
- API version remains 1.

## Alpha 1.12 notes

- Completes Exact Inventory Phase 2 with native `ITEM.MOVE`, `ITEM.UNEQUIP`, and full-stack exact BANK/GBANK deposit.
- `ITEM.MOVE` refreshes and guards both source and destination physical state before dispatch.
- `ITEM.UNEQUIP` uses explicit 0-based server equipment slot `0..18` plus item ID; no synthetic equipment snapshot is introduced.
- Full-stack BANK/GBANK deposit prefers `ITEM_DEPOSIT_EXACT_V1`; partial-count requests retain the existing generic bridge route.
- Precise per-bot quest abandonment intentionally remains on the validated exact-link Playerbots route because the current native reference request has no bot target.

## Alpha 1.11 notes

- Current bridge capability negotiation is handled as an authoritative `CAPS_BEGIN` / repeated `CAPS` / `CAPS_END` batch.
- `BOT.INVENTORY_EXACT` exposes authoritative physical bag/slot stack identity from `INVENTORY_EXACT_V1` while the existing flat inventory view remains available for names, hyperlinks and metadata.
- Semantic `ITEM.EQUIP`, `ITEM.USE`, `ITEM.SELL`, `ITEM.DESTROY` and `ITEM.GIVE` prefer dedicated native bridge mutations when their capabilities are negotiated.
- Native mutations freeze a freshly read physical source tuple and validate the correlated structured result. Sent native mutations are never retried through Playerbots chat.
- The previously runtime-validated Playerbots hyperlink implementations remain compatibility routes chosen only before dispatch when the native route is unavailable.
- Core remains an independent bridge implementation; the current MultiBot 4.0 addon is a protocol reference, not a runtime transport dependency.

## Alpha 1.9 notes

- Inventory mutation consumers now use one semantic service for bridge-native bank/guild-bank/vendor operations and chat-backed item actions. The Core exposes the route/capability contract; frontend modules do not construct protocol or chat commands.
- Added normalized personal-bank and guild-bank views without inventing physical storage slots.
- Added the first semantic quest service. `QUEST.ABANDON` requires explicit confirmation and never synthesizes quest hyperlinks: Core captures the exact Playerbots link from a private `quests all` probe and confirms success only when structured `BOT.QUESTS` no longer contains the quest.
- Added on-demand shared quest metadata enrichment (`BOT.QUEST_METADATA`) so future quest UIs can obtain Playerbots quest names, exact links, and quest levels without issuing their own chat queries.
- Core-triggered quest-list/feedback chatter is hidden from chat frames by default but remains available internally for correlation.

## Alpha 1.6.2 notes

- Fresh-login/group discovery uses the reference client's immediate + 0.8 s + 2.0 s bridge snapshot burst, so modules should no longer need to seed a bot with `BOT.DETAIL` when the first roster arrives before bots are fully visible.
- Core-owned trade initiation suppresses the automatic Playerbots inventory-dump chatter in chat frames by default. This is presentation-only suppression: the Core still receives/processes the whispers. Disable it in **ElvUI -> Multibot Core -> General -> Suppress Core-triggered bot chat noise** if raw chat is desired for debugging.

`ElvUI_Multibot_Core` is a **backend-only ElvUI 6.09 plugin** for World of Warcraft 3.3.5a. It communicates directly with the existing server-side Multibot bridge through the `MBOT` addon-message protocol used by the bridge developer's MultiBot client.

It intentionally does **not** implement bot inventory windows, unit-frame menus, quest windows, character sheets, or other gameplay UI. Future ElvUI modules consume the Core API and may integrate bot functionality into existing ElvUI surfaces.

## Alpha 1 goals

- Own all `MBOT` bridge transport and protocol parsing in one place.
- Convert bridge responses into canonical, reusable data snapshots.
- Deduplicate equivalent data reads so several modules share one in-flight server request and one cache.
- Commit framed/list responses only after the complete transaction ends.
- Expose semantic bridge actions and keep authoritative state unchanged until the bridge confirms a mutation.
- Provide a shared working/saved selection and semantic target-resolution service.
- Provide semantic RTI/CC-RTI and RTSC backend services for future tactical frontends.
- Allow external modules to register themselves, services, and contextual actions at startup or later.
- Provide ElvUI options and diagnostics only; no gameplay UI.
- Preserve room for future physical inventory bag/slot metadata without inventing it today.

## Installation

1. Extract the `ElvUI_Multibot_Core` folder into `World of Warcraft/Interface/AddOns/`.
2. Ensure ElvUI 6.09 is enabled.
3. Log in or `/reload`.
4. Open ElvUI options and select **Multibot Core**.
5. `/mbcore status` should report the bridge connection once the server responds.

The Core is deliberately named and namespaced separately from `ElvUI_PlayerBots_Core`, so both can be present for comparison during this fork's development.

## Diagnostics

Useful commands:

```text
/mbcore status
/mbcore caps
/mbcore modules
/mbcore selections
/mbcore requests
/mbcore extensions
/mbcore manifest
/mbcore refresh
/mbcore read BOT.INVENTORY Stabby
/mbcore get BOT.INVENTORY Stabby
/mbcore read BOT.PROFESSION_RECIPES Stabby 164
/mbcore debug on
```

## Architecture

```text
Future ElvUI modules
        |
        | Core API / subscriptions / registered context actions
        v
+---------------------------------------------------+
| ElvUI_Multibot_Core                              |
|                                                   |
| Module & contribution registry                    |
| Selection service                                 |
| Shared Data Broker -> canonical Store -> Events   |
| Semantic Action service -> invalidation           |
|               |                    |              |
|          Bridge protocol       internal chat      |
|               |              transport scaffold  |
+---------------|-----------------------------------+
                |
          MBOT addon messages
                |
        server Multibot bridge
```

Consumer modules must not send bridge packets or Playerbots chat commands directly. The Core owns communication and state invalidation.

## Inventory semantic backend

Alpha 1.6 keeps `BOT.INVENTORY` as the authoritative bridge snapshot and adds a consumer-facing semantic layer. Future frontends can use:

```lua
API:GetInventoryView(bot)
API:GetInventorySummary(bot)
API:GetInventoryLayout(bot)
API:GetInventoryIndex(bot)
API:FindInventoryItems(bot, query)
API:GetInventoryItemCount(bot, item)
API:ResolveInventoryItem(bot, selector)
API:GetInventoryEquipmentCandidates(bot, query)
API:GetInventoryCapabilities(bot)
API:GetInventoryActionAvailability(bot, action, selector, count)
```

Each observed stack preserves the exact `serverLink` supplied by Playerbots. `link` prefers that server hyperlink; `clientLink` is kept separately when `GetItemInfo()` provides one. The server link remains identity/evidence data, while chat-backed Playerbots item actions mirror the bridge developer client and prefer the canonical `clientLink` for transport, falling back to `serverLink` only when client metadata is unavailable.

An inventory stack record is **not** treated as a stable physical slot. In the current protocol, bridge item actions address `itemId + count`, so `ResolveInventoryItem()` aggregates all observed stacks of one item ID and reports `exactStackAddressable=false`.

The Core may classify carried items as equipment candidates from `equipLoc`; that remains separate from current equipped state. Version 1.2.0 adds `BOT.EQUIPMENT` as a **client-observed** Inspect snapshot for current slots. It does not make `BOT.INVENTORY` or `BOT.INVENTORY_EXACT` authoritative for equipped state, and bridge-authoritative equipment readback remains unavailable.

Alpha 1.6.1 adds Core-owned semantic `USE`, `EQUIP`, `SELL`, `DESTROY`, and `GIVE` actions. Chat transport mirrors the reference MultiBot client: it prefers the canonical client hyperlink from `GetItemInfo(itemId)` and falls back to the preserved bridge/server hyperlink only when necessary. Because the reference client does not provide authoritative ACKs for these Playerbots chat commands, transactions remain `SENT_UNVERIFIED`; inventory-affecting actions invalidate shared state and refresh through the normal data broker. Destroy requires explicit confirmation, sell requires merchant context, and give is Core-owned: Core initiates the normal trade when needed, waits for `TRADE_SHOW`, sends the item command, and never accepts the trade.

## Inventory location contract

The current reference bridge client exposes inventory through:

```text
INV_BEGIN
INV_SUMMARY
INV_ITEM
INV_END
```

`INV_ITEM` contains a useful item line from which the Core resolves item ID, count, cached item metadata, link/icon, and related information. It does **not** prove a physical WoW `bagID/slotID`.

Accordingly Alpha 1 returns inventory snapshots with:

```lua
locationModel = "FLAT"
hasPhysicalLocations = false
item.locationKnown = false
```

The Core also watches for the reference client's named-but-not-defined future/audit opcodes `INV_BAG`, `INV_ITEM_LOC`, and `INV_EQUIP_LOC`. They are recorded as observed protocol extensions, but their payload is never guessed.

## Account linking

Account-linking commands, data domains, UI, and APIs are intentionally absent from this project.

See `Developer/` for the API, domains, bridge protocol mapping, module registration contract, and Alpha 1 runtime test plan.

## Startup discovery readiness

`API:IsReady()` indicates that the Core Lua/API is initialized. `API:IsBridgeReady()` becomes true after `HELLO_ACK` and emits `MB_BRIDGE_READY`. `API:IsBotRegistryReady()` becomes true after the first authoritative bridge roster for the current session and emits `MB_BOT_REGISTRY_READY`.


## Alpha 1.2 transaction/session hardening

Bridge mutation results are correlated against the transaction that produced them before the Core consumes an ACK. A mismatched/stale ACK cannot confirm the wrong action. Known partial strategy results are not reported as full success.

When a bridge session is torn down, outstanding reads are failed immediately with the reset reason. Already-sent writes become `AMBIGUOUS` because the server may have applied them even if their ACK was lost; unsent/dispatching writes become `CANCELLED`. This prevents old-session requests from being deduplicated into a new session.

The communicator also retries an incomplete HELLO handshake and automatically starts a fresh bridge session after heartbeat timeout.
## Alpha 1.3 consumer integration helpers

Alpha 1.3 keeps API v1 and adds frontend-oriented backend helpers without adding gameplay UI. `API:GetActionAvailability()` performs the same argument/scope/capability validation that `Execute()` will use, so a menu can disable an invalid action before creating a transaction.

Context contributions may either provide a normal module `handler`, or bind directly to a Core semantic action:

```lua
API:RegisterContextAction("ExampleModule", {
    id = "set_near",
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

The contribution registry remains UI-agnostic: a unit-frame menu, command palette, radial menu, or other frontend may render the same tree.

Inventory consumers may use `GetInventoryView`, `GetInventoryLayout`, `FindInventoryItems`, and `GetInventoryItemCount` instead of depending on the raw `BOT.INVENTORY` snapshot shape. `BOT.INVENTORY` remains an aggregated `FLAT` compatibility/metadata view even when exact inventory is cached. Physical bag/slot authority is exposed only through `BOT.INVENTORY_EXACT` / `GetInventoryExactView()`.


## Shared selections and targeting

`PRIMARY` is the Core-owned transient working selection. A future unit-frame addon can implement Ctrl-click by calling `API:ToggleSelection("PRIMARY", bot)` and render highlights from `MB_SELECTION_CHANGED`. The selection is shared with every other module.

Named saved selections persist in the ElvUI profile and may be static bot lists or dynamic selectors. Supported semantic selectors include role, range, class and subgroup targets such as `tank`, `healer`, `meleedps`, `class:MAGE`, and `group:2`. Every action resolves the target specification to a frozen bot snapshot before dispatch.

## Tactical backend

RTI/CC-RTI uses the native bridge `RUN RTI` family. The Core exposes semantic assignment/attack/pull helpers and tracks bridge-confirmed assignments for the current bridge session. There is no authoritative RTI readback in the reference protocol, so external/manual RTI changes are not observable by the Core.

RTSC uses the Playerbots chat path used by the reference MultiBot client. Bare `rtsc` enables RTSC and makes AEDM available; `rtsc cancel` is the explicit disable path. The Core can enable RTSC, prepare/select an exact resolved bot set, and send it to saved RTSC locations 1-9. `PrepareRTSCPlacement()` and `SelectRTSCTargets()` enable RTSC before applying the frozen selection; they do not cancel RTSC as initialization. World placement remains a frontend responsibility because the click must use a secure action. Frontends obtain this contract from `API:GetRTSCPlacementContract()`, which returns `/cast aedm`.

RTSC chat transactions finish as `SENT_UNVERIFIED`. This means the Core knows the commands were sent, not that the server performed the resulting movement.


## Alpha 1.6 item-action API

Future modules should use `API:GetInventoryActionAvailability()` and `API:ExecuteInventoryAction()` rather than building `e`, `u`, `s`, `destroy`, or `give` chat strings. `API:GetInventoryInteractionContract()` exposes external interaction requirements such as merchant/trade context. If one item ID maps to multiple distinct server hyperlinks, semantic chat actions require the exact hyperlink/record and refuse a bare item ID with `AMBIGUOUS_ITEM_VARIANT`.



### Equipment readback history and 1.2.0 status

An earlier experimental Inspect implementation was removed after unreliable testing and was not part of the stable 1.0/1.1 API. Version 1.2.0 introduces a new, bounded Core-owned implementation based on the behavior confirmed while planning `ElvUI_Multibot_BotInspect`: native client Inspect requests are serialized, readiness is bounded, and the result is explicitly `CLIENT_INSPECT` rather than bridge authority. Consumers must still distinguish this observation from authoritative bridge state.

Use `API:Acquire(module, "BOT.EQUIPMENT", bot)` and `API:Get("BOT.EQUIPMENT", bot)` (or `GetEquipmentView`) while the bot is currently inspectable. The **live** snapshot remains non-persistent and stale/unavailable observations are not returned as current data. Core 1.3 may retain a separate historical copy, accessible only through the explicit `GetLastKnown*` APIs; that copy never becomes live equipment state.


## Alpha 1.10.3 quest sharing compatibility

Quest frontends pass an exact WoW quest hyperlink to `ExecuteQuestAction(module, targetSpec, "ACCEPT", link, ...)`. The Core freezes the target selection and refreshes structured `BOT.QUESTS` first. Bots that already carry the quest are resolved authoritatively without a redundant whisper; unresolved bots receive `accept <exact link>` individually. Current upstream Playerbots may execute that chat action silently, so Core performs bounded structured post-verification and can prove `ACCEPTED` when a quest that was absent before dispatch appears afterward. Recognized Playerbots feedback is still correlated when present.

## Alpha 1.11 native exact inventory and item actions

Alpha 1.11 keeps the public semantic item API stable while preferring the new structured bridge capabilities. `BOT.INVENTORY` remains the metadata/hyperlink view; `BOT.INVENTORY_EXACT` is a separate physical source-of-truth containing bag, slot, item ID, count and soulbound state.

When `INVENTORY_EXACT_V1` and an action-specific capability are fully negotiated, `ITEM.EQUIP`, `ITEM.USE`, `ITEM.SELL`, `ITEM.DESTROY` and `ITEM.GIVE` use the native bridge route. Otherwise the previously validated Playerbots chat route is selected before dispatch. A native action that has already been sent is never retried through chat.

`ITEM.GIVE` still uses the normal WoW trade lifecycle. Core opens/waits for the trade window and the bridge places the exact physical stack into a trade slot; the user remains responsible for accepting or cancelling the trade.


### Alpha 1.15.2 snapshot presence barrier

Explicit snapshot refresh no longer trusts cached online/lifecycle state. `RequestBotSnapshot()` refreshes `BRIDGE.ROSTER` before provider reads and again before commit. A bot absent from the fresh start roster is refused with `BOT_OFFLINE`; a bot that disappears during capture fails with `BOT_WENT_OFFLINE`. In either case the previous persisted snapshot remains unchanged. `GetSnapshotRefreshAvailability()` is advisory only.


## Alpha 1.16 - Managed Roster and linked lifecycle

Alpha 1.16 distinguishes persistent knowledge from current control authority. `ElvUI_Multibot_ManagedDB` remembers GUID/name/provenance from account Alt roster, successful target resolution and snapshots, but never persists a reusable authorization grant. Own-account Altbots may lifecycle through current `ALT.ROSTER`; non-Alt-roster managed characters require a fresh successful `BOT_TARGET_RESOLVE_V1` in the current bridge session immediately before the GUID-addressed lifecycle mutation. The Core still exposes no account-link or unlink operation.
