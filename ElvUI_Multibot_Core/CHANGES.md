# Changes

## 1.6.4.2 — Questgiver compatibility actions

- Adds fixed, one-bot-only `QUEST.ACCEPT_NEARBY` (`accept *`) and confirmed `QUEST.TALK_TARGET` (`talk`) action descriptors and API wrappers. Checks target GUID/friendliness and bot online state both before and immediately before queued chat dispatch.
- Adds quest interaction capability descriptors and marks both new actions `SENT_UNVERIFIED`; Talk may turn in completed quests and auto-choose rewards.
- Leaves the confirmed exact quest abandonment/acceptance flows, bridge domains, spell/talent behavior and lifecycle-corrected 1.6.4.1 hotfix unchanged.

## 1.6.4.1 — Talent-spec polling hotfix

- Changes `BOT.TALENT_SPECS` from periodic shared data to explicit/on-demand only. `Acquire()` may still perform its initial read, but the Core scheduler will never repeat this domain in the background, even if a subscriber supplies an interval.
- Removes `BOT.TALENT_SPECS` from STANDARD/FULL snapshot capture so an unrelated snapshot cannot trigger the bridge's expensive premade-spec config scan.
- Keeps the `BOT.TALENT_SPECS` API/protocol surface and `ApplyTalentSpec()` intact for deliberate explicit use. LastKnown retention remains passive and does not generate reads.
- Leaves client-inspected `BOT.TALENTS` untouched; it does not use `TALENT_SPEC_LIST` and is not the source of `AiPlayerbot.PremadeSpecName.*` server warnings.
- Preserves the lifecycle-corrected 1.6.4 ElvUI integration and CommandPanel tactical extensions. API version remains 1.

## 1.6.0 lifecycle correction — ElvUI 6.09 load order

- Removes `ElvUI_OptionsUI` from OptionalDeps; Core now depends only on `ElvUI` and never explicitly loads the options addon.
- Moves Core runtime initialization off its own `ADDON_LOADED` event and onto `LibElvUIPlugin-1.0:HookInitialize`, after ElvUI has created `E.data` / `E.db`.
- Defers `LibElvUIPlugin-1.0:RegisterPlugin` until that post-ElvUI initialization point, preventing options registration from touching uninitialized ElvUI profile/global state.
- Registers `multibotCore` defaults with ElvUI's profile defaults before AceDB initialization, binds `MB.db` directly to the active ElvUI profile, and rebinds after profile change/copy/reset callbacks.
- Migrates the pre-correction standalone `ElvUI_Multibot_CoreDB` settings into the active ElvUI profile once, retaining the standalone SavedVariables table only as a migration marker.
- No Core 1.6.0 API, action, data-domain, event, bridge, Inspect, talent, spell, inventory, lifecycle, tactical, or persistence semantics are changed.

## 1.6.0 — Exact inspected talents and bot-spell semantics

- Adds on-demand `BOT.TALENTS`, using the exact legacy 3.3.5 Inspect talent APIs and the same serialized native Inspect coordinator already validated for `BOT.EQUIPMENT`. The snapshot exposes active group, tree point totals, and exact individual talent tier/column/rank/maxRank values and participates in LastKnown retention.
- Adds `BOT.TALENTS` to the confirmed `ApplyTalentSpec` invalidation/refresh family without changing the validated 1.5 structured talent-spec mutation.
- Adds session-scoped `BOT.SPELL_EXCLUSIONS` plus `GetBotSpellEnabled*` / `SetBotSpellEnabled` as a narrow Playerbots-chat compatibility semantic because the current structured bridge lacks spell-exclusion support. Current Playerbots documents `ss +/-<spellId>` mutation but no authoritative exclusion-list query, so Core never pretends a sent command is confirmed: canonical state remains partial/non-authoritative and records the request separately.
- Adds `GetBotSpellCastAvailability` / `CastBotSpell` using the narrow per-bot `cast <spellId>` compatibility path. Explicit casts are not client-side blocked by exclusion state or gameplay guesses; Playerbots/server remains final authority for range, LOS, cooldown, resources and target legality.
- Adds stable managed-GUID action-bar contracts through `GetBotSpellActionContract` and `/mbcastguid <guid> <spellId>`. The slash command invokes the same Core semantic and is not a generic command tunnel.
- API version remains 1. Existing 1.5 public methods/actions/domains/events remain compatible; no full-raid polling or second Inspect scheduler is introduced.

## 1.5.0 — Talents & Spellbook semantic support

- Adds `BOT.SPELLBOOK` to the existing GUID-keyed LastKnown retention policy. Live spellbook behavior remains demand-driven; persistence only copies successful canonical commits and Managed Forget continues to remove the entire forgotten GUID history.
- Extends `BOT.TALENT_SPECS` additively with bridge-provided `current = { slot, treePoints, buildSummary }` when `TALENT_SPEC_CURRENT` is available. Older/no-CURRENT responses remain valid with `current=nil`.
- Adds additive API v1 `GetTalentSpecApplyAvailability(botRef, specIndex, options)` and `ApplyTalentSpec(originModule, botRef, specIndex, options, callback)`, backed only by structured `TALENT_SPEC_APPLY_V1`.
- Talent application is per-bot only. Core fresh-reads `BOT.TALENT_SPECS` immediately before dispatch, validates the selected premade index, resolves omitted/`CURRENT` slot from the fresh CURRENT record, and never falls back to Playerbots chat.
- The bridge result is treated as authoritative and no canonical talent/spec cache is changed optimistically. On confirmed success Core invalidates and refreshes `BOT.TALENT_SPECS`, `BOT.DETAIL`, `BOT.STATE`, `BOT.SPELLBOOK`, and `BOT.GLYPHS`; normal data events update subscribers and `GetBotSpec`/`GetBotRole` through the existing Core read paths.
- Offline mutation is refused. LastKnown talent/spec and spellbook records remain display-only and never authorize mutations.
- API version remains 1; existing 1.4 modules that do not use the new semantic retain their behavior.

## 1.4.0 — Managed identity forget / cleanup

- Adds additive API v1 `GetForgetManagedBotAvailability(botRef)` and `ForgetManagedBot(originModule, botRef, options, callback)`.
- Forget is a local Core persistence operation only: it does not delete the server character, unlink accounts, disconnect bots, or blacklist rediscovery.
- The destructive key is the existing Managed Roster GUID. Name-only requests refuse ambiguous/reused identities.
- Forget is refused while the target is currently online/transitioning, while its snapshot capture is active, or while a Managed Group lifecycle request reserves that GUID.
- Successful forget removes the Managed Roster entry/name index, automatic last-known history, persistent snapshot, session managed authorization, and membership from every Managed Group. Groups and unrelated members/history remain intact.
- Adds `MB_MANAGED_BOT_FORGOTTEN`; affected groups also emit their existing `MB_MANAGED_GROUP_UPDATED` event with reason `MEMBER_FORGOTTEN`.
- Discovery semantics remain unchanged. A real character can be learned again later through the existing authoritative discovery paths.
- API version remains 1; existing 1.3 subscribers that do not call the new forget APIs retain their behavior.

## 1.3.0

- Adds a strictly separate persistent last-known observation store for `ElvUI_Multibot_BotInspect`. Eligible domains automatically retain the newest successful canonical commit for later offline/display-only inspection; no user save button is required.
- Adds API v1 helpers `GetLastKnown`, `GetLastKnownMeta`, `HasLastKnown`, and `GetLastKnownDomains`. Existing `Get/GetMeta/Acquire/Refresh` remain live-only and are never satisfied from historical data.
- Initial retained domains are `BOT.IDENTITY`, `BOT.DETAIL`, `BOT.STATS`, `BOT.TALENT_SPECS`, `BOT.INVENTORY`, `BOT.INVENTORY_EXACT`, and `BOT.EQUIPMENT`. Transient tactical/lifecycle/transaction domains are not retained.
- Historical storage is keyed by the existing Managed Roster GUID identity in new SavedVariables `ElvUI_Multibot_LastKnownDB`; no second persistent bot identity index is introduced. Successful observations that precede GUID discovery may wait in current-session memory and are attached when the managed GUID becomes known, without extra bridge traffic.
- Historical timestamps use wall-clock `time()` so they remain meaningful across `/reload` and login. Source/authority/completeness and useful physical/layout metadata are preserved where available.
- Live `BOT.EQUIPMENT` remains session-scoped, `CLIENT_INSPECT`, non-authoritative, and non-persistent. Only its separate last-known copy is persisted for historical display.
- Existing STANDARD/FULL snapshots remain explicit atomic captures and are unchanged. Last-known persistence is passive, per-domain and non-atomic.
- No existing polling, bridge requests, actions, mutation routes, snapshots, lifecycle, selections, RTI/RTSC, services, context actions, or live event semantics are changed. API version remains 1.

## 1.2.0

- Adds the strictly additive `BOT.EQUIPMENT` domain for session-scoped, client-observed current equipment. It uses the native WoW inspect/inventory APIs and is explicitly non-authoritative/non-persistent; bridge-backed inventory authority is unchanged.
- Core owns and serializes native Inspect requests. Equivalent subscriber reads deduplicate through the existing Data Broker, and different-bot observations are queued so modules do not compete over the shared Inspect context.
- Normalizes all 19 WoW equipment slots (`1..19`) to the corresponding bridge/server equipment slots (`0..18`) in Core-owned slot descriptors. Empty slots are represented explicitly.
- Adds `GetEquipmentView`, `GetEquipmentSlotMap`, `GetEquipmentObservationAvailability`, and `GetEquipmentObservationCapabilities` as additive API v1 helpers. Generic `Acquire/Get/GetMeta/Release` works with `BOT.EQUIPMENT` unchanged.
- Extends `GetInventoryCapabilities().equipment` additively with `clientObserved` / `clientObservation`. Existing `readback`, `bridgeReadback`, and `authoritativeEquippedState` meanings are unchanged.
- `ITEM.EQUIP` and `ITEM.UNEQUIP` additionally invalidate `BOT.EQUIPMENT`. If equipment has active subscriber interest, Core schedules one bounded post-mutation re-observation; existing item mutation routing/verification remains unchanged.
- Client-observed equipment is cleared on Core/bridge session reset and when a bot leaves the live bridge roster. A stale/unavailable observation is not returned by `API:Get` as current equipment.
- Adds a focused 1.2 equipment validation plan; an optional `ElvUI_Multibot_Core_Test` addon is supplied in the accompanying test bundle.
- No existing public signatures, polling defaults, bridge protocols, selection/tactical behavior, lifecycle behavior, inventory mutation contracts, quest behavior, service/context registration semantics, or RTSC behavior are changed. API version remains 1.

## 1.1.0

- Corrects the RTSC/AEDM preparation flow discovered during `ElvUI_Multibot_ContextMenu` development. `RTSC.PREPARE` and `RTSC.SELECT` no longer begin with `rtsc cancel`, which disables RTSC and removes AEDM. They now enable RTSC with bare `rtsc` before selecting the frozen target set.
- Adds the backward-compatible semantic action `RTSC.ENABLE` and public `API:EnableRTSC(originModule, callback)` helper so subscriber modules never need to send the missing Playerbots enable command directly.
- `RTSC.CANCEL` remains the explicit disable path and continues to send `rtsc cancel`. Saved-location `GO`, `SAVE`, and `UNSAVE` behavior and all RTSC callback signatures are unchanged.
- No non-RTSC data domains, bridge routes, cache behavior, selections, lifecycle services, or existing public method signatures are changed.
- API version remains 1 because this is a backward-compatible additive/fix release.

## 1.0.1

- Quality pass over the ElvUI options text; no Core API, data model, defaults or runtime behavior changes.
- Adds hover descriptions/tooltips to the General, Shared Data, Bridge and Developer controls.
- Rewords several labels and inline descriptions to favor player-facing language while retaining technical detail in tooltips.
- Clarifies refresh intervals, bridge timing settings, automatic bot-reply suppression, diagnostics and cache clearing.
- API version remains 1.

## 1.0.0

- Promotes the live-validated Alpha 1.17.1 runtime to the first stable Core release.
- Runtime Lua is unchanged from Alpha 1.17.1; only release metadata/documentation changed.
- Talent reads remain supported through `BOT.TALENT_SPECS`; talent mutations (`TALENT_APPLY_V1`, `TALENT_SPEC_APPLY_V1`) are explicitly unsupported/deferred for 1.0.
- SelfBot and other deliberately excluded/deferred families remain outside the release scope.
- API version remains 1.

## 0.1.17.1-alpha1

- Fixes Managed Roster/group `effectiveState` incorrectly promoting persisted `lastKnownLifecycle` to current state after `/reload` or a new bridge session.
- Persisted lifecycle is now exposed only as historical `lastKnownLifecycle`. Current `effectiveState` is chosen only from current-session evidence: structured lifecycle/target-resolve observations, current `ALT.ROSTER`, or the current-session `BRIDGE.ROSTER`.
- Current evidence is timestamped and the newest authority wins, so lifecycle results can temporarily lead roster refreshes while later roster commits can supersede stale lifecycle state.
- Adds `effectiveStateSource` / `effectiveStateObservedAt` to Managed Roster views; Managed Group member views forward `effectiveStateSource` and `lastKnownLifecycle`.
- Lifecycle authorization, bulk execution, group persistence and all Alpha 1.17 mutation semantics are unchanged.

## 0.1.17-alpha1

- Adds persistent Managed Groups in separate SavedVariables `ElvUI_Multibot_GroupsDB`.
- Group membership is stored by authoritative managed-bot GUID and survives reload/offline state. Membership is organization only and never grants lifecycle authorization.
- Adds group CRUD APIs: list/get/create/rename/delete and add/remove managed members.
- Adds bounded bulk lifecycle orchestration. Each member delegates to the live-validated `RequestBotLifecycle()` path, so own-account Altbots still receive fresh `ALT.ROSTER` preflight while linked/non-Alt bots still receive fresh `BOT_TARGET_RESOLVE` before lifecycle dispatch.
- Default group lifecycle concurrency is 2 with a hard maximum of 4. Test callers may request concurrency 1 for deterministic validation.
- Group requests freeze membership at start, reserve member GUIDs against overlapping group requests, treat already-final members as skips, retain per-member outcomes, and emit start/progress/final result events.
- Bridge/session reset aborts remaining group work without group-level mutation retry or chat fallback. Already-sent per-bot lifecycle transactions retain their existing Core semantics.
- Adds Managed Group and bulk lifecycle public API/event surfaces for future raid/guild UI consumers.
- Guild discovery is intentionally not implemented yet. Future guild membership remains organizational/discovery metadata, not lifecycle authority, and faction-separated guild scopes remain required.
- Account link/unlink controls remain intentionally absent.

## 1.6.4
- Rebased CommandPanel tactical transport extensions onto the lifecycle-corrected 1.6.0 baseline.
- Added `OrderBots` and immediate RTSC placement arming without changing the corrected ElvUI lifecycle/profile implementation.
