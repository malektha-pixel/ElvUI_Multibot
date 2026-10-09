local _, MB = ...

function MB:ReadKey(domainId, targetKey)
    return self:CacheKey(domainId, targetKey)
end

function MB:GetDomainInterval(descriptor)
    if descriptor.onDemand then return nil end
    local key = descriptor.intervalKey
    local configured = key and self.db and self.db.updates and tonumber(self.db.updates[key]) or nil
    return configured or tonumber(descriptor.defaultInterval) or 30
end

function MB:RefreshDomain(domainId, target, callback, options)
    local descriptor = self.dataDomains[domainId]
    if not descriptor then return nil, "UNKNOWN_DOMAIN" end
    if descriptor.provider == "DERIVED" then
        local value, meta = self:GetData(domainId, target)
        if type(callback) == "function" then self:SafeCall(callback, value, meta) end
        return "DERIVED"
    end

    local targetKey, targetInfo, err = self:NormalizeDomainTarget(domainId, target, true)
    if not targetKey then return nil, err end
    local readKey = self:ReadKey(domainId, targetKey)
    local pending = self.pendingReads[readKey]
    if pending then
        if type(callback) == "function" then pending.callbacks[#pending.callbacks + 1] = callback end
        self.runtime.counters.readsDeduped = self.runtime.counters.readsDeduped + 1
        return pending.id, "DEDUPED"
    end

    self.pendingReadSequence = self.pendingReadSequence + 1
    local timeout = options and tonumber(options.timeout) or (self.db and self.db.bridge and tonumber(self.db.bridge.requestTimeout)) or 8
    local request = {
        id = "read-" .. tostring(self.pendingReadSequence),
        domainId = domainId,
        targetKey = targetKey,
        targetInfo = targetInfo,
        descriptor = descriptor,
        callbacks = {},
        startedAt = self:Now(),
        expiresAt = self:Now() + timeout,
        sessionEpoch = self.sessionEpoch,
    }
    if type(callback) == "function" then request.callbacks[#request.callbacks + 1] = callback end
    self.pendingReads[readKey] = request
    self.runtime.counters.readsStarted = self.runtime.counters.readsStarted + 1

    local ok, tokenOrError
    if descriptor.provider == "CLIENT_INSPECT" and self.BeginClientInspectObservation then
        ok, tokenOrError = self:BeginClientInspectObservation(request)
    elseif descriptor.provider == "CLIENT_STATE" then
        local value, meta = self:GetDataByKey(domainId, targetKey)
        if value == nil and domainId == "BOT.SPELL_EXCLUSIONS" and self.EnsureSpellExclusionSnapshot then
            local targetRef = request.targetInfo and (request.targetInfo.botName or request.targetInfo.botKey) or request.targetKey
            value = self:EnsureSpellExclusionSnapshot(targetRef)
            value, meta = self:GetDataByKey(domainId, targetKey)
        end
        if value ~= nil then
            self:CompleteRead(request, value, meta or { status = "OK", source = "CLIENT_STATE" })
            return request.id
        end
        ok, tokenOrError = false, "CLIENT_STATE_MISSING"
    else
        ok, tokenOrError = self:DispatchDomainRead(request)
    end
    if not ok then
        self.pendingReads[readKey] = nil
        self.runtime.counters.readsFailed = self.runtime.counters.readsFailed + 1
        self:SetDataError(domainId, targetKey, tokenOrError or "DISPATCH_FAILED")
        for _, cb in ipairs(request.callbacks) do self:SafeCall(cb, nil, { status = "ERROR", error = tokenOrError or "DISPATCH_FAILED" }) end
        return nil, tokenOrError or "DISPATCH_FAILED"
    end
    request.token = tokenOrError
    return request.id
end

function MB:CompleteRead(request, value, meta)
    if not request then return end
    local readKey = self:ReadKey(request.domainId, request.targetKey)
    if self.pendingReads[readKey] ~= request then return end
    self.pendingReads[readKey] = nil
    self.runtime.counters.readsCompleted = self.runtime.counters.readsCompleted + 1
    for _, callback in ipairs(request.callbacks or {}) do self:SafeCall(callback, self:Copy(value), self:Copy(meta)) end
end

function MB:FailRead(request, errorCode)
    if not request then return end
    local readKey = self:ReadKey(request.domainId, request.targetKey)
    if self.pendingReads[readKey] ~= request then return end
    self.pendingReads[readKey] = nil
    self.runtime.counters.readsFailed = self.runtime.counters.readsFailed + 1
    self:SetDataError(request.domainId, request.targetKey, errorCode)
    for _, callback in ipairs(request.callbacks or {}) do self:SafeCall(callback, nil, { status = "ERROR", error = errorCode, targetKey = request.targetKey }) end
end

function MB:OnDataCommitted(domainId, targetKey, meta)
    local readKey = self:ReadKey(domainId, targetKey)
    local request = self.pendingReads[readKey]
    if not request then return end
    if request.sessionEpoch ~= self.sessionEpoch then return end
    if request.token and meta and meta.token and tostring(request.token) ~= tostring(meta.token) then return end
    local value, cacheMeta = self:GetDataByKey(domainId, targetKey)
    self:CompleteRead(request, value, cacheMeta)
end

function MB:FindPendingReadByToken(token)
    token = self:Trim(token)
    if token == "" then return nil end
    for _, request in pairs(self.pendingReads) do
        if tostring(request.token or "") == token then return request end
    end
end

function MB:AcquireInterest(moduleName, domainId, target, options)
    moduleName = self:Trim(moduleName)
    if moduleName == "" then return nil, "MODULE_REQUIRED" end
    if not self.modules[moduleName] then self:RegisterModule(moduleName) end
    local descriptor = self.dataDomains[domainId]
    if not descriptor then return nil, "UNKNOWN_DOMAIN" end
    local targetKey, targetInfo, err = self:NormalizeDomainTarget(domainId, target, true)
    if not targetKey then return nil, err end
    local key = self:ReadKey(domainId, targetKey)
    local interest = self.interests[key] or {
        domainId = domainId,
        targetKey = targetKey,
        targetInfo = targetInfo,
        modules = {},
        nextAt = 0,
    }
    interest.modules[moduleName] = {
        interval = options and tonumber(options.interval) or nil,
        acquiredAt = self:Now(),
    }
    self.interests[key] = interest
    if not options or options.refreshNow ~= false then self:RefreshDomain(domainId, targetInfo) end
    return key
end

function MB:ReleaseInterest(moduleName, domainId, target)
    local targetKey = self:NormalizeDomainTarget(domainId, target, true)
    if not targetKey then return false end
    local key = self:ReadKey(domainId, targetKey)
    local interest = self.interests[key]
    if not interest then return false end
    interest.modules[moduleName] = nil
    if next(interest.modules) == nil then self.interests[key] = nil end
    return true
end

function MB:ReleaseModuleInterests(moduleName)
    local empty = {}
    for key, interest in pairs(self.interests) do
        interest.modules[moduleName] = nil
        if next(interest.modules) == nil then empty[#empty + 1] = key end
    end
    for _, key in ipairs(empty) do self.interests[key] = nil end
end

function MB:GetInterestCount(domainId, targetKey)
    local interest = self.interests[self:ReadKey(domainId, targetKey)]
    if not interest then return 0 end
    return self:TableCount(interest.modules)
end

function MB:QueueInterestedRefresh(domainId, targetKey)
    local interest = self.interests[self:ReadKey(domainId, targetKey)]
    if interest then interest.nextAt = 0 end
end

local function effectiveInterval(self, interest, descriptor)
    -- Some bridge-backed domains are intentionally explicit-only even if a
    -- subscriber passes an interval. This prevents an accidental Acquire()
    -- option from turning an expensive semantic read into background polling.
    if descriptor and descriptor.suppressPeriodic then return nil end

    local best = self:GetDomainInterval(descriptor)
    for _, moduleOptions in pairs(interest.modules) do
        local requested = tonumber(moduleOptions.interval)
        if requested and requested > 0 and (not best or requested < best) then best = requested end
    end
    return best
end

function MB:RunDataScheduler()
    if not self.bridge.connected then return end
    local now = self:Now()
    for _, interest in pairs(self.interests) do
        local descriptor = self.dataDomains[interest.domainId]
        if descriptor then
            local interval = effectiveInterval(self, interest, descriptor)
            if (not descriptor.onDemand or interval) and now >= (interest.nextAt or 0) then
                self:RefreshDomain(interest.domainId, interest.targetInfo)
                interest.nextAt = now + (interval or 999999)
            end
        end
    end
end

function MB:AbortPendingReads(reason)
    if self.AbortQuestMetadataReads then self:AbortQuestMetadataReads(reason or "SESSION_RESET") end
    reason = self:Trim(reason)
    if reason == "" then reason = "SESSION_RESET" end
    local pending = {}
    for _, request in pairs(self.pendingReads) do pending[#pending + 1] = request end
    for _, request in ipairs(pending) do
        self:FailRead(request, reason)
        if request.token and self.bridge.frames[request.token] then self.bridge.frames[request.token] = nil end
    end
    return #pending
end

function MB:RunReadTimeouts()
    local now = self:Now()
    local expired = {}
    for _, request in pairs(self.pendingReads) do
        if now >= (request.expiresAt or 0) then expired[#expired + 1] = request end
    end
    for _, request in ipairs(expired) do
        self:FailRead(request, "TIMEOUT")
        if request.token and self.bridge.frames[request.token] then self.bridge.frames[request.token] = nil end
    end
end

function MB:RefreshActiveData()
    for _, interest in pairs(self.interests) do interest.nextAt = 0 end
    self:BridgeRequestRoster()
    self:BridgeRequestStates()
    self:BridgeRequestDetails()
    if self:BridgeHasCapability("ALT_ROSTER_V1") then self:RefreshDomain("ALT.ROSTER") end
end
