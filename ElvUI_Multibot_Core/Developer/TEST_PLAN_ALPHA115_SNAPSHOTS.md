# Alpha 1.15 Snapshot Runtime Test Plan

1. With Stabby online, run `/mbcore status` and `/mbtest snapshot Stabby STANDARD`.
2. Expect cached/advisory preflight, a fresh `BRIDGE.ROSTER` presence check, one `snapshot-N` request, a second roster check before commit, `MB_SNAPSHOT_UPDATED`, and callback `SNAPSHOT_COMMITTED`.
3. Run `/mbtest snapshotshow Stabby` and `/mbtest snapshotstatus Stabby`; the persisted data must be readable.
4. `/reload`, then run `/mbtest snapshotshow Stabby` again to prove SavedVariables persistence.
5. Disconnect/unsummon Stabby. Run `/mbtest snapshotshow Stabby` first: the stored snapshot must still be readable.
6. Immediately while Stabby is offline, run `/mbtest snapshot Stabby STANDARD`. Cached availability may still look online, but the request's fresh `BRIDGE.ROSTER` preflight must return readable `BOT_OFFLINE`; the previous snapshot must remain unchanged/readable.
7. Reconnect Stabby and optionally run `/mbtest snapshot Stabby FULL`. Optional provider failures may produce a committed `complete=false` snapshot; required provider failure must refuse commit and preserve the previous snapshot.
8. `snapshot` commands are non-mutating and must emit no lifecycle/item/quest action transactions.
