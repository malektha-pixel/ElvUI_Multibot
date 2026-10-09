# Persistent Bot Snapshot Guide — Alpha 1.15

## Purpose

Snapshots provide UI-readable last-known bot information while the bot is offline. They are deliberately separate from the canonical live cache.

## Safety invariants

1. Snapshot data never satisfies live `API:Get` reads.
2. Snapshot data never participates in action/lifecycle preflight.
3. Capture is explicit only; there is no automatic background sweep.
4. A capture requires a ready bridge, a queryable/online bot, and an authoritative GUID. Current `BRIDGE.ROSTER` presence is accepted as authoritative queryability even if durable `ALT.ROSTER` lifecycle metadata is temporarily stale after a manual summon; explicit `DISCONNECTING` still refuses capture.
5. All remote sections use `RefreshDomain`, preserving existing read deduplication.
6. Capture is staged; required failure, session loss, or bot-offline-before-commit preserves the previous successful snapshot.
7. Only the latest snapshot per GUID is persisted.
8. Guild/faction/team data must come from future authoritative providers and is never inferred.

## Profiles

`STANDARD`: IDENTITY, DETAIL, STATE, STATS, TALENTS, INVENTORY, QUESTS.

`FULL`: STANDARD plus optional PROFESSIONS, PVP_STATS, GLYPHS, SPELLBOOK, SKILLS, REPUTATIONS, EMBLEMS, INVENTORY_EXACT.

Context-bound data such as BANK, GUILD_BANK, BUYBACK, TRAINER and visible objects is not included automatically. Outfits remain deprioritized.

## Persistence

`ElvUI_Multibot_SnapshotsDB` is a separate SavedVariables table keyed by GUID. Inventory providers store compact representations rather than duplicating live derived indexes.

## Future guild/managed-roster integration

The user intends managed Altbots to be organized in real in-game guilds, but two factions do not interact. Future UI must therefore support faction-scoped guild groupings and exceptions. Guild membership is organization metadata only; bridge/lifecycle authorization remains the authority for control.

Server-admin-linked accounts are a high-priority blocked validation item. Core must never expose link/unlink controls, but once linked characters are authorized they should be eligible for the same managed-roster/snapshot model if the bridge exposes sufficient identity.


## Fresh presence verification (Alpha 1.15.2)

Snapshot capture uses two fresh `BRIDGE.ROSTER` barriers: one before provider collection and one before atomic commit. Cached `BOT.IDENTITY.online`, `ALT.ROSTER` lifecycle state, and snapshot status are never sufficient to authorize an explicit refresh because manual summon/unsummon can race those caches. `GetSnapshotRefreshAvailability()` is advisory; `RequestBotSnapshot()` is authoritative and can return an asynchronous `BOT_OFFLINE`, `BOT_WENT_OFFLINE`, or `PRESENCE_CHECK_FAILED` result. The existing stored snapshot is preserved on all of these outcomes.
