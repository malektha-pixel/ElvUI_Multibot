# Built-in actions — ElvUI_Multibot_Core 1.5.0

## Capability surface and deferred mutation families

Raw `/mbcore caps` output is not equivalent to the public Core action surface. Core 1.5 exposes only bridge-provided **premade** talent-spec application as `TALENT.SPEC_APPLY` / `TALENT_SPEC_APPLY_V1`. Arbitrary custom `TALENT_APPLY_V1` remains intentionally unexposed.

These correspond to the `RUN` families exposed by the uploaded bridge reference client.

| Core action | Bridge family | Scope |
|---|---|---|
| `RTI.COMMAND` | `RUN RTI` | ALL / GROUP / BOT |
| `COMBAT.COMMAND` | `RUN COMBAT` | ALL / GROUP / BOT |
| `STRATEGY.MUTATE` | `RUN STRATEGY` | ALL / GROUP / PARTY / RAID / BOT |
| `LOOT.COMMAND` | `RUN LOOT` | ALL / GROUP / BOT |
| `POSITION.COMMAND` | `RUN POSITION` | ALL / GROUP / BOT |
| `FORMATION.SET` | `RUN FORMATION` | GROUP |
| `OUTFIT.COMMAND` | `RUN OUTFIT` | BOT |
| `TRAINER.LEARN` | `RUN TRAINER_LEARN` | BOT |
| `TALENT.SPEC_APPLY` | `RUN TALENT_SPEC_APPLY` | BOT |
| `PROFESSION.CRAFT` | `RUN CRAFT_RECIPE` | BOT |
| `ITEM.ACTION` | `RUN ITEM_ACTION` | BOT |

`ITEM.ACTION` Alpha 1 permits the item actions proven in the reference UI:

```text
BANK_DEPOSIT
BANK_WITHDRAW
GBANK_DEPOSIT
GBANK_WITHDRAW
BUY_ITEM
```


## Core 1.5 premade talent spec action

`TALENT.SPEC_APPLY` is capability-gated by `TALENT_SPEC_APPLY_V1`, single-bot only, and structured-bridge only. Execution always fresh-reads `BOT.TALENT_SPECS`, verifies that the requested `specIndex` exists in that response, and resolves `CURRENT` from the fresh active-slot record before dispatch. The correlated `TALENT_SPEC_APPLY_RESULT` must match target, slot and spec index. No requested build is written to canonical state before confirmation and there is no Playerbots chat fallback.

On confirmation, Core refreshes `BOT.TALENT_SPECS`, `BOT.DETAIL`, `BOT.STATE`, `BOT.SPELLBOOK`, and `BOT.GLYPHS`.

## Transaction rule

The Core does not optimistically write requested values into authoritative data snapshots.

Typical flow:

```text
module request
  -> Core transaction
  -> bridge RUN
  -> ACK/result
  -> CONFIRMED or FAILED
  -> affected domains invalidated
  -> subscribed domains refresh once through Data Broker
```

Timeout of a non-idempotent/best-effort write becomes `AMBIGUOUS`; it is not automatically retried. A session reset also marks any already-sent unresolved write `AMBIGUOUS`, because the server may have applied it before the transport was lost. Unsent/dispatching work becomes `CANCELLED`.

ACK/result packets are correlated with the original transaction before completion. Opcode, scope/target and action-specific identity fields must match. Strategy mutation is `CONFIRMED` only for full success (`matched > 0`, `succeeded == matched`, `failed == 0`); partial/no-match results remain available in `tx.result` but are not treated as confirmed authoritative mutation success.

## Chat transport

Alpha 1 contains an internal bot-whisper transport scaffold for future semantic actions that the bridge cannot perform. It is intentionally not exposed as a public arbitrary-command API. A future chat-backed action must declare its semantics and invalidation behavior in Core before modules can call it.
## Preflight and descriptor metadata

Use `API:GetActionAvailability(actionId, targetSpec, args)` when a frontend needs to decide whether a control should be enabled. It validates bridge readiness, advertised capability requirements, scope, target cardinality, and action-specific arguments without creating a transaction. `API:CanExecute()` is the compact boolean/reason form of the same check.

Built-in descriptors expose `risk` and `verification` metadata in addition to route/family/idempotency/invalidation information. Alpha 1.3 currently uses `verification = BRIDGE_ACK` for the native RUN families.


## Semantic tactical actions

| Core action | Route | Scope | Verification |
|---|---|---|---|
| `RTI.ASSIGN_PRIORITY` | bridge `RUN RTI` | one bot (fan out with `ExecuteSet` / `AssignRTI`) | bridge ACK |
| `RTI.ASSIGN_CC` | bridge `RUN RTI` | one bot (fan out with `ExecuteSet` / `AssignRTI`) | bridge ACK |
| `RTI.ATTACK_ASSIGNED` | bridge `RUN RTI` | one bot (fan out supported) | bridge ACK |
| `RTI.PULL_ASSIGNED` | bridge `RUN RTI` | one bot (fan out supported) | bridge ACK |
| `RTSC.ENABLE` | internal Playerbots group chat | group | `SENT_UNVERIFIED` |
| `RTSC.PREPARE` | internal Playerbots chat | exact bot set | `SENT_UNVERIFIED` |
| `RTSC.SELECT` | internal Playerbots chat | exact bot set | `SENT_UNVERIFIED` |
| `RTSC.GO` | internal Playerbots chat | exact bot set | `SENT_UNVERIFIED` |
| `RTSC.SAVE` | internal Playerbots group chat | group | `SENT_UNVERIFIED` |
| `RTSC.UNSAVE` | internal Playerbots group chat | group | `SENT_UNVERIFIED` |
| `RTSC.CANCEL` | internal Playerbots group chat | group | `SENT_UNVERIFIED` |

Semantic RTI command generation is owned by the Core. Consumers supply a purpose/icon or attack/pull intent rather than bridge command strings.

RTSC arbitrary selections are resolved to exact bot identities before dispatch. `RTSC.ENABLE` sends bare `rtsc` to enable the RTSC/AEDM mode. `RTSC.PREPARE` and `RTSC.SELECT` begin with that enable command rather than `rtsc cancel`, then select the frozen bot set; `RTSC.PREPARE` may additionally arm location 1-9 and returns/exposes the secure AEDM placement contract. `RTSC.CANCEL` is the explicit disable path. The actual world click belongs to a frontend `SecureActionButtonTemplate` using `/cast aedm`.

## Alpha 1.5 inventory action preflight

The low-level bridge-native `ITEM.ACTION` family currently recognizes `BANK_DEPOSIT`, `BANK_WITHDRAW`, `GBANK_DEPOSIT`, `GBANK_WITHDRAW`, and `BUY_ITEM`, addressed by `itemId + count`. Frontends should prefer `API:GetInventoryActionAvailability()` for read-only semantic preflight. Source resolution is action-specific: carried inventory for deposits, personal/guild bank snapshots for withdrawals, and external vendor identity for purchases. Alpha 1.5 does not yet expose semantic USE/EQUIP/SELL/DESTROY/GIVE mutations.


## Alpha 1.6 semantic inventory actions

| Action | Route | Verification | Guard |
|---|---|---|---|
| `ITEM.EQUIP` | Playerbots whisper `e <clientLink>` (server-link fallback) | `BEST_EFFORT_SENT` | exact-link variant safety |
| `ITEM.USE` | Playerbots whisper `u <clientLink>` (server-link fallback) | `BEST_EFFORT_SENT` | exact-link variant safety |
| `ITEM.SELL` | Playerbots whisper `s <clientLink>` (server-link fallback) | `BEST_EFFORT_SENT` | merchant context |
| `ITEM.DESTROY` | Playerbots whisper `destroy <clientLink>` (server-link fallback) | `BEST_EFFORT_SENT` | explicit confirmation |
| `ITEM.GIVE` | Core opens/waits for trade, then whispers `give <clientLink>` (server-link fallback) | `BEST_EFFORT_SENT` | Core-owned trade prerequisite; user accepts/cancels |

The Core invalidates authoritative inventory after sent item mutations where the send itself can change state. `GIVE` does not invalidate on send because the actual transfer occurs only if the trade is accepted.


## Alpha 1.7 item post-verification

`ITEM.EQUIP` is best-effort in the current runtime. No proven equipped-slot readback exists, so a successful send remains `SENT_UNVERIFIED`; modules must not infer equipped state from it.

`ITEM.USE`, `ITEM.SELL`, and `ITEM.DESTROY` use `BRIDGE_INVENTORY_COUNT_POSTCONDITION`: a decrease in authoritative bridge inventory count confirms the requested item was consumed/removed. An item whose use does not alter inventory cannot be proven by this policy and therefore remains `SENT_UNVERIFIED`.



## Alpha 1.11 native semantic item routes

The public semantic action IDs are unchanged, but route selection is now capability-driven and frozen before dispatch. When `INVENTORY_EXACT_V1` and the action capability are negotiated, Core refreshes `BOT.INVENTORY_EXACT`, freezes the physical source tuple, and uses the structured bridge mutation. Otherwise the validated Playerbots hyperlink implementation is a compatibility route selected before dispatch. A sent native mutation is never retried through chat.

| Action | Preferred native capability | Native proof | Compatibility route |
|---|---|---|---|
| `ITEM.EQUIP` | `ITEM_EQUIP_V1` | correlated `OK`, matching source bag/slot, destination equipment slot | `e <link>`; best effort |
| `ITEM.USE` | `ITEM_USE_V1` | correlated `OK`, matching source bag/slot/item | `u <link>` + inventory postcondition when observable |
| `ITEM.SELL` | `ITEM_SELL_SINGLE_V1` | correlated `OK`, matching source, valid `soldCount` | `s <link>` + inventory postcondition |
| `ITEM.DESTROY` | `ITEM_DESTROY_V1` | correlated `OK`, matching source bag/slot/item | `destroy <link>` + inventory postcondition; explicit confirmation still required |
| `ITEM.GIVE` | `ITEM_TRADE_V1` | correlated `OK`, matching source/count, trade slot 0-5 | trade open + `give <link>`; final trade acceptance remains user-controlled |

Native timeouts after send are `AMBIGUOUS`. `SOURCE_STALE` and other bridge errors are returned as failures; Core does not silently refresh and repeat non-idempotent mutations. `ITEM.GIVE` confirmation means the exact stack was placed into a trade slot, **not** that ownership transfer completed.

## Alpha 1.8 semantic quest action

### `QUEST.ABANDON`

- Scope: one bot.
- Route: Core-owned Playerbots whisper workflow.
- Risk: destructive; explicit confirmation required.
- Preconditions: fresh `BOT.QUESTS`, quest ID present in that snapshot.
- Link source: exact raw quest hyperlink captured from the target bot's `quests all` response. Synthetic links are forbidden.
- Mutation: `drop <exact hyperlink>` is sent once and is never automatically retried.
- Feedback: correlated `Quest removed` is diagnostic only.
- Verification: transaction reaches `CONFIRMED` only when structured `BOT.QUESTS` no longer contains the quest ID. Otherwise it remains `SENT_UNVERIFIED`; session loss makes it `AMBIGUOUS`.

Bridge-native inventory actions `BANK_DEPOSIT`, `BANK_WITHDRAW`, `GBANK_DEPOSIT`, `GBANK_WITHDRAW`, and `BUY_ITEM` are exposed through the inventory semantic service. Their transport address is `itemId + count`; no physical bag/slot precision is claimed.

## QUEST.ACCEPT_LINK

- Route: structured `BOT.QUESTS` precheck plus Core chat transport only for unresolved targets.
- Input: exact caller-supplied quest hyperlink.
- Target: any Core target specification; resolved targets are frozen at dispatch.
- Precheck: a fresh structured quest read resolves an already-active quest as `ALREADY_ON` (or in-log `ALREADY_COMPLETED`) without sending a redundant whisper.
- Mutation: only targets where the quest is not present receive `accept <exact hyperlink>`, exactly once.
- Post-verification: if the quest was proven absent before dispatch and appears in a later structured read, Core resolves `ACCEPTED` even when Playerbots emits no chat feedback.
- Result: per-bot `ACCEPTED`, `ALREADY_ON`, `ALREADY_COMPLETED`, `CANNOT_ACCEPT`, or `NO_RESPONSE`.
- `CONFIRMED` may be supported by Playerbots feedback, structured bridge quest state, or both; inspect `result.outcomes` and `completionProof`.
- No synthetic links and no mutation retries.

## Alpha 1.12 Exact Inventory Phase 2

| Action | Capability | Input authority | Result |
|---|---|---|---|
| `ITEM.MOVE` | `INVENTORY_EXACT_V1` + `ITEM_MOVE_V1` | fresh source + destination bag/slot guards | correlated `INVENTORY_ITEM_MOVE` |
| `ITEM.UNEQUIP` | `ITEM_UNEQUIP_V1` | explicit server equipment slot `0..18` + item ID | correlated `INVENTORY_ITEM_UNEQUIP` |
| `BANK_DEPOSIT` / `GBANK_DEPOSIT` full stack | `INVENTORY_EXACT_V1` + `ITEM_DEPOSIT_EXACT_V1` | fresh physical source tuple | correlated `ITEM_DEPOSIT_EXACT`, `movedCount == sourceCount` |

No sent native mutation is retried through another transport.

## Alpha 1.13 inventory/economy actions

| Core semantic | Capability | Wire action | Guard / proof |
|---|---|---|---|
| `OPEN_ITEMS` | `INVENTORY_OPEN_V1` may be advertised | **intentionally unsupported** | no Core dispatch path; preflight returns `INTENTIONALLY_UNSUPPORTED` |
| `SELL_GREY` | `INVENTORY_BULK_SELL_V1` | `ITEM_ACTION ... SELL_GREY 0 0` | current target + structured moved count |
| `SELL_VENDOR` | `INVENTORY_BULK_SELL_V1` | `ITEM_ACTION ... SELL_VENDOR 0 0` | current target + structured moved count |
| `ITEM.BUYBACK` | `VENDOR_BUYBACK_V1` | `BUYBACK_ITEM` | exact buyback slot/item/count/price + correlated `BUYBACK_RESULT` |

These routes are bridge-native only. Core does not invent a Playerbots chat fallback for a sent structured utility action.


## Alpha 1.14 lifecycle actions

| Action | Capability | Addressing | Verification | Timeout |
|---|---|---|---|---|
| `BOT.CONNECT` | `BOT_LIFECYCLE_V1` + `ALT_ROSTER_V1` | authoritative Alt-roster GUID | `BOT_LIFECYCLE` / `BOT_LIFECYCLE_STATE` -> `ONLINE` | 12 s |
| `BOT.DISCONNECT` | `BOT_LIFECYCLE_V1` + `ALT_ROSTER_V1` | authoritative Alt-roster GUID | `BOT_LIFECYCLE` / `BOT_LIFECYCLE_STATE` -> `OFFLINE` | 12 s |

Preflight requires exactly one target, authoritative `ALT.ROSTER` membership, a valid GUID, and the opposite final state (`OFFLINE` for CONNECT, `ONLINE` for DISCONNECT). Per-GUID reservation rejects concurrent lifecycle work with `LIFECYCLE_BUSY`.

A bridge `PENDING` response is not a completion. Core exposes a transient `CONNECTING` or `DISCONNECTING` state and polls `BOT_LIFECYCLE_STATE` once per second. A final converged state confirms. Protocol errors fail before convergence; poll `RATE_LIMIT` is ignored as non-terminal. Because lifecycle mutations are non-idempotent, a sent timeout or session reset is `AMBIGUOUS`; Core never resends or falls back to Playerbots chat.

`BOT_TARGET_RESOLVE_V1` is exposed as a separate read-only resolver and is not a prerequisite for GUID-addressed lifecycle mutation once authoritative Alt-roster identity is available.


## 1.6 spell compatibility semantics

`SPELL.EXCLUSION_SET` is a narrow per-bot chat-backed semantic for the Playerbots `ss +/-<spellId>` feature because the structured bridge does not currently expose it. Results are `SENT_UNVERIFIED` when the chat command was sent; Core does not claim an authoritative state change without readback.

`SPELL.CAST` is a narrow per-bot explicit-cast semantic using `cast <spellId>`. Core validates identity/online state and the learned spellbook where practical, but intentionally leaves target legality, range, line of sight, cooldown, resources and similar gameplay rules to Playerbots/server authority. Exclusion state never blocks an explicit cast client-side.

No generic Playerbots chat passthrough is public. Persistent action-bar macros invoke `/mbcastguid <managedGuid> <spellId>`, which routes back through `CastBotSpell`.
