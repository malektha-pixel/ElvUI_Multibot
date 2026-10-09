ElvUI_Multibot_CommandPanel 0.1.0-alpha10.6
Requires: ElvUI 6.09 + lifecycle-corrected ElvUI_Multibot_Core 1.6.5+


0.1.0-alpha10.6 GO TO reliability rework
- Removes CommandPanel use of Core ArmRTSCMoveImmediate / Playerbots `rtsc move` for GO TO.
- GO TO now always uses reserved scratch slot 9 and the proven Playerbots `rtsc go 9` movement path.
- Slot 9 is pre-armed with `rtsc save 9` while the Combat Front Page is rendered, before the user presses GO TO. The GO TO cell stays covered as ARMING for a short settle window after the chat send.
- The protected GO TO click itself sends no chat commands; it only casts AEDM using the already-armed save-9 state.
- After the ground click is observed, CommandPanel sends STAY through Core, waits until that order is sent, then sends RTSC.GO slot 9 to the exact frozen recipients.
- Slot 9 is intentionally not unsaved after movement. A saved waypoint is inert without a GO command; avoiding UNSAVE removes the earlier go/unsave race.
- After GO has been sent, save-9 is re-armed for the next one-click GO TO. Bot registry/presence changes debounce a re-prime so newly connected bots receive the scratch arm too.
- SET LOCATION still uses the existing named-slot flow; after placement, scratch slot 9 is re-armed automatically if the front page contains GO TO.
- `/mbcp status` now includes `scratch9=true/false` for live diagnosis.

Live-test focus for Alpha10.6
--------------------------------
1. Put one GO TO shortcut on the front page and wait until its brief ARMING state disappears.
2. GO TO -> All. Click a clearly visible location. Expected chat-side order: pre-armed save 9 occurred before the click; after the click, STAY is sent and then `rtsc go 9`.
3. Repeat for Ranged DPS and Melee DPS to two different places. Neither command should use `rtsc move`.
4. Run `/mbcp status`; `scratch9=true` should normally be restored shortly after a completed GO TO.


0.1.0-alpha10.5 secure-front hotfix
- Secure GO TO / SET LOCATION shortcuts remain visibly labelled even if the protected AEDM layer is temporarily unavailable.
- Secure placement setup is retried on PLAYER_ENTERING_WORLD and opportunistically on out-of-combat renders.
- /mbcp status now reports secureReason when secureRTSC=false.
- No shortcut storage, preset, recipient, RTSC movement, or combat workflow semantics changed.

Live-test focus
---------------
1. Planner safety:
   - Out of combat, PLAN opens Encounter Planner normally.
   - In combat lockdown, PLAN refuses cleanly and leaves Combat Control usable.
2. Follow / Stay:
   - Footer FOLLOW ALL sends the actual Core tactical FOLLOW order directly.
   - On successful send it changes to STAY ALL.
   - STAY ALL changes back to FOLLOW ALL after successful send.
   - No per-bot strategy-mutation barrier is used.
3. MOVE TO / GO TO:
   - Both send the actual Playerbots STAY order before RTSC movement.
4. Pull Assigned:
   - Sends FOLLOW first to release a bot parked by STAY, then immediately issues Pull Assigned RTI.
5. RTI side panel:
   - Group recipients stay on the first dropdown level.
   - Individual online bots are under Bots ->.
   - Raid marker buttons show the actual native Star/Circle/Diamond/Triangle/Moon/Square/Cross/Skull textures.
   - Side panel only marks current target and assigns Priority/CC RTI.
   - Attack Assigned and Pull Assigned are not on the side panel; they remain addable front-page shortcuts through Planner.
6. Summon All remains unchanged and should use one RAID command in raids / PARTY command in parties through Core.

Notes
-----
- Alpha10.3 requires lifecycle-corrected Core 1.6.5 because GO TO now uses Core-owned direct RTSC Move arming for native recipient sets.
- Planner is intentionally a pre-fight surface. Combat Control remains the in-combat reaction surface.


0.1.0-alpha10.2 hotfix
- Fixes ResetButtons crash caused by sparse ordinary-button pool when secure RTSC cells reserve grid positions.
- Planner, Combat mode switching, and front-page shortcut removal now reset only actually allocated buttons.


LIFECYCLE MAINTENANCE (alpha10.1)
- Framework-only cleanup; no CommandPanel gameplay/workflow semantics intentionally changed.
- Defaults register in ElvUI P before E:Initialize; runtime DB/UI binds only after E.data/E.db exist.
- Runtime startup uses LibElvUIPlugin-1.0:HookInitialize with a late/manual-load fast path.
- Options register only through LibElvUIPlugin:RegisterPlugin; ElvUI_OptionsUI is never depended on or force-loaded.
- ElvUI profile change/copy/reset callbacks rebind CommandPanel to the active E.db profile and refresh presentation.
- Legacy inherited-template audit: all UIDropDownMenuTemplate frames and the InputBoxTemplate edit box are explicitly named; secure RTSC buttons are explicitly named.
- Alpha10 sparse button-pool ResetButtons fix is preserved.

0.1.0-alpha10.2 compatibility rebase
- Targets the promoted lifecycle-corrected Core branch.
- Requires Core 1.6.4, which is lifecycle-corrected 1.6.0 plus CommandPanel tactical transport extensions.
- Prevents missing tactical Core extensions from leaving CP.API nil and falsely reporting "No bots resolve" for every recipient.


0.1.0-alpha10.3 Go To reliability
- Native All/role/raid-group Go To uses Core 1.6.5 direct Stay + rtsc move arming; no scratch slot.
- Arbitrary exact multi-bot sets retain slot 9 fallback with generation-safe delayed cleanup.
- Presence/reconnect cleanup cannot clear slot 9 during an active exact-set placement.


0.1.0-alpha10.4 Front-page rendering/data hotfix
- Front page is normalized to an explicit dense eight-slot list on profile/preset load.
- Adding a shortcut finds the first empty slot explicitly; it no longer relies on Lua 5.1 # semantics.
- Semantic shortcut data is stored separately from display labels, preventing repeated recipient/action prefixes.
- RTSC secure covers are hidden on non-placement cells instead of being shown across the whole grid.
- Visually disabled ordinary cells remain mouse-blocking no-op cells so stale secure buttons underneath cannot receive clicks.
- Core 1.6.5 remains the required Core baseline; no Core changes in this hotfix.
