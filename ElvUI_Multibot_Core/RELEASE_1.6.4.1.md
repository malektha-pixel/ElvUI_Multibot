# ElvUI_Multibot_Core 1.6.4.1 — talent-spec polling hotfix

Baseline: validated lifecycle-corrected Core 1.6.4.

## Purpose

Stop `BOT.TALENT_SPECS` from creating recurring `TALENT_SPEC_LIST` bridge traffic. Current bridge handling of one talent-spec-list request can probe many optional `AiPlayerbot.PremadeSpecName.*` configuration keys, so periodic subscriber interest can amplify into large synchronous server-log bursts.

## Runtime changes

- `BOT.TALENT_SPECS` is explicit/on-demand only.
- Core's data scheduler will never periodically refresh this domain, including when a subscriber supplies a custom interval.
- STANDARD/FULL snapshots no longer request `BOT.TALENT_SPECS`.
- Explicit `API:Refresh("BOT.TALENT_SPECS", ...)` remains supported.
- `API:ApplyTalentSpec(...)` remains supported and may still perform the explicit talent-spec reads required to validate/apply a user-requested mutation.
- Passive LastKnown storage remains supported and generates no traffic itself.
- `BOT.TALENTS` remains unchanged because it is a native client Inspect domain rather than a bridge `TALENT_SPEC_LIST` read.

## Compatibility

API version remains 1. No public API, action, domain or event identifier is removed. The lifecycle-corrected ElvUI 6.09 files and the Core 1.6.4 CommandPanel tactical extensions are preserved.
