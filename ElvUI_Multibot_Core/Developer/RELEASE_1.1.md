# ElvUI_Multibot_Core 1.1.0

## Scope

Minor backward-compatible RTSC correction discovered during `ElvUI_Multibot_ContextMenu` development.

- `RTSC.PREPARE` / `RTSC.SELECT` no longer initialize with `rtsc cancel`.
- Bare `rtsc` is now the Core-owned enable step so AEDM remains available for the secure world click.
- Adds semantic `RTSC.ENABLE` and `API:EnableRTSC()`.
- `RTSC.CANCEL` remains the explicit disable path.
- No non-RTSC runtime path or existing public signature changes.
- Public API version remains 1.

## Compatibility

Modules that do not call RTSC APIs/actions or consume the RTSC placement domain require no changes. Existing RTSC callers keep the same signatures; their preparation/selection behavior is corrected. Generic action-registry consumers may observe the new additive `RTSC.ENABLE` descriptor.
