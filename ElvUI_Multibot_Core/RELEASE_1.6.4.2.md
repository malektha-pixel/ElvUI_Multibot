# ElvUI_Multibot_Core 1.6.4.2 — narrowly scoped questgiver compatibility actions

This build is based on lifecycle-corrected Core **1.6.4.1**, and keeps API v1.

New API endpoints:
- `API:GetQuestNpcActionAvailability(botRef, "ACCEPT_NEARBY"|"TALK_TARGET", options)`
- `API:ExecuteQuestNpcAction(originModule, botRef, kind, options, callback)`

Fixed Core action descriptors:
- `QUEST.ACCEPT_NEARBY`: whisper `accept *` to exactly one online bot. Playerbots can examine nearby questgivers, not only the NPC under the cursor. A selected friendly NPC is required as an intentional user-interaction gate, but is not an exact NPC selection command.
- `QUEST.TALK_TARGET`: whisper `talk` to one online bot, using the player's current friendly NPC target; requires an explicit `confirmed=true` UI confirmation, because Playerbots may automatically turn in completed quests and choose rewards.

Both actions check an actual friendly NPC target (no enemy or player) and bot-online status at preflight, and re-check its exact UnitGUID plus online state immediately before queued whisper dispatch. The chat payload is a hardcoded whitelist; callers cannot inject arbitrary Playerbots chat commands. Outcomes are `SENT_UNVERIFIED` after chat dispatch, not assumed quest success. Operators should manually refresh quest state to confirm actual quest changes.

Existing `BOT.QUESTS`, `BOT.QUEST_METADATA`, confirmed quest abandonment, exact-link acceptance, snapshot policies, spell interfaces, and the 1.6.4.1 talent-spec polling hotfix are unchanged. The bridge, server, ContextMenu addon and ElvUI lifecycle behavior are unchanged.

No new recurring quest or talent polling is introduced. One online bot at a time is intentionally supported for the new NPC actions.
