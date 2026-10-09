# Quest Semantic Service — Alpha 1.10

## Two-source model

`BOT.QUESTS` remains the authoritative bridge snapshot for which quests the bot currently has and whether each quest is incomplete/completed. The installed server may return numeric placeholder names even though the protocol has a name field.

`BOT.QUEST_METADATA` is an optional, on-demand Playerbots chat enrichment source. Core sends one private `quests all` query, captures the exact raw `Hquest` links/names/quest-level fields, commits one shared metadata snapshot, and suppresses the presentation noise. Concurrent consumers share the same in-flight metadata read through the normal DataBroker.

Metadata never creates/removes quests and never overrides bridge status. `GetQuestView()` merges metadata only onto quest IDs that are present in the current `BOT.QUESTS` snapshot.

## Read APIs

- `GetQuestView(bot)` — authoritative quest membership/status with optional merged metadata.
- `GetQuestMetadata(bot)` — cached `BOT.QUEST_METADATA` snapshot/meta.
- `RefreshQuestMetadata(bot, callback, options)` — request one shared metadata hydration.
- `FindQuests(bot, query)`
- `ResolveQuest(bot, selector)`
- `GetQuestCapabilities(bot)`

Consumers may also use the generic data API with `BOT.QUEST_METADATA` (`Acquire`, `Get`, `Refresh`, `Subscribe`).

An enriched quest record may contain:

```lua
{
    questId = 226,
    status = "I",                 -- authoritative from BOT.QUESTS
    name = "Wolves at Our Heels",
    nameSource = "PLAYERBOTS_QUESTS_ALL",
    exactLink = "|c...|Hquest:226:10|h[Wolves at Our Heels]|h|r",
    linkSource = "PLAYERBOTS_QUESTS_ALL",
    questLevel = 10,
}
```

If metadata has not been hydrated, the view remains valid and may use the bridge name or quest ID fallback.

## Abandon workflow

The runtime-validated Alpha 1.8 abandonment behavior is unchanged:

1. Consumer asks Core for `ABANDON` availability and supplies explicit confirmation.
2. Core verifies the quest is present in fresh `BOT.QUESTS`.
3. Core privately whispers `quests all`; presentation noise is suppressed.
4. Core captures the exact raw `Hquest` hyperlink emitted by that same bot, including the server-provided quest-level field.
5. Core sends `drop <exact link>` exactly once.
6. `Quest removed` feedback may be correlated but is not authoritative.
7. Core refreshes `BOT.QUESTS`; absence of the quest confirms the transaction.

No synthetic quest links and no destructive automatic retries are allowed. A metadata hydration and an abandon link probe cannot run concurrently for the same bot; Core returns `QUEST_CHAT_BUSY` rather than ambiguously correlating whispers.

## Accept/share workflow

`QUEST.ACCEPT_LINK` models a target-scoped request using an exact caller-supplied WoW quest hyperlink. The Core never manufactures an acceptance link.

The current upstream Playerbots chat `accept <quest>` action may execute silently. Therefore chat feedback is no longer the sole authority. Core freezes the resolved bot set and first refreshes `BOT.QUESTS` for every target:

- if the quest is already present, Core resolves `ALREADY_ON` (or `ALREADY_COMPLETED` when the in-log status is complete) with `BRIDGE_QUEST_PRESENT_BEFORE_SEND` and does not send a redundant whisper;
- if the quest is absent, Core whispers `accept <exact quest hyperlink>` exactly once to that bot;
- after a send from a proven-absent baseline, bounded `BOT.QUESTS` refreshes can prove `ACCEPTED` when the quest appears, using `BRIDGE_QUEST_APPEARED_AFTER_SEND`;
- if the quest remains absent and no recognized Playerbots feedback arrives, Core reports `NO_RESPONSE` / unverified rather than guessing why the bot did not accept.

Recognized Playerbots responses remain useful supplemental evidence. The normalized per-bot outcomes remain `ACCEPTED`, `ALREADY_ON`, `ALREADY_COMPLETED`, `CANNOT_ACCEPT`, and `NO_RESPONSE`. A confirmed transaction can now be supported by Playerbots feedback, structured bridge quest state, or a mixture of the two.

No accept mutation is retried automatically. Quest metadata hydration, abandonment link probing, and acceptance workflows still cannot overlap for the same bot (`QUEST_CHAT_BUSY`).
