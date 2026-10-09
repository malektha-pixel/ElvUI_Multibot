# Bridge protocol mapping used by ElvUI_Multibot_Core Alpha 1

Reference: the uploaded bridge developer client (`MultiBot`, `Core/MultiBotComm.lua`).

## Transport

- Prefix: `MBOT`
- Client protocol version: `1`
- Field separator: `~`
- Encoded field characters: `%`, `~`, CR, LF as `%XX`
- Channel selection matches the reference client: RAID, else PARTY, else WHISPER to self.

## Handshake/control

```text
HELLO~1
HELLO_ACK~<protocol>~<server>
PING~<token>
PONG~<token>
CAPS~<comma-separated capabilities>
```

`CAPS` may be sent more than once during one handshake/bootstrap on current bridge builds. Each packet contributes to the negotiated capability set for that bridge session; the set is cleared only when the Core resets the bridge session.

Known reference capabilities:

```text
STATE_FRAMING_V1
STRATEGY_MUTATION_V1
```

The Core stores unknown capability strings too.

## GET families implemented

```text
ROSTER
STATE / STATES
DETAIL / DETAILS
STATS
PVP_STATS
WEAPON_ENCHANT
TALENT_SPEC_LIST
FORMATIONS
OUTFITS
TRAINER
GLYPHS
QUESTS
GAMEOBJECTS
INVENTORY
BANK
GBANK
SPELLBOOK
BOT_SKILLS
BOT_REPUTATIONS
BOT_EMBLEMS
PROFESSION_RECIPES
```

`PROFESSION` / `PROFESSIONS` are response surfaces associated with the bridge detail refresh path.

## RUN families implemented

```text
RTI
COMBAT
STRATEGY
LOOT
POSITION
FORMATION
OUTFIT
TRAINER_LEARN
CRAFT_RECIPE
ITEM_ACTION
TALENT_SPEC_APPLY
```

## Response opcodes

Alpha 1 has explicit handlers for every opcode handled by the uploaded reference client's `HandleAddonMessage`, including:

```text
HELLO_ACK PONG CAPS ROSTER
STATE STATES STATE_BEGIN STATE_ITEM STATE_END STATE_ABORT STATES_BEGIN STATES_END
DETAIL DETAILS PROFESSION PROFESSIONS STATS PVP_STATS WEAPON_ENCHANT
TALENT_SPEC_BEGIN TALENT_SPEC_CURRENT TALENT_SPEC_ITEM TALENT_SPEC_END
GLYPHS_BEGIN GLYPHS_ITEM GLYPHS GLYPHS_END
QUESTS_BEGIN QUESTS_ITEM QUESTS_END QUESTS_DONE
GAMEOBJECTS_BEGIN GAMEOBJECTS_ITEM GAMEOBJECTS_END GAMEOBJECTS_DONE
INV_BEGIN INV_SUMMARY INV_ITEM INV_END
BANK_BEGIN BANK_ITEM BANK_ERROR BANK_END
GBANK_BEGIN GBANK_ITEM GBANK_ERROR GBANK_RIGHTS GBANK_END
SB_BEGIN SB_ITEM SB_END
BOT_SKILLS_BEGIN BOT_SKILLS_ITEM BOT_SKILLS_END
BOT_REPUTATIONS_BEGIN BOT_REPUTATION_ITEM BOT_REPUTATIONS_END
BOT_EMBLEMS_BEGIN BOT_EMBLEM_ITEM BOT_EMBLEMS_MONEY BOT_EMBLEMS_END
PROFESSION_RECIPES_BEGIN PROFESSION_RECIPES_ITEM PROFESSION_RECIPES_END
OUTFITS_BEGIN OUTFITS_ITEM OUTFITS_END OUTFITS_CMD
TRAINER_BEGIN TRAINER_ITEM TRAINER_ERROR TRAINER_END TRAINER_LEARN
PROFESSION_RECIPE_CRAFT INVENTORY_ITEM_ACTION TALENT_SPEC_APPLY_RESULT
FORMATIONS_BEGIN FORMATIONS_ITEM FORMATIONS_END FORMATION_ACK
STRATEGY_ACK RTI_ACK COMBAT_ACK POSITION_ACK LOOT_ACK
ERR
```

## State framing protections

The Core preserves the important reference-client guards:

- request tokens;
- complete-frame commit only;
- per-bot request ordering so an older global reply cannot overwrite a newer targeted reply;
- max 32 active state bot frames;
- max 128 bots in a global state response;
- max 256 strategies per state scope;
- max 192 bytes per strategy;
- max 32768 strategy payload bytes per bot frame.

## Inventory location extension probe

The reference roadmap names these future/audit surfaces but the reference client does not define their payload:

```text
INV_BAG
INV_ITEM_LOC
INV_EQUIP_LOC
```

If received, Alpha 1 records them in `observedProtocolExtensions` and emits `MB_PROTOCOL_EXTENSION_OBSERVED`. It does not interpret their payload until there is authoritative protocol evidence.


## Alpha 1.11 exact inventory / native item subset

Capability negotiation is framed as `CAPS_BEGIN`, one or more `CAPS`, `CAPS_END`. Capabilities are not considered resolved until `CAPS_END`.

Exact inventory request: `GET~INVENTORY_EXACT~<bot>~<token>`. Response frames: `INV_EXACT_BEGIN`, `INV_BAG~bot~token~kind~bag~slotStart~slotCount~bagItemId`, `INV_ITEM_LOC~bot~token~bag~slot~itemId~count~soulbound`, optional `INV_EXACT_ERROR`, then `INV_EXACT_END`.

Native item runs use `RUN~ITEM_<ACTION>~<bot>~<token>~<srcBag>~<srcSlot>~<srcItemId>~<srcCount>` for EQUIP/USE/SELL/DESTROY/TRADE. Their response opcodes are `INVENTORY_ITEM_EQUIP`, `INVENTORY_ITEM_USE`, `INVENTORY_ITEM_SELL`, `INVENTORY_ITEM_DESTROY`, and `INVENTORY_ITEM_TRADE`. Alpha 1.11 validates token correlation plus returned source identity before completing a transaction.


### Alpha 1.12 structured writes

- `RUN~ITEM_MOVE~bot~token~srcBag~srcSlot~srcItemId~srcCount~dstBag~dstSlot~dstItemId~dstCount` -> `INVENTORY_ITEM_MOVE~bot~token~status~reason~srcBag~srcSlot~dstBag~dstSlot`
- `RUN~ITEM_UNEQUIP~bot~token~serverSlot0~itemId` -> `INVENTORY_ITEM_UNEQUIP~bot~token~status~reason~serverSlot0~itemId`
- `RUN~ITEM_DEPOSIT_EXACT~bot~token~BANK_DEPOSIT|GBANK_DEPOSIT~srcBag~srcSlot~itemId~srcCount` -> `ITEM_DEPOSIT_EXACT~bot~token~status~reason~action~srcBag~srcSlot~itemId~srcCount~movedCount`

## Alpha 1.13 protocol additions

Buyback list: `GET~BUYBACK~<bot>~<token>` followed by `BUYBACK_BEGIN`, zero or more `BUYBACK_ITEM`, and `BUYBACK_END`. Slots are restricted to server vendor buyback slots 74..85.

Buyback mutation: `RUN~BUYBACK_ITEM~<bot>~<token>~<slot>~<itemId>~<count>~<price>` with `BUYBACK_RESULT~<bot>~<token>~<OK|ERR>~<reason>~<slot>~<itemId>~<count>~<price>`.

The bridge protocol advertises `INVENTORY_OPEN_V1` / `OPEN_ITEMS`, but Alpha 1.13.3 intentionally does not expose or dispatch that mutation. Live tests showed the server can apply it without a structured success frame, and autonomous Playerbots inventory/gear changes make client-side postcondition inference unsafe. Raw capability diagnostics may still show `INVENTORY_OPEN_V1`. Bulk sell remains in the existing `ITEM_ACTION` family with `SELL_GREY` and `SELL_VENDOR`, each using `itemId=0,count=0`.


## Alpha 1.14 Alt roster / lifecycle protocol

The uploaded current MultiBot client is used only as the protocol-reference authority. `ElvUI_Multibot_Core` implements these packets independently and does not call `MultiBot.Comm`.

```text
GET~ALT_ROSTER
ALT_ROSTER_BEGIN~<count 0..128>~<truncated 0|1>
ALT_ROSTER_ENTRY~<guid>~<encodedName>~<classId>~<level>~<ONLINE|OFFLINE>
ALT_ROSTER_END~<count>~<truncated>

GET~BOT_TARGET_RESOLVE~<encodedName>~<token>
BOT_TARGET_RESOLVE~<token>~<OK|ERR>~<reason>~<canonicalName>~<guid>~<ONLINE|CONNECTING|OFFLINE|UNKNOWN>

RUN~BOT_CONNECT~<guid>~<token>
RUN~BOT_DISCONNECT~<guid>~<token>
BOT_LIFECYCLE~<token>~<guid>~<encodedName>~<CONNECT|DISCONNECT>~<OK|PENDING|ERR>~<reason>

GET~BOT_LIFECYCLE_STATE~<guid>~<token>
BOT_LIFECYCLE_STATE~<token>~<guid>~<encodedName>~<ONLINE|CONNECTING|OFFLINE>~<reason>
```

The lifecycle client window is 12 seconds total and polling starts only after `PENDING`, at one-second intervals. A poll-level `ERR ... BOT_LIFECYCLE_STATE ... RATE_LIMIT` is non-terminal. `ALT_ROSTER` is framed but un-tokenized, therefore Core avoids overlapping startup requests and performs a single deduplicated discovery read after capability resolution.

Alpha 1.14 treats `ALT.ROSTER` membership as the lifecycle authorization boundary. `BOT_TARGET_RESOLVE_V1` can resolve other bridge-authorized names for read-only identity purposes, but it does not widen the Alpha 1.14 mutation surface. Account linking is not implemented.
## Core 1.5 talent protocol

Current bridge `TALENT_SPEC_LIST` framing may include `TALENT_SPEC_CURRENT` between BEGIN and ITEM rows. Core preserves active slot and three tree-point totals but remains compatible with responses that omit CURRENT.

The premade mutation wire contract used by Core is `RUN TALENT_SPEC_APPLY~token~encodedBot~slot~specIndex`. Core correlates the resulting `TALENT_SPEC_APPLY_RESULT~token~encodedBot~status~reason~slot~specIndex~tree0~tree1~tree2` before confirming the transaction. Arbitrary custom `TALENT_APPLY` is not exposed to subscribers.

