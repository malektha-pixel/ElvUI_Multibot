# ElvUI_Multibot_Core 1.3.0

## Scope

Core 1.3.0 is a strictly additive release requested by `ElvUI_Multibot_BotInspect`. It adds passive persistence of the newest successfully committed observation for a small explicit set of inspection-oriented bot domains.

The new historical layer does not replace the canonical live cache and does not replace STANDARD/FULL snapshots.

## Last-known store

Core now owns `ElvUI_Multibot_LastKnownDB`, keyed by the existing Managed Roster GUID identity. It deliberately has no independent name/identity index.

Initial retained domains:

- `BOT.IDENTITY`
- `BOT.DETAIL`
- `BOT.STATS`
- `BOT.TALENT_SPECS`
- `BOT.INVENTORY`
- `BOT.INVENTORY_EXACT`
- `BOT.EQUIPMENT`

Persistence happens only after a successful canonical `CommitData()` for a domain whose descriptor has `retainLastKnown=true`. Failed reads, staged/partial frames, explicit incomplete values, pending mutations, and transient/tactical domains are not retained.

If a valid observation arrives before Core has learned the bot's stable managed GUID, Core keeps only the newest eligible observation in memory for the current bridge session. When Managed Roster subsequently learns the GUID, that pending observation is bound to the GUID without issuing another read. Session reset clears these unresolved pending observations.

## Public API v1

```lua
API:GetLastKnown(domainId, botRef)
API:GetLastKnownMeta(domainId, botRef)
API:HasLastKnown(domainId, botRef)
API:GetLastKnownDomains(botRef)
```

These methods are explicitly historical/display-only. They never feed `API:Get`, `Acquire`, `Refresh`, action preflight, mutation addressing, mutation verification, lifecycle authority, target resolution authority, or transaction completion.

## Timestamps

Live Core timestamps continue to use the existing session clock where appropriate. Historical `meta.observedAt` is a wall-clock epoch from WoW's `time()` so it remains meaningful after `/reload` and logout/login.

## Equipment distinction

Live `BOT.EQUIPMENT` remains exactly as in 1.2:

- `source=CLIENT_INSPECT`
- `authoritative=false`
- `persistent=false`
- `sessionScoped=true`

A successful live observation may additionally produce a persistent historical copy returned only by `GetLastKnown("BOT.EQUIPMENT", bot)`. Historical metadata reports `historical=true`, `persistent=true`, and retains the original source/authority distinction. The copied domain value still describes the source live observation, so `sourcePersistent=false` / `sourceSessionScoped=true` are preserved in historical metadata where available.

## Snapshots remain separate

STANDARD/FULL snapshots remain explicit, staged, multi-domain, and atomic. Last-known retention is automatic, per-domain, newest-successful, non-atomic, and passive. Neither system satisfies live gameplay/control paths.

## Compatibility

API version remains 1. Existing live API signatures and semantics are unchanged. No existing poller, refresh interval, bridge route, action, mutation, snapshot, lifecycle, selection, RTI, RTSC, Managed Roster, Managed Group, service, or context-action contract is changed.

A Core 1.2.0 subscriber that never calls the new last-known APIs should behave exactly as before.
