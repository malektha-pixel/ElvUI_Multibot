# Alpha 1.10.3 — Quest Accept/Share Compatibility Test Plan

1. Install matching Core/Test builds and run `/mbtest all Stabby`; it must remain non-mutating and report `acceptLink=true` in the quest API line.
2. Obtain an exact quest hyperlink. The Core never synthesizes one.
3. Already-active safe test: `/mbtest questaccept Stabby <QuestLink>` using a quest known to be in Stabby's structured `BOT.QUESTS`. Core should refresh `BOT.QUESTS`, resolve `ALREADY_ON` (or `ALREADY_COMPLETED` for an in-log complete quest), and finish `CONFIRMED` without sending a redundant `accept` whisper. Expected proof: `BRIDGE_QUEST_STATE`.
4. Acceptance transition test: use a quest link that is absent from the target bot before dispatch but currently acceptable from the relevant quest giver. Core should precheck absence, send `accept <exact link>` once, and then refresh `BOT.QUESTS`. If the quest appears, the outcome is `ACCEPTED` with `presenceVerified=true` and proof `BRIDGE_QUEST_APPEARED_AFTER_SEND`, even if Playerbots sends no chat reply.
5. Current upstream Playerbots can be silent for the chat accept action. Recognized feedback is still correlated when present, including legacy outcomes and current strings such as `Quest accepted`, `I have this quest`, and `I can't take this quest`.
6. Multi-target tests freeze the resolved Core target set. Bots already carrying the quest are resolved from structured state; only unresolved bots receive the whisper.
7. No mutation retry is allowed. If a quest was absent before dispatch and remains absent after bounded verification with no recognized feedback, the target remains `NO_RESPONSE` and the transaction stays unverified.
