# Alpha 1.9 Quest Metadata Test Plan

This phase is non-mutating. It validates shared Playerbots quest metadata enrichment only.

1. Install matching Core/Test Alpha 1.9 builds.
2. Run `/mbtest all Stabby` or `/mbtest questmeta Stabby`.
3. Expected: Core sends a private `quests all` query; its list/summary is hidden from normal chat when suppression is enabled.
4. Test should report `PASS quest metadata` with coverage=true and exactLinks matching the current structured quest count.
5. `/mbtest questlist Stabby` after hydration should show human-readable names, `nameSource=PLAYERBOTS_QUESTS_ALL` for runtime-enriched placeholders, `exactLink=true`, and a quest level where Playerbots supplied it.
6. No quest is accepted, abandoned, or otherwise mutated by `questmeta`/`all`.

The already validated `/mbtest questabandon ... CONFIRM` flow is intentionally unchanged.
