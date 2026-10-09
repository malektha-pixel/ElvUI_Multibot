# Core 1.3 last-known observation test plan

Use the optional `ElvUI_Multibot_Core_Test` addon from the 1.3 test bundle. Existing 1.2 equipment commands remain available.

## Basic commands

```text
/mbctest lk <bot>
/mbctest lk <bot> BOT.STATS
/mbctest lkrefresh <bot> BOT.STATS
/mbctest lkcompare <bot> BOT.STATS
```

For inventory/equipment, substitute `BOT.INVENTORY`, `BOT.INVENTORY_EXACT`, or `BOT.EQUIPMENT`.

## Validation

1. With an online managed Altbot, run `lkrefresh` for one retained bridge domain. Expected: the normal live read succeeds and the callback immediately sees a last-known record.
2. Run `lk <bot>`. Expected: retained domains are listed with wall-clock `observedAt` values and original sources.
3. Refresh the same domain after its data changes. Expected: its last-known value/timestamp is replaced independently of other domains.
4. Cause a read to fail after a good historical value exists (for example make the bot unavailable, then try an on-demand domain). Expected: the previous historical value remains unchanged.
5. `/reload`, then run `lk <bot> <domain>` before refreshing that domain. Expected: the historical value survives and its wall-clock timestamp is unchanged.
6. Logout/login if practical, then repeat. Expected: SavedVariables preserve the record.
7. Unsummon/disconnect the bot and compare a domain with `lkcompare`. Historical access must remain available through `GetLastKnown`; no historical record may be promoted into canonical live storage by the history subsystem.
8. For `BOT.EQUIPMENT`, verify live metadata remains `CLIENT_INSPECT`, non-authoritative, non-persistent/session-scoped while historical metadata reports `historical=true`, `persistent=true`, and preserves `source=CLIENT_INSPECT` / `authoritative=false`.
9. For `BOT.INVENTORY_EXACT`, verify historical data still contains its physical bag/slot records and last-known metadata reports physical/layout information.
10. Acquire the same live domain from multiple normal subscribers. Existing Data Broker read deduplication must remain unchanged; history retention must cause no additional read.
11. Re-run existing STANDARD/FULL snapshot tests. Snapshot behavior and stored snapshots must be unchanged.
12. Re-run existing 1.2 equipment observation/deduplication tests and RTSC regression. They must remain unchanged.
13. Re-run representative inventory mutation tests. Historical inventory must never be accepted as a mutation source when a normal live source/preflight is unavailable.
14. ContextMenu and UnitFrames should require no source changes and should behave as under Core 1.2.0.
