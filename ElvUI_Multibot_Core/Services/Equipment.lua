local _, MB = ...

-- Client inventory slots are 1..19. AzerothCore/bridge equipment slots use the
-- same ordering at 0..18. Keep the mapping in Core so subscribers never need
-- to duplicate or guess the off-by-one normalization.
local EQUIPMENT_SLOTS = {
    { uiSlot = 1,  serverSlot = 0,  slotName = "HeadSlot" },
    { uiSlot = 2,  serverSlot = 1,  slotName = "NeckSlot" },
    { uiSlot = 3,  serverSlot = 2,  slotName = "ShoulderSlot" },
    { uiSlot = 4,  serverSlot = 3,  slotName = "ShirtSlot" },
    { uiSlot = 5,  serverSlot = 4,  slotName = "ChestSlot" },
    { uiSlot = 6,  serverSlot = 5,  slotName = "WaistSlot" },
    { uiSlot = 7,  serverSlot = 6,  slotName = "LegsSlot" },
    { uiSlot = 8,  serverSlot = 7,  slotName = "FeetSlot" },
    { uiSlot = 9,  serverSlot = 8,  slotName = "WristSlot" },
    { uiSlot = 10, serverSlot = 9,  slotName = "HandsSlot" },
    { uiSlot = 11, serverSlot = 10, slotName = "Finger0Slot" },
    { uiSlot = 12, serverSlot = 11, slotName = "Finger1Slot" },
    { uiSlot = 13, serverSlot = 12, slotName = "Trinket0Slot" },
    { uiSlot = 14, serverSlot = 13, slotName = "Trinket1Slot" },
    { uiSlot = 15, serverSlot = 14, slotName = "BackSlot" },
    { uiSlot = 16, serverSlot = 15, slotName = "MainHandSlot" },
    { uiSlot = 17, serverSlot = 16, slotName = "SecondaryHandSlot" },
    { uiSlot = 18, serverSlot = 17, slotName = "RangedSlot" },
    { uiSlot = 19, serverSlot = 18, slotName = "TabardSlot" },
}

-- This state now serializes all Core-owned native Inspect observations (equipment + talents).
-- The legacy field name is retained internally to minimize regression risk for the validated 1.2 equipment path.
MB.equipmentObservation = MB.equipmentObservation or {
    active = nil,
    queue = {},
    sequence = 0,
    inspectEventRegistered = false,
}

local function unitExists(unit)
    if type(UnitExists) == "function" then
        local exists = UnitExists(unit)
        return exists == 1 or exists == true
    end
    if type(UnitName) == "function" then
        local name = UnitName(unit)
        return name ~= nil and name ~= "" and name ~= "Unknown Entity"
    end
    return false
end

function MB:IsInspectFrameShown()
    local frame = _G.InspectFrame
    if not frame or type(frame.IsShown) ~= "function" then return false end
    local shown = frame:IsShown()
    return shown == 1 or shown == true
end

function MB:SetEquipmentInspectEventRegistered(registered)
    self.equipmentObservation = self.equipmentObservation or { active = nil, queue = {} }
    self.equipmentObservation.inspectEventRegistered = registered == true
end

function MB:IsEquipmentObservationSupported()
    return type(NotifyInspect) == "function"
        and type(GetInventoryItemLink) == "function"
        and type(UnitName) == "function"
        and type(UnitGUID) == "function"
end

function MB:GetEquipmentSlotMap()
    return self:Copy(EQUIPMENT_SLOTS)
end

local function candidateUnits()
    local out = { "target", "focus", "mouseover" }
    local raidCount = type(GetNumRaidMembers) == "function" and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then
        for i = 1, math.min(40, raidCount) do out[#out + 1] = "raid" .. tostring(i) end
    else
        local partyCount = type(GetNumPartyMembers) == "function" and (GetNumPartyMembers() or 0) or 0
        for i = 1, math.min(4, partyCount) do out[#out + 1] = "party" .. tostring(i) end
    end
    return out
end

function MB:ResolveEquipmentUnit(botRef)
    local bot = self:ResolveBot(botRef)
    local wantedName = bot and bot.name or self:NormalizeName(type(botRef) == "table" and (botRef.name or botRef.bot or botRef.botName) or botRef)
    local wantedKey = self:BotKey(wantedName)
    if not wantedKey then return nil, nil, "BOT_REQUIRED" end

    for _, unit in ipairs(candidateUnits()) do
        if unitExists(unit) and self:BotKey(UnitName(unit)) == wantedKey then
            if type(UnitIsUnit) ~= "function" or not UnitIsUnit(unit, "player") then
                local guid = type(UnitGUID) == "function" and UnitGUID(unit) or nil
                return unit, guid, nil
            end
        end
    end
    return nil, nil, (bot and bot.online == false) and "BOT_OFFLINE" or "BOT_UNIT_UNAVAILABLE"
end

local function sameUnit(a, b)
    if not a or not b then return false end
    if type(UnitIsUnit) == "function" then
        local ok, result = pcall(UnitIsUnit, a, b)
        if ok then return result == 1 or result == true end
    end
    if type(UnitGUID) == "function" then
        local ga, gb = UnitGUID(a), UnitGUID(b)
        if ga and gb then return tostring(ga) == tostring(gb) end
    end
    return tostring(a) == tostring(b)
end

function MB:GetClientInspectObservationAvailability(botRef, options)
    options = type(options) == "table" and options or {}
    if type(NotifyInspect) ~= "function" or type(UnitName) ~= "function" or type(UnitGUID) ~= "function" then
        return { enabled = false, reason = "CLIENT_INSPECT_UNAVAILABLE", source = "CLIENT_INSPECT", authoritative = false }
    end

    local unit, guid, err = self:ResolveEquipmentUnit(botRef)
    if not unit then
        return { enabled = false, reason = err or "BOT_UNIT_UNAVAILABLE", source = "CLIENT_INSPECT", authoritative = false }
    end
    if type(UnitIsConnected) == "function" and not UnitIsConnected(unit) then
        return { enabled = false, reason = "BOT_NOT_CONNECTED", unit = unit, guid = guid, source = "CLIENT_INSPECT", authoritative = false }
    end
    if type(UnitIsVisible) == "function" and not UnitIsVisible(unit) then
        return { enabled = false, reason = "BOT_NOT_VISIBLE", unit = unit, guid = guid, source = "CLIENT_INSPECT", authoritative = false }
    end
    if type(CanInspect) == "function" then
        local ok, canInspect = pcall(CanInspect, unit, false)
        if ok and not canInspect then
            return { enabled = false, reason = "BOT_NOT_INSPECTABLE", unit = unit, guid = guid, source = "CLIENT_INSPECT", authoritative = false }
        end
    end

    if options.ignoreInspectBusy ~= true and self:IsInspectFrameShown() and _G.InspectFrame and _G.InspectFrame.unit and not sameUnit(unit, _G.InspectFrame.unit) then
        return { enabled = false, reason = "INSPECT_CONTEXT_BUSY", unit = unit, guid = guid, source = "CLIENT_INSPECT", authoritative = false }
    end

    return {
        enabled = true,
        reason = nil,
        unit = unit,
        guid = guid,
        source = "CLIENT_INSPECT",
        authoritative = false,
        persistent = false,
        sessionScoped = true,
    }
end

function MB:GetEquipmentObservationAvailability(botRef, options)
    if not self:IsEquipmentObservationSupported() then
        return { enabled = false, reason = "CLIENT_INSPECT_UNAVAILABLE", source = "CLIENT_INSPECT", authoritative = false }
    end
    return self:GetClientInspectObservationAvailability(botRef, options)
end

function MB:GetEquipmentObservationCapabilities(botRef)
    local supported = self:IsEquipmentObservationSupported()
    local availability = botRef ~= nil and self:GetEquipmentObservationAvailability(botRef) or nil
    return {
        supported = supported,
        domain = "BOT.EQUIPMENT",
        source = "CLIENT_INSPECT",
        authoritative = false,
        persistent = false,
        sessionScoped = true,
        serialized = true,
        inspectEventRegistered = self.equipmentObservation and self.equipmentObservation.inspectEventRegistered == true,
        availability = availability and self:Copy(availability) or nil,
        slotModel = {
            ui = "WOW_1_BASED_1_TO_19",
            server = "SERVER_0_BASED_0_TO_18",
            relation = "serverSlot = uiSlot - 1",
        },
    }
end

function MB:GetEquipmentView(botRef)
    return self:GetData("BOT.EQUIPMENT", botRef)
end

function MB:ValidateEquipmentSnapshotAccess(botRef, entry)
    if type(entry) ~= "table" then return false, { status = "MISSING", stale = true, available = false } end
    local meta = self:Copy(entry.meta or {})
    if tonumber(meta.sessionEpoch) ~= tonumber(self.sessionEpoch) then
        meta.status = "STALE_SESSION"
        meta.stale = true
        meta.available = false
        meta.error = "STALE_SESSION"
        return false, meta
    end
    if meta.stale == true then
        meta.status = "STALE"
        meta.available = false
        meta.error = meta.error or meta.invalidatedReason or "STALE"
        return false, meta
    end
    local availability = self:GetEquipmentObservationAvailability(botRef, { ignoreInspectBusy = true })
    if not availability.enabled then
        meta.status = "UNAVAILABLE"
        meta.stale = true
        meta.available = false
        meta.error = availability.reason or "BOT_UNIT_UNAVAILABLE"
        meta.unit = availability.unit or meta.unit
        return false, meta
    end
    meta.status = "FRESH"
    meta.available = true
    return true, meta
end

function MB:MarkEquipmentSnapshotRefreshing(targetKey)
    local entry = self.cache[self:CacheKey("BOT.EQUIPMENT", targetKey)]
    if not entry then return end
    entry.meta = entry.meta or {}
    entry.meta.stale = true
    entry.meta.refreshing = true
    entry.meta.refreshStartedAt = self:Now()
end

local function readSlot(self, unit, descriptor)
    local uiSlot = descriptor.uiSlot
    local itemLink = type(GetInventoryItemLink) == "function" and GetInventoryItemLink(unit, uiSlot) or nil
    local texture = type(GetInventoryItemTexture) == "function" and GetInventoryItemTexture(unit, uiSlot) or nil
    local count = type(GetInventoryItemCount) == "function" and (GetInventoryItemCount(unit, uiSlot) or 0) or 0
    local itemId = itemLink and self:ExtractItemId(itemLink) or nil
    local name, quality, itemLevel, equipLoc
    if itemLink and type(GetItemInfo) == "function" then
        name, _, quality, itemLevel, _, _, _, _, equipLoc = GetItemInfo(itemLink)
    end
    if not name and itemLink then name = self:ExtractItemLinkName(itemLink) end
    return {
        uiSlot = uiSlot,
        serverSlot = descriptor.serverSlot,
        slotName = descriptor.slotName,
        empty = itemLink == nil and texture == nil,
        itemId = itemId,
        itemLink = itemLink,
        link = itemLink,
        name = name,
        texture = texture,
        count = tonumber(count) or 0,
        quality = quality,
        itemLevel = itemLevel,
        equipLoc = equipLoc,
    }
end

function MB:BuildEquipmentSnapshot(active, allowEmpty)
    if type(active) ~= "table" or not active.unit or not unitExists(active.unit) then return nil, "BOT_UNIT_UNAVAILABLE" end
    if active.guid and type(UnitGUID) == "function" then
        local currentGuid = UnitGUID(active.unit)
        if not currentGuid or tostring(currentGuid) ~= tostring(active.guid) then return nil, "BOT_UNIT_CHANGED" end
    end

    local slots, byUiSlot, byServerSlot = {}, {}, {}
    local itemCount, unresolvedOccupied = 0, 0
    for _, descriptor in ipairs(EQUIPMENT_SLOTS) do
        local slot = readSlot(self, active.unit, descriptor)
        if slot.itemLink then itemCount = itemCount + 1
        elseif slot.texture then unresolvedOccupied = unresolvedOccupied + 1 end
        slots[#slots + 1] = slot
        byUiSlot[slot.uiSlot] = self:Copy(slot)
        byServerSlot[slot.serverSlot] = self:Copy(slot)
    end

    if unresolvedOccupied > 0 then return nil, "INSPECT_ITEMS_PENDING" end
    if itemCount == 0 and allowEmpty ~= true then return nil, "INSPECT_DATA_PENDING" end

    local observedAt = self:Now()
    return {
        schemaVersion = 1,
        bot = active.botName,
        name = active.botName,
        botKey = active.botKey,
        guid = active.guid,
        unit = active.unit,
        source = "CLIENT_INSPECT",
        observedAt = observedAt,
        complete = true,
        available = true,
        authoritative = false,
        persistent = false,
        sessionScoped = true,
        slotModel = {
            ui = "WOW_1_BASED_1_TO_19",
            server = "SERVER_0_BASED_0_TO_18",
            relation = "serverSlot = uiSlot - 1",
        },
        slotCount = #slots,
        equippedCount = itemCount,
        slots = slots,
        byUiSlot = byUiSlot,
        byServerSlot = byServerSlot,
    }, nil
end

function MB:FinishClientInspectObservation(active, errorCode)
    if self.equipmentObservation and self.equipmentObservation.active == active then
        self.equipmentObservation.active = nil
    end
    local frameOpen = self:IsInspectFrameShown()
    if active and active.notified == true and not frameOpen and type(ClearInspectPlayer) == "function" then
        pcall(ClearInspectPlayer)
    end
    if errorCode and active and active.request and self.pendingReads[self:ReadKey(active.request.domainId, active.request.targetKey)] == active.request then
        self:FailRead(active.request, errorCode)
    end
    self:After(0.05, function()
        if MB.PumpClientInspectObservation then MB:PumpClientInspectObservation() end
    end)
end

function MB:CommitEquipmentObservation(active, snapshot)
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

    local previous = self.cache[self:CacheKey("BOT.EQUIPMENT", request.targetKey)]
    if previous and previous.meta then
        previous.meta.invalidatedAt = nil
        previous.meta.invalidatedReason = nil
        previous.meta.refreshStartedAt = nil
    end
    self:CommitData("BOT.EQUIPMENT", request.targetKey, snapshot, {
        source = "CLIENT_INSPECT",
        token = active.token,
        observedAt = snapshot.observedAt,
        complete = true,
        available = true,
        authority = "CLIENT_OBSERVED",
        authoritative = false,
        persistent = false,
        sessionScoped = true,
        sessionEpoch = self.sessionEpoch,
        unit = active.unit,
        guid = active.guid,
        refreshing = false,
    })
    self:FinishClientInspectObservation(active)
    return true
end

function MB:CommitTalentObservation(active, snapshot)
    if not self.CommitTalentSnapshot then return false end
    return self:CommitTalentSnapshot(active, snapshot)
end

function MB:ProbeClientInspectObservation(token, allowEmpty)
    local active = self.equipmentObservation and self.equipmentObservation.active or nil
    if not active or tostring(active.token) ~= tostring(token) then return false end
    if active.sessionEpoch ~= self.sessionEpoch then self:FinishClientInspectObservation(active, "STALE_SESSION"); return false end
    local domainId = active.request and active.request.domainId or nil
    local snapshot, err
    if domainId == "BOT.EQUIPMENT" then
        snapshot, err = self:BuildEquipmentSnapshot(active, allowEmpty == true)
        if snapshot then return self:CommitEquipmentObservation(active, snapshot) end
    elseif domainId == "BOT.TALENTS" and self.BuildTalentSnapshot then
        snapshot, err = self:BuildTalentSnapshot(active)
        if snapshot then return self:CommitTalentObservation(active, snapshot) end
    else
        err = "UNSUPPORTED_CLIENT_INSPECT_DOMAIN"
    end
    active.lastProbeError = err
    return false
end

function MB:ProbeEquipmentObservation(token, allowEmpty)
    return self:ProbeClientInspectObservation(token, allowEmpty)
end

function MB:OnInspectReady(guid)
    local active = self.equipmentObservation and self.equipmentObservation.active or nil
    if not active then return false end
    if guid and active.guid and tostring(guid) ~= tostring(active.guid) then return false end
    active.inspectReadyAt = self:Now()
    if self:ProbeClientInspectObservation(active.token, true) then return true end
    self:After(0.10, function() MB:ProbeClientInspectObservation(active.token, true) end)
    return true
end

function MB:PumpClientInspectObservation()
    local state = self.equipmentObservation
    if not state or state.active then return false end

    local queued
    while #state.queue > 0 do
        local candidate = table.remove(state.queue, 1)
        local request = candidate and candidate.request
        local readKey = request and self:ReadKey(request.domainId, request.targetKey) or nil
        if request and request.sessionEpoch == self.sessionEpoch and self.pendingReads[readKey] == request then
            queued = candidate
            break
        end
    end
    if not queued then return false end

    local request = queued.request
    local availability
    if request.domainId == "BOT.TALENTS" and self.GetTalentObservationAvailability then
        availability = self:GetTalentObservationAvailability(request.targetInfo and request.targetInfo.botName or request.targetKey)
    else
        availability = self:GetEquipmentObservationAvailability(request.targetInfo and request.targetInfo.botName or request.targetKey)
    end
    if not availability.enabled then
        self:FailRead(request, availability.reason or "BOT_NOT_INSPECTABLE")
        return self:PumpClientInspectObservation()
    end

    local active = {
        request = request,
        token = queued.token,
        botName = request.targetInfo and request.targetInfo.botName or request.targetKey,
        botKey = request.targetInfo and request.targetInfo.botKey or request.targetKey,
        unit = availability.unit,
        guid = availability.guid,
        startedAt = self:Now(),
        sessionEpoch = self.sessionEpoch,
        notified = false,
    }
    state.active = active

    local ok, err = pcall(NotifyInspect, active.unit)
    if not ok then
        self:FinishClientInspectObservation(active, "INSPECT_REQUEST_FAILED")
        return false, err
    end
    active.notified = true

    -- Some 3.3.5a Inspect data is readable before INSPECT_READY. Bounded probes
    -- cover that behavior while the event remains the preferred completion signal.
    -- Equipment keeps its validated all-empty guard; talent reads simply remain
    -- pending until the legacy talent API exposes the inspected group/tree data.
    self:After(0.05, function() MB:ProbeClientInspectObservation(active.token, false) end)
    self:After(0.20, function() MB:ProbeClientInspectObservation(active.token, false) end)
    self:After(0.50, function() MB:ProbeClientInspectObservation(active.token, false) end)
    self:After(1.00, function() MB:ProbeClientInspectObservation(active.token, false) end)
    self:After(1.50, function()
        local current = MB.equipmentObservation and MB.equipmentObservation.active or nil
        if current and tostring(current.token) == tostring(active.token) then
            MB:FinishClientInspectObservation(current, current.lastProbeError == "INSPECT_ITEMS_PENDING" and "INSPECT_ITEMS_UNRESOLVED" or (current.lastProbeError or "INSPECT_DATA_UNAVAILABLE"))
        end
    end)
    return true
end

function MB:BeginClientInspectObservation(request)
    if type(request) ~= "table" then return false, "INVALID_REQUEST" end
    if request.domainId == "BOT.EQUIPMENT" then
        if not self:IsEquipmentObservationSupported() then return false, "CLIENT_INSPECT_UNAVAILABLE" end
        self:MarkEquipmentSnapshotRefreshing(request.targetKey)
    elseif request.domainId == "BOT.TALENTS" then
        if not self.IsTalentObservationSupported or not self:IsTalentObservationSupported() then return false, "CLIENT_TALENT_INSPECT_UNAVAILABLE" end
        if self.MarkTalentSnapshotRefreshing then self:MarkTalentSnapshotRefreshing(request.targetKey) end
    else
        return false, "UNSUPPORTED_CLIENT_INSPECT_DOMAIN"
    end
    local token = self:NewToken("inspect")
    local state = self.equipmentObservation
    state.queue[#state.queue + 1] = { request = request, token = token }
    self:PumpClientInspectObservation()
    return true, token
end

function MB:BeginEquipmentObservation(request)
    return self:BeginClientInspectObservation(request)
end

function MB:ScheduleEquipmentRefreshIfInterested(botKey, botName, delay)
    botKey = self:BotKey(botKey or botName)
    if not botKey or self:GetInterestCount("BOT.EQUIPMENT", botKey) <= 0 then return false end
    local epoch = self.sessionEpoch
    self:After(delay or 0.65, function()
        if MB.sessionEpoch ~= epoch then return end
        if MB:GetInterestCount("BOT.EQUIPMENT", botKey) <= 0 then return end
        MB:RefreshDomain("BOT.EQUIPMENT", botName or botKey)
    end)
    return true
end

function MB:ClearEquipmentSnapshot(botRef, reason)
    local targetKey = self:BotKey(type(botRef) == "table" and (botRef.key or botRef.name or botRef.bot) or botRef)
    if not targetKey then return false end
    local cacheKey = self:CacheKey("BOT.EQUIPMENT", targetKey)
    if not self.cache[cacheKey] then return false end
    self.cache[cacheKey] = nil
    self:Emit("MB_DATA_INVALIDATED", "BOT.EQUIPMENT", targetKey, reason or "EQUIPMENT_UNAVAILABLE")
    return true
end

function MB:ClearEquipmentObservationCache(reason)
    local cleared = 0
    local keys = {}
    for key, entry in pairs(self.cache or {}) do
        if entry and entry.meta and entry.meta.domain == "BOT.EQUIPMENT" then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        local entry = self.cache[key]
        local targetKey = entry and entry.meta and entry.meta.targetKey or nil
        self.cache[key] = nil
        cleared = cleared + 1
        if targetKey then self:Emit("MB_DATA_INVALIDATED", "BOT.EQUIPMENT", targetKey, reason or "SESSION_RESET") end
    end
    return cleared
end

function MB:AbortEquipmentObservations()
    local state = self.equipmentObservation
    if not state then return end
    local active = state.active
    state.active = nil
    state.queue = {}
    if active and active.notified == true and not self:IsInspectFrameShown() and type(ClearInspectPlayer) == "function" then pcall(ClearInspectPlayer) end
end

function MB:ResetEquipmentObservationSession(reason)
    self:AbortEquipmentObservations()
    self:ClearEquipmentObservationCache(reason or "SESSION_RESET")
    if self.ClearTalentObservationCache then self:ClearTalentObservationCache(reason or "SESSION_RESET") end
end
