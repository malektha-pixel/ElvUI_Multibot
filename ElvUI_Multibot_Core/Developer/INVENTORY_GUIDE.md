# Inventory integration guide — Alpha 1.6

This guide is for future ElvUI consumer modules. The Core owns bridge communication and authoritative inventory state; frontends render and request semantics through API v1.

## Acquire once, share everywhere

```lua
API:Acquire(MODULE, "BOT.INVENTORY", botName)
local view, meta = API:GetInventoryView(botName)
```

Several modules acquiring the same bot inventory share the same Core cache and in-flight bridge request.

## Item record contract

Important fields on `view.items[]`:

```text
itemId                  numeric item identity
count                   quantity represented by this observed record
serverLink              exact Playerbots/server hyperlink when supplied
clientLink              local GetItemInfo() hyperlink when cached
link                    serverLink preferred, otherwise clientLink
name/icon/type/subType   client-enriched metadata when available
equipLoc                 local item equipment classification
metadataResolved         local item metadata currently cached
locationKnown            authoritative physical location known?
bag/slot/equipmentSlot   nil until the bridge actually supplies them
equipCandidate           item metadata has an equip location
exactStackAddressable    bridge can address this physical record exactly?
recordKeyStable          false for the current flat snapshot
```

The canonical client hyperlink (bridge/server fallback) is intentionally preserved. Do not replace it with a reconstructed `item:<id>` link for Playerbots-facing semantics.

## Aggregate identity vs. observed stacks

```lua
local item, err = API:ResolveInventoryItem(bot, selector)
```

Selectors may be an item ID, exact item hyperlink/record, or an unambiguous exact item name. The result aggregates duplicate observed stacks:

```text
itemId
totalCount
stackCount
records[]
representative
serverLink
bridgeAddress = { itemId=..., addressKind="ITEM_ID_COUNT" }
exactStackAddressable=false  -- current reference protocol
```

Do not interpret `records[3]` as bag slot 3. List order is not physical placement.

## Equipment

`API:GetInventoryEquipmentCandidates()` filters carried records whose local item metadata has `equipLoc`. This remains candidate classification, not current equipped-state readback. Current equipped items are a separate Core 1.2 `BOT.EQUIPMENT` client observation.

Check:

```lua
local caps = API:GetInventoryCapabilities(bot)
if caps.equipment.readback then
    -- bridge-authoritative equipped-state UI may be rendered
elseif caps.equipment.clientObserved then
    -- BOT.EQUIPMENT can provide a non-authoritative current client observation
end
```

For Alpha 1.6 `readback=false`.

## Summary and grouping

```lua
API:GetInventorySummary(bot)
API:GetInventoryIndex(bot)
API:FindInventoryItems(bot, query)
```

The summary includes bag used/total/free, stack count, total quantity, unique item IDs, money in copper, metadata resolution counts, server-link count and equipment-candidate count.

The index groups records by item ID, type, subtype, equipment location and quality. These are data helpers, not prescribed UI categories.

## Item action preflight

```lua
API:GetInventoryActionAvailability(bot, action, selector, count)
```

Alpha 1.5 performs no mutation through this helper. Source semantics are:

```text
BANK_DEPOSIT    source BOT.INVENTORY
GBANK_DEPOSIT   source BOT.INVENTORY
BANK_WITHDRAW   source BOT.BANK
GBANK_WITHDRAW  source BOT.GUILD_BANK (+ withdrawal rights)
BUY_ITEM        source VENDOR/external item ID
```

Current bridge address form is `itemId + count`. USE/EQUIP/SELL/DESTROY/GIVE are deliberately not implemented yet; they return `SEMANTIC_ACTION_NOT_IMPLEMENTED`.


## Semantic item actions

The Core now owns `EQUIP`, `USE`, `SELL`, `DESTROY`, and `GIVE`. Do not emit Playerbots chat strings from a frontend. Use preflight, then `ExecuteInventoryAction`. The semantic model preserves the exact bridge/server hyperlink for identity/evidence, but the Playerbots chat transport mirrors the bridge developer client by preferring the canonical `GetItemInfo(itemId)` client hyperlink and using `serverLink` only as fallback. Because that chat form cannot reliably distinguish multiple server-link variants sharing one item ID, variant ambiguity is rejected. `GIVE` owns its prerequisite: the Core initiates trade, waits for `TRADE_SHOW`, then sends `give <clientLink>`; the user still accepts/cancels the normal trade. Core-initiated trade inventory-dump chatter is presentation-suppressed by default without blocking Core parsers/events.



## Core 1.2 equipment observation

Use the shared Data Broker just like other domains:

```lua
API:Acquire("ElvUI_Multibot_BotInspect", "BOT.EQUIPMENT", bot)
local equipment, meta = API:Get("BOT.EQUIPMENT", bot)
-- API:Release(...) when the inspect/equipment UI no longer needs it
```

Convenience helpers are also available: `GetEquipmentView`, `GetEquipmentSlotMap`, `GetEquipmentObservationAvailability`, and `GetEquipmentObservationCapabilities`. The snapshot always uses Core-normalized pairs `uiSlot=1..19` / `serverSlot=0..18`, so an Inspect frontend can pass `slot.serverSlot` directly to the existing `ITEM.UNEQUIP` helper.

The source is `CLIENT_INSPECT`, not the bridge. Do not persist it, do not merge it into `BOT.INVENTORY_EXACT`, and do not reinterpret `GetInventoryCapabilities().equipment.readback` as client observation. The existing authoritative flags remain bridge-only; `clientObserved` is the additive 1.2 signal.

Core serializes Inspect requests globally because the native Inspect context is shared. Equivalent requests for the same bot deduplicate through the existing pending-read key. There is no new periodic equipment poller: acquire/refresh and known mutation invalidation drive observations.

## Alpha 1.7 equipment separation

## Alpha 1.11 physical inventory

Use `BOT.INVENTORY` for normalized item metadata, links, aggregate counts and compatibility UI. Use `BOT.INVENTORY_EXACT` / `API:GetInventoryExactView(botRef)` when a physical stack address is required. Exact records contain `bag`, `slot`, `itemId`, `count`, and `soulbound`. Do not infer a bag/slot by matching duplicate flat stacks.

The semantic item API chooses a native bridge route when the capability set includes both `INVENTORY_EXACT_V1` and the action-specific capability. Modules should continue calling `ExecuteInventoryAction`; they must not construct `RUN~ITEM_*` payloads directly.


## Alpha 1.12 exact operations

Use `GetInventoryExactView()` to choose physical source/destination positions. `ExecuteInventoryMove()` re-reads exact inventory before sending and fails pre-dispatch on `SOURCE_STALE` / `DESTINATION_STALE`. `ExecuteInventoryUnequip()` uses the bridge/server equipment slot index (`0..18`), not the WoW UI slot index (`1..19`). Full-stack BANK/GBANK deposits prefer exact physical addressing automatically; partial-count deposits remain on the generic bridge action route.

## Alpha 1.13 utilities and buyback

Frontends may use `SELL_GREY` / `SELL_VENDOR` for bridge-native bulk selling. Bulk selling requires a current target (the reference client uses target presence as the client-side precondition); the bridge/server remains authoritative about vendor validity and the returned `moved` value is the bridge-reported number of affected items/stacks according to the server implementation. `OPEN_ITEMS` is intentionally unsupported in Alpha 1.13.3 and frontends should hide it when the capability contract reports `reason=INTENTIONALLY_UNSUPPORTED`.

Buyback is modeled separately from inventory because server buyback slots are not bag positions. Refresh `BOT.BUYBACK`, render `GetBuybackView()`, then execute a chosen exact slot with `ExecuteBuyback()`. Do not reconstruct or guess price/count values; the Core freezes the cached exact tuple.
