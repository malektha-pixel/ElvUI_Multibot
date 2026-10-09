# Tactical selection integration guide — Alpha 1.4

This Core deliberately separates **selection state** from whichever frontend edits or renders it.

## Ctrl-click unit-frame pattern

A future ElvUI unit-frame addon should treat `PRIMARY` as the shared transient selection:

```lua
-- When the frontend has already determined that the clicked unit is a Core bot:
API:ToggleSelection("PRIMARY", botName)
```

The frontend should subscribe to `MB_SELECTION_CHANGED` and redraw selection highlights from:

```lua
local selection = API:GetSelection("PRIMARY")
```

Do not keep a second authoritative selected-bot set inside the unit-frame addon.

## Saving and editing groups

Save the current working set:

```lua
API:SaveSelection("Left Flank")
```

Add the current working selection to an existing static group:

```lua
API:AddToSavedSelection("Left Flank", "selected")
```

Other static-group editing APIs:

```lua
API:RemoveFromSavedSelection("Left Flank", "Stabby")
API:ToggleSavedSelectionMember("Left Flank", "Kitten")
```

Dynamic saved selections use a selector instead of manual members:

```lua
API:SaveSelection("Ranged", "rangeddps", { dynamic = true })
```

Dynamic groups intentionally reject manual membership editing.

## Reusing the same target everywhere

All tactical/action services accept the same target concepts:

```text
selected
saved:Left Flank
tank
healer
meleedps
rangeddps
class:MAGE
group:2
explicit bot list
one bot
```

The Core freezes the resolved bot identities when an action is dispatched. Later Ctrl-click changes cannot retarget an in-flight action.

## RTI / CC RTI

Use semantic Core methods rather than constructing `rti` bridge commands:

```lua
API:AssignRTI(MODULE, "saved:Left Flank", "priority", "cross")
API:AssignRTI(MODULE, "healer", "cc", "moon")
API:RunAssignedRTI(MODULE, "saved:Left Flank", "attack")
```

RTI assignments tracked by the Core are session-scoped and represent commands confirmed through the bridge. The reference protocol has no RTI query/readback, so external/manual RTI changes cannot be observed by the Core.

## RTSC world placement

RTSC state/commands belong to the Core, but the actual world click belongs to a secure frontend button.

```lua
local contract = API:GetRTSCPlacementContract()
-- contract.secureType == "macro"
-- contract.macroText == "/cast aedm"
-- contract.slots == 9

API:EnableRTSC(MODULE) -- optional when explicit enable control is useful
API:PrepareRTSCPlacement(MODULE, "selected", 3)
```

`PrepareRTSCPlacement()` enables RTSC/AEDM before applying the frozen selection and optional save slot. The frontend then invokes the secure AEDM action for the user's world click. `CancelRTSC()` is the explicit disable operation. Do not call `SendChatMessage` with `rtsc` commands from the frontend.

RTSC chat transactions are `SENT_UNVERIFIED`: sent successfully is not the same as server-confirmed movement.

## Combat/security note

WoW 3.3.5a secure/protected frame rules still apply to the frontend. Build or change secure button attributes outside combat where required. The Core itself creates no unit-frame or secure-action UI.
