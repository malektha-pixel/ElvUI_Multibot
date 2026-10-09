local _, MB = ...

local function register(id, descriptor)
    descriptor.id = id
    MB.dataDomains[id] = descriptor
end

register("BRIDGE.ROSTER", { scope = "GLOBAL", provider = "ROSTER", intervalKey = "roster", description = "Bridge bot roster and live presence summary." })
register("ALT.ROSTER", { scope = "GLOBAL", provider = "ALT_ROSTER", intervalKey = "altRoster", description = "Authoritative account Altbot roster from ALT_ROSTER_V1, including offline characters and lifecycle presence." })
register("BOT.LIFECYCLE_TARGET", { scope = "BOT", provider = "BOT_TARGET_RESOLVE", onDemand = true, description = "Canonical lifecycle target resolution from BOT_TARGET_RESOLVE_V1: canonical name, GUID and lifecycle state." })
register("BOT.IDENTITY", { scope = "BOT", provider = "DERIVED", onDemand = true, retainLastKnown = true, retainLastKnownSources = { ["BOT.DETAIL"] = true }, description = "Canonical bot identity assembled from roster/detail data." })
register("BOT.STATE", { scope = "BOT", provider = "STATE", intervalKey = "state", description = "Combat and non-combat Playerbots strategies." })
register("BOT.DETAIL", { scope = "BOT", provider = "DETAIL", intervalKey = "detail", retainLastKnown = true, description = "Race, gender, class, level, talent points and score." })
register("BOT.PROFESSIONS", { scope = "BOT", provider = "PROFESSIONS", intervalKey = "professions", description = "Profession summary delivered alongside bridge detail refreshes." })
register("BOT.STATS", { scope = "BOT", provider = "STATS", intervalKey = "stats", retainLastKnown = true, description = "Gold, bag use, durability, XP and mana summary." })
register("BOT.PVP_STATS", { scope = "BOT", provider = "PVP_STATS", intervalKey = "pvpStats", description = "Honor, arena points and arena teams." })
register("BOT.WEAPON_ENCHANT", { scope = "BOT", provider = "WEAPON_ENCHANT", onDemand = true, description = "Weapon enchant bridge diagnostic/status data." })
register("BOT.TALENT_SPECS", { scope = "BOT", provider = "TALENT_SPEC_LIST", onDemand = true, suppressPeriodic = true, retainLastKnown = true, description = "Structured talent spec/build list. Expensive bridge/config-backed data: explicit reads only; never scheduler-polled." })
register("BOT.GLYPHS", { scope = "BOT", provider = "GLYPHS", intervalKey = "glyphs", description = "Structured glyph list." })
register("BOT.INVENTORY", { scope = "BOT", provider = "INVENTORY", intervalKey = "inventory", retainLastKnown = true, description = "Structured flat inventory snapshot preserving server hyperlinks and item metadata." })
register("BOT.INVENTORY_EXACT", { scope = "BOT", provider = "INVENTORY_EXACT", onDemand = true, retainLastKnown = true, description = "Physical inventory snapshot from INVENTORY_EXACT_V1 with authoritative bag/slot/item/count/soulbound identity." })
register("BOT.EQUIPMENT", { scope = "BOT", provider = "CLIENT_INSPECT", onDemand = true, retainLastKnown = true, description = "Session-scoped client-observed current equipment snapshot from the native WoW Inspect/inventory APIs. The live domain is non-authoritative and non-persistent; Core may retain a separate historical last-known copy." })
register("BOT.TALENTS", { scope = "BOT", provider = "CLIENT_INSPECT", onDemand = true, retainLastKnown = true, description = "Session-scoped client-observed exact talent-tree snapshot from the native WoW 3.3.5 Inspect talent APIs, including per-talent ranks." })
register("BOT.BUYBACK", { scope = "BOT", provider = "BUYBACK", onDemand = true, description = "Structured vendor buyback snapshot from VENDOR_BUYBACK_V1. Slots 74..85 are server vendor buyback slots, not inventory bag slots." })
register("BOT.BANK", { scope = "BOT", provider = "BANK", onDemand = true, description = "Personal bank inventory." })
register("BOT.GUILD_BANK", { scope = "BOT", provider = "GBANK", onDemand = true, description = "Guild bank inventory and withdrawal rights." })
register("BOT.SPELLBOOK", { scope = "BOT", provider = "SPELLBOOK", intervalKey = "spellbook", retainLastKnown = true, description = "Spell IDs known by the bot." })
register("BOT.SPELL_EXCLUSIONS", { scope = "BOT", provider = "CLIENT_STATE", onDemand = true, description = "Session-scoped Core-observed Playerbots autonomous-use spell exclusions. Because current Playerbots exposes mutation but no documented authoritative list query, completeness/confidence metadata must be respected." })
register("BOT.SKILLS", { scope = "BOT", provider = "BOT_SKILLS", intervalKey = "skills", description = "Skill categories and values." })
register("BOT.REPUTATIONS", { scope = "BOT", provider = "BOT_REPUTATIONS", intervalKey = "reputations", description = "Faction reputation standings." })
register("BOT.EMBLEMS", { scope = "BOT", provider = "BOT_EMBLEMS", intervalKey = "emblems", description = "Currency/emblem item counts and money." })
register("BOT.PROFESSION_RECIPES", { scope = "BOT_VARIANT", provider = "PROFESSION_RECIPES", onDemand = true, variantField = "skillId", description = "Recipes for one profession skill ID." })
register("BOT.OUTFITS", { scope = "BOT", provider = "OUTFITS", onDemand = true, description = "Raw bridge-backed outfit list." })
register("BOT.TRAINER", { scope = "BOT", provider = "TRAINER", onDemand = true, description = "Trainer context and learnable spells." })
register("BOT.QUESTS", { scope = "BOT", provider = "QUESTS", intervalKey = "quests", description = "Structured incomplete/completed quest snapshot." })
register("BOT.QUEST_METADATA", { scope = "BOT", provider = "QUEST_METADATA_CHAT", onDemand = true, description = "On-demand Playerbots quests-all metadata enrichment: exact quest hyperlinks, quest levels and human-readable names. BOT.QUESTS remains authoritative for quest membership/status." })
register("BOT.GAMEOBJECTS", { scope = "BOT", provider = "GAMEOBJECTS", onDemand = true, description = "Bridge visible game-object result lines." })
register("GROUP.FORMATIONS", { scope = "GLOBAL", provider = "FORMATIONS", intervalKey = "formations", description = "Current formation per bot." })

function MB:GetDomainDescriptor(id)
    local descriptor = self.dataDomains[id]
    return descriptor and self:Copy(descriptor) or nil
end
register("BOT.RTI", { scope = "BOT", provider = "CLIENT_STATE", onDemand = true, description = "Core-session priority RTI assignment acknowledged by the bridge. No bridge readback exists." })
register("BOT.CC_RTI", { scope = "BOT", provider = "CLIENT_STATE", onDemand = true, description = "Core-session CC RTI assignment acknowledged by the bridge. No bridge readback exists." })
register("CORE.RTI_ASSIGNMENTS", { scope = "GLOBAL", provider = "DERIVED", onDemand = true, description = "Core-session summary of bridge-acknowledged priority and CC RTI assignments." })
register("CORE.RTSC_PLACEMENT", { scope = "GLOBAL", provider = "CLIENT_STATE", onDemand = true, description = "Most recent RTSC world-placement preparation contract and frozen target set." })
