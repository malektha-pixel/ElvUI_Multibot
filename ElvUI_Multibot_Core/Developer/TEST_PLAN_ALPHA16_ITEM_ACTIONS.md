# Alpha 1.6 semantic item-action live test

Install matching Alpha 1.6 builds of `ElvUI_Multibot_Core` and `ElvUI_Multibot_Test`.

## 1. Non-mutating regression

Run:

```text
/mbtest all Stabby
```

The inventory line should report semantic action preflight similar to:

```text
use=true equip=true destroy=CONFIRMATION_REQUIRED/true sell=MERCHANT_CONTEXT_REQUIRED give=READY_CORE_TRADE
```

This test sends no item command.

## 2. Safest live semantic action: GIVE into an open trade

Choose an unimportant carried item with a unique item ID. Start a normal trade with the bot so the WoW trade frame is open, then run:

```text
/mbtest itemexec Stabby GIVE <itemId>
```

Expected Core result: transaction reaches `SENT_UNVERIFIED` and Playerbots places the selected item into the trade window. **Cancel the trade** rather than accepting it. This validates semantic resolution, exact server-link dispatch, centralized chat transport, and honest unverified transaction state without intentionally transferring the item.

Do not open trade manually. `ITEM.GIVE` should cause the Core to call `InitiateTrade(botName)`, wait for `TRADE_SHOW`, then whisper `give <canonical client hyperlink>`. The user remains responsible for accepting/cancelling the trade.

## 3. Other explicit mutation probes

These are deliberately not part of `/mbtest all`:

```text
/mbtest itemexec Stabby EQUIP <itemId>
/mbtest itemexec Stabby USE <itemId>
/mbtest itemexec Stabby SELL <itemId>
/mbtest itemexec Stabby DESTROY <itemId> CONFIRM
```

`SELL` requires the merchant frame to be open. `DESTROY` requires the literal confirmation word. These chat-backed actions report `SENT_UNVERIFIED`, not `CONFIRMED`; inventory invalidation/refresh supplies authoritative post-action state.

## Variant safety

Semantic chat actions use the canonical client hyperlink (bridge/server fallback). If one item ID has multiple distinct server hyperlinks (for example differently enchanted/random-property variants), a bare item ID is refused with `AMBIGUOUS_ITEM_VARIANT`; a frontend should pass the exact item record/server hyperlink instead. Bridge-native bank/vendor actions remain item-ID/count addressed because that is the server endpoint contract.
