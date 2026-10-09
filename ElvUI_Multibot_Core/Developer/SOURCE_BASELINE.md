# Source baseline and fork rules

## Version 1.0 lineage

Version 1.0.0 is a metadata/documentation promotion of the live-validated Alpha 1.17.1 runtime. No Alpha 1.18 talent-mutation code is part of this lineage. Talent mutation remains unsupported/deferred.

## Protocol authority

The uploaded `Multibot.zip` is the bridge developer's intended **client-side interface** for the installed server Multibot bridge. Alpha 1 uses its `Core/MultiBotComm.lua` behavior as the wire-protocol reference.

The Core is a new implementation; MultiBot's gameplay UI is not copied into this project.

## What is intentionally learned from the older ElvUI PlayerBots Core fork

Architectural lessons retained:

- one authoritative Core-owned cache;
- equivalent read request deduplication;
- complete transaction commits rather than partial packet state;
- semantic actions and post-action invalidation;
- static target resolution for a dispatched selection;
- event subscriptions rather than direct module-to-module state sharing;
- ElvUI 6.09 options/diagnostics integration.

The old project's implementation and progression are not treated as the implementation baseline for this fork.

## New fork-specific foundations

- project/addon namespace: `ElvUI_Multibot_Core`;
- bridge-native data domains are derived from the uploaded developer client;
- generic module/service/context contribution registry is built into API v1;
- inventory keeps explicit future physical-location fields while remaining truthfully `FLAT` today;
- unknown location opcodes are observed rather than inferred;
- no gameplay UI lives in Core;
- account link/unlink control is excluded from the addon; server-admin-linked characters may be consumed as authorized managed bots once runtime behavior is validated.


## 2026-09-14 client protocol reference

Alpha 1.11 was cross-checked against the user-supplied current client-side MultiBot 4.0 addon (`Multibot(1).zip`). That addon is a protocol/reference authority only; `ElvUI_Multibot_Core` remains an independent bridge communicator and does not call `MultiBot.Comm` as a transport dependency.

## Version 1.5 structured talent semantics

Core 1.5.0 additively exposes only the bridge-provided premade talent-spec mutation (`TALENT_SPEC_APPLY_V1`) through the Core semantic `TALENT.SPEC_APPLY`. The arbitrary/custom `TALENT_APPLY_V1` mutation remains intentionally unexposed. Subscribers do not construct bridge packets or use Playerbots chat fallbacks for talent switching.
