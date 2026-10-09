# Alpha 1.5 inventory semantic live test

Install matching Alpha 1.5 builds of `ElvUI_Multibot_Core` and `ElvUI_Multibot_Test`.

With Stabby present and the bridge ready:

```text
/mbtest all Stabby
```

The existing Alpha 1.4 target/tactical tests should still pass. After the shared inventory read completes, Alpha 1.5 should print a line similar to:

```text
PASS inventory API: revision=... stacks=... quantity=... unique=... bag=.../... free=... layout=FLAT physical=false links=... metadata=.../... equipCandidates=... sampleItem=... sampleTotal=... nativePreflight=true semanticUse=SEMANTIC_ACTION_NOT_IMPLEMENTED
```

Key expectations:

- `links` should normally equal the number of observed stacks because the bridge client sends Playerbots item hyperlinks.
- `layout=FLAT` and `physical=false` are expected with the current reference protocol.
- `nativePreflight=true` performs validation only; it does **not** deposit anything.
- `semanticUse=SEMANTIC_ACTION_NOT_IMPLEMENTED` is intentional in this read-first build.
- inventory-dependent context action should become enabled after the shared inventory commit.

Individual command:

```text
/mbtest inventory Stabby
```

No command in this plan mutates inventory.
