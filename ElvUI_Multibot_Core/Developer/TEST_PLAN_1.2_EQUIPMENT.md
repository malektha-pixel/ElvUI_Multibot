# Core 1.2 equipment observation test plan

Use the optional `ElvUI_Multibot_Core_Test` addon from the accompanying test bundle for read-only diagnostics. The commands below do not equip/unequip items themselves.

## Preconditions

- WoW 3.3.5a + ElvUI 6.09.
- Core 1.2.0 loaded and bridge ready.
- One Altbot (examples below use `Stabby`) is in the party/raid and close enough to inspect.

## 1. Complete visible equipment observation

Run:

```text
/mbctest eq Stabby
```

Expected:

- request completes with `source=CLIENT_INSPECT`;
- `complete=true`, `authoritative=false`, `persistent=false`, `sessionScoped=true`;
- 19 slots are returned;
- occupied slots contain item link/item ID where available.

## 2. Empty-slot representation

Inspect the printed slot summary or use a small subscriber to read `equipment.slots`.

Expected: every equipment position exists in the array. Unequipped positions have `empty=true`; they are not omitted.

## 3. Slot normalization

Run:

```text
/mbctest slots
```

Expected: exactly 19 descriptors; each row satisfies `serverSlot = uiSlot - 1`, from `1 -> 0` through `19 -> 18`.

## 4. Uninspectable bot

Move the bot out of usable inspect context/range or remove it from the visible group, then run:

```text
/mbctest eq Stabby
```

Expected: clean error such as `BOT_UNIT_UNAVAILABLE`, `BOT_NOT_VISIBLE`, or `BOT_NOT_INSPECTABLE`. No fabricated equipment snapshot is returned as current.

## 5. Shared-read deduplication

Run:

```text
/mbctest dual Stabby
```

Expected: the diagnostic reports one new read and at least one deduplicated equivalent request, not two competing Inspect requests.

Afterward:

```text
/mbctest release Stabby
```

## 6. Release behavior

After releasing both diagnostic interests, leave the bot unchanged.

Expected: no periodic equipment polling is created. Core 1.2 equipment is on-demand; only explicit refresh/acquire or known mutation invalidation can request another observation.

## 7. ITEM.EQUIP invalidation

With an BotInspect/test subscriber holding `BOT.EQUIPMENT` interest, perform a normal existing Core `ITEM.EQUIP` mutation.

Expected:

- existing item transaction behavior/route is unchanged;
- `MB_DATA_INVALIDATED` includes `BOT.EQUIPMENT` for that bot;
- because interest exists, a bounded delayed equipment refresh is scheduled;
- a successful re-observation shows the new equipped state.

## 8. ITEM.UNEQUIP invalidation

Repeat with existing `ITEM.UNEQUIP` using the snapshot's `serverSlot` and expected item ID.

Expected: same invalidation/re-observation behavior; mutation arguments and bridge verification remain unchanged.

## 9. No-interest mutation behavior

Release `BOT.EQUIPMENT` interest, then equip/unequip normally.

Expected: the domain is invalidated if cached, but no unnecessary Inspect refresh is scheduled.

## 10. Session reset

Acquire equipment, confirm a snapshot, then `/reload` or otherwise begin a fresh Core bridge session.

Expected: the old client-observed equipment cache is not carried forward as current data.

## 11. Existing API compatibility

Run normal ContextMenu, UnitFrames, RTSC, RTI, selections, managed roster/groups, lifecycle, inventory, quest, snapshot, service-registration and context-action tests used for Core 1.1.0.

Expected: no source change is required for modules that do not request `BOT.EQUIPMENT`.

## 12. Inventory mutation regression

Repeat representative existing `ITEM.EQUIP`, `ITEM.UNEQUIP`, `ITEM.USE`, `ITEM.SELL`, `ITEM.GIVE`, `ITEM.MOVE`, and `ITEM.DESTROY` tests as applicable.

Expected: preflight, route selection, transaction state, bridge/chat fallback rules, exact-source validation and inventory refresh behavior are unchanged except for the additional equipment invalidation on equip/unequip.

## 13. RTSC regression

Repeat the 1.1 RTSC preparation test.

Expected: bare `rtsc` still enables AEDM, `RTSC.PREPARE`/`RTSC.SELECT` do not initialize with `rtsc cancel`, and the equipment release has no interaction with tactical state.
