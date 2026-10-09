# Core 1.4 managed-forget validation

Use an expendable/stale managed identity where possible. The test command is intentionally destructive only to Core-owned local persistence; it never deletes a server character.

## 1. Online refusal

With a managed bot online:

`/mbctest forgetstatus <bot>`

Expected: `enabled=false reason=BOT_ONLINE`. Do not expect Core to disconnect it.

## 2. Prepare an offline target

Choose an offline managed bot. Record its GUID from BotInspect/Managed Roster. If available, ensure it has last-known data, a snapshot, and membership in one or more Managed Groups. Record unrelated bots/group members for comparison.

Run:

`/mbctest forgetstatus <bot-or-guid>`

Expected: `enabled=true` unless a snapshot/group lifecycle operation is busy.

## 3. Forget

Run:

`/mbctest forget <bot-or-guid> CONFIRM`

Expected: `ok=true status=CONFIRMED code=MANAGED_BOT_FORGOTTEN`. The cleanup counts report what existed. The immediate `forgetcheck` line should show `managed=false lastKnown=false snapshot=false groups=0`.

## 4. Repeat safety

Run the same forget again. Expected: clean refusal `MANAGED_BOT_NOT_FOUND`; no unrelated state changes.

## 5. Persistence

Run `/reload`, then:

`/mbctest forgetcheck <guid>`

Expected: all false/zero. Repeat after a full logout/login or client restart. The forgotten identity must not be reconstructed from stale Core snapshots/history.

## 6. Unrelated state

Verify other Managed Roster entries, last-known observations, snapshots, groups, and group members remain unchanged. Existing UnitFrames/ContextMenu behavior should be unchanged.

## 7. Rediscovery

If the actual character still exists, later rediscover it using an existing authoritative path such as `BOT_TARGET_RESOLVE`. Expected: Core may manage it again normally; Forget is not a blacklist.

## 8. Regression

Re-run representative 1.3 last-known, 1.2 equipment, Managed Group, lifecycle, snapshot, inventory/equipment mutation, RTSC and ContextMenu/UnitFrames smoke tests as appropriate.
