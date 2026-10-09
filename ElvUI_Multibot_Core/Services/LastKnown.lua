local _, MB = ...

local LAST_KNOWN_SCHEMA_VERSION = 1

local function epochNow()
    if type(time) == "function" then return time() end
    return 0
end

local function managedEntry(self, guidKey)
    return self.managedStore and self.managedStore.entries and self.managedStore.entries[tostring(guidKey)] or nil
end

local function managedGuidKey(self, botRef)
    if not self.managedStore then return nil end
    if self.ResolveManagedKey then
        local key = self:ResolveManagedKey(botRef)
        if key then return tostring(key) end
    end
    return nil
end

local function sourceAllowed(descriptor, source)
    local allowed = descriptor and descriptor.retainLastKnownSources
    if type(allowed) ~= "table" then return true end
    return allowed[tostring(source or "")] == true
end

local function historicalMeta(self, domainId, guidKey, value, liveMeta, observedAt)
    liveMeta = type(liveMeta) == "table" and liveMeta or {}
    value = type(value) == "table" and value or {}
    local entry = managedEntry(self, guidKey)
    local meta = {
        status = "OK",
        domain = domainId,
        guid = tonumber(guidKey) or guidKey,
        name = entry and entry.name or value.name or value.bot,
        historical = true,
        persistent = true,
        neverLiveAuthority = true,
        observedAt = observedAt,
        source = liveMeta.source or value.source,
    }

    local complete = liveMeta.complete
    if complete == nil then complete = value.complete end
    if complete ~= nil then meta.complete = complete == true end

    local authoritative = liveMeta.authoritative
    if authoritative == nil then authoritative = value.authoritative end
    if authoritative ~= nil then meta.authoritative = authoritative == true end

    if liveMeta.authority ~= nil then meta.authority = self:Copy(liveMeta.authority) end
    if value.hasPhysicalLocations ~= nil then meta.physical = value.hasPhysicalLocations == true end
    if value.locationModel ~= nil then meta.layout = value.locationModel end
    if value.exactStackAddressable ~= nil then meta.exactStackAddressable = value.exactStackAddressable == true end
    if value.sessionScoped ~= nil then meta.sourceSessionScoped = value.sessionScoped == true end
    if liveMeta.sessionScoped ~= nil then meta.sourceSessionScoped = liveMeta.sessionScoped == true end
    if liveMeta.persistent ~= nil then meta.sourcePersistent = liveMeta.persistent == true end
    if liveMeta.available ~= nil then meta.sourceAvailable = liveMeta.available == true end
    return meta
end

local function retainedCommitAllowed(self, domainId, value, liveMeta)
    local descriptor = self.dataDomains and self.dataDomains[domainId] or nil
    if not descriptor or descriptor.retainLastKnown ~= true then return false, "DOMAIN_NOT_RETAINED", descriptor end
    if descriptor.scope ~= "BOT" then return false, "BOT_SCOPE_REQUIRED", descriptor end
    if not self.lastKnownStore then return false, "LAST_KNOWN_STORE_NOT_READY", descriptor end
    if value == nil then return false, "VALUE_REQUIRED", descriptor end

    liveMeta = type(liveMeta) == "table" and liveMeta or {}
    if liveMeta.stale == true or liveMeta.error ~= nil then return false, "LIVE_VALUE_NOT_CURRENT", descriptor end
    if liveMeta.complete == false then return false, "INCOMPLETE_VALUE", descriptor end
    if type(value) == "table" and value.complete == false then return false, "INCOMPLETE_VALUE", descriptor end

    local source = liveMeta.source or (type(value) == "table" and value.source) or nil
    if not sourceAllowed(descriptor, source) then return false, "SOURCE_NOT_RETAINED", descriptor end
    return true, nil, descriptor
end

local function storeHistoricalRecord(self, domainId, guidKey, value, liveMeta, observedAt)
    observedAt = tonumber(observedAt) or epochNow()
    if observedAt <= 0 then return false, "WALL_CLOCK_UNAVAILABLE" end
    guidKey = tostring(guidKey)

    local persisted = self.lastKnownStore.bots[guidKey]
    if type(persisted) ~= "table" then
        persisted = { schemaVersion = LAST_KNOWN_SCHEMA_VERSION, guid = tonumber(guidKey) or guidKey, domains = {} }
    end
    persisted.schemaVersion = LAST_KNOWN_SCHEMA_VERSION
    persisted.guid = tonumber(guidKey) or persisted.guid or guidKey
    persisted.domains = type(persisted.domains) == "table" and persisted.domains or {}

    local managed = managedEntry(self, guidKey)
    if managed and managed.name then persisted.name = managed.name end

    local record = {
        schemaVersion = LAST_KNOWN_SCHEMA_VERSION,
        domain = domainId,
        observedAt = observedAt,
        value = self:Copy(value),
        meta = historicalMeta(self, domainId, guidKey, value, liveMeta, observedAt),
    }
    persisted.domains[domainId] = record
    self.lastKnownStore.bots[guidKey] = persisted
    return true, self:Copy(record)
end

function MB:InitializeLastKnownStore()
    local saved = _G.ElvUI_Multibot_LastKnownDB
    if type(saved) ~= "table" then saved = {}; _G.ElvUI_Multibot_LastKnownDB = saved end
    saved.schemaVersion = LAST_KNOWN_SCHEMA_VERSION
    saved.bots = type(saved.bots) == "table" and saved.bots or {}

    -- Identity remains owned by Managed Roster. Historical storage is keyed only
    -- by that stable GUID and deliberately keeps no independent name index.
    for guidKey, botRecord in pairs(saved.bots) do
        if type(botRecord) ~= "table" then
            saved.bots[guidKey] = nil
        else
            botRecord.schemaVersion = LAST_KNOWN_SCHEMA_VERSION
            botRecord.guid = tonumber(botRecord.guid) or tonumber(guidKey) or botRecord.guid
            botRecord.domains = type(botRecord.domains) == "table" and botRecord.domains or {}
        end
    end
    self.lastKnownStore = saved
    self.lastKnownPending = {}
end

function MB:ResetLastKnownSessionState()
    self.lastKnownPending = {}
end

-- Removes only the persisted/display-only history owned by LastKnown for one
-- stable managed GUID. Pending pre-GUID observations for the same historical
-- name are also discarded so an explicit Forget cannot be undone by stale
-- current-session staging. This never touches canonical live data.
function MB:ForgetLastKnownForManagedBot(guidKey, name, clearPending)
    guidKey = tostring(guidKey or "")
    if guidKey == "" then return 0 end
    local removed = 0
    if self.lastKnownStore and self.lastKnownStore.bots and self.lastKnownStore.bots[guidKey] ~= nil then
        self.lastKnownStore.bots[guidKey] = nil
        removed = removed + 1
    end

    if clearPending == nil then clearPending = true end
    local nameKey = clearPending and self:BotKey(name) or nil
    if nameKey and self.lastKnownPending then
        local purge = {}
        for pendingKey, pending in pairs(self.lastKnownPending) do
            if type(pending) == "table" and pending.targetKey == nameKey then purge[#purge + 1] = pendingKey end
        end
        for _, pendingKey in ipairs(purge) do self.lastKnownPending[pendingKey] = nil end
    end
    return removed
end

function MB:CanRetainLastKnown(domainId, targetKey, value, liveMeta)
    local allowed, reason = retainedCommitAllowed(self, domainId, value, liveMeta)
    if not allowed then return false, reason end
    local guidKey = managedGuidKey(self, targetKey)
    if not guidKey then return false, "MANAGED_GUID_REQUIRED" end
    return true, guidKey
end

function MB:RetainLastKnown(domainId, targetKey, value, liveMeta)
    local allowed, reason = retainedCommitAllowed(self, domainId, value, liveMeta)
    if not allowed then return false, reason end
    local observedAt = epochNow()
    if observedAt <= 0 then return false, "WALL_CLOCK_UNAVAILABLE" end

    local guidKey = managedGuidKey(self, targetKey)
    if not guidKey then
        -- Some bridge data can arrive before a linked/managed GUID is learned.
        -- Keep only the newest successful observation in memory and bind it later;
        -- this never creates a second persistent identity database.
        self.lastKnownPending = self.lastKnownPending or {}
        local pendingKey = self:CacheKey(domainId, targetKey)
        self.lastKnownPending[pendingKey] = {
            domainId = domainId,
            targetKey = targetKey,
            value = self:Copy(value),
            meta = self:Copy(liveMeta or {}),
            observedAt = observedAt,
            sessionEpoch = self.sessionEpoch,
        }
        return false, "MANAGED_GUID_PENDING"
    end

    self.lastKnownPending = self.lastKnownPending or {}
    self.lastKnownPending[self:CacheKey(domainId, targetKey)] = nil
    return storeHistoricalRecord(self, domainId, guidKey, value, liveMeta, observedAt)
end

function MB:BackfillLastKnownForBot(botRef)
    if not self.lastKnownStore then return 0 end
    local guidKey = managedGuidKey(self, botRef)
    if not guidKey then return 0 end
    local managed = managedEntry(self, guidKey)
    local name = managed and managed.name or (type(botRef) == "table" and botRef.name) or botRef
    local botKey = self:BotKey(name)
    if not botKey then return 0 end

    local retained = 0
    self.lastKnownPending = self.lastKnownPending or {}
    local remove = {}
    for pendingKey, pending in pairs(self.lastKnownPending) do
        if type(pending) == "table" and pending.targetKey == botKey then
            if tonumber(pending.sessionEpoch) == tonumber(self.sessionEpoch) then
                local ok = storeHistoricalRecord(self, pending.domainId, guidKey, pending.value, pending.meta, pending.observedAt)
                if ok then retained = retained + 1 end
            end
            remove[#remove + 1] = pendingKey
        end
    end
    for _, pendingKey in ipairs(remove) do self.lastKnownPending[pendingKey] = nil end
    return retained
end

function MB:GetLastKnown(domainId, botRef)
    local descriptor = self.dataDomains and self.dataDomains[domainId] or nil
    if not descriptor then return nil, { status = "ERROR", error = "UNKNOWN_DOMAIN" } end
    if descriptor.retainLastKnown ~= true then return nil, { status = "UNAVAILABLE", error = "DOMAIN_NOT_RETAINED", domain = domainId, historical = true } end
    if not self.lastKnownStore then return nil, { status = "UNAVAILABLE", error = "LAST_KNOWN_STORE_NOT_READY", historical = true } end

    local guidKey = managedGuidKey(self, botRef)
    if not guidKey then return nil, { status = "MISSING", error = "MANAGED_BOT_NOT_FOUND", historical = true, domain = domainId } end
    local botRecord = self.lastKnownStore.bots[tostring(guidKey)]
    local record = botRecord and botRecord.domains and botRecord.domains[domainId] or nil
    if type(record) ~= "table" or record.value == nil then
        return nil, { status = "MISSING", historical = true, domain = domainId, guid = tonumber(guidKey) or guidKey }
    end
    return self:Copy(record.value), self:Copy(record.meta or {})
end

function MB:GetLastKnownMeta(domainId, botRef)
    local _, meta = self:GetLastKnown(domainId, botRef)
    return meta
end

function MB:HasLastKnown(domainId, botRef)
    local value = self:GetLastKnown(domainId, botRef)
    return value ~= nil
end

function MB:GetLastKnownDomains(botRef)
    local guidKey = managedGuidKey(self, botRef)
    if not guidKey or not self.lastKnownStore then return {} end
    local botRecord = self.lastKnownStore.bots[tostring(guidKey)]
    local out = {}
    for domainId, record in pairs(botRecord and botRecord.domains or {}) do
        if self.dataDomains[domainId] and self.dataDomains[domainId].retainLastKnown == true and type(record) == "table" and record.value ~= nil then
            out[#out + 1] = { domain = domainId, meta = self:Copy(record.meta or {}) }
        end
    end
    table.sort(out, function(a, b) return tostring(a.domain) < tostring(b.domain) end)
    return out
end
