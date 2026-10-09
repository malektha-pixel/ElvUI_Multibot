local _, MB = ...

local function register(id, descriptor)
    descriptor.id = id
    MB.actions[id] = descriptor
end

register("RTI.COMMAND", {
    route = "BRIDGE", family = "RTI", scopes = { ALL = true, GROUP = true, BOT = true },
    description = "Run a bridge RTI command.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("COMBAT.COMMAND", {
    route = "BRIDGE", family = "COMBAT", scopes = { ALL = true, GROUP = true, BOT = true },
    description = "Run a bridge combat command.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("STRATEGY.MUTATE", {
    route = "BRIDGE", family = "STRATEGY", scopes = { ALL = true, GROUP = true, PARTY = true, RAID = true, BOT = true },
    capability = "STRATEGY_MUTATION_V1", description = "Add/remove strategies in combat or non-combat state.", timeout = 6,
    idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BRIDGE_ACK", invalidates = { "BOT.STATE" },
})
register("LOOT.COMMAND", {
    route = "BRIDGE", family = "LOOT", scopes = { ALL = true, GROUP = true, BOT = true },
    description = "Run a bridge loot command.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("POSITION.COMMAND", {
    route = "BRIDGE", family = "POSITION", scopes = { ALL = true, GROUP = true, BOT = true },
    description = "Run a bridge position/disperse command.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("FORMATION.SET", {
    route = "BRIDGE", family = "FORMATION", scopes = { GROUP = true },
    description = "Set the bridge group formation.", timeout = 6, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BRIDGE_ACK",
    invalidates = { "GROUP.FORMATIONS" },
})
register("OUTFIT.COMMAND", {
    route = "BRIDGE", family = "OUTFIT", scopes = { BOT = true },
    description = "Run an outfit command for one bot.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK",
    invalidates = { "BOT.OUTFITS", "BOT.INVENTORY" },
})
register("TRAINER.LEARN", {
    route = "BRIDGE", family = "TRAINER_LEARN", scopes = { BOT = true },
    description = "Learn one trainer spell or ALL.", timeout = 10, idempotency = "NON_IDEMPOTENT", risk = "NON_IDEMPOTENT", verification = "BRIDGE_ACK",
    invalidates = { "BOT.TRAINER", "BOT.SPELLBOOK", "BOT.STATS" },
})
register("TALENT.SPEC_APPLY", {
    route = "BRIDGE", family = "TALENT_SPEC_APPLY", scopes = { BOT = true }, capability = "TALENT_SPEC_APPLY_V1",
    description = "Apply one bridge-provided premade talent spec to one bot talent slot.", timeout = 10,
    idempotency = "NON_IDEMPOTENT", risk = "CONTROL", verification = "BRIDGE_ACK",
    invalidates = { "BOT.TALENT_SPECS", "BOT.TALENTS", "BOT.DETAIL", "BOT.STATE", "BOT.SPELLBOOK", "BOT.GLYPHS" },
})
register("SPELL.EXCLUSION_SET", {
    route = "CHAT", family = "SPELL_EXCLUSION_SET", scopes = { BOT = true },
    description = "Enable or disable one learned bot spell for autonomous Playerbots use through the narrow ss compatibility semantic.",
    timeout = 6, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("SPELL.CAST", {
    route = "CHAT", family = "SPELL_CAST", scopes = { BOT = true },
    description = "Explicitly order one bot to cast one learned spell through the narrow Playerbots cast compatibility semantic.",
    timeout = 6, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("PROFESSION.CRAFT", {
    route = "BRIDGE", family = "CRAFT_RECIPE", scopes = { BOT = true },
    description = "Craft a known profession recipe.", timeout = 10, idempotency = "NON_IDEMPOTENT", risk = "NON_IDEMPOTENT", verification = "BRIDGE_ACK",
    invalidates = { "BOT.PROFESSION_RECIPES", "BOT.INVENTORY" },
})
register("ITEM.ACTION", {
    route = "BRIDGE", family = "ITEM_ACTION", scopes = { BOT = true },
    description = "Bridge inventory/bank/vendor item action.", timeout = 10, idempotency = "NON_IDEMPOTENT", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT" },
})
register("BOT.CONNECT", {
    route = "BRIDGE", family = "BOT_LIFECYCLE", lifecycleAction = "CONNECT", scopes = { BOT = true }, capability = "BOT_LIFECYCLE_V1",
    description = "Connect one authorized managed bot by authoritative lifecycle GUID.", timeout = 12,
    idempotency = "NON_IDEMPOTENT", risk = "LIFECYCLE_MUTATION", verification = "BOT_LIFECYCLE_STATE",
    invalidates = { "ALT.ROSTER", "BRIDGE.ROSTER", "BOT.LIFECYCLE_TARGET" },
})
register("BOT.DISCONNECT", {
    route = "BRIDGE", family = "BOT_LIFECYCLE", lifecycleAction = "DISCONNECT", scopes = { BOT = true }, capability = "BOT_LIFECYCLE_V1",
    description = "Disconnect one authorized managed bot by authoritative lifecycle GUID.", timeout = 12,
    idempotency = "NON_IDEMPOTENT", risk = "LIFECYCLE_MUTATION", verification = "BOT_LIFECYCLE_STATE",
    invalidates = { "ALT.ROSTER", "BRIDGE.ROSTER", "BOT.LIFECYCLE_TARGET" },
})
register("ITEM.BUYBACK", {
    route = "BRIDGE", family = "ITEM_BUYBACK", scopes = { BOT = true }, capability = "VENDOR_BUYBACK_V1",
    description = "Buy back one exact entry from the bot vendor buyback list using slot/item/count/price stale-state guards.", timeout = 8,
    idempotency = "NON_IDEMPOTENT", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT", "BOT.BUYBACK", "BOT.STATS" },
})

function MB:GetActionDescriptor(id)
    local descriptor = self.actions[id]
    return descriptor and self:Copy(descriptor) or nil
end

register("RTI.ASSIGN_PRIORITY", {
    route = "BRIDGE", family = "RTI", semanticKind = "ASSIGN_PRIORITY", scopes = { BOT = true },
    description = "Assign a priority raid-target icon to one bot.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("RTI.ASSIGN_CC", {
    route = "BRIDGE", family = "RTI", semanticKind = "ASSIGN_CC", scopes = { BOT = true },
    description = "Assign a CC raid-target icon to one bot.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("RTI.ATTACK_ASSIGNED", {
    route = "BRIDGE", family = "RTI", semanticKind = "ATTACK_ASSIGNED", scopes = { BOT = true },
    description = "Tell one bot to attack its assigned priority RTI target.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("RTI.PULL_ASSIGNED", {
    route = "BRIDGE", family = "RTI", semanticKind = "PULL_ASSIGNED", scopes = { BOT = true },
    description = "Tell one bot to pull its assigned priority RTI target.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BRIDGE_ACK",
})
register("TACTICAL.ORDER", {
    route = "CHAT", family = "TACTICAL_ORDER", defaultScope = "SET", scopes = { SET = true },
    description = "Issue one whitelisted Playerbots tactical order to an exact frozen bot set, using native party/raid selectors when possible.",
    timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.ENABLE", {
    route = "CHAT", family = "RTSC_ENABLE", defaultScope = "GROUP", scopes = { GROUP = true },
    description = "Enable Playerbots RTSC mode and make the AEDM world-placement spell available to the player.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.PREPARE", {
    route = "CHAT", family = "RTSC_PREPARE", defaultScope = "SET", scopes = { SET = true },
    description = "Enable RTSC, prepare an exact frozen bot set for an AEDM world click, and optionally arm a saved location slot.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.SELECT", {
    route = "CHAT", family = "RTSC_SELECT", defaultScope = "SET", scopes = { SET = true },
    description = "Enable RTSC and select an exact frozen bot set using Playerbots chat commands.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.GO", {
    route = "CHAT", family = "RTSC_GO", defaultScope = "SET", scopes = { SET = true },
    description = "Send an exact frozen bot set to saved RTSC location 1-9.", timeout = 8, idempotency = "BEST_EFFORT_ORDER", risk = "MOVEMENT", verification = "BEST_EFFORT_SENT",
})
register("RTSC.SAVE", {
    route = "CHAT", family = "RTSC_SAVE", defaultScope = "GROUP", scopes = { GROUP = true },
    description = "Arm saved RTSC location 1-9 before the next AEDM world click.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.UNSAVE", {
    route = "CHAT", family = "RTSC_UNSAVE", defaultScope = "GROUP", scopes = { GROUP = true },
    description = "Remove saved RTSC location 1-9.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})
register("RTSC.CANCEL", {
    route = "CHAT", family = "RTSC_CANCEL", defaultScope = "GROUP", scopes = { GROUP = true },
    description = "Disable Playerbots RTSC mode and remove the AEDM world-placement spell.", timeout = 8, idempotency = "IDEMPOTENT_SET", risk = "CONTROL", verification = "BEST_EFFORT_SENT",
})

register("ITEM.EQUIP", {
    route = "HYBRID", family = "ITEM_SEMANTIC", semanticKind = "EQUIP", scopes = { BOT = true },
    description = "Equip one exact inventory stack. Prefer the structured bridge item route; use the validated Playerbots hyperlink route only as a pre-dispatch compatibility fallback.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK_OR_COMPAT_BEST_EFFORT",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT", "BOT.STATS", "BOT.EQUIPMENT" }, invalidatesOnSend = true,
})
register("ITEM.USE", {
    route = "HYBRID", family = "ITEM_SEMANTIC", semanticKind = "USE", scopes = { BOT = true },
    description = "Use one exact inventory stack. Prefer the structured bridge item route; use the validated Playerbots hyperlink route only as a pre-dispatch compatibility fallback.", timeout = 8,
    idempotency = "NON_IDEMPOTENT", risk = "NON_IDEMPOTENT", verification = "BRIDGE_ACK_OR_COMPAT_POSTCONDITION",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT" }, invalidatesOnSend = true, postVerification = "BRIDGE_INVENTORY_COUNT_POSTCONDITION",
})
register("ITEM.SELL", {
    route = "HYBRID", family = "ITEM_SEMANTIC", semanticKind = "SELL", scopes = { BOT = true },
    description = "Sell one exact inventory stack to the current vendor. Prefer the structured bridge item route; use the validated Playerbots hyperlink route only as a pre-dispatch compatibility fallback.", timeout = 8,
    idempotency = "NON_IDEMPOTENT", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK_OR_COMPAT_POSTCONDITION",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT", "BOT.BUYBACK" }, invalidatesOnSend = true, requiresMerchantContext = true, postVerification = "BRIDGE_INVENTORY_COUNT_POSTCONDITION",
})
register("ITEM.DESTROY", {
    route = "HYBRID", family = "ITEM_SEMANTIC", semanticKind = "DESTROY", scopes = { BOT = true },
    description = "Destroy one exact inventory stack. Prefer the structured bridge item route; use the validated Playerbots hyperlink route only as a pre-dispatch compatibility fallback. Explicit confirmation is required.", timeout = 8,
    idempotency = "DESTRUCTIVE", risk = "DESTRUCTIVE", verification = "BRIDGE_ACK_OR_COMPAT_POSTCONDITION",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT" }, invalidatesOnSend = true, requiresConfirmation = true, postVerification = "BRIDGE_INVENTORY_COUNT_POSTCONDITION",
})
register("ITEM.GIVE", {
    route = "HYBRID", family = "ITEM_SEMANTIC", semanticKind = "GIVE", scopes = { BOT = true },
    description = "Place one exact inventory stack into trade. Core owns trade opening; the structured bridge route is preferred and the Playerbots hyperlink route remains a pre-dispatch compatibility fallback. Final trade acceptance stays under user control.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "ITEM_TRANSFER", verification = "BRIDGE_TRADE_SLOT_OR_COMPAT_BEST_EFFORT",
    coreOwnsTrade = true,
})
register("ITEM.MOVE", {
    route = "BRIDGE", family = "ITEM_MOVE", scopes = { BOT = true }, capability = "ITEM_MOVE_V1",
    description = "Move one exact physical inventory stack to another exact inventory position using fresh source/destination guards.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT" },
})
register("ITEM.UNEQUIP", {
    route = "BRIDGE", family = "ITEM_UNEQUIP", scopes = { BOT = true }, capability = "ITEM_UNEQUIP_V1",
    description = "Unequip one item from an explicit 0-based server equipment slot with item-ID stale-state guarding.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "ITEM_MUTATION", verification = "BRIDGE_ACK",
    invalidates = { "BOT.INVENTORY", "BOT.INVENTORY_EXACT", "BOT.STATS", "BOT.EQUIPMENT" },
})
register("QUEST.ABANDON", {
    route = "CHAT", family = "QUEST_ABANDON", scopes = { BOT = true },
    description = "Abandon one quest after resolving the exact Playerbots-generated quest hyperlink.", timeout = 12,
    idempotency = "DESTRUCTIVE", risk = "DESTRUCTIVE", verification = "BRIDGE_QUEST_ABSENT",
    invalidates = { "BOT.QUESTS", "BOT.QUEST_METADATA" }, invalidatesOnSend = true, requiresConfirmation = true,
})
register("QUEST.ACCEPT_NEARBY", {
    route = "CHAT", family = "QUEST_NPC", semanticKind = "ACCEPT_NEARBY", scopes = { BOT = true },
    description = "Request the online bot accept quests at nearby questgivers (Playerbots accept *). Requires a friendly NPC target, with a target GUID guard at dispatch.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "QUEST_STATE", verification = "CHAT_SENT_UNVERIFIED",
})
register("QUEST.TALK_TARGET", {
    route = "CHAT", family = "QUEST_NPC", semanticKind = "TALK_TARGET", scopes = { BOT = true },
    description = "Ask the bot to talk to the master's friendly NPC target; Playerbots can automatically turn in quests/choose rewards. Requires UI confirmation.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "QUEST_REWARD", verification = "CHAT_SENT_UNVERIFIED",
})
register("QUEST.ACCEPT_LINK", {
    route = "CHAT", family = "QUEST_ACCEPT_LINK", scopes = { BOT = true, SET = true }, defaultScope = "SET",
    description = "Offer one exact quest hyperlink to a frozen Core target set. Core prechecks BOT.QUESTS, skips redundant sends for already-active quests, and verifies silent accepts through structured quest state when possible.", timeout = 8,
    idempotency = "BEST_EFFORT_ORDER", risk = "QUEST_STATE", verification = "BRIDGE_QUEST_STATE_WITH_PLAYERBOTS_FEEDBACK",
})

