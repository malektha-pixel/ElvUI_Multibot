# Core 1.6 live validation

## Exact talents

1. `/mbctest talentsx Frosty` while Frosty is online/visible. Verify all three trees, points, and learned ranks against the native Inspect window.
2. `/mbctest inspectpair Frosty` repeatedly; verify Equipment and Talents both complete and no cross-bot Inspect corruption.
3. Disconnect Frosty: live `BOT.TALENTS` should become unavailable while `/mbctest lk Frosty BOT.TALENTS` remains. Test `/reload` and full restart.
4. Apply a premade spec through the validated 1.5 semantic and verify `BOT.TALENTS` refreshes to the new exact ranks.

## Spell exclusion compatibility

1. Choose a learned spell ID from `/mbctest spellbook <bot>`.
2. `/mbctest spellstate <bot> <id>` should report the domain as partial/non-authoritative and normally `enabled=nil/status=UNKNOWN` because current Playerbots documentation has no authoritative list query.
3. `/mbctest spellenable <bot> <id> off CONFIRM`; verify the transaction ends `SENT_UNVERIFIED`. Observe autonomous behavior separately. Core may report `requested=false`, but must not claim confirmed disabled state.
4. `/mbctest spellenable <bot> <id> on CONFIRM`; same semantics.
5. `/mbctest ssprobe <bot> CONFIRM` sends a bare `ss` diagnostic only after explicit confirmation. Record any bot reply verbatim; if your server exposes a stable list/readback, it can be added to a later Core parser.
6. Offline bot and invalid spell IDs must fail cleanly.

## Explicit spell cast and action-bar contract

1. `/mbctest caststatus <bot> <id>` then `/mbctest cast <bot> <id> CONFIRM`; confirm only that bot receives the command. Server/Playerbots remains authority for range/LOS/cooldown/resources/target legality.
2. Disable/exclude the same spell and confirm explicit cast is still allowed client-side.
3. `/mbctest contract <bot> <id>` should return `/mbcastguid <stable-guid> <id>` and no raw Playerbots command.
4. Execute that printed slash command with BotInspect closed, then after `/reload`; verify it routes to the correct bot/spell.

## Regression

Run the validated 1.5 talent-spec checks, 1.4 managed-forget check, 1.2 equipment check, and a basic ContextMenu RTSC save/unsave check. Existing subscribers require no source changes.
