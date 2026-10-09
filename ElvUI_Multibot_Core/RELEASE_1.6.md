# ElvUI_Multibot_Core 1.6.0 candidate

Built additively from validated Core 1.5.0. API_VERSION remains 1.

## Added
- BOT.TALENTS exact legacy 3.3.5 Inspect observation + LastKnown.
- Shared serialized native Inspect queue for BOT.EQUIPMENT and BOT.TALENTS.
- BOT.SPELL_EXCLUSIONS partial/non-authoritative session state.
- Narrow spell exclusion and explicit bot spell-cast semantics.
- Stable /mbcastguid action-bar macro contract.

## Important spell-exclusion confidence boundary
Current mod-playerbots documentation exposes `ss +<id>`, `ss -<id>`, and `ss reset`, but no authoritative exclusion-list read query. Core therefore does not fabricate a complete exclusion set. A successfully sent mutation is recorded only as requested/SENT_UNVERIFIED state. Core does not mark the spell confirmed enabled/disabled without a trustworthy readback.

## ElvUI 6.09 lifecycle/load-order correction
- Core no longer declares or force-loads `ElvUI_OptionsUI`; its only required addon dependency is `ElvUI`.
- Runtime initialization is registered through `LibElvUIPlugin-1.0:HookInitialize` and therefore runs only after ElvUI's `E:Initialize()` has created the live AceDB profile/global tables.
- Options registration through `LibElvUIPlugin-1.0:RegisterPlugin` is deferred until Core's post-ElvUI initialization.
- Core profile defaults are registered through ElvUI's `P.multibotCore`; `MB.db` is rebound to the active profile on profile change/copy/reset.
- Existing standalone Core settings are migrated once into the current ElvUI profile.
- This correction does not add or remove any Core 1.6.0 public API/action/domain/event surface.
