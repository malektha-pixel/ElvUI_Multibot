# Alpha 1.7.2 Item Action Runtime Test

1. Run `/mbtest all Stabby` and confirm the normal non-mutating suite passes. There is intentionally no equipment-readback test.
2. `ITEM.EQUIP` remains an explicit mutation test: `/mbtest itemexec Stabby EQUIP <itemId>`. A successful send is expected to finish `SENT_UNVERIFIED`; this is not a failure.
3. `ITEM.USE` is best-effort because Playerbots/server logic may silently veto contextually invalid requests. Use an item known to be currently usable. If bridge inventory proves a count decrease, the transaction may upgrade to `CONFIRMED`; otherwise it remains `SENT_UNVERIFIED`.
4. `ITEM.GIVE` remains runtime-validated: Core initiates trade, suppresses the automatic trade inventory dump, sends `give <clientLink>`, and leaves acceptance/cancellation to the user.
5. Do not expose equipped-state UI from this Core until an authoritative/proven readback source exists.
