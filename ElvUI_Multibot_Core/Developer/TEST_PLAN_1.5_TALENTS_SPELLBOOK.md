# Core 1.5 Talents & Spellbook validation

Use one online managed bot with `TALENT_SPEC_APPLY_V1` available. Prefer a bot whose two premade specs are visibly different.

## A. Read and LastKnown

1. `/mbctest talents <bot>`
   - Existing premade spec list is present.
   - `current` prints active slot and three tree totals when the current bridge supports `TALENT_SPEC_CURRENT`.
2. `/mbctest spellbook <bot>`
   - Live spellbook succeeds and reports a nonzero count for a normal trained bot.
   - LastKnown spellbook is created with `historical=true`, `persistent=true`.
3. Disconnect the bot.
   - `/mbctest lk <bot> BOT.SPELLBOOK` remains available.
   - `/mbctest lk <bot> BOT.TALENT_SPECS` preserves `current`.
4. Attempt `/mbctest lkrefresh <bot> BOT.SPELLBOOK` while offline.
   - Live read fails/TIMEOUT; the prior LastKnown timestamp/value remains unchanged.
5. `/reload`, then repeat the LastKnown reads.
6. Full client restart, then repeat the LastKnown reads.

## B. Availability and validation

7. Reconnect the bot and run `/mbctest talents <bot>` once.
8. `/mbctest talentstatus <bot> <validIndex> CURRENT` -> enabled=true.
9. `/mbctest talentstatus <bot> 30 CURRENT` using an index not listed for that class -> `SPEC_NOT_AVAILABLE` (choose another absent index if 30 exists).
10. Disconnect the bot -> talentstatus is disabled with `BOT_OFFLINE`.
11. Older/no-CURRENT compatibility can be validated with a bridge response that omits CURRENT: the list remains usable; `CURRENT` application is unavailable while explicit slot 1/2 remains structurally supported.

## C. Structured mutation

12. Reconnect and refresh talents. Record active slot/build and `GetBotSpec`/`GetBotRole` output.
13. Apply a different premade spec to active slot:
    `/mbctest talentapply <bot> <validIndex> CURRENT CONFIRM`
    - transaction becomes CONFIRMED;
    - result status is OK;
    - result slot/specIndex match request;
    - result contains three tree totals.
14. Observe the automatic post output and/or rerun `/mbctest talents <bot>`:
    - canonical CURRENT reflects the new tree totals;
    - `BOT.DETAIL` and `BOT.STATE` have refreshed so Core spec/role helpers converge normally;
    - `BOT.SPELLBOOK` refresh succeeds;
    - LastKnown talent/spellbook update on successful commits.
15. If dual spec slot 2 is available/eligible, repeat with explicit slot `2`; likewise test explicit slot `1`.
16. Omit slot entirely (`... <index> CONFIRM`) and verify it resolves the fresh CURRENT slot.
17. Verify no Playerbots talent whisper/chat command is sent.

## D. Regression

18. Managed Forget a disposable/offline managed identity with retained spellbook history and confirm its LastKnown data is removed.
19. Existing Core 1.4 Managed Forget test remains clean after restart.
20. Smoke-test ContextMenu RTSC/RTI, UnitFrames, lifecycle, and one inventory/equipment read/mutation path. No subscriber source changes should be required.
