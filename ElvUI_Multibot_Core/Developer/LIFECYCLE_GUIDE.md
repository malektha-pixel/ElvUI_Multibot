# Altbot lifecycle guide — Alpha 1.14

Alpha 1.14 makes account Altbots a first-class backend identity/lifecycle surface. The UI/module contract is deliberately semantic: modules ask Core for the Alt roster and request CONNECT/DISCONNECT; they do not send bridge packets, store their own GUID authority, or poll lifecycle state themselves.

## State authorities

`ALT.ROSTER` is the durable lifecycle authority. It can contain authorized Altbots that are not currently in the world. Existing `BRIDGE.ROSTER`/party identity remains a different concept and must not be treated as equivalent to Altbot online state.

While a lifecycle transaction is pending, the registry may expose transient `CONNECTING`/`DISCONNECTING`. `GetAltRosterView()` publishes that as `effectiveState` without rewriting the durable cached roster snapshot. Final bridge convergence triggers fresh roster reads.

## Safe mutation flow

1. Refresh/read `ALT.ROSTER`.
2. Call `GetBotLifecycleAvailability(bot, action)`.
3. If enabled, call `ExecuteBotLifecycle(module, bot, action, callback)`.
4. Core freezes the authoritative GUID and sends exactly one RUN packet.
5. If bridge returns `PENDING`, Core polls state once per second.
6. Final `ONLINE` for CONNECT or `OFFLINE` for DISCONNECT confirms.
7. Core refreshes durable authorities.

Never retry an `AMBIGUOUS` lifecycle transaction automatically. Refresh `ALT.ROSTER`/target state first and let a user or higher-level workflow make the next decision.

## Authorization boundary

Alpha 1.14 only mutates entries present in `ALT.ROSTER`. Account linking is prohibited. Resolver support is not permission to control arbitrary guild/friend characters.

## Alpha 1.16 linked/trusted targets

`ALT.ROSTER` is not a complete enumeration source for server-authorized linked/trusted-account characters. A live characterization showed a linked character (`Finn`, GUID 8069) absent from `ALT.ROSTER` while `BOT_TARGET_RESOLVE_V1` returned `OK`/`OFFLINE`.

Preferred module flow is therefore `RequestBotLifecycle`:

- current account Altbot: fresh deduplicated `ALT.ROSTER` -> GUID lifecycle action;
- other managed candidate: fresh `BOT_TARGET_RESOLVE` -> validate canonical name/GUID/state -> GUID lifecycle action.

A successful target resolve creates only a short current-session execution proof. Persisted identity, snapshots, guild membership, and old resolves never authorize a later lifecycle mutation.
