# AI / developer handoff — ElvUI_Multibot_Core 1.3

Build future modules against these rules:

**Version 1.0 scope note:** `BOT.TALENT_SPECS` is a supported read domain. Talent mutation is not a supported Core action in 1.0; do not dispatch or infer `TALENT_APPLY_V1` / `TALENT_SPEC_APPLY_V1` from raw bridge capabilities.

1. Target WoW 3.3.5a / ElvUI 6.09.
2. The backend addon is `ElvUI_Multibot_Core`; public API version is 1.
3. Get it from `_G.ElvUI_Multibot_Core:GetAPI(1)`.
4. Register the module before acquiring data or subscribing.
5. Use Core data domains; never parse raw MBOT messages in a consumer module.
6. Use Core semantic actions; never directly send bridge packets or Playerbots chat commands from a consumer module.
7. Do not maintain a competing authoritative bot-state cache.
8. Contextual functionality should be registered through `RegisterContextAction`; menu/front-end addons render `GetContextActions` / `GetContextTree`.
9. Module registration may happen at startup or later; frontends must react to `MB_REGISTRY_CHANGED`.
10. `BOT.INVENTORY` is currently a structured FLAT snapshot. `bag`, `slot`, and `equipmentSlot` are unavailable until the bridge proves them. Never infer locations from list order.
11. Account linking is not part of this Core and must not be implemented unless the project owner explicitly reverses that rule.
12. UI should use ElvUI 6.09 APIs and styling; do not assume Retail/current Classic APIs.
13. Treat action transactions as authoritative: `CONFIRMED` means a validated full-success bridge result; `FAILED`, `AMBIGUOUS`, and `CANCELLED` are distinct outcomes. Never assume a timed-out or session-reset write did not reach the server.
14. Use `API:GetActionAvailability()` when a frontend needs enabled/disabled action state; do not reimplement bridge/action validation in the UI module.
15. Context contributions may use either a module `handler` or a `coreAction` binding. Prefer `coreAction` when the contribution simply maps to an existing semantic Core action.
16. Inventory frontends may use `GetInventoryView`, `GetInventoryLayout`, `FindInventoryItems`, and `GetInventoryItemCount` for the aggregated flat domain. Physical bag/slot identity must come from `BOT.INVENTORY_EXACT` / `GetInventoryExactView()`; never project exact locations onto aggregated flat rows.
17. Shared multi-selection belongs to Core. Unit-frame/frontends should modify `PRIMARY` with `ToggleSelection`/`AddSelection`/`RemoveSelection`, then render state from `MB_SELECTION_CHANGED`; never keep a competing tactical selection.
18. Named saved selections are profile-persistent. Static selections store bot identities and may be edited through Core membership APIs (including adding the current `selected` set); dynamic selections store semantic selectors such as `tank`, `rangeddps`, `class:MAGE`, or `group:2` and reject manual membership edits.
19. RTI/CC-RTI uses Core semantic APIs and native bridge transactions. Never manufacture `rti ...` command strings in a consumer.
20. RTSC is Core-owned chat transport. A frontend may create the secure world-placement control from `GetRTSCPlacementContract()` (`/cast aedm`) but must call Core for enable/select/prepare/go/save/unsave/cancel. `PrepareRTSCPlacement()` and `SelectRTSCTargets()` ensure RTSC/AEDM is enabled; `CancelRTSC()` explicitly disables it.
21. Chat-backed RTSC state is `SENT_UNVERIFIED`; do not display it as server-confirmed movement. RTI/RTSC client-known tactical state is cleared across bridge sessions.
22. Core 1.3 last-known data is historical/display-only. Online modules should use normal `Acquire/Get`; offline inspection may use `GetLastKnown*`. Never feed historical inventory/equipment into actions or treat it as current state.
23. Last-known persistence is passive and per-domain; STANDARD/FULL snapshots remain the explicit atomic historical capture system.

Primary docs: `CORE_API.md`, `DATA_DOMAINS.md`, `LAST_KNOWN_GUIDE.md`, `ACTIONS.md`, `PROTOCOL_REFERENCE.md`, `MODULE_GUIDE.md`.

## Startup identity readiness

`API:IsReady()` means the Core addon is initialized. `API:IsBridgeReady()` / `MB_BRIDGE_READY` indicate a completed bridge handshake. Modules that require the initial authoritative bot list should check `API:IsBotRegistryReady()` or subscribe to `MB_BOT_REGISTRY_READY`.

## Inventory semantic contract (Alpha 1.6)

Use the public inventory helpers instead of parsing `BOT.INVENTORY` bridge payloads. Preserve `serverLink` when a UI needs exact bridge/server identity evidence, but do not construct Playerbots chat commands from it; Core chooses the correct transport link and currently prefers the canonical client `GetItemInfo()` hyperlink. Do not infer bag/slot or equipped state from list order. Current bridge item actions address item ID + quantity, not an exact physical stack.


Inventory consumers MUST use `GetInventoryActionAvailability` / `ExecuteInventoryAction`; do not construct Playerbots item chat commands. Treat `SENT_UNVERIFIED` as a send result, not proof of gameplay success.

## Alpha 1.9 quest/storage rules

- Use `GetBankView` / `GetGuildBankView` and the inventory semantic action APIs for storage workflows. Never send `ITEM_ACTION` bridge packets directly.
- Use `GetQuestView` for authoritative bot quest state. If human-readable names/exact links are needed, acquire/refresh `BOT.QUEST_METADATA` or call `RefreshQuestMetadata`; never send `quests all` directly. Use `ExecuteQuestAction(..., "ABANDON", ...)` for abandonment. Modules must never build `drop` commands or synthesize `Hquest` hyperlinks.
- `QUEST.ABANDON` is destructive and requires explicit user confirmation. Core resolves the exact Playerbots-generated quest hyperlink internally and verifies against structured bridge state.
- `SENT_UNVERIFIED` is a legitimate terminal state for best-effort Playerbots actions. Do not display it as a transport failure.

### Quest acceptance/share

Use the Core semantic quest API with an exact quest hyperlink. `QUEST.ACCEPT_LINK` supports normal Core target specs and returns per-bot outcomes. Do not send `accept <link>` directly from a module.
