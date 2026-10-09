# ElvUI Multibot UnitFrames 0.4.0-alpha1 — Quest-log status indicator

This build adds a read-only quest-log occupancy indicator to the existing lifecycle-corrected 0.3.4 baseline.

## New feature

Under **ElvUI -> Multibot UnitFrames -> Status Panel -> Character Stats -> Quest Log**:

- **Show Quest Log** enables the indicator.
- Display format is `Quest: current/max`.
- The maximum uses the WotLK client quest-log capacity (`MAX_QUESTLOG_QUESTS`, falling back to 25).
- **Color by fullness** is enabled by default:
  - near empty: white
  - around half full: yellow
  - near/full: red
  - color changes smoothly between those points
- Font size, anchor, X offset, and Y offset use the same controls as the other Status Panel text elements.

The indicator consumes Core's `BOT.QUESTS` domain and renders `API:GetQuestView(bot).totalCount`. It does not parse Playerbots chat or maintain a separate quest cache.

## Live test

1. Replace the previous UnitFrames addon folder and `/reload`.
2. Confirm existing PB/status/selection behavior is unchanged.
3. Enable **Quest Log** under Character Stats.
4. Confirm each bot displays e.g. `Quest: 8/25`.
5. Accept/turn in/abandon quests on a bot and allow Core's normal quest-state refresh to run; the count should update from Core.
6. Verify low counts are white, mid-range counts yellow, and nearly-full counts red.
7. Change anchor/font/offset settings and `/reload`; settings should persist.
8. Run `/mbuf frames`; each bot now includes a `quest=Quest: n/25/true|false` diagnostic.

No gameplay, selection, lifecycle, or mutation semantics are changed in this release.
