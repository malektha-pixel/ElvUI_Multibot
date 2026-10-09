ElvUI_Multibot_ContextMenu 0.1.0-alpha22.1
==========================================

Target
------
- WoW WotLK 3.3.5a / Interface 30300
- ElvUI 6.09
- ElvUI_Multibot_Core API v1; lifecycle-corrected Core baseline (RTSC semantics require Core 1.1.0+)

Baseline
--------
Alpha21 is built directly from live-validated Alpha20. Alpha20 itself returned to the Alpha18 lineage and deliberately skipped the experimental Alpha19 Hfound branch. No experimental direct-target probe/chat implementation is carried forward.

Interaction model
-----------------
1. Bot UnitFrame
   - Shift+Right-click continues to open the explicit per-bot menu.
   - PRIMARY is ignored for per-bot actions.

2. Empty 3D world
   - Shift+Right-click opens the PRIMARY-selection contextual menu.
   - Existing RTSC/selection behavior is retained.

3. Playerbot hovered in the 3D world
   - Still classified as WORLD_BOT through Core ResolveBot identity.
   - ElvUI > Multibot Context Menu > Interaction > World Playerbot menu
     controls whether the explicit per-bot menu is available:
       Disabled
       Enabled
       Enabled out of combat
   - The OUT_OF_COMBAT gate uses WoW InCombatLockdown() directly, not an
     ElvUI combat-state flag. PLAYER_REGEN_DISABLED closes an already-open
     WORLD_BOT menu when that policy is active.
   - When available, WORLD_BOT deliberately uses the same built-in per-bot
     controls and UNITFRAME Core contribution set as BOT_FRAME.
   - WORLD_BOT also uses the UnitFrame menu scale.

4. Other world units
   - Attackable hostile/neutral, friendly, and conservative-other units remain
     classified with legacy client-native Unit* checks for future development.
   - These contexts remain intentionally inert in Alpha21: they do not open a
     menu, do not query Core context trees, and do not read PRIMARY.
   - No spellbook/role/spec acquisition, direct Playerbots chat, or combat
     action is performed for these contexts.

Settings
--------
- World menu scale: empty-world PRIMARY menu.
- UnitFrame menu scale: UnitFrame and optional WORLD_BOT per-bot menus.
- Shared text size, background color/transparency and hover-out grace period.
- World Playerbot menu: Disabled / Enabled / Enabled out of combat.

Compatibility
-------------
- RequiredDeps remain exactly ElvUI and ElvUI_Multibot_Core.
- No ElvUI_Multibot_UnitFrames dependency.
- No raw bridge transport.
- No direct Playerbots chat in Alpha21.

Alpha21 presentation cleanup
----------------------------
- Explicit bot menus use the bot name as the class-colored title.
- Empty-world PRIMARY menus use the simple title "Selection".
- Empty-world Shift+Right-click opens no menu when PRIMARY is empty.
- Recipient/context diagnostic lines and Core contribution source labels are hidden from normal menus.
- Routine gesture capture diagnostics are no longer printed automatically; /mbcm status, last and history remain available for explicit diagnostics.
- Routine successful Follow/Stay/context-action dispatch is quiet; errors and required RTSC placement instructions remain concise.


Alpha22 adds an explicit per-bot Strategies menu for BOT_FRAME/WORLD_BOT contexts.
Strategies contains NC, CO, applicable class-specific controls, RTI, and CC RTI.
Active strategies/assignments are green; strategy toggles keep the menu open.
Role/spec/class filtering deliberately hides obviously irrelevant strategy choices.


0.1.0-alpha22.1 framework maintenance
- Corrected ElvUI 6.09 lifecycle integration: runtime starts through LibElvUIPlugin HookInitialize only after E.data/E.db exist.
- ElvUI profile defaults are registered before E:Initialize; profile change/copy/reset rebinds settings.
- Options remain registered only through LibElvUIPlugin RegisterPlugin.
- No gameplay/context/RTSC/strategy/menu-presentation behavior is intentionally changed.
