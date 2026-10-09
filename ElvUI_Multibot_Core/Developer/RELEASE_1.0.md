# ElvUI_Multibot_Core 1.0 — Final Regression / Completion Assessment

## Release decision

**PASS — Alpha 1.17.1 is promoted to Version 1.0.0.**

The 1.0 runtime is deliberately the exact Alpha 1.17.1 Lua implementation. No Alpha 1.18 talent-mutation implementation is carried forward. Only `.toc` version metadata and documentation are changed for the stable release.

## Final scope decision

Supported talent functionality in 1.0:

- structured `BOT.TALENT_SPECS` reads;
- existing class/spec/role derivation from read data where available;
- snapshot capture of the existing talent-spec read domain.

Unsupported/deferred talent functionality in 1.0:

- `TALENT_APPLY_V1`;
- `TALENT_SPEC_APPLY_V1`;
- `TALENT.APPLY_CUSTOM`;
- `TALENT.APPLY_SPEC`.

A raw bridge capability may be advertised by the server without becoming a supported Core action.

## Regression assessment

### Static/package integrity — PASS

- 26 Core Lua files + 1 Test Lua file parse successfully with the available Lua runtime parser.
- Every `.toc` Lua entry resolves to a real file.
- No Lua files exist outside the `.toc` load list.
- No modern-Retail API/syntax red flags were found in the loaded Lua files.
- Action registry: 32 entries, all with required action descriptor metadata.
- Data-domain registry: 32 entries, all with required domain descriptor metadata.

### Architecture/safety invariants — PASS

- Shared Data Broker/canonical-cache architecture remains intact.
- Persisted Managed Roster `lastKnownLifecycle` remains historical only and cannot be promoted into current `effectiveState` after reload/session reset.
- Linked/non-Alt lifecycle uses fresh target resolution; Managed Group membership does not grant lifecycle authority.
- Bulk lifecycle delegates each member to the existing per-bot lifecycle path, with bounded concurrency and no group-level retry/chat fallback.
- Persistent snapshots remain a separate historical/offline layer and perform fresh live-roster checks around staged capture/atomic commit.
- `BOT.INVENTORY` remains the flat/compatibility view; `BOT.INVENTORY_EXACT` remains the physical bag/slot authority.
- `INVENTORY_OPEN_V1` remains intentionally unsupported.
- Precise quest abandon still captures the Playerbots-generated exact quest hyperlink before `drop`, with structured quest-state verification.
- Structured mutations retain the no-blind-retry/no-post-send-chat-fallback safety policy in their validated paths.

### Explicitly absent/deferred families — PASS

The 1.0 Lua runtime contains no implementation references for:

- `SELF_BOT_V1`, `SELF_STRATEGY_V1`, `SELF_ACTION_V1`;
- `TALENT_APPLY_V1`, `TALENT_SPEC_APPLY_V1`;
- `LOOT_RULE_ITEM_V1`, `GROUP_ROLL_V1`;
- `CRAFT_RECIPE_TARGET_V1`, `ENCHANT_TRADE_V1`;
- Core account-link creation/removal actions.

## Live-validation basis inherited from Alpha 1.17.1

The promoted baseline already had live validation for the bridge/session foundation, shared/deduplicated reads, own-account and linked-bot lifecycle, Managed Roster current-vs-historical state, STANDARD/FULL snapshots and persistence, GUID-backed Managed Groups, sequential/parallel bulk lifecycle, structured/exact inventory and item mutations, vendor buyback, structured quest reads, exact quest accept, and exact-link quest abandon.

## Release policy after 1.0

Treat Core 1.0 as feature-complete for its frozen initial scope. Future work should primarily be subscriber modules. Add Core functionality only when a real subscriber exposes a genuine backend deficiency or the project owner explicitly reopens a deferred family.
