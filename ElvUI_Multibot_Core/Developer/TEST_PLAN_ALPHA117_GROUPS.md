# Alpha 1.17 live test plan

## Prerequisites

1. Install matching Core/Test Alpha 1.17 and `/reload`.
2. Bridge must report ready with `ALT_ROSTER_V1`, `BOT_TARGET_RESOLVE_V1`, and `BOT_LIFECYCLE_V1`.
3. Managed Roster must already know the intended members. For the first test use:
   - `Stabby` — own-account Alliance Altbot
   - `Finn` — linked-account Alliance character already runtime-validated through target resolve/lifecycle
4. Keep both test bots OFFLINE before the first bulk CONNECT.
5. Use a test group containing only those two bots. Do not include opposite-faction characters such as the previously observed hostile linked/Altbot case.

## Persistence / membership

```
/mbtest groupcreate RaidTest
/mbtest groupadd RaidTest Stabby
/mbtest groupadd RaidTest Finn
/mbtest group RaidTest
/reload
/mbtest group RaidTest
```

Expected: same group id, two GUID-backed members after reload.

## Sequential bulk CONNECT

```
/mbtest grouplifecycle RaidTest CONNECT CONFIRM 1
```

Expected: one member at a time. Stabby uses Alt-roster authorization; Finn uses fresh target resolve. Final aggregate result should be completed with two confirmed members (or an already-final skip if one was already online).

## Sequential bulk DISCONNECT

```
/mbtest grouplifecycle RaidTest DISCONNECT CONFIRM 1
```

Expected: both return OFFLINE with per-member results retained.

## Default concurrency smoke test

With both offline again:

```
/mbtest grouplifecycle RaidTest CONNECT CONFIRM 2
```

Expected: at most two children in flight; both independently retain normal lifecycle authorization/convergence.

Then disconnect again, optionally at concurrency 2.

## Safety checks

- Starting another lifecycle request on the same active group must refuse `GROUP_LIFECYCLE_BUSY`.
- Starting an overlapping group request containing a GUID already reserved by another active group must refuse `GROUP_MEMBER_BUSY`.
- Group membership alone must never make a linked bot lifecycle-authorized; Finn must continue to resolve fresh for each group CONNECT/DISCONNECT.
