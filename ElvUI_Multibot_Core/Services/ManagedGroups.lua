local _, MB = ...

local GROUP_SCHEMA_VERSION = 1
local BULK_DEFAULT_CONCURRENCY = 2
local BULK_MAX_CONCURRENCY = 4

local function epochNow()
    if type(time) == "function" then return time() end
    return 0
end

local function normalizeAction(self, action)
    action = self:Upper(action)
    if action == "CONNECT" or action == "DISCONNECT" then return action end
    return nil
end

local function finalStateFor(action)
    return action == "CONNECT" and "ONLINE" or "OFFLINE"
end

local function groupNameKey(self, name)
    name = self:Trim(name)
    if name == "" then return nil end
    return self:Lower(name)
end

function MB:InitializeManagedGroupStore()
    local saved = _G.ElvUI_Multibot_GroupsDB
    if type(saved) ~= "table" then saved = {}; _G.ElvUI_Multibot_GroupsDB = saved end
    saved.schemaVersion = GROUP_SCHEMA_VERSION
    saved.nextId = math.max(1, tonumber(saved.nextId) or 1)
    saved.groups = type(saved.groups) == "table" and saved.groups or {}
    saved.nameIndex = {}
    for id, group in pairs(saved.groups) do
        if type(group) == "table" then
            group.id = tostring(group.id or id)
            group.name = self:Trim(group.name)
            group.members = type(group.members) == "table" and group.members or {}
            group.schemaVersion = GROUP_SCHEMA_VERSION
            local key = groupNameKey(self, group.name)
            if key then saved.nameIndex[key] = group.id end
        end
    end
    self.managedGroupStore = saved
    self.managedGroupLifecycleRequests = {}
    self.managedGroupLifecycleGuidReservations = {}
    self.managedGroupLifecycleRequestSequence = 0
end

function MB:ResolveManagedGroupKey(groupRef)
    if not self.managedGroupStore then return nil end
    if type(groupRef) == "table" then groupRef = groupRef.id or groupRef.name end
    groupRef = self:Trim(groupRef)
    if groupRef == "" then return nil end
    if self.managedGroupStore.groups[groupRef] then return groupRef end
    local key = groupNameKey(self, groupRef)
    return key and self.managedGroupStore.nameIndex[key] or nil
end

local function managedGroupView(self, group)
    if type(group) ~= "table" then return nil end
    local view = self:Copy(group)
    view.members = {}
    for guidKey, member in pairs(group.members or {}) do
        local guid = tonumber(guidKey) or tonumber(member and member.guid)
        local managed = guid and self.GetManagedBot and select(1, self:GetManagedBot(guid)) or nil
        local item = {
            guid = guid,
            name = managed and managed.name or (member and member.nameAtAdd) or nil,
            addedAt = member and member.addedAt or nil,
            known = managed ~= nil,
            effectiveState = managed and managed.effectiveState or "UNKNOWN",
            effectiveStateSource = managed and managed.effectiveStateSource or "NONE",
            lastKnownLifecycle = managed and managed.lastKnownLifecycle or "UNKNOWN",
            online = managed and managed.online == true or false,
            altRosterPresent = managed and managed.altRosterPresent == true or false,
            snapshot = managed and self:Copy(managed.snapshot) or { exists = false },
            authorization = managed and self:Copy(managed.authorization) or { authorized = false, source = "NONE" },
            class = managed and managed.class or nil,
            classId = managed and managed.classId or nil,
            level = managed and managed.level or nil,
            race = managed and managed.race or nil,
            faction = managed and managed.faction or nil,
            team = managed and managed.team or nil,
            guildName = managed and managed.guildName or nil,
        }
        view.members[#view.members + 1] = item
    end
    table.sort(view.members, function(a, b)
        local an, bn = self:Lower(a.name or ""), self:Lower(b.name or "")
        if an == bn then return (tonumber(a.guid) or 0) < (tonumber(b.guid) or 0) end
        return an < bn
    end)
    view.memberCount = #view.members
    return view
end

function MB:GetManagedGroup(groupRef)
    local key = self:ResolveManagedGroupKey(groupRef)
    if not key then return nil, "MANAGED_GROUP_NOT_FOUND" end
    local group = self.managedGroupStore and self.managedGroupStore.groups[key]
    if not group then return nil, "MANAGED_GROUP_NOT_FOUND" end
    return managedGroupView(self, group)
end

function MB:GetManagedGroups()
    local result = {}
    if not self.managedGroupStore then return result end
    for _, group in pairs(self.managedGroupStore.groups or {}) do
        local view = managedGroupView(self, group)
        if view then result[#result + 1] = view end
    end
    table.sort(result, function(a, b) return self:Lower(a.name or "") < self:Lower(b.name or "") end)
    return result
end

-- Removes a managed GUID from every persisted group without deleting the
-- groups themselves. Existing group-update semantics are reused so subscribers
-- can refresh immediately after an explicit Forget operation.
function MB:ForgetManagedBotFromGroups(guidKey)
    if not self.managedGroupStore then return 0, {} end
    guidKey = tostring(guidKey or "")
    if guidKey == "" then return 0, {} end
    local changed = {}
    local now = epochNow()
    local numericGuid = tonumber(guidKey)
    for groupId, group in pairs(self.managedGroupStore.groups or {}) do
        if type(group) == "table" and type(group.members) == "table"
            and (group.members[guidKey] ~= nil or (numericGuid and group.members[numericGuid] ~= nil)) then
            group.members[guidKey] = nil
            if numericGuid then group.members[numericGuid] = nil end
            group.updatedAt = now
            changed[#changed + 1] = tostring(groupId)
        end
    end
    table.sort(changed)
    for _, groupId in ipairs(changed) do
        local group = self.managedGroupStore.groups[groupId]
        self:Emit("MB_MANAGED_GROUP_UPDATED", groupId, self:Copy(managedGroupView(self, group)), "MEMBER_FORGOTTEN", tonumber(guidKey) or guidKey)
    end
    return #changed, changed
end

function MB:CreateManagedGroup(name)
    if not self.managedGroupStore then return nil, "MANAGED_GROUP_STORE_NOT_READY" end
    name = self:Trim(name)
    if name == "" then return nil, "GROUP_NAME_REQUIRED" end
    if #name > 64 then return nil, "GROUP_NAME_TOO_LONG" end
    local nameKey = groupNameKey(self, name)
    if self.managedGroupStore.nameIndex[nameKey] then return nil, "GROUP_NAME_EXISTS" end
    local id
    repeat
        id = "managed-group-" .. tostring(self.managedGroupStore.nextId)
        self.managedGroupStore.nextId = self.managedGroupStore.nextId + 1
    until not self.managedGroupStore.groups[id]
    local now = epochNow()
    local group = {
        schemaVersion = GROUP_SCHEMA_VERSION, id = id, name = name,
        createdAt = now, updatedAt = now, members = {},
    }
    self.managedGroupStore.groups[id] = group
    self.managedGroupStore.nameIndex[nameKey] = id
    local view = managedGroupView(self, group)
    self:Emit("MB_MANAGED_GROUP_UPDATED", id, self:Copy(view), "CREATED")
    return view
end

function MB:RenameManagedGroup(groupRef, newName)
    local key = self:ResolveManagedGroupKey(groupRef)
    if not key then return nil, "MANAGED_GROUP_NOT_FOUND" end
    newName = self:Trim(newName)
    if newName == "" then return nil, "GROUP_NAME_REQUIRED" end
    if #newName > 64 then return nil, "GROUP_NAME_TOO_LONG" end
    local newKey = groupNameKey(self, newName)
    local existing = self.managedGroupStore.nameIndex[newKey]
    if existing and existing ~= key then return nil, "GROUP_NAME_EXISTS" end
    local group = self.managedGroupStore.groups[key]
    local oldKey = groupNameKey(self, group.name)
    if oldKey and self.managedGroupStore.nameIndex[oldKey] == key then self.managedGroupStore.nameIndex[oldKey] = nil end
    group.name = newName
    group.updatedAt = epochNow()
    self.managedGroupStore.nameIndex[newKey] = key
    local view = managedGroupView(self, group)
    self:Emit("MB_MANAGED_GROUP_UPDATED", key, self:Copy(view), "RENAMED")
    return view
end

function MB:DeleteManagedGroup(groupRef)
    local key = self:ResolveManagedGroupKey(groupRef)
    if not key then return false, "MANAGED_GROUP_NOT_FOUND" end
    for _, request in pairs(self.managedGroupLifecycleRequests or {}) do
        if request.groupId == key and request.finished ~= true then return false, "GROUP_LIFECYCLE_BUSY" end
    end
    local group = self.managedGroupStore.groups[key]
    local nameKey = groupNameKey(self, group and group.name)
    if nameKey and self.managedGroupStore.nameIndex[nameKey] == key then self.managedGroupStore.nameIndex[nameKey] = nil end
    self.managedGroupStore.groups[key] = nil
    self:Emit("MB_MANAGED_GROUP_DELETED", key, group and group.name or nil)
    return true
end

function MB:AddManagedGroupMember(groupRef, botRef)
    local key = self:ResolveManagedGroupKey(groupRef)
    if not key then return nil, "MANAGED_GROUP_NOT_FOUND" end
    local managed, err = self:GetManagedBot(botRef)
    if not managed then return nil, err or "MANAGED_BOT_NOT_FOUND" end
    local guid = tonumber(managed.guid)
    if not guid or guid <= 0 then return nil, "MANAGED_GUID_REQUIRED" end
    local group = self.managedGroupStore.groups[key]
    local guidKey = tostring(guid)
    if not group.members[guidKey] then
        group.members[guidKey] = { guid = guid, nameAtAdd = managed.name, addedAt = epochNow() }
        group.updatedAt = epochNow()
    else
        group.members[guidKey].nameAtAdd = managed.name or group.members[guidKey].nameAtAdd
    end
    local view = managedGroupView(self, group)
    self:Emit("MB_MANAGED_GROUP_UPDATED", key, self:Copy(view), "MEMBER_ADDED", guid)
    return view
end

function MB:RemoveManagedGroupMember(groupRef, botRef)
    local key = self:ResolveManagedGroupKey(groupRef)
    if not key then return nil, "MANAGED_GROUP_NOT_FOUND" end
    local group = self.managedGroupStore.groups[key]
    local managed = self:GetManagedBot(botRef)
    local guid = managed and tonumber(managed.guid) or tonumber(botRef)
    if not guid and type(botRef) == "string" then
        local bot = self:ResolveBot(botRef)
        guid = bot and tonumber(bot.guid or bot.altGuid) or nil
    end
    if not guid or not group.members[tostring(guid)] then return nil, "GROUP_MEMBER_NOT_FOUND" end
    group.members[tostring(guid)] = nil
    group.updatedAt = epochNow()
    local view = managedGroupView(self, group)
    self:Emit("MB_MANAGED_GROUP_UPDATED", key, self:Copy(view), "MEMBER_REMOVED", guid)
    return view
end

local function bulkRequestView(self, request)
    if type(request) ~= "table" then return nil end
    local results = {}
    for _, entry in ipairs(request.results or {}) do results[#results + 1] = self:Copy(entry) end
    return {
        id = request.id, originModule = request.originModule, groupId = request.groupId, groupName = request.groupName,
        action = request.action, status = request.status, code = request.code, ok = request.ok == true,
        sessionEpoch = request.sessionEpoch, concurrency = request.concurrency, total = request.total,
        started = request.started or 0, completed = request.completed or 0, inFlight = request.inFlight or 0,
        confirmed = request.confirmed or 0, skipped = request.skipped or 0, failed = request.failed or 0,
        refused = request.refused or 0, ambiguous = request.ambiguous or 0, notDispatched = request.notDispatched or 0,
        createdAt = request.createdAt, completedAt = request.completedAt, results = results,
    }
end

function MB:GetManagedGroupLifecycleAvailability(groupRef, action, options)
    action = normalizeAction(self, action)
    if not action then return { enabled = false, reason = "INVALID_LIFECYCLE_ACTION" } end
    local group, err = self:GetManagedGroup(groupRef)
    if not group then return { enabled = false, reason = err or "MANAGED_GROUP_NOT_FOUND", action = action } end
    if group.memberCount <= 0 then return { enabled = false, reason = "GROUP_EMPTY", action = action, group = group } end
    if not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED", action = action, group = group } end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY", action = action, group = group } end
    if not self:BridgeHasCapability("BOT_LIFECYCLE_V1") then return { enabled = false, reason = "CAPABILITY_UNAVAILABLE", action = action, group = group } end
    local needsResolve = false
    for _, member in ipairs(group.members or {}) do
        if member.altRosterPresent ~= true then needsResolve = true; break end
    end
    if needsResolve and not self:BridgeHasCapability("BOT_TARGET_RESOLVE_V1") then
        return { enabled = false, reason = "TARGET_RESOLVE_CAPABILITY_UNAVAILABLE", action = action, group = group }
    end
    for _, request in pairs(self.managedGroupLifecycleRequests or {}) do
        if request.groupId == group.id and request.finished ~= true then
            return { enabled = false, reason = "GROUP_LIFECYCLE_BUSY", action = action, group = group, requestId = request.id }
        end
    end
    for _, member in ipairs(group.members or {}) do
        local reserved = self.managedGroupLifecycleGuidReservations and self.managedGroupLifecycleGuidReservations[tostring(member.guid)]
        if reserved then
            return { enabled = false, reason = "GROUP_MEMBER_BUSY", action = action, group = group, busyGuid = member.guid, requestId = reserved }
        end
    end
    options = type(options) == "table" and options or {}
    local concurrency = math.floor(tonumber(options.concurrency) or BULK_DEFAULT_CONCURRENCY)
    if concurrency < 1 then concurrency = 1 end
    if concurrency > BULK_MAX_CONCURRENCY then concurrency = BULK_MAX_CONCURRENCY end
    return {
        enabled = true, reason = nil, action = action, group = group, groupId = group.id, groupName = group.name,
        memberCount = group.memberCount, concurrency = concurrency, maxConcurrency = BULK_MAX_CONCURRENCY,
        execution = "PER_MEMBER_REQUEST_BOT_LIFECYCLE", finalState = finalStateFor(action),
    }
end

local function classifyChildResult(request, member, result)
    local entry = {
        guid = member.guid, name = member.name, childRequestId = result and result.requestId or member.childRequestId,
        status = result and result.status or "REFUSED", code = result and result.code or "LIFECYCLE_DISPATCH_FAILED",
        authority = result and result.authority or nil,
    }
    local tx = result and result.transaction or nil
    entry.transactionId = tx and tx.id or nil
    entry.transactionState = tx and tx.state or nil
    entry.lifecycleState = tx and tx.result and tx.result.lifecycleState or nil
    entry.proof = tx and tx.result and tx.result.proof or nil
    local alreadyFinal = (request.action == "CONNECT" and entry.code == "ALREADY_ONLINE") or (request.action == "DISCONNECT" and entry.code == "ALREADY_OFFLINE")
    if alreadyFinal then
        entry.outcome = "SKIPPED_ALREADY_FINAL"
        request.skipped = request.skipped + 1
    elseif result and result.ok == true and tx and tx.state == "CONFIRMED" then
        entry.outcome = "CONFIRMED"
        request.confirmed = request.confirmed + 1
    elseif tx and tx.state == "AMBIGUOUS" then
        entry.outcome = "AMBIGUOUS"
        request.ambiguous = request.ambiguous + 1
    elseif result and result.status == "REFUSED" then
        entry.outcome = "REFUSED"
        request.refused = request.refused + 1
    else
        entry.outcome = "FAILED"
        request.failed = request.failed + 1
    end
    return entry
end

local function finalizeBulkRequest(self, request, status, code)
    if not request or request.finished then return end
    request.finished = true
    request.status = status or "COMPLETED"
    request.code = code or ((request.failed + request.refused + request.ambiguous + request.notDispatched) == 0 and "GROUP_LIFECYCLE_COMPLETE" or "GROUP_LIFECYCLE_PARTIAL")
    request.ok = request.status == "COMPLETED" and (request.failed + request.refused + request.ambiguous + request.notDispatched) == 0
    request.completedAt = self:Now()
    for _, member in ipairs(request.members or {}) do
        local guidKey = tostring(member.guid or "")
        if self.managedGroupLifecycleGuidReservations and self.managedGroupLifecycleGuidReservations[guidKey] == request.id then
            self.managedGroupLifecycleGuidReservations[guidKey] = nil
        end
    end
    local view = bulkRequestView(self, request)
    self.managedGroupLifecycleRequests[request.id] = nil
    self:Emit("MB_MANAGED_GROUP_LIFECYCLE_RESULT", self:Copy(view))
    if type(request.callback) == "function" then self:SafeCall(request.callback, self:Copy(view)) end
end

local function emitBulkProgress(self, request, memberResult)
    self:Emit("MB_MANAGED_GROUP_LIFECYCLE_PROGRESS", self:Copy(bulkRequestView(self, request)), self:Copy(memberResult))
end

local function pumpBulkLifecycle(self, request)
    if not request or request.finished or self.managedGroupLifecycleRequests[request.id] ~= request then return end
    if request.sessionEpoch ~= self.sessionEpoch or not self.bridge.connected then
        self:AbortManagedGroupLifecycleRequest(request.id, "BRIDGE_SESSION_CHANGED")
        return
    end
    while not request.finished and request.inFlight < request.concurrency and request.nextIndex <= request.total do
        local member = request.members[request.nextIndex]
        request.nextIndex = request.nextIndex + 1
        if not member or not member.name then
            request.completed = request.completed + 1
            request.refused = request.refused + 1
            local bad = { guid = member and member.guid or nil, name = member and member.name or nil, outcome = "REFUSED", code = "MANAGED_BOT_NOT_FOUND" }
            request.results[#request.results + 1] = bad
            emitBulkProgress(self, request, bad)
        else
            request.started = request.started + 1
            request.inFlight = request.inFlight + 1
            request.activeByGuid[tostring(member.guid)] = true
            local childId, childStatus = self:RequestBotLifecycle(request.originModule, member.name, request.action, function(childResult)
                local live = MB.managedGroupLifecycleRequests[request.id]
                if live ~= request or request.finished then return end
                request.inFlight = math.max(0, request.inFlight - 1)
                request.activeByGuid[tostring(member.guid)] = nil
                request.completed = request.completed + 1
                local memberResult = classifyChildResult(request, member, childResult)
                request.results[#request.results + 1] = memberResult
                emitBulkProgress(MB, request, memberResult)
                if request.completed >= request.total then
                    finalizeBulkRequest(MB, request, "COMPLETED")
                else
                    MB:After(0, function() pumpBulkLifecycle(MB, request) end)
                end
            end)
            member.childRequestId = childId
            if not childId then
                request.inFlight = math.max(0, request.inFlight - 1)
                request.activeByGuid[tostring(member.guid)] = nil
                request.completed = request.completed + 1
                local immediate = classifyChildResult(request, member, { status = "REFUSED", code = childStatus or "LIFECYCLE_DISPATCH_FAILED", ok = false })
                request.results[#request.results + 1] = immediate
                emitBulkProgress(self, request, immediate)
            end
        end
    end
    if not request.finished and request.completed >= request.total then finalizeBulkRequest(self, request, "COMPLETED") end
end

function MB:RequestManagedGroupLifecycle(originModule, groupRef, action, callback, options)
    local availability = self:GetManagedGroupLifecycleAvailability(groupRef, action, options)
    if not availability.enabled then return nil, availability.reason or "GROUP_LIFECYCLE_UNAVAILABLE" end
    local group = availability.group
    self.managedGroupLifecycleRequestSequence = (self.managedGroupLifecycleRequestSequence or 0) + 1
    local id = "group-lifecycle-" .. tostring(self.managedGroupLifecycleRequestSequence)
    local members = {}
    for _, item in ipairs(group.members or {}) do
        members[#members + 1] = { guid = tonumber(item.guid), name = item.name }
    end
    local request = {
        id = id, originModule = originModule, groupId = group.id, groupName = group.name,
        action = availability.action, status = "RUNNING", code = nil, ok = false,
        sessionEpoch = self.sessionEpoch, concurrency = availability.concurrency,
        members = members, total = #members, nextIndex = 1, inFlight = 0, started = 0, completed = 0,
        confirmed = 0, skipped = 0, failed = 0, refused = 0, ambiguous = 0, notDispatched = 0,
        results = {}, activeByGuid = {}, callback = callback, createdAt = self:Now(), finished = false,
    }
    self.managedGroupLifecycleRequests[id] = request
    self.managedGroupLifecycleGuidReservations = self.managedGroupLifecycleGuidReservations or {}
    for _, member in ipairs(members) do self.managedGroupLifecycleGuidReservations[tostring(member.guid)] = id end
    self:Emit("MB_MANAGED_GROUP_LIFECYCLE_STARTED", self:Copy(bulkRequestView(self, request)))
    self:After(0, function() pumpBulkLifecycle(MB, request) end)
    return id, "RUNNING"
end

function MB:GetManagedGroupLifecycleRequest(requestId)
    local request = self.managedGroupLifecycleRequests and self.managedGroupLifecycleRequests[tostring(requestId or "")]
    return request and bulkRequestView(self, request) or nil
end

function MB:GetManagedGroupLifecycleRequests()
    local result = {}
    for _, request in pairs(self.managedGroupLifecycleRequests or {}) do result[#result + 1] = bulkRequestView(self, request) end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

function MB:AbortManagedGroupLifecycleRequest(requestId, reason)
    local request = self.managedGroupLifecycleRequests and self.managedGroupLifecycleRequests[requestId]
    if not request or request.finished then return false end
    reason = reason or "GROUP_LIFECYCLE_ABORTED"
    local seen = {}
    for _, result in ipairs(request.results or {}) do if result.guid then seen[tostring(result.guid)] = true end end
    for _, member in ipairs(request.members or {}) do
        local guidKey = tostring(member.guid or "")
        if not seen[guidKey] then
            local active = request.activeByGuid and request.activeByGuid[guidKey] == true
            local entry = { guid = member.guid, name = member.name, code = reason }
            if active then
                entry.outcome = reason == "BRIDGE_SESSION_CHANGED" and "AMBIGUOUS_SESSION_RESET" or "ABORTED_IN_FLIGHT"
                if reason == "BRIDGE_SESSION_CHANGED" then request.ambiguous = request.ambiguous + 1 else request.failed = request.failed + 1 end
            else
                entry.outcome = "NOT_DISPATCHED"
                request.notDispatched = request.notDispatched + 1
            end
            request.results[#request.results + 1] = entry
        end
    end
    request.completed = request.total
    request.inFlight = 0
    finalizeBulkRequest(self, request, "ABORTED", reason)
    return true
end

function MB:AbortManagedGroupLifecycleRequests(reason, originModule)
    local ids = {}
    for id, request in pairs(self.managedGroupLifecycleRequests or {}) do
        if not originModule or request.originModule == originModule then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do self:AbortManagedGroupLifecycleRequest(id, reason or "GROUP_LIFECYCLE_ABORTED") end
    return #ids
end

function MB:GetManagedGroupLifecycleContract()
    return {
        implemented = true, persistence = "GUID_MEMBERSHIP_SAVEDVARIABLES", authorization = "PER_MEMBER_REQUEST_BOT_LIFECYCLE",
        defaultConcurrency = BULK_DEFAULT_CONCURRENCY, maxConcurrency = BULK_MAX_CONCURRENCY,
        retryAfterSend = false, chatFallbackAfterSend = false,
        alreadyFinal = "SKIPPED", sessionReset = "ABORT_REMAINING",
    }
end
