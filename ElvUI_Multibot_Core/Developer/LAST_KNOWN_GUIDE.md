# Last-known observations

Core 1.3 adds a persistent historical/display-only layer for offline inspection.

## Three different concepts

### Canonical live data

`API:Get`, `GetMeta`, `Acquire`, and `Refresh` retain their existing current/session semantics. Last-known values are never inserted into the live cache.

### Last-known observations

`API:GetLastKnown` returns the newest successfully committed retained observation for one domain and one managed bot. Each domain has its own observation time. This is intentionally non-atomic.

### STANDARD/FULL snapshots

The existing snapshot service is explicit, staged, multi-domain, and atomic. It remains unchanged and is still appropriate when a deliberate point-in-time capture is required.

## Retention policy

Only descriptors with `retainLastKnown=true` participate. The initial set is identity, detail, stats, talent specs, flat inventory, exact inventory, and client-observed equipment.

Core does not query a bot merely to populate history. Retention piggybacks on normal successful commits. If no subscriber/snapshot/mutation refresh requests a domain, no new historical value is generated for that domain.

## Identity

Persistent records are keyed through the existing Managed Roster GUID. The historical store does not maintain a second bot identity database. Eligible observations that arrive before the managed GUID is known may be held in memory only for the current bridge session and attached when Managed Roster learns that GUID.

## Read-only separation

Historical values are not consulted by:

- action availability or preflight;
- item source selection;
- mutation verification;
- target resolution;
- lifecycle authorization/current state;
- transaction completion;
- canonical `API:Get`.

A frontend should use live data while the bot is available and `GetLastKnown*` only for explicit historical/offline presentation.

## Metadata

`GetLastKnownMeta` returns at least:

```text
status = OK
historical = true
persistent = true
neverLiveAuthority = true
observedAt = <wall-clock epoch>
source = <original source where available>
```

Core also preserves useful source semantics such as `complete`, `authoritative`, physical/layout markers, and source session/persistence flags when they exist.
