# Core 1.6.4.1 talent-spec polling hotfix validation

1. Start with BotInspect talent/spec consumer removed or disabled. Confirm normal login/raid operation produces no recurring `TALENT_SPEC_LIST` traffic attributable to Core.
2. Acquire `BOT.TALENT_SPECS` once from a test subscriber with default options. Expect one initial request only; wait > 120 seconds and confirm no scheduler repeat.
3. Acquire `BOT.TALENT_SPECS` with an explicit interval (for example 5 seconds). Expect one initial request only; confirm the `suppressPeriodic` guard prevents repeated reads.
4. Explicit `Refresh("BOT.TALENT_SPECS")` should still send exactly one request.
5. STANDARD snapshot should complete without a talent-spec provider/request and without a `talents` section generated from `BOT.TALENT_SPECS`.
6. FULL snapshot should likewise avoid `BOT.TALENT_SPECS`.
7. Existing stored snapshots/LastKnown data remain readable; the hotfix does not delete historical talent-spec data.
8. If `ApplyTalentSpec()` is deliberately invoked, its explicit fresh-read/apply/refresh flow should retain existing 1.6 behavior.
9. `BOT.TALENTS` client Inspect remains functional and does not create bridge talent-spec traffic.
10. Regression smoke test lifecycle-corrected ElvUI startup/profile binding, UnitFrames, ContextMenu, BotInspect non-talent features, and CommandPanel tactical/RTSC behavior.
