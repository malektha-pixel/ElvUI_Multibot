# Managed Roster Guide - Alpha 1.16

`MANAGED.ROSTER` is a conceptual persistent identity layer, not a bridge authority.

Sources currently recorded:
- `ALT_ROSTER`: durable own/account-alt discovery.
- `BOT_TARGET_RESOLVE`: server-authorized target resolution; persisted only as identity/provenance.
- `SNAPSHOT`: historical identity/snapshot association.

Authorization rules:
- Current `ALT.ROSTER` membership can directly authorize lifecycle for account Altbots.
- A non-Alt-roster character must receive a fresh successful `BOT_TARGET_RESOLVE_V1` in the current bridge session immediately before lifecycle dispatch. The temporary proof expires after 3 seconds and is cleared on session reset.
- Persisted Managed Roster records, snapshots, guild membership, names, and previous resolves never authorize a mutation.
- `BOT_LIFECYCLE_V1` remains final server-side authority.

No account linking/unlinking controls exist in Core.

## Current vs historical lifecycle state (Alpha 1.17.1)

`lastKnownLifecycle` is persisted history and must never be treated as current presence. `effectiveState` is derived only from evidence observed in the current bridge session. The view also exposes `effectiveStateSource` and `effectiveStateObservedAt`. Current structured lifecycle/resolve, current `ALT.ROSTER`, and current-session `BRIDGE.ROSTER` are eligible authorities; the newest observation wins. If no current-session evidence exists, `effectiveState` is `UNKNOWN`.


## Forgetting stale managed identities (1.4.0)

Subscribers must use `API:ForgetManagedBot(...)`; they must not edit Core SavedVariables. Forget is stable-GUID cleanup of Core-owned local persistence, not a server character deletion, account unlink, disconnect, or blacklist. Core refuses the operation while that identity is currently online/transitioning or involved in conflicting snapshot/group lifecycle work.

The cascade removes Managed Roster identity/index state, last-known history, snapshot state, and membership from every Managed Group. Other bots and groups are preserved. A later authoritative discovery may recreate the managed identity normally.
