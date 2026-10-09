# Managed Groups / Bulk Lifecycle — Alpha 1.17

Managed Groups are persistent local organization records keyed by managed-character GUID. They are intentionally separate from selections, party/raid membership, guild membership, and bridge authorization.

## Authority rule

A group member is only a candidate for lifecycle work. Membership never authorizes CONNECT/DISCONNECT.

Bulk lifecycle delegates every member to `RequestBotLifecycle()`:

- own-account Altbot: fresh `ALT.ROSTER` preflight -> GUID lifecycle
- linked/non-Alt managed bot: fresh `BOT_TARGET_RESOLVE` -> GUID lifecycle

Persisted Managed Roster identity and persisted group membership cannot bypass those checks.

## Persistence

SavedVariables: `ElvUI_Multibot_GroupsDB`

Each group stores:

- stable group id
- display name
- created/updated timestamps
- member GUIDs plus last name at add time

The live group view enriches those GUIDs from Managed Roster with current state, snapshot presence and metadata.

## Bulk lifecycle

`RequestManagedGroupLifecycle(module, group, action, callback, options)` freezes the current group membership at request start.

- default concurrency: 2
- maximum concurrency: 4
- no group-level retry after send
- no chat fallback
- overlapping active group requests may not reserve the same member GUID
- already ONLINE for CONNECT / already OFFLINE for DISCONNECT is a successful skip, not a failure
- final result contains per-member child request/transaction state and aggregate counters

A bridge/session reset aborts undispatched group work. Underlying already-sent lifecycle transactions retain normal Core timeout/ambiguity handling independently.

## Future guild/raid UI

Guilds may later discover/organize managed candidates, potentially in faction-separated guild scopes. Guild membership must never be treated as control authority. Managed Groups are deliberately generic enough to represent raid rosters, role pools, bench lists, faction-specific sets, or arbitrary user organization.

## Member status freshness (Alpha 1.17.1)

Group member `effectiveState` is forwarded from Managed Roster current-session evidence. Persisted `lastKnownLifecycle` is exposed separately for historical/UI context and never grants lifecycle authority or current-state certainty.
