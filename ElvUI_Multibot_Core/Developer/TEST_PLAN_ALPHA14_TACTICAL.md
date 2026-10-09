# Alpha 1.4 tactical/selection live test

Install matching Alpha 1.4 builds of `ElvUI_Multibot_Core` and `ElvUI_Multibot_Test`, then restart/reload normally.

With a known bot such as Stabby online:

```text
/mbtest all Stabby
```

The new Alpha 1.4 lines should include:

```text
PASS targets: ...
PASS tactical: RTIicons=8 ... RTSCslots=9 macro=/cast aedm ...
PASS context refresh after inventory commit: enabled=true ...
```

The `targets` test temporarily edits `PRIMARY`, creates/edits/deletes a generated saved selection, validates applicable dynamic selectors, and restores the previous `PRIMARY` contents.

The `tactical` test is non-mutating. It performs RTI preview/preflight and RTSC preflight/contract validation only. It does not assign an RTI, move a bot, select RTSC targets, or cast AEDM.

Individual checks:

```text
/mbtest targets Stabby
/mbtest tactical Stabby
/mbcore selections
```

Do not perform live RTI/RTSC mutation testing until these checks pass.
