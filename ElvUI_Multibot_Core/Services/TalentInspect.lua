local _, MB = ...

-- Exact Wrath (3.3.5-era) talent inspection. The relevant legacy signatures are:
--   GetActiveTalentGroup(isInspect, isPet)
--   GetNumTalentTabs(isInspect)
--   GetTalentTabInfo(tab, isInspect, isPet, talentGroup)
--   GetNumTalents(tab)
--   GetTalentInfo(tab, talent, isInspect, isPet, talentGroup)
-- Core intentionally does not infer per-talent ranks from BOT.SPELLBOOK.

function MB:IsTalentObservationSupported()
    return type(NotifyInspect) == "function"
        and type(UnitName) == "function"
        and type(UnitGUID) == "function"
        and type(GetActiveTalentGroup) == "function"
        and type(GetNumTalentTabs) == "function"
        and type(GetTalentTabInfo) == "function"
        and type(GetNumTalents) == "function"
        and type(GetTalentInfo) == "function"
end

function MB:GetTalentObservationAvailability(botRef, options)
    if not self:IsTalentObservationSupported() then
        return { enabled = false, reason = "CLIENT_TALENT_INSPECT_UNAVAILABLE", source = "CLIENT_INSPECT", authoritative = false }
    end
    local availability = self:GetClientInspectObservationAvailability(botRef, options)
    availability.domain = "BOT.TALENTS"
    availability.authoritative = availability.enabled == true
    availability.authority = "CLIENT_INSPECT_TALENT_API"
    return availability
end

function MB:GetTalentObservationCapabilities(botRef)
    local supported = self:IsTalentObservationSupported()
    local availability = botRef ~= nil and self:GetTalentObservationAvailability(botRef) or nil
    return {
        supported = supported,
        domain = "BOT.TALENTS",
        source = "CLIENT_INSPECT",
        authoritative = true,
        authority = "CLIENT_INSPECT_TALENT_API",
        persistent = false,
        sessionScoped = true,
        serialized = true,
        sharesInspectCoordinator = true,
        inspectEventRegistered = self.equipmentObservation and self.equipmentObservation.inspectEventRegistered == true,
        availability = availability and self:Copy(availability) or nil,
    }
end

function MB:GetTalentView(botRef)
    return self:GetData("BOT.TALENTS", botRef)
end

function MB:ValidateTalentSnapshotAccess(botRef, entry)
    if type(entry) ~= "table" then return false, { status = "MISSING", stale = true, available = false } end
    local meta = self:Copy(entry.meta or {})
    if tonumber(meta.sessionEpoch) ~= tonumber(self.sessionEpoch) then
        meta.status, meta.stale, meta.available, meta.error = "STALE_SESSION", true, false, "STALE_SESSION"
        return false, meta
    end
    if meta.stale == true then
        meta.status, meta.available = "STALE", false
        meta.error = meta.error or meta.invalidatedReason or "STALE"
        return false, meta
    end
    local availability = self:GetTalentObservationAvailability(botRef, { ignoreInspectBusy = true })
    if not availability.enabled then
        meta.status, meta.stale, meta.available = "UNAVAILABLE", true, false
        meta.error = availability.reason or "BOT_UNIT_UNAVAILABLE"
        meta.unit = availability.unit or meta.unit
        return false, meta
    end
    meta.status, meta.available = "FRESH", true
    return true, meta
end

function MB:MarkTalentSnapshotRefreshing(targetKey)
    local entry = self.cache[self:CacheKey("BOT.TALENTS", targetKey)]
    if not entry then return end
    entry.meta = entry.meta or {}
    entry.meta.stale = true
    entry.meta.refreshing = true
    entry.meta.refreshStartedAt = self:Now()
end

local function inspectedActiveGroup(self)
    local ok, group = pcall(GetActiveTalentGroup, true, false)
    group = ok and tonumber(group) or nil
    if group == 1 or group == 2 then return group, "CLIENT_INSPECT" end
    return nil, "CLIENT_INSPECT_GROUP_UNAVAILABLE"
end

local function readPrereqs(tabIndex, talentIndex, group)
    if type(GetTalentPrereqs) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i = pcall(GetTalentPrereqs, tabIndex, talentIndex, true, false, group)
    if not ok or a == nil then return nil end
    local raw = { a, b, c, d, e, f, g, h, i }
    local prereqs = {}
    local n = 1
    while n <= #raw do
        local tier, column, learnable = tonumber(raw[n]), tonumber(raw[n + 1]), raw[n + 2]
        if tier and column then
            prereqs[#prereqs + 1] = { tier = tier, column = column, met = learnable == 1 or learnable == true }
        end
        n = n + 3
    end
    return #prereqs > 0 and prereqs or nil
end

function MB:BuildTalentSnapshot(active)
    if type(active) ~= "table" or not active.unit then return nil, "BOT_UNIT_UNAVAILABLE" end
    if type(UnitExists) == "function" and not UnitExists(active.unit) then return nil, "BOT_UNIT_UNAVAILABLE" end
    if active.guid and type(UnitGUID) == "function" then
        local currentGuid = UnitGUID(active.unit)
        if not currentGuid or tostring(currentGuid) ~= tostring(active.guid) then return nil, "BOT_UNIT_CHANGED" end
    end

    local activeGroup, groupSource = inspectedActiveGroup(self)
    if not activeGroup then return nil, "INSPECT_TALENT_GROUP_PENDING" end

    local okTabs, numTabs = pcall(GetNumTalentTabs, true)
    numTabs = okTabs and tonumber(numTabs) or 0
    if not numTabs or numTabs <= 0 then return nil, "INSPECT_TALENTS_PENDING" end

    local trees, totalPoints, totalTalents = {}, 0, 0
    for treeIndex = 1, numTabs do
        -- Patch 3.1-era return contract: name, icon, pointsSpent, background, previewPointsSpent.
        local okTab, name, icon, pointsSpent, background, previewPointsSpent = pcall(GetTalentTabInfo, treeIndex, true, false, activeGroup)
        if not okTab or not name then return nil, "INSPECT_TALENTS_PENDING" end
        pointsSpent = tonumber(pointsSpent) or 0
        local okCount, count = pcall(GetNumTalents, treeIndex)
        count = okCount and tonumber(count) or 0
        if count <= 0 then return nil, "INSPECT_TALENTS_PENDING" end

        local tree = {
            index = treeIndex,
            name = name,
            icon = icon,
            pointsSpent = pointsSpent,
            background = background,
            previewPointsSpent = tonumber(previewPointsSpent),
            talents = {},
        }
        for talentIndex = 1, count do
            local okTalent, talentName, talentIcon, tier, column, rank, maxRank, isExceptional, available, previewRank, previewAvailable =
                pcall(GetTalentInfo, treeIndex, talentIndex, true, false, activeGroup)
            if not okTalent or not talentName then return nil, "INSPECT_TALENTS_PENDING" end
            rank, maxRank, tier, column = tonumber(rank) or 0, tonumber(maxRank) or 0, tonumber(tier), tonumber(column)
            if not tier or not column or maxRank <= 0 then return nil, "INSPECT_TALENTS_PENDING" end
            tree.talents[#tree.talents + 1] = {
                index = talentIndex,
                name = talentName,
                icon = talentIcon,
                tier = tier,
                column = column,
                rank = rank,
                maxRank = maxRank,
                isExceptional = isExceptional == 1 or isExceptional == true,
                available = available == 1 or available == true,
                previewRank = tonumber(previewRank),
                previewAvailable = previewAvailable == 1 or previewAvailable == true,
                prereqs = readPrereqs(treeIndex, talentIndex, activeGroup),
            }
            totalTalents = totalTalents + 1
        end
        totalPoints = totalPoints + pointsSpent
        trees[#trees + 1] = tree
    end

    local expectedActiveGroup, activeGroupConsistent
    local specSnapshot = self:GetData("BOT.TALENT_SPECS", active.botName)
    if type(specSnapshot) == "table" and type(specSnapshot.current) == "table" then
        local slot = tonumber(specSnapshot.current.slot)
        if slot == 1 or slot == 2 then
            expectedActiveGroup = slot
            activeGroupConsistent = slot == activeGroup
        end
    end

    local observedAt = self:Now()
    return {
        schemaVersion = 1,
        bot = active.botName,
        name = active.botName,
        botKey = active.botKey,
        guid = active.guid,
        unit = active.unit,
        source = "CLIENT_INSPECT",
        authority = "CLIENT_INSPECT_TALENT_API",
        observedAt = observedAt,
        complete = true,
        available = true,
        authoritative = true,
        persistent = false,
        sessionScoped = true,
        activeGroup = activeGroup,
        activeGroupSource = groupSource,
        expectedActiveGroup = expectedActiveGroup,
        activeGroupConsistent = activeGroupConsistent,
        treeCount = #trees,
        talentCount = totalTalents,
        pointsSpent = totalPoints,
        trees = trees,
    }, nil
end

function MB:CommitTalentSnapshot(active, snapshot)
    if type(active) ~= "table" or type(snapshot) ~= "table" then return false end
    local request = active.request
    if not request or request.sessionEpoch ~= self.sessionEpoch then
        self:FinishClientInspectObservation(active, "STALE_SESSION")
        return false
    end
    local readKey = self:ReadKey(request.domainId, request.targetKey)
    if self.pendingReads[readKey] ~= request then
        self:FinishClientInspectObservation(active)
        return false
    end

    local previous = self.cache[self:CacheKey("BOT.TALENTS", request.targetKey)]
    if previous and previous.meta then
        previous.meta.invalidatedAt, previous.meta.invalidatedReason, previous.meta.refreshStartedAt = nil, nil, nil
    end
    self:CommitData("BOT.TALENTS", request.targetKey, snapshot, {
        source = "CLIENT_INSPECT",
        token = active.token,
        observedAt = snapshot.observedAt,
        complete = true,
        available = true,
        authority = "CLIENT_INSPECT_TALENT_API",
        authoritative = true,
        persistent = false,
        sessionScoped = true,
        sessionEpoch = self.sessionEpoch,
        unit = active.unit,
        guid = active.guid,
        activeGroup = snapshot.activeGroup,
        expectedActiveGroup = snapshot.expectedActiveGroup,
        activeGroupConsistent = snapshot.activeGroupConsistent,
        refreshing = false,
    })
    self:FinishClientInspectObservation(active)
    return true
end

function MB:ClearTalentObservationCache(reason)
    local cleared, keys = 0, {}
    for key, entry in pairs(self.cache or {}) do
        if entry and entry.meta and entry.meta.domain == "BOT.TALENTS" then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        local entry = self.cache[key]
        local targetKey = entry and entry.meta and entry.meta.targetKey or nil
        self.cache[key] = nil
        cleared = cleared + 1
        if targetKey then self:Emit("MB_DATA_INVALIDATED", "BOT.TALENTS", targetKey, reason or "SESSION_RESET") end
    end
    return cleared
end

function MB:ScheduleTalentRefreshIfInterested(botKey, botName, delay)
    botKey = self:BotKey(botKey or botName)
    if not botKey or self:GetInterestCount("BOT.TALENTS", botKey) <= 0 then return false end
    local epoch = self.sessionEpoch
    self:After(delay or 0.65, function()
        if MB.sessionEpoch ~= epoch then return end
        if MB:GetInterestCount("BOT.TALENTS", botKey) <= 0 then return end
        MB:RefreshDomain("BOT.TALENTS", botName or botKey)
    end)
    return true
end
