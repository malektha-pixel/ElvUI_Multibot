# Alpha 1.14 lifecycle runtime test plan

## Read-only smoke

```text
/mbcore status
/mbcore caps
/mbtest altroster
/mbtest resolve Stabby
```

Expected: Core 0.1.14-alpha1; capabilities include `ALT_ROSTER_V1`, `BOT_TARGET_RESOLVE_V1`, `BOT_LIFECYCLE_V1`; Alt roster lists authorized online/offline Altbots with GUID/state; resolver returns canonical Stabby identity.

## Safe lifecycle round trip

Choose an Altbot shown `OFFLINE` in `/mbtest altroster` and not needed for current gameplay.

```text
/mbtest lifecycle <bot> CONNECT CONFIRM
```

Expected: one `BOT.CONNECT` transaction; it may go through `PENDING/CONNECTING`; final `CONFIRMED` must report `ONLINE`. Re-run `/mbtest altroster` and verify the durable roster now reports ONLINE.

Restore the test bot:

```text
/mbtest lifecycle <bot> DISCONNECT CONFIRM
```

Expected final `OFFLINE` and refreshed Alt roster.

## Safety checks

- CONNECT on an ONLINE Altbot -> `ALREADY_ONLINE` before send.
- DISCONNECT on an OFFLINE Altbot -> `ALREADY_OFFLINE` before send.
- Repeated concurrent lifecycle request for the same GUID -> `LIFECYCLE_BUSY`.
- Never repeat a mutation merely because a sent transaction becomes `AMBIGUOUS`; refresh state first.
