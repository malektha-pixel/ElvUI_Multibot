# Module guide

## Target

- WoW 3.3.5a (`Interface: 30300`)
- ElvUI 6.09
- Existing AzerothCore Playerbots setup
- Existing server Multibot bridge
- `ElvUI_Multibot_Core` API v1

## Suggested module `.toc`

```text
## Interface: 30300
## Title: |cff1784d1ElvUI|r Multibot Inventory
## RequiredDeps: ElvUI, ElvUI_Multibot_Core
```

## Startup pattern

```lua
local Core = _G.ElvUI_Multibot_Core
local API = assert(Core:GetAPI(1))

API:RegisterModule("ElvUI_Multibot_Inventory", {
    version = "0.1.0",
})

API:Acquire("ElvUI_Multibot_Inventory", "BOT.INVENTORY", "Stabby")
```

Registration is not restricted to login. A load-on-demand module may register later; the Core emits `MB_REGISTRY_CHANGED` so existing frontends can rebuild context menus.

## Contextual menus without dependencies

The inventory module can register:

```lua
API:RegisterContextAction("ElvUI_Multibot_Inventory", {
    id = "open",
    contexts = { "BOT", "UNITFRAME" },
    path = { "Inventory" },
    label = "Open Inventory",
    handler = function(context)
        Inventory:Open(context.bot)
    end,
})
```

A unit-frame addon simply renders:

```lua
local tree = API:GetContextTree("UNITFRAME", { bot = botName })
```

Neither module needs to know the other exists.

### Direct semantic-action contribution

For a menu entry that maps directly to a Core action, avoid a redundant handler wrapper:

```lua
API:RegisterContextAction("ElvUI_Multibot_Formations", {
    id = "near",
    contexts = { "GROUP" },
    path = { "Formation" },
    label = "Near",
    requirements = { bridgeReady = true },
    coreAction = {
        id = "FORMATION.SET",
        target = "all",
        args = { scope = "GROUP", formation = "near" },
    },
})
```

The Core evaluates action preflight when the context tree is requested, so frontends receive an enabled/disabled state without understanding bridge capabilities or action argument rules.

### Inventory consumer helpers

A bag/equipment frontend should prefer the normalized helpers when convenient:

```lua
local view, meta = API:GetInventoryView(botName)
local layout = API:GetInventoryLayout(botName)
local matches = API:FindInventoryItems(botName, { itemId = 12345 })
local count = API:GetInventoryItemCount(botName, 12345)
```

`view.layout.hasPhysicalLocations` is authoritative. Do not turn flat list order into fake bag/slot coordinates.

## Data rule

Do not keep a second authoritative inventory/quest/state/etc. cache. It is fine to cache layout, filtering, scroll position, expanded tree nodes, or other UI-only state.

When `MB_DATA_CHANGED` fires, read/render the committed Core snapshot.

## Communication rule

Do not call `SendAddonMessage("MBOT", ...)` or Playerbots `SendChatMessage(...)` directly. Request data/actions through API so deduplication, validation, transactions, and invalidation remain coherent.

## Shared tactical selection

A frontend that offers bot multi-selection (for example Ctrl-click on ElvUI unit frames) must use the Core working selection rather than storing its own bot set. `PRIMARY` is the conventional shared selection. Subscribe to `MB_SELECTION_CHANGED` and render highlighting from `API:GetSelection("PRIMARY")`.

Saved groups should use `SaveSelection`; action modules should accept generic `targetSpec` values so the same group can be used by RTI, RTSC, movement, strategies, or future services.

For RTSC world placement, the frontend may own a `SecureActionButtonTemplate` configured from `API:GetRTSCPlacementContract()`. Use `API:EnableRTSC()` when an explicit enable control is needed; preparation/selection also ensures RTSC is enabled. `API:CancelRTSC()` is the explicit disable path. A frontend must not send `rtsc` Playerbots chat itself.
