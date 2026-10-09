# Alpha 1 runtime test plan

The offline harness validates parser/state-store behavior, but the following tests require the actual WoW client + server bridge.

## 1. Load and ElvUI integration

- Install only `ElvUI_Multibot_Core` (the old Core may remain installed because namespaces differ).
- `/reload`.
- Verify no Lua error.
- Open ElvUI options -> **Multibot Core**.
- Verify General, Shared Data, Modules, Bridge, Developer tabs appear.

## 2. Bridge handshake

Run:

```text
/mbcore status
/mbcore caps
```

Expected:

- Bridge becomes connected.
- Protocol is `1` for the uploaded reference generation.
- Server identifier is shown if supplied.
- Capabilities reported by the server are listed; known expected capabilities may include `STATE_FRAMING_V1` and `STRATEGY_MUTATION_V1`.

## 3. Roster / identity

Run:

```text
/mbcore read BRIDGE.ROSTER
/mbcore get BRIDGE.ROSTER
```

Expected: successful revision with current bridge bot roster.

## 4. Structured state

For an online bot:

```text
/mbcore read BOT.STATE Stabby
/mbcore get BOT.STATE Stabby
```

Expected: complete snapshot commits once. No partial state should appear during framed transfer.

## 5. Inventory

```text
/mbcore read BOT.INVENTORY Stabby
/mbcore get BOT.INVENTORY Stabby
```

Expected:

- read completes;
- item count is non-zero when the bot has items;
- item IDs resolve rather than appearing only as an unstructured number list;
- Core reports the snapshot as flat/no physical locations.

If `/mbcore extensions` later reports `INV_BAG`, `INV_ITEM_LOC`, or `INV_EQUIP_LOC`, preserve the output for protocol analysis; Alpha 1 deliberately does not guess those payloads.

## 6. Other read endpoints

Use the same pattern on a bot where data is available:

```text
/mbcore read BOT.DETAIL Stabby
/mbcore read BOT.STATS Stabby
/mbcore read BOT.PVP_STATS Stabby
/mbcore read BOT.TALENT_SPECS Stabby
/mbcore read BOT.GLYPHS Stabby
/mbcore read BOT.SPELLBOOK Stabby
/mbcore read BOT.SKILLS Stabby
/mbcore read BOT.REPUTATIONS Stabby
/mbcore read BOT.EMBLEMS Stabby
/mbcore read BOT.QUESTS Stabby
/mbcore read BOT.OUTFITS Stabby
/mbcore read BOT.BANK Stabby
/mbcore read BOT.GUILD_BANK Stabby
/mbcore read BOT.TRAINER Stabby
/mbcore read BOT.PROFESSION_RECIPES Stabby 164
/mbcore read GROUP.FORMATIONS
```

Some endpoints naturally require context (bank/guild bank/trainer/profession) and may return bridge errors when the bot is not in the required situation. The important Alpha 1 check is that the Core reports failure without corrupting another domain.

## 7. Deduplication (developer module test)

Have two test modules call:

```lua
API:Acquire("ModuleA", "BOT.INVENTORY", "Stabby")
API:Acquire("ModuleB", "BOT.INVENTORY", "Stabby")
```

With debug enabled, there should be one in-flight inventory bridge request, not one request per module. `/mbcore requests` should show one read.

This exact case is covered by the offline Alpha 1 smoke harness as a regression test.

## 8. Module/context registry

A test module registers a `BOT` context action. Confirm:

```text
/mbcore modules
```

Then query the Core API from a frontend test and verify `GetContextTree("BOT", ...)` contains the registered branch. Load another module later and verify `MB_REGISTRY_CHANGED` lets the frontend rebuild dynamically.

## 9. Mutation testing

Do not start with destructive item/vendor/craft actions. First test a reversible `STRATEGY.MUTATE` or formation action through an external test module.

Expected:

- transaction progresses SENT -> CONFIRMED/FAILED;
- authoritative cached state is not changed before ACK;
- confirmed action invalidates the appropriate domain;
- active subscribers trigger one shared refresh.

## Fresh-login identity regression (0.1.1)

After a full client restart, do **not** manually read `BOT.DETAIL` first. Wait for the bridge to connect, then run:

```text
/mbcore status
/mbtest all Stabby
```

Expected: `/mbcore status` reports `identity ready`, and the test module resolves Stabby without a manual detail request.


## Alpha 1.2 safe mutation regression

Use the companion `ElvUI_Multibot_Test` addon and run:

```text
/mbtest mutation
```

The test first refreshes `GROUP.FORMATIONS`. It proceeds only if all returned formation entries agree on one current formation, then reapplies that same formation. This should exercise the full `RUN~FORMATION -> FORMATION_ACK -> CONFIRMED -> GROUP.FORMATIONS invalidated -> shared refresh` chain without intentionally changing the current formation. If the snapshot is mixed/empty, the test refuses to send a mutation.
