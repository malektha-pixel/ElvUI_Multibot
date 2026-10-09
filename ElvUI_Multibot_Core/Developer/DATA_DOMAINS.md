# Data domains — Alpha 1

| Domain | Scope | Bridge source | Refresh behavior |
|---|---|---|---|
| `BRIDGE.ROSTER` | global | `GET ROSTER` | periodic/control-plane |
| `BOT.IDENTITY` | bot | derived from roster/detail/professions | passive |
| `BOT.STATE` | bot | `GET STATE` / `GET STATES` | periodic when acquired |
| `BOT.DETAIL` | bot | `GET DETAIL` / bootstrap `GET DETAILS` | periodic when acquired |
| `BOT.PROFESSIONS` | bot | profession responses associated with `GET DETAILS` | periodic when acquired |
| `BOT.STATS` | bot | `GET STATS` | periodic when acquired |
| `BOT.PVP_STATS` | bot | `GET PVP_STATS` | periodic when acquired |
| `BOT.WEAPON_ENCHANT` | bot | `GET WEAPON_ENCHANT` | on demand |
| `BOT.TALENT_SPECS` | bot | `GET TALENT_SPEC_LIST` | periodic when acquired |
| `BOT.GLYPHS` | bot | `GET GLYPHS` | periodic when acquired |
| `BOT.INVENTORY` | bot | `GET INVENTORY` | periodic when acquired |
| `BOT.INVENTORY_EXACT` | bot | `GET INVENTORY_EXACT` (`INVENTORY_EXACT_V1`) | on demand |
| `BOT.EQUIPMENT` | bot | native client Inspect + `GetInventoryItemLink(unit, slot)` | on demand; shared/serialized; session-only |
| `BOT.BUYBACK` | bot | `GET BUYBACK` (`VENDOR_BUYBACK_V1`) | on demand |
| `BOT.BANK` | bot | `GET BANK` | on demand |
| `BOT.GUILD_BANK` | bot | `GET GBANK` | on demand |
| `BOT.SPELLBOOK` | bot | `GET SPELLBOOK` | periodic when acquired |
| `BOT.SKILLS` | bot | `GET BOT_SKILLS` | periodic when acquired |
| `BOT.REPUTATIONS` | bot | `GET BOT_REPUTATIONS` | periodic when acquired |
| `BOT.EMBLEMS` | bot | `GET BOT_EMBLEMS` | periodic when acquired |
| `BOT.PROFESSION_RECIPES` | bot + `skillId` | `GET PROFESSION_RECIPES` | on demand |
| `BOT.OUTFITS` | bot | `GET OUTFITS` | on demand |
| `BOT.TRAINER` | bot | `GET TRAINER` | on demand |
| `BOT.QUESTS` | bot | `GET QUESTS ALL` | periodic when acquired |
| `BOT.QUEST_METADATA` | bot | Core-owned Playerbots `quests all` whisper | on demand; shared/deduplicated |
| `BOT.GAMEOBJECTS` | bot | `GET GAMEOBJECTS` | on demand |
| `GROUP.FORMATIONS` | global | `GET FORMATIONS GROUP` | periodic when acquired |
| `BOT.RTI` | bot | Core client state after confirmed semantic `RUN RTI` | session-scoped / no bridge readback |
| `BOT.CC_RTI` | bot | Core client state after confirmed semantic `RUN RTI` | session-scoped / no bridge readback |
| `CORE.RTI_ASSIGNMENTS` | global | derived from Core-known RTI assignments | session-scoped |
| `CORE.RTSC_PLACEMENT` | global | prepared RTSC/AEDM contract | session-scoped / best-effort |

## Canonical snapshots

All list/framed protocols are staged until their terminating packet. `MB_DATA_UPDATED` / `MB_DATA_CHANGED` are emitted only after commit.

A module should therefore never need to reconstruct `BEGIN → ITEM → END` protocol state.

### Core 1.5 talent/spellbook additions

`BOT.TALENT_SPECS` remains the same premade-spec list domain and now additively preserves `current.slot`, `current.treePoints`, and `current.buildSummary` when the bridge emits `TALENT_SPEC_CURRENT`; absence of CURRENT leaves `current=nil`. Both `BOT.TALENT_SPECS` and `BOT.SPELLBOOK` are eligible for LastKnown retention. This does not make historical data live or mutation-authoritative.

## Inventory snapshot

```lua
{
    name = "Stabby",
    summary = {
        gold = 0,
        silver = 0,
        copper = 0,
        bagUsed = 0,
        bagTotal = 0,
    },
    items = {
        {
            itemId = 12345,
            count = 2,
            rawLine = "...",
            name = "...",      -- if client item cache knows it
            link = "...",
            quality = 2,
            type = "Armor",
            subType = "Leather",
            icon = "...",

            locationKnown = false,
            bag = nil,
            slot = nil,
            equipmentSlot = nil,
            location = { known = false },
        },
    },
    byItemId = { ... },
    locationModel = "FLAT",
    hasPhysicalLocations = false,
    locationFields = {
        bag = false,
        slot = false,
        equipmentSlot = false,
    },
}
```

This deliberately does not manufacture bag positions from list order.


## Alpha 1.11 exact inventory snapshot

`BOT.INVENTORY_EXACT` is separate from the flat metadata/hyperlink `BOT.INVENTORY` domain. It is committed only after a valid `INV_EXACT_BEGIN ... INV_EXACT_END` frame and contains physical source identity used by native item mutations:

```lua
{
    name = "Stabby",
    bags = {
        { kind = "BACKPACK", bag = 0, slotStart = 0, slotCount = 16, itemId = 0 },
        -- BAG / KEYRING descriptors may follow
    },
    items = {
        { bag = 0, slot = 1, itemId = 1180, count = 1, soulbound = false },
    },
    itemsByPosition = { ["0:1"] = { ... } },
    summary = { bagUsed = 1, bagTotal = 16, bagFree = 15 },
    locationModel = "PHYSICAL",
    hasPhysicalLocations = true,
    exactStackAddressable = true,
    equipmentReadback = false,
}
```

Do not merge duplicate physical stacks by item ID when selecting a mutation source. `BOT.INVENTORY` remains the preferred view for names, links, local item metadata and aggregate UI; `BOT.INVENTORY_EXACT` is the authority for `(bag, slot, itemId, count)` mutation addressing.


## Core 1.2 client-observed equipment snapshot

`BOT.EQUIPMENT` is intentionally separate from both inventory domains. The live domain is not a bridge frame and remains session-scoped/non-persistent. Core resolves the bot to a currently usable WoW unit, serializes the shared native Inspect context, then commits all 19 equipment slots only when the observation is usable. Core 1.3 may separately retain that successful commit as last-known historical display data; this does not change the live domain.

```lua
{
    schemaVersion = 1,
    name = "Stabby",
    guid = "<client UnitGUID>",
    source = "CLIENT_INSPECT",
    observedAt = 123.45,
    complete = true,
    available = true,
    authoritative = false,
    persistent = false,
    sessionScoped = true,
    slotModel = {
        ui = "WOW_1_BASED_1_TO_19",
        server = "SERVER_0_BASED_0_TO_18",
        relation = "serverSlot = uiSlot - 1",
    },
    slots = {
        { uiSlot = 1, serverSlot = 0, slotName = "HeadSlot", empty = false, itemId = 12345, itemLink = "...", texture = "..." },
        { uiSlot = 2, serverSlot = 1, slotName = "NeckSlot", empty = true },
        -- ... through uiSlot 19 / serverSlot 18
    },
    byUiSlot = { ... },
    byServerSlot = { ... },
}
```

Metadata carries `source=CLIENT_INSPECT`, `authority=CLIENT_OBSERVED`, `authoritative=false`, `persistent=false`, `sessionScoped=true`, `observedAt`, `complete`, `available`, and `sessionEpoch`. A Core/session reset clears the observation. Known equip/unequip mutations invalidate it. If the bot is no longer inspectable, `API:Get("BOT.EQUIPMENT", bot)` returns no current snapshot rather than presenting the previous observation as live.

This does **not** change `BOT.INVENTORY_EXACT.equipmentReadback=false`; exact inventory remains authoritative only for physical carried stacks.

## Tactical-state authority

`BOT.RTI`, `BOT.CC_RTI`, and `CORE.RTI_ASSIGNMENTS` represent assignments made through this Core and confirmed by the bridge. The current reference protocol exposes no authoritative RTI query, so manual/MultiBot changes performed outside this Core cannot be detected. These domains are cleared on a bridge-session reset.

`CORE.RTSC_PLACEMENT` represents the Core's most recently prepared exact target set/world-placement contract. RTSC is chat-backed and therefore `BEST_EFFORT_SENT`, not bridge-confirmed. It is also cleared on a bridge-session reset.

## Alpha 1.5 BOT.INVENTORY semantic notes

`BOT.INVENTORY` remains a complete bridge snapshot, but its item records now preserve the exact Playerbots hyperlink in `serverLink`. Physical bag/slot/equipment location is not inferred. Consumer modules should use the inventory helper API instead of depending on raw snapshot internals.

Current addressing:

```text
bridge item action: itemId + count
physical stack address: unavailable
authoritative equipped state: unavailable
exact Playerbots hyperlink: preserved when supplied
```



## Alpha 1.13 buyback snapshot

`BOT.BUYBACK` is committed only after a valid `BUYBACK_BEGIN ... BUYBACK_END` frame. Each item preserves the server vendor buyback slot and stale-state guards used by `ITEM.BUYBACK`:

```lua
{
  name = "Stabby", status = "OK", reason = "OK", count = 1,
  slotModel = "VENDOR_BUYBACK_74_TO_85",
  items = { { slot = 85, itemId = 2589, count = 6, price = 1200, timestamp = 123456 } },
}
```

A module must not treat buyback slot numbers as bag slots.


## Alpha 1.14 lifecycle domains

### `ALT.ROSTER`

- Scope: `GLOBAL`
- Provider: `ALT_ROSTER` / capability `ALT_ROSTER_V1`
- Canonical contents: authorized Altbot GUID, canonical name, class ID, level, and `ONLINE`/`OFFLINE` lifecycle state.
- Framed response is committed atomically only at a valid `ALT_ROSTER_END`. Duplicate GUID/name, invalid entry, count mismatch, or truncation mismatch fails the read and preserves the previous committed snapshot.
- The protocol is un-tokenized, so Core never launches overlapping bootstrap-burst requests for this domain.

### `BOT.LIFECYCLE_TARGET`

- Scope: `BOT`, on-demand
- Provider: `BOT_TARGET_RESOLVE` / capability `BOT_TARGET_RESOLVE_V1`
- Token-correlated canonical name -> GUID + `ONLINE|CONNECTING|OFFLINE` resolution.
- Valid structured errors commit an explicit `ERR` result with GUID 0 and lifecycle `UNKNOWN`; malformed/mismatched frames fail without overwriting a good target snapshot.

## Persistent snapshots (Alpha 1.15)

Persistent bot snapshots are intentionally **not** registered as canonical data domains. They are a separate historical/offline-inspection layer backed by `ElvUI_Multibot_SnapshotsDB`. Snapshot capture refreshes normal domains through the Data Broker, stages copies, then atomically persists compact provider sections. Snapshot values must never be used as fallback data for `API:Get`, semantic action preflight, lifecycle authorization, or mutation verification.


## Core 1.3 last-known retention policy

The following bot domains opt into passive historical retention with `retainLastKnown=true`:

- `BOT.IDENTITY`
- `BOT.DETAIL`
- `BOT.STATS`
- `BOT.TALENT_SPECS`
- `BOT.INVENTORY`
- `BOT.INVENTORY_EXACT`
- `BOT.EQUIPMENT`

This descriptor flag does not make the live domain persistent. After a successful canonical commit, Core may deep-copy the value into the GUID-keyed `ElvUI_Multibot_LastKnownDB` SavedVariables store. `BOT.STATE`, RTI/CC RTI, RTSC placement, lifecycle transition state, pending transactions and other transient/tactical domains are deliberately excluded.


## 1.6 client-inspected talents and spell compatibility state

`BOT.TALENTS` is an on-demand `CLIENT_INSPECT` domain sharing the same serialized native Inspect coordinator as `BOT.EQUIPMENT`. It contains the inspected active talent group, all talent trees, tree points, and exact per-talent tier/column/rank/maxRank data. It is session-scoped live data and participates in LastKnown retention for offline display.

`BOT.SPELL_EXCLUSIONS` is session-scoped partial Core state for the Playerbots `ss` compatibility semantic. Current Playerbots documentation exposes mutation but no authoritative exclusion-list query, so the domain explicitly reports `authoritative=false`, `complete=false`, and `readback=UNAVAILABLE`. A sent mutation is retained only under `requested`; it is not promoted into confirmed `excluded`/`known` state without a future parseable server readback.
