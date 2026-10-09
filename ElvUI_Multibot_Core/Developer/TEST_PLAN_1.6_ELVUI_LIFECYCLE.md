# Core 1.6.0 — ElvUI 6.09 lifecycle/load-order correction test

This is a narrow regression pass. Do not update subscriber modules before the Core itself passes.

1. Install the corrected `ElvUI_Multibot_Core` with ElvUI 6.09 and the existing Multibot subscribers.
2. Enable Lua errors, log in, and run `/reload`.
3. Confirm there is no `AceDBOptions-3.0.lua: db = nil` error and no ElvUI initialization error.
4. Open ElvUI options normally and confirm **Multibot Core** appears and its controls render.
5. Confirm `/mbcore status` (or the normal Core diagnostic/status command) reports initialized/usable Core state.
6. Confirm existing subscriber modules can register/bind and their previous Core-backed behavior remains available.
7. Change to another ElvUI profile. Open **Multibot Core** options and change one harmless setting. Confirm the new profile owns that value.
8. Switch back to the original ElvUI profile and confirm its prior Core setting is restored, proving `MB.db` followed the active profile rather than holding a stale table.
9. `/reload` once more and repeat steps 3–6.

Expected dependency behavior:
- `ElvUI_Multibot_Core.toc` has only `## RequiredDeps: ElvUI`.
- No `OptionalDeps: ElvUI_OptionsUI`.
- Core does not call `LoadAddOn("ElvUI_OptionsUI")`.
- `RegisterPlugin` occurs only after ElvUI initialization.
