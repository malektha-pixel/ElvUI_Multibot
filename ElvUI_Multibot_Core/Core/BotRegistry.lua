local _, MB = ...

local CLASS_BY_ID = {
    [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
    [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
}

function MB:UpsertBot(name, patch, source)
    name = self:NormalizeName(name)
    local key = self:BotKey(name)
    if not key then return nil end
    local first = self.botRegistry[key] == nil
    local bot = self.botRegistry[key] or { key = key, name = name, discoveredAt = self:Now(), online = false }
    bot.name = name or bot.name
    if type(patch) == "table" then
        for k, v in pairs(patch) do if v ~= nil then bot[k] = v end end
    end
    if bot.classId and not bot.class then bot.class = CLASS_BY_ID[tonumber(bot.classId)] end
    bot.lastSource = source or bot.lastSource
    bot.lastSeenAt = self:Now()
    self.botRegistry[key] = bot
    if first then self:Emit("MB_BOT_DISCOVERED", self:Copy(bot)) end
    self:CommitData("BOT.IDENTITY", key, self:Copy(bot), { source = source or "REGISTRY" })
    return bot
end

function MB:SyncRoster(roster)
    local seen = {}
    for _, item in ipairs(roster or {}) do
        local key = self:BotKey(item.name)
        if key then
            seen[key] = true
            local old = self.botRegistry[key]
            local oldOnline = old and old.online == true
            local bot = self:UpsertBot(item.name, {
                online = true,
                classId = item.classId,
                class = CLASS_BY_ID[tonumber(item.classId)],
                level = item.level,
                mapId = item.mapId,
                alive = item.alive,
                hpPct = item.hpPct,
                mpPct = item.mpPct,
            }, "BRIDGE.ROSTER")
            if bot and oldOnline ~= true then self:Emit("MB_BOT_PRESENCE_CHANGED", self:Copy(bot), true) end
        end
    end
    for key, bot in pairs(self.botRegistry) do
        if bot.online and not seen[key] then
            bot.online = false
            bot.lastSeenAt = self:Now()
            self:CommitData("BOT.IDENTITY", key, self:Copy(bot), { source = "BRIDGE.ROSTER" })
            if self.ClearEquipmentSnapshot then self:ClearEquipmentSnapshot(key, "BOT_UNAVAILABLE") end
            self:Emit("MB_BOT_PRESENCE_CHANGED", self:Copy(bot), false)
        end
    end
end

function MB:MergeBotDetail(detail)
    if type(detail) ~= "table" or not detail.name then return end
    self:UpsertBot(detail.name, {
        race = detail.race,
        gender = detail.gender,
        className = detail.className,
        class = detail.className and self:Upper(detail.className) or nil,
        level = detail.level,
        talent1 = detail.talent1,
        talent2 = detail.talent2,
        talent3 = detail.talent3,
        score = detail.score,
    }, "BOT.DETAIL")
end

function MB:MergeBotProfessions(name, professions)
    self:UpsertBot(name, { professions = self:Copy(professions or {}) }, "BOT.PROFESSIONS")
end

function MB:ResolveBot(ref)
    if type(ref) == "table" then
        if ref.key and self.botRegistry[ref.key] then return self.botRegistry[ref.key] end
        ref = ref.name or ref.bot or ref.target
    end
    local key = self:BotKey(ref)
    return key and self.botRegistry[key] or nil
end

function MB:GetBots(filter)
    local out = {}
    for _, bot in pairs(self.botRegistry) do
        local include = true
        if type(filter) == "table" then
            if filter.online ~= nil and (bot.online == true) ~= (filter.online == true) then include = false end
            if filter.class and self:Upper(bot.class or bot.className) ~= self:Upper(filter.class) then include = false end
        elseif type(filter) == "function" then
            local ok, result = pcall(filter, bot)
            include = ok and result ~= false
        end
        if include then out[#out + 1] = self:Copy(bot) end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function MB:SyncAltRoster(snapshot)
    local items = type(snapshot) == "table" and snapshot.items or snapshot
    if type(items) ~= "table" then return false end
    local seen = {}
    for _, entry in ipairs(items) do
        local name = self:NormalizeName(entry and entry.name)
        local guid = tonumber(entry and entry.guid)
        if name and guid and guid > 0 then
            local key = self:BotKey(name)
            seen[key] = true
            self:UpsertBot(name, {
                guid = guid,
                altGuid = guid,
                altbot = true,
                altRosterPresent = true,
                altOnline = self:Upper(entry.state) == "ONLINE",
                lifecycleState = self:Upper(entry.state),
                lifecycleSessionEpoch = self.sessionEpoch,
                lifecycleObservedAt = self:Now(),
                lifecycleStateSource = "ALT.ROSTER",
                altRosterSessionEpoch = self.sessionEpoch,
                altRosterObservedAt = self:Now(),
                classId = tonumber(entry.classId) or nil,
                class = CLASS_BY_ID[tonumber(entry.classId)],
                level = tonumber(entry.level) or nil,
            }, "ALT.ROSTER")
        end
    end
    for key, bot in pairs(self.botRegistry) do
        if bot.altbot == true and bot.altRosterPresent == true and not seen[key] then
            bot.altRosterPresent = false
            bot.altOnline = false
            bot.lifecycleState = "UNKNOWN"
            bot.lastSeenAt = self:Now()
            self:CommitData("BOT.IDENTITY", key, self:Copy(bot), { source = "ALT.ROSTER" })
        end
    end
    return true
end
