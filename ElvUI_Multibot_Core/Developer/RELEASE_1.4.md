# ElvUI_Multibot_Core 1.4.0

Core 1.4.0 is an additive managed-identity cleanup release requested by `ElvUI_Multibot_BotInspect`. API version remains 1.

## Public API

- `API:GetForgetManagedBotAvailability(botRef)`
- `API:ForgetManagedBot(originModule, botRef, options, callback)`

Forget resolves an existing persisted managed identity to its stable GUID before destructive work. A name-only request is refused with `AMBIGUOUS_IDENTITY` when the current session knows the same name with a different GUID.

## Safety policy

Forget is refused with `BOT_ONLINE` when the same GUID is currently online/connecting/disconnecting. It is also refused with `SNAPSHOT_BUSY` or `GROUP_MEMBER_BUSY` when deleting persistence would race an active Core operation.

## Successful cleanup

A confirmed forget removes only state associated with that GUID from:

- `ElvUI_Multibot_ManagedDB` identity and name index;
- `ElvUI_Multibot_LastKnownDB`;
- `ElvUI_Multibot_SnapshotsDB` and its name index;
- membership in every group in `ElvUI_Multibot_GroupsDB`;
- current-session managed authorization for that GUID.

The live bot registry is not deleted or reinterpreted. Only the session markers projected from persistent Managed Roster state are cleared. No server command is sent. Rediscovery remains allowed through the normal existing discovery paths.

## Events

Successful forget emits `MB_MANAGED_BOT_FORGOTTEN`. Each affected Managed Group also emits existing `MB_MANAGED_GROUP_UPDATED` with reason `MEMBER_FORGOTTEN`.
