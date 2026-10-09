# ElvUI_Multibot_Core 1.6.4

Lifecycle-corrected Core 1.6.0 plus the previously validated CommandPanel tactical transport extensions.

This build deliberately preserves the corrected ElvUI 6.09 lifecycle/profile integration from the promoted 1.6.0 baseline. It does not restore the obsolete 1.6.1-1.6.3 lifecycle code.

Added public API v1-compatible services:
- `API:OrderBots(originModule, targetSpec, order, callback)` for whitelisted FOLLOW/STAY/FLEE/RESET/SUMMON orders.
- `API:ArmRTSCLocationImmediate(originModule, slot, clearFirst)` for race-free secure AEDM placement arming.

Transport behavior restored from the CommandPanel branch:
- RAID/PARTY group-call dispatch when an exact native Playerbots selector matches the frozen set.
- fast exact-bot bursts for tactical orders and RTSC Go when a native selector cannot represent the frozen set.
- RTSC Go batching for all/tank/healer/dps/ranged/rangeddps/meleedps/group:N exact sets.

No ElvUI lifecycle/profile/bootstrap code was taken from the obsolete 1.6.3 branch.
