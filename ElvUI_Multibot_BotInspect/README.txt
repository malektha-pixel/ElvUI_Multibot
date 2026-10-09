ElvUI_Multibot_BotInspect 0.3.0-alpha2.2.8

Target
- World of Warcraft WotLK 3.3.5a (Interface 30300)
- ElvUI 6.09
- ElvUI_Multibot_lifecycle-corrected Core 1.6.4.2+ (required for new quest NPC semantics)

Required dependencies
- ElvUI
- ElvUI_Multibot_Core

Overview
BotInspect is the ElvUI Multibot inspection/management frontend. The main window has three top-level views:

1. Gear & Inventory
   - paper-doll equipment
   - physical inventory
   - default item actions and item context menu
   - drag/drop exact physical bag-slot moves and occupied-slot swaps through Core ITEM.MOVE
   - live data with retained read-only fallback

2. Spellbook
   - searchable highest-rank spellbook
   - retained LastKnown spellbook display while offline
   - manual bot-spell cast through Core
   - autonomous-use state shown as ALLOWED / DISABLED from Playerbots' ignored-spell list
   - autonomous-use enable/disable mutations still routed through Core
   - drag bot spells to ordinary Blizzard/ElvUI bars through Core's stable macro contract

3. Quests
   - selected-bot structured quest log with In Progress / Complete filters, search and level/name metadata
   - explicit Refresh Log reads BOT.QUESTS and then Core's on-demand BOT.QUEST_METADATA (`quests all`)
   - Abandon... with user confirmation; Core's existing quest action verifies quest removal
   - Accept Nearby sends exactly one Core-whitelisted `accept *` to one online bot, with a selected friendly NPC target
   - Talk / Turn In... sends Core-whitelisted `talk` after warning/confirmation; may automatically turn in quests and choose rewards
   - commands are reported sent/unverified, not assumed successful
   - no offline quest-history claim; no full-roster quest polling

0.3.0-alpha2.2.8 changes
- Adds a profile-backed BotInspect shortcut, enabled by default as Shift+C.
- The shortcut is configured in ElvUI -> Multibot BotInspect -> Appearance with an enable toggle and keybinding capture control.
- Uses WoW override bindings rather than rewriting saved account/character key bindings; disabling the feature releases the shortcut immediately.
- Plain C remains the normal Character panel with the default Shift+C configuration.
- Binding changes requested during combat are safely deferred until PLAYER_REGEN_ENABLED.
- Core is unchanged; all quest, preset, inventory, Spellbook, Master Loot and Micro Bar behavior is retained.

0.3.0-alpha2.2.7 changes
- Adds third Quests view and Core-mediated ContextMenu contributions: Open Quest Log, Accept Nearby Quests, Talk / Turn In to Target...
- Requires Core 1.6.4.2 for whitelisted, guarded one-bot NPC actions; the ContextMenu addon itself does not require modification.
- Existing 0.3.0-alpha2.2.5 named summon presets are unchanged.

0.3.0-alpha2.2.5 changes
- Adds profile-backed named summon presets to the Bot Roster for fast leveling-party recall.
- Save Group captures the Playerbots currently in your party/raid; saving with an existing name updates that preset. Empty presets can also be created and filled manually.
- Select an active preset from the roster toolbar. Ctrl+Left-click roster rows adds/removes bots; active-preset members get a green roster border.
- Preset actions support Rename, Replace with current group, Clear members and Delete.
- Summon connects offline managed members through Core in the same paced two-at-a-time style as Connect All, then sends the existing Playerbots `summon` feature-coverage whisper as each bot becomes online. Already-online members are summoned immediately.
- `/mbinspect preset <name>` selects and summons a saved preset.
- Existing 0.3.0-alpha2.2.4 Spellbook ignored-list readback, native Master Loot item comparison, inventory ITEM.MOVE drag/drop and Micro Bar behavior are retained.

Existing behavior retained
- Managed Roster + live registry union and bounded target resolving.
- Core-managed Forget for stale/deleted offline identities.
- Virtualized roster; role/spec/Playerbot Gear Score cards; named summon presets for party/raid compositions.
- Paced Connect All / Disconnect All with background inspection suspended during bulk lifecycle work.
- Gear/Inventory historical fallback + bounded retry controller.
- Inventory default left-click None/Sell/Give/Destroy; normal RMB Equip; Shift+RMB action menu.
- ElvUI 6.09 master-loot enrichment: class colors, Spec · Role · GS, equipment comparison and Send to self.
- Spellbook cast and drag-to-action-bar macros.
- Corrected ElvUI 6.09 lifecycle/profile handling and named legacy templates.
- Optional ElvUI 6.09 Micro Bar launcher/capacity integration.
- ESC closes BotInspect.

Reliability/performance boundaries
- BotInspect contains zero runtime interest in BOT.TALENT_SPECS / BOT.TALENTS.
- Spell ignored-list readback is selected-bot/on-entry only; there is no polling or full-raid query.
- Inventory drag/drop uses Core source+destination stale guards and waits for authoritative invalidation/refresh.
- Master-loot comparison uses the bot's already-observed equipment itemLink(s) and native local item tooltips only; hovering causes no bot/bridge refresh traffic.

Architecture boundaries
- Core owns authoritative bot data, history, identity and semantic mutations/actions.
- BotInspect owns presentation/workflow, legacy macro creation/PickupMacro, the existing direct Summon feature-coverage path, and the narrow on-demand `ss ?` ignored-list query because Core does not currently expose that readback.
- BotInspect sends no raw bridge packets.
- ElvUI_Multibot_ContextMenu remains optional and is not a dependency.

Quest limitations: no objective progress counts; nearby quest acceptance can use multiple nearby questgivers; talk may automatically select rewards; live behavior depends on mod-playerbots and client/server NPC interaction range.

0.3.0-alpha2.2.7 changes
- Quest names now prefer the player's native quest-log title for matching quest IDs, then cleaner Questie/exact-link metadata before falling back to the bridge title. This avoids displaying transport/encoding replacement '?' characters without blindly stripping legitimate punctuation.
- Quest rows are grouped under vanilla-style category headers when the selected bot's quest is also known in the player's native quest log. Observed questID -> header mappings stay cached for the session after the player turns a quest in.
- If Questie is installed and exposes its public database helpers, BotInspect can use its zoneOrSort metadata as an optional fallback for bot-only quests. Questie is not a dependency.
- Unresolved bot-only quests are grouped under Other / Unknown instead of guessed into a zone.
- Category headers can be clicked to collapse/expand their quests.
