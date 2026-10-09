# ElvUI_Multibot_Core 1.5.0

Core 1.5.0 is an additive Talents & Spellbook backend release requested by `ElvUI_Multibot_BotInspect`. API version remains 1.

## Read-model additions

- `BOT.SPELLBOOK` now has `retainLastKnown=true`. The existing live read remains demand-driven and unchanged.
- `BOT.TALENT_SPECS.current`, when supplied by the bridge, contains:
  - `slot` — active dual-spec slot (`1` or `2`);
  - `treePoints` — three numeric talent-tree totals;
  - `buildSummary` — convenience `tree0-tree1-tree2` text.
- A bridge/list response without `TALENT_SPEC_CURRENT` commits normally with `current=nil`.

## Premade spec mutation

Public API v1 adds:

- `API:GetTalentSpecApplyAvailability(botRef, specIndex, options)`
- `API:ApplyTalentSpec(originModule, botRef, specIndex, options, callback)`

The semantic action is `TALENT.SPEC_APPLY`, capability-gated by `TALENT_SPEC_APPLY_V1`. It is single-bot only and accepts a bridge-provided `specIndex` plus optional `slot=1|2|CURRENT`. Omitted slot means `CURRENT`.

Every execution performs a fresh `BOT.TALENT_SPECS` read before the mutation is sent. Core confirms the requested index exists in that returned list and, for `CURRENT`, resolves the active slot from that same response. No arbitrary index is sent solely because a frontend supplied it.

The wire mutation is structured only; there is no Playerbots chat fallback. The correlated `TALENT_SPEC_APPLY_RESULT` is validated for target, slot, spec index, status and returned tree totals. Canonical caches are never optimistically rewritten from the request.

## Post-apply state

On a confirmed result Core invalidates and refreshes:

- `BOT.TALENT_SPECS`
- `BOT.DETAIL`
- `BOT.STATE` (role/strategy state is reset by the server-side apply)
- `BOT.SPELLBOOK`
- `BOT.GLYPHS` (the bridge reinitializes glyphs as part of premade-spec application)

`GetBotSpec()` and `GetBotRole()` therefore continue to derive from the existing Core state after the normal detail refresh; no second spec/role cache is introduced.

## Offline/history semantics

Talent mutation is refused for an offline bot. LastKnown talent/spec and spellbook values are display-only and never participate in mutation preflight. Managed Forget continues to delete all LastKnown records for the forgotten GUID, including spellbook.

## Compatibility

Core 1.5.0 keeps API v1 and does not change existing inventory, equipment, lifecycle, Managed Roster/Forget, LastKnown, RTI, RTSC, strategy, group, quest or context-service semantics.
