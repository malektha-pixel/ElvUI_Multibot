local _, MB = ...

local DEFAULT_SELECTION = "PRIMARY"

local PURE_RANGED = { MAGE = true, WARLOCK = true, HUNTER = true, PRIEST = true }
local PURE_MELEE = { ROGUE = true, WARRIOR = true, DEATHKNIGHT = true }
local SPEC_CATALOG = {
    WARRIOR     = { "Arms", "Fury", "Protection" },
    PALADIN     = { "Holy", "Protection", "Retribution" },
    HUNTER      = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE       = { "Assassination", "Combat", "Subtlety" },
    PRIEST      = { "Discipline", "Holy", "Shadow" },
    DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
    SHAMAN      = { "Elemental", "Enhancement", "Restoration" },
    MAGE        = { "Arcane", "Fire", "Frost" },
    WARLOCK     = { "Affliction", "Demonology", "Destruction" },
    DRUID       = { "Balance", "Feral", "Restoration" },
}

local function selectionKey(name)
    name = tostring(name or DEFAULT_SELECTION)
    if name == "" then name = DEFAULT_SELECTION end
    return string.upper(name)
end

local function savedKey(name)
    name = MB:Trim(name)
    if name == "" then return nil end
    return MB:Lower(name)
end

local function classKey(value)
    return string.upper(string.gsub(tostring(value or ""), "[^A-Za-z]", ""))
end

local function normalizeRole(value)
    value = MB:Upper(value)
    if value == "HEAL" or value == "HEALER" then return "HEALER" end
    if value == "TANK" then return "TANK" end
    if value == "DPS" or value == "DAMAGER" then return "DPS" end
    return value ~= "" and value or nil
end

local function sortedUniqueKeys(keys)
    local seen, out = {}, {}
    for _, key in ipairs(keys or {}) do
        key = MB:BotKey(key) or (type(key) == "string" and MB:Lower(key) or nil)
        if key and key ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    table.sort(out)
    return out
end

local function strategySet(snapshot)
    local out = {}
    if type(snapshot) ~= "table" then return out end
    for _, list in ipairs({ snapshot.combatStrategies or {}, snapshot.normalStrategies or {} }) do
        for _, strategy in ipairs(list) do out[MB:Lower(strategy)] = true end
    end
    return out
end

local function dominantTree(bot)
    if type(bot) ~= "table" then return nil, "NO_BOT" end
    local points = { tonumber(bot.talent1) or 0, tonumber(bot.talent2) or 0, tonumber(bot.talent3) or 0 }
    local total = points[1] + points[2] + points[3]
    if total <= 0 then return nil, "NO_TALENT_POINTS", points end
    local maximum = math.max(points[1], points[2], points[3])
    local winner, ties = nil, 0
    for i = 1, 3 do
        if points[i] == maximum then winner, ties = i, ties + 1 end
    end
    if ties ~= 1 then return nil, "TALENT_TIE", points end
    return winner, nil, points
end

local function roleForTree(class, tree)
    if class == "MAGE" or class == "WARLOCK" or class == "HUNTER" or class == "ROGUE" then return "DPS" end
    if class == "PRIEST" then return tree == 3 and "DPS" or "HEALER" end
    if class == "SHAMAN" then return tree == 3 and "HEALER" or "DPS" end
    if class == "PALADIN" then return tree == 1 and "HEALER" or (tree == 2 and "TANK" or "DPS") end
    if class == "WARRIOR" then return tree == 3 and "TANK" or "DPS" end
    if class == "DEATHKNIGHT" then return tree == 1 and "TANK" or "DPS" end
    if class == "DRUID" then
        if tree == 1 then return "DPS" end
        if tree == 3 then return "HEALER" end
        return nil
    end
    return nil
end

function MB:InitializeSelections()
    self.selections = self.selections or {}
    self.selections[DEFAULT_SELECTION] = self.selections[DEFAULT_SELECTION] or { id = DEFAULT_SELECTION, keys = {}, set = {}, revision = 0 }
    self.db.selections = type(self.db.selections) == "table" and self.db.selections or {}
    self.db.selections.saved = type(self.db.selections.saved) == "table" and self.db.selections.saved or {}
end

function MB:GetBotSubgroup(botRef)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil end
    local wanted = self:BotKey(bot.name)
    if not wanted then return nil end

    local raidCount = type(GetNumRaidMembers) == "function" and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 and type(GetRaidRosterInfo) == "function" then
        for i = 1, math.min(40, raidCount) do
            local name, _, subgroup = GetRaidRosterInfo(i)
            if name and self:BotKey(name) == wanted then return tonumber(subgroup) or 1 end
        end
        return nil
    end

    local partyCount = type(GetNumPartyMembers) == "function" and (GetNumPartyMembers() or 0) or 0
    if partyCount > 0 and type(UnitName) == "function" then
        for i = 1, math.min(4, partyCount) do
            local unit = "party" .. tostring(i)
            if (type(UnitExists) ~= "function" or UnitExists(unit)) and self:BotKey(UnitName(unit)) == wanted then return 1 end
        end
    end
    return nil
end

function MB:GetBotSpec(botRef)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "BOT_NOT_FOUND" end
    local class = classKey(bot.class or bot.className)
    local trees = SPEC_CATALOG[class]
    if not trees then return { state = "UNKNOWN", class = class, primary = "UNKNOWN" } end
    local tree, reason, points = dominantTree(bot)
    if not tree then return { state = reason == "TALENT_TIE" and "AMBIGUOUS" or "UNKNOWN", class = class, primary = reason == "TALENT_TIE" and "HYBRID" or "UNKNOWN", points = points, reason = reason } end
    return { state = "CONFIRMED", class = class, tree = tree, primary = trees[tree], points = points }
end

function MB:GetBotRole(botRef)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "BOT_NOT_FOUND" end
    local state = self:GetData("BOT.STATE", bot.key)
    local strategies = strategySet(state)
    if strategies.tank or strategies.bear then return { primary = "TANK", state = "CONFIRMED", source = "STRATEGY" } end
    if strategies.heal or strategies.healer then return { primary = "HEALER", state = "CONFIRMED", source = "STRATEGY" } end
    if strategies.dps or strategies.cat then return { primary = "DPS", state = "CONFIRMED", source = "STRATEGY" } end

    local class = classKey(bot.class or bot.className)
    if class == "MAGE" or class == "WARLOCK" or class == "HUNTER" or class == "ROGUE" then
        return { primary = "DPS", state = "CONFIRMED", source = "CLASS" }
    end
    local spec = self:GetBotSpec(bot)
    if spec and spec.state == "CONFIRMED" then
        local role = roleForTree(class, spec.tree)
        if role then return { primary = role, state = "CONFIRMED", source = "SPEC", spec = spec.primary } end
        if class == "DRUID" and spec.tree == 2 then return { primary = "UNKNOWN", state = "AMBIGUOUS", source = "SPEC", roles = { "TANK", "DPS" }, spec = spec.primary } end
    end
    return { primary = "UNKNOWN", state = "UNKNOWN", source = "INSUFFICIENT_DATA" }
end

function MB:GetBotRange(botRef)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "BOT_NOT_FOUND" end
    local class = classKey(bot.class or bot.className)
    if PURE_RANGED[class] then return "RANGED", "CLASS" end
    if PURE_MELEE[class] then return "MELEE", "CLASS" end
    local spec = self:GetBotSpec(bot)
    local primary = spec and self:Lower(spec.primary) or ""
    if class == "PALADIN" then
        if primary == "holy" then return "RANGED", "SPEC" end
        if primary == "protection" or primary == "retribution" then return "MELEE", "SPEC" end
    elseif class == "SHAMAN" then
        if primary == "enhancement" then return "MELEE", "SPEC" end
        if primary == "elemental" or primary == "restoration" then return "RANGED", "SPEC" end
    elseif class == "DRUID" then
        if primary == "feral" then return "MELEE", "SPEC" end
        if primary == "balance" or primary == "restoration" then return "RANGED", "SPEC" end
    end
    return nil, "UNKNOWN"
end

function MB:SetSelection(name, refs)
    local id = selectionKey(name)
    local set, ordered = {}, {}
    if type(refs) ~= "table" then refs = refs and { refs } or {} end
    for _, ref in ipairs(refs) do
        local bot = self:ResolveBot(ref)
        local key = bot and bot.key or self:BotKey(type(ref) == "table" and (ref.key or ref.name) or ref)
        if key and not set[key] then set[key] = true; ordered[#ordered + 1] = key end
    end
    local old = self.selections[id]
    self.selections[id] = { id = id, keys = ordered, set = set, revision = ((old and old.revision) or 0) + 1, updatedAt = self:Now() }
    self:Emit("MB_SELECTION_CHANGED", id, self:GetSelection(id), old and self:GetSelectionSnapshot(old) or nil)
    return self:GetSelection(id)
end

function MB:GetSelectionSnapshot(selection)
    if type(selection) ~= "table" then return nil end
    local bots, missing = {}, {}
    for _, key in ipairs(selection.keys or {}) do
        local bot = self.botRegistry[key]
        if bot then bots[#bots + 1] = self:Copy(bot) else missing[#missing + 1] = key end
    end
    table.sort(bots, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
    return { id = selection.id, revision = selection.revision or 0, updatedAt = selection.updatedAt, keys = self:Copy(selection.keys or {}), bots = bots, missingKeys = missing, count = #bots }
end

function MB:AddSelection(name, ref)
    local id = selectionKey(name)
    local current = self.selections[id] or { id = id, keys = {}, set = {}, revision = 0 }
    local bot = self:ResolveBot(ref)
    local key = bot and bot.key or self:BotKey(type(ref) == "table" and (ref.key or ref.name) or ref)
    if not key then return nil, "BOT_REQUIRED" end
    if current.set and current.set[key] then return self:GetSelection(id) end
    local refs = self:Copy(current.keys or {})
    refs[#refs + 1] = key
    return self:SetSelection(id, refs)
end

function MB:RemoveSelection(name, ref)
    local id = selectionKey(name)
    local current = self.selections[id] or { id = id, keys = {}, set = {}, revision = 0 }
    local bot = self:ResolveBot(ref)
    local key = bot and bot.key or self:BotKey(type(ref) == "table" and (ref.key or ref.name) or ref)
    if not key then return nil, "BOT_REQUIRED" end
    local refs = {}
    for _, existing in ipairs(current.keys or {}) do if existing ~= key then refs[#refs + 1] = existing end end
    return self:SetSelection(id, refs)
end

function MB:ToggleSelection(name, ref)
    local id = selectionKey(name)
    local current = self.selections[id] or { id = id, keys = {}, set = {}, revision = 0 }
    local bot = self:ResolveBot(ref)
    local key = bot and bot.key or self:BotKey(type(ref) == "table" and (ref.key or ref.name) or ref)
    if not key then return nil, "BOT_REQUIRED" end
    if current.set and current.set[key] then return self:RemoveSelection(id, key) end
    return self:AddSelection(id, key)
end

function MB:ClearSelection(name) return self:SetSelection(name, {}) end

function MB:GetSelection(name)
    local id = selectionKey(name)
    return self:GetSelectionSnapshot(self.selections[id] or { id = id, keys = {}, set = {}, revision = 0 })
end

function MB:ResolveSelector(selector)
    local spec = {}
    if selector == nil then spec.online = true
    elseif type(selector) == "string" then
        local raw, lower = self:Trim(selector), self:Lower(selector)
        if lower == "" or lower == "all" or lower == "online" then spec.online = true
        elseif lower == "tank" then spec.online, spec.role = true, "TANK"
        elseif lower == "heal" or lower == "healer" then spec.online, spec.role = true, "HEALER"
        elseif lower == "dps" then spec.online, spec.role = true, "DPS"
        elseif lower == "ranged" then spec.online, spec.range = true, "RANGED"
        elseif lower == "melee" then spec.online, spec.range = true, "MELEE"
        elseif lower == "rangeddps" or lower == "ranged_dps" then spec.online, spec.range, spec.role = true, "RANGED", "DPS"
        elseif lower == "meleedps" or lower == "melee_dps" then spec.online, spec.range, spec.role = true, "MELEE", "DPS"
        else
            local class = string.match(lower, "^class:(.+)$")
            local group = string.match(lower, "^group:(%d+)$") or string.match(lower, "^group(%d+)$")
            local rti = string.match(lower, "^rti:(.+)$") or string.match(lower, "^priorityrti:(.+)$")
            local ccrti = string.match(lower, "^ccrti:(.+)$")
            if class then spec.online, spec.className = true, class
            elseif group then spec.online, spec.subgroup = true, tonumber(group)
            elseif rti then spec.online, spec.rtiPurpose, spec.rtiIcon = true, "PRIORITY", rti ~= "any" and rti or nil
            elseif ccrti then spec.online, spec.rtiPurpose, spec.rtiIcon = true, "CC", ccrti ~= "any" and ccrti or nil
            else return nil, "INVALID_SELECTOR" end
        end
    elseif type(selector) == "table" then
        spec = self:Copy(selector)
        if spec.online == nil then spec.online = true end
        if spec.role then spec.role = normalizeRole(spec.role) end
        if spec.range then spec.range = self:Upper(spec.range) end
        if spec.class then spec.className, spec.class = spec.class, nil end
        if spec.group then spec.subgroup, spec.group = tonumber(spec.group), nil end
        if spec.rti ~= nil then spec.rtiPurpose, spec.rtiIcon, spec.rti = "PRIORITY", tostring(spec.rti) ~= "any" and self:Lower(spec.rti) or nil, nil end
        if spec.ccrti ~= nil then spec.rtiPurpose, spec.rtiIcon, spec.ccrti = "CC", tostring(spec.ccrti) ~= "any" and self:Lower(spec.ccrti) or nil, nil end
        if spec.rtiPurpose then spec.rtiPurpose = self:Upper(spec.rtiPurpose) end
    else return nil, "INVALID_SELECTOR" end
    return spec
end

function MB:SelectBots(selector)
    local spec, err = self:ResolveSelector(selector)
    if not spec then return nil, err end
    local names = nil
    if type(spec.names) == "table" then
        names = {}
        for _, ref in ipairs(spec.names) do local key = self:BotKey(type(ref) == "table" and (ref.key or ref.name) or ref); if key then names[key] = true end end
    end
    local out = {}
    for _, bot in pairs(self.botRegistry) do
        local include = true
        if spec.online ~= nil and (bot.online == true) ~= (spec.online == true) then include = false end
        if include and names and not names[bot.key] then include = false end
        if include and spec.className and classKey(bot.class or bot.className) ~= classKey(spec.className) then include = false end
        if include and spec.role then
            local role = self:GetBotRole(bot)
            if not role or normalizeRole(role.primary) ~= normalizeRole(spec.role) then include = false end
        end
        if include and spec.range then
            local range = self:GetBotRange(bot)
            if range ~= self:Upper(spec.range) then include = false end
        end
        if include and spec.subgroup and tonumber(self:GetBotSubgroup(bot)) ~= tonumber(spec.subgroup) then include = false end
        if include and spec.rtiPurpose then
            local assignment = self.GetRTIAssignment and self:GetRTIAssignment(bot, spec.rtiPurpose) or nil
            if not assignment or not assignment.icon then include = false
            elseif spec.rtiIcon and self:Lower(assignment.icon) ~= self:Lower(spec.rtiIcon) then include = false end
        end
        if include then out[#out + 1] = self:Copy(bot) end
    end
    table.sort(out, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
    return out, nil, spec
end

function MB:NormalizeSavedSelectionSource(source, options)
    options = type(options) == "table" and options or {}
    if source == nil then
        local current = self:GetSelection(options.workingSelection or DEFAULT_SELECTION)
        return { sourceKind = "LIST", source = self:Copy(current.keys or {}), dynamic = false }
    end
    if type(source) == "table" and (source.type == "selector" or source.selector ~= nil) then
        return { sourceKind = "SELECTOR", source = self:Copy(source.selector or source), dynamic = options.dynamic ~= false }
    end
    if type(source) == "string" and options.dynamic == true then
        return { sourceKind = "SELECTOR", source = source, dynamic = true }
    end
    if type(source) == "table" and source[1] ~= nil then
        local keys = {}
        for _, ref in ipairs(source) do local bot = self:ResolveBot(ref); local key = bot and bot.key or self:BotKey(ref); if key then keys[#keys + 1] = key end end
        return { sourceKind = "LIST", source = sortedUniqueKeys(keys), dynamic = false }
    end
    if type(source) == "string" then
        local bot = self:ResolveBot(source)
        if bot then return { sourceKind = "LIST", source = { bot.key }, dynamic = false } end
        local bots, selectorErr = self:SelectBots(source)
        if bots then
            local keys = {}; for _, item in ipairs(bots) do keys[#keys + 1] = item.key end
            return { sourceKind = options.dynamic and "SELECTOR" or "LIST", source = options.dynamic and source or sortedUniqueKeys(keys), dynamic = options.dynamic == true }
        end
        return nil, selectorErr or "INVALID_SELECTION_SOURCE"
    end
    return nil, "INVALID_SELECTION_SOURCE"
end

function MB:EvaluateSavedSelection(entry)
    if type(entry) ~= "table" then return nil, "SELECTION_NOT_FOUND" end
    local keys = {}
    if entry.sourceKind == "SELECTOR" then
        local bots, err = self:SelectBots(entry.source)
        if not bots then return nil, err end
        for _, bot in ipairs(bots) do keys[#keys + 1] = bot.key end
    else
        keys = sortedUniqueKeys(entry.source or {})
    end
    local bots, missing = {}, {}
    for _, key in ipairs(keys) do
        local bot = self.botRegistry[key]
        if bot and bot.online then bots[#bots + 1] = self:Copy(bot) else missing[#missing + 1] = key end
    end
    table.sort(bots, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
    return {
        name = entry.name, key = entry.key, owner = entry.owner, sourceKind = entry.sourceKind, source = self:Copy(entry.source), dynamic = entry.dynamic == true,
        createdAt = entry.createdAt, updatedAt = entry.updatedAt, keys = keys, bots = bots, missingKeys = missing, count = #bots,
    }
end

function MB:SaveSelection(name, source, options)
    name = self:Trim(name)
    local key = savedKey(name)
    if not key then return nil, "NAME_REQUIRED" end
    options = type(options) == "table" and options or {}
    local normalized, err = self:NormalizeSavedSelectionSource(source, options)
    if not normalized then return nil, err end
    local existing = self.db.selections.saved[key]
    local entry = {
        name = name, key = key, owner = self:Trim(options.owner), sourceKind = normalized.sourceKind, source = self:Copy(normalized.source), dynamic = normalized.dynamic == true,
        createdAt = existing and existing.createdAt or self:Now(), updatedAt = self:Now(),
    }
    self.db.selections.saved[key] = entry
    local public = self:EvaluateSavedSelection(entry)
    self:Emit(existing and "MB_SAVED_SELECTION_CHANGED" or "MB_SAVED_SELECTION_CREATED", key, self:Copy(public))
    return public
end

function MB:GetSavedSelection(name)
    local key = savedKey(name)
    local entry = key and self.db and self.db.selections and self.db.selections.saved and self.db.selections.saved[key] or nil
    if not entry then return nil, "SELECTION_NOT_FOUND" end
    return self:EvaluateSavedSelection(entry)
end

function MB:GetSavedSelections()
    local out = {}
    for _, entry in pairs(self.db.selections.saved or {}) do
        local public = self:EvaluateSavedSelection(entry)
        if public then out[#out + 1] = public end
    end
    table.sort(out, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
    return out
end

local function savedEntry(self, name)
    local key = savedKey(name)
    local entry = key and self.db.selections.saved[key] or nil
    if not entry then return nil, nil, "SELECTION_NOT_FOUND" end
    return entry, key
end

function MB:AddToSavedSelection(name, targetSpec)
    local entry, key, err = savedEntry(self, name)
    if not entry then return nil, err end
    if entry.sourceKind == "SELECTOR" then return nil, "DYNAMIC_SELECTION_IMMUTABLE" end
    local bots, _, targetErr = self:ResolveTargetSpec(targetSpec)
    if not bots then return nil, targetErr end
    local keys = self:Copy(entry.source or {})
    for _, bot in ipairs(bots) do keys[#keys + 1] = bot.key end
    entry.source = sortedUniqueKeys(keys)
    entry.updatedAt = self:Now()
    local public = self:EvaluateSavedSelection(entry)
    self:Emit("MB_SAVED_SELECTION_CHANGED", key, self:Copy(public))
    return public
end

function MB:RemoveFromSavedSelection(name, targetSpec)
    local entry, key, err = savedEntry(self, name)
    if not entry then return nil, err end
    if entry.sourceKind == "SELECTOR" then return nil, "DYNAMIC_SELECTION_IMMUTABLE" end
    local bots, _, targetErr = self:ResolveTargetSpec(targetSpec)
    if not bots then return nil, targetErr end
    local remove = {}
    for _, bot in ipairs(bots) do remove[bot.key] = true end
    local keys = {}
    for _, existing in ipairs(entry.source or {}) do if not remove[existing] then keys[#keys + 1] = existing end end
    entry.source = sortedUniqueKeys(keys)
    entry.updatedAt = self:Now()
    local public = self:EvaluateSavedSelection(entry)
    self:Emit("MB_SAVED_SELECTION_CHANGED", key, self:Copy(public))
    return public
end

function MB:ToggleSavedSelectionMember(name, botRef)
    local entry, key, err = savedEntry(self, name)
    if not entry then return nil, err end
    if entry.sourceKind == "SELECTOR" then return nil, "DYNAMIC_SELECTION_IMMUTABLE" end
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "BOT_NOT_FOUND" end
    local present = false
    for _, existing in ipairs(entry.source or {}) do if existing == bot.key then present = true; break end end
    if present then return self:RemoveFromSavedSelection(name, bot.name) end
    return self:AddToSavedSelection(name, bot.name)
end

function MB:DeleteSavedSelection(name)
    local key = savedKey(name)
    local existing = key and self.db.selections.saved[key] or nil
    if not existing then return false, "SELECTION_NOT_FOUND" end
    self.db.selections.saved[key] = nil
    self:Emit("MB_SAVED_SELECTION_DELETED", key, self:Copy(existing))
    return true
end

function MB:LoadSavedSelection(name, workingName)
    local saved, err = self:GetSavedSelection(name)
    if not saved then return nil, err end
    return self:SetSelection(workingName or DEFAULT_SELECTION, saved.keys or {})
end

function MB:IsSemanticSelectorString(value)
    if type(value) ~= "string" then return false end
    local lower = self:Lower(value)
    if lower == "all" or lower == "online" or lower == "tank" or lower == "heal" or lower == "healer" or lower == "dps"
        or lower == "ranged" or lower == "melee" or lower == "rangeddps" or lower == "ranged_dps" or lower == "meleedps" or lower == "melee_dps" then return true end
    if string.match(lower, "^class:.+$") or string.match(lower, "^group:?%d+$") or string.match(lower, "^rti:.+$") or string.match(lower, "^priorityrti:.+$") or string.match(lower, "^ccrti:.+$") then return true end
    return false
end

function MB:ResolveTargetSpec(targetSpec)
    local info = { kind = "BOT_SET", source = "UNKNOWN" }
    if targetSpec == nil then
        local bots = self:SelectBots("all") or {}; info.source = "ALL"; return bots, info
    end
    if type(targetSpec) == "string" then
        local raw, lower = self:Trim(targetSpec), self:Lower(targetSpec)
        if lower == "selected" or lower == "current" then local selection = self:GetSelection(DEFAULT_SELECTION); info.source, info.selection = "WORKING_SELECTION", selection.id; return selection.bots, info end
        local runtimeName = string.match(raw, "^[Ss][Ee][Ll][Ee][Cc][Tt][Ii][Oo][Nn]:(.+)$")
        if runtimeName then local selection = self:GetSelection(runtimeName); info.source, info.selection = "WORKING_SELECTION", selection.id; return selection.bots, info end
        local savedName = string.match(raw, "^[Ss][Aa][Vv][Ee][Dd]:(.+)$")
        if savedName then local saved, err = self:GetSavedSelection(savedName); if not saved then return nil, nil, err end; info.source, info.savedSelection = "SAVED_SELECTION", saved.name; return saved.bots, info end
        if self:IsSemanticSelectorString(raw) then local bots, err, spec = self:SelectBots(raw); if not bots then return nil, nil, err end; info.source, info.selector = "SELECTOR", spec; return bots, info end
        local bot = self:ResolveBot(raw)
        if bot then info.kind, info.source = "BOT", "BOT"; return { self:Copy(bot) }, info end
        local runtime = self.selections[selectionKey(raw)]
        if runtime then local selection = self:GetSelection(raw); info.source, info.selection = "WORKING_SELECTION", selection.id; return selection.bots, info end
        local saved = self:GetSavedSelection(raw)
        if saved then info.source, info.savedSelection = "SAVED_SELECTION", saved.name; return saved.bots, info end
        return nil, nil, "TARGET_NOT_FOUND"
    elseif type(targetSpec) == "table" then
        if targetSpec.type == "selection" then
            local selection = self:GetSelection(targetSpec.name or targetSpec.selection or DEFAULT_SELECTION); info.source, info.selection = "WORKING_SELECTION", selection.id; return selection.bots, info
        elseif targetSpec.type == "saved" or targetSpec.saved then
            local saved, err = self:GetSavedSelection(targetSpec.name or targetSpec.saved); if not saved then return nil, nil, err end; info.source, info.savedSelection = "SAVED_SELECTION", saved.name; return saved.bots, info
        elseif targetSpec.type == "selector" then
            local bots, err, spec = self:SelectBots(targetSpec.selector); if not bots then return nil, nil, err end; info.source, info.selector = "SELECTOR", spec; return bots, info
        elseif targetSpec.all == true then
            local bots = self:SelectBots("all") or {}; info.source = "ALL"; return bots, info
        elseif targetSpec.names or targetSpec.bots or targetSpec[1] ~= nil then
            local refs = targetSpec.names or targetSpec.bots or targetSpec
            local out, seen = {}, {}
            for _, ref in ipairs(refs) do local bot = self:ResolveBot(ref); if bot and not seen[bot.key] then seen[bot.key] = true; out[#out + 1] = self:Copy(bot) end end
            table.sort(out, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end); info.source = "LIST"; return out, info
        elseif targetSpec.name or targetSpec.bot or targetSpec.key then
            local bot = self:ResolveBot(targetSpec); if not bot then return nil, nil, "BOT_NOT_FOUND" end; info.kind, info.source = "BOT", "BOT"; return { self:Copy(bot) }, info
        else
            local bots, err, spec = self:SelectBots(targetSpec); if not bots then return nil, nil, err end; info.source, info.selector = "SELECTOR", spec; return bots, info
        end
    end
    return nil, nil, "INVALID_TARGET_SPEC"
end

function MB:ResolveSelection(selector)
    local bots = self:ResolveTargetSpec(selector)
    return bots or {}
end

function MB:GetTargetCatalog()
    local current = self:GetSelection(DEFAULT_SELECTION)
    local saved = self:GetSavedSelections()
    return {
        current = current,
        saved = saved,
        semantic = { "all", "tank", "healer", "dps", "melee", "ranged", "meleedps", "rangeddps", "group:1", "group:2", "group:3", "group:4", "group:5", "group:6", "group:7", "group:8" },
    }
end
