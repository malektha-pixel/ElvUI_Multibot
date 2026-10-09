# Alpha 1.8 Quest / Storage Runtime Test Plan

First run the non-mutating suite:

```text
/mbtest all Stabby
```

Expected: existing tests remain PASS and a quest API line reports structured quest totals plus `abandon=true`, `exactLink=PLAYERBOTS_QUESTS_ALL`, blocked unconfirmed preflight, and successful confirmed preflight. No quest is changed.

List structured quests:

```text
/mbtest questlist Stabby
```

To explicitly test abandonment, choose a disposable quest ID from that list and run:

```text
/mbtest questabandon Stabby <questId> CONFIRM
```

Expected workflow: exact-link probe is hidden from chat by default; transaction progresses to `SENT_UNVERIFIED`; optional `MB_ACTION_FEEDBACK` may report `QUEST_REMOVED`; structured `BOT.QUESTS` refresh proves absence and upgrades transaction to `CONFIRMED` with `proof=BRIDGE_QUEST_ABSENT`. If the exact link is not observed, Core must fail before sending `drop`.

Bank/guild-bank reads remain non-mutating and can be inspected through `BOT.BANK`, `BOT.GUILD_BANK`, `GetBankView`, and `GetGuildBankView`. Do not test destructive/money-moving storage mutations with valuable items.
