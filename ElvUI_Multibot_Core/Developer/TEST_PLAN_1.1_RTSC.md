# Runtime test plan — 1.1.0 RTSC/AEDM fix

1. Start with RTSC disabled / AEDM absent if practical.
2. Call `API:EnableRTSC(MODULE)` and verify AEDM becomes available. Transaction is expected to finish `SENT_UNVERIFIED`.
3. Call `API:PrepareRTSCPlacement(MODULE, targetSpec, slot)` for a known target set. Verify AEDM remains available after preparation and the next secure `/cast aedm` click can place/save the requested slot.
4. Call `API:SelectRTSCTargets(MODULE, targetSpec)` and verify this no longer removes AEDM.
5. Call `API:CancelRTSC(MODULE)` and verify RTSC is disabled / AEDM removed.
6. Re-run one non-RTSC subscriber/module smoke test to confirm no unrelated behavior changed.

The Core can prove only chat dispatch (`SENT_UNVERIFIED`), not server movement success.
