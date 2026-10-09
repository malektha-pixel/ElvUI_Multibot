# Alpha 1.16 live test

1. `/mbcore status`
2. `/mbtest managed`
3. `/mbtest managed Finn` - Finn should persist as known from the earlier successful resolve, if the SavedVariables record was created after installing 1.16; otherwise run `/mbtest resolve Finn` once and repeat.
4. `/mbtest lifecycle Finn CONNECT CONFIRM` - must show `requiresResolve=true`, then fresh resolve, then structured lifecycle.
5. When ONLINE: `/mbtest snapshot Finn STANDARD`.
6. `/mbtest lifecycle Finn DISCONNECT CONFIRM`.
7. `/mbtest managed Finn` - identity persists offline, authorization should be `NONE`/resolve-required after the short proof expires while snapshot remains available.

Do not add Finn to a guild before this characterization if possible; this isolates linked/trusted-account authorization from same-guild authorization.
